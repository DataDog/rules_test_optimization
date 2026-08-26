<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Uploader Reference

This page is the full runtime/upload reference for `dd_payload_uploader`.
For a quick path, use the upload section in `README.md`. Examples below use a
package-local `//tools/test_optimization` label because that is the safer
monorepo default. Root labels such as `//:dd_upload_payloads` remain valid for
small repositories.

## How it works

1. Tests write payloads to
   `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests/*.json` and
   `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage/*.json`
2. Bazel automatically collects these to
   `bazel-testlogs/<package>/<target>/test.outputs/`
3. After tests complete, run the doctor via `bazel run` to validate local
   payloads and metadata before upload
4. Optionally run the uploader in dry-run enrichment mode to validate the exact
   outbound body without uploading or deleting files
5. Then run the uploader via `bazel run`
6. The uploader discovers local or BEP-staged `test.outputs/` directories,
   waits for quiescence, uploads, and deletes uploaded payload files

## Basic usage

The `test-optimization` config should contain the recommended Bazel test flags:
`--remote_download_minimal`, `--remote_download_regex=.*test[.]outputs.*`, and
`--zip_undeclared_test_outputs`.

For Go consumers using the reusable bootstrap, keep the phase-correct enablement
in the same config:

```bazelrc
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
build:test-optimization --@rules_go//go/private/orchestrion:enabled=true
```

This is one user-facing switch. Removing `--config=test-optimization` disables
both metadata resolution and the Orchestrion analysis aliases; it does not
require a second bool flag. In WORKSPACE repositories, use the apparent
`rules_go` repository name configured by that workspace.

Config-gated Python consumers use only the
`DD_TEST_OPTIMIZATION_ENABLED=1` entry and omit the Go-specific Orchestrion
line. Java, NodeJS, .NET, and Ruby retain their existing enablement contract in
this release.

```bash
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
# RECOMMENDED: Run tests with BEP, validate payloads, then upload payloads.
tools/test_optimization/run_test_optimization_ci.sh \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //...

# Optional: --report-dir writes doctor-report.json and uploader-dry-run-report.json.
# With --upload it also writes uploader-upload-report.json. --support-bundle
# adds dd-test-optimization-support.zip for escalation.

# Add --upload to send every available fresh valid payload after validation attempts.
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  tools/test_optimization/run_test_optimization_ci.sh \
    --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
    --upload-target //tools/test_optimization:dd_upload_payloads \
    --report-dir .topt/reports \
    --support-bundle .topt/reports/dd-test-optimization-support.zip \
    --upload \
    //...
```

```powershell
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
# RECOMMENDED: Run tests with BEP, validate payloads, then upload payloads.
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -DoctorTarget //tools/test_optimization:dd_test_optimization_doctor `
  -UploadTarget //tools/test_optimization:dd_upload_payloads `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  //...

# Optional: -ReportDir writes doctor-report.json and uploader-dry-run-report.json.
# With -Upload it also writes uploader-upload-report.json. -SupportBundle
# adds dd-test-optimization-support.zip for escalation.

# Add -Upload to send every available fresh valid payload after validation attempts.
$env:DD_API_KEY = "<your-api-key>"
$env:DD_SITE = "datadoghq.com"
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -DoctorTarget //tools/test_optimization:dd_test_optimization_doctor `
  -UploadTarget //tools/test_optimization:dd_upload_payloads `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  -Upload `
  //...
```

Always preserve all statuses. Test failures win, followed by doctor, dry-run,
and uploader failures. When upload is enabled, validation failures do not block
the uploader from processing other fresh valid payloads.

Enrichment validation:

- The CI wrappers always run `--dry-run --validate-enrichment` before a real
  upload. A normal uploader invocation can instead pass
  `--validate-enrichment` without `--dry-run` to validate each enriched source
  payload once, immediately before splitting and upload. Manual invocations
  should pass the matching `--bep-json=<path>` together with
  `--freshness-source=bep --freshness-mode=required --artifact-source=bep`.
- Dry-run mode does not upload data, does not require `DD_API_KEY` in
  agentless mode, and does not delete payload files.
- Raw files under `bazel-testlogs` are not expected to contain every final tag.
  Validation inspects the enriched outbound body after merging `context.json`
  and `bazel_target_metadata.json`. During a normal upload, a validation failure
  prevents that source payload from being sent but does not suppress other
  fresh payloads.
- Empty JSON placeholders such as `{}` under `payloads/tests/` are skipped.
  They have no uploadable `events[]` and are not valid Test Optimization test
  payloads.
- Default required enriched tags are `git.repository_url`, `git.commit.sha`,
  `bazel.target`, and `bazel.package`. Use repeatable
  `--expected-enriched-tag=<tag>` flags to validate additional runtime-specific
  tags such as `bazel.go.payload_selection` during Go/Orchestrion rollouts.

Credential handling:

- Pass `DD_API_KEY`, `DD_SITE`, and `DD_TEST_OPTIMIZATION_AGENT_URL` at uploader
  runtime via environment variables only.
- Do not pass `DD_TEST_OPTIMIZATION_AGENT_URL`,
  `DD_TEST_OPTIMIZATION_AGENTLESS_URL`, or `DD_GIT_*` to Go/Orchestrion tests
  with `--test_env`.
- Do not hardcode secrets in `BUILD.bazel`, scripts committed to git, or CI
  logs.
- The generated uploader scripts read env vars directly (no shell `eval`
  expansion of credential values).

## Add the doctor and uploader targets

```bzl
# tools/test_optimization/BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data",
    expected_targets = [
        "//app:instrumented_test",
    ],
    uploader_kwargs = {
        "quiescent_sec": 10,
        "max_wait_sec": 300,
    },
)
```

If your repository is small, the same helper can live in the root package. In
large monorepos, prefer `//tools/test_optimization` or another lightweight
package to avoid loading unrelated root package wiring when running doctor or
uploader.

Multi-service aggregator variant (include each service context in both targets):

```bzl
dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_service_a",
        "@test_optimization_data//:test_optimization_context_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_service_a",
        "@test_optimization_data//:test_optimization_context_service_b",
    ],
)
```

Mixed-runtime variant (include one context target per runtime or runtime/service repo):

```bzl
dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data_go//:test_optimization_context",
        "@test_optimization_data_python//:test_optimization_context",
        "@test_optimization_data_java//:test_optimization_context",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data_go//:test_optimization_context",
        "@test_optimization_data_python//:test_optimization_context",
        "@test_optimization_data_java//:test_optimization_context",
    ],
)
```

Each `:test_optimization_context` target bundles both `context.json` and
`telemetry_facts.json`. The uploader selects the matching context for payload
enrichment and consumes the bundled telemetry facts for rule-telemetry
augmentation. Do not pass only the physical `context.json` file when using the
normal target-based wiring.

## Upload modes

- **Agentless mode (default):** Requires `DD_API_KEY` and `DD_SITE`; uploads
  directly to Datadog intake
- **EVP proxy mode:** Requires `DD_TEST_OPTIMIZATION_AGENT_URL`; uploads via local agent or
  EVP proxy

## Passing credentials

The examples below show only credential placement. In CI, combine the same
credential style with the BEP freshness flags from the basic usage flow.

```bash
# Option 1: Agentless mode - Inline (recommended for CI)
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads

# Option 2: EVP proxy mode
DD_TEST_OPTIMIZATION_AGENT_URL="http://localhost:8126" bazel run --config=test-optimization //:dd_upload_payloads

# Option 3: Export before run
export DD_API_KEY="your-api-key"
export DD_SITE="datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads
```

```powershell
# Option 1: Agentless mode
$env:DD_API_KEY = "<your-api-key>"
$env:DD_SITE = "datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads

# Option 2: EVP proxy mode
$env:DD_TEST_OPTIMIZATION_AGENT_URL = "http://localhost:8126"
bazel run --config=test-optimization //:dd_upload_payloads

# Option 3: Set variables before run
$env:DD_API_KEY = "your-api-key"
$env:DD_SITE = "datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads
```

## Exit codes

- `0` - All payloads uploaded successfully (or no payloads found)
- `1` - One or more uploads failed (partial success; successfully uploaded files
  are still deleted)
- `2` - Configuration error (invalid `TESTLOGS_DIR`, missing credentials, etc.)

## Optional environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DD_TEST_OPTIMIZATION_KEEP_PAYLOADS` | `0` | Set to `1` to retain payloads after successful upload (for debugging/re-upload) |
| `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | `0` | `0` uploads all payload files; set to `1` to only upload `span_events_*.json` or `coverage_*.json` |
| `DD_TEST_OPTIMIZATION_DEBUG` | `0` | Set to `1` to enable verbose attempt, success, startTime, and runfile/CODEOWNERS resolution logging. Terminal test-upload failures always report the HTTP status, a bounded response body, and payload sizes. |
| `DD_TEST_OPTIMIZATION_GZIP` | `0` | Set to `1` to gzip test payloads before upload (adds `Content-Encoding: gzip`) |
| `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` | `300` | Override max wait time for slow filesystems (NFS, network drives); set to `0` to skip waiting when no payloads are present |
| `DD_TEST_OPTIMIZATION_QUIESCENT_SEC` | `10` | Override quiescence wait time |
| `DD_TEST_OPTIMIZATION_MAX_DEPTH` | `0` (unlimited) | Limit `find` depth for large `bazel-testlogs` trees |
| `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | auto | Explicit path to a CODEOWNERS file for enrichment fallback/discovery edge cases |
| `DD_TEST_OPTIMIZATION_CONTEXT_JSON` | unset | Legacy explicit override for one readable `context.json` path. It still wins when set, but mixed-runtime workspaces should prefer bundling all context targets in uploader `data`. |
| `DD_TEST_OPTIMIZATION_BEP_JSON` | unset | Optional explicit path to one BEP JSON file from the matching `bazel test --build_event_json_file=...` invocation. Prefer repeatable `--bep-json` flags when a wrapper runs multiple Bazel test invocations. The uploader does not auto-discover default BEP paths because stale BEP files can authorize stale local outputs. |
| `DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE` | `auto` | Cache-safety source: `auto`, `bep`, or `execution_log`. `auto` prefers BEP and uses execution-log filtering only as a legacy fallback when configured. |
| `DD_TEST_OPTIMIZATION_FRESHNESS_MODE` | `auto` | Cache-safety mode: `auto`, `required`, `optional`, or `disabled`. In CI, `auto` fails closed when no freshness source is available. |
| `DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON` | unset | Optional path for the doctor machine-readable diagnostic report. Equivalent to passing `--report-json=<path>` after the doctor target's `--` separator. |
| `DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON` | unset | Optional path for the uploader machine-readable diagnostic report. Equivalent to passing `--report-json=<path>` after the uploader target's `--` separator. |
| `DD_TEST_OPTIMIZATION_REPORT_DIR` | unset | Optional wrapper report directory. CI wrappers write `doctor-report.json`, `uploader-dry-run-report.json`, and optional `uploader-upload-report.json` under this directory. |
| `DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE` | `auto` | Legacy alias for freshness mode when `DD_TEST_OPTIMIZATION_FRESHNESS_MODE` is unset. |
| `DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON` | unset | Optional explicit legacy execution-log fallback path. Prefer BEP for new CI integrations. The uploader does not auto-discover `.topt/bazel-execution-log.json` because stale execution-log files can authorize stale local outputs. |
| `DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE` | `local` | Artifact source for `test.outputs` materialization: `local`, `bep`, or `auto`. `local` preserves existing discovery. `bep` requires an explicit BEP JSON file and stages BEP-referenced artifacts. |
| `DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS` | `disabled` | Remote artifact mode: `disabled`, `download`, or `required`. `download` stages local/file and native HTTP/HTTPS BEP carriers, and uses a configured downloader for custom remote providers when needed; `required` fails if any selected BEP artifact cannot be materialized. |
| `DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR` | `.topt/bep-artifacts` | Base directory for per-run staged BEP artifacts. CI wrappers should pass a per-run temporary directory with `--artifact-staging-dir`. The uploader cleans only staging run roots that it owns. |
| `DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER` | unset | Optional executable path used for non-HTTP remote/CAS BEP artifact references, or HTTP/HTTPS endpoints that need custom auth. The executable must write an `outputs.zip` archive to the requested `--output` path. |
| `DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC` | `300` | Positive decimal timeout, in seconds, for each downloader invocation. Scientific notation is rejected. |
| `TESTLOGS_DIR` | auto | Explicit path to `bazel-testlogs` (for non-standard setups) |

### `DD_TEST_OPTIMIZATION_FILTER_PREFIX` behavior

`DD_TEST_OPTIMIZATION_FILTER_PREFIX=1` is mainly for mixed-output environments
where non-Test-Optimization payload JSON files can exist next to Datadog payloads
inside `test.outputs/`. Enabling it narrows uploads to canonical filename
prefixes:
- Test events: `span_events_*.json`
- Coverage: `coverage_*.json`

Leave it at `0` for normal repositories where uploader-managed payload
directories contain only Datadog files.

### Diagnostic report directory

For CI, prefer one report directory per job:

```bash
tools/test_optimization/run_test_optimization_ci.sh \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //...
```

```powershell
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -DoctorTarget //tools/test_optimization:dd_test_optimization_doctor `
  -UploadTarget //tools/test_optimization:dd_upload_payloads `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  //...
```

The wrapper writes `.topt/reports/doctor-report.json` and
`.topt/reports/uploader-dry-run-report.json`. If upload is enabled, it writes
`.topt/reports/uploader-upload-report.json` for the real upload so the dry-run
report is preserved.

For first-pass support, the doctor can create a doctor-only bundle without the
wrapper:

```bash
bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
  --support-bundle .topt/reports/dd-test-optimization-support.zip
```

For CI support artifacts that need uploader dry-run or upload details, prefer
the wrapper support bundle: `.topt/reports/dd-test-optimization-support.zip`.
The bundle contains redacted and bounded doctor/uploader reports, selected BEP
summaries, effective wrapper flags, runtime metadata, and `summary.md`. If a
repository cannot use either bundle mode, keep the manual
`create_support_bundle.py` flow as the fallback when the helper script is
available:

```bash
python3 tools/test_optimization/create_support_bundle.py \
  --report-dir .topt/reports \
  --report-json .topt/reports/doctor-report.json \
  --report-json .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/dd-test-optimization-support.zip \
  --workspace-root "$PWD" \
  --output-base "$(bazel info output_base)"
```

If only a Markdown summary is possible, use `render_report_summary.py`:

```bash
python3 tools/test_optimization/render_report_summary.py \
  .topt/reports/doctor-report.json \
  .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/upload-diagnostics.md
```

Support bundle contents:

| Bundle file | Purpose |
| --- | --- |
| `diagnostics.json` | Machine-readable index and primary reason code |
| `summary.md` | Human-readable support summary |
| `reports/*.json` | Redacted and bounded doctor-only or doctor/uploader reports |
| `bep/*.summary.json` | Redacted BEP test-result summaries; raw BEP is not included |
| `command/flags.json` | Effective doctor or wrapper targets and Test Optimization flags |
| `environment/runtime.json` | OS, Python, and Bazel version metadata |
| `redaction-manifest.json` | Description of redaction rules applied |

For the customer escalation ladder and the order to inspect `summary.md`,
`diagnostics.json`, `reports/*.json`, and `command/flags.json`, see
[`docs/Troubleshooting.md`](Troubleshooting.md#collect-diagnostic-reports).

### Doctor diagnostic report

Pass `--doctor-report-json=<path>` to the Bash wrapper,
`-DoctorReportJson <path>` to the PowerShell wrapper, `--report-json=<path>` to
a manual doctor invocation, or set `DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON`
when CI needs a machine-readable debug artifact. The doctor writes the report
on success and on controlled doctor failures. The report includes a `result`
block with `status`, `reason_code`, `reason`, and `next_steps`, plus resolved
config, expected targets, BEP files and seen targets, fresh/cached/remote-only
BEP outputs, selected and blocked BEP artifact carriers, staged `outputs.zip`
or `test.outputs` artifacts, local/staged payload directories, payload counts,
Bazel metadata, payload-selection counts, and failure messages.
When expected targets are configured, fresh and cached BEP labels jointly
satisfy target coverage. Only fresh outputs are validated; an all-cached
invocation succeeds with zero validated output directories.

Example:

```bash
doctor_report="$(mktemp "${TMPDIR:-/tmp}/dd-topt-doctor.XXXXXX.json")"
bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --report-json="$doctor_report"
```

### Uploader diagnostic report

Pass `--report-json=<path>` to a manual uploader invocation or set
`DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON` when CI needs a machine-readable
artifact from the upload phase. After report initialization, the uploader writes
the report on success, no-op, and controlled uploader failures. Early
argument/configuration validation failures that happen before report
initialization may exit without writing a report. The report includes effective
config, BEP files, selected freshness source, BEP freshness counts, artifact
staging counts, discovered payload directories, per-payload-type discovered,
processed, failed, and skipped counts, aggregate upload failures, upload
attempt status, final status, and exit code. The `result.reason_code` explains
common no-upload cases such as `bep_output_remote_only_without_downloader`,
`no_payload_json_found`, `payload_enrichment_failed`, and
`upload_skipped_dry_run`.

The CI wrapper writes a separate dry-run uploader report when `--report-dir` is
used. If only `DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON` or
`--uploader-report-json` is configured and `--report-dir` is not set, that
single path is used by the dry-run invocation only.

Example:

```bash
uploader_report="$(mktemp "${TMPDIR:-/tmp}/dd-topt-uploader.XXXXXX.json")"
bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment \
  --report-json="$uploader_report"
```

### BEP cache filtering behavior

`--remote_download_minimal --remote_download_regex=.*test[.]outputs.*` makes
payload files available to the doctor and uploader without downloading
unrelated build outputs. Bazel can still download `test.outputs` from a local,
disk, remote, or sandbox cache. Those cached payloads describe the original test
execution, not necessarily the current commit.

To keep test caching enabled without uploading cached payloads, generate Bazel's
BEP JSON file during the same test invocation. Keep stable Bazel download
behavior in `.bazelrc`, and let the wrapper pass per-run BEP and
artifact-staging paths to doctor/uploader:

```text
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
```

```bash
tools/test_optimization/run_test_optimization_ci.sh \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  //...
```

Use repeatable `--bep-json=<path>` flags after the doctor/uploader target's `--`
separator. `DD_TEST_OPTIMIZATION_BEP_JSON` remains available for one-shot
manual flows, but wrappers should prefer CLI flags so multiple test invocations
can pass multiple BEP files without sharing a path. Use a unique BEP file per
Bazel test invocation; stale BEP files can authorize the wrong local outputs.

Cache-safety modes:

- `auto` (default): use explicitly configured BEP when present, otherwise use
  an explicitly configured legacy execution log. In CI, fail closed if no
  explicit freshness source is available. Outside CI, preserve historical upload
  behavior and emit a warning.
- `required`: always require the selected freshness source.
- `optional`: use a configured freshness source, but otherwise preserve
  historical upload behavior without the CI fail-closed default.
- `disabled`: skip freshness filtering even if BEP or execution-log paths are configured.
  The equivalent CLI flag is `--allow-cached-payload-uploads`.

When BEP filtering is active, the uploader:

- Parses `TestResult` events from the BEP JSON file.
- Treats `cachedLocally: true` or `executionInfo.cachedRemotely: true` as ineligible.
- Keeps only fresh outputs that map to local or staged
  `bazel-testlogs/.../test.outputs`.
- Fails in `required` mode when BEP references fresh remote-only outputs that are
  not materialized locally or staged; rerun with
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs`
  and `DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE=bep`, or enable BEP artifact
  resolution with a downloader when local materialization is not viable.
- Compares each eligible target label and normalized `test.outputs` path to the
  local payload directory before upload.

On Unix, active BEP filtering requires `jq` to parse the Bazel JSON file. If the
requested BEP file is missing or malformed, or if `auto`/CI or `required` mode
cannot find a freshness source, the uploader exits with code `2` instead of
falling back to uploading everything.

### BEP artifact resolution

BEP freshness and BEP artifact resolution are separate controls. Freshness
answers whether a `TestResult` output is current for the Bazel invocation.
Artifact resolution answers whether the corresponding `test.outputs` files can
be read by the doctor and uploader.

The default `--artifact-source=local --remote-artifacts=disabled` keeps
local-only discovery: the uploader scans `bazel-testlogs/**/test.outputs` and
does not read or extract `outputs.zip`. The recommended CI config uses BwoB,
selective local materialization, and zipped undeclared outputs:

```text
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
```

When tests use Bazel's `--zip_undeclared_test_outputs`, the local
`test.outputs` directory contains `outputs.zip` instead of loose
`payloads/tests/*.json` files. Pass the matching BEP file and enable BEP
artifact staging so the doctor/uploader extracts the local zip before payload
discovery:

```bash
bep_json="$(mktemp "${TMPDIR:-/tmp}/dd-topt-bep.XXXXXX.json")"
artifact_staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")"
bazel test \
  --config=test-optimization \
  --build_event_json_file="$bep_json" \
  //...

bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir"

bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment
```

`--artifact-source=bep` is enough for locally available `outputs.zip` carriers.
Use `--remote-artifacts` only when BEP points at remote-only carriers that are
not present on local disk. Native HTTP/HTTPS `outputs.zip` carriers do not need
a downloader; custom remote providers still do.

When CI cannot materialize `test.outputs` or `outputs.zip` with selective
remote downloads, pass the matching BEP file and enable remote artifact
staging. Plain HTTP/HTTPS `outputs.zip` BEP carriers are handled natively:

```bash
bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --remote-artifacts=download \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment
```

Customer-facing mode summary:

| Mode | When to use | Required flags |
|------|-------------|----------------|
| Local discovery | Local development or CI where loose `test.outputs/payloads/...` files are already present | No artifact flags; for cache safety still use `--bep-json --freshness-source=bep --freshness-mode=required` |
| Recommended CI | Remote cache/RBE default when outputs can be downloaded from Bazel | `.bazelrc` test config has `--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs`; wrapper passes `--build_event_json_file=<temp>` to each `bazel test`, then passes repeatable `--bep-json=<temp> --freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=<temp-dir>` to doctor/uploader |
| CI without zipped outputs | Test command leaves loose payload files under local `test.outputs` | Same BEP freshness env; `DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE=bep` remains valid but is not required for zip extraction |
| HTTP/HTTPS BEP artifact staging | BEP references remote-only `http://` or `https://` `outputs.zip` carriers and no custom auth is needed | Add `--artifact-source=bep --remote-artifacts=download|required`; no downloader flag |
| Custom remote/CAS artifact staging | BEP references `bytestream://`, CAS, internal artifact APIs, or HTTP endpoints requiring custom auth | Add `--artifact-source=bep --remote-artifacts=download|required --bep-artifact-downloader=/path/to/downloader` |
| Auto staging | Migration path when local outputs may exist but BEP-stageable outputs should win for matching output keys | `--artifact-source=auto --remote-artifacts=download|required` |

The resolver supports local filesystem references, `file://` URIs, local
`outputs.zip` archives, native HTTP/HTTPS `outputs.zip` downloads, and
external-downloader-backed custom remote providers. Native HTTP/HTTPS staging
does not add auth headers or read credentials; it retries transient network
failures, truncated responses, HTTP 408, HTTP 429, and HTTP 5xx responses three
times with exponential backoff. Query strings, fragments, usernames, and
passwords are redacted from uploader warnings and reports.

Custom remote/CAS artifact download requires a downloader executable configured
by the consumer environment.
`DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER` must point to one executable
file; if the provider needs an interpreter, fixed arguments, custom auth
headers, mTLS, signed header refresh, or a CAS client, wrap them in a script and
configure the wrapper path. The downloader must write an `outputs.zip` archive
to the requested `--output` path before `--bep-artifact-downloader-timeout-sec`
expires. The public rule only defines the downloader contract; it does not ship
credentials or a Datadog-internal CAS client.

Artifact staging requires Python at uploader runtime. Bash resolves
`DD_TEST_OPTIMIZATION_PYTHON`, then `PYTHON`, then `python3`, then `python`;
PowerShell uses the same discovery order. Existing local-only uploader flows
remain usable without Python except for support bundle generation and the
pre-existing optional schema and telemetry helpers. Bash BEP freshness parsing
still requires `jq` whenever BEP freshness validation is enabled in the Bash
uploader path.

### Legacy execution-log fallback

Existing integrations that already generate `--execution_log_json_file` can keep
using `DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON` or `--execution-log-json` during
the BEP migration. BEP wins when both BEP and execution-log inputs are present.
New CI integrations should use BEP. The execution-log fallback is explicit-only:
passing `--execution_log_json_file=.topt/bazel-execution-log.json` to `bazel test`
is not enough by itself; also pass `--execution-log-json=.topt/bazel-execution-log.json`
or set `DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON` for the uploader run.

### `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` behavior (including `0`)

`DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` controls how long the uploader waits for
payload discovery/quiescence before proceeding.
- `> 0`: wait up to the configured budget for payload files to appear and settle.
- `0`: skip waiting loops immediately. When BEP freshness is configured, the
  uploader evaluates that BEP before applying no-payload failure policy, so an
  all-cached invocation is a no-op while missing fresh payloads still fail.
  Without BEP freshness, the configured no-payload/`fail_on_error` policy
  applies normally.

## Endpoints and headers

- Agentless (when `DD_TEST_OPTIMIZATION_AGENT_URL` unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
  - `DD_SITE` is validated as a hostname (ASCII-whitespace is trimmed first),
    with compatibility normalization for `app.`/`api.` prefixes and URL-shaped
    inputs; credentials/ports are rejected
  - Test/dev override: set `DD_TEST_OPTIMIZATION_AGENTLESS_URL` to use a custom
    base URL (agentless only)
- EVP proxy (when `DD_TEST_OPTIMIZATION_AGENT_URL` set):
  - Base: `${DD_TEST_OPTIMIZATION_AGENT_URL}/evp_proxy/v2/...`
  - Adds `X-Datadog-EVP-Subdomain` per endpoint
- Test payloads are JSON (msgpack is not available in Starlark). Coverage is
  multipart with `event` and `coveragex` parts.

## Reliability

- HTTP requests use a 60-second timeout
- Failed requests are retried up to 3 times with a 2-second delay between
  attempts
- Both transient errors (connection issues) and HTTP errors (4xx/5xx) trigger
  retries
- After enrichment, test payloads larger than 4,500,000 bytes are split by
  their top-level `events` array before compression and transport. Each part
  preserves the original top-level envelope and remains at or below the split
  target when possible. This leaves headroom below the 5,000,000-byte intake
  limit.
- A single event between the split target and the intake limit is sent intact.
  A single event above the intake limit cannot be split and fails without an
  upload attempt.
- On Unix, splitting requires `jq`. Without it, payloads at or below the intake
  limit retain the existing unsplit upload path; larger payloads fail locally.
  PowerShell performs the same split with its built-in JSON support.
- Split parts are uploaded in event order and retry independently. A failed
  part does not prevent the uploader from attempting the remaining parts. The
  source payload is reported as failed and retained unless every part succeeds.
- Terminal test-upload failures always log the HTTP status, up to 2,000
  characters of the response body, and the uncompressed, compressed, and
  transmitted byte counts. Response logging does not require debug mode.
- Behavior is consistent across Linux/macOS (bash/curl) and Windows
  (PowerShell-only runtime path; no Git Bash requirement)

## Metadata enrichment (`context.json`)

- The uploader resolves `context.json` in this order:
  1. `DD_TEST_OPTIMIZATION_CONTEXT_JSON` when it points to a readable file
  2. if exactly one bundled context exists, use that context for every payload
  3. if multiple bundled contexts exist, read sibling `bazel_target_metadata.json`, take `bazel.test_optimization.repo_name`, and use the matching bundled context for that payload
  4. if multiple bundled contexts exist and no match is found, skip only the `context.json` merge for that payload and continue uploading
  5. if no bundled context resolves, upload without context enrichment
- When a `context.json` file is available, the uploader enriches each test
  payload by merging all non-null keys from `context.json` into each event's
  `content.meta` or `content.metrics`, and it also normalizes top-level
  `metadata.*` runtime tags.
- Bazel sidecar metadata from `bazel_target_metadata.json` is merged separately.
  If a multi-context payload has no repo match, those Bazel sidecar tags remain
  and only the `context.json` merge is skipped.
- If `context.json` is not present (or `jq` is unavailable on Unix), test
  payloads are uploaded as-is.
- `context.json` contains non-secret CI/Git/OS/runtime tags suitable for reuse
  at test time.
- `DD_TEST_OPTIMIZATION_CONTEXT_JSON` is a runtime uploader override only. Do
  not pass it via `--repo_env`, do not treat it as sync-time configuration, and
  do not use it as the normal mixed-runtime wiring path.
- Bazel metadata is included as stable tags:
  `bazel.rule_name`, `bazel.rule_version`, `bazel.os`, and `bazel.arch`.
- When enrichment is active, those Bazel keys are merged into each test event
  alongside the existing CI, Git, OS, and runtime tags. This includes Go tracer
  payloads that encode CI Visibility data as `span` events; those events still
  need the same Git and Bazel tags before upload.
- CODEOWNERS enrichment remains limited to non-span CI Visibility lifecycle and
  test events. Go span-form events still receive Git, context, and Bazel tags,
  but not `test.codeowners`.
- CODEOWNERS lookup order:
  - `<ci.workspace_path>/CODEOWNERS`
  - `<ci.workspace_path>/.github/CODEOWNERS`
  - `<ci.workspace_path>/.gitlab/CODEOWNERS`
  - `<ci.workspace_path>/docs/CODEOWNERS`
  - `<ci.workspace_path>/.docs/CODEOWNERS`
  - `<workspace>/...` equivalents
  - `./CODEOWNERS`
  - `<script_dir>/CODEOWNERS`
- Matching uses GitHub-style glob semantics with "last matching rule wins".
- CODEOWNERS enrichment is best-effort: parse/lookup failures and misses do not
  fail uploads; debug mode logs counters and skip reasons.

### Manifest-driven aggregate contexts

`test_optimization_manifest_sync` places every selected Go/Python runtime
context in one aggregate repository. Its
`:test_optimization_context` target carries a provider mapping deterministic
context keys to the matching `context.json`. Doctor and uploader convert those
entries into virtual repository keys of the form
`<aggregate_repo>_<context_key>`, which match the
`bazel.test_optimization.repo_name` written by selected targets.

The managed doctor should also consume
`@test_optimization_data//:expected_targets` through
`expected_targets_file`. The file contains the exact canonical labels from the
invocation manifest. Static `expected_targets` and the generated file may be
used together only when they describe the same set; disagreement is a hard
error.

A cached Bazel test does not produce a fresh payload for the current
invocation. With exact expected targets configured on both doctor and uploader,
fresh and cached BEP results jointly satisfy invocation coverage. Only fresh
outputs are validated or uploaded; an all-cached invocation is a successful
no-op. A missing expected result is reported without blocking other fresh
payloads. Every fresh expected output that exists must independently contain a
handled payload, so one valid sibling output cannot hide an empty one.

### Advanced: reuse an already-fetched context file

If your workflow already resolved Test Optimization data during the test
command, you can avoid re-resolving the uploader context through external repo
labels by passing the existing `context.json` path directly at uploader runtime:

```bash
DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="/abs/path/to/context.json" \
bazel run --config=test-optimization //:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required
```

This override is global for that uploader invocation. In mixed-runtime
workspaces, prefer bundling all relevant context targets and let the uploader
match them per payload instead of forcing one override path onto the entire run.

## Payload schema validation (best effort)

- Test payload schema validation runs only when all dependencies are available:
  bundled schema JSON, validator script, and `python3`.
- If validation dependencies are missing, validation is skipped and uploads
  continue.
- If validation runs and fails, the uploader logs a warning and continues.

## Test-time environment variables

`dd_topt_go_test` sets the following environment variables for instrumented
tests. Custom wrappers for other languages should set the same contract:

- `DD_TEST_OPTIMIZATION_MANIFEST_FILE`: runfile path to `manifest.txt` in the
  synced repo (`topt_data["manifest_path"]` aware of custom `out_dir`)
- `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES`: always `"true"` so libraries write
  payloads to `TEST_UNDECLARED_OUTPUTS_DIR`

## Critical requirements

1. Use `bazel run` (not `bazel test`) for uploader execution
2. Use a single uploader target per workspace (no concurrent uploaders)
3. Tests must run locally or use the recommended remote-cache/RBE test config:
   `--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs`.
   Doctor/uploader should use `DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE=bep` so
   local `outputs.zip` carriers are staged through BEP.
4. Run uploader on the same machine/workspace where tests executed
5. When using downloaded test outputs from any cache, generate a fresh matching
   BEP file with `--build_event_json_file=<path>` for each Bazel test
   invocation and pass those paths to doctor/uploader with repeatable
   `--bep-json=<path>` plus
   `--freshness-source=bep --freshness-mode=required` so cached payloads are
   skipped.

For Go onboarding, the bootstrap validation script follows the same rule. It
runs upload only when the operator passes `--upload`:

```bash
./tools/test_optimization/validate_go_pilot.sh --no-upload
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  ./tools/test_optimization/validate_go_pilot.sh --upload
```

The script does not print secrets and does not pass uploader credentials to the
test sandbox. Credentials are read by the uploader process at `bazel run` time.
