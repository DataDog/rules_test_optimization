#!/usr/bin/env bash
set -euo pipefail

repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
bazelw="${repo_root}/bazelw"
if [[ ! -x "${bazelw}" ]]; then
  echo "error: bazelw not found at ${bazelw}"
  exit 1
fi

tmp_parent="${TEST_TMPDIR:-${TMPDIR:-}}"
if [[ -n "${tmp_parent}" && -d "${tmp_parent}" ]]; then
  tmp_dir="$(mktemp -d "${tmp_parent%/}/bazelw_test.XXXXXX")"
else
  tmp_dir="$(mktemp -d)"
fi
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/fakebin"
mkdir -p "${fake_bin}"

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
DD_GIT_REPOSITORY_URL="https://override/repo.git" \
DD_GIT_BRANCH="refs/heads/feature/test" \
DD_GIT_COMMIT_SHA="deadbeef" \
DD_GIT_HEAD_COMMIT="deadbeef" \
DD_GIT_COMMIT_MESSAGE="override message" \
DD_GIT_HEAD_MESSAGE="override head message" \
BAZELW_CAPTURE_FILE="${capture}" \
"${bazelw}" --nosystem_rc query //:smoke >/dev/null

capture_norm="${tmp_dir}/query_args.normalized.txt"
tr -d '\r' <"${capture}" >"${capture_norm}"

grep -q '^--nosystem_rc$' "${capture_norm}"
grep -q '^query$' "${capture_norm}"
grep -q '^--repo_env=FETCH_SALT=' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_REPOSITORY_URL=https://override/repo.git$' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_BRANCH=refs/heads/feature/test$' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_COMMIT_SHA=deadbeef$' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_HEAD_COMMIT=deadbeef$' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_COMMIT_MESSAGE=' "${capture_norm}"
grep -q '^--repo_env=DD_GIT_HEAD_MESSAGE=' "${capture_norm}"
grep -q 'override message' "${capture_norm}"
grep -q 'override head message' "${capture_norm}"
grep -q '^//:smoke$' "${capture_norm}"

capture_help="${tmp_dir}/help_args.txt"
PATH="${fake_bin}:${PATH}" \
BAZELW_CAPTURE_FILE="${capture_help}" \
"${bazelw}" help >/dev/null

capture_help_norm="${tmp_dir}/help_args.normalized.txt"
tr -d '\r' <"${capture_help}" >"${capture_help_norm}"

grep -q '^help$' "${capture_help_norm}"
if grep -q '^--repo_env=' "${capture_help_norm}"; then
  echo "error: help command should not inject repo_env flags"
  exit 1
fi
