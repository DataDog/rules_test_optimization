# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Run the uploader's invocation with ddtest instrument bazel post-process.

The Python uploader keeps what needs Bazel's runfiles or its process: the
configuration, the workspace lock, the expected targets, the resources, the
CODEOWNERS lookup and the API key fingerprint. ddtest runs the rest in one
process: freshness, BEP artifact staging, discovery, the doctor's output
checks, the upload, which decodes each payload once, retention and the
report. ddtest exits with POST_PROCESS_FALLBACK, having printed and sent
nothing, when an input needs the Python uploader's own reading.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, TextIO

from topt_runtime.runfiles import RunfilesResolver

from .codeowners import load_codeowners_matcher
from .config import ConfigError, UploaderConfig
from .credentials import check_api_key_fingerprint
from .doctor_checks import context_records, load_doctor_config
from .ddtest_backend import _ContextNames, _environment
from .discovery import DiscoveryError
from .endpoints import EndpointSet
from .expected_targets import ExpectedTargetsError, load_expected_targets
from .resources import ResourceError
from .transport import HttpTransportError, validate_proxy_environment

POST_PROCESS_FALLBACK = 75

_PREFLIGHT_ERRORS = (ConfigError, DiscoveryError, ExpectedTargetsError, ResourceError, HttpTransportError)


class _Settings:
    """What ddtest_backend._environment reads from its settings."""

    def __init__(self, api_key: str) -> None:
        self.api_key = api_key


def _path(value: Path | None) -> str:
    return str(value) if value is not None else ""


def _resources_request(config: UploaderConfig, endpoints: EndpointSet, resources: Any,
                       logger: logging.Logger) -> dict[str, Any]:
    """The context plan, as ddtest_backend writes it, and the pre-worker inputs."""
    names = _ContextNames()
    plan = resources.context_plan
    selection: dict[str, Any] = {
        "by_repo": [{"repo": record.repo_key, "context": names.name(record.values)} for record in plan.by_repo],
        "override": plan.override,
        "require_repo_match": plan.require_repo_match,
    }
    primary = ""
    if plan.primary is not None:
        primary = selection["primary"] = names.name(plan.primary.values)
    records = context_records(plan)
    codeowners = load_codeowners_matcher(
        explicit_path=config.codeowners_file,
        workspace_root=config.workspace,
        context_workspace=resources.context_workspace,
        cwd=config.invocation_cwd,
        launcher_directory=config.launcher_directory,
    )
    fingerprint = check_api_key_fingerprint(resources.primary_context, api_key=config.api_key,
                                            agentless=endpoints.agentless)
    messages = []
    if fingerprint.status == "mismatch":
        messages.append({"level": "WARN", "message": "warning_code=api_key_fingerprint_mismatch "
                         "DD_API_KEY mismatch between fetch and uploader"})
    elif fingerprint.status == "evp_skipped":
        messages.append({"level": "WARN", "message": "warning_code=api_key_fingerprint_evp_skipped DD_API_KEY "
                         "fingerprint present but uploader is in EVP mode; check skipped"})
    else:
        messages.append({"level": "DEBUG", "message": f"DD_API_KEY fingerprint check status={fingerprint.status}"})
    warnings = list(dict.fromkeys(resources.warning_codes + codeowners.warnings
                                  + ((fingerprint.warning_code,) if fingerprint.warning_code else ())))
    return {
        "contexts": names.values,
        "context_selection": selection,
        "primary_context": primary,
        "context_records": [{"repo_key": record.repo_key, "context": names.name(record.values)} for record in records],
        "telemetry_facts_paths": [str(path) for path in resources.telemetry_facts_paths],
        "codeowners_file": _path(codeowners.source_path),
        "warning_codes": warnings,
        "messages": messages,
    }


def _log_level(logger: logging.Logger) -> str:
    """The uploader logger's level, which --debug or the log level set."""
    level = logger.getEffectiveLevel()
    for name, threshold in (("DEBUG", logging.DEBUG), ("INFO", logging.INFO), ("WARN", logging.WARNING)):
        if level <= threshold:
            return name
    return "ERROR"


def _config_request(config: UploaderConfig, endpoints: EndpointSet, expected_targets: tuple[str, ...],
                    execroot_roots: list[str], output_base_roots: list[str], log_level: str) -> dict[str, Any]:
    return {
        "workspace": str(config.workspace),
        "dry_run": config.dry_run,
        "agentless": endpoints.agentless,
        "validate_enrichment": config.validate_enrichment,
        "log_level": log_level,
        "quiescent_sec": config.quiescent_sec,
        "max_wait_sec": config.max_wait_sec,
        "max_depth": config.max_depth,
        "fail_on_error": config.fail_on_error,
        "keep_payloads": config.keep_payloads,
        "filter_prefix": config.filter_prefix,
        "gzip_payloads": config.gzip_payloads,
        "workers": config.workers,
        "workers_explicit": config.workers_explicit,
        "expected_enriched_tags": list(config.expected_enriched_tags),
        "expected_targets": list(expected_targets),
        "bep_json_files": [str(path) for path in config.bep_json_files],
        "freshness_source": config.freshness_source,
        "freshness_mode": config.freshness_mode,
        "freshness_disabled_explicitly": config.freshness_disabled_explicitly,
        "execution_log_json": _path(config.execution_log_json),
        "artifact_source": config.artifact_source,
        "remote_artifacts": config.remote_artifacts,
        "artifact_staging_dir": str(config.artifact_staging_dir),
        "bep_artifact_downloader": _path(config.bep_artifact_downloader),
        "bep_artifact_downloader_timeout_sec": config.bep_artifact_downloader_timeout_sec,
        "report_json": _path(config.report_json),
        "testlogs_dir": _path(config.testlogs_dir),
        "ci": config.ci,
        "retained_outputs_dir": _path(config.retained_outputs_dir),
        "wrapper_temp_root": _path(config.wrapper_temp_root),
        "retention_status_file": _path(config.retention_status_file),
        "rules_version": config.rule.rules_version,
        "uploader_backend": config.uploader_backend,
        "batch_test_payloads": config.rule.batch_test_payloads,
        "execroot_roots": execroot_roots,
        "output_base_roots": output_base_roots,
    }


def _artifact_roots(config: UploaderConfig, resolver: RunfilesResolver) -> tuple[list[str], list[str]]:
    """The doctor's execroot and output base roots, for BEP artifact references."""
    if not config.bep_json_files:
        return [], []
    from .freshness import FreshnessError, _load_doctor_runtime, _resolve_doctor_runtime

    try:
        doctor = _load_doctor_runtime(_resolve_doctor_runtime(config, resolver), [])
    except (FreshnessError, OSError, ImportError):
        return [], []
    return [str(root) for root in doctor._execroot_roots()], [str(root) for root in doctor._output_base_roots()]


def _validation_request(config: UploaderConfig, resolver: RunfilesResolver,
                        logger: logging.Logger) -> dict[str, Any] | None:
    """The doctor's configuration, for its output checks, when the rule names one."""
    document = load_doctor_config(config, resolver, logger)
    if document is None:
        return None
    return {"config": document, "report_json": _path(config.doctor_report_json)}


def run_post_process(
    config: UploaderConfig,
    *,
    resolver: RunfilesResolver,
    endpoints: EndpointSet,
    logger: logging.Logger,
    ddtest: Path,
    load_resources: Any,
    stream: TextIO | None = None,
) -> int | None:
    """Run the invocation with ddtest; None leaves it to the Python uploader."""
    if os.name == "nt":
        # ddtest leaves Windows paths to the Python uploader.
        return None
    preflight_error = ""
    expected_targets: tuple[str, ...] = ()
    resources_request: dict[str, Any] = {}
    try:
        validate_proxy_environment(config.proxy_environment)
        expected_targets = load_expected_targets(
            static_targets=config.rule.expected_targets,
            expected_targets_file_paths=(config.rule.expected_targets_file_path,
                                         config.rule.expected_targets_file_short_path),
            resolver=resolver,
            runtime_targets=config.runtime_expected_targets,
            runtime_targets_file=config.runtime_expected_targets_file,
            runtime_selection=config.rule.runtime_selection,
        ).targets
        resources = load_resources(config, resolver, logger)
        resources_request = _resources_request(config, endpoints, resources, logger)
    except _PREFLIGHT_ERRORS as exc:
        preflight_error = str(exc)
    execroot_roots, output_base_roots = _artifact_roots(config, resolver)
    request = {
        "schema_version": 1,
        "config": _config_request(config, endpoints, expected_targets, execroot_roots, output_base_roots,
                                  _log_level(logger)),
        "resources": resources_request or {"contexts": {}, "warning_codes": [], "messages": []},
    }
    if preflight_error:
        request["preflight_error"] = preflight_error
    validation = _validation_request(config, resolver, logger)
    if validation is not None:
        request["validation"] = validation
    try:
        environment = _environment(os.environ, _Settings(config.api_key), endpoints)
    except Exception as exc:  # noqa: BLE001 - an unexpected endpoint leaves the run to Python.
        logger.debug("ddtest post-process unavailable: %s", exc)
        return None
    try:
        completed = subprocess.run(
            [str(ddtest), "instrument", "bazel", "post-process"],
            input=json.dumps(request), capture_output=True, text=True, encoding="utf-8", errors="replace",
            env=environment, check=False,
        )
    except OSError as exc:
        logger.warning("warning_code=ddtest_post_process_unavailable using the Python uploader: %s", exc)
        return None
    except KeyboardInterrupt:
        return 130
    if completed.returncode == POST_PROCESS_FALLBACK:
        logger.debug("ddtest left this invocation to the Python uploader")
        return None
    (stream if stream is not None else sys.stdout).write(completed.stdout)
    _log_stream(logger).write(completed.stderr)
    return completed.returncode


def _log_stream(logger: logging.Logger) -> TextIO:
    """Where the uploader's logger writes, for ddtest's messages."""
    for handler in logger.handlers:
        handler_stream = getattr(handler, "stream", None)
        if handler_stream is not None:
            return handler_stream
    return sys.stderr
