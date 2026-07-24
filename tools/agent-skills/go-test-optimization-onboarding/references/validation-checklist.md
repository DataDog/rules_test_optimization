<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Validation Checklist

Use this checklist before calling a Go onboarding complete.

Replace `bazel` in these examples with the consumer repository's real Bazel
entrypoint, such as `bzl` or `./bazelw`.

## Local Structural Checks

Check the repository for invalid or review-required patterns:

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
rg -n -- "rules_go_patches|patches = \\[|patch_tool|patch_args|full_bundle_no_match" .
```

Interpretation:

- `--test_env=DD_GIT_*` is invalid outside explicit negative tests or docs that
  warn against it.
- `DD_TEST_OPTIMIZATION_AGENT_URL` and `DD_TEST_OPTIMIZATION_AGENTLESS_URL`
  should not be injected into Go test sandboxes.
- `DD_TEST_OPTIMIZATION_AGENTLESS_URL` can be forwarded as `--repo_env` for
  sync metadata fetches; this check is only about `--test_env`.
- Manual `rules_go` patches should not be part of new onboarding.
- `full_bundle_no_match` is valid for inferred/derived selection when no module
  group matches. Treat it as a stop condition only when the rollout requires a
  specific module group for that target; explicit selectors should fail
  analysis rather than produce this state when module groups exist.

Check that the root pin labels referenced by wrappers are visible:

```bash
bazel query 'set(//:go.mod //:go.sum //:orchestrion.tool.go //:orchestrion.yml)'
```

If the repository keeps Go module files outside the root, query the actual
labels used in `orchestrion_pin_files` instead.

For Bzlmod manual wiring, confirm `MODULE.bazel` has an Orchestrion-enabled
`rules_go` override and `orchestrion.from_source(...)` wiring. If guided
bootstrap wrote the setup, this is in the Datadog-managed module block.

## Disabled Then Enabled On The Same Output Root

Before fetching live metadata, prove the single-switch contract on one fresh
Bazel output root:

```bash
output_root="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-go-output.XXXXXX")"
sync_repo="@test_optimization_data_<service_key>"
public_target="//path/to:public_test"
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

Replace `<service_key>` and `//path/to:public_test` with the consumer's real
repository and target. The ordinary public test must run, no Test Optimization
payload or Bazel metadata files may appear for that target, and disabled
repository resolution must not require a real Orchestrion tool repository or
host Go binary. When the consumer test harness exposes a metadata-server
request counter, require zero requests in this phase.

Then reuse the exact same `output_root` for the enabled path:

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

Require both final `find` commands to return the expected files, then inspect
the Bazel metadata for the expected Orchestrion mode. Every inspection command
above is scoped to `output_root`; using the workspace's default output root at
either stage does not prove the disabled-to-enabled repository transition.
For the hermetic SDK proof, run this transition in an environment where a host
`go` binary is absent from `PATH` after bootstrap has written the workspace
files. The enabled phase must build or restore Orchestrion through the
Bazel-managed SDK declared by the workspace.

## Sync

Normal sync should not use `FETCH_SALT`. Replace
`test_optimization_data_<service_key>` with the actual sync repository name:

```bash
bazel sync --config=test-optimization \
  --only=test_optimization_data_<service_key>
```

Force a fresh metadata fetch only when debugging stale backend data or when an
operator explicitly asks for a refresh:

```bash
bazel sync --config=test-optimization \
  --only=test_optimization_data_<service_key> \
  --repo_env=FETCH_SALT="$(date +%s)"
```

If WORKSPACE mode is disabled by Bazel, retry with:

```bash
bazel sync --enable_workspace --config=test-optimization \
  --only=test_optimization_data_<service_key> \
  --repo_env=FETCH_SALT="$(date +%s)"
```

Inspect the generated repository when needed:

```bash
ls -la "$(bazel info output_base)/external/test_optimization_data_<service_key>/.testoptimization"
cat "$(bazel info output_base)/external/test_optimization_data_<service_key>/export.bzl"
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
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //path/to:pilot_test
```

Use this command shape and preserve test failure priority:

```bash
bep_json="$(mktemp "${TMPDIR:-/tmp}/dd-topt-go.XXXXXX.bep.json")"
artifact_staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")"
report_dir="${REPORT_DIR:-.topt/reports}"
mkdir -p "$report_dir"

bazel test --config=test-optimization --build_event_json_file="$bep_json" //path/to:pilot_test || test_status=$?
test_status=${test_status:-0}

bazel run --config=test-optimization //<topt-package>:dd_test_optimization_doctor -- \
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

bazel run --config=test-optimization //<topt-package>:dd_upload_payloads -- \
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
  bazel run --config=test-optimization //<topt-package>:dd_upload_payloads -- \
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

## Payload Inspection

After tests, inspect `bazel-testlogs`:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*" -type f | sort
find bazel-testlogs -path "*/test.outputs/outputs.zip" -type f | sort
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

Expected:

- JSON payload files exist either as loose files or inside `outputs.zip`.
- `bazel_target_metadata.json` exists for instrumented runtime tests.
- No `.msgpack` or `.msgpack.gz` payloads exist.
- Known pilots that require module selection do not report
  `bazel.go.payload_selection = "full_bundle_no_match"`.
- Go target metadata records the expected `bazel.go.orchestrion.mode`. For
  standard Go `testing` onboarding, that value should be `test_optimization`.

Valid payload selections:

- `module`
- `module_override`
- `full_bundle_disabled`
- `full_bundle_no_match` for intentionally generic inferred/derived fallback

`full_bundle_disabled` can be valid for fixtures or repositories without
backend data provisioned. It means the full bundle path is intentionally not
available, not that instrumentation failed.

The doctor rejects `full_bundle_no_match` by default because known pilots
normally require a module match. A repository that intentionally permits the
generic inferred/derived fallback must set
`forbid_full_bundle_no_match = False` on its doctor target. Do not combine that
with a narrower `allowed_payload_selections` list that excludes
`full_bundle_no_match`. Explicit `importpath` and `module_label_override`
selection still fail analysis when their requested module group is absent.

When validating a known pilot, make the doctor stricter instead of relying only
on the default allowlist:

- Use `expected_targets` for runtime test targets that must emit payloads.
- Use `expected_payload_selection_by_target` when a target must report a
  specific selection value.
- Inspect `bazel_target_metadata.json` directly when the pilot must prove a
  specific Orchestrion mode, because the doctor validates payload shape rather
  than replacing mode-specific rollout evidence.
- Use `allowed_payload_selections` only when the whole onboarding deliberately
  permits a smaller set than the default.
- Do not list `.build_test` or build-only controls in `expected_targets`
  because they do not run instrumented test code.

## Remote Execution

If tests use remote execution or remote cache, make sure the test config uses:

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

## Final Consumer Checks

Before opening or finishing a consumer PR:

- Runtime pilot targets pass.
- Ordinary controls still pass without `--config=test-optimization`.
- Build-only controls are not listed as expected payload targets.
- The workspace doctor `data` label uses the actual sync repository name.
- The repo-local central Go wrapper injects the actual `topt_data` export
  for the service being instrumented.
- Doctor passes.
- Dry-run enrichment passes.
- Real upload passes when credentials are available.
- Datadog shows Git metadata, Bazel metadata, and expected test service.
- No local archive paths, patch directories, or private temporary paths are
  committed.
