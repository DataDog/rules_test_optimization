# Unit tests for common_utils helpers (sanitization, deduping, validation).
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tools:common_utils.bzl", "dedup_keys", "sanitize_label_fragment", "validate_api_key", "validate_runtime_name", "validate_runtime_version", "validate_service_name")

def _sanitize_label_fragment_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo/Bar"))
    asserts.equals(env, "foo_bar", sanitize_label_fragment("Foo--Bar"))
    asserts.equals(env, "foo", sanitize_label_fragment("-Foo-"))
    asserts.equals(env, "module", sanitize_label_fragment("___"))
    asserts.equals(env, "module", sanitize_label_fragment(""))
    return unittest.end(env)

def _dedup_keys_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["a", "a_2", "b", "a_3"], dedup_keys(["a", "a", "b", "a"]))
    asserts.equals(env, ["x", "y"], dedup_keys(["x", "y"]))
    return unittest.end(env)

def _validate_service_name_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "svc", validate_service_name("svc"))
    asserts.equals(env, "svc", validate_service_name("  svc  ", debug = True))
    return unittest.end(env)

def _validate_runtime_version_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "unknown", validate_runtime_version(None))
    asserts.equals(env, "unknown", validate_runtime_version(""))
    asserts.equals(env, "unknown", validate_runtime_version("   "))
    asserts.equals(env, "1.2.3", validate_runtime_version(" 1.2.3 "))
    return unittest.end(env)

def _validate_runtime_name_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "unknown", validate_runtime_name(None))
    asserts.equals(env, "unknown", validate_runtime_name(""))
    asserts.equals(env, "unknown", validate_runtime_name("   "))
    asserts.equals(env, "go", validate_runtime_name(" go "))
    return unittest.end(env)

def _validate_api_key_normalization_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "abcd1234", validate_api_key(" abcd1234 "))
    return unittest.end(env)

sanitize_label_fragment_test = unittest.make(_sanitize_label_fragment_test)
dedup_keys_test = unittest.make(_dedup_keys_test)
validate_service_name_test = unittest.make(_validate_service_name_test)
validate_runtime_version_test = unittest.make(_validate_runtime_version_test)
validate_runtime_name_test = unittest.make(_validate_runtime_name_test)
validate_api_key_normalization_test = unittest.make(_validate_api_key_normalization_test)
