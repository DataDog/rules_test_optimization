manifest = ENV.fetch("DD_TEST_OPTIMIZATION_MANIFEST_FILE", "")
unless manifest.include?(".testoptimization/manifest.txt")
  raise "DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path"
end

payloads_in_files = ENV.fetch("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES", "")
unless payloads_in_files == "true"
  raise "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true"
end
