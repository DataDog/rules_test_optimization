const manifest = process.env.DD_TEST_OPTIMIZATION_MANIFEST_FILE || "";
const manifestNormalized = manifest.replace(/\\/g, "/");
if (!manifestNormalized.includes(".testoptimization/manifest.txt")) {
  throw new Error("DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path");
}

if (process.env.DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES !== "true") {
  throw new Error("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true");
}
