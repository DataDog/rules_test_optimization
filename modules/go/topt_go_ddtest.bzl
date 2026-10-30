# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Go tests instrumented by `ddtest instrument bazel`.

The public test wraps a hidden raw go_test built with the instrumented SDK:
its transition sets `@io_bazel_rules_go//go/toolchain:sdk_name` to the value
that selects the SDK's toolchains. The raw test also gets Mini's `testopt`
library and the registration file that `ddtest instrument` writes, and an
aspect stops a test that would link a second copy of Mini.
"""

load("@io_bazel_rules_go//go:def.bzl", "GoArchive")
load(":topt_go_ddtest_repository.bzl", "DDTEST_RELEASE", "MINI_REPO")

_BAZEL_TARGET_METADATA_OUTPUT = "bazel_target_metadata.json"
_SDK_NAME_SETTING = "@io_bazel_rules_go//go/toolchain:sdk_name"
_MINI_MODULE = "github.com/DataDog/ddtest/ddto"

# Mini's testopt library, which the raw test depends on.
MINI_TESTOPT = Label("@%s//testopt" % MINI_REPO)

def _ddtest_transition_impl(_settings, _attr):
    return {_SDK_NAME_SETTING: DDTEST_RELEASE.sdk_name}

ddtest_transition_impl_for_tests = _ddtest_transition_impl

ddtest_transition = transition(
    implementation = _ddtest_transition_impl,
    inputs = [],
    outputs = [_SDK_NAME_SETTING],
)

# --- A single Mini --------------------------------------------------------

ToptGoForeignMiniInfo = provider(
    doc = "Mini's packages that reach a target from a repository other than the generated Mini.",
    fields = {"labels": "depset of Labels of foreign copies of Mini's packages"},
)

def is_foreign_mini(importpath, repo_name, mini_repo_name):
    """Whether a Go package is a copy of Mini's from another repository."""
    if importpath != _MINI_MODULE and not importpath.startswith(_MINI_MODULE + "/"):
        return False
    return repo_name != mini_repo_name

def _mini_check_aspect_impl(target, ctx):
    direct = []
    if GoArchive in target:
        data = target[GoArchive].data
        if is_foreign_mini(data.importpath, data.label.repo_name, MINI_TESTOPT.repo_name):
            direct.append(data.label)
    transitive = [
        dep[ToptGoForeignMiniInfo].labels
        for attr in ("deps", "embed")
        for dep in getattr(ctx.rule.attr, attr, []) or []
        if ToptGoForeignMiniInfo in dep
    ]
    return [ToptGoForeignMiniInfo(labels = depset(direct, transitive = transitive))]

mini_check_aspect = aspect(
    implementation = _mini_check_aspect_impl,
    attr_aspects = ["deps", "embed"],
    doc = "Collects copies of Mini's packages that do not come from the generated Mini repository.",
)

def foreign_mini_error(test_label, labels):
    """The analysis error for a test that would link two copies of Mini."""
    return (
        "%s would link Mini's packages twice: %s come from outside @%s. rules_go " +
        "links one copy of each package without an error, so the test could run " +
        "without Test Optimization. In the root MODULE.bazel, replace go_deps' copy " +
        "of github.com/DataDog/ddtest/ddto with the generated Mini:\n\n" +
        "    topt_go_ddtest = use_extension(\"@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl\", \"topt_go_ddtest\")\n" +
        "    use_repo(topt_go_ddtest, \"%s\")\n" +
        "    override_repo(go_deps, com_github_datadog_ddtest_ddto = \"%s\")"
    ) % (test_label, ", ".join([str(label) for label in labels]), MINI_REPO, MINI_REPO, MINI_REPO)

# --- Registration -------------------------------------------------------

def _registration_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "_zz_dd_ci_visibility_test.go")
    go_srcs = [src for src in ctx.files.srcs if src.extension == "go"]
    args = ctx.actions.args()
    args.add("-o", out)
    args.add_all(go_srcs)
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = go_srcs,
        outputs = [out],
        mnemonic = "ToptGoRegistration",
        progress_message = "Writing the Test Optimization registration of %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

topt_go_ddtest_registration = rule(
    implementation = _registration_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "The test's sources."),
        "_tool": attr.label(
            default = "//tools/registration",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Writes the file that registers a Go test package with Mini.",
)

# --- The public test ------------------------------------------------------

def _test_execution_requirements(tags):
    """Keep caller-requested local execution scoped to the TestRunner action."""
    if "no-remote-exec" in tags:
        return {"no-remote-exec": ""}
    return {}

test_execution_requirements_for_tests = _test_execution_requirements

def _first_target(dep):
    if type(dep) == "list":
        if len(dep) == 0:
            fail("ddtest_go_test: actual produced no targets")
        return dep[0]
    return dep

def _wrapper_output_name(label_name, is_windows):
    """The launcher's name: Windows runs it as a batch file."""
    return label_name + (".bat" if is_windows else "")

wrapper_output_name_for_tests = _wrapper_output_name

def _unix_wrapper_content(actual_filename, metadata_filename):
    """The Unix launcher: it copies the target metadata next to the payloads."""
    return """#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
actual="$script_dir/%s"
undeclared_dir="${TEST_UNDECLARED_OUTPUTS_DIR:-}"

if [[ ! -x "$actual" ]]; then
  echo "ddtest_go_test: wrapped test executable not found: $actual" >&2
  exit 1
fi

if [[ -n "$undeclared_dir" ]]; then
  metadata_source="$script_dir/%s"
  if [[ -f "$metadata_source" ]]; then
    cp "$metadata_source" "$undeclared_dir/%s"
  fi
fi

"$actual" "$@"
""" % (actual_filename, metadata_filename, _BAZEL_TARGET_METADATA_OUTPUT)

def _windows_wrapper_content(actual_filename, metadata_filename):
    """The Windows launcher: it copies the target metadata next to the payloads."""
    return """@echo off
setlocal
set "SCRIPT_DIR=%%~dp0"
set "ACTUAL=%%SCRIPT_DIR%%%s"
set "UNDECLARED_DIR=%%TEST_UNDECLARED_OUTPUTS_DIR%%"

if not exist "%%ACTUAL%%" (
  echo ddtest_go_test: wrapped test executable not found: %%ACTUAL%% 1>&2
  exit /b 1
)

if not "%%UNDECLARED_DIR%%"=="" (
  if exist "%%SCRIPT_DIR%%%s" copy /Y "%%SCRIPT_DIR%%%s" "%%UNDECLARED_DIR%%\\%s" >nul
)

"%%ACTUAL%%" %%*
exit /b %%ERRORLEVEL%%
""" % (
        actual_filename.replace("/", "\\"),
        metadata_filename.replace("/", "\\"),
        metadata_filename.replace("/", "\\"),
        _BAZEL_TARGET_METADATA_OUTPUT,
    )

windows_wrapper_content_for_tests = _windows_wrapper_content

def _ddtest_go_test_impl(ctx):
    target = _first_target(ctx.attr.actual)
    foreign = target[ToptGoForeignMiniInfo].labels.to_list()
    if foreign:
        fail(foreign_mini_error(ctx.label, foreign))
    default_info = target[DefaultInfo]
    dep_exe = default_info.files_to_run.executable
    dep_runfiles = default_info.default_runfiles.merge(default_info.data_runfiles)
    metadata_file = ctx.file.metadata
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_wrapper_output_name(ctx.label.name, is_windows))
    actual_out = ctx.actions.declare_file(ctx.label.name + "__wrapped_" + dep_exe.basename, sibling = out)
    metadata_out = ctx.actions.declare_file(ctx.label.name + "__wrapped_" + metadata_file.basename, sibling = out)

    # Materialize transitioned inputs next to the wrapper so the launcher does
    # not have to guess which configuration-specific paths Bazel chose.
    ctx.actions.symlink(output = actual_out, target_file = dep_exe)
    ctx.actions.symlink(output = metadata_out, target_file = metadata_file)
    ctx.actions.write(
        output = out,
        content = _windows_wrapper_content(actual_out.basename, metadata_out.basename) if is_windows else _unix_wrapper_content(actual_out.basename, metadata_out.basename),
        is_executable = True,
    )
    providers = [DefaultInfo(
        files = depset([out, actual_out, metadata_out]),
        runfiles = dep_runfiles.merge(ctx.runfiles(files = [actual_out, metadata_out])),
        executable = out,
    )]
    if RunEnvironmentInfo in target:
        providers.append(target[RunEnvironmentInfo])
    execution_requirements = _test_execution_requirements(ctx.attr.tags)
    if execution_requirements:
        providers.append(testing.ExecutionInfo(requirements = execution_requirements))
    return providers

ddtest_go_test = rule(
    implementation = _ddtest_go_test_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = ddtest_transition,
            aspects = [mini_check_aspect],
            doc = "The hidden raw go_test, built with the instrumented SDK.",
        ),
        "metadata": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = ddtest_transition,
            doc = "Bazel-owned target metadata copied next to emitted test payloads.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
    doc = "The public test target of a Go test instrumented by ddtest.",
)
