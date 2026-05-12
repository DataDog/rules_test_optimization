# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""WORKSPACE repository helpers for Datadog Go Test Optimization onboarding.

This file is intentionally generic: it wires the Datadog Go companion module
and one published rules_go Orchestrion variant, but it does not encode any
consumer-specific services, targets, scheduling policy, or local wrappers.
"""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "//tools/core:common_utils.bzl",
    "fail_with_prefix",
)

_OWNER = "datadog_go_test_optimization_workspace_repositories"
_GO_COMPANION_REPO = "datadog-rules-test-optimization-go"
_VALID_FETCH_MODES = ["git", "archive"]
_RULES_GO_VARIANT_PREFIXES = {
    "base": "third_party/rules_go_orchestrion_base",
    "complete": "third_party/rules_go_orchestrion_complete",
}

def _archive_attrs(name, url, sha256, strip_prefix, archive_type, repo_mapping = None):
    """Return a normalized http_archive spec attrs dict."""
    attrs = {
        "name": name,
        "sha256": sha256,
        "strip_prefix": strip_prefix,
        "type": archive_type,
        "urls": [url],
    }
    if repo_mapping:
        attrs["repo_mapping"] = repo_mapping
    return attrs

def _git_attrs(name, remote, commit, strip_prefix, repo_mapping = None):
    """Return a normalized git_repository spec attrs dict."""
    attrs = {
        "name": name,
        "commit": commit,
        "remote": remote,
        "strip_prefix": strip_prefix,
    }
    if repo_mapping:
        attrs["repo_mapping"] = repo_mapping
    return attrs

def _fail_existing_repo(name):
    """Fail with a concrete fix when the helper would redeclare a repository."""
    fail_with_prefix(
        _OWNER,
        (
            "repository '%s' is already declared. Remove the manual declaration " +
            "for '%s', or choose a different rules_go_repo_name when the " +
            "collision is for the rules_go fork. Example:\n\n" +
            "datadog_go_test_optimization_workspace_repositories(\n" +
            "    rto_commit = \"<published-sha>\",\n" +
            "    rules_go_repo_name = \"io_bazel_rules_go\",\n" +
            ")\n"
        ) % (name, name),
    )

def _validate_fetch_mode(value, attr_name):
    """Validate a repository fetch mode."""
    if value not in _VALID_FETCH_MODES:
        fail_with_prefix(
            _OWNER,
            "%s must be one of %s, got %r" % (attr_name, _VALID_FETCH_MODES, value),
        )

def _validate_variant(value):
    """Validate the published rules_go Orchestrion variant name."""
    if value not in _RULES_GO_VARIANT_PREFIXES:
        fail_with_prefix(
            _OWNER,
            "rules_go_variant must be one of %s, got %r" % (sorted(_RULES_GO_VARIANT_PREFIXES.keys()), value),
        )

def _require_archive_attrs(url, sha256, prefix, archive_type):
    """Validate archive-mode inputs shared by Datadog and rules_go archives."""
    missing = []
    if not url:
        missing.append("rto_archive_url")
    if not sha256:
        missing.append("rto_archive_sha256")
    if not prefix:
        missing.append("rto_archive_prefix")
    if not archive_type:
        missing.append("rto_archive_type")
    if missing:
        fail_with_prefix(_OWNER, "archive fetch mode requires: %s" % ", ".join(missing))

def _build_workspace_repository_specs(
        rto_commit,
        rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
        datadog_fetch = "git",
        rules_go_fetch = "git",
        rules_go_repo_name = "io_bazel_rules_go",
        rules_go_variant = "base",
        rto_archive_url = None,
        rto_archive_sha256 = None,
        rto_archive_prefix = None,
        rto_archive_type = "tar.gz",
        existing_repositories = None):
    """Build normalized repository specs for the WORKSPACE helper.

    Args:
      rto_commit: Published commit to use for git_repository fetches.
      rto_remote: Git remote for Datadog repositories.
      datadog_fetch: Fetch mode for the Go companion repository.
      rules_go_fetch: Fetch mode for the rules_go Orchestrion fork.
      rules_go_repo_name: Repository name used by the consumer for rules_go.
      rules_go_variant: Published variant, either "base" or "complete".
      rto_archive_url: Archive URL used by archive fetch mode.
      rto_archive_sha256: Archive SHA256 used by archive fetch mode.
      rto_archive_prefix: Archive root prefix used by archive fetch mode.
      rto_archive_type: Archive type passed to http_archive.
      existing_repositories: Optional native.existing_rules()-style dict for tests.

    Returns:
      A list of repository specs with `kind` and `attrs` fields.
    """
    _validate_fetch_mode(datadog_fetch, "datadog_fetch")
    _validate_fetch_mode(rules_go_fetch, "rules_go_fetch")
    _validate_variant(rules_go_variant)

    if not rto_commit and (datadog_fetch == "git" or rules_go_fetch == "git"):
        fail_with_prefix(_OWNER, "rto_commit is required when datadog_fetch or rules_go_fetch is 'git'")
    if not rto_remote and (datadog_fetch == "git" or rules_go_fetch == "git"):
        fail_with_prefix(_OWNER, "rto_remote is required when datadog_fetch or rules_go_fetch is 'git'")
    if not rules_go_repo_name:
        fail_with_prefix(_OWNER, "rules_go_repo_name must be non-empty")

    if datadog_fetch == "archive" or rules_go_fetch == "archive":
        _require_archive_attrs(rto_archive_url, rto_archive_sha256, rto_archive_prefix, rto_archive_type)

    existing = existing_repositories or {}
    for repo_name in [_GO_COMPANION_REPO, rules_go_repo_name]:
        if repo_name in existing:
            _fail_existing_repo(repo_name)

    rules_go_strip_prefix = _RULES_GO_VARIANT_PREFIXES[rules_go_variant]
    companion_repo_mapping = {"@rules_go": "@" + rules_go_repo_name}

    specs = []
    if datadog_fetch == "git":
        specs.append({
            "kind": "git_repository",
            "attrs": _git_attrs(
                _GO_COMPANION_REPO,
                rto_remote,
                rto_commit,
                "modules/go",
                repo_mapping = companion_repo_mapping,
            ),
        })
    else:
        specs.append({
            "kind": "http_archive",
            "attrs": _archive_attrs(
                _GO_COMPANION_REPO,
                rto_archive_url,
                rto_archive_sha256,
                rto_archive_prefix + "/modules/go",
                rto_archive_type,
                repo_mapping = companion_repo_mapping,
            ),
        })

    if rules_go_fetch == "git":
        specs.append({
            "kind": "git_repository",
            "attrs": _git_attrs(
                rules_go_repo_name,
                rto_remote,
                rto_commit,
                rules_go_strip_prefix,
            ),
        })
    else:
        specs.append({
            "kind": "http_archive",
            "attrs": _archive_attrs(
                rules_go_repo_name,
                rto_archive_url,
                rto_archive_sha256,
                rto_archive_prefix + "/" + rules_go_strip_prefix,
                rto_archive_type,
            ),
        })

    return specs

def _materialize_repository_spec(spec):
    """Declare one repository from a normalized spec."""
    attrs = spec["attrs"]
    if spec["kind"] == "git_repository":
        if attrs.get("repo_mapping"):
            git_repository(
                name = attrs["name"],
                commit = attrs["commit"],
                remote = attrs["remote"],
                repo_mapping = attrs["repo_mapping"],
                strip_prefix = attrs["strip_prefix"],
            )
        else:
            git_repository(
                name = attrs["name"],
                commit = attrs["commit"],
                remote = attrs["remote"],
                strip_prefix = attrs["strip_prefix"],
            )
    elif spec["kind"] == "http_archive":
        if attrs.get("repo_mapping"):
            http_archive(
                name = attrs["name"],
                repo_mapping = attrs["repo_mapping"],
                sha256 = attrs["sha256"],
                strip_prefix = attrs["strip_prefix"],
                type = attrs["type"],
                urls = attrs["urls"],
            )
        else:
            http_archive(
                name = attrs["name"],
                sha256 = attrs["sha256"],
                strip_prefix = attrs["strip_prefix"],
                type = attrs["type"],
                urls = attrs["urls"],
            )
    else:
        fail_with_prefix(_OWNER, "unsupported repository spec kind %r" % spec["kind"])

def datadog_go_test_optimization_workspace_repositories(
        rto_commit,
        rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
        datadog_fetch = "git",
        rules_go_fetch = "git",
        rules_go_repo_name = "io_bazel_rules_go",
        rules_go_variant = "base",
        rto_archive_url = None,
        rto_archive_sha256 = None,
        rto_archive_prefix = None,
        rto_archive_type = "tar.gz"):
    """Declare Go Test Optimization repositories for WORKSPACE consumers.

    The consumer must declare `datadog-rules-test-optimization` before loading
    this helper. This helper wires only the Go companion repository and the
    selected rules_go Orchestrion fork variant.
    """
    specs = _build_workspace_repository_specs(
        rto_commit = rto_commit,
        rto_remote = rto_remote,
        datadog_fetch = datadog_fetch,
        rules_go_fetch = rules_go_fetch,
        rules_go_repo_name = rules_go_repo_name,
        rules_go_variant = rules_go_variant,
        rto_archive_url = rto_archive_url,
        rto_archive_sha256 = rto_archive_sha256,
        rto_archive_prefix = rto_archive_prefix,
        rto_archive_type = rto_archive_type,
        existing_repositories = native.existing_rules(),
    )
    for spec in specs:
        _materialize_repository_spec(spec)

# Public aliases for Starlark unit tests.
build_workspace_repository_specs_for_tests = _build_workspace_repository_specs
