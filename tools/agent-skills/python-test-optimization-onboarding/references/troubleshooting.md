# Python Troubleshooting

## No JSON Payloads

Check the test outputs first:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*/*.json" -type f | sort
```

If no files appear:

- Confirm the test target uses `dd_topt_py_test`.
- Confirm the target depends on `pytest` and `ddtrace`.
- Confirm managed pytest mode did not receive `PYTEST_ADDOPTS=--no-ddtrace`.
- In `consumer_runner` mode, confirm the wrapper preserves `env` and runs
  pytest with the ddtrace plugin enabled.
- In WORKSPACE mode, confirm the Python companion was declared with
  `datadog_python_test_optimization_workspace_repositories(...)`.

## Missing Bazel Metadata

Check for metadata:

```bash
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

If it is missing, confirm the test target uses the companion macro and not the
raw language test rule directly. For consumer-owned wrappers, the wrapper must
return an executable test target while preserving the environment passed by the
Datadog macro.

## Missing Git Metadata

Git metadata is fetched during sync, not test execution. Put `DD_GIT_*` values
in `.bazelrc` or CI as `--repo_env`, not `--test_env`:

```text
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_GIT_BRANCH
```

The doctor can scan versioned `.bazelrc` files for `--test_env=DD_GIT_*`, but
it cannot detect a bad `--test_env=DD_GIT_*` flag typed directly on the CLI.

## WORKSPACE Helper Resolution Fails

Check ordering:

- `datadog-rules-test-optimization` must be declared before loading the Python
  helper from that repository.
- `rules_python` must be declared before loading the Python companion in test
  BUILD files.
- `rules_python_repo_name` must match the consumer's actual rules_python repo.

The Python helper only declares `datadog-rules-test-optimization-python`; it is
not a replacement for the consumer's Python dependency setup.

If fetching `datadog-rules-test-optimization` returns `404` in an internal or
private repository, confirm auth before changing the rule wiring. Prefer
`ssh://git@github.com/DataDog/rules_test_optimization.git` for internal git
fetches, or use an authenticated archive setup supported by the consumer's
Bazel environment. Do not commit local archive paths as a CI workaround.

## Monorepo Analysis Looks Unrelated

If tests already produced JSON payloads but doctor/uploader analysis downloads
unrelated toolchains or loads unrelated packages, the issue may be cold
monorepo state or target placement, not payload generation. Move the logical
doctor/uploader pair to a lightweight package such as `//tools/test_optimization`
and run those package-local labels before changing instrumentation.

If metadata refetches repeatedly, check whether `.bazelrc` or scripts set
`FETCH_SALT` by default. It should appear only in an explicit
`bazel sync --only=<repo> --repo_env=FETCH_SALT="$(date +%s)"` force-refresh
command.

## Remote Outputs Missing

If tests use remote execution or remote cache, add:

```text
test:test-optimization --remote_download_outputs=all
```

Then re-run tests before running doctor and uploader.
