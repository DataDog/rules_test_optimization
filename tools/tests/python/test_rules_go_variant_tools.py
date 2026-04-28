#!/usr/bin/env python3
"""Unit tests for rules_go Orchestrion variant tooling."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from contextlib import redirect_stderr


def _runfile(rel_path: str) -> Path:
    """Resolve a Bazel runfile, with a direct-checkout fallback."""
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            candidates.append(candidate / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"runfile not found: {rel_path}")


def _load_module(name: str, rel_path: str) -> types.ModuleType:
    """Load a Python tool module from runfiles."""
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RulesGoVariantToolTests(unittest.TestCase):
    """Test the rules_go variant contract verifier."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the verifier once for all tests."""
        cls.mod = _load_module(
            "verify_rules_go_variants",
            "tools/dev/verify_rules_go_variants.py",
        )

    def test_verify_accepts_declared_difference(self) -> None:
        """The verifier accepts a complete-only change when metadata declares it."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "base"
            complete = root / "complete"
            base.mkdir()
            complete.mkdir()
            (base / "same.txt").write_text("same\n", encoding="utf-8")
            (complete / "same.txt").write_text("same\n", encoding="utf-8")
            (base / "different.txt").write_text("base\n", encoding="utf-8")
            (complete / "different.txt").write_text("complete\n", encoding="utf-8")
            metadata = root / "variants.json"
            metadata.write_text(
                json.dumps(
                    {
                        "base_path": "base",
                        "complete_path": "complete",
                        "allowed_differences": [
                            {
                                "path": "different.txt",
                                "owner": "complete",
                                "reason": "test fixture",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            original_root = self.mod.REPO_ROOT
            self.mod.REPO_ROOT = root
            try:
                self.assertEqual(0, self.mod.verify(metadata))
            finally:
                self.mod.REPO_ROOT = original_root

    def test_verify_rejects_undeclared_difference(self) -> None:
        """The verifier fails when base and complete drift without metadata."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "base"
            complete = root / "complete"
            base.mkdir()
            complete.mkdir()
            (base / "different.txt").write_text("base\n", encoding="utf-8")
            (complete / "different.txt").write_text("complete\n", encoding="utf-8")
            metadata = root / "variants.json"
            metadata.write_text(
                json.dumps(
                    {
                        "base_path": str(base),
                        "complete_path": str(complete),
                        "allowed_differences": [],
                    }
                ),
                encoding="utf-8",
            )

            original_root = self.mod.REPO_ROOT
            self.mod.REPO_ROOT = root
            try:
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(1, self.mod.verify(metadata))
            finally:
                self.mod.REPO_ROOT = original_root


if __name__ == "__main__":
    unittest.main()
