#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Validate local Datadog Test Optimization Bazel outputs before upload."""

from __future__ import annotations

import argparse
import http.client
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time
from typing import Any, Iterable
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import unquote, urlparse
import uuid
import zipfile


FORBIDDEN_TEST_ENV_RE = re.compile(
    r"--test_env(?:=|\s+)"
    r"(DD_GIT_[A-Z0-9_]*|DD_API_KEY|DD_SITE|DD_TEST_OPTIMIZATION_AGENT_URL|DD_TEST_OPTIMIZATION_AGENTLESS_URL)"
)
VALID_GO_PAYLOAD_SELECTIONS = {
    "module",
    "module_override",
    "full_bundle_disabled",
    "full_bundle_no_match",
}
VALID_GO_PAYLOAD_SELECTIONS_TEXT = ", ".join(sorted(VALID_GO_PAYLOAD_SELECTIONS))
DEFAULT_ALLOWED_GO_PAYLOAD_SELECTIONS = {
    "module",
    "module_override",
    "full_bundle_disabled",
}
DOCTOR_EXECROOT_ENV = "DD_TEST_OPTIMIZATION_DOCTOR_EXECROOT"
VALID_FRESHNESS_MODES = {"auto", "required", "optional", "disabled"}
VALID_FRESHNESS_SOURCES = {"auto", "bep", "execution_log"}
VALID_ARTIFACT_SOURCES = {"auto", "bep", "local"}
VALID_REMOTE_ARTIFACT_MODES = {"disabled", "download", "required"}
REMOTE_TEST_OUTPUT_DOWNLOAD_HINT = (
    "rerun them with --remote_download_minimal "
    "--remote_download_regex=.*test[.]outputs.* so Bazel downloads test.outputs locally. "
    "If the test run also uses --zip_undeclared_test_outputs, rerun the doctor/uploader "
    "with --artifact-source=bep so local outputs.zip carriers are materialized before discovery."
)
STAGING_MARKER = ".dd-topt-bep-staged"
MAX_OUTPUTS_TREE_FILES = 10000
MAX_OUTPUTS_TREE_BYTES = 512 * 1024 * 1024
HTTP_DOWNLOAD_ATTEMPTS = 3
HTTP_DOWNLOAD_BACKOFF_INITIAL_SEC = 0.25
HTTP_DOWNLOAD_BACKOFF_MULTIPLIER = 2.0
_LAST_FAILURE_MESSAGE: str | None = None


class BepRemoteOnlyOutput:
    """Fresh BEP output that is not available as a local file in phase 1."""

    def __init__(self, label: str, output_key: str, artifact: str, reason: str) -> None:
        self.label = label
        self.output_key = output_key
        self.artifact = artifact
        self.reason = reason


class BepArtifactReference:
    """One BEP artifact reference associated with a TestResult output."""

    def __init__(
        self,
        *,
        label: str,
        uri: str,
        name: str,
        path: str,
        candidates: list[str],
        fetch_value: str,
        output_key: str,
        cached: bool,
        remote_only: bool,
        is_test_outputs_hint: bool,
        fetch_is_stageable_carrier: bool,
    ) -> None:
        self.label = label
        self.uri = uri
        self.name = name
        self.path = path
        self.candidates = candidates
        self.fetch_value = fetch_value
        self.output_key = output_key
        self.cached = cached
        self.remote_only = remote_only
        self.is_test_outputs_hint = is_test_outputs_hint
        self.fetch_is_stageable_carrier = fetch_is_stageable_carrier


class BepFreshness:
    """Parsed BEP freshness state used by doctor strict expected-target checks."""

    def __init__(
        self,
        eligible_outputs: set[tuple[str, str]],
        cached_outputs: set[tuple[str, str]],
        remote_only_outputs: list[BepRemoteOnlyOutput],
        missing_output_mappings: set[str],
        artifact_references: list[BepArtifactReference] | None = None,
    ) -> None:
        self.eligible_outputs = eligible_outputs
        self.cached_outputs = cached_outputs
        self.remote_only_outputs = remote_only_outputs
        self.missing_output_mappings = missing_output_mappings
        self.artifact_references = artifact_references or []


class StagedBepArtifact:
    """A BEP artifact materialized into an owned staging directory."""

    def __init__(
        self,
        label: str,
        output_key: str,
        output_dir: Path,
        staging_root: Path,
        *,
        downloaded: bool,
        remote_only: bool,
        fetch_value: str,
    ) -> None:
        self.label = label
        self.output_key = output_key
        self.output_dir = output_dir
        self.staging_root = staging_root
        self.downloaded = downloaded
        self.remote_only = remote_only
        self.fetch_value = fetch_value


class BepArtifactStageError(Exception):
    """A BEP artifact was found but cannot be safely staged."""


def _fail(message: str) -> None:
    global _LAST_FAILURE_MESSAGE
    _LAST_FAILURE_MESSAGE = message
    print(f"[dd-test-optimization-doctor] {message}", file=sys.stderr)
    raise SystemExit(1)


def _warn(message: str) -> None:
    print(f"[dd-test-optimization-doctor] warning: {message}", file=sys.stderr)


def _info(message: str) -> None:
    print(f"[dd-test-optimization-doctor] {message}", file=sys.stderr)


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except FileNotFoundError:
        _fail(f"missing JSON file: {path}")
    except json.JSONDecodeError as exc:
        _fail(f"invalid JSON in {path}: {exc}")


def _validate_downloader_timeout_sec(value: object) -> float:
    text = str(value)
    if not re.fullmatch(r"[+]?([0-9]+([.][0-9]*)?|[.][0-9]+)", text):
        _fail("--bep-artifact-downloader-timeout-sec must be a finite number greater than zero")
    try:
        timeout = float(text)
    except (TypeError, ValueError):
        _fail("--bep-artifact-downloader-timeout-sec must be a finite number greater than zero")
    if not math.isfinite(timeout) or timeout <= 0:
        _fail("--bep-artifact-downloader-timeout-sec must be a finite number greater than zero")
    return timeout


def _validate_artifact_resolution_args(args: argparse.Namespace) -> None:
    if args.artifact_source not in VALID_ARTIFACT_SOURCES:
        _fail(
            f"unsupported artifact-source {args.artifact_source!r}; expected one of: "
            f"{', '.join(sorted(VALID_ARTIFACT_SOURCES))}"
        )
    if args.remote_artifacts not in VALID_REMOTE_ARTIFACT_MODES:
        _fail(
            f"unsupported remote-artifacts {args.remote_artifacts!r}; expected one of: "
            f"{', '.join(sorted(VALID_REMOTE_ARTIFACT_MODES))}"
        )
    args.bep_artifact_downloader_timeout_sec = _validate_downloader_timeout_sec(
        args.bep_artifact_downloader_timeout_sec
    )


def _parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse doctor runtime arguments, including optional BEP freshness flags."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--bep-json", action="append", default=[])
    parser.add_argument(
        "--freshness-source",
        choices=sorted(VALID_FRESHNESS_SOURCES),
        default=os.environ.get("DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE", "auto").lower(),
    )
    parser.add_argument(
        "--freshness-mode",
        choices=sorted(VALID_FRESHNESS_MODES),
        default=os.environ.get("DD_TEST_OPTIMIZATION_FRESHNESS_MODE", "auto").lower(),
    )
    parser.add_argument(
        "--artifact-source",
        choices=sorted(VALID_ARTIFACT_SOURCES),
        default=os.environ.get("DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE", "local").lower(),
    )
    parser.add_argument(
        "--remote-artifacts",
        choices=sorted(VALID_REMOTE_ARTIFACT_MODES),
        default=os.environ.get("DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS", "disabled").lower(),
    )
    parser.add_argument(
        "--artifact-staging-dir",
        default=os.environ.get("DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR", ""),
    )
    parser.add_argument(
        "--bep-artifact-downloader",
        default=os.environ.get("DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER", ""),
    )
    parser.add_argument(
        "--bep-artifact-downloader-timeout-sec",
        default=os.environ.get("DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC", "300"),
    )
    parser.add_argument(
        "--report-json",
        default=os.environ.get("DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON", ""),
        help="Optional path for a machine-readable doctor diagnostic report.",
    )
    args = parser.parse_args(argv)
    _validate_artifact_resolution_args(args)
    return args


def _configured_bep_json_files(args: argparse.Namespace) -> list[Path]:
    """Return BEP files selected by CLI or environment with CLI precedence."""
    if args.bep_json:
        raw_files = args.bep_json
    else:
        env_value = os.environ.get("DD_TEST_OPTIMIZATION_BEP_JSON", "")
        raw_files = [env_value] if env_value else []
    return [Path(raw).expanduser().resolve() for raw in raw_files if raw]


def _workspace_root() -> Path:
    return Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()).resolve()


def _runfile_candidate_strings(raw: str) -> list[str]:
    """Return path variants Bazel may use for the same runfile.

    External repository files can appear as `external/<repo>/...` from action
    paths, `<repo>/...` in directory runfiles, or `../<repo>/...` from short
    paths. The doctor accepts all of those forms so WORKSPACE and Bzlmod
    consumers do not need different target definitions.
    """
    raw = raw.replace("\\", "/")
    candidates = [raw]
    stripped = raw
    while stripped.startswith("../"):
        stripped = stripped[3:]
        candidates.append(stripped)
    if raw.startswith("external/"):
        candidates.append(raw[len("external/") :])
    if stripped.startswith("external/"):
        candidates.append(stripped[len("external/") :])
    return list(dict.fromkeys(candidate for candidate in candidates if candidate))


def _runfiles_roots() -> list[Path]:
    """Return directory runfiles roots available to this process."""
    roots: list[Path] = []
    runfiles_dir = os.environ.get("RUNFILES_DIR")
    if runfiles_dir:
        roots.append(Path(runfiles_dir))
    for parent in Path(__file__).resolve().parents:
        if parent.name.endswith(".runfiles"):
            roots.append(parent)
            break
    return list(dict.fromkeys(root.resolve() for root in roots if root.exists()))


def _infer_bazel_execroot(anchor: Path) -> Path | None:
    """Infer the Bazel execroot from a generated output path.

    Windows `bazel run` can launch the doctor without runfiles environment
    variables, while generated config files still live below
    `<output_base>/execroot/<workspace>/bazel-out/...`. Walking upward from the
    config path lets the doctor resolve execroot-relative artifact paths such
    as `external/<repo>/.testoptimization/context.json`.
    """
    start = anchor if anchor.is_dir() else anchor.parent
    for candidate in [start, *start.parents]:
        if (candidate / "external").exists() and (candidate / "bazel-out").exists():
            return candidate.resolve()
        if candidate.parent.name == "execroot" and (candidate / "external").exists():
            return candidate.resolve()
    return None


def _execroot_roots() -> list[Path]:
    """Return Bazel execroot candidates for resolving artifact-relative paths."""
    roots: list[Path] = []
    configured = os.environ.get(DOCTOR_EXECROOT_ENV)
    if configured:
        roots.append(Path(configured))

    cwd = Path.cwd().resolve()
    roots.append(cwd)
    for candidate in [cwd, *cwd.parents]:
        if (candidate / "external").exists() and (candidate / "bazel-out").exists():
            roots.append(candidate)
        elif candidate.parent.name == "execroot" and (candidate / "external").exists():
            roots.append(candidate)

    return list(dict.fromkeys(root.resolve() for root in roots if root.exists()))


def _resolve_execroot_relative_path(candidates: list[str]) -> Path | None:
    """Resolve a path recorded relative to Bazel's execroot."""
    for root in _execroot_roots():
        for candidate in candidates:
            path = root / candidate
            if path.is_file():
                return path.resolve()
            if not candidate.startswith("external/"):
                external_path = root / "external" / candidate
                if external_path.is_file():
                    return external_path.resolve()
    return None


def _lookup_manifest_runfile(candidates: list[str], workspace: str) -> Path | None:
    """Resolve a runfile through RUNFILES_MANIFEST_FILE when directory runfiles are unavailable."""
    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if not manifest:
        return None
    manifest_path = Path(manifest)
    if not manifest_path.is_file():
        return None
    manifest_keys = set(candidates)
    if workspace:
        manifest_keys.update(f"{workspace}/{candidate}" for candidate in candidates)
    with manifest_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            key, sep, value = line.rstrip("\n").partition(" ")
            if sep and key in manifest_keys:
                return Path(value)
    return None


def _resolve_runfile_path(raw_paths: list[str]) -> Path:
    """Resolve one file from direct paths, directory runfiles, or manifest runfiles."""
    workspace = os.environ.get("DD_TEST_OPTIMIZATION_DOCTOR_RUNFILES_WORKSPACE", "")
    candidates: list[str] = []
    for raw in raw_paths:
        candidates.extend(_runfile_candidate_strings(raw))
    candidates = list(dict.fromkeys(candidates))

    for candidate in candidates:
        path = Path(candidate)
        if path.is_file():
            return path.resolve()

    execroot_match = _resolve_execroot_relative_path(candidates)
    if execroot_match is not None:
        return execroot_match

    roots = _runfiles_roots()
    for root in roots:
        for candidate in candidates:
            path = root / candidate
            if path.is_file():
                return path.resolve()
            if workspace:
                workspace_path = root / workspace / candidate
                if workspace_path.is_file():
                    return workspace_path.resolve()

    manifest_match = _lookup_manifest_runfile(candidates, workspace)
    if manifest_match is not None:
        return manifest_match

    return Path(raw_paths[0])


def _resolve_testlogs_dir(workspace: Path, *, allow_missing: bool = False) -> Path | None:
    override = os.environ.get("TESTLOGS_DIR")
    if override:
        path = Path(override).expanduser()
        if not path.exists():
            _fail(f"TESTLOGS_DIR is set but path does not exist: {path}")
        if not path.is_dir():
            _fail(f"TESTLOGS_DIR is set but is not a directory: {path}")
        return path.resolve()

    candidates = [workspace / "bazel-testlogs", Path.cwd() / "bazel-testlogs"]
    for candidate in candidates:
        if candidate.exists() and candidate.is_dir():
            return candidate.resolve()
    if allow_missing:
        return None
    _fail("could not find bazel-testlogs; set TESTLOGS_DIR or run from the Bazel workspace root")


def _expected_target_root(testlogs_dir: Path, label: str) -> Path:
    """Return the bazel-testlogs target root for one local target label."""
    if label.startswith("@"):
        _fail(f"expected_targets does not support external labels, got {label!r}")
    if not label.startswith("//"):
        _fail(f"expected_targets only supports local labels, got {label!r}")
    body = label[2:]
    if ":" not in body:
        _fail(f"expected target label must include ':', got {label!r}")
    pkg, target = body.split(":", 1)
    if not target:
        _fail(f"expected target label has empty target name: {label!r}")
    if target.startswith("/") or ".." in target.split("/"):
        _fail(f"expected target label has unsupported target path: {label!r}")
    parts = [p for p in pkg.split("/") if p]
    return testlogs_dir.joinpath(*parts, target)


def _expected_target_outputs(testlogs_dir: Path | None, label: str, *, allow_missing: bool = False) -> list[Path]:
    """Return all test.outputs directories for one expected local target.

    Bazel can nest outputs under shard/retry directories, so strict expected
    targets discover recursively below the target root instead of assuming only
    `<pkg>/<target>/test.outputs`.
    """
    if testlogs_dir is None:
        if allow_missing:
            return []
        _fail(f"cannot resolve expected target {label}: bazel-testlogs directory not found")
    target_root = _expected_target_root(testlogs_dir, label)
    if not target_root.exists():
        if allow_missing:
            return []
        _fail(_missing_expected_target_message(label, target_root, "output root"))
    output_dirs = _discover_output_dirs(target_root)
    if not output_dirs:
        if allow_missing:
            return []
        _fail(_missing_expected_target_message(label, target_root, "test.outputs directory"))
    return output_dirs


def _missing_expected_target_message(label: str, target_root: Path, missing_part: str) -> str:
    """Return an actionable error for expected targets with no local outputs."""
    return (
        f"expected target {missing_part} not found for {label}: {target_root}. "
        "Run this exact instrumented test target before running the doctor. "
        "Do not list build-only, wrapper-only, or analysis-only targets in "
        "expected_targets. If tests ran with remote execution or remote cache, "
        f"{REMOTE_TEST_OUTPUT_DOWNLOAD_HINT}"
    )


def _coalesced_field(obj: Any, camel: str, snake: str, default: Any = None) -> Any:
    """Read a BEP JSON field accepting camelCase and snake_case spellings."""
    if not isinstance(obj, dict):
        return default
    if camel in obj:
        return obj[camel]
    if snake in obj:
        return obj[snake]
    return default


def _bep_file_reference_candidates(file_obj: Any) -> list[str]:
    """Return useful path/URI strings from a BEP File JSON object."""
    if isinstance(file_obj, str):
        return [file_obj]
    if not isinstance(file_obj, dict):
        return []
    values = []
    for key in ("uri", "name", "path"):
        value = file_obj.get(key)
        if isinstance(value, str) and value:
            values.append(value)
    path_prefix = _coalesced_field(file_obj, "pathPrefix", "path_prefix", [])
    name = file_obj.get("name")
    if isinstance(path_prefix, list) and isinstance(name, str) and name:
        path_parts = [part for part in path_prefix if isinstance(part, str) and part]
        if path_parts:
            values.append("/".join(path_parts + [name]))
    return values


def _bep_path_prefix_name_candidate(file_obj: Any) -> str:
    """Return the BEP pathPrefix/name reconstruction for one File object."""
    if not isinstance(file_obj, dict):
        return ""
    path_prefix = _coalesced_field(file_obj, "pathPrefix", "path_prefix", [])
    name = file_obj.get("name")
    if not isinstance(path_prefix, list) or not isinstance(name, str) or not name:
        return ""
    path_parts = [part for part in path_prefix if isinstance(part, str) and part]
    if not path_parts:
        return ""
    return "/".join(path_parts + [name])


def _trusted_bep_output_key_candidate(value: str) -> bool:
    """Return true when a fallback BEP value can safely derive an output key."""
    normalized = _strip_file_uri(value).replace("\\", "/").strip("/")
    if not normalized or "/" not in normalized:
        return False
    if _is_remote_only_bep_reference(normalized):
        return False
    parts = [part for part in normalized.split("/") if part]
    return "testlogs" in parts or "bazel-testlogs" in parts


def _bep_canonical_output_key_candidates(file_obj: Any, candidates: list[str]) -> list[str]:
    """Return BEP values allowed to derive the stable upload output key."""
    values: list[str] = []

    def append(value: str) -> None:
        if value and value not in values:
            values.append(value)

    if isinstance(file_obj, dict):
        append(_bep_path_prefix_name_candidate(file_obj))
        path = file_obj.get("path")
        if isinstance(path, str):
            append(path)
    for candidate in candidates:
        if _trusted_bep_output_key_candidate(candidate):
            append(candidate)
    return values


def _bep_artifact_fetch_value(file_obj: Any, candidates: list[str]) -> str:
    """Return the preferred concrete value used to materialize one BEP File."""
    if isinstance(file_obj, dict):
        for key in ("uri", "path"):
            value = file_obj.get(key)
            if isinstance(value, str) and value:
                return value
        reconstructed = _bep_path_prefix_name_candidate(file_obj)
        if reconstructed:
            return reconstructed
    return candidates[0] if candidates else ""


def _strip_file_uri(value: str) -> str:
    """Return a local path-like value for `file://` URI references."""
    if not value.lower().startswith("file://"):
        return value
    parsed = urlparse(value)
    if parsed.scheme != "file":
        return value
    path = unquote(parsed.path or "")
    if parsed.netloc and parsed.netloc not in {"", "localhost"}:
        path = f"//{parsed.netloc}{path}"
    return path


def _local_artifact_path_from_reference(value: str) -> Path:
    """Return a platform-correct Path for a local BEP artifact reference."""
    raw = _strip_file_uri(value)
    if re.match(r"^/[A-Za-z]:[/\\]", raw):
        raw = raw[1:]
    return Path(raw)


def _bep_test_output_key(path_value: str) -> str:
    """Normalize a BEP output reference to a bazel-testlogs-relative test.outputs key."""
    if not path_value:
        return ""
    normalized = _strip_file_uri(path_value)
    normalized = unquote(normalized).replace("\\", "/")
    if "/testlogs/" in normalized:
        normalized = normalized.rsplit("/testlogs/", 1)[-1]
    elif "/bazel-testlogs/" in normalized:
        normalized = normalized.rsplit("/bazel-testlogs/", 1)[-1]
    else:
        normalized = normalized.lstrip("/")

    while normalized.startswith("./"):
        normalized = normalized[2:]
    normalized = normalized.lstrip("/")

    marker = "/test.outputs/"
    if marker in normalized:
        normalized = normalized.split(marker, 1)[0] + "/test.outputs"
    elif normalized.endswith("/test.outputs"):
        pass
    elif normalized.endswith("/outputs.zip"):
        normalized = normalized.rsplit("/", 1)[0] + "/test.outputs"
    elif normalized.endswith("/test.log") or normalized.endswith("/test.xml"):
        normalized = normalized.rsplit("/", 1)[0] + "/test.outputs"
    else:
        return ""

    return normalized.lstrip("/")


def _is_remote_only_bep_reference(path_value: str) -> bool:
    """Return true when a BEP file reference is not locally materialized in phase 1."""
    if not path_value:
        return False
    lowered = path_value.lower()
    if lowered.startswith("file://"):
        return False
    if re.match(r"^[a-z][a-z0-9+.-]*://", lowered):
        return True
    if lowered.startswith("blobs/") or re.match(r"^[0-9a-f]{32,}/[0-9]+$", lowered):
        return True
    return False


def _is_http_artifact_reference(value: str) -> bool:
    """Return true when a BEP artifact reference is an HTTP(S) URI."""
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return False
    return parsed.scheme.lower() in {"http", "https"} and bool(parsed.netloc)


def _display_artifact_reference(value: str) -> str:
    """Return a customer-facing artifact reference without URL secrets."""
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        lowered = value.lower()
        if lowered.startswith("http://") or lowered.startswith("https://"):
            return f"{lowered.split('://', 1)[0]}://redacted-invalid-url"
        return value
    if parsed.scheme.lower() not in {"http", "https"}:
        return value
    host = parsed.hostname or ""
    if not host:
        return f"{parsed.scheme}://redacted-invalid-url"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError:
        port = None
    if port is not None:
        host = f"{host}:{port}"
    redacted = urllib.parse.urlunsplit((parsed.scheme, host, parsed.path, "", ""))
    return redacted or f"{parsed.scheme}://redacted-host"


def _bep_test_outputs_artifact_hint(path_value: str) -> bool:
    """Return true when a BEP reference appears to describe undeclared test outputs."""
    if not path_value:
        return False
    normalized = _strip_file_uri(path_value).replace("\\", "/").lower()
    return (
        normalized == "test.outputs"
        or normalized == "outputs.zip"
        or "/test.outputs/" in normalized
        or normalized.endswith("/test.outputs")
        or normalized.endswith("/outputs.zip")
    )


def _bep_stageable_artifact_carrier_hint(file_obj: Any, candidates: list[str]) -> bool:
    """Return true when a BEP File can materialize one complete test.outputs tree."""
    values: list[str] = []

    def append(value: Any) -> None:
        if isinstance(value, str) and value:
            values.append(value)

    if isinstance(file_obj, dict):
        append(file_obj.get("name"))
        append(file_obj.get("path"))
        append(_bep_path_prefix_name_candidate(file_obj))
        uri = file_obj.get("uri")
        if (
            isinstance(uri, str)
            and uri
            and not _is_remote_only_bep_reference(uri)
            and _trusted_bep_output_key_candidate(uri)
        ):
            append(uri)
    else:
        values.extend(candidates)

    for value in values:
        normalized = _strip_file_uri(value).replace("\\", "/").lower().rstrip("/")
        if normalized in {"test.outputs", "outputs.zip"}:
            return True
        if normalized.endswith("/test.outputs") or normalized.endswith("/outputs.zip"):
            return True
    return False


def _create_staging_run_dir(staging_dir: Path) -> Path:
    """Create a per-run staging root below the configured staging directory."""
    staging_dir.mkdir(parents=True, exist_ok=True)
    run_dir = staging_dir / "__runs" / uuid.uuid4().hex
    run_dir.mkdir(parents=True)
    return run_dir


def _prepare_staging_destination(staging_dir: Path, output_key: str) -> tuple[Path, Path]:
    """Return temporary and final destinations for one staged test.outputs key."""
    if not output_key or output_key.startswith("/") or ".." in output_key.split("/"):
        _fail(f"unsafe BEP output key for staging: {output_key!r}")
    dst = staging_dir / output_key
    resolved_staging = staging_dir.resolve()
    resolved_dst_parent = dst.parent.resolve()
    if resolved_staging not in [resolved_dst_parent, *resolved_dst_parent.parents]:
        _fail(f"unsafe BEP staging destination outside staging dir: {dst}")
    if dst.exists():
        marker = dst / STAGING_MARKER
        if not marker.exists():
            _fail(f"refusing to replace non-owned BEP staging directory: {dst}")
        shutil.rmtree(dst)
    tmp = dst.parent / f".{dst.name}.tmp-{uuid.uuid4().hex}"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    return tmp, dst


def _commit_staging_destination(tmp: Path, dst: Path) -> None:
    """Atomically publish a validated staged test.outputs directory."""
    (tmp / STAGING_MARKER).write_text("owned by dd-test-optimization BEP staging\n", encoding="utf-8")
    tmp.rename(dst)


def _discard_staging_destination(tmp: Path) -> None:
    """Discard a temporary staging destination if it exists."""
    shutil.rmtree(tmp, ignore_errors=True)


def _copy_tree_contents(src: Path, dst: Path) -> None:
    """Copy a local test.outputs tree into an empty staging destination."""
    file_count = 0
    byte_count = 0
    for root, dirs, files in os.walk(src):
        rel_root = Path(root).relative_to(src)
        for dirname in list(dirs):
            source_dir = Path(root) / dirname
            if source_dir.is_symlink():
                raise BepArtifactStageError(
                    f"refusing to stage symlink directory from BEP artifact source: {source_dir}"
                )
            (dst / rel_root / dirname).mkdir(parents=True, exist_ok=True)
        for filename in files:
            file_count += 1
            if file_count > MAX_OUTPUTS_TREE_FILES:
                raise BepArtifactStageError(f"BEP test.outputs tree has too many files: {src}")
            source_file = Path(root) / filename
            if source_file.is_symlink():
                raise BepArtifactStageError(f"refusing to stage symlink from BEP artifact source: {source_file}")
            try:
                size = source_file.stat().st_size
            except OSError as exc:
                raise BepArtifactStageError(f"failed to stat BEP artifact file {source_file}: {exc}") from exc
            byte_count += size
            if byte_count > MAX_OUTPUTS_TREE_BYTES:
                raise BepArtifactStageError(f"BEP test.outputs tree is too large: {src}")
            target_file = dst / rel_root / filename
            target_file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_file, target_file)


def _extract_outputs_zip(zip_path: Path, dst: Path) -> None:
    """Safely extract an outputs.zip archive into an empty staging destination."""
    try:
        with zipfile.ZipFile(zip_path) as archive:
            planned_members = []
            file_count = 0
            byte_count = 0
            resolved_dst = dst.resolve()
            for member in archive.infolist():
                name = member.filename.replace("\\", "/").rstrip("/")
                parts = name.split("/") if name else []
                if (
                    not name
                    or name.startswith("/")
                    or re.match(r"^[A-Za-z]:/", name)
                    or any(part in ("", ".", "..") for part in parts)
                ):
                    raise BepArtifactStageError(f"unsafe path in BEP outputs.zip {zip_path}: {member.filename!r}")
                target = dst / name
                resolved_target = target.resolve()
                if resolved_dst not in [resolved_target, *resolved_target.parents]:
                    raise BepArtifactStageError(f"unsafe path in BEP outputs.zip {zip_path}: {member.filename!r}")
                if len(planned_members) + 1 > MAX_OUTPUTS_TREE_FILES:
                    raise BepArtifactStageError(f"BEP outputs.zip has too many entries: {zip_path}")
                if not member.is_dir():
                    file_count += 1
                    byte_count += member.file_size
                    if byte_count > MAX_OUTPUTS_TREE_BYTES:
                        raise BepArtifactStageError(f"BEP outputs.zip is too large after decompression: {zip_path}")
                planned_members.append((member, target))
            for member, target in planned_members:
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as src, target.open("wb") as out:
                    shutil.copyfileobj(src, out, length=1024 * 1024)
    except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        raise BepArtifactStageError(f"invalid BEP outputs.zip {zip_path}: {exc}") from exc


def _output_base_roots() -> list[Path]:
    """Return Bazel output-base candidates derived from known execroot roots."""
    roots: list[Path] = []
    configured = os.environ.get("DD_TEST_OPTIMIZATION_BAZEL_OUTPUT_BASE")
    if configured:
        roots.append(Path(configured).expanduser())
    for root in _execroot_roots():
        if root.parent.name == "execroot":
            roots.append(root.parent.parent)
    return list(dict.fromkeys(root.resolve() for root in roots if root.exists()))


def _resolve_bep_local_artifact_path(value: str, workspace: Path) -> Path:
    """Resolve a local BEP artifact reference from workspace, execroot, or output base."""
    if not value:
        raise BepArtifactStageError("BEP artifact reference is empty")
    path = _local_artifact_path_from_reference(value).expanduser()
    candidates = [path] if path.is_absolute() else []
    if not path.is_absolute():
        candidates.append(workspace / path)
        candidates.extend(root / path for root in _execroot_roots())
        candidates.extend(root / path for root in _output_base_roots())
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise BepArtifactStageError(f"BEP artifact is not available locally: {value}")


def _safe_download_fragment(value: str) -> str:
    """Return a filesystem-safe fragment for remote downloader scratch paths."""
    fragment = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._-")
    return fragment or "artifact"


def _dedupe_stageable_artifact_references(
    artifact_references: list[BepArtifactReference],
    *,
    workspace: Path,
    remote_artifacts: str,
) -> tuple[list[BepArtifactReference], set[tuple[str, str]]]:
    """Return unambiguous stageable references and keys with conflicting carriers."""
    by_key: dict[tuple[str, str], list[BepArtifactReference]] = {}
    pass_through: list[BepArtifactReference] = []
    for ref in artifact_references:
        if ref.cached or not ref.fetch_is_stageable_carrier or not ref.output_key:
            pass_through.append(ref)
            continue
        if ref.remote_only and remote_artifacts == "disabled":
            pass_through.append(ref)
            continue
        by_key.setdefault((ref.label, ref.output_key), []).append(ref)

    selected: list[BepArtifactReference] = pass_through[:]
    ambiguous: set[tuple[str, str]] = set()
    for key, refs in by_key.items():
        carrier_groups: dict[tuple[bool, str], list[BepArtifactReference]] = {}
        for ref in refs:
            if ref.remote_only:
                carrier_key = (True, ref.fetch_value)
            else:
                try:
                    resolved = _resolve_bep_local_artifact_path(ref.fetch_value, workspace)
                    carrier_key = (False, str(resolved))
                except BepArtifactStageError:
                    carrier_key = (False, _strip_file_uri(ref.fetch_value).replace("\\", "/"))
            carrier_groups.setdefault(carrier_key, []).append(ref)
        carriers = set(carrier_groups)
        if len(carriers) > 1:
            ambiguous.add(key)
            continue
        selected.append(sorted(next(iter(carrier_groups.values())), key=lambda item: item.fetch_value)[0])
    return sorted(selected, key=lambda item: (item.label, item.output_key, item.fetch_value)), ambiguous


def _download_remote_artifact(
    ref: BepArtifactReference,
    staging_dir: Path,
    downloader: str,
    *,
    timeout_sec: float,
) -> Path | None:
    """Run the configured downloader and return its produced outputs.zip path."""
    safe_label = _safe_download_fragment(ref.label)
    safe_key = _safe_download_fragment(ref.output_key)
    dst = staging_dir / "__downloads" / safe_label / safe_key / "outputs.zip"
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        if dst.is_file():
            dst.unlink()
        else:
            raise BepArtifactStageError(f"refusing to replace non-file BEP downloader destination: {dst}")
    cmd = [
        downloader,
        "--uri",
        ref.fetch_value,
        "--name",
        ref.name,
        "--output",
        str(dst),
    ]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _warn(f"BEP artifact downloader timed out for {ref.label} after {timeout_sec:g}s")
        return None
    except OSError as exc:
        _warn(f"BEP artifact downloader could not start for {ref.label}: {exc}")
        return None
    if proc.returncode != 0:
        _warn(f"BEP artifact downloader failed for {ref.label} with exit code {proc.returncode}")
        return None
    if not dst.exists():
        return None
    if not dst.is_file():
        raise BepArtifactStageError(f"BEP artifact downloader did not produce a file at {dst}")
    return dst


def _http_download_backoff_seconds(attempt_index: int) -> float:
    return HTTP_DOWNLOAD_BACKOFF_INITIAL_SEC * (HTTP_DOWNLOAD_BACKOFF_MULTIPLIER ** attempt_index)


def _is_retryable_http_download_error(exc: BaseException) -> bool:
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in {408, 429} or 500 <= exc.code <= 599
    return isinstance(
        exc,
        (
            urllib.error.URLError,
            http.client.IncompleteRead,
            ConnectionResetError,
            BrokenPipeError,
            TimeoutError,
            socket.timeout,
        ),
    )


def _download_http_artifact(
    ref: BepArtifactReference,
    staging_dir: Path,
    *,
    timeout_sec: float,
) -> Path | None:
    """Download an unauthenticated HTTP(S) BEP outputs.zip artifact."""
    safe_label = _safe_download_fragment(ref.label)
    safe_key = _safe_download_fragment(ref.output_key)
    dst = staging_dir / "__downloads" / safe_label / safe_key / "outputs.zip"
    tmp = dst.with_name("outputs.zip.tmp")
    dst.parent.mkdir(parents=True, exist_ok=True)
    for path in (dst, tmp):
        if path.exists():
            if path.is_file():
                path.unlink()
            else:
                raise BepArtifactStageError(f"refusing to replace non-file BEP HTTP download destination: {path}")

    display_uri = _display_artifact_reference(ref.fetch_value)
    last_error: BaseException | None = None
    attempt_count = 0
    for attempt_index in range(HTTP_DOWNLOAD_ATTEMPTS):
        attempt_count = attempt_index + 1
        tmp.unlink(missing_ok=True)
        try:
            request = urllib.request.Request(
                ref.fetch_value,
                headers={"User-Agent": "datadog-rules-test-optimization"},
            )
            with urllib.request.urlopen(request, timeout=timeout_sec) as response, tmp.open("wb") as out:
                length = response.headers.get("Content-Length")
                expected_length: int | None = None
                if length is not None:
                    expected_length = int(length)
                    if expected_length < 0:
                        raise ValueError(f"negative Content-Length: {length}")
                    if expected_length > MAX_OUTPUTS_TREE_BYTES:
                        raise BepArtifactStageError(f"BEP HTTP artifact is too large: {display_uri}")
                total = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_OUTPUTS_TREE_BYTES:
                        raise BepArtifactStageError(f"BEP HTTP artifact is too large: {display_uri}")
                    out.write(chunk)
                if expected_length is not None and total < expected_length:
                    raise http.client.IncompleteRead(b"", expected_length - total)
            tmp.replace(dst)
            _info(
                f"BEP HTTP artifact downloaded for {ref.label} output {ref.output_key}: "
                f"{display_uri} ({total} bytes)"
            )
            return dst
        except BepArtifactStageError:
            tmp.unlink(missing_ok=True)
            raise
        except (
            urllib.error.URLError,
            http.client.IncompleteRead,
            ConnectionResetError,
            BrokenPipeError,
            TimeoutError,
            socket.timeout,
            ValueError,
        ) as exc:
            tmp.unlink(missing_ok=True)
            last_error = exc
            if not _is_retryable_http_download_error(exc) or attempt_index + 1 >= HTTP_DOWNLOAD_ATTEMPTS:
                break
            time.sleep(_http_download_backoff_seconds(attempt_index))
        except OSError as exc:
            tmp.unlink(missing_ok=True)
            raise BepArtifactStageError(f"failed to write BEP HTTP artifact download {tmp}: {exc}") from exc

    if last_error is not None:
        _warn(
            f"BEP HTTP artifact download failed for {ref.label} after "
            f"{attempt_count} attempts: {display_uri}: {last_error}"
        )
        return None
    return None


def _stage_bep_artifacts(
    freshness: BepFreshness,
    *,
    workspace: Path,
    staging_dir: Path,
    remote_artifacts: str,
    downloader: str = "",
    downloader_timeout_sec: float = 300.0,
) -> list[StagedBepArtifact]:
    """Materialize fresh BEP artifacts into local test.outputs directories."""
    warned: set[str] = set()
    staged: list[StagedBepArtifact] = []
    run_staging_dir = _create_staging_run_dir(staging_dir)

    def warn_once(message: str) -> None:
        if message not in warned:
            warned.add(message)
            _warn(message)

    try:
        refs, ambiguous_output_keys = _dedupe_stageable_artifact_references(
            freshness.artifact_references,
            workspace=workspace,
            remote_artifacts=remote_artifacts,
        )
        if ambiguous_output_keys:
            label, output_key = sorted(ambiguous_output_keys)[0]
            message = f"BEP has multiple distinct stageable carriers for {label} {output_key}"
            if remote_artifacts == "required":
                _fail(message)
            warn_once(message)
        for ref in refs:
            if ref.cached:
                continue
            display_fetch_value = _display_artifact_reference(ref.fetch_value)
            if ref.is_test_outputs_hint and not ref.output_key:
                message = f"BEP artifact for {ref.label} has no mappable test.outputs key: {display_fetch_value}"
                if remote_artifacts == "required":
                    _fail(message)
                if remote_artifacts == "download":
                    warn_once(message)
                continue
            if not ref.fetch_is_stageable_carrier:
                if ref.remote_only and not ref.is_test_outputs_hint:
                    continue
                if ref.remote_only and remote_artifacts == "required":
                    _fail(
                        f"BEP artifact for {ref.label} is remote-only but not a supported "
                        f"test.outputs carrier: {display_fetch_value}"
                    )
                if ref.remote_only and remote_artifacts == "download":
                    warn_once(
                        f"BEP artifact for {ref.label} is remote-only but not stageable: "
                        f"{display_fetch_value}"
                    )
                continue
            if ref.remote_only:
                if remote_artifacts == "disabled":
                    warn_once(
                        f"BEP artifact for {ref.label} is remote-only but remote artifact "
                        f"download is disabled: {display_fetch_value}"
                    )
                    continue
                if not downloader and not _is_http_artifact_reference(ref.fetch_value):
                    if remote_artifacts == "required":
                        _fail(
                            f"BEP artifact for {ref.label} is remote-only and no downloader is configured: "
                            f"{display_fetch_value}"
                        )
                    warn_once(
                        f"BEP artifact for {ref.label} is remote-only and no downloader is configured: "
                        f"{display_fetch_value}"
                    )
                    continue
            downloaded = False
            try:
                if ref.remote_only:
                    if downloader:
                        source = _download_remote_artifact(
                            ref,
                            run_staging_dir,
                            downloader,
                            timeout_sec=downloader_timeout_sec,
                        )
                    else:
                        source = _download_http_artifact(
                            ref,
                            run_staging_dir,
                            timeout_sec=downloader_timeout_sec,
                        )
                    downloaded = source is not None
                else:
                    source = _resolve_bep_local_artifact_path(ref.fetch_value, workspace)
            except (BepArtifactStageError, OSError) as exc:
                if remote_artifacts == "required":
                    _fail(str(exc))
                warn_once(str(exc))
                continue
            if source is None:
                if remote_artifacts == "required":
                    _fail(
                        f"BEP artifact for {ref.label} could not be materialized as a local test.outputs carrier: "
                        f"{display_fetch_value}"
                    )
                if remote_artifacts == "download":
                    warn_once(
                        f"BEP artifact for {ref.label} could not be materialized and will be skipped: "
                        f"{display_fetch_value}"
                    )
                continue
            tmp_dst, dst = _prepare_staging_destination(run_staging_dir, ref.output_key)
            try:
                if downloaded:
                    if not source.is_file() or source.name != "outputs.zip":
                        raise BepArtifactStageError(
                            f"BEP downloader for {ref.label} did not produce an outputs.zip archive: {source}"
                        )
                    _extract_outputs_zip(source, tmp_dst)
                elif source.is_dir():
                    _copy_tree_contents(source, tmp_dst)
                elif source.name == "outputs.zip":
                    _extract_outputs_zip(source, tmp_dst)
                else:
                    raise BepArtifactStageError(
                        f"BEP artifact for {ref.label} is not a supported test.outputs carrier: {source}"
                    )
                _commit_staging_destination(tmp_dst, dst)
            except (BepArtifactStageError, OSError) as exc:
                _discard_staging_destination(tmp_dst)
                if remote_artifacts == "required":
                    _fail(str(exc))
                warn_once(str(exc))
                continue
            staged.append(
                StagedBepArtifact(
                    ref.label,
                    ref.output_key,
                    dst,
                    run_staging_dir,
                    downloaded=downloaded,
                    remote_only=ref.remote_only,
                    fetch_value=ref.fetch_value,
                )
            )
        if not staged:
            shutil.rmtree(run_staging_dir, ignore_errors=True)
        return sorted(staged, key=lambda item: str(item.output_dir))
    except BaseException:
        shutil.rmtree(run_staging_dir, ignore_errors=True)
        raise


def _cleanup_staged_bep_run_roots(staged: Iterable[StagedBepArtifact], *, staging_base: Path) -> None:
    """Remove owned per-run staging roots after staged outputs are no longer needed."""
    runs_root = (staging_base / "__runs").resolve()
    roots = sorted({item.staging_root.resolve() for item in staged})
    for root in roots:
        if root.parent.resolve() != runs_root:
            _fail(f"refusing to clean BEP staging root outside run directory: {root}")
        owned = False
        for item in staged:
            if item.staging_root.resolve() != root:
                continue
            output_dir = item.output_dir.resolve()
            if root not in [output_dir, *output_dir.parents]:
                _fail(f"refusing to clean BEP output outside staging root: {output_dir}")
            if (output_dir / STAGING_MARKER).exists():
                owned = True
        if owned:
            shutil.rmtree(root, ignore_errors=True)


def _artifact_staging_requested(args: argparse.Namespace) -> bool:
    """Return true when CLI/env requested BEP artifact staging."""
    return args.artifact_source == "bep" or (
        args.artifact_source == "auto" and args.remote_artifacts != "disabled"
    )


def _artifact_staging_enabled(args: argparse.Namespace, local_output_keys: set[str]) -> bool:
    """Return true when this invocation should try to stage BEP artifacts."""
    del local_output_keys
    return _artifact_staging_requested(args)


def _artifact_staging_dir(args: argparse.Namespace, workspace: Path) -> Path:
    """Resolve the staging base for BEP artifact materialization."""
    raw = args.artifact_staging_dir or ".topt/bep-artifacts"
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = workspace / path
    return path.resolve()


def _selected_bep_artifact_outputs(
    freshness: BepFreshness,
    workspace: Path,
    remote_artifacts: str,
) -> set[tuple[str, str]]:
    """Return BEP artifact output keys selected for materialization."""
    del workspace
    selected: set[tuple[str, str]] = set()
    for ref in freshness.artifact_references:
        if ref.cached or not ref.fetch_is_stageable_carrier or not ref.output_key:
            continue
        if ref.remote_only and remote_artifacts == "disabled":
            continue
        selected.add((ref.label, ref.output_key))
    return selected


def _blocked_bep_artifact_labels(freshness: BepFreshness, remote_artifacts: str) -> set[str]:
    """Return labels whose no-key BEP artifact refs must not fall back to local outputs."""
    if remote_artifacts != "download":
        return set()
    return {
        ref.label
        for ref in freshness.artifact_references
        if not ref.cached and ref.is_test_outputs_hint and not ref.output_key
    }


def _apply_staged_bep_artifacts_to_freshness(
    freshness: BepFreshness,
    staged: list[StagedBepArtifact],
) -> None:
    """Merge successfully staged artifacts into BEP freshness state."""
    staged_pairs = {(item.label, item.output_key) for item in staged}
    conflicting = staged_pairs.intersection(freshness.cached_outputs)
    if conflicting:
        label, output_key = sorted(conflicting)[0]
        _fail(
            "BEP freshness is ambiguous after staging: the same test output is both "
            f"fresh and cached: {label} {output_key}"
        )
    freshness.eligible_outputs.update(staged_pairs)
    if staged_pairs:
        freshness.remote_only_outputs = [
            remote
            for remote in freshness.remote_only_outputs
            if (remote.label, remote.output_key) not in staged_pairs
        ]


def _merge_staged_output_dirs(
    output_dirs: list[Path],
    staged: list[StagedBepArtifact],
    selected_bep_artifact_outputs: set[tuple[str, str]],
    blocked_bep_artifact_labels: set[str],
    target_by_output_dir: dict[Path, str],
    testlogs_dir: Path | None,
) -> tuple[list[Path], dict[Path, str]]:
    """Prefer staged BEP outputs and suppress selected stale local fallbacks."""
    selected_keys = {output_key for _, output_key in selected_bep_artifact_outputs}
    merged_output_dirs: list[Path] = []
    merged_target_by_output_dir = dict(target_by_output_dir)
    for output_dir in output_dirs:
        if _local_test_output_key(output_dir, testlogs_dir=testlogs_dir) in selected_keys:
            merged_target_by_output_dir.pop(output_dir.resolve(), None)
            continue
        if _output_dir_target_label(output_dir, merged_target_by_output_dir) in blocked_bep_artifact_labels:
            merged_target_by_output_dir.pop(output_dir.resolve(), None)
            continue
        merged_output_dirs.append(output_dir)
    for item in staged:
        merged_output_dirs.append(item.output_dir)
        merged_target_by_output_dir[item.output_dir.resolve()] = item.label
    return merged_output_dirs, merged_target_by_output_dir


def _output_dir_target_label(output_dir: Path, target_by_output_dir: dict[Path, str]) -> str | None:
    """Return the Bazel target label associated with a test.outputs directory."""
    fallback = target_by_output_dir.get(output_dir.resolve())
    for metadata_file in _metadata_files(output_dir):
        metadata = _load_json(metadata_file)
        if isinstance(metadata, dict):
            return _metadata_target_label(metadata, fallback)
    return fallback


def _parse_bep_freshness(
    bep_files: list[Path],
    *,
    unavailable_is_error: bool = True,
) -> BepFreshness | None:
    """Parse BEP JSON files and return concrete fresh/cached output mappings."""
    eligible_outputs: set[tuple[str, str]] = set()
    cached_outputs: set[tuple[str, str]] = set()
    remote_only_outputs: list[BepRemoteOnlyOutput] = []
    missing_output_mappings: set[str] = set()
    artifact_references: list[BepArtifactReference] = []

    for bep_file in bep_files:
        if not bep_file.is_file():
            if not unavailable_is_error:
                _warn(
                    f"BEP JSON file not found: {bep_file}; skipping BEP freshness "
                    "validation and preserving historical local output validation"
                )
                return None
            _fail(f"BEP JSON file not found: {bep_file}")
        try:
            lines = bep_file.read_text(encoding="utf-8-sig").splitlines()
        except OSError as exc:
            if not unavailable_is_error:
                _warn(
                    f"failed to read BEP JSON file {bep_file}: {exc}; skipping BEP "
                    "freshness validation and preserving historical local output validation"
                )
                return None
            _fail(f"failed to read BEP JSON file {bep_file}: {exc}")

        for line_number, raw_line in enumerate(lines, start=1):
            if not raw_line.strip():
                continue
            try:
                event = json.loads(raw_line)
            except json.JSONDecodeError as exc:
                if not unavailable_is_error:
                    _warn(
                        f"invalid BEP JSON in {bep_file}:{line_number}: {exc}; skipping "
                        "BEP freshness validation and preserving historical local output validation"
                    )
                    return None
                _fail(f"invalid BEP JSON in {bep_file}:{line_number}: {exc}")
            event_id = event.get("id") if isinstance(event, dict) else {}
            test_result_id = _coalesced_field(event_id, "testResult", "test_result", {})
            if not isinstance(test_result_id, dict):
                continue
            label = test_result_id.get("label")
            if not isinstance(label, str) or not label:
                continue

            result = _coalesced_field(event, "testResult", "test_result", {})
            if not isinstance(result, dict):
                continue
            cached_locally = bool(_coalesced_field(result, "cachedLocally", "cached_locally", False))
            execution_info = _coalesced_field(result, "executionInfo", "execution_info", {})
            cached_remotely = bool(
                _coalesced_field(execution_info, "cachedRemotely", "cached_remotely", False)
            )
            outputs = _coalesced_field(result, "testActionOutput", "test_action_output", [])
            mapped_any = False
            remote_any = False
            event_fresh_pairs: set[tuple[str, str]] = set()
            event_cached_pairs: set[tuple[str, str]] = set()
            remote_only_candidates: list[tuple[list[str], bool, str]] = []
            for output in outputs if isinstance(outputs, list) else []:
                output_candidates = _bep_file_reference_candidates(output)
                canonical_candidates = _bep_canonical_output_key_candidates(output, output_candidates)
                output_keys = [
                    key
                    for key in (_bep_test_output_key(candidate) for candidate in canonical_candidates)
                    if key
                ]
                output_key = output_keys[0] if output_keys else ""
                output_mapped_any = False
                output_has_test_outputs_hint = False
                output_has_stageable_carrier_hint = _bep_stageable_artifact_carrier_hint(
                    output, output_candidates
                )
                output_remote_candidates: list[str] = []
                if output_key:
                    mapped_any = True
                    output_mapped_any = True
                    pair = (label, output_key)
                    if cached_locally or cached_remotely:
                        event_cached_pairs.add(pair)
                    else:
                        event_fresh_pairs.add(pair)
                for candidate in output_candidates:
                    if _bep_test_outputs_artifact_hint(candidate):
                        output_has_test_outputs_hint = True
                    if not (cached_locally or cached_remotely) and _is_remote_only_bep_reference(candidate):
                        output_remote_candidates.append(candidate)
                fetch_value = _bep_artifact_fetch_value(output, output_candidates)
                fetch_is_remote_only = _is_remote_only_bep_reference(fetch_value)
                artifact_references.append(
                    BepArtifactReference(
                        label=label,
                        uri=output.get("uri", "") if isinstance(output, dict) and isinstance(output.get("uri"), str) else "",
                        name=output.get("name", "") if isinstance(output, dict) and isinstance(output.get("name"), str) else "",
                        path=output.get("path", "") if isinstance(output, dict) and isinstance(output.get("path"), str) else "",
                        candidates=output_candidates,
                        fetch_value=fetch_value,
                        output_key=output_key,
                        cached=bool(cached_locally or cached_remotely),
                        remote_only=fetch_is_remote_only,
                        is_test_outputs_hint=output_has_test_outputs_hint,
                        fetch_is_stageable_carrier=(
                            output_has_stageable_carrier_hint
                            and (not fetch_is_remote_only or bool(output_key))
                        ),
                    )
                )
                if output_remote_candidates and not (cached_locally or cached_remotely):
                    remote_only_candidates.append((
                        output_remote_candidates,
                        output_has_test_outputs_hint,
                        output_key,
                    ))

            for candidates, has_test_outputs_hint, output_key in remote_only_candidates:
                if not has_test_outputs_hint and mapped_any:
                    continue
                for candidate in candidates:
                    remote_any = True
                    remote_only_outputs.append(
                        BepRemoteOnlyOutput(
                            label=label,
                            output_key=output_key,
                            artifact=candidate,
                            reason="remote_only",
                        )
                    )

            cached_outputs.update(event_cached_pairs)
            if not remote_any:
                eligible_outputs.update(event_fresh_pairs)

            if not mapped_any and not remote_any and not (cached_locally or cached_remotely):
                missing_output_mappings.add(label)

    conflicting_outputs = eligible_outputs.intersection(cached_outputs)
    if conflicting_outputs:
        label, output_key = sorted(conflicting_outputs)[0]
        _fail(
            "BEP freshness is ambiguous: the same test output is reported as both "
            f"fresh and cached: {label} {output_key}. Use one BEP file per Bazel test "
            "invocation and do not pass overlapping stale BEP files."
        )

    return BepFreshness(
        eligible_outputs=eligible_outputs,
        cached_outputs=cached_outputs,
        remote_only_outputs=remote_only_outputs,
        missing_output_mappings=missing_output_mappings,
        artifact_references=artifact_references,
    )


def _local_test_output_key(output_dir: Path, *, testlogs_dir: Path | None = None) -> str:
    """Return a stable bazel-testlogs-relative key for a local test.outputs directory."""
    if testlogs_dir is not None:
        try:
            relative = output_dir.resolve().relative_to(testlogs_dir.resolve())
        except ValueError:
            pass
        else:
            return _bep_test_output_key(str(relative))
    return _bep_test_output_key(str(output_dir))


def _local_output_matches_bep_key(output_dir: Path, bep_key: str) -> bool:
    """Return true when a local test.outputs path corresponds to one BEP key."""
    output_path = str(output_dir).replace("\\", "/").rstrip("/")
    return output_path.endswith("/" + bep_key.rstrip("/")) or output_path == bep_key.rstrip("/")


def _validate_expected_target_bep_freshness(
    output_dirs: list[Path],
    expected_targets: set[str],
    freshness: BepFreshness,
    *,
    required: bool,
    output_key_by_output_dir: dict[Path, str] | None = None,
    label_by_output_dir: dict[Path, str] | None = None,
) -> list[Path]:
    """Return expected target output dirs proven fresh by matching BEP TestResult outputs."""
    if not required:
        return output_dirs
    output_key_by_output_dir = output_key_by_output_dir or {}
    label_by_output_dir = label_by_output_dir or {}
    for remote in freshness.remote_only_outputs:
        if not expected_targets or remote.label in expected_targets:
            _fail(
                "BEP references remote-only test outputs for "
                f"{remote.label}: {_display_artifact_reference(remote.artifact)}. Rerun bazel test with "
                f"--build_event_json_file and {REMOTE_TEST_OUTPUT_DOWNLOAD_HINT}"
            )

    fresh_output_dirs = []
    fresh_labels = set()
    for output_dir in output_dirs:
        explicit_output_key = output_key_by_output_dir.get(output_dir.resolve())
        candidate_labels = {
            candidate_label
            for candidate_label, candidate_key in freshness.eligible_outputs
            if (
                explicit_output_key == candidate_key
                if explicit_output_key
                else _local_output_matches_bep_key(output_dir, candidate_key)
            )
        }
        if not candidate_labels:
            continue
        metadata_files = _metadata_files(output_dir)
        label = ""
        if not metadata_files:
            _fail(
                f"BEP required freshness cannot authorize {output_dir} because "
                "bazel_target_metadata.json is missing."
            )
        metadata = _load_json(metadata_files[0])
        if isinstance(metadata, dict):
            label = _metadata_target_label(metadata, None) or ""
        label = label_by_output_dir.get(output_dir.resolve(), label)
        if not label:
            _fail(
                f"BEP required freshness cannot authorize {output_dir} because "
                "bazel_target_metadata.json does not contain bazel.target."
            )
        matched = label in candidate_labels
        if matched:
            fresh_output_dirs.append(output_dir)
            fresh_labels.add(label)

    missing_labels = expected_targets - fresh_labels
    if missing_labels:
        missing_label = sorted(missing_labels)[0]
        if missing_label in freshness.missing_output_mappings:
            reason = "the fresh TestResult did not contain a mappable test.outputs reference"
        elif any(label == missing_label for label, _ in freshness.cached_outputs):
            reason = "BEP reported only cached results for this target"
        else:
            reason = "no fresh BEP TestResult matched this target's local test.outputs"
        _fail(
            f"expected target output is not fresh in BEP: {missing_label} ({reason}). "
            f"Rerun bazel test with --build_event_json_file and {REMOTE_TEST_OUTPUT_DOWNLOAD_HINT} "
            "then rerun the doctor with --bep-json and --freshness-source=bep "
            "--freshness-mode=required."
        )

    return fresh_output_dirs


def _validate_discovered_bep_freshness(
    output_dirs: list[Path],
    freshness: BepFreshness,
    *,
    required: bool,
    output_key_by_output_dir: dict[Path, str] | None = None,
    label_by_output_dir: dict[Path, str] | None = None,
) -> list[Path]:
    """Return discovered output dirs proven fresh by matching BEP TestResult outputs."""
    if not required:
        return output_dirs
    output_key_by_output_dir = output_key_by_output_dir or {}
    label_by_output_dir = label_by_output_dir or {}

    local_labels: set[str] = set()
    for output_dir in output_dirs:
        explicit_label = label_by_output_dir.get(output_dir.resolve())
        if explicit_label:
            local_labels.add(explicit_label)
            continue
        for metadata_file in _metadata_files(output_dir):
            metadata = _load_json(metadata_file)
            if isinstance(metadata, dict):
                label = _metadata_target_label(metadata, None)
                if label:
                    local_labels.add(label)

    for remote in freshness.remote_only_outputs:
        if remote.label in local_labels:
            _fail(
                "BEP references remote-only test outputs for "
                f"{remote.label}: {_display_artifact_reference(remote.artifact)}. Rerun bazel test with "
                f"--build_event_json_file and {REMOTE_TEST_OUTPUT_DOWNLOAD_HINT}"
            )

    missing_local_labels = sorted(local_labels.intersection(freshness.missing_output_mappings))
    if missing_local_labels:
        _fail(
            "BEP required freshness cannot authorize discovered Test Optimization output "
            f"for {missing_local_labels[0]} because the fresh TestResult did not contain "
            "a mappable test.outputs reference. Rerun bazel test with "
            f"--build_event_json_file and {REMOTE_TEST_OUTPUT_DOWNLOAD_HINT}"
        )

    fresh_output_dirs = []
    for output_dir in output_dirs:
        explicit_output_key = output_key_by_output_dir.get(output_dir.resolve())
        candidate_labels = {
            candidate_label
            for candidate_label, candidate_key in freshness.eligible_outputs
            if (
                explicit_output_key == candidate_key
                if explicit_output_key
                else _local_output_matches_bep_key(output_dir, candidate_key)
            )
        }
        if not candidate_labels:
            continue
        metadata_files = _metadata_files(output_dir)
        if not metadata_files:
            _fail(
                f"BEP required freshness cannot authorize {output_dir} because "
                "bazel_target_metadata.json is missing."
            )
        metadata = _load_json(metadata_files[0])
        label = _metadata_target_label(metadata, None) if isinstance(metadata, dict) else None
        label = label_by_output_dir.get(output_dir.resolve(), label)
        if not label:
            _fail(
                f"BEP required freshness cannot authorize {output_dir} because "
                "bazel_target_metadata.json does not contain bazel.target."
            )
        if label in candidate_labels:
            fresh_output_dirs.append(output_dir)

    if not fresh_output_dirs:
        cached_local_labels = {
            label
            for label, _ in freshness.cached_outputs
            if label in local_labels
        }
        if cached_local_labels:
            reason = f"BEP reported only cached results for {sorted(cached_local_labels)[0]}"
        else:
            reason = "no fresh BEP TestResult matched local test.outputs"
        _fail(
            "BEP required freshness did not authorize any discovered Test Optimization "
            f"output directories ({reason}). Rerun bazel test with --build_event_json_file "
            f"and {REMOTE_TEST_OUTPUT_DOWNLOAD_HINT} then rerun the doctor with --bep-json "
            "and --freshness-source=bep --freshness-mode=required."
        )

    return fresh_output_dirs


def _discover_output_dirs(testlogs_dir: Path) -> list[Path]:
    return sorted(path for path in testlogs_dir.rglob("test.outputs") if path.is_dir())


def _discover_candidate_output_dirs(testlogs_dir: Path) -> list[Path]:
    """Return output dirs that appear to belong to Test Optimization targets.

    Global discovery intentionally ignores plain Bazel tests that never produced
    Datadog payloads or Bazel target metadata. Consumers can use
    expected_targets when they need strict validation for a known set of tests.
    """
    return [
        output_dir
        for output_dir in _discover_output_dirs(testlogs_dir)
        if _payload_files(output_dir) or _msgpack_payload_files(output_dir) or _metadata_files(output_dir)
    ]


def _payload_files(output_dir: Path) -> list[Path]:
    payload_root = output_dir / "payloads"
    if not payload_root.exists():
        return []
    return sorted(path for path in payload_root.rglob("*.json") if path.is_file())


def _msgpack_payload_files(output_dir: Path) -> list[Path]:
    """Return raw msgpack payload files emitted under a Bazel test output tree."""
    payload_root = output_dir / "payloads"
    if not payload_root.exists():
        return []
    files = []
    for pattern in ("*.msgpack", "*.msgpack.gz"):
        files.extend(path for path in payload_root.rglob(pattern) if path.is_file())
    return sorted(files)


def _metadata_files(output_dir: Path) -> list[Path]:
    return sorted(path for path in output_dir.rglob("bazel_target_metadata.json") if path.is_file())


def _load_contexts(context_manifest: Path) -> list[tuple[str, Path]]:
    contexts: list[tuple[str, Path]] = []
    if not context_manifest.exists():
        return contexts
    for raw_line in context_manifest.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t")
        if len(parts) != 3:
            _fail(f"invalid context manifest line in {context_manifest}: {raw_line!r}")
        repo_key, short_path, direct_path = parts
        contexts.append((repo_key, _resolve_runfile_path([direct_path, short_path])))
    return contexts


def _resolve_configured_context_manifest(config: dict[str, Any], config_path: Path) -> Path:
    """Resolve the context manifest path recorded in a generated doctor config.

    On Windows, `bazel run` may execute the generated launcher without runfiles
    environment variables. The generated config and context manifest are sibling
    files in Bazel's output tree, so the sibling fallback keeps the doctor
    usable even when Bazel does not provide RUNFILES_MANIFEST_FILE.
    """
    raw_paths = [
        config["context_manifest_path"],
        config.get("context_manifest_short_path", ""),
    ]
    resolved = _resolve_runfile_path(raw_paths)
    if resolved.is_file():
        return resolved

    for raw in raw_paths:
        if not raw:
            continue
        sibling = config_path.parent / Path(raw).name
        if sibling.is_file():
            return sibling.resolve()

    return resolved


def _validate_git_metadata(context_manifest: Path) -> None:
    contexts = _load_contexts(context_manifest)
    if not contexts:
        _fail("require_git_metadata=True but no context.json was provided in data")
    for repo_key, context_path in contexts:
        ctx = _load_json(context_path)
        missing = []
        if not ctx.get("git.repository_url"):
            missing.append("git.repository_url")
        if not ctx.get("git.commit.sha"):
            missing.append("git.commit.sha")
        if not (ctx.get("git.branch") or ctx.get("git.tag")):
            missing.append("git.branch or git.tag")
        if missing:
            _fail(f"context {repo_key} is missing required git metadata: {', '.join(missing)}")


def _validate_bazelrc(workspace: Path) -> None:
    candidates = []
    candidates.extend(workspace.glob(".bazelrc*"))
    tools_bazelrc = workspace / "tools" / "bazelrc"
    if tools_bazelrc.exists():
        candidates.extend(tools_bazelrc.glob("*.bazelrc"))
    for path in sorted(set(candidates)):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), start=1):
            active_line = line.split("#", 1)[0]
            match = FORBIDDEN_TEST_ENV_RE.search(active_line)
            if match:
                _fail(
                    f"{path}:{line_number} sets {match.group(1)} with --test_env; "
                    "use --repo_env for sync metadata and pass upload credentials only to the uploader runtime"
                )


def _validate_outputs(
    output_dirs: list[Path],
    require_json_payloads: bool,
    require_bazel_metadata: bool,
    forbid_full_bundle_no_match: bool,
    forbid_msgpack_payloads: bool,
    allowed_payload_selections: set[str] | None = None,
    expected_payload_selection_by_target: dict[str, str] | None = None,
    target_by_output_dir: dict[Path, str] | None = None,
) -> dict[str, int]:
    """Validate local test.outputs payloads and return payload-selection counts."""
    allowed_selections = _effective_allowed_payload_selections(
        allowed_payload_selections,
        forbid_full_bundle_no_match,
    )
    expected_selections = expected_payload_selection_by_target or {}
    target_lookup = target_by_output_dir or {}
    _validate_expected_payload_selection_values(expected_selections)

    payload_count = 0
    metadata_count = 0
    selection_summary: dict[str, int] = {}
    for output_dir in output_dirs:
        payloads = _payload_files(output_dir)
        msgpack_payloads = _msgpack_payload_files(output_dir)
        metadata = _metadata_files(output_dir)
        payload_count += len(payloads)
        metadata_count += len(metadata)

        if forbid_msgpack_payloads and msgpack_payloads:
            formatted = ", ".join(str(path) for path in msgpack_payloads)
            _fail(
                f"raw msgpack payloads are not supported in Bazel file mode under {output_dir}: "
                f"{formatted}. Tests must write JSON payloads to TEST_UNDECLARED_OUTPUTS_DIR; "
                "check the dd-trace-go version and Go/Orchestrion Bazel environment."
            )
        if require_json_payloads and not payloads:
            _fail(f"missing JSON payloads under {output_dir}")
        for payload in payloads:
            _load_json(payload)

        if require_bazel_metadata and not metadata:
            _fail(f"missing bazel_target_metadata.json under {output_dir}")
        for metadata_file in metadata:
            doc = _load_json(metadata_file)
            selection = doc.get("bazel.go.payload_selection")
            if selection is not None and selection not in VALID_GO_PAYLOAD_SELECTIONS:
                _fail(
                    f"{metadata_file} has unsupported bazel.go.payload_selection={selection!r}; "
                    f"expected one of: {VALID_GO_PAYLOAD_SELECTIONS_TEXT}"
                )
            if selection is not None and selection not in allowed_selections:
                _fail(
                    f"{metadata_file} has bazel.go.payload_selection={selection!r}; "
                    f"allowed values for this doctor target are: {', '.join(sorted(allowed_selections))}"
                )
            if selection is not None:
                selection_summary[selection] = selection_summary.get(selection, 0) + 1

            target_label = _metadata_target_label(doc, target_lookup.get(output_dir.resolve()))
            if target_label and target_label in expected_selections:
                expected = expected_selections[target_label]
                if selection != expected:
                    _fail(
                        f"{metadata_file} has bazel.go.payload_selection={selection!r} for "
                        f"{target_label}; expected {expected!r}"
                    )

    if require_json_payloads and payload_count == 0:
        _fail("no JSON payload files were found under selected test.outputs directories")
    if require_bazel_metadata and metadata_count == 0:
        _fail("no bazel_target_metadata.json files were found under selected test.outputs directories")
    return selection_summary


def _effective_allowed_payload_selections(
    configured: set[str] | None,
    forbid_full_bundle_no_match: bool,
) -> set[str]:
    """Return the payload-selection allowlist enforced by the doctor."""
    allowed = set(configured or DEFAULT_ALLOWED_GO_PAYLOAD_SELECTIONS)
    invalid = sorted(allowed - VALID_GO_PAYLOAD_SELECTIONS)
    if invalid:
        _fail(
            "allowed_payload_selections contains unsupported value(s): "
            f"{', '.join(invalid)}; expected one of: {VALID_GO_PAYLOAD_SELECTIONS_TEXT}"
        )
    if not configured and not forbid_full_bundle_no_match:
        allowed.add("full_bundle_no_match")
    if forbid_full_bundle_no_match and "full_bundle_no_match" in allowed:
        _fail(
            "allowed_payload_selections includes full_bundle_no_match while "
            "forbid_full_bundle_no_match=True"
        )
    return allowed


def _validate_expected_payload_selection_values(expected_selections: dict[str, str]) -> None:
    """Validate target-specific payload-selection expectations."""
    for target, selection in expected_selections.items():
        if selection not in VALID_GO_PAYLOAD_SELECTIONS:
            _fail(
                f"expected_payload_selection_by_target[{target!r}] has unsupported value "
                f"{selection!r}; expected one of: {VALID_GO_PAYLOAD_SELECTIONS_TEXT}"
            )


def _metadata_target_label(doc: dict[str, Any], fallback: str | None) -> str | None:
    """Return the Bazel target label recorded in metadata, or the expected-target fallback."""
    target = doc.get("bazel.target")
    if isinstance(target, str) and target:
        return target
    return fallback


def _format_selection_summary(summary: dict[str, int]) -> str:
    """Format a deterministic payload-selection summary for human-readable doctor output."""
    if not summary:
        return "none"
    return ", ".join(f"{selection}={summary[selection]}" for selection in sorted(summary))


def _sorted_pairs(pairs: Iterable[tuple[str, str]]) -> list[list[str]]:
    """Return deterministic JSON-friendly label/output-key pairs."""
    return [[label, output_key] for label, output_key in sorted(pairs)]


def _set_report_result(
    report: dict[str, Any],
    *,
    status: str,
    reason_code: str,
    reason: str,
    next_steps: list[str] | None = None,
) -> None:
    """Set the report's customer-facing result block."""
    report["result"] = {
        "status": status,
        "reason_code": reason_code,
        "reason": reason,
        "next_steps": list(next_steps or []),
    }


def _target_labels_from_pairs(pairs: set[tuple[str, str]]) -> list[str]:
    """Return deterministic labels from BEP `(label, output_key)` pairs."""
    return sorted({label for label, _ in pairs})


def _new_diagnostic_report(args: argparse.Namespace) -> dict[str, Any]:
    """Create the base machine-readable doctor report."""
    return {
        "schema_version": 1,
        "tool": "dd-test-optimization-doctor",
        "status": "running",
        "result": {
            "status": "running",
            "reason_code": "running",
            "reason": "Doctor validation is still running.",
            "next_steps": [],
        },
        "config": {
            "config_path": "",
            "workspace": "",
            "testlogs_dir": "",
            "expected_targets": [],
            "freshness_source": args.freshness_source,
            "freshness_mode": args.freshness_mode,
            "artifact_source": args.artifact_source,
            "remote_artifacts": args.remote_artifacts,
        },
        "bep": {
            "files": [],
            "seen_targets": [],
            "eligible_outputs": 0,
            "eligible_output_keys": [],
            "cached_outputs": 0,
            "cached_output_keys": [],
            "remote_only_outputs": [],
            "missing_output_mappings": [],
            "artifact_references": 0,
            "selected_artifact_outputs": [],
            "blocked_artifact_labels": [],
        },
        "artifacts": {
            "staging_requested": False,
            "staging_enabled": False,
            "staging_dir": "",
            "staged_count": 0,
            "staged": [],
        },
        "targets": {
            "expected": [],
            "seen_in_bep": [],
            "fresh": [],
            "cached": [],
            "missing": [],
            "remote_only": [],
        },
        "outputs": [],
        "summary": {
            "expected_targets": 0,
            "validated_output_dirs": 0,
            "upload_candidates": 0,
            "payloads": {
                "json": 0,
                "msgpack": 0,
                "tests": 0,
                "coverage": 0,
                "telemetry": 0,
            },
            "metadata_files": 0,
            "payload_selection": {},
        },
        "errors": [],
        "warnings": [],
    }


def _diagnostic_payload_counts(output_dir: Path) -> dict[str, int]:
    """Return payload file counts used by the machine-readable report."""
    payload_root = output_dir / "payloads"
    payloads = _payload_files(output_dir)
    counts = {
        "json": len(payloads),
        "msgpack": len(_msgpack_payload_files(output_dir)),
        "tests": 0,
        "coverage": 0,
        "telemetry": 0,
    }
    for payload in payloads:
        try:
            relative = payload.relative_to(payload_root)
        except ValueError:
            continue
        if relative.parts:
            bucket = relative.parts[0]
            if bucket in {"tests", "coverage", "telemetry"}:
                counts[bucket] += 1
    return counts


def _read_json_for_report(path: Path) -> Any:
    """Best-effort JSON loader for diagnostics that must not change validation."""
    try:
        with path.open("r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def _diagnostic_metadata(output_dir: Path, fallback_label: str | None) -> dict[str, Any]:
    """Return Bazel metadata details for one output directory without failing validation."""
    metadata_files = _metadata_files(output_dir)
    metadata = {
        "count": len(metadata_files),
        "files": [str(path) for path in metadata_files],
        "target": fallback_label or "",
        "payload_selection": "",
    }
    for metadata_file in metadata_files:
        doc = _read_json_for_report(metadata_file)
        if not isinstance(doc, dict):
            continue
        target = _metadata_target_label(doc, fallback_label)
        if target:
            metadata["target"] = target
        selection = doc.get("bazel.go.payload_selection")
        if isinstance(selection, str):
            metadata["payload_selection"] = selection
        break
    return metadata


def _diagnostic_output_entries(
    output_dirs: list[Path],
    *,
    target_by_output_dir: dict[Path, str],
    staged: list[StagedBepArtifact],
    testlogs_dir: Path | None,
) -> list[dict[str, Any]]:
    """Build report entries for local and staged test output directories."""
    staged_by_dir = {item.output_dir.resolve(): item for item in staged}
    entries = []
    for output_dir in output_dirs:
        resolved = output_dir.resolve()
        staged_item = staged_by_dir.get(resolved)
        fallback_label = target_by_output_dir.get(resolved)
        metadata = _diagnostic_metadata(output_dir, fallback_label)
        label = metadata.get("target") or fallback_label or ""
        output_key = staged_item.output_key if staged_item is not None else _local_test_output_key(
            output_dir,
            testlogs_dir=testlogs_dir,
        )
        payloads = _diagnostic_payload_counts(output_dir)
        entries.append(
            {
                "path": str(resolved),
                "label": label,
                "source": "staged" if staged_item is not None else "local",
                "output_key": output_key,
                "payloads": payloads,
                "metadata": metadata,
                "upload_candidate": payloads["json"] > 0,
            }
        )
    return entries


def _update_diagnostic_output_summary(report: dict[str, Any], output_entries: list[dict[str, Any]]) -> None:
    """Update report summary counts from output entries."""
    payload_totals = {
        "json": 0,
        "msgpack": 0,
        "tests": 0,
        "coverage": 0,
        "telemetry": 0,
    }
    metadata_count = 0
    upload_candidates = 0
    for entry in output_entries:
        payloads = entry.get("payloads", {})
        for key in payload_totals:
            payload_totals[key] += int(payloads.get(key, 0))
        metadata = entry.get("metadata", {})
        metadata_count += int(metadata.get("count", 0))
        if entry.get("upload_candidate"):
            upload_candidates += 1
    report["outputs"] = output_entries
    report["summary"]["validated_output_dirs"] = len(output_entries)
    report["summary"]["upload_candidates"] = upload_candidates
    report["summary"]["payloads"] = payload_totals
    report["summary"]["metadata_files"] = metadata_count


def _update_diagnostic_config(
    report: dict[str, Any],
    *,
    config_path: Path,
    workspace: Path,
    testlogs_dir: Path | None,
    expected_targets: list[str],
    bep_files: list[Path],
    staging_requested: bool,
) -> None:
    """Record resolved runtime configuration in the report."""
    report["config"].update(
        {
            "config_path": str(config_path),
            "workspace": str(workspace),
            "testlogs_dir": str(testlogs_dir) if testlogs_dir is not None else "",
            "expected_targets": list(expected_targets),
        }
    )
    report["summary"]["expected_targets"] = len(expected_targets)
    report["bep"]["files"] = [str(path) for path in bep_files]
    report["artifacts"]["staging_requested"] = staging_requested
    report["targets"]["expected"] = list(expected_targets)


def _update_diagnostic_bep(
    report: dict[str, Any],
    freshness: BepFreshness | None,
    *,
    selected_bep_artifact_outputs: set[tuple[str, str]] | None = None,
    blocked_bep_artifact_labels: set[str] | None = None,
) -> None:
    """Record parsed BEP freshness and artifact-selection diagnostics."""
    if freshness is None:
        return
    seen_targets = {
        label
        for label, _ in freshness.eligible_outputs.union(freshness.cached_outputs)
    }
    seen_targets.update(item.label for item in freshness.remote_only_outputs)
    seen_targets.update(ref.label for ref in freshness.artifact_references)
    expected = set(report.get("targets", {}).get("expected", []))
    cached_labels = set(_target_labels_from_pairs(freshness.cached_outputs))
    fresh_labels = set(_target_labels_from_pairs(freshness.eligible_outputs))
    remote_only_labels = {item.label for item in freshness.remote_only_outputs}
    report["bep"].update(
        {
            "seen_targets": sorted(seen_targets),
            "eligible_outputs": len(freshness.eligible_outputs),
            "eligible_output_keys": _sorted_pairs(freshness.eligible_outputs),
            "cached_outputs": len(freshness.cached_outputs),
            "cached_output_keys": _sorted_pairs(freshness.cached_outputs),
            "remote_only_outputs": [
                {
                    "label": item.label,
                    "output_key": item.output_key,
                    "artifact": _display_artifact_reference(item.artifact),
                    "reason": item.reason,
                }
                for item in freshness.remote_only_outputs
            ],
            "missing_output_mappings": sorted(freshness.missing_output_mappings),
            "artifact_references": len(freshness.artifact_references),
            "selected_artifact_outputs": _sorted_pairs(selected_bep_artifact_outputs or set()),
            "blocked_artifact_labels": sorted(blocked_bep_artifact_labels or set()),
        }
    )
    report["targets"].update(
        {
            "seen_in_bep": sorted(seen_targets),
            "fresh": sorted(fresh_labels),
            "cached": sorted(cached_labels),
            "missing": sorted(expected.difference(seen_targets)),
            "remote_only": sorted(remote_only_labels),
        }
    )


def _diagnostic_staged_carrier(item: StagedBepArtifact) -> str:
    """Return a stable carrier type for staged BEP artifacts."""
    if item.downloaded:
        return "downloaded_outputs_zip"
    normalized = _strip_file_uri(item.fetch_value).replace("\\", "/").lower().rstrip("/")
    if normalized == "outputs.zip" or normalized.endswith("/outputs.zip"):
        return "outputs_zip"
    if normalized == "test.outputs" or normalized.endswith("/test.outputs"):
        return "test_outputs"
    return "unknown"


def _update_diagnostic_artifacts(
    report: dict[str, Any],
    *,
    staging_enabled: bool,
    staging_base: Path | None,
    staged: list[StagedBepArtifact],
) -> None:
    """Record BEP artifact staging diagnostics."""
    report["artifacts"].update(
        {
            "staging_enabled": staging_enabled,
            "staging_dir": str(staging_base) if staging_base is not None else "",
            "staged_count": len(staged),
            "staged": [
                {
                    "label": item.label,
                    "output_key": item.output_key,
                    "path": str(item.output_dir),
                    "downloaded": item.downloaded,
                    "remote_only": item.remote_only,
                    "fetch_value": _display_artifact_reference(item.fetch_value),
                    "carrier": _diagnostic_staged_carrier(item),
                }
                for item in staged
            ],
        }
    )


def _write_diagnostic_report(args: argparse.Namespace, report: dict[str, Any]) -> None:
    """Write the requested machine-readable doctor report."""
    if not args.report_json:
        return
    report_path = Path(args.report_json).expanduser()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _exit_code(exc: SystemExit) -> int:
    """Return a numeric code for SystemExit values."""
    if exc.code is None:
        return 0
    if isinstance(exc.code, int):
        return exc.code
    return 1


def _classify_diagnostic_failure(report: dict[str, Any], message: str) -> tuple[str, str, list[str]]:
    """Map known doctor failures to stable reason codes."""
    targets = report.get("targets", {})
    if (
        "BEP freshness validation is required but no BEP JSON file was configured" in message
        or "BEP freshness source was selected but no BEP JSON file was configured" in message
        or "--artifact-source=bep requires --bep-json" in message
    ):
        return (
            "missing_bep_json",
            "BEP freshness or artifact staging was required, but no BEP JSON was configured.",
            ["Pass --bep-json from the matching bazel test invocation."],
        )
    if targets.get("cached") and (
        "not fresh in BEP" in message
        or "did not authorize" in message
        or "only cached results" in message
    ):
        return (
            "target_cached_by_bazel",
            "Required BEP freshness rejected cached Bazel test outputs.",
            ["Run tests with --nocache_test_results or select targets that executed in this invocation."],
        )
    if targets.get("missing"):
        return (
            "expected_target_not_seen_in_bep",
            "At least one expected target was not present in the BEP file.",
            ["Use the BEP file produced by the same bazel test command that ran the expected target."],
        )
    if targets.get("remote_only") or "remote-only" in message:
        return (
            "bep_output_remote_only_without_downloader",
            "BEP selected remote-only outputs that could not be materialized locally.",
            [
                "Enable --remote-artifacts=download; configure --bep-artifact-downloader for non-HTTP remote providers or HTTP endpoints requiring custom auth."
            ],
        )
    if "no Test Optimization output directories found" in message:
        return (
            "no_test_outputs_found",
            "No local or staged test.outputs directories were found.",
            ["Use --artifact-source=bep with the matching --bep-json, or configure Bazel to materialize test outputs."],
        )
    if "outputs.zip" in message and "payload" in message and "json" in message.lower():
        return (
            "zip_contains_no_payloads",
            "outputs.zip was found, but it did not contain payload JSON files.",
            [
                "Inspect the archive for payloads/tests, payloads/coverage, or payloads/telemetry JSON files."
            ],
        )
    if "payload" in message and "json" in message.lower():
        return (
            "no_payload_json_found",
            "Test output directories were found, but no JSON payloads were available.",
            [
                "Inspect TEST_UNDECLARED_OUTPUTS_DIR and outputs.zip for payloads/tests, payloads/coverage, or payloads/telemetry files."
            ],
        )
    return (
        "doctor_failed",
        "Doctor validation failed before upload.",
        ["Inspect the doctor errors array and command logs."],
    )


def _record_diagnostic_failure(report: dict[str, Any], exc: BaseException) -> None:
    """Record a failure in the machine-readable report."""
    status = "fail"
    message = _LAST_FAILURE_MESSAGE or str(exc)
    if isinstance(exc, SystemExit):
        code = _exit_code(exc)
        if code == 0:
            status = "ok"
        report["exit_code"] = code
        if not message and code != 0:
            message = f"doctor exited with status {code}"
    else:
        status = "error"
        report["exit_code"] = 1
    report["status"] = status
    if message and status != "ok":
        report["errors"].append(message)
    if status == "ok":
        _set_report_result(
            report,
            status="ok",
            reason_code="ok",
            reason="Doctor validation succeeded.",
        )
    elif status == "error":
        _set_report_result(
            report,
            status="error",
            reason_code="doctor_failed",
            reason="Doctor validation failed with an unexpected error.",
            next_steps=["Inspect the doctor errors array and command logs."],
        )
    else:
        reason_code, reason, next_steps = _classify_diagnostic_failure(report, message)
        _set_report_result(
            report,
            status="fail",
            reason_code=reason_code,
            reason=reason,
            next_steps=next_steps,
        )


def main(argv: list[str]) -> int:
    global _LAST_FAILURE_MESSAGE
    _LAST_FAILURE_MESSAGE = None
    args = _parse_args(argv)
    report = _new_diagnostic_report(args)
    try:
        rc = _run_doctor(args, report)
    except SystemExit as exc:
        _record_diagnostic_failure(report, exc)
        _write_diagnostic_report(args, report)
        raise
    except Exception as exc:
        _record_diagnostic_failure(report, exc)
        _write_diagnostic_report(args, report)
        raise
    report["status"] = "ok" if rc == 0 else "fail"
    report["exit_code"] = rc
    if rc == 0:
        _set_report_result(
            report,
            status="ok",
            reason_code="ok",
            reason="Doctor validation succeeded.",
        )
    else:
        reason_code, reason, next_steps = _classify_diagnostic_failure(report, "")
        _set_report_result(
            report,
            status="fail",
            reason_code=reason_code,
            reason=reason,
            next_steps=next_steps,
        )
    _write_diagnostic_report(args, report)
    return rc


def _run_doctor(args: argparse.Namespace, report: dict[str, Any]) -> int:
    bep_files = _configured_bep_json_files(args)
    staging_requested = _artifact_staging_requested(args)
    if args.artifact_source == "bep" and not bep_files:
        _fail("--artifact-source=bep requires --bep-json or DD_TEST_OPTIMIZATION_BEP_JSON")
    strict_bep_required = args.freshness_mode == "required"
    if args.freshness_source == "execution_log" and strict_bep_required:
        _fail("doctor freshness validation only supports BEP; use --freshness-source=bep")

    config_path = Path(args.config).resolve()
    config = _load_json(config_path)
    execroot = _infer_bazel_execroot(config_path)
    if execroot is not None and not os.environ.get(DOCTOR_EXECROOT_ENV):
        os.environ[DOCTOR_EXECROOT_ENV] = str(execroot)

    workspace = _workspace_root()
    testlogs_dir = _resolve_testlogs_dir(workspace, allow_missing=staging_requested)

    if config["forbid_dd_git_test_env"]:
        _validate_bazelrc(workspace)
    if config["require_git_metadata"]:
        context_manifest = _resolve_configured_context_manifest(config, config_path)
        _validate_git_metadata(context_manifest)

    expected_targets = config["expected_targets"]
    _update_diagnostic_config(
        report,
        config_path=config_path,
        workspace=workspace,
        testlogs_dir=testlogs_dir,
        expected_targets=expected_targets,
        bep_files=bep_files,
        staging_requested=staging_requested,
    )
    staged: list[StagedBepArtifact] = []
    staging_base: Path | None = None
    output_dirs: list[Path]
    target_by_output_dir: dict[Path, str]
    freshness: BepFreshness | None = None

    try:
        if expected_targets:
            output_dirs = []
            target_by_output_dir = {}
            for label in expected_targets:
                target_output_dirs = _expected_target_outputs(
                    testlogs_dir,
                    label,
                    allow_missing=staging_requested,
                )
                output_dirs.extend(target_output_dirs)
                for output_dir in target_output_dirs:
                    target_by_output_dir[output_dir.resolve()] = label
        else:
            output_dirs = _discover_candidate_output_dirs(testlogs_dir) if testlogs_dir is not None else []
            target_by_output_dir = {}
            if not output_dirs and not staging_requested:
                _fail(f"no Test Optimization output directories found under {testlogs_dir}")

        local_output_keys = {_local_test_output_key(output_dir, testlogs_dir=testlogs_dir) for output_dir in output_dirs}
        staging_enabled = _artifact_staging_enabled(args, local_output_keys)
        if bep_files:
            if args.freshness_mode != "disabled" or staging_enabled:
                freshness = _parse_bep_freshness(
                    bep_files,
                    unavailable_is_error=staging_enabled or args.freshness_mode != "optional",
                )
                _update_diagnostic_bep(report, freshness)
        elif strict_bep_required:
            _fail(
                "BEP freshness validation is required but no BEP JSON file was configured. "
                "Run bazel test with --build_event_json_file=.topt/bazel-bep.json and rerun "
                "the doctor with --bep-json=.topt/bazel-bep.json --freshness-source=bep "
                "--freshness-mode=required."
            )
        elif args.freshness_source == "bep":
            print(
                "[dd-test-optimization-doctor] warning: BEP freshness source was selected but no "
                "BEP JSON file was configured; skipping BEP freshness validation",
                file=sys.stderr,
            )

        selected_bep_artifact_outputs: set[tuple[str, str]] = set()
        blocked_bep_artifact_labels: set[str] = set()
        _update_diagnostic_artifacts(
            report,
            staging_enabled=staging_enabled,
            staging_base=staging_base,
            staged=staged,
        )
        if staging_enabled and freshness is not None:
            selected_bep_artifact_outputs = _selected_bep_artifact_outputs(
                freshness,
                workspace,
                args.remote_artifacts,
            )
            blocked_bep_artifact_labels = _blocked_bep_artifact_labels(freshness, args.remote_artifacts)
            _update_diagnostic_bep(
                report,
                freshness,
                selected_bep_artifact_outputs=selected_bep_artifact_outputs,
                blocked_bep_artifact_labels=blocked_bep_artifact_labels,
            )
            staging_base = _artifact_staging_dir(args, workspace)
            staged = _stage_bep_artifacts(
                freshness,
                workspace=workspace,
                staging_dir=staging_base,
                remote_artifacts=args.remote_artifacts,
                downloader=args.bep_artifact_downloader,
                downloader_timeout_sec=args.bep_artifact_downloader_timeout_sec,
            )
            _apply_staged_bep_artifacts_to_freshness(freshness, staged)
            _update_diagnostic_bep(
                report,
                freshness,
                selected_bep_artifact_outputs=selected_bep_artifact_outputs,
                blocked_bep_artifact_labels=blocked_bep_artifact_labels,
            )
            _update_diagnostic_artifacts(
                report,
                staging_enabled=staging_enabled,
                staging_base=staging_base,
                staged=staged,
            )
            output_dirs, target_by_output_dir = _merge_staged_output_dirs(
                output_dirs,
                staged,
                selected_bep_artifact_outputs,
                blocked_bep_artifact_labels,
                target_by_output_dir,
                testlogs_dir,
            )

        if args.freshness_mode != "disabled" and freshness is not None:
            required = strict_bep_required or args.freshness_mode == "auto"
            output_key_by_output_dir = {item.output_dir.resolve(): item.output_key for item in staged}
            label_by_output_dir = {item.output_dir.resolve(): item.label for item in staged}
            if expected_targets:
                output_dirs = _validate_expected_target_bep_freshness(
                    output_dirs,
                    set(expected_targets),
                    freshness,
                    required=required,
                    output_key_by_output_dir=output_key_by_output_dir,
                    label_by_output_dir=label_by_output_dir,
                )
            else:
                output_dirs = _validate_discovered_bep_freshness(
                    output_dirs,
                    freshness,
                    required=required,
                    output_key_by_output_dir=output_key_by_output_dir,
                    label_by_output_dir=label_by_output_dir,
                )

        if not output_dirs:
            if expected_targets:
                _fail("no Test Optimization output directories found for expected targets after BEP artifact staging")
            missing_root = testlogs_dir if testlogs_dir is not None else workspace / "bazel-testlogs"
            _fail(f"no Test Optimization output directories found under {missing_root}")

        _update_diagnostic_output_summary(
            report,
            _diagnostic_output_entries(
                output_dirs,
                target_by_output_dir=target_by_output_dir,
                staged=staged,
                testlogs_dir=testlogs_dir,
            ),
        )
        allowed_payload_selections = set(config.get("allowed_payload_selections") or [])
        selection_summary = _validate_outputs(
            output_dirs,
            require_json_payloads=config["require_json_payloads"],
            require_bazel_metadata=config["require_bazel_metadata"],
            forbid_full_bundle_no_match=config["forbid_full_bundle_no_match"],
            forbid_msgpack_payloads=config.get("forbid_msgpack_payloads", True),
            allowed_payload_selections=allowed_payload_selections or None,
            expected_payload_selection_by_target=config.get("expected_payload_selection_by_target", {}),
            target_by_output_dir=target_by_output_dir,
        )
        report["summary"]["payload_selection"] = dict(sorted(selection_summary.items()))
        print(
            "[dd-test-optimization-doctor] payload selection summary: "
            f"{_format_selection_summary(selection_summary)}"
        )
        print(f"[dd-test-optimization-doctor] OK: validated {len(output_dirs)} test output directorie(s)")
        return 0
    finally:
        if staged and staging_base is not None:
            _cleanup_staged_bep_run_roots(staged, staging_base=staging_base)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
