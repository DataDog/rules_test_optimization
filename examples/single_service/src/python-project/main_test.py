# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

import os
import importlib.util
import unittest

_TEST_OPTIMIZATION_FILES = [
    os.path.join("cache", "http", "settings.json"),
    os.path.join("cache", "http", "known_tests.json"),
    os.path.join("cache", "http", "test_management.json"),
]

def _load_main_module():
    module_path = os.path.join(os.path.dirname(__file__), "main.py")
    spec = importlib.util.spec_from_file_location("main_module", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load main.py module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _resolve_runfile(path):
    if not path:
        return ""
    if os.path.exists(path):
        return path

    runfiles_dir = os.getenv("RUNFILES_DIR", "")
    if runfiles_dir:
        candidate = os.path.join(runfiles_dir, path)
        if os.path.exists(candidate):
            return candidate

    manifest_file = os.getenv("RUNFILES_MANIFEST_FILE", "")
    if manifest_file and os.path.exists(manifest_file):
        with open(manifest_file, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split(" ", 1)
                if len(parts) == 2 and parts[0] == path and os.path.exists(parts[1]):
                    return parts[1]

    test_srcdir = os.getenv("TEST_SRCDIR", "")
    if test_srcdir:
        candidate = os.path.join(test_srcdir, path)
        if os.path.exists(candidate):
            return candidate

    return ""


class HelloTest(unittest.TestCase):
    def test_greeting(self):
        module = _load_main_module()
        self.assertEqual("Hello from Python!", module.get_greeting())

    def test_manifest_metadata_files_present(self):
        manifest_rloc = os.getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE", "")
        self.assertTrue(manifest_rloc, "DD_TEST_OPTIMIZATION_MANIFEST_FILE should be set by dd_topt_py_test")

        manifest_path = _resolve_runfile(manifest_rloc)
        self.assertTrue(manifest_path, "failed to resolve manifest runfile path")

        manifest_dir = os.path.dirname(manifest_path)
        for rel_path in _TEST_OPTIMIZATION_FILES:
            file_path = os.path.join(manifest_dir, rel_path)
            self.assertTrue(os.path.exists(file_path), "missing metadata file: %s" % rel_path)
            with open(file_path, "r", encoding="utf-8") as handle:
                self.assertTrue(handle.read().strip(), "expected non-empty metadata file: %s" % rel_path)


if __name__ == "__main__":
    unittest.main()
