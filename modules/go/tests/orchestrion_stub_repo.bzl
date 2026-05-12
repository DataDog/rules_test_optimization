# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Thin aliases to the root dev orchestrion stub extension."""

load(
    "@datadog-rules-test-optimization//tools/dev:orchestrion_stub.bzl",
    _orchestrion_stub_extension = "orchestrion_stub_extension",
    _orchestrion_stub_repo = "orchestrion_stub_repo",
)

orchestrion_stub_extension = _orchestrion_stub_extension
orchestrion_stub_repo = _orchestrion_stub_repo
