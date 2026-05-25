<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Java Troubleshooting

## No JSON Payloads

Check the test outputs first:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*/*.json" -type f | sort
```

If no files appear:

- Confirm the test target uses `dd_topt_java_test`, either directly or through a
  repo-local wrapper.
- Confirm `agent_jar` points at an actual dd-java-agent JAR available in
  runfiles.
- Confirm the repository wrapper preserves `env`, `jvm_flags`, and `data`
  passed by `dd_topt_java_test`.
- Confirm no callsite also injects a competing `-javaagent` flag.
- Confirm the test process actually ran and was not a build-only target or a
  false-green wrapper.
- In WORKSPACE mode, confirm the Java companion was declared with
  `datadog_java_test_optimization_workspace_repositories(...)`.

## Missing Bazel Metadata

Check for metadata:

```bash
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

If it is missing, confirm the test target uses the companion macro and not the
raw Java test rule directly. For consumer-owned wrappers, the wrapper must
return an executable test target while preserving the environment, data, and JVM
flags passed by the Datadog macro.

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

- `datadog-rules-test-optimization` must be declared before loading the Java
  helper from that repository.
- `rules_java` must be declared before loading the Java companion in test BUILD
  files.
- `rules_java_repo_name` must match the consumer's actual rules_java repo.

The Java helper only declares `datadog-rules-test-optimization-java`; it is not
a replacement for the consumer's Java toolchain or Maven dependency setup.

If fetching `datadog-rules-test-optimization` returns `404` in an internal or
private repository, confirm auth before changing the rule wiring. Prefer
`ssh://git@github.com/DataDog/rules_test_optimization.git` for internal git
fetches, or use an authenticated archive setup supported by the consumer's
Bazel environment. Do not commit local archive paths as a CI workaround.

## Agent Jar Resolution Fails

`dd_topt_java_test` requires `agent_jar`. The label should resolve to a single
dd-java-agent JAR or to the repository's established file target for that JAR.
For local development, a local repository or filegroup is fine, but CI should
use a pinned artifact source that matches the consumer repository's dependency
policy.

If the test binary starts but the JVM rejects the agent path, confirm runfiles
are enabled on platforms that need them. Windows consumers should add:

```text
build --enable_runfiles
```

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
