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

# Run the uploader while collecting transcript output so assertions can inspect
# the debug stream for invalid synthetic upload attempts.
function Invoke-UploaderScriptWithTranscript {
  param(
    [string]$PowerShellPath,
    [string]$ScriptPath,
    [string[]]$ForwardedArgs,
    [string]$TranscriptPath
  )
  if (Test-Path -LiteralPath $TranscriptPath) {
    Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
  }
  Start-Transcript -Path $TranscriptPath -Force | Out-Null
  try {
    $null = Invoke-UploaderScript -PowerShellPath $PowerShellPath -ScriptPath $ScriptPath -ForwardedArgs $ForwardedArgs
    return (Get-NativeExitCode)
  } finally {
    try {
      Stop-Transcript | Out-Null
    } catch {
      # Transcript teardown is best-effort so the caller still sees the real
      # uploader exit code and any captured logs.
    }
  }
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
    [string]$OutputPath,
    [string]$ContextJsonPath = "",
    [string]$TelemetryFactsManifestPath = ""
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
    "__DDTPL_CONTEXT_JSON_PATH__" = $ContextJsonPath
    "__DDTPL_TELEMETRY_FACTS_MANIFEST_RLOC__" = ""
    "__DDTPL_TELEMETRY_FACTS_MANIFEST_PATH__" = $TelemetryFactsManifestPath
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

# Read one JSON document into a deterministic dictionary-oriented shape so the
# assertions do not depend on platform-specific PSCustomObject behavior.
function Read-JsonMap {
  param([string]$JsonText)
  return ($JsonText | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop)
}

# Read one key from either a dictionary or a PSCustomObject produced by
# ConvertFrom-Json.
function Get-JsonValue {
  param(
    $Object,
    [string]$Key
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    return $Object[$Key]
  }
  $property = $Object.PSObject.Properties[$Key]
  if ($property) { return $property.Value }
  return $null
}

# Collect metric names from a telemetry message-batch while accepting either
# array-backed or singleton-object JSON materialization.
function Get-TelemetryMetricNames {
  param($Payload)

  $metricNames = @()
  foreach ($message in @(Get-JsonValue -Object $Payload -Key "payload")) {
    $messagePayload = Get-JsonValue -Object $message -Key "payload"
    foreach ($series in @(Get-JsonValue -Object $messagePayload -Key "series")) {
      $metric = Get-JsonValue -Object $series -Key "metric"
      if (($metric -is [string]) -and -not [string]::IsNullOrWhiteSpace($metric)) {
        $metricNames += $metric
      }
    }
  }
  return $metricNames
}

# Read one metric tag array from a telemetry payload while accepting either
# array-backed or singleton-object JSON materialization.
function Get-TelemetryMetricTags {
  param(
    $Payload,
    [string]$MetricName
  )

  foreach ($message in @(Get-JsonValue -Object $Payload -Key "payload")) {
    $messagePayload = Get-JsonValue -Object $message -Key "payload"
    foreach ($series in @(Get-JsonValue -Object $messagePayload -Key "series")) {
      if ((Get-JsonValue -Object $series -Key "metric") -ne $MetricName) { continue }
      return @((Get-JsonValue -Object $series -Key "tags"))
    }
  }
  return @()
}

# Collect telemetry payloads from mock-server log entries for one request path.
function Get-TelemetryPayloadsByPath {
  param(
    [object[]]$Entries,
    [string]$Path
  )

  $payloads = @()
  foreach ($entry in @($Entries | Where-Object { $_.path -eq $Path })) {
    $body = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.body_b64))
    $payloads += ,(Read-JsonMap -JsonText $body)
  }
  return $payloads
}

# Read the current transcript and return true when it contains a forbidden
# string that should never be emitted by the uploader.
function Test-TranscriptContains([string]$TranscriptPath, [string]$ForbiddenText) {
  if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) { return $false }
  $content = Get-Content -LiteralPath $TranscriptPath -Raw -Encoding UTF8
  return $content.Contains($ForbiddenText)
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
  $contextPath = Join-Path $toptDir "context.json"
  $telemetryFactsPath = Join-Path $toptDir "telemetry_facts.json"
  if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    throw "missing context.json after sync preflight at $contextPath"
  }
  if (-not (Test-Path -LiteralPath $telemetryFactsPath -PathType Leaf)) {
    throw "missing telemetry_facts.json after sync preflight at $telemetryFactsPath"
  }
  $telemetryFactsManifest = Join-Path $tempRoot "telemetry_facts_manifest.txt"
  [System.IO.File]::WriteAllText($telemetryFactsManifest, "`t$telemetryFactsPath`n", (New-Object System.Text.UTF8Encoding($false)))
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

  $env:TESTLOGS_DIR = Join-Path $tempRoot "bazel-testlogs"
  $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS = "1"
  $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
  if ([string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP = $tempDir }
  if ([string]::IsNullOrWhiteSpace($env:TMP)) { $env:TMP = $tempDir }

  function Initialize-WindowsTelemetryOutputs {
    param(
      [string]$Root,
      [string]$ServiceName,
      [string]$RuntimeName,
      [string]$EnvValue,
      [string]$RuntimeIdPrefix,
      [bool]$HasMessageBatchAnchor,
      [bool]$IncludeEmptyEnvField
    )

    $testsDir = Join-Path $Root "payloads/tests"
    $coverageDir = Join-Path $Root "payloads/coverage"
    $telemetryDir = Join-Path $Root "payloads/telemetry"
    New-Item -ItemType Directory -Force -Path $testsDir, $coverageDir, $telemetryDir | Out-Null
    Copy-Item -LiteralPath $snapshotFile -Destination (Join-Path $testsDir "span_events_windows.json") -Force
    '{"mock_mode":"ok"}' | Set-Content -LiteralPath (Join-Path $coverageDir "coverage_windows.json") -Encoding UTF8

    $envField = if ($IncludeEmptyEnvField) { '"env": "none",' } else { '' }
    @"
{
  "api_version": "v2",
  "request_type": "app-started",
  "runtime_id": "${RuntimeIdPrefix}-aux-runtime",
  "application": {
    "service_name": "$ServiceName",
    $envField
    "language_name": "$RuntimeName",
    "tracer_version": "3.40.0"
  },
  "payload": {
    "marker": "$RuntimeIdPrefix-aux"
  }
}
"@ | Set-Content -LiteralPath (Join-Path $telemetryDir "telemetry_${RuntimeIdPrefix}_010.json") -Encoding UTF8

    $anchorRequestType = if ($HasMessageBatchAnchor) { "message-batch" } else { "app-closing" }
    $anchorPayload = if ($HasMessageBatchAnchor) {
@"
  "payload": [
    {
      "request_type": "generate-metrics",
      "payload": {
        "namespace": "civisibility",
        "series": [
          {
            "metric": "existing.windows.metric",
            "points": [[1710000000, 1]],
            "type": "count",
            "tags": ["marker:${RuntimeIdPrefix}-existing", "provider:bazel"],
            "common": true,
            "namespace": "civisibility"
          }
        ]
      }
    }
  ]
"@
    } else {
@"
  "payload": {
    "marker": "${RuntimeIdPrefix}-anchor"
  }
"@
    }

    @"
{
  "api_version": "v2",
  "request_type": "$anchorRequestType",
  "runtime_id": "${RuntimeIdPrefix}-anchor-runtime",
  $(if ($HasMessageBatchAnchor) { '"seq_id": 11,' } else { '"seq_id": 9,' })
  "tracer_time": 1710000000,
  "application": {
    "service_name": "$ServiceName",
    $envField
    "language_name": "$RuntimeName",
    "tracer_version": "2.9.0-dev"
  },
$anchorPayload
}
"@ | Set-Content -LiteralPath (Join-Path $telemetryDir "telemetry_${RuntimeIdPrefix}_020.json") -Encoding UTF8
  }

  function Read-NewLogEntries {
    param([int]$StartIndex)
    $allEntries = @(Read-JsonLog -Path $mockLog)
    if ($StartIndex -ge $allEntries.Count) { return @() }
    return @($allEntries | Select-Object -Skip $StartIndex)
  }

  function Assert-TopTelemetryBatch {
    param(
      [object[]]$Entries,
      [string]$ExpectedService,
      [string]$ExpectedEnv,
      [string[]]$ExpectedMetrics,
      [string]$ExpectedRuntimeId
    )
    $batch = @(
      $Entries |
        Where-Object { $_.path -like "*/apmtelemetry" } |
        ForEach-Object {
          $payload = Read-JsonMap -JsonText ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.body_b64)))
          if ((Get-JsonValue -Object $payload -Key "request_type") -ne "message-batch") { return }
          $application = Get-JsonValue -Object $payload -Key "application"
          if (-not $application) { return }
          if ((Get-JsonValue -Object $application -Key "service_name") -ne $ExpectedService) { return }
          [PSCustomObject]@{
            Payload = $payload
            RuntimeId = Get-JsonValue -Object $payload -Key "runtime_id"
            SeqId = Get-JsonValue -Object $payload -Key "seq_id"
            Env = Get-JsonValue -Object $application -Key "env"
            MetricNames = @(Get-TelemetryMetricNames -Payload $payload)
          }
        } |
        Where-Object { $_ }
    )
    if ($batch.Count -ne 1) {
      throw "expected exactly one telemetry message-batch for service '$ExpectedService', saw $($batch.Count)"
    }
    if ($batch[0].RuntimeId -ne $ExpectedRuntimeId) {
      throw "unexpected telemetry runtime_id for service '$ExpectedService': $($batch[0].RuntimeId)"
    }
    if ($batch[0].Env -ne $ExpectedEnv) {
      throw "unexpected telemetry env for service '$ExpectedService': expected '$ExpectedEnv' but saw '$($batch[0].Env)'"
    }
    foreach ($metric in $ExpectedMetrics) {
      if (-not ($batch[0].MetricNames -contains $metric)) {
        throw "telemetry batch for service '$ExpectedService' missing expected metric '$metric' (saw: $($batch[0].MetricNames -join ','))"
      }
    }
  }

  # Scenario 1: env mismatch should still match and normalize outbound env.
  $mismatchOutputs = Join-Path $tempRoot "bazel-testlogs/mismatch/pkg/target/test.outputs"
  Initialize-WindowsTelemetryOutputs -Root $mismatchOutputs -ServiceName "mock-service" -RuntimeName "go" -EnvValue "CI" -RuntimeIdPrefix "mismatch" -HasMessageBatchAnchor $true -IncludeEmptyEnvField $true
  $mismatchFactsPath = Join-Path $tempRoot "mismatch_telemetry_facts.json"
  @'
{
  "schema_version": 1,
  "service_name": "mock-service",
  "runtime_name": "go",
  "env": "CI",
  "counts": [
    {
      "name": "git_requests.settings",
      "value": 1,
      "tags": []
    },
    {
      "name": "known_tests.request",
      "value": 1,
      "tags": []
    },
    {
      "name": "test_management_tests.request",
      "value": 1,
      "tags": []
    }
  ],
  "distributions": [
    {
      "name": "known_tests.response_tests",
      "value": 0,
      "tags": []
    }
  ]
}
'@ | Set-Content -LiteralPath $mismatchFactsPath -Encoding UTF8

  $mismatchContextPath = Join-Path $tempRoot "mismatch_context.json"
  Copy-Item -LiteralPath $contextPath -Destination $mismatchContextPath -Force
  $mismatchContext = Get-Content -LiteralPath $mismatchContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $mismatchContext | Add-Member -NotePropertyName "ci.provider.name" -NotePropertyValue "github" -Force
  $mismatchContext | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $mismatchContextPath -Encoding UTF8
  $mismatchManifest = Join-Path $tempRoot "mismatch_telemetry_facts_manifest.txt"
  [System.IO.File]::WriteAllText($mismatchManifest, "`t$mismatchFactsPath`n", (New-Object System.Text.UTF8Encoding($false)))
  Render-UploaderTemplate -TemplatePath $psTemplate -OutputPath $renderedUploader -ContextJsonPath $mismatchContextPath -TelemetryFactsManifestPath $mismatchManifest

  $env:TESTLOGS_DIR = Join-Path $tempRoot "bazel-testlogs"
  $env:DD_API_KEY = [string]::new("0", 32)
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $mismatchTranscript = Join-Path $tempRoot "mismatch.transcript.txt"
  $mismatchStart = @(Read-JsonLog -Path $mockLog).Count
  $mismatchExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs -TranscriptPath $mismatchTranscript
  if ($mismatchExitCode -ne 0) {
    throw "agentless uploader execution failed with exit code $mismatchExitCode"
  }
  $mismatchEntries = Read-NewLogEntries -StartIndex $mismatchStart
  $mismatchTelemetry = @(Get-TelemetryPayloadsByPath -Entries $mismatchEntries -Path "/api/v2/apmtelemetry")
  if ($mismatchTelemetry.Count -ne 2) {
    throw "expected 2 telemetry uploads for the env-mismatch scenario, saw $($mismatchTelemetry.Count)"
  }
  $mismatchEnvs = @(
    $mismatchTelemetry |
      ForEach-Object {
        $application = Get-JsonValue -Object $_ -Key "application"
        Get-JsonValue -Object $application -Key "env"
      } |
      Where-Object { $_ }
  )
  if (($mismatchEnvs -join ",") -ne "CI,CI") {
    throw "unexpected env normalization for env-mismatch scenario: $($mismatchEnvs -join ',')"
  }
  Assert-TopTelemetryBatch -Entries $mismatchEntries -ExpectedService "mock-service" -ExpectedEnv "CI" -ExpectedMetrics @("existing.windows.metric", "git_requests.settings", "known_tests.response_tests", "test_management_tests.request") -ExpectedRuntimeId "mismatch-anchor-runtime"
  $mismatchBatch = @(
    Get-TelemetryPayloadsByPath -Entries $mismatchEntries -Path "/api/v2/apmtelemetry" |
      Where-Object {
        $application = Get-JsonValue -Object $_ -Key "application"
        (Get-JsonValue -Object $_ -Key "request_type") -eq "message-batch" -and
        (Get-JsonValue -Object $application -Key "service_name") -eq "mock-service"
      }
  )
  $existingWindowsTags = @(Get-TelemetryMetricTags -Payload $mismatchBatch[0] -MetricName "existing.windows.metric")
  if (-not ($existingWindowsTags -contains "provider:bazel/github")) {
    throw "expected existing.windows.metric to rewrite provider:bazel with the detected provider, saw $($existingWindowsTags -join ',')"
  }
  if ($existingWindowsTags -contains "provider:bazel") {
    throw "expected existing.windows.metric to stop sending the bare provider:bazel tag when a provider is detected"
  }
  if (Test-TranscriptContains -TranscriptPath $mismatchTranscript -ForbiddenText "posting '' (body '')") {
    throw "env-mismatch transcript unexpectedly contained an empty synthetic upload"
  }

  # Scenario 2: empty-env facts should still augment, and synthetic uploads must
  # never queue an empty anchor/body path.
  $emptyOutputs = Join-Path $tempRoot "bazel-testlogs/empty/pkg/target/test.outputs"
  Initialize-WindowsTelemetryOutputs -Root $emptyOutputs -ServiceName "empty-env-service" -RuntimeName "go" -EnvValue "" -RuntimeIdPrefix "empty" -HasMessageBatchAnchor $false -IncludeEmptyEnvField $true
  $emptyFactsPath = Join-Path $tempRoot "empty_telemetry_facts.json"
  @'
{
  "schema_version": 1,
  "service_name": "empty-env-service",
  "runtime_name": "go",
  "counts": [
    {
      "name": "git_requests.settings",
      "value": 1,
      "tags": []
    },
    {
      "name": "test_management_tests.request",
      "value": 1,
      "tags": []
    }
  ],
  "distributions": [
    {
      "name": "known_tests.response_tests",
      "value": 0,
      "tags": []
    }
  ]
}
'@ | Set-Content -LiteralPath $emptyFactsPath -Encoding UTF8
  $emptyContextPath = Join-Path $tempRoot "empty_context.json"
  Copy-Item -LiteralPath $contextPath -Destination $emptyContextPath -Force
  $emptyManifest = Join-Path $tempRoot "empty_telemetry_facts_manifest.txt"
  [System.IO.File]::WriteAllText($emptyManifest, "`t$emptyFactsPath`n", (New-Object System.Text.UTF8Encoding($false)))
  Render-UploaderTemplate -TemplatePath $psTemplate -OutputPath $renderedUploader -ContextJsonPath $emptyContextPath -TelemetryFactsManifestPath $emptyManifest

  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENTLESS_URL -ErrorAction SilentlyContinue
  $env:DD_TEST_OPTIMIZATION_AGENT_URL = "http://127.0.0.1:$port"
  $emptyTranscript = Join-Path $tempRoot "empty.transcript.txt"
  $emptyStart = @(Read-JsonLog -Path $mockLog).Count
  $emptyExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs -TranscriptPath $emptyTranscript
  if ($emptyExitCode -ne 0) {
    throw "evp uploader execution failed with exit code $emptyExitCode"
  }
  $emptyEntries = Read-NewLogEntries -StartIndex $emptyStart
  $emptyTelemetry = @(
    Get-TelemetryPayloadsByPath -Entries $emptyEntries -Path "/telemetry/proxy/api/v2/apmtelemetry" |
      Where-Object {
        $application = Get-JsonValue -Object $_ -Key "application"
        (Get-JsonValue -Object $application -Key "service_name") -eq "empty-env-service"
      }
  )
  if ($emptyTelemetry.Count -ne 3) {
    throw "expected 3 telemetry uploads for the empty-env service scenario, saw $($emptyTelemetry.Count)"
  }
  $emptyBatch = @(
    $emptyTelemetry |
      Where-Object { (Get-JsonValue -Object $_ -Key "request_type") -eq "message-batch" } |
      ForEach-Object {
        $application = Get-JsonValue -Object $_ -Key "application"
        [PSCustomObject]@{
          Env = Get-JsonValue -Object $application -Key "env"
          MetricNames = @(Get-TelemetryMetricNames -Payload $_)
        }
      }
  )
  if ($emptyBatch.Count -ne 1) {
    throw "expected exactly one synthetic telemetry batch for the empty-env scenario, saw $($emptyBatch.Count)"
  }
  if ($emptyBatch[0].Env -ne "none") {
    throw "unexpected synthetic env for the empty-env scenario: $($emptyBatch[0].Env)"
  }
  foreach ($metric in @("git_requests.settings", "test_management_tests.request", "known_tests.response_tests")) {
    if (-not ($emptyBatch[0].MetricNames -contains $metric)) {
      throw "synthetic telemetry batch missing expected metric '$metric' (saw: $($emptyBatch[0].MetricNames -join ','))"
    }
  }
  if (Test-TranscriptContains -TranscriptPath $emptyTranscript -ForbiddenText "posting '' (body '')") {
    throw "empty-env transcript unexpectedly contained an empty synthetic upload"
  }

  # Scenario 3: when no provider is present in the resolved context, telemetry
  # uploads must leave provider:bazel unchanged.
  $noProviderOutputs = Join-Path $tempRoot "bazel-testlogs/no-provider/pkg/target/test.outputs"
  $noProviderTelemetryDir = Join-Path $noProviderOutputs "payloads/telemetry"
  New-Item -ItemType Directory -Force -Path $noProviderTelemetryDir | Out-Null
  @'
{
  "api_version": "v2",
  "request_type": "message-batch",
  "runtime_id": "no-provider-runtime",
  "seq_id": 13,
  "tracer_time": 1710000200,
  "application": {
    "service_name": "no-provider-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "payload": [
    {
      "request_type": "generate-metrics",
      "payload": {
        "namespace": "civisibility",
        "series": [
          {
            "metric": "existing.no_provider.metric",
            "points": [[1710000200, 1]],
            "type": "count",
            "tags": ["provider:bazel", "marker:no-provider"],
            "common": true,
            "namespace": "civisibility"
          }
        ]
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $noProviderTelemetryDir "telemetry_no_provider_001.json") -Encoding UTF8
  $noProviderContextPath = Join-Path $tempRoot "no_provider_context.json"
  '{}' | Set-Content -LiteralPath $noProviderContextPath -Encoding UTF8
  Render-UploaderTemplate -TemplatePath $psTemplate -OutputPath $renderedUploader -ContextJsonPath $noProviderContextPath -TelemetryFactsManifestPath ""

  $env:TESTLOGS_DIR = Join-Path $tempRoot "bazel-testlogs"
  $env:DD_API_KEY = [string]::new("0", 32)
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $noProviderTranscript = Join-Path $tempRoot "no-provider.transcript.txt"
  $noProviderStart = @(Read-JsonLog -Path $mockLog).Count
  $noProviderExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs -TranscriptPath $noProviderTranscript
  if ($noProviderExitCode -ne 0) {
    throw "no-provider uploader execution failed with exit code $noProviderExitCode"
  }
  $noProviderEntries = Read-NewLogEntries -StartIndex $noProviderStart
  $noProviderTelemetry = @(
    Get-TelemetryPayloadsByPath -Entries $noProviderEntries -Path "/api/v2/apmtelemetry" |
      Where-Object {
        $application = Get-JsonValue -Object $_ -Key "application"
        (Get-JsonValue -Object $application -Key "service_name") -eq "no-provider-service"
      }
  )
  if ($noProviderTelemetry.Count -ne 1) {
    throw "expected 1 telemetry upload for the no-provider scenario, saw $($noProviderTelemetry.Count)"
  }
  $noProviderTags = @(Get-TelemetryMetricTags -Payload $noProviderTelemetry[0] -MetricName "existing.no_provider.metric")
  if (-not ($noProviderTags -contains "provider:bazel")) {
    throw "expected no-provider scenario to keep provider:bazel unchanged, saw $($noProviderTags -join ',')"
  }
  if (@($noProviderTags | Where-Object { $_ -like "provider:bazel/*" }).Count -gt 0) {
    throw "expected no-provider scenario to avoid adding a provider suffix, saw $($noProviderTags -join ',')"
  }

  Write-Host "Windows integration harness passed (PowerShell-only uploader path)."
} finally {
  if ($serverProc -and -not $serverProc.HasExited) {
    Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
  }
  Pop-Location
}
