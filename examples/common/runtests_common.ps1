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

  Push-Location $ScriptDir
  try {
    $bazelCmd = Get-BazelCommand
    $testStatus = 0

    Write-Output "--- non-hermetic run"
    $rc = Invoke-RunCmd -Command $bazelCmd -Args @("test", "//src/go-project/...", "--test_output=streamed", "--test_arg=-test.v", "--sandbox_debug")
    if ($rc -ne 0) { $testStatus = $rc }

    Write-Output "--- hermetic run"
    $rc = Invoke-RunCmd -Command $bazelCmd -Args @("test", "//src/go-project/...", "--test_output=streamed", "--test_arg=-test.v", "--sandbox_debug", "--config=hermetic")
    if ($rc -ne 0) { $testStatus = $rc }

    Write-Output "--- validating payloads"
    $doctorStatus = Invoke-RunCmd -Command $bazelCmd -Args @("run", "//:dd_test_optimization_doctor")
    if ($doctorStatus -ne 0) {
      if ($testStatus -ne 0) { exit $testStatus }
      exit $doctorStatus
    }

    Write-Output "--- validating upload enrichment"
    $dryRunStatus = Invoke-RunCmd -Command $bazelCmd -Args @("run", "//:dd_upload_payloads", "--", "--dry-run", "--validate-enrichment")
    if ($dryRunStatus -ne 0) {
      if ($testStatus -ne 0) { exit $testStatus }
      exit $dryRunStatus
    }

    Write-Output "--- uploading payloads"
    if (-not $env:DD_SITE) { $env:DD_SITE = "datadoghq.com" }
    $uploadRc = Invoke-RunCmd -Command $bazelCmd -Args @("run", "//:dd_upload_payloads")

    if ($testStatus -ne 0) { exit $testStatus }
    exit $uploadRc
  } finally {
    Pop-Location
  }
}
