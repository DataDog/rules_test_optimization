<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Deterministic rules_go Standard-Library Cache Plan

## Status

Draft implementation plan for the Orchestrion v1.12.0 update. This document
describes the intended implementation and validation sequence; the cache fix is
not implemented merely by adding this plan.

The work starts in `rules_test_optimization`, is validated through
`rules_test_optimization_tests`, and is adopted by `dd-source` only after a
published rules commit is available. The source changes must cover every
maintained `rules_go` profile:

- `v0_60_0`
- `v0_61_1`
- `v0_62_0`

It must preserve both supported Go execution modes:

- ordinary Go builds and tests without Test Optimization;
- Go builds and tests with Orchestrion in `test_optimization` mode.

Generic Orchestrion behavior must remain compatible as well, even though the
cross-repository end-to-end acceptance matrix is focused on the two consumer
modes above.

## Objective

Make the `GoStdlib` action output deterministic without losing the woven
standard-library archives required by Test Optimization.

The implementation must separate two concepts that currently overlap:

1. a writable, action-private Go build cache used by live `go install` and
   `go list -export -deps` subprocesses; and
2. the Bazel-declared `-cacheout` TreeArtifact consumed by later Orchestrion
   compile and link actions.

No Go subprocess may use the declared TreeArtifact as its live `GOCACHE`.
Instead, Test Optimization must explicitly publish only the deterministic
archive data required by downstream actions. Ordinary Go builds must still
create the declared TreeArtifact, but leave it empty.

## Problem Statement

The Go build cache is not a reproducible Bazel action output. In addition to
archive data entries (`*-d`), the Go tool writes action index entries (`*-a`)
whose bytes include a wall-clock timestamp. Re-running the same command with
identical sources can therefore produce different cache bytes.

The current `GoStdlib` integration allows that mutable cache format to become a
Bazel-declared output in two places:

1. `stdlib.go` selects `-cacheout` as `GOCACHE` when the flag is present.
2. `env_orchestrion.go:newBufferedCommand` overwrites a subprocess's `GOCACHE`
   with `env.stdlibCache`, which is the declared `-cacheout` directory.

There is a third indirect writer. During publication,
`syncPersistedOrchestrionExportsToCache` calls
`resolveCacheStdlibExportsAt` for both the declared cache and the current
environment cache. That resolver executes `go list -export -deps` against the
selected cache root. Running it against the declared root creates the same
non-deterministic Go cache metadata even if the original stdlib build used a
private cache.

The downstream `dd-source` patch
`third_party/rules_go/0019-Keep-stdlib-GOCACHE-off-the-declared-cacheout-output.patch`
correctly identifies the first writer and moves the primary stdlib build to a
private cache. Porting that patch literally is insufficient for this repository
because the two Orchestrion-specific writers would remain.

## Terminology and Data Flow

This plan uses these names consistently:

- **scratch cache**: the private, writable `GOCACHE` rooted at
  `<stdlib-output>/.gocache`. It may contain any files produced by Go and is
  deleted when the `GoStdlib` action finishes.
- **declared cache**: the directory supplied by Bazel through `-cacheout` and
  recorded as `env.stdlibCache`. It is a TreeArtifact and must contain only
  deterministic published files.
- **persisted stdlib exports**: the woven archives already copied under the
  replicated GOROOT output and recorded by the existing persisted-export
  manifest.
- **published cache exports**: the selected woven archives projected into the
  declared cache using their Go cache data-entry paths, plus
  `.orchestrion_stdlib_cache_manifest`.
- **consumer cache**: a later action's writable cache. It can be seeded from the
  declared cache, but it is never the declared cache itself.

The intended flow is:

```text
GoStdlib action
  |
  +-- live go install / go list
  |     GOCACHE=<stdlib-output>/.gocache
  |     produces mutable *-a and data *-d entries
  |
  +-- Orchestrion persistence
  |     produces woven archives under the replicated GOROOT
  |
  +-- deterministic publisher
        reads archive locations from the scratch cache
        copies selected woven bytes to equivalent *-d paths in -cacheout
        writes a sorted .orchestrion_stdlib_cache_manifest

Later compile/link action
  |
  +-- RULES_GO_ORCHESTRION_STDLIB_CACHE=<declared cache, read-only source>
  +-- GOCACHE=<later action's private writable cache>
  +-- seedWovenStdlibCache copies/hard-links declared archives into GOCACHE
```

## Required Invariants

The implementation is complete only if all of the following remain true.

### Cache ownership

- `GOCACHE` and `env.stdlibCache` never refer to the same directory.
- Every `go install`, `go list`, or Orchestrion subprocess receives a writable
  scratch or consumer cache through `GOCACHE`.
- `RULES_GO_ORCHESTRION_STDLIB_CACHE` may point to `env.stdlibCache`, but treats
  it as a read-only source of published archives.
- The scratch cache is removed at the end of the stdlib action on success and
  failure.
- Bazel's declared cache directory exists whenever `-cacheout` is provided,
  including ordinary non-Orchestrion builds.

### Declared output contents

- Without Orchestrion, the declared cache is empty.
- With Test Optimization, the declared cache contains only:
  - selected woven archive data entries at stable relative `*-d` paths; and
  - `.orchestrion_stdlib_cache_manifest`.
- The declared cache contains no `*-a` action index entries, `trim.txt`, Go
  cache README files, temporary files, lock files, or unrelated cache-prefix
  siblings.
- Manifest records are sorted deterministically and contain relative paths.
- Two isolated executions with identical inputs produce the same set of paths
  and identical bytes for every declared output file.

### Runtime correctness

- Ordinary Go targets compile, link, and test without Test Optimization.
- Test Optimization still weaves the required stdlib closure.
- Synthetic test-main and final link actions can find the published woven
  archives.
- A real Go test emits Test Optimization test and telemetry payloads. A green
  build without payloads is a failure, not successful validation.
- Existing partial-result, doctor, enrichment-validation, and upload behavior
  remains unchanged; this fix is confined to stdlib cache production and
  consumption.

## Scope

### In scope

- The base `rules_go` trees for all three registered upstreams.
- Builder unit tests covering cache ownership, publication, manifest contents,
  path safety, and command environments.
- Generated public patch profiles, metadata, and changed-files reports.
- The generated-profile functional smoke in
  `tools/dev/verify_rules_go_profiles.py`.
- Consumer validation in `rules_test_optimization_tests` for every maintained
  upstream in both disabled/plain and Test Optimization modes.
- Adoption in `dd-source`, including removal of its temporary `0019` overlay,
  after the rules change has been published and pinned.

### Out of scope

- Replacing the Go build cache implementation.
- Persisting or remotely sharing the entire Go `GOCACHE`.
- Changing the public Test Optimization configuration or onboarding API.
- Adding another user-facing Orchestrion mode.
- Parallelizing doctor or payload upload work.
- Changing which stdlib packages are woven, except where required to preserve
  the existing closure while changing cache storage.
- Refactoring unrelated Orchestrion cache, jobserver, resolver, uploader, or
  payload code.

## Design Decisions

### D-1: Fix the base trees, then regenerate

The three directories under `third_party/rgo/*/base` are the editable source of
truth. Generated files under `third_party/rules_go_orchestrion/patches` must not
be hand-edited. After the base implementations and tests agree, use the
repository generators once to refresh all derived artifacts.

This is especially important on the current PR branch because generated patch
files already contain pending review fixes. Regenerating once at the end avoids
overlapping generated churn and preserves those changes.

### D-2: Keep the current Go-cache-shaped archive layout

Published archives will retain their cache-relative `*-d` paths. Existing
manifest readers and cache-seeding logic already understand this format, so it
is the smallest compatible change. A new custom flat archive layout would
increase the diff and require more consumer rewrites without improving the
determinism guarantee.

### D-3: Resolve layout only against writable scratch

`go list -export -deps` remains the authority for locating Go cache archive
paths, but it runs only against the scratch cache during stdlib publication.
The resulting path for each package is made relative to the scratch root and
projected into the declared root. The resolver must never run with the declared
root as `GOCACHE`.

### D-4: Publish an allowlist, not a copied cache tree

The publisher copies the existing woven archive bytes for the selected package
set. It does not recursively copy a Go cache directory or a two-character cache
prefix. This prevents an adjacent `*-a`, metadata file, or unrelated data entry
from entering the declared TreeArtifact.

### D-5: Treat path containment as a correctness boundary

For every projected destination:

1. compute the source archive's path relative to the absolute scratch root;
2. reject absolute relative results;
3. reject `..` and any path whose cleaned form escapes the root;
4. join the validated relative path to the declared root;
5. verify the resulting destination is still contained by the declared root.

The implementation must use `filepath` semantics so the same validation works
on Linux, macOS, and Windows.

### D-6: Prove determinism from bytes, not filesystem timestamps

The verifier compares a canonical inventory of relative path, file type, size,
and SHA-256 content digest. Filesystem mtimes are not part of the TreeArtifact's
semantic content and must not be used to create a false failure. Symlinks, if
any unexpectedly appear, must be reported rather than silently followed.

## Implementation Plan

### S-1: Introduce explicit cache setup in `stdlib.go`

Apply the same logical change in:

- `third_party/rgo/v0_60_0/base/go/tools/builders/stdlib.go`
- `third_party/rgo/v0_61_1/base/go/tools/builders/stdlib.go`
- `third_party/rgo/v0_62_0/base/go/tools/builders/stdlib.go`

In `stdlib`, immediately after the replicated GOROOT is selected:

1. Always define `cachePath` as `filepath.Join(output, ".gocache")`.
2. If `-cacheout` is non-empty, store `abs(*cacheOut)` in
   `goenv.stdlibCache`; do not assign it to `cachePath`.
3. Set process `GOCACHE` to the scratch `cachePath`.
4. Create the scratch directory and register unconditional deferred removal.
5. If `goenv.stdlibCache` is non-empty, create that directory separately so
   the declared TreeArtifact exists even when the plain path publishes no
   files.
6. Remove `shouldRemoveStdlibCache`; cache ownership no longer depends on
   Orchestrion or on the presence of `-cacheout`.

Errors must identify whether scratch preparation or declared-output
preparation failed and include the affected path.

Expected behavior after S-1 alone:

- plain stdlib builds no longer write live cache data into `-cacheout`;
- Orchestrion has access to both roots through separate fields/environment;
- publication is not yet safe until S-2 and S-3 are complete.

### S-2: Stop Orchestrion commands from overriding `GOCACHE`

Apply the same logical change to each version's
`go/tools/builders/env_orchestrion.go`.

Change `env.newBufferedCommand` so it:

- preserves the `GOCACHE` already present in `os.Environ()`;
- sets `RULES_GO_ORCHESTRION_STDLIB_CACHE` when `env.stdlibCache` exists and is
  a directory;
- never assigns `env.stdlibCache` to `GOCACHE`.

Update the function comment to describe the declared cache as an archive
source, not a cache override. Do not duplicate scratch-cache creation here:
stdlib setup and the existing command-environment helpers already own writable
cache selection.

Audit all direct uses of `env.stdlibCache` in the builder package. Classify each
one as either:

- a read of the declared manifest/archive source; or
- an accidental attempt to use it as a writable Go cache.

Only the latter are changed. In particular, preserve manifest readers and
`seedWovenStdlibCache`, which intentionally copy declared archives into a
different writable cache.

### S-3: Make stdlib publication one-way and deterministic

Refactor `syncPersistedOrchestrionExportsToCache` in each version's
`stdlib.go`.

The new algorithm is:

1. Return early when there is no environment, no persisted export, no selected
   root, or no declared cache.
2. Read the current absolute scratch cache from `GOCACHE`. Reject an empty
   value or an alias with the declared cache.
3. Create the declared cache directory without changing process `GOCACHE`.
4. Call `resolveCacheStdlibExportsAt(goenv, roots, scratchCache)` exactly once.
5. Sort the resolved package names.
6. For each selected package:
   - require a persisted woven source archive;
   - require a resolved scratch data-entry path;
   - derive and validate its cache-relative destination;
   - require the destination to be a data entry rather than an action index;
   - copy the persisted woven archive bytes to that destination under the
     declared cache;
   - append `package=relative/path` to the manifest.
7. Write `.orchestrion_stdlib_cache_manifest` atomically after all archives
   have been copied successfully.

Prefer a small helper for safe path projection, for example a function that
takes `(scratchRoot, declaredRoot, scratchArchive)` and returns a validated
destination and relative manifest path. Keep it private to the builder package.

The publisher must not:

- build a `candidateCaches` list;
- temporarily set `GOCACHE` to the declared cache;
- call `resolveCacheStdlibExportsAt` against the declared cache;
- copy a whole Go cache prefix directory into the declared cache;
- include a manifest record for a package whose archive was not published.

If later code in the same stdlib action needs the woven archive in scratch, it
may replace the corresponding scratch `*-d` entry with the woven bytes as a
separate operation. That mutable update remains inside scratch and is not a
substitute for explicit publication.

### S-4: Preserve downstream manifest and seeding behavior

Review, and change only if a test proves it necessary:

- `readStdlibCacheManifest`
- `readAllStdlibCacheManifest`
- `currentWovenStdlibCacheKey`
- `seedWovenStdlibCache`
- `resolveCacheStdlibExportsAt`
- importcfg rewrite helpers that consume `goenv.stdlibCache`

The desired downstream contract is:

- manifest reads never invoke Go or mutate the declared cache;
- `seedWovenStdlibCache` resolves destinations against its writable
  `cacheRoot`, then copies or hard-links source bytes from the declared cache;
- a consumer that receives `RULES_GO_ORCHESTRION_STDLIB_CACHE` can populate its
  own `GOCACHE` without modifying the TreeArtifact;
- generic Orchestrion and Test Optimization continue to use their existing
  package selection logic.

Do not make `resolveCacheStdlibExportsAt` globally read-only. It is still valid
for ephemeral writable caches used by consumers. The caller, not the resolver,
must enforce that the declared cache is never passed as its writable root.

### S-5: Add builder unit tests

The existing builder test target includes `stdlib_test.go` in
`@rules_go//go/tools/builders:orchestrion_test`. Add the tests to the base trees
and keep the test sources identical across all three versions where the
production sources are identical.

#### Cache setup and ownership tests

- Replace `TestShouldRemoveStdlibCache` with tests for the new cache-selection
  helper or directly test the smallest extracted setup seam.
- With no `-cacheout`, verify scratch is `<output>/.gocache` and scheduled for
  removal.
- With `-cacheout`, verify scratch remains `<output>/.gocache`, declared cache
  is stored separately, both directories exist, and the paths do not alias.
- Cover relative inputs normalized to absolute paths.

Avoid testing deferred filesystem cleanup through the complete `stdlib`
command if a small ownership helper can prove the same contract more reliably.

#### Command environment tests

Add a focused test for `newBufferedCommand`:

- set a known private `GOCACHE` in the process environment;
- set `env.stdlibCache` to a distinct existing directory;
- construct the command without executing it;
- assert its `GOCACHE` is still the private value;
- assert `RULES_GO_ORCHESTRION_STDLIB_CACHE` is the declared value;
- verify an absent or invalid declared directory does not replace `GOCACHE`.

#### Publisher determinism tests

Construct two fake scratch cache roots with:

- identical selected `*-d` relative paths;
- identical persisted woven archive bytes;
- different `*-a` contents that model Go's timestamped index records;
- different unrelated metadata or prefix siblings.

Publish each into a fresh declared directory and assert:

- the canonical path-and-content inventories are identical;
- the expected `*-d` archives contain the woven bytes;
- no `*-a`, metadata, temporary, or unrelated sibling file is present;
- the manifest contains only successfully published packages;
- records and relative paths are identical and sorted.

Where invoking the real resolver would make the unit test depend on a host Go
cache, factor the copying/projection portion into a deterministic helper and
test it with an explicit package-to-scratch-path map. Existing integration
tests will cover the real resolver.

#### Negative tests

- Reject a resolved path outside the scratch root.
- Reject an absolute or `..`-escaping manifest projection.
- Reject an action-index (`*-a`) source where a data entry is required.
- Return a useful error when a selected package has no persisted woven archive.
- Do not leave a complete-looking manifest after a failed publication.

#### Existing regression tests

Keep existing tests for:

- persisted stdlib export installation;
- manifest reads;
- seeding a writable cache;
- importcfg rewrites;
- the standard-library package closure in `general` and
  `test_optimization` modes.

### S-6: Apply the implementation to every maintained upstream

At the start of implementation, compare the relevant source files across the
three bases. They are currently byte-identical for `stdlib.go`,
`stdlib_test.go`, `importcfg.go`, and `env_orchestrion.go`, so the preferred
workflow is:

1. implement and review the change in `v0_60_0`;
2. copy the exact logical change to `v0_61_1` and `v0_62_0`;
3. compare the resulting files or focused diffs across versions;
4. retain a version-specific difference only when the upstream base requires
   it and document the reason in the diff.

Do not assume future equality: re-run the comparison immediately before
propagating the change.

### S-7: Extend generated-profile functional verification

Extend the existing functional smoke in
`tools/dev/verify_rules_go_profiles.py`; do not create a parallel profile
verifier.

For each registered upstream, the verifier already materializes a pristine
upstream tree, applies the generated public patch, creates a temporary WORKSPACE
consumer, executes a Test Optimization test, and inspects `aquery`. Add a
determinism phase to that same temporary consumer.

#### Plain mode

1. Build or test the Go target without the Orchestrion flags.
2. Identify the `GoStdlib` action and its declared `gocache` TreeArtifact.
3. Record a canonical inventory of the output.
4. Force a second execution with identical source inputs but without reusing
   the first `GoStdlib` action result.
5. Record the second inventory and compare it with the first.
6. Assert both declared cache inventories are empty.

#### Test Optimization mode

1. Run with:

   ```text
   --@io_bazel_rules_go//go/private/orchestrion:enabled=true
   --@io_bazel_rules_go//go/private/orchestrion:mode=test_optimization
   ```

2. Capture the `GoStdlib` declared cache inventory.
3. Force the same action to execute again in an isolated output state.
4. Compare every relative path and file digest.
5. Require a non-empty sorted manifest and its referenced archives.
6. Reject `*-a`, `trim.txt`, cache metadata, symlinks, and unmanifested files.
7. Preserve the existing `aquery` assertions proving that the generated patch
   actually enabled Test Optimization.
8. Preserve the real test execution proving that the woven stdlib can be
   consumed.

The implementation may use two isolated Bazel output roots or an explicit
action-cache invalidation mechanism. It must not compare one execution with a
cache hit from that same execution. Disable remote and disk cache reuse for this
specific determinism check so both inventories come from executed actions.

Use `aquery --output=jsonproto` or another structured Bazel output to locate
the action outputs. Do not depend on a hard-coded configuration hash in a
`bazel-out` path.

#### Functional payload assertion

The generated-profile smoke currently proves the test and action shape. If it
cannot observe Test Optimization payloads directly, add the smallest fixture
assertion that the test created the expected test and telemetry output files.
Keep full doctor/uploader validation in the consumer repository, where those
targets already exist.

### S-8: Regenerate public profiles and metadata

After all base files and focused tests are stable, regenerate and inspect the
derived outputs:

```bash
python3 tools/dev/diff_rules_go_fork.py --all --write-report
python3 tools/dev/generate_rules_go_fork_maps.py --check
python3 tools/dev/materialize_rules_go_fork.py check --all
python3 tools/dev/verify_rules_go_profiles.py \
  --public-denylist tools/dev/private_leak_public_denylist.txt
python3 tools/dev/check_release_archive_contents.py
```

Expected generated changes include the matching
`third_party/rules_go_orchestrion/patches/<version>/base/0001-full-delta.patch`
files and any changed-files or metadata output owned by the generator. Inspect
every generated diff to ensure it contains the cache fix and the already
intended PR changes, without private paths or unrelated churn.

If a generator modifies a base source file, stop and understand why before
continuing; the base source implementation must remain the reviewed source of
truth.

## Validation Matrix

The minimum acceptance matrix is:

| rules_go | Plain Go | Test Optimization | Declared-cache bytes | Payload proof |
| --- | --- | --- | --- | --- |
| v0.60.0 | required | required | two isolated runs | required |
| v0.61.1 | required | required | two isolated runs | required |
| v0.62.0 | required | required | two isolated runs | required |

For every row:

- plain Go must compile and test without enabling Orchestrion;
- Test Optimization must compile, link, execute, and emit payloads;
- the declared cache must satisfy the file allowlist;
- two independently executed `GoStdlib` actions must produce identical
  canonical inventories;
- a subsequent unchanged consumer run must be eligible for a Bazel cache hit.

### Focused repository validation

Before the full repository suite, run the smallest relevant builder and Python
tooling tests. Resolve exact labels with `bazel query` if necessary rather than
guessing a target that is not visible from the root module.

Expected focused coverage includes:

```bash
./bazelw test @rules_go//go/tools/builders:orchestrion_test \
  --noexperimental_split_xml_generation
./bazelw test @rules_go//go/tools/builders:importcfg_test \
  --noexperimental_split_xml_generation
./bazelw test //tools/tests/python:python_tools_test \
  --noexperimental_split_xml_generation
```

Then run:

```bash
./bazelw test //... --noexperimental_split_xml_generation
```

On macOS, use the repository's documented Bazel wrapper and macOS validation
procedure. Do not introduce a source-level workaround for a local Bazel test
runner issue.

### Consumer validation in `rules_test_optimization_tests`

Before publishing, validate the local rule checkout through the sibling
consumer repository. Enable the existing local overrides for:

- `datadog-rules-test-optimization`;
- `datadog-rules-test-optimization-go`;
- the selected `rules_go` base tree.

Exercise all three upstreams using the existing fixture support:

```bash
for rules_go_upstream in v0_60_0 v0_61_1 v0_62_0; do
  RULES_GO_UPSTREAM="$rules_go_upstream" RTO_LOCAL_ARCHIVE=1 \
    ./fixtures/bzlmod-go/runtests
done
```

Use the repository's documented WORKSPACE and hermetic variants as required by
the canonical matrix. For each upstream, validate both phases explicitly:

1. disabled/plain run without `--config=test-optimization`;
2. enabled run with `--config=test-optimization`;
3. doctor;
4. uploader enrichment validation using the current one-pass uploader
   contract;
5. actual upload only where the CI workflow is already authorized to upload;
6. a second unchanged run to observe Bazel cache reuse.

The local run must use Go 1.25.0, reset long-lived Bazel state when diagnosing a
discrepancy, and clear the stable Orchestrion cache when the test specifically
needs a cold Orchestrion execution. Do not clear caches between the first and
second runs whose purpose is to prove cache reuse.

## Cross-Repository Rollout

### R-1: Publish `rules_test_optimization`

Only after the complete rules and consumer matrices pass:

1. inspect the final diff and generated artifacts;
2. commit only the intended PR #214 files;
3. push the current PR branch;
4. record the exact remote commit SHA;
5. allow PR CI to verify Linux, macOS, and Windows behavior.

Publishing is a separate authorized phase. Implementation and local validation
do not themselves authorize a commit or push.

### R-2: Repin `rules_test_optimization_tests`

Update PR #108 to the exact published rules SHA using its maintained refresh
tooling, including every generated fixture pin and hash. Run the full
multi-version consumer matrix from the pinned commit, not from a local override,
before considering the repin complete.

### R-3: Adopt in `dd-source`

After PR #108 proves the published artifact:

1. update dd-source's rules/Test Optimization pin to the exact rules SHA;
2. regenerate dd-source's composed `rules_go` patch so the deterministic cache
   fix is already present in its generated rules patch;
3. remove
   `third_party/rules_go/0019-Keep-stdlib-GOCACHE-off-the-declared-cacheout-output.patch`;
4. remove the corresponding patch-list entry from `WORKSPACE`;
5. remove the `0019` section from `third_party/rules_go/README.md`;
6. verify there is no second application of the same source hunk.

Validate dd-source in both modes:

- a representative ordinary Go target without Test Optimization;
- the Test Optimization pilot target with
  `--config=test-optimization`;
- the existing Reprise determinism check for `GoStdlib` outputs;
- the Test Optimization load job, including a fresh run and an unchanged
  cached run;
- the existing Bazel cache hydration flow after the generated patch and pin are
  final.

For the Test Optimization run, require test and telemetry payload counts and
successful doctor/enrichment/upload stages. A Reprise success from a plain Go
target alone does not prove the Orchestrion path.

## Failure Handling and Rollback

### During Rule implementation

- If plain mode is deterministic but Test Optimization is not, inspect the
  declared tree for a remaining writer before changing the output comparison.
- If the declared tree is deterministic but payloads disappear, revert the
  consumer-side cache-read change and inspect manifest/seeding behavior. Do not
  accept build-only success.
- If only one upstream fails, compare its pristine upstream source and
  generated patch with the other bases before adding a version-specific branch.
- If Windows path tests fail, fix path normalization and containment logic; do
  not disable the negative test on Windows.

### During downstream adoption

- Keep dd-source's `0019` until the new rules commit has been successfully
  pinned and its composed patch is verified to contain the replacement fix.
- If the repinned dd-source patch cannot apply, restore the previous exact rules
  pin and retain `0019`; do not partially combine old and new hunks.
- If CI exposes a regression after publication, roll back by exact pin rather
  than adding another overlay before determining whether the failure is in
  Rule generation, consumer integration, or dd-source composition.

## Risks and Mitigations

### Silent loss of instrumentation

**Risk:** compile and link succeed while downstream actions read plain stdlib
archives.

**Mitigation:** require real payload emission plus doctor/enrichment validation,
not only builder unit tests or `aquery` output.

### A hidden declared-cache writer remains

**Risk:** another helper passes `env.stdlibCache` as `GOCACHE` and reintroduces
timestamped index files.

**Mitigation:** audit every `env.stdlibCache`, `GOCACHE`, and
`resolveCacheStdlibExportsAt` call site; assert the output allowlist in both unit
and generated-profile tests.

### Accidental cache-prefix copying

**Risk:** copying siblings of a selected data archive includes an action index
or unrelated package entry.

**Mitigation:** publish only explicit selected archive paths and verify that
every output except the manifest is referenced by the manifest.

### Path escape or platform-specific path handling

**Risk:** relative projection produces a destination outside the declared root,
especially with Windows volume or separator semantics.

**Mitigation:** centralized `filepath`-based containment validation with Linux,
macOS, and Windows CI coverage and explicit negative unit tests.

### False determinism from Bazel cache reuse

**Risk:** the verifier compares a newly executed action with a Bazel cache hit
of the same output.

**Mitigation:** use isolated output/action-cache state for both runs and record
evidence that `GoStdlib` executed twice.

### Excessive stdlib preparation time

**Risk:** resolving exports once per package or per destination cache increases
the already expensive preparation phase.

**Mitigation:** resolve the complete selected package set once against scratch,
sort once, and copy once. Add no new `go list` invocation per package.

### Generated patch drift on the active PR

**Risk:** regenerating while review fixes are pending loses or duplicates
changes already present in generated profiles.

**Mitigation:** modify base sources first, keep existing user changes intact,
then run the canonical generators once and inspect the combined generated diff.

## Completion Criteria

The work is complete only when:

- all three base profiles implement the same cache ownership contract;
- no live Go or Orchestrion subprocess receives the declared cache as
  `GOCACHE`;
- plain Go declared cache outputs are empty and reproducible;
- Test Optimization declared cache outputs contain only deterministic
  manifested archive data;
- two isolated executions per mode and upstream have identical path-and-byte
  inventories;
- builder unit tests, profile materialization, profile verification, release
  archive checks, and the full rules suite pass;
- local and published consumer fixtures pass for `v0.60.0`, `v0.61.1`, and
  `v0.62.0`;
- real Test Optimization tests emit valid test and telemetry payloads;
- an unchanged second consumer run demonstrates Bazel cache reuse;
- PR #108 is pinned to the final rules SHA and passes its CI matrix;
- dd-source is pinned to that same rules version, passes both plain and Test
  Optimization validation, and no longer carries the standalone `0019` patch;
- no temporary overrides, scratch artifacts, or unrelated generated changes
  remain in any of the three repositories.

## Execution Checklist

- [ ] Confirm the active Rule branch and preserve all existing review changes.
- [ ] Recompare relevant builder sources across all three bases.
- [ ] Implement private scratch and separate declared-cache setup.
- [ ] Remove the Orchestrion `GOCACHE=env.stdlibCache` override.
- [ ] Implement safe deterministic archive publication.
- [ ] Audit every declared-cache read and write call site.
- [ ] Add cache ownership and command-environment tests.
- [ ] Add deterministic publisher and path-safety tests.
- [ ] Run focused builder tests.
- [ ] Propagate and compare the implementation across all upstreams.
- [ ] Extend generated-profile plain and Test Optimization determinism smoke.
- [ ] Regenerate profiles, metadata, and changed-files reports.
- [ ] Run materialization, verifier, release, and full-suite checks.
- [ ] Validate local consumer fixtures across all versions and both modes.
- [ ] Publish the Rule commit when explicitly authorized.
- [ ] Repin and validate PR #108 from the published commit.
- [ ] Repin dd-source and regenerate its composed rules_go patch.
- [ ] Remove dd-source `0019` and its WORKSPACE/README references.
- [ ] Validate dd-source plain, Test Optimization, Reprise, load, and cache
      hydration flows.
- [ ] Inspect final diffs and confirm all temporary local wiring is removed.

