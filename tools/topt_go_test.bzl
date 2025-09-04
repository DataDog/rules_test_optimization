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
load("//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")
load("//tools:repositories.bzl", "dd_test_opt_repositories")

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
    data = list(user_data) + [files_label]
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


