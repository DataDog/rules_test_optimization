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

load("@io_bazel_rules_go//go:def.bzl", "GoArchive", "GoInfo")
load(":topt_go_ddtest_repository.bzl", "DDTEST_RELEASE", "MINI_REPO")

_BAZEL_TARGET_METADATA_OUTPUT = "bazel_target_metadata.json"
_SDK_NAME_SETTING = "@io_bazel_rules_go//go/toolchain:sdk_name"
_MINI_MODULE = "github.com/DataDog/ddtest/ddto"
_ARG_COUNT = "_DD_TOPT_WRAPPER_ARG_COUNT"
_ARG_PREFIX = "_DD_TOPT_WRAPPER_ARG_"

ToptGoTestArgsInfo = provider(
    doc = "Arguments expanded against the raw test's configured data, after rules_go transitions.",
    fields = {"args": "Expanded arguments in caller order."},
)

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

# Tokenization follows Bazel ShellUtils (Apache-2.0).
# Copyright 2014 The Bazel Authors. All rights reserved.
# https://github.com/bazelbuild/bazel/blob/8.4.1/src/main/java/com/google/devtools/build/lib/shell/ShellUtils.java
def _argument_words(value):
    """Bazel's Bourne-word splitting (no expansion or shell execution).

    Starlark has no API for TestRunner's already-tokenized args. Match
    ShellUtils.tokenize so moving args to the raw configuration preserves them.
    """
    words = []
    word = []
    quote = ""
    escaped = False
    force_word = False
    for char in value.elems():
        if escaped:
            if quote == '\"' and char not in ["\\", '\"']:
                word.append("\\")
            word.append(char)
            escaped = False
        elif quote:
            if char == quote:
                quote = ""
            elif char == "\\" and quote == '\"':
                escaped = True
            else:
                word.append(char)
        elif char in ["'", '\"']:
            quote = char
            force_word = True
        elif char in [" ", "\t"]:
            if word or force_word:
                words.append("".join(word))
                word = []
                force_word = False
        elif char == "\\":
            escaped = True
        else:
            word.append(char)
    if escaped:
        fail("ddtest_go_test: backslash at end of argument string")
    if quote:
        fail("ddtest_go_test: unterminated argument quotation")
    if word or force_word:
        words.append("".join(word))
    return words

argument_words_for_tests = _argument_words

def _argument_expressions(arg):
    expressions = []
    skip_until = 0
    for offset in range(len(arg)):
        if offset < skip_until:
            continue
        if arg[offset:offset + 2] == "$$":
            skip_until = offset + 2
        elif arg[offset:offset + 2] == "$(":
            end = arg.find(")", offset + 2)
            if end != -1:
                expressions.append((offset, end, arg[offset + 2:end]))
                skip_until = end + 1
    return expressions

def _expand_argument_locations(ctx, arg, data):
    # Resolve location functions before Make expansion; returned paths are
    # literal data, while the caller's $$ escapes remain untouched.
    fragments = []
    copied_until = 0
    for offset, end, expression in _argument_expressions(arg):
        if expression.split(" ", 1)[0] in ["location", "locations", "execpath", "execpaths", "rootpath", "rootpaths", "rlocationpath", "rlocationpaths"]:
            # TestRunner expands location(s) as runfiles-root paths.
            path_expression = expression
            if expression.startswith("location "):
                path_expression = "rootpath " + expression[len("location "):]
            elif expression.startswith("locations "):
                path_expression = "rootpaths " + expression[len("locations "):]
            value = ctx.expand_location("$(" + path_expression + ")", targets = data)
            fragments.extend([arg[copied_until:offset], value.replace("$", "$$")])
            copied_until = end + 1
    fragments.append(arg[copied_until:])
    return "".join(fragments)

def _test_args_aspect_impl(_target, ctx):
    args = []
    data = getattr(ctx.rule.attr, "data", []) or []
    raw_args = getattr(ctx.rule.attr, "args", []) or []

    # Native args also expand locations introduced recursively by --define.
    # Resolve only reachable variables: unrelated defines can name labels that
    # are not in this test's data. Native expansion enforces its depth limit.
    substitutions = {}
    pending = raw_args
    for _ in range(11):
        next_pending = []
        for value in pending:
            for _, _, expression in _argument_expressions(value):
                if expression in ctx.var and expression not in substitutions:
                    original = ctx.var[expression]
                    substitutions[expression] = _expand_argument_locations(ctx, original, data)
                    next_pending.append(original)
        pending = next_pending
        if not pending:
            break
    for arg in raw_args:
        expanded = ctx.expand_make_variables("args", _expand_argument_locations(ctx, arg, data), substitutions)
        args.extend(_argument_words(expanded))
    return [ToptGoTestArgsInfo(args = args)]

_test_args_aspect = aspect(implementation = _test_args_aspect_impl)

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
        "    override_repo(go_deps, com_github_datadog_ddtest_ddto = \"%s\")\n\n" +
        "In WORKSPACE, depend on @%s labels instead of another repository's copy " +
        "of github.com/DataDog/ddtest/ddto."
    ) % (test_label, ", ".join([str(label) for label in labels]), MINI_REPO, MINI_REPO, MINI_REPO, MINI_REPO)

# --- Registration -------------------------------------------------------

def _registration_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + "_zz_dd_ci_visibility_test.go")

    # rules_go compiles the test with the sources of the libraries it embeds
    # too, so a test whose sources all come through embed still has a package.
    embedded = [src for lib in ctx.attr.embed for src in lib[GoInfo].srcs]
    go_srcs = [src for src in ctx.files.srcs + embedded if src.extension == "go"]
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
        "embed": attr.label_list(providers = [GoInfo], doc = "The libraries that the test embeds."),
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
    """The launcher's name: Windows runs a native executable."""
    return label_name + (".exe" if is_windows else "")

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

configured_args=()
for ((i=0; i<${_DD_TOPT_WRAPPER_ARG_COUNT:-0}; i++)); do
  argument_name="_DD_TOPT_WRAPPER_ARG_$i"
  configured_args+=("${!argument_name}")
  unset "$argument_name"
done
unset _DD_TOPT_WRAPPER_ARG_COUNT
"$actual" ${configured_args[@]+"${configured_args[@]}"} "$@"
""" % (actual_filename, metadata_filename, _BAZEL_TARGET_METADATA_OUTPUT)

def _wrapped_actual_relpath(wrapper_basename, actual_label, executable):
    # rules_go places <out> under <target>_/. Preserve the whole suffix;
    # for nested target names that suffix itself has directory components.
    short_path = executable.short_path
    if short_path.startswith("../"):
        short_path = short_path.split("/", 2)[2]
    package_prefix = actual_label.package + "/" if actual_label.package else ""
    output_prefix = package_prefix + actual_label.name + "_/"
    suffix = short_path[len(output_prefix):] if short_path.startswith(output_prefix) else executable.basename
    return wrapper_basename + "__wrapped_/" + suffix

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

    # rules_go's cgo rpaths are relative to the binary's directory, one level
    # below the package. Keep that depth when materializing the transitioned test.
    actual_relpath = _wrapped_actual_relpath(out.basename, target.label, dep_exe)
    actual_out = ctx.actions.declare_file(actual_relpath, sibling = out)
    metadata_out = ctx.actions.declare_file(out.basename + "__wrapped_" + metadata_file.basename, sibling = out)

    # Materialize transitioned inputs next to the wrapper so the launcher does
    # not have to guess which configuration-specific paths Bazel chose.
    ctx.actions.symlink(output = actual_out, target_file = dep_exe)
    ctx.actions.symlink(output = metadata_out, target_file = metadata_file)
    configured_args = target[ToptGoTestArgsInfo].args
    wrapper_files = [actual_out, metadata_out]
    if is_windows:
        # A native launcher avoids cmd.exe interpreting configured or runtime
        # arguments. One shared Go binary serves every test in this platform.
        configuration = ctx.actions.declare_file(out.basename + ".json", sibling = out)
        ctx.actions.write(configuration, json.encode({
            "actual": actual_relpath,
            "metadata": metadata_out.basename,
            "args": configured_args,
        }))
        ctx.actions.symlink(output = out, target_file = ctx.executable._windows_launcher)
        wrapper_files.append(configuration)
    else:
        ctx.actions.write(
            output = out,
            content = _unix_wrapper_content(actual_relpath, metadata_out.basename),
            is_executable = True,
        )
    providers = [DefaultInfo(
        files = depset([out] + wrapper_files),
        runfiles = dep_runfiles.merge(ctx.runfiles(files = wrapper_files)),
        executable = out,
    )]
    run_environment = target[RunEnvironmentInfo] if RunEnvironmentInfo in target else None
    environment = dict(run_environment.environment) if run_environment != None else {}
    if configured_args and not is_windows:
        environment[_ARG_COUNT] = str(len(configured_args))
        for index, arg in enumerate(configured_args):
            environment[_ARG_PREFIX + str(index)] = arg
    if run_environment != None or configured_args:
        providers.append(RunEnvironmentInfo(
            environment = environment,
            inherited_environment = run_environment.inherited_environment if run_environment != None else [],
        ))
    execution_requirements = _test_execution_requirements(ctx.attr.tags)
    if execution_requirements:
        providers.append(testing.ExecutionInfo(requirements = execution_requirements))
    return providers

ddtest_go_test = rule(
    implementation = _ddtest_go_test_impl,
    attrs = {
        "_windows_launcher": attr.label(
            default = "//tools/testwrapper",
            executable = True,
            cfg = "target",
        ),
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = ddtest_transition,
            aspects = [mini_check_aspect, _test_args_aspect],
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
