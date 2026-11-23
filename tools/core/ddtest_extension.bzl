# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Bzlmod extension that declares the host's ddtest executable once.

The core module uses it for the uploader, and the Go companion uses the same
repository to write Mini and the instrumented SDKs, so a build downloads the
executable once.
"""

load(":ddtest_release.bzl", "DDTEST_REPO", "ddtest_host_repository")

def _ddtest_impl(_module_ctx):
    ddtest_host_repository(name = DDTEST_REPO)

ddtest = module_extension(
    implementation = _ddtest_impl,
    doc = "Declares @topt_ddtest, the host's executable of the pinned ddtest release.",
)
