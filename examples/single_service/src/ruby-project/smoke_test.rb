manifest = ENV["DD_TEST_OPTIMIZATION_MANIFEST_FILE"] || ""
if !manifest.empty?
  manifest_normalized = manifest.tr("\\", "/")
  unless manifest_normalized.downcase.include?("manifest.txt")
    raise "DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path"
  end
end

payloads_in_files = (ENV["DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] || "")
                     .strip
                     .gsub(/\A['"]+|['"]+\z/, "")
                     .downcase
unless payloads_in_files.empty? || payloads_in_files == "true" || payloads_in_files == "1"
  raise "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true"
end
