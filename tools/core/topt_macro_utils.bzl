"""Shared helpers for language-specific Test Optimization macros.

Maintainers:
- This is core-owned shared logic and must stay language-rule agnostic.
- Keep this file free from `rules_<lang>` imports; companion modules depend on
  core helpers, not the other way around.
"""

load(
    "//tools/core:common_utils.bzl",
    "sanitize_label_fragment",
    _is_dict = "is_dict",
    _is_list = "is_list",
    _is_string = "is_string",
)

is_dict = _is_dict
is_list = _is_list
is_string = _is_string

def service_mapping_entries(topt_data):
    """Extract service-shaped entries from an aggregator mapping.

    The multi-service export may contain helper/meta keys. A service entry is
    identified by a dict value that includes `repo_name`.

    Args:
      topt_data: Aggregator mapping exported by multi-service sync.

    Returns:
      Dict containing only service entries keyed by service selector.
    """
    entries = {}
    for key, value in topt_data.items():
        if is_dict(value) and value.get("repo_name"):
            entries[key] = value
    return entries

def normalize_user_data(user_data):
    """Normalize caller-provided `data` into a mutable list.

    Args:
      user_data: Value from macro `data` attribute (None/string/list/tuple).

    Returns:
      Mutable list of labels suitable for downstream augmentation.
    """
    if user_data == None:
        return []

    # A single label can be passed as a string; keep it atomic.
    if is_string(user_data):
        return [user_data]
    if is_list(user_data):
        return list(user_data)
    fail("normalize_user_data: expected None, string, list, or tuple; got %s" % type(user_data))

def resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_macro"):
    """Resolve a requested service key within a multi-service mapping.

    Args:
      service_entries: Filtered mapping of service key to exported topt_data.
      topt_service: Optional user-selected service key.
      macro_name: Macro name used to render actionable failure messages.

    Returns:
      Resolved service key (exact match or sanitized fallback).
    """
    keys = sorted(service_entries.keys())
    if topt_service == None:
        if len(keys) == 1:
            return keys[0]
        fail("%s: topt_data looks like a multi-service mapping; please pass topt_service (one of: %s)" % (macro_name, ", ".join(keys)))

    if service_entries.get(topt_service) != None:
        return topt_service

    sanitized = sanitize_label_fragment(topt_service)
    if service_entries.get(sanitized) != None:
        return sanitized

    fail("%s: topt_service '%s' not found. Available: %s" % (macro_name, topt_service, ", ".join(keys)))
