#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Parity tests for the invocation-wide Python CODEOWNERS matcher."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import sys
import tempfile
import unittest


def _runfile(rel_path: str) -> Path:
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    candidates: list[Path] = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace_dir:
        candidates.append(Path(workspace_dir) / rel_path)
    for parent in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        if (parent / "MODULE.bazel").exists() or (parent / ".git").exists():
            candidates.append(parent / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate
    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).is_file():
        keys = {rel_path, f"{test_workspace}/{rel_path}"}
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            for line in handle:
                key, separator, value = line.rstrip("\n").partition(" ")
                if separator and key in keys:
                    return Path(value)
    raise FileNotFoundError(f"runfile not found: {rel_path}")


CORE_DIR = _runfile("tools/core/uploader_main.py").parent
if str(CORE_DIR) not in sys.path:
    sys.path.insert(0, str(CORE_DIR))

from uploader_py.codeowners import (  # noqa: E402
    CodeOwnersMatcher,
    enrich_payload_codeowners,
    load_codeowners_matcher,
    normalize_path_like,
    parse_codeowners,
    source_candidates,
)


CODEOWNERS_FIXTURE = r"""
[CoreTeam]
[Core Team] @org/section-space
* @org/default
[xy] @org/class-owner
[abc] @org/class-owner-abc
[A1B2C3] @org/class-owner-alnum-long
[ABCD] @org/class-owner-upper-long
[ABC] @org/class-owner-upper
[Abc] @org/class-owner-mixed
[Backend] @org/section-default
/manual/owned.cs @org/owned
/manual/unowned.cs
/manual/comment_only.cs # explicit empty-owner rule via inline comment
/manual/hash_owner.cs @org/team#chat
/manual/space\ owner.cs @org/space-owner
/manual/dir/ @org/dir-owner
/manual/literal\*.cs @org/literal-star
/manual/literal\?.cs @org/literal-question
/manual/literal\[ab\].cs @org/literal-brackets
/manual/duplicate_owners.cs @org/dedupe @org/dedupe @org/extra
/manual/last_match.cs @org/first
/manual/last_match.cs @org/second
/manual/override_empty.cs @org/will-be-overridden
/manual/override_empty.cs
/manual/file_scheme.cs @org/file-scheme
/manual/percent_slash.cs @org/percent-slash
/manual/dotnorm.cs @org/dotnorm
/external/local/file.cs @org/repo-external
/tracer/test/test-applications/integrations/Samples.XUnitTests/[Tt]estSuite.cs @DataDog/ci-app-libraries-dotnet
/manual/[z-a].cs @org/invalid-range
/manual/tab_sep.cs	@org/tab-owner
""".lstrip()


def _fixture_matcher(
    *,
    workspace_root: str = "/workspace",
    context_workspace: str = "",
    windows_paths: bool = False,
) -> CodeOwnersMatcher:
    rules, warnings = parse_codeowners(CODEOWNERS_FIXTURE)
    return CodeOwnersMatcher(
        source_path=Path("CODEOWNERS"),
        workspace_root=workspace_root,
        context_workspace=context_workspace,
        rules=rules,
        warnings=warnings,
        windows_paths=windows_paths,
    )


class CodeOwnersMatcherTests(unittest.TestCase):
    def test_existing_integration_fixture_cases_match_python(self) -> None:
        matcher = _fixture_matcher()
        checks = (
            ("manual/owned.cs", ("@org/owned",)),
            ("manual/unowned.cs", ()),
            ("manual/comment_only.cs", ()),
            ("manual/hash_owner.cs", ("@org/team#chat",)),
            ("manual/space owner.cs", ("@org/space-owner",)),
            ("manual/dir/sub/file.cs", ("@org/dir-owner",)),
            ("manual/literal*.cs", ("@org/literal-star",)),
            ("manual/literal?.cs", ("@org/literal-question",)),
            ("manual/literal[ab].cs", ("@org/literal-brackets",)),
            ("manual/duplicate_owners.cs", ("@org/dedupe", "@org/extra")),
            ("manual/last_match.cs", ("@org/second",)),
            ("manual/override_empty.cs", ()),
            ("file://manual/file_scheme.cs", ("@org/file-scheme",)),
            ("manual%2Fpercent_slash.cs", ("@org/percent-slash",)),
            ("./manual/sub/../dotnorm.cs", ("@org/dotnorm",)),
            ("../manual/owned.cs", None),
            ("manual%00owned.cs", ("@org/default",)),
            ("manual%2Gbad.cs", ("@org/default",)),
            ("/tmp/mock.runfiles/_main/manual/owned.cs", ("@org/owned",)),
            ("/tmp/mock.runfiles/_main/external/rules_go/pkg/file.go", None),
            ("/tmp/execroot/mock_ws/_main/manual/owned.cs", ("@org/owned",)),
            ("manual/tab_sep.cs", ("@org/tab-owner",)),
            ("x", ("@org/class-owner",)),
            ("a", ("@org/class-owner-abc",)),
            ("B", ("@org/class-owner-upper",)),
            ("D", ("@org/class-owner-upper-long",)),
            ("2", ("@org/class-owner-alnum-long",)),
            ("b", ("@org/class-owner-mixed",)),
            ("[Core", ("@org/default",)),
            ("manual/invalid_range.cs", ("@org/default",)),
            ("manual%5Cowned.cs", ("@org/owned",)),
            ("/tmp/not-in-workspace/manual_external.cs", None),
            ("/tmp/execroot/mock_ws/external/rules_go/pkg/file.go", None),
            ("external/local/file.cs", ("@org/repo-external",)),
            (
                "tracer/test/test-applications/integrations/"
                "Samples.XUnitTests/TestSuite.cs",
                ("@DataDog/ci-app-libraries-dotnet",),
            ),
            ("manual/z/file.cs", ("@org/default",)),
        )
        for source, expected in checks:
            with self.subTest(source=source):
                match = matcher.match_source(source)
                if expected is None:
                    self.assertFalse(match.matched)
                else:
                    self.assertTrue(match.matched)
                    self.assertEqual(expected, match.owners)
        self.assertEqual(1, len(matcher.warnings))
        self.assertIn("invalid CODEOWNERS rule", matcher.warnings[0])

    def test_workspace_stripping_derived_paths_and_generated_paths(self) -> None:
        self.assertEqual(
            ("src/pkg/file.go",),
            source_candidates(
                "/workspace/src/pkg/file.go",
                workspace_root="/workspace",
            ),
        )
        self.assertEqual(
            ("manual/owned.cs", "_main/manual/owned.cs"),
            source_candidates(
                "/tmp/execroot/ws/_main/manual/owned.cs",
                workspace_root="/workspace",
            ),
        )
        self.assertEqual(
            (),
            source_candidates(
                "/tmp/execroot/ws/external/repo/file.go",
                workspace_root="/workspace",
            ),
        )
        self.assertEqual(
            (),
            source_candidates("bazel-out/darwin-fastbuild/bin/generated.go"),
        )
        self.assertEqual(
            ("Src/File.cs",),
            source_candidates(
                r"c:\repo\Src\File.cs",
                workspace_root="C:/Repo",
                windows_paths=True,
            ),
        )

    def test_normalization_is_safe_and_deterministic(self) -> None:
        self.assertEqual("manual/owned.cs", normalize_path_like("manual%5Cowned.cs"))
        self.assertEqual("C:/repo/file.cs", normalize_path_like("file:///C:/repo/file.cs"))
        self.assertIsNone(normalize_path_like("../outside.cs"))
        self.assertEqual("manual%00owned.cs", normalize_path_like("manual%00owned.cs"))

    def test_double_star_character_classes_and_last_match_wins(self) -> None:
        rules, warnings = parse_codeowners(
            "docs/**/test?.py @docs\n"
            "docs/private/** @private\n"
            "docs/private/generated/**\n"
            "[!a-z] @upper\n"
        )
        matcher = CodeOwnersMatcher(None, "", "", rules, warnings, False)
        self.assertEqual(("@docs",), matcher.match_source("docs/test1.py").owners)
        self.assertEqual(("@docs",), matcher.match_source("docs/a/test2.py").owners)
        self.assertEqual(("@private",), matcher.match_source("docs/private/a.txt").owners)
        self.assertEqual((), matcher.match_source("docs/private/generated/a.txt").owners)
        self.assertEqual(("@upper",), matcher.match_source("Z").owners)

    def test_rules_and_matcher_are_immutable(self) -> None:
        matcher = _fixture_matcher()
        with self.assertRaises(FrozenInstanceError):
            matcher.workspace_root = "changed"  # type: ignore[misc]
        with self.assertRaises(FrozenInstanceError):
            matcher.rules[0].owners = ("changed",)  # type: ignore[misc]


class CodeOwnersDiscoveryTests(unittest.TestCase):
    def test_discovery_precedence_and_explicit_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            context = root / "context"
            workspace = root / "workspace"
            cwd = root / "cwd"
            launcher = root / "launcher"
            for directory in (context / ".github", workspace, cwd, launcher):
                directory.mkdir(parents=True, exist_ok=True)
            context_file = context / ".github" / "CODEOWNERS"
            workspace_file = workspace / "CODEOWNERS"
            cwd_file = cwd / "CODEOWNERS"
            launcher_file = launcher / "CODEOWNERS"
            context_file.write_text("* @context\n", encoding="utf-8")
            workspace_file.write_text("* @workspace\n", encoding="utf-8")
            cwd_file.write_text("* @cwd\n", encoding="utf-8")
            launcher_file.write_text("* @launcher\n", encoding="utf-8")

            discovered = load_codeowners_matcher(
                explicit_path=root / "missing-explicit",
                workspace_root=workspace,
                context_workspace=str(context),
                cwd=cwd,
                launcher_directory=launcher,
                windows_paths=False,
            )
            self.assertEqual(context_file.resolve(), discovered.source_path)
            self.assertEqual(("@context",), discovered.match_source("any/file").owners)

            explicit = load_codeowners_matcher(
                explicit_path=workspace_file,
                workspace_root=workspace,
                context_workspace=str(context),
                cwd=cwd,
                launcher_directory=launcher,
                windows_paths=False,
            )
            self.assertEqual(workspace_file.resolve(), explicit.source_path)
            self.assertEqual(("@workspace",), explicit.match_source("any/file").owners)

    def test_missing_or_unreadable_file_is_best_effort(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            matcher = load_codeowners_matcher(
                explicit_path=root / "missing",
                workspace_root=root,
                cwd=root,
                windows_paths=False,
            )
            self.assertFalse(matcher.enabled)
            self.assertIsNone(matcher.source_path)

    def test_matcher_is_loaded_once_then_shared_for_concurrent_reads(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            codeowners = root / "CODEOWNERS"
            codeowners.write_text(CODEOWNERS_FIXTURE, encoding="utf-8")
            matcher = load_codeowners_matcher(
                explicit_path=codeowners,
                workspace_root=root,
                cwd=root,
                windows_paths=False,
            )
            codeowners.unlink()
            sources = ["manual/owned.cs", "manual/default.cs"] * 100
            with ThreadPoolExecutor(max_workers=12) as executor:
                results = list(executor.map(matcher.match_source, sources))

        self.assertEqual(("@org/owned",), results[0].owners)
        self.assertEqual(("@org/default",), results[1].owners)
        self.assertTrue(all(result.matched for result in results))


class CodeOwnersEnrichmentTests(unittest.TestCase):
    def test_event_enrichment_preserves_existing_and_skips_spans(self) -> None:
        matcher = _fixture_matcher()
        payload = {
            "events": [
                {
                    "type": "test",
                    "content": {
                        "meta": {
                            "test.source.file": "manual/owned.cs",
                            "test.codeowners": '["@existing"]',
                        }
                    },
                },
                {
                    "type": "span",
                    "content": {"meta": {"test.source.file": "manual/owned.cs"}},
                },
                {
                    "type": "test_module_end",
                    "content": {"source": {"path": "manual/owned.cs"}},
                },
                {
                    "type": "test",
                    "content": {"meta": {"test.source.path": "manual/unowned.cs"}},
                },
                {"type": "test", "content": {"meta": {}}},
            ]
        }
        cache = {}
        stats = enrich_payload_codeowners(payload, matcher, cache=cache)

        events = payload["events"]
        self.assertEqual('["@existing"]', events[0]["content"]["meta"]["test.codeowners"])
        self.assertNotIn("test.codeowners", events[1]["content"]["meta"])
        self.assertEqual(
            '["@org/owned"]',
            events[2]["content"]["meta"]["test.codeowners"],
        )
        self.assertNotIn("test.codeowners", events[3]["content"]["meta"])
        self.assertEqual(4, stats.scanned)
        self.assertEqual(1, stats.enriched)
        self.assertEqual(1, stats.skipped_existing)
        self.assertEqual(1, stats.skipped_missing_source)
        self.assertEqual(1, stats.skipped_unmatched)
        self.assertEqual(2, len(cache))

    def test_disabled_matcher_is_a_noop(self) -> None:
        payload = {"events": [{"type": "test", "content": {"meta": {}}}]}
        stats = enrich_payload_codeowners(
            payload,
            CodeOwnersMatcher(None, "", ""),
        )
        self.assertEqual(0, stats.scanned)
        self.assertEqual(
            {"events": [{"type": "test", "content": {"meta": {}}}]},
            payload,
        )


if __name__ == "__main__":
    unittest.main()
