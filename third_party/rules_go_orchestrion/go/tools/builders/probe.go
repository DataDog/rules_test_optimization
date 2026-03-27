// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// orchestrionProbeEnvVar enables structured timing probes across the
	// vendored rules_go fork when set to a truthy value.
	orchestrionProbeEnvVar = "RULES_GO_ORCHESTRION_PROBE"

	// orchestrionProbeFileEnvVar optionally mirrors builder probe lines into a
	// host-visible file so successful Bazel actions do not hide the timings.
	orchestrionProbeFileEnvVar = "RULES_GO_ORCHESTRION_PROBE_FILE"

	// orchestrionProbePrefix is the stable line prefix emitted for every probe.
	orchestrionProbePrefix = "RULES_GO_ORCHESTRION_PROBE"

	// orchestrionProbeDefaultFileName is the default file name used when probe
	// collection is mirrored into the shared Orchestrion cache.
	orchestrionProbeDefaultFileName = "builder-probes.log"

	// orchestrionProbeSharedCacheDirName matches the stable shared cache root
	// already used by the Orchestrion builders for local persistent state.
	orchestrionProbeSharedCacheDirName = "datadog-orchestrion-go-cache"
)

var (
	orchestrionProbeEnabledOnce  sync.Once
	orchestrionProbeEnabledFlag  bool
	orchestrionProbeFilePathOnce sync.Once
	orchestrionProbeFilePath     string
	orchestrionProbeWriteMu      sync.Mutex
)

// probeField is a single structured key/value attribute attached to a probe.
type probeField struct {
	Key   string
	Value string
}

// probeSpan measures the elapsed time for a named phase.
type probeSpan struct {
	phase   string
	start   time.Time
	fields  []probeField
	enabled bool
}

// newProbeField creates a structured attribute for a probe line.
func newProbeField(key, value string) probeField {
	return probeField{Key: key, Value: value}
}

// beginProbe starts a timed probe span for the provided phase.
func beginProbe(phase string, fields ...probeField) probeSpan {
	return probeSpan{
		phase:   phase,
		start:   time.Now(),
		fields:  append([]probeField(nil), fields...),
		enabled: probesEnabled(),
	}
}

// End emits the final timing line for the probe span.
func (p probeSpan) End(err error, fields ...probeField) {
	if !p.enabled {
		return
	}
	merged := make([]probeField, 0, len(p.fields)+len(fields)+2)
	merged = append(merged, p.fields...)
	merged = append(merged, fields...)
	merged = append(merged, newProbeField("status", probeStatus(err)))
	if err != nil {
		merged = append(merged, newProbeField("error", err.Error()))
	}
	emitProbeLine(p.phase, time.Since(p.start), merged...)
}

// probesEnabled reports whether structured timing probes should be emitted.
func probesEnabled() bool {
	orchestrionProbeEnabledOnce.Do(func() {
		orchestrionProbeEnabledFlag = truthyEnv(os.Getenv(orchestrionProbeEnvVar))
	})
	return orchestrionProbeEnabledFlag
}

// emitProbeLine writes a single structured timing event to stderr.
func emitProbeLine(phase string, elapsed time.Duration, fields ...probeField) {
	if !probesEnabled() {
		return
	}
	merged := make([]probeField, 0, len(fields)+3)
	merged = append(merged,
		newProbeField("phase", phase),
		newProbeField("pid", strconv.Itoa(os.Getpid())),
		newProbeField("elapsed_ms", fmt.Sprintf("%.3f", float64(elapsed)/float64(time.Millisecond))),
		newProbeField("ts_unix_ms", strconv.FormatInt(time.Now().UnixMilli(), 10)),
	)
	merged = append(merged, fields...)
	sort.SliceStable(merged, func(i, j int) bool {
		return merged[i].Key < merged[j].Key
	})

	var b strings.Builder
	b.WriteString(orchestrionProbePrefix)
	for _, field := range merged {
		if field.Key == "" {
			continue
		}
		b.WriteByte(' ')
		b.WriteString(field.Key)
		b.WriteByte('=')
		b.WriteString(strconv.Quote(field.Value))
	}
	b.WriteByte('\n')
	line := b.String()
	_, _ = os.Stderr.WriteString(line)
	appendProbeFile(line)
}

// probeStatus converts an error value into a stable probe status token.
func probeStatus(err error) string {
	if err != nil {
		return "error"
	}
	return "ok"
}

// truthyEnv returns true when an environment variable is explicitly enabled.
func truthyEnv(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on", "enabled":
		return true
	default:
		return false
	}
}

// probeFilePath returns the host-visible file used to mirror builder probe
// lines for successful Bazel actions.
func probeFilePath() string {
	orchestrionProbeFilePathOnce.Do(func() {
		configuredPath := strings.TrimSpace(os.Getenv(orchestrionProbeFileEnvVar))
		if configuredPath == "" {
			orchestrionProbeFilePath = defaultProbeFilePath()
			return
		}
		orchestrionProbeFilePath = sanitizedProbeFilePath(configuredPath)
	})
	return orchestrionProbeFilePath
}

// appendProbeFile mirrors probe lines into a shared append-only file when the
// caller requested it. This is best-effort instrumentation and must never
// change builder behavior if the file is unavailable.
func appendProbeFile(line string) {
	path := probeFilePath()
	if path == "" {
		return
	}

	orchestrionProbeWriteMu.Lock()
	defer orchestrionProbeWriteMu.Unlock()

	if appendProbeLineToPath(path, line) == nil {
		return
	}
	if path != defaultProbeFilePath() {
		_ = appendProbeLineToPath(defaultProbeFilePath(), line)
	}
}

// defaultProbeFilePath keeps probe collection under the same shared cache root
// the Orchestrion builders already use for their persistent state.
func defaultProbeFilePath() string {
	return filepath.Join(orchestrionProbeDir(), orchestrionProbeDefaultFileName)
}

// orchestrionProbeDir is the stable directory where probe logs are collected.
func orchestrionProbeDir() string {
	return filepath.Join(orchestrionProbeCacheRoot(), "probes")
}

// appendProbeLineToPath best-effort appends a probe line to the requested
// collection file without changing builder behavior on failure.
func appendProbeLineToPath(path, line string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(line)
	return err
}

// sanitizedProbeFilePath constrains custom probe mirrors to locations the
// builders already own so probe logging cannot be redirected to arbitrary host
// paths. Absolute paths must stay under the shared probe cache or the system
// temp directory; relative paths stay rooted under the shared probe directory.
func sanitizedProbeFilePath(configuredPath string) string {
	defaultPath := defaultProbeFilePath()
	if configuredPath == "" {
		return defaultPath
	}
	if filepath.IsAbs(configuredPath) {
		cleanedPath := filepath.Clean(configuredPath)
		if probePathWithinBase(cleanedPath, os.TempDir()) || probePathWithinBase(cleanedPath, orchestrionProbeCacheRoot()) {
			return cleanedPath
		}
		return defaultPath
	}

	rootedPath := filepath.Clean(filepath.Join(orchestrionProbeDir(), configuredPath))
	if probePathWithinBase(rootedPath, orchestrionProbeDir()) {
		return rootedPath
	}
	return defaultPath
}

// probePathWithinBase reports whether the target path stays inside the base
// directory after path normalization.
func probePathWithinBase(targetPath, baseDir string) bool {
	cleanBase := filepath.Clean(baseDir)
	cleanTarget := filepath.Clean(targetPath)
	relPath, err := filepath.Rel(cleanBase, cleanTarget)
	if err != nil {
		return false
	}
	return relPath == "." || (relPath != ".." && !strings.HasPrefix(relPath, ".."+string(os.PathSeparator)))
}

// orchestrionProbeCacheRoot mirrors the builder cache root selection so probe
// files land in a location that survives across local Bazel output bases.
func orchestrionProbeCacheRoot() string {
	if cacheRoot := strings.TrimSpace(os.Getenv("GOPATH")); cacheRoot != "" {
		return probeAbs(cacheRoot)
	}
	if cacheDir := strings.TrimSpace(os.Getenv("XDG_CACHE_HOME")); cacheDir != "" {
		return filepath.Join(probeAbs(cacheDir), orchestrionProbeSharedCacheDirName)
	}
	if cacheDir, err := os.UserCacheDir(); err == nil && strings.TrimSpace(cacheDir) != "" {
		return filepath.Join(probeAbs(cacheDir), orchestrionProbeSharedCacheDirName)
	}
	if home := strings.TrimSpace(os.Getenv("HOME")); home != "" {
		return filepath.Join(probeAbs(home), ".cache", orchestrionProbeSharedCacheDirName)
	}
	if homeDir, err := os.UserHomeDir(); err == nil && strings.TrimSpace(homeDir) != "" {
		return filepath.Join(probeAbs(homeDir), ".cache", orchestrionProbeSharedCacheDirName)
	}
	return filepath.Join(os.TempDir(), orchestrionProbeSharedCacheDirName)
}

// probeAbs normalizes probe cache paths without failing the builder if a path
// cannot be absolutized.
func probeAbs(path string) string {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return absPath
}
