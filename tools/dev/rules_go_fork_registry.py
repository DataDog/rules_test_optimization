#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Load and validate the versioned rules_go Orchestrion fork registry."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = REPO_ROOT / "third_party" / "rules_go_orchestrion" / "registry.json"
SUPPORTED_SCHEMA_VERSION = 2
REMOVED_COMPLETE_VARIANT_ERROR = 'rules_go_variant "complete" is no longer supported. Use "base".'
IGNORED_TREE_NAMES = frozenset({
    ".bzr",
    ".git",
    ".hg",
    ".svn",
    "bazel-bin",
    "bazel-out",
    "bazel-testlogs",
})


@dataclass(frozen=True)
class UpstreamInfo:
    """Exact upstream rules_go source for one supported fork version."""

    repository: str
    commit: str
    tag: str
    archive_sha256: str


@dataclass(frozen=True)
class ForkSelection:
    """Resolved rules_go fork version and variant."""

    upstream_id: str
    variant: str
    rules_go_version: str
    upstream: UpstreamInfo
    patch_root: Path
    tree_path: Path
    metadata_path: Path
    changed_files_report: Path
    series_path: Path


class ForkRegistry:
    """Validated registry for rules_go Orchestrion fork versions."""

    def __init__(self, root: Path, repo_root: Path, data: dict[str, Any]) -> None:
        self.root = root
        self.repo_root = repo_root
        self.data = data
        self.default_upstream = _require_string(data, "default_upstream")
        self.default_variant = _require_string(data, "default_variant")
        upstreams = data.get("upstreams")
        if not isinstance(upstreams, dict) or not upstreams:
            raise ValueError("registry must contain a non-empty upstreams object")
        self.upstreams = upstreams

    def resolve(self, upstream: str | None, variant: str | None) -> ForkSelection:
        """Resolve an upstream and variant pair to concrete repository paths."""
        upstream_id = self.default_upstream if upstream in (None, "", "default") else upstream
        variant_id = self.default_variant if variant in (None, "", "default") else variant
        if upstream_id not in self.upstreams:
            raise ValueError(
                "rules_go upstream must be one of %s, got %r"
                % (sorted(self.upstreams.keys()), upstream)
            )
        upstream_entry = self.upstreams[upstream_id]
        variants = upstream_entry.get("variants")
        if variant_id != "base":
            if variant_id == "complete":
                raise ValueError(REMOVED_COMPLETE_VARIANT_ERROR)
            raise ValueError(
                "rules_go variant must be one of %s for upstream %r, got %r"
                % (sorted((variants or {}).keys()), upstream_id, variant)
            )
        if not isinstance(variants, dict) or variant_id not in variants:
            raise ValueError(
                "rules_go variant must be one of %s for upstream %r, got %r"
                % (sorted((variants or {}).keys()), upstream_id, variant)
            )
        variant_entry = variants[variant_id]
        upstream_info = upstream_entry.get("upstream")
        if not isinstance(upstream_info, dict):
            raise ValueError("upstream %r must contain an upstream object" % upstream_id)
        return ForkSelection(
            upstream_id=upstream_id,
            variant=variant_id,
            rules_go_version=_require_string(upstream_entry, "rules_go_version"),
            upstream=UpstreamInfo(
                repository=_require_string(upstream_info, "repository"),
                commit=_require_string(upstream_info, "commit"),
                tag=_require_string(upstream_info, "tag"),
                archive_sha256=_require_string(upstream_info, "archive_sha256"),
            ),
            patch_root=_repo_path(self.repo_root, _require_string(upstream_entry, "patch_root")),
            tree_path=_repo_path(self.repo_root, _require_string(variant_entry, "tree_path")),
            metadata_path=_repo_path(self.repo_root, _require_string(variant_entry, "metadata_path")),
            changed_files_report=_repo_path(
                self.repo_root, _require_string(variant_entry, "changed_files_report")
            ),
            series_path=_repo_path(self.repo_root, _require_string(variant_entry, "series")),
        )

    def selections(self) -> list[ForkSelection]:
        """Return all registered upstream and variant selections in deterministic order."""
        result: list[ForkSelection] = []
        for upstream_id in sorted(self.upstreams.keys()):
            variants = self.upstreams[upstream_id].get("variants", {})
            for variant in sorted(variants.keys()):
                result.append(self.resolve(upstream_id, variant))
        return result

    def upstream_ids(self) -> list[str]:
        """Return supported upstream ids in deterministic order."""
        return sorted(self.upstreams.keys())


def load_registry(path: Path = DEFAULT_REGISTRY) -> ForkRegistry:
    """Load and eagerly validate a registry JSON file."""
    path = Path(path)
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("schema_version") != SUPPORTED_SCHEMA_VERSION:
        raise ValueError("unsupported registry schema_version %r" % data.get("schema_version"))
    registry = ForkRegistry(path.parent, _find_repo_root(path.parent), data)
    _validate_registry(registry)
    return registry


def repo_relative_path(repo_root: Path, path: Path) -> str:
    """Return a repository-relative POSIX path."""
    return path.resolve().relative_to(repo_root.resolve()).as_posix()


def is_ignored_tree_path(path: Path) -> bool:
    """Return whether a tree-relative path is local output noise."""
    return any(part in IGNORED_TREE_NAMES or part.startswith("bazel-") for part in path.parts)


def _validate_registry(registry: ForkRegistry) -> None:
    """Validate every registered selection so registry typos fail at load time."""
    required_top_level = {"schema_version", "default_upstream", "default_variant", "upstreams"}
    missing_top_level = required_top_level - set(registry.data.keys())
    if missing_top_level:
        raise ValueError(
            "registry missing required top-level fields: %s" % sorted(missing_top_level)
        )
    if registry.default_upstream not in registry.upstreams:
        raise ValueError("default_upstream is not registered: %s" % registry.default_upstream)

    for upstream_id, upstream_entry in registry.upstreams.items():
        if not isinstance(upstream_entry, dict):
            raise ValueError("registry upstream %s must be an object" % upstream_id)
        required_upstream = {
            "rules_go_version",
            "upstream",
            "patch_root",
            "variants",
        }
        missing_upstream = required_upstream - set(upstream_entry.keys())
        if missing_upstream:
            raise ValueError(
                "registry upstream %s missing fields: %s"
                % (upstream_id, sorted(missing_upstream))
            )
        upstream_info = upstream_entry.get("upstream")
        if not isinstance(upstream_info, dict):
            raise ValueError("registry upstream %s upstream must be an object" % upstream_id)
        required_upstream_info = {"repository", "commit", "tag", "archive_sha256"}
        missing_upstream_info = required_upstream_info - set(upstream_info.keys())
        if missing_upstream_info:
            raise ValueError(
                "registry upstream %s upstream missing fields: %s"
                % (upstream_id, sorted(missing_upstream_info))
            )
        _validate_archive_sha256(upstream_id, _require_string(upstream_info, "archive_sha256"))
        variants = upstream_entry.get("variants")
        if not isinstance(variants, dict) or not variants:
            raise ValueError("registry upstream %s variants must be a non-empty object" % upstream_id)
        if "complete" in variants:
            raise ValueError(REMOVED_COMPLETE_VARIANT_ERROR)
        non_base_variants = sorted(variant for variant in variants if variant != "base")
        if non_base_variants:
            raise ValueError(
                "registry upstream %s only supports the base variant, got: %s"
                % (upstream_id, non_base_variants)
            )
        if "base" not in variants:
            raise ValueError("registry upstream %s must register the base variant" % upstream_id)
        if registry.default_variant not in variants and upstream_id == registry.default_upstream:
            raise ValueError(
                "default_variant %s is not registered for %s"
                % (registry.default_variant, upstream_id)
            )
        required_variant = {"tree_path", "metadata_path", "changed_files_report", "series"}
        for variant, variant_entry in variants.items():
            if not isinstance(variant_entry, dict):
                raise ValueError("registry variant %s/%s must be an object" % (upstream_id, variant))
            missing_variant = required_variant - set(variant_entry.keys())
            if missing_variant:
                raise ValueError(
                    "registry variant %s/%s missing fields: %s"
                    % (upstream_id, variant, sorted(missing_variant))
                )
            registry.resolve(upstream_id, variant)


def _require_string(data: dict[str, Any], key: str) -> str:
    """Return a required non-empty string field."""
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError("registry field %s must be a non-empty string" % key)
    return value


def _validate_archive_sha256(upstream_id: str, value: str) -> None:
    """Validate the pinned upstream archive checksum shape."""
    if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
        raise ValueError(
            "registry upstream %s archive_sha256 must be a 64-character lowercase hex SHA256"
            % upstream_id
        )


def _find_repo_root(start: Path) -> Path:
    """Find the repository root containing a registry path."""
    current = start.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / "MODULE.bazel").is_file() and (candidate / "WORKSPACE").exists():
            return candidate
    return REPO_ROOT


def _repo_path(repo_root: Path, value: str) -> Path:
    """Resolve a repository-relative registry path."""
    path = Path(value)
    if path.is_absolute():
        raise ValueError("registry paths must be repository-relative: %s" % value)
    normalized = Path(*path.parts)
    if ".." in normalized.parts:
        raise ValueError("registry paths must not contain '..': %s" % value)
    return (repo_root / normalized).resolve()
