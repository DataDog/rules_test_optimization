#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Lint standalone uploader runtime template files."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import re

_TOKEN_RE = re.compile(r"__DDTPL_[A-Z0-9_]+__")


def _repo_root() -> Path:
    """Internal helper for repo root behavior."""
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def _normalize_bash_template_for_lint(template: str) -> str:
    # Runtime templates carry __DDTPL_*__ tokens; replace them with deterministic
    # literals so shellcheck parses render-equivalent syntax.
    """Internal helper for normalize bash template for lint behavior."""
    normalized = _TOKEN_RE.sub("0", template)
    return normalized


def _normalize_powershell_template_for_lint(template: str) -> str:
    # Keep parser checks deterministic by replacing token placeholders with
    # scalar literals.
    """Internal helper for normalize powershell template for lint behavior."""
    return _TOKEN_RE.sub("0", template)


def _lint_batch_template(template: str) -> None:
    """Internal helper for lint batch template behavior."""
    if "__DDTPL_PS_NAME__" not in template:
        raise RuntimeError("batch template missing __DDTPL_PS_NAME__ placeholder")
    normalized = _TOKEN_RE.sub("dd_upload_payloads.ps1", template).lower()
    if "powershell.exe" not in normalized:
        raise RuntimeError("batch template missing powershell.exe invocation")
    if "exit /b %errorlevel%" not in normalized:
        raise RuntimeError("batch template missing exit code propagation (exit /b %ERRORLEVEL%)")


def _run(cmd: list[str], cwd: Path) -> None:
    """Internal helper for run behavior."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise RuntimeError(f"required command not found: {cmd[0]}") from exc
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        stdout = proc.stdout.strip()
        detail = stderr or stdout or "unknown error"
        raise RuntimeError(f"{' '.join(cmd)} failed: {detail}")


def main() -> int:
    """Run CLI entrypoint logic and return process exit code."""
    parser = argparse.ArgumentParser(description="Lint uploader runtime template files")
    parser.add_argument(
        "--skip-shellcheck",
        action="store_true",
        help="Skip shellcheck for bash template",
    )
    parser.add_argument(
        "--skip-powershell-parse",
        action="store_true",
        help="Skip PowerShell parse check for powershell template",
    )
    args = parser.parse_args()

    repo = _repo_root()
    bash_tpl = repo / "tools/core/uploader_bash_runtime.sh.tpl"
    ps_tpl = repo / "tools/core/uploader_powershell_runtime.ps1.tpl"
    batch_tpl = repo / "tools/core/uploader_batch_runtime.bat.tpl"
    bash_template = _normalize_bash_template_for_lint(bash_tpl.read_text(encoding="utf-8"))
    ps_template = _normalize_powershell_template_for_lint(ps_tpl.read_text(encoding="utf-8"))
    batch_template = batch_tpl.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="uploader_template_lint.") as tmp:
        tmp_dir = Path(tmp)
        bash_file = tmp_dir / "uploader_template.sh"
        ps_file = tmp_dir / "uploader_template.ps1"
        ps_parse_file = tmp_dir / "parse_template.ps1"
        bash_file.write_text(bash_template, encoding="utf-8")
        ps_file.write_text(ps_template, encoding="utf-8")
        ps_parse_file.write_text(
            (
                "param([string]$TemplatePath)\n"
                "$tokens = $null\n"
                "$errors = $null\n"
                "[System.Management.Automation.Language.Parser]::ParseFile($TemplatePath, [ref]$tokens, [ref]$errors) | Out-Null\n"
                "if ($errors -and $errors.Count -gt 0) {\n"
                "  $errors | ForEach-Object { Write-Error $_ }\n"
                "  exit 1\n"
                "}\n"
            ),
            encoding="utf-8",
        )

        if not args.skip_shellcheck:
            _run(["shellcheck", "--severity=error", str(bash_file)], repo)

        if not args.skip_powershell_parse:
            _run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-NonInteractive",
                    "-File",
                    str(ps_parse_file),
                    "-TemplatePath",
                    str(ps_file),
                ],
                repo,
            )
    _lint_batch_template(batch_template)

    print("uploader template lint: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
