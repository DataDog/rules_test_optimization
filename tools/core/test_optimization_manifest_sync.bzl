# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Manifest-driven Test Optimization repository support.

This API is intentionally separate from `test_optimization_multi_sync`:

- static multi-sync accepts a checked-in service list and fans out repositories;
- manifest sync accepts an invocation-scoped manifest and writes one aggregate
  repository containing every selected Go/Python context.

The helpers in this file keep manifest validation and generated source
deterministic so they can be tested without executing a repository rule.
"""

load(
    "//tools/core:common_utils.bzl",
    "fail_with_prefix",
    "sanitize_label_fragment",
    "validate_runtime_name",
    "validate_runtime_version",
    "validate_service_name",
    _is_dict = "is_dict",
    _is_list = "is_list",
    _is_string = "is_string",
)
load(
    "//tools/core:test_optimization_sync.bzl",
    "materialize_test_optimization_context",
    "render_test_optimization_module_runfiles",
    "test_optimization_enabled",
    "test_optimization_repository_environ",
)

_OWNER = "test_optimization_manifest_sync"
_SCHEMA_VERSION = 1
_MANIFEST_ENV = "DD_TEST_OPTIMIZATION_SERVICES_MANIFEST"
_SUPPORTED_RUNTIMES = ["go", "python"]
_SERVICE_DERIVATIONS = ["application", "domain_fallback"]

def _fail(message):
    fail_with_prefix(_OWNER, message)

def _unexpected_keys(value, allowed):
    out = []
    for key in value.keys():
        if key not in allowed:
            out.append(key)
    return sorted(out)

def _validate_keys(value, allowed, location):
    unexpected = _unexpected_keys(value, allowed)
    if unexpected:
        _fail("%s contains unsupported keys: %s" % (location, ", ".join(unexpected)))

def _required_string(value, field_name):
    if not _is_string(value) or not value.strip():
        _fail("%s must be a non-empty string" % field_name)
    return value.strip()

def _optional_string(value, field_name):
    if value == None:
        return ""
    if not _is_string(value):
        _fail("%s must be a string when set" % field_name)
    return value.strip()

def _context_key(service, runtime_name):
    return "%s__%s" % (
        sanitize_label_fragment(service),
        sanitize_label_fragment(runtime_name),
    )

def _validate_local_target_label(label):
    raw_label = label
    label = _required_string(label, "targets[].label")
    if label != raw_label:
        _fail("targets[].label must not contain leading or trailing whitespace, got %r" % raw_label)
    if not label.startswith("//") or label.startswith("@"):
        _fail("targets[].label must be a canonical local label, got %r" % label)
    for index in range(len(label)):
        ch = label[index]
        if ch <= " ":
            _fail("targets[].label must not contain whitespace or control characters, got %r" % label)
    label_parts = label.split(":")
    if len(label_parts) != 2:
        _fail("targets[].label must contain exactly one ':', got %r" % label)
    package = label_parts[0][2:]
    target = label_parts[1]
    if not target:
        _fail("targets[].label must include a non-empty target name, got %r" % label)
    if package:
        for component in package.split("/"):
            if not component or component in [".", ".."]:
                _fail("targets[].label contains an unsupported package component, got %r" % label)
    for component in target.split("/"):
        if not component or component in [".", ".."]:
            _fail("targets[].label contains an unsupported target component, got %r" % label)
    if "*" in label or "..." in label or "\\" in label:
        _fail("targets[].label must be fully expanded, got %r" % label)
    return label

def _normalize_runtime(runtime, location):
    if not _is_dict(runtime):
        _fail("%s must be an object" % location)
    _validate_keys(runtime, ["name", "version", "arch", "module_path"], location)
    runtime_name = _required_string(runtime.get("name"), "%s.name" % location)
    validate_runtime_name(runtime_name, False)
    if runtime_name not in _SUPPORTED_RUNTIMES:
        _fail(
            "%s.name %r is not supported by manifest onboarding; expected one of: %s" %
            (location, runtime_name, ", ".join(_SUPPORTED_RUNTIMES)),
        )
    runtime_version = _required_string(runtime.get("version"), "%s.version" % location)
    validate_runtime_version(runtime_version, False)
    module_path = _required_string(runtime.get("module_path"), "%s.module_path" % location)
    runtime_arch = _optional_string(runtime.get("arch"), "%s.arch" % location)
    return {
        "name": runtime_name,
        "version": runtime_version,
        "arch": runtime_arch,
        "module_path": module_path,
    }

def _normalize_context(raw_context, index):
    location = "contexts[%d]" % index
    if not _is_dict(raw_context):
        _fail("%s must be an object" % location)
    _validate_keys(raw_context, ["key", "service", "runtime"], location)
    service = _required_string(raw_context.get("service"), "%s.service" % location)
    validate_service_name(service, False)
    runtime = _normalize_runtime(raw_context.get("runtime"), "%s.runtime" % location)
    expected_key = _context_key(service, runtime["name"])
    key = _required_string(raw_context.get("key"), "%s.key" % location)
    if key != expected_key:
        _fail(
            "%s.key must be %r for service %r and runtime %r, got %r" %
            (location, expected_key, service, runtime["name"], key),
        )
    return {
        "key": key,
        "service": service,
        "runtime": runtime,
    }

def _normalize_target(raw_target, index, contexts):
    location = "targets[%d]" % index
    if not _is_dict(raw_target):
        _fail("%s must be an object" % location)
    _validate_keys(raw_target, ["label", "context_key", "service_derivation"], location)
    label = _validate_local_target_label(raw_target.get("label"))
    context_key = _required_string(raw_target.get("context_key"), "%s.context_key" % location)
    if context_key not in contexts:
        _fail("%s.context_key %r does not reference a declared context" % (location, context_key))
    derivation = _required_string(
        raw_target.get("service_derivation"),
        "%s.service_derivation" % location,
    )
    if derivation not in _SERVICE_DERIVATIONS:
        _fail(
            "%s.service_derivation must be one of: %s" %
            (location, ", ".join(_SERVICE_DERIVATIONS)),
        )
    return {
        "label": label,
        "context_key": context_key,
        "service_derivation": derivation,
    }

def _normalize_manifest(value):
    """Validate and deterministically normalize a decoded manifest object."""
    if not _is_dict(value):
        _fail("manifest root must be an object")
    _validate_keys(value, ["schema_version", "contexts", "targets"], "manifest")
    if value.get("schema_version") != _SCHEMA_VERSION:
        _fail(
            "unsupported schema_version %r; expected %d" %
            (value.get("schema_version"), _SCHEMA_VERSION),
        )

    raw_contexts = value.get("contexts")
    raw_targets = value.get("targets")
    if not _is_list(raw_contexts) or not raw_contexts:
        _fail("contexts must be a non-empty list")
    if not _is_list(raw_targets) or not raw_targets:
        _fail("targets must be a non-empty list")

    contexts_by_key = {}
    for index in range(len(raw_contexts)):
        context = _normalize_context(raw_contexts[index], index)
        key = context["key"]
        if key in contexts_by_key:
            _fail("duplicate context key %r" % key)
        contexts_by_key[key] = context

    targets_by_label = {}
    used_contexts = {}
    for index in range(len(raw_targets)):
        target = _normalize_target(raw_targets[index], index, contexts_by_key)
        label = target["label"]
        if label in targets_by_label:
            _fail("duplicate target label %r" % label)
        targets_by_label[label] = target
        used_contexts[target["context_key"]] = True

    unused_contexts = []
    for key in contexts_by_key.keys():
        if key not in used_contexts:
            unused_contexts.append(key)
    if unused_contexts:
        _fail("manifest contains contexts with no selected targets: %s" % ", ".join(sorted(unused_contexts)))

    return {
        "schema_version": _SCHEMA_VERSION,
        "contexts": [contexts_by_key[key] for key in sorted(contexts_by_key.keys())],
        "targets": [targets_by_label[label] for label in sorted(targets_by_label.keys())],
    }

def _decode_manifest(content):
    """Decode and normalize manifest JSON content."""
    if not _is_string(content) or not content.strip():
        _fail("manifest file must contain non-empty UTF-8 JSON")
    return _normalize_manifest(json.decode(content))

def _render_expected_targets(manifest):
    """Render the exact sorted selected-target contract for doctor."""
    labels = [target["label"] for target in manifest["targets"]]
    return json.encode({
        "schema_version": _SCHEMA_VERSION,
        "targets": labels,
    }) + "\n"

def _render_disabled_export():
    """Render the stable manifest-repository export used while disabled."""
    return (
        "# Generated by test_optimization_manifest_sync\n" +
        "enabled = False\n" +
        "topt_data_by_target = {}\n" +
        "topt_data_by_context = {}\n" +
        "target_context_keys = {}\n"
    )

def _empty_expected_targets():
    return json.encode({
        "schema_version": _SCHEMA_VERSION,
        "targets": [],
    }) + "\n"

def _render_disabled_build():
    return (
        "filegroup(\n" +
        '    name = "test_optimization_files",\n' +
        "    srcs = [],\n" +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        "filegroup(\n" +
        '    name = "test_optimization_context",\n' +
        "    srcs = [],\n" +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        "filegroup(\n" +
        '    name = "expected_targets",\n' +
        '    srcs = ["expected_targets.json"],\n' +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        'exports_files(["export.bzl", "expected_targets.json"], visibility = ["//visibility:public"])\n'
    )

def _runtime_exports(materialized):
    runtime = materialized["runtime"]
    return {
        "go": {
            "module_path": runtime["go_module_path"],
            "sanitized_module_path": runtime["sanitized_go_module_path"],
            "module_included": runtime["go_module_included"],
        },
        "python": {
            "module_path": runtime["python_module_path"],
            "sanitized_module_path": runtime["sanitized_python_module_path"],
            "module_included": runtime["python_module_included"],
        },
    }

def _context_topt_data(aggregate_repo_name, context_key, materialized):
    module_labels = [
        "@%s//:module_%s_%s" % (aggregate_repo_name, context_key, label)
        for label in materialized["labels"]
    ]
    module_group_names = [
        "module_%s" % label
        for label in materialized["labels"]
    ]
    return {
        "enabled": True,
        "repo_name": "%s_%s" % (aggregate_repo_name, context_key),
        "service_name": materialized["service"],
        "manifest_path": materialized["manifest_file"],
        "labels": materialized["labels"],
        "set": {label: True for label in materialized["labels"]},
        "runtimes": _runtime_exports(materialized),
        "files_label": "@%s//:test_optimization_files_%s" % (aggregate_repo_name, context_key),
        "manifest_label": "@%s//:%s" % (aggregate_repo_name, materialized["manifest_file"]),
        "module_labels": module_labels,
        "module_group_names": module_group_names,
        "context_label": "@%s//:test_optimization_context_%s" % (aggregate_repo_name, context_key),
    }

def _render_enabled_export(manifest, aggregate_repo_name, materialized_by_context):
    lines = [
        "# Generated by test_optimization_manifest_sync",
        "enabled = True",
        "topt_data_by_context = {",
    ]
    for context in manifest["contexts"]:
        key = context["key"]
        lines.append("    %s: %s," % (
            json.encode(key),
            repr(_context_topt_data(aggregate_repo_name, key, materialized_by_context[key])),
        ))
    lines.extend([
        "}",
        "target_context_keys = {",
    ])
    for target in manifest["targets"]:
        lines.append("    %s: %s," % (
            json.encode(target["label"]),
            json.encode(target["context_key"]),
        ))
    lines.extend([
        "}",
        "topt_data_by_target = {",
    ])
    for target in manifest["targets"]:
        lines.append("    %s: topt_data_by_context[%s]," % (
            json.encode(target["label"]),
            json.encode(target["context_key"]),
        ))
    lines.extend([
        "}",
        "",
    ])
    return "\n".join(lines)

def _render_context_filegroup(name, srcs):
    return (
        "filegroup(\n" +
        '    name = "%s",\n' % name +
        "    srcs = %s,\n" % repr(srcs) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n"
    )

def _render_module_target(name, files):
    return (
        "topt_module_files(\n" +
        '    name = "%s",\n' % name +
        "    settings = %s,\n" % json.encode(files["settings"]) +
        "    manifest = %s,\n" % json.encode(files["manifest"]) +
        (("    known_tests = %s,\n" % json.encode(files["known_tests"])) if files["known_tests"] else "") +
        (("    test_management = %s,\n" % json.encode(files["test_management"])) if files["test_management"] else "") +
        (("    flaky_tests = %s,\n" % json.encode(files["flaky_tests"])) if files["flaky_tests"] else "") +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n"
    )

def _render_enabled_build(manifest, materialized_by_context):
    content = (
        'load(":module_runfiles.bzl", "topt_module_files")\n' +
        'load("@datadog-rules-test-optimization//tools/core:test_optimization_context_utils.bzl", "test_optimization_context_bundle")\n\n'
    )
    aggregate_files = []
    context_targets = []
    context_keys = []
    exported_files = ["export.bzl", "expected_targets.json"]
    for context in manifest["contexts"]:
        key = context["key"]
        materialized = materialized_by_context[key]
        aggregate_files.extend(materialized["exports"])
        context_targets.append(":test_optimization_context_%s" % key)
        context_keys.append(key)
        exported_files.append(materialized["manifest_file"])
        content += _render_context_filegroup(
            "test_optimization_files_%s" % key,
            materialized["exports"],
        )
        content += _render_context_filegroup(
            "test_optimization_context_%s" % key,
            materialized["context_files"],
        )
        for label in materialized["labels"]:
            content += _render_module_target(
                "module_%s_%s" % (key, label),
                materialized["module_files"][label],
            )

    content += _render_context_filegroup("test_optimization_files", aggregate_files)
    content += (
        "test_optimization_context_bundle(\n" +
        '    name = "test_optimization_context",\n' +
        "    contexts = %s,\n" % repr(context_targets) +
        "    context_keys = %s,\n" % repr(context_keys) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n"
    )
    content += _render_context_filegroup("expected_targets", ["expected_targets.json"])
    content += "exports_files(%s, visibility = [\"//visibility:public\"])\n" % repr(exported_files)
    return content

def _manifest_summary(manifest):
    """Return deterministic counts for diagnostics and tests."""
    services = {}
    derivations = {}
    for context in manifest["contexts"]:
        services[context["service"]] = True
    for target in manifest["targets"]:
        derivation = target["service_derivation"]
        derivations[derivation] = derivations.get(derivation, 0) + 1
    return {
        "contexts": len(manifest["contexts"]),
        "services": len(services),
        "targets": len(manifest["targets"]),
        "application_targets": derivations.get("application", 0),
        "domain_fallback_targets": derivations.get("domain_fallback", 0),
    }

# Public aliases for focused unit tests. The repository rule below consumes the
# same helpers so validation cannot drift between tests and production.
context_key_for_tests = _context_key
decode_manifest_for_tests = _decode_manifest
manifest_summary_for_tests = _manifest_summary
normalize_manifest_for_tests = _normalize_manifest
render_disabled_manifest_export_for_tests = _render_disabled_export
render_disabled_manifest_build_for_tests = _render_disabled_build
render_enabled_manifest_build_for_tests = _render_enabled_build
render_enabled_manifest_export_for_tests = _render_enabled_export
render_expected_targets_for_tests = _render_expected_targets

def _write_disabled_repository(ctx):
    ctx.file("export.bzl", _render_disabled_export())
    ctx.file("expected_targets.json", _empty_expected_targets())
    ctx.file("BUILD", _render_disabled_build())

def _manifest_sync_impl(ctx):
    enabled = test_optimization_enabled(
        ctx.attr.enabled,
        ctx.attr.enabled_by_env,
        ctx.os.environ.get("DD_TEST_OPTIMIZATION_ENABLED", ""),
    )
    if not enabled:
        _write_disabled_repository(ctx)
        return

    manifest_path = (ctx.os.environ.get(_MANIFEST_ENV) or "").strip()
    if not manifest_path:
        _fail("%s must point to the invocation-scoped manifest while enabled" % _MANIFEST_ENV)
    manifest = _decode_manifest(ctx.read(ctx.path(manifest_path)))

    aggregate_repo_name = ctx.attr.repo_name or ctx.name
    context_root = (ctx.attr.out_dir or "contexts").strip().strip("/")
    if not context_root:
        _fail("out_dir must be a non-empty relative path")

    materialized_by_context = {}
    for context in manifest["contexts"]:
        key = context["key"]
        materialized_by_context[key] = materialize_test_optimization_context(
            ctx,
            {
                "out_dir": "%s/%s/.testoptimization" % (context_root, key),
                "repo_name": "%s_%s" % (aggregate_repo_name, key),
                "service": context["service"],
                "runtime": context["runtime"],
                "runtime_module_path_is_authoritative": True,
                "known_tests": ctx.attr.known_tests,
                "test_management": ctx.attr.test_management,
                "flaky_tests": ctx.attr.flaky_tests,
                "require_git_metadata": ctx.attr.require_git_metadata,
                "debug": ctx.attr.debug,
            },
            emit_surface = False,
        )

    ctx.file("expected_targets.json", _render_expected_targets(manifest))
    ctx.file("export.bzl", _render_enabled_export(manifest, aggregate_repo_name, materialized_by_context))
    ctx.file("module_runfiles.bzl", render_test_optimization_module_runfiles(ctx.name, ""))
    ctx.file("BUILD", _render_enabled_build(manifest, materialized_by_context))

test_optimization_manifest_sync = repository_rule(
    implementation = _manifest_sync_impl,
    attrs = {
        "repo_name": attr.string(),
        "out_dir": attr.string(default = "contexts"),
        "http_connect_timeout_seconds": attr.int(default = -1),
        "http_max_time_seconds": attr.int(default = -1),
        "http_retry_attempts": attr.int(default = -1),
        "http_retry_delay_seconds": attr.int(default = -1),
        "http_execute_timeout_buffer_seconds": attr.int(default = -1),
        "known_tests": attr.bool(default = True),
        "test_management": attr.bool(default = True),
        "flaky_tests": attr.bool(default = True),
        "enabled": attr.bool(default = True),
        "enabled_by_env": attr.bool(default = True),
        "require_git_metadata": attr.bool(default = False),
        "debug": attr.bool(default = False),
    },
    environ = test_optimization_repository_environ + [_MANIFEST_ENV],
    local = True,
)

def _manifest_sync_extension_impl(module_ctx):
    seen = {}
    for mod in module_ctx.modules:
        owner = mod.name or "<unnamed-module>"
        for call in mod.tags.test_optimization_manifest_sync:
            previous = seen.get(call.name)
            if previous != None:
                _fail(
                    "duplicate repository name %r declared by modules %r and %r" %
                    (call.name, previous, owner),
                )
            seen[call.name] = owner
            test_optimization_manifest_sync(
                name = call.name,
                repo_name = call.name,
                out_dir = call.out_dir,
                http_connect_timeout_seconds = call.http_connect_timeout_seconds,
                http_max_time_seconds = call.http_max_time_seconds,
                http_retry_attempts = call.http_retry_attempts,
                http_retry_delay_seconds = call.http_retry_delay_seconds,
                http_execute_timeout_buffer_seconds = call.http_execute_timeout_buffer_seconds,
                known_tests = call.known_tests,
                test_management = call.test_management,
                flaky_tests = call.flaky_tests,
                enabled = call.enabled,
                enabled_by_env = call.enabled_by_env,
                require_git_metadata = call.require_git_metadata,
                debug = call.debug,
            )

_manifest_sync_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "out_dir": attr.string(default = "contexts"),
    "http_connect_timeout_seconds": attr.int(default = -1),
    "http_max_time_seconds": attr.int(default = -1),
    "http_retry_attempts": attr.int(default = -1),
    "http_retry_delay_seconds": attr.int(default = -1),
    "http_execute_timeout_buffer_seconds": attr.int(default = -1),
    "known_tests": attr.bool(default = True),
    "test_management": attr.bool(default = True),
    "flaky_tests": attr.bool(default = True),
    "enabled": attr.bool(default = True),
    "enabled_by_env": attr.bool(default = True),
    "require_git_metadata": attr.bool(default = False),
    "debug": attr.bool(default = False),
})

test_optimization_manifest_sync_extension = module_extension(
    implementation = _manifest_sync_extension_impl,
    tag_classes = {
        "test_optimization_manifest_sync": _manifest_sync_tag,
    },
)
