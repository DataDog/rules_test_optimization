# Python Consumer Runner Mode

Use `runner_mode = "consumer_runner"` when the consumer repository already owns
the pytest launcher or wrapper policy.

## When To Use It

Use consumer-runner mode when any of these are true:

- The repository has a standard pytest wrapper that owns imports, tags, Docker,
  sharding, or flaky policy.
- The wrapper already sets repository-specific pytest arguments.
- The repository must avoid Datadog's bundled `run_pytest.py`.
- The repository does not allow synthetic `imports` in raw `py_test` targets.

Do not use consumer-runner mode to make a raw `py_test` execute a test file
directly. That shape can pass without actually running pytest or the ddtrace
plugin.

## Required Wrapper Behavior

The repository-owned wrapper must:

- Preserve the `env` dictionary passed by `dd_topt_py_test`.
- Run pytest, not a Python test file directly.
- Enable the ddtrace pytest plugin, normally with `PYTEST_ADDOPTS=--ddtrace`.
- Include `ddtrace` and `pytest` in the test dependencies.
- Keep the executable target compatible with Bazel runfiles.
- If `env` is configurable with `select(...)`, ensure every relevant branch
  preserves the Datadog environment and enables the ddtrace pytest plugin.

Recommended target shape:

```bzl
dd_topt_py_test(
    name = "pkg_py_test",
    py_test_rule = repo_pytest_wrapper,
    runner_mode = "consumer_runner",
    module_identifier = "example.python.pkg",
    srcs = glob(["test_*.py"]),
    deps = [
        ":pkg_lib",
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    topt_data = topt_data,
)
```

Prefer `module_identifier` in consumer-runner mode because the Datadog macro
does not need to synthesize Python imports to infer the module.

## Validation

After running the test, inspect outputs:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*/*.json" -type f | sort
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

If no JSON payloads exist, check the wrapper first. The most common mistake is
dropping the `env` supplied by the Datadog macro or launching Python directly
instead of pytest.
