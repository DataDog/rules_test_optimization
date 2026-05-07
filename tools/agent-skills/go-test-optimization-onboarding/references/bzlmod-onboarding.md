# Bzlmod Go Onboarding

Use this reference for repositories that use `MODULE.bazel` and can consume the
Go companion module through Bzlmod.

## Module Wiring

Add core and Go companion dependencies:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<published-main-commit>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<published-main-commit>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.60.0")
```

Use a commit that is reachable from `origin/main`. Do not publish branch-only
commits in consumer snippets because squash merges can make them disappear.

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
    strip_prefix = "third_party/rules_go_orchestrion_base",
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_version = "v2.9.0-dev.0.20260416093245-194346a71c51",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
```

Use `third_party/rules_go_orchestrion_complete` instead of
`third_party/rules_go_orchestrion_base` only when the repository needs the
extended monorepo compatibility variant. Do not set both `dd_trace_go_version`
and `dd_trace_go_versions` in the same `orchestrion.from_source(...)` call. If
the repository resolves Datadog tracer modules to different exact versions, use
guided bootstrap or its onboarding summary to generate the exact
`dd_trace_go_versions` block.

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
- root `dd_test_optimization_doctor`
- root `dd_upload_payloads`
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

## Manual Sync And Root Targets

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

Then add root doctor and uploader targets:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
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

Use the generated local wrapper when available. If wiring manually, load
`dd_topt_go_test` and pass `topt_data`:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_go_test(
    name = "go_default_test",
    srcs = ["service_test.go"],
    embed = [":service_lib"],
    orchestrion_pin_files = [
        "//:go.mod",
        "//:go.sum",
        "//:orchestrion.tool.go",
        "//:orchestrion.yml",
    ],
    topt_data = topt_data,
)
```

Prefer `embed` so the macro can infer the same import path that `rules_go`
uses. Use explicit `importpath` only when the repository already uses explicit
import paths and the value is known to match the compiled package.

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

Root doctor/uploader targets must include every service context that can appear
in emitted payloads:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)
```
