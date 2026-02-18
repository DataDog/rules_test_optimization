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
if [[ ! -f "$TEST_FILE" ]]; then
  echo "error: unable to locate python unit test file: $TEST_FILE" >&2
  exit 1
fi

"$PYTHON" "$TEST_FILE"
