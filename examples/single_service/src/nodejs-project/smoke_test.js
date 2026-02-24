const manifest = process.env.DD_TEST_OPTIMIZATION_MANIFEST_FILE || "";
if (manifest) {
  const manifestNormalized = manifest.replace(/\\/g, "/");
  if (!manifestNormalized.includes("manifest.txt")) {
    throw new Error("DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path");
  }
}

const payloadsInFiles = process.env.DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES || "";
if (payloadsInFiles && payloadsInFiles !== "true") {
  throw new Error("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true");
}
