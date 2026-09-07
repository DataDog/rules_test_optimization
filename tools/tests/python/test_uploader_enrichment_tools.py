#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify immutable context selection and per-file test enrichment.

Focused coverage protects tag and metadata behavior independently from uploads.
"""

from __future__ import annotations

import unittest

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.codeowners import CodeOwnersMatcher, parse_codeowners  # noqa: E402
from uploader_py.enrichment import (  # noqa: E402
    ContextPlan,
    ContextRecord,
    ContextSelection,
    enrich_test_payload,
    payload_repo_key,
)


def _matcher() -> CodeOwnersMatcher:
    rules, warnings = parse_codeowners("* @default\n/src/owned.py @src\n")
    return CodeOwnersMatcher(None, "/workspace", "", rules, warnings, False)


class ContextPlanTests(unittest.TestCase):
    def test_zero_one_override_and_multiple_context_selection(self) -> None:
        empty = ContextPlan(None)
        self.assertIsNone(empty.select(None).values)

        only = ContextRecord.create("repo-one", {"service": "one"})
        one = ContextPlan(only, (only,))
        self.assertEqual("one", one.select(None).values["service"])

        two = ContextRecord.create("repo-two", {"service": "two"})
        multiple = ContextPlan(only, (only, two))
        self.assertEqual("two", multiple.select("repo-two").values["service"])
        self.assertEqual(
            "context_repo_metadata_missing",
            multiple.select(None).warning_code,
        )
        self.assertEqual(
            "context_repo_not_found",
            multiple.select("missing").warning_code,
        )

        override = ContextPlan(only, (only, two), override=True)
        self.assertEqual("one", override.select("missing").values["service"])

    def test_context_records_are_immutable(self) -> None:
        record = ContextRecord.create("repo", {"service": "value"})
        with self.assertRaises(TypeError):
            record.values["service"] = "changed"  # type: ignore[index]

    def test_repo_key_requires_nonempty_string(self) -> None:
        self.assertEqual(
            "repo",
            payload_repo_key({"bazel.test_optimization.repo_name": "repo"}),
        )
        self.assertIsNone(payload_repo_key({"bazel.test_optimization.repo_name": 1}))
        self.assertIsNone(payload_repo_key(None))


class TestPayloadEnrichmentTests(unittest.TestCase):
    def test_top_level_context_sidecar_and_codeowners_order(self) -> None:
        payload = {
            "metadata": {
                "*": {"language": "python", "env": "payload-env"},
                "test": {"keep": True},
                "unexpected": {"drop": True},
            },
            "events": [
                {
                    "type": "test",
                    "content": {
                        "meta": {"test.source.file": "src/owned.py"},
                        "metrics": "invalid",
                    },
                },
                {
                    "type": "span",
                    "content": {"meta": {"test.source.file": "src/owned.py"}},
                },
            ],
        }
        context = ContextSelection(
            ContextRecord.create(
                "repo",
                {
                    "runtime.id": "context-runtime",
                    "runtime.name": "context-language",
                    "env": "context-env",
                    "git.commit.sha": "abc",
                    "numeric": 7,
                    "enabled": True,
                    "nested": {"key": "value"},
                    "topt.api_key_fingerprint": "must-not-upload",
                },
            ).values
        )
        sidecar = {
            "bazel.target": "//pkg:test",
            "numeric": 9,
            "sidecar_bool": False,
        }
        result = enrich_test_payload(
            payload,
            context_selection=context,
            bazel_metadata=sidecar,
            runtime_id="fallback-runtime",
            rules_version="1.2.3",
            codeowners_matcher=_matcher(),
            codeowners_cache={},
        )

        self.assertEqual(
            {
                "*": {
                    "runtime-id": "context-runtime",
                    "language": "python",
                    "library_version": "1.2.3",
                    "env": "payload-env",
                },
                "test": {"keep": True},
            },
            payload["metadata"],
        )
        test_meta = payload["events"][0]["content"]["meta"]
        test_metrics = payload["events"][0]["content"]["metrics"]
        self.assertEqual("abc", test_meta["git.commit.sha"])
        self.assertEqual("//pkg:test", test_meta["bazel.target"])
        self.assertEqual("true", test_meta["enabled"])
        self.assertEqual("false", test_meta["sidecar_bool"])
        self.assertEqual('{"key":"value"}', test_meta["nested"])
        self.assertNotIn("topt.api_key_fingerprint", test_meta)
        self.assertEqual(9, test_metrics["numeric"])
        self.assertEqual('["@src"]', test_meta["test.codeowners"])

        span_meta = payload["events"][1]["content"]["meta"]
        self.assertEqual("abc", span_meta["git.commit.sha"])
        self.assertNotIn("test.codeowners", span_meta)
        self.assertEqual(1, result.codeowners.enriched)

    def test_missing_context_still_normalizes_payload(self) -> None:
        payload = {"metadata": "invalid", "events": "invalid"}
        result = enrich_test_payload(
            payload,
            context_selection=ContextSelection(
                None,
                "context_repo_metadata_missing",
            ),
            bazel_metadata=None,
            runtime_id="runtime",
            rules_version="rules",
            codeowners_matcher=CodeOwnersMatcher(None, "", ""),
        )
        self.assertEqual(
            {
                "*": {
                    "runtime-id": "runtime",
                    "language": "bazel",
                    "library_version": "rules",
                }
            },
            payload["metadata"],
        )
        self.assertEqual(("context_repo_metadata_missing",), result.warning_codes)

    def test_producer_values_win_and_bazel_sidecar_overrides_context_tags(self) -> None:
        payload = {
            "metadata": {
                "*": {
                    "runtime-id": "producer-runtime",
                    "language": "go",
                    "library_version": "producer-version",
                    "env": "producer-env",
                }
            },
            "events": [{"type": "test", "content": {"meta": {}}}],
        }
        enrich_test_payload(
            payload,
            context_selection=ContextSelection({"same": "context"}),
            bazel_metadata={"same": "sidecar"},
            runtime_id="fallback",
            rules_version="fallback",
            codeowners_matcher=CodeOwnersMatcher(None, "", ""),
        )
        self.assertEqual(
            {
                "runtime-id": "producer-runtime",
                "language": "go",
                "library_version": "producer-version",
                "env": "producer-env",
            },
            payload["metadata"]["*"],
        )
        self.assertEqual("sidecar", payload["events"][0]["content"]["meta"]["same"])


if __name__ == "__main__":
    unittest.main()
