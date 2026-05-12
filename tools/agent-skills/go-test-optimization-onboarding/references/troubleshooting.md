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
- Is the doctor looking at the actual sync repository name for the service?
- Is the target a `.build_test` or build-only control? Those do not emit test
  runtime payloads.
- Did the test use `dd_topt_go_test` or the repo-local wrapper that delegates
  to it?
- Does the repo-local wrapper inject `topt_data` from the actual generated
  service repository, for example `@test_optimization_data_<service>//:export.bzl`?
- Is `DD_CIVISIBILITY_ENABLED` or equivalent tracer setup enabled by the macro?
- With remote execution/cache, did the test config use
  `--remote_download_outputs=all`?

Fix the target selection or wrapper first. Do not work around missing payloads
by adding a proxy or uploading from inside the test sandbox.

## Msgpack Payloads Instead Of JSON

Symptoms:

- Doctor rejects `.msgpack` or `.msgpack.gz`.
- Payload directory contains msgpack files and no JSON payloads.

Meaning:

- The tracer did not enter the Bazel filesystem payload mode expected by this
  rule.

Checks:

- The repository uses a dd-trace-go version with Bazel JSON payload support.
- The test macro injects the static Bazel-mode environment required by the
  tracer.
- The consumer Go module resolves the same tracer version configured for
  Orchestrion.
- No local proxy behavior has been added.

Fix the tracer version or macro wiring. Do not add a msgpack conversion path as
part of onboarding unless the rule contract is intentionally redesigned.

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

- The target uses the Test Optimization wrapper.
- The macro is not bypassed by a repo-local wrapper path.
- The payload files came from the current test run.
- Remote outputs were downloaded locally.
- The target is a runtime test target, not a `.build_test` or build-only
  control listed accidentally in `expected_targets`.
- The root pin labels used by `orchestrion_pin_files` are exported and visible,
  especially `//:go.mod`, `//:go.sum`, `//:orchestrion.tool.go`, and
  `//:orchestrion.yml` when those labels are used.

Fix the wrapper or command path. Do not fake Bazel tags in the uploader.

## `full_bundle_no_match`

Symptoms:

- Doctor fails with invalid Go payload selection.
- Payload metadata contains `bazel.go.payload_selection = "full_bundle_no_match"`.

Meaning:

- The Go macro could not match the test target to a module payload and the full
  bundle did not provide a safe fallback.

Checks:

- Prefer `embed = [":go_library"]` so importpath inference matches rules_go.
- If using explicit `importpath`, verify it is exactly what the compiled Go
  package uses.
- Verify the synced metadata includes the module path expected for this target.
- For monorepos, verify `topt_data` or `topt_data_by_service` points to the
  correct service/runtime slice.

Valid alternatives are `module`, `module_override`, and
`full_bundle_disabled`. `full_bundle_disabled` is acceptable only when the setup
intentionally lacks backend full-bundle data.

## Fingerprint Or Linker Mismatches

Symptoms:

- Go compile or link fails after enabling Orchestrion.
- Failures mention package fingerprints, archives, or mismatched compiled
  inputs.

Checks:

- The consumer uses a current published commit from this repository.
- The consumer resolves `rules_go` to `rules_go_orchestrion_base` or
  `rules_go_orchestrion_complete`, not upstream plain `rules_go`.
- The WORKSPACE helper or Bzlmod override points at the correct variant.
- `go_orchestrion_tool_repo` is loaded from the same `rules_go` repository name
  used by the consumer, not from an undeclared default alias.
- Local Orchestrion caches are not stale. If local-only behavior diverges from
  CI, shut down Bazel and clear the Orchestrion cache.

Do not fix this by patching the consumer. Correctness bugs in the fork belong in
`rules_test_optimization` with fixture coverage.

## Existing dd-trace-go Version Conflict

Symptoms:

- `go mod` changes more than expected.
- The repository already pins Datadog tracer modules.
- Instrumented tests build with one tracer version while Orchestrion is pinned
  to another.

Checks:

- Bootstrap should resolve one coherent tracer version set.
- The Go module must resolve packages injected into the final test binary.
- Do not maintain two conflicting tracer versions between Orchestrion tooling
  and the target's Go module.

If the repository needs a different tracer version, make that an explicit
version decision and validate with real tests, doctor, dry-run, and upload.

## Local Disk Pressure

Go/Orchestrion validation can use significant disk through Bazel output bases,
Go caches, and Orchestrion caches.

Safe cleanup sequence:

```bash
bazel shutdown
rm -rf /private/var/tmp/_bazel_"$(whoami)"
rm -rf "$HOME/Library/Caches/bazel"
rm -rf "$HOME/Library/Caches/datadog-orchestrion-go-cache"
go clean -cache
```

Do not delete a consumer repository's `.git` directory. Do not clear
`~/go/pkg/mod` unless you explicitly accept the redownload cost.
