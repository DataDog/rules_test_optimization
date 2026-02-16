# Unit tests for Go macro/rule selection helpers.
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools/go:topt_go_infer.bzl",
    "select_module_group_name_for_tests",
)
load(
    "//tools/go:topt_go_test.bzl",
    "normalize_user_data_for_tests",
    "resolve_topt_service_key_for_tests",
    "service_mapping_entries_for_tests",
)

def _service_mapping_entries_filters_non_service_test(ctx):
    """Validate filtering of non-service entries in aggregator mappings."""
    env = unittest.begin(ctx)
    entries = service_mapping_entries_for_tests({
        "go_service": {"repo_name": "repo_go"},
        "ruby_service": {"repo_name": "repo_ruby"},
        "_meta": {"note": "non-service metadata"},
    })
    asserts.equals(env, 2, len(entries))
    asserts.equals(env, "repo_go", entries["go_service"]["repo_name"])
    asserts.equals(env, "repo_ruby", entries["ruby_service"]["repo_name"])
    return unittest.end(env)

def _resolve_topt_service_key_prefers_exact_then_sanitized_test(ctx):
    """Validate service key resolution precedence (exact before sanitized)."""
    env = unittest.begin(ctx)
    entries = {
        "go_service": {"repo_name": "repo_go"},
        "go_service_2": {"repo_name": "repo_go_2"},
    }
    # Exact keys are stable and should win when provided explicitly.
    asserts.equals(env, "go_service_2", resolve_topt_service_key_for_tests(entries, "go_service_2"))
    # Raw service names can still resolve through sanitization.
    asserts.equals(env, "go_service", resolve_topt_service_key_for_tests(entries, "go-service"))
    return unittest.end(env)

def _select_module_group_name_test(ctx):
    """Validate module-group selection helper and override behavior."""
    env = unittest.begin(ctx)
    groups = [
        "module_github_com_example_mod_pkg",
        "module_custom_override",
    ]
    asserts.equals(
        env,
        "module_github_com_example_mod_pkg",
        select_module_group_name_for_tests(
            "github.com/example/mod/pkg",
            groups,
            True,
        ),
    )
    asserts.equals(
        env,
        "module_custom_override",
        select_module_group_name_for_tests(
            "github.com/example/mod/pkg",
            groups,
            True,
            "custom_override",
        ),
    )
    asserts.equals(
        env,
        "",
        select_module_group_name_for_tests(
            "github.com/example/mod/pkg",
            groups,
            False,
        ),
    )
    asserts.equals(
        env,
        "",
        select_module_group_name_for_tests(
            "github.com/example/other",
            groups,
            True,
        ),
    )
    return unittest.end(env)

def _normalize_user_data_handles_none_test(ctx):
    """Validate macro `data` normalization for None/list/tuple input."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], normalize_user_data_for_tests(None))
    asserts.equals(env, [":a", ":b"], normalize_user_data_for_tests([":a", ":b"]))
    asserts.equals(env, [":x", ":y"], normalize_user_data_for_tests((":x", ":y")))
    return unittest.end(env)

service_mapping_entries_filters_non_service_test = unittest.make(_service_mapping_entries_filters_non_service_test)
resolve_topt_service_key_prefers_exact_then_sanitized_test = unittest.make(_resolve_topt_service_key_prefers_exact_then_sanitized_test)
select_module_group_name_test = unittest.make(_select_module_group_name_test)
normalize_user_data_handles_none_test = unittest.make(_normalize_user_data_handles_none_test)
