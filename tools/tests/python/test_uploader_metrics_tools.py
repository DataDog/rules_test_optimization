#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Check phase timing without wall-clock waits or network traffic."""

import unittest

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.metrics import PhaseRecorder, execution_environment


class PhaseRecorderTests(unittest.TestCase):
    def test_wall_and_cpu_accumulate_independently_on_success_and_failure(self) -> None:
        wall = iter((0.0, 4.0, 10.0, 15.0))
        cpu = iter((0.0, 1.0, 2.0, 4.0))
        recorder = PhaseRecorder(lambda: next(wall), lambda: next(cpu))
        with recorder.phase("http"):
            pass
        with self.assertRaises(ValueError), recorder.phase("http"):
            raise ValueError("request failed")
        self.assertEqual((("http", 9.0, 3.0),), recorder.snapshot())

    def test_recorders_do_not_share_worker_state(self) -> None:
        wall = iter((3.0, 5.0))
        cpu = iter((7.0, 8.0))
        first = PhaseRecorder(lambda: next(wall), lambda: next(cpu))
        second = PhaseRecorder()
        with first.phase("validation"):
            pass
        self.assertEqual((("validation", 2.0, 1.0),), first.snapshot())
        self.assertEqual((), second.snapshot())

    def test_unavailable_resource_observations_remain_unknown(self) -> None:
        from unittest import mock

        with mock.patch("pathlib.Path.read_text", side_effect=PermissionError), \
             mock.patch("os.cpu_count", return_value=None), \
             mock.patch("os.sched_getaffinity", side_effect=OSError, create=True):
            environment = execution_environment()
        self.assertIsNone(environment["host_logical_cpus"])
        self.assertIsNone(environment["affinity_cpus"])
        self.assertIsNone(environment["cgroup_v2_mount_cpu_max"])
        self.assertIsNone(environment["cgroup_v2_mount_cpu_stat"])
        self.assertIsNone(environment["effective_cpu_quota"])
        self.assertTrue(environment["python_version"])

    def test_mount_root_observations_are_not_claimed_as_effective_quota(self) -> None:
        from unittest import mock

        with mock.patch("pathlib.Path.read_text", side_effect=("200000 100000\n", "nr_throttled 7\n")):
            environment = execution_environment()
        self.assertEqual("200000 100000", environment["cgroup_v2_mount_cpu_max"])
        self.assertEqual("nr_throttled 7", environment["cgroup_v2_mount_cpu_stat"])
        self.assertIsNone(environment["effective_cpu_quota"])


    def test_human_report_includes_phase_and_process_cpu_without_json_file(self) -> None:
        from dataclasses import replace
        from uploader_py.models import FileResult, FileStatus, PayloadType
        from uploader_py.reporting import AggregateReport

        report = AggregateReport.create(dry_run=True, exit_code=0, configured_workers=1,
            worker_threads=1, peak_active_workers=1, elapsed_seconds=5,
            discovered_by_type={PayloadType.TEST: 1}, results=(FileResult(
                "task", "events.json", PayloadType.TEST, FileStatus.SUCCEEDED,
                phase_times=(("encoding_split", 4.0, 2.0),)),))
        report = replace(report, invocation_phase_times=(("freshness", 1.0, 0.25),),
                         process_cpu_seconds=(2.5, 0.5))
        lines = "\n".join(report.human_lines())
        self.assertIn("worker phase encoding_split: sum_wall=4.000s sum_thread_cpu=2.000s", lines)
        self.assertIn("invocation phase freshness: wall=1.000s main_thread_cpu=0.250s", lines)
        self.assertIn("process CPU: user=2.500s system=0.500s", lines)
        self.assertIn("sums overlap", lines)


class ProgressTests(unittest.TestCase):
    def test_progress_uses_aggregate_counts_and_stops_without_sleep(self) -> None:
        from io import StringIO
        from unittest import mock
        from uploader_py.logging_utils import configure_logging
        from uploader_py.worker_pool import _report_progress

        output = StringIO()
        stop = mock.Mock()
        stop.wait.side_effect = (False, False, True)
        clock = iter((0.0, 5.0, 10.0))
        snapshots = iter(((10, 2, 12), (20, 1, 25)))
        _report_progress(stop, configure_logging(debug=False, stream=output),
                         lambda: next(snapshots), 100, lambda: next(clock))
        lines = output.getvalue().splitlines()
        self.assertEqual(2, len(lines))
        self.assertIn("completed=10/100 active=2 requests_attempted=12 files_per_sec=2.00", lines[0])
        self.assertIn("completed=20/100 active=1 requests_attempted=25 files_per_sec=2.00", lines[1])
        self.assertNotIn("payload", output.getvalue())

    def test_reporter_is_started_and_joined_on_pool_exit(self) -> None:
        from io import StringIO
        import threading
        from unittest import mock
        from uploader_py.logging_utils import configure_logging
        from uploader_py.models import FileResult, FileStatus
        from uploader_py.worker_pool import run_file_workers
        from test_uploader_worker_pool_tools import _tasks

        original_thread = threading.Thread
        created = []

        def create(*args, **kwargs):
            thread = original_thread(*args, **kwargs)
            created.append(thread)
            return thread

        def process(task, _runtime, _transport):
            return FileResult(task.task_id, task.display_path, task.payload_type, FileStatus.SUCCEEDED)

        with mock.patch("uploader_py.worker_pool.threading.Thread", side_effect=create):
            result = run_file_workers(_tasks(3), workers=2, runtime=object(),
                transport_factory=object, process_file=process,
                logger=configure_logging(debug=False, stream=StringIO()))
        self.assertEqual(3, len(result.results))
        reporters = [thread for thread in created if thread.name == "topt-upload-progress"]
        self.assertEqual(1, len(reporters))
        self.assertTrue(all(not thread.is_alive() for thread in created))


    def test_interrupted_reporter_start_still_cancels_and_joins_it(self) -> None:
        from io import StringIO
        import threading
        from unittest import mock
        from uploader_py.logging_utils import configure_logging
        from uploader_py.worker_pool import WorkerPoolInterrupted, run_file_workers
        from test_uploader_worker_pool_tools import _tasks

        original_thread = threading.Thread
        joined = []

        class StartedThenInterrupted(original_thread):
            def start(self):
                super().start()
                raise KeyboardInterrupt

            def join(self, *args, **kwargs):
                joined.append(self.name)
                return super().join(*args, **kwargs)

        def create(*args, **kwargs):
            cls = StartedThenInterrupted if kwargs.get("name") == "topt-upload-progress" else original_thread
            return cls(*args, **kwargs)

        with mock.patch("uploader_py.worker_pool.threading.Thread", side_effect=create):
            with self.assertRaises(WorkerPoolInterrupted) as interrupted:
                run_file_workers(_tasks(2), workers=1, runtime=object(),
                    transport_factory=object, process_file=lambda *_: self.fail("no worker should start"),
                    logger=configure_logging(debug=False, stream=StringIO()))
        self.assertEqual(["topt-upload-progress"], joined)
        self.assertEqual(2, interrupted.exception.cancelled)


    def test_ident_before_native_startup_completion_waits_before_join(self) -> None:
        from io import StringIO
        import inspect
        import threading
        from unittest import mock
        from uploader_py.logging_utils import configure_logging
        from uploader_py.worker_pool import WorkerPoolInterrupted, run_file_workers
        from test_uploader_worker_pool_tools import _tasks

        original_thread = threading.Thread
        reporter = None

        class IntermediateReporter:
            ident = None
            ready = False
            joined = False

            def __init__(self, target):
                self.entered = inspect.getclosurevars(target).nonlocals["progress_entered"]
                # Simulate native startup completing while cleanup waits for
                # the target-entry handshake (no actual thread or sleep).
                self.entered.wait = self.complete_startup

            def complete_startup(self):
                self.ready = True
                return True

            def start(self):
                self.ident = 1
                raise KeyboardInterrupt

            def join(self):
                if not self.ready:
                    raise RuntimeError("cannot join thread before it is started")
                self.joined = True

        def create(*args, **kwargs):
            nonlocal reporter
            if kwargs.get("name") == "topt-upload-progress":
                reporter = IntermediateReporter(kwargs["target"])
                return reporter
            return original_thread(*args, **kwargs)

        with mock.patch("uploader_py.worker_pool.threading.Thread", side_effect=create):
            with self.assertRaises(WorkerPoolInterrupted) as interrupted:
                run_file_workers(_tasks(2), workers=1, runtime=object(),
                    transport_factory=object, process_file=lambda *_: self.fail("not queued yet"),
                    logger=configure_logging(debug=False, stream=StringIO()))
        self.assertEqual(2, interrupted.exception.cancelled)
        self.assertTrue(reporter.joined)

    def test_reporter_resource_failure_does_not_prevent_uploads(self) -> None:
        from io import StringIO
        import threading
        from unittest import mock
        from uploader_py.logging_utils import configure_logging
        from uploader_py.models import FileResult, FileStatus
        from uploader_py.worker_pool import run_file_workers
        from test_uploader_worker_pool_tools import _tasks

        original_thread = threading.Thread
        for construction_fails in (False, True):
            with self.subTest(construction_fails=construction_fails):
                created = []

                class ReporterFailure(original_thread):
                    def start(self):
                        raise RuntimeError("no thread resources")

                def create(*args, **kwargs):
                    if kwargs.get("name") == "topt-upload-progress":
                        self.assertTrue(all(thread.ident is not None for thread in created))
                        if construction_fails:
                            raise RuntimeError("no thread resources")
                        return ReporterFailure(*args, **kwargs)
                    thread = original_thread(*args, **kwargs)
                    created.append(thread)
                    return thread

                def process(task, _runtime, _transport):
                    return FileResult(task.task_id, task.display_path, task.payload_type, FileStatus.SUCCEEDED)

                with mock.patch("uploader_py.worker_pool.threading.Thread", side_effect=create):
                    result = run_file_workers(_tasks(3), workers=2, runtime=object(),
                        transport_factory=object, process_file=process,
                        logger=configure_logging(debug=False, stream=StringIO()))
                self.assertEqual(3, len(result.results))
                self.assertTrue(all(not thread.is_alive() for thread in created))


if __name__ == "__main__":
    unittest.main()
