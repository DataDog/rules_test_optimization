# Configuration Reference

This page contains the full configuration and environment reference.

## Go Orchestrion version selection

Guided Go bootstrap accepts:

| Flag | Default | Description |
|------|---------|-------------|
| `--dd-trace-go-version` | `v2.6.0` | Go tracer query for bootstrap. Accepts a tag, pseudo-version, branch, or commit SHA and persists the exact resolved versions Bazel should use |

Manual Orchestrion wiring in `MODULE.bazel` accepts:

| Setting | Default | Description |
|---------|---------|-------------|
| `orchestrion.from_source(..., dd_trace_go_version = "...")` | `v2.6.0` | Shared tracer version used by Bazel's Orchestrion tool and fallback paths |
| `orchestrion.from_source(..., dd_trace_go_versions = {...})` | none | Exact per-module tracer versions for `github.com/DataDog/dd-trace-go/v2`, `github.com/DataDog/dd-trace-go/contrib/net/http/v2`, and `github.com/DataDog/dd-trace-go/contrib/log/slog/v2` |

Notes:

- The selected version is workspace-wide for Go. There is no per-test override.
- Bootstrap repins the local Go module to the same effective versions.
- Bootstrap writes `dd_trace_go_version` when all traced modules resolve to one
  shared version, and `dd_trace_go_versions` when they resolve to different
  exact versions.
- If you rerun bootstrap without `--dd-trace-go-version`, it preserves the
  existing bootstrap-managed tracer config instead of resetting it.
- Bootstrap does not take ownership of tracer settings that are already managed
  manually outside its managed block.
- Do not set both `dd_trace_go_version` and `dd_trace_go_versions` in the same
  `orchestrion.from_source(...)` call.
- If the workspace setting and the effective local Go module versions differ,
  the build fails instead of mixing versions.

## Sync extension attributes

Extension tag: `test_optimization_sync.test_optimization_sync(...)`

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | External repository name to create (examples use `test_optimization_data`) |
| `out_dir` | string | `.testoptimization` | Base output directory. Must be a non-empty relative path; absolute paths and `..` traversal are rejected |
| `service` | string | `"unnamed-service"` or `DD_SERVICE` | Service name precedence: `service` attr > `DD_SERVICE` env > fallback |
| `runtime_name` | string | empty | Optional runtime name (examples: `go`, `python`, `java`, `nodejs`, `dotnet`, `ruby`) |
| `runtime_version` | string | empty | Optional runtime version (example: `1.24.0`) |
| `runtime_arch` | string | auto-detected | Optional runtime arch; defaults to detected `os.architecture` |
| `http_connect_timeout_seconds` | int | `-1` attr / `10` effective | Optional connect-timeout override for sync HTTP requests (`-1` keeps env/default behavior) |
| `http_max_time_seconds` | int | `-1` attr / `60` effective | Optional per-request max-time override for sync HTTP requests (`-1` keeps env/default behavior) |
| `http_retry_attempts` | int | `-1` attr / `3` effective | Optional retry-attempt override for sync HTTP requests (`-1` keeps env/default behavior) |
| `http_retry_delay_seconds` | int | `-1` attr / `2` effective | Optional retry-delay override for sync HTTP requests (`-1` keeps env/default behavior) |
| `http_execute_timeout_buffer_seconds` | int | `-1` attr / `60` effective | Optional outer execute-timeout buffer override (`-1` keeps env/default behavior) |
| `known_tests` | bool | `True` | Local switch for Known Tests request. When `False`, request is skipped, a minimal stub is written, and settings are mutated to `known_tests_enabled=false` |
| `test_management` | bool | `True` | Local switch for Test Management request. When `False`, request is skipped, a minimal stub is written, and settings are mutated to `test_management.enabled=false` |
| `debug` | bool | `False` | Enables verbose repository-rule logging |

Notes:

- `manifest.txt` path is exported via `topt_data["manifest_path"]` and respects
  `out_dir`.
- Parent directories are created automatically for all output paths.
- Omitted optional attributes keep default behavior and avoid unnecessary
  cache-key churn.
- For HTTP numeric overrides, `-1` means "do not pin here"; resolution falls
  back to environment overrides first, then the rule default.

## Multi-sync extension attributes

Extension tag: `test_optimization_multi_sync.test_optimization_multi_sync(...)`

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Aggregator repository name (examples use `test_optimization_data`) |
| `services` | string_list | required | Non-empty list of service names; one sync repo is created per service |
| `out_dir` | string | `.testoptimization` | Optional base output directory applied to each per-service sync repo |
| `runtime_name` | string | empty | Optional runtime name propagated to each per-service sync repo |
| `runtime_version` | string | empty | Optional runtime version propagated to each per-service sync repo |
| `runtime_arch` | string | auto-detected | Optional runtime arch propagated to each per-service sync repo |
| `http_connect_timeout_seconds` | int | `-1` attr / `10` effective | Optional connect-timeout override propagated to each per-service sync repo (`-1` keeps env/default behavior) |
| `http_max_time_seconds` | int | `-1` attr / `60` effective | Optional per-request max-time override propagated to each per-service sync repo (`-1` keeps env/default behavior) |
| `http_retry_attempts` | int | `-1` attr / `3` effective | Optional retry-attempt override propagated to each per-service sync repo (`-1` keeps env/default behavior) |
| `http_retry_delay_seconds` | int | `-1` attr / `2` effective | Optional retry-delay override propagated to each per-service sync repo (`-1` keeps env/default behavior) |
| `http_execute_timeout_buffer_seconds` | int | `-1` attr / `60` effective | Optional outer execute-timeout buffer override propagated to each per-service sync repo (`-1` keeps env/default behavior) |
| `known_tests` | bool | `True` | Known Tests kill-switch propagated to each per-service sync repo |
| `test_management` | bool | `True` | Test Management kill-switch propagated to each per-service sync repo |
| `debug` | bool | `False` | Enables verbose logging for generated per-service sync repos |

## Uploader rule attributes

Rule: `dd_payload_uploader(...)`

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Target name |
| `quiescent_sec` | int | `10` | Seconds to wait for filesystem to settle before uploading |
| `max_wait_sec` | int | `300` | Maximum seconds to wait for payloads (`0` skips waiting when no payloads are present) |
| `fail_on_error` | bool | `False` | Exit with error if no payloads found when tests ran |
| `debug` | bool | `False` | Enable debug logging |
| `keep_payloads` | bool | `False` | Keep payload files after successful upload |
| `filter_prefix` | bool | `False` | Only upload files matching `span_events_*.json` or `coverage_*.json` |
| `gzip_payloads` | bool | `False` | Gzip test payloads before upload |
| `data` | label_list | `[]` | Data files to include (for example, `context.json` for enrichment) |

## How data is fetched

The sync rule executes HTTP requests with timeouts/retries to:

- Settings:
  `https://api.<DD_SITE>/api/v2/libraries/tests/services/setting`
- Known Tests:
  `https://api.<DD_SITE>/api/v2/ci/libraries/tests`
- Test Management Tests:
  `https://api.<DD_SITE>/api/v2/test/libraries/test-management/tests`

Settings response attributes determine follow-up requests:

- `known_tests_enabled` -> triggers Known Tests
- `test_management.enabled` -> triggers Test Management Tests

If a feature is disabled, the rule still writes a minimal stub JSON for the
corresponding output file so consumers can always depend on stable filegroups.

## Environment variables

All variables in this section are declared in repository-rule `environ`, so
changes can invalidate fetch cache entries as expected.

### Primary inputs

| Variable | Required | Purpose |
|----------|----------|---------|
| `DD_API_KEY` | Yes | Datadog API key for metadata fetches |
| `DD_SITE` | No | Site domain (`datadoghq.com`, `datadoghq.eu`, etc.). Leading/trailing ASCII whitespace is trimmed; values like `app.<site>` normalize to `api.<site>` |
| `DD_TEST_OPTIMIZATION_AGENTLESS_URL` | No | Override sync API base URL (test/dev and mock-server scenarios) |
| `FETCH_SALT` | No | Manual refetch trigger (example: `--repo_env=FETCH_SALT=<timestamp>`) |
| `GO_MODULE_PATH` | No | Explicit Go module path override used when emitting `export.bzl` |
| `PYTHON_MODULE_PATH` | No | Explicit Python module path override used when emitting `export.bzl` |
| `JAVA_MODULE_PATH` | No | Explicit Java module path override used when emitting `export.bzl` |
| `NODEJS_MODULE_PATH` | No | Explicit NodeJS module path override used when emitting `export.bzl` |
| `DOTNET_MODULE_PATH` | No | Explicit .NET module path override used when emitting `export.bzl` |
| `RUBY_MODULE_PATH` | No | Explicit Ruby module path override used when emitting `export.bzl` |
| `DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS` | No | Sync connect-timeout override |
| `DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS` | No | Sync per-request max-time override |
| `DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS` | No | Sync retry-attempt override |
| `DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS` | No | Sync retry-delay override |
| `DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS` | No | Sync outer execute-timeout buffer override |

`DD_TEST_OPTIMIZATION_AGENTLESS_URL` is the shared direct URL override used by:
- Sync metadata requests (repository rule phase), and
- Agentless uploader intake requests (`bazel run //:dd_upload_payloads`).

Note: `FETCH_SALT_TTL` is a convenience variable for this repository's `./bazelw`
wrapper (not a repository-rule input itself). It periodically derives
`--repo_env=FETCH_SALT=...` for local maintainer workflows.

### Datadog Git metadata overrides (highest precedence)

When set, these override auto-detected CI/git metadata:

| Variable |
|----------|
| `DD_GIT_REPOSITORY_URL` |
| `DD_GIT_BRANCH` |
| `DD_GIT_COMMIT_SHA` |
| `DD_GIT_HEAD_COMMIT` |
| `DD_GIT_COMMIT_MESSAGE` |
| `DD_GIT_HEAD_MESSAGE` |

### CI provider detection coverage

Auto-detection currently maps CI metadata from:

- GitHub Actions
- GitLab CI
- Jenkins
- CircleCI
- Azure Pipelines
- Buildkite
- Travis CI
- Bitbucket
- AppVeyor
- TeamCity
- Bitrise
- Codefresh
- AWS CodeBuild
- Drone

Provider-name note: AWS CodeBuild is emitted as `awscodebuild` in sync
metadata (`ci.provider.name`).

Provider precedence note:
- explicit `DD_GIT_*` overrides win first;
- CI-provider environment detection is second;
- git CLI fallback (`git rev-parse`, `git log`, etc.) is last.

Additional mapped metadata inputs include:

- `APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH`
- `CI_PROJECT_PATH`
- `GITHUB_WORKFLOW`
- `TRAVIS_JOB_WEB_URL`
- `BUILD_URL`

## Uploader runtime environment variables

The uploader rule reads these variables at `bazel run` time:

| Variable | Purpose |
|----------|---------|
| `DD_API_KEY` | Required for agentless uploads |
| `DD_SITE` | Required for agentless uploads (intake host derivation) |
| `DD_TEST_OPTIMIZATION_AGENT_URL` | Enables EVP proxy mode |
| `DD_TEST_OPTIMIZATION_AGENTLESS_URL` | Optional agentless intake base override for test/dev setups |
| `DD_TEST_OPTIMIZATION_KEEP_PAYLOADS` | Keep payload files after successful upload |
| `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | `0` uploads all payloads; `1` restricts to `span_events_*.json` / `coverage_*.json` |
| `DD_TEST_OPTIMIZATION_DEBUG` | Enable verbose uploader logs |
| `DD_TEST_OPTIMIZATION_GZIP` | Gzip test payloads before upload |
| `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` | Override uploader max wait |
| `DD_TEST_OPTIMIZATION_QUIESCENT_SEC` | Override uploader quiescence wait |
| `DD_TEST_OPTIMIZATION_MAX_DEPTH` | Limit payload discovery depth in large trees |
| `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | Explicit CODEOWNERS path for enrichment |
| `TESTLOGS_DIR` | Explicit `bazel-testlogs` path for non-standard layouts |

Numeric precision caveat:
- Keep high-cardinality IDs (for example CI job IDs) as strings when possible.
  Some JSON tooling and runtimes may lose precision for integers above `2^53 - 1`.

## Integration harness environment variables (maintainer workflows)

These variables are used by repository integration harness scripts (not by the
sync repository rule or uploader runtime paths above):

- Linux/macOS harness supports existing shell env overrides documented in
  `tools/tests/integration/run_mock_server_tests.sh`.
- Windows harness is PowerShell-only; no Git Bash path override variable is used.
