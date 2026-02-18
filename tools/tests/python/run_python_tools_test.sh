#!/usr/bin/env bash
set -euo pipefail

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON="python"
  else
    echo "error: python interpreter not found (tried '$PYTHON' and 'python')" >&2
    exit 1
  fi
fi

TEST_FILE="${TEST_SRCDIR}/${TEST_WORKSPACE}/tools/tests/python/test_python_tools.py"

# Windows often runs tests in manifest mode without a populated runfiles tree.
if [[ ! -f "$TEST_FILE" ]] && [[ -n "${RUNFILES_MANIFEST_FILE:-}" ]] && [[ -f "$RUNFILES_MANIFEST_FILE" ]]; then
  manifest_key="${TEST_WORKSPACE}/tools/tests/python/test_python_tools.py"
  manifest_path="$(awk -v key="$manifest_key" 'index($0, key " ") == 1 { print substr($0, length(key) + 2); exit }' "$RUNFILES_MANIFEST_FILE")"
  if [[ -n "$manifest_path" ]]; then
    TEST_FILE="$manifest_path"
  fi
fi

if [[ ! -f "$TEST_FILE" ]]; then
  echo "error: unable to locate python unit test file (tried runfiles tree + manifest): $TEST_FILE" >&2
  exit 1
fi

"$PYTHON" "$TEST_FILE"
