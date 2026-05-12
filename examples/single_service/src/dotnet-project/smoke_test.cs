// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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
