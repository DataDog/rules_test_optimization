<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Troubleshooting

Examples below assume the generated repository is named
`test_optimization_data`. If you used a different `name`, replace labels and
repository names accordingly. For config-gated Go and Python repositories,
include `--config=test-optimization` in sync, test, doctor, and uploader
commands. Other companions retain their current activation contract.

If Bazel reports that sync requires WORKSPACE support, add
`--enable_workspace` to sync commands in this document.

## Test Optimization config and disabled mode

For config-gated Go and Python onboarding,
`--config=test-optimization` is the single user-facing enablement switch. Both
languages set the metadata repository environment:

```bazelrc
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

Instrumented Go tests select the Go SDK that `ddtest instrument` instruments
through their own transition; no other build setting is needed.

When the config is omitted, the public Go extension's config-gated default and
repositories explicitly configured with `enabled_by_env = True` generate the
documented no-fetch stubs. `dd_topt_go_test` then creates a plain `go_test`;
Python keeps the normal consumer runner without Test Optimization metadata or
payload wiring. Java, NodeJS, .NET, and Ruby retain their existing enablement contract
in this release.

## Quick triage map

| Symptom | First checks | Likely section |
|---------|--------------|----------------|
| No files fetched or stale data | `DD_API_KEY` forwarded with `--repo_env`; use `FETCH_SALT` only for an explicit force-refresh sync | Repository rule not fetching data |
| Uploader says no payload files | tracer file-mode contract + payload files under `bazel-testlogs/*/test.outputs/` | Uploader not finding payloads, Instrumented test writes no payloads |
| Doctor reports msgpack payloads | tracer is not in Bazel JSON file mode | Doctor failures |
| Doctor reports missing Git or Bazel metadata | sync metadata context or sidecar metadata is absent | Doctor failures |
| Uploaded tests miss Git or Bazel tags | run uploader dry-run enrichment validation | Uploader enrichment dry-run |
| Python uploader cannot start | Python 3.10+ discovery and override | Python uploader cannot resolve Python |
| Test payload split or `413` failure | enriched size, individual event size, fixed threshold | Python uploader split and `413` failures |
| Upload network errors | credential mode (agentless vs EVP), intake reachability | Tests not uploading (network errors) |
| CI failure requires log archaeology | archive the support bundle from the failing run | Collect diagnostic reports |
| Module selection misses | `bazel query` for `module_*` targets and importpath/module label expectations | Per-module files not found |
| Instrumented Go test fails with "need a Go SDK to instrument" | `topt_go_ddtest.sdk(...)` in the root `MODULE.bazel`, or `topt_go_ddtest_workspace_repositories(...)` in WORKSPACE | Instrumented test fails: no Go SDK to instrument |
| Go test analysis fails with "would link Mini's packages twice" | `override_repo` of go_deps' `github.com/DataDog/ddtest/ddto` | Analysis fails: test would link Mini twice |
| Repository rule fails with "DDTEST_INSTRUMENT has" | the pinned ddtest release | DDTEST_INSTRUMENT contract mismatch |
| Go bootstrap stops on a `rules_go` override | override that points at the removed Datadog fork | Bootstrap stops on a rules_go fork override |
| WORKSPACE archive pins fail after a PR was squash-merged | generated pins commit reachability and archive SHA | Published Go pins |
| Private/internal WORKSPACE fetch returns 404 | SSH git or authenticated archive access | Private repository fetch |
| Bazel downloads unrelated toolchains or analyzes unrelated packages | cold monorepo state or root-package doctor/uploader placement | Monorepo analysis cost |
| Windows path/policy failures | PowerShell policy + path separators | Windows-specific issues |

## Collect diagnostic reports

When a failure is hard to classify from logs alone, archive a support bundle
from the same run. For the simplest customer ask after tests have already run,
use the doctor directly:

```bash
bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
  --support-bundle .topt/reports/dd-test-optimization-support.zip
```

For BEP/BwoB CI investigations, include the same BEP and artifact flags used by
the failing job:

```bash
bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --support-bundle=.topt/reports/dd-test-optimization-support.zip
```

The doctor bundle is doctor-only: it captures expected targets, BEP freshness,
artifact staging, discovered payload directories, payload counts, status, exit
code, effective doctor flags, runtime metadata, and selected BEP summaries. It
does not prove uploader dry-run, enrichment, API-key, or upload behavior.

Use this escalation ladder:

| Situation | Ask for | Why |
| --- | --- | --- |
| First customer response after tests already ran | Doctor `--support-bundle=<path>` | Smallest command; built into the doctor target; no helper scripts required |
| CI failure where upload, enrichment, or dry-run behavior matters | Wrapper `--report-dir=<path> --support-bundle=<path>` | Includes doctor, the selected uploader report, BEP summaries, and effective wrapper flags |
| Repository cannot run the wrapper or doctor bundle | Raw `--report-json` files plus manual `create_support_bundle.py` output | Fallback only; raw reports may include internal paths until the redacted zip is created |

Ask the customer to attach the zip, not screenshots of terminal output. If the
bundle is not available, ask for the individual JSON reports and the exact
`bazel test`, doctor, and uploader commands.

Use the wrapper flow when the CI job should also validate uploader dry-run or
perform the real upload:

```bash
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
tools/test_optimization/run_test_optimization_ci.sh \
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //...
```

```powershell
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  //...
```

The wrapper writes `doctor-report.json` and `uploader-dry-run-report.json`
under the report directory. If the same wrapper run includes the real upload,
it also writes `uploader-upload-report.json`, preserving the dry-run report.
When `--support-bundle` or `-SupportBundle` is configured, it also writes
`dd-test-optimization-support.zip`.
Each report has a `result.reason_code`, human-readable `result.reason`, and
`result.next_steps` so support can distinguish cached tests, remote-only BEP
artifacts, missing payloads, enrichment failures, dry-run no-upload, and real
upload failures without reading the full log.

When opening a support ticket, attach
`.topt/reports/dd-test-optimization-support.zip`. The bundle is redacted by
default and does not contain raw payload files, raw CI logs, raw environment
variables, or the raw BEP. Depending on whether the doctor or wrapper created
it, it contains bounded doctor-only or doctor/uploader reports, selected BEP
summaries, `command/flags.json`, `environment/runtime.json`, `summary.md`, and
`diagnostics.json`.

Triage the bundle in this order:

1. Open `summary.md` for the human-readable failure classification.
2. Check `diagnostics.json` for `summary.status`,
   `summary.primary_reason_code`, payload counts, and included report paths.
3. Check `reports/doctor-report.json` for expected targets, seen targets,
   fresh/cached/remote-only BEP outputs, artifact staging, and doctor errors.
4. If the wrapper created the bundle, check `reports/uploader-dry-run-report.json`
   for payload discovery, enrichment validation, skipped payloads, and
   no-upload reasons.
5. If upload was enabled, check `reports/uploader-upload-report.json` for the
   real upload attempt count, HTTP status, and terminal upload failure.
6. Check `command/flags.json` to confirm the test run used a unique BEP file
   and that doctor/uploader ran with the matching `--bep-json`,
   `--freshness-source=bep`, `--freshness-mode=required`,
   `--artifact-source=bep`, and artifact staging flags.

Manual doctor/uploader flow:

```bash
bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --report-json=.topt/doctor-report.json

bazel run --config=test-optimization //:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --artifact-source=bep \
  --artifact-staging-dir="$artifact_staging_dir" \
  --dry-run \
  --validate-enrichment \
  --report-json=.topt/uploader-report.json
```

Archive the JSON files as CI artifacts when a repository cannot use the wrapper
support bundle. If the repository has the helper script available, create the
same redacted zip from existing reports:

```bash
python3 tools/test_optimization/create_support_bundle.py \
  --report-dir .topt/reports \
  --report-json .topt/reports/doctor-report.json \
  --report-json .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/dd-test-optimization-support.zip \
  --workspace-root "$PWD" \
  --output-base "$(bazel info output_base)"
```

Use repeatable `--bep-json=<path>` flags with that command when the reports came
from BEP/BwoB runs. If only a Markdown summary is possible, render a short
fallback summary:

```bash
python3 tools/test_optimization/render_report_summary.py \
  .topt/reports/doctor-report.json \
  .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/upload-diagnostics.md
```

Before sharing raw reports outside the trusted project boundary, review them
for repository paths, target names, and service metadata. They must not contain
API keys, but they can contain internal labels and filesystem paths. Prefer a
support bundle for external escalation because it redacts and bounds those
values automatically.

## Repository rule not fetching data

**Symptom**: Build succeeds but test optimization files are empty or stale.

**Solutions**:

1. **Verify DD_API_KEY is set**:
   ```bash
   env | grep '^DD_API_KEY='
   grep -n 'common --repo_env=DD_API_KEY' .bazelrc
   ```
   ```powershell
   $env:DD_API_KEY
   Select-String -Path .bazelrc -Pattern "common --repo_env=DD_API_KEY"
   ```
   If missing, set `DD_API_KEY` in your shell/CI secret store and add to
   `.bazelrc`:
   ```
   common --repo_env=DD_API_KEY
   ```

2. **Force refetch only when intentional** with a cache-busting salt:
   ```bash
   bazel sync --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT="$(date +%s)"
   ```
   ```powershell
   bazel sync --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT="$(Get-Date -UFormat %s)"
   ```
   Do not put `FETCH_SALT` in `.bazelrc`, `bazel test`, doctor, or uploader
   commands. It deliberately breaks the repository-rule cache key and should be
   used only when you want fresh backend metadata.

3. **Check repository cache** to see if the rule ran:
   ```bash
   # Find the external repository directory
   bazel info output_base
   # Repository contents at: $(bazel info output_base)/external/<repo_name>
   ls -la $(bazel info output_base)/external/<repo_name>/.testoptimization/
   ```
   ```powershell
   # Find the external repository directory
   $outputBase = bazel info output_base
   # Repository contents at: "$outputBase/external/<repo_name>"
   Get-ChildItem -Force "$outputBase/external/<repo_name>/.testoptimization/"
   ```

4. **Enable debug logging** in your `MODULE.bazel`:
   ```bzl
   test_optimization_sync.test_optimization_sync(
       name = "test_optimization_data",
       debug = True,  # Verbose logging
   )
   ```
   Preserve the repository's existing `enabled_by_env` value; enabling debug
   logging must not change its activation contract.

## Manifest-driven managed runs

These checks apply only to the automatic Go/Python path. Static single-service
and static multi-service consumers do not need an invocation manifest.

### Enabled run reports a missing manifest

The aggregate repository intentionally fails before HTTP when enabled without
the command-owned manifest. Run the consumer repository's managed Test
Optimization command. Do not add the internal manifest handoff to `.bazelrc`
or ordinary CI jobs.

If a direct `bazel test --config=test-optimization` bypasses the managed
command, the failure is expected: target discovery must run first so the
repository rule receives exact targets and runtime contexts.

### Doctor or uploader triggers another metadata fetch

One managed command invocation must pass the same temporary manifest path to
test, doctor, and the validated uploader. If the request log shows
another fetch during a post-test phase, check that the command did not create a
new temporary directory or change
`DD_TEST_OPTIMIZATION_SERVICES_MANIFEST` between child Bazel processes.

A later managed command intentionally creates a new manifest path and fetches
current backend state once. If its selected settings/module files are
unchanged, tests should remain Bazel cache hits even though
`telemetry_facts.json` contains new request timings.

### Manifest is malformed or unsupported

The error names the schema field rejected before metadata requests. Verify
that the consumer resolver emitted:

- schema version `1`;
- canonical local labels such as `//pkg:test`, not patterns or external labels;
- unique, used contexts;
- only Go/Python runtimes;
- deterministic context keys matching service and runtime;
- `application` or `domain_fallback` for every target.

Fix the resolver or its target input. Do not hand-edit the temporary manifest.

### Unsupported target is absent from the aggregate mapping

Only targets recognized by the consumer's central Go/Python macro policy are
eligible. A target absent from `topt_data_by_target` correctly keeps its raw
behavior. Inspect the managed command summary for unsupported labels and
confirm that the target is a runtime test, not a build-only companion.

Java, NodeJS, .NET, and Ruby are intentionally outside automatic manifest
onboarding in this release.

### Service or context collision

The resolver and repository reject two logical services that sanitize to the
same context key, conflicting module paths or runtime versions for one
service/runtime, duplicate labels, and one label assigned to multiple
contexts. Change the consumer's deterministic naming grammar or split the
conflicting runtime contexts; do not append positional suffixes whose result
depends on input order.

### Doctor expected-target mismatch

The aggregate `:expected_targets` file is exact. A mismatch means the execution
set, BEP inputs, or doctor wiring does not match the manifest. The managed
command must test the fully expanded labels from the same discovery phase and
pass that invocation's BEP file to doctor.

Cached tests do not emit fresh payloads. With configured expected targets,
strict BEP freshness accepts those cache hits as covered, validates no stale
local outputs for them, and lets uploader treat an all-cached invocation as a
no-op. If a cached target is reported as missing instead, verify that doctor
received the BEP from the exact matching `bazel test` invocation. Use separate
cache-isolation tests when validating action-key behavior.

### Disabled mode or enabled run invokes host Go

Disabled manifest sync must not read the manifest or contact Datadog. Neither
mode needs a host `go` binary: `ddtest instrument` writes the instrumented Go
SDK and Mini without it, and rules_go builds with its registered SDK. If a
host-Go sentinel fires, check which repository rule or action called `go`
before installing Go on the host.

## Published Go pins

**Symptom**: A consumer cannot fetch the published Go companion archive, or a
pin that worked during review stops working after a squash merge.

**Cause**: The consumer was given a feature-branch commit, a stale archive hash,
or a tuple that was not generated from the real GitHub codeload archive.

**Solutions**:

1. **Regenerate pins from `origin/main`** in this repository:
   ```bash
   ./bazelw run //tools/dev:print_go_onboarding_pins -- \
     --commit "$(git rev-parse origin/main)" \
     --verify-main-reachable
   ```

2. **If you are in a consumer repo**, use the bootstrap helper with the
   squash-merged commit:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --print-published-pins \
     --rto-commit <published-origin-main-sha>
   ```

3. **Keep the generated tuple together**. If `RTO_COMMIT`,
   `RTO_ARCHIVE_URL`, `RTO_ARCHIVE_SHA256`, and `RTO_ARCHIVE_PREFIX` come from
   different commits, archive mode will fail or fetch the wrong source. See
   [Generate published Go pins](Installation_Reference.md#generate-published-go-pins).

4. **Authenticate private archive downloads**. The helper uses `GITHUB_TOKEN`,
   `GH_TOKEN`, or `gh auth token` when available. If codeload returns `404` for
   a commit you can see in GitHub, refresh local GitHub CLI authentication or
   set one of those token variables before regenerating pins.

5. **Use the generated summary for handoff** when a monorepo needs a permanent
   local guide:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --write-onboarding-summary=TEST_OPTIMIZATION_GUIDE.md \
     --rto-commit <published-origin-main-sha>
   ```

## Private repository fetch

**Symptom**: A WORKSPACE consumer gets `404` when fetching the rules archive or
companion archive from a private/internal repository.

**Cause**: Anonymous codeload archive URLs can return `404` for private
repositories even when the commit exists and the user can see it in GitHub.

**Solutions**:

1. Prefer SSH git fetch for internal Datadog consumers:
   ```bzl
   git_repository(
       name = "datadog-rules-test-optimization",
       commit = "<commit-sha>",
       remote = "ssh://git@github.com/DataDog/rules_test_optimization.git",
   )
   ```

2. Use archive fetch only when Bazel has compatible authentication, for
   example `.netrc` or another repository-approved token mechanism.

3. Do not commit local archive paths or local checkouts as a workaround for CI.
   Use local paths only for temporary local validation.

## Monorepo analysis cost

**Symptom**: Tests already produced payload files, but running doctor or
uploader appears slow because Bazel downloads unrelated toolchains or analyzes
unrelated packages.

**Cause**: Some cost is normal cold-cache monorepo behavior. Another common
cause is placing doctor/uploader in the workspace root package, which can load
global root `BUILD.bazel` wiring unrelated to Test Optimization.

**Solutions**:

1. Move the logical doctor/uploader pair to a lightweight package:
   ```bzl
   # tools/test_optimization/BUILD.bazel
   load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

   dd_test_optimization_targets(
       name = "test_optimization",
       sync_repo_name = "test_optimization_data",
       expected_targets = ["//app:service_py_test"],
   )
   ```

2. Run package-local labels:
   ```bash
   bep_json="${bep_json:-/path/from/matching/bazel-test.bep.json}"
   bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required
   bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required \
     --dry-run \
     --validate-enrichment
   ```

3. If Bazel repeatedly refetches Test Optimization metadata, check whether a
   script or `.bazelrc` is setting `FETCH_SALT` by default.

## Uploader not finding payloads

**Symptom**: Uploader runs but says "no payload files found".

**Solutions**:

1. **Check if tests wrote payloads**:
   ```bash
   find bazel-testlogs -name "test.outputs" -type d
   ls bazel-testlogs/*/test.outputs/payloads/tests/
   ```
   ```powershell
   Get-ChildItem -Recurse -Directory -Path bazel-testlogs -Filter "test.outputs"
   Get-ChildItem -Recurse -Path bazel-testlogs -File -Filter "*.json" | Where-Object { $_.FullName -match "test\.outputs[\\/]+payloads[\\/]+tests" }
   ```

2. **Verify tracer support**: Ensure your tracer/runtime supports file mode via
   `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES` and manifest discovery via
   `DD_TEST_OPTIMIZATION_MANIFEST_FILE`.

3. **Check DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES**: The macro should set this
   to `"true"`. Verify your test environment:
   ```bash
   bazel test --config=test-optimization //your:test --test_output=all 2>&1 | grep DD_TEST_OPTIMIZATION
   ```
   ```powershell
   bazel test --config=test-optimization //your:test --test_output=all *>&1 | Select-String "DD_TEST_OPTIMIZATION"
   ```
   PowerShell uses `*>&1` (not Bash `2>&1`) to merge stderr/stdout.

4. **For RBE/remote-cache users**: Put
   `--remote_download_minimal`, `--remote_download_regex=.*test[.]outputs.*`,
   and `--zip_undeclared_test_outputs` in the active test `.bazelrc` config.
   Run tests with a fresh `--build_event_json_file=...`, then run
   doctor/uploader with repeatable `--bep-json=<path>`,
   `--freshness-source=bep`, `--freshness-mode=required`,
   `--artifact-source=bep`, and `--artifact-staging-dir=<temp-dir>` so cached
   outputs are skipped and local `outputs.zip` carriers are extracted through
   BEP staging.

## Doctor failures

**Symptom**: `bazel run --config=test-optimization //:dd_test_optimization_doctor`
fails before upload.

**Solutions**:

1. **Msgpack payloads**: Go tests built by `dd_topt_go_test` write JSON
   payloads to `TEST_UNDECLARED_OUTPUTS_DIR`. If the doctor finds `.msgpack` or
   `.msgpack.gz`, verify that the target uses `dd_topt_go_test` or the
   repository's wrapper around it.

2. **No JSON payloads**: Confirm the test target actually ran with Test
   Optimization enabled and inspect:
   ```bash
   find bazel-testlogs -path '*/test.outputs/payloads/*/*.json' -type f
   ```
   For Python WORKSPACE consumers, confirm the target loads `dd_topt_py_test`
   from `@datadog-rules-test-optimization-python//:topt_py_test.bzl` and that
   the companion repository was declared with
   `datadog_python_test_optimization_workspace_repositories(...)`.
   For Python `runner_mode = "consumer_runner"`, also verify that the
   consumer-owned wrapper really executes pytest, propagates the `env` passed
   by `dd_topt_py_test`, and keeps `PYTEST_ADDOPTS=--ddtrace` unless it
   intentionally sets `--no-ddtrace`. If `env` is a `select(...)`, the macro
   cannot add `PYTEST_ADDOPTS` inside each branch; include `--ddtrace` in every
   relevant selected environment. The target must also depend on `ddtrace` and
   `pytest`.

3. **Missing Git metadata**: The sync metadata fetch must see repository URL,
   commit SHA, and branch or tag. Put `DD_GIT_*` values in `.bazelrc` as
   `common:test-optimization --repo_env=DD_GIT_<NAME>`, not `--test_env`.
   The doctor scans versioned `.bazelrc` files for `--test_env=DD_GIT_*`, but
   it cannot detect a bad `--test_env=DD_GIT_*` flag typed directly on the CLI.

4. **Missing Bazel metadata**: The target should emit
   `bazel_target_metadata.json` next to payload files. Use the companion macro
   or generated wrapper instead of invoking the raw language test rule directly.

   For Python consumer-owned wrappers, the wrapper must expose an executable
   target with `RunEnvironmentInfo` preserved from the raw `py_test`; otherwise
   the public metadata wrapper can run but the actual pytest process may miss
   the required `DD_TEST_OPTIMIZATION_*` environment.

   In WORKSPACE mode, also verify that the Python helper maps the companion's
   internal `@rules_python` dependency to the consumer repository name:
   ```bzl
   datadog_python_test_optimization_workspace_repositories(
       rto_commit = "<commit-sha>",
       rules_python_repo_name = "rules_python",  # or the consumer's custom name
   )
   ```

5. **`full_bundle_no_match`**: The Go macro could not map the test target to a
   per-module bundle. Prefer `embed = [":lib"]` so the macro can read the same
   importpath that `rules_go` uses, or set `module_label_override` only when the
   module label is intentionally known. `module` and `module_override` are valid
   successful selections; `full_bundle_disabled` is valid when backend module
   data is disabled. Generic inferred/derived selection may intentionally use
   the canonical full bundle and report `full_bundle_no_match`; the doctor
   rejects that state by default, so only an intentionally generic consumer
   should set `forbid_full_bundle_no_match = False`.

   For a local-static descriptor, `runtime_module_path` identifies the sync
   repository but does not select payloads for every test beneath that root.
   Inspect `@<repo>//:module_*` and compare those labels with the effective test
   package importpath. The generated catalog handles Go's escaped runtime
   module name and external `_test` package automatically; do not derive those
   names from the sanitized Bazel label. A package present in a freshly synced
   catalog should report `module`.

6. **Expected target output missing**: Run the exact target listed in
   `expected_targets` before the doctor. With remote execution or remote cache,
   use the recommended test `.bazelrc` config:
   `--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs`.
   Export `DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE=bep` for doctor/uploader; if
   BEP references remote-only artifacts, enable BEP artifact resolution with
   `--artifact-source=bep --remote-artifacts=download`.

## BEP artifact resolution failures

**Symptom**: The doctor or uploader is configured with BEP freshness, but
loose `test.outputs/payloads/...` files are not present under `bazel-testlogs/`
because the Bazel invocation used remote execution/cache, zipped undeclared
outputs, or left the selected BEP artifacts remote-only.

**Solutions**:

1. Prefer selective local materialization plus zipped undeclared outputs when
   Bazel can download the needed outputs:
   ```text
   test:test-optimization --remote_download_minimal
   test:test-optimization --remote_download_regex=.*test[.]outputs.*
   test:test-optimization --zip_undeclared_test_outputs
   ```

2. Pass the same BEP file to doctor/uploader and enable local BEP artifact
   staging. The checked-in CI wrapper does this with repeatable CLI flags:
   ```bash
   tools/test_optimization/run_test_optimization_ci.sh //...
   ```
   Manual invocations should use the same temporary BEP and staging paths:
   ```bash
   bep_json="${bep_json:-/path/from/matching/bazel-test.bep.json}"
   artifact_staging_dir="${artifact_staging_dir:-$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")}"
   bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required \
     --artifact-source=bep \
     --artifact-staging-dir="$artifact_staging_dir"

   bazel run --config=test-optimization //:dd_upload_payloads -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required \
     --artifact-source=bep \
     --artifact-staging-dir="$artifact_staging_dir" \
     --dry-run \
     --validate-enrichment
   ```
   `--remote-artifacts` is not required for local `outputs.zip` files.

3. If CI cannot download `test.outputs` or `outputs.zip` locally, pass the same
   BEP file to doctor and uploader and enable remote staging. HTTP/HTTPS
   `outputs.zip` carriers can be staged without a downloader:
   ```bash
   artifact_staging_dir="${artifact_staging_dir:-$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-artifacts.XXXXXX")}"
   bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required \
     --artifact-source=bep \
     --remote-artifacts=download \
     --artifact-staging-dir="$artifact_staging_dir"

   bazel run --config=test-optimization //:dd_upload_payloads -- \
     --bep-json="$bep_json" \
     --freshness-source=bep \
     --freshness-mode=required \
     --artifact-source=bep \
     --remote-artifacts=download \
     --artifact-staging-dir="$artifact_staging_dir" \
     --dry-run \
     --validate-enrichment
   ```

4. For bytestream/CAS/custom provider BEP artifact references, or HTTP/HTTPS
   endpoints that require custom auth, configure one downloader executable:
   ```bash
   export DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER=/path/to/download-outputs-zip
   ```
   The executable receives `--uri`, `--name`, and `--output` arguments and must
   write an `outputs.zip` archive to `--output` before
   `--bep-artifact-downloader-timeout-sec` expires. If your provider needs an
   interpreter, fixed arguments, custom auth headers, mTLS, signed header
   refresh, or a CAS client, wrap it in a script and configure the wrapper path.
   The public rule does not ship credentials or a Datadog-internal CAS client.

Native HTTP/HTTPS staging is unauthenticated. It retries transient network
failures, truncated responses, HTTP 408, HTTP 429, and HTTP 5xx responses three
times with exponential backoff. It does not add custom headers, read
credentials, use cookies, or consult netrc. Query strings, fragments,
usernames, and passwords are redacted from doctor/uploader warnings and JSON
reports.

Common messages:

- `--artifact-source=bep requires --bep-json or DD_TEST_OPTIMIZATION_BEP_JSON`:
  pass the BEP JSON produced by the matching `bazel test` invocation.
- `BEP artifact is remote-only and no downloader is configured`: either use
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs`
  with `--artifact-source=bep`, enable `--remote-artifacts=download` for
  HTTP/HTTPS `outputs.zip` carriers, configure
  `DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER` for bytestream/CAS/custom-auth
  providers, or use `--remote-artifacts=disabled` outside required freshness
  mode.
- `BEP HTTP artifact download failed ... HTTP Error 401` or `403`: the endpoint
  likely requires auth. Use a downloader wrapper that injects the required
  credentials or headers.
- `BEP HTTP artifact download failed ... HTTP Error 404`: confirm the BEP URI
  still exists for the current job and has not expired.
- `BEP HTTP artifact download failed ... timed out`: native HTTP retries
  transient failures three times; raise `--bep-artifact-downloader-timeout-sec`
  only when each request attempt needs more time.
- `invalid BEP outputs.zip`: confirm the URL serves Bazel's `outputs.zip`, not
  HTML, JSON, or an error page.
- `BEP HTTP artifact is too large`: inspect undeclared test outputs for
  unexpected files; the compressed download and extracted tree both have size
  guards.
- `BEP artifact is not available locally`: the BEP points at a local path or
  `file://` URI that does not exist in this workspace. Check that the BEP file
  matches the current test invocation and machine.
- `remote-artifacts=required`: strict artifact mode is all-or-nothing. Missing,
  ambiguous, unsafe, or undownloadable selected BEP artifacts fail the command
  instead of falling back to local payloads.
- `unsafe path in BEP outputs.zip`: the archive contains an absolute path or
  parent traversal entry. Regenerate the archive or fix the downloader.
- `BEP outputs.zip has too many entries`: the archive exceeds the staging entry
  limit and is rejected before extraction.
- `BEP outputs.zip is too large after decompression`: the archive exceeds the
  staging decompressed-size limit.
- `BEP artifact staging requires PYTHON, python3, or python`: the uploader needs
  Python only when artifact staging is enabled. Set
  `DD_TEST_OPTIMIZATION_PYTHON` or `PYTHON` when Python is not discoverable as
  `python3` or `python` on `PATH`.

## Uploader enrichment dry-run

**Symptom**: Payload files exist, but Datadog UI or JSON inspection suggests the
uploaded test is missing Git or Bazel tags.

**Explanation**: Raw test payloads on disk are not the final upload body. The
uploader adds `context.json` and `bazel_target_metadata.json` tags immediately
before upload.

**Solution**: Run the uploader dry-run after tests and doctor:

```bash
bep_json="${bep_json:-/path/from/matching/bazel-test.bep.json}"
bazel run --config=test-optimization //:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --dry-run \
  --validate-enrichment
```

```powershell
$env:BEP_JSON = "C:\path\from\matching\bazel-test.bep.json"
bazel run --config=test-optimization //:dd_upload_payloads -- `
  --bep-json="$env:BEP_JSON" `
  --freshness-source=bep `
  --freshness-mode=required `
  --dry-run `
  --validate-enrichment
```

Dry-run mode does not upload, does not delete payload files, and does not need
`DD_API_KEY` for agentless mode. By default it requires
`git.repository_url`, `git.commit.sha`, `bazel.target`, and `bazel.package` in
the enriched test payload. Add
`--expected-enriched-tag=bazel.go.payload_selection` when a Go rollout must
prove per-module selection. If this fails:

1. Ensure the uploader target has the right `data = ["@...//:test_optimization_context"]`.
2. Ensure `bazel_target_metadata.json` exists beside the payloads.
3. When using the temporary legacy Bash uploader, ensure `jq` is available on
   Linux/macOS. Python uploader mode does not require `jq`.
4. Use `--expected-enriched-tag=<tag>` for repository-specific required tags.

## Python uploader cannot resolve Python

**Symptom**: The generated uploader prints `Python 3.10 or newer was not found`
or reports that the discovered interpreter is older than 3.10.

**Solution**:

1. Confirm the uploader target does not explicitly set
   `use_python_uploader = False`; that value selects the temporary legacy
   rollback path.
2. Set `DD_TEST_OPTIMIZATION_PYTHON` to an explicit Python 3.10+ executable.
   `PYTHON`, `python3`, and `python` are tried afterward, in that order.
3. On Windows, set the environment variable before invoking `bazel run`:
   ```powershell
   $env:DD_TEST_OPTIMIZATION_PYTHON = "C:\Python312\python.exe"
   bazel run //:dd_upload_payloads -- --dry-run
   ```
4. On Linux/macOS:
   ```bash
   DD_TEST_OPTIMIZATION_PYTHON=/usr/local/bin/python3.12 \
     bazel run //:dd_upload_payloads -- --dry-run
   ```

The launcher only resolves runfiles, the interpreter, and the generated config;
all enrichment and upload behavior remains in the shared Python runtime.

## Python uploader split and `413` failures

Python mode calculates the compact UTF-8 size after enrichment and before any
HTTP request. Test bodies larger than `4_718_592` bytes (4.5 MiB) are split
deterministically by event while preserving event order and all non-event
top-level fields.

- `single_event_exceeds_payload_limit`: one enriched event cannot fit by
  itself. Reduce the producing tracer/event metadata; increasing or overriding
  the uploader threshold is intentionally unsupported.
- `test_payload_not_json_serializable` or `invalid_test_json`: the source or an
  enriched value is not standards-compliant JSON. In particular, `NaN` and
  positive/negative `Infinity` are rejected.
- `payload_limit_contract_mismatch` after HTTP `413`: every prepared chunk was
  already at or below 4.5 MiB, so the backend limit or request contract differs
  from the uploader contract. The uploader retains the source, stops later
  chunks, does not retry `413`, and does not split adaptively.

Reproduce preparation without backend traffic or deletion:

```bash
bazel run //:dd_upload_payloads -- \
  --dry-run --allow-cached-payload-uploads --debug
```

```powershell
bazel run //:dd_upload_payloads -- `
  --dry-run --allow-cached-payload-uploads --debug
```

Inspect the final `split`, `requests`, and `cleanup` statistics and, when
configured, the schema-v1 JSON report. Do not retry a retained `413` payload
unchanged; first reconcile the configured 4.5 MiB contract with the backend.

## Non-standard bazel-testlogs location

**Symptom**: Uploader cannot find the `bazel-testlogs` directory.

**Solution**: Set `TESTLOGS_DIR` explicitly using the same Bazel flags:

```bash
# Bash - use array for multiple flags
BAZEL_FLAGS=("--output_base=/custom/base")
bep_json="${bep_json:-/path/from/matching/bazel-test.bep.json}"
TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required
```

```powershell
# PowerShell
$BazelFlags = @("--output_base=/custom/base")
$env:BEP_JSON = "C:\path\from\matching\bazel-test.bep.json"
$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)
bazel @BazelFlags run //:dd_upload_payloads -- `
  --bep-json="$env:BEP_JSON" `
  --freshness-source=bep `
  --freshness-mode=required
```

## Tests not uploading (network errors)

**Symptom**: Uploader fails with network errors.

**Solutions**:

1. **Verify credentials**:
   - Agentless mode requires: `DD_API_KEY`, `DD_SITE`
   - EVP proxy mode requires: `DD_TEST_OPTIMIZATION_AGENT_URL`

2. **Check firewall/proxy** allows HTTPS to:
   - `https://citestcycle-intake.datadoghq.com`
   - `https://citestcov-intake.datadoghq.com`
   - (or equivalent for your `DD_SITE`)

3. **Enable debug logging**:
   ```bzl
   dd_payload_uploader(
       name = "dd_upload_payloads",
       debug = True,
       ...
   )
   ```

## Per-module files not found

**Symptom**: `dd_topt_go_test` fails with "module_X not found" or falls back to
full bundle.

**Solutions**:

1. **List available modules**:
   ```bash
   bazel query 'kind(".*", @<repo_name>//...)' | grep module_
   ```
   ```powershell
   bazel query 'kind(".*", @<repo_name>//...)' | Select-String "module_"
   ```

2. **Override module label** explicitly (workaround):
   ```bzl
   dd_topt_go_test(
       name = "my_test",
       module_label_override = "my_expected_module",  # Matches :module_my_expected_module
       ...
   )
   ```

## Go tests instrumented by ddtest

`dd_topt_go_test` builds enabled tests with the Go SDK that `ddtest instrument`
instruments and links Mini, ddtest's Test Optimization runtime. The SDK and
Mini come from the ddtest release that
[`modules/go/topt_go_ddtest_repository.bzl`](../modules/go/topt_go_ddtest_repository.bzl)
pins. See [Go instrumentation SDK](Configuration_Reference.md#go-instrumentation-sdk)
for the configuration and
[ddtest's Bazel documentation](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md)
for the ddtest side. To move a 1.x setup, see the
[migration note](../CHANGELOG.md#unreleased).

### Instrumented test fails: no Go SDK to instrument

**Symptom**: Building or testing a `dd_topt_go_test` target fails with:

```text
Go tests instrumented by dd_topt_go_test need a Go SDK to instrument: add topt_go_ddtest.sdk(go_mod = "//:go.mod") to the root MODULE.bazel, or call topt_go_ddtest_repositories(go_version = ...) in WORKSPACE
```

**Cause**: The root module has no `topt_go_ddtest.sdk(...)` tag. The Go
companion then registers a stand-in toolchain that only instrumented tests
select, and it fails with this message. Builds without instrumented tests are
not affected. Tags in modules other than the root module are ignored.

**Solutions**:

1. In Bzlmod, add the tag to the root `MODULE.bazel`:
   ```bzl
   topt_go_ddtest = use_extension(
       "@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl",
       "topt_go_ddtest",
   )
   topt_go_ddtest.sdk(go_mod = "//:go.mod")  # or go_version = "1.25.0"
   ```
   The directory of `go_mod` must be a Bazel package.

2. In WORKSPACE, call `topt_go_ddtest_workspace_repositories` after
   `go_rules_dependencies()`. The message names `topt_go_ddtest_repositories`,
   which declares the repositories but does not register the toolchains:
   ```bzl
   load("@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl", "topt_go_ddtest_workspace_repositories")

   topt_go_ddtest_workspace_repositories(go_version = "1.25.0")
   ```
   Without this call, WORKSPACE has neither the instrumented toolchains nor
   the `@topt_go_ddtest_mini` repository, so analysis of an instrumented test
   fails on the missing repository instead of this message. See
   [Configure Go support in WORKSPACE](Installation_Reference.md#8-configure-go-support-in-workspace-with-the-public-helper).

### Analysis fails: test would link Mini twice

**Symptom**: Analysis of a `dd_topt_go_test` target fails with:

```text
//pkg:my_test would link Mini's packages twice: <labels> come from outside @topt_go_ddtest_mini. rules_go links one copy of each package without an error, so the test could run without Test Optimization. ...
```

**Cause**: A package of `github.com/DataDog/ddtest/ddto` reaches the test
through `deps` or `embed` from a repository other than the generated Mini,
usually go_deps' copy when the workspace's `go.mod` requires that module to use
Mini's Go API in tests. The macro also adds the generated Mini, and rules_go
would silently link only one of the two copies.

**Solution**: In the root `MODULE.bazel`, replace go_deps' copy with the
generated Mini. If the file already has a `topt_go_ddtest` extension proxy for
the `sdk` tag, add the last two lines next to it:

```bzl
topt_go_ddtest = use_extension("@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl", "topt_go_ddtest")
use_repo(topt_go_ddtest, "topt_go_ddtest_mini")
override_repo(go_deps, com_github_datadog_ddtest_ddto = "topt_go_ddtest_mini")
```

After the override, a test whose `deps` name `testopt` keeps that dependency;
the macro does not add it a second time. The macro cannot look inside a
`select()`, so when `deps` is or contains one, it always adds `testopt`, and
Bazel reports a duplicated label if `testopt` is also in the list. Remove
`@topt_go_ddtest_mini//testopt` from such a `deps`; the macro adds it. In
WORKSPACE, depend on `@topt_go_ddtest_mini` labels rather than on another
repository that provides the same module.

### DDTEST_INSTRUMENT contract mismatch

**Symptom**: Fetching `@topt_go_ddtest_mini` or an instrumented SDK fails with
a message such as:

```text
Mini's repository: DDTEST_INSTRUMENT has version="<value>", want "v0.0.0-pre-release-f5df4db" (ddtest pre-release-f5df4db)
```

For an SDK, the message starts with `the instrumented SDK for <platform>`.

**Cause**: After `ddtest instrument bazel` writes Mini or an SDK, the companion
reads the `DDTEST_INSTRUMENT` file that ddtest wrote and compares its
`contract`, `sdk_name`, and `version` with `DDTEST_RELEASE` in
[`modules/go/topt_go_ddtest_repository.bzl`](../modules/go/topt_go_ddtest_repository.bzl).
The downloaded executables are checked against the pinned SHA256 values, so
a mismatch usually means that `DDTEST_RELEASE` itself is inconsistent: its tag
and checksums name one ddtest release, and its `runtime_version`, `contract`,
or `sdk_name` another.

**Solution**: Use a released version of the Go companion without local edits
to `DDTEST_RELEASE`. When you change the pin, take the tag, the runtime
version, the contract, the SDK name, and the six checksums from the same ddtest
release. A different `contract` means the companion's rules and that ddtest
release do not agree on what ddtest writes; it needs a companion change, not a
different expected value.

### Instrumented test writes no payloads

**Symptom**: A Go test passes, but `bazel-testlogs/<target>/test.outputs/`
has no payloads or no `bazel_target_metadata.json`.

**Causes and solutions**:

1. **The export is disabled.** Without `--config=test-optimization`, or when
   the sync repository is disabled, `dd_topt_go_test` creates a plain
   `go_test` under the same name. Check the rule kind with the config you run
   tests with:
   ```bash
   bazel query --config=test-optimization --output=label_kind //pkg:my_test
   ```
   An enabled test prints `ddtest_go_test rule`; `go_test rule` means the
   export is disabled.

2. **The hidden test ran instead of the public one.** Only the public
   `<name>` target builds `<name>__raw_go_test` with the instrumented Go SDK
   and copies `bazel_target_metadata.json`. Run `<name>`.

3. **`ci_visibility_enabled = False`.** The macro then does not set
   `DD_CIVISIBILITY_ENABLED=true`. Set it in the test's `env`, or remove the
   attribute.

4. **The result was cached.** A `(cached)` result reuses the outputs of an
   earlier run, and BEP freshness skips them. Rerun the target with
   `--nocache_test_results` when you need new payloads from it.

5. **The outputs stayed remote.** With remote execution or a remote cache,
   follow item 4 of
   [Uploader not finding payloads](#uploader-not-finding-payloads).

### Bootstrap stops on a rules_go fork override

**Symptom**: `dd_topt_go_bootstrap` stops with:

```text
MODULE.bazel has a git_override of rules_go with the removed Datadog rules_go fork (strip_prefix = <fork path>); remove it so that rules_go comes from the Bazel Central Registry, then rerun the bootstrap
```

The same message names `archive_override` or `local_path_override` (with
`path`) for those override kinds.

**Cause**: `MODULE.bazel` overrides `rules_go` with the Datadog fork that 1.x
used, outside the Go bootstrap block that 1.x wrote. Bootstrap replaces that
block itself, but leaves other overrides to you.

**Solution**: Delete the override so that `bazel_dep(name = "rules_go", ...)`
resolves from the Bazel Central Registry (0.60.0 or newer), then rerun the
bootstrap. If the workspace cannot load because the fork commit in the old block
is no longer fetchable, run the bootstrap from another Bazel workspace that
depends on the Go companion and pass `--workspace /path/to/your/workspace`, or
delete the old block by hand and rerun. A `# BEGIN Datadog Go Pin Files` block
that 1.x left in a `BUILD` file is not used anymore; you can delete it.

## Large monorepo validation is easy to run incorrectly

**Symptom**: onboarding works in small fixtures but large WORKSPACE repos need a
long command sequence, local controls, disk checks, and an explicit upload step.

**Solutions**:

1. Generate a local validation script instead of hand-copying commands:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --workspace-mode \
     --write-validation-script \
     --bazel-command bzl \
     --bazel-config test-optimization \
     --sync-repo-name test_optimization_data \
     --control-target //pkg/plain:go_default_test \
     --expected-target //pkg:go_default_test \
     --large-monorepo \
     --shutdown-bazel-on-exit
   ```

2. Run without upload first:
   ```bash
   ./tools/test_optimization/validate_go_pilot.sh --no-upload
   ```

3. When credentials and upload authorization are available, run the upload even
   if the validation-only attempt reported a test, doctor, or dry-run failure.
   The script uploads every available fresh valid payload and still returns the
   earliest failure:
   ```bash
   DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
     ./tools/test_optimization/validate_go_pilot.sh --upload
   ```

The generated script never deletes caches. In `--large-monorepo` mode it warns
when free disk drops below `--min-free-disk-gb`, runs phases serially, and can
shut down Bazel on exit. It still depends on the normal Bazel config for
`--remote_download_minimal --remote_download_regex=.*test[.]outputs.*` and
`--zip_undeclared_test_outputs`, plus BEP runtime configuration through
`DD_TEST_OPTIMIZATION_*` or equivalent CLI flags; no rule can force that
client-side Bazel behavior.

## Windows-specific issues

**Symptom**: PowerShell errors or path issues.

**Solutions**:

1. **Verify PowerShell execution policy**:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

2. **Check paths use forward slashes** in Starlark/Bazel contexts (backslashes
   are auto-converted).
3. **Use native PowerShell harness on Windows**:
   - `.\tools\tests\integration\run_mock_server_tests.ps1`
   - Git Bash is not required for Windows integration runs.

## Safe command patterns

- Prefer explicit env assignment over shell interpolation in troubleshooting
  commands:
  - Unix: `DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads`
  - PowerShell: set `$env:DD_API_KEY` and `$env:DD_SITE` first, then run `bazel run --config=test-optimization //:dd_upload_payloads`
- Quote paths containing spaces and avoid `eval`-style wrappers.
- For refetch debugging, use:
  - `bazel sync --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`
  - if required by workspace mode: `bazel sync --enable_workspace --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`

## Getting help

If issues persist:

1. **Enable debug mode** and capture full output:
   ```bash
   bazel sync --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT=<timestamp> 2>&1 | tee debug.log
   ```
   ```powershell
   bazel sync --config=test-optimization --only=<repo_name> --repo_env=FETCH_SALT=<timestamp> *>&1 | Tee-Object -FilePath debug.log
   ```

2. **Collect diagnostic info**:
   - Bazel version: `bazel version`
   - OS: `uname -a` (Linux/macOS) or `systeminfo` (Windows)
   - Repository rule outputs (as shown above)
   - Doctor and uploader JSON reports, if the failing run produced them
   - Sanitized logs (remove API keys before sharing)

3. **File an issue**:
   - open an issue in the repository issue tracker with sanitized logs
