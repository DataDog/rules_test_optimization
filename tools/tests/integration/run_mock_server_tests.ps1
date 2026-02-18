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

.NOTES
  Maintainers: keep this wrapper intentionally thin. The canonical scenario
  logic must stay in the Bash harness to avoid cross-platform drift and
  duplicated assertions. The Bash harness also owns dual-module Go wiring
  (core + go companion + rules_go + local overrides).
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..\..")).Path
$integrationSh = "tools/tests/integration/run_mock_server_tests.sh"

Push-Location $repoRoot
try {
  # Prefer known Git for Windows bash locations to avoid accidentally resolving
  # WSL's System32 bash.exe when both are installed.
  $bashPath = $null
  $probeNotes = New-Object System.Collections.Generic.List[string]
  $gitBashCandidates = @(
    $env:DD_TEST_OPTIMIZATION_GIT_BASH,
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\usr\bin\bash.exe"
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $gitBashCandidates) {
    # Prefer an explicit Git Bash binary so CI does not accidentally invoke
    # a WSL/System32 shim with incompatible path semantics.
    $probeNotes.Add("candidate: $candidate")
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $bashPath = $candidate
      $probeNotes.Add("selected candidate: $candidate")
      break
    }
  }

  if ($null -eq $bashPath) {
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $bashCmd) {
      $bashPath = $bashCmd.Source
      $probeNotes.Add("selected from PATH: $bashPath")
    }
  }

  if ($null -eq $bashPath) {
    $details = ($probeNotes -join "; ")
    throw "bash not found. Set DD_TEST_OPTIMIZATION_GIT_BASH or install Git for Windows. Probe details: $details"
  }

  if ($bashPath -match "System32\\bash\.exe$") {
    Write-Warning "Resolved bash to System32 shim ($bashPath). Set DD_TEST_OPTIMIZATION_GIT_BASH to a Git Bash binary for predictable path behavior."
  }

  if (-not (Test-Path -LiteralPath $integrationSh -PathType Leaf)) {
    throw "integration harness not found: $integrationSh"
  }

  $bashArgs = @($integrationSh)
  if ($null -ne $ForwardArgs -and $ForwardArgs.Count -gt 0) {
    # Forward extra args so local debugging mirrors direct Bash invocation.
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
