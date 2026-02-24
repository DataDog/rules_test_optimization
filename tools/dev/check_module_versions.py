#!/usr/bin/env python3
"""Verify module version alignment for core + companion modules.

This guard is intentionally lightweight so it can run in CI and local pre-release
checks without extra dependencies.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys
from typing import Dict, List, Optional


def _repo_root() -> Path:
    """Internal helper for repo root behavior."""
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise ValueError("unable to locate repository root from script path")


def _read_text(path: Path) -> str:
    """Internal helper for read text behavior."""
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
                if len(in_string) == 3:
                    if text.startswith(in_string, i):
                        in_string = ""
                        i += 3
                        continue
                    i += 1
                    continue
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == in_string:
                    in_string = ""
                i += 1
                continue

            if ch == "#":
                newline = text.find("\n", i)
                if newline < 0:
                    i = n
                else:
                    i = newline + 1
                continue
            if text.startswith('"""', i) or text.startswith("'''", i):
                in_string = text[i:i + 3]
                escape = False
                i += 3
                continue
            if ch == '"' or ch == "'":
                in_string = ch
                escape = False
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
    """Internal helper for extract module version behavior."""
    text = _read_text(path)
    module_blocks = _extract_call_args_blocks(text, "module")
    if not module_blocks:
        raise ValueError(f"no module(...) declaration found in {path}")

    version_match = re.search(r'version\s*=\s*"([^"]+)"', module_blocks[0])
    if version_match is None:
        raise ValueError(f'no module version = "..." found in {path}')

    return version_match.group(1)


def _extract_bazel_dep_version(path: Path, dep_name: str) -> str:
    """Internal helper for extract bazel dep version behavior."""
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

def _extract_optional_bazel_dep_version(path: Path, dep_name: str) -> Optional[str]:
    """Return dep version when declared, otherwise None."""
    text = _read_text(path)
    for block in _extract_call_args_blocks(text, "bazel_dep"):
        if re.search(r'name\s*=\s*"%s"' % re.escape(dep_name), block):
            version_match = re.search(r'version\s*=\s*"([^"]+)"', block)
            if version_match is None:
                raise ValueError(
                    f'{path} declares bazel_dep(name = "{dep_name}") without version'
                )
            return version_match.group(1)
    return None

def _extract_starlark_string_constant(path: Path, constant_name: str) -> str:
    """Internal helper for extract starlark string constant behavior."""
    text = _read_text(path)
    m = re.search(
        r"^\s*%s\s*=\s*\"([^\"]+)\"\s*$" % re.escape(constant_name),
        text,
        re.MULTILINE,
    )
    if m is None:
        raise ValueError(f'{path} is missing {constant_name} = "..."')
    return m.group(1)

def _is_semver_like(version: str) -> bool:
    """Internal helper for is semver like behavior."""
    return bool(re.match(r"^\d+\.\d+\.\d+$", version or ""))

def _check_semver(label: str, version: str, errors: List[str]) -> None:
    """Internal helper for check semver behavior."""
    if not _is_semver_like(version):
        errors.append(f'{label} "{version}" must be semantic version format X.Y.Z')


def main() -> int:
    """Run CLI entrypoint logic and return process exit code."""
    try:
        repo_root = _repo_root()
        core_module = repo_root / "MODULE.bazel"
        companion_module_paths = {
            "go": repo_root / "modules" / "go" / "MODULE.bazel",
            "python": repo_root / "modules" / "python" / "MODULE.bazel",
            "java": repo_root / "modules" / "java" / "MODULE.bazel",
            "nodejs": repo_root / "modules" / "nodejs" / "MODULE.bazel",
            "dotnet": repo_root / "modules" / "dotnet" / "MODULE.bazel",
            "ruby": repo_root / "modules" / "ruby" / "MODULE.bazel",
        }
        companion_dep_names = {
            "go": "datadog-rules-test-optimization-go",
            "python": "datadog-rules-test-optimization-python",
            "java": "datadog-rules-test-optimization-java",
            "nodejs": "datadog-rules-test-optimization-nodejs",
            "dotnet": "datadog-rules-test-optimization-dotnet",
            "ruby": "datadog-rules-test-optimization-ruby",
        }
        common_utils = repo_root / "tools" / "core" / "common_utils.bzl"
        if not core_module.exists():
            raise ValueError(f"core module file not found: {core_module}")
        if not common_utils.exists():
            raise ValueError(f"common utils file not found: {common_utils}")

        core_module_version = _extract_module_version(core_module)
        companion_versions: Dict[str, str] = {}
        companion_core_dep_versions: Dict[str, str] = {}
        companion_exists: Dict[str, bool] = {}
        for language, module_path in companion_module_paths.items():
            exists = module_path.exists()
            companion_exists[language] = exists
            if not exists:
                continue
            companion_versions[language] = _extract_module_version(module_path)
            companion_core_dep_versions[language] = _extract_bazel_dep_version(
                module_path,
                "datadog-rules-test-optimization",
            )
        rules_version = _extract_starlark_string_constant(common_utils, "RULES_VERSION")
        uploader_version = _extract_starlark_string_constant(common_utils, "UPLOADER_VERSION")
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    example_modules = [
        repo_root / "examples" / "single_service" / "MODULE.bazel",
        repo_root / "examples" / "multi_service" / "MODULE.bazel",
    ]

    errors = []
    for language, exists in companion_exists.items():
        if not exists:
            continue
        module_version = companion_versions[language]
        core_dep_version = companion_core_dep_versions[language]
        module_rel = f"modules/{language}/MODULE.bazel"
        if core_module_version != module_version:
            errors.append(
                "module version mismatch: "
                f'root MODULE.bazel is "{core_module_version}" but '
                f'{module_rel} is "{module_version}"'
            )
        if core_dep_version != core_module_version:
            errors.append(
                "dependency version mismatch: "
                f'{module_rel} depends on core version "{core_dep_version}" but '
                f'root MODULE.bazel declares "{core_module_version}"'
            )
    if rules_version != core_module_version:
        errors.append(
            "rules version mismatch: "
            f'tools/core/common_utils.bzl RULES_VERSION is "{rules_version}" but '
            f'root MODULE.bazel declares "{core_module_version}"'
        )
    _check_semver("root MODULE.bazel version", core_module_version, errors)
    for language, exists in companion_exists.items():
        if not exists:
            continue
        _check_semver(f"modules/{language} MODULE.bazel version", companion_versions[language], errors)
        _check_semver(
            f"modules/{language} -> core dependency version",
            companion_core_dep_versions[language],
            errors,
        )
    _check_semver("tools/core/common_utils.bzl RULES_VERSION", rules_version, errors)
    _check_semver("tools/core/common_utils.bzl UPLOADER_VERSION", uploader_version, errors)
    for example_module in example_modules:
        try:
            ex_core_dep = _extract_bazel_dep_version(
                example_module,
                "datadog-rules-test-optimization",
            )
        except ValueError as exc:
            errors.append(str(exc))
            continue

        if ex_core_dep != core_module_version:
            errors.append(
                f'example dependency mismatch ({example_module}): core dep is "{ex_core_dep}" '
                f'but root module declares "{core_module_version}"'
            )
        _check_semver(f"{example_module} core dependency version", ex_core_dep, errors)
        for language, exists in companion_exists.items():
            if not exists:
                continue
            dep_name = companion_dep_names[language]
            try:
                ex_dep = _extract_optional_bazel_dep_version(example_module, dep_name)
            except ValueError as exc:
                errors.append(str(exc))
                continue
            if ex_dep is None:
                continue
            module_version = companion_versions[language]
            if ex_dep != module_version:
                errors.append(
                    f'example dependency mismatch ({example_module}): {language} dep is "{ex_dep}" '
                    f'but modules/{language} declares "{module_version}"'
                )
            _check_semver(f"{example_module} {language} dependency version", ex_dep, errors)

    if errors:
        print("ERROR: module version alignment check failed:", file=sys.stderr)
        for err in errors:
            print(f"- {err}", file=sys.stderr)
        return 1

    companion_display = []
    for language in ["go", "python", "java", "nodejs", "dotnet", "ruby"]:
        if not companion_exists.get(language):
            companion_display.append(f'{language}="<missing>"')
            continue
        companion_display.append(f'{language}="{companion_versions[language]}"')
    print(
        "Module versions are aligned: "
        f'core="{core_module_version}", {", ".join(companion_display)}, '
        f'rules="{rules_version}", uploader="{uploader_version}"'
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
