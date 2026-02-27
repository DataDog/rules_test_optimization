"""Shared helpers for language-specific Test Optimization macros.

Maintainers:
- This is core-owned shared logic and must stay language-rule agnostic.
- Keep this file free from `rules_<lang>` imports; companion modules depend on
  core helpers, not the other way around.
"""

load(
    "//tools/core:common_utils.bzl",
    "LABEL_FRAGMENT_ALLOWED_CHARS",
    "fail_with_prefix",
    "sanitize_label_fragment",
    _is_dict = "is_dict",
    _is_list = "is_list",
    _is_string = "is_string",
)

is_dict = _is_dict
is_list = _is_list
is_string = _is_string

def is_select(value):
    """Return True when value is a configurable `select(...)` expression."""
    return type(value) == "select"

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

    if is_select(user_data):
        return user_data

    # A single label can be passed as a string; keep it atomic.
    if is_string(user_data):
        return [user_data]
    if is_list(user_data):
        return list(user_data)
    fail_with_prefix("topt_macro_utils", "normalize_user_data: expected None, string, list, tuple, or select; got %s" % type(user_data))
    return []

def append_data_dependencies(user_data, extra_labels):
    """Append generated data labels while preserving `select(...)` configurability."""

    labels = list(extra_labels or [])
    normalized = normalize_user_data(user_data)
    if is_select(normalized):
        return normalized + labels
    out = list(normalized)
    out.extend(labels)
    return out

def merge_user_env(user_env, required_env, macro_name = "dd_topt_macro"):
    """Merge caller env with required env keys, supporting `select(...)` values."""

    if required_env == None or not is_dict(required_env):
        fail_with_prefix("topt_macro_utils", "%s: required_env must be a dict" % macro_name)

    if user_env == None:
        base = {}
    elif is_dict(user_env) or is_select(user_env):
        base = user_env
    else:
        fail_with_prefix("topt_macro_utils", "%s: env must be None, dict, or select; got %s" % (macro_name, type(user_env)))

    # Required keys intentionally win over caller-provided values.
    return base | required_env

def build_module_labels(sync_repo_name, labels, macro_name = "dd_topt_macro"):
    """Build per-module filegroup labels from sanitized module fragments.

    Args:
      sync_repo_name: Name of the generated sync repository.
      labels: List/tuple of sanitized module label fragments.
      macro_name: Macro name included in validation error text.

    Returns:
      List of `@repo//:module_<label>` filegroup labels.
    """
    if labels == None:
        return []
    if not is_list(labels):
        fail_with_prefix("topt_macro_utils", "%s: selected service topt_data['labels'] must be a list or tuple" % macro_name)

    module_labels = []
    for lab in labels:
        if not is_string(lab):
            fail_with_prefix("topt_macro_utils", "%s: selected service topt_data['labels'] entries must be strings" % macro_name)
        if not lab:
            fail_with_prefix("topt_macro_utils", "%s: selected service topt_data['labels'] entries must be non-empty" % macro_name)
        for i in range(len(lab)):
            ch = lab[i]
            if ch not in LABEL_FRAGMENT_ALLOWED_CHARS:
                fail_with_prefix("topt_macro_utils", "%s: selected service topt_data['labels'] entries must be sanitized ([a-z0-9_]): '%s'" % (macro_name, lab))
        module_labels.append("@%s//:module_%s" % (sync_repo_name, lab))
    return module_labels

def select_service_entry_or_fail(topt_data, topt_service, macro_name = "dd_topt_macro"):
    """Select single-service payload data from single or aggregated exports.

    Args:
      topt_data: Exported single-service dict or multi-service mapping.
      topt_service: Optional selected service key for aggregator mappings.
      macro_name: Macro name included in validation error text.

    Returns:
      The selected single-service `topt_data` entry.
    """
    if topt_data == None or not is_dict(topt_data):
        fail_with_prefix("topt_macro_utils", "%s: topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping" % macro_name)

    if topt_data.get("repo_name"):
        return topt_data

    service_entries = service_mapping_entries(topt_data)
    if not service_entries:
        fail_with_prefix("topt_macro_utils", "%s: topt_data mapping did not contain any service entries" % macro_name)
    selected_key = resolve_topt_service_key(service_entries, topt_service, macro_name = macro_name)
    return service_entries[selected_key]

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
        fail_with_prefix("topt_macro_utils", "%s: topt_data looks like a multi-service mapping; please pass topt_service (one of: %s)" % (macro_name, ", ".join(keys)))

    if service_entries.get(topt_service) != None:
        return topt_service

    sanitized = sanitize_label_fragment(topt_service)
    if service_entries.get(sanitized) != None:
        return sanitized

    fail_with_prefix("topt_macro_utils", "%s: topt_service '%s' not found. Available: %s" % (macro_name, topt_service, ", ".join(keys)))
    return ""
