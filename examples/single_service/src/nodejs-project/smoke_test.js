const manifest = process.env.DD_TEST_OPTIMIZATION_MANIFEST_FILE || "";
if (manifest) {
  const manifestNormalized = manifest.replace(/\\/g, "/");
  if (!manifestNormalized.toLowerCase().includes("manifest.txt")) {
    throw new Error("DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path");
  }
}

const payloadsInFilesRaw = process.env.DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES || "";
const payloadsInFiles = payloadsInFilesRaw
  .trim()
  .replace(/^['"]+|['"]+$/g, "")
  .toLowerCase();
if (payloadsInFiles && payloadsInFiles !== "true" && payloadsInFiles !== "1") {
  throw new Error("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true");
}
