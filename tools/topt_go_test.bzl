"""Macro: dd_topt_go_test.

Wraps a rules_go `go_test` together with the Datadog payload uploader so you
can run a single label. The macro creates three targets:
- <name>_go: the underlying go_test
- <name>_dd_upload_payloads: the uploader test
- <name>: a test_suite including both of the above

Notes:
- You must set up the sync repo once (via MODULE.bazel or WORKSPACE) so that
  `@test_optimization_data//:test_optimization_*` labels exist.
- Pass normal go_test attributes via **kwargs.
- Use --sandbox_writable_path and --test_env=TEST_OPTIMIZATION_PAYLOADS_DIR on the CLI.
- Import path inference mirrors rules_go behavior by walking `embed` via
  an aspect and reading the GoArchive provider; when unavailable, falls
  back to go_module_path + Bazel package path.
"""

load("//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")
load("//tools:topt_go_infer.bzl", "topt_go_payloads_selector")
load("//tools:common_utils.bzl", "sanitize_label_fragment")

def dd_topt_go_test(
        name,
        # Required: pass the exported `modules` dict from @<repo>//:export.bzl
        topt_data,
        # Required: pass the rules_go go_test rule symbol from your BUILD file (e.g., go_test_rule = go_test)
        go_test_rule,
        # Optional: when using the multi-service aggregator, select the service
        # (raw or sanitized). Ignored when a single-service dict is passed.
        topt_service = None,
        # Auto-select per-module known_tests/test_management group based on Go package import path
        module_label_override = None,
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
      topt_data: Either the single-service dict exported by @<repo>//:export.bzl, or the
        aggregator mapping (topt_data_by_service) exported by the multi-service repo.
        Used to derive the repo alias, go_module_path, and whether to include per-module files.
      go_test_rule: The rules_go go_test rule symbol (e.g., go_test from @rules_go//go:def.bzl).
        Required to avoid repo visibility issues.
      topt_service: Optional when passing the aggregator mapping; selects which service to use.
        Accepts raw or sanitized service key (e.g., "go-service" or "go_service").
      module_label_override: Optional override for the sanitized module label suffix when the
        automatic detection doesn't match the expected module name.
      payloads_dir: Optional absolute path to the payloads directory. If not set, uses
        TEST_OPTIMIZATION_PAYLOADS_DIR environment variable. Should match --sandbox_writable_path.
      tests_subdir: Subdirectory under payloads_dir for test payloads (default: "tests").
      coverage_subdir: Subdirectory under payloads_dir for coverage payloads (default: "coverage").
      quiescent_sec: Seconds to wait for directory quiescence before uploading (default: 10).
      max_wait_sec: Maximum seconds to wait before forcing upload (default: 1800).
      fail_on_error: Whether the uploader test should fail on upload errors (default: False).
      uploader_debug: Enable debug logging in the uploader test (default: False).
      uploader_tags: Extra tags applied to the uploader test target.
      suite_tags: Tags applied to the generated test_suite target.
      **kwargs: Forwarded to underlying go_test (e.g., srcs, deps, data, tags, ...).
    """

    # Validate required topt_data
    if topt_data == None or type(topt_data) != type({}):
        fail("dd_topt_go_test: topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping")

    # Support both shapes:
    # 1) Single-service dict with keys: repo_name, labels, set, go
    # 2) Aggregator mapping dict: { <svc_key>: single-service dict, ... }
    if topt_data.get("repo_name"):
        _svc = topt_data
    else:
        # Aggregator mapping: select service
        keys = [k for k in topt_data.keys()]
        if topt_service == None:
            if len(keys) == 1:
                _svc = topt_data[keys[0]]
            else:
                fail("dd_topt_go_test: topt_data looks like a multi-service mapping; please pass topt_service (one of: %s)" % ", ".join(sorted(keys)))
        else:
            # Try sanitized then raw
            sk = sanitize_label_fragment(topt_service)
            _svc = topt_data.get(sk)
            if _svc == None:
                _svc = topt_data.get(topt_service)
            if _svc == None:
                fail("dd_topt_go_test: topt_service '%s' not found. Available: %s" % (topt_service, ", ".join(sorted(keys))))

    # 1) Underlying go_test
    inner_name = name + "_go"
    user_data = kwargs.pop("data", [])
    data = list(user_data)

    # Extract hints for importpath detection
    explicit_importpath = kwargs.get("importpath") if "importpath" in kwargs else None
    embed_labels = (kwargs.get("embed", []) or [])

    # If caller provided the exported service dict, derive defaults
    include_per_module_files = False

    # Resolve sync repo name from selected service
    sync_repo_name = _svc.get("repo_name") or "test_optimization_data"

    # Decide whether to include per-module files:
    # - When inferring (explicit importpath or embed provided), always attempt per-module selection
    # - When falling back to go.mod + Bazel package, gate by modules.go.module_included
    _go = _svc.get("go") or {}
    uses_inference = bool(explicit_importpath) or bool(embed_labels)
    if uses_inference:
        include_per_module_files = True
    else:
        _inc = _go.get("module_included") if (type(_go) == type({})) else None
        if _inc != None:
            include_per_module_files = bool(_inc)

    # Build labels for files/context based on (possibly derived) sync_repo_name
    files_label = "@%s//:test_optimization_files" % sync_repo_name
    context_label = "@%s//:test_optimization_context" % sync_repo_name

    # Prepare env map using a selector rule that infers importpath via aspect
    user_env = kwargs.pop("env", {})
    env = dict(user_env)

    # Build the list of per-module groups once (if any were exported)
    module_labels = []
    _labels = _svc.get("labels") or []
    for lab in _labels:
        module_labels.append("@%s//:module_%s" % (sync_repo_name, lab))

    # Fallback importpath when providers are unavailable: go_module_path + Bazel package
    pkg_path = native.package_name()
    fallback_importpath = None
    if explicit_importpath:
        fallback_importpath = explicit_importpath
    else:
        _mp = (_go.get("module_path") if type(_go) == type({}) else None) or None
        if _mp:
            base = _mp[:-1] if _mp.endswith("/") else _mp
            fallback_importpath = (base + "/" + pkg_path) if pkg_path else base
        else:
            fallback_importpath = pkg_path

    selector_name = name + "_topt_payloads"
    topt_go_payloads_selector(
        name = selector_name,
        embeds = embed_labels,
        explicit_importpath = explicit_importpath,
        fallback_importpath = fallback_importpath,
        full_files = files_label,
        module_groups = module_labels,
        include_per_module = include_per_module_files,
        module_label_override = module_label_override,
    )

    # Data/env for the go test: depend only on the selector and use its runfiles
    data.append(":" + selector_name)

    # Add manifest file reference for deriving the working directory
    # Library can resolve this path and call filepath.Dir() to get the .testoptimization directory
    manifest_label = "@%s//:.testoptimization/manifest.txt" % sync_repo_name
    data.append(manifest_label)
    env["TEST_OPTIMIZATION_MANIFEST_FILE"] = "$(rlocationpath %s)" % manifest_label

    # Signal to the library that payloads should be written to files (not network)
    # Only set when payloads_dir is configured, meaning the user has set up file-based payloads
    if payloads_dir:
        env["TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"

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
