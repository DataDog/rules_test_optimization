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
                "PYTHON_MAIN_RLOC": "repo/tools/core/uploader_main.py",
                "PYTHON_CONFIG_PATH": "missing/direct/config.json",
                "PYTHON_CONFIG_RLOC": "repo/generated/config.json",
                "PYTHON_CONFIG_NAME": config.name,
            }
            for key, value in substitutions.items():
                rendered = rendered.replace(f"__DDTPL_{key}__", value)
            self.assertNotIn("__DDTPL_", rendered)
            launcher.write_text(rendered, encoding="utf-8")
            launcher.chmod(0o755)
            manifest = root / "MANIFEST"
            manifest.write_text(
                f"repo/tools/core/uploader_main.py {main}\n",
                encoding="utf-8",
            )
            environment = {
                "PATH": os.environ.get("PATH", ""),
                "DD_TEST_OPTIMIZATION_PYTHON": sys.executable,
                "RUNFILES_MANIFEST_FILE": str(manifest),
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "TESTLOGS_DIR": str(testlogs),
            }

            completed = subprocess.run(
                [
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
            self.assertIn("summary: mode=dry-run", completed.stdout)

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


if __name__ == "__main__":
    unittest.main()
