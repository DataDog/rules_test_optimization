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

	// orchestrionProbePrefix is the stable line prefix emitted for every probe.
	orchestrionProbePrefix = "RULES_GO_ORCHESTRION_PROBE"
)

var (
	orchestrionProbeEnabledOnce sync.Once
	orchestrionProbeEnabledFlag bool
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
	_, _ = os.Stderr.WriteString(b.String())
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
