"""Common utilities for Datadog Test Optimization Bazel rules.

This module is intentionally dependency-free and is imported by most rule files
in `tools/`. Keep this file small, deterministic, and easy to reason about.

Design goals:
- Provide reusable primitives (logging, sanitization, validation, de-duplication)
  so each rule does not re-implement cross-cutting behavior.
- Keep helpers pure where possible: a helper should return normalized data
  instead of mutating caller state.
- Emit user-focused failures for configuration mistakes (for example, missing
  service/API key) so users do not have to inspect Starlark stack traces.

Maintenance notes:
- Any change here can affect sync, multi-sync, uploader, and test helpers.
  Favor additive changes and preserve backwards compatibility of helper
  contracts (inputs/outputs).
- Keep this module rules-engine neutral (`rules_go`, etc. must not be loaded
  from core utilities).
- Validation helpers return normalized values and may call `fail(...)` when
  invariants are violated.
- Logging helpers should never print secrets.
"""

# ##########################################################################
# Logging utilities
# ##########################################################################
#
# Logging is split into:
# - log_info: always-on progress messages visible to users.
# - log_debug: gated diagnostics controlled by each rule's debug flag.
#
# Keep log messages short and actionable because they appear in Bazel output.

SERVICE_NAME_MAX_LEN = 200
RUNTIME_VALUE_WARN_LEN = 100
RULES_VERSION = "1.0.0"
UPLOADER_VERSION = "2.0.0"

def log_info(message):
    """Print user-facing progress messages."""
    print("test_optimization: %s" % message)

def log_debug(debug_enabled, category, message):
    """Print debug messages when debug is enabled.

    Args:
      debug_enabled: Boolean flag to enable/disable debug output
      category: String category for the log (e.g., "http", "ci", "validation")
      message: The log message
    """
    if debug_enabled:
        print("test_optimization[%s]: %s" % (category, message))

def is_dict(value):
    """Return True when value is a Starlark dict."""
    return type(value) == type({})

def is_list(value):
    """Return True when value is a Starlark list or tuple."""
    return type(value) == type([]) or type(value) == type(())

def is_string(value):
    """Return True when value is a Starlark string."""
    return type(value) == type("")

# ##########################################################################
# Sanitization utilities
# ##########################################################################

def sanitize_label_fragment(name):
    """Produce a safe Bazel target name fragment from an arbitrary string.

    Rules:
    - Lowercase
    - Allowed characters: [a-z0-9_]
    - All other characters become '_'
    - Collapse multiple consecutive underscores
    - Strip leading/trailing underscores

    Args:
      name: Input string to sanitize

    Returns:
      Sanitized string safe for use in Bazel target names
    """
    s = (name or "").lower()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
    out = []
    last_us = False
    n_s = len(s)
    for i in range(n_s):
        ch = s[i]
        if ch in allowed:
            out.append(ch)
            last_us = (ch == "_")
        elif not last_us:
            out.append("_")
            last_us = True

    # Trim leading/trailing underscores
    n = len(out)
    start = 0
    found_start = False
    for i in range(n):
        if out[i] != "_":
            start = i
            found_start = True
            break
    if not found_start:
        start = n
    end = 0

    # Reverse scan without a negative-step range
    for k in range(n):
        j = n - 1 - k
        if out[j] != "_":
            end = j + 1
            break
    result = "".join(out[start:end])
    if not result:
        if not s:
            result = "module"
        else:
            # Keep empty input stable while reducing collisions for all-invalid
            # non-empty inputs by adding a deterministic suffix.
            seed = len(s)
            for i in range(len(s)):
                ch = s[i]
                idx = allowed.find(ch)
                if idx < 0:
                    idx = 37
                seed = ((seed * 33) + idx + i) % 10000
            result = "module_%d" % seed
    return result

# ##########################################################################
# Validation utilities
# ##########################################################################

def validate_service_name(service, debug = False):
    """Validate a service name and fail with helpful error messages.

    Args:
      service: The service name to validate
      debug: Whether debug logging is enabled

    Returns:
      The validated service name (trimmed)
    """
    if not service:
        fail("""
test_optimization: service name cannot be empty.

Please provide a service name via:
1. The 'service' attribute in your test_optimization_sync call, or
2. The DD_SERVICE environment variable in .bazelrc:
   common --repo_env=DD_SERVICE=my-service
""")

    trimmed = service.strip()
    if not trimmed:
        fail("test_optimization: service name cannot be empty or whitespace-only: '%s'" % service)

    if len(trimmed) > SERVICE_NAME_MAX_LEN:
        fail("""
test_optimization: service name is too long (max %d characters): '%s'

Please use a shorter service name.
""" % (SERVICE_NAME_MAX_LEN, trimmed))

    # Warn about potential issues
    if " " in trimmed:
        log_info("WARNING: service name contains spaces; this may cause issues: '%s'" % trimmed)

    if trimmed != service:
        log_debug(debug, "validation", "Service name trimmed: '%s' -> '%s'" % (service, trimmed))

    return trimmed

def validate_api_key(api_key):
    """Validate DD_API_KEY is present and provide helpful error message.

    Args:
      api_key: The API key value (may be None/empty)

    Returns:
      Normalized API key value
    """
    if not api_key:
        fail("""
test_optimization: DD_API_KEY is not set.

Datadog Test Optimization requires an API key for authentication.

To fix this, add to your .bazelrc:
  common --repo_env=DD_API_KEY

Or export it in your shell:
  export DD_API_KEY=your-key-here

To obtain an API key:
1. Log in to Datadog
2. Navigate to Organization Settings > API Keys
3. Create a new API key or use an existing one
""")

    trimmed = api_key.strip()
    if not trimmed:
        fail("""
test_optimization: DD_API_KEY cannot be empty or whitespace-only.

Please provide a non-empty API key via:
  common --repo_env=DD_API_KEY
""")

    return trimmed

def validate_runtime_name(name, debug = False):
    """Validate and normalize runtime name string.

    Args:
      name: Runtime name string (may be None)
      debug: Whether debug logging is enabled

    Returns:
      Normalized runtime name string or "unknown"
    """
    if not name:
        return "unknown"

    trimmed = name.strip()
    if not trimmed:
        return "unknown"

    if len(trimmed) > RUNTIME_VALUE_WARN_LEN:
        log_debug(debug, "validation", "WARNING: runtime name is unusually long: '%s'" % trimmed)

    return trimmed

def validate_runtime_version(version, debug = False):
    """Validate and normalize runtime version string.

    Args:
      version: Runtime version string (may be None)
      debug: Whether debug logging is enabled

    Returns:
      Normalized version string or "unknown"
    """
    if not version:
        return "unknown"

    trimmed = version.strip()
    if not trimmed:
        return "unknown"

    if len(trimmed) > RUNTIME_VALUE_WARN_LEN:
        log_debug(debug, "validation", "WARNING: runtime version is unusually long: '%s'" % trimmed)

    return trimmed

# ##########################################################################
# Deduplication utilities
# ##########################################################################

def dedup_keys(keys):
    """Ensure keys are unique by appending numeric suffixes if needed.

    Args:
      keys: List of strings that may contain duplicates

    Returns:
      List of unique strings with numeric suffixes (_2, _3, etc.) for duplicates
    """
    base_counts = {}
    taken = {}
    out = []
    for k in keys:
        c = base_counts.get(k, 0) + 1
        base_counts[k] = c
        candidate = k if c == 1 else ("%s_%d" % (k, c))
        for _ in range(len(keys) + len(taken) + 2):
            if not taken.get(candidate):
                break
            c += 1
            base_counts[k] = c
            candidate = "%s_%d" % (k, c)
        taken[candidate] = True
        out.append(candidate)
    return out
