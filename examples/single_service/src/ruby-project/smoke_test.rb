manifest = ENV.fetch("DD_TEST_OPTIMIZATION_MANIFEST_FILE", "")
manifest_normalized = manifest.tr("\\", "/")
unless manifest_normalized.include?(".testoptimization/manifest.txt")
  raise "DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path"
end

payloads_in_files = ENV.fetch("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES", "")
unless payloads_in_files == "true"
  raise "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true"
end
