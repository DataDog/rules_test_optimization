#!/usr/bin/env bash
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
DD_GIT_COMMIT_SHA="deadbeef" \
DD_GIT_HEAD_COMMIT="deadbeef" \
DD_GIT_COMMIT_MESSAGE="override message" \
DD_GIT_HEAD_MESSAGE="override head message" \
BAZELW_CAPTURE_FILE="${capture}" \
bash "${bazelw}" --nosystem_rc query //:smoke >/dev/null

capture_norm="${tmp_dir}/query_args.normalized.txt"
tr -d '\r' <"${capture}" >"${capture_norm}"

assert_grep '^--nosystem_rc$' "${capture_norm}" "missing startup arg --nosystem_rc"
assert_grep '^query$' "${capture_norm}" "missing bazel command verb query"
assert_grep '^--repo_env=FETCH_SALT=' "${capture_norm}" "missing FETCH_SALT repo_env injection"
assert_grep '^--repo_env=DD_GIT_REPOSITORY_URL=https://override/repo.git$' "${capture_norm}" "repository URL should be scrubbed and forwarded"
assert_grep '^--repo_env=DD_GIT_BRANCH=refs/heads/feature/test$' "${capture_norm}" "missing DD_GIT_BRANCH override"
assert_grep '^--repo_env=DD_GIT_COMMIT_SHA=deadbeef$' "${capture_norm}" "missing DD_GIT_COMMIT_SHA override"
assert_grep '^--repo_env=DD_GIT_HEAD_COMMIT=deadbeef$' "${capture_norm}" "missing DD_GIT_HEAD_COMMIT override"
assert_grep '^--repo_env=DD_GIT_COMMIT_MESSAGE=' "${capture_norm}" "missing DD_GIT_COMMIT_MESSAGE repo_env"
assert_grep '^--repo_env=DD_GIT_HEAD_MESSAGE=' "${capture_norm}" "missing DD_GIT_HEAD_MESSAGE repo_env"
assert_grep 'override message' "${capture_norm}" "missing commit message content in forwarded args"
assert_grep 'override head message' "${capture_norm}" "missing head message content in forwarded args"
assert_grep '^//:smoke$' "${capture_norm}" "missing forwarded query target"

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
