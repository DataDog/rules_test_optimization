# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Resolve uploader test runfiles and expose the runtime package for imports.

One helper keeps direct, runfiles-tree, and manifest-only test startup consistent.
"""

from __future__ import annotations

import os
from pathlib import Path
import sys


def resolve_runfile(relative_path: str) -> Path:
    """Resolve one test dependency across local and Bazel runfiles layouts."""
    test_source_root = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    candidates: list[Path] = []
    if test_source_root and test_workspace:
        candidates.append(Path(test_source_root) / test_workspace / relative_path)
    if test_source_root:
        candidates.append(Path(test_source_root) / relative_path)
    if workspace:
        candidates.append(Path(workspace) / relative_path)

    test_directory = Path(__file__).resolve().parent
    for parent in (test_directory, *test_directory.parents):
        if (parent / "MODULE.bazel").exists() or (parent / ".git").exists():
            candidates.append(parent / relative_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()

    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).is_file():
        logical_paths = {relative_path}
        if test_workspace:
            logical_paths.add(f"{test_workspace}/{relative_path}")
        with Path(manifest_path).open("r", encoding="utf-8") as manifest:
            for line in manifest:
                logical_path, separator, physical_path = (
                    line.rstrip("\n").partition(" ")
                )
                if separator and logical_path in logical_paths and physical_path:
                    return Path(physical_path)
    raise FileNotFoundError(f"runfile not found: {relative_path}")


def add_uploader_runtime_to_path() -> Path:
    """Make the uploader package importable and return its core directory."""
    core_directory = resolve_runfile("tools/core/uploader_main.py").parent
    if str(core_directory) not in sys.path:
        sys.path.insert(0, str(core_directory))
    return core_directory
