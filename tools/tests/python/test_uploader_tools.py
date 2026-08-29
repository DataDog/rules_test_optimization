#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Focused tests for the Python parallel uploader foundation."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import FrozenInstanceError
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
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

    here = Path(__file__).resolve().parent
    for candidate in (here, *here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            candidates.append(candidate / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate

    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).exists():
        keys = {rel_path}
        if test_workspace:
            keys.add(f"{test_workspace}/{rel_path}")
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            for line in handle:
                key, separator, value = line.rstrip("\n").partition(" ")
                if separator and key in keys and value:
                    return Path(value)
    raise FileNotFoundError(f"runfile not found: {rel_path}")


CORE_DIR = _runfile("tools/core/uploader_main.py").parent
if str(CORE_DIR) not in sys.path:
    sys.path.insert(0, str(CORE_DIR))

from uploader_py.config import (  # noqa: E402
    ConfigError,
    DEFAULT_EXPECTED_ENRICHED_TAGS,
    load_rule_config,
    parse_uploader_config,
    validate_upload_credentials,
)
from uploader_py.main import (  # noqa: E402
    main as uploader_main,
    python_version_is_supported,
)
from uploader_py.endpoints import build_endpoints, normalize_dd_site  # noqa: E402
from uploader_py.logging_utils import (  # noqa: E402
    configure_logging,
    redact_header_value,
    redact_url,
)
from uploader_py.locking import (  # noqa: E402
    WorkspaceLock,
    WorkspaceLockError,
    workspace_lock_name,
)
from uploader_py.json_utils import strict_json_dumps, strict_json_loads  # noqa: E402
from uploader_py.models import (  # noqa: E402
    DEFAULT_WORKERS,
    MAX_TEST_PAYLOAD_BYTES,
    FileStatus,
    FileTask,
    PayloadType,
)
from uploader_py.splitting import (  # noqa: E402
    TestPayloadSplitError,
    compact_json_bytes,
    prepare_test_chunks,
)
from uploader_py.temporary import (  # noqa: E402
    TemporaryDirectoryError,
    invocation_temporary_directory,
    task_temporary_directory,
)
from topt_runtime.runfiles import (  # noqa: E402
    RunfileResolutionError,
    RunfilesResolver,
    runfile_candidates,
)
from validate_payload_schema import validate_payload  # noqa: E402


LEGACY_CLI_FLAGS = {
    "--allow-cached-payload-uploads",
    "--artifact-source",
    "--artifact-staging-dir",
    "--bep-artifact-downloader",
    "--bep-artifact-downloader-timeout-sec",
    "--bep-json",
    "--dry-run",
    "--execution-log-json",
    "--execution-log-mode",
    "--expected-enriched-tag",
    "--freshness-mode",
    "--freshness-source",
    "--remote-artifacts",
    "--report-json",
    "--validate-enrichment",
}
NEW_CLI_FLAGS = {"--debug", "--workers"}
LEGACY_RUNTIME_ENVIRONMENT = {
    "DD_TEST_OPTIMIZATION_AGENT_URL",
    "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
    "DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE",
    "DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR",
    "DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER",
    "DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC",
    "DD_TEST_OPTIMIZATION_BEP_JSON",
    "DD_TEST_OPTIMIZATION_CODEOWNERS_FILE",
    "DD_TEST_OPTIMIZATION_CONTEXT_JSON",
    "DD_TEST_OPTIMIZATION_DEBUG",
    "DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON",
    "DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE",
    "DD_TEST_OPTIMIZATION_FILTER_PREFIX",
    "DD_TEST_OPTIMIZATION_FRESHNESS_MODE",
    "DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE",
    "DD_TEST_OPTIMIZATION_GZIP",
    "DD_TEST_OPTIMIZATION_KEEP_PAYLOADS",
    "DD_TEST_OPTIMIZATION_MAX_DEPTH",
    "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC",
    "DD_TEST_OPTIMIZATION_QUIESCENT_SEC",
    "DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS",
    "DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON",
}
RULE_ATTRIBUTES = {
    "quiescent_sec",
    "max_wait_sec",
    "fail_on_error",
    "debug",
    "keep_payloads",
    "filter_prefix",
    "gzip_payloads",
    "workers",
    "use_python_uploader",
    "data",
    "expected_targets",
    "expected_targets_file",
}


class UploaderConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.config_path = self.root / "uploader.config.json"
        self.write_config()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_config(self, **overrides: object) -> None:
        body: dict[str, object] = {
            "schema_version": 1,
            "quiescent_sec": 10,
            "max_wait_sec": 300,
            "fail_on_error": False,
            "debug": False,
            "keep_payloads": False,
            "filter_prefix": False,
            "gzip_payloads": False,
            "workers": 4,
            "expected_targets": ["//pkg:test"],
        }
        body.update(overrides)
        self.config_path.write_text(json.dumps(body), encoding="utf-8")

    def parse(self, *arguments: str, environ: dict[str, str] | None = None):
        return parse_uploader_config(
            ["--config", str(self.config_path), "--dry-run", *arguments],
            environ={} if environ is None else environ,
            cwd=self.root,
        )

    def test_rule_config_defaults_and_fixed_contracts(self) -> None:
        rule = load_rule_config(self.config_path)
        self.assertEqual(DEFAULT_WORKERS, rule.workers)
        self.assertEqual(("//pkg:test",), rule.expected_targets)
        self.assertEqual(4_718_592, MAX_TEST_PAYLOAD_BYTES)

    def test_rule_config_is_strictly_typed(self) -> None:
        invalid_values = {
            "schema_version": 2,
            "quiescent_sec": -1,
            "max_wait_sec": "300",
            "fail_on_error": 1,
            "workers": 0,
            "expected_targets": "//pkg:test",
        }
        for name, value in invalid_values.items():
            with self.subTest(name=name), self.assertRaises(ConfigError):
                self.write_config(**{name: value})
                load_rule_config(self.config_path)

    def test_non_finite_numbers_are_rejected_as_non_standard_json(self) -> None:
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant):
                with self.assertRaises(json.JSONDecodeError):
                    strict_json_loads(f'{{"value":{constant}}}')
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                strict_json_dumps({"value": value})

        self.config_path.write_text(
            '{"schema_version":1,"workers":NaN}',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ConfigError, "invalid uploader config JSON"):
            load_rule_config(self.config_path)

    def test_cli_environment_and_rule_precedence(self) -> None:
        self.write_config(debug=True, workers=2)
        config = self.parse(
            "--debug",
            "--workers=7",
            environ={
                "DD_TEST_OPTIMIZATION_DEBUG": "false",
                "DD_TEST_OPTIMIZATION_WORKERS": "6",
            },
        )
        self.assertTrue(config.debug)
        self.assertEqual(7, config.workers)

        config = self.parse(
            environ={
                "DD_TEST_OPTIMIZATION_DEBUG": "false",
                "DD_TEST_OPTIMIZATION_WORKERS": "6",
            }
        )
        self.assertFalse(config.debug)
        self.assertEqual(6, config.workers)

        config = self.parse()
        self.assertTrue(config.debug)
        self.assertEqual(2, config.workers)

    def test_workspace_lock_scope_preserves_legacy_unresolved_path(self) -> None:
        actual_workspace = self.root / "actual-workspace"
        actual_workspace.mkdir()
        workspace_link = self.root / "workspace-link"
        try:
            workspace_link.symlink_to(actual_workspace, target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"directory symlinks unavailable: {exc}")

        invocation_cwd = self.root / "invocation-cwd"
        invocation_cwd.mkdir()
        launcher_directory = self.root / "launcher"
        launcher_directory.mkdir()
        config = parse_uploader_config(
            ["--config", str(self.config_path), "--dry-run"],
            environ={
                "BUILD_WORKSPACE_DIRECTORY": str(workspace_link),
                "DD_TEST_OPTIMIZATION_UPLOADER_LAUNCHER_DIR": str(
                    launcher_directory
                ),
            },
            cwd=invocation_cwd,
        )

        self.assertEqual(actual_workspace.resolve(), config.workspace)
        self.assertEqual(str(workspace_link), config.lock_workspace)
        self.assertEqual(invocation_cwd.absolute(), config.invocation_cwd)
        self.assertEqual(launcher_directory, config.launcher_directory)
        self.assertEqual(
            workspace_lock_name(str(workspace_link)),
            workspace_lock_name(config.lock_workspace),
        )
        self.assertNotEqual(
            workspace_lock_name(str(workspace_link)),
            workspace_lock_name(config.workspace),
        )

    def test_legacy_boolean_normalization_is_preserved(self) -> None:
        config = self.parse(
            environ={
                "DD_TEST_OPTIMIZATION_KEEP_PAYLOADS": "YES",
                "DD_TEST_OPTIMIZATION_FILTER_PREFIX": "unexpected",
                "DD_TEST_OPTIMIZATION_GZIP": "1",
            }
        )
        self.assertTrue(config.keep_payloads)
        self.assertFalse(config.filter_prefix)
        self.assertTrue(config.gzip_payloads)

    def test_numeric_controls_and_worker_validation(self) -> None:
        config = self.parse(
            environ={
                "DD_TEST_OPTIMIZATION_QUIESCENT_SEC": "0",
                "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC": "0",
                "DD_TEST_OPTIMIZATION_MAX_DEPTH": "12",
            }
        )
        self.assertEqual(0, config.quiescent_sec)
        self.assertEqual(0, config.max_wait_sec)
        self.assertEqual(12, config.max_depth)

        for arguments, environment in [
            (("--workers=0",), {}),
            (("--workers=-1",), {}),
            ((), {"DD_TEST_OPTIMIZATION_WORKERS": "many"}),
            ((), {"DD_TEST_OPTIMIZATION_MAX_DEPTH": "-1"}),
        ]:
            with self.subTest(arguments=arguments, environment=environment):
                with self.assertRaises(ConfigError):
                    self.parse(*arguments, environ=environment)

    def test_freshness_precedence_and_allow_cached_override(self) -> None:
        config = self.parse(
            "--freshness-mode=required",
            "--execution-log-mode=optional",
            environ={"DD_TEST_OPTIMIZATION_FRESHNESS_MODE": "disabled"},
        )
        self.assertEqual("required", config.freshness_mode)

        config = self.parse(
            "--allow-cached-payload-uploads",
            environ={"DD_TEST_OPTIMIZATION_FRESHNESS_MODE": "required"},
        )
        self.assertEqual("disabled", config.freshness_mode)
        self.assertTrue(config.freshness_disabled_explicitly)

        config = self.parse(
            environ={"DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE": "OPTIONAL"}
        )
        self.assertEqual("optional", config.freshness_mode)

    def test_repeatable_values_and_expected_tag_defaults(self) -> None:
        config = self.parse(
            "--bep-json=cli-one.json",
            "--bep-json",
            "cli-two.json",
            environ={"DD_TEST_OPTIMIZATION_BEP_JSON": "environment.json"},
        )
        self.assertEqual(
            (Path("environment.json"), Path("cli-one.json"), Path("cli-two.json")),
            config.bep_json_files,
        )
        self.assertEqual(DEFAULT_EXPECTED_ENRICHED_TAGS, config.expected_enriched_tags)

        config = self.parse(
            "--expected-enriched-tag=git.commit.sha",
            "--expected-enriched-tag",
            "bazel.target",
        )
        self.assertEqual(("git.commit.sha", "bazel.target"), config.expected_enriched_tags)

    def test_artifact_report_and_environment_paths(self) -> None:
        config = self.parse(
            "--artifact-source=BEP",
            "--remote-artifacts=DOWNLOAD",
            "--artifact-staging-dir=relative staging",
            "--report-json=cli-report.json",
            environ={
                "DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON": "env-report.json",
                "DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON": "execution.json",
                "DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER": "fetch tool",
                "TESTLOGS_DIR": "custom testlogs",
            },
        )
        self.assertEqual("bep", config.artifact_source)
        self.assertEqual("download", config.remote_artifacts)
        self.assertEqual(
            self.root.resolve() / "relative staging",
            config.artifact_staging_dir,
        )
        self.assertEqual(Path("cli-report.json"), config.report_json)
        self.assertEqual(Path("execution.json"), config.execution_log_json)
        self.assertEqual(Path("fetch tool"), config.bep_artifact_downloader)
        self.assertEqual(Path("custom testlogs"), config.testlogs_dir)

    def test_positive_decimal_validation(self) -> None:
        for accepted in (".5", "1", "1.", "+2.25"):
            with self.subTest(accepted=accepted):
                config = self.parse(
                    f"--bep-artifact-downloader-timeout-sec={accepted}"
                )
                self.assertGreater(config.bep_artifact_downloader_timeout_sec, 0)
        for rejected in ("0", "-1", "nan", "1e3", ""):
            with self.subTest(rejected=rejected), self.assertRaises(ConfigError):
                self.parse(f"--bep-artifact-downloader-timeout-sec={rejected}")

    def test_validate_enrichment_requires_dry_run(self) -> None:
        with self.assertRaisesRegex(ConfigError, "requires --dry-run"):
            parse_uploader_config(
                ["--config", str(self.config_path), "--validate-enrichment"],
                environ={},
                cwd=self.root,
            )

    def test_unknown_and_abbreviated_arguments_exit_two(self) -> None:
        for argument in ("--unknown", "--dry"):
            with self.subTest(argument=argument):
                with self.assertRaisesRegex(SystemExit, "2"):
                    with mock.patch("sys.stderr", io.StringIO()):
                        parse_uploader_config(
                            ["--config", str(self.config_path), argument],
                            environ={},
                            cwd=self.root,
                        )

    def test_credentials_are_validated_after_mode_resolution(self) -> None:
        dry_run = self.parse()
        validate_upload_credentials(dry_run)
        self.assertEqual("datadoghq.com", dry_run.site)

        real_upload = parse_uploader_config(
            ["--config", str(self.config_path)], environ={}, cwd=self.root
        )
        with self.assertRaisesRegex(ConfigError, "DD_API_KEY"):
            validate_upload_credentials(real_upload)

        evp = parse_uploader_config(
            ["--config", str(self.config_path)],
            environ={"DD_TEST_OPTIMIZATION_AGENT_URL": "http://localhost:8126"},
            cwd=self.root,
        )
        validate_upload_credentials(evp)

    def test_ci_environment_false_markers_match_legacy_runtime(self) -> None:
        for value in ("", "0", "false", "FALSE", " no "):
            with self.subTest(value=value):
                self.assertFalse(self.parse(environ={"CI": value}).ci)
        for value in ("1", "true", "yes"):
            with self.subTest(value=value):
                self.assertTrue(self.parse(environ={"CI": value}).ci)

    def test_dd_site_normalization_and_endpoint_modes(self) -> None:
        accepted = {
            "": "datadoghq.com",
            "  APP.DatadogHQ.EU  ": "datadoghq.eu",
            "https://api.us5.datadoghq.com/path?query=yes#fragment": (
                "us5.datadoghq.com"
            ),
        }
        for raw, expected in accepted.items():
            with self.subTest(raw=raw):
                self.assertEqual(expected, normalize_dd_site(raw))

        for raw in (
            "https://",
            "user@example.com",
            "example.com:443",
            ".example.com",
            "example..com",
            "bad_name.example",
        ):
            with self.subTest(raw=raw), self.assertRaises(ConfigError):
                normalize_dd_site(raw)

        direct = build_endpoints(
            self.parse(
                environ={
                    "DD_SITE": "app.datadoghq.eu",
                    "DD_TEST_OPTIMIZATION_AGENTLESS_URL": "https://mock.invalid/root/",
                }
            )
        )
        self.assertTrue(direct.agentless)
        self.assertEqual("https://mock.invalid/root/api/v2/citestcycle", direct.test_url)
        self.assertEqual("datadoghq.eu", direct.site)

        evp = build_endpoints(
            self.parse(
                environ={
                    "DD_TEST_OPTIMIZATION_AGENT_URL": "http://localhost:8126",
                    "DD_TEST_OPTIMIZATION_AGENTLESS_URL": "https://ignored.invalid",
                }
            )
        )
        self.assertFalse(evp.agentless)
        self.assertEqual(
            "http://localhost:8126/evp_proxy/v2/api/v2/citestcycle",
            evp.test_url,
        )

    def test_endpoint_configuration_errors_do_not_expose_sensitive_urls(self) -> None:
        marker = "SENSITIVE_URL_MARKER"
        environments = (
            {"DD_SITE": f"https://user:{marker}@example.com"},
            {
                "DD_TEST_OPTIMIZATION_AGENTLESS_URL": (
                    f"https://user:{marker}@example.com"
                ),
            },
            {
                "DD_TEST_OPTIMIZATION_AGENT_URL": (
                    f"https://user:{marker}@example.com"
                ),
            },
            {"DD_TEST_OPTIMIZATION_AGENTLESS_URL": "not-an-absolute-url"},
            {"DD_TEST_OPTIMIZATION_AGENTLESS_URL": "http://localhost:notaport"},
            {"DD_TEST_OPTIMIZATION_AGENTLESS_URL": "http://localhost:65536"},
            {
                "DD_TEST_OPTIMIZATION_AGENTLESS_URL": (
                    "http://localhost/path with space"
                )
            },
            {"DD_TEST_OPTIMIZATION_AGENTLESS_URL": "http://exa%mple.invalid"},
            {"DD_TEST_OPTIMIZATION_AGENT_URL": "http://localhost/%ZZ"},
            {"DD_TEST_OPTIMIZATION_AGENT_URL": "http://localhost:notaport"},
        )
        for environment in environments:
            with self.subTest(environment=tuple(environment)):
                with self.assertRaises(ConfigError) as caught:
                    build_endpoints(self.parse(environ=environment))
                self.assertNotIn(marker, str(caught.exception))

    def test_proxy_environment_is_captured_immutably(self) -> None:
        config = self.parse(
            environ={
                "HTTPS_PROXY": "http://proxy.example",
                "no_proxy": "localhost,127.0.0.1",
            }
        )
        self.assertEqual(
            (
                ("HTTPS_PROXY", "http://proxy.example"),
                ("no_proxy", "localhost,127.0.0.1"),
            ),
            config.proxy_environment,
        )
        with self.assertRaises(FrozenInstanceError):
            config.workers = 99  # type: ignore[misc]

    def test_file_tasks_are_immutable_and_typed(self) -> None:
        task = FileTask(
            task_id="0001",
            source_path=Path("payload.json"),
            display_path="payload.json",
            payload_type=PayloadType.TEST,
        )
        self.assertEqual(PayloadType.TEST, task.payload_type)
        self.assertEqual("succeeded", FileStatus.SUCCEEDED.value)
        with self.assertRaises(FrozenInstanceError):
            task.task_id = "changed"  # type: ignore[misc]


class UploaderTemporaryDirectoryTests(unittest.TestCase):
    def test_cleanup_os_error_is_reported_without_replacing_body_outcome(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            owned_path = Path(raw_root) / "owned"
            owned_path.mkdir()

            class FailedCleanup:
                name = str(owned_path)

                def cleanup(self) -> None:
                    raise PermissionError("simulated cleanup failure")

            errors: list[str] = []
            with mock.patch(
                "uploader_py.temporary.tempfile.TemporaryDirectory",
                return_value=FailedCleanup(),
            ):
                with invocation_temporary_directory(
                    on_cleanup_error=errors.append,
                ) as created:
                    self.assertEqual(owned_path, created)

            self.assertEqual(["PermissionError"], errors)

    def test_invocation_and_task_directories_support_complex_temp_roots(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            temp_root = Path(raw_root) / "temporary path ü"
            temp_root.mkdir()
            with invocation_temporary_directory(temp_root=temp_root) as invocation_root:
                self.assertEqual(temp_root, invocation_root.parent)
                with task_temporary_directory(invocation_root, "task:/ one") as task_root:
                    self.assertTrue(task_root.is_dir())
                    self.assertNotIn(":", task_root.name)
                self.assertFalse(task_root.exists())
            self.assertFalse(invocation_root.exists())

    def test_temporary_root_creation_failure_is_actionable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            not_a_directory = Path(raw_root) / "file"
            not_a_directory.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(
                TemporaryDirectoryError, "failed to create uploader temporary directory"
            ):
                with invocation_temporary_directory(temp_root=not_a_directory):
                    self.fail("temporary directory unexpectedly created")

    def test_task_directory_is_removed_after_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            invocation_root = Path(raw_root)
            task_root: Path | None = None
            with self.assertRaisesRegex(RuntimeError, "simulated"):
                with task_temporary_directory(invocation_root, "failure") as created:
                    task_root = created
                    raise RuntimeError("simulated")
            self.assertIsNotNone(task_root)
            self.assertFalse(task_root.exists())

    def test_task_body_os_error_is_not_misclassified_as_temp_creation(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            with self.assertRaisesRegex(OSError, "source read failed"):
                with task_temporary_directory(Path(raw_root), "source-read"):
                    raise OSError("source read failed")


class UploaderRunfilesTests(unittest.TestCase):
    def test_direct_relative_path_is_resolved_from_snapshotted_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            cwd = Path(raw_root) / "working path ü"
            cwd.mkdir()
            expected = cwd / "direct payload.json"
            expected.write_text("{}", encoding="utf-8")
            resolver = RunfilesResolver.from_environment(environ={}, cwd=cwd)

            self.assertEqual(expected.resolve(), resolver.resolve_file("direct payload.json"))

    def test_runfiles_directory_supports_external_main_and_workspace_layouts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            runfiles = Path(raw_root) / "tool.runfiles"
            external = runfiles / "dependency" / "data" / "context.json"
            main = runfiles / "_main" / "tools" / "schema.json"
            workspace = runfiles / "workspace_name" / "pkg" / "facts.json"
            for path in (external, main, workspace):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}", encoding="utf-8")

            resolver = RunfilesResolver.from_environment(
                environ={
                    "RUNFILES_DIR": str(runfiles),
                    "TEST_WORKSPACE": "workspace_name",
                },
                cwd=Path(raw_root),
            )
            self.assertEqual(
                external.resolve(),
                resolver.resolve_file("external/dependency/data/context.json"),
            )
            self.assertEqual(main.resolve(), resolver.resolve_file("tools/schema.json"))
            self.assertEqual(workspace.resolve(), resolver.resolve_file("pkg/facts.json"))

    def test_launcher_adjacent_runfiles_fallback_is_supported(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            launcher = root / "bin" / "dd_upload_payloads"
            launcher.parent.mkdir()
            runfile = Path(f"{launcher}.runfiles") / "_main" / "tools" / "config.json"
            runfile.parent.mkdir(parents=True)
            runfile.write_text("{}", encoding="utf-8")

            resolver = RunfilesResolver.from_environment(
                argv0=launcher,
                environ={},
                cwd=root,
            )
            self.assertEqual(runfile.resolve(), resolver.resolve_file("tools/config.json"))

    def test_manifest_is_loaded_once_and_preserves_paths_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            exact = root / "actual files" / "context ü.json"
            suffix = root / "actual files" / "telemetry facts.json"
            exact.parent.mkdir()
            exact.write_text("{}", encoding="utf-8")
            suffix.write_text("{}", encoding="utf-8")
            manifest = root / "MANIFEST"
            manifest.write_text(
                "\ufeffworkspace/pkg/context.json "
                f"{exact}\nunknown-prefix/pkg/facts.json {suffix}\n",
                encoding="utf-8",
            )
            environment = {
                "RUNFILES_MANIFEST_FILE": str(manifest),
                "TEST_WORKSPACE": "workspace",
            }
            resolver = RunfilesResolver.from_environment(
                environ=environment,
                cwd=root,
            )

            # The resolver must not consult mutable process/environment state in workers.
            environment.clear()
            manifest.write_text("", encoding="utf-8")
            self.assertEqual(exact.resolve(), resolver.resolve_file("pkg/context.json"))
            self.assertEqual(suffix.resolve(), resolver.resolve_file("pkg/facts.json"))

    def test_manifest_decodes_bazel_escaped_entries(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            expected = root / "actual files" / "context.json"
            expected.parent.mkdir()
            expected.write_text("{}", encoding="utf-8")
            encoded_path = (
                str(expected).replace("\\", r"\b").replace(" ", r"\s")
            )
            manifest = root / "MANIFEST"
            manifest.write_text(
                f" workspace/pkg\\sname/context.json {encoded_path}\n",
                encoding="utf-8",
            )
            resolver = RunfilesResolver.from_environment(
                environ={"RUNFILES_MANIFEST_FILE": str(manifest)},
                cwd=root,
            )

            self.assertEqual(
                expected.resolve(),
                resolver.resolve_file("workspace/pkg name/context.json"),
            )

    def test_short_path_normalization_and_suspicious_labels(self) -> None:
        self.assertEqual(
            (
                "repo/pkg/file.json",
                "external/repo/pkg/file.json",
                "_main/repo/pkg/file.json",
            ),
            runfile_candidates("../../repo/pkg/file.json"),
        )
        for raw in ("pkg/../secret", "/absolute/missing", "C:\\absolute\\missing"):
            with self.subTest(raw=raw), self.assertRaises(RunfileResolutionError):
                runfile_candidates(raw)

    def test_unresolved_file_has_actionable_error(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            resolver = RunfilesResolver.from_environment(environ={}, cwd=Path(raw_root))
            with self.assertRaisesRegex(RunfileResolutionError, "runfile not found"):
                resolver.resolve_file(("missing-one", "missing-two"))

    def test_unreadable_manifest_has_a_controlled_resolution_error(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            manifest = root / "MANIFEST"
            manifest.write_text("workspace/file /actual/file\n", encoding="utf-8")
            with mock.patch(
                "topt_runtime.runfiles.Path.open",
                side_effect=PermissionError("sensitive operating-system detail"),
            ):
                with self.assertRaisesRegex(
                    RunfileResolutionError,
                    "failed to read runfiles manifest.*PermissionError",
                ):
                    RunfilesResolver.from_environment(
                        environ={"RUNFILES_MANIFEST_FILE": str(manifest)},
                        cwd=root,
                    )


class UploaderWorkspaceLockTests(unittest.TestCase):
    def test_lock_name_matches_legacy_workspace_md5_contract(self) -> None:
        with mock.patch(
            "uploader_py.locking.hashlib.md5",
            wraps=hashlib.md5,
        ) as md5:
            self.assertEqual(
                "dd_upload_payloads_56512a07.lock",
                workspace_lock_name("/workspace/example"),
            )
        md5.assert_called_once_with(
            b"/workspace/example",
            usedforsecurity=False,
        )

    def test_same_workspace_contends_and_owner_cleanup_releases(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            first = WorkspaceLock("/workspace/same", temp_root=root, retry_seconds=0)
            second = WorkspaceLock("/workspace/same", temp_root=root, retry_seconds=0)
            with first:
                self.assertTrue(first.acquired)
                if os.name == "nt":
                    self.assertTrue(first.path.is_file())
                else:
                    self.assertTrue(first.path.is_dir())
                    self.assertEqual(
                        str(os.getpid()),
                        (first.path / "pid").read_text().strip(),
                    )
                with self.assertRaisesRegex(WorkspaceLockError, "already running"):
                    second.acquire()
            self.assertFalse(first.acquired)
            self.assertFalse(first.path.exists())

            with second:
                self.assertTrue(second.acquired)

    def test_different_workspaces_can_run_at_the_same_time(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            with WorkspaceLock("/workspace/one", temp_root=root, retry_seconds=0) as first:
                with WorkspaceLock("/workspace/two", temp_root=root, retry_seconds=0) as second:
                    self.assertNotEqual(first.path, second.path)
                    self.assertTrue(first.path.exists())
                    self.assertTrue(second.path.exists())

    @unittest.skipIf(os.name == "nt", "Unix stale-directory behavior")
    def test_dead_pid_lock_is_reclaimed_without_waiting(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            waits: list[float] = []
            lock = WorkspaceLock(
                "/workspace/stale",
                temp_root=Path(raw_root),
                sleeper=waits.append,
                process_alive=lambda _pid: False,
            )
            lock.path.mkdir()
            (lock.path / "pid").write_text("999999\n", encoding="ascii")
            with lock:
                self.assertEqual(str(os.getpid()), (lock.path / "pid").read_text().strip())
            self.assertEqual([], waits)

    @unittest.skipIf(os.name == "nt", "Unix stale-directory behavior")
    def test_fresh_malformed_lock_is_not_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            waits: list[float] = []
            lock = WorkspaceLock(
                "/workspace/incomplete",
                temp_root=Path(raw_root),
                retry_seconds=0.25,
                sleeper=waits.append,
                clock=lambda: 105,
            )
            lock.path.mkdir()
            (lock.path / "pid").write_text("not-a-pid\n", encoding="ascii")
            os.utime(lock.path, (100, 100))

            with self.assertRaisesRegex(WorkspaceLockError, "PID metadata"):
                lock.acquire()
            self.assertTrue(lock.path.exists())
            self.assertEqual([0.25, 0.25], waits)

    @unittest.skipIf(os.name == "nt", "Unix stale-directory behavior")
    def test_old_incomplete_lock_is_reclaimed_but_unexpected_tree_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            old = WorkspaceLock(
                "/workspace/old-incomplete",
                temp_root=root,
                retry_seconds=0,
                clock=lambda: 131,
            )
            old.path.mkdir()
            (old.path / "pid").write_text("broken", encoding="ascii")
            os.utime(old.path, (100, 100))
            with old:
                self.assertTrue(old.acquired)

            unsafe = WorkspaceLock(
                "/workspace/unexpected-tree",
                temp_root=root,
                attempts=2,
                retry_seconds=0,
                process_alive=lambda _pid: False,
            )
            unsafe.path.mkdir()
            (unsafe.path / "pid").write_text("999999", encoding="ascii")
            unexpected = unsafe.path / "do-not-delete"
            unexpected.write_text("preserve", encoding="utf-8")
            with self.assertRaises(WorkspaceLockError):
                unsafe.acquire()
            self.assertEqual("preserve", unexpected.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "Unix stale-directory behavior")
    def test_stale_reclamation_is_serialized_between_python_uploaders(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            first = WorkspaceLock(
                "/workspace/stale-race",
                temp_root=root,
                attempts=2,
                retry_seconds=0,
            )
            second = WorkspaceLock(
                "/workspace/stale-race",
                temp_root=root,
                attempts=2,
                retry_seconds=0,
            )
            first.path.mkdir()
            (first.path / "pid").write_text("999999\n", encoding="ascii")

            start = threading.Barrier(3)
            state_lock = threading.Lock()
            outcomes: list[str] = []
            active_inspections = 0
            peak_inspections = 0
            original_inspect = WorkspaceLock._inspect_unix_lock

            def slow_inspect(lock: WorkspaceLock) -> str:
                nonlocal active_inspections, peak_inspections
                with state_lock:
                    active_inspections += 1
                    peak_inspections = max(peak_inspections, active_inspections)
                try:
                    time.sleep(0.05)
                    return original_inspect(lock)
                finally:
                    with state_lock:
                        active_inspections -= 1

            def contend(lock: WorkspaceLock) -> None:
                start.wait()
                try:
                    lock.acquire()
                except WorkspaceLockError:
                    with state_lock:
                        outcomes.append("contended")
                    return
                with state_lock:
                    outcomes.append("acquired")
                try:
                    time.sleep(0.15)
                finally:
                    lock.release()

            with mock.patch.object(
                WorkspaceLock,
                "_inspect_unix_lock",
                slow_inspect,
            ):
                threads = (
                    threading.Thread(target=contend, args=(first,)),
                    threading.Thread(target=contend, args=(second,)),
                )
                for thread in threads:
                    thread.start()
                start.wait()
                for thread in threads:
                    thread.join(timeout=2)

            self.assertTrue(all(not thread.is_alive() for thread in threads))
            self.assertEqual(1, peak_inspections)
            self.assertEqual(["acquired", "contended"], sorted(outcomes))

    @unittest.skipUnless(os.name == "nt", "Windows byte-lock behavior")
    def test_windows_lock_contention(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            first = WorkspaceLock("C:/workspace", temp_root=root, attempts=1)
            second = WorkspaceLock("C:/workspace", temp_root=root, attempts=1)
            with first:
                with self.assertRaises(WorkspaceLockError):
                    second.acquire()


class UploaderSplittingTests(unittest.TestCase):
    @staticmethod
    def payload_with_exact_size(size_bytes: int) -> dict[str, object]:
        payload: dict[str, object] = {"version": 1, "events": [{"value": ""}]}
        base_size = len(compact_json_bytes(payload))
        if size_bytes < base_size:
            raise ValueError("requested fixture is smaller than its JSON envelope")
        payload["events"] = [{"value": "x" * (size_bytes - base_size)}]
        actual_size = len(compact_json_bytes(payload))
        if actual_size != size_bytes:
            raise AssertionError(f"fixture size mismatch: {actual_size} != {size_bytes}")
        return payload

    def test_boundary_below_and_at_limit_remain_single_requests(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            for size in (MAX_TEST_PAYLOAD_BYTES - 1, MAX_TEST_PAYLOAD_BYTES):
                with self.subTest(size=size):
                    payload = self.payload_with_exact_size(size)
                    chunks = prepare_test_chunks(payload, root)
                    self.assertEqual(1, len(chunks))
                    self.assertEqual(size, chunks[0].size_bytes)
                    self.assertEqual(compact_json_bytes(payload), chunks[0].path.read_bytes())
                    chunks[0].path.unlink()

    def test_one_byte_over_limit_splits_before_http(self) -> None:
        events = [
            {"index": 0, "value": ""},
            {"index": 1, "value": ""},
        ]
        payload = {
            "meta": "kept",
            "events": events,
            "tail": 7,
        }
        base_size = len(compact_json_bytes(payload))
        events[0]["value"] = "a" * (MAX_TEST_PAYLOAD_BYTES + 1 - base_size)
        self.assertEqual(
            MAX_TEST_PAYLOAD_BYTES + 1,
            len(compact_json_bytes(payload)),
        )

        with tempfile.TemporaryDirectory() as raw_root:
            chunks = prepare_test_chunks(payload, Path(raw_root))
            raw_bodies = [chunk.path.read_bytes() for chunk in chunks]
            decoded = [json.loads(body.decode("utf-8")) for body in raw_bodies]
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(chunk.size_bytes <= MAX_TEST_PAYLOAD_BYTES for chunk in chunks))
        self.assertEqual(["meta", "events", "tail"], list(decoded[0]))
        self.assertTrue(all(body["meta"] == "kept" and body["tail"] == 7 for body in decoded))
        self.assertEqual(payload["events"], [event for body in decoded for event in body["events"]])
        for chunk, body in zip(chunks, raw_bodies):
            expected = {
                "meta": "kept",
                "events": payload["events"][chunk.event_start : chunk.event_end],
                "tail": 7,
            }
            self.assertEqual(compact_json_bytes(expected), body)

    def test_unicode_uses_utf8_bytes_not_character_count(self) -> None:
        payload = {"events": [{"value": "€"}, {"value": "plain"}]}
        character_count = len(compact_json_bytes(payload).decode("utf-8"))
        byte_count = len(compact_json_bytes(payload))
        self.assertGreater(byte_count, character_count)
        with tempfile.TemporaryDirectory() as raw_root:
            chunks = prepare_test_chunks(
                payload,
                Path(raw_root),
                limit_bytes=byte_count - 1,
            )
            self.assertEqual(2, len(chunks))
            self.assertTrue(all(chunk.size_bytes <= byte_count - 1 for chunk in chunks))

    def test_single_oversized_event_writes_no_chunk(self) -> None:
        payload = self.payload_with_exact_size(MAX_TEST_PAYLOAD_BYTES + 1)
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            with self.assertRaises(TestPayloadSplitError) as captured:
                prepare_test_chunks(payload, root)
            self.assertEqual("single_event_exceeds_payload_limit", captured.exception.code)
            self.assertEqual([], list(root.iterdir()))

    def test_invalid_or_empty_events_are_rejected(self) -> None:
        invalid_payloads = (
            {},
            {"events": []},
            {"events": "not-an-array"},
            {1: "invalid-key", "events": [{"ok": True}]},
        )
        with tempfile.TemporaryDirectory() as raw_root:
            for payload in invalid_payloads:
                with self.subTest(payload=payload), self.assertRaises(TestPayloadSplitError):
                    prepare_test_chunks(payload, Path(raw_root))

    def test_envelope_larger_than_custom_limit_is_actionable(self) -> None:
        payload = {"large_meta": "x" * 100, "events": [{"ok": True}]}
        with tempfile.TemporaryDirectory() as raw_root:
            with self.assertRaises(TestPayloadSplitError) as captured:
                prepare_test_chunks(payload, Path(raw_root), limit_bytes=20)
        self.assertEqual(
            "test_payload_envelope_exceeds_payload_limit",
            captured.exception.code,
        )


class UploaderSchemaValidationTests(unittest.TestCase):
    def test_importable_validation_returns_structured_result(self) -> None:
        schema = {
            "type": "object",
            "required": ["ok"],
            "properties": {"ok": {"type": "boolean"}},
            "additionalProperties": False,
        }
        valid = validate_payload({"ok": True}, schema)
        invalid = validate_payload({"unexpected": 1}, schema)

        self.assertTrue(valid.valid)
        self.assertEqual((), valid.errors)
        self.assertFalse(invalid.valid)
        self.assertIn("missing required property 'ok'", invalid.errors[0])
        self.assertGreater(valid.stats["nodes"], 0)

    def test_warn_policy_returns_warnings_without_writing_process_stderr(self) -> None:
        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            result = validate_payload(
                "ok",
                {"oneOf": [{"const": "ok"}]},
                unsupported_policy="warn",
            )
        self.assertTrue(result.valid)
        self.assertEqual("", stderr.getvalue())
        self.assertIn("unsupported JSON Schema keyword 'oneOf'", result.warnings[0])

    def test_one_loaded_schema_is_safe_for_parallel_worker_validation(self) -> None:
        schema = {
            "type": "object",
            "required": ["index"],
            "properties": {"index": {"type": "integer", "minimum": 0}},
            "additionalProperties": False,
        }
        payloads = [{"index": index} for index in range(50)] + [{"index": -1}]
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda value: validate_payload(value, schema), payloads))

        self.assertTrue(all(result.valid for result in results[:-1]))
        self.assertFalse(results[-1].valid)
        self.assertTrue(all(result.stats["nodes"] == 2 for result in results))

    def test_importable_validation_rejects_invalid_controls(self) -> None:
        with self.assertRaisesRegex(ValueError, "max_errors"):
            validate_payload({}, {}, max_errors=0)
        with self.assertRaisesRegex(ValueError, "unsupported_policy"):
            validate_payload({}, {}, unsupported_policy="ignore")


class UploaderLoggingTests(unittest.TestCase):
    def test_debug_level_and_known_secret_redaction(self) -> None:
        output = io.StringIO()
        logger = configure_logging(debug=True, secrets=("secret-value",), stream=output)
        logger.debug("request key=%s", "secret-value")
        self.assertIn("DEBUG", output.getvalue())
        self.assertNotIn("secret-value", output.getvalue())
        self.assertIn("<redacted>", output.getvalue())

    def test_normal_mode_suppresses_debug(self) -> None:
        output = io.StringIO()
        logger = configure_logging(debug=False, stream=output)
        logger.debug("hidden")
        logger.info("visible")
        self.assertNotIn("hidden", output.getvalue())
        self.assertIn("visible", output.getvalue())

    def test_headers_and_urls_are_redacted(self) -> None:
        self.assertEqual("<redacted>", redact_header_value("DD-API-KEY", "abcd"))
        self.assertEqual(
            "application/json",
            redact_header_value("Content-Type", "application/json"),
        )
        self.assertEqual(
            "https://example.com:8443/api/v2/citestcycle",
            redact_url(
                "HTTPS://user:password@example.com:8443/api/v2/citestcycle?token=secret#fragment"
            ),
        )
        self.assertEqual("<redacted-invalid-url>", redact_url("not a URL"))


class UploaderContractCharacterizationTests(unittest.TestCase):
    def test_supported_python_minimum_is_explicit(self) -> None:
        self.assertFalse(python_version_is_supported(3, 9))
        self.assertTrue(python_version_is_supported(3, 10))
        self.assertTrue(python_version_is_supported(3, 14))

    def test_legacy_runtimes_expose_the_recorded_cli_surface(self) -> None:
        for relative_path in (
            "tools/core/uploader_bash_runtime.sh.tpl",
            "tools/core/uploader_powershell_runtime.ps1.tpl",
        ):
            text = _runfile(relative_path).read_text(encoding="utf-8")
            with self.subTest(runtime=relative_path):
                for flag in LEGACY_CLI_FLAGS:
                    self.assertIn(flag, text)

    def test_legacy_runtimes_expose_the_recorded_environment_surface(self) -> None:
        for relative_path in (
            "tools/core/uploader_bash_runtime.sh.tpl",
            "tools/core/uploader_powershell_runtime.ps1.tpl",
        ):
            text = _runfile(relative_path).read_text(encoding="utf-8")
            with self.subTest(runtime=relative_path):
                for name in LEGACY_RUNTIME_ENVIRONMENT:
                    self.assertIn(name, text)

    def test_rule_exposes_the_recorded_attribute_surface(self) -> None:
        text = _runfile("tools/core/test_optimization_uploader.bzl").read_text(encoding="utf-8")
        for name in RULE_ATTRIBUTES:
            self.assertIn(f'"{name}": attr.', text)

    def test_python_parser_contains_legacy_and_new_options(self) -> None:
        from uploader_py import config as config_module

        option_strings = {
            option
            for action in config_module._parser()._actions
            for option in action.option_strings
        }
        self.assertTrue(LEGACY_CLI_FLAGS.issubset(option_strings))
        self.assertTrue(NEW_CLI_FLAGS.issubset(option_strings))
        self.assertIn("--help", option_strings)
        self.assertIn("-h", option_strings)

    def test_bootstrap_is_intentionally_small(self) -> None:
        text = _runfile("tools/core/uploader_main.py").read_text(encoding="utf-8")
        self.assertIn("from uploader_py.main import main", text)
        self.assertIn("raise SystemExit(main())", text)
        self.assertNotIn("argparse", text)
        self.assertNotIn("urllib", text)

    def test_python_entrypoint_runs_a_controlled_dry_run_noop(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            testlogs.mkdir()
            config_path = root / "config.json"
            config_path.write_text(
                '{"schema_version":1,"quiescent_sec":0,"max_wait_sec":0}',
                encoding="utf-8",
            )
            stderr = io.StringIO()
            stdout = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(testlogs),
                },
                clear=True,
            ), mock.patch("sys.stderr", stderr), mock.patch("sys.stdout", stdout):
                result = uploader_main(
                    [
                        "--config",
                        str(config_path),
                        "--dry-run",
                        "--allow-cached-payload-uploads",
                    ]
                )
        self.assertEqual(0, result)
        self.assertIn("summary: mode=dry-run", stdout.getvalue())

    def test_python_entrypoint_rejects_invalid_endpoint_during_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            config_path = root / "config.json"
            config_path.write_text(
                '{"schema_version":1,"quiescent_sec":0,"max_wait_sec":0}',
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "DD_TEST_OPTIMIZATION_AGENTLESS_URL": (
                        "http://localhost:notaport"
                    ),
                },
                clear=True,
            ), mock.patch("sys.stderr", stderr):
                result = uploader_main(
                    ["--config", str(config_path), "--dry-run"]
                )

        self.assertEqual(2, result)
        self.assertIn("absolute HTTP(S) URL", stderr.getvalue())

    def test_python_entrypoint_handles_runfiles_manifest_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            config_path = root / "config.json"
            config_path.write_text(
                '{"schema_version":1,"quiescent_sec":0,"max_wait_sec":0}',
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {"BUILD_WORKSPACE_DIRECTORY": str(root)},
                clear=True,
            ), mock.patch(
                "topt_runtime.runfiles.RunfilesResolver.from_environment",
                side_effect=RunfileResolutionError("manifest unavailable"),
            ), mock.patch("sys.stderr", stderr):
                result = uploader_main(
                    ["--config", str(config_path), "--dry-run"]
                )

        self.assertEqual(2, result)
        self.assertIn("manifest unavailable", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
