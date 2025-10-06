"""Common utilities for Datadog Test Optimization Bazel rules.

This file provides shared helper functions used across multiple rule files
to reduce duplication and ensure consistency.
"""

# ##########################################################################
# Logging utilities
# ##########################################################################

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
        if j < 0:
            break
        if out[j] != "_":
            end = j + 1
            break
    result = "".join(out[start:end])
    if not result:
        result = "module"
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
    
    if len(trimmed) > 200:
        fail("""
test_optimization: service name is too long (max 200 characters): '%s'

Please use a shorter service name.
""" % trimmed)
    
    # Warn about potential issues
    if " " in trimmed:
        log_debug(debug, "validation", "WARNING: service name contains spaces; this may cause issues: '%s'" % trimmed)
    
    if trimmed != service:
        log_debug(debug, "validation", "Service name trimmed: '%s' -> '%s'" % (service, trimmed))
    
    return trimmed

def validate_api_key(api_key):
    """Validate DD_API_KEY is present and provide helpful error message.
    
    Args:
      api_key: The API key value (may be None/empty)
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
    
    if len(trimmed) > 100:
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
    seen = {}
    out = []
    for k in keys:
        c = seen.get(k, 0) + 1
        seen[k] = c
        out.append(k if c == 1 else ("%s_%d" % (k, c)))
    return out

# ##########################################################################
# JSON utilities
# ##########################################################################

