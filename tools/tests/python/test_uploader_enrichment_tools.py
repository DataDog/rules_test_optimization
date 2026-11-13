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


class ReportingServiceTests(unittest.TestCase):
    def inputs(self, service="tests-one"):
        return ContextSelection({"topt.sync.repository_name": "repo", "service.name": service, "runtime.name": "go"}), {
            "bazel.target": "//pkg:test",
            "bazel.test_optimization.repo_name": "repo",
            "bazel.test_optimization.service_name": service,
            "bazel.test_optimization.runtime_name": "go",
        }

    def enrich(self, payload, context, metadata):
        return enrich_test_payload(payload, context_selection=context, bazel_metadata=metadata,
            runtime_id="runtime", rules_version="rules", codeowners_matcher=_matcher())

    def test_reporting_service_applies_only_to_the_ci_hierarchy_and_legacy_test_spans(self):
        for service in ("tests-one", "tests-two"):
            with self.subTest(service=service):
                context, metadata = self.inputs(service)
                ci_kinds = ("test", "test_suite_end", "test_module_end", "test_session_end", "span", None)
                events = [{"type": kind, "content": {"type": "test", "service": "application-default",
                    "meta": {"_dd.test.is_user_provided_service": "false"}}} for kind in ci_kinds]
                events += [
                    {"type": "span", "content": {"type": "web", "service": "application-explicit", "meta": {"test.name": "not-a-classifier"}}},
                    {"type": "future", "content": {"type": "test", "service": "future-service"}},
                ]
                payload = {"metadata": {"*": {"service": "global-conflict"}, "test": {"service": "type-conflict"}}, "events": events}

                self.enrich(payload, context, metadata)

                self.assertEqual([service] * len(ci_kinds) + ["application-explicit", "future-service"],
                    [event["content"]["service"] for event in payload["events"]])
                self.assertTrue(all(event["content"]["meta"]["_dd.test.is_user_provided_service"] == "false" for event in events[:len(ci_kinds)]))
                self.assertNotIn("service", payload["metadata"]["*"])

    def test_sources_without_a_declared_reporting_contract_keep_their_service(self):
        context, _metadata = self.inputs()
        for metadata in (None, {"bazel.target": "//pkg:test", "bazel.test_optimization.repo_name": "repo"}):
            with self.subTest(metadata=metadata):
                payload = {"events": [{"type": "test", "content": {"service": "legacy-service"}}]}
                self.enrich(payload, context, metadata)
                self.assertEqual("legacy-service", payload["events"][0]["content"]["service"])

    def test_mismatched_or_partial_declared_identity_is_not_authorized(self):
        context, metadata = self.inputs()
        for key in ("bazel.test_optimization.repo_name", "bazel.test_optimization.service_name", "bazel.test_optimization.runtime_name"):
            for value in ("different", "", None, 1):
                with self.subTest(key=key, value=value):
                    invalid = {**metadata, key: value}
                    with self.assertRaisesRegex(ValueError, "reporting service"):
                        self.enrich({"events": [{"type": "test", "content": {}}]}, context, invalid)
        for context in (ContextSelection(None), ContextSelection(None, "context_repo_not_found")):
            with self.subTest(context=context), self.assertRaisesRegex(ValueError, "reporting service"):
                self.enrich({"events": [{"type": "test", "content": {}}]}, context, metadata)


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
