"""Internal Orchestrion wrapper rule for Go tests."""

def _orch_transition_impl(_settings, _attr):
    return {
        "@rules_go//go/private/orchestrion:enabled": True,
    }

orch_transition = transition(
    implementation = _orch_transition_impl,
    inputs = [],
    outputs = [
        "@rules_go//go/private/orchestrion:enabled",
    ],
)

def _first_target(dep):
    if type(dep) == "list":
        if len(dep) == 0:
            fail("orch_go_test: actual produced no targets")
        return dep[0]
    return dep

def _dep_exec_and_runfiles(dep):
    target = _first_target(dep)
    default_info = target[DefaultInfo]
    return default_info.files_to_run.executable, default_info.default_runfiles.merge(default_info.data_runfiles)

def _orch_go_test_impl(ctx):
    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = dep_exe)

    return [DefaultInfo(
        files = depset([out]),
        runfiles = dep_runfiles,
        executable = out,
    )]

orch_go_test = rule(
    implementation = _orch_go_test_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = orch_transition,
            doc = "The underlying raw go_test target built with Orchestrion enabled.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    test = True,
)
