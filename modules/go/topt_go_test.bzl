"""Macro: dd_topt_go_test.

Wraps a rules_go `go_test` with Datadog Test Optimization support and
Orchestrion-backed compile-time instrumentation.

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
- This macro creates a hidden raw `go_test` plus a public wrapper target.
- It does not create upload targets and does not alter workspace-level upload
  behavior.
- Runtime behavior must remain hermetic: tests write payloads to
  `TEST_UNDECLARED_OUTPUTS_DIR`; uploads happen in a separate `bazel run` step.
- Data selection should be predictable:
  - Prefer per-module payloads when importpath inference is available.
  - Fall back to full bundle safely when module matching is unavailable.

Maintenance notes:
- This file belongs to the Go companion module and should be the only macro
  surface depending on rules_go behavior.
- Keep this macro repository-agnostic by requiring `go_test_rule` injection.
- Avoid hardcoding labels outside values exported by `@<repo>//:export.bzl`.
- Preserve compatibility with both single-service (`topt_data`) and
  multi-service (`topt_data_by_service`) exports.
- Keep macro contracts aligned with `//tests:test_macro.bzl`, which validates
  env/data wiring, default/custom rundir behavior, and multi-service
  service-key resolution.
"""

load(
    "@datadog-rules-test-optimization//tools/core:common_utils.bzl",
    "fail_with_prefix",
)
load(
    "@datadog-rules-test-optimization//tools/core:topt_macro_utils.bzl",
    "append_data_dependencies",
    "build_module_labels",
    "merge_user_env",
    "normalize_user_data",
    "resolve_topt_service_key",
    "service_mapping_entries",
    _is_dict = "is_dict",
)
load("//:topt_go_infer.bzl", "topt_go_payloads_selector")
load("//:topt_go_orchestrion.bzl", "orch_go_test")

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data
_append_data_dependencies = append_data_dependencies
_merge_user_env = merge_user_env

def _resolve_topt_service_key(service_entries, topt_service):
    """Implement resolve topt service key behavior."""
    return resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_go_test")

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data

def _build_module_labels(sync_repo_name, labels):
    """Implement build module labels behavior."""
    return build_module_labels(sync_repo_name, labels, macro_name = "dd_topt_go_test")

build_module_labels_for_tests = _build_module_labels

_WRAPPER_ONLY_ATTRS = [
    "flaky",
    "local",
    "shard_count",
    "size",
    "tags",
    "timeout",
    "visibility",
]

_SHARED_TEST_ATTRS = [
    "compatible_with",
    "exec_compatible_with",
    "restricted_to",
    "target_compatible_with",
    "testonly",
]

def _extract_wrapper_kwargs(kwargs):
    """Split macro kwargs between raw go_test and public wrapper."""
    wrapper_kwargs = {}
    raw_passthrough = {}

    for key in _WRAPPER_ONLY_ATTRS:
        if key in kwargs:
            wrapper_kwargs[key] = kwargs.pop(key)

    for key in _SHARED_TEST_ATTRS:
        if key in kwargs:
            value = kwargs.pop(key)
            wrapper_kwargs[key] = value
            raw_passthrough[key] = value

    return wrapper_kwargs, raw_passthrough

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

    This macro creates a hidden raw go_test target plus a public
    Orchestrion-enabled wrapper target. Payloads are written to Bazel's
    TEST_UNDECLARED_OUTPUTS_DIR and collected in bazel-testlogs/<target>/test.outputs/.

    After running tests, use a single workspace-level uploader target to upload
    all payloads:
        bazel test //... || test_status=$?; test_status=${test_status:-0}; DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads; exit $test_status

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

    # ------------------------------------------------------------------
    # Phase 1: Validate + select service payload metadata.
    # ------------------------------------------------------------------
    # Validate required topt_data early so failures surface at loading time.
    if topt_data == None or not _is_dict(topt_data):
        fail_with_prefix("dd_topt_go_test", "topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping")

    # Support both shapes:
    # 1) Single-service dict with keys: repo_name, labels, set, runtimes
    # 2) Aggregator mapping dict: { <svc_key>: single-service dict, ... }
    if topt_data.get("repo_name"):
        # Single-service shape: caller already selected the service by choosing
        # this exported dict, so no key resolution is needed.
        _svc = topt_data
    else:
        # Aggregator mapping: select service from service-shaped entries only.
        service_entries = _service_mapping_entries(topt_data)
        if not service_entries:
            fail_with_prefix("dd_topt_go_test", "topt_data mapping did not contain any service entries")

        # Explicit `topt_service` is resolved via exact-then-sanitized matching
        # to preserve collision-safe keys while still accepting ergonomic input.
        selected_key = _resolve_topt_service_key(service_entries, topt_service)
        _svc = service_entries[selected_key]

    wrapper_kwargs, raw_passthrough = _extract_wrapper_kwargs(kwargs)

    # ------------------------------------------------------------------
    # Phase 2: Collect caller-provided inputs that we augment downstream.
    # ------------------------------------------------------------------
    # Prepare data dependencies
    # Use `pop` so caller kwargs forwarded to go_test do not contain stale
    # `data` after we normalize/augment it below.
    user_data = kwargs.pop("data", None)
    data = _append_data_dependencies(user_data, [])

    # Extract hints for importpath detection
    explicit_importpath = kwargs.get("importpath") if "importpath" in kwargs else None
    embed_labels = (kwargs.get("embed", []) or [])

    # ------------------------------------------------------------------
    # Phase 3: Compute selection strategy and labels for payload files.
    # ------------------------------------------------------------------
    # If caller provided the exported service dict, derive defaults
    include_per_module_files = False

    # Resolve sync repo name from selected service
    sync_repo_name = _svc.get("repo_name")
    if not sync_repo_name:
        fail_with_prefix("dd_topt_go_test", "selected topt_data entry is missing required 'repo_name'")

    # Decide whether to include per-module files:
    # - When inferring (explicit importpath or embed provided), always attempt per-module selection
    # - When falling back to go.mod + Bazel package, gate by
    #   topt_data["runtimes"]["go"]["module_included"].
    _runtimes = _svc.get("runtimes") or {}
    _go = _runtimes.get("go") if _is_dict(_runtimes) else {}
    if not _is_dict(_go):
        _go = {}
    uses_inference = bool(explicit_importpath) or bool(embed_labels)
    if uses_inference:
        # When we can infer importpath, always allow per-module selection.
        # Missing module matches still safely fall back in selector rule.
        include_per_module_files = True
    else:
        _inc = _go.get("module_included") if _is_dict(_go) else None
        if _inc != None:
            # In fallback mode, `module_included` acts as a coarse gate derived
            # from sync metadata rather than analysis-time provider information.
            include_per_module_files = bool(_inc)
        else:
            # Keep fallback behavior practical for older exports that omit the
            # coarse gate but still expose per-module labels.
            include_per_module_files = bool(_svc.get("labels"))

    # Build labels for files/context based on (possibly derived) sync_repo_name.
    # These labels remain stable public contracts of the generated sync repo.
    files_label = "@%s//:test_optimization_files" % sync_repo_name

    # ------------------------------------------------------------------
    # Phase 4: Build environment and selector inputs for analysis-time mapping.
    # ------------------------------------------------------------------
    # Prepare env map using a selector rule that infers importpath via aspect
    # Same `pop` pattern keeps final go_test kwargs clean and explicit.
    user_env = kwargs.pop("env", None)

    # Build the list of per-module groups once (if any were exported)
    # Use exported sanitized labels directly to avoid re-deriving naming policy
    # in the macro and drifting from sync-side label generation.
    module_labels = _build_module_labels(sync_repo_name, _svc.get("labels"))

    # Fallback importpath when providers are unavailable: go_module_path + Bazel package
    pkg_path = native.package_name()
    fallback_importpath = None
    if explicit_importpath:
        # Explicit importpath is authoritative and mirrors rules_go semantics.
        fallback_importpath = explicit_importpath
    else:
        _mp = (_go.get("module_path") if _is_dict(_go) else None) or None
        if _mp:
            # Build module-relative fallback importpath: "<go_module>/<pkg>".
            # Trim trailing slash to avoid accidental double separators.
            base = _mp[:-1] if _mp.endswith("/") else _mp
            fallback_importpath = (base + "/" + pkg_path) if pkg_path else base
        else:
            # Last resort: package path only, still sufficient for best-effort
            # module label matching when repo metadata is incomplete.
            fallback_importpath = pkg_path

    selector_name = name + "_topt_payloads"

    # Selector encapsulates importpath inference + module fallback in analysis
    # phase, keeping runtime logic and user callsites simple.
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

    # ------------------------------------------------------------------
    # Phase 5: Wire selector + manifest into go_test runfiles and environment.
    # ------------------------------------------------------------------
    # Data/env for the go test: depend only on the selector and use its runfiles.
    # This keeps go_test callsites simple while centralizing selection logic.
    data = _append_data_dependencies(data, [":" + selector_name])

    # Add manifest file reference for deriving the working directory.
    # Keep this dynamic via export metadata so custom out_dir values continue
    # to work without macro changes.
    # Library can resolve this path and call filepath.Dir() to get the
    # directory containing manifest + cached metadata files.
    # manifest_path is emitted by sync metadata and may include slashes.
    # These paths are rooted at the sync repo package, so target syntax remains
    # @repo//:<path> (for example @test_optimization_data//:.testoptimization/manifest.txt).
    manifest_path = _svc.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (sync_repo_name, manifest_path)
    data = _append_data_dependencies(data, [manifest_label])
    env = _merge_user_env(
        user_env,
        {
            "DD_TEST_OPTIMIZATION_MANIFEST_FILE": "$(rlocationpath %s)" % manifest_label,
            # Signal to the library that payloads should be written to files
            # (TEST_UNDECLARED_OUTPUTS_DIR) regardless of caller input.
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "true",
        },
        macro_name = "dd_topt_go_test",
    )

    # Allow caller to inject rules_go's go_test symbol to avoid repo visibility issues
    # Keeping this explicit avoids hidden repository dependencies in the macro.
    if go_test_rule == None:
        fail_with_prefix("dd_topt_go_test", "you must pass go_test_rule = go_test from @rules_go//go:def.bzl")

    # Use the package directory as the default runtime working directory when
    # callers do not specify one. This keeps relative fixture paths stable.
    if "rundir" not in kwargs:
        kwargs["rundir"] = native.package_name()

    raw_name = name + "__raw_go_test"
    user_tags = wrapper_kwargs.get("tags")
    kwargs["tags"] = (user_tags or []) + ["manual"]
    kwargs["visibility"] = ["//visibility:private"]
    for key, value in raw_passthrough.items():
        kwargs[key] = value

    # Create the hidden raw go_test first, then expose it through an
    # Orchestrion-enabled public wrapper target.
    go_test_rule(
        name = raw_name,
        data = data,
        env = env,
        **kwargs
    )

    orch_go_test(
        name = name,
        actual = ":" + raw_name,
        **wrapper_kwargs
    )
