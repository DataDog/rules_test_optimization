# Configuration Reference

This page contains the full configuration and environment reference.

## Sync extension attributes

Extension tag: `test_optimization_sync.test_optimization_sync(...)`

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | External repository name to create (examples use `test_optimization_data`) |
| `out_dir` | string | `.testoptimization` | Base output directory. Must be a non-empty relative path; absolute paths and `..` traversal are rejected |
| `service` | string | `"unnamed-service"` or `DD_SERVICE` | Service name precedence: `service` attr > `DD_SERVICE` env > fallback |
| `runtime_name` | string | empty | Optional runtime name (example: `go`) |
| `runtime_version` | string | empty | Optional runtime version (example: `1.24.0`) |
| `runtime_arch` | string | auto-detected | Optional runtime arch; defaults to detected `os.architecture` |
| `known_tests` | bool | `True` | Local switch for Known Tests request. When `False`, request is skipped, a minimal stub is written, and settings are mutated to `known_tests_enabled=false` |
| `test_management` | bool | `True` | Local switch for Test Management request. When `False`, request is skipped, a minimal stub is written, and settings are mutated to `test_management.enabled=false` |
| `debug` | bool | `False` | Enables verbose repository-rule logging |

Notes:

- `manifest.txt` path is exported via `topt_data["manifest_path"]` and respects
  `out_dir`.
- Parent directories are created automatically for all output paths.
- Omitted optional attributes keep default behavior and avoid unnecessary
  cache-key churn.

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
| `DD_SITE` | No | Site domain (`datadoghq.com`, `datadoghq.eu`, etc.). Values like `app.<site>` normalize to `api.<site>` |
| `FETCH_SALT` | No | Manual refetch trigger (example: `--repo_env=FETCH_SALT=<timestamp>`) |
| `GO_MODULE_PATH` | No | Explicit Go module path override used when emitting `export.bzl` |

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

Additional mapped metadata inputs include:

- `APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH`
- `CI_PROJECT_PATH`
- `GITHUB_WORKFLOW`
- `TRAVIS_JOB_WEB_URL`
- `BUILD_URL`
