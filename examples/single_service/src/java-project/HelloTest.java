package com.example.topt;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class HelloTest {
    @Test
    public void testGreeting() {
        assertEquals("Hello from Java!", Hello.greeting());
    }

    @Test
    public void testManifestEnvConfigured() {
        String manifest = System.getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE");
        assertNotNull("DD_TEST_OPTIMIZATION_MANIFEST_FILE should be set by dd_topt_java_test", manifest);
        assertFalse("DD_TEST_OPTIMIZATION_MANIFEST_FILE should not be empty", manifest.isEmpty());
        assertTrue(
                "DD_TEST_OPTIMIZATION_MANIFEST_FILE should point to manifest.txt runfile",
                manifest.contains("manifest.txt"));
    }
}
