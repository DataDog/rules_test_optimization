"""Environment/CI metadata helpers for test_optimization_sync.

This file exists to keep `test_optimization_sync.bzl` focused on orchestration
and payload generation logic.
"""

_MAX_REF_STRIP_ITERATIONS = 8

_BASE_SYNC_ENVIRONMENT_KEYS = [
    "DD_SITE",
    "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
    "DD_SERVICE",
    "DD_ENV",
    "DD_GIT_REPOSITORY_URL",
    "DD_GIT_BRANCH",
    "DD_GIT_TAG",
    "DD_GIT_COMMIT_SHA",
    "DD_GIT_HEAD_COMMIT",
    "DD_GIT_COMMIT_MESSAGE",
    "DD_GIT_HEAD_MESSAGE",
    "DD_GIT_COMMIT_AUTHOR_NAME",
    "DD_GIT_COMMIT_AUTHOR_EMAIL",
    "DD_GIT_COMMIT_AUTHOR_DATE",
    "DD_GIT_COMMIT_COMMITTER_NAME",
    "DD_GIT_COMMIT_COMMITTER_EMAIL",
    "DD_GIT_COMMIT_COMMITTER_DATE",
    "DD_GIT_HEAD_AUTHOR_NAME",
    "DD_GIT_HEAD_AUTHOR_EMAIL",
    "DD_GIT_HEAD_AUTHOR_DATE",
    "DD_GIT_HEAD_COMMITTER_NAME",
    "DD_GIT_HEAD_COMMITTER_EMAIL",
    "DD_GIT_HEAD_COMMITTER_DATE",
    "DD_GIT_PR_BASE_BRANCH",
    "DD_GIT_PR_BASE_BRANCH_SHA",
    "DD_GIT_PR_BASE_BRANCH_HEAD_SHA",
    "DD_PR_NUMBER",
]

_PROVIDER_ENVIRONMENT_KEYS = {
    "appveyor": [
        "APPVEYOR",
        "APPVEYOR_REPO_PROVIDER",
        "APPVEYOR_REPO_NAME",
        "APPVEYOR_REPO_COMMIT",
        "APPVEYOR_REPO_BRANCH",
        "APPVEYOR_REPO_TAG_NAME",
        "APPVEYOR_BUILD_FOLDER",
        "APPVEYOR_BUILD_ID",
        "APPVEYOR_BUILD_NUMBER",
        "APPVEYOR_REPO_COMMIT_MESSAGE",
        "APPVEYOR_REPO_COMMIT_MESSAGE_EXTENDED",
        "APPVEYOR_REPO_COMMIT_AUTHOR",
        "APPVEYOR_REPO_COMMIT_AUTHOR_EMAIL",
        "APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH",
        "APPVEYOR_PULL_REQUEST_HEAD_COMMIT",
        "APPVEYOR_PULL_REQUEST_NUMBER",
    ],
    "azurepipelines": [
        "TF_BUILD",
        "SYSTEM_PULLREQUEST_SOURCEBRANCH",
        "BUILD_SOURCEBRANCH",
        "BUILD_SOURCEBRANCHNAME",
        "SYSTEM_PULLREQUEST_SOURCEREPOSITORYURI",
        "BUILD_REPOSITORY_URI",
        "SYSTEM_PULLREQUEST_SOURCECOMMITID",
        "BUILD_SOURCEVERSION",
        "BUILD_SOURCEVERSIONMESSAGE",
        "BUILD_SOURCESDIRECTORY",
        "BUILD_BUILDID",
        "BUILD_DEFINITIONNAME",
        "SYSTEM_TEAMFOUNDATIONSERVERURI",
        "SYSTEM_TEAMPROJECTID",
        "SYSTEM_STAGEDISPLAYNAME",
        "SYSTEM_JOBID",
        "SYSTEM_JOBDISPLAYNAME",
        "SYSTEM_TASKINSTANCEID",
        "BUILD_REQUESTEDFORID",
        "BUILD_REQUESTEDFOREMAIL",
        "SYSTEM_PULLREQUEST_TARGETBRANCH",
        "SYSTEM_PULLREQUEST_PULLREQUESTNUMBER",
    ],
    "bitbucket": [
        "BITBUCKET_COMMIT",
        "BITBUCKET_GIT_SSH_ORIGIN",
        "BITBUCKET_GIT_HTTP_ORIGIN",
        "BITBUCKET_BRANCH",
        "BITBUCKET_TAG",
        "BITBUCKET_CLONE_DIR",
        "BITBUCKET_PIPELINE_UUID",
        "BITBUCKET_BUILD_NUMBER",
        "BITBUCKET_REPO_FULL_NAME",
        "BITBUCKET_PR_DESTINATION_BRANCH",
        "BITBUCKET_PR_ID",
        "BITBUCKET_REPO_SLUG",
    ],
    "buddy": [
        "BUDDY",
        "BUDDY_PIPELINE_ID",
        "BUDDY_EXECUTION_ID",
        "BUDDY_PIPELINE_NAME",
        "BUDDY_EXECUTION_URL",
        "BUDDY_EXECUTION_REVISION",
        "BUDDY_EXECUTION_REVISION_COMMIT_ID",
        "BUDDY_SCM_URL",
        "BUDDY_REPO_URL",
        "BUDDY_EXECUTION_BRANCH",
        "BUDDY_EXECUTION_BRANCH_NAME",
        "BUDDY_EXECUTION_TAG",
        "BUDDY_EXECUTION_REVISION_MESSAGE",
        "BUDDY_EXECUTION_REVISION_COMMITTER_NAME",
        "BUDDY_EXECUTION_REVISION_COMMITTER_EMAIL",
        "BUDDY_RUN_PR_BASE_BRANCH",
        "BUDDY_RUN_PR_NO",
    ],
    "buildkite": [
        "BUILDKITE",
        "BUILDKITE_BRANCH",
        "BUILDKITE_COMMIT",
        "BUILDKITE_REPO",
        "BUILDKITE_TAG",
        "BUILDKITE_BUILD_ID",
        "BUILDKITE_PIPELINE_SLUG",
        "BUILDKITE_BUILD_NUMBER",
        "BUILDKITE_BUILD_URL",
        "BUILDKITE_JOB_ID",
        "BUILDKITE_BUILD_CHECKOUT_PATH",
        "BUILDKITE_MESSAGE",
        "BUILDKITE_BUILD_AUTHOR",
        "BUILDKITE_BUILD_AUTHOR_EMAIL",
        "BUILDKITE_AGENT_ID",
        "BUILDKITE_PULL_REQUEST_BASE_BRANCH",
        "BUILDKITE_PULL_REQUEST",
        "BUILDKITE_AGENT_META_DATA_QUEUE",
    ],
    "circleci": [
        "CIRCLECI",
        "CIRCLE_REPOSITORY_URL",
        "CIRCLE_SHA1",
        "CIRCLE_TAG",
        "CIRCLE_BRANCH",
        "CIRCLE_WORKING_DIRECTORY",
        "CIRCLE_WORKFLOW_ID",
        "CIRCLE_PROJECT_REPONAME",
        "CIRCLE_BUILD_NUM",
        "CIRCLE_BUILD_URL",
        "CIRCLE_JOB",
        "CIRCLE_PR_NUMBER",
    ],
    "github": [
        "GITHUB_SHA",
        "GITHUB_HEAD_REF",
        "GITHUB_REF",
        "GITHUB_REPOSITORY",
        "GITHUB_SERVER_URL",
        "GITHUB_WORKSPACE",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_RUN_NUMBER",
        "GITHUB_WORKFLOW",
        "GITHUB_JOB",
        "GITHUB_EVENT_PATH",
        "JOB_CHECK_RUN_ID",
    ],
    "gitlab": [
        "GITLAB_CI",
        "CI_REPOSITORY_URL",
        "CI_COMMIT_SHA",
        "CI_COMMIT_BRANCH",
        "CI_COMMIT_REF_NAME",
        "CI_COMMIT_TAG",
        "CI_PROJECT_DIR",
        "CI_PIPELINE_ID",
        "CI_PROJECT_PATH",
        "CI_PIPELINE_IID",
        "CI_PIPELINE_URL",
        "CI_JOB_URL",
        "CI_JOB_ID",
        "CI_JOB_NAME",
        "CI_JOB_STAGE",
        "CI_COMMIT_MESSAGE",
        "CI_RUNNER_ID",
        "CI_RUNNER_TAGS",
        "CI_COMMIT_AUTHOR",
        "CI_COMMIT_TIMESTAMP",
        "CI_PROJECT_URL",
        "CI_MERGE_REQUEST_SOURCE_BRANCH_SHA",
        "CI_MERGE_REQUEST_TARGET_BRANCH_SHA",
        "CI_MERGE_REQUEST_DIFF_BASE_SHA",
        "CI_MERGE_REQUEST_TARGET_BRANCH_NAME",
        "CI_MERGE_REQUEST_IID",
    ],
    "jenkins": [
        "JENKINS_URL",
        "GIT_URL",
        "GIT_URL_1",
        "GIT_COMMIT",
        "GIT_BRANCH",
        "WORKSPACE",
        "BUILD_TAG",
        "BUILD_NUMBER",
        "JOB_NAME",
        "BUILD_URL",
        "NODE_NAME",
        "NODE_LABELS",
        "CHANGE_ID",
        "CHANGE_TARGET",
        "DD_CUSTOM_TRACE_ID",
    ],
    "teamcity": [
        "TEAMCITY_VERSION",
        "BUILD_URL",
        "TEAMCITY_BUILDCONF_NAME",
        "TEAMCITY_PULLREQUEST_NUMBER",
        "TEAMCITY_PULLREQUEST_TARGET_BRANCH",
        "GIT_URL",
        "GIT_COMMIT",
        "GIT_BRANCH",
    ],
    "travisci": [
        "TRAVIS",
        "TRAVIS_PULL_REQUEST_SLUG",
        "TRAVIS_REPO_SLUG",
        "TRAVIS_COMMIT",
        "TRAVIS_TAG",
        "TRAVIS_PULL_REQUEST_BRANCH",
        "TRAVIS_BRANCH",
        "TRAVIS_BUILD_DIR",
        "TRAVIS_BUILD_ID",
        "TRAVIS_BUILD_NUMBER",
        "TRAVIS_BUILD_WEB_URL",
        "TRAVIS_JOB_WEB_URL",
        "TRAVIS_COMMIT_MESSAGE",
        "TRAVIS_PULL_REQUEST_SHA",
        "TRAVIS_PULL_REQUEST",
    ],
    "bitrise": [
        "BITRISE_BUILD_SLUG",
        "GIT_REPOSITORY_URL",
        "BITRISE_GIT_COMMIT",
        "GIT_CLONE_COMMIT_HASH",
        "BITRISEIO_PULL_REQUEST_HEAD_BRANCH",
        "BITRISE_GIT_BRANCH",
        "BITRISE_GIT_TAG",
        "BITRISE_SOURCE_DIR",
        "BITRISE_TRIGGERED_WORKFLOW_ID",
        "BITRISE_BUILD_NUMBER",
        "BITRISE_BUILD_URL",
        "BITRISE_GIT_MESSAGE",
        "BITRISEIO_GIT_BRANCH_DEST",
        "BITRISE_PULL_REQUEST",
    ],
    "codefresh": [
        "CF_BUILD_ID",
        "CF_PIPELINE_NAME",
        "CF_BUILD_URL",
        "CF_STEP_NAME",
        "CF_BRANCH",
        "CF_PULL_REQUEST_TARGET",
        "CF_PULL_REQUEST_NUMBER",
        "CF_REVISION",
        "CF_REPO_URL",
        "CF_REPO_OWNER",
        "CF_REPO_NAME",
    ],
    "awscodepipeline": [
        "CODEBUILD_INITIATOR",
        "DD_PIPELINE_EXECUTION_ID",
        "DD_ACTION_EXECUTION_ID",
        "CODEBUILD_BUILD_ARN",
        "CODEBUILD_SOURCE_REPO_URL",
        "CODEBUILD_RESOLVED_SOURCE_VERSION",
        "CODEBUILD_WEBHOOK_HEAD_REF",
        "CODEBUILD_SOURCE_VERSION",
    ],
    "drone": [
        "DRONE",
        "DRONE_BRANCH",
        "DRONE_COMMIT_SHA",
        "DRONE_GIT_HTTP_URL",
        "DRONE_TAG",
        "DRONE_BUILD_NUMBER",
        "DRONE_BUILD_LINK",
        "DRONE_COMMIT_MESSAGE",
        "DRONE_COMMIT_AUTHOR_NAME",
        "DRONE_COMMIT_AUTHOR_EMAIL",
        "DRONE_WORKSPACE",
        "DRONE_STEP_NAME",
        "DRONE_STAGE_NAME",
        "DRONE_PULL_REQUEST",
        "DRONE_TARGET_BRANCH",
    ],
}

def _unique_env_keys(keys):
    seen = {}
    result = []
    for key in keys:
        if not seen.get(key):
            seen[key] = True
            result.append(key)
    return result

SYNC_ENVIRONMENT_KEYS = _unique_env_keys(
    _BASE_SYNC_ENVIRONMENT_KEYS +
    [key for provider_keys in _PROVIDER_ENVIRONMENT_KEYS.values() for key in provider_keys]
)
ALL_SYNC_ENV_KEYS = SYNC_ENVIRONMENT_KEYS

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

def _new_env_data(attr_service, environ):
    return {
        "dd_site": environ.get("DD_SITE") or "",
        "dd_api_base": environ.get("DD_TEST_OPTIMIZATION_AGENTLESS_URL") or "",
        "service": (attr_service or environ.get("DD_SERVICE") or "unnamed-service"),
        "environment": environ.get("DD_ENV") or "CI",
        "repository_url": "",
        "branch": "",
        "tag": "",
        "sha": "",
        "head_sha": "",
        "commit_message": "",
        "head_message": "",
        "commit_author_name": "",
        "commit_author_email": "",
        "commit_author_date": "",
        "commit_committer_name": "",
        "commit_committer_email": "",
        "commit_committer_date": "",
        "head_author_name": "",
        "head_author_email": "",
        "head_author_date": "",
        "head_committer_name": "",
        "head_committer_email": "",
        "head_committer_date": "",
        "pr_number": "",
        "pr_base_branch": "",
        "pr_base_branch_sha": "",
        "pr_base_branch_head_sha": "",
        "ci_provider_name": "",
        "ci_workspace_path": "",
        "ci_pipeline_id": "",
        "ci_pipeline_name": "",
        "ci_pipeline_number": "",
        "ci_pipeline_url": "",
        "ci_job_id": "",
        "ci_job_name": "",
        "ci_job_url": "",
        "ci_stage_name": "",
        "ci_node_name": "",
        "ci_node_labels": "",
        "ci_env_vars_json": "",
    }

def _set_if_value(env_data, key, value):
    if value:
        env_data[key] = value

def _json_env_subset(environ, keys):
    data = {}
    for key in keys:
        value = environ.get(key)
        if value:
            data[key] = value
    if not data:
        return ""
    return json.encode(data)

def _json_list(values):
    if not values:
        return ""
    return json.encode(values)

def _branch_or_tag_from_ref(value):
    if not value:
        return {"branch": "", "tag": ""}
    if "tags/" in value:
        return {"branch": "", "tag": normalize_ref(value)}
    return {"branch": normalize_ref(value), "tag": ""}

def _trim_wrapping_braces(value):
    if not value:
        return ""
    if value.startswith("{") and value.endswith("}") and len(value) > 1:
        return value[1:-1]
    return value

def _parse_author(author):
    if not author:
        return {"name": "", "email": ""}
    lt = author.find("<")
    gt = author.rfind(">")
    if lt >= 0 and gt > lt:
        return {
            "name": author[:lt].strip(),
            "email": author[lt + 1:gt].strip(),
        }
    return {"name": author.strip(), "email": ""}

def _split_space_labels(value):
    if not value:
        return ""
    parts = []
    for part in value.split(" "):
        trimmed = part.strip()
        if trimmed:
            parts.append(trimmed)
    return _json_list(parts)

def _extract_prefixed_labels(environ, prefix):
    labels = []
    for key, value in environ.items():
        if key.startswith(prefix) and value:
            suffix = key[len(prefix):].lower()
            labels.append("%s:%s" % (suffix, value))
    if not labels:
        return ""
    labels = sorted(labels, reverse = True)
    return _json_list(labels)

def _clean_jenkins_job_name(job_name, branch_or_tag):
    """Match tracer cleanup so Jenkins matrix details do not pollute pipeline names."""
    name = job_name or ""
    normalized_branch = normalize_ref(branch_or_tag or "")
    if normalized_branch:
        name = name.replace("/%s" % normalized_branch, "")

    cleaned_parts = []
    for part in name.split("/"):
        if not part:
            continue
        if "=" in part:
            key, value = part.split("=", 1)
            if key and value != "":
                continue
        cleaned_parts.append(part)
    return "/".join(cleaned_parts)

def apply_github_event_payload(env_data, event_payload_raw):
    """Augment GitHub metadata from the event payload JSON when available."""
    if not event_payload_raw:
        return
    data = json.decode(event_payload_raw)
    if type(data) != "dict":
        return
    pull_request = data.get("pull_request")
    if type(pull_request) != "dict":
        return

    number = data.get("number")
    if number != None:
        env_data["pr_number"] = str(number)

    head = pull_request.get("head")
    if type(head) == "dict":
        _set_if_value(env_data, "head_sha", head.get("sha") or "")

    base = pull_request.get("base")
    if type(base) == "dict":
        _set_if_value(env_data, "pr_base_branch", base.get("ref") or "")
        _set_if_value(env_data, "pr_base_branch_head_sha", base.get("sha") or "")

def apply_dd_git_overrides(env_data, environ):
    """Apply DD_GIT_* overrides with explicit precedence."""
    mapping = {
        "DD_GIT_REPOSITORY_URL": ("repository_url", sanitize_repository_url),
        "DD_GIT_BRANCH": ("branch", normalize_ref),
        "DD_GIT_TAG": ("tag", normalize_ref),
        "DD_GIT_COMMIT_SHA": ("sha", None),
        "DD_GIT_HEAD_COMMIT": ("head_sha", None),
        "DD_GIT_COMMIT_MESSAGE": ("commit_message", None),
        "DD_GIT_HEAD_MESSAGE": ("head_message", None),
        "DD_GIT_COMMIT_AUTHOR_NAME": ("commit_author_name", None),
        "DD_GIT_COMMIT_AUTHOR_EMAIL": ("commit_author_email", None),
        "DD_GIT_COMMIT_AUTHOR_DATE": ("commit_author_date", None),
        "DD_GIT_COMMIT_COMMITTER_NAME": ("commit_committer_name", None),
        "DD_GIT_COMMIT_COMMITTER_EMAIL": ("commit_committer_email", None),
        "DD_GIT_COMMIT_COMMITTER_DATE": ("commit_committer_date", None),
        "DD_GIT_HEAD_AUTHOR_NAME": ("head_author_name", None),
        "DD_GIT_HEAD_AUTHOR_EMAIL": ("head_author_email", None),
        "DD_GIT_HEAD_AUTHOR_DATE": ("head_author_date", None),
        "DD_GIT_HEAD_COMMITTER_NAME": ("head_committer_name", None),
        "DD_GIT_HEAD_COMMITTER_EMAIL": ("head_committer_email", None),
        "DD_GIT_HEAD_COMMITTER_DATE": ("head_committer_date", None),
        "DD_GIT_PR_BASE_BRANCH": ("pr_base_branch", normalize_ref),
        "DD_GIT_PR_BASE_BRANCH_SHA": ("pr_base_branch_sha", None),
        "DD_GIT_PR_BASE_BRANCH_HEAD_SHA": ("pr_base_branch_head_sha", None),
        "DD_PR_NUMBER": ("pr_number", None),
    }
    for env_key, field_info in mapping.items():
        value = environ.get(env_key) or ""
        if not value:
            continue
        field_name = field_info[0]
        normalizer = field_info[1]
        env_data[field_name] = normalizer(value) if normalizer else value

def _extract_provider_env(environ, env_data):
    if environ.get("APPVEYOR"):
        env_data["ci_provider_name"] = "appveyor"
        repo_name = environ.get("APPVEYOR_REPO_NAME") or ""
        if (environ.get("APPVEYOR_REPO_PROVIDER") or "") == "github" and repo_name:
            env_data["repository_url"] = "https://github.com/%s.git" % repo_name
        else:
            env_data["repository_url"] = repo_name
        env_data["sha"] = environ.get("APPVEYOR_REPO_COMMIT") or ""
        env_data["branch"] = normalize_ref(first_env_from_environ(environ, ["APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH", "APPVEYOR_REPO_BRANCH"]))
        env_data["tag"] = normalize_ref(environ.get("APPVEYOR_REPO_TAG_NAME") or "")
        env_data["ci_workspace_path"] = environ.get("APPVEYOR_BUILD_FOLDER") or ""
        env_data["ci_pipeline_id"] = environ.get("APPVEYOR_BUILD_ID") or ""
        env_data["ci_pipeline_name"] = repo_name
        env_data["ci_pipeline_number"] = environ.get("APPVEYOR_BUILD_NUMBER") or ""
        if repo_name and env_data["ci_pipeline_id"]:
            url = "https://ci.appveyor.com/project/%s/builds/%s" % (repo_name, env_data["ci_pipeline_id"])
            env_data["ci_pipeline_url"] = url
            env_data["ci_job_url"] = url
        env_data["commit_message"] = (environ.get("APPVEYOR_REPO_COMMIT_MESSAGE") or "")
        extended = environ.get("APPVEYOR_REPO_COMMIT_MESSAGE_EXTENDED") or ""
        if extended:
            env_data["commit_message"] = "%s\n%s" % (env_data["commit_message"], extended) if env_data["commit_message"] else extended
        env_data["commit_author_name"] = environ.get("APPVEYOR_REPO_COMMIT_AUTHOR") or ""
        env_data["commit_author_email"] = environ.get("APPVEYOR_REPO_COMMIT_AUTHOR_EMAIL") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("APPVEYOR_REPO_BRANCH") or "")
        env_data["head_sha"] = environ.get("APPVEYOR_PULL_REQUEST_HEAD_COMMIT") or ""
        env_data["pr_number"] = environ.get("APPVEYOR_PULL_REQUEST_NUMBER") or ""
        return

    if environ.get("TF_BUILD"):
        env_data["ci_provider_name"] = "azurepipelines"
        ref = _branch_or_tag_from_ref(first_env_from_environ(environ, ["SYSTEM_PULLREQUEST_SOURCEBRANCH", "BUILD_SOURCEBRANCH", "BUILD_SOURCEBRANCHNAME"]))
        env_data["branch"] = ref.get("branch")
        env_data["tag"] = ref.get("tag")
        env_data["repository_url"] = first_env_from_environ(environ, ["SYSTEM_PULLREQUEST_SOURCEREPOSITORYURI", "BUILD_REPOSITORY_URI"])
        env_data["sha"] = first_env_from_environ(environ, ["SYSTEM_PULLREQUEST_SOURCECOMMITID", "BUILD_SOURCEVERSION"])
        env_data["commit_message"] = environ.get("BUILD_SOURCEVERSIONMESSAGE") or ""
        env_data["ci_workspace_path"] = environ.get("BUILD_SOURCESDIRECTORY") or ""
        env_data["ci_pipeline_id"] = environ.get("BUILD_BUILDID") or ""
        env_data["ci_pipeline_name"] = environ.get("BUILD_DEFINITIONNAME") or ""
        env_data["ci_pipeline_number"] = environ.get("BUILD_BUILDID") or ""
        if environ.get("SYSTEM_TEAMFOUNDATIONSERVERURI") and environ.get("SYSTEM_TEAMPROJECTID") and environ.get("BUILD_BUILDID"):
            base_url = "%s%s/_build/results?buildId=%s" % (
                environ.get("SYSTEM_TEAMFOUNDATIONSERVERURI"),
                environ.get("SYSTEM_TEAMPROJECTID"),
                environ.get("BUILD_BUILDID"),
            )
            env_data["ci_pipeline_url"] = base_url
            if environ.get("SYSTEM_JOBID") and environ.get("SYSTEM_TASKINSTANCEID"):
                env_data["ci_job_url"] = "%s&view=logs&j=%s&t=%s" % (base_url, environ.get("SYSTEM_JOBID"), environ.get("SYSTEM_TASKINSTANCEID"))
        env_data["ci_stage_name"] = environ.get("SYSTEM_STAGEDISPLAYNAME") or ""
        env_data["ci_job_id"] = environ.get("SYSTEM_JOBID") or ""
        env_data["ci_job_name"] = environ.get("SYSTEM_JOBDISPLAYNAME") or ""
        env_data["commit_author_name"] = environ.get("BUILD_REQUESTEDFORID") or ""
        env_data["commit_author_email"] = environ.get("BUILD_REQUESTEDFOREMAIL") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("SYSTEM_PULLREQUEST_TARGETBRANCH") or "")
        env_data["pr_number"] = environ.get("SYSTEM_PULLREQUEST_PULLREQUESTNUMBER") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["SYSTEM_TEAMPROJECTID", "BUILD_BUILDID", "SYSTEM_JOBID"])
        return

    if environ.get("BITBUCKET_COMMIT"):
        env_data["ci_provider_name"] = "bitbucket"
        env_data["repository_url"] = first_env_from_environ(environ, ["BITBUCKET_GIT_SSH_ORIGIN", "BITBUCKET_GIT_HTTP_ORIGIN"])
        if not env_data["repository_url"]:
            slug = environ.get("BITBUCKET_REPO_SLUG") or ""
            if slug:
                env_data["repository_url"] = "https://bitbucket.org/%s.git" % slug
        env_data["sha"] = environ.get("BITBUCKET_COMMIT") or ""
        env_data["branch"] = normalize_ref(environ.get("BITBUCKET_BRANCH") or "")
        env_data["tag"] = normalize_ref(environ.get("BITBUCKET_TAG") or "")
        env_data["ci_workspace_path"] = environ.get("BITBUCKET_CLONE_DIR") or ""
        env_data["ci_pipeline_id"] = _trim_wrapping_braces(environ.get("BITBUCKET_PIPELINE_UUID") or "")
        env_data["ci_pipeline_number"] = environ.get("BITBUCKET_BUILD_NUMBER") or ""
        env_data["ci_pipeline_name"] = environ.get("BITBUCKET_REPO_FULL_NAME") or ""
        if env_data["ci_pipeline_name"] and env_data["ci_pipeline_number"]:
            url = "https://bitbucket.org/%s/addon/pipelines/home#!/results/%s" % (env_data["ci_pipeline_name"], env_data["ci_pipeline_number"])
            env_data["ci_pipeline_url"] = url
            env_data["ci_job_url"] = url
        env_data["pr_base_branch"] = normalize_ref(environ.get("BITBUCKET_PR_DESTINATION_BRANCH") or "")
        env_data["pr_number"] = environ.get("BITBUCKET_PR_ID") or ""
        return

    if environ.get("BUDDY"):
        env_data["ci_provider_name"] = "buddy"
        pipeline_id = environ.get("BUDDY_PIPELINE_ID") or ""
        execution_id = environ.get("BUDDY_EXECUTION_ID") or ""
        if pipeline_id and execution_id:
            env_data["ci_pipeline_id"] = "%s/%s" % (pipeline_id, execution_id)
        env_data["ci_pipeline_name"] = environ.get("BUDDY_PIPELINE_NAME") or ""
        env_data["ci_pipeline_number"] = execution_id
        env_data["ci_pipeline_url"] = environ.get("BUDDY_EXECUTION_URL") or ""
        env_data["sha"] = first_env_from_environ(environ, ["BUDDY_EXECUTION_REVISION", "BUDDY_EXECUTION_REVISION_COMMIT_ID"])
        env_data["repository_url"] = first_env_from_environ(environ, ["BUDDY_SCM_URL", "BUDDY_REPO_URL"])
        env_data["branch"] = normalize_ref(first_env_from_environ(environ, ["BUDDY_EXECUTION_BRANCH", "BUDDY_EXECUTION_BRANCH_NAME"]))
        env_data["tag"] = normalize_ref(environ.get("BUDDY_EXECUTION_TAG") or "")
        env_data["commit_message"] = environ.get("BUDDY_EXECUTION_REVISION_MESSAGE") or ""
        env_data["commit_committer_name"] = environ.get("BUDDY_EXECUTION_REVISION_COMMITTER_NAME") or ""
        env_data["commit_committer_email"] = environ.get("BUDDY_EXECUTION_REVISION_COMMITTER_EMAIL") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("BUDDY_RUN_PR_BASE_BRANCH") or "")
        env_data["pr_number"] = environ.get("BUDDY_RUN_PR_NO") or ""
        return

    if environ.get("BUILDKITE"):
        env_data["ci_provider_name"] = "buildkite"
        env_data["branch"] = normalize_ref(environ.get("BUILDKITE_BRANCH") or "")
        env_data["sha"] = environ.get("BUILDKITE_COMMIT") or ""
        env_data["repository_url"] = environ.get("BUILDKITE_REPO") or ""
        env_data["tag"] = normalize_ref(environ.get("BUILDKITE_TAG") or "")
        env_data["ci_pipeline_id"] = environ.get("BUILDKITE_BUILD_ID") or ""
        env_data["ci_pipeline_name"] = environ.get("BUILDKITE_PIPELINE_SLUG") or ""
        env_data["ci_pipeline_number"] = environ.get("BUILDKITE_BUILD_NUMBER") or ""
        env_data["ci_pipeline_url"] = environ.get("BUILDKITE_BUILD_URL") or ""
        env_data["ci_job_id"] = environ.get("BUILDKITE_JOB_ID") or ""
        if env_data["ci_pipeline_url"] and env_data["ci_job_id"]:
            env_data["ci_job_url"] = "%s#%s" % (env_data["ci_pipeline_url"], env_data["ci_job_id"])
        env_data["ci_workspace_path"] = environ.get("BUILDKITE_BUILD_CHECKOUT_PATH") or ""
        env_data["commit_message"] = environ.get("BUILDKITE_MESSAGE") or ""
        env_data["commit_author_name"] = environ.get("BUILDKITE_BUILD_AUTHOR") or ""
        env_data["commit_author_email"] = environ.get("BUILDKITE_BUILD_AUTHOR_EMAIL") or ""
        env_data["ci_node_name"] = environ.get("BUILDKITE_AGENT_ID") or ""
        env_data["ci_node_labels"] = _extract_prefixed_labels(environ, "BUILDKITE_AGENT_META_DATA_")
        env_data["pr_base_branch"] = normalize_ref(environ.get("BUILDKITE_PULL_REQUEST_BASE_BRANCH") or "")
        env_data["pr_number"] = environ.get("BUILDKITE_PULL_REQUEST") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["BUILDKITE_BUILD_ID", "BUILDKITE_JOB_ID"])
        return

    if environ.get("CIRCLECI"):
        env_data["ci_provider_name"] = "circleci"
        env_data["repository_url"] = environ.get("CIRCLE_REPOSITORY_URL") or ""
        env_data["sha"] = environ.get("CIRCLE_SHA1") or ""
        env_data["tag"] = normalize_ref(environ.get("CIRCLE_TAG") or "")
        env_data["branch"] = normalize_ref(environ.get("CIRCLE_BRANCH") or "")
        env_data["ci_workspace_path"] = environ.get("CIRCLE_WORKING_DIRECTORY") or ""
        env_data["ci_pipeline_id"] = environ.get("CIRCLE_WORKFLOW_ID") or ""
        env_data["ci_pipeline_name"] = environ.get("CIRCLE_PROJECT_REPONAME") or ""
        env_data["ci_pipeline_number"] = environ.get("CIRCLE_BUILD_NUM") or ""
        if env_data["ci_pipeline_id"]:
            env_data["ci_pipeline_url"] = "https://app.circleci.com/pipelines/workflows/%s" % env_data["ci_pipeline_id"]
        env_data["ci_job_name"] = environ.get("CIRCLE_JOB") or ""
        env_data["ci_job_id"] = environ.get("CIRCLE_BUILD_NUM") or ""
        env_data["ci_job_url"] = environ.get("CIRCLE_BUILD_URL") or ""
        env_data["pr_number"] = environ.get("CIRCLE_PR_NUMBER") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["CIRCLE_BUILD_NUM", "CIRCLE_WORKFLOW_ID"])
        return

    if environ.get("GITHUB_SHA"):
        env_data["ci_provider_name"] = "github"
        branch_or_tag = first_env_from_environ(environ, ["GITHUB_HEAD_REF", "GITHUB_REF"])
        ref = _branch_or_tag_from_ref(branch_or_tag)
        env_data["branch"] = ref.get("branch")
        env_data["tag"] = ref.get("tag")
        server_url = (environ.get("GITHUB_SERVER_URL") or "https://github.com").rstrip("/")
        repository = environ.get("GITHUB_REPOSITORY") or ""
        if repository:
            env_data["repository_url"] = "%s/%s.git" % (server_url, repository)
        env_data["sha"] = environ.get("GITHUB_SHA") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("GITHUB_BASE_REF") or "")
        env_data["ci_workspace_path"] = environ.get("GITHUB_WORKSPACE") or ""
        env_data["ci_pipeline_number"] = environ.get("GITHUB_RUN_NUMBER") or ""
        env_data["ci_pipeline_name"] = environ.get("GITHUB_WORKFLOW") or ""
        pipeline_id = environ.get("GITHUB_RUN_ID") or ""
        env_data["ci_pipeline_id"] = pipeline_id
        if pipeline_id and repository:
            attempt = environ.get("GITHUB_RUN_ATTEMPT") or ""
            raw_repo = "%s/%s" % (server_url, repository)
            if attempt:
                env_data["ci_pipeline_url"] = "%s/actions/runs/%s/attempts/%s" % (raw_repo, pipeline_id, attempt)
            else:
                env_data["ci_pipeline_url"] = "%s/actions/runs/%s" % (raw_repo, pipeline_id)
            job_name = environ.get("GITHUB_JOB") or ""
            env_data["ci_job_name"] = job_name
            numeric_job_id = environ.get("JOB_CHECK_RUN_ID") or ""
            if numeric_job_id:
                env_data["ci_job_id"] = numeric_job_id
                env_data["ci_job_url"] = "%s/actions/runs/%s/job/%s" % (raw_repo, pipeline_id, numeric_job_id)
            else:
                env_data["ci_job_id"] = job_name
                if env_data["sha"]:
                    env_data["ci_job_url"] = "%s/commit/%s/checks" % (raw_repo, env_data["sha"])
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"])
        return

    if environ.get("GITLAB_CI"):
        env_data["ci_provider_name"] = "gitlab"
        env_data["repository_url"] = environ.get("CI_REPOSITORY_URL") or ""
        env_data["sha"] = environ.get("CI_COMMIT_SHA") or ""
        env_data["branch"] = normalize_ref(first_env_from_environ(environ, ["CI_COMMIT_BRANCH", "CI_COMMIT_REF_NAME"]))
        env_data["tag"] = normalize_ref(environ.get("CI_COMMIT_TAG") or "")
        env_data["ci_workspace_path"] = environ.get("CI_PROJECT_DIR") or ""
        env_data["ci_pipeline_id"] = environ.get("CI_PIPELINE_ID") or ""
        env_data["ci_pipeline_name"] = environ.get("CI_PROJECT_PATH") or ""
        env_data["ci_pipeline_number"] = environ.get("CI_PIPELINE_IID") or ""
        env_data["ci_pipeline_url"] = environ.get("CI_PIPELINE_URL") or ""
        env_data["ci_job_url"] = environ.get("CI_JOB_URL") or ""
        env_data["ci_job_id"] = environ.get("CI_JOB_ID") or ""
        env_data["ci_job_name"] = environ.get("CI_JOB_NAME") or ""
        env_data["ci_stage_name"] = environ.get("CI_JOB_STAGE") or ""
        env_data["commit_message"] = environ.get("CI_COMMIT_MESSAGE") or ""
        env_data["ci_node_name"] = environ.get("CI_RUNNER_ID") or ""
        env_data["ci_node_labels"] = environ.get("CI_RUNNER_TAGS") or ""
        author = _parse_author(environ.get("CI_COMMIT_AUTHOR") or "")
        env_data["commit_author_name"] = author.get("name")
        env_data["commit_author_email"] = author.get("email")
        env_data["commit_author_date"] = environ.get("CI_COMMIT_TIMESTAMP") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["CI_PROJECT_URL", "CI_PIPELINE_ID", "CI_JOB_ID"])
        env_data["head_sha"] = environ.get("CI_MERGE_REQUEST_SOURCE_BRANCH_SHA") or ""
        env_data["pr_base_branch_head_sha"] = environ.get("CI_MERGE_REQUEST_TARGET_BRANCH_SHA") or ""
        env_data["pr_base_branch_sha"] = environ.get("CI_MERGE_REQUEST_DIFF_BASE_SHA") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("CI_MERGE_REQUEST_TARGET_BRANCH_NAME") or "")
        env_data["pr_number"] = environ.get("CI_MERGE_REQUEST_IID") or ""
        return

    if environ.get("JENKINS_URL"):
        env_data["ci_provider_name"] = "jenkins"
        env_data["repository_url"] = first_env_from_environ(environ, ["GIT_URL", "GIT_URL_1"])
        env_data["sha"] = environ.get("GIT_COMMIT") or ""
        ref = _branch_or_tag_from_ref(environ.get("GIT_BRANCH") or "")
        env_data["branch"] = ref.get("branch")
        env_data["tag"] = ref.get("tag")
        env_data["ci_workspace_path"] = environ.get("WORKSPACE") or ""
        env_data["ci_pipeline_id"] = environ.get("BUILD_TAG") or ""
        env_data["ci_pipeline_number"] = environ.get("BUILD_NUMBER") or ""
        env_data["ci_pipeline_name"] = _clean_jenkins_job_name(environ.get("JOB_NAME") or "", environ.get("GIT_BRANCH") or "")
        env_data["ci_pipeline_url"] = environ.get("BUILD_URL") or ""
        env_data["ci_node_name"] = environ.get("NODE_NAME") or ""
        env_data["pr_number"] = environ.get("CHANGE_ID") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("CHANGE_TARGET") or "")
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["DD_CUSTOM_TRACE_ID"])
        env_data["ci_node_labels"] = _split_space_labels(environ.get("NODE_LABELS") or "")
        return

    if environ.get("TEAMCITY_VERSION"):
        env_data["ci_provider_name"] = "teamcity"
        env_data["ci_job_url"] = environ.get("BUILD_URL") or ""
        env_data["ci_job_name"] = environ.get("TEAMCITY_BUILDCONF_NAME") or ""
        env_data["pr_number"] = environ.get("TEAMCITY_PULLREQUEST_NUMBER") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("TEAMCITY_PULLREQUEST_TARGET_BRANCH") or "")
        return

    if environ.get("TRAVIS"):
        env_data["ci_provider_name"] = "travisci"
        pr_slug = environ.get("TRAVIS_PULL_REQUEST_SLUG") or ""
        repo_slug = pr_slug or (environ.get("TRAVIS_REPO_SLUG") or "")
        if repo_slug:
            env_data["repository_url"] = "https://github.com/%s.git" % repo_slug
        env_data["sha"] = environ.get("TRAVIS_COMMIT") or ""
        env_data["tag"] = normalize_ref(environ.get("TRAVIS_TAG") or "")
        env_data["branch"] = normalize_ref(first_env_from_environ(environ, ["TRAVIS_PULL_REQUEST_BRANCH", "TRAVIS_BRANCH"]))
        env_data["ci_workspace_path"] = environ.get("TRAVIS_BUILD_DIR") or ""
        env_data["ci_pipeline_id"] = environ.get("TRAVIS_BUILD_ID") or ""
        env_data["ci_pipeline_number"] = environ.get("TRAVIS_BUILD_NUMBER") or ""
        env_data["ci_pipeline_name"] = repo_slug
        env_data["ci_pipeline_url"] = environ.get("TRAVIS_BUILD_WEB_URL") or ""
        env_data["ci_job_url"] = environ.get("TRAVIS_JOB_WEB_URL") or ""
        env_data["commit_message"] = environ.get("TRAVIS_COMMIT_MESSAGE") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("TRAVIS_BRANCH") or "")
        env_data["head_sha"] = environ.get("TRAVIS_PULL_REQUEST_SHA") or ""
        env_data["pr_number"] = environ.get("TRAVIS_PULL_REQUEST") or ""
        return

    if environ.get("BITRISE_BUILD_SLUG"):
        env_data["ci_provider_name"] = "bitrise"
        env_data["repository_url"] = environ.get("GIT_REPOSITORY_URL") or environ.get("BITRISE_GIT_REPOSITORY_URL") or ""
        env_data["sha"] = first_env_from_environ(environ, ["BITRISE_GIT_COMMIT", "GIT_CLONE_COMMIT_HASH"])
        env_data["branch"] = normalize_ref(first_env_from_environ(environ, ["BITRISEIO_PULL_REQUEST_HEAD_BRANCH", "BITRISE_GIT_BRANCH"]))
        env_data["tag"] = normalize_ref(environ.get("BITRISE_GIT_TAG") or "")
        env_data["ci_workspace_path"] = environ.get("BITRISE_SOURCE_DIR") or ""
        env_data["ci_pipeline_id"] = environ.get("BITRISE_BUILD_SLUG") or ""
        env_data["ci_pipeline_name"] = environ.get("BITRISE_TRIGGERED_WORKFLOW_ID") or ""
        env_data["ci_pipeline_number"] = environ.get("BITRISE_BUILD_NUMBER") or ""
        env_data["ci_pipeline_url"] = environ.get("BITRISE_BUILD_URL") or ""
        env_data["commit_message"] = environ.get("BITRISE_GIT_MESSAGE") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("BITRISEIO_GIT_BRANCH_DEST") or "")
        env_data["pr_number"] = environ.get("BITRISE_PULL_REQUEST") or ""
        return

    if environ.get("CF_BUILD_ID"):
        env_data["ci_provider_name"] = "codefresh"
        env_data["ci_pipeline_id"] = environ.get("CF_BUILD_ID") or ""
        env_data["ci_pipeline_name"] = environ.get("CF_PIPELINE_NAME") or ""
        env_data["ci_pipeline_url"] = environ.get("CF_BUILD_URL") or ""
        env_data["ci_job_name"] = environ.get("CF_STEP_NAME") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["CF_BUILD_ID"])
        ref = _branch_or_tag_from_ref(environ.get("CF_BRANCH") or "")
        env_data["branch"] = ref.get("branch")
        env_data["tag"] = ref.get("tag")
        env_data["pr_base_branch"] = normalize_ref(environ.get("CF_PULL_REQUEST_TARGET") or "")
        env_data["pr_number"] = environ.get("CF_PULL_REQUEST_NUMBER") or ""
        return

    if environ.get("CODEBUILD_INITIATOR"):
        if not (environ.get("CODEBUILD_INITIATOR") or "").startswith("codepipeline"):
            return
        env_data["ci_provider_name"] = "awscodepipeline"
        env_data["ci_pipeline_id"] = environ.get("DD_PIPELINE_EXECUTION_ID") or ""
        env_data["ci_job_id"] = environ.get("DD_ACTION_EXECUTION_ID") or ""
        env_data["ci_env_vars_json"] = _json_env_subset(environ, ["CODEBUILD_BUILD_ARN", "DD_ACTION_EXECUTION_ID", "DD_PIPELINE_EXECUTION_ID"])
        return

    if environ.get("DRONE"):
        env_data["ci_provider_name"] = "drone"
        env_data["branch"] = normalize_ref(environ.get("DRONE_BRANCH") or "")
        env_data["sha"] = environ.get("DRONE_COMMIT_SHA") or ""
        env_data["repository_url"] = environ.get("DRONE_GIT_HTTP_URL") or ""
        env_data["tag"] = normalize_ref(environ.get("DRONE_TAG") or "")
        env_data["ci_pipeline_number"] = environ.get("DRONE_BUILD_NUMBER") or ""
        env_data["ci_pipeline_url"] = environ.get("DRONE_BUILD_LINK") or ""
        env_data["commit_message"] = environ.get("DRONE_COMMIT_MESSAGE") or ""
        env_data["commit_author_name"] = environ.get("DRONE_COMMIT_AUTHOR_NAME") or ""
        env_data["commit_author_email"] = environ.get("DRONE_COMMIT_AUTHOR_EMAIL") or ""
        env_data["ci_workspace_path"] = environ.get("DRONE_WORKSPACE") or ""
        env_data["ci_job_name"] = environ.get("DRONE_STEP_NAME") or ""
        env_data["ci_stage_name"] = environ.get("DRONE_STAGE_NAME") or ""
        env_data["pr_number"] = environ.get("DRONE_PULL_REQUEST") or ""
        env_data["pr_base_branch"] = normalize_ref(environ.get("DRONE_TARGET_BRANCH") or "")
        return

def collect_env_from_environ(environ, attr_service = None, github_event_payload = None):
    """Collect CI/git/service context from a plain env mapping."""
    env_data = _new_env_data(attr_service, environ)
    _extract_provider_env(environ, env_data)
    if environ.get("GITHUB_SHA") and github_event_payload:
        apply_github_event_payload(env_data, github_event_payload)
    env_data["branch"] = normalize_ref(env_data.get("branch"))
    env_data["tag"] = normalize_ref(env_data.get("tag"))
    apply_dd_git_overrides(env_data, environ)
    env_data["branch"] = normalize_ref(env_data.get("branch"))
    env_data["tag"] = normalize_ref(env_data.get("tag"))
    env_data["pr_base_branch"] = normalize_ref(env_data.get("pr_base_branch"))
    env_data["repository_url"] = sanitize_repository_url(env_data.get("repository_url"))
    return env_data

def set_context_tag_from_env(environ, tags, env_key, tag_key):
    """Copy one optional environment variable into context tags."""
    value = environ.get(env_key)
    if value:
        tags[tag_key] = value
