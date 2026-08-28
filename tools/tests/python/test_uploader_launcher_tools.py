#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Minimal Python launcher tests, including manifest-only runfiles."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def _repo_file(relative: str) -> Path:
    for parent in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        candidate = parent / relative
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(relative)


class LauncherTests(unittest.TestCase):
    def test_unix_launcher_supports_manifest_only_runfiles_and_space_paths(self) -> None:
        if os.name == "nt":
            self.skipTest("Unix launcher test")
        template = _repo_file("tools/core/uploader_python_launcher.sh.tpl")
        main = _repo_file("tools/core/uploader_main.py")
        with tempfile.TemporaryDirectory(prefix="uploader launcher ") as raw_root:
            root = Path(raw_root)
            launcher_dir = root / "generated files"
            launcher_dir.mkdir()
            testlogs = root / "empty testlogs"
            testlogs.mkdir()
            launcher = launcher_dir / "uploader script.sh"
            config = launcher_dir / "uploader config.json"
            config.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "quiescent_sec": 0,
                        "max_wait_sec": 0,
                    }
                ),
                encoding="utf-8",
            )
            rendered = template.read_text(encoding="utf-8")
            substitutions = {
                "PYTHON_MAIN_PATH": "missing/direct/uploader_main.py",
                "PYTHON_MAIN_RLOC": "repo/tools/core/uploader main.py",
                "PYTHON_CONFIG_PATH": "missing/direct/config.json",
                "PYTHON_CONFIG_RLOC": "repo/generated/config.json",
                "PYTHON_CONFIG_NAME": config.name,
            }
            for key, value in substitutions.items():
                rendered = rendered.replace(f"__DDTPL_{key}__", value)
            self.assertNotIn("__DDTPL_", rendered)
            launcher.write_text(rendered, encoding="utf-8")
            launcher.chmod(0o755)
            manifest = Path(f"{launcher}.runfiles_manifest")
            manifest.write_text(
                f" repo/tools/core/uploader\\smain.py {main}\n",
                encoding="utf-8",
            )
            environment = {
                "PATH": os.environ.get("PATH", ""),
                "DD_TEST_OPTIMIZATION_PYTHON": sys.executable,
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "TESTLOGS_DIR": str(testlogs),
            }

            completed = subprocess.run(
                [
                    str(launcher),
                    "--debug",
                    "--dry-run",
                    "--allow-cached-payload-uploads",
                ],
                cwd=root,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertIn("summary: mode=dry-run", completed.stdout)
            self.assertIn(f"manifest={manifest.resolve()}", completed.stderr)

    def test_powershell_launcher_finds_batch_runfiles_manifest(self) -> None:
        if os.name == "nt":
            self.skipTest("covered by the generated uploader Windows CI smoke")
        powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is not installed")
        template = _repo_file("tools/core/uploader_python_launcher.ps1.tpl")
        main = _repo_file("tools/core/uploader_main.py")
        with tempfile.TemporaryDirectory(prefix="uploader launcher ") as raw_root:
            root = Path(raw_root)
            fake_python = root / "fake python"
            fake_python.write_text(
                "#!/usr/bin/env sh\nprintf '%s\\n' \"$RUNFILES_MANIFEST_FILE\"\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            launcher_dir = root / "generated files"
            launcher_dir.mkdir()
            testlogs = root / "empty testlogs"
            testlogs.mkdir()
            launcher = launcher_dir / "uploader.python.ps1"
            config = launcher_dir / "uploader config.json"
            config.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "quiescent_sec": 0,
                        "max_wait_sec": 0,
                    }
                ),
                encoding="utf-8",
            )
            rendered = template.read_text(encoding="utf-8")
            substitutions = {
                "PYTHON_MAIN_PATH": "missing/direct/uploader_main.py",
                "PYTHON_MAIN_RLOC": "repo/tools/core/uploader_main.py",
                "PYTHON_CONFIG_PATH": "missing/direct/config.json",
                "PYTHON_CONFIG_RLOC": "repo/generated/config.json",
                "PYTHON_CONFIG_NAME": config.name,
            }
            for key, value in substitutions.items():
                rendered = rendered.replace(f"__DDTPL_{key}__", value)
            self.assertNotIn("__DDTPL_", rendered)
            launcher.write_text(rendered, encoding="utf-8")
            manifest = launcher_dir / "uploader.python.bat.runfiles_manifest"
            manifest_main = root / "runtime files" / "uploader main.py"
            manifest_main.parent.mkdir()
            manifest_main.write_bytes(main.read_bytes())
            encoded_main = (
                str(manifest_main).replace("\\", r"\b").replace(" ", r"\s")
            )
            manifest.write_text(
                " repo/tools/core/uploader_main.py "
                f"{encoded_main}\n",
                encoding="utf-8",
            )
            environment = dict(os.environ)
            for name in ("RUNFILES_DIR", "RUNFILES_MANIFEST_FILE", "TEST_SRCDIR"):
                environment.pop(name, None)
            environment.update(
                {
                    "DD_TEST_OPTIMIZATION_PYTHON": str(fake_python),
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(testlogs),
                }
            )

            completed = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-NonInteractive",
                    "-File",
                    str(launcher),
                    "--dry-run",
                    "--allow-cached-payload-uploads",
                ],
                cwd=root,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertEqual(
                manifest.resolve(),
                Path(completed.stdout.strip()).resolve(),
            )

    def test_launchers_contain_resolution_only_not_uploader_behavior(self) -> None:
        for relative in (
            "tools/core/uploader_python_launcher.sh.tpl",
            "tools/core/uploader_python_launcher.ps1.tpl",
        ):
            text = _repo_file(relative).read_text(encoding="utf-8")
            with self.subTest(relative=relative):
                self.assertIn("python_main", text.lower())
                self.assertNotIn("citestcycle", text.lower())
                self.assertNotIn("codeowners", text.lower())
                self.assertNotIn("multipart", text.lower())
                self.assertNotIn("payloads/tests", text.lower())
                if relative.endswith(".ps1.tpl"):
                    self.assertIn(
                        "$script:BatchLauncherPath.runfiles_manifest",
                        text,
                    )
                    self.assertIn("$env:RUNFILES_MANIFEST_FILE =", text)
                else:
                    self.assertIn("export RUNFILES_MANIFEST_FILE", text)


if __name__ == "__main__":
    unittest.main()
