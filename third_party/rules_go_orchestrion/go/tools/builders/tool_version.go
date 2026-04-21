package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	// rulesGoOrchestrionToolVersionFileEnvVar points at the generated tool-repo
	// file that records the exact Orchestrion tool version configured for this
	// build.
	rulesGoOrchestrionToolVersionFileEnvVar = "RULES_GO_ORCHESTRION_TOOL_VERSION_FILE"

	// orchestrionToolVersionFileName is the only generated metadata file name
	// accepted for the configured Orchestrion tool version input.
	orchestrionToolVersionFileName = "orchestrion_version.txt"

	// ddTraceGoVersionsFileName is the only generated metadata file name accepted
	// for the configured dd-trace-go version input.
	ddTraceGoVersionsFileName = "dd_trace_go_versions.json"
)

// configuredOrchestrionToolVersion returns the configured Orchestrion tool
// version from the generated tool-repo metadata file.
func configuredOrchestrionToolVersion() (string, error) {
	content, versionFile, err := readGeneratedMetadataFile(
		rulesGoOrchestrionToolVersionFileEnvVar,
		orchestrionToolVersionFileName,
	)
	if err != nil {
		return "", err
	}
	version := strings.TrimSpace(string(content))
	if version == "" {
		return "", fmt.Errorf("configured orchestrion tool version file %s is empty", versionFile)
	}
	return version, nil
}

// orchestrionToolVersionIdentity returns the best-effort Orchestrion version
// token used in cache identity when the strict version file is unavailable.
func orchestrionToolVersionIdentity() string {
	version, err := configuredOrchestrionToolVersion()
	if err != nil {
		return "unknown-orchestrion-version"
	}
	return version
}

// readGeneratedMetadataFile reads a generated metadata file referenced through
// action environment. Only the expected generated file name is accepted so the
// builder does not follow arbitrary file paths supplied through the environment.
func readGeneratedMetadataFile(envVar, expectedBaseName string) ([]byte, string, error) {
	path := strings.TrimSpace(os.Getenv(envVar))
	if path == "" {
		return nil, "", fmt.Errorf("%s is not set", envVar)
	}
	if err := validateGeneratedMetadataFilePath(path, expectedBaseName); err != nil {
		return nil, "", err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("read generated metadata file %s: %w", path, err)
	}
	return content, path, nil
}

// validateGeneratedMetadataFilePath rejects traversal-like paths and enforces
// the exact generated metadata file name expected for a given environment slot.
func validateGeneratedMetadataFilePath(path, expectedBaseName string) error {
	if filepath.Base(path) != expectedBaseName {
		return fmt.Errorf("generated metadata path %q must point to %s", path, expectedBaseName)
	}
	for _, component := range strings.Split(filepath.ToSlash(path), "/") {
		if component == ".." {
			return fmt.Errorf("generated metadata path %q must not contain parent directory traversal", path)
		}
	}
	return nil
}
