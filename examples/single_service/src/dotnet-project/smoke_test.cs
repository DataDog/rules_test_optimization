using System;

public static class Program
{
    public static int Main()
    {
        var manifest = Environment.GetEnvironmentVariable("DD_TEST_OPTIMIZATION_MANIFEST_FILE") ?? string.Empty;
        if (!manifest.Contains(".testoptimization/manifest.txt", StringComparison.Ordinal))
        {
            throw new Exception("DD_TEST_OPTIMIZATION_MANIFEST_FILE is missing manifest path");
        }

        var payloadsInFiles = Environment.GetEnvironmentVariable("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES");
        if (!string.Equals(payloadsInFiles, "true", StringComparison.Ordinal))
        {
            throw new Exception("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES must be true");
        }

        return 0;
    }
}
