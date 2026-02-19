#!/usr/bin/env python3
"""Verify PyYAML and Ruby parse the schema YAML identically."""

from __future__ import annotations

import sys

from sync_agentless_schema import (  # type: ignore
    _default_yaml_path,
    _load_yaml_with_pyyaml,
    _load_yaml_with_ruby,
)


def main() -> int:
    yaml_path = _default_yaml_path().resolve()
    try:
        pyyaml_data = _load_yaml_with_pyyaml(yaml_path)
    except Exception as exc:
        print(f"error: PyYAML parser failed: {exc}", file=sys.stderr)
        print(
            "hint: install tooling deps with `python3 -m pip install -r tools/requirements.txt`",
            file=sys.stderr,
        )
        return 2

    try:
        ruby_data = _load_yaml_with_ruby(yaml_path)
    except Exception as exc:
        print(f"error: Ruby parser failed: {exc}", file=sys.stderr)
        print(
            "hint: ensure Ruby is installed and available in PATH for parser parity checks",
            file=sys.stderr,
        )
        return 2

    if pyyaml_data != ruby_data:
        print(
            "error: parser parity mismatch between PyYAML and Ruby for "
            f"{yaml_path}",
            file=sys.stderr,
        )
        return 1

    print(f"parser parity ok: {yaml_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
