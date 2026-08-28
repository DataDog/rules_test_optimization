# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Bounded file-worker execution with no cross-file worker coordination."""

from __future__ import annotations

from dataclasses import dataclass
import logging
from queue import Empty, Queue
import threading
import time
from typing import Callable, Iterable, Protocol, TypeVar

from .models import FileResult, FileStatus, FileTask


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
) -> tuple[FileResult, ...]:
    """Process each source exactly once through one complete worker pipeline.

    Results are returned in intake order for deterministic reports. Workers do
    not mutate aggregate counters or wait for results from other source files.
    """
    return run_file_workers_with_stats(
        tasks,
        workers=workers,
        runtime=runtime,
        transport_factory=transport_factory,
        process_file=process_file,
        logger=logger,
    ).results


def run_file_workers_with_stats(
    tasks: Iterable[FileTask],
    *,
    workers: int,
    runtime: RuntimeType,
    transport_factory: Callable[[], TransportType],
    process_file: FileProcessor[RuntimeType, TransportType],
    logger: logging.Logger | None = None,
) -> WorkerPoolRun:
    """Run the bounded pool and return metrics never mutated by file workers."""
    if workers <= 0:
        raise WorkerPoolError("workers must be positive")
    planned_tasks = tuple(tasks)
    task_ids = [task.task_id for task in planned_tasks]
    if len(task_ids) != len(set(task_ids)):
        raise WorkerPoolError("file task IDs must be unique")
    if not planned_tasks:
        return WorkerPoolRun((), 0, 0)

    worker_count = min(workers, len(planned_tasks))
    try:
        transports = tuple(transport_factory() for _ in range(worker_count))
    except Exception as exc:
        raise WorkerPoolError(
            f"failed to initialize worker transport: {type(exc).__name__}"
        ) from exc

    sentinel = object()
    task_queue: Queue[FileTask | object] = Queue(maxsize=max(1, worker_count * 2))
    result_queue: Queue[FileResult] = Queue()
    activity_lock = threading.Lock()
    shutdown_event = threading.Event()
    active_workers = 0
    peak_active_workers = 0

    def worker_loop(transport: TransportType) -> None:
        nonlocal active_workers, peak_active_workers
        if logger is not None:
            logger.debug("worker=%s started", threading.current_thread().name)
        while True:
            try:
                item = task_queue.get(timeout=0.1)
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
                if item is sentinel:
                    if logger is not None:
                        logger.debug("worker=%s stopped", threading.current_thread().name)
                    return
                task = item
                if shutdown_event.is_set():
                    if logger is not None:
                        logger.debug(
                            "task=%s type=%s file=%s cancelled before worker ownership",
                            task.task_id,
                            task.payload_type.value,
                            task.display_path,
                        )
                    continue
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
                    try:
                        result = process_file(task, runtime, transport)
                        if result.task_id != task.task_id:
                            raise WorkerPoolError(
                                "file processor returned a result for a different task"
                            )
                    except Exception as exc:
                        result = FileResult(
                            task_id=task.task_id,
                            source_path=task.display_path,
                            payload_type=task.payload_type,
                            status=FileStatus.FAILED,
                            failure_code="unhandled_worker_exception",
                            failure_message=type(exc).__name__,
                        )
                finally:
                    with activity_lock:
                        active_workers -= 1
                result_queue.put(result)
                if logger is not None:
                    logger.debug(
                        "task=%s type=%s file=%s worker=%s completed status=%s "
                        "elapsed=%.3fs",
                        task.task_id,
                        task.payload_type.value,
                        task.display_path,
                        threading.current_thread().name,
                        result.status.value,
                        max(0.0, time.monotonic() - task_started),
                    )
            finally:
                task_queue.task_done()

    threads = tuple(
        threading.Thread(
            target=worker_loop,
            args=(transport,),
            name=f"dd-uploader-worker-{index + 1}",
            daemon=False,
        )
        for index, transport in enumerate(transports)
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

    try:
        for thread in threads:
            thread.start()
            started_threads.append(thread)
        for task in planned_tasks:
            task_queue.put(task)
            if logger is not None:
                logger.debug(
                    "task=%s type=%s file=%s enqueued",
                    task.task_id,
                    task.payload_type.value,
                    task.display_path,
                )
        for _ in started_threads:
            task_queue.put(sentinel)
        task_queue.join()
        for thread in started_threads:
            thread.join()
    except KeyboardInterrupt:
        if logger is not None:
            logger.warning("interrupt received; draining unowned file tasks")
        # Stop scheduling queued files, but let already-owned files finish
        # their current pipeline. Their normal cleanup contract still applies;
        # every not-yet-owned source remains untouched. Workers observe the
        # shutdown event after finishing owned work, so no new sentinels are
        # added here: some or all normal sentinels may already have been
        # consumed when the interrupt arrives.
        stop_started_workers()
        interrupted_run = _collect_run(
            planned_tasks,
            result_queue,
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

    return _collect_run(
        planned_tasks,
        result_queue,
        worker_count=worker_count,
        peak_active_workers=peak_active_workers,
        require_complete=True,
    )


def _collect_run(
    planned_tasks: tuple[FileTask, ...],
    result_queue: Queue[FileResult],
    *,
    worker_count: int,
    peak_active_workers: int,
    require_complete: bool,
) -> WorkerPoolRun:
    """Drain terminal results and restore deterministic intake order."""
    completed: list[FileResult] = []
    while True:
        try:
            completed.append(result_queue.get_nowait())
        except Empty:
            break
    results_by_id = {result.task_id: result for result in completed}
    if len(results_by_id) != len(completed):
        raise WorkerPoolError("worker pool returned duplicate task results")
    planned_ids = {task.task_id for task in planned_tasks}
    if any(task_id not in planned_ids for task_id in results_by_id):
        raise WorkerPoolError("worker pool returned a result for an unknown task")
    if len(results_by_id) != len(planned_tasks):
        if require_complete:
            raise WorkerPoolError("worker pool did not return exactly one result per task")
    return WorkerPoolRun(
        results=tuple(
            results_by_id[task.task_id]
            for task in planned_tasks
            if task.task_id in results_by_id
        ),
        worker_threads=worker_count,
        peak_active_workers=peak_active_workers,
    )
