load("@bazel_skylib//rules:common_settings.bzl", "bool_flag", "string_flag")

filegroup(
    name = "all_rules",
    srcs = glob(["**/*.bzl"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "all_files",
    testonly = True,
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)

bool_flag(
    name = "enabled",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

string_flag(
    name = "mode",
    build_setting_default = "general",
    values = [
        "general",
        "test_optimization",
    ],
    visibility = ["//visibility:public"],
)

# Proxy target for the orchestrion tool binary.
# This always points to the rules_go_orchestrion_tool repo.
# The repo provides an empty filegroup by default, or the actual orchestrion
# binary when configured via module extension.
# go_context_data checks the :enabled flag to determine whether to use this.
alias(
    name = "tool_binary",
    actual = "@rules_go_orchestrion_tool//:orchestrion",
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_version_file",
    actual = "@rules_go_orchestrion_tool//:dd_trace_go_version_file",
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_module_proxy_files",
    actual = "@rules_go_orchestrion_tool//:dd_trace_go_module_proxy_files",
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_module_proxy_root_marker",
    actual = "@rules_go_orchestrion_tool//:dd_trace_go_module_proxy_root_marker",
    visibility = ["//visibility:public"],
)

alias(
    name = "orchestrion_tool_version_file",
    actual = "@rules_go_orchestrion_tool//:orchestrion_tool_version_file",
    visibility = ["//visibility:public"],
)
