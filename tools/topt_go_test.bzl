"""Macro: dd_topt_go_test.

Wraps a rules_go `go_test` with Datadog Test Optimization support. The macro
creates a single go_test target with the necessary environment variables and
data dependencies for test optimization.

Notes:
- You must set up the sync repo once (via MODULE.bazel or WORKSPACE) so that
  `@test_optimization_data//:test_optimization_*` labels exist.
- Pass normal go_test attributes via **kwargs.
- Payloads are written to TEST_UNDECLARED_OUTPUTS_DIR automatically.
- RBE users: ensure --remote_download_outputs=all is set.
- Import path inference mirrors rules_go behavior by walking `embed` via
  an aspect and reading the GoArchive provider; when unavailable, falls
  back to go_module_path + Bazel package path.
- Create ONE uploader target per workspace (see dd_payload_uploader in
  test_optimization_uploader.bzl) and run it via `bazel run` after tests.

Macro design constraints:
- This macro only wraps `go_test`; it does not create upload targets and does
  not alter workspace-level upload behavior.
- Runtime behavior must remain hermetic: tests write payloads to
  `TEST_UNDECLARED_OUTPUTS_DIR`; uploads happen in a separate `bazel run` step.
- Data selection should be predictable:
  - Prefer per-module payloads when importpath inference is available.
  - Fall back to full bundle safely when module matching is unavailable.

Maintenance notes:
- Keep this macro repository-agnostic by requiring `go_test_rule` injection.
- Avoid hardcoding labels outside values exported by `@<repo>//:export.bzl`.
- Preserve compatibility with both single-service (`topt_data`) and
  multi-service (`topt_data_by_service`) exports.
"""

load("//tools:topt_go_infer.bzl", "topt_go_payloads_selector")
load("//tools:common_utils.bzl", "sanitize_label_fragment")

def _is_dict(value):
    return type(value) == type({})

def _service_mapping_entries(topt_data):
    entries = {}
    for key, value in topt_data.items():
        if _is_dict(value) and value.get("repo_name"):
            entries[key] = value
    return entries

def _normalize_user_data(user_data):
    return list(user_data or [])

def _resolve_topt_service_key(service_entries, topt_service):
    keys = sorted(service_entries.keys())
    if topt_service == None:
        if len(keys) == 1:
            return keys[0]
        fail("dd_topt_go_test: topt_data looks like a multi-service mapping; please pass topt_service (one of: %s)" % ", ".join(keys))

    # Prefer exact key match first, then sanitized fallback.
    # This allows callers to pass explicit deduped keys such as "go_service_2".
    if service_entries.get(topt_service) != None:
        return topt_service

    sk = sanitize_label_fragment(topt_service)
    if service_entries.get(sk) != None:
        return sk

    fail("dd_topt_go_test: topt_service '%s' not found. Available: %s" % (topt_service, ", ".join(keys)))

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data

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
        **kwargs):
    """Define a Go test with Datadog Test Optimization support.

    This macro creates a single go_test target with the necessary environment
    variables for test optimization. Payloads are written to Bazel's
    TEST_UNDECLARED_OUTPUTS_DIR and collected in bazel-testlogs/<target>/test.outputs/.

    After running tests, use a single workspace-level uploader target to upload
    all payloads:
        bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

    Args:
      name: Test target name.
      topt_data: Either the single-service dict exported by @<repo>//:export.bzl, or the
        aggregator mapping (topt_data_by_service) exported by the multi-service repo.
        Used to derive the repo alias, go_module_path, and whether to include per-module files.
      go_test_rule: The rules_go go_test rule symbol (e.g., go_test from @rules_go//go:def.bzl).
        Required to avoid repo visibility issues.
      topt_service: Optional when passing the aggregator mapping; selects which service to use.
        Accepts raw or sanitized service key (e.g., "go-service" or "go_service").
        If sanitization collisions exist, pass the deduped key (for example "go_service_2").
      module_label_override: Optional override for the sanitized module label suffix when the
        automatic detection doesn't match the expected module name.
      **kwargs: Forwarded to underlying go_test (e.g., srcs, deps, data, tags, ...).
    """

    # Validate required topt_data early so failures surface at loading time.
    if topt_data == None or not _is_dict(topt_data):
        fail("dd_topt_go_test: topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping")

    # Support both shapes:
    # 1) Single-service dict with keys: repo_name, labels, set, go
    # 2) Aggregator mapping dict: { <svc_key>: single-service dict, ... }
    if topt_data.get("repo_name"):
        _svc = topt_data
    else:
        # Aggregator mapping: select service from service-shaped entries only.
        service_entries = _service_mapping_entries(topt_data)
        if not service_entries:
            fail("dd_topt_go_test: topt_data mapping did not contain any service entries")
        selected_key = _resolve_topt_service_key(service_entries, topt_service)
        _svc = service_entries[selected_key]

    # Prepare data dependencies
    user_data = kwargs.pop("data", None)
    data = _normalize_user_data(user_data)

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
        _inc = _go.get("module_included") if _is_dict(_go) else None
        if _inc != None:
            include_per_module_files = bool(_inc)

    # Build labels for files/context based on (possibly derived) sync_repo_name.
    # These labels remain stable public contracts of the generated sync repo.
    files_label = "@%s//:test_optimization_files" % sync_repo_name

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
        _mp = (_go.get("module_path") if _is_dict(_go) else None) or None
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

    # Data/env for the go test: depend only on the selector and use its runfiles.
    # This keeps go_test callsites simple while centralizing selection logic.
    data.append(":" + selector_name)

    # Add manifest file reference for deriving the working directory
    # Library can resolve this path and call filepath.Dir() to get the .testoptimization directory
    manifest_path = _svc.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (sync_repo_name, manifest_path)
    data.append(manifest_label)
    env["TEST_OPTIMIZATION_MANIFEST_FILE"] = "$(rlocationpath %s)" % manifest_label

    # Signal to the library that payloads should be written to files (TEST_UNDECLARED_OUTPUTS_DIR)
    # Always set - the library will write to TEST_UNDECLARED_OUTPUTS_DIR when this is true
    env["TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"

    # Allow caller to inject rules_go's go_test symbol to avoid repo visibility issues
    _go_test = go_test_rule if go_test_rule != None else None
    if _go_test == None:
        fail("dd_topt_go_test: you must pass go_test_rule = go_test from @rules_go//go:def.bzl")

    # Use the package directory as the default runtime working directory when
    # callers do not specify one. This keeps relative fixture paths stable.
    if "rundir" not in kwargs:
        kwargs["rundir"] = native.package_name()

    # Create ONLY the go_test - NO uploader, NO test_suite.
    # Users must create ONE uploader target per workspace and run it via `bazel run`.
    _go_test(
        name = name,
        data = data,
        env = env,
        **kwargs
    )
