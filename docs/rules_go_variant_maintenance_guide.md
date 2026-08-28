<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Orchestrion Support Folder Guide

This guide describes the maintained folder layout for the vendored
Orchestrion-enabled `rules_go` support lines and public consumer patch profiles.

## Folders

### `third_party/rgo/<upstream>/base/`

The public base tree for one supported upstream. For example, the current
default upstream uses `third_party/rgo/v0_60_0/base`, and the additional
support lines use `third_party/rgo/v0_61_1/base` and
`third_party/rgo/v0_62_0/base`. Each tree contains clean upstream `rules_go`
plus the generic Orchestrion support maintained by this repository. Bugs in
our integration are fixed in the affected materialized tree, then the matching
patch series is regenerated from that tree.

### `third_party/rules_go_orchestrion/`

The registry-driven support area for multi-version maintenance:

- `registry.json` selects supported upstream lines and base tree paths.
- `patches/<upstream>/` stores the maintainer patch series for rebasing.
- `profiles/<profile>.json` declares public sparse-patch profiles for
  consumers that need to apply this repository's `rules_go` changes on top of
  a repository-owned patch stack.
- `patches/<upstream>/base.series` lists the patch files that recreate the
  public base tree for that upstream.

The default `rules_go_upstream` is currently `v0_60_0`, which preserves the
existing `third_party/rgo/v0_60_0/base` path. When multiple upstream
`rules_go` versions are supported, use `rules_go_upstream` to choose the upstream
support line. Omitting `rules_go_upstream` preserves the repository default.

Materialized base trees always live at the registry-selected `tree_path`. The
current convention is `third_party/rgo/<upstream>/base`; do not add new
`third_party/rules_go_orchestrion/versions/...` trees.

### `tools/tests/rules_go_variant_regressions/`

Maintainer-only proof fixtures copied into temporary variant trees by the smoke
and extended scripts. These files are not part of the published base tree or
generated public consumer patch profiles.

## Metadata

- `third_party/rgo/<upstream>/base.METADATA.json`
- `third_party/rgo/<upstream>/base.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion/registry.json`
- `third_party/rules_go_orchestrion/profiles/<profile>.json`
- `third_party/rules_go_orchestrion/patches/<upstream>/`

Use `tools/dev/diff_rules_go_fork.py` to regenerate each changed-files report.
Use `tools/dev/materialize_rules_go_fork.py check --all` to verify that patch
series recreate the checked-in trees. Use
`tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt`
to verify that public consumer patch profiles round-trip against clean upstream
`rules_go` without leaking private-only strings.

## Adding A rules_go Upstream Release

Use this sequence when adding support for a new upstream `rules_go` release.
Replace the example `v0_62_0` and `v0.62.0` values with the requested release.

1. Resolve the exact upstream tag, commit, and archive checksum:

   ```bash
   NEW_UPSTREAM=v0_62_0
   NEW_RULES_GO_VERSION=0.62.0
   NEW_TAG=v0.62.0
   NEW_COMMIT="$(git ls-remote --tags https://github.com/bazel-contrib/rules_go.git "refs/tags/${NEW_TAG}^{}" | awk '{print $1}')"
   if [ -z "$NEW_COMMIT" ]; then
     NEW_COMMIT="$(git ls-remote --tags https://github.com/bazel-contrib/rules_go.git "refs/tags/${NEW_TAG}" | awk '{print $1}')"
   fi
   test -n "$NEW_COMMIT"
   curl -L "https://github.com/bazel-contrib/rules_go/archive/${NEW_COMMIT}.tar.gz" \
     -o "/tmp/rules_go-${NEW_UPSTREAM}.tar.gz"
   NEW_ARCHIVE_SHA256="$(shasum -a 256 "/tmp/rules_go-${NEW_UPSTREAM}.tar.gz" | awk '{print $1}')"
   echo "$NEW_ARCHIVE_SHA256"
   ```

2. Add a `third_party/rules_go_orchestrion/registry.json` entry using:

   ```json
   {
     "rules_go_version": "0.62.0",
     "upstream": {
       "repository": "https://github.com/bazel-contrib/rules_go.git",
       "commit": "<NEW_COMMIT>",
       "tag": "v0.62.0",
       "archive_sha256": "<NEW_ARCHIVE_SHA256>"
     },
     "patch_root": "third_party/rules_go_orchestrion/patches/v0_62_0",
     "variants": {
       "base": {
         "tree_path": "third_party/rgo/v0_62_0/base",
         "metadata_path": "third_party/rgo/v0_62_0/base.METADATA.json",
         "changed_files_report": "third_party/rgo/v0_62_0/base.CHANGED_FILES.md",
         "series": "third_party/rules_go_orchestrion/patches/v0_62_0/base.series"
       }
     }
   }
   ```

3. Create the metadata sidecar named by the registry entry:

   ```bash
   mkdir -p "third_party/rgo/${NEW_UPSTREAM}"
   cat > "third_party/rgo/${NEW_UPSTREAM}/base.METADATA.json" <<EOF
   {
     "upstream": {
       "repository": "https://github.com/bazel-contrib/rules_go.git",
       "commit": "${NEW_COMMIT}",
       "tag": "${NEW_TAG}",
       "archive_sha256": "${NEW_ARCHIVE_SHA256}"
     },
     "fork_path": "third_party/rgo/${NEW_UPSTREAM}/base",
     "generated_report": "third_party/rgo/${NEW_UPSTREAM}/base.CHANGED_FILES.md",
     "generator": "python3 tools/dev/diff_rules_go_fork.py --upstream ${NEW_UPSTREAM} --variant base --write-report"
   }
   EOF
   ```

   Keep this file aligned with `registry.json`. The registry is what tooling
   resolves; the metadata sidecar is the checked-in provenance record and report
   input for humans and release archives.

4. Seed the new patch directory from the nearest supported upstream, then try a
   mechanical materialization:

   ```bash
   PREVIOUS_UPSTREAM=v0_61_1
   mkdir -p "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}/base"
   cp "third_party/rules_go_orchestrion/patches/${PREVIOUS_UPSTREAM}/base.series" \
     "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}/base.series"
   cp third_party/rules_go_orchestrion/patches/${PREVIOUS_UPSTREAM}/base/*.patch \
     "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}/base/"
   python3 tools/dev/materialize_rules_go_fork.py write \
     --upstream "${NEW_UPSTREAM}" \
     --variant base
   ```

   If the old patch stack does not apply cleanly, port the Orchestrion changes
   into `third_party/rgo/${NEW_UPSTREAM}/base` manually. Start from the clean
   upstream tree recorded in the registry, then reapply the Datadog Orchestrion
   behavior from the previous support line:

   ```bash
   TMPDIR="$(mktemp -d)"
   tar -xf "/tmp/rules_go-${NEW_UPSTREAM}.tar.gz" -C "$TMPDIR"
   UPSTREAM_ROOT="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
   rm -rf "third_party/rgo/${NEW_UPSTREAM}/base"
   mkdir -p "third_party/rgo/${NEW_UPSTREAM}"
   cp -R "$UPSTREAM_ROOT" "third_party/rgo/${NEW_UPSTREAM}/base"
   PREVIOUS_PATCH="third_party/rules_go_orchestrion/patches/${PREVIOUS_UPSTREAM}/base/0001-full-delta.patch"
   cp "$PREVIOUS_PATCH" "/tmp/${PREVIOUS_UPSTREAM}-base.patch"
   ```

   Use `/tmp/${PREVIOUS_UPSTREAM}-base.patch` as a human-readable map for the
   manual port, but adapt the changes to the new upstream file layout instead of
   forcing old paths. Do not apply the previous patch blindly unless it applies
   cleanly and review confirms it still matches the new upstream semantics.

5. Regenerate the new upstream's canonical patch series from the final
   materialized tree:

   ```bash
   python3 tools/dev/diff_rules_go_fork.py \
     --upstream "${NEW_UPSTREAM}" \
     --variant base \
     --export-patch-series \
     --new-tree "third_party/rgo/${NEW_UPSTREAM}/base" \
     --patch-root "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}" \
     --patch-output-dir "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}/base" \
     --series-file "third_party/rules_go_orchestrion/patches/${NEW_UPSTREAM}/base.series" \
     --patch-name 0001-full-delta.patch
   ```

6. Update Bazel exports for the new upstream:

   - add `v0_62_0/base.METADATA.json` and `v0_62_0/base.CHANGED_FILES.md` to
     `third_party/rgo/BUILD.bazel`;
   - add `patches/v0_62_0/base.series` and
     `patches/v0_62_0/base/0001-full-delta.patch` to
     `third_party/rules_go_orchestrion/BUILD.bazel`;
   - add the same patch files to the `base_patch_series` filegroup in
     `third_party/rules_go_orchestrion/BUILD.bazel`;
   - run `buildifier` on both BUILD files.

7. Regenerate reports, maps, archive contents, and profile checks:

   ```bash
   python3 tools/dev/generate_rules_go_fork_maps.py
   python3 tools/dev/diff_rules_go_fork.py \
     --upstream "${NEW_UPSTREAM}" \
     --variant base \
     --write-report
   python3 tools/dev/materialize_rules_go_fork.py check \
     --upstream "${NEW_UPSTREAM}" \
     --variant base
   python3 tools/dev/verify_rules_go_profiles.py \
     --upstream "${NEW_UPSTREAM}" \
     --public-denylist tools/dev/private_leak_public_denylist.txt
   python3 tools/dev/check_release_archive_contents.py
   ```

8. Generate public consumer patch artifacts when a repository with its own
   `rules_go` patch stack needs a sparse patch input:

   ```bash
   python3 tools/dev/generate_rules_go_consumer_patch.py \
     --upstream "${NEW_UPSTREAM}" \
     --variant base \
     --profile workspace_runtime \
     --output "/tmp/${NEW_UPSTREAM}-workspace_runtime.patch" \
     --manifest "/tmp/${NEW_UPSTREAM}-workspace_runtime.MANIFEST.json" \
     --check-private-safe \
     --public-denylist tools/dev/private_leak_public_denylist.txt
   ```

   To generate the same profile for every registered upstream:

   ```bash
   python3 tools/dev/generate_rules_go_consumer_patch.py \
     --all-upstreams \
     --variant base \
     --profile workspace_runtime \
     --output-dir /tmp/rules_go_consumer_patches \
     --check-private-safe \
     --public-denylist tools/dev/private_leak_public_denylist.txt
   ```

9. Run the migration validation checklist before calling the support line done.
   Build success alone is not enough; at least one runtime lane must prove CI
   Visibility startup, JSON payload generation, doctor success, and upload or
   dry-run upload behavior.

## Consumer Contract

A consumer fetches the complete base tree. Example:

```bzl
http_archive(
    name = "io_bazel_rules_go",
    urls = ["https://example.invalid/rules_test_optimization/<commit>.tar.gz"],
    sha256 = "<sha256>",
    strip_prefix = "rules_test_optimization-<commit>/third_party/rgo/v0_60_0/base",
)
```

For non-default support lines, use the registry-resolved base tree path, for
example `third_party/rgo/v0_61_1/base`.

Consumers should not apply additional Datadog-managed Bazel patch files when
they consume a complete base tree. Repositories that already own their
`rules_go` patch stack should instead use a generated public consumer patch
profile as a local rebase or merge input, then verify the regenerated private
patch in their private patch order.

## Test Optimization Alias Contract

The public base trees keep the existing
`//go/private/orchestrion:enabled` setting and stable aliases. The Datadog Go
wrapper transitions that setting only for optimized targets. Consumers expose
one metadata config:

```bazelrc
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

The public Go extension reads the metadata environment by default; low-level
repositories do so when explicitly configured with `enabled_by_env = True`.
Removing the config is the metadata opt-out and must not require a
consumer-owned duplicate bool flag or stub repository.
