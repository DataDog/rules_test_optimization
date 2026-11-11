# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Schedule complete file pipelines on a bounded pool of homogeneous workers.

The pool owns queueing and metrics while file workers remain mutually independent.
"""

from __future__ import annotations

from contextlib import nullcontext
from dataclasses import dataclass
import logging
from queue import Empty, Queue
import threading
import time
from typing import Callable, Iterable, Iterator, Protocol, TypeVar

from .metrics import PhaseRecorder
from .models import FileResult, FileStatus, FileTask, PayloadType, RequestOutcome, WorkItemOutcome


RuntimeType = TypeVar("RuntimeType")
TransportType = TypeVar("TransportType")


class FileProcessor(Protocol[RuntimeType, TransportType]):
    def __call__(
        self,
        task: FileTask,
        runtime: RuntimeType,
        transport: TransportType,
    ) -> FileResult: ...


class WorkerPoolError(ValueError):
    """The coordinator cannot safely construct the requested worker pool."""


@dataclass(frozen=True)
class WorkerPoolRun:
    """Deterministic results plus coordinator-owned concurrency observations."""

    results: tuple[FileResult, ...]
    worker_threads: int
    peak_active_workers: int
    requests: tuple[RequestOutcome, ...] = ()


class WorkerPoolInterrupted(KeyboardInterrupt):
    """An interrupt after workers joined, carrying every completed result."""

    def __init__(self, run: WorkerPoolRun, *, cancelled: int) -> None:
        super().__init__("worker pool interrupted")
        self.run = run
        self.cancelled = cancelled


def run_file_workers(
    tasks: Iterable[FileTask],
    *,
    workers: int,
    runtime: RuntimeType,
    transport_factory: Callable[[], TransportType],
    process_file: FileProcessor[RuntimeType, TransportType],
    logger: logging.Logger | None = None,
    measurements: PhaseRecorder | None = None,
    process_cohort: Callable[[tuple[FileTask, ...], RuntimeType, TransportType], Iterable[WorkItemOutcome]] | None = None,
    cohort_size: int = 64,
) -> WorkerPoolRun:
    """Process each source exactly once through one complete worker pipeline.

    Results are returned in intake order for deterministic reports. The pool
    owns aggregate concurrency metrics; file workers remain independent.
    """
    if workers <= 0:
        raise WorkerPoolError("workers must be positive")
    planned_tasks = tuple(tasks)
    task_ids = [task.task_id for task in planned_tasks]
    if len(task_ids) != len(set(task_ids)):
        raise WorkerPoolError("file task IDs must be unique")
    if not planned_tasks:
        return WorkerPoolRun((), 0, 0)

    if cohort_size <= 0:
        raise WorkerPoolError("cohort size must be positive")
    work_items: list[tuple[FileTask, ...]] = []
    pending: list[FileTask] = []
    for task in planned_tasks:
        if process_cohort is not None and task.payload_type is PayloadType.TEST:
            pending.append(task)
            if len(pending) == cohort_size:
                work_items.append(tuple(pending))
                pending.clear()
        else:
            # Discovery interleaves tests and telemetry within every output.
            # Other protocols keep their own work items without closing the
            # unrelated test cohort. Final results restore original order.
            work_items.append((task,))
    if pending:
        work_items.append(tuple(pending))
    worker_count = min(workers, len(work_items))
    try:
        with measurements.phase("transport_setup") if measurements is not None else nullcontext():
            worker_transports = tuple(transport_factory() for _ in range(worker_count))
    except Exception as exc:
        raise WorkerPoolError(
            f"failed to initialize worker transport: {type(exc).__name__}"
        ) from exc

    task_queue: Queue[tuple[FileTask, ...] | None] = Queue(maxsize=max(1, worker_count * 2))
    result_queue: Queue[FileResult] = Queue()
    request_queue: Queue[RequestOutcome] = Queue()
    activity_lock = threading.Lock()
    shutdown_event = threading.Event()
    active_workers = 0
    peak_active_workers = 0
    completed_sources = 0
    attempted_requests = 0

    def request_started() -> None:
        nonlocal attempted_requests
        with activity_lock:
            attempted_requests += 1

    def worker_loop(transport: TransportType) -> None:
        nonlocal active_workers, peak_active_workers, completed_sources, attempted_requests
        set_attempt_callback = getattr(transport, "set_attempt_callback", None)
        live_attempts = callable(set_attempt_callback)
        if live_attempts:
            set_attempt_callback(request_started)
        if logger is not None:
            logger.debug("worker=%s started", threading.current_thread().name)
        while True:
            try:
                cohort = task_queue.get(timeout=0.1)
            except Empty:
                if shutdown_event.is_set():
                    if logger is not None:
                        logger.debug(
                            "worker=%s stopped after interrupt",
                            threading.current_thread().name,
                        )
                    return
                continue
            try:
                if cohort is None:
                    if logger is not None:
                        logger.debug("worker=%s stopped", threading.current_thread().name)
                    return
                if shutdown_event.is_set():
                    continue
                task = cohort[0]
                task_started = time.monotonic()
                if logger is not None:
                    logger.debug(
                        "task=%s type=%s file=%s dequeued worker=%s",
                        task.task_id,
                        task.payload_type.value,
                        task.display_path,
                        threading.current_thread().name,
                    )
                with activity_lock:
                    active_workers += 1
                    peak_active_workers = max(peak_active_workers, active_workers)
                try:
                    outcomes = _owned_work_item_outcomes(cohort, runtime, transport, process_file, process_cohort)
                    try:
                        for outcome in outcomes:
                            for request in outcome.requests:
                                request_queue.put(request)
                            for result in outcome.results:
                                result_queue.put(result)
                            with activity_lock:
                                completed_sources += len(outcome.results)
                                if not live_attempts:
                                    attempted_requests += sum(request.attempts for request in outcome.requests)
                                    attempted_requests += sum(result.requests_attempted for result in outcome.results if not result.request_ids)
                            if shutdown_event.is_set():
                                break
                    finally:
                        outcomes.close()
                finally:
                    with activity_lock:
                        active_workers -= 1
                if logger is not None:
                    logger.debug(
                        "task=%s type=%s file=%s worker=%s completed cohort_sources=%s "
                        "elapsed=%.3fs",
                        task.task_id,
                        task.payload_type.value,
                        task.display_path,
                        threading.current_thread().name,
                        len(cohort),
                        max(0.0, time.monotonic() - task_started),
                    )
            finally:
                task_queue.task_done()

    worker_threads = tuple(
        threading.Thread(
            target=worker_loop,
            args=(transport,),
            name=f"dd-uploader-worker-{index + 1}",
            daemon=False,
        )
        for index, transport in enumerate(worker_transports)
    )
    started_threads: list[threading.Thread] = []

    def stop_started_workers() -> None:
        """Leave no queued work or live non-daemon thread after coordinator exit."""
        shutdown_event.set()
        while True:
            try:
                task_queue.get_nowait()
            except Empty:
                break
            else:
                task_queue.task_done()
        for started_thread in started_threads:
            started_thread.join()
        task_queue.join()

    progress_stop = threading.Event()
    progress_entered = threading.Event()
    progress_thread = None

    def snapshot() -> tuple[int, int, int]:
        with activity_lock:
            return completed_sources, active_workers, attempted_requests

    def report_progress() -> None:
        # Entry proves Thread's own startup bookkeeping is complete; ident
        # alone is published earlier and cannot safely authorize join().
        progress_entered.set()
        _report_progress(progress_stop, logger, snapshot, len(planned_tasks))

    try:
        for thread in worker_threads:
            thread.start()
            started_threads.append(thread)
        if logger is not None and logger.isEnabledFor(logging.INFO):
            try:
                progress_thread = threading.Thread(
                    target=report_progress,
                    name="topt-upload-progress",
                )
                progress_thread.start()
            except (RuntimeError, OSError):
                # Diagnostics must not consume the threads required to upload.
                # Workers already own their slots; lack of a reporter is safe.
                logger.warning("progress reporter unavailable; uploads continue")
        for cohort in work_items:
            task_queue.put(cohort)
            if logger is not None:
                task = cohort[0]
                logger.debug(
                    "task=%s type=%s file=%s enqueued",
                    task.task_id,
                    task.payload_type.value,
                    task.display_path,
                )
        for _ in started_threads:
            task_queue.put(None)
        task_queue.join()
        for thread in started_threads:
            thread.join()
    except KeyboardInterrupt:
        if logger is not None:
            logger.warning("interrupt received; draining unowned file tasks")
        # Stop scheduling queued files, but let already-owned files finish
        # their current pipeline. Their normal cleanup contract still applies;
        # every not-yet-owned source remains untouched. Workers observe the
        # shutdown event after finishing owned work, so no new stop markers are
        # added here: some or all normal markers may already have been
        # consumed when the interrupt arrives.
        stop_started_workers()
        interrupted_run = _collect_run(
            planned_tasks,
            result_queue,
            request_queue,
            worker_count=len(started_threads),
            peak_active_workers=peak_active_workers,
            require_complete=False,
        )
        raise WorkerPoolInterrupted(
            interrupted_run,
            cancelled=len(planned_tasks) - len(interrupted_run.results),
        ) from None
    except Exception as exc:
        stop_started_workers()
        raise WorkerPoolError(
            f"worker pool coordinator failed: {type(exc).__name__}"
        ) from exc

    finally:
        progress_stop.set()
        # start() can be interrupted after the native thread started but before
        # it returned to us. Join that reporter too.
        if progress_thread is not None and progress_thread.ident is not None:
            progress_entered.wait()
            progress_thread.join()
        for transport in worker_transports:
            set_attempt_callback = getattr(transport, "set_attempt_callback", None)
            if callable(set_attempt_callback):
                set_attempt_callback(None)

    return _collect_run(
        planned_tasks,
        result_queue,
        request_queue,
        worker_count=worker_count,
        peak_active_workers=peak_active_workers,
        require_complete=True,
    )


def _report_progress(
    stop: threading.Event,
    logger: logging.Logger,
    snapshot: Callable[[], tuple[int, int, int]],
    total: int,
    clock: Callable[[], float] = time.monotonic,
) -> None:
    """One invocation-owned reporter; shutdown wakes its wait immediately."""
    started = clock()
    while not stop.wait(5.0):
        completed, active, requests = snapshot()
        elapsed = max(0.0, clock() - started)
        rate = completed / elapsed if elapsed else 0.0
        logger.info(
            "progress: completed=%d/%d active=%d requests_attempted=%d files_per_sec=%.2f",
            completed, total, active, requests, rate,
        )

def _owned_work_item_outcomes(
    cohort: tuple[FileTask, ...], runtime: RuntimeType, transport: TransportType,
    process_file: FileProcessor[RuntimeType, TransportType],
    process_cohort: Callable[[tuple[FileTask, ...], RuntimeType, TransportType], Iterable[WorkItemOutcome]] | None,
) -> Iterator[WorkItemOutcome]:
    """Validate each committed part and fail only unresolved original sources.

    Closing after an interrupt propagates GeneratorExit without manufacturing
    failed results for unowned work. Already yielded outcomes remain committed.
    """
    completed_ids: set[str] = set()
    owned_ids = {source.task_id for source in cohort}
    iterator = None
    try:
        outcomes = process_cohort(cohort, runtime, transport) if process_cohort is not None and cohort[0].payload_type is PayloadType.TEST else (
            WorkItemOutcome((process_file(cohort[0], runtime, transport),)),
        )
        iterator = iter(outcomes)
        for outcome in iterator:
            ids = [result.task_id for result in outcome.results]
            if len(ids) != len(set(ids)) or completed_ids.intersection(ids) or set(ids).difference(owned_ids):
                raise WorkerPoolError("work item returned duplicate or foreign source results")
            if any(not request.source_ids or set(request.source_ids).difference(owned_ids) for request in outcome.requests):
                raise WorkerPoolError("request refers to a source outside its owning work item")
            completed_ids.update(ids)
            yield outcome
        if completed_ids != owned_ids:
            raise WorkerPoolError("work item did not return every owned source result")
    except Exception as exc:
        yield WorkItemOutcome(tuple(FileResult(
            task_id=source.task_id, source_path=source.display_path,
            payload_type=source.payload_type, status=FileStatus.FAILED,
            failure_code="unhandled_worker_exception", failure_message=type(exc).__name__)
            for source in cohort if source.task_id not in completed_ids))
    finally:
        close = getattr(iterator, "close", None)
        if close is not None:
            close()


def _collect_run(
    planned_tasks: tuple[FileTask, ...],
    result_queue: Queue[FileResult],
    request_queue: Queue[RequestOutcome],
    *,
    worker_count: int,
    peak_active_workers: int,
    require_complete: bool,
) -> WorkerPoolRun:
    """Drain terminal results and restore deterministic intake order."""
    completed_results: list[FileResult] = []
    while True:
        try:
            completed_results.append(result_queue.get_nowait())
        except Empty:
            break
    results_by_id = {result.task_id: result for result in completed_results}
    if len(results_by_id) != len(completed_results):
        raise WorkerPoolError("worker pool returned duplicate task results")
    planned_ids = {task.task_id for task in planned_tasks}
    if any(task_id not in planned_ids for task_id in results_by_id):
        raise WorkerPoolError("worker pool returned a result for an unknown task")
    if len(results_by_id) != len(planned_tasks):
        if require_complete:
            raise WorkerPoolError("worker pool did not return exactly one result per task")
    requests: dict[str, RequestOutcome] = {}
    while not request_queue.empty():
        request = request_queue.get_nowait()
        if request.request_id in requests:
            raise WorkerPoolError("worker pool returned duplicate request outcomes")
        requests[request.request_id] = request
    for result in completed_results:
        if any(request_id not in requests or result.task_id not in requests[request_id].source_ids for request_id in result.request_ids):
            raise WorkerPoolError("source result refers to an unknown or unrelated request")
    return WorkerPoolRun(
        results=tuple(
            results_by_id[task.task_id]
            for task in planned_tasks
            if task.task_id in results_by_id
        ),
        worker_threads=worker_count,
        peak_active_workers=peak_active_workers,
        requests=tuple(requests[key] for key in sorted(requests)),
    )
