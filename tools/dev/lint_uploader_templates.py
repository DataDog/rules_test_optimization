#!/usr/bin/env python3
"""Extract and lint embedded uploader templates from Starlark files."""

from __future__ import annotations

import argparse
import re
import subprocess
import tempfile
from pathlib import Path

_PLACEHOLDER_RE = re.compile(r"\{\{[A-Za-z0-9_]+\}\}")


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            return candidate
    raise RuntimeError("unable to locate repository root from script path")


def _extract_template(path: Path, variable_name: str) -> str:
    marker = f'{variable_name} = """'
    text = path.read_text(encoding="utf-8")
    start = text.find(marker)
    if start < 0:
        raise RuntimeError(f"template marker not found in {path}: {marker}")
    start += len(marker)
    end = text.find('"""', start)
    if end < 0:
        raise RuntimeError(f"template terminator not found in {path}")
    return text[start:end].lstrip("\n")


def _normalize_template_for_lint(template: str) -> str:
    # Replace format placeholders and unescape doubled braces used in the .bzl
    # template literals so shellcheck/PowerShell parser see render-equivalent syntax.
    normalized = _PLACEHOLDER_RE.sub("0", template)
    normalized = normalized.replace("{{", "{").replace("}}", "}")
    return normalized


def _run(cmd: list[str], cwd: Path) -> None:
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
    parser = argparse.ArgumentParser(description="Lint uploader template strings")
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
    bash_bzl = repo / "tools/core/uploader_bash_template.bzl"
    ps_bzl = repo / "tools/core/uploader_powershell_template.bzl"
    bash_template = _normalize_template_for_lint(_extract_template(bash_bzl, "UPLOADER_BASH_TEMPLATE"))
    # The Starlark source encodes escaped parenthesis as "\\(" and "\\)" so
    # shellcheck sees parse-equivalent output to the rendered script.
    bash_template = bash_template.replace("\\\\(", "\\(").replace("\\\\)", "\\)")
    ps_template = _normalize_template_for_lint(_extract_template(ps_bzl, "UPLOADER_POWERSHELL_TEMPLATE"))

    with tempfile.TemporaryDirectory(prefix="uploader_template_lint.") as tmp:
        tmp_dir = Path(tmp)
        bash_file = tmp_dir / "uploader_template.sh"
        ps_file = tmp_dir / "uploader_template.ps1"
        bash_file.write_text(bash_template, encoding="utf-8")
        ps_file.write_text(ps_template, encoding="utf-8")

        if not args.skip_shellcheck:
            _run(["shellcheck", "--severity=error", str(bash_file)], repo)

        if not args.skip_powershell_parse:
            ps_file_path = str(ps_file).replace("'", "''")
            ps_parse_cmd = (
                "$tokens = $null; "
                "$errors = $null; "
                f"[System.Management.Automation.Language.Parser]::ParseFile('{ps_file_path}', [ref]$tokens, [ref]$errors) | Out-Null; "
                "if ($errors -and $errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }"
            )
            _run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    ps_parse_cmd,
                ],
                repo,
            )

    print("uploader template lint: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
