"""Environment/CI metadata helpers for test_optimization_sync.

This file exists to keep `test_optimization_sync.bzl` focused on orchestration
and payload generation logic.
"""

_MAX_REF_STRIP_ITERATIONS = 8

def first_env(ctx, keys):
    """Return the first non-empty environment value among candidate keys."""
    for k in keys:
        v = ctx.os.environ.get(k)
        if v:
            return v
    return ""

def first_env_from_environ(environ, keys):
    """Return first non-empty env value from a plain dict-like mapping."""
    for k in keys:
        v = environ.get(k)
        if v:
            return v
    return ""

def sanitize_repository_url(url):
    """Strip URL userinfo to avoid forwarding embedded credentials."""
    if not url:
        return ""
    scheme_idx = url.find("://")
    if scheme_idx < 0:
        return url
    auth_start = scheme_idx + 3
    slash_idx = url.find("/", auth_start)
    if slash_idx < 0:
        authority = url[auth_start:]
        suffix = ""
    else:
        authority = url[auth_start:slash_idx]
        suffix = url[slash_idx:]

    at_idx = -1
    for i in range(len(authority)):
        if authority[i] == "@":
            at_idx = i
    if at_idx < 0:
        return url
    return url[:auth_start] + authority[at_idx + 1:] + suffix

def normalize_ref(name):
    """Normalize branch/tag refs by removing common prefix forms."""
    if not name:
        return name

    # Keep a bounded loop so malformed cyclical prefixes cannot spin forever.
    for _ in range(_MAX_REF_STRIP_ITERATIONS):
        if name.startswith("refs/remotes/origin/"):
            name = name[len("refs/remotes/origin/"):]
            continue
        if name.startswith("refs/heads/"):
            name = name[len("refs/heads/"):]
            continue
        if name.startswith("refs/tags/"):
            name = name[len("refs/tags/"):]
            continue
        if name.startswith("refs/"):
            name = name[len("refs/"):]
            continue
        if name.startswith("remotes/origin/"):
            name = name[len("remotes/origin/"):]
            continue
        if name.startswith("origin/"):
            name = name[len("origin/"):]
            continue
        if name.startswith("tags/"):
            name = name[len("tags/"):]
            continue
        break
    return name

def apply_dd_git_overrides(env_data, environ):
    """Apply DD_GIT_* overrides with explicit precedence."""
    dd_repo = environ.get("DD_GIT_REPOSITORY_URL") or ""
    dd_branch = environ.get("DD_GIT_BRANCH") or ""
    dd_sha = environ.get("DD_GIT_COMMIT_SHA") or ""
    dd_head_sha = environ.get("DD_GIT_HEAD_COMMIT") or ""
    dd_commit_msg = environ.get("DD_GIT_COMMIT_MESSAGE") or ""
    dd_head_msg = environ.get("DD_GIT_HEAD_MESSAGE") or ""
    if dd_repo:
        env_data["repository_url"] = sanitize_repository_url(dd_repo)
    if dd_branch:
        env_data["branch"] = normalize_ref(dd_branch)
    if dd_sha:
        env_data["sha"] = dd_sha
    if dd_head_sha:
        env_data["head_sha"] = dd_head_sha
    if dd_commit_msg:
        env_data["commit_message"] = dd_commit_msg
    if dd_head_msg:
        env_data["head_message"] = dd_head_msg

def collect_env_from_environ(environ, attr_service = None):
    """Collect CI/git/service context from a plain env mapping."""
    env_data = {
        "dd_site": environ.get("DD_SITE") or "",
        "dd_api_base": environ.get("DD_TEST_OPTIMIZATION_AGENTLESS_URL") or "",
        "service": (attr_service or environ.get("DD_SERVICE") or "unnamed-service"),
        "environment": environ.get("DD_ENV") or "CI",
        "repository_url": "",
        "branch": "",
        "sha": "",
        "head_sha": "",
        "commit_message": "",
        "head_message": "",
    }

    provider = ""
    if environ.get("APPVEYOR"):
        provider = "appveyor"
        repo_name = environ.get("APPVEYOR_REPO_NAME") or ""
        if (environ.get("APPVEYOR_REPO_PROVIDER") or "") == "github" and repo_name:
            env_data["repository_url"] = "https://github.com/%s.git" % repo_name
        else:
            env_data["repository_url"] = repo_name
        env_data["sha"] = environ.get("APPVEYOR_REPO_COMMIT") or ""
        env_data["branch"] = first_env_from_environ(environ, ["APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH", "APPVEYOR_REPO_BRANCH"]) or ""
    elif environ.get("TF_BUILD"):
        provider = "azure_pipelines"
        env_data["repository_url"] = environ.get("BUILD_REPOSITORY_URI") or ""
        env_data["sha"] = environ.get("BUILD_SOURCEVERSION") or ""
        env_data["branch"] = environ.get("BUILD_SOURCEBRANCH") or ""
        env_data["commit_message"] = environ.get("BUILD_SOURCEVERSIONMESSAGE") or ""
    elif environ.get("BITBUCKET_COMMIT"):
        provider = "bitbucket"
        env_data["repository_url"] = (
            environ.get("BITBUCKET_GIT_HTTP_ORIGIN") or
            ("https://bitbucket.org/%s.git" % (environ.get("BITBUCKET_REPO_SLUG") or ""))
        )
        env_data["sha"] = environ.get("BITBUCKET_COMMIT") or ""
        env_data["branch"] = environ.get("BITBUCKET_BRANCH") or ""
    elif environ.get("BUDDY"):
        provider = "buddy"
        env_data["repository_url"] = first_env_from_environ(environ, [
            "BUDDY_SCM_URL",
            "BUDDY_REPO_URL",
        ]) or ""
        env_data["sha"] = first_env_from_environ(environ, [
            "BUDDY_EXECUTION_REVISION",
            "BUDDY_EXECUTION_REVISION_COMMIT_ID",
        ]) or ""
        env_data["branch"] = first_env_from_environ(environ, [
            "BUDDY_EXECUTION_BRANCH",
            "BUDDY_EXECUTION_BRANCH_NAME",
        ]) or ""
    elif environ.get("BUILDKITE"):
        provider = "buildkite"
        env_data["repository_url"] = environ.get("BUILDKITE_REPO") or ""
        env_data["sha"] = environ.get("BUILDKITE_COMMIT") or ""
        env_data["branch"] = environ.get("BUILDKITE_BRANCH") or ""
        env_data["commit_message"] = environ.get("BUILDKITE_MESSAGE") or ""
    elif environ.get("CIRCLECI"):
        provider = "circleci"
        env_data["repository_url"] = environ.get("CIRCLE_REPOSITORY_URL") or ""
        env_data["sha"] = environ.get("CIRCLE_SHA1") or ""
        env_data["branch"] = environ.get("CIRCLE_BRANCH") or ""
    elif environ.get("GITHUB_SHA"):
        provider = "github_actions"
        gh_repo = environ.get("GITHUB_REPOSITORY") or ""
        gh_server = environ.get("GITHUB_SERVER_URL") or "https://github.com"
        if gh_repo:
            env_data["repository_url"] = "%s/%s.git" % (gh_server, gh_repo)
        env_data["sha"] = environ.get("GITHUB_SHA") or ""
        env_data["branch"] = environ.get("GITHUB_HEAD_REF") or normalize_ref(environ.get("GITHUB_REF") or "")
    elif environ.get("GITLAB_CI"):
        provider = "gitlab"
        env_data["repository_url"] = environ.get("CI_REPOSITORY_URL") or ""
        env_data["sha"] = environ.get("CI_COMMIT_SHA") or ""
        env_data["branch"] = environ.get("CI_COMMIT_BRANCH") or ""
        env_data["commit_message"] = environ.get("CI_COMMIT_MESSAGE") or ""
        env_data["head_sha"] = environ.get("CI_MERGE_REQUEST_SOURCE_BRANCH_SHA") or ""
    elif environ.get("JENKINS_URL"):
        provider = "jenkins"
        env_data["repository_url"] = first_env_from_environ(environ, ["GIT_URL", "GIT_URL_1"]) or ""
        env_data["sha"] = environ.get("GIT_COMMIT") or ""
        env_data["branch"] = environ.get("GIT_BRANCH") or ""
    elif environ.get("TEAMCITY_VERSION"):
        provider = "teamcity"
        env_data["repository_url"] = environ.get("GIT_URL") or ""
        env_data["sha"] = environ.get("GIT_COMMIT") or ""
        env_data["branch"] = environ.get("GIT_BRANCH") or ""
    elif environ.get("TRAVIS"):
        provider = "travisci"
        slug = environ.get("TRAVIS_REPO_SLUG") or ""
        if slug:
            env_data["repository_url"] = "https://github.com/%s.git" % slug
        env_data["sha"] = environ.get("TRAVIS_COMMIT") or ""
        env_data["branch"] = first_env_from_environ(environ, ["TRAVIS_PULL_REQUEST_BRANCH", "TRAVIS_BRANCH"]) or ""
        env_data["commit_message"] = environ.get("TRAVIS_COMMIT_MESSAGE") or ""
    elif environ.get("BITRISE_BUILD_SLUG"):
        provider = "bitrise"
        env_data["repository_url"] = environ.get("BITRISE_GIT_REPOSITORY_URL") or ""
        env_data["sha"] = environ.get("BITRISE_GIT_COMMIT") or ""
        env_data["branch"] = environ.get("BITRISE_GIT_BRANCH") or ""
    elif environ.get("CF_BUILD_ID"):
        provider = "codefresh"
        env_data["branch"] = environ.get("CF_BRANCH") or ""
        env_data["sha"] = environ.get("CF_REVISION") or ""
        cf_repo_url = environ.get("CF_REPO_URL") or ""
        if cf_repo_url:
            env_data["repository_url"] = cf_repo_url
        else:
            owner = environ.get("CF_REPO_OWNER") or ""
            repo = environ.get("CF_REPO_NAME") or ""
            if owner and repo:
                env_data["repository_url"] = "https://github.com/%s/%s.git" % (owner, repo)
    elif environ.get("CODEBUILD_INITIATOR"):
        provider = "awscodebuild"
        env_data["repository_url"] = environ.get("CODEBUILD_SOURCE_REPO_URL") or ""
        env_data["sha"] = environ.get("CODEBUILD_RESOLVED_SOURCE_VERSION") or ""
        env_data["branch"] = first_env_from_environ(environ, [
            "CODEBUILD_WEBHOOK_HEAD_REF",
            "CODEBUILD_SOURCE_VERSION",
        ]) or ""
    elif environ.get("DRONE"):
        provider = "drone"
        env_data["repository_url"] = environ.get("DRONE_GIT_HTTP_URL") or ""
        env_data["sha"] = environ.get("DRONE_COMMIT_SHA") or ""
        env_data["branch"] = environ.get("DRONE_BRANCH") or ""
        env_data["commit_message"] = environ.get("DRONE_COMMIT_MESSAGE") or ""

    env_data["branch"] = normalize_ref(env_data.get("branch"))
    apply_dd_git_overrides(env_data, environ)
    env_data["repository_url"] = sanitize_repository_url(env_data.get("repository_url"))
    env_data["ci_provider_name"] = provider
    return env_data

def set_context_tag_from_env(environ, tags, env_key, tag_key):
    """Copy one optional environment variable into context tags."""
    value = environ.get(env_key)
    if value:
        tags[tag_key] = value
