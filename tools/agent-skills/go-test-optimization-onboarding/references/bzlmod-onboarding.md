<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Bzlmod Go Onboarding

Use this reference for repositories that use `MODULE.bazel` and can consume the
Go companion module through Bzlmod.

## Module Wiring

Copy core and Go companion dependencies from the release's `INSTALL.md`.
Replace the archive placeholders below with that tuple and match the Datadog
module versions to the release. For releases without bundle assets or for
development commits, use the Git alternative in `docs/Installation_Reference.md`.

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.4.0")
archive_override(
    module_name = "datadog-rules-test-optimization",
    urls = ["<release-archive-url>"],
    sha256 = "<release-archive-sha256>",
    strip_prefix = "<archive-prefix>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.4.0")
archive_override(
    module_name = "datadog-rules-test-optimization-go",
    urls = ["<release-archive-url>"],
    sha256 = "<release-archive-sha256>",
    strip_prefix = "<archive-prefix>/modules/go",
)

bazel_dep(name = "rules_go", version = "0.60.0")

topt_go_ddtest = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl",
    "topt_go_ddtest",
)
topt_go_ddtest.sdk(go_mod = "//:go.mod")
```

`rules_go` is plain upstream `rules_go` from the Bazel Central Registry,
`0.60.0` or newer. CI covers `0.60.0` through `0.65.0`; `0.65.0` requires Go
`1.26`. Do not add a `rules_go` override.

`topt_go_ddtest.sdk(...)` selects the Go SDK that `ddtest instrument`
instruments. Set it once, in the root module:

- `go_mod`: a `go.mod` label. Its `toolchain` directive, then its `go`
  directive, gives the Go version, as with rules_go's `go_sdk.from_file`. The
  package that owns `go.mod` needs a BUILD file.
- `go_version`: a Go version such as `"1.25.0"`; it overrides `go_mod`.
- `base_sdk_roots`: exec platform to a file at the root of the Go SDK to
  instrument there, for example `{"linux_amd64": "@go_sdk//:ROOT"}`. Other
  exec platforms download the official SDK.
- `exec_platforms`: the exec platforms to instrument. The default is all six
  ddtest platforms: `linux`, `darwin`, and `windows` on `amd64` and `arm64`.
- `experiments`: `GOEXPERIMENT` values of the base SDKs.
- `panic_hook`: record an unrecovered panic as the running test's failure.

The Go companion registers the instrumented toolchains, so the root module
registers none. Only instrumented tests select them: a build without
instrumented tests fetches neither the instrumented SDKs nor Mini, ddtest's
Test Optimization runtime, and Bazel fetches only the SDKs of the exec
platforms it selects. `ddtest instrument` needs no host `go` binary. See
[`docs/Configuration_Reference.md`](../../../../docs/Configuration_Reference.md#go-instrumentation-sdk)
for the full attribute reference and
[ddtest's Bazel guide](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md)
for what `ddtest instrument bazel` writes.

Without an `sdk` tag, a stand-in toolchain fails every instrumented test with
`Go tests instrumented by dd_topt_go_test need a Go SDK to instrument`.

Add this line to the named config used by test, doctor, and uploader:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

The config is the only user-facing switch. No global Go flag is required.

When using the Git alternative, use a commit reachable from `origin/main`.
Do not publish branch-only commits in consumer snippets because squash merges
can make them disappear.

The guided bootstrap writes the `topt_go_ddtest` block for you. Without the
bootstrap, add it by hand as shown above.

## Managed Manifest Variant

For a large monorepo whose repository-owned command expands exact Go/Python
targets, declare the aggregate API instead of a checked-in service list:

```bzl
topt_manifest = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync_extension",
)
topt_manifest.test_optimization_manifest_sync(
    name = "test_optimization_data",
)
use_repo(topt_manifest, "test_optimization_data")
```

The managed command owns the temporary manifest and its private handoff to
Bazel. Agents must not add that handoff to `.bazelrc`, generate `examples.bzl`,
or create Gazelle/ownership machinery. The central Go wrapper looks up its full
label in `topt_data_by_target`; only present labels delegate to
`dd_topt_go_test`.

One command invocation must reuse the same manifest path for test, doctor,
dry-run, and optional upload. A later invocation creates a new path and fetches
again. Unchanged selected metadata must retain Bazel test-result cache hits;
telemetry timing facts are post-test context, not test action inputs.

This changes metadata selection, not Go toolchain ownership. Keep the same
`topt_go_ddtest.sdk(...)` configuration described above.

## Recommended Bootstrap

For fresh or simple Bzlmod workspaces, use guided bootstrap:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service <datadog-service> \
  --runtime-version <go-version> \
  --write-bazelrc
```

If the Go module lives below the workspace root, pass its directory:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service <datadog-service> \
  --runtime-version <go-version> \
  --go-module-dir path/to/go-module \
  --write-bazelrc
```

The guided bootstrap creates or updates:

- a managed `MODULE.bazel` block, between
  `# BEGIN Datadog Go Test Optimization bootstrap` and
  `# END Datadog Go Test Optimization bootstrap`, with
  `topt_go_ddtest.sdk(go_version = "<runtime-version>")`
- `bazel_dep(name = "rules_go", version = "0.60.0")` when `MODULE.bazel` has no
  `rules_go` dependency
- the managed single-service Go sync block (`test_optimization_go_extension`)
- root `dd_test_optimization_doctor` and `dd_upload_payloads` targets for a
  small repository
- a safe `.bazelrc` block with `--write-bazelrc`
- a local Go test wrapper at `//tools/build:dd_go_test.bzl`

The guided flow requires the core and Go companion modules in `MODULE.bazel`
first. Run without `--guided` to write only the managed `MODULE.bazel` block.
Without `--runtime-version`, that block reads the Go version from the Go
module's `go.mod` with `go_mod = "//<package>:go.mod"`; the bootstrap stops when
the directory of `go.mod` has no BUILD file.

Use `--print-bazelrc-snippet` for read-only `.bazelrc` inspection. Use
`--write-onboarding-summary=<path>` with `--rto-commit <sha>` when you want a
repository-local guide for humans and agents. `--print-workspace-snippet`
belongs to `--workspace-mode`, not the Bzlmod guided flow.

## Migrating A 1.x Setup

Rerun the bootstrap with the same flags. It replaces the Go bootstrap block
that 1.x wrote with the new block and writes no `rules_go` override.

- The bootstrap stops when `MODULE.bazel` still has an unmanaged override of
  `rules_go` that points at the 1.x `rules_go` fork. Remove that override so
  `rules_go` comes from the Bazel Central Registry, then rerun the bootstrap.
- If Bazel cannot load the workspace because the old block points at a fork
  commit that no longer resolves, run the bootstrap from another workspace with
  `--workspace /absolute/path/to/consumer`, or delete the old block by hand.
- Remove the 1.x instrumentation attributes from wrappers and callsites.
  `dd_topt_go_test` fails analysis with a migration message while they remain.
- The `# BEGIN Datadog Go Pin Files` blocks that 1.x wrote in BUILD files are
  harmless. You may delete them.

The [migration note](../../../../CHANGELOG.md#unreleased) lists the files,
`go.mod` requirements, and metadata keys that changed.

## Manual Sync And Workspace Targets

Skip guided bootstrap only when the repository already has custom sync wiring,
mixed-language setup, or multi-service Go setup. In that case, create the sync
repo explicitly in `MODULE.bazel`:

```bzl
datadog_go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

datadog_go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "<datadog-service>",
    runtime_version = "<go-version>",
    module_path = "<go-module-path>",
    require_git_metadata = True,
)

use_repo(datadog_go_topt, "test_optimization_data")
```

Then add one doctor and uploader pair. Root is acceptable for a small
repository; in a monorepo put this block in a lightweight package such as
`//tools/test_optimization`:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
)
```

Use the actual sync repository name consistently if it is not
`test_optimization_data`.

## Wrapper Usage

Use the generated central wrapper when available. If wiring manually, keep one
repository-owned public wrapper that always delegates to `dd_topt_go_test`:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        **kwargs
    )
```

For an enabled export, `dd_topt_go_test` builds a hidden
`<name>__raw_go_test` with the instrumented Go SDK, adds Mini's
`@topt_go_ddtest_mini//testopt` library and a registration file, and exposes
the public `<name>` test. For a disabled export, it creates a plain `go_test`
under the same name.

Prefer `embed` so the macro can infer the same import path that `rules_go`
uses. Use explicit `importpath` only when the repository already uses explicit
import paths and the value is known to match the compiled package. When
synchronized metadata exposes module groups, explicit `importpath` and
`module_label_override` selections must match one or analysis fails. Inferred
misses and metadata with no module groups use the canonical full bundle.
Local-static descriptors follow the same rules: their stable repository-state
target exposes the generated module catalog without requiring a load of
`export.bzl`. The catalog retains exact backend identifiers, so Go's escaped
runtime symbol name and an external `<importpath>_test` package resolve without
manual label overrides.

The macro adds `-s -w` test linker flags by default, except in Bazel modes
where rules_go already strips or the user asked otherwise: `-c dbg`,
`--strip=always`, `--strip=never`, and `fastbuild` with the default
`--strip=sometimes`. Set `enable_test_binary_linker_optimization = False` to
keep the caller's linker flags unchanged.

## Mini From go_deps

The Go module needs no Datadog requirements. When tests use Mini's Go API,
`go.mod` requires `github.com/DataDog/ddtest/ddto`, and `go_deps` creates its
own copy of that module. Replace it with the generated Mini: add these lines
after the `topt_go_ddtest` block of the root `MODULE.bazel`:

```bzl
use_repo(topt_go_ddtest, "topt_go_ddtest_mini")

# go_deps is the workspace's existing Gazelle go_deps extension.
override_repo(go_deps, com_github_datadog_ddtest_ddto = "topt_go_ddtest_mini")
```

Without the override, analysis of an instrumented test fails with
`would link Mini's packages twice` and prints this recipe.

## Bzlmod Monorepos

For Bzlmod monorepos:

- Use one sync repo for a single service.
- Use a multi-sync aggregator when one Go runtime owns multiple Datadog
  services.
- Bundle every relevant `:test_optimization_context` target into the root
  doctor and uploader.
- Use service-specific `topt_data` or `topt_data_by_service` in wrappers.

The doctor and uploader can handle service-qualified aggregate context aliases
when the generated sync repo exposes them.

Example multi-service Go wiring:

```bzl
datadog_go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

datadog_go_topt.test_optimization_go(
    name = "test_optimization_data",
    services = ["go-service-a", "go-service-b"],
    runtime_version = "<go-version>",
    module_path = "<go-module-path>",
    require_git_metadata = True,
)

use_repo(datadog_go_topt, "test_optimization_data")
```

Wrapper callsites can load the aggregate mapping:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "go_default_test",
    srcs = ["service_test.go"],
    embed = [":service_lib"],
    topt_data = topt_data_by_service,
    topt_service = "go-service-a",
)
```

The workspace doctor/uploader targets must include every service context that
can appear in emitted payloads:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    context_data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)
```
