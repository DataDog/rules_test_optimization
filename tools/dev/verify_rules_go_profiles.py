#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify generated rules_go consumer patch profiles."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shutil
import subprocess
import sys
import tempfile

try:
    from tools.dev.generate_rules_go_consumer_patch import (
        DEFAULT_PROFILE_ROOT,
        REPO_ROOT,
        copy_filtered_tree,
        generate_consumer_patch,
        profile_path,
        read_private_safe_patterns,
        sha256_file,
        verify_private_safe,
        verify_private_safe_text,
    )
    from tools.dev.materialize_rules_go_fork import download_upstream
    from tools.dev.rules_go_fork_registry import DEFAULT_REGISTRY, ForkSelection, load_registry
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.dev.generate_rules_go_consumer_patch import (
        DEFAULT_PROFILE_ROOT,
        REPO_ROOT,
        copy_filtered_tree,
        generate_consumer_patch,
        profile_path,
        read_private_safe_patterns,
        sha256_file,
        verify_private_safe,
        verify_private_safe_text,
    )
    from tools.dev.materialize_rules_go_fork import download_upstream
    from tools.dev.rules_go_fork_registry import DEFAULT_REGISTRY, ForkSelection, load_registry


def verify_profiles(
    *,
    registry_path: Path,
    profile_root: Path,
    profile: str,
    output_dir: Path,
    public_denylist: Path | None,
    private_blocklist_file: Path | None,
    upstream: str | None = None,
    run_functional_smoke: bool = True,
    bazel: Path = REPO_ROOT / "bazelw",
    go_version: str = "1.25.0",
    orchestrion_version: str = "v1.12.0",
    dd_trace_go_version: str = "v2.9.1",
) -> None:
    """Generate and validate one profile patch for selected upstreams."""
    registry = load_registry(registry_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_paths: list[Path] = []
    private_safe_patterns = read_private_safe_patterns(public_denylist, private_blocklist_file)
    upstream_ids = registry.upstream_ids()
    if upstream is not None:
        if upstream not in upstream_ids:
            raise ValueError(
                "unknown upstream %r; supported upstreams: %s"
                % (upstream, ", ".join(upstream_ids))
            )
        upstream_ids = [upstream]
    with temporary_smoke_root() as smoke_root:
        bazel_output_user_root = smoke_root / "bazel_output_user_root"
        for upstream_id in upstream_ids:
            selection = registry.resolve(upstream_id, "base")
            patch = output_dir / ("%s-%s.patch" % (upstream_id, profile))
            manifest = output_dir / ("%s-%s.MANIFEST.json" % (upstream_id, profile))
            generate_consumer_patch(
                registry_path=registry_path,
                upstream=upstream_id,
                variant="base",
                profile_path=profile_path(profile_root, profile),
                output=patch,
                manifest=manifest,
                check_private_safe=public_denylist is not None or private_blocklist_file is not None,
                public_denylist=public_denylist,
                private_blocklist_file=private_blocklist_file,
            )
            if patch.stat().st_size == 0:
                raise ValueError("generated patch is empty: %s" % patch)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            if data.get("patch_sha256") != sha256_file(patch):
                raise ValueError("manifest SHA does not match generated patch: %s" % manifest)
            if data.get("included_paths") != sorted(data.get("included_paths", [])):
                raise ValueError("manifest included_paths are not sorted: %s" % manifest)
            if data.get("excluded_paths") != sorted(data.get("excluded_paths", [])):
                raise ValueError("manifest excluded_paths are not sorted: %s" % manifest)
            if run_functional_smoke:
                print("running functional smoke for %s/%s" % (upstream_id, profile))
                verify_workspace_runtime_functional_smoke(
                    selection=selection,
                    patch=patch,
                    work_root=smoke_root / upstream_id,
                    bazel_output_user_root=bazel_output_user_root,
                    bazel=bazel,
                    go_version=go_version,
                    orchestrion_version=orchestrion_version,
                    dd_trace_go_version=dd_trace_go_version,
                    private_safe_patterns=private_safe_patterns,
                )
            generated_paths.extend([patch, manifest])
            print("verified %s" % patch)
        _bazel_shutdown(bazel, bazel_output_user_root, private_safe_patterns)
    if public_denylist is not None or private_blocklist_file is not None:
        verify_private_safe(
            paths=generated_paths,
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )
    if private_blocklist_file is not None:
        verify_private_safe(
            paths=modified_tracked_files(private_blocklist_file),
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )


def verify_workspace_runtime_functional_smoke(
    *,
    selection: ForkSelection,
    patch: Path,
    work_root: Path,
    bazel_output_user_root: Path,
    bazel: Path,
    go_version: str,
    orchestrion_version: str,
    dd_trace_go_version: str,
    private_safe_patterns: list[str],
) -> None:
    """Verify a generated workspace_runtime patch is usable without the base tree."""
    upstream_source = download_upstream(selection, work_root / "download")
    rules_go_root = work_root / "rules_go_patched"
    workspace = work_root / "workspace"
    copy_filtered_tree(upstream_source, rules_go_root)
    run_private_safe(
        ["git", "-C", rules_go_root.as_posix(), "apply", "--binary", "-p1", patch.as_posix()],
        private_safe_patterns=private_safe_patterns,
    )
    write_smoke_workspace(
        workspace=workspace,
        rules_go_root=rules_go_root,
        go_version=go_version,
        orchestrion_version=orchestrion_version,
        dd_trace_go_version=dd_trace_go_version,
    )

    common_flags = [
        "--noenable_bzlmod",
        "--enable_workspace",
    ]
    orchestrion_flags = common_flags + [
        "--@io_bazel_rules_go//go/private/orchestrion:enabled=true",
        "--@io_bazel_rules_go//go/private/orchestrion:mode=test_optimization",
    ]
    isolated_cache_flags = [
        "--disk_cache=",
        "--remote_cache=",
    ]
    run_bazel(
        bazel,
        bazel_output_user_root,
        workspace,
        ["build", *common_flags, "@go_sdk//:builder"],
        private_safe_patterns=private_safe_patterns,
    )
    first_plain = run_stdlib_inventory(
        bazel,
        bazel_output_user_root,
        workspace,
        command="build",
        mode_flags=[*common_flags, *isolated_cache_flags],
        target="//app:hello_test",
        private_safe_patterns=private_safe_patterns,
    )
    first_orchestrion = run_stdlib_inventory(
        bazel,
        bazel_output_user_root,
        workspace,
        command="test",
        mode_flags=[*orchestrion_flags, *isolated_cache_flags, "--test_output=errors"],
        target="//app:hello_test",
        private_safe_patterns=private_safe_patterns,
    )
    aquery = run_bazel(
        bazel,
        bazel_output_user_root,
        workspace,
        ["aquery", *orchestrion_flags, 'mnemonic("GoCompilePkg", //app:hello_test)'],
        private_safe_patterns=private_safe_patterns,
    )
    assert_aquery_contains(aquery.stdout, patch)

    replay_output_user_root = work_root / "bazel_output_user_root_replay"
    second_plain = run_stdlib_inventory(
        bazel,
        replay_output_user_root,
        workspace,
        command="build",
        mode_flags=[*common_flags, *isolated_cache_flags],
        target="//app:hello_test",
        private_safe_patterns=private_safe_patterns,
    )
    second_orchestrion = run_stdlib_inventory(
        bazel,
        replay_output_user_root,
        workspace,
        command="test",
        mode_flags=[*orchestrion_flags, *isolated_cache_flags, "--test_output=errors"],
        target="//app:hello_test",
        private_safe_patterns=private_safe_patterns,
    )
    assert_plain_stdlib_cache(first_plain, patch)
    assert_plain_stdlib_cache(second_plain, patch)
    assert_orchestrion_stdlib_cache(first_orchestrion, patch)
    assert_orchestrion_stdlib_cache(second_orchestrion, patch)
    if first_plain != second_plain:
        raise ValueError(
            "plain stdlib cache inventories differ for %s: %s"
            % (patch, describe_snapshot_difference(first_plain, second_plain))
        )
    if first_orchestrion != second_orchestrion:
        raise ValueError(
            "Test Optimization stdlib cache inventories differ for %s: %s"
            % (
                patch,
                describe_snapshot_difference(first_orchestrion, second_orchestrion),
            )
        )


def describe_snapshot_difference(
    first: StdlibCacheSnapshot, second: StdlibCacheSnapshot
) -> str:
    """Describe canonical cache entries that differ between two executions."""
    differences = []
    for relative in sorted(set(first.inventory) | set(second.inventory)):
        first_value = first.inventory.get(relative, "missing")
        second_value = second.inventory.get(relative, "missing")
        if first_value != second_value:
            differences.append("%s=(%s != %s)" % (relative, first_value, second_value))
    if first.manifest != second.manifest:
        differences.append("manifest contents differ")
    return ", ".join(differences) or "snapshot metadata differs"


def write_smoke_workspace(
    *,
    workspace: Path,
    rules_go_root: Path,
    go_version: str,
    orchestrion_version: str,
    dd_trace_go_version: str,
) -> None:
    """Create a minimal WORKSPACE-mode Go project for generated profile smoke."""
    app = workspace / "app"
    app.mkdir(parents=True, exist_ok=True)
    workspace.joinpath("WORKSPACE").write_text(
        """workspace(name = "profile_smoke")

local_repository(
    name = "io_bazel_rules_go",
    path = "%s",
)

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "bazel_gazelle",
    sha256 = "b760f7fe75173886007f7c2e616a21241208f3d90e8657dc65d36a771e916b6a",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
    ],
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")

go_rules_dependencies()
go_register_toolchains(version = "%s")
gazelle_dependencies()

go_orchestrion_tool_repo(
    version = "%s",
    dd_trace_go_version = "%s",
    go_sdk_root = "@go_sdk//:ROOT",
    go_sdk_version = "%s",
)
"""
        % (
            rules_go_root.as_posix(),
            go_version,
            orchestrion_version,
            dd_trace_go_version,
            go_version,
        ),
        encoding="utf-8",
    )
    app.joinpath("BUILD.bazel").write_text(
        """load("@io_bazel_rules_go//go:def.bzl", "go_library", "go_test")

go_library(
    name = "hello_lib",
    srcs = ["hello.go"],
    importpath = "example.com/profile_smoke/app",
)

go_test(
    name = "hello_test",
    srcs = ["hello_test.go"],
    embed = [":hello_lib"],
)
""",
        encoding="utf-8",
    )
    app.joinpath("hello.go").write_text(
        'package app\n\nfunc Greeting() string { return "hello" }\n',
        encoding="utf-8",
    )
    app.joinpath("hello_test.go").write_text(
        'package app\n\nimport "testing"\n\nfunc TestGreeting(t *testing.T) { if Greeting() != "hello" { t.Fatal("bad") } }\n',
        encoding="utf-8",
    )


def run_bazel(
    bazel: Path,
    output_user_root: Path,
    cwd: Path,
    args: list[str],
    private_safe_patterns: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run Bazel through this repository's wrapper in a temporary workspace."""
    env = smoke_bazel_env(output_user_root)
    result = subprocess.run(
        [
            bazel.as_posix(),
            "--batch",
            "--output_user_root=%s" % output_user_root.as_posix(),
            *args,
        ],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    patterns = private_safe_patterns or []
    verify_private_safe_text("bazel stdout", result.stdout, patterns)
    verify_private_safe_text("bazel stderr", result.stderr, patterns)
    if result.returncode != 0:
        details = "\n".join(
            part[-4000:]
            for part in (result.stdout.strip(), result.stderr.strip())
            if part
        )
        raise RuntimeError(
            "bazel command failed (%s):\n%s" % (" ".join(args), details)
        )
    return result


@dataclass(frozen=True)
class StdlibCacheSnapshot:
    """Canonical declared-cache inventory plus its manifest contents."""

    inventory: dict[str, str]
    manifest: str | None


def run_stdlib_inventory(
    bazel: Path,
    output_user_root: Path,
    workspace: Path,
    *,
    command: str,
    mode_flags: list[str],
    target: str,
    private_safe_patterns: list[str] | None = None,
) -> StdlibCacheSnapshot:
    """Execute one stdlib action and inventory its declared cache TreeArtifact."""
    run_bazel(
        bazel,
        output_user_root,
        workspace,
        [command, *mode_flags, target],
        private_safe_patterns=private_safe_patterns,
    )
    output_path_result = run_bazel(
        bazel,
        output_user_root,
        workspace,
        ["info", *mode_flags, "output_path"],
        private_safe_patterns=private_safe_patterns,
    )
    output_path = Path(output_path_result.stdout.strip())
    candidates = sorted(
        path
        for path in output_path.rglob("gocache")
        if path.parent.name == "stdlib_" and path.is_dir()
    )
    if not candidates:
        raise ValueError(
            "expected a declared GoStdlib gocache under %s" % output_path
        )
    snapshots = [(path, canonical_tree_inventory(path)) for path in candidates]
    manifested = [(path, snapshot) for path, snapshot in snapshots if snapshot.manifest is not None]
    if len(manifested) > 1:
        raise ValueError(
            "multiple declared GoStdlib caches contain manifests under %s: %s"
            % (output_path, [path.as_posix() for path, _ in manifested])
        )
    for path, snapshot in snapshots:
        if manifested and path == manifested[0][0]:
            continue
        if snapshot.inventory:
            raise ValueError(
                "non-selected declared GoStdlib cache is not empty: %s contains %s"
                % (path, sorted(snapshot.inventory))
            )
    if manifested:
        return manifested[0][1]
    return StdlibCacheSnapshot(inventory={}, manifest=None)


def canonical_tree_inventory(root: Path) -> StdlibCacheSnapshot:
    """Return a deterministic relative-path inventory and reject symlinks."""
    inventory: dict[str, str] = {}
    manifest: str | None = None
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError("declared stdlib cache contains symlink %s" % relative)
        if path.is_dir():
            inventory[relative] = "dir"
            continue
        if not path.is_file():
            raise ValueError("declared stdlib cache contains non-file %s" % relative)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        inventory[relative] = "file:%s" % digest
        if relative == ".orchestrion_stdlib_cache_manifest":
            manifest = path.read_text(encoding="utf-8")
    return StdlibCacheSnapshot(inventory=inventory, manifest=manifest)


def assert_plain_stdlib_cache(snapshot: StdlibCacheSnapshot, patch: Path) -> None:
    """Require the plain-mode declared stdlib cache to be empty."""
    if snapshot.inventory or snapshot.manifest is not None:
        raise ValueError(
            "plain stdlib cache for %s is not empty: %s"
            % (patch, sorted(snapshot.inventory))
        )


def assert_orchestrion_stdlib_cache(snapshot: StdlibCacheSnapshot, patch: Path) -> None:
    """Require only sorted, manifested Go cache data entries."""
    manifest_name = ".orchestrion_stdlib_cache_manifest"
    inventory = snapshot.inventory
    manifest_value = inventory.get(manifest_name, "")
    if not manifest_value.startswith("file:"):
        raise ValueError("Test Optimization stdlib cache for %s has no manifest" % patch)
    if snapshot.manifest is None:
        raise ValueError("Test Optimization stdlib cache for %s has no manifest contents" % patch)
    lines = snapshot.manifest.splitlines()
    if not lines:
        raise ValueError("Test Optimization stdlib cache manifest for %s is empty" % patch)

    expected = {manifest_name}
    archives: set[str] = set()
    directories: set[str] = set()
    packages: set[str] = set()
    package_order: list[str] = []
    for line in lines:
        package, separator, relative = line.partition("=")
        relative_path = PurePosixPath(relative)
        if (
            not separator
            or not package
            or package in packages
            or not relative
            or "\\" in relative
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or relative_path.name.endswith("-a")
            or not relative_path.name.endswith("-d")
        ):
            raise ValueError(
                "invalid Test Optimization stdlib cache manifest entry for %s: %r"
                % (patch, line)
            )
        packages.add(package)
        package_order.append(package)
        archives.add(relative)
        parent = relative_path.parent
        while parent != PurePosixPath("."):
            directories.add(parent.as_posix())
            parent = parent.parent

    if package_order != sorted(package_order):
        raise ValueError("Test Optimization stdlib cache manifest for %s is unsorted" % patch)

    expected.update(archives)
    expected.update(directories)
    actual = set(inventory)
    if actual != expected:
        raise ValueError(
            "Test Optimization stdlib cache for %s contains unmanifested entries: missing=%s extra=%s"
            % (patch, sorted(expected - actual), sorted(actual - expected))
        )
    for relative in archives:
        if not inventory[relative].startswith("file:"):
            raise ValueError("manifested stdlib archive %s is not a file" % relative)
    for relative in directories:
        if inventory[relative] != "dir":
            raise ValueError("stdlib cache parent %s is not a directory" % relative)


@contextmanager
def temporary_smoke_root():
    """Create and remove a smoke tempdir without Python-level Bazel tree cleanup."""
    smoke_root = Path(tempfile.mkdtemp(prefix="rules_go_profile_smoke_"))
    try:
        yield smoke_root
    finally:
        remove_tree(smoke_root)


def remove_tree(path: Path) -> None:
    """Best-effort removal for large Bazel/Go SDK output trees."""
    if not path.exists():
        return
    result = run_cleanup_command(["rm", "-rf", path.as_posix()])
    if result.returncode == 0 or not path.exists():
        return
    run_cleanup_command(["chmod", "-R", "u+w", path.as_posix()])
    run_cleanup_command(["rm", "-rf", path.as_posix()])


def run_cleanup_command(argv: list[str]) -> subprocess.CompletedProcess[bytes]:
    """Run a cleanup command without letting slow temp cleanup block verification."""
    try:
        return subprocess.run(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, 124)


def smoke_bazel_env(output_user_root: Path) -> dict[str, str]:
    """Return the minimal environment needed by the Bazel smoke test."""
    smoke_home = output_user_root.parent / "home"
    smoke_tmp = output_user_root.parent / "tmp"
    smoke_home.mkdir(parents=True, exist_ok=True)
    smoke_tmp.mkdir(parents=True, exist_ok=True)
    path_entries: list[str] = []
    for tool in ("bash", "date", "tr", "awk", "sed", "git", "bazelisk", "bazel"):
        resolved = shutil.which(tool)
        if resolved is not None:
            path_entries.append(str(Path(resolved).parent))
    path_entries.extend(["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin"])
    env = {
        "HOME": smoke_home.as_posix(),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "LOGNAME": "rules_go_smoke",
        "PATH": os.pathsep.join(dict.fromkeys(path_entries)),
        "TMPDIR": smoke_tmp.as_posix(),
        "USER": "rules_go_smoke",
        "USE_BAZEL_VERSION": (REPO_ROOT / ".bazelversion").read_text().strip(),
    }
    for key in ("JAVA_HOME", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        if key in os.environ:
            env[key] = os.environ[key]
    return env


def run_private_safe(
    argv: list[str],
    *,
    private_safe_patterns: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one command and scan captured output before reporting failures."""
    result = subprocess.run(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    patterns = private_safe_patterns or []
    verify_private_safe_text("%s stdout" % argv[0], result.stdout, patterns)
    verify_private_safe_text("%s stderr" % argv[0], result.stderr, patterns)
    if result.returncode != 0:
        raise RuntimeError(
            "command failed (%s): %s" % (" ".join(argv), result.stderr.strip())
        )
    return result


def assert_aquery_contains(aquery_output: str, patch: Path) -> None:
    """Assert the generated-patch smoke actually used Orchestrion test mode."""
    required = [
        "-orchestrion_mode",
        "test_optimization",
        "rules_go_orchestrion_tool",
    ]
    missing = [needle for needle in required if needle not in aquery_output]
    if missing:
        raise ValueError(
            "functional smoke for %s did not prove Orchestrion test mode; missing %s"
            % (patch, ", ".join(missing))
        )


def modified_tracked_files(private_blocklist_file: Path | None) -> list[Path]:
    """Return modified tracked repository files when a private scan is requested."""
    if private_blocklist_file is None:
        return []
    paths: set[Path] = set()
    for args in (
        ["diff", "--name-only", "--diff-filter=ACMRT"],
        ["diff", "--cached", "--name-only", "--diff-filter=ACMRT"],
    ):
        result = subprocess.run(
            ["git", "-C", REPO_ROOT.as_posix(), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip())
        for line in result.stdout.splitlines():
            path = REPO_ROOT / line
            if path.is_file():
                paths.add(path)
    return sorted(paths)


def _bazel_shutdown(
    bazel: Path,
    output_user_root: Path,
    private_safe_patterns: list[str] | None = None,
) -> None:
    """Best-effort shutdown for the smoke workspace Bazel server."""
    try:
        run_bazel(
            bazel,
            output_user_root,
            REPO_ROOT,
            ["shutdown"],
            private_safe_patterns=private_safe_patterns,
        )
    except (OSError, RuntimeError):
        return


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--profile-root", type=Path, default=DEFAULT_PROFILE_ROOT)
    parser.add_argument("--profile", default="workspace_runtime")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument(
        "--upstream",
        help="Verify only one upstream support line. Defaults to all registered upstreams.",
    )
    parser.add_argument(
        "--public-denylist",
        type=Path,
        default=REPO_ROOT / "tools/dev/private_leak_public_denylist.txt",
        help="Public denylist used to reject private-only strings in generated artifacts.",
    )
    parser.add_argument("--private-blocklist-file", type=Path)
    parser.add_argument(
        "--skip-functional-smoke",
        action="store_true",
        help="Skip the generated-patch WORKSPACE smoke. Intended only for focused unit tests.",
    )
    parser.add_argument("--bazel", type=Path, default=REPO_ROOT / "bazelw")
    parser.add_argument("--go-version", default="1.25.0")
    parser.add_argument("--orchestrion-version", default="v1.12.0")
    parser.add_argument("--dd-trace-go-version", default="v2.9.1")
    args = parser.parse_args(argv)
    try:
        if args.output_dir:
            verify_profiles(
                registry_path=args.registry,
                profile_root=args.profile_root,
                profile=args.profile,
                output_dir=args.output_dir,
                public_denylist=args.public_denylist,
                private_blocklist_file=args.private_blocklist_file,
                upstream=args.upstream,
                run_functional_smoke=not args.skip_functional_smoke,
                bazel=args.bazel,
                go_version=args.go_version,
                orchestrion_version=args.orchestrion_version,
                dd_trace_go_version=args.dd_trace_go_version,
            )
        else:
            with tempfile.TemporaryDirectory(prefix="rules_go_profiles_") as raw_tmp:
                verify_profiles(
                    registry_path=args.registry,
                    profile_root=args.profile_root,
                    profile=args.profile,
                    output_dir=Path(raw_tmp),
                    public_denylist=args.public_denylist,
                    private_blocklist_file=args.private_blocklist_file,
                    upstream=args.upstream,
                    run_functional_smoke=not args.skip_functional_smoke,
                    bazel=args.bazel,
                    go_version=args.go_version,
                    orchestrion_version=args.orchestrion_version,
                    dd_trace_go_version=args.dd_trace_go_version,
                )
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
