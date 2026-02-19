#!/usr/bin/env python3
"""Verify module version alignment for core + Go companion.

This guard is intentionally lightweight so it can run in CI and local pre-release
checks without extra dependencies.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys
from typing import List


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (
            (candidate / "MODULE.bazel").exists() and
            (candidate / "modules" / "go" / "MODULE.bazel").exists()
        ):
            return candidate
    raise ValueError("unable to locate repository root from script path")


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"unable to read {path}: {exc}") from exc


def _extract_call_args_blocks(text: str, fn_name: str) -> List[str]:
    """Extract argument blocks from `fn_name(...)` calls.

    This parser handles multiline calls and nested parentheses while ignoring
    quoted strings and `#` comments.
    """
    blocks: List[str] = []
    needle = f"{fn_name}("
    idx = 0
    n = len(text)
    while idx < n:
        start = text.find(needle, idx)
        if start < 0:
            break
        if start > 0:
            prev = text[start - 1]
            if prev.isalnum() or prev == "_":
                idx = start + 1
                continue
        i = start + len(needle)
        depth = 1
        in_string = ""
        escape = False
        while i < n:
            ch = text[i]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == in_string:
                    in_string = ""
                i += 1
                continue

            if ch == "#" :
                newline = text.find("\n", i)
                if newline < 0:
                    i = n
                else:
                    i = newline + 1
                continue
            if ch == '"' or ch == "'":
                in_string = ch
                i += 1
                continue
            if ch == "(":
                depth += 1
                i += 1
                continue
            if ch == ")":
                depth -= 1
                if depth == 0:
                    blocks.append(text[start + len(needle):i])
                    i += 1
                    break
                i += 1
                continue
            i += 1

        if depth != 0:
            raise ValueError(f"unterminated {fn_name}(...) block")
        idx = i
    return blocks


def _extract_module_version(path: Path) -> str:
    text = _read_text(path)
    module_blocks = _extract_call_args_blocks(text, "module")
    if not module_blocks:
        raise ValueError(f"no module(...) declaration found in {path}")

    version_match = re.search(r'version\s*=\s*"([^"]+)"', module_blocks[0])
    if version_match is None:
        raise ValueError(f'no module version = "..." found in {path}')

    return version_match.group(1)


def _extract_bazel_dep_version(path: Path, dep_name: str) -> str:
    text = _read_text(path)
    for block in _extract_call_args_blocks(text, "bazel_dep"):
        if re.search(r'name\s*=\s*"%s"' % re.escape(dep_name), block):
            version_match = re.search(r'version\s*=\s*"([^"]+)"', block)
            if version_match is None:
                raise ValueError(
                    f'{path} declares bazel_dep(name = "{dep_name}") without version'
                )
            return version_match.group(1)

    raise ValueError(
        f'{path} is missing bazel_dep(name = "{dep_name}", ...)'
    )


def main() -> int:
    try:
        repo_root = _repo_root()
        core_module = repo_root / "MODULE.bazel"
        go_module = repo_root / "modules" / "go" / "MODULE.bazel"
        if not core_module.exists():
            raise ValueError(f"core module file not found: {core_module}")
        if not go_module.exists():
            raise ValueError(f"go companion module file not found: {go_module}")

        core_module_version = _extract_module_version(core_module)
        go_module_version = _extract_module_version(go_module)
        go_core_dep_version = _extract_bazel_dep_version(
            go_module,
            "datadog-rules-test-optimization",
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    example_modules = [
        repo_root / "examples" / "single_service" / "MODULE.bazel",
        repo_root / "examples" / "multi_service" / "MODULE.bazel",
    ]

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
    for example_module in example_modules:
        try:
            ex_core_dep = _extract_bazel_dep_version(
                example_module,
                "datadog-rules-test-optimization",
            )
            ex_go_dep = _extract_bazel_dep_version(
                example_module,
                "datadog-rules-test-optimization-go",
            )
        except ValueError as exc:
            errors.append(str(exc))
            continue

        if ex_core_dep != core_module_version:
            errors.append(
                f'example dependency mismatch ({example_module}): core dep is "{ex_core_dep}" '
                f'but root module declares "{core_module_version}"'
            )
        if ex_go_dep != go_module_version:
            errors.append(
                f'example dependency mismatch ({example_module}): go dep is "{ex_go_dep}" '
                f'but modules/go declares "{go_module_version}"'
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
