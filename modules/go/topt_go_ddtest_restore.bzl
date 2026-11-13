# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Explicit adapter for rules_go with original SDK/nogo restoration settings."""

load(":topt_go_ddtest.bzl", "ddtest_go_test_rule")

# Export the same name so Bazel's test language remains ddtest_go in both modes.
ddtest_go_test = ddtest_go_test_rule(restore_non_go_settings = True)
