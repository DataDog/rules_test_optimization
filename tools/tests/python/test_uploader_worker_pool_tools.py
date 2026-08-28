#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Concurrency-contract tests for the bounded per-file worker pool."""

from __future__ import annotations

import os
from pathlib import Path
import sys
import threading
import time
import unittest
from queue import Queue
from unittest import mock


def _runfile(rel_path: str) -> Path:
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    candidates: list[Path] = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace_dir:
        candidates.append(Path(workspace_dir) / rel_path)
    for parent in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        if (parent / "MODULE.bazel").exists() or (parent / ".git").exists():
            candidates.append(parent / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate
    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).is_file():
        keys = {rel_path, f"{test_workspace}/{rel_path}"}
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            for line in handle:
                key, separator, value = line.rstrip("\n").partition(" ")
                if separator and key in keys:
                    return Path(value)
    raise FileNotFoundError(f"runfile not found: {rel_path}")


CORE_DIR = _runfile("tools/core/uploader_main.py").parent
if str(CORE_DIR) not in sys.path:
    sys.path.insert(0, str(CORE_DIR))

from uploader_py.models import FileResult, FileStatus, FileTask, PayloadType  # noqa: E402
from uploader_py.worker_pool import (  # noqa: E402
    WorkerPoolError,
    WorkerPoolInterrupted,
    run_file_workers,
    run_file_workers_with_stats,
)


def _tasks(count: int) -> tuple[FileTask, ...]:
    return tuple(
        FileTask(
            task_id=f"{index:04d}",
            source_path=Path(f"payload-{index}.json"),
            display_path=f"payload-{index}.json",
            payload_type=PayloadType.TEST,
        )
        for index in range(count)
    )


class WorkerPoolTests(unittest.TestCase):
    def test_keyboard_interrupt_drains_unowned_tasks_and_joins_workers(self) -> None:
        tasks = _tasks(8)
        processed: list[str] = []
        processed_lock = threading.Lock()

        def processor(task, _runtime, _transport):
            with processed_lock:
                processed.append(task.task_id)
            time.sleep(0.03)
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        original_join = Queue.join
        join_calls = 0

        def interrupt_first_join(queue):
            nonlocal join_calls
            join_calls += 1
            if join_calls == 1:
                raise KeyboardInterrupt
            return original_join(queue)

        with mock.patch.object(Queue, "join", interrupt_first_join):
            with self.assertRaises(WorkerPoolInterrupted) as raised:
                run_file_workers(
                    tasks,
                    workers=2,
                    runtime=object(),
                    transport_factory=object,
                    process_file=processor,
                )

        interrupt = raised.exception
        self.assertGreaterEqual(len(processed), 1)
        self.assertLess(len(processed), len(tasks))
        self.assertEqual(len(processed), len(interrupt.run.results))
        self.assertEqual(len(tasks), len(interrupt.run.results) + interrupt.cancelled)
        self.assertEqual(
            sorted(processed),
            sorted(result.task_id for result in interrupt.run.results),
        )
        self.assertFalse(
            any(
                thread.name.startswith("dd-uploader-worker-")
                for thread in threading.enumerate()
            )
        )

    def test_keyboard_interrupt_after_queue_completion_does_not_add_work(self) -> None:
        tasks = _tasks(2)

        def processor(task, _runtime, _transport):
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        original_join = Queue.join
        join_calls = 0

        def interrupt_after_first_completion(queue):
            nonlocal join_calls
            join_calls += 1
            original_join(queue)
            if join_calls == 1:
                raise KeyboardInterrupt

        with mock.patch.object(Queue, "join", interrupt_after_first_completion):
            with self.assertRaises(WorkerPoolInterrupted) as raised:
                run_file_workers(
                    tasks,
                    workers=2,
                    runtime=object(),
                    transport_factory=object,
                    process_file=processor,
                )

        self.assertEqual(2, join_calls)
        self.assertEqual(len(tasks), len(raised.exception.run.results))
        self.assertEqual(0, raised.exception.cancelled)
        self.assertFalse(
            any(
                thread.name.startswith("dd-uploader-worker-")
                for thread in threading.enumerate()
            )
        )

    def test_keyboard_interrupt_during_thread_start_joins_started_workers(self) -> None:
        tasks = _tasks(4)
        original_start = threading.Thread.start
        start_calls = 0

        def interrupt_second_start(thread):
            nonlocal start_calls
            start_calls += 1
            if start_calls == 2:
                raise KeyboardInterrupt
            return original_start(thread)

        with mock.patch.object(threading.Thread, "start", interrupt_second_start):
            with self.assertRaises(WorkerPoolInterrupted) as raised:
                run_file_workers(
                    tasks,
                    workers=2,
                    runtime=object(),
                    transport_factory=object,
                    process_file=lambda *_args: self.fail(
                        "no task should be owned during interrupted startup"
                    ),
                )

        self.assertEqual(1, raised.exception.run.worker_threads)
        self.assertEqual(0, len(raised.exception.run.results))
        self.assertEqual(len(tasks), raised.exception.cancelled)
        self.assertFalse(
            any(
                thread.name.startswith("dd-uploader-worker-")
                for thread in threading.enumerate()
            )
        )

    def test_each_file_runs_its_complete_pipeline_on_one_worker(self) -> None:
        tasks = _tasks(8)
        steps: dict[str, list[tuple[str, int]]] = {task.task_id: [] for task in tasks}
        state_lock = threading.Lock()
        active = 0
        maximum_active = 0

        def processor(task, _runtime, _transport):
            nonlocal active, maximum_active
            thread_id = threading.get_ident()
            with state_lock:
                active += 1
                maximum_active = max(maximum_active, active)
            for step in ("enrich", "validate", "split", "send-1", "send-2"):
                steps[task.task_id].append((step, thread_id))
                time.sleep(0.002)
            with state_lock:
                active -= 1
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
                chunks_created=2,
                chunks_uploaded=2,
            )

        results = run_file_workers(
            tasks,
            workers=3,
            runtime=object(),
            transport_factory=object,
            process_file=processor,
        )

        self.assertEqual([task.task_id for task in tasks], [result.task_id for result in results])
        self.assertEqual(3, maximum_active)
        for task in tasks:
            task_steps = steps[task.task_id]
            self.assertEqual(
                ["enrich", "validate", "split", "send-1", "send-2"],
                [step for step, _thread in task_steps],
            )
            self.assertEqual(1, len({thread for _step, thread in task_steps}))

    def test_each_thread_owns_and_reuses_exactly_one_transport(self) -> None:
        tasks = _tasks(12)
        created: list[object] = []
        uses: list[tuple[int, int]] = []
        state_lock = threading.Lock()
        first_wave = threading.Barrier(4)

        def transport_factory():
            transport = object()
            created.append(transport)
            return transport

        def processor(task, _runtime, transport):
            if int(task.task_id) < 4:
                first_wave.wait(timeout=2)
            with state_lock:
                uses.append((threading.get_ident(), id(transport)))
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        run_file_workers(
            tasks,
            workers=4,
            runtime=object(),
            transport_factory=transport_factory,
            process_file=processor,
        )
        self.assertEqual(4, len(created))
        transport_by_thread: dict[int, set[int]] = {}
        for thread_id, transport_id in uses:
            transport_by_thread.setdefault(thread_id, set()).add(transport_id)
        self.assertTrue(
            all(
                len(transport_ids) == 1
                for transport_ids in transport_by_thread.values()
            )
        )
        self.assertEqual({id(transport) for transport in created}, {item[1] for item in uses})

    def test_one_file_exception_does_not_cancel_other_files(self) -> None:
        tasks = _tasks(5)

        def processor(task, _runtime, _transport):
            if task.task_id == "0002":
                raise RuntimeError("secret details must not enter the result")
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        results = run_file_workers(
            tasks,
            workers=3,
            runtime=object(),
            transport_factory=object,
            process_file=processor,
        )
        self.assertEqual(4, sum(result.status is FileStatus.SUCCEEDED for result in results))
        failure = results[2]
        self.assertEqual(FileStatus.FAILED, failure.status)
        self.assertEqual("unhandled_worker_exception", failure.failure_code)
        self.assertEqual("RuntimeError", failure.failure_message)

    def test_empty_intake_creates_no_transports(self) -> None:
        calls = 0

        def transport_factory():
            nonlocal calls
            calls += 1
            return object()

        results = run_file_workers(
            (),
            workers=4,
            runtime=object(),
            transport_factory=transport_factory,
            process_file=lambda *_args: self.fail("processor should not run"),
        )
        self.assertEqual((), results)
        self.assertEqual(0, calls)

    def test_workers_one_is_the_sequential_baseline(self) -> None:
        tasks = _tasks(6)
        observed: list[tuple[str, int]] = []

        def processor(task, _runtime, _transport):
            observed.append((task.task_id, threading.get_ident()))
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        results = run_file_workers(
            tasks,
            workers=1,
            runtime=object(),
            transport_factory=object,
            process_file=processor,
        )
        self.assertEqual([task.task_id for task in tasks], [item[0] for item in observed])
        self.assertEqual(1, len({item[1] for item in observed}))
        self.assertEqual([task.task_id for task in tasks], [result.task_id for result in results])

    def test_pool_reports_peak_activity_from_coordinator_state(self) -> None:
        barrier = threading.Barrier(3)

        def processor(task, _runtime, _transport):
            barrier.wait(timeout=2)
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

        run = run_file_workers_with_stats(
            _tasks(6),
            workers=3,
            runtime=object(),
            transport_factory=object,
            process_file=processor,
        )

        self.assertEqual(6, len(run.results))
        self.assertEqual(3, run.worker_threads)
        self.assertEqual(3, run.peak_active_workers)

    def test_invalid_worker_setup_fails_before_threads_start(self) -> None:
        with self.assertRaisesRegex(WorkerPoolError, "positive"):
            run_file_workers(
                _tasks(1),
                workers=0,
                runtime=object(),
                transport_factory=object,
                process_file=lambda *_args: self.fail("processor should not run"),
            )
        duplicate = (_tasks(1)[0], _tasks(1)[0])
        with self.assertRaisesRegex(WorkerPoolError, "unique"):
            run_file_workers(
                duplicate,
                workers=2,
                runtime=object(),
                transport_factory=object,
                process_file=lambda *_args: self.fail("processor should not run"),
            )


if __name__ == "__main__":
    unittest.main()
