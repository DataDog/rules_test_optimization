# WORKSPACE Python Onboarding

Use this path when the consumer repository disables Bzlmod or still relies on
`WORKSPACE`.

## Inspect Before Editing

Collect these facts first:

- Existing `rules_python` repository name, commonly `rules_python`.
- Existing Python toolchain version.
- Existing `pip_parse` repository name, commonly `python_deps` or `pip`.
- Existing pytest wrapper macro, if any.
- Service name and Python runtime version for sync metadata.
- Runtime test targets that should emit payloads.
- Build-only controls that should not be listed as expected payload targets.
- Whether fetching this rules repository needs SSH git or authenticated archive
  access.
- A lightweight package for doctor/uploader targets, usually
  `//tools/test_optimization` in monorepos.

## Dependency Wiring

Declare the core repository first:

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)
```

For private/internal repositories, prefer SSH git fetch unless the Bazel
environment has authenticated archive access:

```bzl
git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "ssh://git@github.com/DataDog/rules_test_optimization.git",
)
```

An unauthenticated codeload archive can return `404` for a private repository
even when the commit exists.

Declare `rules_python` using the consumer repository's normal mirror policy. A
direct public pin for rules_python 1.7.0 looks like this:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_python",
    sha256 = "f609f341d6e9090b981b3f45324d05a819fd7a5a56434f849c761971ce2c47da",
    strip_prefix = "rules_python-1.7.0",
    urls = ["https://github.com/bazel-contrib/rules_python/releases/download/1.7.0/rules_python-1.7.0.tar.gz"],
)
```

Then use the public Datadog Python WORKSPACE helper:

```bzl
load("@datadog-rules-test-optimization//tools/python:workspace_repositories.bzl", "datadog_python_test_optimization_workspace_repositories")

datadog_python_test_optimization_workspace_repositories(
    rto_commit = "<published-main-commit>",
    rules_python_repo_name = "rules_python",
)
```

The helper declares only `datadog-rules-test-optimization-python`. It does not
declare `rules_python`, Python toolchains, `pip_parse`, `pytest`, `ddtrace`, or
lockfiles.

Use archive mode when the consumer fetch policy requires mirrored Datadog
archives:

```bzl
datadog_python_test_optimization_workspace_repositories(
    rto_commit = "",
    datadog_fetch = "archive",
    rules_python_repo_name = "rules_python",
    rto_archive_url = "<mirror-url>",
    rto_archive_sha256 = "<archive-sha256>",
    rto_archive_prefix = "rules_test_optimization-<commit-sha>",
)
```

## Python Toolchains And Dependencies

Keep Python setup in the consumer repository:

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

The lockfile must include `pytest` and `ddtrace`.

## Sync, Doctor, And Uploader

Instantiate sync with Python metadata:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    service = "<datadog-service>",
    runtime_name = "python",
    runtime_version = "3.12",
)
```

Add one logical doctor/uploader pair. Prefer a lightweight package in monorepos:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data",
    expected_targets = [
        "//path/to:python_test",
    ],
)
```

## Test Targets

Managed pytest mode:

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

Consumer-owned pytest wrapper mode:

```bzl
load("@python_deps//:requirements.bzl", "requirement")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load("//tools/build:py_test.bzl", "repo_py_test")

dd_topt_py_test(
    name = "pkg_py_test",
    py_test_rule = repo_py_test,
    runner_mode = "consumer_runner",
    module_identifier = "example.python.pkg",
    srcs = glob(["test_*.py"]),
    deps = [
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    topt_data = topt_data,
)
```

The wrapper must preserve the `env` passed by `dd_topt_py_test` and must run
pytest with the ddtrace plugin enabled.

## Snippet Generator

After the Python companion is available, the published bootstrap can print the
same shape without modifying files:

```bash
bazel run @datadog-rules-test-optimization-python//tools/dd_topt_py_bootstrap:dd_topt_py_bootstrap -- \
  --mode=workspace \
  --service=<datadog-service> \
  --runtime-version=3.12 \
  --runtime-module-path=example.python.pkg \
  --rto-commit=<published-main-commit> \
  --private-repo-fetch=ssh-git \
  --bazel-command=bazel
```

The generator does not add `FETCH_SALT` to normal snippets. Use
`--print-refresh-snippet` only when you intentionally want a separate metadata
refresh command.
