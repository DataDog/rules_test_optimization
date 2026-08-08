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

## Managed Manifest Checks

For automatic managed onboarding, additionally prove:

- there is no committed target/service mapping or Gazelle/ownership machinery;
- target patterns are expanded to exact canonical labels before sync;
- selected targets use `topt_data_by_target`;
- unselected targets keep the same raw/consumer-runner behavior;
- adding/removing a selected target changes only the command-owned manifest;
- disabled mode needs no manifest and makes zero metadata requests;
- doctor uses aggregate contexts and the generated exact-target file;
- uploader dry-run selects the correct virtual context for each Python payload;
- cache tests keep test-result caching enabled, while strict fresh-payload
  validation runs selected tests freshly.

Invoke the consumer's managed command. Do not set the internal manifest handoff
manually.

## Disabled Then Enabled On The Same Output Root

Prove the config is the only user-facing switch before fetching live metadata:

```bash
output_root="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-python-output.XXXXXX")"
sync_repo="@test_optimization_data"
public_target="//path/to:python_test"
unset DD_TEST_OPTIMIZATION_ENABLED

bazel --output_user_root="$output_root" test "$public_target"
bazel --output_user_root="$output_root" cquery \
  "${sync_repo}//:test_optimization_files" \
  --output=files

execution_root="$(
  bazel --output_user_root="$output_root" info execution_root
)"
export_rel="$(
  bazel --output_user_root="$output_root" cquery \
    "${sync_repo}//:export.bzl" \
    --output=files
)"
case "$export_rel" in
  /*) export_file="$export_rel" ;;
  *) export_file="$execution_root/$export_rel" ;;
esac
testlogs="$(
  bazel --output_user_root="$output_root" info bazel-testlogs
)"
grep -F '"enabled": False' "$export_file"
if find "$testlogs" \
  \( -path '*/test.outputs/payloads/*' -o -name bazel_target_metadata.json \) \
  -type f -print -quit | grep -q .; then
  echo "disabled run emitted Test Optimization outputs" >&2
  exit 1
fi
```

Replace `sync_repo` and `public_target` when the consumer uses different
labels. The ordinary Python runner must still execute, while Test Optimization
selectors, Bazel metadata, and payload files remain absent. When a mock metadata
server or request counter is available, require zero requests in this phase.

Then reuse the exact same `output_root`:

```bash
bazel --output_user_root="$output_root" test \
  --config=test-optimization \
  "$public_target"

export_rel="$(
  bazel --output_user_root="$output_root" cquery \
    --config=test-optimization \
    "${sync_repo}//:export.bzl" \
    --output=files
)"
case "$export_rel" in
  /*) export_file="$export_rel" ;;
  *) export_file="$execution_root/$export_rel" ;;
esac
grep -F '"enabled": True' "$export_file"
find "$testlogs" -path '*/test.outputs/payloads/tests/*.json' -type f -print
find "$testlogs" -name bazel_target_metadata.json -type f -print
```

Require both final `find` commands to return the expected files. Every
inspection command above is scoped to `output_root`; using the workspace's
default output root at either stage does not prove the disabled-to-enabled
repository transition.

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
`bazel run --config=test-optimization //<topt-package>:dd_test_optimization_doctor -- --support-bundle=<path>` with any
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
  //path/to:python_test
```

Preserve test failure priority:

```bash
bep_json="$(mktemp "${TMPDIR:-/tmp}/dd-topt-python.XXXXXX.bep.json")"
artifact_staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")"
report_dir="${REPORT_DIR:-.topt/reports}"
mkdir -p "$report_dir"

test_status=0; doctor_status=0; dry_run_status=0; upload_status=0
bazel test --config=test-optimization --build_event_json_file="$bep_json" //path/to:python_test || test_status=$?

bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --report-json="$report_dir/doctor-report.json" || doctor_status=$?

bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment \
  --report-json="$report_dir/uploader-dry-run-report.json" || dry_run_status=$?

DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
    --bep-json="$bep_json" \
    --freshness-source=bep \
    --freshness-mode=required \
    --artifact-source=bep \
    --artifact-staging-dir="$artifact_staging_dir" \
    --report-json="$report_dir/uploader-upload-report.json" || upload_status=$?

for status in "$test_status" "$doctor_status" "$dry_run_status" "$upload_status"; do
  if [ "$status" -ne 0 ]; then exit "$status"; fi
done
```

Do not run the real upload unless credentials are intentionally available and
the user or CI environment expects data to be sent.

## Expected Outputs

After tests:

- JSON payload files exist under `bazel-testlogs`.
- `bazel_target_metadata.json` exists for instrumented runtime tests.
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
Manual flows can pass `--report-json=<path>` to doctor/uploader. Reports
include `result.reason_code`, `result.next_steps`, expected targets, BEP
freshness, artifact staging, payload discovery, payload processing,
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
