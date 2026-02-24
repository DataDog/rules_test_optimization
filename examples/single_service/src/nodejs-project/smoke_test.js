const manifest = process.env.DD_TEST_OPTIMIZATION_MANIFEST_FILE || "";
if (manifest) {
  const manifestNormalized = manifest.replace(/\\/g, "/");
  if (!manifestNormalized.toLowerCase().includes("manifest")) {
    // Keep this as a warning because windows launchers can rewrite formatting.
    console.warn("DD_TEST_OPTIMIZATION_MANIFEST_FILE did not look like a manifest path");
  }
}

const payloadsInFilesRaw = process.env.DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES || "";
const payloadsInFiles = payloadsInFilesRaw
  .trim()
  .replace(/^['"]+|['"]+$/g, "")
  .toLowerCase();
if (payloadsInFiles && !payloadsInFiles.includes("true") && !payloadsInFiles.includes("1")) {
  // Keep this as a warning because windows launchers can rewrite formatting.
  console.warn("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES was set to an unexpected value");
}
