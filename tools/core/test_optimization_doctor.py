#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Validate local Datadog Test Optimization Bazel outputs before upload."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.parse import unquote, urlparse


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


class BepRemoteOnlyOutput:
    """Fresh BEP output that is not available as a local file in phase 1."""

    def __init__(self, label: str, artifact: str, reason: str) -> None:
        self.label = label
        self.artifact = artifact
        self.reason = reason


class BepFreshness:
    """Parsed BEP freshness state used by doctor strict expected-target checks."""

    def __init__(
        self,
        eligible_outputs: set[tuple[str, str]],
        cached_outputs: set[tuple[str, str]],
        remote_only_outputs: list[BepRemoteOnlyOutput],
        missing_output_mappings: set[str],
    ) -> None:
        self.eligible_outputs = eligible_outputs
        self.cached_outputs = cached_outputs
        self.remote_only_outputs = remote_only_outputs
        self.missing_output_mappings = missing_output_mappings


def _fail(message: str) -> None:
    print(f"[dd-test-optimization-doctor] {message}", file=sys.stderr)
    raise SystemExit(1)


def _warn(message: str) -> None:
    print(f"[dd-test-optimization-doctor] warning: {message}", file=sys.stderr)


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except FileNotFoundError:
        _fail(f"missing JSON file: {path}")
    except json.JSONDecodeError as exc:
        _fail(f"invalid JSON in {path}: {exc}")


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
    return parser.parse_args(argv)


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


def _resolve_testlogs_dir(workspace: Path) -> Path:
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


def _expected_target_outputs(testlogs_dir: Path, label: str) -> list[Path]:
    """Return all test.outputs directories for one expected local target.

    Bazel can nest outputs under shard/retry directories, so strict expected
    targets discover recursively below the target root instead of assuming only
    `<pkg>/<target>/test.outputs`.
    """
    target_root = _expected_target_root(testlogs_dir, label)
    if not target_root.exists():
        _fail(_missing_expected_target_message(label, target_root, "output root"))
    output_dirs = _discover_output_dirs(target_root)
    if not output_dirs:
        _fail(_missing_expected_target_message(label, target_root, "test.outputs directory"))
    return output_dirs


def _missing_expected_target_message(label: str, target_root: Path, missing_part: str) -> str:
    """Return an actionable error for expected targets with no local outputs."""
    return (
        f"expected target {missing_part} not found for {label}: {target_root}. "
        "Run this exact instrumented test target before running the doctor. "
        "Do not list build-only, wrapper-only, or analysis-only targets in "
        "expected_targets. If tests ran with remote execution or remote cache, "
        "rerun them with --remote_download_outputs=all "
        "so Bazel downloads test.outputs locally."
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
            remote_only_candidates: list[tuple[list[str], bool]] = []
            for output in outputs if isinstance(outputs, list) else []:
                output_candidates = _bep_file_reference_candidates(output)
                output_mapped_any = False
                output_has_test_outputs_hint = False
                output_remote_candidates: list[str] = []
                for candidate in output_candidates:
                    output_key = _bep_test_output_key(candidate)
                    if output_key:
                        mapped_any = True
                        output_mapped_any = True
                        pair = (label, output_key)
                        if cached_locally or cached_remotely:
                            event_cached_pairs.add(pair)
                        else:
                            event_fresh_pairs.add(pair)
                    if _bep_test_outputs_artifact_hint(candidate):
                        output_has_test_outputs_hint = True
                    if not (cached_locally or cached_remotely) and _is_remote_only_bep_reference(candidate):
                        output_remote_candidates.append(candidate)
                if output_remote_candidates and not (cached_locally or cached_remotely):
                    remote_only_candidates.append((
                        output_remote_candidates,
                        output_has_test_outputs_hint,
                    ))

            for candidates, has_test_outputs_hint in remote_only_candidates:
                if not has_test_outputs_hint and mapped_any:
                    continue
                for candidate in candidates:
                    remote_any = True
                    remote_only_outputs.append(
                        BepRemoteOnlyOutput(label=label, artifact=candidate, reason="remote_only")
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
    )


def _local_test_output_key(output_dir: Path) -> str:
    """Return a stable bazel-testlogs-relative key for a local test.outputs directory."""
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
) -> list[Path]:
    """Return expected target output dirs proven fresh by matching BEP TestResult outputs."""
    if not required:
        return output_dirs
    for remote in freshness.remote_only_outputs:
        if not expected_targets or remote.label in expected_targets:
            _fail(
                "BEP references remote-only test outputs for "
                f"{remote.label}: {remote.artifact}. Rerun bazel test with "
                "--build_event_json_file and --remote_download_outputs=all before running the doctor."
            )

    fresh_output_dirs = []
    fresh_labels = set()
    for output_dir in output_dirs:
        candidate_labels = {
            candidate_label
            for candidate_label, candidate_key in freshness.eligible_outputs
            if _local_output_matches_bep_key(output_dir, candidate_key)
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
            "Rerun bazel test with --build_event_json_file and --remote_download_outputs=all, "
            "then rerun the doctor with --bep-json and --freshness-source=bep "
            "--freshness-mode=required."
        )

    return fresh_output_dirs


def _validate_discovered_bep_freshness(
    output_dirs: list[Path],
    freshness: BepFreshness,
    *,
    required: bool,
) -> list[Path]:
    """Return discovered output dirs proven fresh by matching BEP TestResult outputs."""
    if not required:
        return output_dirs

    local_labels: set[str] = set()
    for output_dir in output_dirs:
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
                f"{remote.label}: {remote.artifact}. Rerun bazel test with "
                "--build_event_json_file and --remote_download_outputs=all before running the doctor."
            )

    missing_local_labels = sorted(local_labels.intersection(freshness.missing_output_mappings))
    if missing_local_labels:
        _fail(
            "BEP required freshness cannot authorize discovered Test Optimization output "
            f"for {missing_local_labels[0]} because the fresh TestResult did not contain "
            "a mappable test.outputs reference. Rerun bazel test with "
            "--build_event_json_file and --remote_download_outputs=all before running the doctor."
        )

    fresh_output_dirs = []
    for output_dir in output_dirs:
        candidate_labels = {
            candidate_label
            for candidate_label, candidate_key in freshness.eligible_outputs
            if _local_output_matches_bep_key(output_dir, candidate_key)
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
            "and --remote_download_outputs=all, then rerun the doctor with --bep-json "
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


def main(argv: list[str]) -> int:
    args = _parse_args(argv)

    config_path = Path(args.config).resolve()
    config = _load_json(config_path)
    execroot = _infer_bazel_execroot(config_path)
    if execroot is not None and not os.environ.get(DOCTOR_EXECROOT_ENV):
        os.environ[DOCTOR_EXECROOT_ENV] = str(execroot)

    workspace = _workspace_root()
    testlogs_dir = _resolve_testlogs_dir(workspace)

    if config["forbid_dd_git_test_env"]:
        _validate_bazelrc(workspace)
    if config["require_git_metadata"]:
        context_manifest = _resolve_configured_context_manifest(config, config_path)
        _validate_git_metadata(context_manifest)

    expected_targets = config["expected_targets"]
    if expected_targets:
        output_dirs = []
        target_by_output_dir = {}
        for label in expected_targets:
            target_output_dirs = _expected_target_outputs(testlogs_dir, label)
            output_dirs.extend(target_output_dirs)
            for output_dir in target_output_dirs:
                target_by_output_dir[output_dir.resolve()] = label
    else:
        output_dirs = _discover_candidate_output_dirs(testlogs_dir)
        target_by_output_dir = {}
        if not output_dirs:
            _fail(f"no Test Optimization output directories found under {testlogs_dir}")

    if args.freshness_mode != "disabled":
        bep_files = _configured_bep_json_files(args)
        strict_bep_required = args.freshness_mode == "required"
        if args.freshness_source == "execution_log" and strict_bep_required:
            _fail("doctor freshness validation only supports BEP; use --freshness-source=bep")
        if bep_files:
            freshness = _parse_bep_freshness(
                bep_files,
                unavailable_is_error=args.freshness_mode != "optional",
            )
            if freshness is not None:
                required = strict_bep_required or args.freshness_mode == "auto"
                if expected_targets:
                    output_dirs = _validate_expected_target_bep_freshness(
                        output_dirs,
                        set(expected_targets),
                        freshness,
                        required=required,
                    )
                else:
                    output_dirs = _validate_discovered_bep_freshness(
                        output_dirs,
                        freshness,
                        required=required,
                    )
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
    print(
        "[dd-test-optimization-doctor] payload selection summary: "
        f"{_format_selection_summary(selection_summary)}"
    )
    print(f"[dd-test-optimization-doctor] OK: validated {len(output_dirs)} test output directorie(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
