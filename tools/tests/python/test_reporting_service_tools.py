#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise reporting-service policy in the native rollback uploaders."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from uploader_test_support import resolve_runfile


def _block(text: str, start: str, end: str) -> str:
    return text[text.index(start):text.index(end, text.index(start))]


class ReportingServiceToolsTests(unittest.TestCase):
    def test_powershell_json_copy_preserves_empty_and_single_item_arrays(self) -> None:
        pwsh = shutil.which("pwsh")
        if not pwsh:
            self.skipTest("PowerShell is unavailable")
        template = resolve_runfile("tools/core/uploader_powershell_runtime.ps1.tpl")
        source = {"empty": [], "one": [{"tags": ["a"], "points": [[1, 2]]}], "many": [1, 2]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source.json").write_text(json.dumps(source), encoding="utf-8")
            script = '''$ErrorActionPreference='Stop'
$names=@('Convert-ToMutableObject','Ensure-Hashtable','Get-MapValue')
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)
foreach ($function in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names},$true)) { Invoke-Expression $function.Extent.Text }
$payload=Ensure-Hashtable (Get-Content -LiteralPath $args[1] -Raw | ConvertFrom-Json)
ConvertTo-Json -InputObject $payload -Depth 100 -Compress
'''
            (root / "test.ps1").write_text(script, encoding="utf-8")
            result = subprocess.run(
                [pwsh, "-NoProfile", "-File", str(root / "test.ps1"), str(template), str(root / "source.json")],
                capture_output=True, text=True, timeout=20, check=False,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(source, json.loads(result.stdout))

    def _enrich(
        self, runtime: str, service: str, *, mismatch: bool = False,
        target_array: bool = False, context_array: bool = False,
    ):
        if runtime == "bash" and os.name == "nt":
            self.skipTest("The Bash rollback is supported on Unix only")
        suffix = "sh.tpl" if runtime == "bash" else "ps1.tpl"
        template = resolve_runfile(f"tools/core/uploader_{runtime}_runtime.{suffix}")
        tool = shutil.which("bash" if runtime == "bash" else "pwsh")
        if not tool:
            self.skipTest(runtime + " is unavailable")
        if runtime == "bash" and not shutil.which("jq"):
            self.skipTest("jq is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = {"topt.sync.repository_name": "repo", "service.name": service, "runtime.name": "go"}
            metadata = {
                "bazel.target": "//pkg:test", "bazel.test_optimization.repo_name": "repo",
                "bazel.test_optimization.service_name": "wrong" if mismatch else service,
                "bazel.test_optimization.runtime_name": "go",
            }
            if target_array:
                metadata["bazel.test_optimization.service_name"] = [service]
            if context_array:
                context["service.name"] = [service]
            kinds = ("test", "test_suite_end", "test_module_end", "test_session_end", "span", None)
            events = [
                {"type": kind, "content": {"type": "test", "service": "application",
                    "meta": {"_dd.test.is_user_provided_service": "false"}}}
                for kind in kinds
            ]
            events += [
                {"type": "span", "content": {"type": "web", "service": "application-explicit",
                    "meta": {"test.name": "not-ci"}}},
                {"type": "future", "content": {"type": "test", "service": "future-service"}},
            ]
            source = json.dumps({"metadata": {"*": {"service": "global-conflict"}}, "events": events})
            (root / "source.json").write_text(source, encoding="utf-8")
            (root / "context.json").write_text(json.dumps(context), encoding="utf-8")
            (root / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            if runtime == "bash":
                functions = _block(template.read_text(encoding="utf-8"), "# Merge flat sidecar metadata", "# Emit basic startTime")
                script = '''set -euo pipefail
log() { echo "$*" >&2; }; dbg() { :; }; inject_codeowners_tags() { :; }
select_context_json_for_payload() { echo "$ROOT/context.json"; }
find_bazel_target_metadata() { echo "$ROOT/metadata.json"; }
JQ_AVAILABLE=1; RUNTIME_ID=runtime; RULES_VERSION=rules; TMP_PAYLOAD_DIR="$ROOT"
''' + functions + '\nenrich_with_context "$ROOT/source.json" "$ROOT/out.json"\n'
                command = [tool, "-c", script]
            else:
                script = '''$ErrorActionPreference = 'Stop'
$names = @('Convert-ToMutableObject','Ensure-Hashtable','Get-MapValue','Merge-FlatMetadataIntoEvent','Merge-With-Context','Write-Utf8NoBomFile','Get-ReportingService','Test-CiReportingEvent')
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$tokens, [ref]$errors)
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)) { Invoke-Expression $function.Extent.Text }
function Dbg($message) {}
function Resolve-ContextJsonForPayload($file) { return "$env:ROOT/context.json" }
function Get-ContextInfo($file) { return @{Object=(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)} }
function Get-BazelTargetMetadataPath($file) { return "$env:ROOT/metadata.json" }
function Get-EventSourcePath($event) { return '' }
$script:CodeOwnersStats = @{scanned=0;skipped_missing_source=0}; $script:DebugMode=$false; $script:RuntimeId='runtime'; $script:RulesVersion='rules'
Merge-With-Context "$env:ROOT/source.json" "$env:ROOT/out.json"
'''
                script_path = root / "test.ps1"
                script_path.write_text(script, encoding="utf-8")
                command = [tool, "-NoProfile", "-File", str(script_path), str(template)]
            result = subprocess.run(
                command, env={**os.environ, "ROOT": directory},
                capture_output=True, text=True, timeout=20, check=False,
            )
            self.assertEqual(source, (root / "source.json").read_text(encoding="utf-8"))
            if mismatch or target_array or context_array:
                self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn("reporting service identity mismatch", result.stdout + result.stderr)
                return
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            payload = json.loads((root / "out.json").read_text(encoding="utf-8"))
            self.assertEqual(
                [service] * len(kinds) + ["application-explicit", "future-service"],
                [event["content"]["service"] for event in payload["events"]],
            )
            self.assertTrue(all(
                event["content"]["meta"]["_dd.test.is_user_provided_service"] == "false"
                for event in payload["events"][:len(kinds)]
            ))
            self.assertNotIn("service", payload["metadata"]["*"])

    def test_native_service_policy_and_identity_failures(self) -> None:
        for runtime in ("bash", "powershell"):
            for service in ("tests-one", "tests-two"):
                with self.subTest(runtime=runtime, service=service):
                    self._enrich(runtime, service)
            with self.subTest(runtime=runtime, mismatch=True):
                self._enrich(runtime, "tests-one", mismatch=True)

    def test_powershell_rejects_array_identities_on_both_sides(self) -> None:
        for field in ("target", "context"):
            with self.subTest(field=field):
                self._enrich("powershell", "tests-one", target_array=field == "target", context_array=field == "context")

    def test_native_telemetry_keeps_two_target_services_and_facts_separate(self) -> None:
        for runtime in ("bash", "powershell"):
            with self.subTest(runtime=runtime):
                self._telemetry(runtime)

    def test_native_telemetry_rejects_mismatched_source_without_suppressing_valid_source(self) -> None:
        for runtime in ("bash", "powershell"):
            with self.subTest(runtime=runtime):
                self._telemetry(runtime, mismatch=True)

    def test_native_dry_run_rejects_mismatched_telemetry(self) -> None:
        for runtime in ("bash", "powershell"):
            with self.subTest(runtime=runtime):
                self._telemetry(runtime, mismatch=True, dry_run=True)

    def test_native_telemetry_continues_after_an_invalid_source(self) -> None:
        for runtime in ("bash", "powershell"):
            with self.subTest(runtime=runtime):
                self._telemetry(runtime, mismatch=True, reverse_order=True)

    def test_native_telemetry_requires_an_application_object_for_declared_identity(self) -> None:
        for runtime in ("bash", "powershell"):
            for application in ("null", "array"):
                with self.subTest(runtime=runtime, application=application):
                    self._telemetry(runtime, invalid_application=application)

    def test_powershell_uses_a_valid_sibling_for_same_service_facts(self) -> None:
        self._telemetry("powershell", invalid_application="array", same_service=True)

    def test_bash_reports_the_service_without_python(self) -> None:
        self._telemetry("bash", without_python=True)

    def _telemetry(
        self, runtime: str, *, mismatch: bool = False, dry_run: bool = False,
        invalid_application: str | None = None, same_service: bool = False,
        without_python: bool = False, reverse_order: bool = False,
    ) -> None:
        if runtime == "bash" and os.name == "nt":
            self.skipTest("The Bash rollback is supported on Unix only")
        tool = shutil.which("bash" if runtime == "bash" else "pwsh")
        if not tool or (runtime == "bash" and not shutil.which("jq")):
            self.skipTest(runtime + " dependencies are unavailable")
        suffix = "sh.tpl" if runtime == "bash" else "ps1.tpl"
        template = resolve_runfile(f"tools/core/uploader_{runtime}_runtime.{suffix}")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_bytes = {}
            for name in ("one", "two"):
                reporting_service = "tests-one" if same_service else "tests-" + name
                output = root / name
                source = output / "payloads/telemetry/input.json"
                source.parent.mkdir(parents=True)
                payload = {"api_version": "v2", "request_type": "message-batch", "runtime_id": "same-runtime",
                    "seq_id": 8, "application": {"service_name": "application", "language_name": "go", "env": "none"},
                    "payload": [{"request_type": "app-heartbeat", "payload": {}}]}
                if invalid_application and name == "two":
                    payload["application"] = [payload["application"]] if invalid_application == "array" else None
                source.write_text(json.dumps(payload), encoding="utf-8")
                source_bytes[source] = source.read_bytes()
                (output / "context.json").write_text(json.dumps({"topt.sync.repository_name": name,
                    "service.name": reporting_service, "runtime.name": "go"}), encoding="utf-8")
                service = "wrong" if mismatch and name == "two" else reporting_service
                (output / "metadata.json").write_text(json.dumps({"bazel.test_optimization.repo_name": name,
                    "bazel.test_optimization.service_name": service, "bazel.test_optimization.runtime_name": "go"}), encoding="utf-8")
                (output / "facts.json").write_text(json.dumps({"schema_version": 1, "service_name": reporting_service,
                    "runtime_name": "go", "counts": [{"name": "metric-" + name, "value": 1, "tags": []}]}), encoding="utf-8")
            if runtime == "bash":
                text = template.read_text(encoding="utf-8")
                functions = "\n".join([
                    _block(text, "# Merge flat sidecar metadata", "# Emit basic startTime"),
                    _block(text, "lookup_telemetry_plan_body()", "# Remove temporary augmented"),
                    _block(text, "rewrite_telemetry_provider_tags()", "# Track per-payload upload report counters"),
                    _block(text, "upload_single_telemetry()", "# Handle upload all tests"),
                    _block(text, "upload_all_telemetry()", "\nprepare_expected_targets\n"),
                    _block(text, "cleanup_file()", "# Handle validate payload"),
                ])
                script = '''set -euo pipefail
log() { echo "$*" >&2; }; dbg() { :; }
select_context_json_for_payload() { echo "${1%/payloads/*}/context.json"; }
find_bazel_target_metadata() { echo "${1%/payloads/*}/metadata.json"; }
load_telemetry_provider_suffix() { TELEMETRY_PROVIDER_SUFFIX=github; }
resolve_telemetry_facts_sources() { printf '%s\\n' "$ROOT/one/facts.json" "$ROOT/two/facts.json"; }
list_all_sorted_telemetry_files() { printf '%s\\n' "$ROOT/one/payloads/telemetry/input.json" "$ROOT/two/payloads/telemetry/input.json"; }
build_telemetry_headers() { TELEMETRY_HDRS=('X-Fixture: true'); }
curl_agentless() {
  local origin="${display_file%/payloads/*}"
  while (( $# )); do
    if [[ "$1" == --data-binary ]]; then cp "${2#@}" "$ROOT/sent-${origin##*/}.json"; fi
    shift
  done
  echo 200
}
TMP_PAYLOAD_DIR="$ROOT"; JQ_AVAILABLE=1; AGENTLESS=1; DEBUG=0; TELEMETRY_URL=http://unused; CURL_RETRY_FLAGS=(--retry 0)
''' + functions + '''
payload_dir_has_replayable_files() { return 0; }; test_output_dir_is_freshness_eligible() { return 0; }
list_sorted_payload_files() { echo "$1/input.json"; }; mark_fresh_output_handled() { :; }
cleanup_telemetry_augmentation_plan() { :; }
if [[ "$REVERSE_CASE" == 1 ]]; then
  TEST_OUTPUTS_CACHE="$(printf '%s\\n' "$ROOT/two" "$ROOT/one")"
else
  TEST_OUTPUTS_CACHE="$(printf '%s\\n' "$ROOT/one" "$ROOT/two")"
fi
DRY_RUN="$DRY_CASE"; KEEP_PAYLOADS=1; UPLOAD_FAILURES=0; REPORT_TELEMETRY_PROCESSED=0; REPORT_TELEMETRY_FAILED=0
upload_all_telemetry
exit "$(( UPLOAD_FAILURES != 0 ))"
'''
                command = [tool, "-c", script]
            else:
                script = '''$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$tokens, [ref]$errors)
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { Invoke-Expression $function.Extent.Text }
function Dbg($message) {}
function Log($message) { [Console]::Error.WriteLine($message) }
function Resolve-ContextJsonForPayload($file) { return ((Split-Path (Split-Path (Split-Path $file))) + '/context.json') }
function Get-ContextInfo($file) { return @{Object=(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)} }
function Get-BazelTargetMetadataPath($file) { return ((Split-Path (Split-Path (Split-Path $file))) + '/metadata.json') }
function Get-ContextCiProviderName { return 'github' }
function Resolve-TelemetryFactsSources { return @("$env:ROOT/one/facts.json", "$env:ROOT/two/facts.json") }
function Get-AllSortedTelemetryFiles { return @(Get-Item "$env:ROOT/one/payloads/telemetry/input.json", "$env:ROOT/two/payloads/telemetry/input.json") }
function Get-TelemetryHeaders($path) { return @{'X-Fixture'='true'} }
function Send-PostRawJson($url,$headers,$body) {
  $origin=Split-Path -Leaf (Split-Path (Split-Path (Split-Path $DisplayPath)))
  Copy-Item -LiteralPath $body -Destination "$env:ROOT/sent-$origin.json"
  return $true
}
$script:TmpPayloadDir=$env:ROOT; $script:DebugMode=$false; $TelemetryUrl='http://unused'
function Test-PayloadDirHasReplayableFiles($path) { return $true }
function Test-OutputDirFreshnessEligible($path) { return $true }
function Get-SortedPayloadFiles($path) { return Get-Item "$path/input.json" }
function Mark-FreshOutputHandled($path) {}
$script:TestOutputsCache=@(Get-Item "$env:ROOT/one", "$env:ROOT/two")
if ($env:REVERSE_CASE -eq '1') { [Array]::Reverse($script:TestOutputsCache) }
$script:DryRun=($env:DRY_CASE -eq '1'); $script:KeepPayloads=$true
$script:UploadFailures=0; $script:ReportTelemetryProcessed=0; $script:ReportTelemetryFailed=0
Upload-AllTelemetry
if ($script:UploadFailures) { exit 1 }; exit 0
'''
                script_path = root / "test.ps1"
                script_path.write_text(script, encoding="utf-8")
                command = [tool, "-NoProfile", "-File", str(script_path), str(template)]
            environment = {
                **os.environ, "ROOT": directory, "DRY_CASE": str(int(dry_run)),
                "REVERSE_CASE": str(int(reverse_order)),
            }
            if without_python:
                bin_directory = root / "bin"
                bin_directory.mkdir()
                for name in ("jq", "cp", "mktemp", "rm", "awk"):
                    executable = shutil.which(name)
                    if not executable:
                        self.skipTest(name + " is unavailable")
                    (bin_directory / name).symlink_to(executable)
                environment["PATH"] = str(bin_directory)
            result = subprocess.run(
                command, env=environment,
                capture_output=True, text=True, timeout=25, check=False,
            )
            if mismatch or invalid_application:
                self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
                message = "telemetry application identity is missing" if invalid_application else "reporting service identity mismatch"
                self.assertIn(message, result.stdout + result.stderr)
                self.assertFalse((root / "sent-two.json").exists())
            else:
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            expected_names = ("one",) if mismatch or invalid_application else ("one", "two")
            if dry_run:
                expected_names = ()
            for name in expected_names:
                body = json.loads((root / ("sent-" + name + ".json")).read_text(encoding="utf-8"))
                self.assertEqual("tests-one" if same_service else "tests-" + name, body["application"]["service_name"])
                self.assertEqual("same-runtime", body["runtime_id"])
                self.assertEqual(8, body["seq_id"])
                metrics = [
                    series for message in body["payload"]
                    if message["request_type"] == "generate-metrics"
                    for series in message["payload"]["series"]
                ]
                expected_metrics = ["metric-one", "metric-two"] if same_service else ["metric-" + name]
                if without_python:
                    expected_metrics = []  # Existing optional augmentation needs Python.
                self.assertEqual(expected_metrics, sorted(series["metric"] for series in metrics))
            if dry_run:
                self.assertFalse(list(root.glob("sent-*.json")))
            for source, expected in source_bytes.items():
                self.assertEqual(expected, source.read_bytes())

    def test_bash_requires_jq_before_upload_or_enrichment(self) -> None:
        if os.name == "nt":
            self.skipTest("The Bash rollback is supported on Unix only")
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("Bash is unavailable")
        template = resolve_runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        startup = _block(template, "# Load context.json for enrichment", "# CODEOWNERS state")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [bash, "-c", 'log() { echo "$*" >&2; }; dbg() { :; }; PRIMARY_CONTEXT_JSON=\n' + startup],
                env={**os.environ, "PATH": directory},
                capture_output=True, text=True, timeout=15, check=False,
            )
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("requires jq", result.stderr)


if __name__ == "__main__":
    unittest.main()
