# Datadog Test Optimization Bazel Module Extension

This repository provides a Bazel module extension and repository rule that fetch Datadog Test Optimization metadata during the module resolution phase and materialize JSON files for use in your build. It also generates a public filegroup so you can conveniently depend on all produced files with a single label.

The extension performs these HTTP POST transactions (via curl):

- Settings: always executed. Parses feature flags from response.
- Known Tests: executed only when `known_tests_enabled: true` in Settings.
- Skippable Tests (ITR): executed only when `tests_skipping: true` in Settings.
- Test Management Tests: executed only when `test_management.enabled: true` in Settings.

All outputs are written under a configurable directory (default: `.testoptimization`) and are grouped under a single filegroup target.

## What gets created

Given an external repository name `<repo_name>` created by the extension, the generated BUILD inside the external repo contains:

- A filegroup target named `test_optimization_files` which includes all produced JSON files
- Files (always created; some may be minimal stubs if the corresponding feature is disabled):
  - `settings.json` (Settings API response)
  - `knowntests.json` (Known Tests API response or minimal stub)
  - `skippabletests.json` (Skippable Tests API response or minimal stub)
  - `tmtests.json` (Test Management Tests API response or minimal stub)

Reference them with a single label:

```bzl
@<repo_name>//:test_optimization_files
```

## Installation (Bzlmod)

In your `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "")

# Optional: develop locally
local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "/absolute/path/to/datadog-rules-test-optimization",
)

test_optimization_sync = use_extension("@datadog-rules-test-optimization//tools:test_optimization_sync.bzl", "test_optimization_sync_extension")

# Minimal usage: defaults to writing under .testoptimization and creating the filegroup
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

Then in any BUILD file:

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)
```

## Configuration and attributes

Extension tag: `test_optimization_sync.test_optimization_sync(...)`

- Required
  - `name`: external repository name to create

- Optional
  - `out_dir` (string): base output directory. Defaults to `.testoptimization`
  - `service` (string): overrides service name. Precedence: `service` attr > `DD_SERVICE` env > `"unnamed-service"`
  - `settings_file` (string): file name or path for settings; if a bare name, it is placed under `out_dir`. Default: `settings.json`
  - `knowntests_file` (string): file name/path for known tests. Default: `knowntests.json`
  - `skippables_file` (string): file name/path for skippable tests. Default: `skippabletests.json`
  - `tmtests_file` (string): file name/path for test management tests. Default: `tmtests.json`
  - `runtime_name` (string): optional runtime name to include in configurations (e.g. `go`)
  - `runtime_version` (string): optional runtime version to include in configurations (e.g. `go1.22`)
  - `runtime_arch` (string): optional runtime architecture. Defaults to auto-detected `os.architecture` when not provided
  - `debug` (bool): default `False`. Enables verbose logging

Notes:
- If optional file attributes are omitted, defaults are used under `out_dir` and do not affect the repository rule cache key.
- Parent directories are created automatically for all output paths.

## How data is fetched

The rule executes curl with timeouts and retries to these Datadog endpoints:

- Settings: `https://api.<DD_SITE>/api/v2/libraries/tests/services/setting`
- Known Tests: `https://api.<DD_SITE>/api/v2/ci/libraries/tests`
- Skippable Tests: `https://api.<DD_SITE>/api/v2/ci/tests/skippable`
- Test Management Tests: `https://api.<DD_SITE>/api/v2/test/libraries/test-management/tests`

Settings response attributes determine which follow-up requests are sent:

- `known_tests_enabled` → triggers Known Tests
- `tests_skipping` → triggers Skippable Tests
- `test_management.enabled` → triggers Test Management Tests

If a feature is disabled, the rule still writes a minimal stub JSON for that output file so consumers can always depend on the filegroup.

## OS and runtime configuration

- OS fields (auto-detected):
  - `os.platform`, `os.version`, `os.architecture` are detected from the host (via `uname`).
- Runtime fields (configurable):
  - `runtime.name`, `runtime.version`, `runtime.architecture`
  - If `runtime_arch` is not provided, it defaults to `os.architecture`.

## Service and environment

- Service precedence: `service` attr > `DD_SERVICE` env > `"unnamed-service"`
- Environment (`env` attribute in payload): `DD_ENV` env or default `"CI"`

## Caching semantics

The repository rule re-executes (fetches) when:

- Any provided attribute changes (e.g., `out_dir`, `service`, runtime_*), or
- Any environment variable listed in `environ` changes, or
- The rule’s Starlark implementation changes.

Outputs are content-addressed for downstream actions, but the repository fetch is keyed only by the repository rule inputs above (attrs + `environ`).

## Environment variables

The rule uses the following environment variables (they are declared in `environ`, and thus affect the repository rule cache key). The extension auto-detects CI providers and maps their environment variables to unified fields (repository URL, branch, SHA, etc.). Datadog-specific `DD_*` variables override provider-derived values.

### Datadog and generic inputs

- `DD_API_KEY` (required): Datadog API key
- `DD_SITE` (optional): site domain (e.g., `datadoghq.com`, `datadoghq.eu`). If a value like `app.datadoghq.com` is provided, it is normalized to use `api.<site>`
- `FETCH_SALT` (optional): use to force re-fetch, e.g., `--repo_env=FETCH_SALT=$(date +%s)`
- `GIT_DIRTY` (optional): only for cache-key shaping, not sent to Datadog

### Datadog Git overrides (highest precedence)

- `DD_GIT_REPOSITORY_URL`
- `DD_GIT_BRANCH`
- `DD_GIT_COMMIT_SHA`
- `DD_GIT_HEAD_COMMIT`
- `DD_GIT_COMMIT_MESSAGE`
- `DD_GIT_HEAD_MESSAGE`

### CI provider detection (examples of fields used)

Below is a summary of detection keys and mapped fields. If multiple are available, Datadog-specific overrides (`DD_GIT_*`) take precedence.

- AppVeyor (detect by `APPVEYOR`)
  - repo: `APPVEYOR_REPO_NAME` (if provider=github → `https://github.com/<name>.git`)
  - sha: `APPVEYOR_REPO_COMMIT`
  - branch: `APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH` or `APPVEYOR_REPO_BRANCH`

- Azure Pipelines (detect by `TF_BUILD`)
  - repo: `BUILD_REPOSITORY_URI`
  - sha: `BUILD_SOURCEVERSION`
  - branch: `BUILD_SOURCEBRANCH`
  - message: `BUILD_SOURCEVERSIONMESSAGE`

- Bitbucket (detect by `BITBUCKET_COMMIT`)
  - repo: `BITBUCKET_GIT_HTTP_ORIGIN` or `https://bitbucket.org/<slug>.git`
  - sha: `BITBUCKET_COMMIT`
  - branch: `BITBUCKET_BRANCH`

- Buildkite (detect by `BUILDKITE`)
  - repo: `BUILDKITE_REPO`
  - sha: `BUILDKITE_COMMIT`
  - branch: `BUILDKITE_BRANCH`
  - message: `BUILDKITE_MESSAGE`

- CircleCI (detect by `CIRCLECI`)
  - repo: `CIRCLE_REPOSITORY_URL`
  - sha: `CIRCLE_SHA1`
  - branch: `CIRCLE_BRANCH`

- GitHub Actions (detect by `GITHUB_SHA`)
  - repo: `GITHUB_SERVER_URL` + `GITHUB_REPOSITORY` + `.git`
  - sha: `GITHUB_SHA`
  - ref → branch: normalized from `GITHUB_REF`

- GitLab (detect by `GITLAB_CI`)
  - repo: `CI_REPOSITORY_URL`
  - sha: `CI_COMMIT_SHA`
  - branch: `CI_COMMIT_BRANCH`
  - message: `CI_COMMIT_MESSAGE`
  - head sha (MR): `CI_MERGE_REQUEST_SOURCE_BRANCH_SHA`

- Jenkins (detect by `JENKINS_URL`)
  - repo: `GIT_URL` or `GIT_URL_1`
  - sha: `GIT_COMMIT`
  - branch: `GIT_BRANCH`

- TeamCity (detect by `TEAMCITY_VERSION`)
  - repo: `GIT_URL`
  - sha: `GIT_COMMIT`
  - branch: `GIT_BRANCH`

- Travis CI (detect by `TRAVIS`)
  - repo: `TRAVIS_REPO_SLUG` → `https://github.com/<slug>.git`
  - sha: `TRAVIS_COMMIT`
  - branch: `TRAVIS_PULL_REQUEST_BRANCH` or `TRAVIS_BRANCH`
  - message: `TRAVIS_COMMIT_MESSAGE`

- Bitrise (detect by `BITRISE_BUILD_SLUG`)
  - repo: `BITRISE_GIT_REPOSITORY_URL`
  - sha: `BITRISE_GIT_COMMIT`
  - branch: `BITRISE_GIT_BRANCH`

- Codefresh (detect by `CF_BUILD_ID`)
  - branch: `CF_BRANCH`

- AWS CodeBuild/CodePipeline (detect by `CODEBUILD_INITIATOR`)
  - limited extraction by default

- Drone (detect by `DRONE`)
  - repo: `DRONE_GIT_HTTP_URL`
  - sha: `DRONE_COMMIT_SHA`
  - branch: `DRONE_BRANCH`
  - message: `DRONE_COMMIT_MESSAGE`

All above detection variables are also declared in `environ` to ensure changes re-run the repository rule.

## Wrapper script (bazelw)

This repo provides a `bazelw` wrapper to simplify running with the right `--repo_env` variables:

- Always injects a changing `FETCH_SALT` for commands that can trigger repo fetching (`build|test|run|sync|fetch|query|cquery|aquery|coverage|info`).
  - Set `FETCH_SALT_TTL` (seconds) to bucketize the salt and avoid re-fetching too frequently.
- Computes Git metadata when a Git repo is present and forwards via `--repo_env`:
  - `GIT_DIRTY`: `clean|dirty`
  - `DD_GIT_REPOSITORY_URL`: from `git config --get remote.origin.url`
  - `DD_GIT_BRANCH`: from `git symbolic-ref --short -q HEAD` (falls back to `rev-parse --abbrev-ref`); defaults to `auto:git-detached-head` on detached HEAD
  - `DD_GIT_COMMIT_SHA`: from `git rev-parse HEAD`
  - `DD_GIT_HEAD_COMMIT`: same as `DD_GIT_COMMIT_SHA`
  - `DD_GIT_COMMIT_MESSAGE`: one-line subject of the HEAD commit
  - `DD_GIT_HEAD_MESSAGE`: same as `DD_GIT_COMMIT_MESSAGE`
- Precedence: if you export any `DD_GIT_*` variables in your shell, they override the computed ones.

Examples:

```sh
# Always refresh on each run
./bazelw build //...

# Refresh on an hourly TTL
FETCH_SALT_TTL=3600 ./bazelw build //...

# Override computed Git metadata (useful in CI or custom scenarios)
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //...
```

## Tips

- To force re-fetch on demand: `./bazelw build //...` automatically injects a changing `FETCH_SALT` (see the provided wrapper). You can also set a TTL via `FETCH_SALT_TTL`.
- For debugging, set `debug = True` when calling the extension to get verbose logs, including request bodies and detected OS info.

