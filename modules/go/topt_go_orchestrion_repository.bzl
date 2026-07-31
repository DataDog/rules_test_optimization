# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Thin WORKSPACE wrapper around rules_go's public Orchestrion repository API."""

load(
    "@rules_go//go:orchestrion_workspace.bzl",
    "go_orchestrion_tool_repo",
)

_DEFAULT_TOOL_REPO_NAME = "rules_go_orchestrion_tool"

def _configured_version_modes(dd_trace_go_version, dd_trace_go_versions, dd_trace_go_pin_files):
    return len([
        value
        for value in [
            dd_trace_go_version,
            dd_trace_go_versions,
            dd_trace_go_pin_files,
        ]
        if value
    ])

def _build_orchestrion_repo_call(
        dd_trace_go_version = "",
        dd_trace_go_versions = {},
        dd_trace_go_pin_files = [],
        version = "",
        go_sdk_root = "",
        go_sdk_version = "",
        log_timing = False):
    """Build the fixed-name public rules_go repository call."""
    if _configured_version_modes(dd_trace_go_version, dd_trace_go_versions, dd_trace_go_pin_files) > 1:
        fail("dd_trace_go_version, dd_trace_go_versions, and dd_trace_go_pin_files are mutually exclusive")

    call = {
        "name": _DEFAULT_TOOL_REPO_NAME,
        "dd_trace_go_version": dd_trace_go_version,
        "dd_trace_go_versions": dd_trace_go_versions,
        "dd_trace_go_pin_files": dd_trace_go_pin_files,
        "enabled_by_env": True,
        "version": version,
        "log_timing": log_timing,
    }
    if go_sdk_root:
        call["go_sdk_root"] = go_sdk_root
    if go_sdk_version:
        call["go_sdk_version"] = go_sdk_version
    return call

def dd_topt_go_orchestrion_tool_repo(
        dd_trace_go_version = "",
        dd_trace_go_versions = {},
        dd_trace_go_pin_files = [],
        version = "",
        go_sdk_root = "",
        go_sdk_version = "",
        log_timing = False):
    """Declare the real Orchestrion repository through rules_go's public API."""
    go_orchestrion_tool_repo(**_build_orchestrion_repo_call(
        dd_trace_go_version = dd_trace_go_version,
        dd_trace_go_versions = dd_trace_go_versions,
        dd_trace_go_pin_files = dd_trace_go_pin_files,
        version = version,
        go_sdk_root = go_sdk_root,
        go_sdk_version = go_sdk_version,
        log_timing = log_timing,
    ))

build_orchestrion_repo_call_for_tests = _build_orchestrion_repo_call
