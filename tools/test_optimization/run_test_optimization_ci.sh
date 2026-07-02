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
DO_UPLOAD=0
KEEP_TMP="${DD_TEST_OPTIMIZATION_KEEP_TMP:-0}"
TARGETS=()
TEST_ARGS=()

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
  --upload-target LABEL    Uploader target. Defaults to //:dd_upload_payloads.
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
    --upload-target)
      UPLOAD_TARGET="${2:?--upload-target requires a value}"
      shift 2
      ;;
    --upload-target=*)
      UPLOAD_TARGET="${1#--upload-target=}"
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

cleanup() {
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
  if run_bazel run "--config=$BAZEL_CONFIG" "$UPLOAD_TARGET" -- "${runtime_args[@]}" --dry-run --validate-enrichment; then
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
  if run_bazel run "--config=$BAZEL_CONFIG" "$UPLOAD_TARGET" -- "${runtime_args[@]}"; then
    :
  else
    upload_status=$?
    if [[ "$final_status" -eq 0 ]]; then
      final_status="$upload_status"
    fi
  fi
fi

exit "$final_status"
