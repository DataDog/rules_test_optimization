#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise behavior-free Python launchers across runfiles layouts.

Manifest-only and spaced-path cases protect Bazel portability on every platform.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
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


def _render_direct_launcher(template: Path, destination: Path, root: Path) -> None:
    main = root / "main.py"
    config = root / "config.json"
    main.write_text("# selected interpreter owns execution\n", encoding="utf-8")
    config.write_text("{}", encoding="utf-8")
    rendered = template.read_text(encoding="utf-8")
    substitutions = {
        "PYTHON_MAIN_PATH": str(main),
        "PYTHON_MAIN_RLOC": "missing/main.py",
        "PYTHON_CONFIG_PATH": str(config),
        "PYTHON_CONFIG_RLOC": "missing/config.json",
        "PYTHON_CONFIG_NAME": "missing-config.json",
    }
    for key, value in substitutions.items():
        rendered = rendered.replace(f"__DDTPL_{key}__", value)
    destination.write_text(rendered, encoding="utf-8")


def _write_versioned_python_shims(root: Path) -> tuple[Path, Path]:
    bin_dir = root / "bin"
    bin_dir.mkdir()
    marker = root / "selected-python.txt"
    old_python = bin_dir / "python3"
    old_python.write_text(
        "#!/bin/sh\n"
        'if [ "${1:-}" = "-c" ]; then exit 1; fi\n'
        "exit 97\n",
        encoding="utf-8",
    )
    compatible_python = bin_dir / "python"
    compatible_python.write_text(
        "#!/bin/sh\n"
        'if [ "${1:-}" = "-c" ]; then exit 0; fi\n'
        f"printf '%s\\n' python > {shlex.quote(str(marker))}\n",
        encoding="utf-8",
    )
    old_python.chmod(0o755)
    compatible_python.chmod(0o755)
    return bin_dir, marker


class LauncherTests(unittest.TestCase):
    def test_launchers_skip_an_unsupported_python_candidate(self) -> None:
        if os.name == "nt":
            self.skipTest("POSIX shim test")
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        cases = [("bash", "uploader_python_launcher.sh.tpl")]
        if powershell:
            cases.append((powershell, "uploader_python_launcher.ps1.tpl"))

        for executable, template_name in cases:
            with self.subTest(template=template_name), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                launcher = root / template_name.removesuffix(".tpl")
                _render_direct_launcher(
                    _repo_file(f"tools/core/{template_name}"),
                    launcher,
                    root,
                )
                if executable == "bash":
                    launcher.chmod(0o755)
                    command = [str(launcher)]
                else:
                    command = [
                        executable,
                        "-NoProfile",
                        "-NonInteractive",
                        "-File",
                        str(launcher),
                    ]
                bin_dir, marker = _write_versioned_python_shims(root)
                environment = dict(os.environ)
                environment.pop("DD_TEST_OPTIMIZATION_PYTHON", None)
                environment.pop("PYTHON", None)
                environment["PATH"] = os.pathsep.join(
                    (str(bin_dir), environment.get("PATH", ""))
                )

                completed = subprocess.run(
                    command,
                    cwd=root,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    timeout=10,
                )

                self.assertEqual(0, completed.returncode, completed.stderr)
                self.assertEqual("python", marker.read_text(encoding="utf-8").strip())

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
                self.assertIn(
                    "DD_TEST_OPTIMIZATION_UPLOADER_LAUNCHER_DIR",
                    text,
                )
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
