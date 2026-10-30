<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Installation Reference

This page contains full installation and setup flows. For fast onboarding, use
the scenario quickstarts in `README.md`. For language-specific single-service
and multi-service onboarding, use [`docs/Language_Onboarding.md`](Language_Onboarding.md).

## Bzlmod installation

### Option A: install from a release archive (recommended)

Download `INSTALL.md`, `release.json`, and `SHA256SUMS` from the chosen
[GitHub release](https://github.com/DataDog/rules_test_optimization/releases).
`INSTALL.md` contains complete dependency blocks with the release version,
archive URL, SHA256, and each module's `strip_prefix`. Copy the core block and
only the companion blocks you need. These overrides do not depend on BCR
publication.

In `MODULE.bazel`, use `archive_override`, which uses Bazel's HTTP downloader
and repository cache. In WORKSPACE, use `http_archive`. Reuse the same archive
and SHA256 for core and companions. Each companion uses
`<archive-prefix>/modules/<language>`. Go uses upstream `rules_go`, which you
declare yourself.

The following is the shape of a core Bzlmod install. Replace every placeholder
with the tuple from one release; do not copy a checksum from another version.

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "<release-version>")
archive_override(
    module_name = "datadog-rules-test-optimization",
    urls = ["<release-archive-url>"],
    sha256 = "<release-archive-sha256>",
    strip_prefix = "<archive-prefix>",
)
```

The Go bootstrap does not write or change core and companion overrides. Copy
them from `INSTALL.md`; the bootstrap adds the Go SDK configuration described
in [Go companion module](#go-companion-module).

Release bundles are prepared by the [release workflow](../CONTRIBUTING.md#release-runbook-core--companion-modules).
GitHub's automatic source downloads are distinct from the uploaded, checksum-pinned
release asset. `v1.3.0` predates bundle automation and has no `INSTALL.md` asset;
use the Git recipe below for that version. The historical `v1.2.0` archive
tuple further below still belongs to `v1.2.0`.

### Option B: install from a Git commit

Use this for an unreleased change, an older release without bundle assets, or
a private repository that requires Git authentication. Pin the same published
commit for core and companions. The examples use `1.4.0`, which is in
preparation; use a development commit with that version, or select the
published `v1.3.0` commit and module versions.

In your `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

# Optional companion module (only needed if you use dd_topt_go_test)
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

# Only needed when using dd_topt_go_test. Also configure the Go SDK to
# instrument with topt_go_ddtest.sdk(...); see "Go companion module" below.
bazel_dep(name = "rules_go", version = "0.60.0")

# Optional companion module (only needed if you use dd_topt_py_test)
bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)

# Optional companion module (only needed if you use dd_topt_java_test)
bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)

# Optional companion module (only needed if you use dd_topt_nodejs_test)
bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

# Optional companion module (only needed if you use dd_topt_dotnet_test)
bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

# Optional companion module (only needed if you use dd_topt_ruby_test)
bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)
```

Use the same full commit SHA (40 chars) for core and companion modules.
For mirrored/archive installs, also pin and verify archive `sha256` values (see
"Archive mirror installation" below) so the fetched source is integrity-checked
in CI and local builds.

For `v1.2.0`, use commit
`69953536d4ef1252c8181c267d16c61263f0aa4c`.

### Generate published Go pins

Before copying Go pins into a consumer repository, generate them from a
squash-merged commit that is already reachable from `origin/main`.

From a `rules_test_optimization` checkout:

```bash
./bazelw run //tools/dev:print_go_onboarding_pins -- \
  --commit "$(git rev-parse origin/main)" \
  --verify-main-reachable
```

The command prints the six values used by WORKSPACE git and archive mode:
`RTO_COMMIT`, `RTO_REMOTE`, `RTO_ARCHIVE_URL`, `RTO_ARCHIVE_SHA256`,
`RTO_ARCHIVE_PREFIX`, and `RTO_ARCHIVE_TYPE`. Add `--print-summary` to also
print a Markdown summary. Published GitHub codeload pins are `tar.gz`; use a
separate repository-owned mirror process for any other archive format.

#### Historical `v1.2.0` published tuple

```bash
RTO_COMMIT="69953536d4ef1252c8181c267d16c61263f0aa4c"
RTO_REMOTE="https://github.com/DataDog/rules_test_optimization.git"
RTO_ARCHIVE_URL="https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/69953536d4ef1252c8181c267d16c61263f0aa4c"
RTO_ARCHIVE_SHA256="fd54d1871fc01ff0bb3db190dfaadaa8256edd68a4f3bb85ecc08b315fbf5bd4"
RTO_ARCHIVE_PREFIX="rules_test_optimization-69953536d4ef1252c8181c267d16c61263f0aa4c"
RTO_ARCHIVE_TYPE="tar.gz"
```

The archive URL, SHA256, and prefix are tied to the repository commit. This
tuple installs `v1.2.0`, which predates `ddtest instrument`; the Go setup on
this page needs a newer commit.

From a consumer that already has the Go companion available, the bootstrap can
print the same values or write a checked-in Markdown summary:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --print-published-pins \
  --rto-commit <published-origin-main-sha>

bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --write-onboarding-summary=TEST_OPTIMIZATION_GUIDE.md \
  --rto-commit <published-origin-main-sha>
```

The bootstrap summary command does not inspect `MODULE.bazel` or `go.mod`; it
validates that the commit is a full SHA, hashes the published archive, and
writes a Datadog-managed Markdown file. If you run it from a checkout that has
the `rules_test_optimization` Git history, add `--verify-main-reachable` for
the same `origin/main` reachability check as the dev helper. Existing unmanaged
files are preserved unless `--force` is passed.

### Option C: local development overrides

```bzl
local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "/absolute/path/to/datadog-rules-test-optimization",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/go",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-python",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/python",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-java",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/java",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/nodejs",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/dotnet",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-ruby",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/ruby",
)
```

### Configure sync extension (single service)

```bzl
test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

# Minimal usage: defaults to writing under .testoptimization and creating
# @test_optimization_data//:test_optimization_files
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

The low-level core sync remains always enabled by default. The public Go
extension is config-gated by default; config-gated Python onboarding sets
`enabled_by_env = True` in its language-specific setup. Do not add that
attribute to another companion until its runtime wrapper implements the
disabled export contract.

Core module note: `datadog-rules-test-optimization` is runtime-agnostic and
does not declare language-rule dependencies. Language-specific orchestration
lives in companion modules:
- `datadog-rules-test-optimization-go` (depends on `rules_go` providers),
- `datadog-rules-test-optimization-python`,
- `datadog-rules-test-optimization-java`,
- `datadog-rules-test-optimization-nodejs`,
- `datadog-rules-test-optimization-dotnet`,
- `datadog-rules-test-optimization-ruby`.

### Go companion module

`dd_topt_go_test` builds each enabled test with the Go SDK that
`ddtest instrument` instruments, and links Mini, ddtest's Test Optimization
runtime. `rules_go` is plain upstream: Bzlmod consumers use
`bazel_dep(name = "rules_go", version = "0.60.0")` or newer, with no override.
The ddtest side is documented in
[ddtest's Bazel guide](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md).

The root module configures the Go SDK to instrument:

```bzl
topt_go_ddtest = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl",
    "topt_go_ddtest",
)
topt_go_ddtest.sdk(go_mod = "//:go.mod")  # or go_version = "1.25.0"
```

`go_mod` reads the `toolchain` directive, then the `go` directive, like
`rules_go`'s `go_sdk.from_file`; the package that holds `go.mod` needs a BUILD
file. `go_version` overrides `go_mod`. The Go companion registers the
toolchains, so the root module registers none. Only instrumented tests select
those toolchains, so other builds fetch neither the instrumented SDK nor Mini,
and Bazel fetches only the SDKs of the exec platforms it selects. ddtest does
not need a Go installation on the host. All `sdk` attributes are listed in
[`Configuration_Reference.md`](./Configuration_Reference.md#go-instrumentation-sdk).

For a fresh single-service Go workspace, the recommended path is:

1. add the core + Go companion dependency/override block and the `rules_go`
   `bazel_dep`
2. run guided bootstrap
3. use the generated local wrapper

Guided bootstrap command:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --write-bazelrc
```

If the Go module lives below the workspace root:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --go-module-dir path/to/go-module \
  --write-bazelrc
```

Bootstrap writes a managed `MODULE.bazel` block between
`# BEGIN Datadog Go Test Optimization bootstrap` and
`# END Datadog Go Test Optimization bootstrap` with the `topt_go_ddtest`
extension. With `--runtime-version`, which guided mode requires, the block sets
`topt_go_ddtest.sdk(go_version = "<runtime-version>")`. Without it, the block
sets `go_mod = "//<pkg>:go.mod"` for the `--go-module-dir` module; bootstrap
stops when that directory has no BUILD file. Bootstrap also inserts
`bazel_dep(name = "rules_go", version = "0.60.0")` when `MODULE.bazel` has no
`rules_go` dependency. It does not write a `rules_go` override, and it does
not run Go commands or change `go.mod`.

Guided mode also writes the single-service sync block, the root doctor and
uploader targets, and `//tools/build:dd_go_test.bzl`.

Guided bootstrap is intentionally for single-service Go workspaces. If the
workspace already uses conflicting or multi-service sync wiring:
- `test_optimization_sync_extension`
- `test_optimization_multi_sync_extension`
- a conflicting `test_optimization_go_extension` setup

use the manual/advanced Go setup path instead.

If the workspace already has a matching single-service
`test_optimization_go_extension` plus `use_repo(...)`, guided bootstrap can
reuse that wiring and continue.

Rerunning bootstrap on a workspace that 1.x set up replaces the Go bootstrap
block that 1.x wrote with the block above. It stops with a message when
`MODULE.bazel` still overrides `rules_go` with the 1.x fork outside that block;
remove that override and rerun. If the old block's fork commit no longer loads,
run bootstrap from another workspace with `--workspace <path>`, or delete the
old block by hand. Managed pin-file blocks that 1.x wrote in BUILD files are
harmless and can be deleted. See the
[migration note](../CHANGELOG.md#unreleased).

A Bzlmod workspace whose `go.mod` requires `github.com/DataDog/ddtest/ddto`, to
use Mini's Go API in tests, must replace `go_deps`' copy of that module with
the generated Mini. Otherwise the test fails analysis because it would link
Mini's packages twice:

```bzl
use_repo(topt_go_ddtest, "topt_go_ddtest_mini")
override_repo(go_deps, com_github_datadog_ddtest_ddto = "topt_go_ddtest_mini")
```

For WORKSPACE monorepos, use `--workspace-mode` instead of `--guided`.
WORKSPACE mode deliberately does not edit `WORKSPACE`; it prints the repository
wiring for manual placement and writes only local managed files:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --print-workspace-snippet \
  --service go-service \
  --runtime-version 1.25.0 \
  --sync-repo-name test_optimization_data \
  --rto-commit <commit-sha> \
  --rules-go-repo-name io_bazel_rules_go
```

The snippet declares upstream `rules_go` first, as a commented `http_archive`
placeholder with the release URL, then the core repository,
`datadog_go_test_optimization_workspace_repositories(...)`,
`go_rules_dependencies()`, `go_register_toolchains(...)`,
`topt_go_ddtest_workspace_repositories(go_version = ...)`, and the sync
repositories. Step 8 below shows the same wiring.

After placing the WORKSPACE snippet, generate the safe local scaffolding:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --sync-repo-name test_optimization_data \
  --write-bazelrc \
  --write-wrapper-template \
  --expected-target //pkg:go_default_test
```

Create the single doctor/uploader pair in a lightweight monorepo package such
as `//tools/test_optimization`; reserve `--write-root-targets` for small
repositories that intentionally keep these targets in the root BUILD.

The generated wrapper template creates one central local wrapper and retains
the former optimized name only as a compatibility alias. Keep
repository-specific scheduling, tags, flaky behavior, Docker defaults, and
platform constraints in the local policy helper; the central wrapper owns only
`topt_data`. Omitting `--config=test-optimization` preserves normal `go_test`
behavior through that same entry point.

Generate a repeatable validation script when onboarding needs several control
and instrumented targets:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --write-validation-script \
  --validation-script-path tools/test_optimization/validate_go_pilot.sh \
  --bazel-command bazel \
  --bazel-config test-optimization \
  --sync-repo-name test_optimization_data \
  --control-target //pkg/plain:go_default_test \
  --expected-target //pkg:go_default_test \
  --large-monorepo \
  --min-free-disk-gb 25 \
  --shutdown-bazel-on-exit
```

The generated script runs
`sync -> controls -> instrumented tests -> doctor -> validated uploader`.
It captures one BEP JSON file per Bazel test invocation and passes those files
to doctor/uploader with `--freshness-source=bep --freshness-mode=required`. It
runs the uploader exactly once with enrichment validation: dry-run by default,
or real upload when called with `--upload`. It does not delete caches, print
secrets, proxy payloads, or pass
`DD_GIT_*` through `--test_env`. The generated test config uses
`--zip_undeclared_test_outputs`, and the script passes `--artifact-source=bep`
to doctor/uploader so local `outputs.zip` carriers are extracted through BEP
artifact staging. If BEP points at remote-only HTTP/HTTPS `outputs.zip`
carriers, doctor/uploader can stage them natively with
`--remote-artifacts=download` or `required`; bytestream/CAS/custom-auth
providers still need `--bep-artifact-downloader`. Set
`DD_TEST_OPTIMIZATION_REPORT_DIR` to choose where the
generated script writes `doctor-report.json` and `uploader-report.json` under
that directory; otherwise it writes them under its per-run temporary directory
and logs that path.

### Go Bazel config

Use `--write-bazelrc` to insert or replace the managed
`# BEGIN Datadog Test Optimization Bazelrc` block. Use
`--print-bazelrc-snippet` when you want to review or copy the block manually.

The generated config is named `test-optimization` by default:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
common:test-optimization --repo_env=DD_API_KEY
common:test-optimization --repo_env=DD_SITE
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_BRANCH
common:test-optimization --repo_env=DD_GIT_TAG
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_PR_NUMBER
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
```

The full generated block includes all sync metadata inputs from the repository
rule. It intentionally does not include `--test_env=DD_GIT_*`,
`--test_env=DD_TEST_OPTIMIZATION_AGENT_URL`, or
`--test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`. Git metadata belongs to the
sync metadata fetch through `--repo_env`, and uploader credentials/endpoints are
read later by `bazel run`.

The generated config intentionally does not include a fixed
`--build_event_json_file`. CI wrappers should create a unique BEP path for each
Bazel test invocation, pass it to `bazel test` with
`--build_event_json_file=<path>`, and pass the same path to doctor/uploader with
repeatable `--bep-json=<path>` flags. This keeps parallel CI jobs and repeated
local runs from overwriting or reusing stale BEP files.

`FETCH_SALT` is intentionally not part of the generated default config. Use it
only in a separate force-refresh
`bazel sync --config=test-optimization --only=<repo>` command when you
deliberately want fresh backend metadata from a config-gated repository.

Run Go onboarding commands with this config:

```bash
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
tools/test_optimization/run_test_optimization_ci.sh \
  --report-dir .topt/reports \
  --support-bundle .topt/reports/dd-test-optimization-support.zip \
  //...

# Add --upload to send every available fresh valid payload after validation attempts.
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
  tools/test_optimization/run_test_optimization_ci.sh \
    --report-dir .topt/reports \
    --support-bundle .topt/reports/dd-test-optimization-support.zip \
    --upload \
    //...
```

```powershell
# Vendor the full tools/test_optimization/ helper directory, or set
# DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR to create_support_bundle.py.
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  //...

# Add -Upload to send every available fresh valid payload after validation attempts.
$env:DD_API_KEY = "<your-api-key>"
$env:DD_SITE = "datadoghq.com"
.\tools\test_optimization\run_test_optimization_ci.ps1 `
  -ReportDir .topt\reports `
  -SupportBundle .topt\reports\dd-test-optimization-support.zip `
  -Upload `
  //...
```

During rollout debugging, prefer `--report-dir <path>` plus
`--support-bundle <path>` on the CI wrapper, or set
`DD_TEST_OPTIMIZATION_REPORT_DIR` and `DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE`.
The wrapper writes `doctor-report.json` plus exactly one uploader report:
`uploader-dry-run-report.json` without `--upload`, or
`uploader-upload-report.json` with it. When support bundle output is
configured, it also writes `dd-test-optimization-support.zip` with redacted
reports, selected BEP summaries, effective wrapper flags, runtime metadata, and
`summary.md`. Use `--doctor-report-json` or
`--uploader-report-json` only when CI needs one explicitly named report; manual
doctor/uploader commands can pass `--report-json=<path>` after the target's
`--` separator.

For a first-pass support request after tests have run, the customer can run only
the doctor:

```bash
bazel run --config=test-optimization //:dd_test_optimization_doctor -- \
  --support-bundle .topt/reports/dd-test-optimization-support.zip
```

Add the matching `--bep-json`, `--freshness-*`, and `--artifact-*` flags when
the failing job uses BEP/BwoB. This doctor-only bundle does not include uploader
dry-run or upload results.
For a complete support handoff, follow the escalation ladder in
[`docs/Troubleshooting.md`](Troubleshooting.md#collect-diagnostic-reports).

Reports include `result.status`, `result.reason_code`, human-readable
`result.reason`, and `result.next_steps`, plus expected targets, BEP
fresh/cached/remote-only outputs, artifact staging, payload discovery, payload
processing, and upload counters. If a repository cannot use the doctor or
wrapper support-bundle entrypoints but has the helper script, create the
redacted zip manually:

```bash
python3 tools/test_optimization/create_support_bundle.py \
  --report-dir .topt/reports \
  --report-json .topt/reports/doctor-report.json \
  --report-json .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/dd-test-optimization-support.zip \
  --workspace-root "$PWD" \
  --output-base "$(bazel info output_base)"
```

When only Markdown is possible, generate a short fallback summary with:

```bash
python3 tools/test_optimization/render_report_summary.py \
  .topt/reports/doctor-report.json \
  .topt/reports/uploader-dry-run-report.json \
  --output .topt/reports/upload-diagnostics.md
```

When upload is enabled, the wrapper runs the real uploader once after the doctor
and validates enrichment in that same pass. It processes every available fresh
valid payload even if tests or doctor failed while preserving the earliest
failure as the job result.

The default uploader is one standard-library Python 3.10+ implementation on
Linux, macOS, and Windows. It prepares shared CODEOWNERS and context data once,
then uses eight independent file workers by default. Each worker handles one
test, coverage, or telemetry source through preparation, retries, and cleanup.
The run ends with human-readable and JSON statistics. Use `--debug` only when
the normal report is not enough; use `--dry-run --validate-enrichment` to verify
the complete outbound preparation without HTTP or deletion.

For manual Go extension wiring, set `module_path` to the Go module path from
`go.mod`:

```bzl
go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.25.0",
    module_path = "github.com/example/service",
)
```

`GO_MODULE_PATH` remains an env override and wins when set, but new workspaces
should prefer the attr so CI does not need an extra repo-env passthrough.

The generated package-facing API is:

```bzl
load("//tools/build:dd_go_test.bzl", "dd_go_test")
```

### Python companion module

```bzl
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
```

Use the default `runner_mode = "managed_pytest"` when the Datadog macro should
own pytest execution. Use `runner_mode = "consumer_runner"` when a repository
already has a Python test wrapper and must keep control of `main`, `imports`,
and internal test policy. In `consumer_runner` mode, pass a custom
`py_test_rule` or an explicit `main` that runs pytest with ddtrace enabled. When
the runtime module path and Bazel package path identify the test, omit
`module_identifier` and use the derived fallback. Keep an explicit
`module_identifier` only for a documented repository-specific exception.
When synchronized metadata exposes module groups, explicit
`module_identifier` and `module_label_override` values must match one or
analysis fails. Inferred or derived misses, and metadata with no module groups,
use the canonical full bundle.

Python consumers can generate copy/paste onboarding snippets from the companion
without running tests or changing lockfiles:

```bash
bazel run @datadog-rules-test-optimization-python//tools/dd_topt_py_bootstrap:dd_topt_py_bootstrap -- \
  --mode=workspace \
  --service py-service \
  --runtime-version 3.12 \
  --runtime-module-path example.python.pkg \
  --rto-commit <commit-sha> \
  --bazel-command bazel
```

Add `--write-bazelrc` or `--write-targets` only when you want the tool to
insert managed blocks. The normal generated flow does not include
`FETCH_SALT`; use `--print-refresh-snippet` only for an explicit one-off
metadata refresh.

### Java companion module

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
```

### NodeJS companion module

```bzl
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
```

### .NET companion module

```bzl
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
```

### Ruby companion module

```bzl
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
```

### Core-only consumer (no companion module)

If your repository needs sync + uploader only (including non-Go languages),
depend on core only:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.4.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)
use_repo(test_optimization_sync, "test_optimization_data")
```

This core-only example preserves the always-enabled contract. Add
`enabled_by_env = True` only when deliberately composing the config-gated Go or
Python flow.

### Multi-service usage (Bzlmod)

Fetch multiple services with one extension and select per-service data by label:

```bzl
# MODULE.bazel
topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["service-a", "service-b"],
    runtime_module_path = "example.python.pkg",
    runtime_name = "python",
    runtime_version = "3.12",
    debug = True,
    enabled_by_env = True,
)

use_repo(
    topt_multi,
    # Aggregator repo
    "test_optimization_data",
    # Per-service repos (auto-created, names include sanitized service key)
    "test_optimization_data_service_a",
    "test_optimization_data_service_b",
)

# Consuming labels (aggregator):
#  - All files for one service
#    @test_optimization_data//:test_optimization_files_service_a
#  - One module for one service (service + module label in the aggregator repo)
#    @test_optimization_data//:module_service_a_core
# Per-service repos are primarily used for per-service exports like:
#   load("@test_optimization_data_service_a//:export.bzl", "topt_data")

# Macros that expect "topt_data" can use either:
# 1) Select explicitly:
#    load("@test_optimization_data//:export.bzl", "topt_data_by_service")
#    dd_topt_py_test(..., topt_data = topt_data_by_service["service_a"])
# 2) Pass the mapping and choose via topt_service (keeps BUILD simpler):
#    dd_topt_py_test(..., topt_data = topt_data_by_service, topt_service = "service_a")
#    When service names sanitize to the same key, pass the deduped key shown in
#    the available list (for example "service_a_2").
```

Mixed-runtime note: keep runtime-specific sync repositories separate (for
example one sync for Go services and another sync for Python services). A single
`test_optimization_multi_sync` call currently models one runtime per invocation.

### Manifest-driven managed Go/Python monorepos

Use this API only when a consumer-owned managed command discovers exact test
labels and derives service/runtime contexts for each invocation. It is not a
replacement for static single-service or static multi-service wiring.

```bzl
# MODULE.bazel
topt_manifest = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync_extension",
)

topt_manifest.test_optimization_manifest_sync(
    name = "test_optimization_data",
)

use_repo(topt_manifest, "test_optimization_data")
```

The same repository rule is available to WORKSPACE consumers:

```bzl
# WORKSPACE
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync",
)

test_optimization_manifest_sync(
    name = "test_optimization_data",
)
```

The declaration contains no service list. The managed command owns a private
temporary manifest with fully expanded local target labels and provides it only
to the child Bazel invocation. Users should run that command rather than
creating the manifest or its environment handoff manually. When
`--config=test-optimization` is absent, the repository ignores the manifest
and emits stable disabled stubs. When enabled, a missing or invalid manifest
fails before any metadata HTTP request.

The command must reuse one manifest path for test, doctor, and the validated
uploader so all phases resolve the same metadata snapshot. The next
command invocation creates a new temporary manifest path and fetches current
backend state once. Equivalent selected settings/module files remain stable
test action inputs, preserving normal Bazel test-result cache hits; variable
`telemetry_facts.json` timing data remains post-test context.

The generated aggregate repository exports:

- `topt_data_by_target`: exact local label to context-specific `topt_data`;
- `topt_data_by_context`: deterministic context key to `topt_data`;
- `target_context_keys`: exact local label to context key;
- `@test_optimization_data//:test_optimization_context`: every generated
  context for doctor/uploader enrichment;
- `@test_optimization_data//:expected_targets`: the exact selected-target JSON
  contract for the doctor;
- `@test_optimization_data//:test_optimization_files_<context_key>` and
  `@test_optimization_data//:module_<context_key>_<module_label>` for narrow
  action inputs.

The consumer's central Go/Python wrapper computes the current full label and
looks it up in `topt_data_by_target`. A present entry delegates to
`dd_topt_go_test` or `dd_topt_py_test`; an absent entry preserves the
repository's raw test behavior. Java, NodeJS, .NET, and Ruby do not use this
automatic manifest path in this release.

Wire one doctor/uploader pair to the dynamic outputs:

```bzl
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl",
    "dd_test_optimization_targets",
)

dd_test_optimization_targets(
    name = "test_optimization",
    context_data = [
        "@test_optimization_data//:test_optimization_context",
    ],
    expected_targets_file = "@test_optimization_data//:expected_targets",
)
```

Additional helper file exported by the generated repository:

- `export.bzl` with a single dictionary `topt_data` containing:
  - `repo_name`: external repository name created by the sync rule (for example,
    `test_optimization_data`)
  - `manifest_path`: path to `manifest.txt` inside the generated repo
  - `labels`: list of available per-module sanitized labels
  - `set`: dict-as-set keyed by sanitized labels for fast membership checks
  - `module_group_by_identifier`: exact backend module identifier to generated
    `module_<sanitized>` group mapping; Go selectors use this for escaped symbol
    names, external `_test` packages, and collision-safe lookup
  - `runtimes["go"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["python"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["java"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["nodejs"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["dotnet"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["ruby"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`

Then in any BUILD file:

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)

# Access context.json and telemetry_facts.json through the shared context target.
filegroup(
    name = "dd_test_opt_context",
    srcs = ["@test_optimization_data//:test_optimization_context"],
)
```

## WORKSPACE installation (Bazel without Bzlmod)

WORKSPACE mode is supported for v1 when Bzlmod is disabled.

### 1) Add this repository in `WORKSPACE`

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    # Use an immutable commit SHA.
    commit = "<commit-sha>",
)

# Or:
# local_repository(
#     name = "datadog-rules-test-optimization",
#     path = "/absolute/path/to/rules_test_optimization",
# )
```

Pin an immutable commit SHA (or internal mirrored archive) for reproducibility.

For WORKSPACE Go usage, declare upstream `rules_go` as `io_bazel_rules_go` and
the core repository first, then use the public helper in step 8 to declare the
Go companion at the same Datadog revision:

- `io_bazel_rules_go` for Go rules and toolchains
- `datadog-rules-test-optimization` for sync and uploader rules
- `datadog-rules-test-optimization-go` for `dd_topt_go_test`

Load the Go macro from `@datadog-rules-test-optimization-go//:topt_go_test.bzl`,
not from the root repository.

For WORKSPACE Python usage, declare the core repository and `rules_python`
first, then use the public helper in step 6 to declare the Python companion at
the same Datadog revision:

- `datadog-rules-test-optimization` for sync and uploader rules
- `rules_python` for Python toolchains, `py_test`, and `pip_parse`
- `datadog-rules-test-optimization-python` for `dd_topt_py_test`

Load the Python macro from
`@datadog-rules-test-optimization-python//:topt_py_test.bzl`, not from the root
repository.

For WORKSPACE Java usage, declare the core repository and `rules_java` first,
then use the public helper in step 7 to declare the Java companion at the same
Datadog revision:

- `datadog-rules-test-optimization` for sync and uploader rules
- `rules_java` for Java rules and toolchains
- `datadog-rules-test-optimization-java` for `dd_topt_java_test`

Load the Java macro from
`@datadog-rules-test-optimization-java//:topt_java_test.bzl`, not from the root
repository.

### Archive mirror installation

If your environment requires `http_archive`, use an internal mirror and pin all
three values (`urls`, `strip_prefix`, and `sha256`):

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "datadog-rules-test-optimization",
    urls = [
        "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    ],
    # Match your mirrored archive layout. For commit archives this is typically:
    # "rules_test_optimization-<full_commit_sha>".
    strip_prefix = "rules_test_optimization-<commit-sha>",
    sha256 = "<sha256-for-archive>",
)
```

If your mirror repackages archives, adjust `strip_prefix` to the archive's
actual top-level directory.

### 2) Instantiate the repository rule in `WORKSPACE`

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    service = "my-service",  # recommended; otherwise falls back to DD_SERVICE or unnamed-service
    # Optional:
    # runtime_name = "go",
    # runtime_version = "1.25.0",
    # known_tests = True,
    # test_management = True,
)
```

This generic WORKSPACE example preserves the always-enabled core default. The
public Go helpers apply metadata gating by default; the Python section adds
`enabled_by_env = True` where its macro can safely consume a disabled export.

For a managed Go/Python monorepo, instantiate
`test_optimization_manifest_sync` instead of this static rule, as shown in
[Manifest-driven managed Go/Python monorepos](#manifest-driven-managed-gopython-monorepos).
The consumer-owned command supplies the private invocation manifest; do not
check a service list or target mapping into WORKSPACE.

### 3) Depend on generated files in BUILD files

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)

filegroup(
    name = "dd_test_opt_context",
    srcs = ["@test_optimization_data//:test_optimization_context"],
)
```

### 4) Add the doctor and uploader targets (one pair per workspace)

```bzl
# In root BUILD.bazel for a small repository, or in a lightweight monorepo
# package such as //tools/test_optimization.
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
)
```

After tests and doctor pass, you can validate the exact enriched outbound test
payload without uploading or deleting files. If you invoke this manually instead
of using the CI wrapper, reuse the BEP file created by the matching
`bazel test --build_event_json_file=...` invocation:

```bash
bazel run --config=test-optimization //<topt-package>:dd_upload_payloads -- \
  --bep-json="$bep_json" \
  --freshness-source=bep \
  --freshness-mode=required \
  --dry-run \
  --validate-enrichment
```

Replace `<topt-package>` with the package used above, for example
`tools/test_optimization`. Use `//:dd_upload_payloads` only when the pair lives
in the root package.

Multi-service aggregator variant:

```bzl
dd_test_optimization_targets(
    name = "test_optimization",
    context_data = [
        "@test_optimization_data//:test_optimization_context_service_a",
        "@test_optimization_data//:test_optimization_context_service_b",
    ],
)
```

### 5) Forward environment variables in `.bazelrc`

The metadata forwarding entries below apply to every runtime. Config-gated Go
and Python onboarding also includes:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

Instrumented Go tests select the Go SDK that `ddtest instrument` instruments
through their own transition, so the config has no Go build setting. Java,
NodeJS, .NET, and Ruby
retain their existing enablement contract and omit the metadata gate in this
release.

```text
# Repository rule (module/repo phase) — affects refetch
common:test-optimization --repo_env=DD_API_KEY
common:test-optimization --repo_env=DD_SITE
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL  # Optional sync/uploader agentless URL override
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS  # Optional sync HTTP connect-timeout override
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS         # Optional sync HTTP max-time override
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS           # Optional sync HTTP retry-attempt override
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS      # Optional sync HTTP retry-delay override
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS  # Optional sync execute-timeout buffer override
common:test-optimization --repo_env=DD_SERVICE
common:test-optimization --repo_env=DD_ENV
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_BRANCH
common:test-optimization --repo_env=DD_GIT_TAG
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_GIT_HEAD_COMMIT
common:test-optimization --repo_env=DD_GIT_COMMIT_MESSAGE
common:test-optimization --repo_env=DD_GIT_HEAD_MESSAGE
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_NAME
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_EMAIL
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_DATE
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_NAME
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_EMAIL
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_DATE
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_NAME
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_EMAIL
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_DATE
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_NAME
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_EMAIL
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_DATE
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH_SHA
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH_HEAD_SHA
common:test-optimization --repo_env=DD_PR_NUMBER
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
# Optional: override detected Go module path for export.bzl
common:test-optimization --repo_env=GO_MODULE_PATH
# Optional: provide Python module path hint for export.bzl
common:test-optimization --repo_env=PYTHON_MODULE_PATH
# Optional: provide Java module path hint for export.bzl
common:test-optimization --repo_env=JAVA_MODULE_PATH
# Optional: provide NodeJS module path hint for export.bzl
common:test-optimization --repo_env=NODEJS_MODULE_PATH
# Optional: provide .NET module path hint for export.bzl
common:test-optimization --repo_env=DOTNET_MODULE_PATH
# Optional: provide Ruby module path hint for export.bzl
common:test-optimization --repo_env=RUBY_MODULE_PATH

# Doctor/uploader runtime is passed by the CI wrapper after bazel run's `--`:
#   --bep-json=<per-test-invocation-bep-json>
#   --freshness-source=bep
#   --freshness-mode=required
#   --artifact-source=bep
#   --artifact-staging-dir=<per-run-temp-dir>
#   # If BEP points at remote-only HTTP/HTTPS outputs.zip carriers, add:
#   # --remote-artifacts=download
#   # If BEP points at bytestream/CAS/custom-auth providers, also add:
#   # --bep-artifact-downloader=<path-to-downloader>
#
# Uploader credentials (pass inline or export before run)
# DD_API_KEY and DD_SITE are passed when running the uploader:
#   DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
# PowerShell equivalent:
#   # Set once per shell session before first run:
#   # $env:DD_API_KEY = "<your-api-key>"
#   # $env:DD_SITE = "datadoghq.com"
#   # The PowerShell wrapper passes --bep-json, --freshness-source=bep,
#   # --freshness-mode=required, --artifact-source=bep, and
#   # --artifact-staging-dir after bazel run's `--`.
#   bazel run --config=test-optimization //:dd_upload_payloads

# Tests (runtime)
# Keep uploader credentials out of test runtime by default.
# Do not pass DD_GIT_* through --test_env. Git metadata belongs to the
# repository-rule phase through --repo_env so it cannot invalidate test actions.
# Do not pass DD_TEST_OPTIMIZATION_AGENT_URL or
# DD_TEST_OPTIMIZATION_AGENTLESS_URL through --test_env for instrumented Go tests.
```

Security note: keep secret values out of `.bazelrc`. Forward variable names
with `--repo_env=DD_API_KEY` and provide values via shell/CI secret stores.
In Bazel file-mode workflows, tests do not require `DD_API_KEY`/`DD_SITE`;
those credentials are only needed for the post-test uploader step.

Git metadata note: wrappers in this repository and the sibling fixture repo can
fill in current commit author and committer fields automatically when a CI
provider does not expose them. Explicit `DD_GIT_*` values still win over both
provider-derived metadata and wrapper synthesis.

Repository policy note: this repository intentionally has no root `.bazelrc`.
Consumer repos should keep their own `.bazelrc` and follow CI-maintainer flags
from `README.md` and `docs/Maintainers.md`.

### 6) Configure Python support in WORKSPACE with the public helper

Python WORKSPACE onboarding keeps ownership of Python toolchains and Python
dependencies in the consumer repository. The Datadog helper declares only the
Python companion repository and maps its internal `@rules_python` dependency to
the repository name the consumer already uses.

Declare `rules_python` with the version and mirror policy approved by the
consumer repository. For a direct public pin:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_python",
    sha256 = "f609f341d6e9090b981b3f45324d05a819fd7a5a56434f849c761971ce2c47da",
    strip_prefix = "rules_python-1.7.0",
    urls = ["https://github.com/bazel-contrib/rules_python/releases/download/1.7.0/rules_python-1.7.0.tar.gz"],
)
```

Then declare the Datadog Python companion:

```bzl
load("@datadog-rules-test-optimization//tools/python:workspace_repositories.bzl", "datadog_python_test_optimization_workspace_repositories")

datadog_python_test_optimization_workspace_repositories(
    rto_commit = "<commit-sha>",
    rules_python_repo_name = "rules_python",
)
```

Internal/private consumers should use SSH git fetch when anonymous archives are
not available:

```bzl
git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<commit-sha>",
    remote = "ssh://git@github.com/DataDog/rules_test_optimization.git",
)
```

If you use archive mode for a private repository, Bazel must have
authentication configured for that archive URL. A `404` from codeload usually
means missing auth rather than a missing commit.

Archive mode for mirrored Datadog repositories:

```bzl
load("@datadog-rules-test-optimization//tools/python:workspace_repositories.bzl", "datadog_python_test_optimization_workspace_repositories")

datadog_python_test_optimization_workspace_repositories(
    rto_commit = "",
    datadog_fetch = "archive",
    rules_python_repo_name = "rules_python",
    rto_archive_url = "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    rto_archive_sha256 = "<sha256-for-archive>",
    rto_archive_prefix = "rules_test_optimization-<commit-sha>",
)
```

Next configure Python toolchains and Python package dependencies through the
consumer's normal `rules_python` flow:

```bzl
load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

py_repositories()

python_register_toolchains(
    name = "python_3_12",
    python_version = "3.12",
)

load("@rules_python//python:pip.bzl", "pip_parse")

pip_parse(
    name = "python_deps",
    python_interpreter_target = "@python_3_12_host//:python",
    requirements_lock = "//:requirements_lock.txt",
)

load("@python_deps//:requirements.bzl", "install_deps")

install_deps()
```

Your lockfile should include `pytest` and `ddtrace` because Python dependency
ownership remains with the consumer repository. The helper does not declare
`pytest`, `ddtrace`, `pip_parse`, toolchains, or lockfiles.

Update the sync repository for Python metadata:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    enabled_by_env = True,
    runtime_module_path = "example.python.pkg",
    runtime_name = "python",
    runtime_version = "3.12",
    service = "py-service",
)
```

Pair this opt-in repository rule with
`common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1`. Python
needs no Go setting.

Then in package BUILD files, use either managed pytest mode:

```bzl
load("@python_deps//:requirements.bzl", "requirement")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = glob(["test_*.py"]),
    deps = [
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
)
```

or consumer-runner mode when the repository already owns a pytest wrapper:

```bzl
load("@python_deps//:requirements.bzl", "requirement")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load("//tools/build:py_test.bzl", "repo_py_test")

dd_topt_py_test(
    name = "pkg_py_test",
    py_test_rule = repo_py_test,
    runner_mode = "consumer_runner",
    srcs = glob(["test_*.py"]),
    deps = [
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    topt_data = topt_data,
)
```

In `consumer_runner` mode, the repository-owned wrapper must preserve the
environment passed by `dd_topt_py_test` and must actually execute pytest with
the ddtrace plugin enabled. Do not set `main` to a test file just to satisfy
Bazel; that can produce a false-green target that never runs pytest.

For monorepos, put doctor/uploader in a lightweight package:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data",
    expected_targets = [
        "//python/pkg:pkg_py_test",
    ],
)
```

Run package-local labels such as
`//tools/test_optimization:dd_test_optimization_doctor` and
`//tools/test_optimization:dd_upload_payloads`. Root labels are still valid for
small repositories.

### 7) Configure Java support in WORKSPACE with the public helper

Java WORKSPACE onboarding keeps ownership of Java rules, Java toolchains, test
framework dependencies, and the dd-java-agent artifact in the consumer
repository. The Datadog helper declares only the Java companion repository and
maps its internal `@rules_java` dependency to the repository name the consumer
already uses.

Declare `rules_java` with the version and mirror policy approved by the
consumer repository. Then declare the Datadog Java companion:

```bzl
load("@datadog-rules-test-optimization//tools/java:workspace_repositories.bzl", "datadog_java_test_optimization_workspace_repositories")

datadog_java_test_optimization_workspace_repositories(
    rto_commit = "<commit-sha>",
    rules_java_repo_name = "rules_java",
)
```

Internal/private consumers should use SSH git fetch when anonymous archives are
not available:

```bzl
git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<commit-sha>",
    remote = "ssh://git@github.com/DataDog/rules_test_optimization.git",
)
```

Archive mode for mirrored Datadog repositories:

```bzl
load("@datadog-rules-test-optimization//tools/java:workspace_repositories.bzl", "datadog_java_test_optimization_workspace_repositories")

datadog_java_test_optimization_workspace_repositories(
    rto_commit = "",
    datadog_fetch = "archive",
    rules_java_repo_name = "rules_java",
    rto_archive_url = "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    rto_archive_sha256 = "<sha256-for-archive>",
    rto_archive_prefix = "rules_test_optimization-<commit-sha>",
)
```

After the companion is available, load the macro from the Java companion repo:

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
```

### 8) Configure Go support in WORKSPACE with the public helper

For Bzlmod single-service Go workspaces, prefer guided bootstrap instead. For
WORKSPACE consumers, prefer this helper over a hand-written companion
declaration. It declares only the Go companion and maps the companion's
`@io_bazel_rules_go` to your `rules_go` repository. It fails when that
repository is not declared yet.

Declare upstream `rules_go` first, under the name `io_bazel_rules_go`: the SDK
repositories that `go_wrap_sdk` writes for the instrumented SDK load it under
that name. Then declare the core repository (step 1), the Go companion,
`rules_go`'s dependencies and toolchains, the instrumented SDK, and the sync
repository, in this order:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "io_bazel_rules_go",
    sha256 = "<sha256 from the rules_go release notes>",
    urls = ["https://github.com/bazel-contrib/rules_go/releases/download/v0.60.0/rules_go-v0.60.0.zip"],
)

# Declare datadog-rules-test-optimization here (step 1).

load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<commit-sha>",
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")

go_rules_dependencies()

# Bazel's coverage helper needs a shell toolchain even for a plain go_test.
# Bzlmod registers it automatically; WORKSPACE consumers must do so.
load("@rules_shell//shell:repositories.bzl", "rules_shell_dependencies", "rules_shell_toolchains")

rules_shell_dependencies()

rules_shell_toolchains()

go_register_toolchains(version = "1.25.0")

load("@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl", "topt_go_ddtest_workspace_repositories")

topt_go_ddtest_workspace_repositories(go_version = "1.25.0")

load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")

dd_topt_go_workspace_sync_repositories(
    name = "test_optimization_data",
    service = "go-service",
    module_path = "github.com/example/service",
    runtime_version = "1.25.0",
    require_git_metadata = True,
)
```

Archive mode for mirrored environments:

```bzl
datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<commit-sha>",
    datadog_fetch = "archive",
    rto_archive_url = "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    rto_archive_sha256 = "<sha256-for-archive>",
    rto_archive_prefix = "rules_test_optimization-<commit-sha>",
)
```

Notes for the helpers:

- `datadog_fetch` is `git` (default) or `archive`. Archive mode requires
  `rto_archive_url`, `rto_archive_sha256`, and `rto_archive_prefix`;
  `rto_archive_type` defaults to `tar.gz`. Use values generated from one
  published commit; see [Generate published Go pins](#generate-published-go-pins).
- `rules_go_repo_name` defaults to `io_bazel_rules_go`. Keep that default.
- `topt_go_ddtest_workspace_repositories` declares the ddtest executable,
  Mini's repository, and one instrumented SDK per exec platform, and registers
  their toolchains. It takes the same arguments as the Bzlmod
  `topt_go_ddtest.sdk` tag except `go_mod`: `go_version`, `base_sdk_roots`,
  `exec_platforms`, `experiments`, and `panic_hook`. See
  [`Configuration_Reference.md`](./Configuration_Reference.md#go-instrumentation-sdk).
- To instrument the SDK that `go_register_toolchains` registered instead of
  downloading the official one, name its root file per exec platform:

  ```bzl
  topt_go_ddtest_workspace_repositories(
      base_sdk_roots = {"linux_amd64": "@go_sdk//:ROOT"},
      exec_platforms = ["linux_amd64"],
  )
  ```

- Only instrumented tests select the instrumented toolchains, so other builds
  fetch neither the SDKs nor Mini, and Bazel fetches only the SDKs of the exec
  platforms it selects. ddtest does not need a Go installation on the host.

Then in your Go package `BUILD.bazel`:

```bzl
load("@io_bazel_rules_go//go:def.bzl", "go_library")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["pkg.go"],
    importpath = "github.com/example/service/pkg",
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["pkg_test.go"],
    embed = [":pkg_lib"],  # Enables provider-based importpath inference
    topt_data = topt_data,
)
```

With Test Optimization enabled, the macro builds a hidden raw `go_test` with
the Go SDK that `ddtest instrument` instruments, adds Mini's `testopt` library
and a registration file to it, and exposes `pkg_go_test` as the public test.
The macro's attributes are listed in
[`Configuration_Reference.md`](./Configuration_Reference.md#dd_topt_go_test-attributes).
The ddtest side is documented in
[ddtest's Bazel guide](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md).

To make the direct test sources available at run time, enable source staging
explicitly:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["pkg_test.go"],
    embed = [":pkg_lib"],
    stage_sources = True,
    topt_data = topt_data,
)
```

`stage_sources` stages only the target's direct `srcs` and direct
`embedsrcs`. When enabled, it changes the default `rundir` to `.` only if the
caller did not already set `rundir`.

Note: in WORKSPACE mode, Go support uses three repositories:

- `io_bazel_rules_go` for upstream `rules_go`
- `datadog-rules-test-optimization` for the core rules
- `datadog-rules-test-optimization-go` for the Go companion

No pin files or Go module changes are needed for the instrumentation.
