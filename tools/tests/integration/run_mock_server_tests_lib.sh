#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

# Shared helper functions for run_mock_server_tests.sh.

cleanup() {
  # Best-effort teardown that prioritizes deterministic cleanup over strict
  # failures. Integration runs can leave transient Bazel/Java locks behind,
  # especially on Windows, so this helper is intentionally defensive.
  if [[ -n "${SERVER_PID:-}" ]]; then
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill "$SERVER_PID" 2>/dev/null || true
      for _ in {1..10}; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
          break
        fi
        sleep 0.2
      done
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -9 "$SERVER_PID" 2>/dev/null || true
      fi
    fi
  fi
  # Bazel can keep files under output_base open on Windows for a short time.
  # Best-effort shutdown avoids cleanup flakiness from locked JVM logs.
  if [[ -n "${BAZEL:-}" && -x "${BAZEL:-}" ]]; then
    if [[ -n "${OUT_BASE:-}" ]]; then
      "$BAZEL" --output_base="$OUT_BASE" shutdown >/dev/null 2>&1 || true
    else
      "$BAZEL" shutdown >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${TMP_WS:-}" && -d "$TMP_WS" && "${KEEP_TMP:-0}" != "1" ]]; then
    chmod -R u+w "$TMP_WS" 2>/dev/null || true
    rm -rf "$TMP_WS" || true
  fi
  if [[ -n "${SERVER_PID_FILE:-}" && -f "${SERVER_PID_FILE:-}" ]]; then
    rm -f "${SERVER_PID_FILE:-}" || true
  fi
}

to_mixed_path() {
  # Convert a local path to mixed-style form (C:/...) when cygpath is
  # available. This keeps PowerShell + Git Bash path handoff predictable.
  local value="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$value" 2>/dev/null || printf '%s\n' "$value"
    return
  fi
  printf '%s\n' "$value"
}

log_line_count() {
  # Return current mock server log line count. Used as an offset marker so
  # per-scenario assertions only inspect newly produced request records.
  if [[ -f "$LOG_FILE" ]]; then
    wc -l < "$LOG_FILE" | tr -d '[:space:]'
  else
    echo 0
  fi
}

reset_mock_retries() {
  # Keep per-scenario retry assertions isolated from earlier scenario state.
  MOCK_PORT="$PORT" "$PYTHON" - <<'PY'
import json
import os
import sys
import urllib.request

port = os.environ["MOCK_PORT"]
req = urllib.request.Request(
    "http://127.0.0.1:%s/__mock/reset_retries" % port,
    data = b"{}",
    method = "POST",
)
try:
    with urllib.request.urlopen(req, timeout = 5) as resp:
        body = resp.read().decode("utf-8")
        payload = json.loads(body or "{}")
        if resp.status != 200 or payload.get("ok") != True:
            raise RuntimeError("unexpected reset response")
except Exception as exc:
    print("error: failed to reset mock retry counters: %s" % exc)
    sys.exit(1)
PY
}

path_exists() {
  # Cross-platform file existence probe that accepts mixed path separators.
  # This avoids false negatives on Windows where Bash/Python path styles differ.
  "$PYTHON" - "$1" <<'PY'
import os
import sys

path = (sys.argv[1] if len(sys.argv) > 1 else "").strip().rstrip("\r")
if not path:
    raise SystemExit(1)

candidates = [path]
if "\\" in path:
    candidates.append(path.replace("\\", "/"))
if "/" in path:
    candidates.append(path.replace("/", "\\"))

# Git Bash often uses /c/... while Bazel emits C:/... (or vice versa).
if len(path) >= 3 and path[1] == ":" and path[2] in ("/", "\\"):
    drive = path[0].lower()
    rest = path[2:].replace("\\", "/")
    candidates.append("/%s%s" % (drive, rest))

for cand in candidates:
    if os.path.isfile(cand):
        print(cand)
        raise SystemExit(0)

raise SystemExit(1)
PY
}
