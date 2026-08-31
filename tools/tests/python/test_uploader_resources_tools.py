#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify pre-worker context, telemetry-facts, and schema loading.

These tests ensure shared resources are resolved once and selected deterministically.
"""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from uploader_py.resources import ResourceError, ResourceInputs, load_resources  # noqa: E402


def _json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


class ResourceLoadingTests(unittest.TestCase):
    def test_runtime_selection_loads_sorted_keyed_contexts_and_facts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            entries = []
            for repo, service in (("repo-b", "service-b"), ("repo-a", "service-a")):
                directory = root / repo
                context = directory / "context.json"
                facts = directory / "telemetry_facts.json"
                _json(
                    context,
                    {
                        "topt.sync.repository_name": repo,
                        "service.name": service,
                        "runtime.name": "go",
                    },
                )
                _json(
                    facts,
                    {
                        "schema_version": 1,
                        "service_name": service,
                        "runtime_name": "go",
                        "counts": [],
                        "distributions": [],
                    },
                )
                entries.append(f"{repo}={context.relative_to(root)}")

            loaded = load_resources(
                RunfilesResolver.from_environment(environ={}, cwd=root),
                ResourceInputs(
                    runtime_context_entries=tuple(entries),
                    runtime_selection=True,
                    invocation_cwd=root,
                ),
            )

            self.assertEqual(
                ("repo-a", "repo-b"),
                tuple(record.repo_key for record in loaded.context_plan.by_repo),
            )
            self.assertEqual(
                "service-a",
                loaded.context_plan.select("repo-a").values["service.name"],
            )
            self.assertEqual(
                "context_repo_not_found",
                loaded.context_plan.select("different-repo").warning_code,
            )
            self.assertEqual("service-a", loaded.primary_context["service.name"])
            self.assertEqual(
                (
                    (root / "repo-a" / "telemetry_facts.json").resolve(),
                    (root / "repo-b" / "telemetry_facts.json").resolve(),
                ),
                loaded.telemetry_facts_paths,
            )

    def test_runtime_selection_fails_before_optional_resource_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            with self.assertRaisesRegex(ResourceError, "at least one --context-entry"):
                load_resources(
                    resolver,
                    ResourceInputs(runtime_selection=True, invocation_cwd=root),
                )

            context = root / "context.json"
            facts = root / "telemetry_facts.json"
            _json(
                context,
                {
                    "topt.sync.repository_name": "different-repo",
                    "service.name": "service",
                    "runtime.name": "go",
                },
            )
            _json(
                facts,
                {
                    "schema_version": 1,
                    "service_name": "service",
                    "runtime_name": "go",
                    "counts": [],
                    "distributions": [],
                },
            )
            with self.assertRaisesRegex(ResourceError, "identity or schema mismatch"):
                load_resources(
                    resolver,
                    ResourceInputs(
                        runtime_context_entries=(f"repo={context}",),
                        runtime_selection=True,
                        invocation_cwd=root,
                    ),
                )

    def test_manifest_loads_normalized_contexts_facts_and_schema_once(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            context_a = root / "context-a.json"
            context_b = root / "context-b.json"
            facts = root / "telemetry facts.json"
            schema = root / "schema.json"
            _json(context_a, {"env": "a", "ci.workspace_path": "/workspace"})
            _json(context_b, {"env": "b"})
            _json(facts, {"service_name": "service"})
            _json(schema, {"type": "object"})
            context_manifest = root / "contexts.manifest"
            context_manifest.write_text(
                f"canonical+repo_a\tmissing-a\t{context_a}\n"
                f"repo_b\tmissing-b\t{context_b}\n",
                encoding="utf-8",
            )
            facts_manifest = root / "facts.manifest"
            facts_manifest.write_text(
                f"missing-facts\t{facts}\n",
                encoding="utf-8",
            )
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)

            loaded = load_resources(
                resolver,
                ResourceInputs(
                    context_manifest_paths=(str(context_manifest),),
                    telemetry_facts_manifest_paths=(str(facts_manifest),),
                    schema_paths=(str(schema),),
                ),
            )

            self.assertEqual("a", loaded.context_plan.select("repo_a").values["env"])
            self.assertEqual("b", loaded.context_plan.select("repo_b").values["env"])
            self.assertEqual("/workspace", loaded.context_workspace)
            self.assertEqual((facts.resolve(),), loaded.telemetry_facts_paths)
            self.assertEqual({"type": "object"}, loaded.schema)
            self.assertEqual((), loaded.warning_codes)

    def test_valid_override_wins_and_adds_sibling_telemetry_facts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            override = root / "context.json"
            sibling = root / "telemetry_facts.json"
            _json(override, {"env": "override"})
            _json(sibling, {"service_name": "override-service"})
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)

            loaded = load_resources(
                resolver,
                ResourceInputs(context_override=override),
            )

            self.assertTrue(loaded.context_plan.override)
            self.assertEqual("override", loaded.context_plan.select("anything").values["env"])
            self.assertEqual((sibling.resolve(),), loaded.telemetry_facts_paths)

    def test_invalid_optional_inputs_warn_and_disable_without_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            bad_override = root / "bad-context.json"
            bad_override.write_text('{"env":NaN}', encoding="utf-8")
            bad_schema = root / "bad-schema.json"
            bad_schema.write_text("not-json", encoding="utf-8")
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)

            loaded = load_resources(
                resolver,
                ResourceInputs(
                    context_override=bad_override,
                    context_manifest_paths=("missing.manifest",),
                    schema_paths=(str(bad_schema),),
                ),
            )

            self.assertIsNone(loaded.context_plan.primary)
            self.assertIsNone(loaded.schema)
            self.assertIn("context_override_invalid", loaded.warning_codes)
            self.assertIn("context_manifest_unresolved", loaded.warning_codes)
            self.assertIn("schema_invalid_or_unresolved", loaded.warning_codes)


if __name__ == "__main__":
    unittest.main()
