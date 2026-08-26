# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Format-ArtifactReferenceForLog {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if (-not (
        $Value.StartsWith("http://", [System.StringComparison]::OrdinalIgnoreCase) -or
        $Value.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)
    )) {
        return $Value
    }
    try {
        $uri = [System.Uri]::new($Value)
        if (
            -not $uri.IsAbsoluteUri -or
            [string]::IsNullOrWhiteSpace($uri.Host) -or
            ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")
        ) {
            return "$($uri.Scheme)://redacted-invalid-url"
        }
        $host = $uri.IdnHost
        if ($host.Contains(":") -and -not $host.StartsWith("[")) {
            $host = "[$host]"
        }
        $port = ""
        if (-not $uri.IsDefaultPort) {
            $port = ":$($uri.Port)"
        }
        return "$($uri.Scheme)://$host$port$($uri.AbsolutePath)"
    } catch {
        $scheme = "http"
        if ($Value.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
            $scheme = "https"
        }
        $rest = $Value.Substring($scheme.Length + 3)
        $hashIndex = $rest.IndexOf("#")
        if ($hashIndex -ge 0) {
            $rest = $rest.Substring(0, $hashIndex)
        }
        $queryIndex = $rest.IndexOf("?")
        if ($queryIndex -ge 0) {
            $rest = $rest.Substring(0, $queryIndex)
        }
        $atIndex = $rest.LastIndexOf("@")
        if ($atIndex -ge 0) {
            $rest = $rest.Substring($atIndex + 1)
        }
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return "${scheme}://redacted-invalid-url"
        }
        return "${scheme}://$rest"
    }
}

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
function Resolve-Runfile {
    param([string]$InputRloc)

    $Rloc = $InputRloc
    $Rloc = $Rloc.Replace([char]92, [char]47)
    # Normalize relative prefixes that can appear in bzlmod runfile paths
    if ($Rloc.StartsWith("./")) { $Rloc = $Rloc.Substring(2) }
    while ($Rloc.StartsWith("../")) { $Rloc = $Rloc.Substring(3) }
    # Defensive guard: runfile labels must remain repository-relative.
    # We reject absolute/drive-qualified and parent-traversal paths so lookups
    # cannot accidentally resolve outside runfiles roots.
    if ([string]::IsNullOrEmpty($Rloc) -or $Rloc.StartsWith("/") -or ($Rloc -match '^[A-Za-z]:/') -or $Rloc -eq ".." -or $Rloc.EndsWith("/..") -or $Rloc.Contains("/../")) {
        Dbg "Resolve-Runfile rejected suspicious runfile label '$InputRloc' (normalized='$Rloc')"
        return $null
    }

    $candidates = @($Rloc)
    if ($Rloc.StartsWith("external/")) {
        $candidates += $Rloc.Substring(9)
    } else {
        # Try the external/ prefix when short_path omits it under bzlmod.
        $candidates += "external/$Rloc"
    }
    if (-not $Rloc.StartsWith("_main/")) {
        $candidates += "_main/$Rloc"
    }
    Dbg "Resolve-Runfile input='$InputRloc' normalized='$Rloc' candidates='$($candidates -join ',')'"

    if ($env:RUNFILES_DIR) {
        $rfExists = Test-Path -LiteralPath $env:RUNFILES_DIR
        Dbg "Resolve-Runfile RUNFILES_DIR='$($env:RUNFILES_DIR)' exists=$rfExists"
    } else {
        Dbg "Resolve-Runfile RUNFILES_DIR=<unset>"
    }

    $manifest = $null
    if ($env:RUNFILES_MANIFEST_FILE) {
        $mfExists = Test-Path -LiteralPath $env:RUNFILES_MANIFEST_FILE
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE='$($env:RUNFILES_MANIFEST_FILE)' exists=$mfExists"
        if ($mfExists) {
            $manifest = Get-Content -LiteralPath $env:RUNFILES_MANIFEST_FILE -Encoding UTF8
            Dbg "Resolve-Runfile manifest entries loaded=$($manifest.Count)"
        }
    } else {
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE=<unset>"
    }

    foreach ($cand in $candidates) {
        Dbg "Resolve-Runfile trying candidate '$cand'"
        # Try RUNFILES_DIR first
        if ($env:RUNFILES_DIR) {
            $candidate = Join-Path $env:RUNFILES_DIR $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Dbg "Resolve-Runfile hit RUNFILES_DIR -> '$candidate'"
                return $candidate
            }
        }

        # Try local runfiles directory fallbacks when RUNFILES_DIR is unavailable.
        # Depending on launcher/platform we may see:
        #   - <script>.runfiles
        #   - <script>.bat.runfiles
        #   - legacy $PSScriptRoot.runfiles path
        $scriptBase = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
        $runfilesDirs = @(
            "$PSScriptRoot.runfiles",
            (Join-Path $PSScriptRoot "$scriptBase.runfiles"),
            (Join-Path $PSScriptRoot "$scriptBase.bat.runfiles")
        ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
        foreach ($runfilesDir in $runfilesDirs) {
            $candidate = Join-Path $runfilesDir $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Dbg "Resolve-Runfile hit script runfiles -> '$candidate'"
                return $candidate
            }
        }

        # Try RUNFILES_MANIFEST_FILE (Windows default)
        if ($manifest) {
            # Pass 1: exact key matches (fast path, most reliable).
            foreach ($line in $manifest) {
                $lineNorm = $line
                # Some tools write manifests with UTF-8 BOM; strip it from key.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {
                    $lineNorm = $lineNorm.Substring(1)
                }
                if ($lineNorm.Length -gt $cand.Length -and $lineNorm.StartsWith($cand, [System.StringComparison]::Ordinal)) {
                    $sep = $lineNorm.Substring($cand.Length, 1)
                    if ($sep -ne ' ' -and $sep -ne "`t") { continue }
                    $path = $lineNorm.Substring($cand.Length + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        Dbg "Resolve-Runfile hit manifest exact key '$cand' -> '$path'"
                        return $path
                    }
                    Dbg "Resolve-Runfile manifest exact key '$cand' -> '$path' (not a file)"
                }
            }
            # Fallback: some manifests prefix keys with repo names (for example "<repo>/path/to/file").
            # Match entries whose key ends with "/<candidate>" or "\<candidate>".
            # Pass 2: suffix-key matches for bzlmod/workspace key variants.
            foreach ($line in $manifest) {
                $lineNorm = $line
                # Same BOM handling for suffix-key fallback.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {
                    $lineNorm = $lineNorm.Substring(1)
                }
                $spaceIdx = $lineNorm.IndexOf(' ')
                $tabIdx = $lineNorm.IndexOf("`t")
                if ($spaceIdx -lt 0) {
                    $i = $tabIdx
                } elseif ($tabIdx -lt 0) {
                    $i = $spaceIdx
                } else {
                    $i = [Math]::Min($spaceIdx, $tabIdx)
                }
                if ($i -le 0) { continue }
                $key = $lineNorm.Substring(0, $i)
                if ($key.Length -le $cand.Length) { continue }
                if ($key.EndsWith("/$cand", [System.StringComparison]::Ordinal) -or $key.EndsWith("\$cand", [System.StringComparison]::Ordinal)) {
                    $path = $lineNorm.Substring($i + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        Dbg "Resolve-Runfile hit manifest suffix key '$cand' -> '$path'"
                        return $path
                    }
                    Dbg "Resolve-Runfile manifest suffix key '$cand' -> '$path' (not a file)"
                }
            }
        }
    }

    Dbg "Resolve-Runfile miss for input '$InputRloc'"
    return $null  # Not found
}

function Resolve-ArtifactPath {
    param([string]$InputPath)

    if (-not $InputPath) { return $null }
    Dbg "Resolve-ArtifactPath input='$InputPath'"

    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        Dbg "Resolve-ArtifactPath hit direct -> '$InputPath'"
        return $InputPath
    }

    $execRoot = $null
    try {
        $execRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
    } catch {
        $execRoot = $null
    }
    if ($execRoot) {
        $candidate = Join-Path $execRoot $InputPath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Dbg "Resolve-ArtifactPath hit execroot-relative -> '$candidate'"
            return $candidate
        }
    }

    Dbg "Resolve-ArtifactPath miss for input '$InputPath'"
    return $null
}

function Resolve-RuntimeFilePath {
    param([string]$InputPath)

    if (-not $InputPath) { return $null }
    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        return $InputPath
    }
    if ($env:BUILD_WORKSPACE_DIRECTORY) {
        $workspaceCandidate = Join-Path $env:BUILD_WORKSPACE_DIRECTORY $InputPath
        if (Test-Path -LiteralPath $workspaceCandidate -PathType Leaf) {
            return $workspaceCandidate
        }
    }
    return (Resolve-ArtifactPath $InputPath)
}

# Logging functions (defined early so other functions can use them)
# Note: $Debug is set later, so Dbg checks the variable at runtime
$script:DebugMode = $false  # Will be set properly after Normalize-Bool is defined
if ($env:DD_TEST_OPTIMIZATION_DEBUG) {
    switch ($env:DD_TEST_OPTIMIZATION_DEBUG.ToLower()) {
        { $_ -in '1', 'true', 'yes' } { $script:DebugMode = $true }
    }
}
function Log([string]$msg) { [Console]::Out.WriteLine("[dd-uploader] $msg") }
function Log-Stderr([string]$msg) { [Console]::Error.WriteLine("[dd-uploader] $msg") }
function Use-OptionalBepUnavailable([string]$msg) {
    if ($script:FreshnessMode -ne "optional") { return $false }
    [Console]::Out.WriteLine("[dd-uploader] warning: $msg; BEP freshness filtering skipped and cached test outputs may be uploaded")
    $script:FreshnessSelectedSource = "none"
    $script:FreshnessEligibilityEnabled = $false
    return $true
}
function Dbg([string]$msg) { if ($script:DebugMode) { Write-Host "[dd-uploader][dbg] $msg" } }
function Write-Utf8NoBomFile([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}
$script:HttpAssemblyReady = $false
function Ensure-HttpClientTypes {
    if ($script:HttpAssemblyReady) { return $true }
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) {
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }
        if (-not ("System.Net.Http.HttpClient" -as [type])) {
            Dbg "System.Net.Http.HttpClient type unavailable after Add-Type"
            return $false
        }
        $script:HttpAssemblyReady = $true
        return $true
    } catch {
        Dbg "failed to load System.Net.Http assembly: $_"
        return $false
    }
}
Dbg "startup runfiles env: RUNFILES_DIR='$(if ($env:RUNFILES_DIR) { $env:RUNFILES_DIR } else { '<unset>' })' RUNFILES_MANIFEST_FILE='$(if ($env:RUNFILES_MANIFEST_FILE) { $env:RUNFILES_MANIFEST_FILE } else { '<unset>' })' PSScriptRoot='$PSScriptRoot'"

function Redact-HeaderValue([string]$name, [string]$value) {
    if ($name -ne 'DD-API-KEY') { return $value }
    if ([string]::IsNullOrEmpty($value)) { return $value }
    if ($value.Length -gt 4) {
        return ("****" + $value.Substring($value.Length - 4))
    }
    return "****"
}

function Dbg-Headers([string]$label, $headers) {
    if (-not $script:DebugMode) { return }
    foreach ($k in $headers.Keys) {
        $v = Redact-HeaderValue $k ($headers[$k].ToString())
        Dbg "header[$label]: ${k}: $v"
    }
}

function Normalize-DdSiteOrFail {
    param([string]$RawSite)

    $site = if ([string]::IsNullOrWhiteSpace($RawSite)) { "datadoghq.com" } else { $RawSite.Trim() }
    if ($site.Contains("://")) {
        $site = $site.Split("://", 2)[1]
    }
    if ($site.Contains("/")) {
        $site = $site.Split("/", 2)[0]
    }
    if ($site.Contains("?")) {
        $site = $site.Split("?", 2)[0]
    }
    if ($site.Contains("#")) {
        $site = $site.Split("#", 2)[0]
    }
    if ($site.StartsWith("app.", [System.StringComparison]::OrdinalIgnoreCase)) {
        $site = $site.Substring(4)
    }
    if ($site.StartsWith("api.", [System.StringComparison]::OrdinalIgnoreCase)) {
        $site = $site.Substring(4)
    }
    $site = $site.Trim().ToLowerInvariant()

    if ([string]::IsNullOrEmpty($site)) {
        throw "DD_SITE resolved to an empty hostname (input: '$RawSite')"
    }
    if ($site.Contains("@")) {
        throw "DD_SITE must not include credentials/userinfo (input: '$RawSite')"
    }
    if ($site.Contains(":")) {
        throw "DD_SITE must be a hostname without an explicit port (input: '$RawSite')"
    }
    if ($site.StartsWith(".") -or $site.EndsWith(".") -or $site.Contains("..")) {
        throw "DD_SITE must be a valid hostname (input: '$RawSite')"
    }
    if ($site -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$') {
        throw "DD_SITE contains unsupported hostname characters (input: '$RawSite')"
    }
    return $site
}

# Emit basic startTime statistics (ms) for debugging.
function Get-StartTimes($obj, [ref]$acc) {
    if ($null -eq $obj) { return }
    if ($obj -is [System.Collections.IDictionary]) {
    if ($obj.Contains("startTime")) {
        $v = $obj["startTime"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {
            $acc.Value += [double]$v
        }
    } elseif ($obj.Contains("start")) {
        $v = $obj["start"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {
            $acc.Value += [double]$v
        }
    }
        foreach ($val in $obj.Values) { Get-StartTimes $val ([ref]$acc) }
        return
    }
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
        foreach ($item in $obj) { Get-StartTimes $item ([ref]$acc) }
    }
}

function Log-StartTimeStats([string]$FilePath) {
    try {
        $payload = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $times = @()
        Get-StartTimes $payload ([ref]$times)
        if ($times.Count -eq 0) {
            Dbg "startTime stats: no startTime fields found in $FilePath"
            return
        }
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Dbg "startTime/ms range for ${FilePath}: min=$min max=$max now=$nowMs"
    } catch {
        Dbg "startTime stats failed for ${FilePath}: $_"
    }
}

# Resolve context.json path (used by upload functions for payload enrichment).
# Runtime override wins first so callers can reuse an already-fetched context
# file without reintroducing sync repo dependencies at uploader run time.
$ContextManifestRloc = "__DDTPL_CONTEXT_MANIFEST_RLOC__"
$ContextManifestPath = "__DDTPL_CONTEXT_MANIFEST_PATH__"
$ContextJsonRloc = "__DDTPL_CONTEXT_JSON_RLOC__"
$ContextJsonPath = "__DDTPL_CONTEXT_JSON_PATH__"
$TelemetryFactsManifestRloc = "__DDTPL_TELEMETRY_FACTS_MANIFEST_RLOC__"
$TelemetryFactsManifestPath = "__DDTPL_TELEMETRY_FACTS_MANIFEST_PATH__"
$ContextJsonOverride = $env:DD_TEST_OPTIMIZATION_CONTEXT_JSON
Dbg "context.json resolution inputs: override='$ContextJsonOverride' path='$ContextJsonPath' rloc='$ContextJsonRloc' manifest_path='$ContextManifestPath' manifest_rloc='$ContextManifestRloc'"
$script:ContextJson = $null
$script:PrimaryContextJson = $null
$script:ContextManifest = $null
$script:BundledContextEntries = [ordered]@{}
$contextJsonFromOverride = $false

function Resolve-ContextEntryPath {
    param(
        [string]$EntryPath,
        [string]$EntryRloc
    )

    $resolved = Resolve-ArtifactPath $EntryPath
    if ($resolved) { return $resolved }
    if ($EntryRloc) {
        $resolved = Resolve-Runfile $EntryRloc
        if ($resolved) { return $resolved }
    }
    return $null
}

function Normalize-ContextRepoKey {
    param([string]$RepoKey)

    if ([string]::IsNullOrEmpty($RepoKey)) { return $RepoKey }
    $lastPlus = $RepoKey.LastIndexOf('+')
    if ($lastPlus -ge 0 -and $lastPlus + 1 -lt $RepoKey.Length) {
        return $RepoKey.Substring($lastPlus + 1)
    }
    return $RepoKey
}

function Load-ContextManifestEntries {
    param([string]$ManifestPath)

    $script:BundledContextEntries = [ordered]@{}
    if ([string]::IsNullOrEmpty($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return
    }

    foreach ($line in (Get-Content -LiteralPath $ManifestPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 1) { continue }
        $repoKey = Normalize-ContextRepoKey $parts[0]
        if ([string]::IsNullOrWhiteSpace($repoKey)) { continue }
        $entryPath = if ($parts.Count -ge 2) { $parts[1] } else { "" }
        $entryRloc = if ($parts.Count -ge 3) { $parts[2] } else { "" }
        $resolved = Resolve-ContextEntryPath -EntryPath $entryPath -EntryRloc $entryRloc
        if (-not $resolved) {
            Dbg "context manifest entry unresolved for repo '$repoKey'"
            continue
        }
        $script:BundledContextEntries[$repoKey] = $resolved
    }
}
if ($ContextJsonOverride) {
    $script:PrimaryContextJson = Resolve-ArtifactPath $ContextJsonOverride
    if ($script:PrimaryContextJson) {
        $contextJsonFromOverride = $true
        Dbg "context.json resolved via runtime override: '$script:PrimaryContextJson'"
    } else {
        Log "warning: DD_TEST_OPTIMIZATION_CONTEXT_JSON did not resolve to a readable file; falling back to configured data"
    }
}
if (-not $script:PrimaryContextJson) {
    $script:ContextManifest = Resolve-ArtifactPath $ContextManifestPath
    if ($script:ContextManifest) {
        Dbg "context manifest resolved via direct path: '$script:ContextManifest'"
    } elseif ($ContextManifestRloc) {
        $script:ContextManifest = Resolve-Runfile $ContextManifestRloc
        if ($script:ContextManifest) {
            Dbg "context manifest resolved via runfiles: '$script:ContextManifest'"
        }
    }
    Load-ContextManifestEntries -ManifestPath $script:ContextManifest
    if ($script:BundledContextEntries.Count -gt 0) {
        $script:PrimaryContextJson = @($script:BundledContextEntries.Values)[0]
        if ($script:BundledContextEntries.Count -eq 1) {
            Dbg "context.json resolved from single bundled context: '$script:PrimaryContextJson'"
        } else {
            Dbg "primary context.json resolved from bundled manifest: '$script:PrimaryContextJson' (repos=$([string]::Join(', ', @($script:BundledContextEntries.Keys))))"
        }
    }
}
if (-not $script:PrimaryContextJson) {
    $script:PrimaryContextJson = Resolve-ArtifactPath $ContextJsonPath
    if ($script:PrimaryContextJson) {
        # Direct artifact path is preferred when launcher preserves it.
        Dbg "context.json resolved via direct path: '$script:PrimaryContextJson'"
    } elseif ($ContextJsonRloc) {
        # Runfiles fallback supports manifest-only and bzlmod path variants.
        $script:PrimaryContextJson = Resolve-Runfile $ContextJsonRloc
        if (-not $script:PrimaryContextJson) {
            Log "warning: context.json not found in runfiles; payloads will not be enriched"
        } else {
            Dbg "context.json resolved via runfiles: '$script:PrimaryContextJson'"
        }
    } else {
        Dbg "context.json not configured in data files; enrichment disabled"
    }
}
$script:ContextJson = $script:PrimaryContextJson
$script:ContextJsonFromOverride = $contextJsonFromOverride

Dbg "telemetry facts manifest resolution inputs: path='$TelemetryFactsManifestPath' rloc='$TelemetryFactsManifestRloc'"
$script:TelemetryFactsManifest = Resolve-ArtifactPath $TelemetryFactsManifestPath
if ($script:TelemetryFactsManifest) {
    Dbg "telemetry facts manifest resolved via direct path: '$script:TelemetryFactsManifest'"
} elseif ($TelemetryFactsManifestRloc) {
    $script:TelemetryFactsManifest = Resolve-Runfile $TelemetryFactsManifestRloc
    if (-not $script:TelemetryFactsManifest) {
        Dbg "telemetry facts manifest not found in runfiles"
    } else {
        Dbg "telemetry facts manifest resolved via runfiles: '$script:TelemetryFactsManifest'"
    }
} else {
    $script:TelemetryFactsManifest = $null
    Dbg "telemetry facts manifest not configured in data files"
}

# Resolve schema + validator paths (used for payload validation)
$SchemaJsonRloc = "__DDTPL_SCHEMA_JSON_RLOC__"
$SchemaJsonPath = "__DDTPL_SCHEMA_JSON_PATH__"
Dbg "schema resolution inputs: schema_path='$SchemaJsonPath' schema_rloc='$SchemaJsonRloc'"
$script:SchemaJson = Resolve-ArtifactPath $SchemaJsonPath
if ($script:SchemaJson) {
    Dbg "schema resolved via direct path: '$script:SchemaJson'"
} elseif ($SchemaJsonRloc) {
    # Keep parity with Bash: attempt runfiles resolution before disabling.
    $script:SchemaJson = Resolve-Runfile $SchemaJsonRloc
    if (-not $script:SchemaJson) {
        Log "warning: schema not found in runfiles; validation disabled"
    } else {
        Dbg "schema resolved via runfiles: '$script:SchemaJson'"
    }
} else {
    $script:SchemaJson = $null
    Dbg "schema not configured in data files; validation disabled"
}

$SchemaValidatorRloc = "__DDTPL_SCHEMA_VALIDATOR_RLOC__"
$SchemaValidatorPath = "__DDTPL_SCHEMA_VALIDATOR_PATH__"
$script:BepArtifactStageHelperRloc = "__DDTPL_BEP_ARTIFACT_STAGE_HELPER_RLOC__"
$script:DoctorRuntimeRloc = "__DDTPL_DOCTOR_RUNTIME_RLOC__"
$script:ExpectedTargetsRloc = "__DDTPL_EXPECTED_TARGETS_RLOC__"
$script:ExpectedTargetsPath = "__DDTPL_EXPECTED_TARGETS_PATH__"
$script:ExpectedTargetsFileRloc = "__DDTPL_EXPECTED_TARGETS_FILE_RLOC__"
$script:ExpectedTargetsFilePath = "__DDTPL_EXPECTED_TARGETS_FILE_PATH__"
Dbg "schema validator resolution inputs: validator_path='$SchemaValidatorPath' validator_rloc='$SchemaValidatorRloc'"
$script:SchemaValidator = Resolve-ArtifactPath $SchemaValidatorPath
if ($script:SchemaValidator) {
    Dbg "schema validator resolved via direct path: '$script:SchemaValidator'"
} elseif ($SchemaValidatorRloc) {
    # Validation is best-effort; unresolved validator disables schema checks.
    $script:SchemaValidator = Resolve-Runfile $SchemaValidatorRloc
    if (-not $script:SchemaValidator) {
        Log "warning: schema validator not found in runfiles; validation disabled"
    } else {
        Dbg "schema validator resolved via runfiles: '$script:SchemaValidator'"
    }
} else {
    $script:SchemaValidator = $null
    Dbg "schema validator not configured in data files; validation disabled"
}

# Parse context.json once (best effort)
$script:ContextObj = $null
$script:ContextJsonText = $null
$script:TelemetryProviderName = ""
if ($script:PrimaryContextJson -and (Test-Path -LiteralPath $script:PrimaryContextJson)) {
    try {
        $script:ContextJsonText = Get-Content -LiteralPath $script:PrimaryContextJson -Raw -Encoding UTF8
        $script:ContextObj = $script:ContextJsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $script:ContextObj = $null
        $script:ContextJsonText = $null
    }
}

# Runtime defaults
$script:RulesVersion = "__DDTPL_RULES_VERSION__"
$script:RuntimeId = [guid]::NewGuid().ToString()
# Reuse one uploader-local session fallback for telemetry files that do not
# carry a runtime_id in their raw body.
$script:TelemetrySessionFallback = [guid]::NewGuid().ToString()

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
function Normalize-Bool([string]$val) {
    switch ($val.ToLower()) {
        { $_ -in '1', 'true', 'yes' } { return $true }
        default { return $false }
    }
}

# Validate numeric value; exit 2 if invalid
function Validate-Numeric([string]$name, [string]$val) {
    if ($val -notmatch '^\d+$') {
        Log "error: $name must be a non-negative integer, got: '$val'"
        exit 2  # Configuration error
    }
}

function Validate-PositiveDecimal([string]$name, [string]$val) {
    if ($val -notmatch '^[+]?([0-9]+([.][0-9]*)?|[.][0-9]+)$') {
        Log "error: invalid ${name}=$val"
        exit 2
    }
    $parsed = 0.0
    if (-not [double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or [double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -le 0) {
        Log "error: invalid ${name}=$val"
        exit 2
    }
}

# Compute FNV-1a 32-bit hex fingerprint (non-cryptographic, for parity checks only)
function Get-Fnv1a32Hex([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return "" }
    $alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+@=#%~!$^*()[]{}<>?,;|\"''` '
    [uint32]$hash = 2166136261
    for ($i = 0; $i -lt $value.Length; $i++) {
        $ch = $value.Substring($i, 1)
        $idx = $alphabet.IndexOf([string]$ch)
        if ($idx -lt 0) { $idx = $alphabet.Length + ($i % 7) }
        $hash = $hash -bxor ([uint32]$idx)
        # Keep arithmetic in uint64 and wrap to 32 bits explicitly.
        # This avoids signed-mask behavior differences on PowerShell.
        $hash = [uint32](([uint64]$hash * [uint64]16777619) % [uint64]4294967296)
    }
    return ("{0:x8}" -f $hash)
}

# Rule attributes (can be overridden via environment variables)
$QuiescentSec = if ($env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC) { $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC } else { "__DDTPL_QUIESCENT_SEC__" }
$MaxWaitSec = if ($env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC) { $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC } else { "__DDTPL_MAX_WAIT_SEC__" }
$MaxDepth = if ($env:DD_TEST_OPTIMIZATION_MAX_DEPTH) { $env:DD_TEST_OPTIMIZATION_MAX_DEPTH } else { "0" }

# Validate numeric values before conversion
Validate-Numeric "QUIESCENT_SEC" $QuiescentSec
Validate-Numeric "MAX_WAIT_SEC" $MaxWaitSec
Validate-Numeric "MAX_DEPTH" $MaxDepth

$QuiescentSec = [int]$QuiescentSec
$MaxWaitSec = [int]$MaxWaitSec
$MaxDepth = [int]$MaxDepth

$FailOnError = Normalize-Bool "__DDTPL_FAIL_ON_ERROR__"
$KeepPayloads = if ($env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS) { Normalize-Bool $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS } else { Normalize-Bool "__DDTPL_KEEP_PAYLOADS__" }
$FilterPrefix = if ($env:DD_TEST_OPTIMIZATION_FILTER_PREFIX) { Normalize-Bool $env:DD_TEST_OPTIMIZATION_FILTER_PREFIX } else { Normalize-Bool "__DDTPL_FILTER_PREFIX__" }
$Debug = if ($env:DD_TEST_OPTIMIZATION_DEBUG) { Normalize-Bool $env:DD_TEST_OPTIMIZATION_DEBUG } else { Normalize-Bool "__DDTPL_DEBUG__" }
$GzipPayloads = if ($env:DD_TEST_OPTIMIZATION_GZIP) { Normalize-Bool $env:DD_TEST_OPTIMIZATION_GZIP } else { Normalize-Bool "__DDTPL_GZIP_PAYLOADS__" }
$script:TestPayloadSplitTargetBytes = 4500000
$script:TestPayloadMaxBytes = 5000000
$script:UploadResponseLogChars = 2000

# Now that $Debug is set, update the script-level debug mode for Dbg function
$script:DebugMode = $Debug
$script:GzipPayloads = $GzipPayloads
Dbg "gzip enabled: $GzipPayloads"

$DryRun = $false
$ValidateEnrichment = $false
$ReportJson = $env:DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON
$script:UploaderReportWritten = $false
$script:ReportReasonCode = "running"
$script:ReportReason = "Uploader is still running."
$script:ReportNextSteps = [System.Collections.Generic.List[string]]::new()
$script:ReportUploadAttempted = $false
$script:ReportUploadFailed = $false
$script:ReportPayloadsDiscoveredTests = 0
$script:ReportPayloadsDiscoveredCoverage = 0
$script:ReportPayloadsDiscoveredTelemetry = 0
$script:UploadFailures = 0
$script:ReportTestsProcessed = 0
$script:ReportTestsFailed = 0
$script:ReportTestsSkipped = 0
$script:ReportCoverageProcessed = 0
$script:ReportCoverageFailed = 0
$script:ReportCoverageSkipped = 0
$script:ReportTelemetryProcessed = 0
$script:ReportTelemetryFailed = 0
$script:ReportTelemetrySkipped = 0
$BepJsonFiles = New-Object System.Collections.Generic.List[string]
if ($env:DD_TEST_OPTIMIZATION_BEP_JSON) {
    $BepJsonFiles.Add($env:DD_TEST_OPTIMIZATION_BEP_JSON) | Out-Null
}
$ArtifactSource = if ($env:DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE) { $env:DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE } else { "local" }
$RemoteArtifacts = if ($env:DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS) { $env:DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS } else { "disabled" }
$ArtifactStagingDir = $env:DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR
$BepArtifactDownloader = $env:DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER
$BepArtifactDownloaderTimeoutSec = if ($env:DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC) { $env:DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC } else { "300" }
$script:StagedTestlogsDirs = New-Object System.Collections.Generic.List[string]
$script:TestlogsScanDirs = New-Object System.Collections.Generic.List[string]
$script:SelectedBepArtifactOutputKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:BlockedBepArtifactLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:StagedOutputKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:StagedRemoteClearances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$FreshnessMode = if ($env:DD_TEST_OPTIMIZATION_FRESHNESS_MODE) {
    $env:DD_TEST_OPTIMIZATION_FRESHNESS_MODE
} elseif ($env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE) {
    $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE
} else {
    "auto"
}
$FreshnessModeHasNewConfig = -not [string]::IsNullOrWhiteSpace($env:DD_TEST_OPTIMIZATION_FRESHNESS_MODE)
$FreshnessDisabledExplicit = $false
$FreshnessSource = if ($env:DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE) { $env:DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE } else { "auto" }
$ExecutionLogJson = $env:DD_TEST_OPTIMIZATION_EXECUTION_LOG_JSON
$ExecutionLogMode = $FreshnessMode
$DefaultBepJson = ".topt/bazel-bep.json"
$DefaultExecutionLogJson = ".topt/bazel-execution-log.json"
$script:FreshnessEligibilityEnabled = $false
$script:FreshnessSelectedSource = "none"
$script:FreshnessEligibleLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:FreshnessEligibleOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:FreshnessCachedOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:FreshnessSkippedOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:FreshnessRemoteOnlyOutputs = New-Object System.Collections.Generic.List[object]
$script:FreshnessMissingOutputLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:FreshnessSkipWasWritten = $false
$script:RemoteOnlyOutputsValidated = $false
$script:ExpectedTargetsConfigured = $false
$script:ExpectedTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:HandledFreshOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:ExecutionEligibilityEnabled = $false
$script:ExecutionEligibleLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:ExecutionEligibleOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:ExecutionSkippedOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$ExpectedEnrichedTags = New-Object System.Collections.Generic.List[string]
$DefaultExpectedEnrichedTags = @(
    "git.repository_url",
    "git.commit.sha",
    "bazel.target",
    "bazel.package"
)

function Show-Usage {
    Write-Host "Usage: dd_upload_payloads [--dry-run] [--validate-enrichment] [--expected-enriched-tag=TAG ...]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --dry-run                    Enrich and validate payloads without uploading or deleting files."
    Write-Host "  --validate-enrichment        Require key context and Bazel tags after enrichment, before upload."
    Write-Host "  --expected-enriched-tag TAG  Add one required enriched tag; repeatable. Defaults to git and Bazel tags."
    Write-Host "  --bep-json PATH              BEP JSON file from the matching bazel test invocation; repeatable."
    Write-Host "  --freshness-source SOURCE    Cache-safety source: auto, bep, execution_log. Default: auto."
    Write-Host "  --freshness-mode MODE        Cache-safety mode: auto, required, optional, or disabled. Default: auto."
    Write-Host "  --artifact-source SOURCE     Artifact source: local, bep, or auto. Default: local."
    Write-Host "  --remote-artifacts MODE      Remote artifact mode: disabled, download, or required. Default: disabled."
    Write-Host "  --artifact-staging-dir PATH  Directory for staged BEP artifacts. Default: .topt/bep-artifacts."
    Write-Host "  --bep-artifact-downloader PATH"
    Write-Host "                                Executable that writes remote BEP outputs.zip artifacts."
    Write-Host "  --bep-artifact-downloader-timeout-sec SECONDS"
    Write-Host "                                Positive decimal timeout for the BEP artifact downloader."
    Write-Host "  --execution-log-json PATH    Only upload payloads from TestRunner actions that executed in this Bazel execution log."
    Write-Host "  --execution-log-mode MODE    Legacy alias for --freshness-mode."
    Write-Host "  --allow-cached-payload-uploads"
    Write-Host "                                Disable BEP and execution-log cache filtering for this uploader run."
    Write-Host "  --report-json PATH           Write a machine-readable uploader diagnostic report."
}

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]
    if ($arg -eq "--dry-run") {
        $DryRun = $true
        continue
    }
    if ($arg -eq "--validate-enrichment") {
        $ValidateEnrichment = $true
        continue
    }
    if ($arg -eq "--expected-enriched-tag") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --expected-enriched-tag requires a tag name"
            exit 2
        }
        $i++
        $ExpectedEnrichedTags.Add([string]$args[$i]) | Out-Null
        continue
    }
    if ($arg.StartsWith("--expected-enriched-tag=")) {
        $ExpectedEnrichedTags.Add($arg.Substring("--expected-enriched-tag=".Length)) | Out-Null
        continue
    }
    if ($arg -eq "--bep-json") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --bep-json requires a file path"
            exit 2
        }
        $i++
        $BepJsonFiles.Add([string]$args[$i]) | Out-Null
        continue
    }
    if ($arg.StartsWith("--bep-json=")) {
        $BepJsonFiles.Add($arg.Substring("--bep-json=".Length)) | Out-Null
        continue
    }
    if ($arg -eq "--freshness-source") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --freshness-source requires one of: auto, bep, execution_log"
            exit 2
        }
        $i++
        $FreshnessSource = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--freshness-source=")) {
        $FreshnessSource = $arg.Substring("--freshness-source=".Length)
        continue
    }
    if ($arg -eq "--freshness-mode") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --freshness-mode requires one of: auto, required, optional, disabled"
            exit 2
        }
        $i++
        $FreshnessMode = [string]$args[$i]
        $ExecutionLogMode = $FreshnessMode
        $FreshnessModeHasNewConfig = $true
        continue
    }
    if ($arg.StartsWith("--freshness-mode=")) {
        $FreshnessMode = $arg.Substring("--freshness-mode=".Length)
        $ExecutionLogMode = $FreshnessMode
        $FreshnessModeHasNewConfig = $true
        continue
    }
    if ($arg -eq "--artifact-source") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --artifact-source requires one of: local, bep, auto"
            exit 2
        }
        $i++
        $ArtifactSource = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--artifact-source=")) {
        $ArtifactSource = $arg.Substring("--artifact-source=".Length)
        continue
    }
    if ($arg -eq "--remote-artifacts") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --remote-artifacts requires one of: disabled, download, required"
            exit 2
        }
        $i++
        $RemoteArtifacts = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--remote-artifacts=")) {
        $RemoteArtifacts = $arg.Substring("--remote-artifacts=".Length)
        continue
    }
    if ($arg -eq "--artifact-staging-dir") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --artifact-staging-dir requires a path"
            exit 2
        }
        $i++
        $ArtifactStagingDir = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--artifact-staging-dir=")) {
        $ArtifactStagingDir = $arg.Substring("--artifact-staging-dir=".Length)
        continue
    }
    if ($arg -eq "--bep-artifact-downloader") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --bep-artifact-downloader requires an executable path"
            exit 2
        }
        $i++
        $BepArtifactDownloader = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--bep-artifact-downloader=")) {
        $BepArtifactDownloader = $arg.Substring("--bep-artifact-downloader=".Length)
        continue
    }
    if ($arg -eq "--bep-artifact-downloader-timeout-sec") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --bep-artifact-downloader-timeout-sec requires a number"
            exit 2
        }
        $i++
        $BepArtifactDownloaderTimeoutSec = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--bep-artifact-downloader-timeout-sec=")) {
        $BepArtifactDownloaderTimeoutSec = $arg.Substring("--bep-artifact-downloader-timeout-sec=".Length)
        continue
    }
    if ($arg -eq "--execution-log-json") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --execution-log-json requires a file path"
            exit 2
        }
        $i++
        $ExecutionLogJson = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--execution-log-json=")) {
        $ExecutionLogJson = $arg.Substring("--execution-log-json=".Length)
        continue
    }
    if ($arg -eq "--execution-log-mode") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --execution-log-mode requires one of: auto, required, optional, disabled"
            exit 2
        }
        $i++
        $ExecutionLogMode = [string]$args[$i]
        if (-not $FreshnessModeHasNewConfig) {
          $FreshnessMode = $ExecutionLogMode
        }
        continue
    }
    if ($arg.StartsWith("--execution-log-mode=")) {
        $ExecutionLogMode = $arg.Substring("--execution-log-mode=".Length)
        if (-not $FreshnessModeHasNewConfig) {
          $FreshnessMode = $ExecutionLogMode
        }
        continue
    }
    if ($arg -eq "--allow-cached-payload-uploads") {
        $FreshnessDisabledExplicit = $true
        $FreshnessMode = "disabled"
        $ExecutionLogMode = "disabled"
        continue
    }
    if ($arg -eq "--report-json") {
        if ($i + 1 -ge $args.Count) {
            Log "error: --report-json requires a file path"
            exit 2
        }
        $i++
        $ReportJson = [string]$args[$i]
        continue
    }
    if ($arg.StartsWith("--report-json=")) {
        $ReportJson = $arg.Substring("--report-json=".Length)
        continue
    }
    if ($arg -eq "--help" -or $arg -eq "-h") {
        Show-Usage
        exit 0
    }
    Log "error: unknown argument: $arg"
    Show-Usage
    exit 2
}

if ($FreshnessDisabledExplicit) {
    $FreshnessMode = "disabled"
    $ExecutionLogMode = "disabled"
}
$FreshnessMode = $FreshnessMode.ToLowerInvariant()
$FreshnessSource = $FreshnessSource.ToLowerInvariant()
$ArtifactSource = $ArtifactSource.ToLowerInvariant()
$RemoteArtifacts = $RemoteArtifacts.ToLowerInvariant()
$ExecutionLogMode = $FreshnessMode
if (@("auto", "required", "optional", "disabled") -notcontains $FreshnessMode) {
    Log "error: DD_TEST_OPTIMIZATION_FRESHNESS_MODE/--freshness-mode must be one of: auto, required, optional, disabled"
    exit 2
}
if (@("auto", "bep", "execution_log") -notcontains $FreshnessSource) {
    Log "error: DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE/--freshness-source must be one of: auto, bep, execution_log"
    exit 2
}
if (@("local", "bep", "auto") -notcontains $ArtifactSource) {
    Log "error: DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE/--artifact-source must be one of: local, bep, auto"
    exit 2
}
if (@("disabled", "download", "required") -notcontains $RemoteArtifacts) {
    Log "error: DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS/--remote-artifacts must be one of: disabled, download, required"
    exit 2
}
Validate-PositiveDecimal "--bep-artifact-downloader-timeout-sec" $BepArtifactDownloaderTimeoutSec
if ([string]::IsNullOrWhiteSpace($ArtifactStagingDir)) {
    if ($env:BUILD_WORKSPACE_DIRECTORY) {
        $ArtifactStagingDir = Join-Path $env:BUILD_WORKSPACE_DIRECTORY ".topt/bep-artifacts"
    } else {
        $ArtifactStagingDir = Join-Path (Get-Location) ".topt/bep-artifacts"
    }
} elseif (-not [System.IO.Path]::IsPathRooted($ArtifactStagingDir)) {
    if ($env:BUILD_WORKSPACE_DIRECTORY) {
        $ArtifactStagingDir = Join-Path $env:BUILD_WORKSPACE_DIRECTORY $ArtifactStagingDir
    } else {
        $ArtifactStagingDir = Join-Path (Get-Location) $ArtifactStagingDir
    }
}
$script:DryRun = $DryRun
$script:ValidateEnrichment = $ValidateEnrichment
$script:BepJsonFiles = $BepJsonFiles
$script:FreshnessMode = $FreshnessMode
$script:FreshnessSource = $FreshnessSource
$script:FreshnessDisabledExplicit = $FreshnessDisabledExplicit
$script:ArtifactSource = $ArtifactSource
$script:RemoteArtifacts = $RemoteArtifacts
$script:ArtifactStagingDir = $ArtifactStagingDir
$script:BepArtifactDownloader = $BepArtifactDownloader
$script:BepArtifactDownloaderTimeoutSec = $BepArtifactDownloaderTimeoutSec
$script:ReportJson = $ReportJson
$script:DefaultBepJson = $DefaultBepJson
$script:ExecutionLogJson = $ExecutionLogJson
$script:ExecutionLogMode = $ExecutionLogMode
$script:DefaultExecutionLogJson = $DefaultExecutionLogJson
$script:ExpectedEnrichedTags = $ExpectedEnrichedTags
$script:DefaultExpectedEnrichedTags = $DefaultExpectedEnrichedTags

# Acquire exclusive lock to prevent concurrent uploaders
# Lock is scoped to workspace to allow parallel uploads in different workspaces
$WorkspacePath = if ($env:BUILD_WORKSPACE_DIRECTORY) { $env:BUILD_WORKSPACE_DIRECTORY } else { (Get-Location).Path }
$WorkspaceHash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkspacePath))).Replace("-","").Substring(0,8)
$TempRoot = $env:TEMP
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
    $TempRoot = [System.IO.Path]::GetTempPath()
}
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
    Log "error: unable to determine a temporary directory (TEMP/GetTempPath)"
    exit 2
}
$LockFile = Join-Path $TempRoot "dd_upload_payloads_$WorkspaceHash.lock"

function Acquire-Lock {
    $maxAttempts = 3
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        try {
            # FileShare.None provides process-wide mutual exclusion while this
            # handle stays open. If another uploader holds it, Open will throw.
            $script:LockStream = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
            Dbg "acquired lock: $LockFile (workspace hash: $WorkspaceHash)"
            return $true
        } catch {
            # If the lock were truly stale (unheld), OpenOrCreate with FileShare.None
            # would succeed. In the catch path, prefer bounded retries over deleting
            # lock files, which can race with another active uploader.
            Dbg "lock acquisition attempt $($attempt + 1)/$maxAttempts failed: $_"
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

if (-not (Acquire-Lock)) {
    Log "error: another uploader is already running (lock: $LockFile)"
    Log "hint: wait for the other uploader to finish, or remove the lock file if stale"
    exit 2
}

# Temp directory for enriched payloads / event files
$script:TmpPayloadDir = Join-Path $TempRoot ("dd_topt_payloads_" + [System.Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $script:TmpPayloadDir -Force | Out-Null
} catch {
    Log "error: failed to create temp directory for payload uploads: $script:TmpPayloadDir"
    Release-Lock
    exit 2
}

# Cleanup function for lock release
function Release-Lock {
    $runsRoot = Join-Path $script:ArtifactStagingDir "__runs"
    foreach ($stagedRoot in @($script:StagedTestlogsDirs)) {
        if ([string]::IsNullOrWhiteSpace($stagedRoot)) { continue }
        try {
            $fullRoot = Resolve-DirectoryPhysicalPath $stagedRoot
            $fullRuns = Resolve-DirectoryPhysicalPath $runsRoot
            if (Test-PathUnderDirectory $fullRoot $fullRuns) {
                Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Log-Stderr "warning: refusing to clean BEP staging root outside owned run directory: $stagedRoot"
            }
        } catch {
            Log-Stderr "warning: failed to clean BEP staging root: $stagedRoot"
        }
    }
    # Release lock handle first, then best-effort remove lock file and temp dir.
    if ($script:LockStream) {
        $script:LockStream.Close()
        $script:LockStream = $null
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }
    if ($script:TmpPayloadDir -and (Test-Path -LiteralPath $script:TmpPayloadDir)) {
        Remove-Item -LiteralPath $script:TmpPayloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReportCollectionCount($Value) {
    if ($null -eq $Value) { return 0 }
    if ($Value.PSObject.Properties['Count']) { return [int]$Value.Count }
    return @($Value).Count
}

function Get-ReportUniqueStrings($Values) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        $text = [string]$value
        if ($seen.Add($text)) {
            $unique.Add($text) | Out-Null
        }
    }
    return @($unique.ToArray())
}

function Set-ReportResult([string]$ReasonCode, [string]$Reason, [string[]]$NextSteps = @()) {
    $script:ReportReasonCode = $ReasonCode
    $script:ReportReason = $Reason
    $script:ReportNextSteps.Clear()
    foreach ($step in $NextSteps) {
        [void]$script:ReportNextSteps.Add($step)
    }
}

function Set-ClassifiedUploaderResult([int]$ExitCode) {
    if ($script:ReportReasonCode -ne "running") { return }
    $testOutputsDirs = @($script:TestOutputsCache).Count
    $discoveredTotal = [int]$script:ReportPayloadsDiscoveredTests + [int]$script:ReportPayloadsDiscoveredCoverage + [int]$script:ReportPayloadsDiscoveredTelemetry
    if ($ExitCode -ne 0 -and $script:BepJsonFiles.Count -eq 0 -and ($script:FreshnessSource -eq "bep" -or $script:ArtifactSource -eq "bep" -or $script:FreshnessMode -eq "required")) {
        Set-ReportResult "missing_bep_json" `
            "BEP freshness or artifact staging was required, but no BEP JSON was configured." `
            @("Pass --bep-json from the matching bazel test invocation.")
        return
    }
    if ($ExitCode -ne 0 -and (Get-ReportCollectionCount $script:FreshnessRemoteOnlyOutputs) -gt 0) {
        Set-ReportResult "bep_output_remote_only_without_downloader" `
            "BEP selected remote-only outputs that could not be materialized locally." `
            @("Enable --remote-artifacts=download with --bep-artifact-downloader, or adjust Bazel remote download settings.")
        return
    }
    if (
        $ExitCode -ne 0 `
        -and (Get-ReportCollectionCount $script:FreshnessCachedOutputs) -gt 0 `
        -and (Get-ReportCollectionCount $script:FreshnessEligibleOutputs) -eq 0
    ) {
        Set-ReportResult "target_cached_by_bazel" `
            "Cached Bazel outputs did not satisfy the requested BEP freshness contract." `
            @("Use the BEP from the exact matching bazel test invocation and verify each expected target is fresh or exclusively cached.")
        return
    }
    if ($ExitCode -ne 0 -and -not $script:DryRun -and $script:ReportUploadFailed) {
        Set-ReportResult "upload_failed_http" `
            "One or more payload uploads failed." `
            @("Check HTTP status diagnostics and Datadog credentials/site configuration.")
        return
    }
    if ($ExitCode -ne 0 -and (($script:ReportTestsFailed + $script:ReportCoverageFailed + $script:ReportTelemetryFailed) -gt 0)) {
        Set-ReportResult "payload_enrichment_failed" `
            "Dry-run or payload processing failed for at least one payload." `
            @("Inspect uploader logs for the first payload validation failure.")
        return
    }
    if ($testOutputsDirs -eq 0) {
        Set-ReportResult "no_test_outputs_found" `
            "No local or staged test.outputs directories were found." `
            @("Use --artifact-source=bep with the matching --bep-json, or configure Bazel to materialize test outputs.")
        return
    }
    if ($discoveredTotal -eq 0) {
        Set-ReportResult "no_payload_json_found" `
            "Test output directories were found, but no JSON payloads were available." `
            @("Inspect TEST_UNDECLARED_OUTPUTS_DIR and outputs.zip for payloads/tests, payloads/coverage, or payloads/telemetry files.")
        return
    }
    if ($ExitCode -eq 0 -and $script:DryRun) {
        Set-ReportResult "upload_skipped_dry_run" `
            "Dry-run completed successfully; real upload was not requested." `
            @("Run again with -Upload or without --dry-run to send payloads.")
        return
    }
    if ($ExitCode -eq 0) {
        Set-ReportResult "ok" "Uploader completed successfully." @()
        return
    }
    Set-ReportResult "upload_failed_unknown" `
        "Uploader failed without a more specific report reason." `
        @("Inspect uploader logs and report counters.")
}

function Write-UploaderReport([string]$Status, [int]$ExitCode) {
    if ([string]::IsNullOrWhiteSpace($script:ReportJson)) { return }
    Set-ClassifiedUploaderResult $ExitCode

    $payloadsUploaded = 0
    $payloadsAttempted = 0
    if ($script:ReportUploadAttempted) {
        $payloadsUploaded = [int]($script:ReportTestsProcessed + $script:ReportCoverageProcessed + $script:ReportTelemetryProcessed)
        $payloadsAttempted = [int]($payloadsUploaded + $script:UploadFailures)
    }

    $report = [ordered]@{
        schema_version = 1
        tool = "dd-test-optimization-uploader"
        status = $Status
        exit_code = $ExitCode
        result = [ordered]@{
            status = [string]$Status
            reason_code = [string]$script:ReportReasonCode
            reason = [string]$script:ReportReason
            next_steps = @($script:ReportNextSteps.ToArray())
        }
        config = [ordered]@{
            dry_run = [bool]$script:DryRun
            validate_enrichment = [bool]$script:ValidateEnrichment
            artifact_source = [string]$script:ArtifactSource
            remote_artifacts = [string]$script:RemoteArtifacts
            freshness_source = [string]$script:FreshnessSource
            freshness_mode = [string]$script:FreshnessMode
            allow_cached_payload_uploads = [bool]$script:FreshnessDisabledExplicit
        }
        bep = [ordered]@{
            files = @(Get-ReportUniqueStrings @($script:BepJsonFiles.ToArray()))
            freshness_selected_source = [string]$script:FreshnessSelectedSource
            eligible_outputs = Get-ReportCollectionCount $script:FreshnessEligibleOutputs
            cached_outputs = Get-ReportCollectionCount $script:FreshnessCachedOutputs
            remote_only_outputs = Get-ReportCollectionCount $script:FreshnessRemoteOnlyOutputs
            skipped_outputs = Get-ReportCollectionCount $script:FreshnessSkippedOutputs
            missing_output_labels = Get-ReportCollectionCount $script:FreshnessMissingOutputLabels
        }
        artifacts = [ordered]@{
            source = [string]$script:ArtifactSource
            staging_dir = [string]$script:ArtifactStagingDir
            staged_testlogs_dirs = Get-ReportCollectionCount $script:StagedTestlogsDirs
            selected_remote_artifacts = Get-ReportCollectionCount $script:SelectedBepArtifactOutputKeys
            staged_remote_artifacts = Get-ReportCollectionCount $script:StagedOutputKeys
            remote_artifacts_ignored = Get-ReportCollectionCount $script:BlockedBepArtifactLabels
        }
        upload = [ordered]@{
            attempted = [bool]$script:ReportUploadAttempted
            dry_run = [bool]$script:DryRun
            payloads_attempted = [int]$payloadsAttempted
            payloads_uploaded = [int]$payloadsUploaded
            payloads_failed = [int]$script:UploadFailures
        }
        payloads = [ordered]@{
            test_outputs_dirs = @($script:TestOutputsCache).Count
            discovered = [ordered]@{
                tests = [int]$script:ReportPayloadsDiscoveredTests
                coverage = [int]$script:ReportPayloadsDiscoveredCoverage
                telemetry = [int]$script:ReportPayloadsDiscoveredTelemetry
            }
            tests = [ordered]@{
                processed = [int]$script:ReportTestsProcessed
                failed = [int]$script:ReportTestsFailed
                skipped = [int]$script:ReportTestsSkipped
            }
            coverage = [ordered]@{
                processed = [int]$script:ReportCoverageProcessed
                failed = [int]$script:ReportCoverageFailed
                skipped = [int]$script:ReportCoverageSkipped
            }
            telemetry = [ordered]@{
                processed = [int]$script:ReportTelemetryProcessed
                failed = [int]$script:ReportTelemetryFailed
                skipped = [int]$script:ReportTelemetrySkipped
            }
        }
        upload_failures = [int]$script:UploadFailures
    }

    try {
        $reportDir = Split-Path -Parent $script:ReportJson
        if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
            New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
        }
        $tmpReport = "$($script:ReportJson).tmp.$PID"
        Write-Utf8NoBomFile -Path $tmpReport -Content (($report | ConvertTo-Json -Depth 20) + "`n")
        Move-Item -LiteralPath $tmpReport -Destination $script:ReportJson -Force
    } catch {
        Log-Stderr "warning: failed to write uploader report '$($script:ReportJson)': $_"
    }
}

function Complete-UploaderReport([int]$ExitCode) {
    if ($script:UploaderReportWritten) { return }
    $status = if ($ExitCode -eq 0) { "ok" } else { "fail" }
    Write-UploaderReport $status $ExitCode
    $script:UploaderReportWritten = $true
}

function Exit-WithUploaderReport([int]$ExitCode) {
    Complete-UploaderReport $ExitCode
    Release-Lock
    exit $ExitCode
}

# Register cleanup on exit (backup for unexpected termination)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Release-Lock }

function Test-ArtifactStagingRequested {
    if ($script:ArtifactSource -eq "bep") { return [bool]$true }
    return [bool]($script:ArtifactSource -eq "auto" -and $script:RemoteArtifacts -ne "disabled")
}

function Get-PythonForBepArtifactStaging {
    foreach ($candidate in @($env:DD_TEST_OPTIMIZATION_PYTHON, $env:PYTHON)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($candidate in @("python3", "python")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Parse-BepArtifactHelperOutput {
    param([string[]]$Lines)

    $script:SelectedBepArtifactOutputKeys.Clear()
    $script:BlockedBepArtifactLabels.Clear()
    $script:StagedOutputKeys.Clear()
    $script:StagedRemoteClearances.Clear()
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            Log "error: malformed BEP artifact helper output: blank line"
            exit 2
        }
        $parts = $line.Split([char]9)
        switch ($parts[0]) {
            "selected" {
                if ($parts.Count -ne 3 -or [string]::IsNullOrWhiteSpace($parts[1]) -or [string]::IsNullOrWhiteSpace($parts[2])) {
                    Log "error: malformed BEP artifact helper selected row"
                    exit 2
                }
                Dbg "BEP artifact staging selected output key: $($parts[2])"
                $script:SelectedBepArtifactOutputKeys.Add($parts[2]) | Out-Null
            }
            "blocked_label" {
                if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
                    Log "error: malformed BEP artifact helper blocked_label row"
                    exit 2
                }
                Dbg "BEP artifact staging blocked local fallback for unmappable output label: $($parts[1])"
                $script:BlockedBepArtifactLabels.Add($parts[1]) | Out-Null
            }
            "root" {
                if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1]) -or -not (Test-Path -LiteralPath $parts[1] -PathType Container)) {
                    Log "error: malformed BEP artifact helper root row"
                    exit 2
                }
                $stagedRoot = Resolve-DirectoryPhysicalPath $parts[1]
                $script:StagedTestlogsDirs.Add($stagedRoot) | Out-Null
                $script:TestlogsScanDirs.Add($stagedRoot) | Out-Null
            }
            "staged" {
                if ($parts.Count -ne 6 -or [string]::IsNullOrWhiteSpace($parts[1]) -or [string]::IsNullOrWhiteSpace($parts[2]) -or [string]::IsNullOrWhiteSpace($parts[3]) -or [string]::IsNullOrWhiteSpace($parts[5])) {
                    Log "error: malformed BEP artifact helper staged row"
                    exit 2
                }
                if ($parts[4] -ne "0" -and $parts[4] -ne "1") {
                    Log "error: malformed BEP artifact helper staged row"
                    exit 2
                }
                $pair = "$($parts[1])`t$($parts[2])"
                Dbg "BEP artifact staging materialized $($parts[1]) output $($parts[2]) at $($parts[3])"
                $script:StagedOutputKeys.Add($pair) | Out-Null
                if ($parts[4] -eq "1") {
                    $script:StagedRemoteClearances.Add($pair) | Out-Null
                }
            }
            default {
                Log "error: unknown BEP artifact helper output row kind: $($parts[0])"
                exit 2
            }
        }
    }
}

function Stage-BepArtifacts {
    if (-not (Test-ArtifactStagingRequested)) { return }
    if ($script:ArtifactSource -eq "bep" -and $script:BepJsonFiles.Count -eq 0) {
        Log "error: --artifact-source=bep requires --bep-json or DD_TEST_OPTIMIZATION_BEP_JSON"
        Exit-WithUploaderReport 2
    }
    if ($script:BepJsonFiles.Count -eq 0) { return }
    $pythonBin = Get-PythonForBepArtifactStaging
    if (-not $pythonBin) {
        Log "error: BEP artifact staging requires PYTHON, python3, or python"
        exit 2
    }
    $script:BepArtifactStageHelper = Resolve-Runfile $script:BepArtifactStageHelperRloc
    $script:DoctorRuntime = Resolve-Runfile $script:DoctorRuntimeRloc
    if (-not $script:BepArtifactStageHelper -or -not (Test-Path -LiteralPath $script:BepArtifactStageHelper -PathType Leaf)) {
        Log "error: BEP artifact stage helper not found in runfiles"
        exit 2
    }
    if (-not $script:DoctorRuntime -or -not (Test-Path -LiteralPath $script:DoctorRuntime -PathType Leaf)) {
        Log "error: BEP artifact staging doctor runtime not found in runfiles"
        exit 2
    }
    $resolvedBepJsonFiles = New-Object System.Collections.Generic.List[string]
    foreach ($bepJson in @($script:BepJsonFiles)) {
        $resolvedBepJson = Resolve-RuntimeFilePath $bepJson
        if ([string]::IsNullOrWhiteSpace($resolvedBepJson) -or -not (Test-Path -LiteralPath $resolvedBepJson -PathType Leaf)) {
            Log "error: BEP JSON not found for artifact staging: $bepJson; continuing with other BEP files"
            continue
        }
        $resolvedBepJsonFiles.Add($resolvedBepJson) | Out-Null
    }
    if ($resolvedBepJsonFiles.Count -eq 0) { return }
    $cmd = @(
        "--doctor-runtime", $script:DoctorRuntime,
        "--staging-dir", $script:ArtifactStagingDir,
        "--remote-artifacts", $script:RemoteArtifacts,
        "--artifact-source", $script:ArtifactSource,
        "--bep-artifact-downloader-timeout-sec", $script:BepArtifactDownloaderTimeoutSec
    )
    if (-not [string]::IsNullOrWhiteSpace($script:BepArtifactDownloader)) {
        $cmd += @("--bep-artifact-downloader", $script:BepArtifactDownloader)
    }
    $cmd += @($resolvedBepJsonFiles.ToArray())
    $helperStderr = Join-Path $script:TmpPayloadDir ("bep_artifacts_stderr_" + [System.Guid]::NewGuid().ToString("N") + ".txt")
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $helperOutput = @(& $PythonBin $script:BepArtifactStageHelper @cmd 2> $helperStderr)
        $helperStatus = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (Test-Path -LiteralPath $helperStderr -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $helperStderr -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Log-Stderr ([string]$line)
            }
        }
    }
    if ($helperStatus -ne 0) {
        foreach ($line in $helperOutput) { Log-Stderr ([string]$line) }
        Log "error: BEP artifact staging helper failed with exit code $helperStatus"
        exit $helperStatus
    }
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $helperOutput) {
        $text = [string]$line
        if ($text.StartsWith("[dd-test-optimization")) {
            Log-Stderr $text
        } else {
            $stdoutLines.Add($text) | Out-Null
        }
    }
    Parse-BepArtifactHelperOutput -Lines $stdoutLines.ToArray()
}

# Determine bazel-testlogs directory
# Priority: TESTLOGS_DIR env var > BUILD_WORKSPACE_DIRECTORY/bazel-testlogs > ./bazel-testlogs
#
# NOTE: We intentionally do NOT call `bazel info` from within the uploader.
# Running `bazel info` inside `bazel run` can deadlock when the output base is locked.
# For non-standard setups (--symlink_prefix, disabled symlinks), users should set
# TESTLOGS_DIR externally using the same Bazel binary AND flags as for 'bazel test':
#   $BazelFlags = @("--output_base=/custom/base")
#   $env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs); bazel @BazelFlags run ...

# Check explicit TESTLOGS_DIR override first (fail fast if set but invalid)
if ($env:TESTLOGS_DIR) {
    if (Test-Path -LiteralPath $env:TESTLOGS_DIR -PathType Container) {
        # Explicit override bypasses auto-discovery heuristics.
        $TestlogsDir = $env:TESTLOGS_DIR
        Dbg "using explicit TESTLOGS_DIR=$TestlogsDir"
    } elseif (Test-Path -LiteralPath $env:TESTLOGS_DIR) {
        Log "error: TESTLOGS_DIR is set but is not a directory: $($env:TESTLOGS_DIR)"
        Release-Lock
        exit 2  # Configuration error (see exit codes in docs)
    } else {
        Log "error: TESTLOGS_DIR is set but path does not exist: $($env:TESTLOGS_DIR)"
        Log "hint: ensure you used the same Bazel wrapper for 'bazel info' as for 'bazel test'"
        Release-Lock
        exit 2  # Configuration error (see exit codes in docs)
    }
} else {
    # Auto-discover testlogs directory
    # Discovery order mirrors Bash implementation for cross-platform parity:
    # 1) BUILD_WORKSPACE_DIRECTORY/bazel-testlogs
    # 2) cwd/bazel-testlogs
    $TestlogsDir = $null

    if ($env:BUILD_WORKSPACE_DIRECTORY) {
        $candidate = Join-Path $env:BUILD_WORKSPACE_DIRECTORY "bazel-testlogs"
        if (Test-Path -LiteralPath $candidate) { $TestlogsDir = $candidate }
    }

    if (-not $TestlogsDir) {
        $candidate = Join-Path (Get-Location) "bazel-testlogs"
        if (Test-Path -LiteralPath $candidate) { $TestlogsDir = $candidate }
    }

    if (-not $TestlogsDir) {
        if (Test-ArtifactStagingRequested) {
            Dbg "testlogs dir not found; deferring no-output decision until after BEP artifact staging"
        } else {
            Log "warning: testlogs dir not found (nothing to upload)"
            Log "hint: set TESTLOGS_DIR env var, or ensure bazel-testlogs symlink exists"
            # Exit 0 by default (graceful no-op), but respect FailOnError to catch misconfigurations
            if ($FailOnError) {
                Log "error: FailOnError is set and no testlogs found - this may indicate misconfiguration"
                Release-Lock
                exit 2  # Configuration error
            }
            Release-Lock
            exit 0
        }
    }

    if ($TestlogsDir) {
        Dbg "auto-discovered TestlogsDir=$TestlogsDir"
    }
}

function Resolve-DirectoryPhysicalPath {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.LinkType) {
            try {
                $target = $item.ResolveLinkTarget($true)
                if ($target) { return $target.FullName }
            } catch {
                Dbg "Resolve-DirectoryPhysicalPath could not resolve link target for '$Path': $($_.Exception.Message)"
            }
        }
        return $item.FullName
    } catch {
        try {
            return [System.IO.Path]::GetFullPath($Path)
        } catch {
            return $Path
        }
    }
}

function Get-PathPrefixComparison {
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

function Normalize-PathForPrefix([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return $Path.Replace('\', '/').TrimEnd('/')
}

function Test-PathUnderDirectory([string]$Path, [string]$Root) {
    $normalizedPath = Normalize-PathForPrefix $Path
    $normalizedRoot = Normalize-PathForPrefix $Root
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return $false
    }
    return $normalizedPath.StartsWith($normalizedRoot + "/", (Get-PathPrefixComparison))
}

# Keep the logical path for messages/context derivation, but walk the physical
# directory so a workspace bazel-testlogs symlink is handled consistently.
$TestlogsScanDir = $null
if ($TestlogsDir) {
    $TestlogsScanDir = Resolve-DirectoryPhysicalPath $TestlogsDir
    $script:TestlogsScanDir = $TestlogsScanDir
    $script:TestlogsScanDirs.Add($TestlogsScanDir) | Out-Null
    Dbg "using TestlogsScanDir=$TestlogsScanDir"
}
Stage-BepArtifacts

# Find all test.outputs directories (supports DD_TEST_OPTIMIZATION_MAX_DEPTH to limit search depth)
# Note: -Depth parameter requires PowerShell 7+; on older versions, depth limiting is ignored
function Find-TestOutputs {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($scanDir in @($script:TestlogsScanDirs)) {
        if ([string]::IsNullOrWhiteSpace($scanDir) -or -not (Test-Path -LiteralPath $scanDir -PathType Container)) { continue }
        $params = @{
            Path = $scanDir
            Recurse = $true
            Directory = $true
            Filter = "test.outputs"
            ErrorAction = 'SilentlyContinue'
        }
        if ($MaxDepth -gt 0) {
            # -Depth is only available in PowerShell 7+
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $params['Depth'] = $MaxDepth
                Dbg "limiting search depth to $MaxDepth"
            } else {
                Log "warning: DD_TEST_OPTIMIZATION_MAX_DEPTH ignored (requires PowerShell 7+, have $($PSVersionTable.PSVersion))"
            }
        }
        foreach ($dir in @(Get-ChildItem @params)) {
            $found.Add($dir) | Out-Null
        }
    }
    return @($found.ToArray())
}

function Get-TestOutputDirKey([string]$OutputsDir) {
  if ([string]::IsNullOrWhiteSpace($OutputsDir)) { return "" }
  $normalized = Normalize-PathForPrefix $OutputsDir
  $comparison = Get-PathPrefixComparison
  foreach ($scanDir in @($script:TestlogsScanDirs)) {
    $scanRoot = Normalize-PathForPrefix ([string]$scanDir)
    if (-not [string]::IsNullOrWhiteSpace($scanRoot) -and $normalized.StartsWith($scanRoot + "/", $comparison)) {
      return $normalized.Substring($scanRoot.Length + 1)
    }
  }

  $marker = "/testlogs/"
  $markerIndex = $normalized.LastIndexOf($marker, [System.StringComparison]::Ordinal)
  if ($markerIndex -ge 0) {
    $normalized = $normalized.Substring($markerIndex + $marker.Length)
  } else {
    $normalized = $normalized.TrimStart('/')
  }

  $insideIndex = $normalized.IndexOf("/test.outputs/", [System.StringComparison]::Ordinal)
  if ($insideIndex -ge 0) {
    $normalized = $normalized.Substring(0, $insideIndex) + "/test.outputs"
  } elseif (-not $normalized.EndsWith("/test.outputs", [System.StringComparison]::Ordinal)) {
    return ""
  }

  while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(2)
  }
  return $normalized.TrimStart('/')
}

# Cache the list of test.outputs directories for efficiency (avoid rescanning on each loop iteration)
$script:TestOutputsCache = @()
function Update-TestOutputsCache {
    $dirs = @(Find-TestOutputs)
    if ($dirs.Count -gt 1) {
        [Array]::Sort(
            $dirs,
            [System.Collections.Generic.Comparer[object]]::Create(
                [System.Comparison[object]]{
                    param($left, $right)
                    $leftPath = if ($null -eq $left) { "" } else { [string]$left.FullName }
                    $rightPath = if ($null -eq $right) { "" } else { [string]$right.FullName }
                    return [System.StringComparer]::Ordinal.Compare($leftPath, $rightPath)
                }
            )
        )
    }
    $deduped = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($dir in $dirs) {
        $key = Get-TestOutputDirKey $dir.FullName
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($script:SelectedBepArtifactOutputKeys.Contains($key)) {
            $isStaged = $false
            foreach ($stagedRoot in @($script:StagedTestlogsDirs)) {
                if (Test-PathUnderDirectory $dir.FullName $stagedRoot) {
                    $isStaged = $true
                    break
                }
            }
            if (-not $isStaged) {
                Dbg "suppressing local test.outputs selected for BEP artifact staging: $($dir.FullName)"
                continue
            }
        }
        if ($seen.Add($key)) {
            $deduped.Add($dir) | Out-Null
        }
    }
    $script:TestOutputsCache = @($deduped.ToArray())
}

function Get-LatestMTimeAll {
    $maxTime = [DateTime]::MinValue
    foreach ($outputsDir in $script:TestOutputsCache) {
        foreach ($subdir in @("payloads/tests", "payloads/coverage", "payloads/telemetry")) {
            $dir = Join-Path $outputsDir.FullName $subdir
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }
            foreach ($file in $files) {
                if ($file.LastWriteTime -gt $maxTime) {
                    $maxTime = $file.LastWriteTime
                }
            }
        }
    }
    return $maxTime
}

function Count-PayloadFiles {
    $count = 0
    foreach ($outputsDir in $script:TestOutputsCache) {
        $testsDir = Join-Path $outputsDir.FullName "payloads/tests"
        $covDir = Join-Path $outputsDir.FullName "payloads/coverage"
        $telemetryDir = Join-Path $outputsDir.FullName "payloads/telemetry"
        if (Test-Path -LiteralPath $testsDir) {
            $count += @(Get-ChildItem -Path $testsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
        if (Test-Path -LiteralPath $covDir) {
            $count += @(Get-ChildItem -Path $covDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
        if (Test-Path -LiteralPath $telemetryDir) {
            $count += @(Get-ChildItem -Path $telemetryDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
    }
    return $count
}

function Update-DiscoveredPayloadCounts {
    $script:ReportPayloadsDiscoveredTests = 0
    $script:ReportPayloadsDiscoveredCoverage = 0
    $script:ReportPayloadsDiscoveredTelemetry = 0
    foreach ($outputsDir in $script:TestOutputsCache) {
        $testsDir = Join-Path $outputsDir.FullName "payloads/tests"
        $covDir = Join-Path $outputsDir.FullName "payloads/coverage"
        $telemetryDir = Join-Path $outputsDir.FullName "payloads/telemetry"
        if (Test-Path -LiteralPath $testsDir) {
            $script:ReportPayloadsDiscoveredTests += @(Get-ChildItem -Path $testsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
        if (Test-Path -LiteralPath $covDir) {
            $script:ReportPayloadsDiscoveredCoverage += @(Get-ChildItem -Path $covDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
        if (Test-Path -LiteralPath $telemetryDir) {
            $script:ReportPayloadsDiscoveredTelemetry += @(Get-ChildItem -Path $telemetryDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") }).Count
        }
    }
}

# Detect if tests actually ran by looking for test.log or test.xml files
# This helps distinguish "no payloads because tests didn't run" from "tests ran but dd-trace-go is misconfigured"
function Test-ExecutedTests {
    foreach ($scanDir in @($script:TestlogsScanDirs)) {
        if ([string]::IsNullOrWhiteSpace($scanDir) -or -not (Test-Path -LiteralPath $scanDir -PathType Container)) { continue }
        $testFiles = Get-ChildItem -Path $scanDir -Recurse -File -Include @("test.log", "test.xml") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $testFiles) { return [bool]$true }
    }
    return [bool]$false
}

# Wait for quiescence (filesystem to settle)
# Since the uploader runs AFTER tests complete (via `bazel run` after `bazel test`),
# we just need a short quiescence period to ensure all files are written.
$start = Get-Date
Dbg "Uploader start time: $start"

# Initialize the cache
Update-TestOutputsCache
Update-DiscoveredPayloadCounts

while ($true) {
    $elapsed = ((Get-Date) - $start).TotalSeconds

    # Refresh cache in case new test.outputs dirs appeared (e.g., remote downloads)
    Update-TestOutputsCache
    Update-DiscoveredPayloadCounts
    $totalFiles = Count-PayloadFiles

    if ($totalFiles -eq 0) {
        # No payloads yet. Branch behavior depends on max-wait configuration.
        if ($MaxWaitSec -eq 0) {
            if ($script:FreshnessMode -ne "disabled" -and ($script:FreshnessSource -eq "bep" -or $script:BepJsonFiles.Count -gt 0)) {
                Log "BEP freshness is configured; checking BEP before treating missing local payloads as no-op"
                break
            }
            if (Test-ExecutedTests) {
                Log "warning: tests ran but no payload files found"
                Log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
                if ($FailOnError) {
                    Log "error: FailOnError is set; failing due to missing payloads"
                    Exit-WithUploaderReport 1
                }
            } else {
                Log "no payload files found and no test execution detected; nothing to upload"
            }
            Exit-WithUploaderReport 0
        }
        if ($elapsed -gt $MaxWaitSec) {
            if ($script:FreshnessMode -ne "disabled" -and ($script:FreshnessSource -eq "bep" -or $script:BepJsonFiles.Count -gt 0)) {
                Log "BEP freshness is configured; checking BEP before treating missing local payloads as no-op"
                break
            }
            if (Test-ExecutedTests) {
                Log "warning: tests ran but no payload files found"
                Log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
                if ($FailOnError) {
                    Log "error: FailOnError is set; failing due to missing payloads"
                    Exit-WithUploaderReport 1
                }
            } else {
                Log "no payload files found and no test execution detected; nothing to upload"
            }
            Exit-WithUploaderReport 0
        }
        Dbg "no payload files yet; waiting"
        Start-Sleep -Seconds 2
        continue
    }

    if ($elapsed -gt $MaxWaitSec) {
        # Payloads are present; continue with upload once budget expires.
        Log "max wait exceeded ($MaxWaitSec s); proceeding to upload"
        break
    }

    # Check if files have been stable for QuiescentSec
    $latestTime = Get-LatestMTimeAll
    $idle = ((Get-Date) - $latestTime).TotalSeconds
    Dbg "total_files=$totalFiles, idle=$idle s"

    if ($idle -ge $QuiescentSec) {
        Log "outputs quiescent for $idle s ($totalFiles files); starting upload"
        break
    }

    Start-Sleep -Seconds 2
}

# Build endpoints
$Agentless = [string]::IsNullOrEmpty($env:DD_TEST_OPTIMIZATION_AGENT_URL)
try {
  $DD_Site = Normalize-DdSiteOrFail $env:DD_SITE
} catch {
  Log "error: $($_.Exception.Message)"
  Release-Lock
  exit 2
}
# Allow tests/dev to override intake base without changing DD_SITE.
$IntakeBase = $env:DD_TEST_OPTIMIZATION_AGENTLESS_URL
if ($Agentless) {
  # Agentless mode posts directly to Datadog intake hosts.
  if (-not [string]::IsNullOrEmpty($IntakeBase)) {
    $Base = $IntakeBase.TrimEnd('/')
    $TestUrl = "$Base/api/v2/citestcycle"
    $CovUrl = "$Base/api/v2/citestcov"
    $TelemetryUrl = "$Base/api/v2/apmtelemetry"
    Dbg "DD_TEST_OPTIMIZATION_AGENTLESS_URL override active: $Base"
  } else {
    $TestUrl = "https://citestcycle-intake.$DD_Site/api/v2/citestcycle"
    $CovUrl = "https://citestcov-intake.$DD_Site/api/v2/citestcov"
    $TelemetryUrl = "https://instrumentation-telemetry-intake.$DD_Site/api/v2/apmtelemetry"
  }
} else {
  # EVP mode tunnels through agent endpoint and requires EVP subdomain headers.
  $TestUrl = "$($env:DD_TEST_OPTIMIZATION_AGENT_URL)/evp_proxy/v2/api/v2/citestcycle"
  $CovUrl = "$($env:DD_TEST_OPTIMIZATION_AGENT_URL)/evp_proxy/v2/api/v2/citestcov"
  $TelemetryUrl = "$($env:DD_TEST_OPTIMIZATION_AGENT_URL)/telemetry/proxy/api/v2/apmtelemetry"
  if (-not [string]::IsNullOrEmpty($IntakeBase)) { Dbg "DD_TEST_OPTIMIZATION_AGENTLESS_URL ignored in EVP mode" }
}
Dbg "mode: Agentless=$Agentless Site=$DD_Site"
Dbg "endpoints: TestUrl=$TestUrl CovUrl=$CovUrl TelemetryUrl=$TelemetryUrl"

$script:HeaderLangDefault = 'bazel-starlark'
$script:HeaderLangVersionDefault = 'n/a'
$script:HeaderLangInterpreterDefault = 'bazel-run'
$script:HeaderTracerVersionDefault = '__DDTPL_UPLOADER_VERSION__'
if ($Agentless -and -not $script:DryRun) {
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {
    Log "error: DD_API_KEY required for agentless uploads"
    Log "hint: pass credentials via environment: `$env:DD_API_KEY=... `$env:DD_SITE=... bazel run //:dd_upload_payloads"
    Release-Lock
    exit 2  # Configuration error
  }
} else {
  $TestEvp = @{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }
  $CovEvp  = @{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }
}
Dbg "headers prepared (agentless=$Agentless; test headers can be derived from metadata)"

Dbg "primary context.json: $(if ([string]::IsNullOrEmpty($script:PrimaryContextJson)) { '<none>' } else { $script:PrimaryContextJson })"

# Optional check: verify fetch-time API key fingerprint matches uploader API key.
$ContextFingerprint = $null
if ($script:PrimaryContextJson -and (Test-Path -LiteralPath $script:PrimaryContextJson)) {
  try {
    $ctxForCheck = Get-Content -LiteralPath $script:PrimaryContextJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ContextFingerprint = $ctxForCheck.'topt.api_key_fingerprint'
  } catch {
    $ContextFingerprint = $null
  }
}
if ($ContextFingerprint) {
  if ($Agentless) {
    # Compare only non-secret fingerprints; never log raw DD_API_KEY.
    if (-not [string]::IsNullOrEmpty($env:DD_API_KEY)) {
      $LocalFp = Get-Fnv1a32Hex $env:DD_API_KEY
      if ($LocalFp -and ($LocalFp -ne $ContextFingerprint)) {
        Log "warning: DD_API_KEY mismatch between fetch and uploader"
      } else {
        Dbg "DD_API_KEY fingerprint match"
      }
    } else {
      Dbg "DD_API_KEY fingerprint check skipped because DD_API_KEY is unset"
    }
  } else {
    Log "warning: DD_API_KEY fingerprint present but uploader running in EVP mode; check skipped"
  }
}

function Get-CommonHeaders([string]$PayloadPath) {
  $lang = $script:HeaderLangDefault
  $langVersion = $script:HeaderLangVersionDefault
  $langInterpreter = $script:HeaderLangInterpreterDefault
  $tracerVersion = $script:HeaderTracerVersionDefault

  if (-not [string]::IsNullOrEmpty($PayloadPath) -and (Test-Path -LiteralPath $PayloadPath)) {
    try {
      $payloadObj = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $metaStar = $null
      if ($payloadObj.metadata) { $metaStar = $payloadObj.metadata.'*' }
      if ($metaStar) {
        $metaLang = $metaStar.language
        if (-not [string]::IsNullOrEmpty($metaLang)) { $lang = [string]$metaLang }

        $metaTracerVersion = $metaStar.library_version
        if (-not [string]::IsNullOrEmpty($metaTracerVersion)) { $tracerVersion = [string]$metaTracerVersion }

        $metaLangVersion = $metaStar.language_version
        if ([string]::IsNullOrEmpty($metaLangVersion)) { $metaLangVersion = $metaStar.runtime_version }
        if (-not [string]::IsNullOrEmpty($metaLangVersion)) { $langVersion = [string]$metaLangVersion }

        $metaLangInterpreter = $metaStar.language_interpreter
        if ([string]::IsNullOrEmpty($metaLangInterpreter)) { $metaLangInterpreter = $metaStar.runtime_name }
        if (-not [string]::IsNullOrEmpty($metaLangInterpreter)) { $langInterpreter = [string]$metaLangInterpreter }
      }
    } catch {
      # Metadata extraction is best-effort; fall back to defaults on parse issues.
      Dbg "Get-CommonHeaders: failed to parse payload metadata from '$PayloadPath' ($_)"
    }
  }

  $headers = @{
    'Datadog-Meta-Lang' = $lang
    'Datadog-Meta-Lang-Version' = $langVersion
    'Datadog-Meta-Lang-Interpreter' = $langInterpreter
    'Datadog-Meta-Tracer-Version' = $tracerVersion
    'Accept' = 'application/json'
  }
  if ($Agentless) {
    # DD-API-KEY is only required in direct agentless upload mode.
    $headers['DD-API-KEY'] = $env:DD_API_KEY
  }
  return $headers
}

function Convert-ToMutableObject($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($k in $Value.Keys) {
      $map[[string]$k] = Convert-ToMutableObject $Value[$k]
    }
    return $map
  }
  if ($Value -is [PSCustomObject]) {
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Value.PSObject.Properties) {
      $map[$p.Name] = Convert-ToMutableObject $p.Value
    }
    return $map
  }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $arr = @()
    foreach ($item in $Value) {
      $arr += ,(Convert-ToMutableObject $item)
    }
    return $arr
  }
  return $Value
}

function Ensure-Hashtable($Value) {
  $converted = Convert-ToMutableObject $Value
  if ($converted -is [System.Collections.IDictionary]) {
    return $converted
  }
  return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}

function Get-MutableDictionary($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    return $Value
  }
  if ($Value -is [PSCustomObject]) {
    return Convert-ToMutableObject $Value
  }
  return $null
}

function Get-MapValue($MapObj, [string]$Key) {
  if ($null -eq $MapObj -or [string]::IsNullOrEmpty($Key)) { return $null }
  if ($MapObj -is [System.Collections.IDictionary]) {
    if ($MapObj.Contains($Key)) { return $MapObj[$Key] }
    return $null
  }
  $prop = $MapObj.PSObject.Properties[$Key]
  if ($prop) { return $prop.Value }
  return $null
}

function Get-StringPropertyValue($Object, [string]$Key) {
  $value = Get-MapValue $Object $Key
  if (($value -is [string]) -and -not [string]::IsNullOrWhiteSpace($value)) {
    return $value.Trim()
  }
  return ""
}

function Get-ContextProviderFromObject($ContextValue) {
  if ($null -eq $ContextValue) { return "" }

  $providerName = Get-StringPropertyValue $ContextValue 'ci.provider.name'
  if (-not [string]::IsNullOrWhiteSpace($providerName)) { return $providerName }

  $providerName = Get-StringPropertyValue $ContextValue 'ci_provider_name'
  if (-not [string]::IsNullOrWhiteSpace($providerName)) { return $providerName }

  $ciValue = Get-MapValue $ContextValue 'ci'
  if ($ciValue) {
    $providerName = Get-StringPropertyValue $ciValue 'provider.name'
    if (-not [string]::IsNullOrWhiteSpace($providerName)) { return $providerName }

    $providerName = Get-StringPropertyValue $ciValue 'provider_name'
    if (-not [string]::IsNullOrWhiteSpace($providerName)) { return $providerName }

    $providerValue = Get-MapValue $ciValue 'provider'
    if ($providerValue) {
      $providerName = Get-StringPropertyValue $providerValue 'name'
      if (-not [string]::IsNullOrWhiteSpace($providerName)) { return $providerName }
    }
  }

  return ""
}

function Get-ContextProviderFromJsonText([string]$JsonText) {
  if ([string]::IsNullOrWhiteSpace($JsonText)) { return "" }

  foreach ($pattern in @(
    '"ci\.provider\.name"\s*:\s*"(?<provider>(?:[^"\\]|\\.)*)"',
    '"ci_provider_name"\s*:\s*"(?<provider>(?:[^"\\]|\\.)*)"'
  )) {
    $match = [regex]::Match($JsonText, $pattern)
    if (-not $match.Success) { continue }
    $rawProvider = $match.Groups['provider'].Value
    if ([string]::IsNullOrWhiteSpace($rawProvider)) { continue }
    try {
      $decoded = ConvertFrom-Json -InputObject ('"' + $rawProvider.Replace('\', '\\') + '"') -ErrorAction Stop
      if (($decoded -is [string]) -and -not [string]::IsNullOrWhiteSpace($decoded)) {
        return $decoded.Trim()
      }
    } catch {
      if (-not [string]::IsNullOrWhiteSpace($rawProvider)) {
        return $rawProvider.Trim()
      }
    }
  }

  return ""
}

function Convert-ToObjectArray($Value) {
  if ($null -eq $Value) { return @() }
  if (($Value -is [System.Collections.IDictionary]) -or ($Value -is [PSCustomObject])) {
    return ,$Value
  }
  if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
    return @($Value)
  }
  return ,$Value
}

$script:CodeOwnersInitialized = $false
$script:CodeOwnersEnabled = $false
$script:CodeOwnersPath = $null
$script:CodeOwnersRules = @()
$script:CodeOwnersStats = @{
  scanned = 0
  enriched = 0
  skipped_existing = 0
  skipped_missing_source = 0
  skipped_unmatched = 0
  skipped_errors = 0
}

function Normalize-PathLike([string]$PathValue) {
  if ([string]::IsNullOrEmpty($PathValue)) { return $null }
  $v = $PathValue
  if ($v.StartsWith("file://")) { $v = $v.Substring(7) }
  if ($v.Contains('%')) {
    # Keep behavior aligned with Bash: avoid decoding NUL (%00) into paths.
    $containsNullEscape = ($v -match '(?i)%00')
    $stripped = [regex]::Replace($v, '%[0-9A-Fa-f]{2}', '')
    if (-not $containsNullEscape -and -not $stripped.Contains('%')) {
      try { $v = [Uri]::UnescapeDataString($v) } catch {}
    }
  }
  # Decode can re-introduce backslashes (for example %5C on Windows paths).
  # Normalize after decoding so slash-based matching stays consistent.
  $v = $v.Replace([char]92, [char]47)
  # Normalize duplicate separators and leading "./" fragments first.
  while ($v.Contains("//")) { $v = $v.Replace("//", "/") }
  while ($v.StartsWith("./")) { $v = $v.Substring(2) }
  if ($v -match '^/[A-Za-z]:/') {
    # file:///C:/... style paths become /C:/... after scheme removal.
    # Drop only the leading slash to preserve the drive-qualified path.
    $v = $v.Substring(1)
  }

  # Resolve dot segments. If ".." would traverse above root, return null so
  # callers can safely ignore this candidate.
  $isAbs = $v.StartsWith("/")
  if ($isAbs) { $v = $v.Substring(1) }
  $parts = @($v.Split('/', [System.StringSplitOptions]::None))
  $stack = New-Object System.Collections.Generic.List[string]
  foreach ($part in $parts) {
    if ([string]::IsNullOrEmpty($part) -or $part -eq ".") { continue }
    if ($part -eq "..") {
      if ($stack.Count -gt 0) {
        $stack.RemoveAt($stack.Count - 1)
        continue
      }
      return $null
    }
    $stack.Add($part)
  }
  $joined = [string]::Join("/", $stack.ToArray())
  if ($isAbs) { return "/$joined" }
  return $joined
}

function Add-PathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Candidate) {
  $normalized = Normalize-PathLike $Candidate
  if ([string]::IsNullOrEmpty($normalized)) { return }
  if ($normalized.StartsWith("/")) { $normalized = $normalized.Substring(1) }
  while ($normalized.StartsWith("./")) { $normalized = $normalized.Substring(2) }
  if ([string]::IsNullOrEmpty($normalized)) { return }
  # Generated artifacts should not be matched against repo CODEOWNERS.
  if ($normalized.StartsWith("bazel-out/")) { return }
  if (-not $Candidates.Contains($normalized)) { $Candidates.Add($normalized) | Out-Null }
}

function Add-DerivedPathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Candidate) {
  if ([string]::IsNullOrEmpty($Candidate)) { return }
  if ($Candidate.StartsWith("external/") -or $Candidate.StartsWith("_main/external/")) {
    # Execroot/runfiles derived external paths belong to fetched dependencies,
    # not repository-owned source files. Skip to avoid false owner attribution.
    if ($script:DebugMode) { Dbg "codeowners: skip external source candidate '$Candidate'" }
    return
  }
  Add-PathCandidate $Candidates $Candidate
}

function Strip-WorkspacePrefix([string]$PathValue, [string]$WorkspaceRoot) {
  if ([string]::IsNullOrEmpty($PathValue) -or [string]::IsNullOrEmpty($WorkspaceRoot)) { return $null }
  $pathNorm = Normalize-PathLike $PathValue
  $rootNorm = Normalize-PathLike $WorkspaceRoot
  if ([string]::IsNullOrEmpty($pathNorm) -or [string]::IsNullOrEmpty($rootNorm)) { return $null }
  # Windows paths are case-insensitive; honor that when stripping repo roots.
  $pathComparison = if ($env:OS -eq 'Windows_NT') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
  if ([string]::Equals($pathNorm, $rootNorm, $pathComparison)) { return "" }
  if ($pathNorm.StartsWith("$rootNorm/", $pathComparison)) {
    return $pathNorm.Substring($rootNorm.Length + 1)
  }
  return $null
}

function Get-PathCandidates([string]$SourcePath) {
  $candidates = New-Object System.Collections.Generic.List[string]
  $normalized = Normalize-PathLike $SourcePath
  if ([string]::IsNullOrEmpty($normalized)) { return $candidates }

  $workspaceRoot = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {
    $workspaceRoot = $env:BUILD_WORKSPACE_DIRECTORY
  } elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {
    $workspaceRoot = $Matches[1]
  } else {
    $workspaceRoot = (Get-Location).Path
  }

  # Candidate order is deliberate: try repo-relative variants first, then
  # runfiles/execroot-derived forms, then absolute normalized fallback.
  $workspaceRoots = @(
    $(if ($script:ContextObj) { $script:ContextObj.'ci.workspace_path' } else { $null }),
    $workspaceRoot
  )
  foreach ($root in $workspaceRoots) {
    $stripped = Strip-WorkspacePrefix $normalized $root
    if ($stripped -ne $null) { Add-PathCandidate $candidates $stripped }
  }

  if ($normalized -match '/execroot/[^/]+/_main/(.+)$') {
    Add-DerivedPathCandidate $candidates $Matches[1]
  }
  if ($normalized -match '/execroot/[^/]+/(.+)$') {
    Add-DerivedPathCandidate $candidates $Matches[1]
  }
  if ($normalized -match '\.runfiles/_main/(.+)$') {
    Add-DerivedPathCandidate $candidates $Matches[1]
  }
  if ($normalized -match '\.runfiles/[^/]+/(.+)$') {
    Add-DerivedPathCandidate $candidates $Matches[1]
  }
  # Keep only repository-relative fallback candidates. Absolute paths that are
  # not under known repo roots can incorrectly inherit broad CODEOWNERS rules.
  if (-not $normalized.StartsWith("/") -and -not ($normalized -match '^[A-Za-z]:/')) {
    Add-PathCandidate $candidates $normalized
  } elseif ($script:DebugMode) {
    Dbg "codeowners: skip absolute source fallback candidate '$normalized'"
  }
  return $candidates
}

function Convert-CodeOwnersGlobToRegex([string]$Pattern) {
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $Pattern.Length) {
    $ch = $Pattern.Substring($i, 1)
    # Backslash escapes a literal glob metacharacter.
    if ([int][char]$ch -eq 92) {
      if (($i + 1) -lt $Pattern.Length) {
        $escapedCh = $Pattern.Substring($i + 1, 1)
        [void]$sb.Append([Regex]::Escape($escapedCh))
        $i += 2
      } else {
        [void]$sb.Append("\\")
        $i++
      }
      continue
    }
    if ($ch -eq '*' -and ($i + 1) -lt $Pattern.Length -and $Pattern.Substring($i + 1, 1) -eq '*') {
      if (($i + 2) -lt $Pattern.Length -and $Pattern.Substring($i + 2, 1) -eq '/') {
        # CODEOWNERS follows gitignore-style globbing: **/ matches zero or more directories.
        [void]$sb.Append("(.*/)?")
        $i += 3
      } else {
        [void]$sb.Append(".*")
        $i += 2
      }
      continue
    }
    if ($ch -eq '*') {
      [void]$sb.Append("[^/]*")
      $i++
      continue
    } elseif ($ch -eq '?') {
      [void]$sb.Append("[^/]")
      $i++
      continue
    }
    if ($ch -eq '[') {
      # Preserve character classes (including negation), because repositories
      # frequently use patterns like [Tt]est*.cs in CODEOWNERS.
      $j = $i + 1
      $classSb = New-Object System.Text.StringBuilder
      $closed = $false
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '!') {
        [void]$classSb.Append("^")
        $j++
      } elseif ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '^') {
        [void]$classSb.Append("\^")
        $j++
      }
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq ']') {
        [void]$classSb.Append("\]")
        $j++
      }
      while ($j -lt $Pattern.Length) {
        $classCh = $Pattern.Substring($j, 1)
        if ($classCh -eq ']') {
          $closed = $true
          break
        }
        if ([int][char]$classCh -eq 92) {
          [void]$classSb.Append("\\")
        } elseif ($classCh -eq '^') {
          [void]$classSb.Append("\^")
        } elseif ($classCh -eq '[') {
          [void]$classSb.Append("\[")
        } elseif ($classCh -eq '-') {
          [void]$classSb.Append("-")
        } else {
          [void]$classSb.Append([Regex]::Escape($classCh))
        }
        $j++
      }
      if ($closed) {
        [void]$sb.Append("[$classSb]")
        $i = $j + 1
        continue
      }
      [void]$sb.Append("\[")
      $i++
      continue
    }
    if ($ch -eq '.') {
      [void]$sb.Append("\.")
    } elseif ($ch -eq '+') {
      [void]$sb.Append("\+")
    } elseif ($ch -eq '(') {
      [void]$sb.Append("\(")
    } elseif ($ch -eq ')') {
      [void]$sb.Append("\)")
    } elseif ($ch -eq '{') {
      [void]$sb.Append("\{")
    } elseif ($ch -eq '}') {
      [void]$sb.Append("\}")
    } elseif ($ch -eq '^') {
      [void]$sb.Append("\^")
    } elseif ($ch -eq '$') {
      [void]$sb.Append("\$")
    } elseif ($ch -eq '|') {
      [void]$sb.Append("\|")
    } elseif ([int][char]$ch -eq 92) {
      [void]$sb.Append("\\")
    } elseif ($ch -eq ']') {
      [void]$sb.Append("\]")
    } else {
      [void]$sb.Append($ch)
    }
    $i++
  }
  return $sb.ToString()
}

function Convert-CodeOwnersPatternToRegex([string]$Pattern) {
  if ([string]::IsNullOrEmpty($Pattern)) { return $null }
  $anchored = $false
  $dirOnly = $false
  $raw = $Pattern
  if ($raw.StartsWith("/")) {
    $anchored = $true
    $raw = $raw.Substring(1)
  }
  if ($raw.EndsWith("/")) {
    $dirOnly = $true
    $raw = $raw.Substring(0, $raw.Length - 1)
  }
  if ([string]::IsNullOrEmpty($raw)) { return $null }
  $hasSlash = $raw.Contains("/")
  $body = Convert-CodeOwnersGlobToRegex $raw

  # Match semantics:
  # - anchored or slash-containing rules start at repo root
  # - simple names can match at any path segment boundary
  $prefix = if ($anchored -or $hasSlash) { "^" } else { "(^|.*/)" }
  $suffix = if ($dirOnly) { "/.*$" } else { "($|/.*)" }
  return "$prefix$body$suffix"
}

function Split-CodeOwnersLine([string]$Line) {
  if ([string]::IsNullOrEmpty($Line)) {
    return [PSCustomObject]@{ Pattern = ""; OwnersRaw = "" }
  }
  $sb = New-Object System.Text.StringBuilder
  $escaped = $false
  for ($i = 0; $i -lt $Line.Length; $i++) {
    $ch = $Line.Substring($i, 1)
    if ($escaped) {
      [void]$sb.Append($ch)
      $escaped = $false
      continue
    }
    if ([int][char]$ch -eq 92) {
      [void]$sb.Append($ch)
      $escaped = $true
      continue
    }
    if ([char]::IsWhiteSpace($Line[$i])) {
      $ownersRaw = $Line.Substring($i).TrimStart()
      return [PSCustomObject]@{ Pattern = $sb.ToString(); OwnersRaw = $ownersRaw }
    }
    [void]$sb.Append($ch)
  }
  return [PSCustomObject]@{ Pattern = $sb.ToString(); OwnersRaw = "" }
}

function Test-IsGitLabSectionHeaderPattern([string]$Pattern) {
  if ([string]::IsNullOrEmpty($Pattern)) { return $false }
  if ($Pattern -notmatch '^\[[^\[\]]+\]$') { return $false }
  $inner = $Pattern.Substring(1, $Pattern.Length - 2)
  # GitLab section headers can include whitespace (for example [Core Team]).
  if ($inner.Contains(" ") -or $inner.Contains("`t")) {
    return $true
  }
  # Heuristic to avoid class-only glob false positives:
  # keep range-like and short bracket classes (for example [xy], [A-Z]).
  if ($inner.Contains('-') -or $inner.Contains('!') -or $inner.Contains('^') -or $inner.Contains([string]([char]92))) {
    return $false
  }
  # Preserve all-uppercase/digit class sets such as [ABCD] and [A1B2C3].
  if ($inner -cmatch '^[A-Z0-9]+$') { return $false }
  # Preserve short alnum bracket classes (for example [xy], [ABC], [Abc]).
  if ($inner.Length -le 3 -and $inner -cmatch '^[A-Za-z0-9]+$') { return $false }
  # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
  if ($inner -cmatch '^[a-z0-9]+$') { return $false }
  return $true
}

function Test-IsGitLabSectionHeaderLine([string]$Line) {
  if ([string]::IsNullOrEmpty($Line)) { return $false }
  if ($Line -notmatch '^(\[[^\[\]]+\])(?:\s+.*)?$') { return $false }
  return (Test-IsGitLabSectionHeaderPattern $Matches[1])
}

function Initialize-CodeOwnersRules {
  if ($script:CodeOwnersInitialized) { return }
  $script:CodeOwnersInitialized = $true

  $workspace = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {
    $workspace = $env:BUILD_WORKSPACE_DIRECTORY
  } elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {
    $workspace = $Matches[1]
  } else {
    $workspace = (Get-Location).Path
  }
  $explicitCodeOwners = $env:DD_TEST_OPTIMIZATION_CODEOWNERS_FILE
  if (-not [string]::IsNullOrEmpty($explicitCodeOwners)) {
    Dbg "codeowners: explicit path candidate '$explicitCodeOwners'"
    if (Test-Path -LiteralPath $explicitCodeOwners -PathType Leaf) {
      $script:CodeOwnersPath = $explicitCodeOwners
      Dbg "codeowners: using explicit CODEOWNERS file '$script:CodeOwnersPath'"
    } else {
      Dbg "codeowners: DD_TEST_OPTIMIZATION_CODEOWNERS_FILE is set but not readable: '$explicitCodeOwners' (falling back to discovery)"
    }
  }
  $compatWorkspace = if ($script:ContextObj) { $script:ContextObj.'ci.workspace_path' } else { $null }
  # Lookup order must mirror Bash implementation for cross-platform parity.
  if (-not $script:CodeOwnersPath) {
    $lookupPaths = @(
      $(if ($compatWorkspace) { Join-Path $compatWorkspace "CODEOWNERS" } else { $null }),
      $(if ($compatWorkspace) { Join-Path $compatWorkspace ".github/CODEOWNERS" } else { $null }),
      $(if ($compatWorkspace) { Join-Path $compatWorkspace ".gitlab/CODEOWNERS" } else { $null }),
      $(if ($compatWorkspace) { Join-Path $compatWorkspace "docs/CODEOWNERS" } else { $null }),
      $(if ($compatWorkspace) { Join-Path $compatWorkspace ".docs/CODEOWNERS" } else { $null }),
      (Join-Path $workspace "CODEOWNERS"),
      (Join-Path $workspace ".github/CODEOWNERS"),
      (Join-Path $workspace ".gitlab/CODEOWNERS"),
      (Join-Path $workspace "docs/CODEOWNERS"),
      (Join-Path $workspace ".docs/CODEOWNERS"),
      (Join-Path (Get-Location).Path "CODEOWNERS"),
      (Join-Path $PSScriptRoot "CODEOWNERS")
    )

    foreach ($candidate in $lookupPaths) {
      if ([string]::IsNullOrEmpty($candidate)) { continue }
      $candidateExists = Test-Path -LiteralPath $candidate -PathType Leaf
      if ($candidateExists) {
        Dbg "codeowners: discovery candidate hit '$candidate'"
      }
      if ($candidateExists) {
        $script:CodeOwnersPath = $candidate
        break
      }
    }
  }
  if (-not $script:CodeOwnersPath) {
    Dbg "codeowners: no CODEOWNERS file found (workspace='$workspace')"
    return
  }

  try {
    $lines = Get-Content -LiteralPath $script:CodeOwnersPath -Encoding UTF8 -ErrorAction Stop
  } catch {
    Dbg "codeowners: failed to read '$script:CodeOwnersPath' ($_)"
    return
  }

  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) { continue }
    # Section headers may include spaces (for example "[Core Team] @org/team").
    # Detect them from the full raw line before splitting on whitespace.
    if (Test-IsGitLabSectionHeaderLine $trimmed) {
      continue
    }
    $split = Split-CodeOwnersLine $trimmed
    $pattern = [string]$split.Pattern
    if ([string]::IsNullOrEmpty($pattern)) { continue }
    $ownersRaw = [string]$split.OwnersRaw
    # Ignore GitLab-style section headers while preserving bracket-class globs.
    if (Test-IsGitLabSectionHeaderPattern $pattern) {
      continue
    }
    $ownersRaw = $ownersRaw.Trim()
    # Strip inline comments only when '#' begins a comment segment.
    if ($ownersRaw.StartsWith("#")) {
      $ownersRaw = ""
    } elseif ($ownersRaw -match '\s#') {
      $ownersRaw = ($ownersRaw -replace '\s#.*$', '').TrimEnd()
    }
    $ownerTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($ownersRaw)) {
      $ownerTokens = @($ownersRaw -split '\s+' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    $regex = Convert-CodeOwnersPatternToRegex $pattern
    if ([string]::IsNullOrEmpty($regex)) { continue }
    # Best-effort hardening: malformed character classes can produce invalid
    # .NET regexes (for example "[z-a]"). Skip those rules here so one bad
    # line cannot force all candidate evaluations into catch paths.
    try {
      [void][System.Text.RegularExpressions.Regex]::new($regex)
    } catch {
      Dbg "codeowners: skipping invalid regex '$regex' from pattern '$pattern'"
      continue
    }
    $script:CodeOwnersRules += [PSCustomObject]@{
      Regex = $regex
      Owners = $ownerTokens
      HasOwners = ($ownerTokens.Count -gt 0)
    }
  }

  if ($script:CodeOwnersRules.Count -gt 0) {
    $script:CodeOwnersEnabled = $true
    Dbg "codeowners: using '$script:CodeOwnersPath' with $($script:CodeOwnersRules.Count) rule(s)"
  } else {
    Dbg "codeowners: file '$script:CodeOwnersPath' had no usable rules"
  }
}

function Get-CodeOwnersMatchForCandidate([string]$Candidate) {
  $matched = $false
  $matchOwners = @()
  $matchHasOwners = $false
  # Last matching rule wins (GitHub CODEOWNERS behavior).
  foreach ($rule in $script:CodeOwnersRules) {
    if ($Candidate -cmatch $rule.Regex) {
      $matched = $true
      $matchOwners = @($rule.Owners)
      $matchHasOwners = [bool]$rule.HasOwners
    }
  }
  return [PSCustomObject]@{
    Matched = $matched
    Owners = $matchOwners
    HasOwners = $matchHasOwners
  }
}

function Convert-OwnersToJsonString($Owners) {
  if (-not $Owners -or $Owners.Count -eq 0) { return $null }
  $dedup = New-Object System.Collections.Generic.List[string]
  foreach ($owner in $Owners) {
    if (-not [string]::IsNullOrEmpty($owner) -and -not $dedup.Contains([string]$owner)) {
      $dedup.Add([string]$owner) | Out-Null
    }
  }
  if ($dedup.Count -eq 0) { return $null }
  # Keep JSON shape stable: always emit an array string, including a single owner.
  $dedupArr = @($dedup.ToArray())
  return (ConvertTo-Json -InputObject $dedupArr -Compress)
}

function Get-CodeOwnersJsonForSource([string]$SourcePath) {
  Initialize-CodeOwnersRules
  if (-not $script:CodeOwnersEnabled) { return $null }
  $candidates = Get-PathCandidates $SourcePath
  # Return first candidate hit (candidate list is already priority-ordered).
  foreach ($candidate in $candidates) {
    $match = Get-CodeOwnersMatchForCandidate $candidate
    if (-not $match.Matched) { continue }
    if (-not $match.HasOwners) { return $null }
    $jsonOwners = Convert-OwnersToJsonString $match.Owners
    if (-not [string]::IsNullOrEmpty($jsonOwners)) {
      return $jsonOwners
    }
  }
  return $null
}

function Get-EventSourcePath($EventObj) {
  if (-not $EventObj) { return $null }
  $content = Get-MapValue $EventObj 'content'
  if ($null -eq $content) { return $null }
  $contentMap = Ensure-Hashtable $content

  # Accept both flattened meta keys and nested source objects.
  $meta = Ensure-Hashtable (Get-MapValue $contentMap 'meta')
  foreach ($k in @('test.source.file', 'test.source.path', 'source.file', 'source.path')) {
    $v = Get-MapValue $meta $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { return $v }
  }

  $source = Ensure-Hashtable (Get-MapValue $contentMap 'source')
  foreach ($k in @('file', 'path')) {
    $v = Get-MapValue $source $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { return $v }
  }
  return $null
}

$script:BazelTargetMetadataOutput = 'bazel_target_metadata.json'

function Get-DirectoryNameSafe([string]$PathValue) {
  if ([string]::IsNullOrEmpty($PathValue)) { return $null }
  try {
    return [System.IO.Path]::GetDirectoryName($PathValue)
  } catch {
    return $null
  }
}

function Get-BazelTargetMetadataPath([string]$PayloadFile) {
  if ([string]::IsNullOrEmpty($PayloadFile)) { return $null }
  $leafDir = Get-DirectoryNameSafe $PayloadFile
  if ([string]::IsNullOrEmpty($leafDir)) { return $null }
  $payloadDir = Get-DirectoryNameSafe $leafDir
  if ([string]::IsNullOrEmpty($payloadDir)) { return $null }
  $outputsRoot = Get-DirectoryNameSafe $payloadDir
  if ([string]::IsNullOrEmpty($outputsRoot)) { return $null }
  $candidate = Join-Path $outputsRoot $script:BazelTargetMetadataOutput
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  return $null
}

function Get-JsonStreamObjects([string]$PathValue) {
  $text = Get-Content -LiteralPath $PathValue -Raw -Encoding UTF8
  $objects = New-Object System.Collections.Generic.List[object]
  $depth = 0
  $start = -1
  $inString = $false
  $escape = $false
  for ($i = 0; $i -lt $text.Length; $i++) {
    $ch = $text[$i]
    if ($inString) {
      if ($escape) {
        $escape = $false
      } elseif ($ch -eq '\') {
        $escape = $true
      } elseif ($ch -eq '"') {
        $inString = $false
      }
      continue
    }
    if ($ch -eq '"') {
      $inString = $true
      continue
    }
    if ($ch -eq '{') {
      if ($depth -eq 0) { $start = $i }
      $depth++
      continue
    }
    if ($ch -eq '}') {
      $depth--
      if ($depth -eq 0 -and $start -ge 0) {
        $json = $text.Substring($start, $i - $start + 1)
        $objects.Add(($json | ConvertFrom-Json -ErrorAction Stop)) | Out-Null
        $start = -1
      }
      if ($depth -lt 0) {
        throw "unbalanced JSON object stream"
      }
    }
  }
  if ($depth -ne 0 -or $inString) {
    throw "unterminated JSON object stream"
  }
  return $objects
}

function Get-ExecutionLogTestOutputKey([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
  $normalized = $PathValue.Replace('\', '/')
  $marker = "/testlogs/"
  $markerIndex = $normalized.LastIndexOf($marker, [System.StringComparison]::Ordinal)
  if ($markerIndex -ge 0) {
    $normalized = $normalized.Substring($markerIndex + $marker.Length)
  } else {
    $normalized = $normalized.TrimStart('/')
  }

  $insideIndex = $normalized.IndexOf("/test.outputs/", [System.StringComparison]::Ordinal)
  if ($insideIndex -ge 0) {
    $normalized = $normalized.Substring(0, $insideIndex) + "/test.outputs"
  } elseif (-not $normalized.EndsWith("/test.outputs", [System.StringComparison]::Ordinal)) {
    return ""
  }

  while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(2)
  }
  return $normalized.TrimStart('/')
}

function Get-SpawnTestOutputKeys($Spawn) {
  $values = New-Object System.Collections.Generic.List[string]
  $keys = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Spawn.listedOutputs)) {
    if ($item -is [string]) { $values.Add($item) | Out-Null }
  }
  foreach ($item in @($Spawn.actualOutputs)) {
    if ($null -ne $item -and $item.PSObject.Properties.Name -contains "path" -and $item.path -is [string]) {
      $values.Add([string]$item.path) | Out-Null
    }
  }
  foreach ($value in $values) {
    $key = Get-ExecutionLogTestOutputKey ([string]$value)
    if (-not [string]::IsNullOrWhiteSpace($key)) {
      $keys.Add($key) | Out-Null
    }
  }
  return $keys
}

function Get-BepTestOutputKey([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
  $normalized = $PathValue
  if ($normalized.StartsWith("file://", [System.StringComparison]::OrdinalIgnoreCase)) {
    try {
      $uri = [System.Uri]$normalized
      $normalized = [System.Uri]::UnescapeDataString($uri.LocalPath)
    } catch {
      $normalized = $normalized.Substring("file://".Length)
    }
  }
  $normalized = [System.Uri]::UnescapeDataString($normalized).Replace('\', '/').TrimStart('/')
  $marker = "/testlogs/"
  $markerIndex = $normalized.LastIndexOf($marker, [System.StringComparison]::Ordinal)
  if ($markerIndex -ge 0) {
    $normalized = $normalized.Substring($markerIndex + $marker.Length)
  } else {
    $bazelMarker = "/bazel-testlogs/"
    $bazelMarkerIndex = $normalized.LastIndexOf($bazelMarker, [System.StringComparison]::Ordinal)
    if ($bazelMarkerIndex -ge 0) {
      $normalized = $normalized.Substring($bazelMarkerIndex + $bazelMarker.Length)
    }
  }
  while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(2)
  }
  $insideIndex = $normalized.IndexOf("/test.outputs/", [System.StringComparison]::Ordinal)
  if ($insideIndex -ge 0) {
    return ($normalized.Substring(0, $insideIndex) + "/test.outputs").TrimStart('/')
  }
  if ($normalized.EndsWith("/test.outputs", [System.StringComparison]::Ordinal)) {
    return $normalized.TrimStart('/')
  }
  if ($normalized.EndsWith("/outputs.zip", [System.StringComparison]::Ordinal)) {
    $separatorIndex = $normalized.LastIndexOf("/", [System.StringComparison]::Ordinal)
    $parent = if ($separatorIndex -ge 0) { $normalized.Substring(0, $separatorIndex) } else { "" }
    return ($parent + "/test.outputs").TrimStart('/')
  }
  if ($normalized.EndsWith("/test.log", [System.StringComparison]::Ordinal) -or $normalized.EndsWith("/test.xml", [System.StringComparison]::Ordinal)) {
    $parent = $normalized.Substring(0, $normalized.LastIndexOf("/", [System.StringComparison]::Ordinal))
    return ($parent + "/test.outputs").TrimStart('/')
  }
  return ""
}

function Get-BepPathPrefixNameCandidate($FileObject) {
  if ($null -eq $FileObject -or -not ($FileObject.PSObject.Properties.Name -contains "name")) { return "" }
  $name = Get-MapValue $FileObject "name"
  $pathPrefix = Get-MapValue $FileObject "pathPrefix"
  if ($null -eq $pathPrefix) { $pathPrefix = Get-MapValue $FileObject "path_prefix" }
  if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name)) { return "" }
  if (-not ($pathPrefix -is [System.Collections.IEnumerable]) -or ($pathPrefix -is [string])) { return "" }
  $parts = New-Object System.Collections.ArrayList
  foreach ($part in @($pathPrefix)) {
    if (($part -is [string]) -and -not [string]::IsNullOrWhiteSpace($part)) {
      $parts.Add([string]$part) | Out-Null
    }
  }
  if ($parts.Count -eq 0) { return "" }
  $parts.Add([string]$name) | Out-Null
  return ($parts.ToArray() -join "/")
}

function Test-TrustedBepOutputKeyCandidate([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  $normalized = $PathValue
  if ($normalized.StartsWith("file://", [System.StringComparison]::OrdinalIgnoreCase)) {
    try {
      $uri = [System.Uri]$normalized
      $normalized = [System.Uri]::UnescapeDataString($uri.LocalPath)
    } catch {
      $normalized = $normalized.Substring("file://".Length)
    }
  }
  $normalized = [System.Uri]::UnescapeDataString($normalized).Replace('\', '/').Trim('/')
  if ([string]::IsNullOrWhiteSpace($normalized) -or -not $normalized.Contains("/")) { return $false }
  if (Test-BepRemoteOnlyReference $normalized) { return $false }
  $parts = @($normalized -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  return [bool](($parts -contains "testlogs") -or ($parts -contains "bazel-testlogs"))
}

function Get-BepCanonicalOutputKeyCandidates($FileObject, [string[]]$Candidates) {
  $values = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $append = {
    param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and $seen.Add($Value)) {
      $values.Add($Value) | Out-Null
    }
  }

  if ($null -ne $FileObject -and -not ($FileObject -is [string])) {
    & $append (Get-BepPathPrefixNameCandidate $FileObject)
    $path = Get-MapValue $FileObject "path"
    if ($path -is [string]) {
      & $append ([string]$path)
    }
  }
  foreach ($candidate in @($Candidates)) {
    if (Test-TrustedBepOutputKeyCandidate $candidate) {
      & $append ([string]$candidate)
    }
  }
  return $values
}

function Test-BepRemoteOnlyReference([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  $lowered = $PathValue.ToLowerInvariant()
  if ($lowered.StartsWith("file://")) { return $false }
  if ($lowered -match '^[a-z][a-z0-9+.-]*://') { return $true }
  if ($lowered.StartsWith("blobs/")) { return $true }
  if ($lowered -match '^[0-9a-f]{32,}/[0-9]+$') { return $true }
  return $false
}

function Test-BepTestOutputsArtifactHint([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
  $normalized = $PathValue.Replace('\', '/').ToLowerInvariant()
  if ($normalized.StartsWith("file://")) {
    $normalized = $normalized.Substring("file://".Length)
  }
  return (
    $normalized -eq "test.outputs" -or
    $normalized -eq "outputs.zip" -or
    $normalized.Contains("/test.outputs/") -or
    $normalized.EndsWith("/test.outputs", [System.StringComparison]::Ordinal) -or
    $normalized.EndsWith("/outputs.zip", [System.StringComparison]::Ordinal)
  )
}

function Get-BepFileReferenceCandidates($FileObject) {
  $values = New-Object System.Collections.Generic.List[string]
  if ($FileObject -is [string]) {
    $values.Add($FileObject) | Out-Null
    return $values
  }
  foreach ($key in @("uri", "name", "path")) {
    $value = Get-MapValue $FileObject $key
    if (($value -is [string]) -and -not [string]::IsNullOrWhiteSpace($value)) {
      $values.Add([string]$value) | Out-Null
    }
  }
  $name = Get-MapValue $FileObject "name"
  $pathPrefixName = Get-BepPathPrefixNameCandidate $FileObject
  if (-not [string]::IsNullOrWhiteSpace($pathPrefixName)) {
    $values.Add($pathPrefixName) | Out-Null
  }
  return $values
}

function Initialize-ExpectedTargets {
  $script:ExpectedTargets.Clear()
  $script:ExpectedTargetsConfigured = $false
  $staticTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $staticFile = Resolve-ArtifactPath $script:ExpectedTargetsPath
  if ([string]::IsNullOrWhiteSpace($staticFile) -and -not [string]::IsNullOrWhiteSpace($script:ExpectedTargetsRloc)) {
    $staticFile = Resolve-Runfile $script:ExpectedTargetsRloc
  }
  if (-not [string]::IsNullOrWhiteSpace($staticFile) -and (Test-Path -LiteralPath $staticFile -PathType Leaf)) {
    foreach ($line in [System.IO.File]::ReadAllLines($staticFile)) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $staticTargets.Add($line) | Out-Null
      }
    }
  }

  $dynamicConfigured = (
    -not [string]::IsNullOrWhiteSpace($script:ExpectedTargetsFilePath) -or
    -not [string]::IsNullOrWhiteSpace($script:ExpectedTargetsFileRloc)
  )
  if (-not $dynamicConfigured) {
    foreach ($label in $staticTargets) { $script:ExpectedTargets.Add($label) | Out-Null }
    $script:ExpectedTargetsConfigured = $staticTargets.Count -gt 0
    return
  }

  $dynamicFile = Resolve-ArtifactPath $script:ExpectedTargetsFilePath
  if ([string]::IsNullOrWhiteSpace($dynamicFile) -and -not [string]::IsNullOrWhiteSpace($script:ExpectedTargetsFileRloc)) {
    $dynamicFile = Resolve-Runfile $script:ExpectedTargetsFileRloc
  }
  if ([string]::IsNullOrWhiteSpace($dynamicFile) -or -not (Test-Path -LiteralPath $dynamicFile -PathType Leaf)) {
    Log "error: expected_targets_file does not exist or is not a file"
    exit 2
  }
  try {
    $doc = Get-Content -LiteralPath $dynamicFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Log "error: expected_targets_file must contain valid JSON"
    exit 2
  }
  $propertyNames = @($doc.PSObject.Properties.Name | Sort-Object)
  if (
    ($propertyNames -join ",") -ne "schema_version,targets" -or
    [int]$doc.schema_version -ne 1 -or
    $doc.targets -isnot [System.Array]
  ) {
    Log "error: expected_targets_file must contain exactly schema_version 1 and a targets array"
    exit 2
  }
  $dynamicTargets = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($value in @($doc.targets)) {
    if ($value -isnot [string] -or ([string]$value) -notmatch '^//[^:]*:[^:]+$') {
      Log "error: expected_targets_file targets must be local //pkg:target labels"
      exit 2
    }
    $label = [string]$value
    if (-not $seen.Add($label)) {
      Log "error: expected_targets_file contains duplicate target labels"
      exit 2
    }
    $dynamicTargets.Add($label) | Out-Null
  }
  $sortedTargets = @($dynamicTargets.ToArray() | Sort-Object -CaseSensitive)
  if (($dynamicTargets.ToArray() -join "`n") -cne ($sortedTargets -join "`n")) {
    Log "error: expected_targets_file targets must be sorted"
    exit 2
  }
  if ($staticTargets.Count -gt 0) {
    $dynamicSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($label in $dynamicTargets) { $dynamicSet.Add($label) | Out-Null }
    if (
      $staticTargets.Count -ne $dynamicSet.Count -or
      @($staticTargets | Where-Object { -not $dynamicSet.Contains($_) }).Count -gt 0
    ) {
      Log "error: static expected_targets and expected_targets_file contain different target sets"
      exit 2
    }
  }
  foreach ($label in $dynamicTargets) { $script:ExpectedTargets.Add($label) | Out-Null }
  $script:ExpectedTargetsConfigured = $true
}

function Initialize-BepEligibility {
  $script:FreshnessEligibleLabels.Clear()
  $script:FreshnessEligibleOutputs.Clear()
  $script:FreshnessCachedOutputs.Clear()
  $script:FreshnessSkippedOutputs.Clear()
  $script:FreshnessRemoteOnlyOutputs.Clear()
  $script:FreshnessMissingOutputLabels.Clear()

	  foreach ($bepJson in @($script:BepJsonFiles)) {
	    $resolvedBep = Resolve-RuntimeFilePath $bepJson
	    if ([string]::IsNullOrWhiteSpace($resolvedBep) -or -not (Test-Path -LiteralPath $resolvedBep -PathType Leaf)) {
	      if (Use-OptionalBepUnavailable "BEP JSON not found: $bepJson") {
	        return
	      }
	      Log "error: BEP JSON not found: $bepJson; continuing with other BEP files"
	      $script:UploadFailures++
	      continue
	    }
    $eligibleLabelsBefore = @($script:FreshnessEligibleLabels)
    $eligibleOutputsBefore = @($script:FreshnessEligibleOutputs)
    $cachedOutputsBefore = @($script:FreshnessCachedOutputs)
    $remoteOutputsBefore = @($script:FreshnessRemoteOnlyOutputs.ToArray())
    $missingLabelsBefore = @($script:FreshnessMissingOutputLabels)
    try {
      foreach ($event in @(Get-JsonStreamObjects $resolvedBep)) {
        $eventId = Get-MapValue $event 'id'
        $testResultId = Get-MapValue $eventId 'testResult'
        if ($null -eq $testResultId) { $testResultId = Get-MapValue $eventId 'test_result' }
        if ($null -eq $testResultId) { continue }
        $label = [string](Get-MapValue $testResultId 'label')
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if ($script:ExpectedTargetsConfigured -and -not $script:ExpectedTargets.Contains($label)) { continue }
        $result = Get-MapValue $event 'testResult'
        if ($null -eq $result) { $result = Get-MapValue $event 'test_result' }
        if ($null -eq $result) { continue }
        $cachedLocally = [bool](Get-MapValue $result 'cachedLocally')
        if (-not $cachedLocally) { $cachedLocally = [bool](Get-MapValue $result 'cached_locally') }
        $executionInfo = Get-MapValue $result 'executionInfo'
        if ($null -eq $executionInfo) { $executionInfo = Get-MapValue $result 'execution_info' }
        $cachedRemotely = [bool](Get-MapValue $executionInfo 'cachedRemotely')
        if (-not $cachedRemotely) { $cachedRemotely = [bool](Get-MapValue $executionInfo 'cached_remotely') }
	        $outputs = Get-MapValue $result 'testActionOutput'
	        if ($null -eq $outputs) { $outputs = Get-MapValue $result 'test_action_output' }
	        $mappedAny = $false
	        $eventEligibleOutputs = New-Object System.Collections.ArrayList
	        $eventCachedOutputs = New-Object System.Collections.ArrayList
	        $remoteOnlyCandidates = New-Object System.Collections.ArrayList
        foreach ($output in @($outputs)) {
          $outputHasTestOutputsHint = $false
          $outputRemoteCandidates = New-Object System.Collections.ArrayList
          $outputCandidates = @(Get-BepFileReferenceCandidates $output)
          $outputKey = ""
          foreach ($candidate in @(Get-BepCanonicalOutputKeyCandidates $output $outputCandidates)) {
            $candidateKey = Get-BepTestOutputKey $candidate
            if (-not [string]::IsNullOrWhiteSpace($candidateKey)) {
              $outputKey = $candidateKey
              break
            }
          }
          if (-not [string]::IsNullOrWhiteSpace($outputKey)) {
            $mappedAny = $true
            if ($cachedLocally -or $cachedRemotely) {
              $eventCachedOutputs.Add("$label`t$outputKey") | Out-Null
            } else {
              $eventEligibleOutputs.Add("$label`t$outputKey") | Out-Null
            }
          }
          foreach ($candidate in @($outputCandidates)) {
            if (Test-BepTestOutputsArtifactHint $candidate) {
              $outputHasTestOutputsHint = $true
            }
            if ((-not $cachedLocally) -and (-not $cachedRemotely) -and (Test-BepRemoteOnlyReference $candidate)) {
              $outputRemoteCandidates.Add([string]$candidate) | Out-Null
            }
          }
          if ((-not $cachedLocally) -and (-not $cachedRemotely) -and $outputRemoteCandidates.Count -gt 0) {
            $remoteOnlyCandidates.Add([pscustomobject]@{
              Candidates = @($outputRemoteCandidates.ToArray())
              HasTestOutputsHint = $outputHasTestOutputsHint
              OutputKey = $outputKey
            }) | Out-Null
          }
        }
        $eventRemoteOnlyAny = $false
        foreach ($remoteRef in @($remoteOnlyCandidates)) {
          if ($remoteRef.HasTestOutputsHint -or (-not $mappedAny)) {
            foreach ($candidate in @($remoteRef.Candidates)) {
              $eventRemoteOnlyAny = $true
              $script:FreshnessRemoteOnlyOutputs.Add([pscustomobject]@{
                Label = $label
                OutputKey = [string]$remoteRef.OutputKey
                Artifact = $candidate
                Reason = "remote_only"
              }) | Out-Null
	            }
	          }
	        }
	        foreach ($entry in @($eventCachedOutputs.ToArray())) {
	          $script:FreshnessCachedOutputs.Add([string]$entry) | Out-Null
	        }
	        if (-not $eventRemoteOnlyAny) {
	          foreach ($entry in @($eventEligibleOutputs.ToArray())) {
	            $script:FreshnessEligibleOutputs.Add([string]$entry) | Out-Null
	            $script:FreshnessEligibleLabels.Add(($entry -split "`t", 2)[0]) | Out-Null
	          }
	        }
	        if ((-not $cachedLocally) -and (-not $cachedRemotely) -and (-not $mappedAny) -and (-not $eventRemoteOnlyAny)) {
	          $script:FreshnessMissingOutputLabels.Add($label) | Out-Null
	        }
      }
	    } catch {
	      $script:FreshnessEligibleLabels.Clear()
	      foreach ($entry in $eligibleLabelsBefore) { $script:FreshnessEligibleLabels.Add([string]$entry) | Out-Null }
	      $script:FreshnessEligibleOutputs.Clear()
	      foreach ($entry in $eligibleOutputsBefore) { $script:FreshnessEligibleOutputs.Add([string]$entry) | Out-Null }
	      $script:FreshnessCachedOutputs.Clear()
	      foreach ($entry in $cachedOutputsBefore) { $script:FreshnessCachedOutputs.Add([string]$entry) | Out-Null }
	      $script:FreshnessRemoteOnlyOutputs.Clear()
	      foreach ($entry in $remoteOutputsBefore) { $script:FreshnessRemoteOnlyOutputs.Add($entry) | Out-Null }
	      $script:FreshnessMissingOutputLabels.Clear()
	      foreach ($entry in $missingLabelsBefore) { $script:FreshnessMissingOutputLabels.Add([string]$entry) | Out-Null }
	      if (Use-OptionalBepUnavailable "failed to parse BEP JSON: $resolvedBep ($($_.Exception.Message))") {
	        return
	      }
	      Log "error: failed to parse BEP JSON: $resolvedBep ($($_.Exception.Message)); continuing with other BEP files"
	      $script:UploadFailures++
	      continue
	    }
  }

  $conflictingOutputs = @($script:FreshnessEligibleOutputs | Where-Object { $script:FreshnessCachedOutputs.Contains($_) })
  if ($conflictingOutputs.Count -gt 0) {
    Log "error: BEP freshness is ambiguous: the same test output is reported as both fresh and cached: $($conflictingOutputs[0]). Use one BEP file per Bazel test invocation and do not pass overlapping stale BEP files."
    exit 2
  }

	  $script:FreshnessSelectedSource = "bep"
	  $script:FreshnessEligibilityEnabled = $true
	  Log "freshness filtering enabled: source=bep files=$($script:BepJsonFiles.Count) eligible_outputs=$($script:FreshnessEligibleOutputs.Count) remote_only_outputs=$($script:FreshnessRemoteOnlyOutputs.Count)"
	  if ($script:FreshnessMode -eq "optional" -and $script:RemoteArtifacts -ne "required" -and $script:FreshnessRemoteOnlyOutputs.Count -gt 0) {
	    $first = $script:FreshnessRemoteOnlyOutputs[0]
	    $firstArtifact = Format-ArtifactReferenceForLog $first.Artifact
	    Log "warning: BEP references remote-only test outputs for $($first.Label): $firstArtifact; skipping those outputs. Rerun with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* to materialize payloads locally. If the test run used --zip_undeclared_test_outputs, rerun the uploader with --artifact-source=bep."
	  }
	}

function Test-CiEnvironment {
  $ci = [string]$env:CI
  if ([string]::IsNullOrWhiteSpace($ci)) { return $false }
  $normalized = $ci.ToLowerInvariant()
  return ($normalized -ne "0" -and $normalized -ne "false" -and $normalized -ne "no")
}

function Initialize-ExecutionLogEligibility {
  if ($script:ExecutionLogMode -eq "disabled") {
    if (-not [string]::IsNullOrWhiteSpace($script:ExecutionLogJson)) {
      Log "warning: execution-log filtering disabled; ignoring configured execution log: $($script:ExecutionLogJson)"
    }
    return
  }

  if ([string]::IsNullOrWhiteSpace($script:ExecutionLogJson)) {
    if ($script:ExecutionLogMode -eq "required" -or ($script:ExecutionLogMode -eq "auto" -and (Test-CiEnvironment))) {
      if ($script:ExecutionLogMode -eq "required") {
        Log "error: execution-log cache filtering is required by DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE=required / --execution-log-mode=required. Run bazel test with --execution_log_json_file=$($script:DefaultExecutionLogJson), then rerun the uploader with --execution-log-json=$($script:DefaultExecutionLogJson), or opt out explicitly with DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE=disabled / --allow-cached-payload-uploads."
      } else {
        Log "error: execution-log cache filtering is required in CI. Run bazel test with --execution_log_json_file=$($script:DefaultExecutionLogJson), then rerun the uploader with --execution-log-json=$($script:DefaultExecutionLogJson), or opt out explicitly with DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE=disabled / --allow-cached-payload-uploads."
      }
      exit 2
    }
    if ($script:ExecutionLogMode -eq "auto") {
      Log "warning: execution-log cache filtering is not configured; cached test outputs may be uploaded. Add --execution_log_json_file=$($script:DefaultExecutionLogJson) to bazel test and --execution-log-json=$($script:DefaultExecutionLogJson) to the uploader, or set DD_TEST_OPTIMIZATION_EXECUTION_LOG_MODE=disabled to opt out explicitly."
    }
    return
  }

  $resolvedLog = Resolve-RuntimeFilePath $script:ExecutionLogJson
  if ([string]::IsNullOrWhiteSpace($resolvedLog) -or -not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) {
    Log "error: execution log JSON not found: $($script:ExecutionLogJson)"
    exit 2
  }
  try {
    foreach ($spawn in @(Get-JsonStreamObjects $resolvedLog)) {
      if (([string]($spawn.mnemonic)) -ne "TestRunner") { continue }
      $outputKeys = @(Get-SpawnTestOutputKeys $spawn)
      if ($outputKeys.Count -eq 0) { continue }
      if ($spawn.PSObject.Properties.Name -contains "cacheHit" -and [bool]$spawn.cacheHit) { continue }
      $runner = [string]($spawn.runner)
      if ($runner.ToLowerInvariant().Contains("cache hit")) { continue }
      $label = [string]($spawn.targetLabel)
      if (-not [string]::IsNullOrWhiteSpace($label)) {
        $script:ExecutionEligibleLabels.Add($label) | Out-Null
        foreach ($outputKey in $outputKeys) {
          $script:ExecutionEligibleOutputs.Add("$label`t$outputKey") | Out-Null
        }
      }
    }
  } catch {
    Log "error: failed to parse execution log JSON: $resolvedLog"
    exit 2
  }
  $script:ExecutionEligibilityEnabled = $true
  Dbg "execution-log freshness filter enabled: $resolvedLog ($($script:ExecutionEligibleOutputs.Count) eligible test outputs)"
}

function Initialize-FreshnessEligibility {
  if ($script:FreshnessMode -eq "disabled") {
    if ($script:BepJsonFiles.Count -gt 0) {
      Log "warning: freshness filtering disabled; ignoring configured BEP JSON"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ExecutionLogJson)) {
      Log "warning: freshness filtering disabled; ignoring configured execution log: $($script:ExecutionLogJson)"
    }
    $script:FreshnessSelectedSource = "none"
    $script:FreshnessEligibilityEnabled = $false
    Log "freshness filtering disabled"
    return
  }

  if ($script:FreshnessSource -eq "bep") {
    if ($script:BepJsonFiles.Count -eq 0) {
      if ($script:FreshnessMode -eq "required" -or ($script:FreshnessMode -eq "auto" -and (Test-CiEnvironment))) {
        Log "error: BEP freshness filtering is required but no BEP JSON file was configured. Run bazel test with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=$($script:DefaultBepJson), then rerun the uploader with --bep-json=$($script:DefaultBepJson), or opt out explicitly with --allow-cached-payload-uploads."
        Exit-WithUploaderReport 2
      }
      Log "warning: BEP freshness source was selected but no BEP JSON file was configured; cached test outputs may be uploaded. Rerun the uploader with --bep-json=$($script:DefaultBepJson) --freshness-source=bep --freshness-mode=required, or opt out explicitly with --allow-cached-payload-uploads."
      return
    }
    Initialize-BepEligibility
    return
  }

  if ($script:FreshnessSource -eq "execution_log") {
    Initialize-ExecutionLogEligibility
  } elseif ($script:BepJsonFiles.Count -gt 0) {
    Initialize-BepEligibility
  } else {
    if ([string]::IsNullOrWhiteSpace($script:ExecutionLogJson)) {
      if ($script:FreshnessMode -eq "required" -or ($script:FreshnessMode -eq "auto" -and (Test-CiEnvironment))) {
        Log "error: freshness filtering is required in CI or required mode, but no BEP or execution log was found. Run bazel test with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=$($script:DefaultBepJson), then rerun the uploader with --bep-json=$($script:DefaultBepJson) --freshness-source=bep --freshness-mode=required, or opt out explicitly with --allow-cached-payload-uploads."
        Exit-WithUploaderReport 2
      }
      Log "warning: freshness filtering is not configured; cached test outputs may be uploaded. Prefer bazel test --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --build_event_json_file=$($script:DefaultBepJson) and rerun the uploader with --bep-json=$($script:DefaultBepJson) --freshness-source=bep --freshness-mode=required, or opt out explicitly with --allow-cached-payload-uploads."
      return
    }
    Initialize-ExecutionLogEligibility
  }

  if ($script:ExecutionEligibilityEnabled) {
    $script:FreshnessSelectedSource = "execution_log"
    $script:FreshnessEligibilityEnabled = $true
    foreach ($item in $script:ExecutionEligibleLabels) { $script:FreshnessEligibleLabels.Add($item) | Out-Null }
    foreach ($item in $script:ExecutionEligibleOutputs) { $script:FreshnessEligibleOutputs.Add($item) | Out-Null }
    Log "freshness filtering enabled: source=execution_log"
  }
}

function Get-TestOutputTargetLabel([string]$OutputsDir) {
  if ([string]::IsNullOrWhiteSpace($OutputsDir)) { return "" }
  $metadataPath = Join-Path $OutputsDir $script:BazelTargetMetadataOutput
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return "" }
  try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    return [string]($metadata.'bazel.target')
  } catch {
    return ""
  }
}

function Merge-StagedBepFreshness {
  if ($script:FreshnessSelectedSource -ne "bep") { return }

  foreach ($pair in @($script:StagedOutputKeys)) {
    if ([string]::IsNullOrWhiteSpace($pair)) { continue }
    $pairLabel = ($pair -split "`t", 2)[0]
    if ($script:ExpectedTargetsConfigured -and -not $script:ExpectedTargets.Contains($pairLabel)) { continue }
    $script:FreshnessEligibleOutputs.Add($pair) | Out-Null
    $parts = $pair -split "`t", 2
    if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
      $script:FreshnessEligibleLabels.Add($parts[0]) | Out-Null
    }
  }

  if ($script:StagedRemoteClearances.Count -gt 0) {
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($remote in $script:FreshnessRemoteOnlyOutputs.ToArray()) {
      $pair = "$($remote.Label)`t$($remote.OutputKey)"
      if (-not $script:StagedRemoteClearances.Contains($pair)) {
        $remaining.Add($remote) | Out-Null
      }
    }
    $script:FreshnessRemoteOnlyOutputs.Clear()
    foreach ($remote in @($remaining.ToArray())) {
      $script:FreshnessRemoteOnlyOutputs.Add($remote) | Out-Null
    }
  }

  $conflictingOutputs = @($script:FreshnessEligibleOutputs | Where-Object { $script:FreshnessCachedOutputs.Contains($_) })
  if ($conflictingOutputs.Count -gt 0) {
    Log "error: BEP freshness is ambiguous: the same test output is reported as both fresh and cached: $($conflictingOutputs[0]). Use one BEP file per Bazel test invocation and do not pass overlapping stale BEP files."
    exit 2
  }
}

function Assert-ExpectedTargetCoverage {
  if (-not $script:ExpectedTargetsConfigured -or $script:FreshnessSelectedSource -ne "bep") { return }
  $missingCount = 0
  foreach ($label in $script:ExpectedTargets) {
    $hasFresh = @($script:FreshnessEligibleOutputs | Where-Object { $_.StartsWith("$label`t", [System.StringComparison]::Ordinal) }).Count -gt 0
    $hasCached = @($script:FreshnessCachedOutputs | Where-Object { $_.StartsWith("$label`t", [System.StringComparison]::Ordinal) }).Count -gt 0
    if ($hasFresh -or $hasCached) { continue }
    $hasRemote = @($script:FreshnessRemoteOnlyOutputs | Where-Object { $_.Label -eq $label }).Count -gt 0
    if ($hasRemote) { continue }
    if ($script:FreshnessMissingOutputLabels.Contains($label)) {
      Log "warning: expected target output is neither fresh nor exclusively cached in BEP: $label (the fresh TestResult did not contain a mappable test.outputs reference); continuing with other fresh outputs"
    } else {
      Log "warning: expected target output is neither fresh nor exclusively cached in BEP: $label (no TestResult matched this target); continuing with other fresh outputs"
    }
    $missingCount++
  }
  if ($missingCount -gt 0) {
    Log "warning: $missingCount expected target(s) produced no current uploadable output; available fresh payloads will still be processed"
    $script:UploadFailures += $missingCount
  }
}

function Write-ExecutionSkipOnce([string]$OutputsDir, [string]$Reason) {
  if ($script:ExecutionSkippedOutputs.Add($OutputsDir)) {
    [Console]::Out.WriteLine("[dd-uploader] skipping cached test output: $OutputsDir ($Reason)")
  }
}

function Assert-NoRequiredRemoteOnlyBepOutputs {
  if ($script:RemoteOnlyOutputsValidated) { return }
  $script:RemoteOnlyOutputsValidated = $true
  if ($script:FreshnessSelectedSource -ne "bep") { return }
  if ($script:FreshnessRemoteOnlyOutputs.Count -gt 0) {
    $first = $script:FreshnessRemoteOnlyOutputs[0]
    $firstArtifact = Format-ArtifactReferenceForLog $first.Artifact
    if ($script:FreshnessMode -eq "required" -or $script:RemoteArtifacts -eq "required") {
      Log "error: BEP references remote-only test outputs for $($first.Label), but local test.outputs was not found: $firstArtifact. Those outputs will be skipped while other fresh payloads are processed. Rerun with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* or configure a BEP artifact fetcher. If the test run used --zip_undeclared_test_outputs, rerun the uploader with --artifact-source=bep."
      $script:UploadFailures += $script:FreshnessRemoteOnlyOutputs.Count
      return
    }
    if ($script:RemoteArtifacts -eq "download") {
      Log "warning: BEP references remote-only test outputs for $($first.Label): $firstArtifact; unmaterialized outputs will be skipped."
      return
    }
    if ($script:RemoteArtifacts -eq "disabled") {
      Log "warning: BEP references remote-only test outputs for $($first.Label): $firstArtifact; remote artifact staging is disabled."
      return
    }
  }
}

function Write-FreshnessSkipOnce([string]$OutputsDir, [string]$Reason) {
  $script:FreshnessSkipWasWritten = $false
  if ($script:FreshnessSkippedOutputs.Add($OutputsDir)) {
    [Console]::Out.WriteLine("[dd-uploader] skipping cached or non-current test output: $OutputsDir ($Reason)")
    $script:FreshnessSkipWasWritten = $true
  }
}

function Test-OutputDirFreshnessEligible([string]$OutputsDir) {
  Assert-NoRequiredRemoteOnlyBepOutputs
  $targetLabel = Get-TestOutputTargetLabel $OutputsDir
  if ((-not [string]::IsNullOrWhiteSpace($targetLabel)) -and $script:BlockedBepArtifactLabels.Contains($targetLabel)) {
    Write-FreshnessSkipOnce $OutputsDir "BEP artifact for target $targetLabel did not contain a mappable test.outputs key"
    return $false
  }
  if (-not $script:FreshnessEligibilityEnabled) { return $true }
  if ([string]::IsNullOrWhiteSpace($targetLabel)) {
    if ($script:FreshnessSelectedSource -eq "bep" -and $script:FreshnessMode -eq "required") {
      Log "error: BEP required freshness cannot authorize $OutputsDir because bazel.target metadata is missing"
      exit 2
    }
    Write-FreshnessSkipOnce $OutputsDir "missing bazel.target metadata"
    return $false
  }
  $outputKey = Get-TestOutputDirKey $OutputsDir
  if ([string]::IsNullOrWhiteSpace($outputKey)) {
    if ($script:FreshnessSelectedSource -eq "bep" -and $script:FreshnessMode -eq "required") {
      Log "error: BEP required freshness cannot authorize $OutputsDir because the test.outputs path could not be mapped"
      exit 2
    }
    Write-FreshnessSkipOnce $OutputsDir "could not map test.outputs path"
    return $false
  }
  if ($script:FreshnessEligibleOutputs.Contains("$targetLabel`t$outputKey")) {
    return $true
  }
  if ($script:FreshnessCachedOutputs.Contains("$targetLabel`t$outputKey")) {
    Write-FreshnessSkipOnce $OutputsDir "BEP reported cached result for target $targetLabel output $outputKey"
  } elseif ($script:FreshnessSelectedSource -eq "bep" -and $script:FreshnessMode -eq "required") {
    if ($script:FreshnessMissingOutputLabels.Contains($targetLabel)) {
      Write-FreshnessSkipOnce $OutputsDir "fresh BEP TestResult for $targetLabel did not contain a mappable test.outputs reference"
      if ($script:FreshnessSkipWasWritten) {
        Log "warning: BEP required freshness skipped $OutputsDir because the fresh TestResult for $targetLabel did not contain a mappable test.outputs reference. Rerun with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* and inspect the BEP testActionOutput entries. If the test run used --zip_undeclared_test_outputs, rerun the uploader with --artifact-source=bep."
        if (-not $script:ExpectedTargetsConfigured) {
          $script:UploadFailures++
        }
      }
    } else {
      Write-FreshnessSkipOnce $OutputsDir "no fresh BEP TestResult matched target $targetLabel output $outputKey"
    }
  } elseif ($script:FreshnessSelectedSource -eq "bep" -and $script:FreshnessMode -eq "optional" -and $script:FreshnessMissingOutputLabels.Contains($targetLabel)) {
    Write-FreshnessSkipOnce $OutputsDir "fresh BEP TestResult for $targetLabel did not contain a mappable test.outputs reference"
    if ($script:FreshnessSkipWasWritten) {
      Log "warning: BEP optional freshness skipped $OutputsDir because the fresh TestResult for $targetLabel did not contain a mappable test.outputs reference. Rerun with --remote_download_minimal --remote_download_regex=.*test[.]outputs.* and inspect the BEP testActionOutput entries. If the test run used --zip_undeclared_test_outputs, rerun the uploader with --artifact-source=bep."
    }
  } else {
    Write-FreshnessSkipOnce $OutputsDir "no fresh $($script:FreshnessSelectedSource) result matched target $targetLabel output $outputKey"
  }
  return $false
}

function Mark-FreshOutputHandled([string]$OutputsDir) {
  if ([string]::IsNullOrWhiteSpace($OutputsDir)) { return }
  $targetLabel = Get-TestOutputTargetLabel $OutputsDir
  $outputKey = Get-TestOutputDirKey $OutputsDir
  if ([string]::IsNullOrWhiteSpace($targetLabel) -or [string]::IsNullOrWhiteSpace($outputKey)) { return }
  $pair = "$targetLabel`t$outputKey"
  if ($script:FreshnessEligibleOutputs.Contains($pair)) {
    $script:HandledFreshOutputs.Add($pair) | Out-Null
  }
}

function Assert-FreshOutputsHandled {
  if (-not $FailOnError -or $script:FreshnessSelectedSource -ne "bep") { return }
  if ($script:ExpectedTargetsConfigured) {
    $missing = @($script:FreshnessEligibleOutputs | Where-Object { -not $script:HandledFreshOutputs.Contains($_) })
    if ($missing.Count -gt 0) {
      Log "error: fresh expected test output produced no uploadable payloads: $($missing[0])"
      Exit-WithUploaderReport 1
    }
    return
  }
  $freshOutputCount = Get-ReportCollectionCount $script:FreshnessEligibleOutputs
  $handledPayloadCount = [int](
    $script:ReportTestsProcessed +
    $script:ReportCoverageProcessed +
    $script:ReportTelemetryProcessed +
    $script:ReportTestsFailed +
    $script:ReportCoverageFailed +
    $script:ReportTelemetryFailed
  )
  if ($freshOutputCount -gt 0 -and $handledPayloadCount -eq 0) {
    Log "error: BEP reported $freshOutputCount fresh test output(s), but none produced uploadable payloads"
    Exit-WithUploaderReport 1
  }
}

function Test-OutputDirExecutionEligible([string]$OutputsDir) {
  if (-not $script:ExecutionEligibilityEnabled) { return $true }
  $targetLabel = Get-TestOutputTargetLabel $OutputsDir
  if ([string]::IsNullOrWhiteSpace($targetLabel)) {
    Write-ExecutionSkipOnce $OutputsDir "missing bazel.target metadata"
    return $false
  }
  $outputKey = Get-TestOutputDirKey $OutputsDir
  if ([string]::IsNullOrWhiteSpace($outputKey)) {
    Write-ExecutionSkipOnce $OutputsDir "could not map test.outputs path"
    return $false
  }
  $eligibleOutput = $script:ExecutionEligibleOutputs.Contains("$targetLabel`t$outputKey")
  if ($eligibleOutput) {
    return $true
  }
  Write-ExecutionSkipOnce $OutputsDir "target $targetLabel output $outputKey was not freshly executed"
  return $false
}

$script:ContextInfoCache = @{}

function Get-ContextInfo([string]$ContextPath) {
  if ([string]::IsNullOrEmpty($ContextPath)) { return $null }
  if ($script:ContextInfoCache.ContainsKey($ContextPath)) {
    return $script:ContextInfoCache[$ContextPath]
  }

  $info = @{
    Path = $ContextPath
    JsonText = $null
    Object = $null
  }

  if (Test-Path -LiteralPath $ContextPath -PathType Leaf) {
    try {
      $info.JsonText = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8
      $info.Object = $info.JsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Log "warning: failed to parse context.json for payload enrichment: $ContextPath"
    }
  }

  $script:ContextInfoCache[$ContextPath] = $info
  return $info
}

function Resolve-ContextJsonForPayload([string]$PayloadFile) {
  if ($script:ContextJsonFromOverride) {
    return $script:PrimaryContextJson
  }

  if ($script:BundledContextEntries.Count -le 1) {
    return $script:PrimaryContextJson
  }

  $bazelMetadataPath = Get-BazelTargetMetadataPath $PayloadFile
  if ([string]::IsNullOrEmpty($bazelMetadataPath)) {
    Log-Stderr "warning: skipping context enrichment for '$PayloadFile' because multiple bundled contexts are present and bazel_target_metadata.json is missing"
    return $null
  }

  $bazelMetadataObj = $null
  try {
    $bazelMetadataObj = Get-Content -LiteralPath $bazelMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Log "warning: failed to parse Bazel target metadata for payload: $PayloadFile"
    return $null
  }

  $repoKey = Get-MapValue $bazelMetadataObj 'bazel.test_optimization.repo_name'
  if (($repoKey -isnot [string]) -or [string]::IsNullOrWhiteSpace($repoKey)) {
    Log-Stderr "warning: skipping context enrichment for '$PayloadFile' because bazel.test_optimization.repo_name is missing from '$bazelMetadataPath'"
    return $null
  }

  if (-not $script:BundledContextEntries.Contains($repoKey)) {
    Log-Stderr "warning: skipping context enrichment for '$PayloadFile' because no bundled context matched repo '$repoKey'"
    return $null
  }

  $matchedContext = [string]$script:BundledContextEntries[$repoKey]
  Dbg "selected bundled context '$matchedContext' for payload '$PayloadFile' via repo '$repoKey'"
  return $matchedContext
}

function Merge-FlatMetadataIntoEvent($EventObj, $MetadataObj, [string[]]$SkippedKeys = @()) {
  if (-not $MetadataObj) { return }
  if (-not (Get-MapValue $EventObj 'content')) { $EventObj | Add-Member -NotePropertyName content -NotePropertyValue @{} -Force }
  $EventObj.content = Ensure-Hashtable $EventObj.content
  $EventObj.content.meta = Ensure-Hashtable $EventObj.content.meta
  $EventObj.content.metrics = Ensure-Hashtable $EventObj.content.metrics

  foreach ($prop in $MetadataObj.PSObject.Properties) {
    if ($SkippedKeys -contains $prop.Name) { continue }
    $val = $prop.Value
    if ($val -is [string]) {
      $EventObj.content.meta[$prop.Name] = $val
    } elseif ($val -is [bool]) {
      $EventObj.content.meta[$prop.Name] = $val.ToString().ToLowerInvariant()
    } elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {
      $EventObj.content.metrics[$prop.Name] = [double]$val
    } else {
      try {
        $EventObj.content.meta[$prop.Name] = ($val | ConvertTo-Json -Compress -Depth 100)
      } catch {
        $EventObj.content.meta[$prop.Name] = $val.ToString()
      }
    }
  }
}

function Merge-With-Context([string]$infile, [string]$outfile) {
  try {
    $payload = Get-Content -LiteralPath $infile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  } catch {
    # If payload is not JSON, preserve original bytes and let upload attempt
    # proceed; validation/debugging layers surface the issue separately.
    Copy-Item -LiteralPath $infile -Destination $outfile -Force
    return
  }

  $selectedContextPath = Resolve-ContextJsonForPayload $infile
  $selectedContextInfo = Get-ContextInfo $selectedContextPath
  $selectedContextObj = if ($selectedContextInfo) { $selectedContextInfo.Object } else { $null }
  Dbg "Merge-With-Context: infile='$infile' selected_ctx='$(if ([string]::IsNullOrEmpty($selectedContextPath)) { '<none>' } else { $selectedContextPath })' primary='$(if ([string]::IsNullOrEmpty($script:PrimaryContextJson)) { '<none>' } else { $script:PrimaryContextJson })'"

  if (-not $payload.metadata) { $payload | Add-Member -NotePropertyName metadata -NotePropertyValue @{} -Force }
  $meta = Ensure-Hashtable $payload.metadata
  $star = Ensure-Hashtable (Get-MapValue $meta '*')

  # Compute runtime-id, language, library_version, env (fill missing only)
  $runtimeId = Get-MapValue $star 'runtime-id'
  if ([string]::IsNullOrEmpty($runtimeId)) {
    if ($selectedContextObj) {
      $runtimeId = Get-MapValue $selectedContextObj 'runtime-id'
      if ([string]::IsNullOrEmpty($runtimeId)) { $runtimeId = Get-MapValue $selectedContextObj 'runtime.id' }
      if ([string]::IsNullOrEmpty($runtimeId)) { $runtimeId = Get-MapValue $selectedContextObj 'runtime_id' }
    }
    if ([string]::IsNullOrEmpty($runtimeId)) { $runtimeId = $script:RuntimeId }
  }

  $language = Get-MapValue $star 'language'
  if ([string]::IsNullOrEmpty($language)) {
    if ($selectedContextObj) {
      $language = Get-MapValue $selectedContextObj 'language'
      if ([string]::IsNullOrEmpty($language)) { $language = Get-MapValue $selectedContextObj 'runtime.name' }
      if ([string]::IsNullOrEmpty($language)) { $language = Get-MapValue $selectedContextObj 'runtime_name' }
    }
    if ([string]::IsNullOrEmpty($language)) { $language = 'bazel' }
  }

  $libraryVersion = Get-MapValue $star 'library_version'
  if ([string]::IsNullOrEmpty($libraryVersion)) { $libraryVersion = $script:RulesVersion }

  $envVal = Get-MapValue $star 'env'
  if ([string]::IsNullOrEmpty($envVal) -and $selectedContextObj) { $envVal = Get-MapValue $selectedContextObj 'env' }

  $newStar = @{ 'runtime-id' = $runtimeId; 'language' = $language; 'library_version' = $libraryVersion }
  if (-not [string]::IsNullOrEmpty($envVal)) { $newStar['env'] = $envVal }

  # Prune top-level metadata keys
  # Keep only documented metadata sections to avoid propagating unexpected
  # large/unstable keys from upstream payload generators.
  $newMeta = @{ '*' = $newStar }
  foreach ($k in @('test', 'test_suite_end', 'test_module_end', 'test_session_end')) {
    $metaVal = Get-MapValue $meta $k
    if ($null -ne $metaVal) { $newMeta[$k] = $metaVal }
  }
  $payload.metadata = $newMeta

  $bazelMetadataObj = $null
  $bazelMetadataPath = Get-BazelTargetMetadataPath $infile
  if (-not [string]::IsNullOrEmpty($bazelMetadataPath)) {
    try {
      $bazelMetadataObj = Get-Content -LiteralPath $bazelMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Log "warning: failed to parse Bazel target metadata for payload: $infile"
      $bazelMetadataObj = $null
    }
  }

  # Copy context tags into every captured test event, then inject CODEOWNERS.
  # Go test payloads can encode CI Visibility test data as span events, and
  # those events still need Git and Bazel sidecar tags before upload.
  if ($payload.events) {
    foreach ($evt in $payload.events) {
      $evtType = Get-MapValue $evt 'type'
      if (-not (Get-MapValue $evt 'content')) { $evt | Add-Member -NotePropertyName content -NotePropertyValue @{} -Force }
      $evt.content = Ensure-Hashtable $evt.content
      $evt.content.meta = Ensure-Hashtable $evt.content.meta
      $evt.content.metrics = Ensure-Hashtable $evt.content.metrics

      if ($selectedContextObj) {
        # Keep API key fingerprint out of uploaded event content.
        Merge-FlatMetadataIntoEvent $evt $selectedContextObj @('topt.api_key_fingerprint')
      }
      if ($bazelMetadataObj) {
        Merge-FlatMetadataIntoEvent $evt $bazelMetadataObj
      }

      # CODEOWNERS remains scoped to non-span lifecycle/test events. Span-form Go
      # events still receive context and Bazel tags before this CODEOWNERS pass.
      if ($evtType -eq 'span') { continue }

      $script:CodeOwnersStats.scanned++
      # Respect upstream/producer-specified ownership tags.
      if ($evt.content.meta.Contains('test.codeowners')) {
        $script:CodeOwnersStats.skipped_existing++
        if ($script:DebugMode) { Dbg "codeowners: skip existing tag for event type '$evtType'" }
        continue
      }
      $sourcePath = Get-EventSourcePath $evt
      if ([string]::IsNullOrEmpty($sourcePath)) {
        $script:CodeOwnersStats.skipped_missing_source++
        if ($script:DebugMode) { Dbg "codeowners: skip missing source for event type '$evtType'" }
        continue
      }
      try {
        $ownersJson = Get-CodeOwnersJsonForSource $sourcePath
        if ([string]::IsNullOrEmpty($ownersJson)) {
          $script:CodeOwnersStats.skipped_unmatched++
          if ($script:DebugMode) { Dbg "codeowners: skip unmatched source '$sourcePath' for event type '$evtType'" }
          continue
        }
        $evt.content.meta['test.codeowners'] = $ownersJson
        $script:CodeOwnersStats.enriched++
        if ($script:DebugMode) { Dbg "codeowners: assigned owners '$ownersJson' for event type '$evtType'" }
      } catch {
        $script:CodeOwnersStats.skipped_errors++
        Dbg "codeowners: failed to resolve owners for '$sourcePath' ($_)"
      }
    }
  }

  if ($script:DebugMode) {
    Dbg "codeowners: scanned=$($script:CodeOwnersStats.scanned) enriched=$($script:CodeOwnersStats.enriched) skipped_existing=$($script:CodeOwnersStats.skipped_existing) skipped_missing_source=$($script:CodeOwnersStats.skipped_missing_source) skipped_unmatched=$($script:CodeOwnersStats.skipped_unmatched) skipped_errors=$($script:CodeOwnersStats.skipped_errors)"
  }

  Dbg "Merge-With-Context: wrote enriched '$outfile'"
  $jsonPayload = $payload | ConvertTo-Json -Depth 100
  Write-Utf8NoBomFile -Path $outfile -Content $jsonPayload
}

function Validate-Payload([string]$FilePath) {
    if (-not $script:SchemaJson -or -not (Test-Path -LiteralPath $script:SchemaJson)) {
        Dbg "schema validation skipped: schema not available"
        return
    }
    if (-not $script:SchemaValidator -or -not (Test-Path -LiteralPath $script:SchemaValidator)) {
        Dbg "schema validation skipped: validator not available"
        return
    }
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) {
        Dbg "schema validation skipped: python3 not available"
        return
    }
    Dbg "schema validate: python3 $script:SchemaValidator $script:SchemaJson $FilePath"
    try {
        # Suppress validator stdout/stderr so upload boolean control flow is not
        # polluted by non-empty command output streams.
        & $py.Source $script:SchemaValidator $script:SchemaJson $FilePath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Warning-only contract: validation should not block uploads.
            Log "warning: schema validation failed for payload: $FilePath"
        }
    } catch {
        Log "warning: schema validation failed for payload: $FilePath"
    }
}

# Check if file matches prefix filter (when enabled)
function Test-PrefixFilter([string]$FilePath, [string]$ExpectedPrefix) {
    if (-not $FilterPrefix) { return $true }  # No filtering, accept all
    $basename = Split-Path -Leaf $FilePath
    return $basename.StartsWith($ExpectedPrefix)
}

# Enumerate replayable payload files in deterministic lexicographic order.
function Get-SortedPayloadFiles([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return @() }
    $files = @(Get-ChildItem -Path $DirPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".json", ".msgpack") })
    if ($files.Count -gt 1) {
        [Array]::Sort(
            $files,
            [System.Collections.Generic.Comparer[object]]::Create(
                [System.Comparison[object]]{
                    param($left, $right)
                    $leftName = if ($null -eq $left) { "" } else { [string]$left.Name }
                    $rightName = if ($null -eq $right) { "" } else { [string]$right.Name }
                    return [System.StringComparer]::Ordinal.Compare($leftName, $rightName)
                }
            )
        )
    }
    return $files
}

# Enumerate Bazel-mode test payload files. Test payloads must stay JSON so the
# uploader can enrich them with repository and Bazel metadata before upload.
function Get-SortedTestPayloadFiles([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return @() }
    $files = @(Get-ChildItem -Path $DirPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".json" })
    if ($files.Count -gt 1) {
        [Array]::Sort(
            $files,
            [System.Collections.Generic.Comparer[object]]::Create(
                [System.Comparison[object]]{
                    param($left, $right)
                    $leftName = if ($null -eq $left) { "" } else { [string]$left.Name }
                    $rightName = if ($null -eq $right) { "" } else { [string]$right.Name }
                    return [System.StringComparer]::Ordinal.Compare($leftName, $rightName)
                }
            )
        )
    }
    return $files
}

function Get-SortedRawTestMsgpackFiles([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return @() }
    $files = @(Get-ChildItem -Path $DirPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".msgpack" })
    if ($files.Count -gt 1) {
        [Array]::Sort(
            $files,
            [System.Collections.Generic.Comparer[object]]::Create(
                [System.Comparison[object]]{
                    param($left, $right)
                    $leftName = if ($null -eq $left) { "" } else { [string]$left.Name }
                    $rightName = if ($null -eq $right) { "" } else { [string]$right.Name }
                    return [System.StringComparer]::Ordinal.Compare($leftName, $rightName)
                }
            )
        )
    }
    return $files
}

function Test-PayloadDirHasReplayableFiles([string]$DirPath) {
    return ((@(Get-SortedPayloadFiles $DirPath)).Count -gt 0)
}

function Test-TestPayloadDirHasCandidateFiles([string]$DirPath) {
    return (((@(Get-SortedTestPayloadFiles $DirPath)).Count + (@(Get-SortedRawTestMsgpackFiles $DirPath)).Count) -gt 0)
}

# Return true when a JSON test payload has at least one uploadable event. Some
# tracers can leave empty `{}` placeholder files under payloads/tests; those
# files are not valid Test Optimization payloads and should not be uploaded.
function Test-TestPayloadHasEvents([string]$FilePath) {
    try {
        $payload = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Preserve the existing error path for malformed JSON instead of hiding
        # it as an empty payload.
        return [bool]$true
    }
    $events = @(Get-MapValue $payload 'events')
    return [bool]($events.Count -gt 0)
}

# Detect whether one replay payload is stored in raw msgpack form.
function Test-MsgpackPayload([string]$FilePath) {
    return ([System.StringComparer]::OrdinalIgnoreCase.Compare([System.IO.Path]::GetExtension($FilePath), ".msgpack") -eq 0)
}

# Select the coverage multipart content type that matches the captured payload.
function Get-CoveragePayloadContentType([string]$FilePath) {
    if (Test-MsgpackPayload $FilePath) { return "application/msgpack" }
    return "application/json"
}

# Select the coverage multipart filename that matches the captured payload.
function Get-CoveragePayloadFileName([string]$FilePath) {
    if (Test-MsgpackPayload $FilePath) { return "filecoveragex.msgpack" }
    return "filecoveragex.json"
}

# Delete file unless KeepPayloads is set
function Remove-PayloadFile([string]$FilePath) {
    if (-not $KeepPayloads) {
        # Best-effort cleanup: payload persistence is controlled by KeepPayloads,
        # not by upload success/failure of individual files.
        try {
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop
        } catch {
            # Preserve best-effort semantics even when files are read-only or already gone.
            try {
                $item = Get-Item -LiteralPath $FilePath -ErrorAction Stop
                if ($item -and $item.PSObject.Properties['IsReadOnly']) {
                    $item.IsReadOnly = $false
                }
            } catch {}
            if (-not $IsWindows) {
                & chmod u+w -- (Split-Path -Parent $FilePath) 2>$null
            }
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        }
    } else {
        Dbg "keeping payload (KEEP_PAYLOADS=1): $FilePath"
    }
}

# Track per-payload upload report counters. UploadFailures is initialized
# before BEP preparation so partial-input failures remain part of the result.
$script:ReportTestsProcessed = 0
$script:ReportTestsFailed = 0
$script:ReportTestsSkipped = 0
$script:ReportCoverageProcessed = 0
$script:ReportCoverageFailed = 0
$script:ReportCoverageSkipped = 0
$script:ReportTelemetryProcessed = 0
$script:ReportTelemetryFailed = 0
$script:ReportTelemetrySkipped = 0

function Format-BoundedUploadResponse([string]$Body) {
  if ([string]::IsNullOrEmpty($Body)) {
    return [pscustomobject]@{ Text = '<empty>'; Bytes = 0; Truncated = $false }
  }
  $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount($Body)
  $singleLine = $Body.Replace("`r", ' ').Replace("`n", ' ')
  $truncated = $singleLine.Length -gt $script:UploadResponseLogChars
  if ($truncated) {
    $singleLine = $singleLine.Substring(0, $script:UploadResponseLogChars)
  }
  return [pscustomobject]@{ Text = $singleLine; Bytes = $responseBytes; Truncated = $truncated }
}

function Send-PostJson(
  [string]$url,
  [hashtable]$headers,
  [string]$file,
  [string]$SourcePath = $file,
  [int]$PartIndex = 1,
  [int]$PartCount = 1
) {
  $maxRetries = 3
  $retryDelay = 2
  $uncompressedBytes = (Get-Item -LiteralPath $file -ErrorAction Stop).Length
  if (-not (Ensure-HttpClientTypes)) {
    Log "upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
    return [bool]$false
  }
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $client = $null
    try {
      # Build a fresh HttpClient per retry attempt to avoid carrying stale
      # request state or headers across attempts.
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {
        # Add() returns bool; suppress pipeline output so callers receive only
        # the explicit boolean return from this function.
        $null = $client.DefaultRequestHeaders.Add($k, [string]$headers[$k])
      }
      Dbg "Send-PostJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      if ($script:GzipPayloads) {
        # Inline gzip keeps implementation dependency-free on Windows hosts.
        $bytes = [IO.File]::ReadAllBytes($file)
        $ms = New-Object System.IO.MemoryStream
        $gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()
        $compressed = $ms.ToArray()
        # New-Object treats byte[] as a list of constructor args unless wrapped.
        $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $compressed)
        $content.Headers.ContentType = 'application/json'
        $null = $content.Headers.ContentEncoding.Add('gzip')
        $compressedBytes = $compressed.Length
        $transmittedBytes = $compressedBytes
        $encoding = 'gzip'
        Dbg "Send-PostJson: Content-Type=application/json; Content-Encoding=gzip (bytes=$($compressed.Length))"
      } else {
        $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
        $content.Headers.ContentType = 'application/json'
        $compressedBytes = 'none'
        $transmittedBytes = $uncompressedBytes
        $encoding = 'identity'
        Dbg "Send-PostJson: Content-Type=application/json"
      }
      $script:ReportUploadAttempted = $true
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {
        if ($script:DebugMode) {
          $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          if ($body) { Dbg "Send-PostJson response: $body" }
        }
        return [bool]$true
      } else {
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Dbg "Send-PostJson: HTTP $([int]$resp.StatusCode) on attempt $attempt"
        if ($attempt -eq $maxRetries) {
          $script:ReportUploadFailed = $true
          $bounded = Format-BoundedUploadResponse $body
          Log "upload failed: source='$SourcePath' part=$PartIndex/$PartCount http=$([int]$resp.StatusCode) encoding=$encoding uncompressed_bytes=$uncompressedBytes compressed_bytes=$compressedBytes transmitted_bytes=$transmittedBytes response_bytes=$($bounded.Bytes) response_truncated=$($bounded.Truncated.ToString().ToLowerInvariant()) response_body='$($bounded.Text)'"
          return [bool]$false
        }
      }
    } catch {
      Dbg "Send-PostJson: Exception on attempt $attempt - $_"
      if ($attempt -eq $maxRetries) {
        $script:ReportUploadFailed = $true
        $encoding = if ($script:GzipPayloads) { 'gzip' } else { 'identity' }
        $compressedBytes = if ($script:GzipPayloads -and $null -ne $compressed) { $compressed.Length } else { 'none' }
        $transmittedBytes = if ($script:GzipPayloads -and $null -ne $compressed) { $compressed.Length } else { $uncompressedBytes }
        Log "upload failed: source='$SourcePath' part=$PartIndex/$PartCount http=000 encoding=$encoding uncompressed_bytes=$uncompressedBytes compressed_bytes=$compressedBytes transmitted_bytes=$transmittedBytes response_bytes=0 response_truncated=false response_body='<empty>' exception='$_'"
        return [bool]$false
      }
    } finally {
      # Dispose HttpClient each attempt to release sockets promptly in long runs.
      if ($client) { $client.Dispose() }
    }
    # Fixed retry delay keeps behavior deterministic across hosts/CI lanes.
    Start-Sleep -Seconds $retryDelay
  }
  return [bool]$false
}

$script:PreparedTestPayloads = [System.Collections.Generic.List[string]]::new()
$script:PreparedTestTempFiles = [System.Collections.Generic.List[string]]::new()

function Clear-PreparedTestPayloads {
  foreach ($path in @($script:PreparedTestTempFiles.ToArray())) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
  $script:PreparedTestPayloads.Clear()
  $script:PreparedTestTempFiles.Clear()
}

function Write-TestPayloadPart($Payload, [object[]]$Events) {
  $path = Join-Path $script:TmpPayloadDir ("test_payload_part_" + [System.Guid]::NewGuid().ToString("N") + ".json")
  $Payload.events = @($Events)
  Write-Utf8NoBomFile -Path $path -Content (($Payload | ConvertTo-Json -Depth 100 -Compress) + "`n")
  $script:PreparedTestTempFiles.Add($path) | Out-Null
  return $path
}

function Split-TestPayloadEvents($Payload, [object[]]$Events, [string]$SourcePath) {
  $path = Write-TestPayloadPart $Payload $Events
  $size = (Get-Item -LiteralPath $path -ErrorAction Stop).Length
  if ($size -le $script:TestPayloadSplitTargetBytes) {
    $script:PreparedTestPayloads.Add($path) | Out-Null
    return [bool]$true
  }
  if ($Events.Count -eq 1) {
    if ($size -le $script:TestPayloadMaxBytes) {
      Log "warning: single-event test payload exceeds the split target but remains within the intake limit: source='$SourcePath' uncompressed_bytes=$size"
      $script:PreparedTestPayloads.Add($path) | Out-Null
      return [bool]$true
    }
    Log "error: single_event_too_large: source='$SourcePath' uncompressed_bytes=$size max_bytes=$($script:TestPayloadMaxBytes)"
    return [bool]$false
  }

  $midpoint = [int][Math]::Floor($Events.Count / 2)
  $left = @($Events[0..($midpoint - 1)])
  $right = @($Events[$midpoint..($Events.Count - 1)])
  return [bool]((Split-TestPayloadEvents $Payload $left $SourcePath) -and (Split-TestPayloadEvents $Payload $right $SourcePath))
}

function Prepare-TestPayloadParts([string]$BodyPath, [string]$SourcePath) {
  $script:PreparedTestPayloads.Clear()
  $script:PreparedTestTempFiles.Clear()
  $script:PreparedTestTempFiles.Add($BodyPath) | Out-Null
  $size = (Get-Item -LiteralPath $BodyPath -ErrorAction Stop).Length
  if ($size -le $script:TestPayloadSplitTargetBytes) {
    $script:PreparedTestPayloads.Add($BodyPath) | Out-Null
    return [bool]$true
  }
  try {
    $payload = Get-Content -LiteralPath $BodyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  } catch {
    if ($size -le $script:TestPayloadMaxBytes) {
      Log "warning: oversized test payload is not valid JSON; sending within the intake limit: source='$SourcePath' uncompressed_bytes=$size"
      $script:PreparedTestPayloads.Add($BodyPath) | Out-Null
      return [bool]$true
    }
    Log "error: oversized test payload is not valid JSON and cannot be split: $SourcePath"
    return [bool]$false
  }
  $events = @(Get-MapValue $payload 'events')
  if ($events.Count -lt 1) {
    Log "error: oversized test payload cannot be split because its events array is invalid: $SourcePath"
    return [bool]$false
  }
  if (-not (Split-TestPayloadEvents $payload $events $SourcePath)) {
    return [bool]$false
  }
  Log "split test payload: source='$SourcePath' uncompressed_bytes=$size parts=$($script:PreparedTestPayloads.Count) target_bytes=$($script:TestPayloadSplitTargetBytes)"
  return [bool]$true
}

function Save-FailedTestPayloadParts([string]$SourcePath, [string[]]$FailedParts) {
  if ($KeepPayloads -or $null -eq $FailedParts -or $FailedParts.Count -eq 0) { return }
  $retryPath = Join-Path (Split-Path -Parent $SourcePath) ((Split-Path -Leaf $SourcePath) + ".retry." + [System.Guid]::NewGuid().ToString("N"))
  try {
    $retryPayload = Get-Content -LiteralPath $FailedParts[0] -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($FailedParts.Count -gt 1) {
      $failedEvents = [System.Collections.Generic.List[object]]::new()
      foreach ($partPath in $FailedParts) {
        $partPayload = Get-Content -LiteralPath $partPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($event in @(Get-MapValue $partPayload 'events')) {
          $failedEvents.Add($event) | Out-Null
        }
      }
      $retryPayload.events = @($failedEvents.ToArray())
    }
    Write-Utf8NoBomFile -Path $retryPath -Content (($retryPayload | ConvertTo-Json -Depth 100 -Compress) + "`n")
    [System.IO.File]::Move($retryPath, $SourcePath, $true)
    Log "retained $($FailedParts.Count) failed split payload part(s) for retry: $SourcePath"
  } catch {
    Log "warning: failed to retain rejected split payload parts; retaining the original payload '$SourcePath': $_"
  } finally {
    Remove-Item -LiteralPath $retryPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-TelemetryHeaders([string]$FilePath) {
    try {
        $payloadObj = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Log "warning: failed to parse telemetry payload '$FilePath': invalid JSON body"
        return $null
    }

    if (($payloadObj -isnot [System.Management.Automation.PSCustomObject]) -and ($payloadObj -isnot [System.Collections.IDictionary])) {
        Log "warning: failed to parse telemetry payload '$FilePath': body is not a JSON object"
        return $null
    }

    $payload = Ensure-Hashtable $payloadObj
    $apiVersion = Get-MapValue $payload 'api_version'
    if (($apiVersion -isnot [string]) -or [string]::IsNullOrWhiteSpace($apiVersion)) {
        Log "warning: failed to parse telemetry payload '$FilePath': missing or invalid api_version"
        return $null
    }

    $requestType = Get-MapValue $payload 'request_type'
    if (($requestType -isnot [string]) -or [string]::IsNullOrWhiteSpace($requestType)) {
        Log "warning: failed to parse telemetry payload '$FilePath': missing or invalid request_type"
        return $null
    }

    $runtimeId = Get-MapValue $payload 'runtime_id'
    $application = Ensure-Hashtable (Get-MapValue $payload 'application')
    $languageName = Get-MapValue $application 'language_name'
    $tracerVersion = Get-MapValue $application 'tracer_version'
    $sessionId = if (($runtimeId -is [string]) -and -not [string]::IsNullOrWhiteSpace($runtimeId)) { $runtimeId } else { $script:TelemetrySessionFallback }

    $headers = @{
        'DD-Telemetry-API-Version' = [string]$apiVersion
        'DD-Telemetry-Request-Type' = [string]$requestType
        'DD-Session-ID' = [string]$sessionId
    }
    if (($languageName -is [string]) -and -not [string]::IsNullOrWhiteSpace($languageName)) {
        $headers['DD-Client-Library-Language'] = [string]$languageName
    }
    if (($tracerVersion -is [string]) -and -not [string]::IsNullOrWhiteSpace($tracerVersion)) {
        $headers['DD-Client-Library-Version'] = [string]$tracerVersion
    }
    if ($Agentless) {
        $headers['DD-API-KEY'] = $env:DD_API_KEY
    }
    return $headers
}

function Resolve-CanonicalExistingFile([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $PathValue -ErrorAction Stop).FullName)
    } catch {
        return $null
    }
}

function Get-OrdinalSortedStrings([string[]]$Values) {
    if ($null -eq $Values) { return @() }
    $copy = @($Values)
    if ($copy.Count -gt 1) {
        [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    }
    return $copy
}

function Resolve-TelemetryFactsSources {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $sources = @()

    if ($script:TelemetryFactsManifest -and (Test-Path -LiteralPath $script:TelemetryFactsManifest -PathType Leaf)) {
        foreach ($line in (Get-Content -LiteralPath $script:TelemetryFactsManifest -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t", 2
            $rloc = if ($parts.Count -ge 1) { $parts[0] } else { "" }
            $pathValue = if ($parts.Count -ge 2) { $parts[1] } else { "" }
            $resolved = Resolve-ArtifactPath $pathValue
            if (-not $resolved -and -not [string]::IsNullOrWhiteSpace($rloc)) {
                $resolved = Resolve-Runfile $rloc
            }
            $canonical = Resolve-CanonicalExistingFile $resolved
            if ($canonical -and $seen.Add($canonical)) {
                $sources += ,$canonical
            }
        }
    }

    if ($script:ContextJsonFromOverride -and $script:PrimaryContextJson) {
        $sibling = Join-Path (Split-Path -Parent $script:PrimaryContextJson) "telemetry_facts.json"
        $canonical = Resolve-CanonicalExistingFile $sibling
        if ($canonical -and $seen.Add($canonical)) {
            $sources += ,$canonical
        }
    }

    return (Get-OrdinalSortedStrings $sources)
}

function Get-AllSortedTelemetryFiles {
    $files = @()
    foreach ($outputsDir in $script:TestOutputsCache) {
        $telemetryDir = Join-Path $outputsDir.FullName "payloads/telemetry"
        if (-not (Test-PayloadDirHasReplayableFiles $telemetryDir)) { continue }
        if (-not (Test-OutputDirFreshnessEligible $outputsDir.FullName)) { continue }
        foreach ($file in (Get-SortedPayloadFiles $telemetryDir)) {
            $files += ,$file
        }
    }
    return $files
}

function Copy-MutableObject($Value) {
  return Convert-ToMutableObject $Value
}

# Read the rule-detected CI provider from context so telemetry uploads can
# refine Bazel-owned provider tags without depending on tracer-side detection.
function Get-ContextCiProviderName {
    return $script:TelemetryProviderName
}

$script:TelemetryProviderName = Get-ContextProviderFromObject $script:ContextObj
if ([string]::IsNullOrWhiteSpace($script:TelemetryProviderName)) {
    $script:TelemetryProviderName = Get-ContextProviderFromJsonText $script:ContextJsonText
}
if (-not [string]::IsNullOrWhiteSpace($script:TelemetryProviderName)) {
    Dbg "telemetry provider rewrite enabled: provider:bazel/$($script:TelemetryProviderName)"
}

# Rewrite one metric-series tag array in place when it still carries the bare
# provider:bazel tag and the rule already knows the concrete CI provider.
function Update-TelemetrySeriesProviderTags($SeriesItems, [string]$ProviderName) {
    if ([string]::IsNullOrWhiteSpace($ProviderName)) { return }
    foreach ($seriesObj in @(Convert-ToObjectArray $SeriesItems)) {
        $series = Get-MutableDictionary $seriesObj
        if (($null -eq $series) -or ($series.Count -eq 0)) { continue }
        $tagsValue = Get-MapValue $series 'tags'
        if (($null -eq $tagsValue) -or ($tagsValue -is [string])) { continue }

        $updatedTags = @()
        foreach ($tag in @(Convert-ToObjectArray $tagsValue)) {
            $tagText = [string]$tag
            if ($tagText -eq "provider:bazel") {
                $updatedTags += ,"provider:bazel/$ProviderName"
            } else {
                $updatedTags += ,$tagText
            }
        }
        $series['tags'] = $updatedTags
    }
}

# Walk a telemetry payload recursively so both top-level metric messages and
# nested message-batch payloads receive the same provider-tag normalization.
function Update-TelemetryProviderTags($PayloadObject, [string]$ProviderName) {
    if ([string]::IsNullOrWhiteSpace($ProviderName)) { return }

    $payload = Get-MutableDictionary $PayloadObject
    if (($null -eq $payload) -or ($payload.Count -eq 0)) { return }

    $requestType = Get-MapValue $payload 'request_type'
    $payloadValue = Get-MapValue $payload 'payload'

    if ($requestType -eq "generate-metrics" -or $requestType -eq "distributions") {
        $payloadMap = Get-MutableDictionary $payloadValue
        if (($null -eq $payloadMap) -or ($payloadMap.Count -eq 0)) { return }
        Update-TelemetrySeriesProviderTags (Get-MapValue $payloadMap 'series') $ProviderName
        return
    }

    if ($requestType -eq "message-batch") {
        foreach ($message in @(Convert-ToObjectArray $payloadValue)) {
            Update-TelemetryProviderTags $message $ProviderName
        }
    }
}

function New-TelemetryOutboundBody([object]$PayloadObject, [string]$EnvOverride) {
    $outbound = Copy-MutableObject $PayloadObject
    if (-not [string]::IsNullOrWhiteSpace($EnvOverride)) {
        $application = Get-MapValue $outbound 'application'
        if ($application -is [System.Collections.IDictionary]) {
            $application['env'] = $EnvOverride
        }
    }
    return $outbound
}

function ConvertFrom-JsonCompat([string]$JsonText) {
    try {
        return ($JsonText | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop)
    } catch {
        # Windows PowerShell 5.1 does not support -AsHashtable/-NoEnumerate.
        # Fall back to plain ConvertFrom-Json and normalize the result later.
        return ($JsonText | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Read-JsonObjectFile([string]$FilePath, [string]$WarningMessage) {
    try {
        $payload = ConvertFrom-JsonCompat (Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8)
    } catch {
        if ($WarningMessage) { Log "warning: $WarningMessage" }
        return $null
    }
    if (($payload -isnot [System.Management.Automation.PSCustomObject]) -and ($payload -isnot [System.Collections.IDictionary])) {
        if ($WarningMessage) { Log "warning: $WarningMessage" }
        return $null
    }
    return Ensure-Hashtable $payload
}

function Get-LexicographicallyLastTelemetryCandidate($Candidates) {
    $selected = $null
    foreach ($candidate in $Candidates) {
        if ($null -eq $selected -or [System.StringComparer]::Ordinal.Compare([string]$candidate.Path, [string]$selected.Path) -gt 0) {
            $selected = $candidate
        }
    }
    return $selected
}

function Get-TelemetryStreamSummaries($Candidates) {
    $summaries = @()
    foreach ($stream in @($Candidates | Group-Object -Property RuntimeId)) {
        $streamCandidates = @($stream.Group)
        if ($streamCandidates.Count -eq 0) { continue }

        $batchCandidates = @($streamCandidates | Where-Object { $_.RequestType -eq "message-batch" })
        $selectionCandidates = if ($batchCandidates.Count -gt 0) { $batchCandidates } else { $streamCandidates }
        $bestCandidate = Get-LexicographicallyLastTelemetryCandidate $selectionCandidates
        if (-not $bestCandidate) { continue }

        $summaries += ,([PSCustomObject]@{
            RuntimeId = [string]$stream.Name
            Candidates = $streamCandidates
            HasBatch = ($batchCandidates.Count -gt 0)
            BestPath = [string]$bestCandidate.Path
            Representative = $bestCandidate
        })
    }
    return $summaries
}

function Select-TelemetryStreamSummary($Summaries) {
    $selected = $null
    foreach ($summary in @($Summaries)) {
        if ($null -eq $selected) {
            $selected = $summary
            continue
        }
        if ($summary.HasBatch -and -not $selected.HasBatch) {
            $selected = $summary
            continue
        }
        if (($summary.HasBatch -eq $selected.HasBatch) -and ([System.StringComparer]::Ordinal.Compare([string]$summary.BestPath, [string]$selected.BestPath) -gt 0)) {
            $selected = $summary
        }
    }
    return $selected
}

function New-TelemetryInnerMessages($CountFacts, $DistributionFacts, [long]$Timestamp) {
    $messages = @()

    $countSeries = @()
    foreach ($factObj in @($CountFacts)) {
        $fact = Ensure-Hashtable $factObj
        $name = Get-MapValue $fact 'name'
        if (($name -isnot [string]) -or [string]::IsNullOrWhiteSpace($name)) { continue }
        $tagsValue = Get-MapValue $fact 'tags'
        $tags = @()
        if ($tagsValue -is [System.Collections.IEnumerable] -and -not ($tagsValue -is [string])) {
            $tags = @($tagsValue | ForEach-Object { [string]$_ })
        }
        $countSeries += ,([ordered]@{
            metric = [string]$name
            points = @(@($Timestamp, (Get-MapValue $fact 'value')))
            type = "count"
            tags = $tags
            common = $true
            namespace = "civisibility"
        })
    }
    if ($countSeries.Count -gt 0) {
        $messages += ,([ordered]@{
            request_type = "generate-metrics"
            payload = [ordered]@{
                namespace = "civisibility"
                series = $countSeries
            }
        })
    }

    $distributionSeries = @()
    foreach ($factObj in @($DistributionFacts)) {
        $fact = Ensure-Hashtable $factObj
        $name = Get-MapValue $fact 'name'
        if (($name -isnot [string]) -or [string]::IsNullOrWhiteSpace($name)) { continue }
        $tagsValue = Get-MapValue $fact 'tags'
        $tags = @()
        if ($tagsValue -is [System.Collections.IEnumerable] -and -not ($tagsValue -is [string])) {
            $tags = @($tagsValue | ForEach-Object { [string]$_ })
        }
        $distributionSeries += ,([ordered]@{
            metric = [string]$name
            points = @((Get-MapValue $fact 'value'))
            tags = $tags
            common = $true
            namespace = "civisibility"
        })
    }
    if ($distributionSeries.Count -gt 0) {
        $messages += ,([ordered]@{
            request_type = "distributions"
            payload = [ordered]@{
                namespace = ""
                series = $distributionSeries
            }
        })
    }

    return $messages
}

function Write-TelemetryTempBody($PayloadObject) {
    $path = Join-Path $script:TmpPayloadDir ("telemetry_aug_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Write-Utf8NoBomFile -Path $path -Content ((ConvertTo-Json -InputObject $PayloadObject -Depth 100 -Compress) + "`n")
    return $path
}

# Build the best-effort telemetry rewrite plan. Matching is based on tracer
# service and language identity because sandboxed tracer telemetry can emit
# application.env="none" even when Bazel sync still knows the real CI env.
function New-TelemetryAugmentationPlan {
    $plan = @{
        ReplaceMap = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        SyntheticEntries = @()
        TempFiles = @()
    }

    $factsSources = @(Resolve-TelemetryFactsSources)
    $telemetryFiles = @(Get-AllSortedTelemetryFiles)
    if ($factsSources.Count -eq 0 -or $telemetryFiles.Count -eq 0) {
        return $plan
    }

    $candidates = @()
    foreach ($file in $telemetryFiles) {
        $payload = Read-JsonObjectFile $file.FullName ""
        if (-not $payload) { continue }
        $application = Ensure-Hashtable (Get-MapValue $payload 'application')
        $serviceName = Get-MapValue $application 'service_name'
        $languageName = Get-MapValue $application 'language_name'
        $apiVersion = Get-MapValue $payload 'api_version'
        $requestType = Get-MapValue $payload 'request_type'
        if (($serviceName -isnot [string]) -or [string]::IsNullOrWhiteSpace($serviceName)) { continue }
        if (($languageName -isnot [string]) -or [string]::IsNullOrWhiteSpace($languageName)) { continue }
        if (($apiVersion -isnot [string]) -or [string]::IsNullOrWhiteSpace($apiVersion)) { continue }
        if (($requestType -isnot [string]) -or [string]::IsNullOrWhiteSpace($requestType)) { continue }
        $runtimeId = Get-MapValue $payload 'runtime_id'
        if ($runtimeId -isnot [string]) { $runtimeId = "" }
        $seqIdValue = Get-MapValue $payload 'seq_id'
        $seqId = $null
        if ($seqIdValue -is [sbyte] -or $seqIdValue -is [byte] -or $seqIdValue -is [int16] -or $seqIdValue -is [uint16] -or $seqIdValue -is [int32] -or $seqIdValue -is [uint32] -or $seqIdValue -is [int64] -or $seqIdValue -is [uint64]) {
            $seqId = [int64]$seqIdValue
        }
        $candidates += ,([PSCustomObject]@{
            Path = $file.FullName
            Payload = $payload
            ServiceName = [string]$serviceName
            LanguageName = [string]$languageName
            RuntimeId = [string]$runtimeId
            SeqId = $seqId
            RequestType = [string]$requestType
        })
    }
    if ($candidates.Count -eq 0) {
        return $plan
    }

    $groups = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($factsPath in $factsSources) {
        $facts = Read-JsonObjectFile $factsPath "skipped invalid telemetry facts file: $factsPath"
        if (-not $facts) { continue }
        $serviceName = Get-MapValue $facts 'service_name'
        if (($serviceName -isnot [string]) -or [string]::IsNullOrWhiteSpace($serviceName)) {
            Log "warning: skipped telemetry facts without service_name: $factsPath"
            continue
        }
        $runtimeName = Get-MapValue $facts 'runtime_name'
        if ($runtimeName -isnot [string]) { $runtimeName = "" }
        $envValue = Get-MapValue $facts 'env'
        if ($envValue -isnot [string]) { $envValue = "" }
        $counts = Get-MapValue $facts 'counts'
        if ($counts -is [string]) { $counts = @() } else { $counts = @(Convert-ToObjectArray $counts) }
        $distributions = Get-MapValue $facts 'distributions'
        if ($distributions -is [string]) { $distributions = @() } else { $distributions = @(Convert-ToObjectArray $distributions) }

        $matched = @($candidates | Where-Object { $_.ServiceName -eq $serviceName })
        if ($matched.Count -eq 0) {
            Log "warning: skipped telemetry facts without matching tracer anchor: $factsPath"
            continue
        }

        $languages = @($matched | ForEach-Object { $_.LanguageName } | Select-Object -Unique)
        if ($languages.Count -gt 1) {
            if ([string]::IsNullOrWhiteSpace($runtimeName)) {
                Log "warning: skipped ambiguous telemetry facts across tracer languages: $factsPath"
                continue
            }
            $matched = @($matched | Where-Object { $_.LanguageName -eq $runtimeName })
            $languages = @($matched | ForEach-Object { $_.LanguageName } | Select-Object -Unique)
            if ($languages.Count -ne 1) {
                Log "warning: skipped ambiguous telemetry facts across tracer languages: $factsPath"
                continue
            }
        }

        if ($languages.Count -ne 1) {
            Log "warning: skipped telemetry facts without matching tracer language: $factsPath"
            continue
        }

        $groupKey = "{0}`t{1}" -f $serviceName, [string]$languages[0]
        if (-not $groups.Contains($groupKey)) {
            $groups[$groupKey] = @{
                ServiceName = [string]$serviceName
                LanguageName = [string]$languages[0]
                Counts = @()
                Distributions = @()
                EnvValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            }
        }
        $group = $groups[$groupKey]
        $group.Counts += @($counts)
        $group.Distributions += @($distributions)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            $null = $group.EnvValues.Add([string]$envValue)
        }
    }

    foreach ($groupKey in @(Get-OrdinalSortedStrings @($groups.Keys))) {
        $group = $groups[$groupKey]
        $candidateSet = @($candidates | Where-Object {
            $_.ServiceName -eq $group.ServiceName -and $_.LanguageName -eq $group.LanguageName
        })
        if ($candidateSet.Count -eq 0) { continue }

        $envOverride = ""
        if ($group.EnvValues.Count -gt 1) {
            Log "warning: skipped telemetry augmentation for service='$($group.ServiceName)' language='$($group.LanguageName)' because telemetry facts provided conflicting env values"
            continue
        } elseif ($group.EnvValues.Count -eq 1) {
            $envOverride = [string](@($group.EnvValues)[0])
        }

        $streamSummaries = @(Get-TelemetryStreamSummaries $candidateSet)
        $selectedStream = Select-TelemetryStreamSummary $streamSummaries
        if (-not $selectedStream) { continue }
        $anchor = $selectedStream.Representative
        if (-not $anchor) { continue }

        $envOverrideLog = if ([string]::IsNullOrWhiteSpace($envOverride)) { "<none>" } else { $envOverride }
        Dbg "telemetry group selected: service='$($group.ServiceName)' language='$($group.LanguageName)' runtime_id='$($selectedStream.RuntimeId)' anchor='$($anchor.Path)' env_override='$envOverrideLog'"

        $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $innerMessages = @(New-TelemetryInnerMessages $group.Counts $group.Distributions $timestamp)
        $hasBazelMetrics = ($innerMessages.Count -gt 0)

        foreach ($candidate in $candidateSet) {
            $isAnchor = ($candidate.Path -eq $anchor.Path)
            $needsTempBody = (-not [string]::IsNullOrWhiteSpace($envOverride)) -or ($isAnchor -and $hasBazelMetrics -and $anchor.RequestType -eq "message-batch")
            if (-not $needsTempBody) { continue }

            try {
                $outbound = New-TelemetryOutboundBody $candidate.Payload $envOverride
                if ($isAnchor -and $hasBazelMetrics -and $anchor.RequestType -eq "message-batch") {
                    $payloadItems = Get-MapValue $outbound 'payload'
                    if (($payloadItems -is [string]) -or ($null -eq $payloadItems)) {
                        Log "warning: skipped telemetry augmentation for '$($anchor.Path)': message-batch payload is not an array"
                        if ([string]::IsNullOrWhiteSpace($envOverride)) {
                            continue
                        }
                    } else {
                        $mergedPayload = @(Convert-ToObjectArray $payloadItems)
                        $mergedPayload += @($innerMessages)
                        $outbound['payload'] = $mergedPayload
                        Dbg "telemetry augmentation: appended rule metrics to anchor '$($anchor.Path)'"
                    }
                }

                $bodyPath = Write-TelemetryTempBody $outbound
                if ([string]::IsNullOrWhiteSpace($bodyPath) -or -not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
                    throw "failed to create temporary telemetry body"
                }
                $plan.ReplaceMap[$candidate.Path] = $bodyPath
                $plan.TempFiles += ,$bodyPath
                Dbg "telemetry augmentation: created temporary body '$bodyPath' for '$($candidate.Path)'"
            } catch {
                Log "warning: skipped telemetry rewrite for '$($candidate.Path)': $_"
            }
        }

        if (($anchor.RequestType -ne "message-batch") -and $hasBazelMetrics) {
            try {
                $anchorPayload = Ensure-Hashtable $anchor.Payload
                $application = Get-MapValue $anchorPayload 'application'
                if ($application -isnot [System.Collections.IDictionary]) {
                    Log "warning: skipped synthetic telemetry augmentation for '$($anchor.Path)': anchor application is missing or invalid"
                    continue
                }
                [int64]$maxSeqId = 0
                foreach ($candidate in $selectedStream.Candidates) {
                    if ($candidate.SeqId -ne $null -and [int64]$candidate.SeqId -gt $maxSeqId) {
                        $maxSeqId = [int64]$candidate.SeqId
                    }
                }

                $synthetic = [ordered]@{
                    api_version = Get-MapValue $anchorPayload 'api_version'
                    request_type = "message-batch"
                    runtime_id = Get-MapValue $anchorPayload 'runtime_id'
                    seq_id = $maxSeqId + 1
                    tracer_time = $timestamp
                    payload = @($innerMessages)
                }

                $appCopy = Copy-MutableObject $application
                if ($appCopy -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace($envOverride)) {
                    $appCopy['env'] = $envOverride
                }
                $synthetic['application'] = $appCopy
                if ($anchorPayload.Contains('host')) { $synthetic['host'] = Get-MapValue $anchorPayload 'host' }
                if ($anchorPayload.Contains('debug')) { $synthetic['debug'] = Get-MapValue $anchorPayload 'debug' }

                $bodyPath = Write-TelemetryTempBody $synthetic
                if ([string]::IsNullOrWhiteSpace($bodyPath) -or -not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
                    Log "warning: skipped synthetic telemetry augmentation for '$($anchor.Path)': failed to create synthetic body path"
                    continue
                }
                $plan.SyntheticEntries += ,([PSCustomObject]@{
                    AnchorPath = [string]$anchor.Path
                    BodyPath = $bodyPath
                    ServiceName = $group.ServiceName
                    LanguageName = $group.LanguageName
                })
                $plan.TempFiles += ,$bodyPath
                Dbg "telemetry augmentation: created synthetic body '$bodyPath' for anchor '$($anchor.Path)'"
            } catch {
                Log "warning: skipped synthetic telemetry augmentation for '$($anchor.Path)': $_"
            }
        }
    }

    if ($plan.SyntheticEntries.Count -gt 1) {
        $plan.SyntheticEntries = @(
            $plan.SyntheticEntries |
                Sort-Object -Property @{ Expression = { $_.AnchorPath } ; Ascending = $true }
        )
    }
    return $plan
}

function Remove-TelemetryAugmentationPlanTempFiles($Plan) {
    if ($null -eq $Plan) { return }
    foreach ($path in @($Plan.TempFiles)) {
        if ($path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Send-PostRawJson([string]$url, [hashtable]$headers, [string]$file) {
  $maxRetries = 3
  $retryDelay = 2
  if (-not (Ensure-HttpClientTypes)) {
    Log "upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
    return [bool]$false
  }
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    $client = $null
    try {
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {
        $null = $client.DefaultRequestHeaders.Add($k, [string]$headers[$k])
      }
      Dbg "Send-PostRawJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      $bytes = [IO.File]::ReadAllBytes($file)
      $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
      $content.Headers.ContentType = 'application/json'
      Dbg "Send-PostRawJson: Content-Type=application/json"
      $script:ReportUploadAttempted = $true
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {
        if ($script:DebugMode) {
          $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          if ($body) { Dbg "Send-PostRawJson response: $body" }
        }
        return [bool]$true
      } else {
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Dbg "Send-PostRawJson: HTTP $([int]$resp.StatusCode) on attempt $attempt"
        if ($attempt -eq $maxRetries) {
          $script:ReportUploadFailed = $true
          Log "upload failed: HTTP $([int]$resp.StatusCode) $body"
          return [bool]$false
        }
      }
    } catch {
      Dbg "Send-PostRawJson: Exception on attempt $attempt - $_"
      if ($attempt -eq $maxRetries) {
        $script:ReportUploadFailed = $true
        Log "upload failed: $_"
        return [bool]$false
      }
    } finally {
      if ($client) { $client.Dispose() }
    }
    Start-Sleep -Seconds $retryDelay
  }
  return [bool]$false
}

function Upload-SingleTest([string]$FilePath) {
    $body = Join-Path $script:TmpPayloadDir ("test_payload_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Merge-With-Context $FilePath $body
    Validate-Payload $body
    Dbg "Upload-SingleTest: posting '$FilePath' (body '$body')"
    if ($script:DebugMode) {
        Write-Host "[dd-uploader][dbg] payload content (enriched) for '$FilePath':"
        Write-Host (Get-Content -LiteralPath $body -Raw)
        Log-StartTimeStats $body
    }
    if (-not (Test-EnrichedPayloadTags $body $FilePath)) {
        Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
        return [bool]$false
    }
    if (-not (Prepare-TestPayloadParts $body $FilePath)) {
        Clear-PreparedTestPayloads
        return [bool]$false
    }
    $partCount = $script:PreparedTestPayloads.Count
    $failed = $false
    $failedParts = [System.Collections.Generic.List[string]]::new()
    try {
        for ($index = 0; $index -lt $partCount; $index++) {
            $part = $script:PreparedTestPayloads[$index]
            $hdrs = Get-CommonHeaders $part
            if (-not $Agentless) { $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }
            if ($script:DebugMode) {
                Dbg "request: POST $TestUrl (part=$($index + 1)/$partCount)"
                Dbg-Headers "common" $hdrs
            }
            $resultStream = @(Send-PostJson $TestUrl $hdrs $part $FilePath ($index + 1) $partCount)
            if ($resultStream.Count -eq 0 -or -not [bool]$resultStream[-1]) {
                $failed = $true
                $failedParts.Add($part) | Out-Null
            }
        }
        if ($failed -and $failedParts.Count -lt $partCount) {
            Save-FailedTestPayloadParts $FilePath @($failedParts.ToArray())
        }
    } finally {
        Clear-PreparedTestPayloads
    }
    return [bool](-not $failed)
}

function Get-ExpectedEnrichedTags {
    if ($script:ExpectedEnrichedTags -and $script:ExpectedEnrichedTags.Count -gt 0) {
        return @($script:ExpectedEnrichedTags.ToArray())
    }
    return @($script:DefaultExpectedEnrichedTags)
}

function Test-EventHasEnrichedTag($EventObj, [string]$Tag) {
    if ($null -eq $EventObj -or [string]::IsNullOrEmpty($Tag)) { return [bool]$false }
    $content = Ensure-Hashtable (Get-MapValue $EventObj 'content')
    $meta = Ensure-Hashtable (Get-MapValue $content 'meta')
    if ($meta.Contains($Tag)) { return [bool]$true }
    $metrics = Ensure-Hashtable (Get-MapValue $content 'metrics')
    if ($metrics.Contains($Tag)) { return [bool]$true }
    return [bool]$false
}

function Test-EnrichedPayloadTags([string]$BodyPath, [string]$SourcePath) {
    if (-not $script:ValidateEnrichment) { return [bool]$true }
    $payload = Read-JsonObjectFile $BodyPath "could not parse enriched test payload '$SourcePath'"
    if (-not $payload) { return [bool]$false }
    $events = @(Get-MapValue $payload 'events')
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($tag in @(Get-ExpectedEnrichedTags)) {
        if ([string]::IsNullOrEmpty($tag)) { continue }
        $found = $false
        foreach ($event in $events) {
            if ($null -eq $event) { continue }
            if (Test-EventHasEnrichedTag $event $tag) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $missing.Add([string]$tag) | Out-Null
        }
    }
    if ($missing.Count -gt 0) {
        Log "error: enriched test payload for '$SourcePath' is missing expected tag(s): $($missing -join ', ')"
        return [bool]$false
    }
    if ($script:DryRun) {
        Log "dry-run validated enriched test payload: $SourcePath"
    } else {
        Log "validated enriched test payload: $SourcePath"
    }
    return [bool]$true
}

function DryRun-SingleTest([string]$FilePath) {
    $body = Join-Path $script:TmpPayloadDir ("test_payload_dry_run_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    try {
        Merge-With-Context $FilePath $body
        Validate-Payload $body
        $null = Get-CommonHeaders $body
        if ($script:DebugMode) {
            Log-StartTimeStats $body
        }
        $validationResult = @(Test-EnrichedPayloadTags $body $FilePath)
        $validated = $false
        foreach ($item in $validationResult) {
            if ($item -is [bool]) {
                $validated = [bool]$item
            } else {
                # Test-EnrichedPayloadTags logs through the success stream, so
                # preserve those operator messages while still returning a bool.
                Write-Output $item
            }
        }
        if (-not $validated) {
            return [bool]$false
        }
        if (-not (Prepare-TestPayloadParts $body $FilePath)) {
            return [bool]$false
        }
        if ($script:PreparedTestPayloads.Count -gt 1) {
            Log "dry-run would split test payload '$FilePath' into $($script:PreparedTestPayloads.Count) parts"
        }
        return [bool]$true
    } finally {
        Clear-PreparedTestPayloads
        Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    }
}

function Upload-SingleCoverage([string]$FilePath) {
    $eventFile = Join-Path $script:TmpPayloadDir ("coverage_event_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    $coverageContentType = Get-CoveragePayloadContentType $FilePath
    $coverageFileName = Get-CoveragePayloadFileName $FilePath
    # Coverage endpoint expects multipart with an `event` part; a small dummy
    # object is sufficient and matches agentless/EVP server expectations.
    Write-Utf8NoBomFile -Path $eventFile -Content '{"dummy":true}'

    $client = $null
    $fs = $null
    $maxRetries = 3
    $retryDelay = 2
    $uploaded = $false

    try {
        if (-not (Ensure-HttpClientTypes)) {
            Log "coverage upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
            return [bool]$false
        }
        $covHeaders = Get-CommonHeaders $null
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        foreach ($k in $covHeaders.Keys) {
            # Add() returns bool; suppress pipeline output to preserve boolean semantics.
            $null = $client.DefaultRequestHeaders.Add($k, [string]$covHeaders[$k])
        }
        if (-not $Agentless) { $null = $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }
        if ($script:DebugMode) {
            Dbg "request: POST $CovUrl"
            Dbg-Headers "common" $covHeaders
            if (-not $Agentless) { Dbg "header[evp]: X-Datadog-EVP-Subdomain: citestcov-intake" }
        }

        for ($attempt = 1; $attempt -le $maxRetries -and -not $uploaded; $attempt++) {
            try {
                # Recreate multipart content on each retry; StreamContent cannot
                # be safely reused once a request has been sent.
                $content = New-Object System.Net.Http.MultipartFormDataContent
                $eventContent = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($eventFile, [System.Text.Encoding]::UTF8))
                $eventContent.Headers.ContentType = 'application/json'
                $content.Add($eventContent, 'event', 'fileevent.json')
                $fs = [System.IO.File]::OpenRead($FilePath)
                $covContent = New-Object System.Net.Http.StreamContent($fs)
                $covContent.Headers.ContentType = $coverageContentType
                $content.Add($covContent, 'coveragex', $coverageFileName)
                Dbg "Upload-SingleCoverage: posting '$FilePath' (attempt $attempt/$maxRetries; Content-Type=multipart/form-data; coveragex=$coverageContentType)"
                $script:ReportUploadAttempted = $true
                $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) {
                    $uploaded = $true
                    if ($script:DebugMode) {
                        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if ($respBody) { Dbg "Upload-SingleCoverage response: $respBody" }
                    }
                } else {
                    $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    Dbg "Upload-SingleCoverage: HTTP $([int]$resp.StatusCode) on attempt $attempt"
                    if ($attempt -eq $maxRetries) {
                        $script:ReportUploadFailed = $true
                        # Only emit user-facing error after final retry to avoid
                        # noisy logs for transient first-attempt failures.
                        Log "coverage upload failed: HTTP $([int]$resp.StatusCode) $respBody"
                    }
                }
            } catch {
                Dbg "Upload-SingleCoverage: Exception on attempt $attempt - $_"
                if ($attempt -eq $maxRetries) {
                    $script:ReportUploadFailed = $true
                    Log "coverage upload failed: $_"
                }
            } finally {
                # Close file handle every attempt before retrying.
                if ($fs) { $fs.Dispose(); $fs = $null }
            }
            if (-not $uploaded -and $attempt -lt $maxRetries) { Start-Sleep -Seconds $retryDelay }
        }
    } finally {
        if ($client) { $client.Dispose() }
        Remove-Item -LiteralPath $eventFile -Force -ErrorAction SilentlyContinue
    }
    return [bool]$uploaded
}

function Upload-SingleTelemetry([string]$DisplayPath, [string]$BodyPath = $null) {
    if ([string]::IsNullOrWhiteSpace($DisplayPath)) {
        Log "warning: skipped telemetry upload because the display path was empty"
        return [bool]$false
    }
    if ([string]::IsNullOrWhiteSpace($BodyPath)) {
        $BodyPath = $DisplayPath
    }
    if ([string]::IsNullOrWhiteSpace($BodyPath)) {
        Log "warning: skipped telemetry upload for '$DisplayPath' because the body path was empty"
        return [bool]$false
    }
    if (-not (Test-Path -LiteralPath $BodyPath -PathType Leaf)) {
        Log "warning: skipped telemetry upload for '$DisplayPath' because the body path does not exist: $BodyPath"
        return [bool]$false
    }
    $uploadBodyPath = $BodyPath
    $providerTempBody = $null
    try {
        $providerName = Get-ContextCiProviderName
        if (-not [string]::IsNullOrWhiteSpace($providerName)) {
            # Keep tracer payloads on disk immutable; only rewrite the outbound
            # body used for this upload attempt.
            $payload = Read-JsonObjectFile $BodyPath ""
            if ($payload) {
                Update-TelemetryProviderTags $payload $providerName
                $providerTempBody = Write-TelemetryTempBody $payload
                if (-not [string]::IsNullOrWhiteSpace($providerTempBody) -and (Test-Path -LiteralPath $providerTempBody -PathType Leaf)) {
                    $uploadBodyPath = $providerTempBody
                } else {
                    Log "warning: failed to create telemetry provider rewrite body for '$DisplayPath'"
                }
            }
        }

        $hdrs = Get-TelemetryHeaders $uploadBodyPath
        if (-not $hdrs) {
            return [bool]$false
        }
        Dbg "Upload-SingleTelemetry: posting '$DisplayPath' (body '$uploadBodyPath')"
        if ($script:DebugMode) {
            Write-Host "[dd-uploader][dbg] telemetry content for '$DisplayPath':"
            Write-Host (Get-Content -LiteralPath $uploadBodyPath -Raw -Encoding UTF8)
            Dbg "request: POST $TelemetryUrl"
            Dbg-Headers "telemetry" $hdrs
            Dbg "headers: Content-Type=application/json"
        }
        $resultStream = @(Send-PostRawJson $TelemetryUrl $hdrs $uploadBodyPath)
        $result = $false
        if ($resultStream.Count -gt 0) {
            $result = [bool]$resultStream[-1]
        }
        return [bool]$result
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($providerTempBody)) {
            Remove-Item -LiteralPath $providerTempBody -Force -ErrorAction SilentlyContinue
        }
    }
}

function Upload-AllTests {
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {
        $testsDir = Join-Path $outputsDir.FullName "payloads/tests"
        if (-not (Test-TestPayloadDirHasCandidateFiles $testsDir)) { continue }
        if (-not (Test-OutputDirFreshnessEligible $outputsDir.FullName)) { continue }
        foreach ($f in @(Get-SortedRawTestMsgpackFiles $testsDir)) {
            Log "error: raw msgpack test payload is not supported in Bazel file mode: $($f.FullName)"
            Mark-FreshOutputHandled $outputsDir.FullName
            $failed++
            $script:ReportTestsFailed++
            $script:UploadFailures++
        }
        $files = Get-SortedTestPayloadFiles $testsDir
        foreach ($f in $files) {
            if (-not (Test-PrefixFilter $f.FullName "span_events_")) {
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                $script:ReportTestsSkipped++
                continue
            }
            if (-not (Test-TestPayloadHasEvents $f.FullName)) {
                Log "skipping test payload with no events: $($f.FullName)"
                $skipped++
                $script:ReportTestsSkipped++
                continue
            }
            if ($script:DryRun) {
                $dryRunResult = @(DryRun-SingleTest $f.FullName)
                $validated = $false
                foreach ($item in $dryRunResult) {
                    if ($item -is [bool]) {
                        $validated = [bool]$item
                    } else {
                        # DryRun-SingleTest may emit validation diagnostics while
                        # also returning a bool result through the success stream.
                        Write-Output $item
                    }
                }
                if ($validated) {
                    Log "dry-run kept test payload: $($f.FullName)"
                    Mark-FreshOutputHandled $outputsDir.FullName
                    $total++
                    $script:ReportTestsProcessed++
                } else {
                    Log "warning: failed to dry-run validate $($f.FullName)"
                    Mark-FreshOutputHandled $outputsDir.FullName
                    $failed++
                    $script:ReportTestsFailed++
                    $script:UploadFailures++
                }
                continue
            }
            $uploadedResult = @(Upload-SingleTest $f.FullName)
            $uploaded = $false
            if ($uploadedResult.Count -gt 0) {
                $uploaded = [bool]$uploadedResult[-1]
            }
            if ($uploaded) {
                Log "uploaded test payload: $($f.FullName)"
                Mark-FreshOutputHandled $outputsDir.FullName
                Remove-PayloadFile $f.FullName
                $total++
                $script:ReportTestsProcessed++
            } else {
                # Continue best-effort upload and report aggregate failures at end.
                Log "warning: failed to upload $($f.FullName)"
                Mark-FreshOutputHandled $outputsDir.FullName
                $failed++
                $script:ReportTestsFailed++
                $script:UploadFailures++
            }
        }
    }
    if ($script:DryRun) {
        Log "dry-run validated $total test payloads"
    } else {
        Log "uploaded $total test payloads"
    }
    if ($failed -gt 0) { Log "warning: $failed test payloads failed to upload" }
    if ($skipped -gt 0) { Dbg "skipped $skipped files (prefix filter)" }
}

function Upload-AllCoverage {
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {
        $covDir = Join-Path $outputsDir.FullName "payloads/coverage"
        if (-not (Test-PayloadDirHasReplayableFiles $covDir)) { continue }
        if (-not (Test-OutputDirFreshnessEligible $outputsDir.FullName)) { continue }
        $files = Get-SortedPayloadFiles $covDir
        foreach ($f in $files) {
            if (-not (Test-PrefixFilter $f.FullName "coverage_")) {
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                $script:ReportCoverageSkipped++
                continue
            }
            if ($script:DryRun) {
                Log "dry-run kept coverage payload: $($f.FullName)"
                Mark-FreshOutputHandled $outputsDir.FullName
                $total++
                $script:ReportCoverageProcessed++
                continue
            }
            $uploadedResult = @(Upload-SingleCoverage $f.FullName)
            $uploaded = $false
            if ($uploadedResult.Count -gt 0) {
                $uploaded = [bool]$uploadedResult[-1]
            }
            if ($uploaded) {
                Log "uploaded coverage payload: $($f.FullName)"
                Mark-FreshOutputHandled $outputsDir.FullName
                Remove-PayloadFile $f.FullName
                $total++
                $script:ReportCoverageProcessed++
            } else {
                # Preserve symmetry with test uploads: keep going, count failures.
                Log "warning: failed to upload $($f.FullName)"
                Mark-FreshOutputHandled $outputsDir.FullName
                $failed++
                $script:ReportCoverageFailed++
                $script:UploadFailures++
            }
        }
    }
    if ($script:DryRun) {
        Log "dry-run found $total coverage payloads"
    } else {
        Log "uploaded $total coverage payloads"
    }
    if ($failed -gt 0) { Log "warning: $failed coverage payloads failed to upload" }
    if ($skipped -gt 0) { Dbg "skipped $skipped files (prefix filter)" }
}

function Upload-AllTelemetry {
    $total = 0
    $failed = 0
    $plan = $null
    try {
        $plan = New-TelemetryAugmentationPlan
        foreach ($outputsDir in $script:TestOutputsCache) {
            $telemetryDir = Join-Path $outputsDir.FullName "payloads/telemetry"
            if (-not (Test-PayloadDirHasReplayableFiles $telemetryDir)) { continue }
            if (-not (Test-OutputDirFreshnessEligible $outputsDir.FullName)) { continue }
            $files = Get-SortedPayloadFiles $telemetryDir
            foreach ($f in $files) {
                $bodyPath = $f.FullName
                if ($plan -and $plan.ReplaceMap.Contains($f.FullName)) {
                    $bodyPath = [string]$plan.ReplaceMap[$f.FullName]
                    Dbg "telemetry augmentation: using temporary outbound body '$bodyPath' for '$($f.FullName)'"
                }
                if ($script:DryRun) {
                    Log "dry-run kept telemetry payload: $($f.FullName)"
                    Mark-FreshOutputHandled $outputsDir.FullName
                    $total++
                    $script:ReportTelemetryProcessed++
                    continue
                }
                $uploadedResult = @(Upload-SingleTelemetry $f.FullName $bodyPath)
                $uploaded = $false
                if ($uploadedResult.Count -gt 0) {
                    $uploaded = [bool]$uploadedResult[-1]
                }
                if ($uploaded) {
                    Log "uploaded telemetry payload: $($f.FullName)"
                    Mark-FreshOutputHandled $outputsDir.FullName
                    Remove-PayloadFile $f.FullName
                    $total++
                    $script:ReportTelemetryProcessed++
                } else {
                    Log "warning: failed to upload $($f.FullName)"
                    Mark-FreshOutputHandled $outputsDir.FullName
                    $failed++
                    $script:ReportTelemetryFailed++
                    $script:UploadFailures++
                }
            }
        }
        foreach ($entry in @($plan.SyntheticEntries)) {
            if (($null -eq $entry) -or [string]::IsNullOrWhiteSpace([string]$entry.AnchorPath) -or [string]::IsNullOrWhiteSpace([string]$entry.BodyPath) -or -not (Test-Path -LiteralPath $entry.BodyPath -PathType Leaf)) {
                Log "warning: skipped synthetic telemetry augmentation because the queued path was invalid: anchor='$([string]$entry.AnchorPath)' body='$([string]$entry.BodyPath)'"
                continue
            }
            Dbg "telemetry augmentation: uploading synthetic body '$($entry.BodyPath)' for anchor '$($entry.AnchorPath)'"
            if ($script:DryRun) {
                Log "dry-run validated synthetic telemetry augmentation for: $($entry.AnchorPath)"
                $total++
                $script:ReportTelemetryProcessed++
                continue
            }
            $uploadedResult = @(Upload-SingleTelemetry $entry.AnchorPath $entry.BodyPath)
            $uploaded = $false
            if ($uploadedResult.Count -gt 0) {
                $uploaded = [bool]$uploadedResult[-1]
            }
            if ($uploaded) {
                Log "uploaded telemetry payload: $($entry.AnchorPath)"
                $total++
                $script:ReportTelemetryProcessed++
            } else {
                Log "warning: failed to upload synthetic telemetry augmentation for $($entry.AnchorPath)"
                $failed++
                $script:ReportTelemetryFailed++
                $script:UploadFailures++
            }
        }
    } finally {
        Remove-TelemetryAugmentationPlanTempFiles $plan
    }
    if ($script:DryRun) {
        Log "dry-run found $total telemetry payloads"
    } else {
        Log "uploaded $total telemetry payloads"
    }
    if ($failed -gt 0) { Log "warning: $failed telemetry payloads failed to upload" }
}

# Main upload logic wrapped in try/finally for proper cleanup
try {
    # Run tests first, then coverage. This ordering mirrors historical behavior
    # and keeps log/snapshot expectations stable across platforms.
    Initialize-ExpectedTargets
    Initialize-FreshnessEligibility
    Merge-StagedBepFreshness
    Assert-NoRequiredRemoteOnlyBepOutputs
    Assert-ExpectedTargetCoverage
    Upload-AllTests
    Upload-AllCoverage
    Upload-AllTelemetry
    Assert-FreshOutputsHandled

    # Exit with appropriate code based on upload results
    if ($script:UploadFailures -gt 0) {
        Log "done with $($script:UploadFailures) upload failures"
        Exit-WithUploaderReport 1
    } else {
        if ($script:DryRun) {
            Log "dry-run done"
        } else {
            Log "done"
        }
        Exit-WithUploaderReport 0
    }
} finally {
    Release-Lock
}
