"""Shared context.json helpers for uploader-like runtime rules.

These helpers keep `:test_optimization_context` discovery consistent between
the uploader and diagnostic rules that need to inspect the same generated sync
context without uploading payloads.
"""

load(
    "//tools/core:common_utils.bzl",
    "fail_with_prefix",
)

def context_manifest_content(entries):
    """Render deterministic context-manifest content from repo/path entries."""
    lines = []
    repo_keys = sorted(entries.keys())
    for repo_key in repo_keys:
        entry = entries[repo_key]
        lines.append("%s\t%s\t%s" % (repo_key, entry[0], entry[1]))
    return "\n".join(lines) + ("\n" if lines else "")

def apparent_repo_key_from_label_text_or_fail(label_text, owner, failure_owner):
    """Return the apparent external repo name from external label text."""
    if not label_text.startswith("@") or "//" not in label_text:
        fail_with_prefix(failure_owner, "context.json owner for %s must come from an external repo" % owner)
    repo_key = label_text.split("//", 1)[0]
    if repo_key.startswith("@@"):
        repo_key = repo_key[2:]
    elif repo_key.startswith("@"):
        repo_key = repo_key[1:]
    if not repo_key:
        fail_with_prefix(failure_owner, "context.json owner for %s must have a non-empty repo name" % owner)
    return repo_key

def apparent_repo_key_or_fail(label, failure_owner):
    """Return the apparent external repo name from the attribute label text."""
    return apparent_repo_key_from_label_text_or_fail(str(label), label, failure_owner)

def context_repo_key_from_label_text_or_none(label_text, label_name, failure_owner):
    """Return the sync repo key for supported context targets.

    Single-service sync repos expose `:test_optimization_context` directly, so
    the repo key is the apparent repo name. Multi-service aggregate repos expose
    service-qualified aliases named `:test_optimization_context_<service_key>`;
    those aliases point at generated repos named `<aggregate_repo>_<service_key>`.
    Returning that derived key preserves the runtime mapping used by payload
    metadata without forcing consumers to depend on per-service repos directly.
    """
    if label_name == "test_optimization_context":
        return apparent_repo_key_from_label_text_or_fail(label_text, label_text, failure_owner)

    prefix = "test_optimization_context_"
    if label_name.startswith(prefix):
        service_key = label_name[len(prefix):]
        if not service_key:
            fail_with_prefix(failure_owner, "context alias %s must include a non-empty service key" % label_text)
        return "%s_%s" % (
            apparent_repo_key_from_label_text_or_fail(label_text, label_text, failure_owner),
            service_key,
        )

    return None

def context_repo_key_or_none(label, failure_owner):
    """Return the sync repo key for a supported context target label."""
    return context_repo_key_from_label_text_or_none(str(label), label.name, failure_owner)

def legacy_single_context_entry_or_fail(data_files, failure_owner):
    """Return a single fallback entry for legacy direct context.json inputs.

    Older single-service workspaces may pass `context.json` directly, or wrap it
    in a local alias/filegroup, instead of depending on a
    `:test_optimization_context` target. That shape cannot support multi-context
    repo matching, but it should continue to work when exactly one bundled
    `context.json` exists.
    """
    raw_context_files = {}
    for f in data_files:
        if f.basename == "context.json":
            raw_context_files[f.path] = f

    if not raw_context_files:
        return {}

    if len(raw_context_files) > 1:
        fail_with_prefix(
            failure_owner,
            "bundled multiple context.json files without explicit context targets; pass :test_optimization_context targets or service-qualified :test_optimization_context_<service> aliases directly in data = [...] for multi-context selection",
        )

    context_file = raw_context_files.values()[0]
    return {
        "__single_context_fallback__": (context_file.short_path, context_file.path),
    }

def context_manifest_entries_or_fail(data_targets, data_files, failure_owner):
    """Collect bundled context.json files keyed by the source sync repo name.

    Under bzlmod, Bazel exposes canonical repo names in analysis, while payload
    metadata stores the apparent sync-repo name exported by companion macros
    (for example `test_optimization_data_python`). Runtime scripts match those
    apparent repo names directly.
    """
    entries = {}
    for dep in data_targets:
        repo_key = context_repo_key_or_none(dep.label, failure_owner)
        if repo_key == None:
            continue
        context_files = []
        for f in dep[DefaultInfo].files.to_list():
            if f.basename == "context.json":
                context_files.append(f)
        if len(context_files) != 1:
            fail_with_prefix(failure_owner, "expected exactly one context.json from %s, found %d" % (dep.label, len(context_files)))
        context_file = context_files[0]
        if repo_key in entries:
            fail_with_prefix(failure_owner, "duplicate bundled context repo name '%s'" % repo_key)
        entries[repo_key] = (context_file.short_path, context_file.path)

    if entries:
        return entries

    return legacy_single_context_entry_or_fail(data_files, failure_owner)
