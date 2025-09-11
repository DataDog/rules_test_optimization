# Macro: dd_topt_go_test
#
# Wraps a rules_go `go_test` together with the Datadog payload uploader so you
# can run a single label. The macro creates three targets:
# - <name>_go: the underlying go_test
# - <name>_dd_upload_payloads: the uploader test
# - <name>: a test_suite including both of the above
#
# Notes
# - You must set up the sync repo once (via MODULE.bazel or WORKSPACE) so that
#   `@test_optimization_data//:test_optimization_*` labels exist.
# - Pass normal go_test attributes via **kwargs.
# - Use --sandbox_writable_path and --test_env=DD_PAYLOADS_DIR on the CLI.

load("@io_bazel_rules_go//go:def.bzl", "go_test")
load("@test_optimization_data//:go_module.bzl", "GO_MODULE_PATH")
load("//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")
load("//tools:repositories.bzl", "dd_test_opt_repositories")

def _dd_sanitize_label_fragment(name):
    # Produce a safe suffix for Bazel target names from an arbitrary string.
    s = (name or "").lower()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
    out = []
    last_us = False
    for ch in s:
        if ch in allowed:
            out.append(ch)
            last_us = (ch == "_")
        else:
            if not last_us:
                out.append("_")
                last_us = True
    # Trim leading/trailing underscores
    n = len(out)
    start = 0
    found = False
    for i in range(n):
        if out[i] != "_":
            start = i
            found = True
            break
    if not found:
        start = n
    end = 0
    for k in range(n):
        j = n - 1 - k
        if j < 0:
            break
        if out[j] != "_":
            end = j + 1
            break
    res = "".join(out[start:end])
    if not res:
        res = "module"
    return res

def dd_topt_go_test(
        name,
        # If you want this macro to auto-create the sync repo when missing,
        # set auto_sync_repo=True. In WORKSPACE mode this will call the
        # repository_rule; in Bzlmod it is a no-op and you should use the
        # MODULE.bazel extension as documented.
        auto_sync_repo = False,
        sync_repo_name = "test_optimization_data",
        context_label = "@test_optimization_data//:test_optimization_context",
        files_label = "@test_optimization_data//:test_optimization_files",
        # Auto-select per-module known-tests/tmtests group based on Go package import path
        # You can override detection via module_importpath or go_module_path or module_label_override
        go_module_path = None,
        module_label_override = None,
        include_per_module_files = True,
        # Uploader knobs
        payloads_dir = None,
        tests_subdir = "tests",
        coverage_subdir = "coverage",
        quiescent_sec = 10,
        max_wait_sec = 1800,
        fail_on_error = False,
        uploader_debug = False,
        uploader_tags = [],
        # Optional: tags attached to the suite target
        suite_tags = [],
        **kwargs):
    """Define a Go test bundled with the Datadog payload uploader.

    Args:
      name: Test suite name users will run (the macro creates <name> target).
      context_label: Label to context.json filegroup.
      files_label: Label to all fetched JSONs filegroup.
      payloads_dir/tests_subdir/coverage_subdir/quiescent_sec/max_wait_sec/fail_on_error/uploader_debug:
        Uploader rule configuration.
      uploader_tags: Extra tags applied to the uploader test.
      suite_tags: Tags applied to the generated test_suite.
      **kwargs: Forwarded to underlying go_test (e.g., srcs, deps, data, tags, ...).
    """

    # Optionally ensure the sync repository exists (WORKSPACE mode helper).
    if auto_sync_repo:
        # In WORKSPACE evaluation, this invokes the repository rule. In Bzlmod,
        # repository macros are ignored; users should rely on the module
        # extension instead.
        dd_test_opt_repositories(name = sync_repo_name)

    # 1) Underlying go_test (include fetched JSONs in runfiles for optional consumption)
    inner_name = name + "_go"
    user_data = kwargs.pop("data", [])
    data = list(user_data)

    # Infer the Go package import path for the test's package
    # Precedence: module_importpath arg > go_test(importpath=...) > (GO_MODULE_PATH or go_module_path) + Bazel package > Bazel package
    pkg_path = native.package_name()
    inferred_importpath = None
    if "importpath" in kwargs and kwargs.get("importpath"):
        inferred_importpath = kwargs.get("importpath")
    elif GO_MODULE_PATH or go_module_path:
        base = GO_MODULE_PATH if GO_MODULE_PATH else go_module_path
        # Normalize possible trailing slash
        if base.endswith("/"):
            base = base[:-1]
        if pkg_path:
            inferred_importpath = base + "/" + pkg_path
        else:
            inferred_importpath = base
    else:
        inferred_importpath = pkg_path

    # Compute sanitized suffix for the per-module filegroup
    module_suffix = module_label_override if module_label_override else _dd_sanitize_label_fragment(inferred_importpath)
    per_module_group = "@%s//:known_tests_module_%s" % (sync_repo_name, module_suffix)

    if include_per_module_files:
        data.append(per_module_group)
    # Keep full files bundle as well for compatibility/convenience
    data.append(files_label)
    go_test(
        name = inner_name,
        data = data,
        **kwargs
    )

    # 2) Uploader test (adds context.json to runfiles for enrichment)
    uploader_name = name + "_dd_upload_payloads"
    dd_payload_uploader_test(
        name = uploader_name,
        payloads_dir = payloads_dir,
        tests_subdir = tests_subdir,
        coverage_subdir = coverage_subdir,
        quiescent_sec = quiescent_sec,
        max_wait_sec = max_wait_sec,
        fail_on_error = fail_on_error,
        debug = uploader_debug,
        data = [context_label],
        tags = uploader_tags,
    )

    # 3) Suite aggregating both
    native.test_suite(
        name = name,
        tests = [":" + inner_name, ":" + uploader_name],
        tags = suite_tags,
    )


