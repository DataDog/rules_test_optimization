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

load("//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")
load("//tools:repositories.bzl", "dd_test_opt_repositories")

def _dd_sanitize_label_fragment(name):
    # Produce a safe suffix for Bazel target names from an arbitrary string.
    s = (name or "").lower()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
    out = []
    last_us = False
    n_s = len(s)
    for i in range(n_s):
        ch = s[i]
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
        # Optional: pass the exported `modules` dict from @<repo>//:export.bzl
        topt_data_modules = None,
        # Auto-select per-module known-tests/tmtests group based on Go package import path
        # You can override detection via module_importpath or go_module_path or module_label_override
        go_module_path = None,
        module_label_override = None,
        include_per_module_files = None,
        # Pass the rules_go go_test rule symbol from your BUILD file (e.g., go_test_rule = go_test)
        go_test_rule = None,
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
      sync_repo_name: External repo name where sync outputs live (used to form labels).
      topt_data_modules: The `modules` dict exported by the sync repo's export.bzl. When provided,
        this macro derives defaults for sync_repo_name, go_module_path, and include_per_module_files.
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

    # If caller provided the exported modules dict, derive defaults
    if topt_data_modules != None and type(topt_data_modules) == type({}):
        # Derive repo name
        _rn = topt_data_modules.get("repo_name")
        if _rn:
            sync_repo_name = _rn
        # Derive go module path
        _go = topt_data_modules.get("go") or {}
        if (go_module_path == None) and (type(_go) == type({})):
            _mp = _go.get("module_path")
            if _mp:
                go_module_path = _mp
        # Derive include_per_module_files when unset
        if include_per_module_files == None and (type(_go) == type({})):
            _inc = _go.get("module_included")
            if _inc != None:
                include_per_module_files = bool(_inc)

    # Default include_per_module_files to True if still unset
    if include_per_module_files == None:
        include_per_module_files = True

    # Build labels for files/context based on (possibly derived) sync_repo_name
    files_label = "@%s//:test_optimization_files" % sync_repo_name
    context_label = "@%s//:test_optimization_context" % sync_repo_name

    # Infer the Go package import path for the test's package
    # Precedence: go_test(importpath=...) > (go_module_path) + Bazel package > Bazel package
    pkg_path = native.package_name()
    inferred_importpath = None
    if "importpath" in kwargs and kwargs.get("importpath"):
        inferred_importpath = kwargs.get("importpath")
    elif go_module_path:
        base = go_module_path
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
    per_module_group = "@%s//:module_%s" % (sync_repo_name, module_suffix)

    if include_per_module_files:
        data.append(per_module_group)
    # Keep full files bundle as well for compatibility/convenience
    data.append(files_label)
    # Prepare env map: include runfiles-relative paths to the selected payload files
    user_env = kwargs.pop("env", {})
    env = dict(user_env)
    if include_per_module_files:
        env_value = "$(rlocationpaths %s)" % per_module_group
    else:
        env_value = "$(rlocationpaths %s)" % files_label
    env["TEST_OPTIMIZATION_PAYLOADS_FILES"] = env_value

    # Allow caller to inject rules_go's go_test symbol to avoid repo visibility issues
    _go_test = go_test_rule if go_test_rule != None else None
    if _go_test == None:
        fail("dd_topt_go_test: you must pass go_test_rule = go_test from @rules_go//go:def.bzl")

    _go_test(
        name = inner_name,
        data = data,
        env = env,
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


