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
VALID_GO_PAYLOAD_SELECTIONS = {"module", "full_bundle_disabled"}


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
        _fail(f"expected target output root not found for {label}: {target_root}")
    output_dirs = _discover_output_dirs(target_root)
    if not output_dirs:
        _fail(f"expected target output directory not found for {label}: {target_root}")
    return output_dirs


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
        if _payload_files(output_dir) or _metadata_files(output_dir)
    ]


def _payload_files(output_dir: Path) -> list[Path]:
    payload_root = output_dir / "payloads"
    if not payload_root.exists():
        return []
    return sorted(path for path in payload_root.rglob("*.json") if path.is_file())


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
        repo_key, _short_path, direct_path = parts
        contexts.append((repo_key, Path(direct_path)))
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


def _validate_outputs(output_dirs: list[Path], require_json_payloads: bool, require_bazel_metadata: bool, forbid_full_bundle_no_match: bool) -> None:
    payload_count = 0
    metadata_count = 0
    for output_dir in output_dirs:
        payloads = _payload_files(output_dir)
        metadata = _metadata_files(output_dir)
        payload_count += len(payloads)
        metadata_count += len(metadata)

        if require_json_payloads and not payloads:
            _fail(f"missing JSON payloads under {output_dir}")
        for payload in payloads:
            _load_json(payload)

        if require_bazel_metadata and not metadata:
            _fail(f"missing bazel_target_metadata.json under {output_dir}")
        for metadata_file in metadata:
            doc = _load_json(metadata_file)
            selection = doc.get("bazel.go.payload_selection")
            if forbid_full_bundle_no_match and selection == "full_bundle_no_match":
                _fail(f"{metadata_file} has bazel.go.payload_selection=full_bundle_no_match")
            if selection is not None and selection not in VALID_GO_PAYLOAD_SELECTIONS:
                _fail(
                    f"{metadata_file} has unsupported bazel.go.payload_selection={selection!r}; "
                    "expected 'module' or 'full_bundle_disabled'"
                )

    if require_json_payloads and payload_count == 0:
        _fail("no JSON payload files were found under selected test.outputs directories")
    if require_bazel_metadata and metadata_count == 0:
        _fail("no bazel_target_metadata.json files were found under selected test.outputs directories")


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
        _validate_git_metadata(Path(config["context_manifest_path"]))

    expected_targets = config["expected_targets"]
    if expected_targets:
        output_dirs = []
        for label in expected_targets:
            output_dirs.extend(_expected_target_outputs(testlogs_dir, label))
    else:
        output_dirs = _discover_candidate_output_dirs(testlogs_dir)
        if not output_dirs:
            _fail(f"no Test Optimization output directories found under {testlogs_dir}")

    _validate_outputs(
        output_dirs,
        require_json_payloads=config["require_json_payloads"],
        require_bazel_metadata=config["require_bazel_metadata"],
        forbid_full_bundle_no_match=config["forbid_full_bundle_no_match"],
    )
    print(f"[dd-test-optimization-doctor] OK: validated {len(output_dirs)} test output directorie(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
