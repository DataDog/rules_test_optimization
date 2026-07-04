#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Render a concise customer-facing Test Optimization report summary."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return value


def _payload_counts(report: dict[str, Any]) -> dict[str, int]:
    payloads = report.get("payloads") or report.get("summary", {}).get("payloads") or {}
    discovered = payloads.get("discovered", payloads) if isinstance(payloads, dict) else {}
    return {
        "tests": int(discovered.get("tests", 0)),
        "coverage": int(discovered.get("coverage", 0)),
        "telemetry": int(discovered.get("telemetry", 0)),
    }


def _remote_only_count(value: Any) -> int:
    if isinstance(value, list):
        return len(value)
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def render_summary_from_reports(reports: list[dict[str, Any]]) -> str:
    lines = ["# Datadog Test Optimization Upload Diagnostics", ""]
    for report in reports:
        tool = report.get("tool", "unknown")
        result = report.get("result", {})
        reason_code = result.get("reason_code", "unknown")
        reason = result.get("reason", "")
        counts = _payload_counts(report)
        lines.append(f"## {tool}")
        lines.append("")
        lines.append(f"Result: {result.get('status', report.get('status', 'unknown'))}")
        lines.append(f"Reason: {reason_code}")
        if reason:
            lines.append(f"Details: {reason}")
        lines.append(
            "Payloads discovered: "
            f"tests={counts['tests']}, coverage={counts['coverage']}, telemetry={counts['telemetry']}"
        )
        bep = report.get("bep", {})
        if isinstance(bep, dict) and bep:
            lines.append(f"BEP fresh outputs: {bep.get('eligible_outputs', 0)}")
            lines.append(f"BEP cached outputs: {bep.get('cached_outputs', 0)}")
            lines.append(f"BEP remote-only outputs: {_remote_only_count(bep.get('remote_only_outputs', 0))}")
        artifacts = report.get("artifacts", {})
        if isinstance(artifacts, dict) and artifacts:
            lines.append(
                f"Artifacts staged: {artifacts.get('staged_count', artifacts.get('staged_remote_artifacts', 0))}"
            )
        upload = report.get("upload", {})
        if isinstance(upload, dict) and upload:
            lines.append(f"Upload attempted: {'yes' if upload.get('attempted') else 'no'}")
        next_steps = result.get("next_steps") or []
        if next_steps:
            lines.append("Next steps:")
            for step in next_steps:
                lines.append(f"- {step}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_summary(paths: list[Path]) -> str:
    return render_summary_from_reports([_load(path) for path in paths])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    text = render_summary(args.reports)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
