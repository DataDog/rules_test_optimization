"""Shared helpers for language-specific Test Optimization macros.

Maintainers:
- This is core-owned shared logic and must stay language-rule agnostic.
- Keep this file free from `rules_<lang>` imports; companion modules depend on
  core helpers, not the other way around.
"""

load("//tools/core:common_utils.bzl", "sanitize_label_fragment")

def is_dict(value):
    """Return True when value is a Starlark dict."""
    return type(value) == type({})

def service_mapping_entries(topt_data):
    """Extract service-shaped entries from an aggregator mapping.

    The multi-service export may contain helper/meta keys. A service entry is
    identified by a dict value that includes `repo_name`.
    """
    entries = {}
    for key, value in topt_data.items():
        if is_dict(value) and value.get("repo_name"):
            entries[key] = value
    return entries

def normalize_user_data(user_data):
    """Normalize caller-provided `data` into a mutable list."""
    if user_data == None:
        return []
    # A single label can be passed as a string; keep it atomic.
    if type(user_data) == type(""):
        return [user_data]
    return list(user_data)

def resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_macro"):
    """Resolve a requested service key within a multi-service mapping."""
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
