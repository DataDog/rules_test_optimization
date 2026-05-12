#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Generate Python Test Optimization onboarding snippets.

The tool is intentionally side-effect-free by default. It prints copy/paste
snippets for WORKSPACE, Bzlmod, `.bazelrc`, target wiring, Python test targets,
and validation commands. Write modes only touch managed blocks with explicit
markers so consumers can re-run the tool safely.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from textwrap import dedent


BEGIN_MARKER = "# BEGIN Datadog Python Test Optimization"
END_MARKER = "# END Datadog Python Test Optimization"
DEFAULT_REMOTE = "https://github.com/DataDog/rules_test_optimization.git"
SSH_REMOTE = "ssh://git@github.com/DataDog/rules_test_optimization.git"
DEFAULT_RULES_VERSION = "1.0.0"
SYNC_REPO_ENV_KEYS = [
    "DD_API_KEY",
    "DD_SITE",
    "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
    "DD_SERVICE",
    "DD_ENV",
    "DD_GIT_REPOSITORY_URL",
    "DD_GIT_BRANCH",
    "DD_GIT_TAG",
    "DD_GIT_COMMIT_SHA",
    "DD_GIT_HEAD_COMMIT",
    "DD_GIT_COMMIT_MESSAGE",
    "DD_GIT_HEAD_MESSAGE",
    "DD_GIT_COMMIT_AUTHOR_NAME",
    "DD_GIT_COMMIT_AUTHOR_EMAIL",
    "DD_GIT_COMMIT_AUTHOR_DATE",
    "DD_GIT_COMMIT_COMMITTER_NAME",
    "DD_GIT_COMMIT_COMMITTER_EMAIL",
    "DD_GIT_COMMIT_COMMITTER_DATE",
    "DD_GIT_HEAD_AUTHOR_NAME",
    "DD_GIT_HEAD_AUTHOR_EMAIL",
    "DD_GIT_HEAD_AUTHOR_DATE",
    "DD_GIT_HEAD_COMMITTER_NAME",
    "DD_GIT_HEAD_COMMITTER_EMAIL",
    "DD_GIT_HEAD_COMMITTER_DATE",
    "DD_GIT_PR_BASE_BRANCH",
    "DD_GIT_PR_BASE_BRANCH_SHA",
    "DD_GIT_PR_BASE_BRANCH_HEAD_SHA",
    "DD_PR_NUMBER",
]


class BootstrapError(Exception):
    """User-facing bootstrap configuration error."""


def _quote(value: str) -> str:
    """Return a Starlark double-quoted string literal for generated snippets."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _target_list(values: list[str], indent: str = "        ") -> str:
    """Render a deterministic Starlark list of labels."""
    if not values:
        return "[]"
    rendered = ["["]
    for value in values:
        rendered.append(f"{indent}{_quote(value)},")
    rendered.append("    ]")
    return "\n".join(rendered)


def _section(title: str, body: str) -> str:
    """Format one named output section."""
    return f"## {title}\n\n{body.strip()}\n"


def _managed_block(body: str) -> str:
    """Wrap generated content in managed markers for idempotent writes."""
    return f"{BEGIN_MARKER}\n{body.rstrip()}\n{END_MARKER}\n"


def _replace_managed_block(existing: str, block: str) -> str:
    """Insert or replace the managed block while preserving user content."""
    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER) + r"\n?",
        re.DOTALL,
    )
    if pattern.search(existing):
        return pattern.sub(block, existing)
    if existing and not existing.endswith("\n"):
        existing += "\n"
    return existing + ("\n" if existing.strip() else "") + block


def _unmanaged_text(existing: str) -> str:
    """Return file content with the managed block removed."""
    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER) + r"\n?",
        re.DOTALL,
    )
    return pattern.sub("", existing)


def _ensure_archive_inputs(args: argparse.Namespace, owner: str) -> None:
    """Validate required archive fields for archive-based fetch snippets."""
    missing = [
        name
        for name in ["rto_archive_url", "rto_archive_sha256", "rto_archive_prefix"]
        if not getattr(args, name)
    ]
    if missing:
        raise BootstrapError(
            f"{owner} requires archive inputs: " + ", ".join("--" + name.replace("_", "-") for name in missing)
        )


def _effective_fetch(args: argparse.Namespace) -> tuple[str, str]:
    """Return the effective Datadog fetch mode and remote URL."""
    if args.private_repo_fetch == "ssh-git":
        return "git", SSH_REMOTE
    if args.private_repo_fetch == "authenticated-archive":
        _ensure_archive_inputs(args, "--private-repo-fetch=authenticated-archive")
        return "archive", args.rto_remote
    if args.datadog_fetch == "archive":
        _ensure_archive_inputs(args, "--datadog-fetch=archive")
    return args.datadog_fetch, args.rto_remote


def _validate_args(args: argparse.Namespace) -> None:
    """Validate CLI inputs before rendering snippets."""
    if args.mode not in {"workspace", "bzlmod"}:
        raise BootstrapError("--mode must be one of: workspace, bzlmod")
    if not args.service:
        raise BootstrapError("--service is required")
    if not args.runtime_version:
        raise BootstrapError("--runtime-version is required")
    if not args.runtime_module_path:
        raise BootstrapError("--runtime-module-path is required")
    if not args.sync_repo_name:
        raise BootstrapError("--sync-repo-name must not be empty")
    if args.datadog_fetch not in {"git", "archive"}:
        raise BootstrapError("--datadog-fetch must be one of: git, archive")
    if args.private_repo_fetch not in {"none", "ssh-git", "authenticated-archive"}:
        raise BootstrapError("--private-repo-fetch must be one of: none, ssh-git, authenticated-archive")
    effective_fetch, _ = _effective_fetch(args)
    if effective_fetch == "git" and not args.rto_commit:
        raise BootstrapError("--rto-commit is required for git fetch mode")
    if args.runner_mode not in {"managed_pytest", "consumer_runner"}:
        raise BootstrapError("--runner-mode must be one of: managed_pytest, consumer_runner")


def render_bazelrc_snippet(args: argparse.Namespace) -> str:
    """Render safe repository-phase and test-output Bazel configuration."""
    lines = [
        "# Datadog metadata is resolved during repository/module analysis.",
        "# These values are repo_env, not test_env, so tests do not receive secrets.",
    ]
    lines.extend(f"common:{args.bazelrc_config} --repo_env={key}" for key in SYNC_REPO_ENV_KEYS)
    lines.append(f"test:{args.bazelrc_config} --remote_download_outputs=all")
    return "\n".join(lines) + "\n"


def render_workspace_snippet(args: argparse.Namespace) -> str:
    """Render WORKSPACE dependency and sync wiring."""
    effective_fetch, remote = _effective_fetch(args)
    repo_block: str
    companion_kwargs = [
        f"    rto_commit = {_quote(args.rto_commit)},",
        f"    rto_remote = {_quote(remote)},",
        f"    datadog_fetch = {_quote(effective_fetch)},",
        f"    rules_python_repo_name = {_quote(args.rules_python_repo_name)},",
    ]
    if effective_fetch == "archive":
        repo_block = dedent(
            f"""
            load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

            http_archive(
                name = "datadog-rules-test-optimization",
                urls = [{_quote(args.rto_archive_url)}],
                sha256 = {_quote(args.rto_archive_sha256)},
                strip_prefix = {_quote(args.rto_archive_prefix)},
                type = {_quote(args.rto_archive_type)},
            )
            """
        ).strip()
        companion_kwargs.extend(
            [
                f"    rto_archive_url = {_quote(args.rto_archive_url)},",
                f"    rto_archive_sha256 = {_quote(args.rto_archive_sha256)},",
                f"    rto_archive_prefix = {_quote(args.rto_archive_prefix)},",
                f"    rto_archive_type = {_quote(args.rto_archive_type)},",
            ]
        )
    else:
        repo_block = dedent(
            f"""
            load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

            git_repository(
                name = "datadog-rules-test-optimization",
                remote = {_quote(remote)},
                commit = {_quote(args.rto_commit)},
            )
            """
        ).strip()

    private_note = ""
    if args.private_repo_fetch == "authenticated-archive":
        private_note = (
            "# Internal/private archives need Bazel-compatible authentication "
            "(.netrc or an equivalent token flow). Unauthenticated codeload URLs "
            "can return 404 even when the commit exists."
        )

    parts = [
        repo_block,
    ]
    if private_note:
        parts.extend(["", private_note])
    parts.extend(
        [
            "",
            "# Declare rules_python, its toolchains, pip_parse, pytest, and ddtrace",
            "# using your repository's normal Python dependency policy before tests run.",
            'load("@datadog-rules-test-optimization//tools/python:workspace_repositories.bzl", "datadog_python_test_optimization_workspace_repositories")',
            "",
            "datadog_python_test_optimization_workspace_repositories(",
            *companion_kwargs,
            ")",
            "",
            'load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")',
            "",
            "test_optimization_sync(",
            f"    name = {_quote(args.sync_repo_name)},",
            f"    service = {_quote(args.service)},",
            '    runtime_name = "python",',
            f"    runtime_version = {_quote(args.runtime_version)},",
            f"    runtime_module_path = {_quote(args.runtime_module_path)},",
            ")",
        ]
    )
    return "\n".join(parts) + "\n"


def render_bzlmod_snippet(args: argparse.Namespace) -> str:
    """Render Bzlmod dependency and sync wiring."""
    effective_fetch, remote = _effective_fetch(args)
    override = ""
    if effective_fetch == "git":
        override = dedent(
            f"""
            git_override(
                module_name = "datadog-rules-test-optimization",
                remote = {_quote(remote)},
                commit = {_quote(args.rto_commit)},
            )
            git_override(
                module_name = "datadog-rules-test-optimization-python",
                remote = {_quote(remote)},
                commit = {_quote(args.rto_commit)},
                strip_prefix = "modules/python",
            )
            """
        ).strip()
    else:
        override = dedent(
            f"""
            archive_override(
                module_name = "datadog-rules-test-optimization",
                urls = [{_quote(args.rto_archive_url)}],
                sha256 = {_quote(args.rto_archive_sha256)},
                strip_prefix = {_quote(args.rto_archive_prefix)},
            )
            archive_override(
                module_name = "datadog-rules-test-optimization-python",
                urls = [{_quote(args.rto_archive_url)}],
                sha256 = {_quote(args.rto_archive_sha256)},
                strip_prefix = {_quote(args.rto_archive_prefix + "/modules/python")},
            )
            """
        ).strip()

    return "\n".join(
        [
            f"bazel_dep(name = \"datadog-rules-test-optimization\", version = {_quote(DEFAULT_RULES_VERSION)})",
            f"bazel_dep(name = \"datadog-rules-test-optimization-python\", version = {_quote(DEFAULT_RULES_VERSION)})",
            "",
            override,
            "",
            "test_optimization_sync = use_extension(",
            '    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",',
            '    "test_optimization_sync_extension",',
            ")",
            "test_optimization_sync.test_optimization_sync(",
            f"    name = {_quote(args.sync_repo_name)},",
            f"    service = {_quote(args.service)},",
            '    runtime_name = "python",',
            f"    runtime_version = {_quote(args.runtime_version)},",
            f"    runtime_module_path = {_quote(args.runtime_module_path)},",
            ")",
            f"use_repo(test_optimization_sync, {_quote(args.sync_repo_name)})",
        ]
    ) + "\n"


def render_targets_snippet(args: argparse.Namespace) -> str:
    """Render doctor/uploader target wiring for a lightweight package."""
    expected_targets = _target_list(args.expected_target)
    lines = [
        'load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")',
        "",
        "dd_test_optimization_targets(",
        '    name = "test_optimization",',
        f"    sync_repo_name = {_quote(args.sync_repo_name)},",
        f"    doctor_name = {_quote(args.doctor_name)},",
        f"    uploader_name = {_quote(args.uploader_name)},",
    ]
    if not args.expected_target:
        lines.extend(
            [
                "    # Add only instrumented test targets that emit payloads. Do not list",
                "    # build-only, wrapper-only, or analysis-only targets here.",
            ]
        )
    lines.append(f"    expected_targets = {expected_targets},")
    lines.append(")")
    return "\n".join(lines) + "\n"


def render_test_snippet(args: argparse.Namespace) -> str:
    """Render a Python test target example for the requested runner mode."""
    target_name = args.test_target_name or "example_test"
    if args.runner_mode == "consumer_runner":
        load_line = "# load(\"//path/to:python_rules.bzl\", \"your_py_test_rule\")"
        rule_ref = "your_py_test_rule"
        if args.py_test_rule_load_label and args.py_test_rule_symbol:
            load_line = f"load({_quote(args.py_test_rule_load_label)}, {_quote(args.py_test_rule_symbol)})"
            rule_ref = args.py_test_rule_symbol
        return dedent(
            f"""
            load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
            load("@{args.sync_repo_name}//:export.bzl", "topt_data")
            {load_line}

            dd_topt_py_test(
                name = {_quote(target_name)},
                topt_data = topt_data,
                runner_mode = "consumer_runner",
                py_test_rule = {rule_ref},
                module_identifier = {_quote(args.module_identifier or args.runtime_module_path)},
                srcs = ["test_example.py"],
                deps = [
                    requirement("ddtrace"),
                    requirement("pytest"),
                ],
                # The consumer wrapper must preserve env and execute pytest with
                # the ddtrace plugin enabled.
            )
            """
        ).strip() + "\n"

    return dedent(
        f"""
        load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
        load("@{args.sync_repo_name}//:export.bzl", "topt_data")

        dd_topt_py_test(
            name = {_quote(target_name)},
            topt_data = topt_data,
            runner_mode = "managed_pytest",
            srcs = ["test_example.py"],
            deps = [
                requirement("ddtrace"),
                requirement("pytest"),
            ],
        )
        """
    ).strip() + "\n"


def _test_targets_for_commands(args: argparse.Namespace) -> tuple[list[str], str]:
    """Return command test labels and an explanatory comment when placeholders are needed."""
    targets = args.test_target or args.expected_target
    if targets:
        return targets, ""
    return ["//path/to:instrumented_python_test"], "# Replace the placeholder target with instrumented Python test targets.\n"


def render_command_snippet(args: argparse.Namespace) -> str:
    """Render the normal test, doctor, dry-run, and upload command flow."""
    targets, comment = _test_targets_for_commands(args)
    target_args = " ".join(targets)
    label_prefix = f"//{args.test_optimization_package}" if args.test_optimization_package else "//"
    return dedent(
        f"""
        {comment}test_status=0
        doctor_status=0
        dry_run_status=0
        upload_status=0

        {args.bazel_command} sync --config={args.bazelrc_config} --only={args.sync_repo_name}
        {args.bazel_command} test --config={args.bazelrc_config} {target_args} || test_status=$?

        {args.bazel_command} run --config={args.bazelrc_config} {label_prefix}:{args.doctor_name} || doctor_status=$?
        if [ "$doctor_status" -ne 0 ]; then
          if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
          exit "$doctor_status"
        fi

        {args.bazel_command} run --config={args.bazelrc_config} {label_prefix}:{args.uploader_name} -- --dry-run --validate-enrichment || dry_run_status=$?
        if [ "$dry_run_status" -ne 0 ]; then
          if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
          exit "$dry_run_status"
        fi

        DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" {args.bazel_command} run --config={args.bazelrc_config} {label_prefix}:{args.uploader_name} || upload_status=$?
        if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
        exit "$upload_status"
        """
    ).strip() + "\n"


def render_refresh_snippet(args: argparse.Namespace) -> str:
    """Render the explicit force-refresh command separated from normal flow."""
    return dedent(
        f"""
        # Force refresh only. Do not add FETCH_SALT to normal test, doctor, or uploader commands.
        {args.bazel_command} sync --config={args.bazelrc_config} --only={args.sync_repo_name} --repo_env=FETCH_SALT="$(date +%s)"
        """
    ).strip() + "\n"


def _selected_sections(args: argparse.Namespace) -> list[tuple[str, str]]:
    """Return output sections selected by print flags and the requested mode."""
    print_flags = [
        args.print_workspace_snippet,
        args.print_bzlmod_snippet,
        args.print_bazelrc_snippet,
        args.print_targets_snippet,
        args.print_test_snippet,
        args.print_command_snippet,
        args.print_refresh_snippet,
    ]
    default_output = not any(print_flags) and not args.write_bazelrc and not args.write_targets
    sections: list[tuple[str, str]] = []

    if args.print_workspace_snippet or (default_output and args.mode == "workspace"):
        sections.append(("WORKSPACE", render_workspace_snippet(args)))
    if args.print_bzlmod_snippet or (default_output and args.mode == "bzlmod"):
        sections.append(("Bzlmod", render_bzlmod_snippet(args)))
    if args.print_bazelrc_snippet or default_output:
        sections.append((".bazelrc", render_bazelrc_snippet(args)))
    if args.print_targets_snippet or default_output:
        sections.append(("Doctor and uploader targets", render_targets_snippet(args)))
    if args.print_test_snippet or default_output:
        sections.append(("Python test target", render_test_snippet(args)))
    if args.print_command_snippet or default_output:
        sections.append(("Commands", render_command_snippet(args)))
    if args.print_refresh_snippet:
        sections.append(("Force refresh only", render_refresh_snippet(args)))
    return sections


def _target_name_collision(existing: str, target_names: list[str]) -> str | None:
    """Return the first generated target name that appears unmanaged."""
    unmanaged = _unmanaged_text(existing)
    for target_name in target_names:
        if re.search(r'name\s*=\s*["\']' + re.escape(target_name) + r'["\']', unmanaged):
            return target_name
    return None


def _write_managed(path: Path, body: str, target_names: list[str] | None = None) -> None:
    """Write or replace a managed block, preserving unmanaged user content."""
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    if target_names:
        collision = _target_name_collision(existing, target_names)
        if collision:
            raise BootstrapError(
                f"{path} already contains unmanaged target name {collision!r}. "
                "Rename the generated target, move the unmanaged target, or delete it explicitly before using --write-targets."
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_replace_managed_block(existing, _managed_block(body)), encoding="utf-8")


def write_outputs(args: argparse.Namespace) -> None:
    """Apply explicit write operations requested by the user."""
    if args.write_bazelrc:
        _write_managed(Path(args.bazelrc_path), render_bazelrc_snippet(args))
    if args.write_targets:
        _write_managed(
            Path(args.targets_build_path),
            render_targets_snippet(args),
            target_names=[args.doctor_name, args.uploader_name],
        )


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["workspace", "bzlmod"], required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--runtime-version", required=True)
    parser.add_argument("--runtime-module-path", required=True)
    parser.add_argument("--sync-repo-name", default="test_optimization_data")
    parser.add_argument("--rto-commit", default="")
    parser.add_argument("--rto-remote", default=DEFAULT_REMOTE)
    parser.add_argument("--datadog-fetch", choices=["git", "archive"], default="git")
    parser.add_argument("--rto-archive-url", default="")
    parser.add_argument("--rto-archive-sha256", default="")
    parser.add_argument("--rto-archive-prefix", default="")
    parser.add_argument("--rto-archive-type", default="tar.gz")
    parser.add_argument("--rules-python-repo-name", default="rules_python")
    parser.add_argument("--private-repo-fetch", choices=["none", "ssh-git", "authenticated-archive"], default="none")
    parser.add_argument("--test-optimization-package", default="tools/test_optimization")
    parser.add_argument("--doctor-name", default="dd_test_optimization_doctor")
    parser.add_argument("--uploader-name", default="dd_upload_payloads")
    parser.add_argument("--bazelrc-config", default="test-optimization")
    parser.add_argument("--expected-target", action="append", default=[])
    parser.add_argument("--test-target", action="append", default=[])
    parser.add_argument("--runner-mode", choices=["managed_pytest", "consumer_runner"], default="managed_pytest")
    parser.add_argument("--py-test-rule-load-label", default="")
    parser.add_argument("--py-test-rule-symbol", default="")
    parser.add_argument("--test-target-name", default="example_test")
    parser.add_argument("--module-identifier", default="")
    parser.add_argument("--bazel-command", default="bazel")
    parser.add_argument("--print-workspace-snippet", action="store_true")
    parser.add_argument("--print-bzlmod-snippet", action="store_true")
    parser.add_argument("--print-bazelrc-snippet", action="store_true")
    parser.add_argument("--print-targets-snippet", action="store_true")
    parser.add_argument("--print-test-snippet", action="store_true")
    parser.add_argument("--print-command-snippet", action="store_true")
    parser.add_argument("--print-refresh-snippet", action="store_true")
    parser.add_argument("--write-bazelrc", action="store_true")
    parser.add_argument("--bazelrc-path", default=".bazelrc")
    parser.add_argument("--write-targets", action="store_true")
    parser.add_argument("--targets-build-path", default="tools/test_optimization/BUILD.bazel")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run the snippet generator CLI."""
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        _validate_args(args)
        write_outputs(args)
        sections = _selected_sections(args)
        if sections:
            print("\n".join(_section(title, body) for title, body in sections))
    except BootstrapError as exc:
        print(f"dd_topt_py_bootstrap: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
