# Troubleshooting

Examples below assume the generated repository is named
`test_optimization_data`. If you used a different `name`, replace labels and
`bazel sync --only=<repo_name>` accordingly.

If Bazel reports that sync requires WORKSPACE support, add
`--enable_workspace` to sync commands in this document.

## Quick triage map

| Symptom | First checks | Likely section |
|---------|--------------|----------------|
| No files fetched or stale data | `DD_API_KEY` forwarded, `bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>` | Repository rule not fetching data |
| Uploader says no payload files | tracer file-mode contract + payload files under `bazel-testlogs/*/test.outputs/` | Uploader not finding payloads |
| Upload network errors | credential mode (agentless vs EVP), intake reachability | Tests not uploading (network errors) |
| Module selection misses | `bazel query` for `module_*` targets and importpath/module label expectations | Per-module files not found |
| Go build fails with a tracer version mismatch | `dd_trace_go_version`, `dd_trace_go_versions`, `--dd-trace-go-version`, local `go.mod` pins | Go tracer version drift |
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

2. **Force refetch** with a cache-busting salt:
   ```bash
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>
   ```
   ```powershell
   bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>
   ```

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

2. **If you wire Orchestrion manually**, make sure both places match:
   - `orchestrion.from_source(..., dd_trace_go_version = "<version>")`
   - or `orchestrion.from_source(..., dd_trace_go_versions = {...})`
   - the local Go module pins in `go.mod` and `orchestrion.tool.go`

3. **If you omitted the version entirely**, remember the default is `v2.6.0`.

The build fails on purpose here. It is preventing Bazel from injecting one
set of tracer versions while the local Go module still resolves another.

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
  - Unix: `DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads`
  - PowerShell: set `$env:DD_API_KEY` and `$env:DD_SITE` first, then run `bazel run //:dd_upload_payloads`
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
