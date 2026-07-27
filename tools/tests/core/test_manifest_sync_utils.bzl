# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for manifest-driven Test Optimization sync helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/core:test_optimization_manifest_sync.bzl",
    "context_key_for_tests",
    "decode_manifest_for_tests",
    "manifest_summary_for_tests",
    "normalize_manifest_for_tests",
    "render_disabled_manifest_export_for_tests",
    "render_enabled_manifest_build_for_tests",
    "render_enabled_manifest_export_for_tests",
    "render_expected_targets_for_tests",
)

def _sample_manifest():
    return {
        "schema_version": 1,
        "contexts": [
            {
                "key": "payments_worker__python",
                "service": "payments-worker",
                "runtime": {
                    "name": "python",
                    "version": "3.12.8",
                    "arch": "arm64",
                    "module_path": "domains/payments/apps/worker",
                },
            },
            {
                "key": "payments_api__go",
                "service": "payments-api",
                "runtime": {
                    "name": "go",
                    "version": "1.25.0",
                    "module_path": "github.com/DataDog/dd-source",
                },
            },
        ],
        "targets": [
            {
                "label": "//domains/payments/apps/worker:worker_test",
                "context_key": "payments_worker__python",
                "service_derivation": "domain_fallback",
            },
            {
                "label": "//domains/payments/apps/api:api_test",
                "context_key": "payments_api__go",
                "service_derivation": "application",
            },
        ],
    }

def _manifest_normalization_test(ctx):
    env = unittest.begin(ctx)
    normalized = normalize_manifest_for_tests(_sample_manifest())
    asserts.equals(
        env,
        ["payments_api__go", "payments_worker__python"],
        [context["key"] for context in normalized["contexts"]],
    )
    asserts.equals(
        env,
        [
            "//domains/payments/apps/api:api_test",
            "//domains/payments/apps/worker:worker_test",
        ],
        [target["label"] for target in normalized["targets"]],
    )
    asserts.equals(env, "", normalized["contexts"][0]["runtime"]["arch"])

    reordered = _sample_manifest()
    reordered["contexts"] = list(reversed(reordered["contexts"]))
    reordered["targets"] = list(reversed(reordered["targets"]))
    reordered = normalize_manifest_for_tests(reordered)
    asserts.equals(env, normalized, reordered)
    asserts.equals(
        env,
        render_expected_targets_for_tests(normalized),
        render_expected_targets_for_tests(reordered),
    )
    return unittest.end(env)

def _manifest_decode_and_summary_test(ctx):
    env = unittest.begin(ctx)
    normalized = decode_manifest_for_tests(json.encode(_sample_manifest()))
    asserts.equals(
        env,
        {
            "contexts": 2,
            "services": 2,
            "targets": 2,
            "application_targets": 1,
            "domain_fallback_targets": 1,
        },
        manifest_summary_for_tests(normalized),
    )
    asserts.equals(env, "payments_api__go", context_key_for_tests("payments-api", "go"))

    same_service = normalize_manifest_for_tests({
        "schema_version": 1,
        "contexts": [
            {
                "key": "payments_api__go",
                "service": "payments-api",
                "runtime": {
                    "name": "go",
                    "version": "1.25.0",
                    "module_path": "github.com/DataDog/dd-source",
                },
            },
            {
                "key": "payments_api__python",
                "service": "payments-api",
                "runtime": {
                    "name": "python",
                    "version": "3.12.8",
                    "module_path": "domains.payments.apps.api",
                },
            },
        ],
        "targets": [
            {
                "label": "//domains/payments/apps/api:go_test",
                "context_key": "payments_api__go",
                "service_derivation": "application",
            },
            {
                "label": "//domains/payments/apps/api:py_test",
                "context_key": "payments_api__python",
                "service_derivation": "application",
            },
        ],
    })
    asserts.equals(env, 2, manifest_summary_for_tests(same_service)["contexts"])
    asserts.equals(env, 1, manifest_summary_for_tests(same_service)["services"])
    return unittest.end(env)

def _manifest_generated_contracts_test(ctx):
    env = unittest.begin(ctx)
    normalized = normalize_manifest_for_tests(_sample_manifest())
    expected_targets = json.decode(render_expected_targets_for_tests(normalized))
    asserts.equals(env, 1, expected_targets["schema_version"])
    asserts.equals(
        env,
        [
            "//domains/payments/apps/api:api_test",
            "//domains/payments/apps/worker:worker_test",
        ],
        expected_targets["targets"],
    )

    disabled_export = render_disabled_manifest_export_for_tests()
    asserts.true(env, "enabled = False" in disabled_export)
    asserts.true(env, "topt_data_by_target = {}" in disabled_export)
    asserts.true(env, "topt_data_by_context = {}" in disabled_export)
    asserts.true(env, "target_context_keys = {}" in disabled_export)
    return unittest.end(env)

def _materialized_context(service, runtime_name, module_label):
    context_key = "%s__%s" % (service.replace("-", "_"), runtime_name)
    root = "contexts/%s/.testoptimization" % context_key
    return {
        "context_files": [
            "%s/context.json" % root,
            "%s/telemetry_facts.json" % root,
        ],
        "exports": [
            "%s/cache/http/settings.json" % root,
            "%s/manifest.txt" % root,
            "%s/cache/http/known_tests.json" % root,
            "%s/cache/http/test_management.json" % root,
            "%s/cache/http/flaky_tests.json" % root,
        ],
        "labels": [module_label],
        "manifest_file": "%s/manifest.txt" % root,
        "module_files": {
            module_label: {
                "settings": "%s/cache/http/settings.json" % root,
                "manifest": "%s/manifest.txt" % root,
                "known_tests": "%s/module_%s/known_tests.json" % (root, module_label),
                "test_management": "%s/module_%s/test_management.json" % (root, module_label),
                "flaky_tests": "%s/module_%s/flaky_tests.json" % (root, module_label),
            },
        },
        "runtime": {
            "name": runtime_name,
            "go_module_path": "github.com/DataDog/dd-source" if runtime_name == "go" else "",
            "sanitized_go_module_path": "github_com_datadog_dd_source" if runtime_name == "go" else "",
            "go_module_included": runtime_name == "go",
            "python_module_path": "domains.payments.apps.worker" if runtime_name == "python" else "",
            "sanitized_python_module_path": "domains_payments_apps_worker" if runtime_name == "python" else "",
            "python_module_included": runtime_name == "python",
        },
        "service": service,
    }

def _manifest_aggregate_rendering_test(ctx):
    env = unittest.begin(ctx)
    manifest = normalize_manifest_for_tests(_sample_manifest())
    materialized = {
        "payments_api__go": _materialized_context(
            "payments-api",
            "go",
            "github_com_datadog_dd_source_domains_payments_apps_api",
        ),
        "payments_worker__python": _materialized_context(
            "payments-worker",
            "python",
            "domains_payments_apps_worker",
        ),
    }
    export_content = render_enabled_manifest_export_for_tests(
        manifest,
        "test_optimization_data",
        materialized,
    )
    asserts.true(env, "topt_data_by_context = {" in export_content)
    asserts.true(env, "topt_data_by_target = {" in export_content)
    asserts.true(env, '"//domains/payments/apps/api:api_test"' in export_content)
    asserts.true(
        env,
        '"@test_optimization_data//:module_payments_api__go_github_com_datadog_dd_source_domains_payments_apps_api"' in export_content,
    )
    asserts.true(
        env,
        '"//domains/payments/apps/api:api_test": topt_data_by_context["payments_api__go"]' in export_content,
    )
    asserts.true(
        env,
        '"//domains/payments/apps/worker:worker_test": topt_data_by_context["payments_worker__python"]' in export_content,
    )

    build_content = render_enabled_manifest_build_for_tests(manifest, materialized)
    asserts.true(env, 'name = "test_optimization_context"' in build_content)
    asserts.true(env, 'name = "expected_targets"' in build_content)
    asserts.true(env, 'name = "module_payments_api__go_' in build_content)
    asserts.true(env, 'name = "module_payments_worker__python_' in build_content)
    return unittest.end(env)

def _invalid_manifest_target_impl(_ctx):
    normalize_manifest_for_tests({
        "schema_version": 1,
        "contexts": [{
            "key": "payments_api__go",
            "service": "payments-api",
            "runtime": {
                "name": "go",
                "version": "1.25.0",
                "module_path": "github.com/DataDog/dd-source",
            },
        }],
        "targets": [{
            "label": "//domains/payments/apps/api:all",
            "context_key": "missing__go",
            "service_derivation": "application",
        }],
    })
    return []

def _unsupported_runtime_target_impl(_ctx):
    normalize_manifest_for_tests({
        "schema_version": 1,
        "contexts": [{
            "key": "payments_api__java",
            "service": "payments-api",
            "runtime": {
                "name": "java",
                "version": "21",
                "module_path": "com.datadog.payments",
            },
        }],
        "targets": [{
            "label": "//domains/payments/apps/api:api_test",
            "context_key": "payments_api__java",
            "service_derivation": "application",
        }],
    })
    return []

def _manifest_validation_failure_target_impl(ctx):
    manifest = _sample_manifest()
    failure_case = ctx.attr.failure_case
    if failure_case == "unknown_version":
        manifest["schema_version"] = 2
    elif failure_case == "duplicate_target":
        manifest["targets"].append(dict(manifest["targets"][0]))
    elif failure_case == "context_key_collision":
        manifest["contexts"] = [
            {
                "key": "payments_api__go",
                "service": "payments-api",
                "runtime": {
                    "name": "go",
                    "version": "1.25.0",
                    "module_path": "github.com/DataDog/dd-source",
                },
            },
            {
                "key": "payments_api__go",
                "service": "payments_api",
                "runtime": {
                    "name": "go",
                    "version": "1.25.0",
                    "module_path": "github.com/DataDog/dd-source",
                },
            },
        ]
        manifest["targets"] = [
            {
                "label": "//domains/payments/apps/api:api_test",
                "context_key": "payments_api__go",
                "service_derivation": "application",
            },
        ]
    elif failure_case == "empty_contexts":
        manifest["contexts"] = []
    elif failure_case == "empty_targets":
        manifest["targets"] = []
    elif failure_case == "unknown_key":
        manifest["unexpected"] = True
    elif failure_case == "unused_context":
        manifest["contexts"].append({
            "key": "unused__go",
            "service": "unused",
            "runtime": {
                "name": "go",
                "version": "1.25.0",
                "module_path": "github.com/DataDog/dd-source",
            },
        })
    elif failure_case == "external_label":
        manifest["targets"][0]["label"] = "@other//domains/payments:worker_test"
    elif failure_case == "noncanonical_label":
        manifest["targets"][0]["label"] = "//domains//payments:worker_test"
    elif failure_case == "invalid_derivation":
        manifest["targets"][0]["service_derivation"] = "manual"
    else:
        fail("unknown manifest failure case %r" % failure_case)
    normalize_manifest_for_tests(manifest)
    return []

manifest_validation_failure_target_rule = rule(
    implementation = _manifest_validation_failure_target_impl,
    attrs = {
        "failure_case": attr.string(mandatory = True),
    },
)

invalid_manifest_target_rule = rule(implementation = _invalid_manifest_target_impl)
unsupported_manifest_runtime_rule = rule(implementation = _unsupported_runtime_target_impl)

def _invalid_manifest_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "does not reference a declared context")
    return analysistest.end(env)

def _unsupported_runtime_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not supported by manifest onboarding")
    return analysistest.end(env)

def _unknown_manifest_version_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "unsupported schema_version 2")
    return analysistest.end(env)

def _duplicate_manifest_target_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "duplicate target label")
    return analysistest.end(env)

def _manifest_context_key_collision_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "duplicate context key")
    return analysistest.end(env)

def _empty_manifest_contexts_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "contexts must be a non-empty list")
    return analysistest.end(env)

def _empty_manifest_targets_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "targets must be a non-empty list")
    return analysistest.end(env)

def _unknown_manifest_key_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "manifest contains unsupported keys: unexpected")
    return analysistest.end(env)

def _unused_manifest_context_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "manifest contains contexts with no selected targets: unused__go")
    return analysistest.end(env)

def _external_manifest_label_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must be a canonical local label")
    return analysistest.end(env)

def _noncanonical_manifest_label_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "contains an unsupported package component")
    return analysistest.end(env)

def _invalid_service_derivation_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service_derivation must be one of")
    return analysistest.end(env)

manifest_normalization_test = unittest.make(_manifest_normalization_test)
manifest_decode_and_summary_test = unittest.make(_manifest_decode_and_summary_test)
manifest_generated_contracts_test = unittest.make(_manifest_generated_contracts_test)
manifest_aggregate_rendering_test = unittest.make(_manifest_aggregate_rendering_test)
invalid_manifest_failure_test = analysistest.make(
    _invalid_manifest_failure_test_impl,
    expect_failure = True,
)
unsupported_manifest_runtime_failure_test = analysistest.make(
    _unsupported_runtime_failure_test_impl,
    expect_failure = True,
)
unknown_manifest_version_failure_test = analysistest.make(
    _unknown_manifest_version_failure_test_impl,
    expect_failure = True,
)
duplicate_manifest_target_failure_test = analysistest.make(
    _duplicate_manifest_target_failure_test_impl,
    expect_failure = True,
)
manifest_context_key_collision_failure_test = analysistest.make(
    _manifest_context_key_collision_failure_test_impl,
    expect_failure = True,
)
empty_manifest_contexts_failure_test = analysistest.make(
    _empty_manifest_contexts_failure_test_impl,
    expect_failure = True,
)
empty_manifest_targets_failure_test = analysistest.make(
    _empty_manifest_targets_failure_test_impl,
    expect_failure = True,
)
unknown_manifest_key_failure_test = analysistest.make(
    _unknown_manifest_key_failure_test_impl,
    expect_failure = True,
)
unused_manifest_context_failure_test = analysistest.make(
    _unused_manifest_context_failure_test_impl,
    expect_failure = True,
)
external_manifest_label_failure_test = analysistest.make(
    _external_manifest_label_failure_test_impl,
    expect_failure = True,
)
noncanonical_manifest_label_failure_test = analysistest.make(
    _noncanonical_manifest_label_failure_test_impl,
    expect_failure = True,
)
invalid_service_derivation_failure_test = analysistest.make(
    _invalid_service_derivation_failure_test_impl,
    expect_failure = True,
)
