#!/usr/bin/env python3
"""Ensure root and modules/go .bazelversion files stay aligned."""

from __future__ import annotations

from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def main() -> int:
    repo = _repo_root()
    root_file = repo / ".bazelversion"
    go_file = repo / "modules/go/.bazelversion"

    for path in (root_file, go_file):
        if not path.exists():
            print(f"error: required file missing: {path}")
            return 1

    root_version = root_file.read_text(encoding="utf-8").strip()
    go_version = go_file.read_text(encoding="utf-8").strip()

    if not root_version or not go_version:
        print("error: .bazelversion files must not be empty")
        return 1
    if root_version != go_version:
        print(
            "error: .bazelversion mismatch: "
            f"root={root_version!r} modules/go={go_version!r}",
        )
        return 1

    print(f".bazelversion parity: ok ({root_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
