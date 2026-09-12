# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Analysis-time state exported by a Test Optimization sync repository.

Local-static descriptors deliberately avoid loading the generated repository's
`export.bzl`, so Bazel resolves only repositories reached by selected targets.
The state target therefore also carries the generated module catalog as
provider data. A selector can inspect every module name at analysis time while
exposing only the chosen module's files to the test action.
"""

TestOptimizationRepositoryStateInfo = provider(
    doc = "Stable identity and enablement state for one synchronized runtime repository.",
    fields = {
        "disabled_reason": "Safe user-facing reason when synchronization is disabled.",
        "enabled": "Whether the repository fetched live Test Optimization metadata.",
        "module_files_by_name": "Per-module file depsets keyed by generated module target name.",
        "module_group_names": "Generated module target names in deterministic order.",
        "repo_name": "Apparent repository name exported to consumers.",
        "runtime_module_included": "Whether the configured runtime module has a dedicated payload group.",
        "runtime_module_path": "Configured runtime module path.",
        "runtime_name": "Runtime name associated with this repository.",
        "service_name": "Service name associated with this repository.",
    },
)

def _test_optimization_repository_state_impl(ctx):
    if len(ctx.attr.module_group_names) != len(ctx.attr.module_groups):
        fail("test_optimization_repository_state: module_group_names must contain one entry per module_groups entry")

    module_files_by_name = {}
    for index in range(len(ctx.attr.module_group_names)):
        name = ctx.attr.module_group_names[index]
        if not name:
            fail("test_optimization_repository_state: module_group_names cannot contain empty entries")
        if name in module_files_by_name:
            fail("test_optimization_repository_state: duplicate module group name %r" % name)
        module_files_by_name[name] = ctx.attr.module_groups[index][DefaultInfo].files

    return [TestOptimizationRepositoryStateInfo(
        disabled_reason = ctx.attr.disabled_reason,
        enabled = ctx.attr.enabled,
        module_files_by_name = module_files_by_name,
        module_group_names = list(ctx.attr.module_group_names),
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
        "module_group_names": attr.string_list(),
        "module_groups": attr.label_list(allow_files = True),
        "repo_name": attr.string(mandatory = True),
        "runtime_module_included": attr.bool(mandatory = True),
        "runtime_module_path": attr.string(mandatory = True),
        "runtime_name": attr.string(mandatory = True),
        "service_name": attr.string(mandatory = True),
    },
)
