// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/DataDog/rules_test_optimization/modules/go/tools/onboardingpins"
)

// cliConfig contains the command-line flags accepted by print_go_onboarding_pins.
type cliConfig struct {
	commit              string
	variant             string
	upstream            string
	remote              string
	workspace           string
	archiveType         string
	ddTraceGoVersion    string
	orchestrionVersion  string
	verifyMainReachable bool
	printSummary        bool
	fetchArchive        onboardingpins.ArchiveFetcher
}

func main() {
	cfg := parseFlags()
	if err := runWithOutput(context.Background(), cfg, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// parseFlags converts process arguments into a validated configuration later
// consumed by run.
func parseFlags() cliConfig {
	cfg := cliConfig{}
	workspaceDefault := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
	if workspaceDefault == "" {
		if cwd, err := os.Getwd(); err == nil {
			workspaceDefault = cwd
		} else {
			workspaceDefault = "."
		}
	}
	flag.StringVar(&cfg.commit, "commit", "", "Published rules_test_optimization commit to print")
	flag.StringVar(&cfg.variant, "variant", "base", "rules_go Orchestrion variant: base")
	flag.StringVar(&cfg.upstream, "rules-go-upstream", "default", "Datadog-managed rules_go upstream support id, for example v0_60_0")
	flag.StringVar(&cfg.remote, "remote", onboardingpins.DefaultRemote, "rules_test_optimization Git remote")
	flag.StringVar(&cfg.workspace, "workspace", workspaceDefault, "rules_test_optimization checkout used for verification")
	flag.StringVar(&cfg.archiveType, "archive-type", onboardingpins.DefaultArchiveType, "Archive type used by http_archive")
	flag.StringVar(&cfg.ddTraceGoVersion, "dd-trace-go-version", onboardingpins.DefaultDDTraceGoVersion, "dd-trace-go version to include in the tuple")
	flag.StringVar(&cfg.orchestrionVersion, "orchestrion-version", onboardingpins.DefaultOrchestrionVersion, "Orchestrion version to include in the tuple")
	flag.BoolVar(&cfg.verifyMainReachable, "verify-main-reachable", false, "Require --commit to be reachable from origin/main")
	flag.BoolVar(&cfg.printSummary, "print-summary", false, "Print the Markdown onboarding summary after the shell tuple")
	flag.Parse()
	return cfg
}

// run computes the published pins and writes them to stdout.
func run(cfg cliConfig) error {
	return runWithOutput(context.Background(), cfg, os.Stdout)
}

func runWithOutput(ctx context.Context, cfg cliConfig, stdout io.Writer) error {
	pins, err := resolvePinsForCLI(ctx, cfg)
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, onboardingpins.FormatShell(pins))
	if cfg.printSummary {
		fmt.Fprint(stdout, "\n")
		fmt.Fprint(stdout, onboardingpins.FormatMarkdownSummary(pins))
	}
	return nil
}

func resolvePinsForCLI(ctx context.Context, cfg cliConfig) (onboardingpins.Pins, error) {
	pins, err := onboardingpins.Resolve(ctx, onboardingpins.Options{
		WorkspaceDir:        cfg.workspace,
		Commit:              cfg.commit,
		Remote:              cfg.remote,
		RulesGoUpstream:     cfg.upstream,
		Variant:             cfg.variant,
		ArchiveType:         cfg.archiveType,
		DDTraceGoVersion:    cfg.ddTraceGoVersion,
		OrchestrionVersion:  cfg.orchestrionVersion,
		VerifyMainReachable: cfg.verifyMainReachable,
		ValidateVariantDir:  true,
		FetchArchive:        cfg.fetchArchive,
	})
	if err != nil {
		return onboardingpins.Pins{}, err
	}
	return pins, nil
}
