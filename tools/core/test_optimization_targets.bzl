"""Convenience macro for workspace-level Test Optimization targets.

Consumer workspaces need one logical doctor/uploader pair after tests complete:
the doctor validates local payload outputs, and the uploader enriches and sends
those outputs. This helper keeps that wiring consistent while allowing the
targets to live in a lightweight package instead of forcing monorepos to place
them in the workspace root package.
"""

load("//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

_DOCTOR_CONTROLLED_ATTRS = ["name", "data", "expected_targets"]
_UPLOADER_CONTROLLED_ATTRS = ["name", "data"]

def _copy_kwargs(kwargs, label):
    """Return a defensive copy of optional keyword arguments."""
    if kwargs == None:
        return {}
    if type(kwargs) != type({}):
        fail("dd_test_optimization_targets: %s must be a dict when provided" % label)
    return dict(kwargs)

def _validate_non_empty_string(value, field_name):
    """Validate that a public string field is present and non-empty."""
    if type(value) != type("") or not value.strip():
        fail("dd_test_optimization_targets: %s must be a non-empty string" % field_name)

def _validate_no_controlled_attrs(kwargs, controlled_attrs, field_name):
    """Reject kwargs that would overwrite attrs owned by this helper."""
    forbidden = []
    for attr_name in controlled_attrs:
        if attr_name in kwargs:
            forbidden.append(attr_name)
    if forbidden:
        fail(
            (
                "dd_test_optimization_targets: %s cannot override controlled attrs %s. " +
                "Set doctor_name, uploader_name, context_data, or expected_targets on " +
                "dd_test_optimization_targets(...) instead."
            ) % (field_name, forbidden),
        )

def _build_test_optimization_target_specs(
        name,
        sync_repo_name,
        doctor_name,
        uploader_name,
        expected_targets,
        context_data,
        doctor_kwargs,
        uploader_kwargs):
    """Build normalized doctor/uploader attrs without materializing rules.

    Args:
      name: Logical helper name used only in diagnostics.
      sync_repo_name: Repository name that exposes `:test_optimization_context`.
      doctor_name: Target name for the generated doctor rule.
      uploader_name: Target name for the generated uploader rule.
      expected_targets: Labels the doctor should require local outputs for.
      context_data: Optional explicit data labels for context files.
      doctor_kwargs: Extra attrs forwarded to `dd_test_optimization_doctor`.
      uploader_kwargs: Extra attrs forwarded to `dd_payload_uploader`.

    Returns:
      A struct with `doctor_attrs` and `uploader_attrs` dictionaries.
    """
    _validate_non_empty_string(name, "name")
    _validate_non_empty_string(sync_repo_name, "sync_repo_name")
    _validate_non_empty_string(doctor_name, "doctor_name")
    _validate_non_empty_string(uploader_name, "uploader_name")
    if doctor_name == uploader_name:
        fail(
            (
                "dd_test_optimization_targets: doctor_name and uploader_name must be " +
                "different target names, got %r"
            ) % doctor_name,
        )

    normalized_context_data = context_data
    if normalized_context_data == None:
        normalized_context_data = ["@%s//:test_optimization_context" % sync_repo_name]

    normalized_doctor_kwargs = _copy_kwargs(doctor_kwargs, "doctor_kwargs")
    normalized_uploader_kwargs = _copy_kwargs(uploader_kwargs, "uploader_kwargs")
    _validate_no_controlled_attrs(normalized_doctor_kwargs, _DOCTOR_CONTROLLED_ATTRS, "doctor_kwargs")
    _validate_no_controlled_attrs(normalized_uploader_kwargs, _UPLOADER_CONTROLLED_ATTRS, "uploader_kwargs")

    doctor_attrs = dict(normalized_doctor_kwargs)
    doctor_attrs.update({
        "name": doctor_name,
        "data": normalized_context_data,
        "expected_targets": expected_targets,
    })

    uploader_attrs = dict(normalized_uploader_kwargs)
    uploader_attrs.update({
        "name": uploader_name,
        "data": normalized_context_data,
    })

    return struct(
        doctor_attrs = doctor_attrs,
        uploader_attrs = uploader_attrs,
    )

build_test_optimization_target_specs_for_tests = _build_test_optimization_target_specs

def dd_test_optimization_targets(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "dd_test_optimization_doctor",
        uploader_name = "dd_upload_payloads",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = None):
    """Create the standard doctor and uploader targets for one workspace.

    The macro can be called from a small package such as
    `//tools/test_optimization`, which avoids forcing large monorepos to load
    their root package just to run validation or upload.
    """
    specs = _build_test_optimization_target_specs(
        name = name,
        sync_repo_name = sync_repo_name,
        doctor_name = doctor_name,
        uploader_name = uploader_name,
        expected_targets = expected_targets,
        context_data = context_data,
        doctor_kwargs = doctor_kwargs,
        uploader_kwargs = uploader_kwargs,
    )
    dd_test_optimization_doctor(**specs.doctor_attrs)
    dd_payload_uploader(**specs.uploader_attrs)
