<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Python Validation Checklist

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
- Upload endpoints and credentials should not be injected into Python test
  sandboxes.
- `DD_GIT_*` belongs to sync metadata through `--repo_env`.

For WORKSPACE consumers, also confirm:

- `datadog-rules-test-optimization` is declared before the Python helper.
- `rules_python` is declared before the Python helper.
- `datadog_python_test_optimization_workspace_repositories(...)` is used for
  `datadog-rules-test-optimization-python`.
- `rules_python_repo_name` matches the consumer repository's actual
  `rules_python` repository name.

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
bep_json="$(mktemp "${TMPDIR:-/tmp}/dd-topt-python.XXXXXX.bep.json")"
artifact_staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")"
report_dir="${REPORT_DIR:-.topt/reports}"
mkdir -p "$report_dir"

bazel test --config=test-optimization --build_event_json_file="$bep_json" //path/to:python_test || test_status=$?
test_status=${test_status:-0}

bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --report-json="$report_dir/doctor-report.json" || doctor_status=$?
doctor_status=${doctor_status:-0}
if [ "$doctor_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$doctor_status"
fi

bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment \
  --report-json="$report_dir/uploader-dry-run-report.json" || dry_run_status=$?
dry_run_status=${dry_run_status:-0}
if [ "$dry_run_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$dry_run_status"
fi

DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
    --bep-json="$bep_json" \
    --freshness-source=bep \
    --freshness-mode=required \
    --artifact-source=bep \
    --artifact-staging-dir="$artifact_staging_dir" \
    --report-json="$report_dir/uploader-upload-report.json"
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
test:test-optimization --zip_undeclared_test_outputs
```

Rules cannot force this client behavior. Without local materialization or BEP
artifact staging/downloader configuration, tests may pass while the doctor and
uploader cannot see payload files. Use a unique `--build_event_json_file` for
each Bazel test invocation and pass the matching paths to doctor/uploader with
repeatable `--bep-json` flags.

When debugging CI rollout failures, prefer a wrapper `--report-dir` or
`DD_TEST_OPTIMIZATION_REPORT_DIR` so CI archives `doctor-report.json`,
`uploader-dry-run-report.json`, and optional `uploader-upload-report.json`
separately. Manual flows can pass `--report-json=<path>` to doctor/uploader.
Reports include `result.reason_code`, `result.next_steps`, expected targets,
BEP freshness, artifact staging, payload discovery, payload processing,
upload-attempt status, aggregate failures, and exit code. Use
`tools/test_optimization/render_report_summary.py` to turn the JSON reports
into a concise Markdown summary.

Artifact mode choices:

| Situation | Doctor/uploader flags |
|-----------|-----------------------|
| Recommended zipped CI | `--bep-json=<path> --freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=<temp-dir>` |
| Loose `test.outputs/payloads/...` exists locally without zip | BEP freshness flags are enough; `--artifact-source=bep` remains valid |
| BEP references HTTP/HTTPS `outputs.zip` artifacts | Add `--artifact-source=bep --remote-artifacts=download`; use `--remote-artifacts=required` for strict all-or-nothing validation |
| BEP references bytestream/CAS/custom-auth `test.outputs` or `outputs.zip` artifacts | Add `--artifact-source=bep --remote-artifacts=download --bep-artifact-downloader=/path/to/downloader`; use `--remote-artifacts=required` for strict all-or-nothing validation |
| Mixed migration where local outputs may be stale but BEP can stage fresh carriers | Use `--artifact-source=auto --remote-artifacts=download` so staged BEP outputs win for matching output keys |
