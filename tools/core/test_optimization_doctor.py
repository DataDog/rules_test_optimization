#!/usr/bin/env python3
"""Validate local Datadog Test Optimization Bazel outputs before upload."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


DD_GIT_TEST_ENV_RE = re.compile(r"--test_env(?:=|\s+)DD_GIT_[A-Z0-9_]*")
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


def _fail(message: str) -> None:
    print(f"[dd-test-optimization-doctor] {message}", file=sys.stderr)
    raise SystemExit(1)


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except FileNotFoundError:
        _fail(f"missing JSON file: {path}")
    except json.JSONDecodeError as exc:
        _fail(f"invalid JSON in {path}: {exc}")


def _workspace_root() -> Path:
    return Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()).resolve()


def _runfile_candidate_strings(raw: str) -> list[str]:
    """Return path variants Bazel may use for the same runfile.

    External repository files can appear as `external/<repo>/...` from action
    paths, `<repo>/...` in directory runfiles, or `../<repo>/...` from short
    paths. The doctor accepts all of those forms so WORKSPACE and Bzlmod
    consumers do not need different target definitions.
    """
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
        "Run this exact test target before running the doctor. If the test ran with "
        "remote execution or remote cache, rerun it with --remote_download_outputs=all "
        "so Bazel downloads test.outputs locally."
    )


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
            if DD_GIT_TEST_ENV_RE.search(active_line):
                _fail(f"{path}:{line_number} sets DD_GIT_* with --test_env; use --repo_env instead")


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
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args(argv)

    config = _load_json(Path(args.config))
    workspace = _workspace_root()
    testlogs_dir = _resolve_testlogs_dir(workspace)

    if config["forbid_dd_git_test_env"]:
        _validate_bazelrc(workspace)
    if config["require_git_metadata"]:
        context_manifest = _resolve_runfile_path([
            config["context_manifest_path"],
            config.get("context_manifest_short_path", ""),
        ])
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
