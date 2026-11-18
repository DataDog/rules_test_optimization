# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed by Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Load the public Bazel entry points from a clean consumer workspace."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from build_release import LANGUAGES, archive_call, module_version

CORE = "datadog-rules-test-optimization"
# Apparent repository names that each published module needs as a dependency.
# A new runtime repository should be reflected here. Test repos belong to the root only.
CONSUMER_REPOS = {
    CORE: {"platforms"},
    f"{CORE}-go": {
        CORE, "bazel_skylib", "io_bazel_rules_go", "platforms",
        "topt_go_ddtest_mini", "topt_go_ddtest_toolchains",
    },
    f"{CORE}-python": {CORE, "rules_python"},
    f"{CORE}-java": {CORE, "rules_java"},
    f"{CORE}-nodejs": {CORE},
    f"{CORE}-dotnet": {CORE},
    f"{CORE}-ruby": {CORE},
}
BUILTIN_REPOS = {"", "bazel_tools", "local_config_platform"}


def write_consumer(workspace: Path, source: Path, release_dir: Path | None) -> None:
    (workspace / ".bazelversion").write_bytes((source / ".bazelversion").read_bytes())
    module_paths = {CORE: source, **{f"{CORE}-{lang}": source / "modules" / lang for lang in LANGUAGES}}
    version = module_version((source / "MODULE.bazel").read_text(encoding="utf-8"))
    archive = None
    if release_dir is not None:
        archive = json.loads((release_dir / "release.json").read_text(encoding="utf-8"))
        archive["url"] = (release_dir / archive["archive"]).resolve().as_uri()
        version = archive["version"]

    module = ['module(name = "test_optimization_consumer")']
    for name, path in module_paths.items():
        module.append(f'bazel_dep(name = "{name}", version = "{version}")')
        if archive is None:
            module.append(f'local_path_override(module_name = "{name}", path = {json.dumps(path.as_posix())})')
        else:
            module.append(archive_call(archive, name, archive["modules"][name], bzlmod=True).rstrip())
    (workspace / "MODULE.bazel").write_text("\n".join(module) + "\n", encoding="utf-8")

    build = [
        f'load("@{CORE}//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")',
    ]
    for language in LANGUAGES:
        prefix = "py" if language == "python" else language
        build.append(f'load("@{CORE}-{language}//:topt_{prefix}_test.bzl", "dd_topt_{prefix}_test")')
    build.append(f"""
filegroup(
    name = "consumer_files",
    srcs = [
        "@{CORE}//tools/core:diagnostic_runtime",
        "@{CORE}//tools/core:uploader_python_runtime",
        "@{CORE}//tools/dev:build_release.py",
        "@{CORE}//tools/tests:integration/mock_dd_server.py",
        "@{CORE}-python//:run_pytest.py",
    ],
)
""")
    (workspace / "BUILD.bazel").write_text("\n".join(build), encoding="utf-8")


def check_consumer(bazel: Path, workspace: Path, output_user_root: Path | None) -> None:
    startup = [str(bazel), "--batch", "--ignore_all_rc_files"]
    if output_user_root is not None:
        startup.append(f"--output_user_root={output_user_root}")

    def run(command: str, *args: str) -> str:
        return subprocess.check_output(
            [*startup, command, "--enable_bzlmod", "--lockfile_mode=off", *args],
            cwd=workspace, text=True,
        )

    root_mapping = json.loads(run("mod", "dump_repo_mapping", ""))
    modules = list(CONSUMER_REPOS)
    mappings = run("mod", "dump_repo_mapping", *(root_mapping[name] for name in modules)).splitlines()
    if len(mappings) != len(modules):
        raise ValueError(f"Bazel returned {len(mappings)} mappings for {len(modules)} modules")
    for name, mapping in zip(modules, mappings):
        actual = set(json.loads(mapping)) - BUILTIN_REPOS - {name}
        expected = CONSUMER_REPOS[name]
        if actual != expected:
            raise ValueError(
                f"{name} consumer mapping: unexpected {sorted(actual - expected)}, "
                f"missing {sorted(expected - actual)}"
            )
        print(f"Checked consumer repositories for {name}", flush=True)

    run("build", "//:consumer_files")
    print("Loaded the core and six companion entry points and resolved their consumer files.", flush=True)


def main() -> None:
    source = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", type=Path, default=source / "bazelw")
    parser.add_argument("--output-user-root", type=Path)
    parser.add_argument("--release-dir", type=Path, help="Validate the archive described by release.json")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rto-consumer-modules-") as temporary:
        workspace = Path(temporary)
        write_consumer(workspace, source, args.release_dir)
        check_consumer(args.bazel.resolve(), workspace, args.output_user_root)


if __name__ == "__main__":
    main()
