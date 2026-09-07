#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Parse every generated uploader runtime and launcher template.

Central linting keeps legacy and Python rollout entrypoints in the same CI gate.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

_TOKEN_RE = re.compile(r"__DDTPL_[A-Z0-9_]+__")


def _repo_root() -> Path:
    """Find the checkout root so linting works from any current directory."""
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def _normalize_bash_template_for_lint(template: str) -> str:
    """Replace generated tokens with shellcheck-safe scalar values."""
    return _TOKEN_RE.sub("0", template)


def _normalize_powershell_template_for_lint(template: str) -> str:
    """Replace generated tokens with PowerShell-parser-safe scalar values."""
    return _TOKEN_RE.sub("0", template)


def _lint_batch_template(template: str) -> None:
    """Check the small batch wrapper contract not covered by a parser."""
    if "__DDTPL_PS_NAME__" not in template:
        raise RuntimeError("batch template missing __DDTPL_PS_NAME__ placeholder")
    normalized = _TOKEN_RE.sub("dd_upload_payloads.ps1", template).lower()
    if "powershell.exe" not in normalized:
        raise RuntimeError("batch template missing powershell.exe invocation")
    if "%*" not in normalized:
        raise RuntimeError("batch template must forward CLI arguments to PowerShell with %*")
    if "exit /b %errorlevel%" not in normalized:
        raise RuntimeError("batch template missing exit code propagation (exit /b %ERRORLEVEL%)")


def _run(cmd: list[str], cwd: Path) -> None:
    """Run one required linter and turn tool failures into useful diagnostics."""
    try:
        completed = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"required command not found: {cmd[0]}") from exc
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        detail = stderr or stdout or "unknown error"
        raise RuntimeError(f"{' '.join(cmd)} failed: {detail}")


def main() -> int:
    """Lint all rollout templates and return a process-compatible status."""
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
    bash_templates = (
        repo / "tools/core/uploader_bash_runtime.sh.tpl",
        repo / "tools/core/uploader_python_launcher.sh.tpl",
    )
    powershell_templates = (
        repo / "tools/core/uploader_powershell_runtime.ps1.tpl",
        repo / "tools/core/uploader_python_launcher.ps1.tpl",
    )
    batch_template_path = repo / "tools/core/uploader_batch_runtime.bat.tpl"
    batch_template = batch_template_path.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="uploader_template_lint.") as temporary:
        temporary_root = Path(temporary)
        powershell_parser_path = temporary_root / "parse_template.ps1"
        powershell_parser_path.write_text(
            (
                "param([string]$TemplatePath)\n"
                "$tokens = $null\n"
                "$errors = $null\n"
                "[System.Management.Automation.Language.Parser]::ParseFile("
                "$TemplatePath, [ref]$tokens, [ref]$errors) | Out-Null\n"
                "if ($errors -and $errors.Count -gt 0) {\n"
                "  $errors | ForEach-Object { Write-Error $_ }\n"
                "  exit 1\n"
                "}\n"
            ),
            encoding="utf-8",
        )

        if not args.skip_shellcheck:
            for index, template_path in enumerate(bash_templates):
                bash_file = temporary_root / f"uploader_template_{index}.sh"
                bash_file.write_text(
                    _normalize_bash_template_for_lint(
                        template_path.read_text(encoding="utf-8")
                    ),
                    encoding="utf-8",
                )
                _run(["shellcheck", "--severity=error", str(bash_file)], repo)

        if not args.skip_powershell_parse:
            for index, template_path in enumerate(powershell_templates):
                ps_file = temporary_root / f"uploader_template_{index}.ps1"
                ps_file.write_text(
                    _normalize_powershell_template_for_lint(
                        template_path.read_text(encoding="utf-8")
                    ),
                    encoding="utf-8",
                )
                _run(
                    [
                        "pwsh",
                        "-NoProfile",
                        "-NonInteractive",
                        "-File",
                        str(powershell_parser_path),
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
