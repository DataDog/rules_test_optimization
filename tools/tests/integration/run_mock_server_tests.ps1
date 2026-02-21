#!/usr/bin/env pwsh
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ForwardArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Handle Get-RepoRoot behavior.
function Get-RepoRoot {
  param([string]$StartPath)
  $candidate = (Resolve-Path $StartPath).Path
  while ($true) {
    if ((Test-Path (Join-Path $candidate "MODULE.bazel") -PathType Leaf) -or (Test-Path (Join-Path $candidate ".git"))) {
      return $candidate
    }
    $parent = Split-Path $candidate -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
      throw "unable to locate repository root from script path: $StartPath"
    }
    $candidate = $parent
  }
}

# Handle Get-PythonCommand behavior.
function Get-PythonCommand {
  if ($env:PYTHON) {
    $cmd = Get-Command $env:PYTHON -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  foreach ($name in @("python3", "python")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "python interpreter not found (tried PYTHON, python3, python)"
}

# Handle Get-TempDirectory behavior.
function Get-TempDirectory {
  foreach ($name in @("TEMP", "TMP", "TMPDIR")) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }
  $fallback = [System.IO.Path]::GetTempPath()
  if (-not [string]::IsNullOrWhiteSpace($fallback)) {
    return $fallback
  }
  throw "unable to resolve temporary directory (checked TEMP, TMP, TMPDIR, and Path.GetTempPath())"
}

# Handle Get-PowerShellCommand behavior.
function Get-PowerShellCommand {
  foreach ($name in @("powershell.exe", "pwsh", "powershell")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "PowerShell host not found (tried powershell.exe, pwsh, powershell)"
}

# Handle Invoke-UploaderScript behavior.
function Invoke-UploaderScript {
  param(
    [string]$PowerShellPath,
    [string]$ScriptPath,
    [string[]]$ForwardedArgs
  )
  $hostName = (Split-Path -Leaf $PowerShellPath).ToLowerInvariant()
  $invokeArgs = @("-NoProfile", "-NonInteractive")
  if ($hostName -eq "powershell.exe") {
    $invokeArgs += @("-ExecutionPolicy", "Bypass")
  }
  $invokeArgs += @("-File", $ScriptPath)
  if ($ForwardedArgs) {
    $invokeArgs += $ForwardedArgs
  }
  & $PowerShellPath @invokeArgs
}

# Handle Get-FreePort behavior.
function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return $listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

# Handle Wait-ForPort behavior.
function Wait-ForPort {
  param(
    [int]$Port,
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $client = $null
    try {
      $client = [System.Net.Sockets.TcpClient]::new()
      $ar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
      if ($ar.AsyncWaitHandle.WaitOne(200)) {
        $client.EndConnect($ar)
        return $true
      }
    } catch {
      # keep polling
    } finally {
      if ($client) { $client.Close() }
    }
    Start-Sleep -Milliseconds 200
  }
  return $false
}

# Handle Render-UploaderTemplate behavior.
function Render-UploaderTemplate {
  param(
    [string]$TemplatePath,
    [string]$OutputPath
  )
  $content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
  $replacements = @{
    "__DDTPL_QUIESCENT_SEC__" = "1"
    "__DDTPL_MAX_WAIT_SEC__" = "10"
    "__DDTPL_FAIL_ON_ERROR__" = "False"
    "__DDTPL_DEBUG__" = "False"
    "__DDTPL_KEEP_PAYLOADS__" = "True"
    "__DDTPL_FILTER_PREFIX__" = "False"
    "__DDTPL_GZIP_PAYLOADS__" = "False"
    "__DDTPL_UPLOADER_VERSION__" = "integration-test"
    "__DDTPL_CONTEXT_JSON_RLOC__" = ""
    "__DDTPL_CONTEXT_JSON_PATH__" = ""
    "__DDTPL_SCHEMA_JSON_RLOC__" = ""
    "__DDTPL_SCHEMA_JSON_PATH__" = ""
    "__DDTPL_SCHEMA_VALIDATOR_RLOC__" = ""
    "__DDTPL_SCHEMA_VALIDATOR_PATH__" = ""
    "__DDTPL_RULES_VERSION__" = "integration-test"
  }
  foreach ($entry in $replacements.GetEnumerator()) {
    $content = $content.Replace($entry.Key, $entry.Value)
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($OutputPath, $content, $utf8NoBom)
}

# Handle Read-JsonLog behavior.
function Read-JsonLog {
  param([string]$Path)
  $entries = @()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $entries }
  foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $entries += ($line | ConvertFrom-Json)
  }
  return $entries
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Get-RepoRoot -StartPath $scriptDir
$python = Get-PythonCommand
$powerShellHost = Get-PowerShellCommand
$tempDir = Get-TempDirectory
$tempRoot = Join-Path $tempDir ("dd_topt_windows_integration_" + [guid]::NewGuid().ToString("N"))
$fixturesDir = Join-Path $repoRoot "tools/tests/integration/fixtures"
$snapshotFile = Join-Path $repoRoot "tools/tests/integration/snapshots/citestcycle.json"
$psTemplate = Join-Path $repoRoot "tools/core/uploader_powershell_runtime.ps1.tpl"
$renderedUploader = Join-Path $tempRoot "dd_upload_payloads.ps1"
$mockLog = Join-Path $tempRoot "mock.log"
$mockOut = Join-Path $tempRoot "mock.out"
$mockErr = Join-Path $tempRoot "mock.err"
$port = Get-FreePort
$serverProc = $null

Push-Location $repoRoot
try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  if (-not (Test-Path -LiteralPath $fixturesDir -PathType Container)) {
    throw "fixtures directory not found: $fixturesDir"
  }
  if (-not (Test-Path -LiteralPath $snapshotFile -PathType Leaf)) {
    throw "snapshot fixture not found: $snapshotFile"
  }
  if (-not (Test-Path -LiteralPath $psTemplate -PathType Leaf)) {
    throw "uploader template not found: $psTemplate"
  }

  $serverArgs = @(
    "-u",
    (Join-Path $repoRoot "tools/tests/integration/mock_dd_server.py"),
    "--fixtures", $fixturesDir,
    "--log", $mockLog,
    "--port", "$port"
  )
  $serverProc = Start-Process -FilePath $python -ArgumentList $serverArgs -PassThru -NoNewWindow -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr
  if (-not (Wait-ForPort -Port $port -TimeoutSeconds 30)) {
    if ($serverProc -and -not $serverProc.HasExited) { Stop-Process -Id $serverProc.Id -Force }
    throw "mock server did not start on port $port"
  }

  $testOutputsRoot = Join-Path $tempRoot "bazel-testlogs/pkg/target/test.outputs"
  $testsDir = Join-Path $testOutputsRoot "payloads/tests"
  $coverageDir = Join-Path $testOutputsRoot "payloads/coverage"
  New-Item -ItemType Directory -Force -Path $testsDir, $coverageDir | Out-Null
  Copy-Item -LiteralPath $snapshotFile -Destination (Join-Path $testsDir "span_events_windows.json") -Force
  '{"mock_mode":"ok"}' | Set-Content -LiteralPath (Join-Path $coverageDir "coverage_windows.json") -Encoding UTF8

  Render-UploaderTemplate -TemplatePath $psTemplate -OutputPath $renderedUploader

  $env:TESTLOGS_DIR = Join-Path $tempRoot "bazel-testlogs"
  $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS = "1"
  if ([string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP = $tempDir }
  if ([string]::IsNullOrWhiteSpace($env:TMP)) { $env:TMP = $tempDir }

  # Agentless flow
  # Build a deterministic mock key at runtime to avoid committing a secret-like literal.
  $env:DD_API_KEY = [string]::new("0", 32)
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_INTAKE_BASE = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TRACE_AGENT_URL -ErrorAction SilentlyContinue
  Invoke-UploaderScript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs
  if ($LASTEXITCODE -ne 0) {
    throw "agentless uploader execution failed with exit code $LASTEXITCODE"
  }

  # EVP flow
  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:DD_TEST_OPTIMIZATION_INTAKE_BASE -ErrorAction SilentlyContinue
  $env:DD_TRACE_AGENT_URL = "http://127.0.0.1:$port"
  Invoke-UploaderScript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs
  if ($LASTEXITCODE -ne 0) {
    throw "evp uploader execution failed with exit code $LASTEXITCODE"
  }

  $entries = Read-JsonLog -Path $mockLog
  $paths = @($entries | ForEach-Object { $_.path })
  $requiredPaths = @(
    "/api/v2/citestcycle",
    "/api/v2/citestcov",
    "/evp_proxy/v2/api/v2/citestcycle",
    "/evp_proxy/v2/api/v2/citestcov"
  )
  foreach ($requiredPath in $requiredPaths) {
    if (-not ($paths -contains $requiredPath)) {
      throw "missing expected uploader request path in mock log: $requiredPath"
    }
  }

  Write-Host "Windows integration harness passed (PowerShell-only uploader path)."
} finally {
  if ($serverProc -and -not $serverProc.HasExited) {
    Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
  }
  Pop-Location
}
