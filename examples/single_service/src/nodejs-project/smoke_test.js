// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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
