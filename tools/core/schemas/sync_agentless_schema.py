#!/usr/bin/env python3
"""Synchronize agentless schema JSON from YAML source.

Usage:
  python3 tools/core/schemas/sync_agentless_schema.py
  python3 tools/core/schemas/sync_agentless_schema.py --check
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def _default_yaml_path() -> Path:
    return _repo_root() / "tools" / "core" / "schemas" / "agentless-schema.yaml"


def _default_json_path() -> Path:
    return _repo_root() / "tools" / "core" / "schemas" / "agentless-schema.json"


def _load_yaml_with_pyyaml(path: Path) -> Any:
    try:
        import yaml  # type: ignore
    except ImportError as exc:
        raise RuntimeError("PyYAML is not available") from exc
    with path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def _load_yaml_with_ruby(path: Path) -> Any:
    ruby = shutil.which("ruby")
    if not ruby:
        raise RuntimeError("Ruby is not available")

    ruby_code = (
        "require 'json'; "
        "require 'yaml'; "
        "data = Psych.safe_load(File.read(ARGV[0]), aliases: false); "
        "puts JSON.generate(data)"
    )
    proc = subprocess.run(
        [ruby, "-e", ruby_code, str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        raise RuntimeError(f"Ruby failed to parse YAML: {stderr}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Ruby produced invalid JSON output") from exc


def load_yaml(path: Path) -> Any:
    pyyaml_error: Exception | None = None
    try:
        return _load_yaml_with_pyyaml(path)
    except Exception as exc:
        pyyaml_error = exc

    try:
        return _load_yaml_with_ruby(path)
    except Exception as ruby_exc:
        if pyyaml_error is not None:
            raise RuntimeError(
                "failed to parse YAML with both PyYAML and Ruby: "
                f"pyyaml={pyyaml_error}; ruby={ruby_exc}"
            ) from ruby_exc
        raise RuntimeError(f"Ruby failed to parse YAML: {ruby_exc}") from ruby_exc


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def render_json(data: Any) -> str:
    return json.dumps(data, indent=2) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync tools/core/schemas/agentless-schema.json from YAML source."
    )
    parser.add_argument(
        "--yaml",
        dest="yaml_path",
        type=Path,
        default=_default_yaml_path(),
        help="Path to YAML schema source.",
    )
    parser.add_argument(
        "--json",
        dest="json_path",
        type=Path,
        default=_default_json_path(),
        help="Path to JSON schema output.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check whether JSON output is in sync; do not modify files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    yaml_path = args.yaml_path.resolve()
    json_path = args.json_path.resolve()

    if not yaml_path.exists():
        print(f"error: YAML schema not found: {yaml_path}", file=sys.stderr)
        return 2

    try:
        yaml_data = load_yaml(yaml_path)
    except RuntimeError as exc:
        print(
            "error: failed to parse YAML schema (install PyYAML or Ruby): "
            f"{exc}",
            file=sys.stderr,
        )
        return 2

    rendered = render_json(yaml_data)

    if args.check:
        if not json_path.exists():
            print(f"out of sync: missing JSON schema at {json_path}", file=sys.stderr)
            return 1
        try:
            json_data = load_json(json_path)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"error: failed to parse JSON schema: {exc}", file=sys.stderr)
            return 2

        if json_data != yaml_data:
            print(
                f"out of sync: {json_path} does not match {yaml_path}",
                file=sys.stderr,
            )
            return 1

        print(f"in sync: {json_path} matches {yaml_path}")
        return 0

    json_path.write_text(rendered, encoding="utf-8")
    print(f"updated: {json_path} <- {yaml_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
