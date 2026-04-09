#!/usr/bin/env python3
"""Benchmark the Go Orchestrion path against a minimal consumer fixture."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any


SCENARIOS = (
    {
        "name": "fresh_non_hermetic",
        "bazel_args": [],
        "cached": False,
    },
    {
        "name": "cached_non_hermetic",
        "bazel_args": [],
        "cached": True,
    },
    {
        "name": "fresh_hermetic",
        "bazel_args": ["--config=hermetic"],
        "cached": False,
    },
)

REQUIRED_RELATIVE_PATHS = (
    ".bazelrc",
    "bazelw",
    "src/go-project/BUILD.bazel",
    "src/go-project/main.go",
    "src/go-project/main_test.go",
    "src/go-project/go.mod",
    "src/go-project/go.sum",
    "src/go-project/orchestrion.tool.go",
    "src/go-project/orchestrion.yml",
    "tools/build/BUILD.bazel",
    "tools/build/dd_go_test.bzl",
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rules-root",
        default=str(repo_root()),
        help="Path to the rules_test_optimization repo to benchmark.",
    )
    parser.add_argument(
        "--consumer-repo",
        default=str(repo_root().parent / "rules_test_optimization_tests"),
        help="Path to the sibling consumer repo.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=5,
        help="Number of runs per scenario.",
    )
    parser.add_argument(
        "--target",
        default="//src/go-project:hello_test",
        help="Bazel target to benchmark.",
    )
    parser.add_argument(
        "--out-dir",
        default="",
        help="Directory where logs, profiles, and summaries should be written.",
    )
    return parser.parse_args()


def parse_consumer_module_config(module_text: str) -> dict[str, str]:
    patterns = {
        "orchestrion_version": r'orchestrion\.from_source\(\s*.*?version\s*=\s*"([^"]+)"',
        "dd_trace_go_version": r'orchestrion\.from_source\(\s*.*?dd_trace_go_version\s*=\s*"([^"]+)"',
        "service": r'go_topt\.test_optimization_go\(\s*.*?service\s*=\s*"([^"]+)"',
        "runtime_version": r'go_topt\.test_optimization_go\(\s*.*?runtime_version\s*=\s*"([^"]+)"',
    }
    result: dict[str, str] = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, module_text, re.DOTALL)
        if match is None:
            raise ValueError(f"unable to locate {key} in consumer MODULE.bazel")
        result[key] = match.group(1)
    return result


def reduced_module_bazel(config: dict[str, str], root: Path) -> str:
    return f"""module(name = "dd-go-benchmark-fixture")

bazel_dep(name = "rules_go", version = "0.60.0")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = {json.dumps(str(root))},
)

local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = {json.dumps(str(root / "modules" / "go"))},
)

local_path_override(
    module_name = "rules_go",
    path = {json.dumps(str(root / "third_party" / "rules_go_orchestrion"))},
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = {json.dumps(config["orchestrion_version"])},
    dd_trace_go_version = {json.dumps(config["dd_trace_go_version"])},
)
use_repo(orchestrion, "rules_go_orchestrion_tool")

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data_go",
    service = {json.dumps(config["service"])},
    runtime_version = {json.dumps(config["runtime_version"])},
)

use_repo(go_topt, "test_optimization_data_go")
"""


def copy_fixture(source_repo: Path, fixture_dir: Path, root: Path) -> None:
    module_text = (source_repo / "MODULE.bazel").read_text(encoding="utf-8")
    config = parse_consumer_module_config(module_text)
    for relative in REQUIRED_RELATIVE_PATHS:
        src = source_repo / relative
        dst = fixture_dir / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    src_testdata = source_repo / "src" / "go-project" / "testdata"
    dst_testdata = fixture_dir / "src" / "go-project" / "testdata"
    shutil.copytree(src_testdata, dst_testdata, dirs_exist_ok=True)
    (fixture_dir / "MODULE.bazel").write_text(
        reduced_module_bazel(config, root),
        encoding="utf-8",
    )
    bazelw = fixture_dir / "bazelw"
    bazelw.chmod(0o755)


def run_command(
    fixture_dir: Path,
    output_user_root: Path,
    profile_path: Path,
    bazel_args: list[str],
    target: str,
    env: dict[str, str],
) -> dict[str, Any]:
    command = [
        "/usr/bin/time",
        "-p",
        "./bazelw",
        f"--output_user_root={output_user_root}",
        "test",
        target,
        "--test_output=errors",
        "--test_summary=terse",
        f"--profile={profile_path}",
        *bazel_args,
    ]
    started = time.time()
    proc = subprocess.run(
        command,
        cwd=fixture_dir,
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    finished = time.time()
    real_seconds = None
    user_seconds = None
    sys_seconds = None
    for line in proc.stderr.splitlines():
        if line.startswith("real "):
            real_seconds = float(line.split()[1])
        elif line.startswith("user "):
            user_seconds = float(line.split()[1])
        elif line.startswith("sys "):
            sys_seconds = float(line.split()[1])
    return {
        "command": command,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "real_seconds": real_seconds,
        "user_seconds": user_seconds,
        "sys_seconds": sys_seconds,
        "wall_seconds": finished - started,
    }


def trimmed_metrics(samples: list[float]) -> dict[str, float]:
    ordered = sorted(samples)
    trimmed = ordered[1:-1] if len(ordered) >= 3 else ordered
    median = statistics.median(trimmed)
    spread = max(trimmed) - min(trimmed) if len(trimmed) > 1 else 0.0
    return {
        "median_seconds": median,
        "spread_seconds": spread,
        "noise_band_seconds": max(median * 0.05, spread),
    }


def benchmark_scenario(
    scenario: dict[str, Any],
    fixture_dir: Path,
    scenario_dir: Path,
    target: str,
    env: dict[str, str],
    runs: int,
) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    print(f"[benchmark] scenario={scenario['name']} runs={runs} cached={scenario['cached']}", flush=True)
    if scenario["cached"]:
        shared_output_root = scenario_dir / "output_user_root"
        prime_profile = scenario_dir / "prime.profile.gz"
        print(f"[benchmark] priming cached scenario={scenario['name']}", flush=True)
        prime = run_command(fixture_dir, shared_output_root, prime_profile, scenario["bazel_args"], target, env)
        if prime["returncode"] != 0:
            raise RuntimeError(f"failed to prime cached scenario {scenario['name']}: {prime['stderr']}")
    for run_index in range(1, runs + 1):
        print(f"[benchmark] scenario={scenario['name']} run={run_index}/{runs}", flush=True)
        if scenario["cached"]:
            output_root = scenario_dir / "output_user_root"
        else:
            output_root = scenario_dir / f"output_user_root_{run_index}"
        profile_path = scenario_dir / f"run_{run_index}.profile.gz"
        result = run_command(fixture_dir, output_root, profile_path, scenario["bazel_args"], target, env)
        if result["returncode"] != 0:
            raise RuntimeError(
                f"scenario {scenario['name']} run {run_index} failed with exit code {result['returncode']}\n{result['stderr']}"
            )
        sample_log = scenario_dir / f"run_{run_index}.stdout.log"
        sample_log.write_text(result["stdout"], encoding="utf-8")
        sample_err = scenario_dir / f"run_{run_index}.stderr.log"
        sample_err.write_text(result["stderr"], encoding="utf-8")
        samples.append(
            {
                "run": run_index,
                "real_seconds": result["real_seconds"],
                "user_seconds": result["user_seconds"],
                "sys_seconds": result["sys_seconds"],
                "wall_seconds": result["wall_seconds"],
                "profile": str(profile_path),
                "stdout_log": str(sample_log),
                "stderr_log": str(sample_err),
            }
        )
    metrics = trimmed_metrics([sample["real_seconds"] for sample in samples if sample["real_seconds"] is not None])
    return {
        "name": scenario["name"],
        "bazel_args": scenario["bazel_args"],
        "cached": scenario["cached"],
        "samples": samples,
        **metrics,
    }


def sanitized_environment() -> dict[str, str]:
    env = dict(os.environ)
    for key in (
        "ORCHESTRION_DEBUG_TRACE",
        "DD_TRACE_DEBUG",
        "DD_CIVISIBILITY_ENABLED",
        "FETCH_SALT",
    ):
        env.pop(key, None)
    return env


def git_value(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.stdout.strip()


def benchmark_environment(consumer_repo: Path) -> dict[str, str]:
    env = sanitized_environment()
    branch = git_value(consumer_repo, "symbolic-ref", "--short", "-q", "HEAD")
    if not branch or branch == "HEAD":
        branch = "benchmark-detached-head"
    commit = git_value(consumer_repo, "rev-parse", "HEAD")
    message = git_value(consumer_repo, "log", "-1", "--pretty=%s")
    repository_url = git_value(consumer_repo, "config", "--get", "remote.origin.url")
    dirty = "clean"
    diff = subprocess.run(
        ["git", "-C", str(consumer_repo), "diff-index", "--quiet", "HEAD", "--"],
        check=False,
    )
    if diff.returncode != 0:
        dirty = "dirty"
    env.update(
        {
            "DD_GIT_REPOSITORY_URL": repository_url,
            "DD_GIT_BRANCH": branch,
            "DD_GIT_COMMIT_SHA": commit,
            "DD_GIT_HEAD_COMMIT": commit,
            "DD_GIT_COMMIT_MESSAGE": message,
            "DD_GIT_HEAD_MESSAGE": message,
            "GIT_DIRTY": dirty,
        }
    )
    return env


def write_markdown(summary_path: Path, payload: dict[str, Any]) -> None:
    lines = [
        "# Go Orchestrion Benchmark",
        "",
        f"- Rules repo: `{payload['rules_root']}`",
        f"- Fixture: `{payload['fixture_dir']}`",
        f"- Consumer repo: `{payload['consumer_repo']}`",
        f"- Target: `{payload['target']}`",
        f"- Root commit: `{payload['root_commit']}`",
        f"- Consumer commit: `{payload['consumer_commit']}`",
        "",
        "## Scenarios",
        "",
    ]
    for scenario in payload["scenarios"]:
        lines.extend(
            [
                f"### {scenario['name']}",
                "",
                f"- Median: `{scenario['median_seconds']:.3f}s`",
                f"- Spread: `{scenario['spread_seconds']:.3f}s`",
                f"- Noise band: `{scenario['noise_band_seconds']:.3f}s`",
                "",
            ]
        )
    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def git_commit(path: Path) -> str:
    proc = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=path,
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout.strip()


def main() -> int:
    args = parse_args()
    root = Path(args.rules_root).resolve()
    if not root.exists():
        raise FileNotFoundError(f"rules repo not found: {root}")
    consumer_repo = Path(args.consumer_repo).resolve()
    if not consumer_repo.exists():
        raise FileNotFoundError(f"consumer repo not found: {consumer_repo}")

    output_root = Path(args.out_dir).resolve() if args.out_dir else Path(
        tempfile.mkdtemp(prefix="go-orchestrion-benchmark.")
    )
    fixture_dir = output_root / "fixture"
    fixture_dir.mkdir(parents=True, exist_ok=True)
    print(f"[benchmark] output_dir={output_root}", flush=True)
    print(f"[benchmark] fixture_dir={fixture_dir}", flush=True)
    copy_fixture(consumer_repo, fixture_dir, root)

    env = benchmark_environment(consumer_repo)
    scenarios = []
    for scenario in SCENARIOS:
        scenario_dir = output_root / scenario["name"]
        scenario_dir.mkdir(parents=True, exist_ok=True)
        scenarios.append(
            benchmark_scenario(
                scenario,
                fixture_dir,
                scenario_dir,
                args.target,
                env,
                args.runs,
            )
        )

    payload = {
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "fixture_dir": str(fixture_dir),
        "consumer_repo": str(consumer_repo),
        "target": args.target,
        "rules_root": str(root),
        "root_commit": git_commit(root),
        "consumer_commit": git_commit(consumer_repo),
        "local_overrides": {
            "datadog-rules-test-optimization": str(root),
            "datadog-rules-test-optimization-go": str(root / "modules" / "go"),
            "rules_go": str(root / "third_party" / "rules_go_orchestrion"),
        },
        "scenarios": scenarios,
    }
    json_path = output_root / "summary.json"
    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    markdown_path = output_root / "summary.md"
    write_markdown(markdown_path, payload)
    print(json.dumps({"out_dir": str(output_root), "summary_json": str(json_path), "summary_md": str(markdown_path)}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
