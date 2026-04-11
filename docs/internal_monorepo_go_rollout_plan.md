# Internal Monorepo Go Rollout Plan

## Objective

Move from the current public-rule state to one real, working internal monorepo
pilot for Go test optimization in the CI App area, with the internal repository
policy wrapper preserved.

This document starts from the current state on the
`feat/workspace-go-internal-support` branch and describes only the work that is
still missing.

## Current State

The public rule is already in a usable state for WORKSPACE-mode Go consumers:

- The official WORKSPACE shape uses a separate core repository and Go companion
  repository.
- The vendored `rules_go` fork exposes a public
  `go_orchestrion_tool_repo(...)` macro for WORKSPACE consumers.
- The Go companion supports nested packages through explicit
  `orchestrion_pin_files`.
- The wrapper boundary is defined: repository-specific policy wrappers should
  wrap `dd_topt_go_test` from the outside instead of passing themselves through
  `go_test_rule`.
- The repository has a real WORKSPACE Go integration harness under
  `tools/tests/integration/run_workspace_go_integration.sh`.
- The public Go onboarding surface, example modules, and WORKSPACE harness are
  aligned on Go `1.25.0` and the current default tracer pin.
- The repository CI lane `workspace-compat` now validates that same WORKSPACE
  Go path with Go `1.25.0`.
- The sibling consumer-style validation repository has a standalone WORKSPACE
  Go sample, is repinned to the latest public SHA for this branch, and its
  `workspace-go` job passed on that pin.
- The public repo-side work needed for an internal Go pilot is complete in this
  branch.

What is not proven yet:

- No real internal monorepo service is using this path yet.
- The internal repository's local Go policy wrapper behavior is not yet proven
  on top of `dd_topt_go_test`.
- Internal monorepo-specific behaviors such as Docker-tagged Go tests, flaky
  test parity, and uploader continuity have not been validated in the real
  repository.
- The validated public Go `1.25.0` shape has not been proven in the internal
  monorepo yet.

## Desired State

The desired end state for the initial rollout is:

- One internal CI App Go service is wired to test optimization through a
  repository-local adapter macro around `dd_topt_go_test`.
- The internal repository keeps its current Go test policy behavior.
- The internal repository uses an Orchestrion-enabled `rules_go` fork or merged
  internal fork that is compatible with the public companion path.
- Normal test runs and hermetic test runs both pass for the pilot targets.
- The pilot writes Bazel-owned metadata, stages the synced payload files
  correctly, and keeps uploader flow working.
- The pilot result is specific enough that the next 2-3 internal services can
  be onboarded without changing the public rule design.

## Done Criteria

This rollout is only complete when all of these are true:

1. The internal monorepo can resolve the core repo, Go companion repo, and
   Orchestrion-enabled `rules_go` fork in WORKSPACE mode.
2. A repository-local internal adapter macro preserves current policy behavior
   while delegating instrumentation to `dd_topt_go_test`.
3. At least one pilot service has passing Go test targets through that adapter.
4. The pilot proves metadata generation, payload staging, and uploader
   continuity in the internal repository.
5. The pilot covers at least one plain Go test and at least one policy-shaped
   test that exercises real internal wrapper behavior.

## Non-Goals

- Broad, repo-wide rollout across all internal Go services.
- Replacing the internal repository's local Go wrapper with `dd_topt_go_test`
  directly.
- Pushing internal-only wrapper logic back into this public repository.
- Reworking the public companion API again unless the internal pilot exposes a
  generic defect.

## Hard Constraints

- Keep internal repository policy in a repository-local adapter macro.
- Do not pass the internal wrapper through `go_test_rule`.
- Keep the Orchestrion tool repository name as `rules_go_orchestrion_tool`.
- Pin the Go toolchain version and the tracer version together. Treat them as a
  single compatibility decision.
- If the internal repository needs extra `rules_go` patches beyond the current
  public fork, keep those patches internal unless the pilot proves they are
  generic consumer requirements.

## Remaining Work

### Step 1: Prepare the Internal `rules_go` Base

Create the internal repository's actual Go runtime base from the current public
Orchestrion-enabled fork:

- Start from the current public fork commit used by the pilot.
- Layer the internal repository's existing `rules_go` deltas on top of that
  base.
- Preserve these public entrypoints exactly:
  - `go/orchestrion_workspace.bzl`
  - `//go/private/orchestrion:*`
  - the `:enabled` build setting used by the companion transition
  - `@rules_go_orchestrion_tool`

Required output:

- One internal `@io_bazel_rules_go` repository that preserves current internal
  behavior and still satisfies the companion's public contract.

Files expected to change in the internal repository:

- the internal `rules_go` fork or mirror used as `@io_bazel_rules_go`
- any internal fork maintenance metadata used to track local deltas

Validation:

- The internal fork loads successfully in WORKSPACE mode.
- `go_orchestrion_tool_repo(...)` instantiates without label or repository-name
  mismatches.

### Step 2: Wire the Internal WORKSPACE Consumer Shape

Add the public companion shape to the internal monorepo:

- Add the core repository import.
- Add the Go companion repository import.
- Add `repo_mapping = {"@rules_go": "@io_bazel_rules_go"}` on the Go companion
  repository declaration.
- Instantiate the sync repository for one pilot service.
- Instantiate `go_orchestrion_tool_repo(...)` with the chosen Orchestrion and
  tracer versions.
- Use the same Go toolchain version in:
  - `go_register_toolchains(...)`
  - the sync repo `runtime_version`
  - the pilot service's pinned local Go module files

Required output:

- One internal WORKSPACE configuration that resolves the public core repo, the
  public Go companion repo, and the internal Orchestrion-enabled `rules_go`
  fork together.

Files expected to change in the internal repository:

- root `WORKSPACE`
- any repository-macro files that centralize external dependency declarations
- root `BUILD.bazel` if the uploader target or shared data wiring lives there

Validation:

- `bazel query` and `bazel test` reach analysis successfully for a pilot Go
  target without repository resolution failures.

### Step 3: Build the Internal Adapter Macro

Create a repository-local adapter macro in the internal repository.

The adapter must:

- call `dd_topt_go_test(...)` directly
- bind the synced `topt_data`
- inject module-root `orchestrion_pin_files` when the target package is below
  the Go module root
- preserve the internal wrapper's policy behavior

The adapter must preserve, if they exist in the internal wrapper:

- Docker-routing tags and resource defaults
- timeout defaults
- local/exclusive tag enforcement
- flaky handling
- generated `build_test` parity for flaky targets
- any repository-specific metadata or default tags added by the current wrapper

Required output:

- One adapter macro with the same public call shape expected by the internal Go
  BUILD files, but instrumented through `dd_topt_go_test`.

Files expected to change in the internal repository:

- the repository-local Go wrapper macro file
- any helper `.bzl` files that enforce tag, timeout, Docker, or flaky policy
- only the pilot service BUILD files at first; do not bulk-edit unrelated Go
  packages yet

Validation:

- A diff between the old wrapper behavior and the adapter behavior shows policy
  parity for the pilot targets.
- The adapter does not use `go_test_rule = <internal wrapper>`.

### Step 4: Choose the Pilot Service and Target Set

Choose one low-risk internal CI App Go service and a narrow set of targets.

The pilot target set must include:

- one ordinary Go test that uses `embed = [":go_default_library"]` or the
  equivalent library/provider path
- one test under a nested package that needs module-root pin files
- one test that exercises meaningful internal wrapper policy
- one flaky test if the service has a real one available; otherwise use a small
  synthetic flaky target inside the same service only for parity validation

Selection rules:

- Prefer one service with a clean Go package structure and several small tests.
- Prefer a service that already uses the local repository wrapper consistently.
- Prefer at least one target that proves a policy-shaped path, not only the
  plain happy path.

Required output:

- A written list of pilot targets and the policy behaviors each target is meant
  to prove.

Files expected to change in the internal repository:

- none yet beyond a short rollout note or internal tracking document if the
  repository keeps one

Validation:

- The selected target set covers both instrumentation behavior and wrapper
  parity behavior.

### Step 5: Prepare the Pilot Service's Local Go Module State

Make the pilot service's local Go instrumentation files consistent:

- confirm the module root that owns the pilot targets
- pin `go.mod` and `go.sum` to the chosen tracer version
- add or update `orchestrion.tool.go`
- add or update `orchestrion.yml`
- ensure the Go version declared in the module is compatible with the chosen
  tracer version

Required output:

- One internally consistent module-root pin set for the pilot service.

Files expected to change in the internal repository:

- the pilot service's `go.mod`
- the pilot service's `go.sum`
- the pilot service's `orchestrion.tool.go`
- the pilot service's `orchestrion.yml`

Validation:

- `go mod download` or the internal repository's equivalent bootstrap path
  succeeds for the chosen tracer version before Bazel tries to weave the pilot
  targets.

### Step 6: Execute the Internal Pilot

Convert only the selected pilot targets to the adapter macro and run them in
the internal repository.

Required validation matrix:

- normal `bazel test` for the pilot targets
- hermetic or network-restricted `bazel test` for the same targets if the
  internal repository has that configuration
- uploader path after the tests run
- one second run to confirm cached behavior does not regress correctness

Runtime checks that must be inspected:

- `bazel_target_metadata.json` exists
- `bazel.go.orchestrion.enabled` is `true`
- synced files next to `DD_TEST_OPTIMIZATION_MANIFEST_FILE` are present
- `DD_SERVICE` is correct for the pilot service
- payload files appear under the expected Bazel test outputs
- uploader still discovers and uploads those payloads

Wrapper checks that must be inspected:

- Docker-tagged targets still route the same way
- timeout/resource defaults are unchanged
- flaky target handling still produces the expected companion `build_test`
  behavior if that policy exists in the internal repository

Required output:

- A pilot result with passing targets and a short factual record of what was
  verified.

Files expected to change in the internal repository:

- the pilot service BUILD files
- any pilot-only adapter loads or macro call-site conversions
- internal CI or script files only if the repository needs explicit uploader
  execution or hermetic target lists for the pilot

### Step 7: Decide Whether the Remaining Gaps Are Generic or Internal

After the pilot, classify every issue found:

- If the issue is generic and reproducible in the public consumer shape, fix it
  in `rules_test_optimization` and add coverage in the public repositories.
- If the issue is specific to the internal repository's wrapper, fork, tags,
  or CI conventions, keep the fix internal.

Required output:

- A short issue list split into:
  - public-rule follow-ups
  - internal-only follow-ups

This step is important because the pilot should not trigger another broad
public redesign unless the defect is actually generic.

### Step 8: Expand to Two More Internal Services

Do not call the work complete after only one service.

After the first pilot is green:

- onboard one second service that has a different package shape
- onboard one third service that exercises a different policy path or test mix

The purpose is to prove that the adapter pattern is reusable and that the first
service did not succeed only because it was unusually simple.

Required output:

- Three total onboarded internal services with no new public design changes
  required between service one and service three.

Validation:

- The second and third services only need internal repository changes unless a
  genuinely generic defect is discovered.

## Recommended Order

Execute the remaining work in this order:

1. Prepare the internal Orchestrion-enabled `rules_go` fork.
2. Wire the internal WORKSPACE consumer shape.
3. Build the internal adapter macro.
4. Select pilot targets.
5. Align the pilot service's local Go module pins.
6. Run and verify the pilot.
7. Classify any issues as public or internal.
8. Expand to two more internal services.

## Final Acceptance Gate

Treat the rollout as genuinely ready only when:

- the internal pilot service is green in normal and hermetic modes
- uploader continuity is proven
- internal wrapper policy parity is proven
- the new `rules_go` base is stable in the internal repository
- at least two more internal services onboard without requiring another public
  API change
