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

config_setting(
    name = "enabled_config",
    flag_values = {":enabled": "true"},
)

filegroup(
    name = "disabled_tool_binary",
    srcs = [],
)

filegroup(
    name = "disabled_dd_trace_go_version_file",
    srcs = [],
)

filegroup(
    name = "disabled_dd_trace_go_module_proxy_files",
    srcs = [],
)

filegroup(
    name = "disabled_dd_trace_go_module_proxy_root_marker",
    srcs = [],
)

filegroup(
    name = "disabled_orchestrion_tool_version_file",
    srcs = [],
)

# Stable Orchestrion aliases select package-local empty targets by default and
# only reference the real tool repository when the public :enabled flag is set.
# go_context_data also checks :enabled before consuming these files.
alias(
    name = "tool_binary",
    actual = select({
        ":enabled_config": "@rules_go_orchestrion_tool//:orchestrion",
        "//conditions:default": ":disabled_tool_binary",
    }),
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_version_file",
    actual = select({
        ":enabled_config": "@rules_go_orchestrion_tool//:dd_trace_go_version_file",
        "//conditions:default": ":disabled_dd_trace_go_version_file",
    }),
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_module_proxy_files",
    actual = select({
        ":enabled_config": "@rules_go_orchestrion_tool//:dd_trace_go_module_proxy_files",
        "//conditions:default": ":disabled_dd_trace_go_module_proxy_files",
    }),
    visibility = ["//visibility:public"],
)

alias(
    name = "dd_trace_go_module_proxy_root_marker",
    actual = select({
        ":enabled_config": "@rules_go_orchestrion_tool//:dd_trace_go_module_proxy_root_marker",
        "//conditions:default": ":disabled_dd_trace_go_module_proxy_root_marker",
    }),
    visibility = ["//visibility:public"],
)

alias(
    name = "orchestrion_tool_version_file",
    actual = select({
        ":enabled_config": "@rules_go_orchestrion_tool//:orchestrion_tool_version_file",
        "//conditions:default": ":disabled_orchestrion_tool_version_file",
    }),
    visibility = ["//visibility:public"],
)
