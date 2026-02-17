#!/usr/bin/env python3
"""Verify module version alignment for core + Go companion.

This guard is intentionally lightweight so it can run in CI and local pre-release
checks without extra dependencies.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"unable to read {path}: {exc}") from exc


def _extract_module_version(path: Path) -> str:
    text = _read_text(path)
    module_block = re.search(r"module\(([\s\S]*?)\)", text)
    if module_block is None:
        raise ValueError(f"no module(...) declaration found in {path}")

    version_match = re.search(
        r'^\s*version\s*=\s*"([^"]+)"\s*,?\s*$',
        module_block.group(1),
        re.MULTILINE,
    )
    if version_match is None:
        raise ValueError(f'no module version = "..." found in {path}')

    return version_match.group(1)


def _extract_core_dep_version_from_go_module(path: Path) -> str:
    text = _read_text(path)
    for dep_block in re.finditer(r"bazel_dep\(([\s\S]*?)\)", text):
        block = dep_block.group(1)
        if re.search(r'name\s*=\s*"datadog-rules-test-optimization"', block):
            version_match = re.search(r'version\s*=\s*"([^"]+)"', block)
            if version_match is None:
                raise ValueError(
                    "go companion MODULE.bazel declares core dep without version"
                )
            return version_match.group(1)

    raise ValueError(
        "go companion MODULE.bazel is missing bazel_dep(name = "
        '"datadog-rules-test-optimization", ...)'
    )


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    core_module = repo_root / "MODULE.bazel"
    go_module = repo_root / "modules" / "go" / "MODULE.bazel"

    try:
        core_module_version = _extract_module_version(core_module)
        go_module_version = _extract_module_version(go_module)
        go_core_dep_version = _extract_core_dep_version_from_go_module(go_module)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    errors = []
    if core_module_version != go_module_version:
        errors.append(
            "module version mismatch: "
            f'root MODULE.bazel is "{core_module_version}" but '
            f'modules/go/MODULE.bazel is "{go_module_version}"'
        )
    if go_core_dep_version != core_module_version:
        errors.append(
            "dependency version mismatch: "
            f'modules/go depends on core version "{go_core_dep_version}" but '
            f'root MODULE.bazel declares "{core_module_version}"'
        )

    if errors:
        print("ERROR: module version alignment check failed:", file=sys.stderr)
        for err in errors:
            print(f"- {err}", file=sys.stderr)
        return 1

    print(
        "Module versions are aligned: "
        f'core="{core_module_version}", go="{go_module_version}", '
        f'go->core dep="{go_core_dep_version}"'
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
