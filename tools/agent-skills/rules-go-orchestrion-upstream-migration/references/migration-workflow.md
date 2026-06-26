<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Migration Workflow

Use this workflow to port the vendored Orchestrion-enabled `rules_go` fork to a
new upstream `rules_go` tag or commit.

Replace `NEW_RULES_GO_TAG_OR_COMMIT` with the exact upstream target. Prefer a
commit SHA in metadata even when the user names a tag, and keep the tag field
only when the upstream target is a real tag.

The public fork has one supported variant: `base`. Do not reintroduce
`complete`, `third_party/rules_go_orchestrion/versions/...`, or
consumer-specific public patch bundles while adding a new upstream.

## Mechanical Release Recipe

Use this recipe as the default algorithm for a new upstream release. Replace
`v0_62_0`, `0.62.0`, and `v0.62.0` with the requested release.

```bash
NEW_UPSTREAM=v0_62_0
NEW_RULES_GO_VERSION=0.62.0
NEW_TAG=v0.62.0
PREVIOUS_UPSTREAM=v0_61_1
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

Then:

1. Add a registry entry in `third_party/rules_go_orchestrion/registry.json` with:
   - `rules_go_version = "$NEW_RULES_GO_VERSION"`
   - `upstream.repository = "https://github.com/bazel-contrib/rules_go.git"`
   - `upstream.commit = "$NEW_COMMIT"`
   - `upstream.tag = "$NEW_TAG"` when the target is a tag
   - `upstream.archive_sha256` from `shasum`
   - `patch_root = "third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM"`
   - `tree_path = "third_party/rgo/$NEW_UPSTREAM/base"`
   - `metadata_path = "third_party/rgo/$NEW_UPSTREAM/base.METADATA.json"`
   - `changed_files_report = "third_party/rgo/$NEW_UPSTREAM/base.CHANGED_FILES.md"`
   - `series = "third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM/base.series"`
2. Create `third_party/rgo/$NEW_UPSTREAM/base.METADATA.json` with the same
   upstream repository, commit, tag, and archive checksum as the registry entry,
   plus:
   - `fork_path = "third_party/rgo/$NEW_UPSTREAM/base"`
   - `generated_report = "third_party/rgo/$NEW_UPSTREAM/base.CHANGED_FILES.md"`
   - `generator = "python3 tools/dev/diff_rules_go_fork.py --upstream $NEW_UPSTREAM --variant base --write-report"`
3. Seed `third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM/base.series`
   and the `base/*.patch` files from `$PREVIOUS_UPSTREAM`.
4. Run:

   ```bash
   python3 tools/dev/materialize_rules_go_fork.py write \
     --upstream "$NEW_UPSTREAM" \
     --variant base
   ```

5. If materialization fails, port the Orchestrion changes manually into
   `third_party/rgo/$NEW_UPSTREAM/base`. Start from the exact clean upstream
   tarball recorded in the registry:

   ```bash
   TMPDIR="$(mktemp -d)"
   tar -xf "/tmp/rules_go-${NEW_UPSTREAM}.tar.gz" -C "$TMPDIR"
   UPSTREAM_ROOT="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
   rm -rf "third_party/rgo/$NEW_UPSTREAM/base"
   mkdir -p "third_party/rgo/$NEW_UPSTREAM"
   cp -R "$UPSTREAM_ROOT" "third_party/rgo/$NEW_UPSTREAM/base"
   PREVIOUS_PATCH="third_party/rules_go_orchestrion/patches/$PREVIOUS_UPSTREAM/base/0001-full-delta.patch"
   cp "$PREVIOUS_PATCH" "/tmp/${PREVIOUS_UPSTREAM}-base.patch"
   ```

   Use `/tmp/${PREVIOUS_UPSTREAM}-base.patch` as a human-readable map, adapt it
   to the new upstream file layout, and keep consumer-specific compatibility
   changes out of the public `base` tree. Do not apply the previous patch blindly
   unless it applies cleanly and review confirms it still matches the new
   upstream semantics.
6. Export the canonical patch series from the final materialized tree:

   ```bash
   python3 tools/dev/diff_rules_go_fork.py \
     --upstream "$NEW_UPSTREAM" \
     --variant base \
     --export-patch-series \
     --new-tree "third_party/rgo/$NEW_UPSTREAM/base" \
     --patch-root "third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM" \
     --patch-output-dir "third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM/base" \
     --series-file "third_party/rules_go_orchestrion/patches/$NEW_UPSTREAM/base.series" \
     --patch-name 0001-full-delta.patch
   ```

7. Update Bazel exports for the new upstream:
   - add `$NEW_UPSTREAM/base.METADATA.json` and
     `$NEW_UPSTREAM/base.CHANGED_FILES.md` to `third_party/rgo/BUILD.bazel`;
   - add `patches/$NEW_UPSTREAM/base.series` and
     `patches/$NEW_UPSTREAM/base/0001-full-delta.patch` to
     `third_party/rules_go_orchestrion/BUILD.bazel`;
   - add the same patch files to the `base_patch_series` filegroup in
     `third_party/rules_go_orchestrion/BUILD.bazel`;
   - run `buildifier` on both BUILD files.
8. Regenerate maps, reports, archive contents, and public consumer profile
   checks:

   ```bash
   python3 tools/dev/generate_rules_go_fork_maps.py
   python3 tools/dev/diff_rules_go_fork.py \
     --upstream "$NEW_UPSTREAM" \
     --variant base \
     --write-report
   python3 tools/dev/materialize_rules_go_fork.py check \
     --upstream "$NEW_UPSTREAM" \
     --variant base
   python3 tools/dev/verify_rules_go_profiles.py \
     --upstream "$NEW_UPSTREAM" \
     --public-denylist tools/dev/private_leak_public_denylist.txt
   python3 tools/dev/check_release_archive_contents.py
   ```

9. Generate public sparse patch artifacts only as derived outputs for consumers
   that own a separate `rules_go` patch stack:

   ```bash
   python3 tools/dev/generate_rules_go_consumer_patch.py \
     --upstream "$NEW_UPSTREAM" \
     --variant base \
     --profile workspace_runtime \
     --output "/tmp/${NEW_UPSTREAM}-workspace_runtime.patch" \
     --manifest "/tmp/${NEW_UPSTREAM}-workspace_runtime.MANIFEST.json" \
     --check-private-safe \
     --public-denylist tools/dev/private_leak_public_denylist.txt
   ```

The generated consumer patch and manifest are not the maintainer source of
truth. The source of truth remains the registry entry, the `base.series` patch
stack, the materialized `third_party/rgo/$NEW_UPSTREAM/base` tree, and the
profile JSON.

## 1. Capture The Current Baseline

Start from a clean understanding of the current fork:

```bash
git status --short
python3 tools/dev/generate_rules_go_fork_maps.py --check
python3 tools/dev/materialize_rules_go_fork.py check --all
python3 tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt
python3 tools/dev/diff_rules_go_fork.py --all
```

Review the current patch series and checked-in reports before editing:

- `third_party/rules_go_orchestrion/registry.json`
- `third_party/rules_go_orchestrion/patches/<current-upstream>/`
- `third_party/rules_go_orchestrion/profiles/workspace_runtime.json`
- the current upstream's `*.METADATA.json`
- the current upstream's `*.CHANGED_FILES.md`

## 2. Materialize The New Upstream Tree

Add the new upstream to `third_party/rules_go_orchestrion/registry.json` using
the shape from the mechanical recipe. Create the metadata file from the same
registry values; do not hand-author a divergent metadata schema.

The repository's diff helper downloads from upstream metadata, so do not rely
on hand-copied upstream files as proof. The final metadata and reports must be
generated from the exact upstream commit recorded in metadata.

## 3. Rebuild `base`

Create the target upstream's `base` patch series and materialized tree. For the
default upstream this may still be `third_party/rgo/v0_60_0/base`; every new
support line should use the registry-selected
`third_party/rgo/<upstream>/base` tree.

The base variant owns:

- Orchestrion extension and WORKSPACE entrypoints
- Orchestrion build repository and bootstrap cache behavior
- builder action changes for compile, archive, stdlib, link, nogo, and import
  configuration
- synthetic `testmain` behavior
- offline module proxy inputs
- `dd_trace_go_versions.json` validation
- tool-version validation
- generic regression tests that prove Orchestrion behavior

Use the current base patch series as a map, not as an unquestioned patch. If
the new upstream moved or rewrote a surface, port the behavior to the new
upstream shape instead of forcing the old file layout.

After the base tree is coherent, regenerate `base.series` and
`base/0001-full-delta.patch` from that tree with
`diff_rules_go_fork.py --export-patch-series` so
`materialize_rules_go_fork.py check --upstream <upstream> --variant base`
recreates it exactly.

## 4. Verify Consumer Patch Profiles

Run the public profile generator against the migrated base tree. The generated
patch must apply to clean upstream `rules_go`, preserve included file modes and
symlinks, exclude profile-excluded files, and pass the public private-leak
denylist. Do not encode private repository names, paths, services, or target
labels in public profiles. Generate profile artifacts into `/tmp` or another
throwaway directory unless a release process explicitly asks for checked-in
derived artifacts.

## 5. Regenerate Reports

Regenerate the target upstream delta report:

```bash
python3 tools/dev/generate_rules_go_fork_maps.py
python3 tools/dev/diff_rules_go_fork.py --upstream <upstream> --variant base --write-report
python3 tools/dev/materialize_rules_go_fork.py check --upstream <upstream> --variant base
python3 tools/dev/verify_rules_go_profiles.py --upstream <upstream> --public-denylist tools/dev/private_leak_public_denylist.txt
python3 tools/dev/check_release_archive_contents.py
```

Read the regenerated reports. The changed-path counts may change, but every new
or removed path should be explainable by the upstream migration.

## 6. Validate Behavior

Run the required lanes from [validation-checklist.md](validation-checklist.md).
For Orchestrion migrations, build success alone is not enough. Runtime
validation must prove that instrumented tests start CI Visibility and write
payload files.

If validation fails, use [troubleshooting.md](troubleshooting.md). Do not hide
failures by weakening tests or deleting variant differences from metadata.

## 7. Final Report

The final report for a migration PR must include:

- old upstream tag or commit
- new upstream tag or commit
- base changed-path count
- whether `verify_rules_go_profiles.py` passed
- smoke and integration lanes run
- lanes skipped, with reasons
- behavior changes caused by upstream, if any
- remaining blockers or reviewer decisions
