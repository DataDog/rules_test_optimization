# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

import os
import unittest
from pathlib import Path

from python.runfiles import runfiles


class PhysicalRunfilesTest(unittest.TestCase):
    def test_selected_metadata_is_materialized_beside_manifest(self) -> None:
        runfiles_resolver = runfiles.Create()
        self.assertIsNotNone(runfiles_resolver)
        manifest_location = runfiles_resolver.Rlocation(
            os.environ["DD_TEST_OPTIMIZATION_MANIFEST_FILE"],
        )
        self.assertIsNotNone(manifest_location)
        manifest = Path(manifest_location)
        known_tests = manifest.parent / "cache" / "http" / "known_tests.json"

        self.assertTrue(manifest.is_file(), manifest)
        self.assertTrue(known_tests.is_file(), known_tests)
        self.assertIn("module:example_python_pkg", known_tests.read_text())


if __name__ == "__main__":
    unittest.main()
