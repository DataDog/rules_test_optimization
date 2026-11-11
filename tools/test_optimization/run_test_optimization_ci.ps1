# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Bazel = $(if ($env:BAZEL) { $env:BAZEL } else { "bazel" }),
  [string]$Config = $(if ($env:DD_TEST_OPTIMIZATION_BAZEL_CONFIG) { $env:DD_TEST_OPTIMIZATION_BAZEL_CONFIG } else { "test-optimization" }),
  [string]$DoctorTarget = $(if ($env:DD_TEST_OPTIMIZATION_DOCTOR_TARGET) { $env:DD_TEST_OPTIMIZATION_DOCTOR_TARGET } else { "//:dd_test_optimization_doctor" }),
  [string]$UploadTarget = $(if ($env:DD_TEST_OPTIMIZATION_UPLOAD_TARGET) { $env:DD_TEST_OPTIMIZATION_UPLOAD_TARGET } else { "//:dd_upload_payloads" }),
  [string]$DoctorReportJson = $(if ($env:DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON) { $env:DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON } else { "" }),
  [string]$UploaderReportJson = $(if ($env:DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON) { $env:DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON } else { "" }),
  [string]$ReportDir = $(if ($env:DD_TEST_OPTIMIZATION_REPORT_DIR) { $env:DD_TEST_OPTIMIZATION_REPORT_DIR } else { "" }),
  [string]$RetainedOutputsDir = $(if ($env:DD_TEST_OPTIMIZATION_RETAINED_OUTPUTS_DIR) { $env:DD_TEST_OPTIMIZATION_RETAINED_OUTPUTS_DIR } else { "" }),
  [string]$SupportBundle = $(if ($env:DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE) { $env:DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE } else { "" }),
  [string]$SupportBundleCollector = $(if ($env:DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR) { $env:DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR } else { "" }),
  [string[]]$TestFlag = @(),
  [switch]$Upload,
  [switch]$KeepTmp,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Targets = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SafeTargetName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Target
  )

  $safe = [System.Text.RegularExpressions.Regex]::Replace($Target, "[^A-Za-z0-9_.-]", "_")
  if ([string]::IsNullOrWhiteSpace($safe.Replace("_", ""))) {
    return "target"
  }
  return $safe
}

function Invoke-BazelCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Args
  )

  Write-Host ("+ {0} {1}" -f $Bazel, ($Args -join " "))
  & $Bazel @Args | ForEach-Object { Write-Host $_ }
  $exitCode = $LASTEXITCODE
  if ($null -eq $exitCode) {
    return 0
  }
  return [int]$exitCode
}

if ($Targets.Count -gt 0 -and $Targets[0] -eq "--") {
  if ($Targets.Count -eq 1) {
    $Targets = @()
  } else {
    $Targets = $Targets[1..($Targets.Count - 1)]
  }
}

if ($Targets.Count -eq 0) {
  $Targets = @("//...")
}

$tmpParent = if ($env:DD_TEST_OPTIMIZATION_TMPDIR) {
  $env:DD_TEST_OPTIMIZATION_TMPDIR
} else {
  [System.IO.Path]::GetTempPath()
}
New-Item -ItemType Directory -Force -Path $tmpParent | Out-Null
$tmpRoot = Join-Path $tmpParent ("dd-topt-" + [System.Guid]::NewGuid().ToString("N"))
$bepDir = Join-Path $tmpRoot "bep"
$artifactStagingDir = Join-Path $tmpRoot "bep-artifacts"
New-Item -ItemType Directory -Force -Path $bepDir, $artifactStagingDir | Out-Null
$retentionStatusJson = Join-Path $tmpRoot "uploader-retention-status.json"
$finalizationRequired = $false
if (-not [string]::IsNullOrWhiteSpace($SupportBundle) -and [string]::IsNullOrWhiteSpace($ReportDir)) {
  $ReportDir = Join-Path $tmpRoot "reports"
}
$commandManifestJson = Join-Path $tmpRoot "support-command-manifest.json"
$UploadReportJson = ""
if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
  New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
  if ([string]::IsNullOrWhiteSpace($DoctorReportJson)) {
    $DoctorReportJson = Join-Path $ReportDir "doctor-report.json"
  }
  if ([string]::IsNullOrWhiteSpace($UploaderReportJson)) {
    if ($Upload.IsPresent) {
      $UploaderReportJson = Join-Path $ReportDir "uploader-upload-report.json"
    } else {
      $UploaderReportJson = Join-Path $ReportDir "uploader-dry-run-report.json"
    }
  }
}
if ($Upload.IsPresent) {
  $UploadReportJson = $UploaderReportJson
}

$keepGeneratedFiles = $KeepTmp.IsPresent -or $env:DD_TEST_OPTIMIZATION_KEEP_TMP -eq "1"

function Get-OutputBase {
  & $Bazel info output_base 2>$null
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
}

function Get-PythonForSupportBundle {
  foreach ($candidate in @($env:DD_TEST_OPTIMIZATION_PYTHON, $env:PYTHON)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  foreach ($candidate in @("python3", "python")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Get-SupportBundleCollector {
  if (-not [string]::IsNullOrWhiteSpace($SupportBundleCollector)) {
    return $SupportBundleCollector
  }
  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Join-Path $scriptDir "create_support_bundle.py")
}

function Test-RetentionCleanupSafe {
  if (-not (Test-Path -LiteralPath $retentionStatusJson -PathType Leaf)) { return $false }
  $python = Get-PythonForSupportBundle
  if (-not $python) { return $false }
  $code = @'
import json
from pathlib import Path
import sys
try:
    status = json.loads(Path(sys.argv[1]).read_text())
    valid = (type(status.get("schema_version")) is int and status["schema_version"] == 1
        and status.get("wrapper_temp_root") == str(Path(sys.argv[2]).resolve())
        and status.get("cleanup_safe") is True
        and not any((Path(sys.argv[3]) / "__runs").glob("*")))
except (OSError, ValueError, TypeError, AttributeError):
    valid = False
sys.exit(0 if valid else 1)
'@
  try {
    & $python -c $code $retentionStatusJson $tmpRoot $artifactStagingDir
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Write-SupportCommandManifest {
  $bepFiles = @()
  foreach ($bepArg in $bepArgs) {
    $bepFiles += ($bepArg -replace '^--bep-json=', '')
  }
  $commandManifest = [ordered]@{
    bazel = $Bazel
    config = $Config
    doctor_target = $DoctorTarget
    upload_target = $UploadTarget
    artifact_staging_dir = $artifactStagingDir
    report_dir = $ReportDir
    doctor_report_json = $DoctorReportJson
    uploader_report_json = $UploaderReportJson
    upload_report_json = $UploadReportJson
    upload_enabled = $Upload.IsPresent
    bep_files = $bepFiles
    test_flags = $TestFlag
    runtime_flags = @(
      "--freshness-source=bep",
      "--freshness-mode=required",
      "--artifact-source=bep",
      "--artifact-staging-dir=$artifactStagingDir"
    )
    targets = $Targets
  }
  $commandManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $commandManifestJson -Encoding UTF8
}

function New-SupportBundle {
  try {
    if ([string]::IsNullOrWhiteSpace($SupportBundle)) {
      return
    }
    $collector = Get-SupportBundleCollector
    if (-not (Test-Path -LiteralPath $collector)) {
      Write-Warning "support bundle collector not found: $collector"
      return
    }
    $python = Get-PythonForSupportBundle
    if ($null -eq $python) {
      Write-Warning "Python interpreter not found; skipping Test Optimization support bundle: $SupportBundle"
      return
    }
    Write-SupportCommandManifest
    $outputBase = Get-OutputBase
    $args = @(
      $collector,
      "--report-dir=$ReportDir",
      "--output=$SupportBundle",
      "--command-manifest-json=$commandManifestJson",
      "--workspace-root=$PWD",
      "--tmp-root=$tmpRoot",
      "--bazel=$Bazel"
    )
    if (-not [string]::IsNullOrWhiteSpace($outputBase)) {
      $args += "--output-base=$outputBase"
    }
    foreach ($reportPath in @($DoctorReportJson, $UploaderReportJson, $UploadReportJson)) {
      if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
        $args += "--report-json=$reportPath"
      }
    }
    foreach ($bepArg in $bepArgs) {
      $args += "--bep-json=$($bepArg -replace '^--bep-json=', '')"
    }
    & $python @args
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "failed to create Test Optimization support bundle: $SupportBundle"
    }
  } catch {
    Write-Warning "failed to create Test Optimization support bundle: $($_.Exception.Message)"
  }
}

try {
  $bepArgs = @()
  $testStatus = 0
  $index = 0

  foreach ($target in $Targets) {
    $index += 1
    $safeTarget = Get-SafeTargetName -Target $target
    $bepJson = Join-Path $bepDir ("{0}_{1}.bep.json" -f $index, $safeTarget)
    $bepArgs += "--bep-json=$bepJson"

    $testArgs = @("test", "--config=$Config") + $TestFlag + @("--build_event_json_file=$bepJson", $target)
    $rc = Invoke-BazelCommand -Args $testArgs
    if ($rc -ne 0 -and $testStatus -eq 0) {
      $testStatus = $rc
    }
  }

  $runtimeArgs = $bepArgs + @(
    "--freshness-source=bep",
    "--freshness-mode=required",
    "--artifact-source=bep",
    "--artifact-staging-dir=$artifactStagingDir"
  )

  $finalStatus = $testStatus

  $doctorRuntimeArgs = $runtimeArgs
  if (-not [string]::IsNullOrWhiteSpace($DoctorReportJson)) {
    $doctorRuntimeArgs += "--report-json=$DoctorReportJson"
  }

  $finalizationRequired = $true
  $doctorStatus = Invoke-BazelCommand -Args (@("run", "--config=$Config", $DoctorTarget, "--") + $doctorRuntimeArgs)
  if ($doctorStatus -ne 0 -and $finalStatus -eq 0) {
    $finalStatus = $doctorStatus
  }

  $uploaderRuntimeArgs = $runtimeArgs
  if ($Upload.IsPresent) {
    if (-not [string]::IsNullOrWhiteSpace($UploadReportJson)) {
      $uploaderRuntimeArgs += "--report-json=$UploadReportJson"
    }
    $uploaderRuntimeArgs += "--validate-enrichment"
  } else {
    if (-not [string]::IsNullOrWhiteSpace($UploaderReportJson)) {
      $uploaderRuntimeArgs += "--report-json=$UploaderReportJson"
    }
    $uploaderRuntimeArgs += @("--dry-run", "--validate-enrichment")
  }
  if ($Upload.IsPresent -and [string]::IsNullOrWhiteSpace($RetainedOutputsDir) -and -not [string]::IsNullOrWhiteSpace($ReportDir)) {
    $python = Get-PythonForSupportBundle
    if ($python) {
      $code = @'
from pathlib import Path
import sys
report, temporary = (Path(value).resolve() for value in sys.argv[1:])
print(report / "retained" if not report.is_relative_to(temporary) else "")
'@
      try {
        $candidate = [string](& $python -c $code $ReportDir $tmpRoot)
        if ($LASTEXITCODE -eq 0) { $RetainedOutputsDir = $candidate }
      } catch {
        Write-Warning "Could not select a durable retention destination; original outputs will be preserved when needed."
      }
    }
  }
  $uploaderEnvironment = @{
    DD_TEST_OPTIMIZATION_INTERNAL_WRAPPER_TEMP_ROOT = $tmpRoot
    DD_TEST_OPTIMIZATION_INTERNAL_RETENTION_STATUS_FILE = $retentionStatusJson
    DD_TEST_OPTIMIZATION_RETAINED_OUTPUTS_DIR = $RetainedOutputsDir
  }
  $previousEnvironment = @{}
  foreach ($name in $uploaderEnvironment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, $uploaderEnvironment[$name], "Process")
  }
  try {
    $uploaderStatus = Invoke-BazelCommand -Args (@("run", "--config=$Config", $UploadTarget, "--") + $uploaderRuntimeArgs)
  } finally {
    foreach ($name in $uploaderEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
    }
  }
  if ($uploaderStatus -ne 0 -and $finalStatus -eq 0) {
    $finalStatus = $uploaderStatus
  }

  exit $finalStatus
} finally {
  New-SupportBundle
  if ($keepGeneratedFiles -or ($finalizationRequired -and -not (Test-RetentionCleanupSafe))) {
    Write-Host "keeping Test Optimization temporary files: $tmpRoot (explicit keep or unverified retention)"
  } else {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
