"""Thin aliases to the root dev orchestrion stub extension."""

load(
    "@datadog-rules-test-optimization//tools/dev:orchestrion_stub.bzl",
    _orchestrion_stub_extension = "orchestrion_stub_extension",
    _orchestrion_stub_repo = "orchestrion_stub_repo",
)

orchestrion_stub_extension = _orchestrion_stub_extension
orchestrion_stub_repo = _orchestrion_stub_repo
