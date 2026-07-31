#!/usr/bin/env bash

# Shared deterministic metadata server lifecycle for Go integration smokes.

GO_INTEGRATION_MOCK_SERVER_PID=""
GO_INTEGRATION_MOCK_SERVER_LOG=""
declare -a GO_INTEGRATION_MOCK_REPO_ENVS=()

stop_go_integration_mock_server() {
  if [[ -n "$GO_INTEGRATION_MOCK_SERVER_PID" ]]; then
    kill "$GO_INTEGRATION_MOCK_SERVER_PID" >/dev/null 2>&1 || true
    wait "$GO_INTEGRATION_MOCK_SERVER_PID" >/dev/null 2>&1 || true
    GO_INTEGRATION_MOCK_SERVER_PID=""
  fi
}

start_go_integration_mock_server() {
  local tmp_root="$1"
  local module_identifier="$2"
  local fixtures_dir="$tmp_root/enabled-metadata-fixtures"
  local port
  local ready=0
  local server_out="$tmp_root/enabled-metadata-server.out"

  rm -rf "$fixtures_dir"
  mkdir -p "$fixtures_dir"
  cp "$REPO_ROOT/tools/tests/integration/fixtures/settings.json" "$fixtures_dir/settings.json"
  "$PYTHON" - "$fixtures_dir" "$module_identifier" <<'PY'
import json
import pathlib
import sys

fixtures_dir = pathlib.Path(sys.argv[1])
module_identifier = sys.argv[2]
(fixtures_dir / "known_tests.json").write_text(json.dumps({
    "data": {
        "id": "1",
        "type": "ci_app_libraries_tests",
        "attributes": {"tests": {module_identifier: {"suite": {"test": {}}}}},
    },
}), encoding="utf-8")
(fixtures_dir / "test_management.json").write_text(json.dumps({
    "data": {
        "id": "1",
        "type": "ci_app_libraries_tests",
        "attributes": {"modules": {module_identifier: {"tests": {}}}},
    },
}), encoding="utf-8")
PY

  port="$("$PYTHON" - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
  GO_INTEGRATION_MOCK_SERVER_LOG="$tmp_root/enabled-metadata-requests.jsonl"
  : >"$GO_INTEGRATION_MOCK_SERVER_LOG"

  "$PYTHON" -u "$REPO_ROOT/tools/tests/integration/mock_dd_server.py" \
    --fixtures "$fixtures_dir" \
    --log "$GO_INTEGRATION_MOCK_SERVER_LOG" \
    --port "$port" >"$server_out" 2>&1 &
  GO_INTEGRATION_MOCK_SERVER_PID=$!

  for _ in $(seq 1 100); do
    if "$PYTHON" - "$port" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
    then
      ready=1
      break
    fi
    if ! kill -0 "$GO_INTEGRATION_MOCK_SERVER_PID" >/dev/null 2>&1; then
      cat "$server_out" >&2
      echo "error: enabled metadata server exited before becoming ready" >&2
      return 1
    fi
    sleep 0.1
  done

  if [[ "$ready" != "1" ]]; then
    cat "$server_out" >&2
    echo "error: timed out waiting for enabled metadata server" >&2
    return 1
  fi

  GO_INTEGRATION_MOCK_REPO_ENVS=(
    --repo_env=DD_API_KEY=mock
    --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$port"
  )
}

assert_go_integration_metadata_requests() {
  "$PYTHON" - "$GO_INTEGRATION_MOCK_SERVER_LOG" <<'PY'
import json
import sys

required = {
    "/api/v2/libraries/tests/services/setting",
    "/api/v2/ci/libraries/tests",
    "/api/v2/test/libraries/test-management/tests",
}
with open(sys.argv[1], encoding="utf-8") as request_log:
    observed = {json.loads(line)["path"] for line in request_log if line.strip()}
missing = sorted(required - observed)
if missing:
    raise SystemExit(f"enabled metadata smoke did not call required endpoints: {missing}; observed={sorted(observed)}")
PY
}
