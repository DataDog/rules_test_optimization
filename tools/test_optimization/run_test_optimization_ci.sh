#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

BAZEL="${BAZEL:-bazel}"
BAZEL_CONFIG="${DD_TEST_OPTIMIZATION_BAZEL_CONFIG:-test-optimization}"
DOCTOR_TARGET="${DD_TEST_OPTIMIZATION_DOCTOR_TARGET:-//:dd_test_optimization_doctor}"
UPLOAD_TARGET="${DD_TEST_OPTIMIZATION_UPLOAD_TARGET:-//:dd_upload_payloads}"
DOCTOR_REPORT_JSON="${DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON:-}"
UPLOADER_REPORT_JSON="${DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON:-}"
REPORT_DIR="${DD_TEST_OPTIMIZATION_REPORT_DIR:-}"
SUPPORT_BUNDLE="${DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE:-}"
SUPPORT_BUNDLE_COLLECTOR="${DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR:-}"
DO_UPLOAD=0
KEEP_TMP="${DD_TEST_OPTIMIZATION_KEEP_TMP:-0}"
TARGETS=()
TEST_ARGS=()
UPLOAD_REPORT_JSON=""

usage() {
  cat <<'EOF'
Usage: tools/test_optimization/run_test_optimization_ci.sh [options] [targets...]

Runs Bazel tests with the recommended Test Optimization remote-output setup,
then validates payloads through BEP freshness and BEP artifact staging.

Options:
  --bazel PATH             Bazel/Bazelisk executable. Defaults to $BAZEL or bazel.
  --config NAME            Bazel config name. Defaults to test-optimization.
  --doctor-target LABEL    Doctor target. Defaults to //:dd_test_optimization_doctor.
  --doctor-report-json PATH
                           Write the doctor machine-readable report to PATH.
  --uploader-report-json PATH
                           Write the dry-run uploader machine-readable report to PATH.
  --report-dir PATH        Write doctor/uploader reports under PATH.
  --upload-target LABEL    Uploader target. Defaults to //:dd_upload_payloads.
  --support-bundle PATH    Write a redacted support diagnostics zip to PATH.
  --support-bundle-collector PATH
                           Collector script path. Defaults to create_support_bundle.py beside this wrapper.
  --test-flag FLAG         Extra flag passed to every bazel test invocation.
  --upload                 Run the real upload after dry-run enrichment validation.
  --no-upload              Skip the real upload. This is the default.
  --keep-tmp               Keep generated BEP and artifact-staging files.
  -h, --help               Show this help.

If no targets are supplied, the script tests //....
EOF
}

while (($#)); do
  case "$1" in
    --bazel)
      BAZEL="${2:?--bazel requires a value}"
      shift 2
      ;;
    --bazel=*)
      BAZEL="${1#--bazel=}"
      shift
      ;;
    --config)
      BAZEL_CONFIG="${2:?--config requires a value}"
      shift 2
      ;;
    --config=*)
      BAZEL_CONFIG="${1#--config=}"
      shift
      ;;
    --doctor-target)
      DOCTOR_TARGET="${2:?--doctor-target requires a value}"
      shift 2
      ;;
    --doctor-target=*)
      DOCTOR_TARGET="${1#--doctor-target=}"
      shift
      ;;
    --doctor-report-json)
      DOCTOR_REPORT_JSON="${2:?--doctor-report-json requires a value}"
      shift 2
      ;;
    --doctor-report-json=*)
      DOCTOR_REPORT_JSON="${1#--doctor-report-json=}"
      shift
      ;;
    --uploader-report-json)
      UPLOADER_REPORT_JSON="${2:?--uploader-report-json requires a value}"
      shift 2
      ;;
    --uploader-report-json=*)
      UPLOADER_REPORT_JSON="${1#--uploader-report-json=}"
      shift
      ;;
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
      ;;
    --report-dir=*)
      REPORT_DIR="${1#--report-dir=}"
      shift
      ;;
    --upload-target)
      UPLOAD_TARGET="${2:?--upload-target requires a value}"
      shift 2
      ;;
    --upload-target=*)
      UPLOAD_TARGET="${1#--upload-target=}"
      shift
      ;;
    --support-bundle)
      SUPPORT_BUNDLE="${2:?--support-bundle requires a value}"
      shift 2
      ;;
    --support-bundle=*)
      SUPPORT_BUNDLE="${1#--support-bundle=}"
      shift
      ;;
    --support-bundle-collector)
      SUPPORT_BUNDLE_COLLECTOR="${2:?--support-bundle-collector requires a value}"
      shift 2
      ;;
    --support-bundle-collector=*)
      SUPPORT_BUNDLE_COLLECTOR="${1#--support-bundle-collector=}"
      shift
      ;;
    --test-flag)
      TEST_ARGS+=("${2:?--test-flag requires a value}")
      shift 2
      ;;
    --test-flag=*)
      TEST_ARGS+=("${1#--test-flag=}")
      shift
      ;;
    --upload)
      DO_UPLOAD=1
      shift
      ;;
    --no-upload)
      DO_UPLOAD=0
      shift
      ;;
    --keep-tmp)
      KEEP_TMP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      TARGETS+=("$@")
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if ((${#TARGETS[@]} == 0)); then
  TARGETS=("//...")
fi

tmp_parent="${DD_TEST_OPTIMIZATION_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_parent"
tmp_root="$(mktemp -d "${tmp_parent%/}/dd-topt.XXXXXX")"
bep_dir="$tmp_root/bep"
artifact_staging_dir="$tmp_root/bep-artifacts"
mkdir -p "$bep_dir" "$artifact_staging_dir"
if [[ -n "$SUPPORT_BUNDLE" && -z "$REPORT_DIR" ]]; then
  REPORT_DIR="$tmp_root/reports"
fi
if [[ -n "$REPORT_DIR" ]]; then
  mkdir -p "$REPORT_DIR"
  if [[ -z "$DOCTOR_REPORT_JSON" ]]; then
    DOCTOR_REPORT_JSON="$REPORT_DIR/doctor-report.json"
  fi
  if [[ -z "$UPLOADER_REPORT_JSON" ]]; then
    UPLOADER_REPORT_JSON="$REPORT_DIR/uploader-dry-run-report.json"
  fi
  UPLOAD_REPORT_JSON="$REPORT_DIR/uploader-upload-report.json"
fi
command_manifest_json="$tmp_root/support-command-manifest.json"

cleanup() {
  create_support_bundle
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo "keeping Test Optimization temporary files: $tmp_root" >&2
    return
  fi
  rm -rf "$tmp_root"
}
trap cleanup EXIT

sanitize_target() {
  local value="$1"
  value="${value//[^A-Za-z0-9_.-]/_}"
  if [[ -z "${value//_/}" ]]; then
    value="target"
  fi
  printf '%s' "$value"
}

run_bazel() {
  echo "+ $BAZEL $*" >&2
  "$BAZEL" "$@"
}

resolve_python() {
  local candidate
  for candidate in "${DD_TEST_OPTIMIZATION_PYTHON:-}" "${PYTHON:-}" python3 python; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" || -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_output_base() {
  "$BAZEL" info output_base 2>/dev/null || true
}

resolve_support_bundle_collector() {
  if [[ -n "$SUPPORT_BUNDLE_COLLECTOR" ]]; then
    printf '%s\n' "$SUPPORT_BUNDLE_COLLECTOR"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$script_dir/create_support_bundle.py"
}

write_command_manifest() {
  local python="${1:?python required}"
  local bep_files=()
  local bep_arg
  for bep_arg in "${bep_args[@]}"; do
    bep_files+=("${bep_arg#--bep-json=}")
  done
  "$python" - "$command_manifest_json" "$BAZEL" "$BAZEL_CONFIG" "$DOCTOR_TARGET" "$UPLOAD_TARGET" "$artifact_staging_dir" "$REPORT_DIR" "$DOCTOR_REPORT_JSON" "$UPLOADER_REPORT_JSON" "$UPLOAD_REPORT_JSON" "$DO_UPLOAD" "${#TEST_ARGS[@]}" "${TEST_ARGS[@]}" "${#bep_files[@]}" "${bep_files[@]}" "${TARGETS[@]}" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    bazel,
    bazel_config,
    doctor_target,
    upload_target,
    artifact_staging_dir,
    report_dir,
    doctor_report_json,
    uploader_report_json,
    upload_report_json,
    do_upload,
    test_arg_count,
    *rest,
) = sys.argv[1:]
test_arg_count = int(test_arg_count)
test_args = rest[:test_arg_count]
rest = rest[test_arg_count:]
bep_file_count = int(rest[0])
bep_files = rest[1:1 + bep_file_count]
targets = rest[1 + bep_file_count:]

Path(output).write_text(json.dumps({
    "bazel": bazel,
    "config": bazel_config,
    "doctor_target": doctor_target,
    "upload_target": upload_target,
    "artifact_staging_dir": artifact_staging_dir,
    "report_dir": report_dir,
    "doctor_report_json": doctor_report_json,
    "uploader_report_json": uploader_report_json,
    "upload_report_json": upload_report_json,
    "upload_enabled": do_upload == "1",
    "bep_files": bep_files,
    "test_flags": test_args,
    "runtime_flags": [
        "--freshness-source=bep",
        "--freshness-mode=required",
        "--artifact-source=bep",
        "--artifact-staging-dir=" + artifact_staging_dir,
    ],
    "targets": targets,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

create_support_bundle() {
  if [[ -z "$SUPPORT_BUNDLE" ]]; then
    return 0
  fi
  local collector output_base python
  collector="$(resolve_support_bundle_collector)"
  if [[ ! -f "$collector" ]]; then
    echo "warning: support bundle collector not found: $collector" >&2
    return 0
  fi
  if ! python="$(resolve_python)"; then
    echo "warning: Python interpreter not found; skipping Test Optimization support bundle: $SUPPORT_BUNDLE" >&2
    return 0
  fi
  write_command_manifest "$python" || echo "warning: failed to write support bundle command manifest" >&2
  output_base="$(resolve_output_base)"
  local args=(
    "$collector"
    "--report-dir=$REPORT_DIR"
    "--output=$SUPPORT_BUNDLE"
    "--command-manifest-json=$command_manifest_json"
    "--workspace-root=$(pwd)"
    "--tmp-root=$tmp_root"
    "--bazel=$BAZEL"
  )
  if [[ -n "$output_base" ]]; then
    args+=("--output-base=$output_base")
  fi
  for report_path in "$DOCTOR_REPORT_JSON" "$UPLOADER_REPORT_JSON" "$UPLOAD_REPORT_JSON"; do
    if [[ -n "$report_path" ]]; then
      args+=("--report-json=$report_path")
    fi
  done
  for bep_arg in "${bep_args[@]}"; do
    args+=("--bep-json=${bep_arg#--bep-json=}")
  done
  if ! "$python" "${args[@]}"; then
    echo "warning: failed to create Test Optimization support bundle: $SUPPORT_BUNDLE" >&2
  fi
}

bep_args=()
test_status=0
idx=0

for target in "${TARGETS[@]}"; do
  idx=$((idx + 1))
  safe_target="$(sanitize_target "$target")"
  bep_json="$bep_dir/${idx}_${safe_target}.bep.json"
  bep_args+=("--bep-json=$bep_json")

  test_command=(test "--config=$BAZEL_CONFIG")
  if ((${#TEST_ARGS[@]} > 0)); then
    test_command+=("${TEST_ARGS[@]}")
  fi
  test_command+=("--build_event_json_file=$bep_json" "$target")

  if run_bazel "${test_command[@]}"; then
    :
  else
    rc=$?
    if [[ "$test_status" -eq 0 ]]; then
      test_status="$rc"
    fi
  fi
done

runtime_args=(
  "${bep_args[@]}"
  "--freshness-source=bep"
  "--freshness-mode=required"
  "--artifact-source=bep"
  "--artifact-staging-dir=$artifact_staging_dir"
)

final_status="$test_status"
doctor_runtime_args=("${runtime_args[@]}")
if [[ -n "$DOCTOR_REPORT_JSON" ]]; then
  doctor_runtime_args+=("--report-json=$DOCTOR_REPORT_JSON")
fi

if run_bazel run "--config=$BAZEL_CONFIG" "$DOCTOR_TARGET" -- "${doctor_runtime_args[@]}"; then
  doctor_status=0
else
  doctor_status=$?
  if [[ "$final_status" -eq 0 ]]; then
    final_status="$doctor_status"
  fi
fi

if [[ "$doctor_status" -eq 0 ]]; then
  dry_run_runtime_args=("${runtime_args[@]}")
  if [[ -n "$UPLOADER_REPORT_JSON" ]]; then
    dry_run_runtime_args+=("--report-json=$UPLOADER_REPORT_JSON")
  fi
  if run_bazel run "--config=$BAZEL_CONFIG" "$UPLOAD_TARGET" -- "${dry_run_runtime_args[@]}" --dry-run --validate-enrichment; then
    dry_run_status=0
  else
    dry_run_status=$?
    if [[ "$final_status" -eq 0 ]]; then
      final_status="$dry_run_status"
    fi
  fi
else
  dry_run_status=0
fi

if [[ "$doctor_status" -eq 0 && "$dry_run_status" -eq 0 && "$DO_UPLOAD" -eq 1 ]]; then
  upload_runtime_args=("${runtime_args[@]}")
  if [[ -n "$UPLOAD_REPORT_JSON" ]]; then
    upload_runtime_args+=("--report-json=$UPLOAD_REPORT_JSON")
  fi
  if run_bazel run "--config=$BAZEL_CONFIG" "$UPLOAD_TARGET" -- "${upload_runtime_args[@]}"; then
    :
  else
    upload_status=$?
    if [[ "$final_status" -eq 0 ]]; then
      final_status="$upload_status"
    fi
  fi
fi

exit "$final_status"
