# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Typed configuration and public CLI compatibility for the Python uploader."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
from typing import Mapping, Sequence

from .json_utils import strict_json_loads
from .models import DEFAULT_WORKERS


CONFIG_SCHEMA_VERSION = 1
DEFAULT_EXPECTED_ENRICHED_TAGS = (
    "git.repository_url",
    "git.commit.sha",
    "bazel.target",
    "bazel.package",
)
VALID_FRESHNESS_MODES = frozenset({"auto", "required", "optional", "disabled"})
VALID_FRESHNESS_SOURCES = frozenset({"auto", "bep", "execution_log"})
VALID_ARTIFACT_SOURCES = frozenset({"auto", "bep", "local"})
VALID_REMOTE_ARTIFACT_MODES = frozenset({"disabled", "download", "required"})
PROXY_ENVIRONMENT_NAMES = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
)
_NON_NEGATIVE_INTEGER_RE = re.compile(r"^[0-9]+$")
_POSITIVE_DECIMAL_RE = re.compile(r"^[+]?([0-9]+([.][0-9]*)?|[.][0-9]+)$")


class ConfigError(ValueError):
    """The generated config, environment, or CLI is invalid."""


@dataclass(frozen=True)
class RuleConfig:
    """Analysis-time values written by the Bazel uploader rule."""

    schema_version: int = CONFIG_SCHEMA_VERSION
    quiescent_sec: int = 10
    max_wait_sec: int = 300
    fail_on_error: bool = False
    debug: bool = False
    keep_payloads: bool = False
    filter_prefix: bool = False
    gzip_payloads: bool = False
    workers: int = DEFAULT_WORKERS
    rules_version: str = ""
    uploader_version: str = ""
    workspace_name: str = ""
    context_manifest_path: str = ""
    context_manifest_short_path: str = ""
    telemetry_facts_manifest_path: str = ""
    telemetry_facts_manifest_short_path: str = ""
    schema_json_path: str = ""
    schema_json_short_path: str = ""
    doctor_runtime_path: str = ""
    doctor_runtime_short_path: str = ""
    expected_targets: tuple[str, ...] = ()
    expected_targets_file_path: str = ""
    expected_targets_file_short_path: str = ""


@dataclass(frozen=True)
class UploaderConfig:
    """Fully resolved immutable configuration shared with workers."""

    rule: RuleConfig
    config_path: Path
    workspace: Path
    lock_workspace: str
    invocation_cwd: Path
    launcher_directory: Path | None
    dry_run: bool
    validate_enrichment: bool
    debug: bool
    quiescent_sec: int
    max_wait_sec: int
    max_depth: int
    fail_on_error: bool
    keep_payloads: bool
    filter_prefix: bool
    gzip_payloads: bool
    workers: int
    expected_enriched_tags: tuple[str, ...]
    bep_json_files: tuple[Path, ...]
    freshness_source: str
    freshness_mode: str
    freshness_disabled_explicitly: bool
    execution_log_json: Path | None
    artifact_source: str
    remote_artifacts: str
    artifact_staging_dir: Path
    bep_artifact_downloader: Path | None
    bep_artifact_downloader_timeout_sec: float
    report_json: Path | None
    testlogs_dir: Path | None
    codeowners_file: Path | None
    context_json: Path | None
    api_key: str
    site: str
    agent_url: str
    agentless_url: str
    proxy_environment: tuple[tuple[str, str], ...]
    ci: bool

    @property
    def agentless(self) -> bool:
        """Whether requests go directly to public intake."""
        return not self.agent_url


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dd_upload_payloads", allow_abbrev=False)
    parser.add_argument("--config", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--validate-enrichment", action="store_true")
    parser.add_argument("--expected-enriched-tag", action="append", default=[])
    parser.add_argument("--bep-json", action="append", default=[])
    parser.add_argument("--freshness-source")
    parser.add_argument("--freshness-mode")
    parser.add_argument("--allow-cached-payload-uploads", action="store_true")
    parser.add_argument("--execution-log-json")
    parser.add_argument("--execution-log-mode")
    parser.add_argument("--artifact-source")
    parser.add_argument("--remote-artifacts")
    parser.add_argument("--artifact-staging-dir")
    parser.add_argument("--bep-artifact-downloader")
    parser.add_argument("--bep-artifact-downloader-timeout-sec")
    parser.add_argument("--report-json")
    parser.add_argument("--debug", action="store_true", default=None)
    parser.add_argument("--workers")
    return parser


def parse_uploader_config(
    argv: Sequence[str],
    *,
    environ: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> UploaderConfig:
    """Resolve generated config, environment, and CLI using public precedence."""
    env = dict(os.environ if environ is None else environ)
    args = _parser().parse_args(list(argv))
    config_path = Path(args.config)
    rule = load_rule_config(config_path)
    invocation_cwd = Path(cwd or Path.cwd()).absolute()
    lock_workspace = env.get("BUILD_WORKSPACE_DIRECTORY") or str(invocation_cwd)
    workspace = Path(lock_workspace).resolve()
    launcher_directory = _optional_path(
        env.get("DD_TEST_OPTIMIZATION_UPLOADER_LAUNCHER_DIR", "")
    )

    quiescent_sec = _non_negative_integer(
        "DD_TEST_OPTIMIZATION_QUIESCENT_SEC",
        env.get("DD_TEST_OPTIMIZATION_QUIESCENT_SEC") or rule.quiescent_sec,
    )
    max_wait_sec = _non_negative_integer(
        "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC",
        env.get("DD_TEST_OPTIMIZATION_MAX_WAIT_SEC") or rule.max_wait_sec,
    )
    max_depth = _non_negative_integer(
        "DD_TEST_OPTIMIZATION_MAX_DEPTH",
        env.get("DD_TEST_OPTIMIZATION_MAX_DEPTH") or 0,
    )
    workers = _positive_integer(
        "--workers/DD_TEST_OPTIMIZATION_WORKERS",
        args.workers
        if args.workers is not None
        else env.get("DD_TEST_OPTIMIZATION_WORKERS") or rule.workers,
    )

    debug = (
        True
        if args.debug is True
        else _environment_bool(env, "DD_TEST_OPTIMIZATION_DEBUG", rule.debug)
    )
    keep_payloads = _environment_bool(
        env, "DD_TEST_OPTIMIZATION_KEEP_PAYLOADS", rule.keep_payloads
    )
    filter_prefix = _environment_bool(
        env, "DD_TEST_OPTIMIZATION_FILTER_PREFIX", rule.filter_prefix
    )
    gzip_payloads = _environment_bool(
        env, "DD_TEST_OPTIMIZATION_GZIP", rule.gzip_payloads
    )

    if args.validate_enrichment and not args.dry_run:
        raise ConfigError("--validate-enrichment requires --dry-run")

    freshness_source_value = (
        args.freshness_source
        if args.freshness_source is not None
        else env.get("DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE") or "auto"
    )
    freshness_source = _choice(
        "--freshness-source/DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE",
        freshness_source_value,
        VALID_FRESHNESS_SOURCES,
    )
    new_freshness_mode = (
        args.freshness_mode
        if args.freshness_mode is not None
        else env.get("DD_TEST_OPTIMIZATION_FRESHNESS_MODE") or None
    )
    legacy_freshness_mode = (
        args.execution_log_mode
        if args.execution_log_mode is not None
        else env.get("DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE") or None
    )
    freshness_mode = _choice(
        "--freshness-mode/DD_TEST_OPTIMIZATION_FRESHNESS_MODE",
        new_freshness_mode or legacy_freshness_mode or "auto",
        VALID_FRESHNESS_MODES,
    )
    if args.allow_cached_payload_uploads:
        freshness_mode = "disabled"

    artifact_source_value = (
        args.artifact_source
        if args.artifact_source is not None
        else env.get("DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE") or "local"
    )
    artifact_source = _choice(
        "--artifact-source/DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE",
        artifact_source_value,
        VALID_ARTIFACT_SOURCES,
    )
    remote_artifacts_value = (
        args.remote_artifacts
        if args.remote_artifacts is not None
        else env.get("DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS") or "disabled"
    )
    remote_artifacts = _choice(
        "--remote-artifacts/DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS",
        remote_artifacts_value,
        VALID_REMOTE_ARTIFACT_MODES,
    )
    downloader_timeout_value = (
        args.bep_artifact_downloader_timeout_sec
        if args.bep_artifact_downloader_timeout_sec is not None
        else env.get("DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC") or "300"
    )
    downloader_timeout = _positive_decimal(
        "--bep-artifact-downloader-timeout-sec",
        downloader_timeout_value,
    )

    staging_text = (
        args.artifact_staging_dir
        if args.artifact_staging_dir is not None
        else env.get("DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR", "")
    )
    artifact_staging_dir = (
        Path(staging_text)
        if staging_text
        else workspace / ".topt" / "bep-artifacts"
    )
    if not artifact_staging_dir.is_absolute():
        artifact_staging_dir = workspace / artifact_staging_dir

    bep_json_values: list[str] = []
    environment_bep = env.get("DD_TEST_OPTIMIZATION_BEP_JSON", "")
    if environment_bep:
        bep_json_values.append(environment_bep)
    bep_json_values.extend(args.bep_json)

    expected_enriched_tags = tuple(args.expected_enriched_tag) or DEFAULT_EXPECTED_ENRICHED_TAGS
    report_text = (
        args.report_json
        if args.report_json is not None
        else env.get("DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON", "")
    )
    execution_log_text = (
        args.execution_log_json
        if args.execution_log_json is not None
        else env.get("DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON", "")
    )
    downloader_text = (
        args.bep_artifact_downloader
        if args.bep_artifact_downloader is not None
        else env.get("DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER", "")
    )

    return UploaderConfig(
        rule=rule,
        config_path=config_path,
        workspace=workspace,
        lock_workspace=lock_workspace,
        invocation_cwd=invocation_cwd,
        launcher_directory=launcher_directory,
        dry_run=args.dry_run,
        validate_enrichment=args.validate_enrichment,
        debug=debug,
        quiescent_sec=quiescent_sec,
        max_wait_sec=max_wait_sec,
        max_depth=max_depth,
        fail_on_error=rule.fail_on_error,
        keep_payloads=keep_payloads,
        filter_prefix=filter_prefix,
        gzip_payloads=gzip_payloads,
        workers=workers,
        expected_enriched_tags=expected_enriched_tags,
        bep_json_files=tuple(Path(value) for value in bep_json_values),
        freshness_source=freshness_source,
        freshness_mode=freshness_mode,
        freshness_disabled_explicitly=args.allow_cached_payload_uploads,
        execution_log_json=_optional_path(execution_log_text),
        artifact_source=artifact_source,
        remote_artifacts=remote_artifacts,
        artifact_staging_dir=artifact_staging_dir,
        bep_artifact_downloader=_optional_path(downloader_text),
        bep_artifact_downloader_timeout_sec=downloader_timeout,
        report_json=_optional_path(report_text),
        testlogs_dir=_optional_path(env.get("TESTLOGS_DIR", "")),
        codeowners_file=_optional_path(env.get("DD_TEST_OPTIMIZATION_CODEOWNERS_FILE", "")),
        context_json=_optional_path(env.get("DD_TEST_OPTIMIZATION_CONTEXT_JSON", "")),
        api_key=env.get("DD_API_KEY", ""),
        site=env.get("DD_SITE", "") or "datadoghq.com",
        agent_url=env.get("DD_TEST_OPTIMIZATION_AGENT_URL", ""),
        agentless_url=env.get("DD_TEST_OPTIMIZATION_AGENTLESS_URL", ""),
        proxy_environment=tuple(
            (name, env[name]) for name in PROXY_ENVIRONMENT_NAMES if env.get(name)
        ),
        ci=env.get("CI", "").strip().lower() not in {"", "0", "false", "no"},
    )


def validate_upload_credentials(config: UploaderConfig) -> None:
    """Validate credentials only after dry-run and endpoint mode are known."""
    if config.agentless and not config.dry_run and not config.api_key:
        raise ConfigError("DD_API_KEY required for agentless uploads")


def load_rule_config(path: Path) -> RuleConfig:
    """Load the small JSON config generated by the Bazel rule."""
    try:
        raw = strict_json_loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise ConfigError(f"uploader config does not exist: {path}") from exc
    except OSError as exc:
        raise ConfigError(f"failed to read uploader config {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid uploader config JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError("uploader config must be a JSON object")

    schema_version = _json_integer(raw, "schema_version", CONFIG_SCHEMA_VERSION, minimum=1)
    if schema_version != CONFIG_SCHEMA_VERSION:
        raise ConfigError(
            f"unsupported uploader config schema_version {schema_version}; "
            f"expected {CONFIG_SCHEMA_VERSION}"
        )
    workers = _json_integer(raw, "workers", DEFAULT_WORKERS, minimum=1)
    return RuleConfig(
        schema_version=schema_version,
        quiescent_sec=_json_integer(raw, "quiescent_sec", 10, minimum=0),
        max_wait_sec=_json_integer(raw, "max_wait_sec", 300, minimum=0),
        fail_on_error=_json_boolean(raw, "fail_on_error", False),
        debug=_json_boolean(raw, "debug", False),
        keep_payloads=_json_boolean(raw, "keep_payloads", False),
        filter_prefix=_json_boolean(raw, "filter_prefix", False),
        gzip_payloads=_json_boolean(raw, "gzip_payloads", False),
        workers=workers,
        rules_version=_json_string(raw, "rules_version", ""),
        uploader_version=_json_string(raw, "uploader_version", ""),
        workspace_name=_json_string(raw, "workspace_name", ""),
        context_manifest_path=_json_string(raw, "context_manifest_path", ""),
        context_manifest_short_path=_json_string(raw, "context_manifest_short_path", ""),
        telemetry_facts_manifest_path=_json_string(
            raw, "telemetry_facts_manifest_path", ""
        ),
        telemetry_facts_manifest_short_path=_json_string(
            raw, "telemetry_facts_manifest_short_path", ""
        ),
        schema_json_path=_json_string(raw, "schema_json_path", ""),
        schema_json_short_path=_json_string(raw, "schema_json_short_path", ""),
        doctor_runtime_path=_json_string(raw, "doctor_runtime_path", ""),
        doctor_runtime_short_path=_json_string(
            raw, "doctor_runtime_short_path", ""
        ),
        expected_targets=_json_string_tuple(raw, "expected_targets"),
        expected_targets_file_path=_json_string(raw, "expected_targets_file_path", ""),
        expected_targets_file_short_path=_json_string(
            raw, "expected_targets_file_short_path", ""
        ),
    )


def _environment_bool(env: Mapping[str, str], name: str, fallback: bool) -> bool:
    value = env.get(name)
    if not value:
        return fallback
    return value.lower() in {"1", "true", "yes"}


def _non_negative_integer(name: str, value: object) -> int:
    text = str(value)
    if not _NON_NEGATIVE_INTEGER_RE.fullmatch(text):
        raise ConfigError(f"{name} must be a non-negative integer, got: {text!r}")
    return int(text)


def _positive_integer(name: str, value: object) -> int:
    result = _non_negative_integer(name, value)
    if result == 0:
        raise ConfigError(f"{name} must be a positive integer, got: {str(value)!r}")
    return result


def _positive_decimal(name: str, value: object) -> float:
    text = str(value)
    if not _POSITIVE_DECIMAL_RE.fullmatch(text):
        raise ConfigError(f"{name} must be a finite number greater than zero")
    try:
        result = float(text)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{name} must be a finite number greater than zero") from exc
    if not math.isfinite(result) or result <= 0:
        raise ConfigError(f"{name} must be a finite number greater than zero")
    return result


def _choice(name: str, value: object, allowed: frozenset[str]) -> str:
    normalized = str(value).lower()
    if normalized not in allowed:
        raise ConfigError(
            f"{name} must be one of: {', '.join(sorted(allowed))}; got {value!r}"
        )
    return normalized


def _optional_path(value: object) -> Path | None:
    text = str(value) if value is not None else ""
    return Path(text) if text else None


def _json_integer(
    raw: Mapping[str, object], name: str, default: int, *, minimum: int
) -> int:
    value = raw.get(name, default)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ConfigError(f"uploader config field {name!r} must be an integer >= {minimum}")
    return value


def _json_boolean(raw: Mapping[str, object], name: str, default: bool) -> bool:
    value = raw.get(name, default)
    if not isinstance(value, bool):
        raise ConfigError(f"uploader config field {name!r} must be a boolean")
    return value


def _json_string(raw: Mapping[str, object], name: str, default: str) -> str:
    value = raw.get(name, default)
    if not isinstance(value, str):
        raise ConfigError(f"uploader config field {name!r} must be a string")
    return value


def _json_string_tuple(raw: Mapping[str, object], name: str) -> tuple[str, ...]:
    value = raw.get(name, [])
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ConfigError(f"uploader config field {name!r} must be a string array")
    return tuple(value)
