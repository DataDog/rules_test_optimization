#!/usr/bin/env python3
"""Ensure root and companion-module .bazelversion files stay aligned."""

from __future__ import annotations

from pathlib import Path
import sys

_COMPANION_LANGUAGES = (
    "go",
    "python",
    "java",
    "nodejs",
    "dotnet",
    "ruby",
)


def _repo_root() -> Path:
    """Internal helper for repo root behavior."""
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def main() -> int:
    """Run CLI entrypoint logic and return process exit code."""
    repo = _repo_root()
    root_file = repo / ".bazelversion"
    companion_files = [
        repo / "modules" / language / ".bazelversion"
        for language in _COMPANION_LANGUAGES
    ]
    expected_files = [root_file] + companion_files

    for path in expected_files:
        if not path.exists():
            print(f"error: required file missing: {path}")
            return 1

    root_version = root_file.read_text(encoding="utf-8").strip()
    companion_versions = {
        str(path.relative_to(repo)): path.read_text(encoding="utf-8").strip()
        for path in companion_files
    }

    if not root_version or any(not version for version in companion_versions.values()):
        print("error: .bazelversion files must not be empty")
        return 1

    mismatches = [
        f"{rel_path}={version!r}"
        for rel_path, version in companion_versions.items()
        if version != root_version
    ]
    if mismatches:
        print("error: .bazelversion mismatch:")
        print(f"  root={root_version!r}")
        for mismatch in mismatches:
            print(f"  {mismatch}")
        return 1

    languages = ", ".join(_COMPANION_LANGUAGES)
    print(f".bazelversion parity: ok ({root_version}) across root + {languages}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
