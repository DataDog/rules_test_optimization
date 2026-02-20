#!/usr/bin/env python3
"""Validate that audit findings sources are fully tracked in the ledger."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

_ID_RE = re.compile(r"`([A-Z]-\d{2})`")
_ID_FALLBACK_RE = re.compile(r"\b([A-Z]-\d{2})\b")
_TABLE_ROW_RE = re.compile(r"^\|\s*([A-Z]-\d{2})\s*\|")
_ALLOWED_DISPOSITIONS = {"fix", "mitigate-doc", "close-no-change"}
_ALLOWED_STATUS = {"pending", "done"}


def _repo_root() -> Path:
    """Internal helper for repo root behavior."""
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def _extract_ids(path: Path) -> set[str]:
    """Internal helper for extract ids behavior."""
    text = path.read_text(encoding="utf-8")
    ids = set(_ID_RE.findall(text))
    if ids:
        return ids
    return set(_ID_FALLBACK_RE.findall(text))


def _parse_ledger_rows(path: Path) -> dict[str, dict[str, str]]:
    """Internal helper for parse ledger rows behavior."""
    rows: dict[str, dict[str, str]] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not _TABLE_ROW_RE.match(raw):
            continue
        cols = [c.strip() for c in raw.strip().strip("|").split("|")]
        if len(cols) < 5:
            continue
        finding_id = cols[0]
        rows[finding_id] = {
            "validation": cols[1],
            "disposition": cols[2],
            "status": cols[3],
            "evidence": cols[4],
        }
    return rows


def main() -> int:
    """Run CLI entrypoint logic and return process exit code."""
    parser = argparse.ArgumentParser(
        description="Check that audit findings are tracked in findings_validation_2026_02.md",
    )
    parser.add_argument(
        "--require-done",
        action="store_true",
        help="fail unless all tracked IDs have status=done",
    )
    parser.add_argument(
        "--require-evidence",
        action="store_true",
        help="fail when any done row has empty evidence",
    )
    parser.add_argument(
        "--expected-count",
        type=int,
        default=61,
        help="expected number of unique finding IDs from sources",
    )
    args = parser.parse_args()

    repo = _repo_root()
    source_paths = [
        repo / "docs/audit/findings_claude_2026_02_source.md",
        repo / "docs/audit/findings_codex_2026_02_source.md",
    ]
    ledger_path = repo / "docs/audit/findings_validation_2026_02.md"

    problems: list[str] = []
    for source_path in source_paths:
        if not source_path.exists():
            problems.append(f"missing source file: {source_path}")
    if not ledger_path.exists():
        problems.append(f"missing ledger file: {ledger_path}")
    if problems:
        for issue in problems:
            print(f"error: {issue}")
        return 1

    source_ids: set[str] = set()
    for source_path in source_paths:
        source_ids.update(_extract_ids(source_path))
    if args.expected_count > 0 and len(source_ids) != args.expected_count:
        problems.append(
            f"expected {args.expected_count} IDs from sources, got {len(source_ids)}",
        )

    ledger_rows = _parse_ledger_rows(ledger_path)
    ledger_ids = set(ledger_rows.keys())
    missing = sorted(source_ids - ledger_ids)
    extras = sorted(ledger_ids - source_ids)
    if missing:
        problems.append(f"missing IDs in ledger: {', '.join(missing)}")
    if extras:
        problems.append(f"unexpected IDs in ledger: {', '.join(extras)}")

    for finding_id in sorted(source_ids):
        row = ledger_rows.get(finding_id)
        if row is None:
            continue
        disposition = row["disposition"]
        status = row["status"]
        evidence = row["evidence"]
        if disposition not in _ALLOWED_DISPOSITIONS:
            problems.append(
                f"{finding_id}: invalid disposition '{disposition}' "
                f"(allowed: {', '.join(sorted(_ALLOWED_DISPOSITIONS))})",
            )
        if status not in _ALLOWED_STATUS:
            problems.append(
                f"{finding_id}: invalid status '{status}' "
                f"(allowed: {', '.join(sorted(_ALLOWED_STATUS))})",
            )
        if args.require_done and status != "done":
            problems.append(f"{finding_id}: status is '{status}', expected 'done'")
        if args.require_evidence and status == "done" and not evidence:
            problems.append(f"{finding_id}: done row requires evidence")

    if problems:
        for issue in problems:
            print(f"error: {issue}")
        return 1

    print(
        "findings ledger check: ok "
        f"(tracked={len(source_ids)}, require_done={args.require_done}, require_evidence={args.require_evidence})",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
