#!/usr/bin/env bash

set -euo pipefail

# Classifies a git diff for CI gating.
#
# A diff is considered docs-only when every changed path is either:
# - a Markdown file anywhere in the repository, or
# - a file rooted under docs/ (to allow documentation assets alongside markdown)
#
# Any unknown or ambiguous state falls back to running full CI.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-sha> <head-sha>" >&2
  exit 2
fi

base_sha="$1"
head_sha="$2"
zero_sha="0000000000000000000000000000000000000000"

emit_result() {
  local docs_only="$1"
  if [[ "${docs_only}" == "true" ]]; then
    printf 'docs_only=true\n'
    printf 'run_full_ci=false\n'
  else
    printf 'docs_only=false\n'
    printf 'run_full_ci=true\n'
  fi
}

if [[ -z "${base_sha}" || -z "${head_sha}" || "${base_sha}" == "${zero_sha}" || "${head_sha}" == "${zero_sha}" ]]; then
  emit_result false
  exit 0
fi

if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  emit_result false
  exit 0
fi

if ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  emit_result false
  exit 0
fi

mapfile -t changed_files < <(git diff --name-only "${base_sha}" "${head_sha}")

if (( ${#changed_files[@]} == 0 )); then
  emit_result false
  exit 0
fi

for changed_path in "${changed_files[@]}"; do
  case "${changed_path}" in
    *.md|docs/*)
      ;;
    *)
      emit_result false
      exit 0
      ;;
  esac
done

emit_result true
