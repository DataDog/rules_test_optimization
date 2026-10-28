// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"errors"
	"fmt"
	"path"
	"reflect"
	"regexp"
	"strconv"
	"strings"

	"github.com/DataDog/rules_test_optimization/modules/go/tools/onboardingpins"
)

// moduleArchive describes the whole Datadog source archive, not just the fork.
// Keep mirrors and the checksum together when deriving a rules_go subdirectory.
type moduleArchive struct {
	urls        []string
	sha256      string
	prefix      string
	archiveType string
}

func (a moduleArchive) validate() error {
	if len(a.urls) == 0 || !regexp.MustCompile(`^[a-fA-F0-9]{64}$`).MatchString(a.sha256) {
		return errors.New("archive override requires literal non-empty urls and a 64-character sha256; use --rto-archive-url, --rto-archive-sha256 and --rto-archive-prefix for computed MODULE values")
	}
	for _, url := range a.urls {
		if strings.TrimSpace(url) == "" {
			return errors.New("archive override contains an empty URL")
		}
	}
	if a.prefix == "" || path.IsAbs(a.prefix) || path.Clean(a.prefix) != a.prefix || a.prefix == ".." || strings.HasPrefix(a.prefix, "../") {
		return errors.New("archive override requires a non-empty relative strip_prefix without parent traversal")
	}
	return nil
}

func (a moduleArchive) render(forkPrefix string) string {
	var result strings.Builder
	result.WriteString("archive_override(\n    module_name = \"rules_go\",\n    urls = [\n")
	for _, url := range a.urls {
		fmt.Fprintf(&result, "        %q,\n", url)
	}
	fmt.Fprintf(&result, "    ],\n    sha256 = %q,\n    strip_prefix = %q,\n", a.sha256, a.prefix+"/"+forkPrefix)
	if a.archiveType != "" {
		fmt.Fprintf(&result, "    type = %q,\n", a.archiveType)
	}
	result.WriteString(")\n")
	return result.String()
}

// configureModuleArchive prefers an existing rules_go archive, then a core/Go
// archive. Explicit Git flags keep their previous meaning. No URL is fetched.
func configureModuleArchive(cfg *config, content string) error {
	if cfg.rulesGoFetchSet && cfg.rulesGoFetch == "git" && cfg.rtoArchiveURL != "" {
		return errors.New("--rules-go-fetch=git conflicts with explicit --rto-archive-* flags for Bzlmod")
	}
	if cfg.rtoArchiveURL != "" || cfg.rulesGoFetch == "archive" {
		archive := &moduleArchive{urls: []string{cfg.rtoArchiveURL}, sha256: cfg.rtoArchiveSHA256, prefix: cfg.rtoArchivePrefix, archiveType: cfg.rtoArchiveType}
		if err := archive.validate(); err != nil {
			return err
		}
		cfg.rulesGoArchive = archive
		return nil
	}
	if cfg.rulesGoCommitSet || cfg.rulesGoRemoteSet || cfg.rulesGoFetchSet {
		return nil
	}
	if remote, commit := inferManagedRulesGoOverride(content); remote != "" && commit != "" {
		cfg.rulesGoRemote, cfg.rulesGoCommit = remote, commit
		return nil
	}
	for _, name := range []string{"rules_go", "datadog-rules-test-optimization-go", "datadog-rules-test-optimization"} {
		archive, err := findModuleArchive(content, name)
		if err != nil {
			return err
		}
		if archive == nil {
			continue
		}
		if name == "rules_go" {
			index := strings.Index(archive.prefix, "/third_party/rgo/")
			if index < 0 {
				return errors.New("rules_go archive strip_prefix is not a supported Datadog fork path")
			}
			upstream, variant, err := onboardingpins.RulesGoSelectionForStripPrefix(archive.prefix[index+1:])
			if err != nil {
				return err
			}
			if !cfg.rulesGoUpstreamSet && !cfg.rulesGoVariantSet {
				cfg.rulesGoUpstream, cfg.rulesGoVariant = upstream, variant
			}
			fork, err := rulesGoStripPrefix(*cfg)
			if err != nil {
				return err
			}
			if archive.prefix[index+1:] != fork {
				return errors.New("existing rules_go archive selects another upstream; update its override before changing the bootstrap selection")
			}
			archive.prefix = archive.prefix[:index]
		} else {
			if name == "datadog-rules-test-optimization-go" {
				if !strings.HasSuffix(archive.prefix, "/modules/go") {
					return errors.New("Go companion archive strip_prefix must end with /modules/go; pass explicit archive flags for a custom layout")
				}
				archive.prefix = strings.TrimSuffix(archive.prefix, "/modules/go")
			}
		}
		cfg.rulesGoArchive = archive
		return nil
	}
	return nil
}

func moduleOverridePresent(content, module string) bool {
	for _, block := range topLevelCallBlocks(stripStarlarkLineComments(content)) {
		if strings.HasSuffix(block.function, "_override") && literalAttribute(block.text, "module_name") == module {
			return true
		}
	}
	return false
}

func moduleArchiveCompatible(content string, cfg config) (bool, error) {
	existing, err := findModuleArchive(content, "rules_go")
	if err != nil || existing == nil {
		return false, err
	}
	fork, err := rulesGoStripPrefix(cfg)
	if err != nil {
		return false, err
	}
	wanted := cfg.rulesGoArchive
	return reflect.DeepEqual(existing.urls, wanted.urls) && strings.EqualFold(existing.sha256, wanted.sha256) && existing.prefix == wanted.prefix+"/"+fork && existing.archiveType == wanted.archiveType, nil
}

// These are literal-only readers, like the existing bootstrap's Git readers.
// Never guess the result of a Starlark expression or silently drop a fork patch.
func findModuleArchive(content, module string) (*moduleArchive, error) {
	for _, block := range topLevelCallBlocks(stripStarlarkLineComments(content)) {
		if block.function != "archive_override" || literalAttribute(block.text, "module_name") != module {
			continue
		}
		if module == "rules_go" {
			// Attribute-looking text in URLs is data, not a keyword argument.
			withoutStrings := regexp.MustCompile(`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'`).ReplaceAllString(block.text, `""`)
			for _, attr := range regexp.MustCompile(`\b([A-Za-z_][A-Za-z0-9_]*)\s*=`).FindAllStringSubmatch(withoutStrings, -1) {
				switch attr[1] {
				case "module_name", "urls", "sha256", "strip_prefix", "type":
				default:
					return nil, fmt.Errorf("cannot manage rules_go archive attribute %q; keep custom patches/authentication wiring outside bootstrap", attr[1])
				}
			}
		}
		archive := &moduleArchive{sha256: literalAttribute(block.text, "sha256"), prefix: literalAttribute(block.text, "strip_prefix"), archiveType: literalAttribute(block.text, "type")}
		match := regexp.MustCompile(`(?s)\burls\s*=\s*\[([^\]]*)\]`).FindStringSubmatch(block.text)
		if len(match) == 2 {
			remaining := match[1]
			for _, literal := range regexp.MustCompile(`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'`).FindAllString(remaining, -1) {
				value, err := unquoteStarlarkLiteral(literal)
				if err != nil {
					return nil, err
				}
				archive.urls = append(archive.urls, value)
				remaining = strings.Replace(remaining, literal, "", 1)
			}
			if strings.Trim(strings.TrimSpace(remaining), ", \t\r\n") != "" {
				return nil, errors.New("archive urls must be a literal list; pass explicit --rto-archive-* flags for computed values")
			}
		}
		if err := archive.validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", module, err)
		}
		return archive, nil
	}
	return nil, nil
}

func literalAttribute(block, name string) string {
	pattern := regexp.MustCompile(`\b` + regexp.QuoteMeta(name) + `\s*=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*[,)]`)
	match := pattern.FindStringSubmatch(block)
	if len(match) != 2 {
		return ""
	}
	value, _ := unquoteStarlarkLiteral(match[1])
	return value
}

func unquoteStarlarkLiteral(value string) (string, error) {
	if strings.HasPrefix(value, "'") {
		value = `"` + strings.ReplaceAll(strings.ReplaceAll(value[1:len(value)-1], `\'`, `'`), `"`, `\"`) + `"`
	}
	return strconv.Unquote(value)
}
