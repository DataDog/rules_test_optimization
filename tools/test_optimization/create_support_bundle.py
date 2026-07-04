#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Create a redacted Datadog Test Optimization support bundle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys
import urllib.parse
import zipfile
from pathlib import Path
from typing import Any


def _load_render_summary_from_reports() -> Any:
    try:
        from render_report_summary import render_summary_from_reports as renderer

        return renderer
    except ImportError:
        pass

    candidates = []
    env_renderer = os.environ.get("DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_RENDERER", "")
    if env_renderer:
        candidates.append(Path(env_renderer))
    candidates.append(Path(__file__).with_name("render_report_summary.py"))
    renderer_path = next((path for path in candidates if path.exists()), None)
    if renderer_path is None:
        return None
    spec = importlib.util.spec_from_file_location("render_report_summary", str(renderer_path))
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return getattr(module, "render_summary_from_reports", None)


render_summary_from_reports = _load_render_summary_from_reports()

SECRET_KEY_RE = re.compile(r"(api[_-]?key|token|secret|password|credential|authorization)", re.I)
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?P<prefix>(?:^|[\s,;])(?:--(?:test_env|repo_env|action_env|client_env)=)?"
    r"(?=[A-Za-z_][A-Za-z0-9_]*=)"
    r"(?=[A-Za-z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTHORIZATION)[A-Za-z0-9_]*=)"
    r"[A-Za-z_][A-Za-z0-9_]*=)"
    r"(?P<value>.*?)(?=(?:[\s,;](?:--(?:test_env|repo_env|action_env|client_env)=)?"
    r"(?=[A-Za-z_][A-Za-z0-9_]*=)[A-Za-z_][A-Za-z0-9_]*=)|$)",
    re.I,
)
HTTP_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.I)
SENSITIVE_QUERY_RE = re.compile(
    r"([?&])([^=\s\"']*(?:sig|signature|token|credential|expires|x-amz-)[^=\s\"']*)=[^&\s\"']*",
    re.I,
)
MAX_BEP_LABELS = 100
MAX_JSON_LIST_ITEMS = 100
MAX_JSON_STRING_CHARS = 20000


def _path_aliases(path: Path) -> list[str]:
    values: list[str] = []
    for candidate in (path, path.absolute(), path.resolve()):
        text = str(candidate)
        if text and text not in values:
            values.append(text)
        if text.startswith("/private/"):
            alias = text[len("/private") :]
            if alias and alias not in values:
                values.append(alias)
        elif text.startswith("/var/"):
            alias = "/private" + text
            if alias not in values:
                values.append(alias)
    return values


def _redact_http_url(match: re.Match[str]) -> str:
    value = match.group(0)
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return "http://redacted-invalid-url" if value.lower().startswith("http://") else "https://redacted-invalid-url"
    host = parsed.hostname or ""
    if not host:
        return f"{parsed.scheme}://redacted-invalid-url"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError:
        port = None
    netloc = f"{host}:{port}" if port is not None else host
    return urllib.parse.urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))


def redact_text(
    value: str,
    *,
    workspace_root: Path | None,
    output_base: Path | None,
    tmp_root: Path | None,
) -> str:
    text = value
    replacements = []
    for path, token in (
        (workspace_root, "<workspace>"),
        (output_base, "<output_base>"),
        (tmp_root, "<tmp>"),
    ):
        if path is None:
            continue
        replacements.extend((alias, token) for alias in _path_aliases(path))
    for path, token in sorted(
        replacements,
        key=lambda item: len(item[0]),
        reverse=True,
    ):
        text = text.replace(path, token)
    text = HTTP_URL_RE.sub(_redact_http_url, text)
    text = SENSITIVE_QUERY_RE.sub(lambda match: f"{match.group(1)}{match.group(2)}=<redacted>", text)
    text = SECRET_ASSIGNMENT_RE.sub(lambda match: f"{match.group('prefix')}<redacted>", text)
    return text


def redact_json(
    value: Any,
    *,
    workspace_root: Path | None,
    output_base: Path | None,
    tmp_root: Path | None,
) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, child in value.items():
            if SECRET_KEY_RE.search(str(key)):
                result[str(key)] = "<redacted>"
            else:
                result[str(key)] = redact_json(
                    child,
                    workspace_root=workspace_root,
                    output_base=output_base,
                    tmp_root=tmp_root,
                )
        return result
    if isinstance(value, list):
        return [
            redact_json(item, workspace_root=workspace_root, output_base=output_base, tmp_root=tmp_root)
            for item in value
        ]
    if isinstance(value, str):
        return redact_text(value, workspace_root=workspace_root, output_base=output_base, tmp_root=tmp_root)
    return value


def bound_json(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): bound_json(child) for key, child in value.items()}
    if isinstance(value, list):
        bounded = [bound_json(item) for item in value[:MAX_JSON_LIST_ITEMS]]
        if len(value) > MAX_JSON_LIST_ITEMS:
            bounded.append({
                "truncated": True,
                "total_items": len(value),
                "omitted_items": len(value) - MAX_JSON_LIST_ITEMS,
            })
        return bounded
    if isinstance(value, str) and len(value) > MAX_JSON_STRING_CHARS:
        omitted = len(value) - MAX_JSON_STRING_CHARS
        return value[:MAX_JSON_STRING_CHARS] + f"...<truncated {omitted} chars>"
    return value


def _load_json_object(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return value


def _safe_archive_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return safe or "file"


def _report_paths(report_dir: Path, explicit_reports: list[Path]) -> tuple[list[Path], list[str]]:
    candidates = [
        *[(path, True) for path in explicit_reports],
        (report_dir / "doctor-report.json", False),
        (report_dir / "uploader-dry-run-report.json", False),
        (report_dir / "uploader-upload-report.json", False),
    ]
    result = []
    warnings = []
    seen: set[Path] = set()
    for path, explicit in candidates:
        resolved = path.resolve()
        if resolved in seen:
            continue
        if not path.exists():
            if explicit:
                warnings.append(f"Report file was missing and skipped: {_safe_archive_name(path.name)}")
            continue
        seen.add(resolved)
        result.append(path)
    return result, warnings


def _report_record(archive_path: str, report: dict[str, Any]) -> dict[str, Any]:
    result = report.get("result", {})
    return {
        "path": archive_path,
        "tool": report.get("tool", "unknown"),
        "status": result.get("status", report.get("status", "unknown")),
        "reason_code": result.get("reason_code", "unknown"),
    }


def _primary_reason(reports: list[dict[str, Any]]) -> str:
    for report in reports:
        result = report.get("result", {})
        status = result.get("status", report.get("status"))
        reason_code = str(result.get("reason_code", "unknown"))
        if status not in ("ok", "success") and reason_code != "ok":
            return reason_code
    for report in reversed(reports):
        reason_code = str(report.get("result", {}).get("reason_code", "unknown"))
        if reason_code != "unknown":
            return reason_code
    return "unknown"


def _render_summary(bundled_reports: list[dict[str, Any]], diagnostics: dict[str, Any]) -> str:
    if render_summary_from_reports is not None and bundled_reports:
        text = render_summary_from_reports(bundled_reports)
    else:
        text = "# Datadog Test Optimization Upload Diagnostics\n"
    summary = diagnostics["summary"]
    return (
        text.rstrip()
        + "\n\n"
        + "## Support bundle\n\n"
        + f"- Reports included: {summary['report_count']}\n"
        + f"- BEP summaries included: {summary['bep_summary_count']}\n"
        + f"- Primary reason: {summary['primary_reason_code']}\n"
    )


def _field(obj: Any, camel: str, snake: str, default: Any = None) -> Any:
    if not isinstance(obj, dict):
        return default
    if camel in obj:
        return obj[camel]
    if snake in obj:
        return obj[snake]
    return default


def _strip_file_uri(value: str) -> str:
    if not value.lower().startswith("file://"):
        return value
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "file":
        return value
    path = urllib.parse.unquote(parsed.path or "")
    if parsed.netloc and parsed.netloc not in {"", "localhost"}:
        path = f"//{parsed.netloc}{path}"
    return path


def _is_remote_uri(value: str) -> bool:
    if not value:
        return False
    lowered = value.lower()
    if lowered.startswith("file://"):
        return False
    if re.match(r"^[a-z][a-z0-9+.-]*://", lowered):
        return True
    if lowered.startswith("blobs/") or re.match(r"^[0-9a-f]{32,}/[0-9]+$", lowered):
        return True
    return False


def _path_prefix_name_candidate(output: dict[str, Any]) -> str:
    path_prefix = _field(output, "pathPrefix", "path_prefix", [])
    name = output.get("name")
    if not isinstance(path_prefix, list) or not isinstance(name, str) or not name:
        return ""
    parts = [part for part in path_prefix if isinstance(part, str) and part]
    return "/".join(parts + [name]) if parts else ""


def _bep_file_candidates(output: Any) -> list[str]:
    if isinstance(output, str):
        return [output]
    if not isinstance(output, dict):
        return []
    values = []
    for key in ("uri", "path", "name"):
        value = output.get(key)
        if isinstance(value, str) and value:
            values.append(value)
    reconstructed = _path_prefix_name_candidate(output)
    if reconstructed:
        values.append(reconstructed)
    return values


def _uploadable_output_name(output: Any, candidates: list[str]) -> str:
    if isinstance(output, dict):
        name = output.get("name")
        if name in ("test.outputs", "outputs.zip"):
            return str(name)
    for candidate in candidates:
        normalized = _strip_file_uri(candidate).replace("\\", "/").lower().rstrip("/")
        if normalized == "outputs.zip" or normalized.endswith("/outputs.zip"):
            return "outputs.zip"
        if (
            normalized == "test.outputs"
            or "/test.outputs/" in normalized
            or normalized.endswith("/test.outputs")
            or normalized.endswith("/test.log")
            or normalized.endswith("/test.xml")
        ):
            return "test.outputs"
    return ""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def summarize_bep(path: Path) -> dict[str, Any]:
    labels: set[str] = set()
    test_result_events = 0
    cached_outputs = 0
    uploadable_outputs = 0
    remote_only_outputs = 0
    outputs_by_name: dict[str, int] = {}

    with path.open("r", encoding="utf-8-sig") as fh:
        for line in fh:
            if not line.strip():
                continue
            event = json.loads(line)
            event_id = event.get("id") if isinstance(event, dict) else {}
            test_result_id = _field(event_id, "testResult", "test_result")
            if not isinstance(test_result_id, dict):
                continue
            test_result = _field(event, "testResult", "test_result")
            if not isinstance(test_result, dict):
                continue
            test_result_events += 1
            label = test_result_id.get("label")
            if isinstance(label, str):
                labels.add(label)
            execution_info = _field(test_result, "executionInfo", "execution_info", {})
            cached = bool(_field(test_result, "cachedLocally", "cached_locally", False)) or bool(
                _field(execution_info, "cachedRemotely", "cached_remotely", False)
            )
            outputs = _field(test_result, "testActionOutput", "test_action_output", [])
            for output in outputs if isinstance(outputs, list) else []:
                candidates = _bep_file_candidates(output)
                name = _uploadable_output_name(output, candidates)
                if not name:
                    continue
                uploadable_outputs += 1
                outputs_by_name[name] = outputs_by_name.get(name, 0) + 1
                if cached:
                    cached_outputs += 1
                if not cached and any(_is_remote_uri(candidate) for candidate in candidates):
                    remote_only_outputs += 1

    sorted_labels = sorted(labels)
    return {
        "source_sha256": _sha256(path),
        "test_result_events": test_result_events,
        "labels": sorted_labels[:MAX_BEP_LABELS],
        "labels_total": len(sorted_labels),
        "labels_truncated": len(sorted_labels) > MAX_BEP_LABELS,
        "cached_outputs": cached_outputs,
        "uploadable_outputs": uploadable_outputs,
        "remote_only_outputs": remote_only_outputs,
        "outputs_by_name": outputs_by_name,
    }


def _bep_summary_archive_path(index: int, path: Path) -> str:
    name = path.name
    if name.endswith(".bep.json"):
        name = name[: -len(".json")]
    elif name.endswith(".json"):
        name = name[: -len(".json")]
    return f"bep/{index}_{_safe_archive_name(name)}.summary.json"


def _unique_report_archive_path(path: Path, used_paths: set[str]) -> str:
    safe = _safe_archive_name(path.name)
    candidate = f"reports/{safe}"
    if candidate not in used_paths:
        used_paths.add(candidate)
        return candidate
    if safe.endswith(".json"):
        stem = safe[: -len(".json")]
        suffix = ".json"
    else:
        stem = safe
        suffix = ""
    index = 2
    while True:
        candidate = f"reports/{stem}_{index}{suffix}"
        if candidate not in used_paths:
            used_paths.add(candidate)
            return candidate
        index += 1


def _runtime_metadata(bazel: str) -> dict[str, Any]:
    metadata = {
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "bazel": bazel,
        "bazel_version": "unknown",
        "bazel_version_error": "",
    }
    try:
        completed = subprocess.run(
            [bazel, "--version"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        metadata["bazel_version_error"] = str(exc)
        return metadata
    if completed.returncode == 0:
        metadata["bazel_version"] = completed.stdout.strip()
    else:
        metadata["bazel_version_error"] = completed.stderr.strip()
    return metadata


def _redaction_manifest(
    workspace_root: Path | None,
    output_base: Path | None,
    tmp_root: Path | None,
) -> dict[str, Any]:
    return {
        "workspace_root": "<workspace>" if workspace_root is not None else "",
        "output_base": "<output_base>" if output_base is not None else "",
        "tmp_root": "<tmp>" if tmp_root is not None else "",
        "secret_keys": SECRET_KEY_RE.pattern,
        "secret_assignments": SECRET_ASSIGNMENT_RE.pattern,
        "http_url_redaction": HTTP_URL_RE.pattern,
        "sensitive_query_parameters": SENSITIVE_QUERY_RE.pattern,
        "raw_payloads_included": False,
        "raw_bep_included": False,
    }


def _diagnostics(
    report_records: list[dict[str, Any]],
    reports: list[dict[str, Any]],
    report_warnings: list[str],
    bep_summaries: list[dict[str, Any]],
    bep_warnings: list[str],
    files: list[str],
) -> dict[str, Any]:
    payloads = {"tests": 0, "coverage": 0, "telemetry": 0}
    for report in reports:
        discovered = report.get("payloads", {}).get("discovered") or report.get("summary", {}).get("payloads") or {}
        for key in payloads:
            try:
                payloads[key] = max(payloads[key], int(discovered.get(key, 0)))
            except (TypeError, ValueError):
                pass

    warnings = [*report_warnings, *bep_warnings]
    if not report_records:
        warnings.append("No usable doctor or uploader reports were included.")
    for index, summary in enumerate(bep_summaries, start=1):
        remote_only = int(summary.get("remote_only_outputs", 0))
        if remote_only:
            warnings.append(f"BEP file {index} contained {remote_only} remote-only uploadable outputs.")

    missing_reports = not report_records
    failed = missing_reports or any(record["status"] not in ("ok", "success") for record in report_records)
    return {
        "schema_version": 1,
        "tool": "dd-test-optimization-support-bundle",
        "summary": {
            "status": "fail" if failed else "ok",
            "primary_reason_code": "missing_reports" if missing_reports else _primary_reason(reports),
            "report_count": len(reports),
            "bep_summary_count": len(bep_summaries),
            "payloads": payloads,
            "warnings": warnings,
        },
        "reports": report_records,
        "bep": bep_summaries,
        "bundle": {
            "files": files,
            "created_by": "tools/test_optimization/create_support_bundle.py",
        },
    }


def _write_zip_text(zf: zipfile.ZipFile, archive_path: str, text: str) -> None:
    info = zipfile.ZipInfo(archive_path)
    info.date_time = (1980, 1, 1, 0, 0, 0)
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, text.encode("utf-8"))


def create_bundle(args: argparse.Namespace) -> None:
    workspace_root = args.workspace_root.absolute() if args.workspace_root else None
    output_base = args.output_base.absolute() if args.output_base else None
    tmp_root = args.tmp_root.absolute() if args.tmp_root else None
    report_paths, report_warnings = _report_paths(args.report_dir, args.report_json)
    reports = []
    bundled_reports = []
    bep_summaries = []
    bep_warnings = []

    files: dict[str, str] = {}
    used_report_archive_paths: set[str] = set()
    report_records = []
    for path in report_paths:
        try:
            report = _load_json_object(path)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            report_warnings.append(
                f"Report file {_safe_archive_name(path.name)} was unreadable or malformed and was skipped ({type(exc).__name__})"
            )
            continue
        reports.append(report)
        redacted_report = redact_json(report, workspace_root=workspace_root, output_base=output_base, tmp_root=tmp_root)
        bounded_report = bound_json(redacted_report)
        archive_path = _unique_report_archive_path(path, used_report_archive_paths)
        report_records.append(_report_record(archive_path, bounded_report))
        bundled_reports.append(bounded_report)
        files[archive_path] = json.dumps(bounded_report, indent=2, sort_keys=True) + "\n"
    for index, path in enumerate(args.bep_json, start=1):
        archive_path = _bep_summary_archive_path(index, path)
        if not path.exists():
            bep_warnings.append(f"BEP file {index} was missing or unreadable and was skipped: {_safe_archive_name(path.name)}")
            continue
        try:
            summary = summarize_bep(path)
        except (OSError, json.JSONDecodeError) as exc:
            bep_warnings.append(
                f"BEP file {index} was missing or unreadable and was skipped: {_safe_archive_name(path.name)} ({type(exc).__name__})"
            )
            continue
        summary["path"] = archive_path
        summary = bound_json(summary)
        bep_summaries.append(summary)
        files[archive_path] = json.dumps(summary, indent=2, sort_keys=True) + "\n"

    if args.command_manifest_json and args.command_manifest_json.exists():
        command = bound_json(redact_json(
            _load_json_object(args.command_manifest_json),
            workspace_root=workspace_root,
            output_base=output_base,
            tmp_root=tmp_root,
        ))
        files["command/flags.json"] = json.dumps(command, indent=2, sort_keys=True) + "\n"

    runtime = bound_json(redact_json(
        _runtime_metadata(args.bazel),
        workspace_root=workspace_root,
        output_base=output_base,
        tmp_root=tmp_root,
    ))
    files["environment/runtime.json"] = json.dumps(runtime, indent=2, sort_keys=True) + "\n"

    files["redaction-manifest.json"] = json.dumps(
        _redaction_manifest(workspace_root, output_base, tmp_root),
        indent=2,
    ) + "\n"
    final_file_names = sorted([*files, "diagnostics.json", "summary.md"])
    diagnostics = _diagnostics(report_records, bundled_reports, report_warnings, bep_summaries, bep_warnings, final_file_names)
    files["summary.md"] = _render_summary(bundled_reports, diagnostics)
    files["diagnostics.json"] = json.dumps(diagnostics, indent=2, sort_keys=True) + "\n"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w") as zf:
        for archive_path in sorted(files):
            _write_zip_text(zf, archive_path, files[archive_path])


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--report-json", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bep-json", type=Path, action="append", default=[])
    parser.add_argument("--command-manifest-json", type=Path)
    parser.add_argument("--workspace-root", type=Path)
    parser.add_argument("--output-base", type=Path)
    parser.add_argument("--tmp-root", type=Path)
    parser.add_argument("--bazel", default="bazel")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    create_bundle(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
