# Unit tests for common_utils helpers (sanitization, deduping, validation).
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//tools/core:common_utils.bzl", "dedup_keys", "is_dict", "is_list", "is_string", "log_debug", "log_info", "missing_api_key_message_for_tests", "sanitize_label_fragment", "validate_api_key", "validate_runtime_name", "validate_runtime_version", "validate_service_name")

def _sanitize_label_fragment_test(ctx):
    """Validate label sanitization rules and fallback behavior."""
    env = unittest.begin(ctx)
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo/Bar"))
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo--Bar"))
    asserts.equals(env, "foo", sanitize_label_fragment("-Foo-"))
    asserts.true(env, sanitize_label_fragment("___").startswith("module_"))
    asserts.true(env, sanitize_label_fragment("ééé").startswith("module_"))
    asserts.true(env, sanitize_label_fragment("中文").startswith("module_"))
    asserts.equals(env, "foo_bar_baz", sanitize_label_fragment("Foo/中文/Bar-Baz"))
    asserts.equals(env, "a" * 256, sanitize_label_fragment("A" * 256))
    asserts.equals(env, "module", sanitize_label_fragment(""))
    return unittest.end(env)

def _dedup_keys_test(ctx):
    """Validate deterministic duplicate key suffixing semantics."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], dedup_keys([]))
    asserts.equals(env, ["solo"], dedup_keys(["solo"]))
    asserts.equals(env, ["a", "a_2", "b", "a_3"], dedup_keys(["a", "a", "b", "a"]))
    asserts.equals(env, ["a", "b", "a_2", "b_2"], dedup_keys(["a", "b", "a", "b"]))
    asserts.equals(env, ["foo_2", "foo", "foo_3"], dedup_keys(["foo_2", "foo", "foo"]))
    asserts.equals(env, ["x", "y"], dedup_keys(["x", "y"]))
    return unittest.end(env)

def _validate_service_name_test(ctx):
    """Validate service-name normalization in success path."""
    env = unittest.begin(ctx)
    asserts.equals(env, "svc", validate_service_name("svc"))
    asserts.equals(env, "svc", validate_service_name("  svc  ", debug = True))
    asserts.equals(env, "servicio-eu", validate_service_name(" servicio-eu "))
    asserts.equals(env, "servicio_ñ", validate_service_name(" servicio_ñ "))
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
    asserts.equals(env, "abc%def", validate_api_key(" abc%def "))
    asserts.equals(env, "abc_def-123", validate_api_key(" abc_def-123 "))
    return unittest.end(env)

def _missing_api_key_message_test(ctx):
    """Validate missing API-key guidance is sync-focused and sandbox-safe."""
    env = unittest.begin(ctx)
    message = missing_api_key_message_for_tests()
    asserts.true(env, message.find("sync metadata fetch") >= 0)
    asserts.true(env, message.find("bazel run") >= 0)
    asserts.true(env, message.find("doctor") >= 0)
    asserts.true(env, message.find("uploader") >= 0)
    asserts.true(env, message.find("--repo_env=DD_API_KEY") >= 0)
    asserts.equals(env, -1, message.find("--test_env=DD_API_KEY"))
    return unittest.end(env)

def _log_helpers_and_is_dict_test(ctx):
    """Validate lightweight logging helpers and type helpers."""
    env = unittest.begin(ctx)
    asserts.equals(env, True, is_dict({}))
    asserts.equals(env, False, is_dict([]))
    asserts.equals(env, False, is_dict("x"))
    asserts.equals(env, True, is_list([]))
    asserts.equals(env, True, is_list(()))
    asserts.equals(env, False, is_list({}))
    asserts.equals(env, True, is_string("x"))
    asserts.equals(env, False, is_string(1))

    # Logging helpers are side-effect only; verify they execute and return None.
    asserts.equals(env, None, log_info("unit-log-info"))
    asserts.equals(env, None, log_debug(False, "unit", "hidden"))
    asserts.equals(env, None, log_debug(True, "unit", "visible"))
    return unittest.end(env)

def _validate_api_key_missing_target_impl(_ctx):
    """Analysis target expected to fail when API key is missing."""
    validate_api_key(None)
    return []

def _validate_api_key_whitespace_target_impl(_ctx):
    """Analysis target expected to fail for whitespace-only API key."""
    validate_api_key("   ")
    return []

def _validate_api_key_control_chars_target_impl(_ctx):
    """Analysis target expected to fail for control characters in API key."""
    validate_api_key("line1\nline2")
    return []

def _validate_api_key_carriage_return_target_impl(_ctx):
    """Analysis target expected to fail for carriage returns in API key."""
    validate_api_key("line1\rline2")
    return []

def _validate_api_key_tab_target_impl(_ctx):
    """Analysis target expected to fail for tabs in API key."""
    validate_api_key("line1\tline2")
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
validate_api_key_control_chars_target_rule = rule(
    implementation = _validate_api_key_control_chars_target_impl,
)
validate_api_key_carriage_return_target_rule = rule(
    implementation = _validate_api_key_carriage_return_target_impl,
)
validate_api_key_tab_target_rule = rule(
    implementation = _validate_api_key_tab_target_impl,
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

def _validate_api_key_control_chars_failure_test_impl(ctx):
    """Assert control-character API-key failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_API_KEY must not contain control characters")
    return analysistest.end(env)

def _validate_api_key_carriage_return_failure_test_impl(ctx):
    """Assert carriage-return API-key failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_API_KEY must not contain control characters")
    return analysistest.end(env)

def _validate_api_key_tab_failure_test_impl(ctx):
    """Assert tab API-key failure message remains stable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_API_KEY must not contain control characters")
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
missing_api_key_message_test = unittest.make(_missing_api_key_message_test)
log_helpers_and_is_dict_test = unittest.make(_log_helpers_and_is_dict_test)
validate_api_key_missing_failure_test = analysistest.make(
    _validate_api_key_missing_failure_test_impl,
    expect_failure = True,
)
validate_api_key_whitespace_failure_test = analysistest.make(
    _validate_api_key_whitespace_failure_test_impl,
    expect_failure = True,
)
validate_api_key_control_chars_failure_test = analysistest.make(
    _validate_api_key_control_chars_failure_test_impl,
    expect_failure = True,
)
validate_api_key_carriage_return_failure_test = analysistest.make(
    _validate_api_key_carriage_return_failure_test_impl,
    expect_failure = True,
)
validate_api_key_tab_failure_test = analysistest.make(
    _validate_api_key_tab_failure_test_impl,
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
