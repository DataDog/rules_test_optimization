#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Consumer-style integration tests for manifest-driven synchronization."""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SYNC_PATHS = {
    "/api/v2/libraries/tests/services/setting",
    "/api/v2/ci/libraries/tests",
    "/api/v2/test/libraries/test-management/tests",
}
INITIAL_TARGETS = ["//:cache_ax", "//:cache_ay", "//:cache_bz"]
ALL_TARGETS = INITIAL_TARGETS + ["//:cache_c"]


def _write_json(path: Path, value: Any) -> None:
    """Write deterministic JSON atomically so the mock never sees partial state."""
    path.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8", newline="\n")
    os.replace(temporary, path)


def _manifest(include_c: bool = False, reverse: bool = False) -> dict[str, Any]:
    contexts = [
        {
            "key": "service_a__go",
            "runtime": {
                "module_path": "module.x",
                "name": "go",
                "version": "1.25.0",
            },
            "service": "service-a",
        },
        {
            "key": "service_a__python",
            "runtime": {
                "module_path": "module.y",
                "name": "python",
                "version": "3.11.0",
            },
            "service": "service-a",
        },
        {
            "key": "service_b__go",
            "runtime": {
                "module_path": "module.z",
                "name": "go",
                "version": "1.25.0",
            },
            "service": "service-b",
        },
    ]
    targets = [
        {
            "context_key": "service_a__go",
            "label": "//:cache_ax",
            "service_derivation": "application",
        },
        {
            "context_key": "service_a__python",
            "label": "//:cache_ay",
            "service_derivation": "application",
        },
        {
            "context_key": "service_b__go",
            "label": "//:cache_bz",
            "service_derivation": "domain_fallback",
        },
    ]
    if include_c:
        contexts.append(
            {
                "key": "service_c__go",
                "runtime": {
                    "module_path": "module.c",
                    "name": "go",
                    "version": "1.25.0",
                },
                "service": "service-c",
            }
        )
        targets.append(
            {
                "context_key": "service_c__go",
                "label": "//:cache_c",
                "service_derivation": "application",
            }
        )
    if reverse:
        contexts.reverse()
        targets.reverse()
    return {
        "schema_version": 1,
        "contexts": contexts,
        "targets": targets,
    }


def _versions(
    *,
    a_x: str = "v1",
    a_y: str = "v1",
    a_settings: str = "v1",
    b_z: str = "v1",
    include_c: bool = False,
) -> dict[str, Any]:
    services: dict[str, Any] = {
        "service-a": {
            "modules": {
                "module.x": a_x,
                "module.y": a_y,
            },
            "settings": a_settings,
        },
        "service-b": {
            "modules": {"module.z": b_z},
            "settings": "v1",
        },
    }
    if include_c:
        services["service-c"] = {
            "modules": {"module.c": "v1"},
            "settings": "v1",
        }
    return {"services": services}


def _workspace_module(repo_root: Path) -> str:
    path = repo_root.resolve().as_posix()
    return f"""module(name = "manifest-sync-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = {json.dumps(path)},
)

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync_extension",
)
topt.test_optimization_manifest_sync(
    name = "test_optimization_data",
    enabled_by_env = True,
    require_git_metadata = False,
)
use_repo(topt, "test_optimization_data")
"""


def _cache_rule() -> str:
    return r'''"""Test rule whose runfiles model one target's metadata action inputs."""

def _cache_payload_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    metadata = json.encode({
        "bazel.package": ctx.label.package,
        "bazel.target": ctx.attr.target_label,
        "bazel.test_optimization.repo_name": ctx.attr.repo_key,
    })
    ctx.actions.write(
        output = executable,
        is_executable = True,
        content = """#!/usr/bin/env bash
set -euo pipefail
out="${TEST_UNDECLARED_OUTPUTS_DIR:?}"
mkdir -p "$out/payloads/tests"
cat >"$out/payloads/tests/events.json" <<'JSON'
{"events":[{"type":"test","version":2,"content":{"name":"mock.test","resource":"mock.test","service":"placeholder","type":"test","meta":{"test.module":"mock","test.name":"test","test.status":"pass","test.suite":"mock","test.type":"test"},"metrics":{}}}]}
JSON
cat >"$out/bazel_target_metadata.json" <<'JSON'
%s
JSON
""" % metadata,
    )
    inputs = depset(transitive = [
        dep[DefaultInfo].files
        for dep in ctx.attr.data
    ])
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(transitive_files = inputs),
    )]

_cache_payload_test = rule(
    implementation = _cache_payload_test_impl,
    attrs = {
        "data": attr.label_list(),
        "repo_key": attr.string(mandatory = True),
        "target_label": attr.string(mandatory = True),
    },
    test = True,
)

def _selected_module_label(entry, module_label):
    suffix = "_" + module_label
    matches = [
        label
        for label in entry["module_labels"]
        if label.endswith(suffix)
    ]
    if len(matches) != 1:
        fail("expected one module label ending in %r, got %r" % (suffix, matches))
    return matches[0]

def manifest_cache_test(name, module_label, target_entries):
    label = "//:" + name
    entry = target_entries.get(label)
    if entry == None:
        fail("manifest is missing required target %s" % label)
    _cache_payload_test(
        name = name,
        data = [_selected_module_label(entry, module_label)],
        repo_key = entry["repo_name"],
        target_label = label,
    )

def optional_manifest_cache_test(name, module_label, target_entries):
    if "//:" + name not in target_entries:
        return
    manifest_cache_test(name, module_label, target_entries)
'''


def _workspace_build() -> str:
    return '''load("@test_optimization_data//:export.bzl", "topt_data_by_target")
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")
load(":cache_test.bzl", "manifest_cache_test", "optional_manifest_cache_test")

manifest_cache_test(
    name = "cache_ax",
    module_label = "module_x",
    target_entries = topt_data_by_target,
)
manifest_cache_test(
    name = "cache_ay",
    module_label = "module_y",
    target_entries = topt_data_by_target,
)
manifest_cache_test(
    name = "cache_bz",
    module_label = "module_z",
    target_entries = topt_data_by_target,
)
optional_manifest_cache_test(
    name = "cache_c",
    module_label = "module_c",
    target_entries = topt_data_by_target,
)

dd_test_optimization_doctor(
    name = "doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
    expected_targets_file = "@test_optimization_data//:expected_targets",
    forbid_dd_git_test_env = False,
    require_git_metadata = False,
)

dd_payload_uploader(
    name = "uploader",
    data = ["@test_optimization_data//:test_optimization_context"],
)
'''


class ManifestSyncHarness:
    """Own one isolated workspace, mock server, and Bazel output root."""

    def __init__(self, repo_root: Path, keep_tmp: bool) -> None:
        self.repo_root = repo_root
        parent = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir()))
        self.root = Path(tempfile.mkdtemp(prefix="rto_manifest_", dir=parent))
        self.keep_tmp = keep_tmp
        self.workspace = self.root / "workspace"
        self.output_user_root = self.root / "bazel"
        self.request_log = self.root / "requests.jsonl"
        self.server_log = self.root / "server.log"
        self.versions_path = self.root / "response_versions.json"
        self.manifest_path = self.workspace / "manifest.json"
        self.go_marker = self.root / "host_go_was_called"
        self.server: subprocess.Popen[str] | None = None
        self.port = 0
        self.bazel = self._find_bazel()
        self.env = self._clean_environment()

    def _find_bazel(self) -> list[str]:
        explicit = os.environ.get("BAZEL")
        if explicit:
            return [explicit]
        for candidate in ("bazelisk", "bazel"):
            resolved = shutil.which(candidate)
            if resolved:
                return [resolved]
        if os.name != "nt":
            return [str(self.repo_root / "bazelw")]
        raise RuntimeError("bazelisk or bazel is required")

    def _clean_environment(self) -> dict[str, str]:
        env = dict(os.environ)
        for key in (
            "DD_API_KEY",
            "DD_SITE",
            "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
            "DD_TEST_OPTIMIZATION_ENABLED",
            "DD_TEST_OPTIMIZATION_SERVICES_MANIFEST",
        ):
            env.pop(key, None)
        if os.name != "nt":
            sentinel_dir = self.root / "no-host-go"
            sentinel_dir.mkdir(parents=True)
            sentinel = sentinel_dir / "go"
            sentinel.write_text(
                "#!/usr/bin/env bash\n"
                f"printf called >{json.dumps(str(self.go_marker))}\n"
                "exit 97\n",
                encoding="utf-8",
                newline="\n",
            )
            sentinel.chmod(0o755)
            env["PATH"] = str(sentinel_dir) + os.pathsep + env.get("PATH", "")
        return env

    def prepare(self) -> None:
        self.workspace.mkdir(parents=True)
        (self.workspace / "MODULE.bazel").write_text(
            _workspace_module(self.repo_root),
            encoding="utf-8",
            newline="\n",
        )
        (self.workspace / "BUILD.bazel").write_text(
            _workspace_build(),
            encoding="utf-8",
            newline="\n",
        )
        (self.workspace / "cache_test.bzl").write_text(
            _cache_rule(),
            encoding="utf-8",
            newline="\n",
        )
        shutil.copyfile(self.repo_root / ".bazelversion", self.workspace / ".bazelversion")
        _write_json(self.versions_path, _versions())

        server_log = self.server_log.open("w", encoding="utf-8")
        self.server = subprocess.Popen(
            [
                sys.executable,
                "-u",
                str(self.repo_root / "tools/tests/integration/mock_dd_server.py"),
                "--fixtures",
                str(self.repo_root / "tools/tests/integration/fixtures"),
                "--log",
                str(self.request_log),
                "--response-versions",
                str(self.versions_path),
            ],
            cwd=self.workspace,
            stdout=subprocess.PIPE,
            stderr=server_log,
            text=True,
        )
        assert self.server.stdout is not None
        first_line = self.server.stdout.readline().strip()
        if not first_line.startswith("PORT="):
            raise RuntimeError(
                "mock server did not report a port; "
                f"first line={first_line!r}, log={self.server_log.read_text(encoding='utf-8')!r}"
            )
        self.port = int(first_line.split("=", 1)[1])

    def close(self) -> None:
        if self.server is not None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=5)
        subprocess.run(
            self.bazel + [
                f"--output_user_root={self.output_user_root}",
                "shutdown",
            ],
            cwd=self.workspace,
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if self.keep_tmp:
            print(f"manifest integration workspace retained at {self.root}")
        else:
            for directory, subdirectories, files in os.walk(self.root, topdown=False):
                for name in files:
                    try:
                        (Path(directory) / name).chmod(0o600)
                    except OSError:
                        pass
                for name in subdirectories:
                    try:
                        (Path(directory) / name).chmod(0o700)
                    except OSError:
                        pass
            shutil.rmtree(self.root, ignore_errors=True)

    def repo_env(
        self,
        *,
        enabled: bool,
        salt: str,
        manifest: Path | None,
    ) -> list[str]:
        values = {
            "DD_ENV": "ci",
            "DD_TEST_OPTIMIZATION_ENABLED": "1" if enabled else "0",
            "DISABLE_CI_METADATA": "1",
            "FETCH_SALT": salt,
        }
        if enabled:
            values.update(
                {
                    "DD_API_KEY": "mock",
                    "DD_GIT_BRANCH": "main",
                    "DD_GIT_COMMIT_MESSAGE": "manifest integration",
                    "DD_GIT_COMMIT_SHA": "1111111",
                    "DD_GIT_HEAD_COMMIT": "1111111",
                    "DD_GIT_HEAD_MESSAGE": "manifest integration",
                    "DD_GIT_REPOSITORY_URL": "https://example.com/repo.git",
                    "DD_TEST_OPTIMIZATION_AGENTLESS_URL": f"http://127.0.0.1:{self.port}",
                    "DD_TEST_OPTIMIZATION_SERVICES_MANIFEST": str(manifest or ""),
                }
            )
        else:
            values["DD_TEST_OPTIMIZATION_SERVICES_MANIFEST"] = ""
        return [f"--repo_env={key}={value}" for key, value in sorted(values.items())]

    def run_bazel(
        self,
        command: str,
        args: list[str],
        repo_env: list[str],
        *,
        check: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        argv = self.bazel + [
            f"--output_user_root={self.output_user_root}",
            command,
        ]
        argv.extend(repo_env)
        argv.extend(args)
        env = dict(self.env)
        env.update(extra_env or {})
        result = subprocess.run(
            argv,
            cwd=self.workspace,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if check and result.returncode != 0:
            raise RuntimeError(
                f"Bazel command failed ({result.returncode}): {' '.join(argv)}\n{result.stdout}"
            )
        return result

    def request_count(self) -> int:
        if not self.request_log.exists():
            return 0
        return len(self.request_log.read_text(encoding="utf-8").splitlines())

    def requests_since(self, offset: int) -> list[dict[str, Any]]:
        if not self.request_log.exists():
            return []
        lines = self.request_log.read_text(encoding="utf-8").splitlines()[offset:]
        return [json.loads(line) for line in lines]

    def output_base(self, repo_env: list[str]) -> Path:
        result = self.run_bazel("info", ["output_base"], repo_env)
        return Path(result.stdout.strip().splitlines()[-1])

    def generated_repo(self, repo_env: list[str]) -> Path:
        external = self.output_base(repo_env) / "external"
        matches = []
        for export in external.rglob("export.bzl"):
            try:
                text = export.read_text(encoding="utf-8")
            except OSError:
                continue
            if text.startswith("# Generated by test_optimization_manifest_sync"):
                matches.append(export.parent)
        unique = {path.resolve() for path in matches}
        if len(unique) != 1:
            raise AssertionError(f"expected one generated manifest repo, got {sorted(unique)}")
        return unique.pop()

    def assert_host_go_unused(self) -> None:
        if self.go_marker.exists():
            raise AssertionError("manifest integration invoked the host Go binary")


def _assert_failure_before_http(
    harness: ManifestSyncHarness,
    manifest: Path | None,
    expected_message: str,
    salt: str,
) -> None:
    start = harness.request_count()
    result = harness.run_bazel(
        "build",
        ["@test_optimization_data//:test_optimization_files"],
        harness.repo_env(enabled=True, salt=salt, manifest=manifest),
        check=False,
    )
    if result.returncode == 0:
        raise AssertionError(f"expected enabled manifest failure for {salt}")
    if expected_message not in result.stdout:
        raise AssertionError(
            f"missing failure diagnostic {expected_message!r} for {salt}\n{result.stdout}"
        )
    if harness.request_count() != start:
        raise AssertionError(f"{salt} contacted the mock server before manifest validation")


def _bep_cache_state(path: Path, expected_labels: list[str]) -> dict[str, bool]:
    state: dict[str, bool] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        event = json.loads(line)
        result = event.get("testResult")
        identity = event.get("id", {}).get("testResult", {})
        if not isinstance(result, dict) or not isinstance(identity, dict):
            continue
        label = identity.get("label")
        if label not in expected_labels:
            continue
        execution_info = result.get("executionInfo") or {}
        state[label] = bool(
            result.get("cachedLocally")
            or execution_info.get("cachedRemotely")
        )
    if set(state) != set(expected_labels):
        raise AssertionError(
            f"BEP test results mismatch: got {sorted(state)}, expected {sorted(expected_labels)}"
        )
    return state


def _assert_cache_state(
    actual: dict[str, bool],
    *,
    cached: list[str],
    fresh: list[str],
) -> None:
    expected = {label: True for label in cached}
    expected.update({label: False for label in fresh})
    if actual != expected:
        raise AssertionError(f"cache state mismatch: got {actual}, expected {expected}")


def _run_test_phase(
    harness: ManifestSyncHarness,
    *,
    name: str,
    labels: list[str],
    cached: list[str],
    fresh: list[str],
    salt: str,
    no_cache: bool = False,
) -> Path:
    bep = harness.root / f"{name}.bep.json"
    args = [
        "--test_output=errors",
        f"--cache_test_results={'no' if no_cache else 'yes'}",
        f"--build_event_json_file={bep}",
    ]
    if sys.platform == "darwin":
        args.append("--noexperimental_split_xml_generation")
    args.extend(labels)
    harness.run_bazel(
        "test",
        args,
        harness.repo_env(enabled=True, salt=salt, manifest=harness.manifest_path),
    )
    state = _bep_cache_state(bep, labels)
    _assert_cache_state(state, cached=cached, fresh=fresh)
    return bep


def _assert_sync_requests(requests: list[dict[str, Any]], context_count: int) -> None:
    sync_requests = [entry for entry in requests if entry.get("path") in SYNC_PATHS]
    expected_count = context_count * len(SYNC_PATHS)
    if len(sync_requests) != expected_count:
        raise AssertionError(
            f"expected {expected_count} sync requests, got {len(sync_requests)}"
        )
    counts = {path: 0 for path in SYNC_PATHS}
    for entry in sync_requests:
        counts[entry["path"]] += 1
        body = json.loads(base64.b64decode(entry["body_b64"]).decode("utf-8"))
        if body.get("data", {}).get("type") not in {
            "ci_app_libraries_tests_request",
            "ci_app_test_service_libraries_settings",
        }:
            raise AssertionError(f"unexpected sync request body: {body}")
    if any(count != context_count for count in counts.values()):
        raise AssertionError(f"sync endpoint request counts mismatch: {counts}")


def run_disabled_contract(harness: ManifestSyncHarness) -> None:
    start = harness.request_count()
    disabled_env = harness.repo_env(enabled=False, salt="disabled", manifest=None)
    harness.run_bazel(
        "build",
        [
            "@test_optimization_data//:test_optimization_files",
            "@test_optimization_data//:test_optimization_context",
            "@test_optimization_data//:expected_targets",
        ],
        disabled_env,
    )
    if harness.request_count() != start:
        raise AssertionError("disabled manifest repository contacted the mock server")
    repo = harness.generated_repo(disabled_env)
    export = (repo / "export.bzl").read_text(encoding="utf-8")
    if "enabled = False" not in export or "topt_data_by_target = {}" not in export:
        raise AssertionError(f"disabled export is not stable:\n{export}")
    expected = json.loads((repo / "expected_targets.json").read_text(encoding="utf-8"))
    if expected != {"schema_version": 1, "targets": []}:
        raise AssertionError(f"disabled expected targets mismatch: {expected}")

    _assert_failure_before_http(
        harness,
        None,
        "DD_TEST_OPTIMIZATION_SERVICES_MANIFEST must point",
        "missing-manifest",
    )
    invalid = harness.workspace / "invalid-manifest.json"
    _write_json(invalid, {"schema_version": 999, "contexts": [], "targets": []})
    _assert_failure_before_http(
        harness,
        invalid,
        "unsupported schema_version",
        "invalid-manifest",
    )
    harness.assert_host_go_unused()


def run_full_contract(harness: ManifestSyncHarness) -> None:
    _write_json(harness.manifest_path, _manifest())
    _write_json(harness.versions_path, _versions())
    enabled_env = harness.repo_env(
        enabled=True,
        salt="enabled-v1",
        manifest=harness.manifest_path,
    )
    start = harness.request_count()
    harness.run_bazel(
        "build",
        [
            "@test_optimization_data//:test_optimization_context",
            "@test_optimization_data//:expected_targets",
            "//:doctor",
            "//:uploader",
        ],
        enabled_env,
    )
    _assert_sync_requests(harness.requests_since(start), context_count=3)
    repo = harness.generated_repo(enabled_env)
    baseline = {
        name: (repo / name).read_bytes()
        for name in ("BUILD", "expected_targets.json", "export.bzl")
    }
    expected = json.loads(baseline["expected_targets.json"])
    if expected != {"schema_version": 1, "targets": sorted(INITIAL_TARGETS)}:
        raise AssertionError(f"enabled expected targets mismatch: {expected}")

    _write_json(harness.manifest_path, _manifest(reverse=True))
    harness.run_bazel(
        "build",
        ["@test_optimization_data//:test_optimization_context"],
        harness.repo_env(
            enabled=True,
            salt="enabled-reordered",
            manifest=harness.manifest_path,
        ),
    )
    reordered_repo = harness.generated_repo(enabled_env)
    for name, expected_bytes in baseline.items():
        actual = (reordered_repo / name).read_bytes()
        if actual != expected_bytes:
            raise AssertionError(f"{name} changed after manifest reordering")
    _write_json(harness.manifest_path, _manifest())

    _run_test_phase(
        harness,
        name="cache_v1",
        labels=INITIAL_TARGETS,
        cached=[],
        fresh=INITIAL_TARGETS,
        salt="cache-v1",
    )
    _run_test_phase(
        harness,
        name="cache_unchanged",
        labels=INITIAL_TARGETS,
        cached=INITIAL_TARGETS,
        fresh=[],
        salt="cache-unchanged",
    )

    _write_json(harness.versions_path, _versions(b_z="v2"))
    _run_test_phase(
        harness,
        name="cache_b_changed",
        labels=INITIAL_TARGETS,
        cached=["//:cache_ax", "//:cache_ay"],
        fresh=["//:cache_bz"],
        salt="cache-b-v2",
    )

    _write_json(harness.versions_path, _versions(a_x="v2", b_z="v2"))
    _run_test_phase(
        harness,
        name="cache_ax_changed",
        labels=INITIAL_TARGETS,
        cached=["//:cache_ay", "//:cache_bz"],
        fresh=["//:cache_ax"],
        salt="cache-ax-v2",
    )

    _write_json(
        harness.versions_path,
        _versions(a_x="v2", a_settings="v2", b_z="v2"),
    )
    _run_test_phase(
        harness,
        name="cache_a_settings_changed",
        labels=INITIAL_TARGETS,
        cached=["//:cache_bz"],
        fresh=["//:cache_ax", "//:cache_ay"],
        salt="cache-a-settings-v2",
    )

    _write_json(harness.manifest_path, _manifest(include_c=True))
    _write_json(
        harness.versions_path,
        _versions(a_x="v2", a_settings="v2", b_z="v2", include_c=True),
    )
    _run_test_phase(
        harness,
        name="cache_add_c",
        labels=ALL_TARGETS,
        cached=INITIAL_TARGETS,
        fresh=["//:cache_c"],
        salt="cache-add-c",
    )

    fresh_bep = _run_test_phase(
        harness,
        name="fresh_payloads",
        labels=ALL_TARGETS,
        cached=[],
        fresh=ALL_TARGETS,
        salt="fresh-payloads",
        no_cache=True,
    )
    repo_env = harness.repo_env(
        enabled=True,
        salt="fresh-payloads",
        manifest=harness.manifest_path,
    )
    testlogs = harness.run_bazel("info", ["bazel-testlogs"], repo_env).stdout.strip().splitlines()[-1]
    doctor_report = harness.root / "doctor-report.json"
    runtime_env = {"TESTLOGS_DIR": testlogs}
    harness.run_bazel(
        "run",
        [
            "//:doctor",
            "--",
            "--bep-json",
            str(fresh_bep),
            "--freshness-source=bep",
            "--freshness-mode=required",
            "--artifact-source=bep",
            "--report-json",
            str(doctor_report),
        ],
        repo_env,
        extra_env=runtime_env,
    )
    doctor = json.loads(doctor_report.read_text(encoding="utf-8"))
    if doctor["config"]["expected_targets"] != sorted(ALL_TARGETS):
        raise AssertionError(f"doctor expected target set mismatch: {doctor}")
    if doctor["config"]["expected_targets_source"] != "file":
        raise AssertionError(f"doctor did not use the dynamic target file: {doctor}")

    uploader_report = harness.root / "uploader-report.json"
    upload_start = harness.request_count()
    result = harness.run_bazel(
        "run",
        [
            "//:uploader",
            "--",
            "--dry-run",
            "--validate-enrichment",
            "--expected-enriched-tag=service.name",
            "--bep-json",
            str(fresh_bep),
            "--freshness-source=bep",
            "--freshness-mode=required",
            "--report-json",
            str(uploader_report),
        ],
        repo_env,
        extra_env=runtime_env,
    )
    if "dry-run validated 4 test payloads" not in result.stdout:
        raise AssertionError(f"uploader did not validate all dynamic payloads:\n{result.stdout}")
    if harness.request_count() != upload_start:
        raise AssertionError("uploader dry-run contacted the mock server")
    uploader = json.loads(uploader_report.read_text(encoding="utf-8"))
    if uploader["payloads"]["tests"]["processed"] != 4:
        raise AssertionError(f"uploader report mismatch: {uploader}")
    harness.assert_host_go_unused()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("disabled", "full"),
        default="full",
        help="Use disabled on Windows lanes that only enforce repository parsing.",
    )
    parser.add_argument("--keep-tmp", action="store_true")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    harness = ManifestSyncHarness(repo_root, keep_tmp=args.keep_tmp)
    try:
        harness.prepare()
        run_disabled_contract(harness)
        if args.mode == "full":
            if os.name == "nt":
                raise RuntimeError("full manifest cache integration requires a POSIX test runtime")
            run_full_contract(harness)
        print(f"manifest sync integration ({args.mode}) passed")
        return 0
    finally:
        harness.close()


if __name__ == "__main__":
    raise SystemExit(main())
