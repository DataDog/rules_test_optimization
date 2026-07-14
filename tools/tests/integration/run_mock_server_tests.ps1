#!/usr/bin/env pwsh
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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

# Run the uploader while capturing its combined stdout/stderr so assertions can
# inspect the real child-process debug stream.
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
  $capturedOutput = @(& $PowerShellPath @(@("-NoProfile", "-NonInteractive") + $(if ((Split-Path -Leaf $PowerShellPath).ToLowerInvariant() -eq "powershell.exe") { @("-ExecutionPolicy", "Bypass") } else { @() }) + @("-File", $ScriptPath) + @($ForwardedArgs)) 2>&1 | ForEach-Object { $_.ToString() })
  $exitCode = Get-NativeExitCode
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $content = if ($capturedOutput.Count -gt 0) { ($capturedOutput -join [Environment]::NewLine) + [Environment]::NewLine } else { "" }
  [System.IO.File]::WriteAllText($TranscriptPath, $content, $utf8NoBom)
  return $exitCode
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
    [string]$ContextManifestPath = "",
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
    "__DDTPL_CONTEXT_MANIFEST_RLOC__" = ""
    "__DDTPL_CONTEXT_MANIFEST_PATH__" = $ContextManifestPath
    "__DDTPL_CONTEXT_JSON_RLOC__" = ""
    "__DDTPL_CONTEXT_JSON_PATH__" = $ContextJsonPath
    "__DDTPL_TELEMETRY_FACTS_MANIFEST_RLOC__" = ""
    "__DDTPL_TELEMETRY_FACTS_MANIFEST_PATH__" = $TelemetryFactsManifestPath
    "__DDTPL_SCHEMA_JSON_RLOC__" = ""
    "__DDTPL_SCHEMA_JSON_PATH__" = ""
    "__DDTPL_SCHEMA_VALIDATOR_RLOC__" = ""
    "__DDTPL_SCHEMA_VALIDATOR_PATH__" = ""
    "__DDTPL_BEP_ARTIFACT_STAGE_HELPER_RLOC__" = "tools/core/bep_artifact_stage_helper.py"
    "__DDTPL_DOCTOR_RUNTIME_RLOC__" = "tools/core/test_optimization_doctor.py"
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

# Read only the newly appended mock-server log entries for one scenario.
function Read-NewLogEntries {
  param(
    [int]$StartIndex,
    [string]$Path = $mockLog
  )
  $allEntries = @(Read-JsonLog -Path $Path)
  if ($StartIndex -ge $allEntries.Count) { return @() }
  return @($allEntries | Select-Object -Skip $StartIndex)
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

function Get-JsonCollectionCount {
  param($Value)
  if ($null -eq $Value) { return 0 }
  if ($Value -is [System.Collections.IDictionary]) { return $Value.Keys.Count }
  if ($Value -is [System.Array]) { return $Value.Length }
  return 1
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
      $tags = Get-JsonValue -Object $series -Key "tags"
      if ($null -eq $tags) {
        return @()
      }
      if ($tags -is [System.Collections.IDictionary]) {
        # Some Windows-hosted JSON shapes materialize an empty tag array as an
        # empty dictionary. Treat that the same as "no tags" so the parity
        # assertions reflect the uploaded telemetry rather than the host shape.
        if ($tags.Count -eq 0) {
          return @()
        }
      }
      return @($tags | Where-Object { $null -ne $_ -and $_ -ne "" })
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

# Read the latest test-event metadata for one CI Visibility test resource from
# mock-server request logs.
function Get-CiTestEventMeta {
  param(
    [object[]]$Entries,
    [string]$Resource,
    [string]$ExpectedBazelPackage = ""
  )

  for ($entryIndex = $Entries.Count - 1; $entryIndex -ge 0; $entryIndex--) {
    $entry = $Entries[$entryIndex]
    if ((Get-JsonValue -Object $entry -Key "path") -ne "/api/v2/citestcycle") { continue }
    $body = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-JsonValue -Object $entry -Key "body_b64")))
    $payload = Read-JsonMap -JsonText $body
    foreach ($event in @(Get-JsonValue -Object $payload -Key "events")) {
      if ((Get-JsonValue -Object $event -Key "type") -ne "test") { continue }
      $content = Get-JsonValue -Object $event -Key "content"
      if ((Get-JsonValue -Object $content -Key "resource") -ne $Resource) { continue }
      $meta = Get-JsonValue -Object $content -Key "meta"
      if (-not [string]::IsNullOrEmpty($ExpectedBazelPackage)) {
        if ((Get-JsonValue -Object $meta -Key "bazel.package") -ne $ExpectedBazelPackage) { continue }
      }
      return $meta
    }
  }
  return $null
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
$originalExecutionLogMode = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE
if ([string]::IsNullOrWhiteSpace($env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE)) {
  # Most scenarios in this harness use hand-written payload directories rather
  # than a preceding `bazel test` invocation, so they opt into legacy optional
  # filtering. Dedicated scenarios below assert the CI default and
  # execution-log cache-safety behavior.
  $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE = "optional"
}

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

  # Canonical runtime-name sync metadata fetch for sync extension coverage.
  $syncWorkspace = Join-Path $tempRoot "sync_metadata_fetch_ws"
  New-Item -ItemType Directory -Force -Path $syncWorkspace | Out-Null
  $repoRootForModule = $repoRoot.Replace("\", "/")
  $moduleContent = @"
module(name = "topt-windows-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")

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
    enabled_by_env = True,
    service = "mock-service",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_nodejs",
    enabled_by_env = True,
    service = "mock-service-nodejs",
    runtime_name = "nodejs",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_dotnet",
    enabled_by_env = True,
    service = "mock-service-dotnet",
    runtime_name = "dotnet",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_ruby",
    enabled_by_env = True,
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

  $syncMetadataFetchOutBase = Join-Path $tempRoot "sync_metadata_fetch_out"
  $bazelFlags = @("--output_base=$syncMetadataFetchOutBase")
  $repoEnvs = @(
    "--repo_env=DD_API_KEY=mock",
    "--repo_env=DD_TEST_OPTIMIZATION_ENABLED=1",
    "--repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL=http://127.0.0.1:$port",
    "--repo_env=DD_ENV=ci",
    "--repo_env=DD_GIT_REPOSITORY_URL=https://example.com/repo.git",
    "--repo_env=DD_GIT_BRANCH=main",
    "--repo_env=DD_GIT_COMMIT_SHA=1111111",
    "--repo_env=DD_GIT_HEAD_COMMIT=1111111",
    "--repo_env=DD_GIT_COMMIT_MESSAGE=Test_commit",
    "--repo_env=DD_GIT_HEAD_MESSAGE=Test_head",
    "--repo_env=DD_GIT_TAG=v1.0.0",

    # Keep the sync metadata fetch bound to the explicit DD_GIT_* fixture metadata.
    "--repo_env=GITHUB_SHA=",
    "--repo_env=GITHUB_EVENT_PATH="
  )

  # -------------------------------------------------------------------------
  # Scenario: disabled repositories render complete local stubs and never fetch.
  # -------------------------------------------------------------------------
  # Run this before the enabled sync so the request-log delta is isolated from
  # the baseline API traffic below.
  $disabledOutputBase = Join-Path $tempRoot "disabled_sync_out"
  $disabledLogStart = @(Read-JsonLog -Path $mockLog).Count
  $disabledRepoEnvs = @(
    "--repo_env=DD_TEST_OPTIMIZATION_ENABLED=0",
    "--repo_env=DISABLE_CI_METADATA=1"
  )
  $savedApiKey = $env:DD_API_KEY
  $savedSite = $env:DD_SITE
  $savedEnabled = $env:DD_TEST_OPTIMIZATION_ENABLED
  $hadApiKey = Test-Path Env:DD_API_KEY
  $hadSite = Test-Path Env:DD_SITE
  $hadEnabled = Test-Path Env:DD_TEST_OPTIMIZATION_ENABLED
  Push-Location $syncWorkspace
  try {
    Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:DD_SITE -ErrorAction SilentlyContinue
    Remove-Item Env:DD_TEST_OPTIMIZATION_ENABLED -ErrorAction SilentlyContinue
    $disabledCqueryOutput = @(
      Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs @(
        "--output_base=$disabledOutputBase",
        "cquery",
        "@test_optimization_data//:test_optimization_files",
        "--output=files"
      ) + $disabledRepoEnvs
    )
    $disabledCqueryExitCode = Get-NativeExitCode
    if ($disabledCqueryExitCode -ne 0) {
      throw "disabled sync cquery failed with exit code $disabledCqueryExitCode"
    }
    $disabledContextCqueryOutput = @(
      Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs @(
        "--output_base=$disabledOutputBase",
        "cquery",
        "@test_optimization_data//:test_optimization_context",
        "--output=files"
      ) + $disabledRepoEnvs
    )
    $disabledContextCqueryExitCode = Get-NativeExitCode
    if ($disabledContextCqueryExitCode -ne 0) {
      throw "disabled sync context cquery failed with exit code $disabledContextCqueryExitCode"
    }
    $disabledCqueryOutput += $disabledContextCqueryOutput
    $disabledBuildOutput = @(
      Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs @(
        "--output_base=$disabledOutputBase",
        "build",
        "@test_optimization_data//:test_optimization_files"
      ) + $disabledRepoEnvs
    )
    $disabledBuildExitCode = Get-NativeExitCode
    if ($disabledBuildExitCode -ne 0) {
      throw "disabled sync build failed with exit code $disabledBuildExitCode"
    }
    $disabledContextBuildOutput = @(
      Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs @(
        "--output_base=$disabledOutputBase",
        "build",
        "@test_optimization_data//:test_optimization_context"
      ) + $disabledRepoEnvs
    )
    $disabledContextBuildExitCode = Get-NativeExitCode
    if ($disabledContextBuildExitCode -ne 0) {
      throw "disabled sync context build failed with exit code $disabledContextBuildExitCode"
    }
  } finally {
    if ($hadApiKey) { $env:DD_API_KEY = $savedApiKey } else { Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue }
    if ($hadSite) { $env:DD_SITE = $savedSite } else { Remove-Item Env:DD_SITE -ErrorAction SilentlyContinue }
    if ($hadEnabled) { $env:DD_TEST_OPTIMIZATION_ENABLED = $savedEnabled } else { Remove-Item Env:DD_TEST_OPTIMIZATION_ENABLED -ErrorAction SilentlyContinue }
    Pop-Location
  }
  $disabledCqueryText = (@($disabledCqueryOutput) -join "`n")
  foreach ($requiredFile in @("settings.json", "known_tests.json", "test_management.json", "flaky_tests.json", "manifest.txt", "context.json")) {
    if (-not $disabledCqueryText.Contains($requiredFile)) {
      throw "disabled sync cquery is missing $requiredFile"
    }
  }
  $disabledSettings = $null
  $disabledSettingsRelativePath = @($disabledCqueryText -split "`r?`n" | Where-Object { $_ -match 'test_optimization_data.*[\\/]\.testoptimization[\\/]cache[\\/]http[\\/]settings\.json$' } | Select-Object -First 1)
  $disabledCqueryBases = @(
    $disabledOutputBase,
    (Join-Path $disabledOutputBase "execroot/_main"),
    (Join-Path $disabledOutputBase "execroot/__main__")
  )
  foreach ($relativePath in $disabledSettingsRelativePath) {
    foreach ($basePath in $disabledCqueryBases) {
      $candidatePath = Join-Path $basePath $relativePath.Trim()
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $disabledSettings = Get-Item -LiteralPath $candidatePath
        break
      }
    }
    if ($disabledSettings) { break }
  }
  if (-not $disabledSettings) {
    throw "disabled sync did not materialize the expected stub repository"
  }
  $disabledRepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $disabledSettings.FullName)))
  $disabledSettingsMap = Read-JsonMap -JsonText (Get-Content -LiteralPath $disabledSettings.FullName -Raw -Encoding UTF8)
  $disabledSettingsData = Get-JsonValue -Object $disabledSettingsMap -Key "data"
  $disabledSettingsAttributes = Get-JsonValue -Object $disabledSettingsData -Key "attributes"
  if ((Get-JsonValue -Object $disabledSettingsAttributes -Key "known_tests_enabled") -ne $false -or
      (Get-JsonValue -Object (Get-JsonValue -Object $disabledSettingsAttributes -Key "test_management") -Key "enabled") -ne $false -or
      (Get-JsonValue -Object $disabledSettingsAttributes -Key "flaky_test_retries_enabled") -ne $false) {
    throw "disabled settings.json does not contain the canonical false flags"
  }
  $knownTestsValue = Read-JsonMap -JsonText (Get-Content -LiteralPath (Join-Path $disabledRepoDir ".testoptimization/cache/http/known_tests.json") -Raw -Encoding UTF8)
  $knownTestsAttributes = Get-JsonValue -Object $knownTestsValue -Key "data"
  $knownTestsAttributes = Get-JsonValue -Object $knownTestsAttributes -Key "attributes"
  $knownTestsMap = Get-JsonValue -Object $knownTestsAttributes -Key "tests"
  if ((Get-JsonCollectionCount $knownTestsMap) -ne 0) { throw "disabled known_tests.json is not empty" }
  $testManagementValue = Read-JsonMap -JsonText (Get-Content -LiteralPath (Join-Path $disabledRepoDir ".testoptimization/cache/http/test_management.json") -Raw -Encoding UTF8)
  $testManagementAttributes = Get-JsonValue -Object $testManagementValue -Key "data"
  $testManagementAttributes = Get-JsonValue -Object $testManagementAttributes -Key "attributes"
  $testManagementMap = Get-JsonValue -Object $testManagementAttributes -Key "modules"
  if ((Get-JsonCollectionCount $testManagementMap) -ne 0) { throw "disabled test_management.json is not empty" }
  $flakyValue = Read-JsonMap -JsonText (Get-Content -LiteralPath (Join-Path $disabledRepoDir ".testoptimization/cache/http/flaky_tests.json") -Raw -Encoding UTF8)
  $flakyData = Get-JsonValue -Object $flakyValue -Key "data"
  if ((Get-JsonCollectionCount $flakyData) -ne 0) { throw "disabled flaky_tests.json is not empty" }
  $disabledContextPath = Join-Path $disabledRepoDir ".testoptimization/context.json"
  $disabledContext = Read-JsonMap -JsonText (Get-Content -LiteralPath $disabledContextPath -Raw -Encoding UTF8)
  if ((Get-JsonValue -Object $disabledContext -Key "topt.sync.enabled") -ne $false) {
    throw "disabled context.json is missing topt.sync.enabled=false"
  }
  $disabledTelemetryPath = Join-Path $disabledRepoDir ".testoptimization/telemetry_facts.json"
  if (-not (Get-Content -LiteralPath $disabledTelemetryPath -Raw -Encoding UTF8).Contains('"sync.disabled"')) {
    throw "disabled telemetry_facts.json is missing sync.disabled"
  }
  $disabledLogEnd = @(Read-JsonLog -Path $mockLog).Count
  if ($disabledLogStart -ne $disabledLogEnd) {
    throw "disabled sync unexpectedly contacted the mock metadata server"
  }

  Push-Location $syncWorkspace
  try {
    Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("fetch", "//:all_sync_payloads") + $repoEnvs))
    $syncFetchExitCode = Get-NativeExitCode
    if ($syncFetchExitCode -ne 0) {
      throw "sync metadata fetch command failed with exit code $syncFetchExitCode"
    }
    Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("build", "//:all_sync_payloads") + $repoEnvs))
    $syncBuildExitCode = Get-NativeExitCode
    if ($syncBuildExitCode -ne 0) {
      throw "sync metadata fetch build failed with exit code $syncBuildExitCode"
    }
  } finally {
    Pop-Location
  }

  $cqueryOutput = Invoke-BazelCommand -BazelInvoker $bazelInvoker -BazelArgs (@($bazelFlags + @("cquery", "@test_optimization_data//:test_optimization_files", "--output=files") + $repoEnvs))
  $syncCqueryExitCode = Get-NativeExitCode
  if ($syncCqueryExitCode -ne 0) {
    throw "sync metadata fetch cquery failed with exit code $syncCqueryExitCode"
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
    $syncMetadataFetchOutBase,
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

  if (-not $settingsPath) {
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
    throw "failed to resolve settings.json path from sync metadata fetch cquery output (requested_output_base=$syncMetadataFetchOutBase, actual_output_base=$actualOutputBase, execution_root=$executionRoot, external_roots=$externalRootsSample, existing_external_roots=$existingExternalRoots, cquery_sample=$cquerySample)"
  }
  $toptHttpDir = Split-Path -Parent $settingsPath
  $toptCacheDir = Split-Path -Parent $toptHttpDir
  $toptDir = Split-Path -Parent $toptCacheDir
  $contextPath = Join-Path $toptDir "context.json"
  $telemetryFactsPath = Join-Path $toptDir "telemetry_facts.json"
  if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    throw "missing context.json after sync metadata fetch at $contextPath"
  }
  $contextMap = Read-JsonMap -JsonText (Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8)
  $enforceBazelContextKeys = $contextPath -notlike "*+example_stub_repo_extension*"
  if ($enforceBazelContextKeys -and [string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $contextMap -Key "bazel.rule_name"))) {
    $contextCandidates = @()
    $knownSettingsCandidates = @()
    $settingsCandidatesVar = Get-Variable -Name settingsCandidates -ErrorAction SilentlyContinue
    if ($settingsCandidatesVar) {
      $knownSettingsCandidates = @($settingsCandidatesVar.Value | Sort-Object Score, Path)
    }
    foreach ($settingsCandidate in $knownSettingsCandidates) {
      $candidateToptDir = Split-Path -Parent (Split-Path -Parent $settingsCandidate.Path)
      $candidateContextPath = Join-Path $candidateToptDir "context.json"
      if (-not (Test-Path -LiteralPath $candidateContextPath -PathType Leaf)) { continue }
      $candidateMap = Read-JsonMap -JsonText (Get-Content -LiteralPath $candidateContextPath -Raw -Encoding UTF8)
      if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $candidateMap -Key "bazel.rule_name"))) { continue }
      $contextCandidates += [pscustomobject]@{
        Path = $candidateContextPath
        Map = $candidateMap
      }
    }
    foreach ($externalRoot in $externalRoots) {
      if (-not (Test-Path -LiteralPath $externalRoot -PathType Container)) { continue }
      $candidatePaths = Get-ChildItem -LiteralPath $externalRoot -Recurse -File -Filter "context.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*/.testoptimization/context.json" }
      foreach ($candidate in $candidatePaths) {
        $candidateMap = Read-JsonMap -JsonText (Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8)
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $candidateMap -Key "bazel.rule_name"))) { continue }
        $contextCandidates += [pscustomobject]@{
          Path = $candidate.FullName
          Map = $candidateMap
        }
      }
    }
    if ($contextCandidates.Count -gt 0) {
      $preferredContext = $contextCandidates | Sort-Object Path | Select-Object -First 1
      $contextPath = $preferredContext.Path
      $contextMap = $preferredContext.Map
    }
  }
  if ($enforceBazelContextKeys) {
    foreach ($key in @("bazel.rule_name", "bazel.rule_version", "bazel.os", "bazel.arch")) {
      if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $contextMap -Key $key))) {
        throw "context.json missing Bazel metadata key '$key' after sync metadata fetch"
      }
    }
    foreach ($key in @("test.bazel.rule_name", "test.bazel.rule_version")) {
      if ($null -ne (Get-JsonValue -Object $contextMap -Key $key)) {
        throw "context.json unexpectedly contains legacy Bazel metadata key '$key' after sync metadata fetch"
      }
    }
    if ((Get-JsonValue -Object $contextMap -Key "bazel.os") -ne (Get-JsonValue -Object $contextMap -Key "os.platform")) {
      throw "context.json bazel.os must match os.platform after sync metadata fetch"
    }
    if ((Get-JsonValue -Object $contextMap -Key "bazel.arch") -ne (Get-JsonValue -Object $contextMap -Key "os.architecture")) {
      throw "context.json bazel.arch must match os.architecture after sync metadata fetch"
    }
  }
  if (-not (Test-Path -LiteralPath $telemetryFactsPath -PathType Leaf)) {
    throw "missing telemetry_facts.json after sync metadata fetch at $telemetryFactsPath"
  }
  $telemetryFactsManifest = Join-Path $tempRoot "telemetry_facts_manifest.txt"
  [System.IO.File]::WriteAllText($telemetryFactsManifest, "`t$telemetryFactsPath`n", (New-Object System.Text.UTF8Encoding($false)))
  $exportPath = Join-Path (Split-Path -Parent $toptDir) "export.bzl"
  if (-not (Test-Path -LiteralPath $exportPath -PathType Leaf)) {
    throw "missing export.bzl after sync metadata fetch at $exportPath"
  }
  $exportContent = Get-Content -LiteralPath $exportPath -Raw -Encoding UTF8
  foreach ($runtime in @("go", "python", "java", "nodejs", "dotnet", "ruby")) {
    if (-not $exportContent.Contains("`"$runtime`": {")) {
      throw "export.bzl missing runtime key '$runtime'"
    }
  }

  $nodejsContextPath = $null
  $nodejsContextCandidates = @()
  $nodejsSearchRoots = @()
  $settingsRepoDir = Split-Path -Parent $toptDir
  if (-not [string]::IsNullOrWhiteSpace($settingsRepoDir)) {
    $nodejsSearchRoots += (Split-Path -Parent $settingsRepoDir)
  }
  $nodejsSearchRoots += $externalRoots
  $nodejsSearchRoots = @(
    $nodejsSearchRoots |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  )
  foreach ($externalRoot in $nodejsSearchRoots) {
    if ([string]::IsNullOrWhiteSpace($externalRoot)) { continue }
    if (-not (Test-Path -LiteralPath $externalRoot -PathType Container)) { continue }
    $repoDirs = Get-ChildItem -LiteralPath $externalRoot -Directory -Force -ErrorAction SilentlyContinue
    foreach ($repoDir in $repoDirs) {
      $normalized = $repoDir.FullName -replace '\\', '/'
      if ($normalized -notlike "*test_optimization_data_nodejs*") { continue }
      $candidatePath = Join-Path $repoDir.FullName ".testoptimization/context.json"
      if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }
      $nodejsContextCandidates += (Resolve-Path -LiteralPath $candidatePath).Path
    }
  }
  $nodejsContextPath = ($nodejsContextCandidates | Sort-Object -Unique | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($nodejsContextPath)) {
    $nodejsRootsSample = ($nodejsSearchRoots | Select-Object -First 8) -join ","
    throw "failed to resolve nodejs context.json path from sync metadata fetch output (search_roots=$nodejsRootsSample)"
  }

  $env:TESTLOGS_DIR = Join-Path $tempRoot "bazel-testlogs"
  $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS = "1"
  $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
  if ([string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP = $tempDir }
  if ([string]::IsNullOrWhiteSpace($env:TMP)) { $env:TMP = $tempDir }
  $sharedTestlogsDir = $env:TESTLOGS_DIR

  function Initialize-WindowsCiTestOutputs {
    param(
      [string]$Root
    )

    $testsDir = Join-Path $Root "payloads/tests"
    $coverageDir = Join-Path $Root "payloads/coverage"
    New-Item -ItemType Directory -Force -Path $testsDir, $coverageDir | Out-Null
    Copy-Item -LiteralPath $snapshotFile -Destination (Join-Path $testsDir "span_events_windows.json") -Force
    '{"mock_mode":"ok"}' | Set-Content -LiteralPath (Join-Path $coverageDir "coverage_windows.json") -Encoding UTF8
  }

  $multiContextManifest = Join-Path $tempRoot "multi_context_manifest.txt"
  [System.IO.File]::WriteAllText(
    $multiContextManifest,
    "test_optimization_data`t$contextPath`t`n" + "test_optimization_data_nodejs`t$nodejsContextPath`t`n",
    (New-Object System.Text.UTF8Encoding($false))
  )

  # Scenario: when multiple bundled contexts are present, the uploader must
  # select the context that matches the payload-side repo selector.
  $multiContextTestlogsDir = Join-Path $tempRoot "bazel-testlogs-multi-context"
  $multiContextOutputs = Join-Path $multiContextTestlogsDir "multi_context/pkg/target/test.outputs"
  Initialize-WindowsCiTestOutputs -Root $multiContextOutputs
  @'
{
  "bazel.package": "//src/nodejs-project",
  "bazel.target": "//src/nodejs-project:hello_test",
  "bazel.test_optimization.repo_name": "test_optimization_data_nodejs",
  "bazel.test_optimization.service_name": "mock-service-nodejs",
  "bazel.test_optimization.runtime_name": "nodejs",
  "bazel.go.payload_selection": "module"
}
'@ | Set-Content -LiteralPath (Join-Path $multiContextOutputs "bazel_target_metadata.json") -Encoding UTF8

  Render-UploaderTemplate -TemplatePath $psTemplate -OutputPath $renderedUploader -ContextManifestPath $multiContextManifest -ContextJsonPath $contextPath -TelemetryFactsManifestPath $telemetryFactsManifest

  $env:TESTLOGS_DIR = $multiContextTestlogsDir
  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $dryRunTranscript = Join-Path $tempRoot "multi_context_dry_run.transcript.txt"
  $dryRunStart = @(Read-JsonLog -Path $mockLog).Count
  $dryRunArgs = @()
  if ($ForwardArgs) { $dryRunArgs += $ForwardArgs }
  $dryRunArgs += @("--dry-run", "--validate-enrichment", "--expected-enriched-tag=bazel.go.payload_selection")
  $dryRunExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $dryRunArgs -TranscriptPath $dryRunTranscript
  if ($dryRunExitCode -ne 0) {
    throw "multi-context uploader dry-run failed with exit code $dryRunExitCode`n$(Get-Content -LiteralPath $dryRunTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $dryRunOutput = Get-Content -LiteralPath $dryRunTranscript -Raw -Encoding UTF8
  if (-not $dryRunOutput.Contains("dry-run validated enriched test payload")) {
    throw "multi-context uploader dry-run did not validate enriched test payloads"
  }
  if (-not $dryRunOutput.Contains("dry-run done")) {
    throw "multi-context uploader dry-run did not finish in dry-run mode"
  }
  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $dryRunStart).Count -ne 0) {
    throw "multi-context uploader dry-run unexpectedly sent requests to the mock server"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $multiContextOutputs "payloads/tests/span_events_windows.json") -PathType Leaf)) {
    throw "multi-context uploader dry-run deleted the source test payload"
  }

  # Scenario: CI defaults to cache-safe uploads. If no BEP or legacy execution
  # log is available, the uploader must fail closed unless the caller opts out
  # explicitly.
  $ciRequiredTranscript = Join-Path $tempRoot "ci_requires_execution_log.transcript.txt"
  $requiredTranscript = Join-Path $tempRoot "required_execution_log.transcript.txt"
  $ciOptOutTranscript = Join-Path $tempRoot "ci_execution_log_opt_out.transcript.txt"
  $missingLogWorkspace = Join-Path $tempRoot "missing-execution-log-workspace"
  New-Item -ItemType Directory -Force -Path $missingLogWorkspace | Out-Null
  $savedCi = $env:CI
  $savedExecutionLogMode = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE
  $savedExecutionLogJson = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON
  $savedBuildWorkspaceDirectory = $env:BUILD_WORKSPACE_DIRECTORY
  try {
    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON -ErrorAction SilentlyContinue
    $env:BUILD_WORKSPACE_DIRECTORY = $missingLogWorkspace
    $env:CI = "true"
    Push-Location $missingLogWorkspace
    try {
      $ciRequiredExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run") -TranscriptPath $ciRequiredTranscript
      if ($ciRequiredExitCode -eq 0) {
        throw "CI uploader unexpectedly succeeded without freshness filtering`n$(Get-Content -LiteralPath $ciRequiredTranscript -Raw -ErrorAction SilentlyContinue)"
      }
      $ciRequiredOutput = Get-Content -LiteralPath $ciRequiredTranscript -Raw -Encoding UTF8
      if (-not $ciRequiredOutput.Contains("freshness filtering is required in CI or required mode") -or -not $ciRequiredOutput.Contains("--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=.topt/bazel-bep.json")) {
        throw "CI missing-freshness failure was not actionable`n$ciRequiredOutput"
      }

      $env:CI = ""
      $requiredExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--execution-log-mode=required") -TranscriptPath $requiredTranscript
      if ($requiredExitCode -eq 0) {
        throw "required-mode uploader unexpectedly succeeded without freshness filtering`n$(Get-Content -LiteralPath $requiredTranscript -Raw -ErrorAction SilentlyContinue)"
      }
      $requiredOutput = Get-Content -LiteralPath $requiredTranscript -Raw -Encoding UTF8
      if (-not $requiredOutput.Contains("freshness filtering is required in CI or required mode") -or -not $requiredOutput.Contains("--remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=.topt/bazel-bep.json")) {
        throw "required-mode missing-freshness failure was not actionable`n$requiredOutput"
      }

      $env:CI = "true"
      $ciOptOutExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--allow-cached-payload-uploads") -TranscriptPath $ciOptOutTranscript
      if ($ciOptOutExitCode -ne 0) {
        throw "CI uploader opt-out failed with exit code $ciOptOutExitCode`n$(Get-Content -LiteralPath $ciOptOutTranscript -Raw -ErrorAction SilentlyContinue)"
      }
    } finally {
      Pop-Location
    }
  } finally {
    if ([string]::IsNullOrWhiteSpace($savedCi)) {
      Remove-Item Env:CI -ErrorAction SilentlyContinue
    } else {
      $env:CI = $savedCi
    }
    if ([string]::IsNullOrWhiteSpace($savedExecutionLogMode)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE = $savedExecutionLogMode
    }
    if ([string]::IsNullOrWhiteSpace($savedExecutionLogJson)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON = $savedExecutionLogJson
    }
    if ([string]::IsNullOrWhiteSpace($savedBuildWorkspaceDirectory)) {
      Remove-Item Env:BUILD_WORKSPACE_DIRECTORY -ErrorAction SilentlyContinue
    } else {
      $env:BUILD_WORKSPACE_DIRECTORY = $savedBuildWorkspaceDirectory
    }
  }

  # Scenario: an execution log can mark one output for a target as fresh and
  # another output for the same target as cached. The uploader must match the
  # output path as well as the target label so it does not enrich cached
  # payloads for the current commit.
  $executionLogTestlogsDir = Join-Path $tempRoot "bazel-testlogs-execution-log"
  $executionLogFreshOutputs = Join-Path $executionLogTestlogsDir "same_label/fresh_attempt/test.outputs"
  $executionLogCachedOutputs = Join-Path $executionLogTestlogsDir "same_label/cached_attempt/test.outputs"
  Initialize-WindowsCiTestOutputs -Root $executionLogFreshOutputs
  Initialize-WindowsCiTestOutputs -Root $executionLogCachedOutputs
  @'
{
  "bazel.package": "same_label",
  "bazel.target": "//same_label:payload_test"
}
'@ | Set-Content -LiteralPath (Join-Path $executionLogFreshOutputs "bazel_target_metadata.json") -Encoding UTF8
  @'
{
  "bazel.package": "same_label",
  "bazel.target": "//same_label:payload_test"
}
'@ | Set-Content -LiteralPath (Join-Path $executionLogCachedOutputs "bazel_target_metadata.json") -Encoding UTF8
  $executionLogJson = Join-Path $tempRoot "same_label_execution_log.json"
  @'
{
  "mnemonic": "TestRunner",
  "runner": "processwrapper-sandbox",
  "cacheHit": false,
  "targetLabel": "//same_label:payload_test",
  "listedOutputs": ["bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.outputs"]
}
{
  "mnemonic": "TestRunner",
  "runner": "disk cache hit",
  "cacheHit": true,
  "targetLabel": "//same_label:payload_test",
  "listedOutputs": ["bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_attempt/test.outputs"]
}
'@ | Set-Content -LiteralPath $executionLogJson -Encoding UTF8

  $env:TESTLOGS_DIR = $executionLogTestlogsDir
  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $executionLogTranscript = Join-Path $tempRoot "execution_log_filter.transcript.txt"
  $executionLogDryRunStart = @(Read-JsonLog -Path $mockLog).Count
  $executionLogArgs = @("--dry-run", "--validate-enrichment", "--execution-log-json", $executionLogJson)
  $executionLogExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $executionLogArgs -TranscriptPath $executionLogTranscript
  if ($executionLogExitCode -ne 0) {
    throw "execution-log uploader dry-run failed with exit code $executionLogExitCode`n$(Get-Content -LiteralPath $executionLogTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $executionLogOutput = Get-Content -LiteralPath $executionLogTranscript -Raw -Encoding UTF8
  if (-not $executionLogOutput.Contains("skipping cached or non-current test output")) {
    throw "execution-log uploader dry-run did not report a cached-output skip"
  }
  if (-not $executionLogOutput.Contains("dry-run validated 1 test payloads")) {
    throw "execution-log uploader dry-run did not process exactly one fresh payload"
  }
  if ($executionLogOutput.Contains("dry-run validated 2 test payloads")) {
    throw "execution-log uploader dry-run processed the cached payload for the same target label"
  }
  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $executionLogDryRunStart).Count -ne 0) {
    throw "execution-log uploader dry-run unexpectedly sent requests to the mock server"
  }

  # Scenario: BEP can mark one output for a target as fresh and other outputs
  # for the same target as cached. The uploader must prefer BEP when selected
  # and must match the output path as well as the target label. A fresh event
  # with both local test.outputs and an extra remote URI remains uploadable.
  $bepTestlogsDir = Join-Path $tempRoot "bazel-testlogs-bep"
  $bepFreshOutputs = Join-Path $bepTestlogsDir "same_label/fresh_attempt/test.outputs"
  $bepCachedLocalOutputs = Join-Path $bepTestlogsDir "same_label/cached_local_attempt/test.outputs"
  $bepCachedRemoteOutputs = Join-Path $bepTestlogsDir "same_label/cached_remote_attempt/test.outputs"
  foreach ($entry in @(
    @{ Root = $bepFreshOutputs; Resource = "Fresh.BEP"; File = "span_events_fresh_bep.json"; Source = "manual/fresh_bep.go" },
    @{ Root = $bepCachedLocalOutputs; Resource = "Cached.Local.BEP"; File = "span_events_cached_local_bep.json"; Source = "manual/cached_local_bep.go" },
    @{ Root = $bepCachedRemoteOutputs; Resource = "Cached.Remote.BEP"; File = "span_events_cached_remote_bep.json"; Source = "manual/cached_remote_bep.go" }
  )) {
    $testsDir = Join-Path $entry.Root "payloads/tests"
    New-Item -ItemType Directory -Force -Path $testsDir | Out-Null
    @"
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.2.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "$($entry.Resource)",
        "meta": {
          "test.source.file": "$($entry.Source)"
        }
      }
    }
  ]
}
"@ | Set-Content -LiteralPath (Join-Path $testsDir $entry.File) -Encoding UTF8
    @'
{
  "bazel.package": "same_label",
  "bazel.target": "//same_label:bep_payload_test"
}
'@ | Set-Content -LiteralPath (Join-Path $entry.Root "bazel_target_metadata.json") -Encoding UTF8
  }
  # A plain control target can leave a test.outputs directory with no payloads
  # and no Bazel metadata. BEP required mode must ignore it because there is no
  # local candidate payload to authorize.
  $bepEmptyControlOutputs = Join-Path $bepTestlogsDir "same_label/empty_control/test.outputs"
  New-Item -ItemType Directory -Force -Path $bepEmptyControlOutputs | Out-Null
  $bepJson = Join-Path $tempRoot "same_label_bep.json"
  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"strategy":"local"},"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.outputs"},{"name":"diagnostic.remote","uri":"bytestream://remote-cas/blobs/abcdef/456"}]}}
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","cachedLocally":true,"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_local_attempt/test.outputs"}]}}
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"cachedRemotely":true},"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_remote_attempt/test.outputs"}]}}
'@ | Set-Content -LiteralPath $bepJson -Encoding UTF8

  $env:TESTLOGS_DIR = $bepTestlogsDir
  Remove-Item Env:DD_API_KEY -ErrorAction SilentlyContinue
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $bepDryRunTranscript = Join-Path $tempRoot "bep_filter_dry_run.transcript.txt"
  $bepDryRunStart = @(Read-JsonLog -Path $mockLog).Count
  $bepDryRunArgs = @("--dry-run", "--bep-json", $bepJson, "--freshness-source=bep", "--freshness-mode=required")
  $bepDryRunExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepDryRunArgs -TranscriptPath $bepDryRunTranscript
  if ($bepDryRunExitCode -ne 0) {
    throw "BEP uploader dry-run failed with exit code $bepDryRunExitCode`n$(Get-Content -LiteralPath $bepDryRunTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepDryRunOutput = Get-Content -LiteralPath $bepDryRunTranscript -Raw -Encoding UTF8
  if (-not $bepDryRunOutput.Contains("freshness filtering enabled: source=bep")) {
    throw "BEP uploader dry-run did not enable BEP freshness filtering`n$bepDryRunOutput"
  }
  if (-not $bepDryRunOutput.Contains("dry-run validated 1 test payloads")) {
    throw "BEP uploader dry-run did not process exactly one fresh payload`n$bepDryRunOutput"
  }
  if (-not $bepDryRunOutput.Contains("skipping cached or non-current test output")) {
    throw "BEP uploader dry-run did not report cached/non-current skips`n$bepDryRunOutput"
  }
  if ($bepDryRunOutput.Contains("bazel.target metadata is missing")) {
    throw "BEP uploader dry-run treated an empty control test.outputs directory as a payload candidate`n$bepDryRunOutput"
  }
	  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $bepDryRunStart).Count -ne 0) {
	    throw "BEP uploader dry-run unexpectedly sent requests to the mock server"
	  }

  $bepStagedTestlogsDir = Join-Path $tempRoot "bazel-testlogs-bep-staged"
  $bepStagedArtifactOutput = Join-Path $tempRoot "mock-staged-artifacts/same_label/fresh_attempt/test.outputs"
  $bepStagedLocalFresh = Join-Path $bepStagedTestlogsDir "same_label/fresh_attempt/test.outputs"
  $bepStagedJson = Join-Path $tempRoot "same_label_bep_staged_artifact.json"
  Remove-Item -LiteralPath $bepStagedTestlogsDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $tempRoot "mock-staged-artifacts") -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $bepTestlogsDir -Destination $bepStagedTestlogsDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bepStagedArtifactOutput) | Out-Null
  Copy-Item -LiteralPath $bepFreshOutputs -Destination $bepStagedArtifactOutput -Recurse -Force
  Remove-Item -LiteralPath $bepStagedLocalFresh -Recurse -Force
  $bepStagedArtifactUri = ([System.Uri]::new((Resolve-Path -LiteralPath $bepStagedArtifactOutput).Path)).AbsoluteUri
  if ([string]::IsNullOrWhiteSpace($bepStagedArtifactUri)) {
    throw "staged BEP scenario failed to build a file URI for $bepStagedArtifactOutput"
  }
@"
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"strategy":"local"},"testActionOutput":[{"name":"test.outputs","uri":"$bepStagedArtifactUri","pathPrefix":["bazel-out","x64_windows-fastbuild","testlogs","same_label","fresh_attempt"]},{"name":"diagnostic.remote","uri":"bytestream://remote-cas/blobs/abcdef/456"}]}}
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","cachedLocally":true,"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_local_attempt/test.outputs"}]}}
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"cachedRemotely":true},"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_remote_attempt/test.outputs"}]}}
"@ | Set-Content -LiteralPath $bepStagedJson -Encoding UTF8
	  if (Test-Path -LiteralPath $bepStagedLocalFresh) {
	    throw "staged BEP scenario did not remove fresh local test.outputs from copied scan root"
	  }
	  New-Item -ItemType Directory -Force -Path (Join-Path $bepStagedLocalFresh "payloads/tests") | Out-Null
	  Copy-Item -LiteralPath (Join-Path $bepStagedArtifactOutput "bazel_target_metadata.json") -Destination (Join-Path $bepStagedLocalFresh "bazel_target_metadata.json") -Force
	  "{}" | Set-Content -LiteralPath (Join-Path $bepStagedLocalFresh "payloads/tests/span_events_stale_1.json") -Encoding UTF8
	  "{}" | Set-Content -LiteralPath (Join-Path $bepStagedLocalFresh "payloads/tests/span_events_stale_2.json") -Encoding UTF8

	  $bepStagedDryRunTranscript = Join-Path $tempRoot "bep_staged_artifact_dry_run.transcript.txt"
  $bepStagedDryRunStart = @(Read-JsonLog -Path $mockLog).Count
  $bepStagedDryRunArgs = @(
    "--dry-run",
    "--bep-json", $bepStagedJson,
    "--freshness-source=bep",
    "--freshness-mode=required",
    "--artifact-source=bep",
    "--remote-artifacts=download",
    "--artifact-staging-dir", (Join-Path $tempRoot "bep-artifacts")
  )
  $savedTestlogsDir = $env:TESTLOGS_DIR
  $savedRunfilesDir = [Environment]::GetEnvironmentVariable("RUNFILES_DIR")
  $savedDebug = [Environment]::GetEnvironmentVariable("DD_TEST_OPTIMIZATION_DEBUG")
  try {
    $env:TESTLOGS_DIR = $bepStagedTestlogsDir
    $env:RUNFILES_DIR = $repoRoot
    $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
    $bepStagedDryRunExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepStagedDryRunArgs -TranscriptPath $bepStagedDryRunTranscript
  } finally {
    $env:TESTLOGS_DIR = $savedTestlogsDir
    if ($null -eq $savedRunfilesDir) {
      Remove-Item Env:RUNFILES_DIR -ErrorAction SilentlyContinue
    } else {
      $env:RUNFILES_DIR = $savedRunfilesDir
    }
    if ($null -eq $savedDebug) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_DEBUG -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_DEBUG = $savedDebug
    }
  }
  if ($bepStagedDryRunExitCode -ne 0) {
    throw "BEP staged-artifact dry-run failed with exit code $bepStagedDryRunExitCode`n$(Get-Content -LiteralPath $bepStagedDryRunTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepStagedDryRunOutput = Get-Content -LiteralPath $bepStagedDryRunTranscript -Raw -Encoding UTF8
  if (-not $bepStagedDryRunOutput.Contains("BEP artifact staging selected output key: same_label/fresh_attempt/test.outputs")) {
    throw "BEP staged-artifact dry-run did not keep the canonical output key`n$bepStagedDryRunOutput"
  }
  if ($bepStagedDryRunOutput.Contains("mock-staged-artifacts/same_label/fresh_attempt/test.outputs")) {
    throw "BEP staged-artifact dry-run derived an output key from the external artifact carrier`n$bepStagedDryRunOutput"
  }
	  if (-not $bepStagedDryRunOutput.Contains("dry-run validated 1 test payloads")) {
	    throw "BEP staged-artifact dry-run did not process exactly one fresh payload`n$bepStagedDryRunOutput"
	  }
	  $bepStagedRunsRoot = Join-Path $tempRoot "bep-artifacts/__runs"
	  if ((Test-Path -LiteralPath $bepStagedRunsRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $bepStagedRunsRoot -Force).Count -ne 0) {
	    throw "BEP staged-artifact dry-run did not clean helper-emitted per-run roots`n$bepStagedDryRunOutput"
	  }
	  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $bepStagedDryRunStart).Count -ne 0) {
	    throw "BEP staged-artifact dry-run unexpectedly sent requests to the mock server"
	  }

  $bepStagedDisabledTranscript = Join-Path $tempRoot "bep_staged_artifact_freshness_disabled.transcript.txt"
  $bepStagedDisabledStart = @(Read-JsonLog -Path $mockLog).Count
  $bepStagedDisabledArgs = @(
    "--dry-run",
    "--bep-json", $bepStagedJson,
    "--freshness-source=bep",
    "--freshness-mode=disabled",
    "--artifact-source=bep",
    "--remote-artifacts=download",
    "--artifact-staging-dir", (Join-Path $tempRoot "bep-artifacts-disabled")
  )
  $savedTestlogsDir = $env:TESTLOGS_DIR
  $savedRunfilesDir = [Environment]::GetEnvironmentVariable("RUNFILES_DIR")
  $savedDebug = [Environment]::GetEnvironmentVariable("DD_TEST_OPTIMIZATION_DEBUG")
  try {
    $env:TESTLOGS_DIR = $bepStagedTestlogsDir
    $env:RUNFILES_DIR = $repoRoot
    $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
    $bepStagedDisabledExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepStagedDisabledArgs -TranscriptPath $bepStagedDisabledTranscript
  } finally {
    $env:TESTLOGS_DIR = $savedTestlogsDir
    if ($null -eq $savedRunfilesDir) {
      Remove-Item Env:RUNFILES_DIR -ErrorAction SilentlyContinue
    } else {
      $env:RUNFILES_DIR = $savedRunfilesDir
    }
    if ($null -eq $savedDebug) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_DEBUG -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_DEBUG = $savedDebug
    }
  }
  if ($bepStagedDisabledExitCode -ne 0) {
    throw "BEP staged-artifact freshness-disabled run failed with exit code $bepStagedDisabledExitCode`n$(Get-Content -LiteralPath $bepStagedDisabledTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepStagedDisabledOutput = Get-Content -LiteralPath $bepStagedDisabledTranscript -Raw -Encoding UTF8
  if (-not $bepStagedDisabledOutput.Contains("BEP artifact staging selected output key: same_label/fresh_attempt/test.outputs")) {
    throw "BEP staged-artifact freshness-disabled run did not stage the canonical output key`n$bepStagedDisabledOutput"
  }
  if ($bepStagedDisabledOutput -notmatch "dry-run validated [1-9][0-9]* test payloads") {
    throw "BEP staged-artifact freshness-disabled run did not validate any payloads`n$bepStagedDisabledOutput"
  }
	  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $bepStagedDisabledStart).Count -ne 0) {
	    throw "BEP staged-artifact freshness-disabled run unexpectedly sent requests to the mock server"
	  }

	  $bepRemoteOnlySkipJson = Join-Path $tempRoot "remote_only_skip_stale_local.json"
@"
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"strategy":"remote"},"testActionOutput":[{"name":"test.outputs","uri":"bytestream://remote-cas/blobs/stale-local-suppression/123","pathPrefix":["bazel-out","x64_windows-fastbuild","testlogs","same_label","fresh_attempt"]}]}}
"@ | Set-Content -LiteralPath $bepRemoteOnlySkipJson -Encoding UTF8
	  $bepRemoteOnlySkipTestlogsDir = Join-Path $tempRoot "bazel-testlogs-remote-only-skip"
	  Remove-Item -LiteralPath $bepRemoteOnlySkipTestlogsDir -Recurse -Force -ErrorAction SilentlyContinue
	  New-Item -ItemType Directory -Force -Path (Join-Path $bepRemoteOnlySkipTestlogsDir "same_label/fresh_attempt") | Out-Null
	  Copy-Item -LiteralPath $bepStagedLocalFresh -Destination (Join-Path $bepRemoteOnlySkipTestlogsDir "same_label/fresh_attempt/test.outputs") -Recurse -Force
	  $bepRemoteOnlySkipTranscript = Join-Path $tempRoot "bep_remote_only_skip_stale_local.transcript.txt"
	  $bepRemoteOnlySkipArgs = @(
	    "--dry-run",
	    "--bep-json", $bepRemoteOnlySkipJson,
	    "--freshness-source=bep",
	    "--freshness-mode=disabled",
	    "--artifact-source=bep",
	    "--remote-artifacts=download",
	    "--artifact-staging-dir", (Join-Path $tempRoot "bep-artifacts-remote-skip")
	  )
	  $savedTestlogsDir = $env:TESTLOGS_DIR
	  $savedRunfilesDir = [Environment]::GetEnvironmentVariable("RUNFILES_DIR")
	  $savedDebug = [Environment]::GetEnvironmentVariable("DD_TEST_OPTIMIZATION_DEBUG")
	  $savedMaxWait = [Environment]::GetEnvironmentVariable("DD_TEST_OPTIMIZATION_MAX_WAIT_SEC")
	  try {
	    $env:TESTLOGS_DIR = $bepRemoteOnlySkipTestlogsDir
	    $env:RUNFILES_DIR = $repoRoot
	    $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
	    $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
	    $bepRemoteOnlySkipExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepRemoteOnlySkipArgs -TranscriptPath $bepRemoteOnlySkipTranscript
	  } finally {
	    $env:TESTLOGS_DIR = $savedTestlogsDir
	    if ($null -eq $savedRunfilesDir) { Remove-Item Env:RUNFILES_DIR -ErrorAction SilentlyContinue } else { $env:RUNFILES_DIR = $savedRunfilesDir }
	    if ($null -eq $savedDebug) { Remove-Item Env:DD_TEST_OPTIMIZATION_DEBUG -ErrorAction SilentlyContinue } else { $env:DD_TEST_OPTIMIZATION_DEBUG = $savedDebug }
	    if ($null -eq $savedMaxWait) { Remove-Item Env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC -ErrorAction SilentlyContinue } else { $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = $savedMaxWait }
	  }
	  if ($bepRemoteOnlySkipExitCode -ne 0) {
	    throw "remote-only BEP artifact skip scenario failed with exit code $bepRemoteOnlySkipExitCode`n$(Get-Content -LiteralPath $bepRemoteOnlySkipTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepRemoteOnlySkipOutput = Get-Content -LiteralPath $bepRemoteOnlySkipTranscript -Raw -Encoding UTF8
	  if ($bepRemoteOnlySkipOutput -match "dry-run validated [1-9]") {
	    throw "remote-only BEP artifact without downloader reused stale local payloads`n$bepRemoteOnlySkipOutput"
	  }
	  if (-not $bepRemoteOnlySkipOutput.Contains("BEP artifact staging selected output key: same_label/fresh_attempt/test.outputs")) {
	    throw "remote-only BEP artifact skip scenario did not select the stale-local suppression key`n$bepRemoteOnlySkipOutput"
	  }

	  $bepRemoteDownloadJson = Join-Path $tempRoot "remote_downloader.json"
@"
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"strategy":"remote"},"testActionOutput":[{"name":"test.outputs","uri":"bytestream://remote-cas/blobs/fake-downloader/456","pathPrefix":["bazel-out","x64_windows-fastbuild","testlogs","same_label","fresh_attempt"]}]}}
"@ | Set-Content -LiteralPath $bepRemoteDownloadJson -Encoding UTF8
	  $bepRemoteZip = Join-Path $tempRoot "fake-remote-outputs.zip"
	  if (Test-Path -LiteralPath $bepRemoteZip) { Remove-Item -LiteralPath $bepRemoteZip -Force }
	  Add-Type -AssemblyName System.IO.Compression.FileSystem
	  [System.IO.Compression.ZipFile]::CreateFromDirectory($bepStagedArtifactOutput, $bepRemoteZip)
	  $fakeDownloaderDir = Join-Path $tempRoot "downloader with spaces"
	  $bepRemoteDownloaderLog = Join-Path $tempRoot "fake-downloader-invocations.tsv"
	  if (Test-Path -LiteralPath $bepRemoteDownloaderLog) { Remove-Item -LiteralPath $bepRemoteDownloaderLog -Force }
	  New-Item -ItemType Directory -Force -Path $fakeDownloaderDir | Out-Null
	  if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
	    $fakeDownloader = Join-Path $fakeDownloaderDir "fake downloader.cmd"
@'
@echo off
setlocal
set "uri="
set "name="
set "out="
:parse
if "%~1"=="" goto done
if "%~1"=="--uri" (
  set "uri=%~2"
  shift
  shift
  goto parse
)
if "%~1"=="--name" (
  set "name=%~2"
  shift
  shift
  goto parse
)
if "%~1"=="--output" (
  set "out=%~2"
  shift
  shift
  goto parse
)
echo unexpected argument: %~1 1>&2
exit /b 2
:done
if "%uri%"=="" (
  echo missing required downloader arguments 1>&2
  exit /b 2
)
if "%name%"=="" (
  echo missing required downloader arguments 1>&2
  exit /b 2
)
if "%out%"=="" (
  echo missing required downloader arguments 1>&2
  exit /b 2
)
>>"%BEP_REMOTE_DOWNLOADER_LOG%" echo %uri%	%name%	%out%
copy /Y "%BEP_REMOTE_ZIP_SOURCE%" "%out%" >nul
'@ | Set-Content -LiteralPath $fakeDownloader -Encoding ASCII
	  } else {
	    $fakeDownloader = Join-Path $fakeDownloaderDir "fake downloader.sh"
@'
#!/usr/bin/env bash
set -euo pipefail
uri=""
name=""
out=""
while (($#)); do
  case "$1" in
    --uri) uri="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    *)
      echo "unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done
if [[ -z "$uri" || -z "$name" || -z "$out" ]]; then
  echo "missing required downloader arguments" >&2
  exit 2
fi
printf '%s\t%s\t%s\n' "$uri" "$name" "$out" >>"$BEP_REMOTE_DOWNLOADER_LOG"
cp "$BEP_REMOTE_ZIP_SOURCE" "$out"
'@ | Set-Content -LiteralPath $fakeDownloader -Encoding UTF8
	    chmod +x $fakeDownloader
	  }
	  $bepRemoteDownloadTranscript = Join-Path $tempRoot "bep_remote_downloader.transcript.txt"
	  $bepRemoteDownloadArgs = @(
	    "--dry-run",
	    "--bep-json", $bepRemoteDownloadJson,
	    "--freshness-source=bep",
	    "--freshness-mode=required",
	    "--artifact-source", "bep",
	    "--remote-artifacts", "required",
	    "--bep-artifact-downloader", $fakeDownloader,
	    "--bep-artifact-downloader-timeout-sec", "5",
	    "--artifact-staging-dir", (Join-Path $tempRoot "bep-artifacts-remote-download")
	  )
	  $savedTestlogsDir = $env:TESTLOGS_DIR
	  $savedRunfilesDir = [Environment]::GetEnvironmentVariable("RUNFILES_DIR")
	  $savedDebug = [Environment]::GetEnvironmentVariable("DD_TEST_OPTIMIZATION_DEBUG")
	  $savedZipSource = [Environment]::GetEnvironmentVariable("BEP_REMOTE_ZIP_SOURCE")
	  $savedDownloaderLog = [Environment]::GetEnvironmentVariable("BEP_REMOTE_DOWNLOADER_LOG")
	  try {
	    $env:TESTLOGS_DIR = $bepStagedTestlogsDir
	    $env:RUNFILES_DIR = $repoRoot
	    $env:DD_TEST_OPTIMIZATION_DEBUG = "1"
	    $env:BEP_REMOTE_ZIP_SOURCE = $bepRemoteZip
	    $env:BEP_REMOTE_DOWNLOADER_LOG = $bepRemoteDownloaderLog
	    $bepRemoteDownloadExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepRemoteDownloadArgs -TranscriptPath $bepRemoteDownloadTranscript
	  } finally {
	    $env:TESTLOGS_DIR = $savedTestlogsDir
	    if ($null -eq $savedRunfilesDir) { Remove-Item Env:RUNFILES_DIR -ErrorAction SilentlyContinue } else { $env:RUNFILES_DIR = $savedRunfilesDir }
	    if ($null -eq $savedDebug) { Remove-Item Env:DD_TEST_OPTIMIZATION_DEBUG -ErrorAction SilentlyContinue } else { $env:DD_TEST_OPTIMIZATION_DEBUG = $savedDebug }
	    if ($null -eq $savedZipSource) { Remove-Item Env:BEP_REMOTE_ZIP_SOURCE -ErrorAction SilentlyContinue } else { $env:BEP_REMOTE_ZIP_SOURCE = $savedZipSource }
	    if ($null -eq $savedDownloaderLog) { Remove-Item Env:BEP_REMOTE_DOWNLOADER_LOG -ErrorAction SilentlyContinue } else { $env:BEP_REMOTE_DOWNLOADER_LOG = $savedDownloaderLog }
	  }
	  if ($bepRemoteDownloadExitCode -ne 0) {
	    throw "remote BEP fake-downloader scenario failed with exit code $bepRemoteDownloadExitCode`n$(Get-Content -LiteralPath $bepRemoteDownloadTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepRemoteDownloadOutput = Get-Content -LiteralPath $bepRemoteDownloadTranscript -Raw -Encoding UTF8
	  if (-not $bepRemoteDownloadOutput.Contains("dry-run validated 1 test payloads")) {
	    throw "remote BEP fake-downloader scenario did not validate the downloaded payload`n$bepRemoteDownloadOutput"
	  }
	  $downloaderLog = Get-Content -LiteralPath $bepRemoteDownloaderLog -Raw -ErrorAction Stop
	  if (-not ($downloaderLog -like "*bytestream://remote-cas/blobs/fake-downloader/456`ttest.outputs`t*")) {
	    throw "remote BEP fake-downloader scenario did not pass the expected URI/name contract`n$downloaderLog"
	  }
	  if ($downloaderLog -notmatch "outputs[.]zip(\r?\n)?$") {
	    throw "remote BEP fake-downloader scenario did not request an outputs.zip destination`n$downloaderLog"
	  }

		  $bepOptionalFilterTranscript = Join-Path $tempRoot "bep_filter_optional.transcript.txt"
	  $bepOptionalFilterStart = @(Read-JsonLog -Path $mockLog).Count
	  $bepOptionalFilterArgs = @("--dry-run", "--bep-json", $bepJson, "--freshness-source=bep", "--freshness-mode=optional")
	  $bepOptionalFilterExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepOptionalFilterArgs -TranscriptPath $bepOptionalFilterTranscript
	  if ($bepOptionalFilterExitCode -ne 0) {
	    throw "optional BEP uploader dry-run failed with exit code $bepOptionalFilterExitCode`n$(Get-Content -LiteralPath $bepOptionalFilterTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepOptionalFilterOutput = Get-Content -LiteralPath $bepOptionalFilterTranscript -Raw -Encoding UTF8
	  if (-not $bepOptionalFilterOutput.Contains("freshness filtering enabled: source=bep") -or -not $bepOptionalFilterOutput.Contains("dry-run validated 1 test payloads")) {
	    throw "optional BEP dry-run did not filter to the fresh payload`n$bepOptionalFilterOutput"
	  }
	  if (-not $bepOptionalFilterOutput.Contains("skipping cached or non-current test output")) {
	    throw "optional BEP dry-run did not report cached/non-current skips`n$bepOptionalFilterOutput"
	  }
	  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $bepOptionalFilterStart).Count -ne 0) {
	    throw "optional BEP uploader dry-run unexpectedly sent requests to the mock server"
	  }

	  $bepUploadTranscript = Join-Path $tempRoot "bep_filter_upload.transcript.txt"
	  $bepUploadStart = @(Read-JsonLog -Path $mockLog).Count
	  $env:DD_API_KEY = "mock"
  $bepUploadArgs = @("--bep-json", $bepJson, "--freshness-source=bep", "--freshness-mode=required")
  $bepUploadExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepUploadArgs -TranscriptPath $bepUploadTranscript
  if ($bepUploadExitCode -ne 0) {
    throw "BEP uploader upload failed with exit code $bepUploadExitCode`n$(Get-Content -LiteralPath $bepUploadTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepUploadEntries = Read-NewLogEntries -Path $mockLog -StartIndex $bepUploadStart
  if ($null -eq (Get-CiTestEventMeta -Entries $bepUploadEntries -Resource "Fresh.BEP")) {
    throw "fresh BEP payload was not uploaded"
  }
  foreach ($cachedResource in @("Cached.Local.BEP", "Cached.Remote.BEP")) {
    if ($null -ne (Get-CiTestEventMeta -Entries $bepUploadEntries -Resource $cachedResource)) {
      throw "cached BEP payload was uploaded: $cachedResource"
    }
  }

  $bepUploadDeleteTranscript = Join-Path $tempRoot "bep_filter_upload_delete.transcript.txt"
  $bepUploadDeleteArgs = @("--bep-json", $bepJson, "--freshness-source=bep", "--freshness-mode=required")
  $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS = "0"
  $bepUploadDeleteExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $bepUploadDeleteArgs -TranscriptPath $bepUploadDeleteTranscript
  $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS = "1"
  if ($bepUploadDeleteExitCode -ne 0) {
    throw "BEP uploader deletion scenario failed with exit code $bepUploadDeleteExitCode`n$(Get-Content -LiteralPath $bepUploadDeleteTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  if (Test-Path -LiteralPath (Join-Path $bepFreshOutputs "payloads/tests/span_events_fresh_bep.json") -PathType Leaf) {
    throw "fresh BEP payload was not deleted after successful upload`n$(Get-Content -LiteralPath $bepUploadDeleteTranscript -Raw -ErrorAction SilentlyContinue)"
  }
	  if (-not (Test-Path -LiteralPath (Join-Path $bepCachedLocalOutputs "payloads/tests/span_events_cached_local_bep.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $bepCachedRemoteOutputs "payloads/tests/span_events_cached_remote_bep.json") -PathType Leaf)) {
	    throw "cached BEP payloads were deleted even though they were skipped`n$(Get-Content -LiteralPath $bepUploadDeleteTranscript -Raw -ErrorAction SilentlyContinue)"
	  }

	  $bepCachedOnlyJson = Join-Path $tempRoot "cached_only_bep.json"
	  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","cachedLocally":true,"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_local_attempt/test.outputs"}]}}
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"cachedRemotely":true},"testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/cached_remote_attempt/test.outputs"}]}}
'@ | Set-Content -LiteralPath $bepCachedOnlyJson -Encoding UTF8
	  $bepCachedOnlyTranscript = Join-Path $tempRoot "bep_cached_only_upload.transcript.txt"
	  $bepCachedOnlyStart = @(Read-JsonLog -Path $mockLog).Count
	  $bepCachedOnlyExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--bep-json", $bepCachedOnlyJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepCachedOnlyTranscript
	  if ($bepCachedOnlyExitCode -ne 0) {
	    throw "cached-only BEP uploader upload failed with exit code $bepCachedOnlyExitCode`n$(Get-Content -LiteralPath $bepCachedOnlyTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  if (@(Read-NewLogEntries -Path $mockLog -StartIndex $bepCachedOnlyStart).Count -ne 0) {
	    throw "cached-only BEP upload sent requests to the mock server"
	  }
	  $bepCachedOnlyOutput = Get-Content -LiteralPath $bepCachedOnlyTranscript -Raw -Encoding UTF8
	  if (-not $bepCachedOnlyOutput.Contains("skipping cached or non-current test output")) {
	    throw "cached-only BEP upload did not report cached/non-current skips`n$bepCachedOnlyOutput"
	  }
	  if (-not (Test-Path -LiteralPath (Join-Path $bepCachedLocalOutputs "payloads/tests/span_events_cached_local_bep.json") -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $bepCachedRemoteOutputs "payloads/tests/span_events_cached_remote_bep.json") -PathType Leaf)) {
	    throw "cached-only BEP upload deleted cached payloads`n$bepCachedOnlyOutput"
	  }

	  $bepFreshTestsDir = Join-Path $bepFreshOutputs "payloads/tests"
	  New-Item -ItemType Directory -Force -Path $bepFreshTestsDir | Out-Null
	  @'
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.2.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "Fresh.BEP",
        "meta": {
          "test.source.file": "manual/fresh_bep.go"
        }
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $bepFreshTestsDir "span_events_fresh_bep.json") -Encoding UTF8

  $defaultBepWorkspace = Join-Path $tempRoot "default-bep-workspace"
  $defaultBepDir = Join-Path $defaultBepWorkspace ".topt"
  New-Item -ItemType Directory -Force -Path $defaultBepDir | Out-Null
  Copy-Item -LiteralPath $bepJson -Destination (Join-Path $defaultBepDir "bazel-bep.json") -Force
  $defaultBepTranscript = Join-Path $tempRoot "default_bep_filter.transcript.txt"
  $savedCiForBep = $env:CI
  $savedBepJson = $env:DD_TEST_OPTIMIZATION_BEP_JSON
  $savedExecutionLogModeForBep = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE
  $savedBuildWorkspaceDirectoryForBep = $env:BUILD_WORKSPACE_DIRECTORY
  try {
	    Remove-Item Env:DD_TEST_OPTIMIZATION_BEP_JSON -ErrorAction SilentlyContinue
	    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
	    $env:BUILD_WORKSPACE_DIRECTORY = $defaultBepWorkspace
	    Remove-Item Env:CI -ErrorAction SilentlyContinue
	    Push-Location $defaultBepWorkspace
	    try {
	      $defaultBepExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run") -TranscriptPath $defaultBepTranscript
	    } finally {
      Pop-Location
    }
    if ($defaultBepExitCode -ne 0) {
      throw "ignored-default-BEP dry-run failed with exit code $defaultBepExitCode`n$(Get-Content -LiteralPath $defaultBepTranscript -Raw -ErrorAction SilentlyContinue)"
    }
    $defaultBepOutput = Get-Content -LiteralPath $defaultBepTranscript -Raw -Encoding UTF8
	    if ($defaultBepOutput.Contains("freshness filtering enabled: source=bep")) {
	      throw "uploader discovered default BEP without explicit configuration`n$defaultBepOutput"
	    }
	    if (-not $defaultBepOutput.Contains("freshness filtering is not configured")) {
	      throw "ignored-default-BEP scenario did not explain unconfigured freshness`n$defaultBepOutput"
	    }

	    $defaultBepCiTranscript = Join-Path $tempRoot "default_bep_ci.transcript.txt"
	    $env:CI = "true"
	    Push-Location $defaultBepWorkspace
	    try {
	      $defaultBepCiExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run") -TranscriptPath $defaultBepCiTranscript
	    } finally {
	      Pop-Location
	    }
	    if ($defaultBepCiExitCode -eq 0) {
	      throw "CI uploader unexpectedly discovered default BEP without explicit configuration`n$(Get-Content -LiteralPath $defaultBepCiTranscript -Raw -ErrorAction SilentlyContinue)"
	    }
	    $defaultBepCiOutput = Get-Content -LiteralPath $defaultBepCiTranscript -Raw -Encoding UTF8
	    if (-not $defaultBepCiOutput.Contains("freshness filtering is required in CI or required mode")) {
	      throw "CI default BEP discovery failure was not actionable`n$defaultBepCiOutput"
	    }
	  } finally {
    if ([string]::IsNullOrWhiteSpace($savedCiForBep)) {
      Remove-Item Env:CI -ErrorAction SilentlyContinue
    } else {
      $env:CI = $savedCiForBep
    }
    if ([string]::IsNullOrWhiteSpace($savedBepJson)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_BEP_JSON -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_BEP_JSON = $savedBepJson
    }
    if ([string]::IsNullOrWhiteSpace($savedExecutionLogModeForBep)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE = $savedExecutionLogModeForBep
    }
    if ([string]::IsNullOrWhiteSpace($savedBuildWorkspaceDirectoryForBep)) {
      Remove-Item Env:BUILD_WORKSPACE_DIRECTORY -ErrorAction SilentlyContinue
    } else {
      $env:BUILD_WORKSPACE_DIRECTORY = $savedBuildWorkspaceDirectoryForBep
    }
	  }

	  $bepConflictFreshJson = Join-Path $tempRoot "conflict_fresh_bep.json"
	  $bepConflictCachedJson = Join-Path $tempRoot "conflict_cached_bep.json"
	  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","testActionOutput":[{"name":"test.log","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.log"}]}}
'@ | Set-Content -LiteralPath $bepConflictFreshJson -Encoding UTF8
	  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","cachedLocally":true,"testActionOutput":[{"name":"test.log","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.log"}]}}
'@ | Set-Content -LiteralPath $bepConflictCachedJson -Encoding UTF8
	  $env:TESTLOGS_DIR = $bepTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepConflictTranscript = Join-Path $tempRoot "bep_conflict.transcript.txt"
	  $bepConflictExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepConflictFreshJson, "--bep-json", $bepConflictCachedJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepConflictTranscript
	  if ($bepConflictExitCode -eq 0) {
	    throw "conflicting BEP freshness scenario unexpectedly succeeded`n$(Get-Content -LiteralPath $bepConflictTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepConflictOutput = Get-Content -LiteralPath $bepConflictTranscript -Raw -Encoding UTF8
	  if (-not $bepConflictOutput.Contains("reported as both fresh and cached")) {
	    throw "conflicting BEP freshness failure was not actionable`n$bepConflictOutput"
	  }

	  $bepMixedRemoteJson = Join-Path $tempRoot "mixed_remote_only_bep.json"
	  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","testActionOutput":[{"name":"test.log","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.log"},{"name":"test.outputs","uri":"bytestream://remote-cas/blobs/remoteoutputs/789"}]}}
'@ | Set-Content -LiteralPath $bepMixedRemoteJson -Encoding UTF8
	  $env:TESTLOGS_DIR = $bepTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepMixedRemoteTranscript = Join-Path $tempRoot "bep_mixed_remote_only.transcript.txt"
	  $bepMixedRemoteExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepMixedRemoteJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepMixedRemoteTranscript
	  if ($bepMixedRemoteExitCode -eq 0) {
	    throw "mixed local-log/remote-output BEP scenario unexpectedly succeeded`n$(Get-Content -LiteralPath $bepMixedRemoteTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepMixedRemoteOutput = Get-Content -LiteralPath $bepMixedRemoteTranscript -Raw -Encoding UTF8
		  if (-not $bepMixedRemoteOutput.Contains("BEP references remote-only test outputs")) {
		    throw "mixed local-log/remote-output failure was not actionable`n$bepMixedRemoteOutput"
		  }

		  $bepMixedRemoteZipJson = Join-Path $tempRoot "mixed_remote_outputs_zip_bep.json"
		  @'
{"id":{"testResult":{"label":"//same_label:bep_payload_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","testActionOutput":[{"name":"test.log","uri":"file:///execroot/main/bazel-out/x64_windows-fastbuild/testlogs/same_label/fresh_attempt/test.log"},{"name":"outputs.zip","uri":"bytestream://remote-cas/blobs/remotezip/790"}]}}
'@ | Set-Content -LiteralPath $bepMixedRemoteZipJson -Encoding UTF8
		  $env:TESTLOGS_DIR = $bepTestlogsDir
		  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
		  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
		  $bepMixedRemoteZipTranscript = Join-Path $tempRoot "bep_mixed_remote_outputs_zip.transcript.txt"
		  $bepMixedRemoteZipExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepMixedRemoteZipJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepMixedRemoteZipTranscript
		  if ($bepMixedRemoteZipExitCode -eq 0) {
		    throw "mixed local-log/remote-outputs.zip BEP scenario unexpectedly succeeded`n$(Get-Content -LiteralPath $bepMixedRemoteZipTranscript -Raw -ErrorAction SilentlyContinue)"
		  }
		  $bepMixedRemoteZipOutput = Get-Content -LiteralPath $bepMixedRemoteZipTranscript -Raw -Encoding UTF8
		  if (-not $bepMixedRemoteZipOutput.Contains("BEP references remote-only test outputs")) {
		    throw "mixed local-log/remote-outputs.zip failure was not actionable`n$bepMixedRemoteZipOutput"
		  }

		  $bepRemoteOnlyTestlogsDir = Join-Path $tempRoot "bazel-testlogs-bep-remote-only"
  New-Item -ItemType Directory -Force -Path $bepRemoteOnlyTestlogsDir | Out-Null
  $bepRemoteOnlyJson = Join-Path $tempRoot "remote_only_bep.json"
  @'
{"id":{"testResult":{"label":"//remote:only_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","executionInfo":{"strategy":"remote"},"testActionOutput":[{"name":"test.outputs","uri":"bytestream://remote-cas/blobs/deadbeef/123"}]}}
'@ | Set-Content -LiteralPath $bepRemoteOnlyJson -Encoding UTF8
  $env:TESTLOGS_DIR = $bepRemoteOnlyTestlogsDir
  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
  $bepRemoteOnlyTranscript = Join-Path $tempRoot "bep_remote_only.transcript.txt"
  $bepRemoteOnlyExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepRemoteOnlyJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepRemoteOnlyTranscript
  if ($bepRemoteOnlyExitCode -eq 0) {
    throw "required BEP remote-only scenario unexpectedly succeeded`n$(Get-Content -LiteralPath $bepRemoteOnlyTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepRemoteOnlyOutput = Get-Content -LiteralPath $bepRemoteOnlyTranscript -Raw -Encoding UTF8
	  if (-not $bepRemoteOnlyOutput.Contains("BEP references remote-only test outputs") -or -not $bepRemoteOnlyOutput.Contains("--remote_download_minimal") -or -not $bepRemoteOnlyOutput.Contains("--remote_download_regex=.*test[.]outputs.*")) {
	    throw "required BEP remote-only failure was not actionable`n$bepRemoteOnlyOutput"
	  }

	  $env:TESTLOGS_DIR = $bepRemoteOnlyTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "0"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepOptionalRemoteOnlyEmptyTranscript = Join-Path $tempRoot "bep_optional_remote_only_empty.transcript.txt"
	  $bepOptionalRemoteOnlyEmptyExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepRemoteOnlyJson, "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalRemoteOnlyEmptyTranscript
	  if ($bepOptionalRemoteOnlyEmptyExitCode -ne 0) {
	    throw "optional BEP remote-only empty-testlogs scenario failed with exit code $bepOptionalRemoteOnlyEmptyExitCode`n$(Get-Content -LiteralPath $bepOptionalRemoteOnlyEmptyTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepOptionalRemoteOnlyEmptyOutput = Get-Content -LiteralPath $bepOptionalRemoteOnlyEmptyTranscript -Raw -Encoding UTF8
	  if (-not $bepOptionalRemoteOnlyEmptyOutput.Contains("warning: BEP references remote-only test outputs") -or -not $bepOptionalRemoteOnlyEmptyOutput.Contains("--remote_download_minimal") -or -not $bepOptionalRemoteOnlyEmptyOutput.Contains("--remote_download_regex=.*test[.]outputs.*")) {
	    throw "optional BEP remote-only empty-testlogs scenario did not warn`n$bepOptionalRemoteOnlyEmptyOutput"
	  }

	  $bepMissingOutputTestlogsDir = Join-Path $tempRoot "bazel-testlogs-bep-missing-output"
  $bepMissingOutputRoot = Join-Path $bepMissingOutputTestlogsDir "missing/output_test/test.outputs"
  Initialize-WindowsCiTestOutputs -Root $bepMissingOutputRoot
  @'
{
  "bazel.package": "missing",
  "bazel.target": "//missing:bep_output_test"
}
'@ | Set-Content -LiteralPath (Join-Path $bepMissingOutputRoot "bazel_target_metadata.json") -Encoding UTF8
  $bepMissingOutputJson = Join-Path $tempRoot "missing_output_bep.json"
  @'
{"id":{"testResult":{"label":"//missing:bep_output_test","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","testActionOutput":[]}}
'@ | Set-Content -LiteralPath $bepMissingOutputJson -Encoding UTF8
  $env:TESTLOGS_DIR = $bepMissingOutputTestlogsDir
  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
  $bepMissingOutputTranscript = Join-Path $tempRoot "bep_missing_output.transcript.txt"
  $bepMissingOutputExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepMissingOutputJson, "--freshness-source=bep", "--freshness-mode=required") -TranscriptPath $bepMissingOutputTranscript
  if ($bepMissingOutputExitCode -eq 0) {
    throw "required BEP missing-output scenario unexpectedly succeeded`n$(Get-Content -LiteralPath $bepMissingOutputTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepMissingOutputOutput = Get-Content -LiteralPath $bepMissingOutputTranscript -Raw -Encoding UTF8
	  if (-not $bepMissingOutputOutput.Contains("did not contain a mappable test.outputs reference")) {
	    throw "required BEP missing-output failure was not actionable`n$bepMissingOutputOutput"
	  }

	  $env:TESTLOGS_DIR = $bepTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepOptionalMissingConfigTranscript = Join-Path $tempRoot "bep_optional_missing_config.transcript.txt"
	  $bepOptionalMissingConfigExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalMissingConfigTranscript
	  if ($bepOptionalMissingConfigExitCode -ne 0) {
	    throw "optional BEP missing-config scenario failed with exit code $bepOptionalMissingConfigExitCode`n$(Get-Content -LiteralPath $bepOptionalMissingConfigTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepOptionalMissingConfigOutput = Get-Content -LiteralPath $bepOptionalMissingConfigTranscript -Raw -Encoding UTF8
		  if (-not $bepOptionalMissingConfigOutput.Contains("BEP freshness source was selected but no BEP JSON file was configured")) {
		    throw "optional BEP missing-config scenario did not warn`n$bepOptionalMissingConfigOutput"
		  }

		  $env:TESTLOGS_DIR = $bepTestlogsDir
		  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
		  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
		  $bepOptionalMissingFileTranscript = Join-Path $tempRoot "bep_optional_missing_file.transcript.txt"
		  $bepOptionalMissingFilePath = Join-Path $tempRoot "missing-optional.bep.json"
		  $bepOptionalMissingFileExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepOptionalMissingFilePath, "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalMissingFileTranscript
		  if ($bepOptionalMissingFileExitCode -ne 0) {
		    throw "optional BEP missing-file scenario failed with exit code $bepOptionalMissingFileExitCode`n$(Get-Content -LiteralPath $bepOptionalMissingFileTranscript -Raw -ErrorAction SilentlyContinue)"
		  }
		  $bepOptionalMissingFileOutput = Get-Content -LiteralPath $bepOptionalMissingFileTranscript -Raw -Encoding UTF8
		  if (-not $bepOptionalMissingFileOutput.Contains("warning: BEP JSON not found") -or -not $bepOptionalMissingFileOutput.Contains("BEP freshness filtering skipped")) {
		    throw "optional BEP missing-file scenario did not warn and continue`n$bepOptionalMissingFileOutput"
		  }

		  $env:TESTLOGS_DIR = $bepTestlogsDir
		  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
		  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
		  $bepOptionalMalformedJson = Join-Path $tempRoot "malformed-optional.bep.json"
		  "{not-json" | Set-Content -LiteralPath $bepOptionalMalformedJson -Encoding UTF8
		  $bepOptionalMalformedTranscript = Join-Path $tempRoot "bep_optional_malformed.transcript.txt"
		  $bepOptionalMalformedExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepOptionalMalformedJson, "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalMalformedTranscript
		  if ($bepOptionalMalformedExitCode -ne 0) {
		    throw "optional BEP malformed scenario failed with exit code $bepOptionalMalformedExitCode`n$(Get-Content -LiteralPath $bepOptionalMalformedTranscript -Raw -ErrorAction SilentlyContinue)"
		  }
		  $bepOptionalMalformedOutput = Get-Content -LiteralPath $bepOptionalMalformedTranscript -Raw -Encoding UTF8
		  if (-not $bepOptionalMalformedOutput.Contains("warning: failed to parse BEP JSON") -or -not $bepOptionalMalformedOutput.Contains("BEP freshness filtering skipped")) {
		    throw "optional BEP malformed scenario did not warn and continue`n$bepOptionalMalformedOutput"
		  }

		  $env:TESTLOGS_DIR = $bepTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepOptionalRemoteOnlyTranscript = Join-Path $tempRoot "bep_optional_remote_only.transcript.txt"
	  $bepOptionalRemoteOnlyExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepMixedRemoteJson, "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalRemoteOnlyTranscript
	  if ($bepOptionalRemoteOnlyExitCode -ne 0) {
	    throw "optional BEP remote-only scenario failed with exit code $bepOptionalRemoteOnlyExitCode`n$(Get-Content -LiteralPath $bepOptionalRemoteOnlyTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepOptionalRemoteOnlyOutput = Get-Content -LiteralPath $bepOptionalRemoteOnlyTranscript -Raw -Encoding UTF8
		  if (-not $bepOptionalRemoteOnlyOutput.Contains("freshness filtering enabled: source=bep") -or -not $bepOptionalRemoteOnlyOutput.Contains("warning: BEP references remote-only test outputs") -or -not $bepOptionalRemoteOnlyOutput.Contains("skipping cached or non-current test output") -or -not $bepOptionalRemoteOnlyOutput.Contains("--remote_download_minimal") -or -not $bepOptionalRemoteOnlyOutput.Contains("--remote_download_regex=.*test[.]outputs.*")) {
		    throw "optional BEP remote-only scenario did not warn and skip`n$bepOptionalRemoteOnlyOutput"
		  }

	  $env:TESTLOGS_DIR = $bepMissingOutputTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "0"
	  $bepOptionalMissingOutputTranscript = Join-Path $tempRoot "bep_optional_missing_output.transcript.txt"
	  $bepOptionalMissingOutputExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepMissingOutputJson, "--freshness-source=bep", "--freshness-mode=optional") -TranscriptPath $bepOptionalMissingOutputTranscript
	  if ($bepOptionalMissingOutputExitCode -ne 0) {
	    throw "optional BEP missing-output scenario failed with exit code $bepOptionalMissingOutputExitCode`n$(Get-Content -LiteralPath $bepOptionalMissingOutputTranscript -Raw -ErrorAction SilentlyContinue)"
	  }
	  $bepOptionalMissingOutputOutput = Get-Content -LiteralPath $bepOptionalMissingOutputTranscript -Raw -Encoding UTF8
		  if (-not $bepOptionalMissingOutputOutput.Contains("skipping cached or non-current test output") -or -not $bepOptionalMissingOutputOutput.Contains("warning: BEP optional freshness skipped") -or -not $bepOptionalMissingOutputOutput.Contains("did not contain a mappable test.outputs reference")) {
		    throw "optional BEP missing-output scenario did not warn and skip local payloads`n$bepOptionalMissingOutputOutput"
		  }

	  $env:TESTLOGS_DIR = $bepTestlogsDir
	  $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC = "30"
	  $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC = "1"
  $bepFlagPrecedenceTranscript = Join-Path $tempRoot "bep_flag_precedence.transcript.txt"
  $bepFlagPrecedenceExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run", "--bep-json", $bepJson, "--freshness-mode=required", "--execution-log-mode=disabled") -TranscriptPath $bepFlagPrecedenceTranscript
  if ($bepFlagPrecedenceExitCode -ne 0) {
    throw "BEP freshness-mode precedence scenario failed with exit code $bepFlagPrecedenceExitCode`n$(Get-Content -LiteralPath $bepFlagPrecedenceTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepFlagPrecedenceOutput = Get-Content -LiteralPath $bepFlagPrecedenceTranscript -Raw -Encoding UTF8
  if (-not $bepFlagPrecedenceOutput.Contains("freshness filtering enabled: source=bep") -or -not $bepFlagPrecedenceOutput.Contains("dry-run validated 1 test payloads")) {
    throw "legacy execution-log mode overrode explicit freshness mode`n$bepFlagPrecedenceOutput"
  }

  $bepOptOutTranscript = Join-Path $tempRoot "bep_opt_out.transcript.txt"
  $bepOptOutExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--bep-json", $bepJson, "--allow-cached-payload-uploads", "--freshness-mode=required", "--dry-run") -TranscriptPath $bepOptOutTranscript
  if ($bepOptOutExitCode -ne 0) {
    throw "BEP uploader opt-out failed with exit code $bepOptOutExitCode`n$(Get-Content -LiteralPath $bepOptOutTranscript -Raw -ErrorAction SilentlyContinue)"
  }
  $bepOptOutOutput = Get-Content -LiteralPath $bepOptOutTranscript -Raw -Encoding UTF8
  if (-not $bepOptOutOutput.Contains("freshness filtering disabled")) {
    throw "BEP opt-out did not disable freshness filtering`n$bepOptOutOutput"
  }
  if (-not $bepOptOutOutput.Contains("dry-run validated 3 test payloads")) {
    throw "BEP opt-out did not fall back to legacy discovery`n$bepOptOutOutput"
  }

  $defaultExecutionLogWorkspace = Join-Path $tempRoot "default-execution-log-workspace"
  $defaultExecutionLogDir = Join-Path $defaultExecutionLogWorkspace ".topt"
  New-Item -ItemType Directory -Force -Path $defaultExecutionLogDir | Out-Null
  Copy-Item -LiteralPath $executionLogJson -Destination (Join-Path $defaultExecutionLogDir "bazel-execution-log.json") -Force
  $defaultExecutionLogTranscript = Join-Path $tempRoot "default_execution_log_filter.transcript.txt"
  $savedCi = $env:CI
  $savedExecutionLogMode = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE
  $savedExecutionLogJson = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON
  $savedBuildWorkspaceDirectory = $env:BUILD_WORKSPACE_DIRECTORY
  try {
    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON -ErrorAction SilentlyContinue
    $env:BUILD_WORKSPACE_DIRECTORY = $defaultExecutionLogWorkspace
    $env:CI = "true"
    Push-Location $defaultExecutionLogWorkspace
    try {
      $defaultExecutionLogExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs @("--dry-run") -TranscriptPath $defaultExecutionLogTranscript
    } finally {
      Pop-Location
    }
    $defaultExecutionLogOutput = Get-Content -LiteralPath $defaultExecutionLogTranscript -Raw -Encoding UTF8
    if ($defaultExecutionLogExitCode -eq 0) {
      throw "uploader unexpectedly auto-discovered a default execution log`n$defaultExecutionLogOutput"
    }
    if (-not $defaultExecutionLogOutput.Contains("no BEP or execution log was found")) {
      throw "missing-source failure did not ignore default execution-log file`n$defaultExecutionLogOutput"
    }
    if ($defaultExecutionLogOutput.Contains("freshness filtering enabled: source=execution_log")) {
      throw "default execution-log file enabled implicit execution-log filtering`n$defaultExecutionLogOutput"
    }
  } finally {
    if ([string]::IsNullOrWhiteSpace($savedCi)) {
      Remove-Item Env:CI -ErrorAction SilentlyContinue
    } else {
      $env:CI = $savedCi
    }
    if ([string]::IsNullOrWhiteSpace($savedExecutionLogMode)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE = $savedExecutionLogMode
    }
    if ([string]::IsNullOrWhiteSpace($savedExecutionLogJson)) {
      Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON -ErrorAction SilentlyContinue
    } else {
      $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON = $savedExecutionLogJson
    }
    if ([string]::IsNullOrWhiteSpace($savedBuildWorkspaceDirectory)) {
      Remove-Item Env:BUILD_WORKSPACE_DIRECTORY -ErrorAction SilentlyContinue
    } else {
      $env:BUILD_WORKSPACE_DIRECTORY = $savedBuildWorkspaceDirectory
    }
  }
  $env:TESTLOGS_DIR = $multiContextTestlogsDir

  $multiContextTranscript = Join-Path $tempRoot "multi_context.transcript.txt"
  $multiContextStart = @(Read-JsonLog -Path $mockLog).Count
  $env:DD_API_KEY = [string]::new("0", 32)
  $env:DD_SITE = "datadoghq.com"
  $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL = "http://127.0.0.1:$port"
  Remove-Item Env:DD_TEST_OPTIMIZATION_AGENT_URL -ErrorAction SilentlyContinue
  $multiContextExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs -TranscriptPath $multiContextTranscript
  if ($multiContextExitCode -ne 0) {
    throw "multi-context uploader execution failed with exit code $multiContextExitCode"
  }

  $multiContextEntries = Read-NewLogEntries -Path $mockLog -StartIndex $multiContextStart
  $multiContextMeta = Get-CiTestEventMeta -Entries $multiContextEntries -Resource "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest" -ExpectedBazelPackage "//src/nodejs-project"
  if ($null -eq $multiContextMeta) {
    throw "missing CI test event after multi-context uploader execution"
  }
  foreach ($entry in @(
    @{ Key = "bazel.package"; Value = "//src/nodejs-project" },
    @{ Key = "bazel.target"; Value = "//src/nodejs-project:hello_test" },
    @{ Key = "bazel.test_optimization.repo_name"; Value = "test_optimization_data_nodejs" },
    @{ Key = "bazel.test_optimization.service_name"; Value = "mock-service-nodejs" },
    @{ Key = "bazel.test_optimization.runtime_name"; Value = "nodejs" },
    @{ Key = "runtime.name"; Value = "nodejs" },
    @{ Key = "runtime.version"; Value = "1.2.3" },
    @{ Key = "service.name"; Value = "mock-service-nodejs" }
  )) {
    if ((Get-JsonValue -Object $multiContextMeta -Key $entry.Key) -ne $entry.Value) {
      throw "multi-context uploader tag mismatch for $($entry.Key): expected '$($entry.Value)' but saw '$((Get-JsonValue -Object $multiContextMeta -Key $entry.Key))'"
    }
  }
  if ((Get-JsonValue -Object $multiContextMeta -Key "runtime.name") -eq "go") {
    throw "multi-context uploader reused the go runtime tag for a nodejs payload"
  }
  if ((Get-JsonValue -Object $multiContextMeta -Key "service.name") -eq "mock-service") {
    throw "multi-context uploader reused the go service tag for a nodejs payload"
  }

  # Scenario: when no bundled context matches the payload selector, uploader
  # must preserve Bazel sidecar tags and skip context-tag enrichment.
  $multiContextMissTestlogsDir = Join-Path $tempRoot "bazel-testlogs-multi-context-missing"
  $multiContextMissOutputs = Join-Path $multiContextMissTestlogsDir "multi_context_missing/pkg/target/test.outputs"
  Initialize-WindowsCiTestOutputs -Root $multiContextMissOutputs
  @'
{
  "bazel.package": "//src/python-project",
  "bazel.target": "//src/python-project:hello_test",
  "bazel.test_optimization.repo_name": "missing_runtime_repo"
}
'@ | Set-Content -LiteralPath (Join-Path $multiContextMissOutputs "bazel_target_metadata.json") -Encoding UTF8

  $multiContextMissTranscript = Join-Path $tempRoot "multi_context_missing.transcript.txt"
  $multiContextMissStart = @(Read-JsonLog -Path $mockLog).Count
  $env:TESTLOGS_DIR = $multiContextMissTestlogsDir
  $multiContextMissExitCode = Invoke-UploaderScriptWithTranscript -PowerShellPath $powerShellHost -ScriptPath $renderedUploader -ForwardedArgs $ForwardArgs -TranscriptPath $multiContextMissTranscript
  if ($multiContextMissExitCode -ne 0) {
    throw "multi-context uploader with missing repo selector failed with exit code $multiContextMissExitCode"
  }
  if (-not (Test-TranscriptContains -TranscriptPath $multiContextMissTranscript -ForbiddenText "no bundled context matched repo 'missing_runtime_repo'")) {
    throw "missing expected warning for unmatched multi-context payload"
  }

  $multiContextMissEntries = Read-NewLogEntries -Path $mockLog -StartIndex $multiContextMissStart
  $multiContextMissMeta = Get-CiTestEventMeta -Entries $multiContextMissEntries -Resource "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest" -ExpectedBazelPackage "//src/python-project"
  if ($null -eq $multiContextMissMeta) {
    throw "missing CI test event after unmatched multi-context uploader execution"
  }
  foreach ($entry in @(
    @{ Key = "bazel.package"; Value = "//src/python-project" },
    @{ Key = "bazel.target"; Value = "//src/python-project:hello_test" },
    @{ Key = "bazel.test_optimization.repo_name"; Value = "missing_runtime_repo" }
  )) {
    if ((Get-JsonValue -Object $multiContextMissMeta -Key $entry.Key) -ne $entry.Value) {
      throw "unmatched multi-context Bazel tag mismatch for $($entry.Key): expected '$($entry.Value)' but saw '$((Get-JsonValue -Object $multiContextMissMeta -Key $entry.Key))'"
    }
  }
  if ((Get-JsonValue -Object $multiContextMissMeta -Key "runtime.name") -eq "nodejs") {
    throw "unmatched multi-context run unexpectedly injected the nodejs runtime.name tag"
  }
  if ((Get-JsonValue -Object $multiContextMissMeta -Key "runtime.version") -eq "1.2.3") {
    throw "unmatched multi-context run unexpectedly injected the nodejs runtime.version tag"
  }
  if ((Get-JsonValue -Object $multiContextMissMeta -Key "service.name") -eq "mock-service-nodejs") {
    throw "unmatched multi-context run unexpectedly injected the nodejs service.name tag"
  }
  $env:TESTLOGS_DIR = $sharedTestlogsDir

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
  $mismatchEntries = Read-NewLogEntries -Path $mockLog -StartIndex $mismatchStart
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
  $settingsTags = @(Get-TelemetryMetricTags -Payload $mismatchBatch[0] -MetricName "git_requests.settings")
  if ($settingsTags.Count -ne 0) {
    throw "expected git_requests.settings to remain tagless on the uncompressed sync path, saw $($settingsTags -join ',')"
  }
  $knownTestsResponseTags = @(Get-TelemetryMetricTags -Payload $mismatchBatch[0] -MetricName "known_tests.response_tests")
  if ($knownTestsResponseTags.Count -ne 0) {
    throw "expected known_tests.response_tests to remain tagless on the uncompressed sync path, saw $($knownTestsResponseTags -join ',')"
  }
  $testManagementRequestTags = @(Get-TelemetryMetricTags -Payload $mismatchBatch[0] -MetricName "test_management_tests.request")
  if ($testManagementRequestTags.Count -ne 0) {
    throw "expected test_management_tests.request to remain tagless on the uncompressed sync path, saw $($testManagementRequestTags -join ',')"
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
  $emptyEntries = Read-NewLogEntries -Path $mockLog -StartIndex $emptyStart
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
  $noProviderEntries = Read-NewLogEntries -Path $mockLog -StartIndex $noProviderStart
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
  if ([string]::IsNullOrWhiteSpace($originalExecutionLogMode)) {
    Remove-Item Env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE -ErrorAction SilentlyContinue
  } else {
    $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE = $originalExecutionLogMode
  }
  Pop-Location
}
