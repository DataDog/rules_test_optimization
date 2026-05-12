# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

manifest = ENV["DD_TEST_OPTIMIZATION_MANIFEST_FILE"] || ""
if !manifest.empty?
  manifest_normalized = manifest.tr("\\", "/")
  unless manifest_normalized.downcase.include?("manifest")
    # Keep this as a warning because windows launchers can rewrite formatting.
    warn "DD_TEST_OPTIMIZATION_MANIFEST_FILE did not look like a manifest path"
  end
end

payloads_in_files = (ENV["DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] || "")
                     .strip
                     .gsub(/\A['"]+|['"]+\z/, "")
                     .downcase
unless payloads_in_files.empty? || payloads_in_files.include?("true") || payloads_in_files.include?("1")
  # Keep this as a warning because windows launchers can rewrite formatting.
  warn "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES was set to an unexpected value"
end
