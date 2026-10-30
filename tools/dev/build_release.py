#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Build a checksum-pinned release bundle from one committed Git revision.

This command is offline and never creates a tag or publishes a release. The same
bundle is used by release validation, the draft release, and consumer installs.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile


LANGUAGES = ("go", "python", "java", "nodejs", "dotnet", "ruby")
REPOSITORY = "DataDog/rules_test_optimization"


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def module_version(text: str) -> str:
    match = re.search(r"\bmodule\s*\([^)]*\bversion\s*=\s*\"(\d+\.\d+\.\d+)\"", text)
    if not match:
        raise ValueError("expected module(version = \"X.Y.Z\", ...)")
    return match[1]


def archive_metadata(archive: Path, prefix: str, version: str, commit: str) -> dict:
    """Check every module/fork prefix against the actual packaged source."""
    with tarfile.open(archive, "r:gz") as source:
        def read(path: str) -> str:
            handle = source.extractfile(f"{prefix}/{path}")
            if handle is None:
                raise ValueError(f"archive is missing {path}")
            return handle.read().decode("utf-8")

        modules = {"datadog-rules-test-optimization": prefix}
        for language in LANGUAGES:
            path = f"modules/{language}"
            text = read(f"{path}/MODULE.bazel")
            if module_version(text) != version:
                raise ValueError(f"{path}/MODULE.bazel version does not match {version}")
            dependency = re.search(
                r'bazel_dep\(\s*name\s*=\s*"datadog-rules-test-optimization"\s*,\s*version\s*=\s*"([^"]+)"', text
            )
            if not dependency or dependency[1] != version:
                raise ValueError(f"{path}/MODULE.bazel core dependency does not match {version}")
            modules[f"datadog-rules-test-optimization-{language}"] = f"{prefix}/{path}"

        registry = json.loads(read("third_party/rules_go_orchestrion/registry.json"))
        forks = {}
        for upstream, entry in registry["upstreams"].items():
            path = entry["variants"]["base"]["tree_path"]
            if PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts:
                raise ValueError(f"unsafe rules_go tree path: {path}")
            read(f"{path}/MODULE.bazel")
            forks[upstream] = {
                "version": entry["rules_go_version"],
                "strip_prefix": f"{prefix}/{path}",
            }
        if registry["default_upstream"] not in forks:
            raise ValueError("default rules_go upstream has no packaged base fork")

    with archive.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    return {
        "version": version,
        "tag": f"v{version}",
        "commit": commit,
        "archive": archive.name,
        "url": f"https://github.com/{REPOSITORY}/releases/download/v{version}/{archive.name}",
        "sha256": digest,
        "strip_prefix": prefix,
        "modules": modules,
        "rules_go": forks,
        "default_rules_go_upstream": registry["default_upstream"],
    }


def archive_call(metadata: dict, name: str, prefix: str, *, bzlmod: bool) -> str:
    function, attribute = ("archive_override", "module_name") if bzlmod else ("http_archive", "name")
    repository_mapping = ""
    if not bzlmod and name == "datadog-rules-test-optimization-go":
        repository_mapping = '    repo_mapping = {"@io_bazel_rules_go": "@io_bazel_rules_go"},\n'
    return (
        f"{function}(\n"
        f"    {attribute} = {json.dumps(name)},\n"
        f"    urls = [{json.dumps(metadata['url'])}],\n"
        f"    sha256 = {json.dumps(metadata['sha256'])},\n"
        f"    strip_prefix = {json.dumps(prefix)},\n"
        f"{repository_mapping}"
        ")\n"
    )


def installation_notes(metadata: dict) -> str:
    lines = [
        f"# Install v{metadata['version']}",
        "",
        f"Source commit: `{metadata['commit']}`.",
        "",
        "Use the same archive and checksum for core, companions, and the Go fork.",
        "These snippets install dependencies; follow the README for runtime/toolchain setup.",
        "For Bzlmod, add the core block and only the companions you use.",
        "For Go, also add one of the rules_go blocks below before running the bootstrap.",
        "WORKSPACE users should use the public language repository helpers after installing core.",
    ]
    for bzlmod in (True, False):
        lines.extend(["", "## Bzlmod" if bzlmod else "## WORKSPACE", ""])
        if not bzlmod:
            lines.extend(['```bzl', 'load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")', '```', ""])
        for name, prefix in metadata["modules"].items():
            lines.extend([f"### {name}", "", "```bzl"])
            if bzlmod:
                lines.append(f'bazel_dep(name = "{name}", version = "{metadata["version"]}")')
            lines.extend([archive_call(metadata, name, prefix, bzlmod=bzlmod).rstrip(), "```", ""])
        lines.extend(["### Go fork (choose one supported upstream)", ""])
        for upstream, fork in metadata["rules_go"].items():
            lines.extend([f"#### {upstream}", "", "```bzl"])
            if bzlmod:
                lines.append(f'bazel_dep(name = "rules_go", version = "{fork["version"]}")')
            lines.extend([archive_call(metadata, "rules_go" if bzlmod else "io_bazel_rules_go", fork["strip_prefix"], bzlmod=bzlmod).rstrip(), "```", ""])
    return "\n".join(lines) + "\n"


def changelog_section(text: str, version: str) -> str:
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError(f"CHANGELOG.md has no release notes for {version}")
    return match[1].strip()


def build(repo: Path, ref: str, output: Path, tag: str | None = None) -> dict:
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
    version = module_version(git(repo, "show", f"{commit}:MODULE.bazel"))
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"release tag mismatch: {tag} does not match v{version}")
    changelog = changelog_section(git(repo, "show", f"{commit}:CHANGELOG.md"), version)
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"output directory must be empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    prefix = f"rules_test_optimization-{version}"
    archive = output / f"{prefix}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="rto-release-source-") as temporary:
        tar = Path(temporary) / "source.tar"
        # Host checkout preferences must not turn executable scripts into CRLF.
        git(repo, "-c", "core.autocrlf=false", "-c", "core.eol=lf", "archive", "--format=tar", f"--prefix={prefix}/", f"--output={tar}", commit)
        with tar.open("rb") as source, archive.open("wb") as target:
            with gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)
    metadata = archive_metadata(archive, prefix, version, commit)
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n")
    installation = installation_notes(metadata)
    (output / "INSTALL.md").write_text(installation, encoding="utf-8", newline="\n")
    (output / "RELEASE_NOTES.md").write_text(
        f"# v{version}\n\n{changelog}\n\n{installation}", encoding="utf-8", newline="\n"
    )
    checksums = []
    for path in sorted(output.iterdir()):
        with path.open("rb") as handle:
            checksums.append(f"{hashlib.file_digest(handle, 'sha256').hexdigest()}  {path.name}\n")
    (output / "SHA256SUMS").write_text("".join(checksums), encoding="utf-8", newline="\n")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--tag", help="Expected release tag; a mismatch aborts before packaging")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        metadata = build(args.repo, args.ref, args.output, args.tag)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release bundle: {error}\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
