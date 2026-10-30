<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Troubleshooting Go Onboarding

Use this reference when validation fails or the Datadog UI shows incomplete
test setup.

## No Payloads Found

Symptoms:

- Doctor says no Test Optimization output directories were found.
- `bazel-testlogs` has no `test.outputs/payloads`.

Checks:

- Did the instrumented runtime test actually run after instrumentation?
- Did the test run with `--config=test-optimization`? Without it, the export
  is disabled and `dd_topt_go_test` creates a plain `go_test` that writes no
  payloads.
- Is the doctor looking at the actual sync repository name for the service?
- Is the target a `.build_test` or build-only control? Those do not emit test
  runtime payloads.
- Did the test use `dd_topt_go_test` or the repo-local wrapper that delegates
  to it?
- Does the repo-local wrapper inject `topt_data` from the actual generated
  service repository, for example `@test_optimization_data_<service>//:export.bzl`?
- Does the target keep the default `ci_visibility_enabled = True`? The macro
  then sets `DD_CIVISIBILITY_ENABLED=true` for the test.
- With remote execution/cache, did the test config use
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.*`
  plus `--zip_undeclared_test_outputs`?
- Did doctor/uploader run with repeatable `--bep-json=<path>`,
  `--freshness-source=bep`, `--freshness-mode=required`,
  `--artifact-source=bep`, and `--artifact-staging-dir=<temp-dir>`?
- If BEP still points at HTTP/HTTPS `outputs.zip` artifacts, did
  doctor/uploader use `--artifact-source=bep --remote-artifacts=download`
  without a downloader? If BEP points at bytestream/CAS/custom-auth artifacts,
  did it also configure `--bep-artifact-downloader`? Use
  `--remote-artifacts=required` only when the rollout should fail if any
  selected artifact cannot be materialized.
- If local outputs may be stale while BEP can stage fresh carriers, consider
  `--artifact-source=auto --remote-artifacts=download` so staged outputs win for
  matching BEP output keys.

Fix the target selection or wrapper first. Do not work around missing payloads
by adding a proxy or uploading from inside the test sandbox. See also
[`docs/Troubleshooting.md`](../../../../docs/Troubleshooting.md#instrumented-test-writes-no-payloads).

## Managed Target Missing From `topt_data_by_target`

Symptoms:

- a requested central `dd_go_test` remains raw in an enabled managed run;
- doctor does not list the target in its generated exact-target set.

Checks:

- The consumer command expanded the target to a canonical local label.
- The target carries the consumer's supported central-macro marker.
- The full label used by the wrapper exactly matches the manifest label.
- Service derivation succeeded and produced one Go runtime context.
- The target was not filtered out as build-only or unsupported.

Fix target discovery or service derivation in the consumer command. Do not add a
checked-in mapping or special-case the label in the Rule.

## Managed Manifest Fails Before HTTP

Missing, malformed, duplicate, unsupported-runtime, or colliding manifest
entries fail before metadata requests. Invoke the consumer's managed command
and inspect its discovery summary. Do not hand-edit the temporary manifest or
persist its private handoff in `.bazelrc`.

## Msgpack Payloads Instead Of JSON

Symptoms:

- Doctor rejects `.msgpack` or `.msgpack.gz`.
- Payload directory contains msgpack files and no JSON payloads.

Checks:

- The target is built by `dd_topt_go_test` or the central wrapper that
  delegates to it. The macro sets `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true`
  so payloads are written as JSON files.
- No local proxy behavior has been added.

Do not add a msgpack conversion path as part of onboarding. If the macro wiring
is correct and payloads are still msgpack, stop and escalate.

## Instrumented Test Fails: No Go SDK To Instrument

Symptoms:

- An instrumented test fails with `Go tests instrumented by dd_topt_go_test
  need a Go SDK to instrument`.

Meaning:

- In Bzlmod, the root module has no `topt_go_ddtest.sdk(...)` tag, so a
  stand-in toolchain answers for the instrumented SDK.
- In WORKSPACE, nothing registers the stand-in. Without
  `topt_go_ddtest_workspace_repositories(...)`, analysis fails on the
  undeclared `@topt_go_ddtest_mini` repository instead.

Fix:

- Add `topt_go_ddtest.sdk(go_mod = "//:go.mod")` or
  `topt_go_ddtest.sdk(go_version = "<go-version>")` to the root
  `MODULE.bazel`, or rerun the bootstrap. Set exactly one `sdk` tag, in the root
  module.
- In WORKSPACE, call `topt_go_ddtest_workspace_repositories(...)` after
  `go_rules_dependencies()`. It declares the repositories and registers the
  toolchains. The message names `topt_go_ddtest_repositories`, which does not
  register them.

See [`docs/Troubleshooting.md`](../../../../docs/Troubleshooting.md#instrumented-test-fails-no-go-sdk-to-instrument).

## Analysis Fails: Test Would Link Mini Twice

Symptoms:

- Analysis of an instrumented test fails with `would link Mini's packages
  twice`, followed by the labels that come from outside
  `@topt_go_ddtest_mini`.

Meaning:

- The test depends on a copy of `github.com/DataDog/ddtest/ddto` from another
  repository, usually the one that `go_deps` created from `go.mod`. rules_go
  would link one copy without an error, so the test could run without Test
  Optimization.

Fix:

- In Bzlmod, apply the recipe from the error message in the root
  `MODULE.bazel`:

  ```bzl
  use_repo(topt_go_ddtest, "topt_go_ddtest_mini")
  override_repo(go_deps, com_github_datadog_ddtest_ddto = "topt_go_ddtest_mini")
  ```

- In WORKSPACE, depend on the packages of `@topt_go_ddtest_mini` instead of a
  `go_repository` copy of the module.

See [`docs/Troubleshooting.md`](../../../../docs/Troubleshooting.md#analysis-fails-test-would-link-mini-twice).

## DDTEST_INSTRUMENT Contract Mismatch

Symptoms:

- Fetching Mini's repository or an instrumented SDK fails with
  `DDTEST_INSTRUMENT has <key>=..., want ...`.

Meaning:

- The ddtest executable wrote a `contract`, `sdk_name`, or `version` that
  differs from the ddtest release pinned in `rules_test_optimization`.

This is not a consumer configuration problem. Do not edit generated
repositories or patch the rule. Stop and escalate with the full message; see
[`docs/Troubleshooting.md`](../../../../docs/Troubleshooting.md#ddtest_instrument-contract-mismatch).

## Bootstrap Stops On A rules_go Fork Override

Symptoms:

- `dd_topt_go_bootstrap` fails with `MODULE.bazel has a ... of rules_go with
  the removed Datadog rules_go fork`.

Meaning:

- `MODULE.bazel` still overrides `rules_go` with the 1.x fork outside the
  managed bootstrap block.

Fix:

- Remove that override so `rules_go` comes from the Bazel Central Registry,
  then rerun the bootstrap. If Bazel cannot load the workspace to run the
  bootstrap, run it from another workspace with
  `--workspace /absolute/path/to/consumer`, or delete the old managed block by
  hand. See the [migration note](../../../../CHANGELOG.md#unreleased) and
  [`docs/Troubleshooting.md`](../../../../docs/Troubleshooting.md#bootstrap-stops-on-a-rules_go-fork-override).

## Missing Git Metadata

Symptoms:

- Datadog UI says "Test setup is incomplete" or "missing git information".
- Doctor fails required Git metadata.

Checks:

- `DD_GIT_REPOSITORY_URL`, `DD_GIT_BRANCH` or `DD_GIT_TAG`, and
  `DD_GIT_COMMIT_SHA` are available to repository/module resolution through
  `--repo_env`.
- `.bazelrc` does not use `--test_env=DD_GIT_*`.
- `.bazelrc` or CI passes the full sync metadata key set through `--repo_env`
  when those values are available, including `DD_SITE`,
  `DD_TEST_OPTIMIZATION_AGENTLESS_URL`, `DD_SERVICE`, `DD_ENV`, `DD_PR_NUMBER`,
  and the `DD_GIT_*` keys.
- CI checkout is not detached without an explicit branch/tag override.
- The sync repository was refreshed after adding Git metadata:
  `bazel sync --config=test-optimization --only=test_optimization_data_<service_key>
  --repo_env=FETCH_SALT="$(date +%s)"`.

Do not pass `DD_GIT_*` into the test sandbox. That invalidates test action cache
keys and violates the onboarding contract.

## Missing Bazel Metadata

Symptoms:

- Doctor reports missing `bazel_target_metadata.json`.
- Datadog UI lacks Bazel target tags.

Checks:

- The target uses the central Go wrapper that delegates to `dd_topt_go_test`.
- The macro is not bypassed by a repo-local wrapper path.
- The payload files came from the current test run.
- Remote outputs were downloaded locally.
- The target is a runtime test target, not a `.build_test` or build-only
  control listed accidentally in `expected_targets`.

Fix the wrapper or command path. Do not fake Bazel tags in the uploader.

## `full_bundle_no_match`

Symptoms:

- Doctor fails with invalid Go payload selection.
- Payload metadata contains `bazel.go.payload_selection = "full_bundle_no_match"`.

Meaning:

- The Go macro could not match an inferred/derived test target to a module
  payload and used the canonical full bundle. The doctor rejects this by
  default because known pilots normally require an exact module match.

Checks:

- Prefer `embed = [":go_library"]` so importpath inference matches rules_go.
- If using explicit `importpath`, verify it is exactly what the compiled Go
  package uses.
- Verify the synced metadata includes the module path expected for this target.
- For monorepos, verify `topt_data` or `topt_data_by_service` points to the
  correct service/runtime slice.
- For a local-static descriptor, treat `runtime_module_path` as repository
  identity, not as the package selection. Compare the test importpath with the
  generated `@<repo>//:module_*` catalog. The sync repository handles Go's
  escaped runtime identifier and external `_test` package; do not copy a
  sanitized target label into `module_label_override` to compensate for either.

For known pilots, valid alternatives are `module`, `module_override`, and
`full_bundle_disabled`. `full_bundle_disabled` is acceptable when the setup
intentionally has no module groups. A repository that intentionally permits
generic inferred/derived fallback may set
`forbid_full_bundle_no_match = False` on its doctor target; do not use that
exception to hide a missing module match for a known pilot.

## Diagnostic Reports

When logs are long or ambiguous, first ask for a doctor-only support bundle with
`bazel run --config=test-optimization //<topt-package>:dd_test_optimization_doctor -- --support-bundle=<path>` plus any
matching BEP/artifact flags. Use the CI wrapper bundle when uploader dry-run or
upload results matter. If a repository cannot use either bundle mode, collect
`doctor-report.json`, `uploader-dry-run-report.json`, optional
`uploader-upload-report.json`, then use `create_support_bundle.py` manually if
the helper is available. Render `upload-diagnostics.md` only as a Markdown
fallback.

- Doctor: pass `--support-bundle=<path>` for the redacted doctor-only zip, or
  `--report-json=<path>` for the raw machine-readable doctor report.
- Uploader: pass `--report-json=<path>` after the uploader target's `--`
  separator, or set `DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON`.
- Wrapper: prefer `--report-dir=<path>` plus `--support-bundle=<path>`, or set
  `DD_TEST_OPTIMIZATION_REPORT_DIR` and
  `DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE`, so CI archives both individual reports
  and `dd-test-optimization-support.zip`.

Use the support bundle to compare `result.reason_code`, next steps, expected
targets, BEP freshness, artifact staging, payload directories, payload counts,
status, exit code, effective flags, runtime metadata, and selected BEP summaries
without reading the full CI log. Wrapper bundles also include upload attempts
and upload failures.
`tools/test_optimization/render_report_summary.py` can render raw JSON files as
a short Markdown fallback summary. Review raw reports for internal paths and
target names before sharing outside the trusted project boundary.

Support bundle intake order:

1. Read `summary.md` for the support-facing failure classification.
2. Read `diagnostics.json` for `summary.status`,
   `summary.primary_reason_code`, report count, BEP summary count, and payload
   counts.
3. Read `reports/doctor-report.json` for expected targets, seen targets,
   missing target roots, fresh/cached/remote-only BEP outputs, and artifact
   staging results.
4. If present, read `reports/uploader-dry-run-report.json` before any upload
   report. It proves payload discovery and enrichment without sending data.
5. If present, read `reports/uploader-upload-report.json` for real upload
   attempts and terminal upload failures.
6. Read `command/flags.json` to verify the test run used a unique BEP file and
   doctor/uploader used the matching `--bep-json`, freshness, artifact-source,
   artifact-staging, and remote-artifact flags.

If `command/flags.json` shows `upload_mode=doctor_only_no_uploader`, do not
claim uploader or Datadog intake behavior was validated. Ask for the wrapper
support bundle when dry-run, enrichment, or real upload behavior matters.

## Instrumented SDK Repositories Fail To Load rules_go

Symptoms:

- Fetching or building an instrumented test fails because a
  `topt_go_ddtest_sdk_<platform>` repository cannot load `@io_bazel_rules_go`.

Checks:

- In WORKSPACE, upstream `rules_go` is declared as `io_bazel_rules_go`. The SDK
  repositories that `go_wrap_sdk` writes load it under that name.
- `rules_go` is upstream `0.60.0` or newer, with no 1.x fork override.

## Local Disk Pressure

Go validation can use significant disk through Bazel output bases and the
instrumented SDKs, one per selected exec platform. Disabled Test Optimization
runs do not fetch the instrumented SDKs.

Safe cleanup sequence:

```bash
bazel shutdown
rm -rf /private/var/tmp/_bazel_"$(whoami)"
rm -rf "$HOME/Library/Caches/bazel"
```

Do not delete a consumer repository's `.git` directory. Do not clear
`~/go/pkg/mod` or run `go clean -modcache` unless you explicitly accept the
redownload cost.
