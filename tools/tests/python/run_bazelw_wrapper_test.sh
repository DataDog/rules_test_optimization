#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

to_unix_path() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "${raw}" 2>/dev/null || printf '%s' "${raw}"
    return 0
  fi
  printf '%s' "${raw}"
}

test_srcdir="$(to_unix_path "${TEST_SRCDIR}")"
repo_root="${test_srcdir}/${TEST_WORKSPACE}"
bazelw="${repo_root}/bazelw"
if [[ ! -f "${bazelw}" ]]; then
  echo "error: bazelw not found at ${bazelw}"
  exit 1
fi

tmp_parent="$(to_unix_path "${TEST_TMPDIR:-${TMPDIR:-}}")"
if [[ -n "${tmp_parent}" && -d "${tmp_parent}" ]]; then
  tmp_dir="$(mktemp -d "${tmp_parent%/}/bazelw_test.XXXXXX")"
else
  tmp_dir="$(mktemp -d)"
fi
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/fakebin"
mkdir -p "${fake_bin}"

assert_grep() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! grep -q "${pattern}" "${file}"; then
    echo "error: ${message}" >&2
    echo "error: expected pattern: ${pattern}" >&2
    exit 1
  fi
}

cat >"${fake_bin}/bazel" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${BAZELW_CAPTURE_FILE}"
exit 0
EOF
chmod +x "${fake_bin}/bazel"
cp "${fake_bin}/bazel" "${fake_bin}/bazelisk"

capture="${tmp_dir}/query_args.txt"
PATH="${fake_bin}:${PATH}" \
FETCH_SALT_TTL=60 \
DD_GIT_REPOSITORY_URL="https://token@override/repo.git" \
DD_GIT_BRANCH="refs/heads/feature/test" \
DD_GIT_TAG="v1.2.3" \
DD_GIT_COMMIT_SHA="deadbeef" \
DD_GIT_HEAD_COMMIT="deadbeef" \
DD_GIT_COMMIT_MESSAGE="override message" \
DD_GIT_HEAD_MESSAGE="override head message" \
DD_GIT_COMMIT_AUTHOR_NAME="Author Name" \
DD_GIT_COMMIT_AUTHOR_EMAIL="author@example.com" \
DD_GIT_COMMIT_AUTHOR_DATE="2026-03-27T11:31:46+01:00" \
DD_GIT_COMMIT_COMMITTER_NAME="Committer Name" \
DD_GIT_COMMIT_COMMITTER_EMAIL="committer@example.com" \
DD_GIT_COMMIT_COMMITTER_DATE="2026-03-27T11:35:00+01:00" \
DD_GIT_HEAD_AUTHOR_NAME="Head Author" \
DD_GIT_HEAD_AUTHOR_EMAIL="head-author@example.com" \
DD_GIT_HEAD_AUTHOR_DATE="2026-03-27T11:36:00+01:00" \
DD_GIT_HEAD_COMMITTER_NAME="Head Committer" \
DD_GIT_HEAD_COMMITTER_EMAIL="head-committer@example.com" \
DD_GIT_HEAD_COMMITTER_DATE="2026-03-27T11:37:00+01:00" \
DD_GIT_PR_BASE_BRANCH="main" \
DD_GIT_PR_BASE_BRANCH_SHA="base-sha" \
DD_GIT_PR_BASE_BRANCH_HEAD_SHA="base-head-sha" \
DD_PR_NUMBER="42" \
BAZELW_CAPTURE_FILE="${capture}" \
bash "${bazelw}" --nosystem_rc query //:smoke >/dev/null

capture_norm="${tmp_dir}/query_args.normalized.txt"
tr -d '\r' <"${capture}" >"${capture_norm}"

assert_grep '^--nosystem_rc$' "${capture_norm}" "missing startup arg --nosystem_rc"
assert_grep '^query$' "${capture_norm}" "missing bazel command verb query"
assert_grep '^--repo_env=FETCH_SALT=' "${capture_norm}" "missing FETCH_SALT repo_env injection"
assert_grep '^--repo_env=DD_GIT_REPOSITORY_URL=https://override/repo.git$' "${capture_norm}" "repository URL should be scrubbed and forwarded"
assert_grep '^--repo_env=DD_GIT_BRANCH=refs/heads/feature/test$' "${capture_norm}" "missing DD_GIT_BRANCH override"
assert_grep '^--repo_env=DD_GIT_TAG=v1.2.3$' "${capture_norm}" "missing DD_GIT_TAG override"
assert_grep '^--repo_env=DD_GIT_COMMIT_SHA=deadbeef$' "${capture_norm}" "missing DD_GIT_COMMIT_SHA override"
assert_grep '^--repo_env=DD_GIT_HEAD_COMMIT=deadbeef$' "${capture_norm}" "missing DD_GIT_HEAD_COMMIT override"
assert_grep '^--repo_env=DD_GIT_COMMIT_MESSAGE=' "${capture_norm}" "missing DD_GIT_COMMIT_MESSAGE repo_env"
assert_grep '^--repo_env=DD_GIT_HEAD_MESSAGE=' "${capture_norm}" "missing DD_GIT_HEAD_MESSAGE repo_env"
assert_grep '^--repo_env=DD_GIT_COMMIT_AUTHOR_NAME=Author Name$' "${capture_norm}" "missing DD_GIT_COMMIT_AUTHOR_NAME override"
assert_grep '^--repo_env=DD_GIT_COMMIT_AUTHOR_EMAIL=author@example.com$' "${capture_norm}" "missing DD_GIT_COMMIT_AUTHOR_EMAIL override"
assert_grep '^--repo_env=DD_GIT_COMMIT_AUTHOR_DATE=2026-03-27T11:31:46+01:00$' "${capture_norm}" "missing DD_GIT_COMMIT_AUTHOR_DATE override"
assert_grep '^--repo_env=DD_GIT_COMMIT_COMMITTER_NAME=Committer Name$' "${capture_norm}" "missing DD_GIT_COMMIT_COMMITTER_NAME override"
assert_grep '^--repo_env=DD_GIT_COMMIT_COMMITTER_EMAIL=committer@example.com$' "${capture_norm}" "missing DD_GIT_COMMIT_COMMITTER_EMAIL override"
assert_grep '^--repo_env=DD_GIT_COMMIT_COMMITTER_DATE=2026-03-27T11:35:00+01:00$' "${capture_norm}" "missing DD_GIT_COMMIT_COMMITTER_DATE override"
assert_grep '^--repo_env=DD_GIT_HEAD_AUTHOR_NAME=Head Author$' "${capture_norm}" "missing DD_GIT_HEAD_AUTHOR_NAME override"
assert_grep '^--repo_env=DD_GIT_HEAD_AUTHOR_EMAIL=head-author@example.com$' "${capture_norm}" "missing DD_GIT_HEAD_AUTHOR_EMAIL override"
assert_grep '^--repo_env=DD_GIT_HEAD_AUTHOR_DATE=2026-03-27T11:36:00+01:00$' "${capture_norm}" "missing DD_GIT_HEAD_AUTHOR_DATE override"
assert_grep '^--repo_env=DD_GIT_HEAD_COMMITTER_NAME=Head Committer$' "${capture_norm}" "missing DD_GIT_HEAD_COMMITTER_NAME override"
assert_grep '^--repo_env=DD_GIT_HEAD_COMMITTER_EMAIL=head-committer@example.com$' "${capture_norm}" "missing DD_GIT_HEAD_COMMITTER_EMAIL override"
assert_grep '^--repo_env=DD_GIT_HEAD_COMMITTER_DATE=2026-03-27T11:37:00+01:00$' "${capture_norm}" "missing DD_GIT_HEAD_COMMITTER_DATE override"
assert_grep '^--repo_env=DD_GIT_PR_BASE_BRANCH=main$' "${capture_norm}" "missing DD_GIT_PR_BASE_BRANCH override"
assert_grep '^--repo_env=DD_GIT_PR_BASE_BRANCH_SHA=base-sha$' "${capture_norm}" "missing DD_GIT_PR_BASE_BRANCH_SHA override"
assert_grep '^--repo_env=DD_GIT_PR_BASE_BRANCH_HEAD_SHA=base-head-sha$' "${capture_norm}" "missing DD_GIT_PR_BASE_BRANCH_HEAD_SHA override"
assert_grep '^--repo_env=DD_PR_NUMBER=42$' "${capture_norm}" "missing DD_PR_NUMBER override"
assert_grep 'override message' "${capture_norm}" "missing commit message content in forwarded args"
assert_grep 'override head message' "${capture_norm}" "missing head message content in forwarded args"
assert_grep '^//:smoke$' "${capture_norm}" "missing forwarded query target"

capture_ci="${tmp_dir}/ci_args.txt"
PATH="${fake_bin}:${PATH}" \
GITHUB_SHA="abc123" \
GITHUB_REPOSITORY="org/repo" \
GITHUB_REF="refs/pull/42/merge" \
GITHUB_HEAD_REF="feature/pr-branch" \
BAZELW_CAPTURE_FILE="${capture_ci}" \
bash "${bazelw}" query //:smoke >/dev/null

capture_ci_norm="${tmp_dir}/ci_args.normalized.txt"
tr -d '\r' <"${capture_ci}" >"${capture_ci_norm}"

if grep -q '^--repo_env=DD_GIT_BRANCH=' "${capture_ci_norm}"; then
  echo "error: CI-provider mode should not force DD_GIT_BRANCH"
  exit 1
fi
if grep -q '^--repo_env=DD_GIT_HEAD_COMMIT=' "${capture_ci_norm}"; then
  echo "error: CI-provider mode should not force DD_GIT_HEAD_COMMIT"
  exit 1
fi
if grep -q '^--repo_env=DD_GIT_HEAD_MESSAGE=' "${capture_ci_norm}"; then
  echo "error: CI-provider mode should not force DD_GIT_HEAD_MESSAGE"
  exit 1
fi

capture_help="${tmp_dir}/help_args.txt"
PATH="${fake_bin}:${PATH}" \
BAZELW_CAPTURE_FILE="${capture_help}" \
bash "${bazelw}" help >/dev/null

capture_help_norm="${tmp_dir}/help_args.normalized.txt"
tr -d '\r' <"${capture_help}" >"${capture_help_norm}"

assert_grep '^help$' "${capture_help_norm}" "help command should be forwarded"
if grep -q '^--repo_env=' "${capture_help_norm}"; then
  echo "error: help command should not inject repo_env flags"
  exit 1
fi
