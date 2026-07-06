# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Handle Invoke-RunCmd behavior.
function Invoke-RunCmd {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [Parameter()]
    [string[]]$Args = @()
  )

  if ($env:RUNTESTS_DRY_RUN -eq "1") {
    Write-Output ("[dry-run] {0} {1}" -f $Command, ($Args -join " "))
    return 0
  }

  & $Command @Args
  return $LASTEXITCODE
}

# Handle Get-BazelCommand behavior.
function Get-BazelCommand {
  $bazel = Get-Command bazel -ErrorAction SilentlyContinue
  if (-not $bazel) {
    throw "bazel not found in PATH. On Windows, runtests.ps1 requires native Bazel/Bazelisk."
  }
  return $bazel.Source
}

# Handle Invoke-ExampleRunTests behavior.
function Invoke-ExampleRunTests {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDir
  )

  $tmpRoot = $null
  Push-Location $ScriptDir
  try {
    $bazelCmd = Get-BazelCommand
    $testStatus = 0
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dd-topt-example-" + [System.Guid]::NewGuid().ToString("N"))
    $artifactStagingDir = Join-Path $tmpRoot "bep-artifacts"
    New-Item -ItemType Directory -Force -Path $artifactStagingDir | Out-Null
    $nonHermeticBep = Join-Path $tmpRoot "non-hermetic.bep.json"
    $hermeticBep = Join-Path $tmpRoot "hermetic.bep.json"
    $bepArgs = @(
      "--bep-json=$nonHermeticBep",
      "--bep-json=$hermeticBep",
      "--freshness-source=bep",
      "--freshness-mode=required",
      "--artifact-source=bep",
      "--artifact-staging-dir=$artifactStagingDir"
    )

    Write-Output "--- non-hermetic run"
    $rc = Invoke-RunCmd -Command $bazelCmd -Args @("test", "//src/go-project/...", "--test_output=streamed", "--test_arg=-test.v", "--sandbox_debug", "--remote_download_minimal", "--remote_download_regex=.*test[.]outputs.*", "--zip_undeclared_test_outputs", "--build_event_json_file=$nonHermeticBep")
    if ($rc -ne 0) { $testStatus = $rc }

    Write-Output "--- hermetic run"
    $rc = Invoke-RunCmd -Command $bazelCmd -Args @("test", "//src/go-project/...", "--test_output=streamed", "--test_arg=-test.v", "--sandbox_debug", "--config=hermetic", "--remote_download_minimal", "--remote_download_regex=.*test[.]outputs.*", "--zip_undeclared_test_outputs", "--build_event_json_file=$hermeticBep")
    if ($rc -ne 0) { $testStatus = $rc }

    Write-Output "--- validating payloads"
    $doctorStatus = Invoke-RunCmd -Command $bazelCmd -Args (@("run", "//:dd_test_optimization_doctor", "--") + $bepArgs)
    if ($doctorStatus -ne 0) {
      if ($testStatus -ne 0) { exit $testStatus }
      exit $doctorStatus
    }

    Write-Output "--- validating upload enrichment"
    $dryRunStatus = Invoke-RunCmd -Command $bazelCmd -Args (@("run", "//:dd_upload_payloads", "--") + $bepArgs + @("--dry-run", "--validate-enrichment"))
    if ($dryRunStatus -ne 0) {
      if ($testStatus -ne 0) { exit $testStatus }
      exit $dryRunStatus
    }

    Write-Output "--- uploading payloads"
    if (-not $env:DD_SITE) { $env:DD_SITE = "datadoghq.com" }
    $uploadRc = Invoke-RunCmd -Command $bazelCmd -Args (@("run", "//:dd_upload_payloads", "--") + $bepArgs)

    if ($testStatus -ne 0) { exit $testStatus }
    exit $uploadRc
  } finally {
    if ($tmpRoot) {
      Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
  }
}
