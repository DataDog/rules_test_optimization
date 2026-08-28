#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

launcher_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
launcher_path="$launcher_dir/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "${RUNFILES_MANIFEST_FILE:-}" || ! -f "$RUNFILES_MANIFEST_FILE" ]]; then
  for manifest_candidate in \
    "$launcher_path.runfiles_manifest" \
    "$launcher_path.runfiles/MANIFEST"; do
    if [[ -f "$manifest_candidate" ]]; then
      RUNFILES_MANIFEST_FILE="$manifest_candidate"
      export RUNFILES_MANIFEST_FILE
      break
    fi
  done
fi

decode_runfiles_manifest_field() {
  local decoded="$1"
  decoded="${decoded//\\s/ }"
  decoded="${decoded//\\n/$'\n'}"
  decoded="${decoded//\\b/\\}"
  printf '%s' "$decoded"
}

resolve_runfile() {
  local direct="$1"
  local logical="$2"
  local sibling_name="${3:-}"
  local candidate root manifest line key value normalized

  if [[ -n "$sibling_name" && -f "$launcher_dir/$sibling_name" ]]; then
    printf '%s\n' "$launcher_dir/$sibling_name"
    return 0
  fi
  if [[ -n "$direct" && -f "$direct" ]]; then
    (cd "$(dirname "$direct")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$direct")")
    return 0
  fi

  normalized="${logical//\\//}"
  while [[ "$normalized" == ../* ]]; do
    normalized="${normalized#../}"
  done
  local logical_candidates=("$normalized")
  if [[ "$normalized" == external/* ]]; then
    logical_candidates+=("${normalized#external/}")
  else
    logical_candidates+=("external/$normalized")
  fi
  logical_candidates+=("_main/$normalized")

  local roots=("${RUNFILES_DIR:-}" "${TEST_SRCDIR:-}" "$launcher_path.runfiles")
  for root in "${roots[@]}"; do
    [[ -n "$root" && -d "$root" ]] || continue
    for candidate in "${logical_candidates[@]}"; do
      for value in "$root/$candidate" "${TEST_WORKSPACE:+$root/$TEST_WORKSPACE/$candidate}"; do
        if [[ -f "$value" ]]; then
          printf '%s\n' "$value"
          return 0
        fi
      done
    done
  done

  local manifests=(
    "${RUNFILES_MANIFEST_FILE:-}"
    "$launcher_path.runfiles_manifest"
    "$launcher_path.runfiles/MANIFEST"
  )
  for manifest in "${manifests[@]}"; do
    [[ -n "$manifest" && -f "$manifest" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "${line:0:1}" == " " ]]; then
        line="${line:1}"
        [[ "$line" == *" "* ]] || continue
        key="$(decode_runfiles_manifest_field "${line%% *}")"
        value="$(decode_runfiles_manifest_field "${line#* }")"
      else
        [[ "$line" == *" "* ]] || continue
        key="${line%% *}"
        value="${line#* }"
      fi
      for candidate in "${logical_candidates[@]}"; do
        if [[ "$key" == "$candidate" || "$key" == */"$candidate" ]]; then
          [[ -f "$value" ]] || continue
          printf '%s\n' "$value"
          return 0
        fi
      done
    done <"$manifest"
  done
  return 1
}

python_bin=""
for candidate in "${DD_TEST_OPTIMIZATION_PYTHON:-}" "${PYTHON:-}" python3 python; do
  [[ -n "$candidate" ]] || continue
  if command -v "$candidate" >/dev/null 2>&1; then
    python_bin="$(command -v "$candidate")"
    break
  fi
done
if [[ -z "$python_bin" ]]; then
  echo "[dd-uploader] error: Python 3.10 or newer was not found" >&2
  exit 2
fi

main_path="$(resolve_runfile \
  "__DDTPL_PYTHON_MAIN_PATH__" \
  "__DDTPL_PYTHON_MAIN_RLOC__" \
)" || {
  echo "[dd-uploader] error: uploader_main.py could not be resolved" >&2
  exit 2
}
config_path="$(resolve_runfile \
  "__DDTPL_PYTHON_CONFIG_PATH__" \
  "__DDTPL_PYTHON_CONFIG_RLOC__" \
  "__DDTPL_PYTHON_CONFIG_NAME__" \
)" || {
  echo "[dd-uploader] error: generated uploader config could not be resolved" >&2
  exit 2
}

exec "$python_bin" "$main_path" --config "$config_path" "$@"
