# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""A descriptor resolves metadata visible only inside its extension's mapping."""

load("@datadog-rules-test-optimization//tools/tests:example_stub_repo.bzl", "example_stub_repo")

def _descriptor_impl(ctx):
    ctx.file("BUILD.bazel", "exports_files([\"descriptor.bzl\"])\n")
    ctx.file("descriptor.bzl", "DESCRIPTOR = %r\nDESCRIPTOR_LABEL = dict(DESCRIPTOR, repository_label = Label(DESCRIPTOR[\"repository_label\"]))\n" % {
        "repository_label": str(ctx.attr.manifest),
        "repo_name": "private_go_metadata",
        "runtime_module_path": "example.com/stub",
        "service_name": "private-go-service",
    })

_descriptor = repository_rule(
    implementation = _descriptor_impl,
    attrs = {"manifest": attr.label(mandatory = True)},
)

def _private_metadata_impl(_ctx):
    example_stub_repo(
        name = "private_go_metadata",
        repo_alias = "private_go_metadata",
        service_name = "private-go-service",
    )
    _descriptor(
        name = "private_go_descriptor",
        manifest = "@private_go_metadata//:.testoptimization/manifest.txt",
    )

private_metadata = module_extension(implementation = _private_metadata_impl)
