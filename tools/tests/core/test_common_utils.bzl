# Unit tests for common_utils helpers (sanitization, deduping, validation).
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//tools/core:common_utils.bzl", "dedup_keys", "sanitize_label_fragment", "validate_api_key", "validate_runtime_name", "validate_runtime_version", "validate_service_name")

def _sanitize_label_fragment_test(ctx):
    """Validate label sanitization rules and fallback behavior."""
    env = unittest.begin(ctx)
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo/Bar"))
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo--Bar"))
    asserts.equals(env, "foo", sanitize_label_fragment("-Foo-"))
    asserts.equals(env, "module", sanitize_label_fragment("___"))
    asserts.equals(env, "module", sanitize_label_fragment("ééé"))
    asserts.equals(env, "a" * 256, sanitize_label_fragment("A" * 256))
    asserts.equals(env, "module", sanitize_label_fragment(""))
    return unittest.end(env)

def _dedup_keys_test(ctx):
    """Validate deterministic duplicate key suffixing semantics."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], dedup_keys([]))
    asserts.equals(env, ["solo"], dedup_keys(["solo"]))
    asserts.equals(env, ["a", "a_2", "b", "a_3"], dedup_keys(["a", "a", "b", "a"]))
    asserts.equals(env, ["x", "y"], dedup_keys(["x", "y"]))
    return unittest.end(env)

def _validate_service_name_test(ctx):
    """Validate service-name normalization in success path."""
    env = unittest.begin(ctx)
    asserts.equals(env, "svc", validate_service_name("svc"))
    asserts.equals(env, "svc", validate_service_name("  svc  ", debug = True))
    return unittest.end(env)

def _validate_runtime_version_test(ctx):
    """Validate runtime version normalization defaults and trimming."""
    env = unittest.begin(ctx)
    asserts.equals(env, "unknown", validate_runtime_version(None))
    asserts.equals(env, "unknown", validate_runtime_version(""))
    asserts.equals(env, "unknown", validate_runtime_version("   "))
    asserts.equals(env, "1.2.3", validate_runtime_version(" 1.2.3 "))
    return unittest.end(env)

def _validate_runtime_name_test(ctx):
    """Validate runtime name normalization defaults and trimming."""
    env = unittest.begin(ctx)
    asserts.equals(env, "unknown", validate_runtime_name(None))
    asserts.equals(env, "unknown", validate_runtime_name(""))
    asserts.equals(env, "unknown", validate_runtime_name("   "))
    asserts.equals(env, "go", validate_runtime_name(" go "))
    return unittest.end(env)

def _validate_api_key_normalization_test(ctx):
    """Validate API key trimming on valid input."""
    env = unittest.begin(ctx)
    asserts.equals(env, "abcd1234", validate_api_key(" abcd1234 "))
    return unittest.end(env)

def _validate_api_key_missing_target_impl(_ctx):
    """Analysis target expected to fail when API key is missing."""
    validate_api_key(None)
    return []

def _validate_api_key_whitespace_target_impl(_ctx):
    """Analysis target expected to fail for whitespace-only API key."""
    validate_api_key("   ")
    return []

def _validate_service_name_missing_target_impl(_ctx):
    """Analysis target expected to fail when service name is missing."""
    validate_service_name(None)
    return []

def _validate_service_name_whitespace_target_impl(_ctx):
    """Analysis target expected to fail for whitespace-only service name."""
    validate_service_name("   ")
    return []

def _validate_service_name_too_long_target_impl(_ctx):
    """Analysis target expected to fail for service names > 200 chars."""
    validate_service_name("x" * 201)
    return []

validate_api_key_missing_target_rule = rule(
    implementation = _validate_api_key_missing_target_impl,
)
validate_api_key_whitespace_target_rule = rule(
    implementation = _validate_api_key_whitespace_target_impl,
)
validate_service_name_missing_target_rule = rule(
    implementation = _validate_service_name_missing_target_impl,
)
validate_service_name_whitespace_target_rule = rule(
    implementation = _validate_service_name_whitespace_target_impl,
)
validate_service_name_too_long_target_rule = rule(
    implementation = _validate_service_name_too_long_target_impl,
)

def _validate_api_key_missing_failure_test_impl(ctx):
    """Assert missing-API-key failure keeps actionable guidance text."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_API_KEY is not set")
    return analysistest.end(env)

def _validate_api_key_whitespace_failure_test_impl(ctx):
    """Assert whitespace-API-key failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_API_KEY cannot be empty or whitespace-only")
    return analysistest.end(env)

def _validate_service_name_missing_failure_test_impl(ctx):
    """Assert missing-service-name failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service name cannot be empty")
    return analysistest.end(env)

def _validate_service_name_whitespace_failure_test_impl(ctx):
    """Assert whitespace-service-name failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service name cannot be empty or whitespace-only")
    return analysistest.end(env)

def _validate_service_name_too_long_failure_test_impl(ctx):
    """Assert too-long service-name failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service name is too long (max 200 characters)")
    return analysistest.end(env)

sanitize_label_fragment_test = unittest.make(_sanitize_label_fragment_test)
dedup_keys_test = unittest.make(_dedup_keys_test)
validate_service_name_test = unittest.make(_validate_service_name_test)
validate_runtime_version_test = unittest.make(_validate_runtime_version_test)
validate_runtime_name_test = unittest.make(_validate_runtime_name_test)
validate_api_key_normalization_test = unittest.make(_validate_api_key_normalization_test)
validate_api_key_missing_failure_test = analysistest.make(
    _validate_api_key_missing_failure_test_impl,
    expect_failure = True,
)
validate_api_key_whitespace_failure_test = analysistest.make(
    _validate_api_key_whitespace_failure_test_impl,
    expect_failure = True,
)
validate_service_name_missing_failure_test = analysistest.make(
    _validate_service_name_missing_failure_test_impl,
    expect_failure = True,
)
validate_service_name_whitespace_failure_test = analysistest.make(
    _validate_service_name_whitespace_failure_test_impl,
    expect_failure = True,
)
validate_service_name_too_long_failure_test = analysistest.make(
    _validate_service_name_too_long_failure_test_impl,
    expect_failure = True,
)
