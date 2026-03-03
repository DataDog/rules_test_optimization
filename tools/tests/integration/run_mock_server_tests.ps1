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

# Resolve Bazel invocation mode without requiring bash.
function Resolve-BazelInvoker {
  param([string]$RepoRoot)

  foreach ($name in @("bazelisk", "bazel")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      return @{
        mode = "native"
        command = $cmd.Source
      }
    }
  }

  $wrapper = Join-Path $RepoRoot "bazelw"
  if (Test-Path -LiteralPath $wrapper -PathType Leaf) {
    foreach ($name in @("bash", "bash.exe")) {
      $bashCmd = Get-Command $name -ErrorAction SilentlyContinue
      if ($bashCmd) {
        Write-Host "warning: bazel/bazelisk not found in PATH; falling back to bazelw via bash"
        return @{
          mode = "wrapper"
          command = $wrapper
          bash = $bashCmd.Source
        }
      }
    }
  }

  throw "unable to locate Bazel command (tried bazelisk, bazel, and bazelw+bash)"
}

# Read LASTEXITCODE safely under strict mode.
function Get-NativeExitCode {
  $lastExitVar = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  if ($null -eq $lastExitVar -or $null -eq $lastExitVar.Value) {
    return 0
  }
  return [int]$lastExitVar.Value
}

# Invoke Bazel command (native if possible, wrapper fallback otherwise).
function Invoke-BazelCommand {
  param(
    [hashtable]$BazelInvoker,
    [string[]]$BazelArgs
  )
  if ($BazelInvoker["mode"] -eq "native") {
    & $BazelInvoker["command"] @BazelArgs
    return
  }

  $invokeArgs = @("-lc", 'exec "$@"', "--", $BazelInvoker["command"])
  if ($BazelArgs) { $invokeArgs += $BazelArgs }
  & $BazelInvoker["bash"] @invokeArgs
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
    "__DDTPL_FAIL_ON_ERROR__" = "false"
    "__DDTPL_DEBUG__" = "false"
    "__DDTPL_KEEP_PAYLOADS__" = "true"
    "__DDTPL_FILTER_PREFIX__" = "false"
    "__DDTPL_GZIP_PAYLOADS__" = "false"
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
$bazelInvoker = Resolve-BazelInvoker -RepoRoot $repoRoot
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

  # Canonical runtime-name preflight for sync extension coverage.
  $syncWorkspace = Join-Path $tempRoot "sync_preflight_ws"
  New-Item -ItemType Directory -Force -Path $syncWorkspace | Out-Null
  $repoRootForModule = $repoRoot.Replace("\", "/")
  $moduleContent = @"
module(name = "topt-windows-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "$repoRootForModule",
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    service = "mock-service",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_nodejs",
    service = "mock-service-nodejs",
    runtime_name = "nodejs",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_dotnet",
    service = "mock-service-dotnet",
    runtime_name = "dotnet",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_ruby",
    service = "mock-service-ruby",
    runtime_name = "ruby",
    runtime_version = "1.2.3",
)

use_repo(
    test_optimization_sync,
    "test_optimization_data",
    "test_optimization_data_nodejs",
    "test_optimization_data_dotnet",
    "test_optimization_data_ruby",
)
"@
  $buildContent = @"
filegroup(
    name = "all_sync_payloads",
    srcs = [
        "@test_optimization_data//:test_optimization_files",
        "@test_optimization_data_nodejs//:test_optimization_files",
        "@test_optimization_data_dotnet//:test_optimization_files",
        "@test_optimization_data_ruby//:test_optimization_files",
    ],
)
"@
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $syncWorkspace "MODULE.bazel"), $moduleContent, $utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $syncWorkspace "BUILD.bazel"), $buildContent, $utf8NoBom)

  $preflightOutBase = Join-Path $tempRoot "sync_preflight_out"
  $bazelFlags = @("--output_base=$preflightOutBase")
  $repoEnvs = @(
    "--repo_env=DD_API_KEY=mock",
    "--repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL=http://127.0.0.1:$port",
    "--repo_env=DD_ENV=ci",
    "--repo_env=DD_GIT_REPOSITORY_URL=https://example.com/repo.git",
    "--repo_env=DD_GIT_BRANCH=main",
    "--repo_env=DD_GIT_COMMIT_SHA=1111111",
    "--repo_env=DD_GIT_HEAD_COMMIT=1111111",
    "--repo_env=DD_GIT_COMMIT_MESSAGE=Test_commit",
    "--repo_env=DD_GIT_HEAD_MESSAGE=Test_head",
    "--repo_env=DD_GIT_TAG=v1.0.0"
  )
  Push-Location $syncWorkspace
  try {
    Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("fetch", "//:all_sync_payloads") + $repoEnvs))
    $syncFetchExitCode = Get-NativeExitCode
    if ($syncFetchExitCode -ne 0) {
      throw "sync runtime preflight fetch failed with exit code $syncFetchExitCode"
    }
    Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("build", "//:all_sync_payloads") + $repoEnvs))
    $syncBuildExitCode = Get-NativeExitCode
    if ($syncBuildExitCode -ne 0) {
      throw "sync runtime preflight build failed with exit code $syncBuildExitCode"
    }
  } finally {
    Pop-Location
  }

  $cqueryOutput = Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("cquery", "@test_optimization_data//:test_optimization_files", "--output=files") + $repoEnvs))
  $syncCqueryExitCode = Get-NativeExitCode
  if ($syncCqueryExitCode -ne 0) {
    throw "sync runtime preflight cquery failed with exit code $syncCqueryExitCode"
  }
  $actualOutputBase = ""
  $outputBaseOutput = Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("info", "output_base") + $repoEnvs))
  $outputBaseExitCode = Get-NativeExitCode
  if ($outputBaseExitCode -eq 0) {
    $outputBaseLines = @($outputBaseOutput)
    if ($outputBaseLines.Count -gt 0) {
      $actualOutputBase = ([string]$outputBaseLines[0]).Trim()
    }
  }
  if ([string]::IsNullOrWhiteSpace($actualOutputBase)) {
    Write-Host "warning: unable to resolve output_base from bazel info (exit=$outputBaseExitCode); using requested output_base path"
  }

  $executionRoot = ""
  $executionRootOutput = Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("info", "execution_root") + $repoEnvs))
  $executionRootExitCode = Get-NativeExitCode
  if ($executionRootExitCode -eq 0) {
    $executionRootLines = @($executionRootOutput)
    if ($executionRootLines.Count -gt 0) {
      $executionRoot = ([string]$executionRootLines[0]).Trim()
    }
  }
  if ([string]::IsNullOrWhiteSpace($executionRoot)) {
    Write-Host "warning: unable to resolve execution_root from bazel info (exit=$executionRootExitCode); continuing with output_base-derived roots"
  }

  $outputBaseRoots = @(
    $preflightOutBase,
    $actualOutputBase
  )
  $outputBaseRoots = @(
    $outputBaseRoots |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  )

  $settingsPath = $null
  $candidateBases = @()
  foreach ($outputBaseRoot in $outputBaseRoots) {
    $candidateBases += $outputBaseRoot
    $candidateBases += (Join-Path $outputBaseRoot "execroot/_main")
  }
  $candidateBases += @($executionRoot, $syncWorkspace)
  $candidateBases = @(
    $candidateBases |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  )

  foreach ($line in @($cqueryOutput)) {
    $candidate = [string]$line
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $candidate = $candidate.Trim()
    $normalized = $candidate.Replace("\", "/")
    if (-not $normalized.EndsWith("/.testoptimization/cache/http/settings.json")) { continue }
    if ([System.IO.Path]::IsPathRooted($candidate)) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $settingsPath = (Resolve-Path -LiteralPath $candidate).Path
        break
      }
      continue
    }
    foreach ($base in $candidateBases) {
      if ([string]::IsNullOrWhiteSpace($base)) { continue }
      $joined = Join-Path $base $candidate
      if (Test-Path -LiteralPath $joined -PathType Leaf) {
        $settingsPath = (Resolve-Path -LiteralPath $joined).Path
        break
      }
    }
    if ($settingsPath) { break }
  }
  $externalRoots = @()
  if (-not $settingsPath) {
    foreach ($outputBaseRoot in $outputBaseRoots) {
      $externalRoots += (Join-Path $outputBaseRoot "external")
      $externalRoots += (Join-Path $outputBaseRoot "execroot/_main/external")
    }
    if (-not [string]::IsNullOrWhiteSpace($executionRoot)) {
      $externalRoots += (Join-Path $executionRoot "external")
    }
    $externalRoots = @(
      $externalRoots |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
    )

    $settingsCandidates = @()
    foreach ($externalRoot in $externalRoots) {
      if (-not (Test-Path -LiteralPath $externalRoot -PathType Container)) { continue }
      $repoDirs = Get-ChildItem -LiteralPath $externalRoot -Directory -Force -ErrorAction SilentlyContinue
      foreach ($repoDir in $repoDirs) {
        $settingsCandidate = Join-Path $repoDir.FullName ".testoptimization/cache/http/settings.json"
        if (-not (Test-Path -LiteralPath $settingsCandidate -PathType Leaf)) { continue }

        $score = 50
        $repoDirNorm = $repoDir.FullName.Replace("\", "/").ToLowerInvariant()
        if ($repoDirNorm -match "test_optimization_data") { $score = 20 }
        if ($repoDirNorm -match "test_optimization_data_(nodejs|dotnet|ruby)") { $score = 40 }

        $exportCandidate = Join-Path $repoDir.FullName "export.bzl"
        if (Test-Path -LiteralPath $exportCandidate -PathType Leaf) {
          $exportText = Get-Content -LiteralPath $exportCandidate -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
          if ($exportText -match 'repo_name"\s*:\s*"test_optimization_data"') {
            $score = 0
          } elseif ($exportText -match 'repo_name"\s*:\s*"test_optimization_data_(nodejs|dotnet|ruby)"') {
            $score = [Math]::Min($score, 30)
          } elseif ($exportText -match 'repo_name"\s*:\s*"test_optimization_data') {
            $score = [Math]::Min($score, 10)
          }
        }

        $settingsCandidates += [pscustomobject]@{
          Score = $score
          Path = (Resolve-Path -LiteralPath $settingsCandidate).Path
          RepoDir = $repoDir.FullName
        }
      }
    }

    if ($settingsCandidates.Count -eq 0) {
      foreach ($externalRoot in $externalRoots) {
        if (-not (Test-Path -LiteralPath $externalRoot -PathType Container)) { continue }
        $exportFiles = Get-ChildItem -LiteralPath $externalRoot -Recurse -File -Filter "export.bzl" -ErrorAction SilentlyContinue
        foreach ($exportFile in $exportFiles) {
          $exportText = Get-Content -LiteralPath $exportFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
          if ([string]::IsNullOrWhiteSpace($exportText)) { continue }
          if ($exportText -notmatch 'repo_name"\s*:\s*"test_optimization_data') { continue }

          $settingsCandidate = Join-Path (Split-Path -Parent $exportFile.FullName) ".testoptimization/cache/http/settings.json"
          if (-not (Test-Path -LiteralPath $settingsCandidate -PathType Leaf)) { continue }

          $score = 15
          if ($exportText -match 'repo_name"\s*:\s*"test_optimization_data"') {
            $score = 0
          } elseif ($exportText -match 'repo_name"\s*:\s*"test_optimization_data_(nodejs|dotnet|ruby)"') {
            $score = 35
          }
          $settingsCandidates += [pscustomobject]@{
            Score = $score
            Path = (Resolve-Path -LiteralPath $settingsCandidate).Path
            RepoDir = (Split-Path -Parent $exportFile.FullName)
          }
        }
      }
    }

    if ($settingsCandidates.Count -gt 0) {
      $preferredSettings = $settingsCandidates | Sort-Object Score, Path | Select-Object -First 1
      $settingsPath = $preferredSettings.Path
      Write-Host "resolved settings.json from external directory fallback: $settingsPath"
    }
  }
  if (-not $settingsPath) {
    $cquerySample = (@($cqueryOutput) | Select-Object -First 10) -join " | "
    $externalRootsSample = ($externalRoots | Select-Object -First 8) -join ","
    $existingExternalRoots = ($externalRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 8) -join ","
    throw "failed to resolve settings.json path from sync runtime preflight cquery output (requested_output_base=$preflightOutBase, actual_output_base=$actualOutputBase, execution_root=$executionRoot, external_roots=$externalRootsSample, existing_external_roots=$existingExternalRoots, cquery_sample=$cquerySample)"
  }
  $toptHttpDir = Split-Path -Parent $settingsPath
  $toptCacheDir = Split-Path -Parent $toptHttpDir
  $toptDir = Split-Path -Parent $toptCacheDir
  $exportPath = Join-Path (Split-Path -Parent $toptDir) "export.bzl"
  if (-not (Test-Path -LiteralPath $exportPath -PathType Leaf)) {
    throw "missing export.bzl after sync preflight at $exportPath"
  }
  $exportContent = Get-Content -LiteralPath $exportPath -Raw -Encoding UTF8
  foreach ($runtime in @("go", "python", "java", "nodejs", "dotnet", "ruby")) {
    if (-not $exportContent.Contains("`"$runtime`": {")) {
      throw "export.bzl missing runtime key '$runtime'"
    }
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
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  Invoke-UploaderScript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs
  $agentlessExitCode = Get-NativeExitCode
  if ($agentlessExitCode -ne 0) {
    throw "agentless uploader execution failed with exit code $agentlessExitCode"
  }

  # EVP flow
  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENTLESS_URL -ErrorAction SilentlyContinue
  $env:DD_TEST_OPTIMIZATION_AGENT_URL = "http://127.0.0.1:$port"
  Invoke-UploaderScript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs
  $evpExitCode = Get-NativeExitCode
  if ($evpExitCode -ne 0) {
    throw "evp uploader execution failed with exit code $evpExitCode"
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
