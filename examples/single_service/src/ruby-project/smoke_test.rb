manifest = ENV["DD_TEST_OPTIMIZATION_MANIFEST_FILE"] || ""
if !manifest.empty?
  manifest_normalized = manifest.tr("\\", "/")
  unless manifest_normalized.include?("manifest.txt")
    raise "DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path"
  end
end

payloads_in_files = ENV["DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] || ""
unless payloads_in_files.empty? || payloads_in_files == "true"
  raise "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true"
end
