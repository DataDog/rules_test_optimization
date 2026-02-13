#!/usr/bin/env pwsh
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ForwardArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
  Windows entrypoint for uploader integration tests.

.DESCRIPTION
  Reuses the canonical integration scenario implemented in
  tools/tests/integration/run_mock_server_tests.sh so Linux/macOS/Windows
  execute the same assertions. On Windows, Bazel resolves dd_upload_payloads
  to the .bat launcher, which exercises the PowerShell uploader implementation.
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..\..")).Path
$integrationSh = "tools/tests/integration/run_mock_server_tests.sh"

Push-Location $repoRoot
try {
  # Prefer known Git for Windows bash locations to avoid accidentally resolving
  # WSL's System32 bash.exe when both are installed.
  $bashPath = $null
  $gitBashCandidates = @(
    $env:DD_TOPT_GIT_BASH,
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\usr\bin\bash.exe"
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $gitBashCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $bashPath = $candidate
      break
    }
  }

  if ($null -eq $bashPath) {
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $bashCmd) {
      $bashPath = $bashCmd.Source
    }
  }

  if ($null -eq $bashPath) {
    throw "bash not found. Install Git for Windows or ensure bash is on PATH."
  }

  if (-not (Test-Path -LiteralPath $integrationSh -PathType Leaf)) {
    throw "integration harness not found: $integrationSh"
  }

  $bashArgs = @($integrationSh)
  if ($null -ne $ForwardArgs -and $ForwardArgs.Count -gt 0) {
    $bashArgs += $ForwardArgs
  }

  Write-Host "Running integration harness via: $bashPath $($bashArgs -join ' ')"
  & $bashPath @bashArgs
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
} finally {
  Pop-Location
}
