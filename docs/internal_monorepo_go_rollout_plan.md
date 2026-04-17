> Superseded note: this document is historical. The current execution spec for
> the clean `rules_go` base split, optional patch bundle, proof overlay, and
> validation matrix lives in
> [docs/rules_go_optional_patch_selection_plan.md](./rules_go_optional_patch_selection_plan.md).
> Use that document for active implementation work.

# dd-source First Go Pilot Plan

## Objective

Instrument one CI App-owned Go service in `dd-source` with Bazel-native
Datadog Test Optimization while keeping `dd-source`'s existing `dd_go_test`
policy intact.

The first pilot must prove all of these at the same time:

1. `dd-source` can consume the current `rules_test_optimization` WORKSPACE Go
   contract.
2. `dd-source` keeps its repository-local `dd_go_test` behavior when Test
   Optimization is enabled for selected targets.
3. Sync metadata, Bazel metadata, and test payload files are produced
   correctly for nested Go packages.
4. The workspace-level uploader works end to end from `dd-source` after test
   runs.

This first pilot is intentionally scoped to the test-payload path. Coverage is
not a required gate for the first rollout.

This document is intentionally a single-service execution spec. If
`test-optimization-worker` is rejected as the first pilot, stop this plan,
restore `dd-source` to the frozen baseline for all `dd-source`-local edits made
under this document, and write a separate replacement-service plan instead of
mutating this one in flight.

For this plan, "keep `dd_go_test` policy intact" has a precise meaning:

- `dd_go_test` remains the public macro surface used by Gazelle-generated and
  hand-written BUILD files.
- the wrapper still owns repository policy such as Docker defaults, local and
  exclusive enforcement, and flaky companion generation.
- unchanged targets that do not opt into Test Optimization still expand to raw
  `go_test(...)` exactly as they do today.
- instrumented targets do not need to preserve the exact same hidden target
  graph as raw `go_test(...)`; `dd_topt_go_test(...)` intentionally inserts a
  wrapper around a hidden raw test target.

## Public Baseline

Use the current checked-in `rules_test_optimization` state and freeze its exact
commit before touching `dd-source`.

For this plan, freeze:

- `rules_test_optimization` commit:
  - `783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab`
- `dd-source` commit:
  - `f6835a8ce196706dc7dc67cc0d65ceb297e3f049`

The current Go companion code already provides the pieces this pilot needs:

- WORKSPACE-mode consumption through separate core and Go companion repos.
- A public `go_orchestrion_tool_repo(...)` helper from the Orchestrion-enabled
  `rules_go` fork.
- Explicit `orchestrion_pin_files` support for nested Go packages.
- A documented wrapper boundary:
  - repository-local wrappers must stay outside `dd_topt_go_test`
  - repository-local wrappers must not be passed through `go_test_rule`
- A validated WORKSPACE Go path through
  [tools/tests/integration/run_workspace_go_integration.sh](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/tools/tests/integration/run_workspace_go_integration.sh),
  including:
  - `repo_mapping = {"@rules_go": "@io_bazel_rules_go"}`
  - the public `go_orchestrion_tool_repo(...)` helper
  - nested-package `orchestrion_pin_files`
  - a real `dd_topt_go_test` execution path

One current constraint in the public repo matters for this plan:

- the bootstrap helper and the WORKSPACE helper both take the Orchestrion
  version as an explicit input
- the rule does not auto-select Orchestrion from the requested Go version or
  from the repo's tracer version

For this pilot, do not treat the helper default as authoritative. Select the
Orchestrion release explicitly from the pilot service's effective v2 tracer
version before editing `dd-source`, then pin that same version in every place
that configures Orchestrion.

Only change `rules_test_optimization` during the pilot if `dd-source` exposes a
generic defect that also reproduces in a normal WORKSPACE consumer.

## dd-source Facts Used By This Plan

The current `dd-source` repository has these relevant properties:

- `dd-source` is a WORKSPACE Bazel repository.
- `dd-source` uses a repo-root Go module:
  - module: `github.com/DataDog/dd-source`
  - Go version: `1.25.9`
- `dd-source` pins the Bazel Go toolchain version to `1.25.9` in
  [rules/go/version.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/version.bzl).
- `dd-source` currently binds `@io_bazel_rules_go` in
  [WORKSPACE](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/WORKSPACE)
  to `rules_go v0.60.0` plus the current `dd-source` patch stack.
- `dd-source` already has a repository-local Go wrapper:
  - public alias:
    [rules/go/dd_go_test.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/dd_go_test.bzl)
  - implementation:
    [rules/go/private/dd_go_test/dd_go_test.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/private/dd_go_test/dd_go_test.bzl)
- `dd_go_test` currently adds repository policy around raw `go_test`:
  - Docker defaults when `dd-requires-docker` is present
  - `local` and `exclusive` enforcement for non-manual targets
  - flaky companion `<name>.build_test` generation
- The repo root
  [BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/BUILD.bazel)
  maps Gazelle `go_test` generation to `dd_go_test`, so the pilot should keep
  `dd_go_test` as the public local macro surface.
- `dd-source` does not currently contain:
  - `dd_topt_go_test` wiring
  - a Test Optimization sync repo
  - `//:dd_upload_payloads`
  - `orchestrion.tool.go`
  - `orchestrion.yml`
- The root
  [go.mod](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/go.mod)
  already contains both `gopkg.in/DataDog/dd-trace-go.v1` and
  `github.com/DataDog/dd-trace-go/v2` dependencies. The Orchestrion bootstrap
  for this pilot must still be pinned explicitly against the v2 tracer module
  set required by `go_orchestrion_tool_repo(...)`.
- The current repo-root v2 tracer pins are:
  - `github.com/DataDog/dd-trace-go/v2 v2.7.1`
  - `github.com/DataDog/dd-trace-go/contrib/net/http/v2 v2.7.1`
  - `github.com/DataDog/dd-trace-go/contrib/log/slog/v2` is not present yet
    and must be added by the repo-root Orchestrion bootstrap flow.
- CI config in
  [tools/bazelrc/ci.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/tools/bazelrc/ci.bazelrc)
  filters out Docker-tagged tests. The first pilot must not rely on a
  Docker-only parity target.

## Pilot Service

Use `domains/ci-app/apps/apis/test-optimization-worker` as the pilot service.

Why this service:

- Its service metadata is
  [service.datadog.yaml](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/service.datadog.yaml),
  and the service name is exactly `test-optimization-worker`.
- Its owner is `ci-app-backend`, so the pilot stays inside the CI App backend
  team boundary.
- It already has several existing nested `dd_go_test` targets.
- It provides better pilot coverage than a single small target:
  - `worker` proves the main service package path
  - `worker/notifications` already depends on dd-trace-go v2 and embeds
    template files
  - `worker/store` already uses `data = glob([".recordings/**"])`
- The selected pilot targets currently mix tracer generations:
  - `worker/notifications` imports `github.com/DataDog/dd-trace-go/v2/...`
  - `worker` and `worker/store` still import
    `gopkg.in/DataDog/dd-trace-go.v1/...`
  - for Orchestrion selection, use the repo-root v2 tracer version, because
    `go_orchestrion_tool_repo(...)` validates the v2 tracer module set rather
    than the legacy v1 import path
- It does not currently have an existing entry in
  `etc/ci/test-all/flaky_test_targets*.txt`, so a pilot-only flaky parity
  target can be added without colliding with repo state.
- It also has one nearby unchanged `dd_go_test` target that can stay fully
  outside the pilot and act as a control:
  - `//domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test`

## Pilot Targets

Instrument these existing targets:

- `//domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test`
- `//domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test`
- `//domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test`

Adopt them in this order:

1. `//domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test`
2. `//domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test`
3. `//domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test`

Why this order:

- `worker/notifications` is the lowest-risk first target because it already
  depends on dd-trace-go v2 and still exercises nested-package instrumentation.
- `worker` then proves the main service package path.
- `worker/store` comes last because it adds both runfile-heavy test inputs and
  an existing v1 tracer dependency, which makes it the most useful
  compatibility check after the first instrumented target is already green.

Add one pilot-only parity target:

- `//domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test`

The parity target should:

- reuse the current `worker` test sources and deps
- set `flaky = True`
- validate that `dd_go_test` still emits
  `//domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test.build_test`

Do not use a Docker-tagged target as a required gate for the first pilot.

Rollout decision rule for the mixed-tracer target set:

- `worker/notifications` is the first required gate because it is already on
  dd-trace-go v2.
- if `worker/notifications` passes but `worker` or `worker/store` fail because
  the service's mixed v1 and v2 tracer imports cannot satisfy the selected
  Orchestrion tuple, stop widening the rollout immediately.
- in that case, do not land a partial `test-optimization-worker` rollout under
  this plan.
- restore the `dd-source` checkout to the frozen baseline commit for every
  `dd-source`-local change introduced by this document, including:
  - the merged `@io_bazel_rules_go` source selection in `WORKSPACE`
  - the service-specific sync repo wiring, uploader target, and pilot Bazel RC
    fragment
  - the repo-root Orchestrion files and root-module edits
  - the pilot BUILD-file conversions
- treat that outcome as pilot-service rejection, not as a signal to start
  package-by-package tracer experiments inside one service.
- do not choose a replacement service inside this document. A different pilot
  service requires a new plan with its own service-specific targets, repo alias,
  control targets, and acceptance matrix.

## Compatibility Tuple

Freeze this tuple before editing `dd-source`:

- exact `rules_test_optimization` commit
- exact `dd-source` commit
- exact `dd-source` `rules_go` source:
  - `rules_go v0.60.0`
  - the current patch list from `dd-source` `WORKSPACE`
- Orchestrion version:
  - select it before editing `dd-source` with this exact rule:
    1. read the repo-root `github.com/DataDog/dd-trace-go/v2` version used by
       the pilot's current Go module graph
    2. inspect Orchestrion releases from newest to oldest and read each
       release tag's `go.mod`
    3. choose the newest Orchestrion release whose `go.mod` requires that same
       `github.com/DataDog/dd-trace-go/v2` version
  - current resolved result for this pilot:
    - `v1.9.0`
    - as of 2026-04-17, that is the latest official Orchestrion release whose
      `go.mod` requires `github.com/DataDog/dd-trace-go/v2 v2.7.1`
- upload mode:
  - agentless for the first pilot
- Orchestrion tracer configuration:
  - one shared `dd_trace_go_version`
  - current pilot value:
    - `v2.7.1`
- Bazel Go toolchain version:
  - `1.25.9`
- sync repo runtime version:
  - `1.25.9`
- sync repo alias:
  - `test_optimization_data_test_optimization_worker`
- pilot service name:
  - `test-optimization-worker`

Important constraint:

- use a shared `dd_trace_go_version` for the first pilot. That matches the
  current `dd-source` root module's v2 tracer version and keeps the first
  rollout smaller than a module-by-module tracer experiment.
- do not derive the Orchestrion release from the pilot service's legacy
  `gopkg.in/DataDog/dd-trace-go.v1/...` imports. The release-selection rule is
  keyed to the v2 tracer module version that the Orchestrion helper validates.
- `dd_trace_go_versions` is a tracer-module map, not a per-service or
  per-package map. Do not use it to express different versions per `dd-source`
  service.
- only switch from shared `dd_trace_go_version = "v2.7.1"` to
  `dd_trace_go_versions` if the repo-root module validation in Step 3 proves
  the shared version cannot satisfy the required tracer modules.
- if later pilot targets fail because they still depend on legacy
  `gopkg.in/DataDog/dd-trace-go.v1/...` imports, reject the pilot service,
  restore `dd-source` to the frozen baseline for all `dd-source`-local edits
  from this document, and stop. Do not use `dd_trace_go_versions` to paper over
  a v1-versus-v2 service mix.

If the tuple cannot be satisfied for `test-optimization-worker`, stop before
touching BUILD files, restore `dd-source` to the frozen baseline for any
partial `dd-source`-local setup already attempted, and create a separate
replacement-service plan.

## dd-source Changes Required For The First Pilot

### 1. Replace the current `@io_bazel_rules_go` base with an Orchestrion-enabled merge

Do not assume the current `dd-source` `rules_go` patch series is already
enough. The first pilot needs an Orchestrion-enabled `@io_bazel_rules_go`
repository while preserving the current `dd-source` patch stack.

The final `@io_bazel_rules_go` repository used by `dd-source` must expose:

- `@io_bazel_rules_go//go:orchestrion_workspace.bzl`
  - exporting `go_orchestrion_tool_repo`
- `@io_bazel_rules_go//go/private/orchestrion:enabled`
- `@io_bazel_rules_go//go/private/orchestrion:tool_binary`
- `@io_bazel_rules_go//go/private/orchestrion:dd_trace_go_version_file`

It must also preserve the fixed tool repository name expected by the public
contract:

- `rules_go_orchestrion_tool`

Do not try to rename that repository. The public helper rejects a custom name.

Implementation rule:

- start from the current `dd-source` `rules_go v0.60.0` base and merge in the
  Orchestrion-enabled fork
- preserve the current patch behavior while adding the missing Orchestrion
  entrypoints
- before publishing the merged result, inventory every `dd-source`-specific
  patch currently applied on top of `rules_go v0.60.0` and classify it as one
  of:
  - already present in the Orchestrion-enabled merge
  - must be re-applied unchanged
  - intentionally dropped with a written rationale

Expected `dd-source` files to change:

- [WORKSPACE](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/WORKSPACE)
- any internal patch files or mirror metadata used to publish the merged
  `rules_go`

This step is done when:

- `load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")`
  works in `WORKSPACE`
- the public Go companion resolves the Orchestrion labels listed above through
  `repo_mapping = {"@rules_go": "@io_bazel_rules_go"}`
- the merge has a reviewed patch inventory showing how every current
  `dd-source`-specific `rules_go` patch was preserved, replaced, or dropped
- the merged `@io_bazel_rules_go` repository passes this minimum pre-pilot
  smoke matrix before any Test Optimization wiring is added:
  - `bzl test //rules/go/private/dd_go_test:dd_go_test_suite_tests`
  - `bzl build //domains/case_management/modules/slack:go_default_test.build_test`
  - `bzl build //domains/app-builder/apps/apis/apps-datastore-api/client:go_default_test`
  - `bzl test //domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test`

### 2. Add WORKSPACE wiring for the public repos, sync repo, and uploader

Wire `dd-source` as a real WORKSPACE consumer of `rules_test_optimization`.

Use these repository names exactly:

- `datadog-rules-test-optimization`
- `datadog-rules-test-optimization-go`
- `test_optimization_data_test_optimization_worker`

The Go companion declaration must set:

```bzl
repo_mapping = {"@rules_go": "@io_bazel_rules_go"}
```

Representative WORKSPACE shape:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# Use the archive URL and sha256 that your approved source mirror publishes for
# commit 783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab.
http_archive(
    name = "datadog-rules-test-optimization",
    urls = ["<approved-archive-url-for-783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab>"],
    sha256 = "<sha256-for-that-archive>",
    strip_prefix = "rules_test_optimization-783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab",
)

http_archive(
    name = "datadog-rules-test-optimization-go",
    urls = ["<approved-archive-url-for-783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab>"],
    sha256 = "<sha256-for-that-archive>",
    strip_prefix = "rules_test_optimization-783f4184214f8c0fa14b0bfd4977d9e6d9fbb3ab/modules/go",
    repo_mapping = {"@rules_go": "@io_bazel_rules_go"},
)

load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync",
)

go_orchestrion_tool_repo(
    version = "v1.9.0",
    dd_trace_go_version = "v2.7.1",
)

test_optimization_sync(
    name = "test_optimization_data_test_optimization_worker",
    service = "test-optimization-worker",
    runtime_name = "go",
    runtime_version = "1.25.9",
)
```

If `dd-source` requires internal mirror macros instead of raw `http_archive`,
transpose the same selected values into that existing mechanism without changing
the repository names above.

Add a workspace-level uploader target to root
[BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/BUILD.bazel):

```bzl
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl",
    "dd_payload_uploader",
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data_test_optimization_worker//:test_optimization_context",
    ],
    fail_on_error = True,
)
```

Do not add the pilot's `--repo_env` lines directly to shared root `common`.
The current
[.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/.bazelrc)
already warns that `--repo_env` on shared command scopes can churn caches
across normal workflows.

For the first pilot, add a dedicated imported Bazel RC fragment instead, for
example:

- [tools/bazelrc/test-optimization-worker-pilot.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/tools/bazelrc/test-optimization-worker-pilot.bazelrc)

Import that file from the root
[.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/.bazelrc)
alongside the existing `tools/bazelrc/*.bazelrc` imports:

- `import %workspace%/tools/bazelrc/test-optimization-worker-pilot.bazelrc`

Wire the pilot repository-rule environment there:

- `common:test-optimization-worker-pilot --repo_env=DD_API_KEY`
- `common:test-optimization-worker-pilot --repo_env=DD_SITE`
- `common:test-optimization-worker-pilot --repo_env=GO_MODULE_PATH=github.com/DataDog/dd-source`
- optionally
  `common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`

Set `GO_MODULE_PATH` explicitly for the first pilot. The sync rule can detect
Go module paths from some CI workspace layouts, but this pilot should not rely
on best-effort discovery for a repo-root module that drives module payload
selection and fallback importpath wiring.

Important runtime distinction:

- `--repo_env` is for the sync repository rule.
- the uploader still needs `DD_API_KEY` and `DD_SITE` in the runtime
  environment of `bazel run //:dd_upload_payloads`.

After changing the tuple or sync config, force a refetch of the sync repo:

```bash
bzl --config=test-optimization-worker-pilot sync --only=test_optimization_data_test_optimization_worker --repo_env=FETCH_SALT=<timestamp>
```

If Bazel requires WORKSPACE mode explicitly:

```bash
bzl --config=test-optimization-worker-pilot sync --enable_workspace --only=test_optimization_data_test_optimization_worker --repo_env=FETCH_SALT=<timestamp>
```

Expected `dd-source` files to change:

- [WORKSPACE](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/WORKSPACE)
- [BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/BUILD.bazel)
- [.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/.bazelrc)
- [tools/bazelrc/test-optimization-worker-pilot.bazelrc](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/tools/bazelrc/test-optimization-worker-pilot.bazelrc)

This step is done when:

- the pilot targets reach analysis without repository mapping failures
- `bzl --config=test-optimization-worker-pilot build //:dd_upload_payloads`
  works from the repo root

### 3. Create the repo-root Orchestrion pin set and validate the root module

Because `dd-source` uses a repo-root Go module, the Orchestrion pin files for
the pilot must live at the repo root.

Use this exact repo-root pin set:

- `//:go.mod`
- `//:go.sum`
- `//:orchestrion.tool.go`
- `//:orchestrion.yml`

`go.mod` and `go.sum` already exist. Add these new repo-root files:

- [orchestrion.tool.go](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/orchestrion.tool.go)
- [orchestrion.yml](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/orchestrion.yml)

Expose the full repo-root pin set from
[BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/BUILD.bazel)
so nested packages can reference:

- `//:go.mod`
- `//:go.sum`
- `//:orchestrion.tool.go`
- `//:orchestrion.yml`

In the current `dd-source` root BUILD file, extend the existing
`exports_files([...])` list with these filenames.

Representative root BUILD fragment:

```bzl
exports_files([
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
])
```

Mirror the current bootstrap helper order for the repo-root Go module even
though `dd-source` is a WORKSPACE consumer:

1. run `orchestrion pin`
2. rewrite `orchestrion.tool.go` to the required v2 integration imports
3. align the root module to the selected Orchestrion and tracer tuple
4. verify the exact resolved Orchestrion and tracer module versions
5. preflight the exact tracer package paths Bazel and Orchestrion will load

Use a Go `1.25.x` toolchain for these repo-root commands. To mirror the current
bootstrap helper more closely, prefer running them with:

- `GOWORK=off`
- `GOTOOLCHAIN=go1.25.0+auto`

The first pilot must make the repo-root module internally consistent with the
selected Orchestrion release and tracer tuple. At minimum:

- add `github.com/DataDog/orchestrion`
- ensure the selected v2 tracer modules resolve in the root module:
  - `github.com/DataDog/dd-trace-go/v2`
  - `github.com/DataDog/dd-trace-go/contrib/net/http/v2`
  - `github.com/DataDog/dd-trace-go/contrib/log/slog/v2`

Start from a real pin operation in the repo-root module:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go run github.com/DataDog/orchestrion@v1.9.0 pin
```

After `orchestrion pin`, do not keep the legacy v1 CI Visibility import if it
appears in `orchestrion.tool.go`. Make the tool file match the current
bootstrap helper contract by ensuring it imports exactly this v2 integration
set:

- `github.com/DataDog/orchestrion`
- `github.com/DataDog/dd-trace-go/v2/orchestrion`
- `github.com/DataDog/dd-trace-go/contrib/net/http/v2`
- `github.com/DataDog/dd-trace-go/contrib/log/slog/v2`

If `orchestrion pin` does not leave an `orchestrion.yml` in the repo root,
write a minimal starter file before moving on:

```yaml
---
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: datadog/go-bootstrap
  description: Datadog starter configuration for Orchestrion.

aspects: []
```

After `orchestrion pin`, apply the selected tracer tuple explicitly in the
repo-root module. For the first pilot, use the shared tracer version from the
compatibility tuple:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/v2@v2.7.1
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.7.1
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.7.1

GOWORK=off GOTOOLCHAIN=go1.25.0+auto go get github.com/DataDog/dd-trace-go/v2/orchestrion@v2.7.1

GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod tidy
```

Only if that shared version fails before BUILD-file conversion, switch to
`dd_trace_go_versions` and mirror the same per-module versions in the repo-root
module edit plus `go get` update.

If that switch is required, also change the WORKSPACE helper call from:

- `dd_trace_go_version = "v2.7.1"`

to:

- `dd_trace_go_versions = {`
- `    "github.com/DataDog/dd-trace-go/v2": "<exact resolved version>",`
- `    "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "<exact resolved version>",`
- `    "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "<exact resolved version>",`
- `}`

Do not add or omit keys in that map. The current helper validates exactly those
three tracer modules and rejects any other shape.

When taking this fallback path, mirror the same three exact versions in the
repo-root module update:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/v2@<exact resolved version>
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/contrib/net/http/v2@<exact resolved version>
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod edit -require=github.com/DataDog/dd-trace-go/contrib/log/slog/v2@<exact resolved version>

GOWORK=off GOTOOLCHAIN=go1.25.0+auto go get github.com/DataDog/dd-trace-go/v2/orchestrion@<exact version for github.com/DataDog/dd-trace-go/v2>

GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod tidy
```

so the Bazel-side tool repo and the repo-root Go module stay aligned.

Representative `orchestrion.tool.go` shape:

```go
//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion"
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"
)
```

Validate the repo-root module outside Bazel after updating it:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod download \
  github.com/DataDog/orchestrion \
  github.com/DataDog/dd-trace-go/v2 \
  github.com/DataDog/dd-trace-go/contrib/net/http/v2 \
  github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

Then verify the exact resolved module versions match the selected Bazel-side
tuple, not just that the modules download:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/orchestrion
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

For the shared-version first pilot, the commands above must resolve to:

- `github.com/DataDog/orchestrion v1.9.0`
- `github.com/DataDog/dd-trace-go/v2 v2.7.1`
- `github.com/DataDog/dd-trace-go/contrib/net/http/v2 v2.7.1`
- `github.com/DataDog/dd-trace-go/contrib/log/slog/v2 v2.7.1`

Then preflight the exact package paths the current bootstrap logic validates:

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

Expected `dd-source` files to change:

- [BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/BUILD.bazel)
- [go.mod](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/go.mod)
- [go.sum](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/go.sum)
- [orchestrion.tool.go](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/orchestrion.tool.go)
- [orchestrion.yml](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/orchestrion.yml)

This step is done when:

- the root module resolves successfully with the selected Orchestrion and
  tracer tuple
- the resolved Orchestrion and tracer module versions, not just `go.mod`,
  match the Bazel-side `go_orchestrion_tool_repo(...)` configuration
- `orchestrion.tool.go` and `orchestrion.yml` exist at the repo root and match
  the current v2 bootstrap contract
- the repo-root pin files are visible to nested packages through `//:` labels
- the root module diff has been reviewed explicitly, because it affects the
  whole repository

### 4. Extend `dd_go_test` with an opt-in Test Optimization path

Do not add a second repo-local public macro for the first pilot. `dd-source`
already routes Go tests through `dd_go_test`, and that is the cleanest place to
keep repository policy.

Recommended shape for
[rules/go/private/dd_go_test/dd_go_test.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/private/dd_go_test/dd_go_test.bzl):

- keep the current behavior exactly as-is when Test Optimization is not
  requested
- add optional parameters:
  - `topt_data = None`
  - `topt_service = None`
  - `module_label_override = None`
  - `orchestrion_pin_files = None`
- keep the current tag, timeout, and `exec_compatible_with` normalization
- keep the current `ban_exclusive_if_not_manual(...)` and
  `ban_local_if_not_manual(...)` calls
- when `topt_data` is not set:
  - call raw `go_test(...)` exactly as today
- when `topt_data` is set:
  - call external `dd_topt_go_test(...)`
  - pass the normalized wrapper values plus:
    - `topt_data = topt_data`
    - `topt_service = topt_service`
    - `module_label_override = module_label_override`
    - `orchestrion_pin_files = orchestrion_pin_files`
- do not pass `go_test_rule = dd_go_test`
- keep the current flaky `.build_test` generation after the call
- update the wrapper comments and docstrings in English as part of the same
  change:
  - document the new optional Test Optimization parameters
  - document that the no-`topt_data` branch still delegates to raw `go_test`
  - document that `dd_go_test` preserves repository policy while
    Test-Optimization-enabled targets intentionally use the
    `dd_topt_go_test(...)` wrapper shape internally

Why this shape is preferred:

- it preserves Gazelle's existing `dd_go_test` mapping
- it avoids duplicating repository policy in a second local macro
- it keeps non-pilot callsites unchanged
- it keeps the public wrapper contract stable without pretending that
  Test-Optimization-enabled targets still expand to the exact same hidden
  implementation graph as raw `go_test(...)`

Representative structure:

```bzl
load(
    "@datadog-rules-test-optimization-go//:topt_go_test.bzl",
    _dd_topt_go_test = "dd_topt_go_test",
)

def dd_go_test(
        *,
        name,
        timeout = None,
        tags = None,
        exec_compatible_with = None,
        topt_data = None,
        topt_service = None,
        module_label_override = None,
        orchestrion_pin_files = None,
        **kwargs):
    tags = tags or []

    if TAG_DD_REQUIRES_DOCKER in tags:
        tags, timeout, exec_compatible_with = apply_docker_test_defaults(
            tags = tags,
            timeout = timeout,
            exec_compatible_with = exec_compatible_with,
        )

    ban_exclusive_if_not_manual(tags)
    ban_local_if_not_manual(tags)

    if topt_data == None:
        go_test(
            name = name,
            tags = tags,
            timeout = timeout,
            exec_compatible_with = exec_compatible_with,
            **kwargs
        )
    else:
        _dd_topt_go_test(
            name = name,
            tags = tags,
            timeout = timeout,
            exec_compatible_with = exec_compatible_with,
            topt_data = topt_data,
            topt_service = topt_service,
            module_label_override = module_label_override,
            orchestrion_pin_files = orchestrion_pin_files,
            **kwargs
        )

    if kwargs.get("flaky", False) or is_flaky(name):
        build_test(
            name = name + ".build_test",
            targets = [":" + name],
        )
```

Expected `dd-source` files to change:

- [rules/go/private/dd_go_test/dd_go_test.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/private/dd_go_test/dd_go_test.bzl)
- [rules/go/dd_go_test.bzl](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/rules/go/dd_go_test.bzl)
  if its module-level comments need updating to match the expanded wrapper
  contract

This step is done when:

- the no-`topt_data` branch still calls raw `go_test(...)` with the same
  wrapper policy behavior as today
- pilot BUILD files can opt in by adding attributes instead of changing macro
  names
- the wrapper comments and docstrings describe both branches and the preserved
  public policy surface accurately

### 5. Convert only the pilot BUILD files

Do not batch-convert unrelated Go packages.

Change only these BUILD files:

- [domains/ci-app/apps/apis/test-optimization-worker/worker/BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/BUILD.bazel)
- [domains/ci-app/apps/apis/test-optimization-worker/worker/notifications/BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/notifications/BUILD.bazel)
- [domains/ci-app/apps/apis/test-optimization-worker/worker/store/BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/store/BUILD.bazel)

Convert them in the same order listed in **Pilot Targets** and run validation
after each conversion before moving to the next file.

Keep this BUILD file unchanged and use it as the plain local control target
that proves the non-pilot `dd_go_test` path still works without Test
Optimization:

- [domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization/BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization/BUILD.bazel)

For each existing pilot target:

- keep the target on `dd_go_test`
- load `topt_data` from
  `@test_optimization_data_test_optimization_worker//:export.bzl`
- add:
  - `topt_data = topt_data`
  - `orchestrion_pin_files = ["//:go.mod", "//:go.sum", "//:orchestrion.tool.go", "//:orchestrion.yml"]`
- preserve existing `srcs`, `embed`, `deps`, `data`, `tags`, and `timeout`
  values exactly

For the pilot-only flaky parity target in
[domains/ci-app/apps/apis/test-optimization-worker/worker/BUILD.bazel](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/BUILD.bazel):

- add a second `dd_go_test`
- reuse the current `worker` test sources and deps
- reuse `embed = [":go_default_library"]`
- name it `topt_flaky_test`
- set `flaky = True`
- set the same `topt_data` and `orchestrion_pin_files` values
- do not add it to `etc/ci/test-all/flaky_test_targets*.txt`

This step is done when:

- the three existing pilot targets build through the instrumented `dd_go_test`
  path
- `topt_flaky_test.build_test` is created automatically by the existing wrapper
  logic

## Validation Sequence

Use `bzl` as the repo-standard Bazel launcher for `dd-source` local work.

### 1. Refetch the sync repo after tuple or environment changes

```bash
bzl --config=test-optimization-worker-pilot sync --only=test_optimization_data_test_optimization_worker --repo_env=FETCH_SALT=<timestamp>
```

If required:

```bash
bzl --config=test-optimization-worker-pilot sync --enable_workspace --only=test_optimization_data_test_optimization_worker --repo_env=FETCH_SALT=<timestamp>
```

### 2. Validate the sync export and repo-root Go module

Before running Bazel tests, inspect the generated sync export to confirm the
pilot repo alias, service name, and Go module path are what the macro layer
expects:

```bash
OUTPUT_BASE="$(bzl --config=test-optimization-worker-pilot info output_base)"
cat "$OUTPUT_BASE/external/test_optimization_data_test_optimization_worker/export.bzl"
```

Verify these exported values:

- `repo_name = "test_optimization_data_test_optimization_worker"`
- `service_name = "test-optimization-worker"`
- `runtimes["go"]["module_path"] = "github.com/DataDog/dd-source"`

Also confirm the repo-root pin files are addressable before converting nested
pilot BUILD files:

```bash
bzl query 'set(//:go.mod //:go.sum //:orchestrion.tool.go //:orchestrion.yml)'
```

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go mod download \
  github.com/DataDog/orchestrion \
  github.com/DataDog/dd-trace-go/v2 \
  github.com/DataDog/dd-trace-go/contrib/net/http/v2 \
  github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/orchestrion
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

```bash
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2
GOWORK=off GOTOOLCHAIN=go1.25.0+auto go list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2
```

### 3. Run the pilot targets

Before converting any pilot BUILD file, run the unchanged control target once
after the `dd_go_test` wrapper change:

```bash
bzl --config=test-optimization-worker-pilot test //domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test
```

Keep this target as a plain-path local control only. The current repo already
lists it in
[etc/ci/test-all/failing_test_targets_rbe.txt](/Users/tony.redondo/go/src/github.com/DataDog/dd-source/etc/ci/test-all/failing_test_targets_rbe.txt),
so it is a poor required gate for the pilot's CI-shaped matrix even though it
is still useful to prove that the unchanged non-pilot `dd_go_test` path keeps
working locally.

Also verify the registry-driven flaky path on an unchanged target outside the
pilot service. Use an existing target that is already listed in
`etc/ci/test-all/flaky_test_targets.txt`, for example:

```bash
bzl query //domains/case_management/modules/slack:go_default_test.build_test
```

```bash
bzl build //domains/case_management/modules/slack:go_default_test.build_test
```

Those commands must succeed without editing that BUILD file or setting
`flaky = True`, which proves that the wrapper still honors `is_flaky(name)` for
repo-listed flaky targets.

Run the staged rollout in this order first:

```bash
bzl --config=test-optimization-worker-pilot test //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test
```

```bash
bzl --config=test-optimization-worker-pilot test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test
```

```bash
bzl --config=test-optimization-worker-pilot test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test
```

Decision rule during the staged rollout:

- if `worker/notifications` fails, stop and debug that first target before
  changing any other pilot BUILD file.
- if `worker/notifications` passes but adding `worker` or `worker/store` fails
  with a failure that looks generic, use this exact public repro lane before
  classifying it as a `rules_test_optimization` defect:
  - from this repository root, run
    `GO_VERSION=1.25.9 ORCHESTRION_VERSION=v1.9.0 DD_TRACE_GO_VERSION=v2.7.1 ./tools/tests/integration/run_workspace_go_integration.sh`
  - only if that command fails with the same class of error may the issue be
    treated as a normal WORKSPACE-consumer defect
  - after a candidate public fix, rerun that same command and the original
    failing `dd-source` command before restarting the staged rollout
- if `worker/notifications` passes but `worker` or `worker/store` fail because
  the mixed v1 and v2 tracer service cannot satisfy the selected Orchestrion
  tuple, reject `test-optimization-worker` as the first pilot service, revert
  every `dd-source`-local change introduced by this document back to the frozen
  baseline, and stop. Do not land the `worker/notifications` conversion by
  itself under this plan.

After the staged rollout is green, run the full pilot matrix:

```bash
bzl --config=test-optimization-worker-pilot test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test.build_test
```

If remote execution or remote caching is in play, add:

```bash
--remote_download_outputs=all
```

Run the same target set under CI config:

```bash
bzl test --config=test-optimization-worker-pilot --config=ci \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test.build_test
```

### 4. Inspect runtime outputs

After the test run, verify all of these outcomes:

- each pilot target produced a `test.outputs` directory under `bazel-testlogs`
- `bazel_target_metadata.json` exists for each instrumented target
- `bazel_target_metadata.json` reports:
  - `bazel.test_optimization.repo_name = "test_optimization_data_test_optimization_worker"`
  - `bazel.test_optimization.service_name = "test-optimization-worker"`
  - `bazel.test_optimization.runtime_name = "go"`
  - `bazel.go.importpath_source = "inferred"` for the three existing pilot
    targets, because they all use `embed = [":go_default_library"]`
  - `bazel.go.importpath` matches the package under test:
    - `worker:go_default_test` and `worker:topt_flaky_test`:
      `github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker`
    - `worker/notifications:go_default_test`:
      `github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/notifications`
    - `worker/store:go_default_test`:
      `github.com/DataDog/dd-source/domains/ci-app/apps/apis/test-optimization-worker/worker/store`
  - `bazel.go.orchestrion.enabled = true`
  - `bazel.go.payload_selection` is not empty
- `DD_SERVICE` resolves to `test-optimization-worker`
- `DD_TEST_OPTIMIZATION_MANIFEST_FILE` is present in the test environment
- the synced metadata bundle is available next to the manifest path
- test payload JSON files were written under Bazel-owned test outputs
- `topt_flaky_test.build_test` exists and passes

Useful inspection command:

```bash
TESTLOGS_DIR="$(bzl --config=test-optimization-worker-pilot info bazel-testlogs)"
find "$TESTLOGS_DIR/domains/ci-app/apps/apis/test-optimization-worker" -path '*test.outputs*' -type f | sort
```

The `worker/store` target is part of the required matrix specifically to prove
that existing `data = glob([".recordings/**"])` inputs still work after
instrumentation. The `worker/notifications` target is part of the matrix to
prove that the pilot still works for a package that embeds template assets and
already uses dd-trace-go v2.

For the three existing pilot targets, a metadata value of
`bazel.go.payload_selection = "module"` is the preferred outcome because it
proves the per-module split path is active. If any target reports
`full_bundle_no_match`, stop and investigate backend module coverage or module
label mapping before widening the rollout beyond this first pilot.

### 5. Run the uploader

Use the first pilot in agentless mode:

```bash
DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
bzl --config=test-optimization-worker-pilot run //:dd_upload_payloads
```

If the environment uses a non-default agentless base URL, add:

```bash
DD_TEST_OPTIMIZATION_AGENTLESS_URL="$DD_TEST_OPTIMIZATION_AGENTLESS_URL"
```

Because the pilot uploader target sets `fail_on_error = True`, a run that finds
no payloads after tests must fail instead of silently succeeding.

## Acceptance Criteria

The first pilot is complete only when all of these are true:

- `dd-source` resolves the public core repo, the public Go companion repo, the
  service-specific sync repo, and `rules_go_orchestrion_tool` in WORKSPACE mode
- the internal `@io_bazel_rules_go` exposes the Orchestrion labels required by
  the public Go companion while preserving the current `dd-source` patch stack
- the `rules_go` merge has a reviewed patch inventory showing how every current
  `dd-source`-specific patch was preserved, replaced, or intentionally dropped
- the merged `@io_bazel_rules_go` repository passed the pre-pilot smoke matrix
  before any Test Optimization wiring was added:
  - `//rules/go/private/dd_go_test:dd_go_test_suite_tests`
  - `//domains/case_management/modules/slack:go_default_test.build_test`
  - `//domains/app-builder/apps/apis/apps-datastore-api/client:go_default_test`
  - `//domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test`
- the repo-root module files (`go.mod`, `go.sum`, `orchestrion.tool.go`,
  `orchestrion.yml`) are internally consistent and pass the repo-root
  `go mod download`, `go list -mod=mod -m -json`, and `go list -mod=mod`
  smoke checks with the selected Orchestrion release and tracer tuple
- the repo-root pin files are exported so nested packages can load them through
  `//:` labels
- the three existing pilot targets pass under
  `bzl --config=test-optimization-worker-pilot test`
- the same instrumented pilot targets pass under
  `bzl test --config=test-optimization-worker-pilot --config=ci`
- the unchanged control target
  `//domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test`
  still passes through the plain `dd_go_test` path in the plain pilot config
- an unchanged target that is already listed in
  `etc/ci/test-all/flaky_test_targets.txt`, for example
  `//domains/case_management/modules/slack:go_default_test`, still exposes and
  builds its generated `.build_test` companion through the `is_flaky(name)`
  path
- the pilot-only flaky target passes and still generates its `.build_test`
  companion
- the unchanged local default `dd_go_test` path is still proven by a target
  that does not opt into Test Optimization
- `dd_go_test` remains the public macro surface and repository-policy layer,
  while Test-Optimization-enabled targets are allowed to use a different hidden
  implementation graph internally
- the first pilot does not claim remote-exec parity for the unchanged control
  path, because that control target is already excluded from the repo's normal
  RBE-shaped test set
- Bazel metadata and test payload files are present in `bazel-testlogs`
- the uploader succeeds through
  `bzl --config=test-optimization-worker-pilot run //:dd_upload_payloads`

## Explicit Non-Goals For The First Pilot

- instrumenting every Go test in `dd-source`
- changing services owned outside the CI App backend team
- replacing Gazelle's `dd_go_test` mapping with direct `dd_topt_go_test` loads
  across the repository
- creating service-local Go modules
- proving Docker-tagged test parity in the first pilot
- making coverage a first-pilot gate
- changing `rules_test_optimization` unless the pilot reveals a generic defect
