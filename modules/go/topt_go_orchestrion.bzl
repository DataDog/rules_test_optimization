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

def _dep_run_environment_info(dep):
    target = _first_target(dep)
    if RunEnvironmentInfo in target:
        return target[RunEnvironmentInfo]
    return None

def _select_wrapper_output_name(label_name, executable_basename, is_windows):
    if is_windows and executable_basename.endswith(".exe"):
        return label_name + ".exe"
    return label_name

def _orch_go_test_impl(ctx):
    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    dep_run_environment = _dep_run_environment_info(ctx.attr.actual)
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_select_wrapper_output_name(ctx.label.name, dep_exe.basename, is_windows))
    ctx.actions.symlink(output = out, target_file = dep_exe)
    providers = [DefaultInfo(
        files = depset([out]),
        runfiles = dep_runfiles,
        executable = out,
    )]
    if dep_run_environment:
        providers.append(dep_run_environment)
    return providers

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
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
)

select_wrapper_output_name_for_tests = _select_wrapper_output_name
