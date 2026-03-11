load("@bazel_skylib//rules:common_settings.bzl", "bool_flag")

bool_flag(
    name = "enabled",
    build_setting_default = False,
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

