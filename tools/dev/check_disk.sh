#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# Fails early before expensive Bazel validations when the host is too low on
# free disk space. Bazel and Go caches are intentionally not cleaned here; the
# caller decides what can be safely removed for the current phase.
min_free_gb="${RTO_MIN_FREE_GB:-25}"
path="${1:-/}"

available_kb="$(df -Pk "${path}" | awk 'NR == 2 {print $4}')"
if [[ -z "${available_kb}" ]]; then
  echo "Could not read free disk space for ${path}" >&2
  exit 2
fi

available_gb="$((available_kb / 1024 / 1024))"
if (( available_gb < min_free_gb )); then
  echo "Free disk space for ${path} is ${available_gb}G, below required ${min_free_gb}G" >&2
  exit 1
fi

echo "Free disk space for ${path}: ${available_gb}G (minimum ${min_free_gb}G)"
