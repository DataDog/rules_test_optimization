<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Java Validation Checklist

Replace `bazel` in examples with the consumer repository's real Bazel entrypoint
such as `bzl` or `./bazelw`.

## Static Checks

Check for invalid sandbox environment patterns:

```bash
rg -n \
  --hidden \
  --glob ".bazelrc*" \
  --glob ".github/**" \
  --glob "BUILD*" \
  --glob "*.bzl" \
  --glob "WORKSPACE*" \
  --glob "MODULE.bazel" \
  -- "--test_env(=|[[:space:]]+)=?(DD_GIT_|DD_TEST_OPTIMIZATION_AGENT_URL|DD_TEST_OPTIMIZATION_AGENTLESS_URL)" .
```

Interpretation:

- `--test_env=DD_GIT_*` is invalid outside explicit negative tests or docs that
  warn against it.
- Upload endpoints and credentials should not be injected into Java test
  sandboxes.
- `DD_GIT_*` belongs to sync metadata through `--repo_env`.

Also check for manual Java payload wiring in consumer tests:

```bash
rg -n \
  --hidden \
  --glob "BUILD*" \
  --glob "*.bzl" \
  "DD_TEST_OPTIMIZATION_MANIFEST_FILE|DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES|DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME" .
```

Those variables are owned by `dd_topt_java_test`. Manual uses are suspicious
unless they are rule tests or docs that explicitly explain the rule behavior.

For WORKSPACE consumers, also confirm:

- `datadog-rules-test-optimization` is declared before the Java helper.
- `rules_java` is declared before the Java helper.
- `datadog_java_test_optimization_workspace_repositories(...)` is used for
  `datadog-rules-test-optimization-java`.
- `rules_java_repo_name` matches the consumer repository's actual `rules_java`
  repository name.

## Sync

Normal sync should not use `FETCH_SALT`:

```bash
bazel sync --config=test-optimization --only=test_optimization_data
```

Force a fresh metadata fetch only when debugging stale backend data or when an
operator explicitly asks for a refresh:

```bash
bazel sync --config=test-optimization \
  --only=test_optimization_data \
  --repo_env=FETCH_SALT="$(date +%s)"
```

If WORKSPACE mode is disabled by Bazel, retry with:

```bash
bazel sync --enable_workspace --config=test-optimization \
  --only=test_optimization_data \
  --repo_env=FETCH_SALT="$(date +%s)"
```

## Test, Doctor, Dry-Run, Upload

Preserve test failure priority:

```bash
mkdir -p .topt
rm -f .topt/pilot.bep.json
bazel test --config=test-optimization --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=.topt/pilot.bep.json //path/to:java_test || test_status=$?
test_status=${test_status:-0}

bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json=.topt/pilot.bep.json \
  --freshness-source=bep \
  --freshness-mode=required || doctor_status=$?
doctor_status=${doctor_status:-0}
if [ "$doctor_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$doctor_status"
fi

bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json=.topt/pilot.bep.json \
  --freshness-source=bep \
  --freshness-mode=required \
  --dry-run \
  --validate-enrichment || dry_run_status=$?
dry_run_status=${dry_run_status:-0}
if [ "$dry_run_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$dry_run_status"
fi

DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
    --bep-json=.topt/pilot.bep.json \
    --freshness-source=bep \
    --freshness-mode=required
upload_status=$?

if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
exit "$upload_status"
```

Do not run the real upload unless credentials are intentionally available and
the user or CI environment expects data to be sent.

## Expected Outputs

After tests:

- JSON payload files exist under `bazel-testlogs`.
- `bazel_target_metadata.json` exists for instrumented runtime tests.
- The raw Java test is wrapped by a Test Optimization executable target.
- Java tests set `stage_sources = True` directly or through their repo-local
  wrapper, unless the repository explicitly accepts missing source location
  tags.
- The doctor passes.
- Dry-run enrichment passes.
- Real upload sends data only after local validation succeeds.
- Datadog shows Git metadata, Bazel metadata, and the expected test service.

Do not list build-only or analysis-only targets in doctor `expected_targets`;
they do not run instrumented test code.

## Remote Execution

If tests use remote execution or remote cache, the test config must include:

```text
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
```

If the pilot test command uses `--zip_undeclared_test_outputs`, include
`--artifact-source=bep` in the matching doctor and uploader commands.

Rules cannot force this client behavior. Without it, tests may pass while the
doctor and uploader cannot see local payload files. Use a unique
`--build_event_json_file` for each Bazel test invocation and pass the same BEP
file to doctor/uploader with `--freshness-source=bep --freshness-mode=required`.

Artifact mode choices:

| Situation | Doctor/uploader flags |
|-----------|-----------------------|
| Loose `test.outputs/payloads/...` exists locally | `--bep-json ... --freshness-source=bep --freshness-mode=required` |
| Tests used `--zip_undeclared_test_outputs` and local `outputs.zip` exists | Add `--artifact-source=bep` |
| BEP references remote/CAS `test.outputs` or `outputs.zip` artifacts | Add `--artifact-source=bep --remote-artifacts=download --bep-artifact-downloader=/path/to/downloader`; use `--remote-artifacts=required` for strict all-or-nothing validation |
| Mixed migration where local outputs may be stale but BEP can stage fresh carriers | Use `--artifact-source=auto --remote-artifacts=download` so staged BEP outputs win for matching output keys |
