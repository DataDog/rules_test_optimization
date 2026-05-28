# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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
- Default to rules_go's `go_test`; keep `go_test_rule` only as an optional
  override for tests and low-level experiments.
- Keep organization-local policy wrappers outside this macro. Wrappers that
  need public-target parity for tags, flaky companions, scheduling policy, or
  similar repository-specific behavior must wrap `dd_topt_go_test` externally
  instead of passing a custom wrapper via `go_test_rule`.
- Keep nested-package Orchestrion pinning explicit. Package-local pin files are
  auto-staged when they live next to the BUILD file, while module-root pin
  files for nested packages should be passed through `orchestrion_pin_files`.
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
    "merge_optional_env_defaults",
    "merge_user_env",
    "normalize_user_data",
    "resolve_topt_service_key",
    "service_mapping_entries",
    "split_test_wrapper_kwargs",
    _is_dict = "is_dict",
)
load("@rules_go//go:def.bzl", "go_test")
load("@rules_go//go/private/orchestrion:pin_files.bzl", _orchestrion_pin_files = "orchestrion_pin_files")
load("//:topt_go_infer.bzl", "topt_go_bazel_metadata", "topt_go_payloads_selector")
load("//:topt_go_orchestrion.bzl", "orch_go_test")

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data
_append_data_dependencies = append_data_dependencies
_merge_optional_env_defaults = merge_optional_env_defaults
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

_ORCHESTRION_PIN_FILES = [
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
]
_ORCHESTRION_MODE_GENERAL = "general"
_ORCHESTRION_MODE_TEST_OPTIMIZATION = "test_optimization"
_ORCHESTRION_MODES = {
    _ORCHESTRION_MODE_GENERAL: None,
    _ORCHESTRION_MODE_TEST_OPTIMIZATION: None,
}

def _attr_or_default(value, default):
    """Return a Starlark attr value or a default without forcing truthiness."""
    return default if value == None else value

def _has_package_local_go_mod(package_local_orchestrion_pin_files):
    """Return whether auto-discovered package-local pin files include go.mod."""
    return "go.mod" in package_local_orchestrion_pin_files

has_package_local_go_mod_for_tests = _has_package_local_go_mod

def _concat_label_list_values(left, right):
    """Concatenate label-list-like macro inputs while preserving `select(...)`."""
    normalized_left = _normalize_user_data(left)
    normalized_right = _normalize_user_data(right)

    if normalized_left == None:
        return normalized_right
    if normalized_right == None:
        return normalized_left
    if normalized_left == []:
        return normalized_right
    if normalized_right == []:
        return normalized_left

    return normalized_left + normalized_right

def dd_topt_go_test(
        name,
        # Required: pass the exported `modules` dict from @<repo>//:export.bzl
        topt_data,
        # Optional override for tests or low-level experiments. Defaults to rules_go's go_test.
        go_test_rule = go_test,
        # Optional: when using the multi-service aggregator, select the service
        # (raw or sanitized). Ignored when a single-service dict is passed.
        topt_service = None,
        # Auto-select per-module known_tests/test_management group based on Go package import path
        module_label_override = None,
        # Optional: stage direct test sources in runtime runfiles so dd-trace-go
        # can open them for AST-derived metadata such as test.source.end.
        stage_sources = False,
        # Enable CI Visibility in opt-in Go tests by default so payload-to-files
        # mode works without extra test_env wiring in consumer repos.
        ci_visibility_enabled = True,
        # Optional module-root Orchestrion pin file labels for nested packages.
        orchestrion_pin_files = None,
        # Experimental Orchestrion mode used by the Datadog rules_go fork.
        experimental_orchestrion_mode = _ORCHESTRION_MODE_GENERAL,
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
      go_test_rule: Optional override for the underlying rules_go go_test rule.
        Defaults to `go_test` from `@rules_go//go:def.bzl`. This hook is for
        tests and low-level experiments; repository policy wrappers should stay
        outside `dd_topt_go_test`.
      topt_service: Optional when passing the aggregator mapping; selects which service to use.
        Accepts raw or sanitized service key (e.g., "go-service" or "go_service").
        If sanitization collisions exist, pass the deduped key (for example "go_service_2").
      module_label_override: Optional override for the sanitized module label suffix when the
        automatic detection doesn't match the expected module name.
      stage_sources: Optional boolean that stages direct `srcs` and `embedsrcs`
        into runtime runfiles so the tracer can open source files for
        AST-derived metadata. When enabled, the macro defaults `rundir` to `.`
        only if the caller did not already set `rundir`.
      ci_visibility_enabled: Optional boolean. When true, the macro forces
        `DD_CIVISIBILITY_ENABLED=true` on the generated test environment.
        Set false only when the caller intentionally owns this tracer switch.
      orchestrion_pin_files: Optional labels for module-root Orchestrion pin
        files such as `//:go.mod`, `//:go.sum`, `//:orchestrion.tool.go`, and
        `//:orchestrion.yml`. Use this when the BUILD file lives in a nested
        package below the Go module root. In `test_optimization` mode, explicit
        labels are required unless the BUILD package itself contains `go.mod`;
        the optimized action graph keeps only the effective pin inputs while
        preserving normal runtime data for the test.
      experimental_orchestrion_mode: Experimental Orchestrion mode. Defaults
        to `general`, which preserves the current behavior. Set to
        `test_optimization` to use the standard Go `testing` Test Optimization
        path: stdlib/`testing` instrumentation, synthetic testmain helper
        wiring, and plain customer/external `_test` package compiles.
      **kwargs: Forwarded to underlying go_test (e.g., srcs, deps, data, tags, ...).
    """

    # ------------------------------------------------------------------
    # Phase 1: Validate + select service payload metadata.
    # ------------------------------------------------------------------
    # Validate required topt_data early so failures surface at loading time.
    if topt_data == None or not _is_dict(topt_data):
        fail_with_prefix("dd_topt_go_test", "topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping")
    if experimental_orchestrion_mode not in _ORCHESTRION_MODES:
        fail_with_prefix("dd_topt_go_test", "experimental_orchestrion_mode must be one of %s" % ", ".join(sorted(_ORCHESTRION_MODES.keys())))

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

    wrapper_kwargs, raw_passthrough = split_test_wrapper_kwargs(kwargs)

    # ------------------------------------------------------------------
    # Phase 2: Collect caller-provided inputs that we augment downstream.
    # ------------------------------------------------------------------
    # Prepare data dependencies
    # Use `pop` so caller kwargs forwarded to go_test do not contain stale
    # `data` after we normalize/augment it below.
    user_data = kwargs.pop("data", None)
    data = user_data

    # Stage direct source files only when callers opt in. This gives the Go
    # tracer a runtime-visible path it can open for AST-derived source metadata.
    if stage_sources:
        data = _concat_label_list_values(data, kwargs.get("srcs"))
        data = _concat_label_list_values(data, kwargs.get("embedsrcs"))

    data = _append_data_dependencies(data, [])

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

    # Default DD_SERVICE from sync metadata so the tracer does not fall back
    # to platform-specific executable names when callers omit the service.
    user_env = _merge_optional_env_defaults(
        user_env,
        {"DD_SERVICE": _svc.get("service_name")},
        macro_name = "dd_topt_go_test",
    )

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
    metadata_name = name + "_topt_bazel_metadata"

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

    # Emit a small Bazel-owned metadata file next to the built test artifacts.
    # The Orchestrion wrapper copies this into TEST_UNDECLARED_OUTPUTS_DIR so
    # the uploader can merge target-specific Bazel tags into emitted events.
    # The metadata rule cross-checks this request against the actual
    # `rules_go_orchestrion_tool` repository contents so omitted bootstrap
    # configuration does not produce a false positive.
    topt_go_bazel_metadata(
        name = metadata_name,
        embeds = embed_labels,
        explicit_importpath = explicit_importpath or "",
        fallback_importpath = fallback_importpath or "",
        module_groups = module_labels,
        include_per_module = include_per_module_files,
        module_label_override = module_label_override or "",
        orchestrion_mode = experimental_orchestrion_mode,
        bazel_package = "//%s" % pkg_path if pkg_path else "//",
        bazel_target = "//%s:%s" % (pkg_path, name) if pkg_path else "//:%s" % name,
        repo_name = sync_repo_name,
        service_name = _svc.get("service_name") or "",
        orchestrion_requested = True,
        cgo = _attr_or_default(kwargs.get("cgo"), False),
        pure = _attr_or_default(kwargs.get("pure"), "auto"),
        race = _attr_or_default(kwargs.get("race"), "auto"),
        msan = _attr_or_default(kwargs.get("msan"), "auto"),
        linkmode = _attr_or_default(kwargs.get("linkmode"), "auto"),
        goos = _attr_or_default(kwargs.get("goos"), ""),
        goarch = _attr_or_default(kwargs.get("goarch"), ""),
    )

    # ------------------------------------------------------------------
    # Phase 5: Wire selector + manifest into go_test runfiles and environment.
    # ------------------------------------------------------------------
    # Data/env for the go test: depend only on the selector and use its runfiles.
    # This keeps go_test callsites simple while centralizing selection logic.
    data = _append_data_dependencies(data, [
        ":" + selector_name,
        ":" + metadata_name,
    ])

    # Nested Go packages often keep the authoritative Orchestrion pin files at
    # the module root. Callers can pass those labels explicitly so the builder's
    # upward directory scan can still find the pinned module/config state.
    explicit_orchestrion_pin_files = _normalize_user_data(orchestrion_pin_files)
    if type(explicit_orchestrion_pin_files) == "select":
        fail_with_prefix("dd_topt_go_test", "orchestrion_pin_files does not support select(...) values")

    # Stage package-local Orchestrion pin files as hidden data inputs when the
    # caller keeps them next to the BUILD file that defines the test target.
    # The provider target lets the optimized mode keep only these pin files in
    # compile/link action inputs while preserving the same runtime data surface
    # for the raw go_test target.
    orchestrion_pin_inputs = []
    package_local_orchestrion_pin_files = native.glob(_ORCHESTRION_PIN_FILES, allow_empty = True)
    if package_local_orchestrion_pin_files:
        orchestrion_pin_inputs.extend(package_local_orchestrion_pin_files)
    if explicit_orchestrion_pin_files:
        orchestrion_pin_inputs.extend(explicit_orchestrion_pin_files)

    if (
        experimental_orchestrion_mode == _ORCHESTRION_MODE_TEST_OPTIMIZATION and
        not explicit_orchestrion_pin_files and
        not _has_package_local_go_mod(package_local_orchestrion_pin_files)
    ):
        fail_with_prefix(
            "dd_topt_go_test",
            (
                "experimental_orchestrion_mode = \"test_optimization\" requires a package-local " +
                "go.mod or explicit orchestrion_pin_files pointing at the Go module root " +
                "(for example //:go.mod, //:go.sum, //:orchestrion.tool.go, and //:orchestrion.yml)"
            ),
        )

    if experimental_orchestrion_mode == _ORCHESTRION_MODE_TEST_OPTIMIZATION and not orchestrion_pin_inputs:
        fail_with_prefix(
            "dd_topt_go_test",
            (
                "experimental_orchestrion_mode = \"test_optimization\" requires package-local " +
                "Orchestrion pin files or explicit orchestrion_pin_files so compile/link actions " +
                "can track the module state"
            ),
        )

    if orchestrion_pin_inputs:
        orchestrion_pin_target_name = name + "_orchestrion_pin_files"
        _orchestrion_pin_files(
            name = orchestrion_pin_target_name,
            srcs = orchestrion_pin_inputs,
        )
        data = _append_data_dependencies(data, [":" + orchestrion_pin_target_name])

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
    required_env = {
        "DD_TEST_OPTIMIZATION_MANIFEST_FILE": "$(rlocationpath %s)" % manifest_label,
        # Signal to the library that payloads should be written to files
        # (TEST_UNDECLARED_OUTPUTS_DIR) regardless of caller input.
        "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "true",
        # The Orchestrion wrapper copies this file into test.outputs so the
        # uploader can enrich payloads with target-specific Bazel metadata.
        "DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME": metadata_name + ".json",
    }
    if ci_visibility_enabled:
        required_env["DD_CIVISIBILITY_ENABLED"] = "true"
    env = _merge_user_env(
        user_env,
        required_env,
        macro_name = "dd_topt_go_test",
    )

    if go_test_rule == None:
        fail_with_prefix("dd_topt_go_test", "go_test_rule override cannot be None")

    # Use the repository root when staged sources need repo-relative lookup.
    # Otherwise keep the package directory default to preserve existing tests.
    if "rundir" not in kwargs:
        kwargs["rundir"] = "." if stage_sources else native.package_name()

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
        orchestrion_mode = experimental_orchestrion_mode,
        **wrapper_kwargs
    )
