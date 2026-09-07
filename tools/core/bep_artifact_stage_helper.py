#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Stage fresh BEP test.outputs artifacts for uploader runtimes."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType


def _helper_fail(message: str) -> None:
    print(f"[dd-test-optimization] error: {message}", file=sys.stderr)
    raise SystemExit(2)


def _load_doctor_runtime(path: str) -> ModuleType:
    runtime_path = Path(path)
    if not runtime_path.is_file():
        _helper_fail(f"BEP artifact staging doctor runtime not found: {path}")
    spec = importlib.util.spec_from_file_location("_dd_topt_doctor_runtime", runtime_path)
    if spec is None or spec.loader is None:
        _helper_fail(f"BEP artifact staging doctor runtime is not importable: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _valid_bep_paths(paths: list[str]) -> list[Path]:
    valid: list[Path] = []
    for value in paths:
        path = Path(value)
        if not path.is_file():
            print(f"[dd-test-optimization] error: BEP JSON not found: {path}; continuing with other BEP files", file=sys.stderr)
            continue
        try:
            with path.open("r", encoding="utf-8-sig") as handle:
                for line_number, line in enumerate(handle, start=1):
                    if line.strip():
                        json.loads(line)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            print(
                f"[dd-test-optimization] error: failed to parse BEP JSON {path}: {exc}; continuing with other BEP files",
                file=sys.stderr,
            )
            continue
        valid.append(path)
    return valid


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--doctor-runtime", required=True)
    parser.add_argument("--staging-dir", required=True)
    parser.add_argument("--remote-artifacts", choices=["disabled", "download", "required"], required=True)
    parser.add_argument("--artifact-source", choices=["local", "bep", "auto"], required=True)
    parser.add_argument("--bep-artifact-downloader", default="")
    parser.add_argument("--bep-artifact-downloader-timeout-sec", default="300")
    parser.add_argument("bep_json", nargs="+")
    args = parser.parse_args(argv)

    doctor = _load_doctor_runtime(args.doctor_runtime)
    downloader_timeout_sec = doctor._validate_downloader_timeout_sec(args.bep_artifact_downloader_timeout_sec)
    if args.artifact_source == "local":
        return 0
    if args.artifact_source == "auto" and args.remote_artifacts == "disabled":
        return 0

    workspace = doctor._workspace_root()
    staging_base = Path(args.staging_dir)
    valid_bep_paths = _valid_bep_paths(args.bep_json)
    if not valid_bep_paths:
        return 0
    freshness = doctor._parse_bep_freshness(valid_bep_paths, unavailable_is_error=True)
    if freshness is None:
        return 0
    selected_outputs = sorted(
        doctor._selected_bep_artifact_outputs(freshness, workspace, args.remote_artifacts)
    )
    blocked_labels = sorted(doctor._blocked_bep_artifact_labels(freshness, args.remote_artifacts))
    staged = doctor._stage_bep_artifacts(
        freshness,
        workspace=workspace,
        staging_dir=staging_base,
        remote_artifacts=args.remote_artifacts,
        downloader=args.bep_artifact_downloader,
        downloader_timeout_sec=downloader_timeout_sec,
    )

    def tsv_field(value: object) -> str:
        text = str(value)
        if "\t" in text or "\n" in text or "\r" in text:
            doctor._fail(f"cannot emit BEP artifact staging TSV field containing control characters: {text!r}")
        return text

    output_lines: list[str] = []
    try:
        for label, output_key in selected_outputs:
            output_lines.append(f"selected\t{tsv_field(label)}\t{tsv_field(output_key)}")
        for label in blocked_labels:
            output_lines.append(f"blocked_label\t{tsv_field(label)}")
        if staged:
            for root in sorted({str(item.staging_root) for item in staged}):
                output_lines.append(f"root\t{tsv_field(root)}")
        for item in staged:
            remote_flag = "1" if item.remote_only else "0"
            output_lines.append(
                "staged\t"
                f"{tsv_field(item.label)}\t{tsv_field(item.output_key)}\t"
                f"{tsv_field(item.output_dir)}\t{remote_flag}\t{tsv_field(item.fetch_value)}"
            )
    except BaseException:
        doctor._cleanup_staged_bep_run_roots(staged, staging_base=staging_base)
        raise

    for line in output_lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
