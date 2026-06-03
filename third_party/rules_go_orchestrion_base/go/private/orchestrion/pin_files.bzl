# Copyright 2026 The Bazel Go Rules Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Internal provider for Orchestrion module pin files."""

OrchestrionPinFilesInfo = provider(
    doc = "Carries module pin files Orchestrion may inspect during Bazel actions.",
    fields = {
        "files": "Depset of pin files such as go.mod, go.sum, orchestrion.tool.go, and orchestrion.yml. Optimized Test Optimization actions keep module/config pins but use a synthetic orchestrion.tool.go.",
    },
)

def _orchestrion_pin_files_impl(ctx):
    files = depset(ctx.files.srcs)
    return [
        OrchestrionPinFilesInfo(files = files),
        DefaultInfo(files = files, runfiles = ctx.runfiles(files = ctx.files.srcs)),
    ]

orchestrion_pin_files = rule(
    implementation = _orchestrion_pin_files_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Module pin files that Orchestrion may need while materializing its temporary module.",
        ),
    },
    doc = "Groups Orchestrion pin files without treating every runtime data file as a build input.",
)
