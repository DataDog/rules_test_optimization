# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Shared helpers for selecting per-module payload groups.

Maintainers:
- Core-owned helper shared by language companion modules.
- Keep this file dependency-light and free of language-specific provider loads.
"""

load("//tools/core:common_utils.bzl", "fail_with_prefix", "sanitize_label_fragment")

def _fail_missing_module_group(expected_name, module_group_names, importpath, module_label_override, failure_context):
    """Fail with actionable diagnostics for explicit module-selection mismatches."""
    available = ", ".join(sorted(module_group_names)) if module_group_names else "<none>"
    if module_label_override:
        msg = (
            "module_label_override '%s' resolved to '%s', but no matching module group exists. " +
            "Available module groups: %s"
        ) % (module_label_override, expected_name, available)
    else:
        msg = (
            "explicit module identifier '%s' resolved to '%s', but no matching module group exists. " +
            "Available module groups: %s"
        ) % (importpath or "", expected_name, available)
    fail_with_prefix(failure_context or "topt_selection_utils", msg)

def select_module_group_name(
        importpath,
        module_group_names,
        include_per_module,
        module_label_override = None,
        fail_on_miss = False,
        failure_context = ""):
    """Choose the per-module filegroup name for an identifier string.

    Returns an empty string when per-module selection is disabled or when no
    module_<sanitized> group matches.
    """
    if not include_per_module:
        return ""

    # Intentionally treat empty-string override as equivalent to no override so
    # historical callsites continue to fall back to importpath sanitization.
    sanitized = module_label_override or sanitize_label_fragment(importpath or "")
    if not sanitized:
        if fail_on_miss:
            _fail_missing_module_group(
                "",
                module_group_names,
                importpath,
                module_label_override,
                failure_context,
            )
        return ""
    expected_name = "module_%s" % sanitized
    for name in module_group_names:
        if name == expected_name:
            return name
    if fail_on_miss:
        _fail_missing_module_group(
            expected_name,
            module_group_names,
            importpath,
            module_label_override,
            failure_context,
        )
    return ""
