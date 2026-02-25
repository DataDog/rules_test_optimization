"""Unit tests for sync utility helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/core:test_optimization_sync.bzl",
    "apply_dd_git_overrides_for_tests",
    "build_module_label_map_for_tests",
    "build_unix_read_abs_file_command_for_tests",
    "build_windows_read_abs_file_command_for_tests",
    "clone_payload_with_detached_attributes_for_tests",
    "collect_env_for_tests",
    "collect_env_from_environ_for_tests",
    "compute_dd_api_base_for_tests",
    "decode_json_object_or_fail_for_tests",
    "dirname_for_tests",
    "first_env_for_tests",
    "first_env_from_environ_for_tests",
    "fnv1a_32_for_tests",
    "http_execute_timeout_buffer_seconds_for_tests",
    "http_execute_timeout_seconds_for_tests",
    "http_max_time_seconds_for_tests",
    "http_retry_attempts_for_tests",
    "http_retry_delay_seconds_for_tests",
    "normalize_out_dir_or_fail_for_tests",
    "normalize_ref_for_tests",
    "parse_go_module_path_for_tests",
    "partition_unix_headers_for_tests",
    "record_sync_extension_repo_owner_or_fail_for_tests",
    "render_export_bzl_for_tests",
    "render_module_runfiles_bzl_for_tests",
    "resolve_dd_api_base_for_tests",
    "runtime_module_path_from_environ_for_tests",
    "sanitize_repository_url_for_tests",
    "set_context_tag_from_env_for_tests",
)
load(
    "//tools/tests:example_stub_repo.bzl",
    "bzl_string_literal_for_tests",
    "render_stub_build_for_tests",
)

def _contains_stripped_line(lines, expected):
    for line in lines:
        if line.strip() == expected:
            return True
    return False

def _dd_site_normalization_test(ctx):
    """Validate DD_SITE normalization into canonical API base URL."""
    env = unittest.begin(ctx)
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("app.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("api.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("https://app.datadoghq.com"))
    asserts.equals(env, "https://api.us5.datadoghq.com", compute_dd_api_base_for_tests("https://api.us5.datadoghq.com/"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests(""))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("   "))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("https://api.datadoghq.com/path"))
    asserts.equals(env, "https://api.datadoghq.eu", compute_dd_api_base_for_tests("http://app.datadoghq.eu/foo"))
    return unittest.end(env)

def _resolve_dd_api_base_test(ctx):
    """Validate DD_TEST_OPTIMIZATION_API_BASE override precedence."""
    env = unittest.begin(ctx)

    # Ensure overrides take precedence over DD_SITE-derived defaults.
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests("datadoghq.com", ""),
    )
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests("app.datadoghq.com", None),
    )
    asserts.equals(
        env,
        "https://example.com",
        resolve_dd_api_base_for_tests("datadoghq.com", "https://example.com"),
    )
    asserts.equals(
        env,
        "https://example.com",
        resolve_dd_api_base_for_tests("datadoghq.com", "https://example.com/"),
    )

    # None/empty inputs should still resolve to the default site endpoint.
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests(None, None),
    )
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests(None, ""),
    )
    return unittest.end(env)

def _module_label_map_collision_test(ctx):
    """Validate deterministic dedup when module labels collide."""
    env = unittest.begin(ctx)
    label_map = build_module_label_map_for_tests(["Foo-Bar"], ["Foo_Bar"])
    asserts.equals(env, 2, len(label_map))
    label_a = label_map.get("Foo-Bar")
    label_b = label_map.get("Foo_Bar")
    asserts.true(env, label_a != None)
    asserts.true(env, label_b != None)
    asserts.true(env, label_a != label_b)

    # Ensure ordering of inputs does not change the mapping
    label_map_rev = build_module_label_map_for_tests(["Foo_Bar"], ["Foo-Bar"])
    asserts.equals(env, label_a, label_map_rev.get("Foo-Bar"))
    asserts.equals(env, label_b, label_map_rev.get("Foo_Bar"))

    # Multiple collisions should dedup deterministically
    multi = build_module_label_map_for_tests(["a-b", "a_b"], ["a b"])
    asserts.equals(env, 3, len(multi))
    labels = [multi.get("a-b"), multi.get("a_b"), multi.get("a b")]
    asserts.true(env, labels[0] != labels[1])
    asserts.true(env, labels[0] != labels[2])
    asserts.true(env, labels[1] != labels[2])
    return unittest.end(env)

def _module_label_map_empty_inputs_test(ctx):
    """Validate empty/None module lists do not produce label entries."""
    env = unittest.begin(ctx)
    asserts.equals(env, {}, build_module_label_map_for_tests([], []))
    asserts.equals(env, {}, build_module_label_map_for_tests(None, []))
    asserts.equals(env, {}, build_module_label_map_for_tests([], None))
    asserts.equals(env, {}, build_module_label_map_for_tests(None, None))
    return unittest.end(env)

def _normalize_ref_test(ctx):
    """Validate ref-prefix normalization helper."""
    env = unittest.begin(ctx)
    asserts.equals(env, "main", normalize_ref_for_tests("refs/heads/main"))
    asserts.equals(env, "v1.2.3", normalize_ref_for_tests("refs/tags/v1.2.3"))
    asserts.equals(env, "feature/foo", normalize_ref_for_tests("origin/feature/foo"))
    asserts.equals(env, "main", normalize_ref_for_tests("origin/refs/heads/main"))
    asserts.equals(env, "main", normalize_ref_for_tests("refs/remotes/origin/main"))
    asserts.equals(env, "main", normalize_ref_for_tests("main"))
    asserts.equals(env, "", normalize_ref_for_tests(""))
    return unittest.end(env)

def _normalize_ref_edge_cases_test(ctx):
    """Validate additional refs/heads and refs/tags normalization paths."""
    env = unittest.begin(ctx)
    asserts.equals(env, "feature/test", normalize_ref_for_tests("refs/heads/feature/test"))
    asserts.equals(env, "release/v2", normalize_ref_for_tests("refs/tags/release/v2"))
    asserts.equals(env, "release/v3", normalize_ref_for_tests("origin/refs/tags/release/v3"))
    asserts.equals(env, "hotfix", normalize_ref_for_tests("refs/remotes/origin/hotfix"))
    return unittest.end(env)

def _sanitize_repository_url_test(ctx):
    """Validate repository URL userinfo stripping behavior."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "https://github.com/org/repo.git",
        sanitize_repository_url_for_tests("https://token@github.com/org/repo.git"),
    )
    asserts.equals(
        env,
        "https://host/repo.git",
        sanitize_repository_url_for_tests("https://user@domain:pass@host/repo.git"),
    )
    asserts.equals(
        env,
        "https://host/repo.git",
        sanitize_repository_url_for_tests("https://user:pa@ss@host/repo.git"),
    )
    asserts.equals(
        env,
        "git@github.com:org/repo.git",
        sanitize_repository_url_for_tests("git@github.com:org/repo.git"),
    )
    asserts.equals(env, "", sanitize_repository_url_for_tests(""))
    return unittest.end(env)

def _first_env_from_environ_test(ctx):
    """Validate dict-based first-non-empty environment lookup."""
    env = unittest.begin(ctx)
    vals = {
        "FIRST": "",
        "SECOND": "chosen",
        "THIRD": "backup",
    }
    asserts.equals(env, "chosen", first_env_from_environ_for_tests(vals, ["FIRST", "SECOND", "THIRD"]))
    asserts.equals(env, "", first_env_from_environ_for_tests(vals, ["MISSING_A", "MISSING_B"]))
    return unittest.end(env)

def _first_env_ctx_test(ctx):
    """Validate ctx-based first-non-empty environment lookup."""
    env = unittest.begin(ctx)
    fake_ctx = struct(os = struct(environ = {
        "A": "",
        "B": "value-b",
    }))
    asserts.equals(env, "value-b", first_env_for_tests(fake_ctx, ["A", "B"]))
    asserts.equals(env, "", first_env_for_tests(fake_ctx, ["X", "Y"]))
    return unittest.end(env)

def _apply_dd_git_overrides_test(ctx):
    """Validate DD_GIT_* override precedence + normalization behavior."""
    env = unittest.begin(ctx)
    data = {
        "repository_url": "https://github.com/original/repo.git",
        "branch": "refs/heads/main",
        "sha": "original-sha",
        "head_sha": "",
        "commit_message": "",
        "head_message": "",
    }
    apply_dd_git_overrides_for_tests(data, {
        "DD_GIT_REPOSITORY_URL": "https://token@github.com/override/repo.git",
        "DD_GIT_BRANCH": "refs/remotes/origin/release",
        "DD_GIT_COMMIT_SHA": "override-sha",
        "DD_GIT_HEAD_COMMIT": "override-head",
        "DD_GIT_COMMIT_MESSAGE": "override-message",
        "DD_GIT_HEAD_MESSAGE": "override-head-message",
    })
    asserts.equals(env, "https://github.com/override/repo.git", data.get("repository_url"))
    asserts.equals(env, "release", data.get("branch"))
    asserts.equals(env, "override-sha", data.get("sha"))
    asserts.equals(env, "override-head", data.get("head_sha"))
    asserts.equals(env, "override-message", data.get("commit_message"))
    asserts.equals(env, "override-head-message", data.get("head_message"))
    return unittest.end(env)

def _set_context_tag_from_env_test(ctx):
    """Validate optional context tag extraction from environment."""
    env = unittest.begin(ctx)
    tags = {}
    set_context_tag_from_env_for_tests({"FOO": "bar"}, tags, "FOO", "foo.tag")
    set_context_tag_from_env_for_tests({"EMPTY": ""}, tags, "EMPTY", "empty.tag")
    set_context_tag_from_env_for_tests({}, tags, "MISSING", "missing.tag")
    asserts.equals(env, "bar", tags.get("foo.tag"))
    asserts.equals(env, None, tags.get("empty.tag"))
    asserts.equals(env, None, tags.get("missing.tag"))
    return unittest.end(env)

def _collect_env_from_environ_provider_mapping_test(ctx):
    """Validate provider extraction and DD_* override precedence."""
    env = unittest.begin(ctx)

    github = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_SERVER_URL": "https://github.example",
        "GITHUB_REF": "refs/heads/main",
    }, None)
    asserts.equals(env, "github_actions", github.get("ci_provider_name"))
    asserts.equals(env, "https://github.example/org/repo.git", github.get("repository_url"))
    asserts.equals(env, "main", github.get("branch"))
    asserts.equals(env, "abc123", github.get("sha"))
    asserts.equals(env, "unnamed-service", github.get("service"))

    github_pr = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITHUB_SHA": "def456",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_SERVER_URL": "https://github.example",
        "GITHUB_REF": "refs/pull/42/merge",
        "GITHUB_HEAD_REF": "feature/pr-branch",
    }, None)
    asserts.equals(env, "github_actions", github_pr.get("ci_provider_name"))
    asserts.equals(env, "feature/pr-branch", github_pr.get("branch"))
    asserts.equals(env, "def456", github_pr.get("sha"))

    github_tag = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITHUB_SHA": "ffeeddcc",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_SERVER_URL": "https://github.example",
        "GITHUB_REF": "refs/tags/v1.2.3",
    }, None)
    asserts.equals(env, "github_actions", github_tag.get("ci_provider_name"))
    asserts.equals(env, "v1.2.3", github_tag.get("branch"))
    asserts.equals(env, "ffeeddcc", github_tag.get("sha"))

    overridden = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "DD_SERVICE": "service-from-env",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_REF": "refs/heads/main",
        "DD_GIT_REPOSITORY_URL": "https://override/repo.git",
        "DD_GIT_BRANCH": "refs/remotes/origin/release",
        "DD_GIT_COMMIT_SHA": "deadbeef",
    }, "service-from-attr")
    asserts.equals(env, "service-from-attr", overridden.get("service"))
    asserts.equals(env, "https://override/repo.git", overridden.get("repository_url"))
    asserts.equals(env, "release", overridden.get("branch"))
    asserts.equals(env, "deadbeef", overridden.get("sha"))

    overridden_with_token = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_REF": "refs/heads/main",
        "DD_GIT_REPOSITORY_URL": "https://token@override/repo.git",
    }, None)
    asserts.equals(env, "https://override/repo.git", overridden_with_token.get("repository_url"))

    appveyor = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "APPVEYOR": "True",
        "APPVEYOR_REPO_PROVIDER": "github",
        "APPVEYOR_REPO_NAME": "team/repo",
        "APPVEYOR_REPO_COMMIT": "cafebabe",
        "APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH": "refs/heads/pr-branch",
        "APPVEYOR_REPO_BRANCH": "refs/heads/fallback",
    }, None)
    asserts.equals(env, "appveyor", appveyor.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/team/repo.git", appveyor.get("repository_url"))
    asserts.equals(env, "pr-branch", appveyor.get("branch"))
    asserts.equals(env, "cafebabe", appveyor.get("sha"))

    buildkite = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "BUILDKITE": "true",
        "BUILDKITE_REPO": "https://buildkite.example/org/repo.git",
        "BUILDKITE_BRANCH": "refs/heads/release",
        "BUILDKITE_COMMIT": "beadfeed",
    }, None)
    asserts.equals(env, "buildkite", buildkite.get("ci_provider_name"))
    asserts.equals(env, "https://buildkite.example/org/repo.git", buildkite.get("repository_url"))
    asserts.equals(env, "release", buildkite.get("branch"))
    asserts.equals(env, "beadfeed", buildkite.get("sha"))

    gitlab = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITLAB_CI": "true",
        "CI_REPOSITORY_URL": "https://gitlab.example/org/repo.git",
        "CI_COMMIT_BRANCH": "refs/heads/main",
        "CI_COMMIT_SHA": "f00dbabe",
    }, None)
    asserts.equals(env, "gitlab", gitlab.get("ci_provider_name"))
    asserts.equals(env, "https://gitlab.example/org/repo.git", gitlab.get("repository_url"))
    asserts.equals(env, "main", gitlab.get("branch"))
    asserts.equals(env, "f00dbabe", gitlab.get("sha"))

    jenkins = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "JENKINS_URL": "https://jenkins.example/",
        "GIT_URL": "https://github.example/org/repo.git",
        "GIT_BRANCH": "refs/heads/dev",
        "GIT_COMMIT": "00112233",
    }, None)
    asserts.equals(env, "jenkins", jenkins.get("ci_provider_name"))
    asserts.equals(env, "https://github.example/org/repo.git", jenkins.get("repository_url"))
    asserts.equals(env, "dev", jenkins.get("branch"))
    asserts.equals(env, "00112233", jenkins.get("sha"))

    azure = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "TF_BUILD": "True",
        "BUILD_REPOSITORY_URI": "https://dev.azure.com/org/repo",
        "BUILD_SOURCEVERSION": "aabbccdd",
        "BUILD_SOURCEBRANCH": "refs/heads/main",
        "BUILD_SOURCEVERSIONMESSAGE": "merge commit",
    }, None)
    asserts.equals(env, "azure_pipelines", azure.get("ci_provider_name"))
    asserts.equals(env, "https://dev.azure.com/org/repo", azure.get("repository_url"))
    asserts.equals(env, "main", azure.get("branch"))
    asserts.equals(env, "aabbccdd", azure.get("sha"))

    bitbucket = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "BITBUCKET_COMMIT": "11223344",
        "BITBUCKET_REPO_SLUG": "team/repo",
        "BITBUCKET_BRANCH": "refs/heads/feature/bb",
    }, None)
    asserts.equals(env, "bitbucket", bitbucket.get("ci_provider_name"))
    asserts.equals(env, "https://bitbucket.org/team/repo.git", bitbucket.get("repository_url"))
    asserts.equals(env, "feature/bb", bitbucket.get("branch"))
    asserts.equals(env, "11223344", bitbucket.get("sha"))

    buddy = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "BUDDY": "true",
        "BUDDY_SCM_URL": "https://github.example/org/repo.git",
        "BUDDY_EXECUTION_REVISION": "cafed00d",
        "BUDDY_EXECUTION_BRANCH": "refs/heads/buddy",
    }, None)
    asserts.equals(env, "buddy", buddy.get("ci_provider_name"))
    asserts.equals(env, "https://github.example/org/repo.git", buddy.get("repository_url"))
    asserts.equals(env, "buddy", buddy.get("branch"))
    asserts.equals(env, "cafed00d", buddy.get("sha"))

    circle = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "CIRCLECI": "true",
        "CIRCLE_REPOSITORY_URL": "https://github.com/org/repo.git",
        "CIRCLE_SHA1": "ccddeeff",
        "CIRCLE_BRANCH": "refs/heads/circle-main",
    }, None)
    asserts.equals(env, "circleci", circle.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/org/repo.git", circle.get("repository_url"))
    asserts.equals(env, "circle-main", circle.get("branch"))
    asserts.equals(env, "ccddeeff", circle.get("sha"))

    teamcity = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "TEAMCITY_VERSION": "2025.01",
        "GIT_URL": "https://tc.example/org/repo.git",
        "GIT_COMMIT": "feed1234",
        "GIT_BRANCH": "refs/heads/tc-branch",
    }, None)
    asserts.equals(env, "teamcity", teamcity.get("ci_provider_name"))
    asserts.equals(env, "https://tc.example/org/repo.git", teamcity.get("repository_url"))
    asserts.equals(env, "tc-branch", teamcity.get("branch"))
    asserts.equals(env, "feed1234", teamcity.get("sha"))

    travis = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "TRAVIS": "true",
        "TRAVIS_REPO_SLUG": "org/repo",
        "TRAVIS_COMMIT": "77889900",
        "TRAVIS_PULL_REQUEST_BRANCH": "refs/heads/pr-branch",
    }, None)
    asserts.equals(env, "travisci", travis.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/org/repo.git", travis.get("repository_url"))
    asserts.equals(env, "pr-branch", travis.get("branch"))
    asserts.equals(env, "77889900", travis.get("sha"))

    bitrise = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "BITRISE_BUILD_SLUG": "build-slug",
        "BITRISE_GIT_REPOSITORY_URL": "https://github.com/org/repo.git",
        "BITRISE_GIT_COMMIT": "1234abcd",
        "BITRISE_GIT_BRANCH": "refs/heads/bitrise-main",
    }, None)
    asserts.equals(env, "bitrise", bitrise.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/org/repo.git", bitrise.get("repository_url"))
    asserts.equals(env, "bitrise-main", bitrise.get("branch"))
    asserts.equals(env, "1234abcd", bitrise.get("sha"))

    codefresh = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "CF_BUILD_ID": "build-1",
        "CF_BRANCH": "refs/heads/cf-main",
        "CF_REVISION": "cf-rev-1234",
        "CF_REPO_OWNER": "cf-org",
        "CF_REPO_NAME": "cf-repo",
    }, None)
    asserts.equals(env, "codefresh", codefresh.get("ci_provider_name"))
    asserts.equals(env, "cf-main", codefresh.get("branch"))
    asserts.equals(env, "cf-rev-1234", codefresh.get("sha"))
    asserts.equals(env, "https://github.com/cf-org/cf-repo.git", codefresh.get("repository_url"))

    codebuild = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "CODEBUILD_INITIATOR": "codepipeline/repo",
        "CODEBUILD_SOURCE_REPO_URL": "https://github.com/org/repo.git",
        "CODEBUILD_RESOLVED_SOURCE_VERSION": "abcdef12",
        "CODEBUILD_WEBHOOK_HEAD_REF": "refs/heads/cb-main",
    }, None)
    asserts.equals(env, "awscodebuild", codebuild.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/org/repo.git", codebuild.get("repository_url"))
    asserts.equals(env, "cb-main", codebuild.get("branch"))
    asserts.equals(env, "abcdef12", codebuild.get("sha"))

    drone = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "DRONE": "true",
        "DRONE_GIT_HTTP_URL": "https://github.com/org/repo.git",
        "DRONE_COMMIT_SHA": "beefbeef",
        "DRONE_BRANCH": "refs/heads/drone-main",
        "DRONE_COMMIT_MESSAGE": "drone message",
    }, None)
    asserts.equals(env, "drone", drone.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/org/repo.git", drone.get("repository_url"))
    asserts.equals(env, "drone-main", drone.get("branch"))
    asserts.equals(env, "beefbeef", drone.get("sha"))
    return unittest.end(env)

def _collect_env_from_environ_empty_test(ctx):
    """Validate empty/minimal env mapping returns stable defaults."""
    env = unittest.begin(ctx)
    empty = collect_env_from_environ_for_tests({}, None)
    asserts.equals(env, "", empty.get("ci_provider_name"))
    asserts.equals(env, "", empty.get("repository_url"))
    asserts.equals(env, "", empty.get("branch"))
    asserts.equals(env, "", empty.get("sha"))
    asserts.equals(env, "unnamed-service", empty.get("service"))
    asserts.equals(env, "CI", empty.get("environment"))
    return unittest.end(env)

def _collect_env_ctx_wrapper_test(ctx):
    """Validate repository-context wrapper delegates to environ collector."""
    env = unittest.begin(ctx)
    fake_ctx = struct(
        os = struct(environ = {
            "DD_SITE": "datadoghq.com",
            "GITHUB_SHA": "abc999",
            "GITHUB_REPOSITORY": "org/repo",
            "GITHUB_REF": "refs/heads/main",
        }),
        attr = struct(service = "svc-from-ctx"),
    )
    collected = collect_env_for_tests(fake_ctx)
    asserts.equals(env, "svc-from-ctx", collected.get("service"))
    asserts.equals(env, "github_actions", collected.get("ci_provider_name"))
    asserts.equals(env, "abc999", collected.get("sha"))
    return unittest.end(env)

def _read_abs_file_command_escaping_test(ctx):
    """Validate read-command construction escapes single quotes safely."""
    env = unittest.begin(ctx)
    unix_cmd = build_unix_read_abs_file_command_for_tests("/tmp/it's/test.txt")
    asserts.true(env, "'\\''" in unix_cmd)
    asserts.true(env, unix_cmd.startswith("cat '"))

    ps_cmd = build_windows_read_abs_file_command_for_tests("C:\\tmp\\it's\\file.txt")
    asserts.true(env, "''" in ps_cmd)
    asserts.true(env, "$p = '" in ps_cmd)
    asserts.true(env, "Get-Content -Raw -LiteralPath $p" in ps_cmd)
    return unittest.end(env)

def _parse_go_module_path_test(ctx):
    """Validate go.mod module path extraction helper."""
    env = unittest.begin(ctx)
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module github.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module\tgithub.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module \"github.com/foo/bar\""))
    asserts.equals(env, "'github.com/foo/bar'", parse_go_module_path_for_tests("// comment\nmodule 'github.com/foo/bar'\n"))
    asserts.equals(env, "github.com/foo/v2", parse_go_module_path_for_tests("module github.com/foo/v2"))
    asserts.equals(env, "github.com/first/mod", parse_go_module_path_for_tests("module github.com/first/mod\nmodule github.com/second/mod"))
    asserts.equals(env, "", parse_go_module_path_for_tests("module"))
    asserts.equals(env, "", parse_go_module_path_for_tests("mod github.com/foo/bar"))
    asserts.equals(env, "", parse_go_module_path_for_tests("// module github.com/foo/bar"))
    asserts.equals(env, "", parse_go_module_path_for_tests(""))
    return unittest.end(env)

def _runtime_module_path_from_environ_test(ctx):
    """Validate runtime module path env helper normalization for set/unset values."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "",
        runtime_module_path_from_environ_for_tests({}, "PYTHON_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "pkg.subpkg",
        runtime_module_path_from_environ_for_tests({"PYTHON_MODULE_PATH": "  pkg.subpkg  "}, "PYTHON_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "",
        runtime_module_path_from_environ_for_tests({"JAVA_MODULE_PATH": "   "}, "JAVA_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "com.example.app",
        runtime_module_path_from_environ_for_tests({"JAVA_MODULE_PATH": "com.example.app"}, "JAVA_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "packages/api",
        runtime_module_path_from_environ_for_tests({"NODEJS_MODULE_PATH": " packages/api "}, "NODEJS_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "My.Product.Service",
        runtime_module_path_from_environ_for_tests({"DOTNET_MODULE_PATH": "My.Product.Service"}, "DOTNET_MODULE_PATH"),
    )
    asserts.equals(
        env,
        "apps/web",
        runtime_module_path_from_environ_for_tests({"RUBY_MODULE_PATH": "apps/web"}, "RUBY_MODULE_PATH"),
    )
    return unittest.end(env)

def _dirname_test(ctx):
    """Validate dirname helper behavior across path forms."""
    env = unittest.begin(ctx)
    asserts.equals(env, "foo/bar", dirname_for_tests("foo/bar/baz.txt"))
    asserts.equals(env, "foo", dirname_for_tests("/foo/bar"))
    asserts.equals(env, "foo", dirname_for_tests("./foo/bar"))
    asserts.equals(env, "", dirname_for_tests("/"))
    asserts.equals(env, "", dirname_for_tests(".."))
    asserts.equals(env, "", dirname_for_tests("foo"))
    asserts.equals(env, "", dirname_for_tests(""))
    return unittest.end(env)

def _normalize_out_dir_or_fail_test(ctx):
    """Validate out_dir normalization and accepted relative-path forms."""
    env = unittest.begin(ctx)
    asserts.equals(env, ".testoptimization", normalize_out_dir_or_fail_for_tests(".testoptimization"))
    asserts.equals(env, "custom_topt", normalize_out_dir_or_fail_for_tests(" custom_topt "))
    asserts.equals(env, "foo/bar", normalize_out_dir_or_fail_for_tests("./foo//bar/"))
    asserts.equals(env, "foo/bar", normalize_out_dir_or_fail_for_tests("foo\\bar"))
    return unittest.end(env)

def _export_bzl_manifest_path_test(ctx):
    """Validate manifest_path emission in generated export.bzl."""
    env = unittest.begin(ctx)
    content = render_export_bzl_for_tests(
        "repo",
        ["a"],
        "{}",
        "example.com/mod",
        "example_com_mod",
        True,
        ".testoptimization/manifest.txt",
        python_module_path = "example.python.mod",
        sanitized_python_module_path = "example_python_mod",
        python_module_included = False,
        java_module_path = "com.example.mod",
        sanitized_java_module_path = "com_example_mod",
        java_module_included = True,
        nodejs_module_path = "packages/service",
        sanitized_nodejs_module_path = "packages_service",
        nodejs_module_included = False,
        dotnet_module_path = "Company.Product.Service",
        sanitized_dotnet_module_path = "company_product_service",
        dotnet_module_included = True,
        ruby_module_path = "apps/ruby_service",
        sanitized_ruby_module_path = "apps_ruby_service",
        ruby_module_included = False,
    )
    asserts.true(env, "\"manifest_path\": \".testoptimization/manifest.txt\"" in content)
    asserts.true(env, "\"runtimes\": {" in content)
    asserts.true(env, "\"go\": {" in content)
    asserts.true(env, "\"python\": {" in content)
    asserts.true(env, "\"java\": {" in content)
    asserts.true(env, "\"nodejs\": {" in content)
    asserts.true(env, "\"dotnet\": {" in content)
    asserts.true(env, "\"ruby\": {" in content)
    asserts.true(env, "\"module_path\": \"example.python.mod\"" in content)
    asserts.true(env, "\"module_path\": \"com.example.mod\"" in content)
    asserts.true(env, "\"module_path\": \"packages/service\"" in content)
    asserts.true(env, "\"module_path\": \"Company.Product.Service\"" in content)
    asserts.true(env, "\"module_path\": \"apps/ruby_service\"" in content)
    asserts.false(env, "\n    \"go\": {\n" in content)
    return unittest.end(env)

def _export_bzl_escaping_test(ctx):
    """Validate generated export.bzl escapes quote/backslash safely."""
    env = unittest.begin(ctx)
    content = render_export_bzl_for_tests(
        "repo\"name",
        ["a"],
        "{}",
        "go\"mod",
        "sanitized\\path",
        True,
        "path\\to\\manifest.txt",
        python_module_path = "py\"mod",
        sanitized_python_module_path = "py\\sanitized",
        python_module_included = False,
        java_module_path = "java\"mod",
        sanitized_java_module_path = "java\\sanitized",
        java_module_included = True,
        nodejs_module_path = "node\"mod",
        sanitized_nodejs_module_path = "node\\sanitized",
        nodejs_module_included = False,
        dotnet_module_path = "dotnet\"mod",
        sanitized_dotnet_module_path = "dotnet\\sanitized",
        dotnet_module_included = True,
        ruby_module_path = "ruby\"mod",
        sanitized_ruby_module_path = "ruby\\sanitized",
        ruby_module_included = False,
    )
    asserts.true(env, "\"repo_name\": \"repo\\\"name\"" in content)
    asserts.true(env, "\"manifest_path\": \"path\\\\to\\\\manifest.txt\"" in content)
    asserts.true(env, "\"module_path\": \"go\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"sanitized\\\\path\"" in content)
    asserts.true(env, "\"module_path\": \"py\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"py\\\\sanitized\"" in content)
    asserts.true(env, "\"module_path\": \"java\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"java\\\\sanitized\"" in content)
    asserts.true(env, "\"module_path\": \"node\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"node\\\\sanitized\"" in content)
    asserts.true(env, "\"module_path\": \"dotnet\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"dotnet\\\\sanitized\"" in content)
    asserts.true(env, "\"module_path\": \"ruby\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"ruby\\\\sanitized\"" in content)
    return unittest.end(env)

def _fnv1a_symbol_distinguishes_common_symbols_test(ctx):
    """Validate FNV-1a determinism and common-symbol distinction."""
    env = unittest.begin(ctx)

    # Known vector for stable regression protection.
    asserts.equals(env, 0xc1a2b2aa, fnv1a_32_for_tests("abc"))

    # Determinism: repeated input must yield identical output.
    first = fnv1a_32_for_tests("abc0def")
    second = fnv1a_32_for_tests("abc0def")
    asserts.equals(env, first, second)

    base = fnv1a_32_for_tests("abc0def")
    asserts.true(env, fnv1a_32_for_tests("abc=def") != base)
    asserts.true(env, fnv1a_32_for_tests("abc@def") != base)
    asserts.true(env, fnv1a_32_for_tests("abc#def") != base)
    return unittest.end(env)

def _clone_payload_with_detached_attributes_test(ctx):
    """Validate module-specific mutations do not leak to source payload."""
    env = unittest.begin(ctx)
    original = {
        "data": {
            "attributes": {
                "tests": {
                    "module_a": {"suite_a": ["test_a"]},
                },
                "modules": {
                    "module_a": {"suite_a": {"test_a": {"properties": {"quarantined": False}}}},
                },
            },
            "id": "source-data",
        },
        "meta": {"source": "fixture", "tags": ["a", "b"]},
    }
    cloned = clone_payload_with_detached_attributes_for_tests(original)
    cloned_attrs = ((cloned.get("data") or {}).get("attributes") or {})
    cloned_attrs["tests"] = {
        "module_b": {"suite_b": ["test_b"]},
    }
    cloned_attrs["modules"] = {
        "module_b": {"suite_b": {}},
    }
    cloned_meta = cloned.get("meta") or {}
    cloned_meta["source"] = "mutated"
    cloned_meta["tags"] = ["x"]

    original_attrs = ((original.get("data") or {}).get("attributes") or {})
    original_tests = original_attrs.get("tests") or {}
    original_modules = original_attrs.get("modules") or {}
    asserts.true(env, original_tests.get("module_a") != None)
    asserts.equals(env, None, original_tests.get("module_b"))
    asserts.true(env, original_modules.get("module_a") != None)
    asserts.equals(env, None, original_modules.get("module_b"))
    original_meta = original.get("meta") or {}
    asserts.equals(env, "fixture", original_meta.get("source"))
    asserts.equals(env, ["a", "b"], original_meta.get("tags"))
    return unittest.end(env)

def _clone_payload_with_nested_structure_test(ctx):
    """Validate detached clone keeps nested structures isolated."""
    env = unittest.begin(ctx)
    original = {
        "data": {
            "attributes": {
                "tests": {"module_a": {"suite_a": ["test_a"]}},
                "modules": {"module_a": {"suite_a": {"test_a": {"properties": {"quarantined": False}}}}},
            },
        },
    }
    cloned = clone_payload_with_detached_attributes_for_tests(original)
    cloned_tests = (((cloned.get("data") or {}).get("attributes") or {}).get("tests") or {})
    cloned_modules = (((cloned.get("data") or {}).get("attributes") or {}).get("modules") or {})
    cloned_tests["module_a"]["suite_a"].append("test_b")
    cloned_modules["module_a"]["suite_a"]["test_a"]["properties"]["quarantined"] = True

    original_tests = (((original.get("data") or {}).get("attributes") or {}).get("tests") or {})
    original_modules = (((original.get("data") or {}).get("attributes") or {}).get("modules") or {})
    asserts.equals(env, ["test_a"], original_tests.get("module_a").get("suite_a"))
    asserts.equals(
        env,
        False,
        original_modules.get("module_a").get("suite_a").get("test_a").get("properties").get("quarantined"),
    )
    return unittest.end(env)

def _example_stub_includes_manifest_in_files_test(ctx):
    """Ensure stub test_optimization_files includes manifest for contract parity."""
    env = unittest.begin(ctx)
    settings = ".testoptimization/cache/http/settings.json"
    manifest = ".testoptimization/manifest.txt"
    known_tests = ".testoptimization/cache/http/known_tests.json"
    test_management = ".testoptimization/cache/http/test_management.json"
    context = ".testoptimization/context.json"

    content = render_stub_build_for_tests(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
    )
    filegroup_start = content.find('name = "test_optimization_files"')
    context_group_start = content.find('name = "test_optimization_context"')
    asserts.true(env, filegroup_start >= 0)
    asserts.true(env, context_group_start > filegroup_start)
    filegroup_block = content[filegroup_start:context_group_start]
    asserts.true(env, "srcs = [" in filegroup_block)
    asserts.true(env, settings in filegroup_block)
    asserts.true(env, manifest in filegroup_block)
    asserts.true(env, known_tests in filegroup_block)
    asserts.true(env, test_management in filegroup_block)
    exports_start = content.find("exports_files(")
    asserts.true(env, exports_start > context_group_start)
    context_group_block = content[context_group_start:exports_start]
    asserts.true(env, context in context_group_block)
    return unittest.end(env)

def _example_stub_service_keys_targets_test(ctx):
    """Validate service-suffixed filegroups are emitted for service keys."""
    env = unittest.begin(ctx)
    content = render_stub_build_for_tests(
        ".testoptimization/cache/http/settings.json",
        ".testoptimization/manifest.txt",
        ".testoptimization/cache/http/known_tests.json",
        ".testoptimization/cache/http/test_management.json",
        ".testoptimization/context.json",
        service_keys = ["go_service", "ruby_service"],
    )
    asserts.true(env, 'name = "test_optimization_files_go_service"' in content)
    asserts.true(env, 'name = "test_optimization_context_go_service"' in content)
    asserts.true(env, 'name = "test_optimization_files_ruby_service"' in content)
    asserts.true(env, 'name = "test_optimization_context_ruby_service"' in content)
    return unittest.end(env)

def _example_stub_export_string_escaping_test(ctx):
    """Validate stub export string literal escaping for unsafe characters."""
    env = unittest.begin(ctx)
    escaped = bzl_string_literal_for_tests('repo"\\name\nline')
    asserts.equals(env, "\"repo\\\"\\\\name\\nline\"", escaped)
    return unittest.end(env)

def _http_execute_timeout_seconds_test(ctx):
    """Guard execute-timeout derivation against retry-policy drift."""
    env = unittest.begin(ctx)

    # Keep execute timeout derived from retry policy + explicit buffer instead
    # of a magic number to avoid accidentally clipping retries in CI.
    expected = (
        (http_retry_attempts_for_tests * http_max_time_seconds_for_tests) +
        ((http_retry_attempts_for_tests - 1) * http_retry_delay_seconds_for_tests) +
        http_execute_timeout_buffer_seconds_for_tests
    )
    asserts.equals(env, expected, http_execute_timeout_seconds_for_tests)
    asserts.true(env, http_execute_timeout_seconds_for_tests > (http_retry_attempts_for_tests * http_max_time_seconds_for_tests))
    return unittest.end(env)

def _render_module_runfiles_bzl_respects_manifest_root_test(ctx):
    """Validate module runfile symlink roots follow manifest root/out_dir."""
    env = unittest.begin(ctx)
    default_content = render_module_runfiles_bzl_for_tests(".testoptimization")
    asserts.true(env, 'syms[".testoptimization/cache/http/settings.json"] = ctx.file.settings' in default_content)
    asserts.true(env, 'syms[".testoptimization/manifest.txt"] = ctx.file.manifest' in default_content)
    asserts.true(env, 'syms[".testoptimization/cache/http/known_tests.json"] = kt' in default_content)
    asserts.true(env, 'syms[".testoptimization/cache/http/test_management.json"] = tm' in default_content)

    custom_content = render_module_runfiles_bzl_for_tests("custom_topt")
    asserts.true(env, 'syms["custom_topt/cache/http/settings.json"] = ctx.file.settings' in custom_content)
    asserts.true(env, 'syms["custom_topt/manifest.txt"] = ctx.file.manifest' in custom_content)
    asserts.true(env, 'syms["custom_topt/cache/http/known_tests.json"] = kt' in custom_content)
    asserts.true(env, 'syms["custom_topt/cache/http/test_management.json"] = tm' in custom_content)
    return unittest.end(env)

def _partition_unix_headers_test(ctx):
    """Validate Unix header partitioning keeps DD-API-KEY out of public headers."""
    env = unittest.begin(ctx)
    out = partition_unix_headers_for_tests({
        "DD-API-KEY": "super-secret",
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    asserts.true(env, out.get("has_dd_api_key"))
    asserts.equals(env, "super-secret", out.get("dd_api_key"))
    public_headers = out.get("public_headers") or {}
    asserts.equals(env, None, public_headers.get("DD-API-KEY"))
    asserts.equals(env, "application/json", public_headers.get("Accept"))
    asserts.equals(env, "application/json", public_headers.get("Content-Type"))
    return unittest.end(env)

def _partition_unix_headers_without_api_key_test(ctx):
    """Validate header partitioning when DD-API-KEY is absent."""
    env = unittest.begin(ctx)
    out = partition_unix_headers_for_tests({
        "Accept": "application/json",
        "X-Test": "1",
    })
    asserts.false(env, out.get("has_dd_api_key"))
    asserts.equals(env, "", out.get("dd_api_key"))
    public_headers = out.get("public_headers") or {}
    asserts.equals(env, "application/json", public_headers.get("Accept"))
    asserts.equals(env, "1", public_headers.get("X-Test"))
    return unittest.end(env)

def _record_sync_extension_repo_owner_success_test(ctx):
    """Validate sync-extension repo owner tracking success path."""
    env = unittest.begin(ctx)
    seen = {}
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_b", "module_a")
    asserts.equals(env, "module_a", seen.get("repo_a"))
    asserts.equals(env, "module_a", seen.get("repo_b"))
    return unittest.end(env)

def _decode_json_object_valid_test(ctx):
    """Validate JSON decode helper success path."""
    env = unittest.begin(ctx)
    obj = decode_json_object_or_fail_for_tests(
        "{\"data\": {\"attributes\": {\"marker\": \"ok\"}}}",
        "settings.json",
    )
    asserts.equals(env, "dict", type(obj))
    attrs = ((obj.get("data") or {}).get("attributes") or {})
    asserts.equals(env, "ok", attrs.get("marker"))
    return unittest.end(env)

def _decode_json_object_empty_target_impl(_ctx):
    """Target expected to fail on empty JSON payload."""
    decode_json_object_or_fail_for_tests("", "settings.json")
    return []

def _dd_site_invalid_target_impl(_ctx):
    """Target expected to fail on invalid DD_SITE hostname input."""
    compute_dd_api_base_for_tests("invalid site value")
    return []

def _read_abs_file_command_control_chars_target_impl(_ctx):
    """Target expected to fail when absolute path contains control characters."""
    build_unix_read_abs_file_command_for_tests("/tmp/bad\nfile.txt")
    return []

def _normalize_out_dir_empty_target_impl(_ctx):
    """Target expected to fail when out_dir is empty/whitespace."""
    normalize_out_dir_or_fail_for_tests("   ")
    return []

def _normalize_out_dir_absolute_target_impl(_ctx):
    """Target expected to fail when out_dir is absolute."""
    normalize_out_dir_or_fail_for_tests("/tmp/out")
    return []

def _normalize_out_dir_traversal_target_impl(_ctx):
    """Target expected to fail when out_dir includes traversal segments."""
    normalize_out_dir_or_fail_for_tests("foo/../bar")
    return []

def _normalize_out_dir_windows_drive_target_impl(_ctx):
    """Target expected to fail when out_dir includes a drive prefix."""
    normalize_out_dir_or_fail_for_tests("C:/tmp/out")
    return []

def _decode_json_object_non_json_target_impl(_ctx):
    """Target expected to fail on non-JSON payload."""
    decode_json_object_or_fail_for_tests("NOT_JSON", "settings.json")
    return []

def _decode_json_object_array_target_impl(_ctx):
    """Target expected to fail when top-level JSON is an array."""
    decode_json_object_or_fail_for_tests("[]", "settings.json")
    return []

def _decode_json_object_malformed_object_target_impl(_ctx):
    """Target expected to fail on deterministic malformed object-like JSON."""
    decode_json_object_or_fail_for_tests("{bad", "settings.json")
    return []

def _decode_json_object_malformed_array_target_impl(_ctx):
    """Target expected to fail on deterministic malformed array-like JSON."""
    decode_json_object_or_fail_for_tests("[bad", "settings.json")
    return []

def _record_sync_extension_repo_owner_duplicate_target_impl(_ctx):
    """Target expected to fail when sync extension repo names collide."""
    seen = {}
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_b")
    return []

decode_json_object_empty_target_rule = rule(
    implementation = _decode_json_object_empty_target_impl,
)
dd_site_invalid_target_rule = rule(
    implementation = _dd_site_invalid_target_impl,
)
read_abs_file_command_control_chars_target_rule = rule(
    implementation = _read_abs_file_command_control_chars_target_impl,
)
normalize_out_dir_empty_target_rule = rule(
    implementation = _normalize_out_dir_empty_target_impl,
)
normalize_out_dir_absolute_target_rule = rule(
    implementation = _normalize_out_dir_absolute_target_impl,
)
normalize_out_dir_traversal_target_rule = rule(
    implementation = _normalize_out_dir_traversal_target_impl,
)
normalize_out_dir_windows_drive_target_rule = rule(
    implementation = _normalize_out_dir_windows_drive_target_impl,
)
decode_json_object_non_json_target_rule = rule(
    implementation = _decode_json_object_non_json_target_impl,
)
decode_json_object_array_target_rule = rule(
    implementation = _decode_json_object_array_target_impl,
)
decode_json_object_malformed_object_target_rule = rule(
    implementation = _decode_json_object_malformed_object_target_impl,
)
decode_json_object_malformed_array_target_rule = rule(
    implementation = _decode_json_object_malformed_array_target_impl,
)
record_sync_extension_repo_owner_duplicate_target_rule = rule(
    implementation = _record_sync_extension_repo_owner_duplicate_target_impl,
)

def _decode_json_object_empty_failure_test_impl(ctx):
    """Assert empty-response failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response is empty; expected JSON object")
    return analysistest.end(env)

def _dd_site_invalid_failure_test_impl(ctx):
    """Assert DD_SITE validation rejects malformed hostnames."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DD_SITE")
    asserts.expect_failure(env, "hostname")
    return analysistest.end(env)

def _read_abs_file_command_control_chars_failure_test_impl(ctx):
    """Assert command builder rejects control characters in absolute paths."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "absolute path contains unsupported control characters")
    return analysistest.end(env)

def _normalize_out_dir_empty_failure_test_impl(ctx):
    """Assert empty out_dir failure keeps guidance explicit."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "out_dir must be a non-empty relative path")
    return analysistest.end(env)

def _normalize_out_dir_absolute_failure_test_impl(ctx):
    """Assert absolute out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "absolute paths are not allowed")
    return analysistest.end(env)

def _normalize_out_dir_traversal_failure_test_impl(ctx):
    """Assert traversal out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must not contain '..' path traversal segments")
    return analysistest.end(env)

def _normalize_out_dir_windows_drive_failure_test_impl(ctx):
    """Assert drive-prefixed out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must not include a Windows drive prefix")
    return analysistest.end(env)

def _decode_json_object_non_json_failure_test_impl(ctx):
    """Assert non-JSON failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response is not JSON")
    return analysistest.end(env)

def _decode_json_object_array_failure_test_impl(ctx):
    """Assert non-object JSON failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response must be a JSON object")
    return analysistest.end(env)

def _decode_json_object_malformed_object_failure_test_impl(ctx):
    """Assert malformed object-like JSON gets actionable diagnostics."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Error in decode:")
    asserts.expect_failure(env, "unexpected character")
    return analysistest.end(env)

def _decode_json_object_malformed_array_failure_test_impl(ctx):
    """Assert malformed array-like JSON gets actionable diagnostics."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Error in decode:")
    asserts.expect_failure(env, "unexpected character")
    return analysistest.end(env)

def _record_sync_extension_repo_owner_duplicate_failure_test_impl(ctx):
    """Assert sync extension duplicate-repo failure remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "duplicate repository name 'repo_a' declared")
    return analysistest.end(env)

dd_site_normalization_test = unittest.make(_dd_site_normalization_test)
resolve_dd_api_base_test = unittest.make(_resolve_dd_api_base_test)
module_label_map_collision_test = unittest.make(_module_label_map_collision_test)
module_label_map_empty_inputs_test = unittest.make(_module_label_map_empty_inputs_test)
normalize_ref_test = unittest.make(_normalize_ref_test)
normalize_ref_edge_cases_test = unittest.make(_normalize_ref_edge_cases_test)
sanitize_repository_url_test = unittest.make(_sanitize_repository_url_test)
first_env_from_environ_test = unittest.make(_first_env_from_environ_test)
first_env_ctx_test = unittest.make(_first_env_ctx_test)
apply_dd_git_overrides_test = unittest.make(_apply_dd_git_overrides_test)
set_context_tag_from_env_test = unittest.make(_set_context_tag_from_env_test)
collect_env_from_environ_provider_mapping_test = unittest.make(_collect_env_from_environ_provider_mapping_test)
collect_env_from_environ_empty_test = unittest.make(_collect_env_from_environ_empty_test)
collect_env_ctx_wrapper_test = unittest.make(_collect_env_ctx_wrapper_test)
read_abs_file_command_escaping_test = unittest.make(_read_abs_file_command_escaping_test)
parse_go_module_path_test = unittest.make(_parse_go_module_path_test)
runtime_module_path_from_environ_test = unittest.make(_runtime_module_path_from_environ_test)
dirname_test = unittest.make(_dirname_test)
normalize_out_dir_or_fail_test = unittest.make(_normalize_out_dir_or_fail_test)
export_bzl_manifest_path_test = unittest.make(_export_bzl_manifest_path_test)
export_bzl_escaping_test = unittest.make(_export_bzl_escaping_test)
fnv1a_symbol_distinguishes_common_symbols_test = unittest.make(_fnv1a_symbol_distinguishes_common_symbols_test)
clone_payload_with_detached_attributes_test = unittest.make(_clone_payload_with_detached_attributes_test)
clone_payload_with_nested_structure_test = unittest.make(_clone_payload_with_nested_structure_test)
example_stub_includes_manifest_in_files_test = unittest.make(_example_stub_includes_manifest_in_files_test)
example_stub_service_keys_targets_test = unittest.make(_example_stub_service_keys_targets_test)
example_stub_export_string_escaping_test = unittest.make(_example_stub_export_string_escaping_test)
http_execute_timeout_seconds_test = unittest.make(_http_execute_timeout_seconds_test)
render_module_runfiles_bzl_respects_manifest_root_test = unittest.make(_render_module_runfiles_bzl_respects_manifest_root_test)
partition_unix_headers_test = unittest.make(_partition_unix_headers_test)
partition_unix_headers_without_api_key_test = unittest.make(_partition_unix_headers_without_api_key_test)
record_sync_extension_repo_owner_success_test = unittest.make(_record_sync_extension_repo_owner_success_test)
decode_json_object_valid_test = unittest.make(_decode_json_object_valid_test)
decode_json_object_empty_failure_test = analysistest.make(
    _decode_json_object_empty_failure_test_impl,
    expect_failure = True,
)
dd_site_invalid_failure_test = analysistest.make(
    _dd_site_invalid_failure_test_impl,
    expect_failure = True,
)
read_abs_file_command_control_chars_failure_test = analysistest.make(
    _read_abs_file_command_control_chars_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_empty_failure_test = analysistest.make(
    _normalize_out_dir_empty_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_absolute_failure_test = analysistest.make(
    _normalize_out_dir_absolute_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_traversal_failure_test = analysistest.make(
    _normalize_out_dir_traversal_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_windows_drive_failure_test = analysistest.make(
    _normalize_out_dir_windows_drive_failure_test_impl,
    expect_failure = True,
)
decode_json_object_non_json_failure_test = analysistest.make(
    _decode_json_object_non_json_failure_test_impl,
    expect_failure = True,
)
decode_json_object_array_failure_test = analysistest.make(
    _decode_json_object_array_failure_test_impl,
    expect_failure = True,
)
decode_json_object_malformed_object_failure_test = analysistest.make(
    _decode_json_object_malformed_object_failure_test_impl,
    expect_failure = True,
)
decode_json_object_malformed_array_failure_test = analysistest.make(
    _decode_json_object_malformed_array_failure_test_impl,
    expect_failure = True,
)
record_sync_extension_repo_owner_duplicate_failure_test = analysistest.make(
    _record_sync_extension_repo_owner_duplicate_failure_test_impl,
    expect_failure = True,
)
