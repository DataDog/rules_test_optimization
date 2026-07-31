<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

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

In a manifest-managed monorepo, the public central wrapper first computes its
full label and looks it up in `topt_data_by_target`. If absent, call the
comparison-base consumer runner exactly as before. If present, pass that entry
to `dd_topt_py_test` with `runner_mode = "consumer_runner"` and the same
repository-owned runner. Do not replace the existing runner merely to support
automatic service selection.

Recommended target shape:

```bzl
dd_topt_py_test(
    name = "pkg_py_test",
    py_test_rule = repo_pytest_wrapper,
    runner_mode = "consumer_runner",
    srcs = glob(["test_*.py"]),
    deps = [
        ":pkg_lib",
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    topt_data = topt_data,
)
```

When the runtime module path and Bazel package path identify the test, omit
`module_identifier` and use the derived fallback. Keep an explicit
`module_identifier` only for a documented repository-specific exception; the
Datadog macro does not need to synthesize Python imports for the normal path.
Derived or inferred misses may use the canonical full bundle. An explicit
`module_identifier` or `module_label_override` must match a module group when
synchronized metadata exposes groups, or analysis fails. When no groups exist,
the canonical full bundle remains valid.

## Validation

After running the test, inspect outputs:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*/*.json" -type f | sort
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

If no JSON payloads exist, check the wrapper first. The most common mistake is
dropping the `env` supplied by the Datadog macro or launching Python directly
instead of pytest.
