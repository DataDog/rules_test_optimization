"""WORKSPACE repository helpers for Datadog Python Test Optimization onboarding.

This helper wires only the Datadog Python companion module. Python toolchains,
pip repositories, pytest, and ddtrace remain consumer-owned so repositories keep
their existing lockfile and dependency policy.
"""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "//tools/core:common_utils.bzl",
    "fail_with_prefix",
)

_OWNER = "datadog_python_test_optimization_workspace_repositories"
_PYTHON_COMPANION_REPO = "datadog-rules-test-optimization-python"
_VALID_FETCH_MODES = ["git", "archive"]

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
            "for '%s', or stop calling this helper for the Python companion repository. " +
            "If the collision is with a consumer-owned rules_python repository, keep " +
            "that repository and pass its name through rules_python_repo_name. " +
            "Example:\n\n" +
            "datadog_python_test_optimization_workspace_repositories(\n" +
            "    rto_commit = \"<published-sha>\",\n" +
            "    rules_python_repo_name = \"rules_python\",\n" +
            ")\n"
        ) % (name, name),
    )

def _fail_missing_rules_python_repo(name):
    """Fail when the consumer has not declared the mapped rules_python repo."""
    fail_with_prefix(
        _OWNER,
        (
            "rules_python repository '%s' is not declared. Declare rules_python " +
            "before calling this helper, or pass rules_python_repo_name with the " +
            "consumer-owned repository name. Example:\n\n" +
            "http_archive(\n" +
            "    name = \"%s\",\n" +
            "    ...\n" +
            ")\n\n" +
            "datadog_python_test_optimization_workspace_repositories(\n" +
            "    rto_commit = \"<published-sha>\",\n" +
            "    rules_python_repo_name = \"%s\",\n" +
            ")\n"
        ) % (name, name, name),
    )

def _validate_fetch_mode(value):
    """Validate the Python companion repository fetch mode."""
    if value not in _VALID_FETCH_MODES:
        fail_with_prefix(
            _OWNER,
            "datadog_fetch must be one of %s, got %r" % (_VALID_FETCH_MODES, value),
        )

def _require_archive_attrs(url, sha256, prefix, archive_type):
    """Validate archive-mode inputs for the Datadog Python companion archive."""
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

def _build_python_workspace_repository_specs(
        rto_commit,
        rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
        datadog_fetch = "git",
        rules_python_repo_name = "rules_python",
        rto_archive_url = None,
        rto_archive_sha256 = None,
        rto_archive_prefix = None,
        rto_archive_type = "tar.gz",
        existing_repositories = None):
    """Build normalized repository specs for the Python WORKSPACE helper.

    Args:
      rto_commit: Published commit to use for git_repository fetches.
      rto_remote: Git remote for Datadog repositories.
      datadog_fetch: Fetch mode for the Python companion repository.
      rules_python_repo_name: Repository name used by the consumer for rules_python.
      rto_archive_url: Archive URL used by archive fetch mode.
      rto_archive_sha256: Archive SHA256 used by archive fetch mode.
      rto_archive_prefix: Archive root prefix used by archive fetch mode.
      rto_archive_type: Archive type passed to http_archive.
      existing_repositories: Optional native.existing_rules()-style dict for tests.

    Returns:
      A list of repository specs with `kind` and `attrs` fields.
    """
    _validate_fetch_mode(datadog_fetch)

    if not rules_python_repo_name:
        fail_with_prefix(_OWNER, "rules_python_repo_name must be non-empty")
    if datadog_fetch == "git" and not rto_commit:
        fail_with_prefix(_OWNER, "rto_commit is required when datadog_fetch is 'git'")
    if datadog_fetch == "git" and not rto_remote:
        fail_with_prefix(_OWNER, "rto_remote is required when datadog_fetch is 'git'")
    if datadog_fetch == "archive":
        _require_archive_attrs(rto_archive_url, rto_archive_sha256, rto_archive_prefix, rto_archive_type)

    if existing_repositories != None:
        if _PYTHON_COMPANION_REPO in existing_repositories:
            _fail_existing_repo(_PYTHON_COMPANION_REPO)
        if rules_python_repo_name not in existing_repositories:
            _fail_missing_rules_python_repo(rules_python_repo_name)

    companion_repo_mapping = {"@rules_python": "@" + rules_python_repo_name}
    if datadog_fetch == "git":
        return [{
            "kind": "git_repository",
            "attrs": _git_attrs(
                _PYTHON_COMPANION_REPO,
                rto_remote,
                rto_commit,
                "modules/python",
                repo_mapping = companion_repo_mapping,
            ),
        }]

    return [{
        "kind": "http_archive",
        "attrs": _archive_attrs(
            _PYTHON_COMPANION_REPO,
            rto_archive_url,
            rto_archive_sha256,
            rto_archive_prefix + "/modules/python",
            rto_archive_type,
            repo_mapping = companion_repo_mapping,
        ),
    }]

def _materialize_repository_spec(spec):
    """Declare one repository from a normalized spec."""
    attrs = spec["attrs"]
    if spec["kind"] == "git_repository":
        git_repository(
            name = attrs["name"],
            commit = attrs["commit"],
            remote = attrs["remote"],
            repo_mapping = attrs["repo_mapping"],
            strip_prefix = attrs["strip_prefix"],
        )
    elif spec["kind"] == "http_archive":
        http_archive(
            name = attrs["name"],
            repo_mapping = attrs["repo_mapping"],
            sha256 = attrs["sha256"],
            strip_prefix = attrs["strip_prefix"],
            type = attrs["type"],
            urls = attrs["urls"],
        )
    else:
        fail_with_prefix(_OWNER, "unsupported repository spec kind %r" % spec["kind"])

def datadog_python_test_optimization_workspace_repositories(
        rto_commit,
        rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
        datadog_fetch = "git",
        rules_python_repo_name = "rules_python",
        rto_archive_url = None,
        rto_archive_sha256 = None,
        rto_archive_prefix = None,
        rto_archive_type = "tar.gz"):
    """Declare Python Test Optimization repositories for WORKSPACE consumers.

    The consumer must declare `datadog-rules-test-optimization` and
    `rules_python` before loading this helper. This helper wires only the Python
    companion repository.
    """
    specs = _build_python_workspace_repository_specs(
        rto_commit = rto_commit,
        rto_remote = rto_remote,
        datadog_fetch = datadog_fetch,
        rules_python_repo_name = rules_python_repo_name,
        rto_archive_url = rto_archive_url,
        rto_archive_sha256 = rto_archive_sha256,
        rto_archive_prefix = rto_archive_prefix,
        rto_archive_type = rto_archive_type,
        existing_repositories = native.existing_rules(),
    )
    for spec in specs:
        _materialize_repository_spec(spec)

# Public alias for Starlark unit tests.
build_python_workspace_repository_specs_for_tests = _build_python_workspace_repository_specs
