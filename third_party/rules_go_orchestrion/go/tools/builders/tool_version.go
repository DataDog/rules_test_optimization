package main

import (
	"fmt"
	"os"
	"strings"
)

const (
	// rulesGoOrchestrionToolVersionFileEnvVar points at the generated tool-repo
	// file that records the exact Orchestrion tool version configured for this
	// build.
	rulesGoOrchestrionToolVersionFileEnvVar = "RULES_GO_ORCHESTRION_TOOL_VERSION_FILE"
)

// configuredOrchestrionToolVersion returns the configured Orchestrion tool
// version from the generated tool-repo metadata file.
func configuredOrchestrionToolVersion() (string, error) {
	versionFile := strings.TrimSpace(os.Getenv(rulesGoOrchestrionToolVersionFileEnvVar))
	if versionFile == "" {
		return "", fmt.Errorf("%s is not set", rulesGoOrchestrionToolVersionFileEnvVar)
	}
	content, err := os.ReadFile(versionFile)
	if err != nil {
		return "", fmt.Errorf("read configured orchestrion tool version file %s: %w", versionFile, err)
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
