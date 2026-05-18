<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Troubleshooting

Examples below assume the generated repository is named
`test_optimization_data`. If you used a different `name`, replace labels and
`bazel sync --only=<repo_name>` accordingly.

If Bazel reports that sync requires WORKSPACE support, add
`--enable_workspace` to sync commands in this document.

## Quick triage map

| Symptom | First checks | Likely section |
|---------|--------------|----------------|
| No files fetched or stale data | `DD_API_KEY` forwarded with `--repo_env`; use `FETCH_SALT` only for an explicit force-refresh sync | Repository rule not fetching data |
| Uploader says no payload files | tracer file-mode contract + payload files under `bazel-testlogs/*/test.outputs/` | Uploader not finding payloads |
| Doctor reports msgpack payloads | tracer is not in Bazel JSON file mode | Doctor failures |
| Doctor reports missing Git or Bazel metadata | sync metadata context or sidecar metadata is absent | Doctor failures |
| Uploaded tests miss Git or Bazel tags | run uploader dry-run enrichment validation | Uploader enrichment dry-run |
| Upload network errors | credential mode (agentless vs EVP), intake reachability | Tests not uploading (network errors) |
| Module selection misses | `bazel query` for `module_*` targets and importpath/module label expectations | Per-module files not found |
| Go build fails with a tracer version mismatch | `dd_trace_go_version`, `dd_trace_go_versions`, `--dd-trace-go-version`, local `go.mod` pins | Go tracer version drift |
| Bazel resolves an older tracer or Orchestrion module in WORKSPACE mode | checked-in `go_repository(...)` pins | WORKSPACE go_repository drift |
| WORKSPACE archive pins fail after a PR was squash-merged | generated pins commit reachability and archive SHA | Published Go pins |
| Private/internal WORKSPACE fetch returns 404 | SSH git or authenticated archive access | Private repository fetch |
| Bazel downloads unrelated toolchains or analyzes unrelated packages | cold monorepo state or root-package doctor/uploader placement | Monorepo analysis cost |
| Windows path/policy failures | PowerShell policy + path separators | Windows-specific issues |

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
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT="$(date +%s)"
   ```
   ```powershell
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT="$(Get-Date -UFormat %s)"
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

## Published Go pins

**Symptom**: A consumer cannot fetch the published Go/Orchestrion archive, or a
pin that worked during review stops working after a squash merge.

**Cause**: The consumer was given a feature-branch commit, a stale archive hash,
or a tuple that was not generated from the real GitHub codeload archive.

**Solutions**:

1. **Regenerate pins from `origin/main`** in this repository:
   ```bash
   ./bazelw run //tools/dev:print_go_onboarding_pins -- \
     --commit "$(git rev-parse origin/main)" \
     --variant complete \
     --verify-main-reachable
   ```

2. **If you are in a consumer repo**, use the bootstrap helper with the
   squash-merged commit:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --print-published-pins \
     --rto-commit <published-origin-main-sha> \
     --rules-go-variant complete
   ```

3. **Keep the generated tuple together**. If `RTO_COMMIT`,
   `RTO_ARCHIVE_URL`, `RTO_ARCHIVE_SHA256`, and `RTO_ARCHIVE_PREFIX` come from
   different commits, archive mode will fail or fetch the wrong source.

4. **Authenticate private archive downloads**. The helper uses `GITHUB_TOKEN`,
   `GH_TOKEN`, or `gh auth token` when available. If codeload returns `404` for
   a commit you can see in GitHub, refresh local GitHub CLI authentication or
   set one of those token variables before regenerating pins.

5. **Use the generated summary for handoff** when a monorepo needs a permanent
   local guide:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --write-onboarding-summary=TEST_OPTIMIZATION_GUIDE.md \
     --rto-commit <published-origin-main-sha> \
     --rules-go-variant complete
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
   bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor
   bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- --dry-run --validate-enrichment
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
   bazel test //your:test --test_output=all 2>&1 | grep DD_TEST_OPTIMIZATION
   ```
   ```powershell
   bazel test //your:test --test_output=all *>&1 | Select-String "DD_TEST_OPTIMIZATION"
   ```
   PowerShell uses `*>&1` (not Bash `2>&1`) to merge stderr/stdout.

4. **For RBE users**: Add `--remote_download_outputs=all` to download test
   outputs locally.

## Doctor failures

**Symptom**: `bazel run --config=test-optimization //:dd_test_optimization_doctor`
fails before upload.

**Solutions**:

1. **Msgpack payloads**: Go/Orchestrion Bazel mode must write JSON payloads to
   `TEST_UNDECLARED_OUTPUTS_DIR`. If the doctor finds `.msgpack` or
   `.msgpack.gz`, verify that the target uses the Go test optimization macro or
   wrapper and that the configured `dd-trace-go` version includes Bazel JSON
   file-mode support.

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
   data is disabled.

6. **Expected target output missing**: Run the exact target listed in
   `expected_targets` before the doctor. With remote execution or remote cache,
   run tests with `--remote_download_outputs=all` or the doctor will not see
   `test.outputs` locally.

## Uploader enrichment dry-run

**Symptom**: Payload files exist, but Datadog UI or JSON inspection suggests the
uploaded test is missing Git or Bazel tags.

**Explanation**: Raw test payloads on disk are not the final upload body. The
uploader adds `context.json` and `bazel_target_metadata.json` tags immediately
before upload.

**Solution**: Run the uploader dry-run after tests and doctor:

```bash
bazel run --config=test-optimization //:dd_upload_payloads -- --dry-run --validate-enrichment
```

```powershell
bazel run --config=test-optimization //:dd_upload_payloads -- --dry-run --validate-enrichment
```

Dry-run mode does not upload, does not delete payload files, and does not need
`DD_API_KEY` for agentless mode. By default it requires
`git.repository_url`, `git.commit.sha`, `bazel.target`, `bazel.package`, and
`bazel.go.payload_selection` in the enriched test payload. If this fails:

1. Ensure the uploader target has the right `data = ["@...//:test_optimization_context"]`.
2. Ensure `bazel_target_metadata.json` exists beside the payloads.
3. Ensure `jq` is available on Linux/macOS when using `--validate-enrichment`.
4. Use `--expected-enriched-tag=<tag>` for repository-specific required tags.

## Non-standard bazel-testlogs location

**Symptom**: Uploader cannot find the `bazel-testlogs` directory.

**Solution**: Set `TESTLOGS_DIR` explicitly using the same Bazel flags:

```bash
# Bash - use array for multiple flags
BAZEL_FLAGS=("--output_base=/custom/base")
TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads
```

```powershell
# PowerShell
$BazelFlags = @("--output_base=/custom/base")
$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)
bazel @BazelFlags run //:dd_upload_payloads
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

## Go tracer version drift

**Symptom**: Go bootstrap or Bazel build fails with a message showing a
configured tracer version map and a different resolved local `dd-trace-go`
module version.

**Solutions**:

1. **If you use guided bootstrap**, rerun it with the query you want:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --dd-trace-go-version <tag-or-sha>
   ```
   Bootstrap accepts tags, pseudo-versions, branches, and commit SHAs. It
   rewrites the workspace to the exact resolved versions that Go actually uses.
   By default it uses targeted module sync, not `go mod tidy`.

2. **If targeted sync reports readonly module errors**, rerun bootstrap with
   explicit targeted sync and the same Go SDK your repository expects:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --go-mod-sync=targeted \
     --go-binary /path/to/go
   ```
   If the workspace uses checked-in `go_repository` declarations, refresh those
   declarations after `go.mod` or `go.sum` changes so Bazel and the Go module
   graph agree.

3. **If you wire Orchestrion manually**, make sure both places match:
   - `orchestrion.from_source(..., dd_trace_go_version = "<version>")`
   - or `orchestrion.from_source(..., dd_trace_go_versions = {...})`
   - the effective local module graph resolved from `go.mod` and `go.sum`

4. **If you omitted the version entirely**, remember the default is
   `v2.9.0-rc.2`.

The build fails on purpose here. It is preventing Bazel from injecting one
set of tracer versions while the local Go module still resolves another.

`orchestrion.tool.go` still matters, but as required import/config wiring for
Orchestrion, not as the source of truth for tracer versions.

## WORKSPACE go_repository drift

**Symptom**: `go.mod` and `go.sum` look correct, but Bazel still resolves an
older `github.com/DataDog/orchestrion` or `dd-trace-go` module from a checked-in
`repositories.bzl` file.

**Cause**: WORKSPACE repositories often keep generated `go_repository(...)`
declarations separate from `go.mod`. Updating the Go module graph is not enough
if the generated repository file still pins old versions.

**Solutions**:

1. **Run bootstrap diagnostics after targeted sync**:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --workspace-mode \
     --write-orchestrion-files \
     --go-mod-sync=targeted \
     --check-go-repositories \
     --go-repositories-file repositories.bzl
   ```
   The checker compares only the modules bootstrap owns:
   `github.com/DataDog/orchestrion`, `github.com/DataDog/dd-trace-go/v2`,
   `github.com/DataDog/dd-trace-go/contrib/net/http/v2`, and
   `github.com/DataDog/dd-trace-go/contrib/log/slog/v2`.

2. **Let your repo-owned refresh command repair the file**:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --workspace-mode \
     --write-orchestrion-files \
     --go-mod-sync=targeted \
     --check-go-repositories \
     --go-repositories-file repositories.bzl \
     --go-repositories-refresh-command './tools/update-go-repositories.sh'
   ```
   Bootstrap runs the refresh command only after targeted sync succeeds, then
   validates `repositories.bzl` again. It never edits `repositories.bzl`
   directly.

3. **Print expected versions for manual updates**:
   ```bash
   bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
     --workspace-mode \
     --go-mod-sync=off \
     --check-go-repositories \
     --print-go-repository-updates
   ```
   This is useful when the repository has a custom Gazelle/update-repos flow
   that must be run manually or in a separate review step.

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

3. Upload only after tests and doctor pass:
   ```bash
   DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
     ./tools/test_optimization/validate_go_pilot.sh --upload
   ```

The generated script never deletes caches. In `--large-monorepo` mode it warns
when free disk drops below `--min-free-disk-gb`, runs phases serially, and can
shut down Bazel on exit. It still depends on the normal Bazel config for
`--remote_download_outputs=all`; no rule can force that client-side behavior.

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
  - `bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`
  - if required by workspace mode: `bazel sync --enable_workspace --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`

## Getting help

If issues persist:

1. **Enable debug mode** and capture full output:
   ```bash
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp> 2>&1 | tee debug.log
   ```
   ```powershell
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp> *>&1 | Tee-Object -FilePath debug.log
   ```

2. **Collect diagnostic info**:
   - Bazel version: `bazel version`
   - OS: `uname -a` (Linux/macOS) or `systeminfo` (Windows)
   - Repository rule outputs (as shown above)
   - Sanitized logs (remove API keys before sharing)

3. **File an issue**:
   - open an issue in the repository issue tracker with sanitized logs
