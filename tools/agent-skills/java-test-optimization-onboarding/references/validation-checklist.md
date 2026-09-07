<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Java Validation Checklist

Replace `bazel` in examples with the consumer repository's real Bazel entrypoint
such as `bzl` or `./bazelw`.

This checklist validates the static Java contracts. The automatic
invocation-scoped manifest API is Go/Python-only in this release; Java does not
need a managed-manifest transition proof.

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

For the simplest customer troubleshooting request after tests have run, use
`bazel run //<topt-package>:dd_test_optimization_doctor -- --support-bundle=<path>` with any
matching BEP/artifact flags. Replace `<topt-package>` with the package that owns
the workspace's logical doctor/uploader pair (for example,
`tools/test_optimization`; use an empty package only when the targets
intentionally live at the root). Prefer the CI wrapper when the repository can
vendor the helper directory and you need uploader dry-run or upload coverage:

```bash
# Vendor the full tools/test_optimization/ helper directory when using the
# wrapper support bundle option. If CI only installs the wrapper script, set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
tools/test_optimization/run_test_optimization_ci.sh \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //path/to:java_test
```

Preserve test failure priority:

```bash
bep_json="$(mktemp "${TMPDIR:-/tmp}/dd-topt-java.XXXXXX.bep.json")"
artifact_staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")"
report_dir="${REPORT_DIR:-.topt/reports}"
mkdir -p "$report_dir"

test_status=0; doctor_status=0; uploader_status=0
bazel test --config=test-optimization --build_event_json_file="$bep_json" //path/to:java_test || test_status=$?

bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --report-json="$report_dir/doctor-report.json" || doctor_status=$?

DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
    --bep-json="$bep_json" \
    --freshness-source=bep \
    --freshness-mode=required \
    --artifact-source=bep \
    --artifact-staging-dir="$artifact_staging_dir" \
    --validate-enrichment \
    --report-json="$report_dir/uploader-upload-report.json" || uploader_status=$?

for status in "$test_status" "$doctor_status" "$uploader_status"; do
  if [ "$status" -ne 0 ]; then exit "$status"; fi
done
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
- Real upload processes every available fresh valid payload after validation
  attempts; any earlier validation failure still fails the workflow.
- Datadog shows Git metadata, Bazel metadata, and the expected test service.

Do not list build-only or analysis-only targets in doctor `expected_targets`;
they do not run instrumented test code.

## Remote Execution

If tests use remote execution or remote cache, the test config must include:

```text
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
```

Rules cannot force this client behavior. Without local materialization or BEP
artifact staging/downloader configuration, tests may pass while the doctor and
uploader cannot see payload files. Use a unique `--build_event_json_file` for
each Bazel test invocation and pass the matching paths to doctor/uploader with
repeatable `--bep-json` flags.

When debugging CI rollout failures, prefer doctor `--support-bundle` for the
first support artifact. Use wrapper `--report-dir` plus `--support-bundle`, or
set `DD_TEST_OPTIMIZATION_REPORT_DIR` and `DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE`,
when CI should archive
`doctor-report.json`, `uploader-dry-run-report.json`, optional
`uploader-upload-report.json`, and `dd-test-optimization-support.zip`.
Manual flows can pass `--report-json=<path>` to doctor/uploader.
Reports include `result.reason_code`, `result.next_steps`, expected targets,
BEP freshness, artifact staging, payload discovery, payload processing,
upload-attempt status, aggregate failures, and exit code. Use
`tools/test_optimization/create_support_bundle.py` manually if the wrapper and
doctor bundle entrypoints are unavailable but the helper script is present.
Use `tools/test_optimization/render_report_summary.py` only as a Markdown
fallback.
When a support bundle is present, inspect `summary.md`, `diagnostics.json`,
`reports/doctor-report.json`, optional uploader reports, and
`command/flags.json` in that order before drawing conclusions.

Artifact mode choices:

| Situation | Doctor/uploader flags |
|-----------|-----------------------|
| Recommended zipped CI | `--bep-json=<path> --freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=<temp-dir>` |
| Loose `test.outputs/payloads/...` exists locally without zip | BEP freshness flags are enough; `--artifact-source=bep` remains valid |
| BEP references HTTP/HTTPS `outputs.zip` artifacts | Add `--artifact-source=bep --remote-artifacts=download`; use `--remote-artifacts=required` for strict all-or-nothing validation |
| BEP references bytestream/CAS/custom-auth `test.outputs` or `outputs.zip` artifacts | Add `--artifact-source=bep --remote-artifacts=download --bep-artifact-downloader=/path/to/downloader`; use `--remote-artifacts=required` for strict all-or-nothing validation |
| Mixed migration where local outputs may be stale but BEP can stage fresh carriers | Use `--artifact-source=auto --remote-artifacts=download` so staged BEP outputs win for matching output keys |
