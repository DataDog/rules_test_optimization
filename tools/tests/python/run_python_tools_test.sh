#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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

TEST_DIR="${TEST_SRCDIR}/${TEST_WORKSPACE}/tools/tests/python"

# Windows often runs tests in manifest mode without a populated runfiles tree.
if [[ ! -d "$TEST_DIR" ]] && [[ -n "${RUNFILES_MANIFEST_FILE:-}" ]] && [[ -f "$RUNFILES_MANIFEST_FILE" ]]; then
  manifest_key="${TEST_WORKSPACE}/tools/tests/python/test_python_tools.py"
  manifest_path="$(awk -v key="$manifest_key" 'index($0, key " ") == 1 { print substr($0, length(key) + 2); exit }' "$RUNFILES_MANIFEST_FILE")"
  if [[ -n "$manifest_path" ]]; then
    TEST_DIR="$(dirname "$manifest_path")"
  fi
fi

if [[ ! -d "$TEST_DIR" ]]; then
  echo "error: unable to locate python unit test directory (tried runfiles tree + manifest): $TEST_DIR" >&2
  exit 1
fi

"$PYTHON" -m unittest discover -s "$TEST_DIR" -p "test*_tools.py"
