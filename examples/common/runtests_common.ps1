Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-BazelCommand {
  $bazel = Get-Command bazel -ErrorAction SilentlyContinue
  if (-not $bazel) {
    throw "bazel not found in PATH. On Windows, runtests.ps1 requires native Bazel/Bazelisk."
  }
  return $bazel.Source
}

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

    Write-Output "--- uploading payloads"
    if (-not $env:DD_SITE) { $env:DD_SITE = "datadoghq.com" }
    $uploadRc = Invoke-RunCmd -Command $bazelCmd -Args @("run", "//:dd_upload_payloads")
    if ($uploadRc -ne 0) {
      Write-Warning "payload upload failed; preserving test exit code ($testStatus)."
    }

    exit $testStatus
  } finally {
    Pop-Location
  }
}
