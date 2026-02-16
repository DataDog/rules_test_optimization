"""Shared helpers for selecting per-module payload groups."""

load("//tools/core:common_utils.bzl", "sanitize_label_fragment")

def select_module_group_name(importpath, module_group_names, include_per_module, module_label_override = None):
    """Choose the per-module filegroup name for an identifier string.

    Returns an empty string when per-module selection is disabled or when no
    module_<sanitized> group matches.
    """
    if not include_per_module:
        return ""
    sanitized = module_label_override or sanitize_label_fragment(importpath or "")
    if not sanitized:
        return ""
    expected_name = "module_%s" % sanitized
    for name in module_group_names:
        if name == expected_name:
            return name
    return ""
