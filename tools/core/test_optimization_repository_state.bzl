# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Analysis-time state exported by a Test Optimization sync repository."""

TestOptimizationRepositoryStateInfo = provider(
    doc = "Stable identity and enablement state for one synchronized runtime repository.",
    fields = {
        "disabled_reason": "Safe user-facing reason when synchronization is disabled.",
        "enabled": "Whether the repository fetched live Test Optimization metadata.",
        "repo_name": "Apparent repository name exported to consumers.",
        "runtime_module_included": "Whether the configured runtime module has a dedicated payload group.",
        "runtime_module_path": "Configured runtime module path.",
        "runtime_name": "Runtime name associated with this repository.",
        "service_name": "Service name associated with this repository.",
    },
)

def _test_optimization_repository_state_impl(ctx):
    return [TestOptimizationRepositoryStateInfo(
        disabled_reason = ctx.attr.disabled_reason,
        enabled = ctx.attr.enabled,
        repo_name = ctx.attr.repo_name,
        runtime_module_included = ctx.attr.runtime_module_included,
        runtime_module_path = ctx.attr.runtime_module_path,
        runtime_name = ctx.attr.runtime_name,
        service_name = ctx.attr.service_name,
    )]

test_optimization_repository_state = rule(
    implementation = _test_optimization_repository_state_impl,
    attrs = {
        "disabled_reason": attr.string(),
        "enabled": attr.bool(mandatory = True),
        "repo_name": attr.string(mandatory = True),
        "runtime_module_included": attr.bool(mandatory = True),
        "runtime_module_path": attr.string(mandatory = True),
        "runtime_name": attr.string(mandatory = True),
        "service_name": attr.string(mandatory = True),
    },
)
