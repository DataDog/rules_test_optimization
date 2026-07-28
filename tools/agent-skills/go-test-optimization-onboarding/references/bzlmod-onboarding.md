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

Add core and Go companion dependencies:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<published-main-commit>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.2.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<published-main-commit>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.60.0")
```

Add these lines to the named config used by test, doctor, and uploader:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
build:test-optimization --@rules_go//go/private/orchestrion:enabled=true
```

The config is the only user-facing switch. Removing
`--config=test-optimization` disables metadata fetching and selects the local
empty Orchestrion aliases; no second Test Optimization flag is required.

Use a commit that is reachable from `origin/main`. Do not publish branch-only
commits in consumer snippets because squash merges can make them disappear.
The `rules_go` version must match the selected Datadog-managed fork support
line. The current default support line is `rules_go_upstream = "v0_60_0"`,
which uses `rules_go` `0.60.0`.

This prerequisite block is enough to run guided bootstrap. If you do not run
guided bootstrap, you must also add the Datadog-managed `rules_go` override and
Orchestrion extension wiring that bootstrap normally writes. Plain upstream
`rules_go` does not provide the Orchestrion integration required by
`dd_topt_go_test`.

Manual Bzlmod wiring must include this block:

```bzl
git_override(
    module_name = "rules_go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<published-main-commit>",
    strip_prefix = "third_party/rgo/v0_60_0/base",
)

test_optimization_go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
test_optimization_go_sdk.download(
    name = "test_optimization_go_sdk",
    version = "<go-version>",
)
use_repo(test_optimization_go_sdk, "test_optimization_go_sdk")

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_pin_files = [
        "@//:go.mod",
        "@//:go.sum",
    ],
    go_sdk_root = "@test_optimization_go_sdk//:ROOT",
    go_sdk_version = "<go-version>",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
```

Guided bootstrap writes this SDK declaration from `--runtime-version`.
Orchestrion uses the Bazel-managed SDK on cache misses, while a compatible
bootstrap cache hit can be restored before the SDK repository is materialized.
Do not add SDK or Orchestrion settings to individual service or test targets.
Export the root `go.mod` and `go.sum` labels from their BUILD package. The
pin-file mode uses this Bazel-managed SDK with `-mod=readonly` to derive direct
and transitive supported tracer versions without editing the module.

For newer support lines such as `v0_61_1`, use the base strip prefix printed by
the bootstrap or onboarding pins summary, for example
`third_party/rgo/v0_61_1/base`. Repositories that
already own a private `rules_go` patch stack should generate a public consumer
patch profile and rebase or merge it locally inside that repository instead of
using a second complete tree. `dd_trace_go_pin_files`,
`dd_trace_go_version`, and `dd_trace_go_versions` are mutually exclusive.
Use an explicit shared or per-module version only when the checked-in module
graph cannot be resolved by normal pin-file mode.

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
Bazel-managed SDK and Orchestrion wiring described above.

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

The bootstrap can create or update:

- `orchestrion.tool.go`
- `orchestrion.yml`
- root `dd_test_optimization_doctor` and `dd_upload_payloads` targets for a
  small repository
- a safe `.bazelrc` block
- a local Go test wrapper

By default, bootstrap uses `--go-mod-sync=targeted`, which updates only the
Orchestrion and Datadog tracer modules needed by the tool imports. Use
`--go-mod-sync=off` if the repository owns Go module changes through a separate
process, and use `--go-mod-sync=tidy` only when the repository explicitly wants
a full `go mod tidy`.

Use `--print-bazelrc-snippet` for read-only `.bazelrc` inspection. Use
`--write-onboarding-summary=<path>` when you want a repository-local guide for
humans and agents. `--print-workspace-snippet` belongs to `--workspace-mode`,
not the Bzlmod guided flow.

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

## Manual Orchestrion Pin Files

Guided bootstrap creates these files automatically. Manual setups must create
them in the Go module directory before using `dd_topt_go_test`.

`orchestrion.tool.go`:

```go
//go:build tools

package tools

import (
    _ "github.com/DataDog/orchestrion" // integration
    _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
    _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
    _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
```

`orchestrion.yml`:

```yaml
---
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: datadog/go-bootstrap
  description: Datadog starter configuration for Orchestrion.

aspects: []
```

Export the pin files from the Bazel package that owns the Go module:

```bzl
exports_files([
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
])
```

If the Go module is not at the workspace root, put this export block in that
module package and use labels such as `//path/to/go-module:go.mod`.

## Wrapper Usage

Use the generated central wrapper when available. If wiring manually, keep one
repository-owned public wrapper that always delegates to `dd_topt_go_test`:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [
            "//:go.mod",
            "//:go.sum",
            "//:orchestrion.tool.go",
            "//:orchestrion.yml",
        ],
        topt_data = topt_data,
        **kwargs
    )
```

Prefer `embed` so the macro can infer the same import path that `rules_go`
uses. Use explicit `importpath` only when the repository already uses explicit
import paths and the value is known to match the compiled package. When
synchronized metadata exposes module groups, explicit `importpath` and
`module_label_override` selections must match one or analysis fails. Inferred
misses and metadata with no module groups use the canonical full bundle.

Set `orchestrion_mode = "test_optimization"` for standard Go `testing`
onboarding. The generated local wrapper should inject this mode; manual
`dd_topt_go_test` callsites must set it explicitly. Automatic `testify/suite`
instrumentation is outside this mode.

Pass `orchestrion_pin_files` whenever tests live outside the package that owns
the pin files. Ensure those labels are exported from the owning package. The
generated wrapper handles this automatically; manual macro callsites must do it
explicitly. If the Go module lives below the workspace root, point the pin file
labels at that module package, for example
`//path/to/go-module:orchestrion.tool.go`, instead of blindly using root labels.

## Go Module Pinning

The current Orchestrion path requires the repository's Go module to resolve the
instrumentation packages that become part of the test binary. Bootstrap should
pin the tracer version consistently. Do not hand-edit random tracer versions
unless you are intentionally testing a version change.

If `go.mod` already contains Datadog tracer dependencies, keep one coherent
version set. Do not mix the Bazel Orchestrion configuration with a different
root Go module tracer version.

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
    orchestrion_mode = "test_optimization",
    orchestrion_pin_files = [
        "//:go.mod",
        "//:go.sum",
        "//:orchestrion.tool.go",
        "//:orchestrion.yml",
    ],
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
