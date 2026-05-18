<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Validation Checklist

Use this checklist before calling a `rules_go` upstream migration complete.

## Metadata And Inventory

Run these checks after editing either variant:

```bash
python3 tools/dev/verify_rules_go_variants.py
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_base.METADATA.json
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_complete.METADATA.json
git diff -- third_party/rules_go_orchestrion_base.CHANGED_FILES.md
git diff -- third_party/rules_go_orchestrion_complete.CHANGED_FILES.md
git diff -- third_party/rules_go_orchestrion_variants.json
```

Expected:

- variant verification passes
- both diff commands report the same counts as the regenerated reports
- generated reports name the new upstream tag or commit
- every `complete`-only difference is declared
- no generated report was edited manually

## Fast Variant Smoke

Run both published variants:

```bash
RULES_GO_VARIANT=base tools/dev/run_rules_go_variant_smoke.sh
RULES_GO_VARIANT=complete tools/dev/run_rules_go_variant_smoke.sh
```

If the migration changes slow or platform-sensitive areas, also run:

```bash
RULES_GO_VARIANT=base tools/dev/run_rules_go_variant_extended.sh
RULES_GO_VARIANT=complete tools/dev/run_rules_go_variant_extended.sh
```

## Go Consumer Integration

Run both WORKSPACE and Bzlmod integration harnesses when the migration touches
Orchestrion wiring, module proxy handling, stdlib behavior, transitions, or
builder actions:

```bash
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=base \
  tools/tests/integration/run_workspace_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=complete \
  tools/tests/integration/run_workspace_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=base \
  tools/tests/integration/run_bzlmod_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=complete \
  tools/tests/integration/run_bzlmod_go_integration.sh
```

Expected:

- normal mode passes
- hermetic mode passes
- structural `aquery` assertions for offline module proxy wiring pass
- payload files are written under `bazel-testlogs`
- payload metadata does not show unexpected fallback states

## Repository-Level Regression

Run root or focused repository tests when changed files overlap repository
helpers or companion integration:

```bash
./bazelw test //tools/...
cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
```

Run broader checks when the migration also touches shared scripts, docs, or
workspace wiring:

```bash
./bazelw test //...
./bazelw build //examples/...
```

## Cross-Repository Fixture

If the migration is intended to validate consumer-style behavior before a PR is
called done, run the sibling fixture repository with local overrides:

1. In `../rules_test_optimization_tests/MODULE.bazel`, enable the documented
   `local_path_override(...)` entries for this repository and affected
   companion modules.
2. Add a temporary `rules_go` override pointing to the migrated local variant:
   `../rules_test_optimization/third_party/rules_go_orchestrion_base` or
   `../rules_test_optimization/third_party/rules_go_orchestrion_complete`.
3. Run the fixture's documented entrypoint, such as:

```bash
cd ../rules_test_optimization_tests
./runtests
./runtests-hermetic
```

Restore the fixture repository to its pinned overrides before committing or
pushing changes there.

## Runtime Correctness Checks

For stdlib, synthetic `testmain`, module proxy, or tool-version changes, do not
stop at build success. Inspect runtime behavior:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*" -type f | sort
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

Expected:

- JSON payload files exist for instrumented runtime tests.
- `bazel_target_metadata.json` exists for instrumented runtime tests.
- CI Visibility starts in the test process.
- No `.msgpack` or `.msgpack.gz` payloads are emitted.
- No unexpected `full_bundle_no_match` state appears.

## Completion Gate

Before final response or PR handoff, record:

- exact commands run
- pass/fail result for each command
- skipped commands and concrete reasons
- local environment blockers, if any
- whether review or CI follow-up remains
