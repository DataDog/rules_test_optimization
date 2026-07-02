# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

[CmdletBinding()]
param(
  [string]$Bazel = $(if ($env:BAZEL) { $env:BAZEL } else { "bazel" }),
  [string]$Config = $(if ($env:DD_TEST_OPTIMIZATION_BAZEL_CONFIG) { $env:DD_TEST_OPTIMIZATION_BAZEL_CONFIG } else { "test-optimization" }),
  [string]$DoctorTarget = $(if ($env:DD_TEST_OPTIMIZATION_DOCTOR_TARGET) { $env:DD_TEST_OPTIMIZATION_DOCTOR_TARGET } else { "//:dd_test_optimization_doctor" }),
  [string]$UploadTarget = $(if ($env:DD_TEST_OPTIMIZATION_UPLOAD_TARGET) { $env:DD_TEST_OPTIMIZATION_UPLOAD_TARGET } else { "//:dd_upload_payloads" }),
  [string]$DoctorReportJson = $(if ($env:DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON) { $env:DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON } else { "" }),
  [string[]]$TestFlag = @(),
  [switch]$Upload,
  [switch]$KeepTmp,
  [Parameter(ValueFromRemainingArguments = $true)]
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
  & $Bazel @Args
  if ($null -eq $LASTEXITCODE) {
    return 0
  }
  return [int]$LASTEXITCODE
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

$keepGeneratedFiles = $KeepTmp.IsPresent -or $env:DD_TEST_OPTIMIZATION_KEEP_TMP -eq "1"

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

  $doctorStatus = Invoke-BazelCommand -Args (@("run", "--config=$Config", $DoctorTarget, "--") + $doctorRuntimeArgs)
  if ($doctorStatus -ne 0 -and $finalStatus -eq 0) {
    $finalStatus = $doctorStatus
  }

  $dryRunStatus = 0
  if ($doctorStatus -eq 0) {
    $dryRunStatus = Invoke-BazelCommand -Args (@("run", "--config=$Config", $UploadTarget, "--") + $runtimeArgs + @("--dry-run", "--validate-enrichment"))
    if ($dryRunStatus -ne 0 -and $finalStatus -eq 0) {
      $finalStatus = $dryRunStatus
    }
  }

  if ($doctorStatus -eq 0 -and $dryRunStatus -eq 0 -and $Upload.IsPresent) {
    $uploadStatus = Invoke-BazelCommand -Args (@("run", "--config=$Config", $UploadTarget, "--") + $runtimeArgs)
    if ($uploadStatus -ne 0 -and $finalStatus -eq 0) {
      $finalStatus = $uploadStatus
    }
  }

  exit $finalStatus
} finally {
  if ($keepGeneratedFiles) {
    Write-Host "keeping Test Optimization temporary files: $tmpRoot"
  } else {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
