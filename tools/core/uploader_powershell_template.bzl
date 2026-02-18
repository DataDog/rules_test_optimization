"""PowerShell runtime template for dd_payload_uploader."""

UPLOADER_POWERSHELL_TEMPLATE = """
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
function Resolve-Runfile {{
    param([string]$InputRloc)

    $Rloc = $InputRloc
    $Rloc = $Rloc.Replace([char]92, [char]47)
    # Normalize relative prefixes that can appear in bzlmod runfile paths
    if ($Rloc.StartsWith("./")) {{ $Rloc = $Rloc.Substring(2) }}
    while ($Rloc.StartsWith("../")) {{ $Rloc = $Rloc.Substring(3) }}
    # Defensive guard: runfile labels must remain repository-relative.
    # We reject absolute/drive-qualified and parent-traversal paths so lookups
    # cannot accidentally resolve outside runfiles roots.
    if ([string]::IsNullOrEmpty($Rloc) -or $Rloc.StartsWith("/") -or ($Rloc -match '^[A-Za-z]:/') -or $Rloc -eq ".." -or $Rloc.EndsWith("/..") -or $Rloc.Contains("/../")) {{
        Dbg "Resolve-Runfile rejected suspicious runfile label '$InputRloc' (normalized='$Rloc')"
        return $null
    }}

    $candidates = @($Rloc)
    if ($Rloc.StartsWith("external/")) {{
        $candidates += $Rloc.Substring(9)
    }} else {{
        # Try the external/ prefix when short_path omits it under bzlmod.
        $candidates += "external/$Rloc"
    }}
    if (-not $Rloc.StartsWith("_main/")) {{
        $candidates += "_main/$Rloc"
    }}
    Dbg "Resolve-Runfile input='$InputRloc' normalized='$Rloc' candidates='$($candidates -join ',')'"

    if ($env:RUNFILES_DIR) {{
        $rfExists = Test-Path -LiteralPath $env:RUNFILES_DIR
        Dbg "Resolve-Runfile RUNFILES_DIR='$($env:RUNFILES_DIR)' exists=$rfExists"
    }} else {{
        Dbg "Resolve-Runfile RUNFILES_DIR=<unset>"
    }}

    $manifest = $null
    if ($env:RUNFILES_MANIFEST_FILE) {{
        $mfExists = Test-Path -LiteralPath $env:RUNFILES_MANIFEST_FILE
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE='$($env:RUNFILES_MANIFEST_FILE)' exists=$mfExists"
        if ($mfExists) {{
            $manifest = Get-Content -LiteralPath $env:RUNFILES_MANIFEST_FILE -Encoding UTF8
            Dbg "Resolve-Runfile manifest entries loaded=$($manifest.Count)"
        }}
    }} else {{
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE=<unset>"
    }}

    foreach ($cand in $candidates) {{
        Dbg "Resolve-Runfile trying candidate '$cand'"
        # Try RUNFILES_DIR first
        if ($env:RUNFILES_DIR) {{
            $candidate = Join-Path $env:RUNFILES_DIR $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
                Dbg "Resolve-Runfile hit RUNFILES_DIR -> '$candidate'"
                return $candidate
            }}
        }}

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
        foreach ($runfilesDir in $runfilesDirs) {{
            $candidate = Join-Path $runfilesDir $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
                Dbg "Resolve-Runfile hit script runfiles -> '$candidate'"
                return $candidate
            }}
        }}

        # Try RUNFILES_MANIFEST_FILE (Windows default)
        if ($manifest) {{
            # Pass 1: exact key matches (fast path, most reliable).
            foreach ($line in $manifest) {{
                $lineNorm = $line
                # Some tools write manifests with UTF-8 BOM; strip it from key.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {{
                    $lineNorm = $lineNorm.Substring(1)
                }}
                if ($lineNorm.Length -gt $cand.Length -and $lineNorm.StartsWith($cand, [System.StringComparison]::Ordinal)) {{
                    $sep = $lineNorm.Substring($cand.Length, 1)
                    if ($sep -ne ' ' -and $sep -ne "`t") {{ continue }}
                    $path = $lineNorm.Substring($cand.Length + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {{
                        Dbg "Resolve-Runfile hit manifest exact key '$cand' -> '$path'"
                        return $path
                    }}
                    Dbg "Resolve-Runfile manifest exact key '$cand' -> '$path' (not a file)"
                }}
            }}
            # Fallback: some manifests prefix keys with repo names (for example "<repo>/path/to/file").
            # Match entries whose key ends with "/<candidate>" or "\\<candidate>".
            # Pass 2: suffix-key matches for bzlmod/workspace key variants.
            foreach ($line in $manifest) {{
                $lineNorm = $line
                # Same BOM handling for suffix-key fallback.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {{
                    $lineNorm = $lineNorm.Substring(1)
                }}
                $spaceIdx = $lineNorm.IndexOf(' ')
                $tabIdx = $lineNorm.IndexOf("`t")
                if ($spaceIdx -lt 0) {{
                    $i = $tabIdx
                }} elseif ($tabIdx -lt 0) {{
                    $i = $spaceIdx
                }} else {{
                    $i = [Math]::Min($spaceIdx, $tabIdx)
                }}
                if ($i -le 0) {{ continue }}
                $key = $lineNorm.Substring(0, $i)
                if ($key.Length -le $cand.Length) {{ continue }}
                if ($key.EndsWith("/$cand", [System.StringComparison]::Ordinal) -or $key.EndsWith("\\$cand", [System.StringComparison]::Ordinal)) {{
                    $path = $lineNorm.Substring($i + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {{
                        Dbg "Resolve-Runfile hit manifest suffix key '$cand' -> '$path'"
                        return $path
                    }}
                    Dbg "Resolve-Runfile manifest suffix key '$cand' -> '$path' (not a file)"
                }}
            }}
        }}
    }}

    Dbg "Resolve-Runfile miss for input '$InputRloc'"
    return $null  # Not found
}}

function Resolve-ArtifactPath {{
    param([string]$InputPath)

    if (-not $InputPath) {{ return $null }}
    Dbg "Resolve-ArtifactPath input='$InputPath'"

    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {{
        Dbg "Resolve-ArtifactPath hit direct -> '$InputPath'"
        return $InputPath
    }}

    $execRoot = $null
    try {{
        $execRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\\..\\.."))
    }} catch {{
        $execRoot = $null
    }}
    if ($execRoot) {{
        $candidate = Join-Path $execRoot $InputPath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
            Dbg "Resolve-ArtifactPath hit execroot-relative -> '$candidate'"
            return $candidate
        }}
    }}

    Dbg "Resolve-ArtifactPath miss for input '$InputPath'"
    return $null
}}

# Logging functions (defined early so other functions can use them)
# Note: $Debug is set later, so Dbg checks the variable at runtime
$script:DebugMode = $false  # Will be set properly after Normalize-Bool is defined
if ($env:DD_TEST_OPTIMIZATION_DEBUG) {{
    switch ($env:DD_TEST_OPTIMIZATION_DEBUG.ToLower()) {{
        {{ $_ -in '1', 'true', 'yes' }} {{ $script:DebugMode = $true }}
    }}
}}
function Log([string]$msg) {{ Write-Output "[dd-uploader] $msg" }}
function Dbg([string]$msg) {{ if ($script:DebugMode) {{ Write-Host "[dd-uploader][dbg] $msg" }} }}
function Write-Utf8NoBomFile([string]$Path, [string]$Content) {{
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}}
$script:HttpAssemblyReady = $false
function Ensure-HttpClientTypes {{
    if ($script:HttpAssemblyReady) {{ return $true }}
    try {{
        if (-not ("System.Net.Http.HttpClient" -as [type])) {{
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }}
        if (-not ("System.Net.Http.HttpClient" -as [type])) {{
            Dbg "System.Net.Http.HttpClient type unavailable after Add-Type"
            return $false
        }}
        $script:HttpAssemblyReady = $true
        return $true
    }} catch {{
        Dbg "failed to load System.Net.Http assembly: $_"
        return $false
    }}
}}
Dbg "startup runfiles env: RUNFILES_DIR='$(if ($env:RUNFILES_DIR) {{ $env:RUNFILES_DIR }} else {{ '<unset>' }})' RUNFILES_MANIFEST_FILE='$(if ($env:RUNFILES_MANIFEST_FILE) {{ $env:RUNFILES_MANIFEST_FILE }} else {{ '<unset>' }})' PSScriptRoot='$PSScriptRoot'"

function Redact-HeaderValue([string]$name, [string]$value) {{
    if ($name -ne 'DD-API-KEY') {{ return $value }}
    if ([string]::IsNullOrEmpty($value)) {{ return $value }}
    if ($value.Length -gt 4) {{
        return ("****" + $value.Substring($value.Length - 4))
    }}
    return $value
}}

function Dbg-Headers([string]$label, $headers) {{
    if (-not $script:DebugMode) {{ return }}
    foreach ($k in $headers.Keys) {{
        $v = Redact-HeaderValue $k ($headers[$k].ToString())
        Dbg "header[$label]: ${{k}}: $v"
    }}
}}

# Emit basic startTime statistics (ms) for debugging.
function Get-StartTimes($obj, [ref]$acc) {{
    if ($null -eq $obj) {{ return }}
    if ($obj -is [System.Collections.IDictionary]) {{
    if ($obj.Contains("startTime")) {{
        $v = $obj["startTime"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {{
            $acc.Value += [double]$v
        }}
    }} elseif ($obj.Contains("start")) {{
        $v = $obj["start"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {{
            $acc.Value += [double]$v
        }}
    }}
        foreach ($val in $obj.Values) {{ Get-StartTimes $val ([ref]$acc) }}
        return
    }}
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {{
        foreach ($item in $obj) {{ Get-StartTimes $item ([ref]$acc) }}
    }}
}}

function Log-StartTimeStats([string]$FilePath) {{
    try {{
        $payload = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $times = @()
        Get-StartTimes $payload ([ref]$times)
        if ($times.Count -eq 0) {{
            Dbg "startTime stats: no startTime fields found in $FilePath"
            return
        }}
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Dbg "startTime/ms range for ${{FilePath}}: min=$min max=$max now=$nowMs"
    }} catch {{
        Dbg "startTime stats failed for ${{FilePath}}: $_"
    }}
}}

# Resolve context.json path (used by upload functions for payload enrichment)
# Path is determined at rule implementation time from data files
$ContextJsonRloc = "{context_json_rloc}"
$ContextJsonPath = "{context_json_path}"
Dbg "context.json resolution inputs: path='$ContextJsonPath' rloc='$ContextJsonRloc'"
$script:ContextJson = Resolve-ArtifactPath $ContextJsonPath
if ($script:ContextJson) {{
    # Direct artifact path is preferred when launcher preserves it.
    Dbg "context.json resolved via direct path: '$script:ContextJson'"
}} elseif ($ContextJsonRloc) {{
    # Runfiles fallback supports manifest-only and bzlmod path variants.
    $script:ContextJson = Resolve-Runfile $ContextJsonRloc
    if (-not $script:ContextJson) {{
        Log "warning: context.json not found in runfiles; payloads will not be enriched"
    }} else {{
        Dbg "context.json resolved via runfiles: '$script:ContextJson'"
    }}
}} else {{
    $script:ContextJson = $null
    Dbg "context.json not configured in data files; enrichment disabled"
}}

# Resolve schema + validator paths (used for payload validation)
$SchemaJsonRloc = "{schema_json_rloc}"
$SchemaJsonPath = "{schema_json_path}"
Dbg "schema resolution inputs: schema_path='$SchemaJsonPath' schema_rloc='$SchemaJsonRloc'"
$script:SchemaJson = Resolve-ArtifactPath $SchemaJsonPath
if ($script:SchemaJson) {{
    Dbg "schema resolved via direct path: '$script:SchemaJson'"
}} elseif ($SchemaJsonRloc) {{
    # Keep parity with Bash: attempt runfiles resolution before disabling.
    $script:SchemaJson = Resolve-Runfile $SchemaJsonRloc
    if (-not $script:SchemaJson) {{
        Log "warning: schema not found in runfiles; validation disabled"
    }} else {{
        Dbg "schema resolved via runfiles: '$script:SchemaJson'"
    }}
}} else {{
    $script:SchemaJson = $null
    Dbg "schema not configured in data files; validation disabled"
}}

$SchemaValidatorRloc = "{schema_validator_rloc}"
$SchemaValidatorPath = "{schema_validator_path}"
Dbg "schema validator resolution inputs: validator_path='$SchemaValidatorPath' validator_rloc='$SchemaValidatorRloc'"
$script:SchemaValidator = Resolve-ArtifactPath $SchemaValidatorPath
if ($script:SchemaValidator) {{
    Dbg "schema validator resolved via direct path: '$script:SchemaValidator'"
}} elseif ($SchemaValidatorRloc) {{
    # Validation is best-effort; unresolved validator disables schema checks.
    $script:SchemaValidator = Resolve-Runfile $SchemaValidatorRloc
    if (-not $script:SchemaValidator) {{
        Log "warning: schema validator not found in runfiles; validation disabled"
    }} else {{
        Dbg "schema validator resolved via runfiles: '$script:SchemaValidator'"
    }}
}} else {{
    $script:SchemaValidator = $null
    Dbg "schema validator not configured in data files; validation disabled"
}}

# Parse context.json once (best effort)
$script:ContextObj = $null
if ($script:ContextJson -and (Test-Path -LiteralPath $script:ContextJson)) {{
    try {{
        $script:ContextObj = Get-Content -LiteralPath $script:ContextJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }} catch {{
        $script:ContextObj = $null
    }}
}}

# Runtime defaults
$script:RulesVersion = "{rules_version}"
$script:RuntimeId = [guid]::NewGuid().ToString()

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
function Normalize-Bool([string]$val) {{
    switch ($val.ToLower()) {{
        {{ $_ -in '1', 'true', 'yes' }} {{ return $true }}
        default {{ return $false }}
    }}
}}

# Validate numeric value; exit 2 if invalid
function Validate-Numeric([string]$name, [string]$val) {{
    if ($val -notmatch '^\\d+$') {{
        Log "error: $name must be a non-negative integer, got: '$val'"
        exit 2  # Configuration error
    }}
}}

# Compute FNV-1a 32-bit hex fingerprint (non-cryptographic, for parity checks only)
function Get-Fnv1a32Hex([string]$value) {{
    if ([string]::IsNullOrEmpty($value)) {{ return "" }}
    $alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+"
    [uint32]$hash = 2166136261
    foreach ($ch in $value.ToCharArray()) {{
        $idx = $alphabet.IndexOf([string]$ch)
        if ($idx -lt 0) {{ $idx = 0 }}
        $hash = $hash -bxor ([uint32]$idx)
        # Keep arithmetic in uint64 and wrap to 32 bits explicitly.
        # This avoids signed-mask behavior differences on PowerShell.
        $hash = [uint32](([uint64]$hash * [uint64]16777619) % [uint64]4294967296)
    }}
    return ("{0:x8}" -f $hash)
}}

# Rule attributes (can be overridden via environment variables)
$QuiescentSec = if ($env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC) {{ $env:DD_TEST_OPTIMIZATION_QUIESCENT_SEC }} else {{ "{quiescent_sec}" }}
$MaxWaitSec = if ($env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC) {{ $env:DD_TEST_OPTIMIZATION_MAX_WAIT_SEC }} else {{ "{max_wait_sec}" }}
$MaxDepth = if ($env:DD_TEST_OPTIMIZATION_MAX_DEPTH) {{ $env:DD_TEST_OPTIMIZATION_MAX_DEPTH }} else {{ "0" }}

# Validate numeric values before conversion
Validate-Numeric "QUIESCENT_SEC" $QuiescentSec
Validate-Numeric "MAX_WAIT_SEC" $MaxWaitSec
Validate-Numeric "MAX_DEPTH" $MaxDepth

$QuiescentSec = [int]$QuiescentSec
$MaxWaitSec = [int]$MaxWaitSec
$MaxDepth = [int]$MaxDepth

$FailOnError = Normalize-Bool "{fail_on_error}"
$KeepPayloads = if ($env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS) {{ Normalize-Bool $env:DD_TEST_OPTIMIZATION_KEEP_PAYLOADS }} else {{ Normalize-Bool "{keep_payloads}" }}
$FilterPrefix = if ($env:DD_TEST_OPTIMIZATION_FILTER_PREFIX) {{ Normalize-Bool $env:DD_TEST_OPTIMIZATION_FILTER_PREFIX }} else {{ Normalize-Bool "{filter_prefix}" }}
$Debug = if ($env:DD_TEST_OPTIMIZATION_DEBUG) { Normalize-Bool $env:DD_TEST_OPTIMIZATION_DEBUG } else { Normalize-Bool "{debug}" }
$GzipPayloads = if ($env:DD_TEST_OPTIMIZATION_GZIP) {{ Normalize-Bool $env:DD_TEST_OPTIMIZATION_GZIP }} else {{ Normalize-Bool "{gzip_payloads}" }}

# Now that $Debug is set, update the script-level debug mode for Dbg function
$script:DebugMode = $Debug
$script:GzipPayloads = $GzipPayloads
Dbg "gzip enabled: $GzipPayloads"

# Acquire exclusive lock to prevent concurrent uploaders
# Lock is scoped to workspace to allow parallel uploads in different workspaces
$WorkspacePath = if ($env:BUILD_WORKSPACE_DIRECTORY) {{ $env:BUILD_WORKSPACE_DIRECTORY }} else {{ (Get-Location).Path }}
$WorkspaceHash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkspacePath))).Replace("-","").Substring(0,8)
$LockFile = Join-Path $env:TEMP "dd_upload_payloads_$WorkspaceHash.lock"

function Acquire-Lock {{
    $maxAttempts = 3
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {{
        try {{
            # FileShare.None provides process-wide mutual exclusion while this
            # handle stays open. If another uploader holds it, Open will throw.
            $script:LockStream = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
            Dbg "acquired lock: $LockFile (workspace hash: $WorkspaceHash)"
            return $true
        }} catch {{
            # If the lock were truly stale (unheld), OpenOrCreate with FileShare.None
            # would succeed. In the catch path, prefer bounded retries over deleting
            # lock files, which can race with another active uploader.
            Dbg "lock acquisition attempt $($attempt + 1)/$maxAttempts failed: $_"
            Start-Sleep -Seconds 1
        }}
    }}
    return $false
}}

if (-not (Acquire-Lock)) {{
    Log "error: another uploader is already running (lock: $LockFile)"
    Log "hint: wait for the other uploader to finish, or remove the lock file if stale"
    exit 2
}}

# Temp directory for enriched payloads / event files
$script:TmpPayloadDir = Join-Path $env:TEMP ("dd_topt_payloads_" + [System.Guid]::NewGuid().ToString("N"))
try {{
    New-Item -ItemType Directory -Path $script:TmpPayloadDir -Force | Out-Null
}} catch {{
    Log "error: failed to create temp directory for payload uploads: $script:TmpPayloadDir"
    Release-Lock
    exit 2
}}

# Cleanup function for lock release
function Release-Lock {{
    # Release lock handle first, then best-effort remove lock file and temp dir.
    if ($script:LockStream) {{
        $script:LockStream.Close()
        $script:LockStream = $null
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }}
    if ($script:TmpPayloadDir -and (Test-Path -LiteralPath $script:TmpPayloadDir)) {{
        Remove-Item -LiteralPath $script:TmpPayloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }}
}}

# Register cleanup on exit (backup for unexpected termination)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {{ Release-Lock }}

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
if ($env:TESTLOGS_DIR) {{
    if (Test-Path -LiteralPath $env:TESTLOGS_DIR) {{
        # Explicit override bypasses auto-discovery heuristics.
        $TestlogsDir = $env:TESTLOGS_DIR
        Dbg "using explicit TESTLOGS_DIR=$TestlogsDir"
    }} else {{
        Log "error: TESTLOGS_DIR is set but path does not exist: $($env:TESTLOGS_DIR)"
        Log "hint: ensure you used the same Bazel wrapper for 'bazel info' as for 'bazel test'"
        Release-Lock
        exit 2  # Configuration error (see exit codes in docs)
    }}
}} else {{
    # Auto-discover testlogs directory
    # Discovery order mirrors Bash implementation for cross-platform parity:
    # 1) BUILD_WORKSPACE_DIRECTORY/bazel-testlogs
    # 2) cwd/bazel-testlogs
    $TestlogsDir = $null

    if ($env:BUILD_WORKSPACE_DIRECTORY) {{
        $candidate = Join-Path $env:BUILD_WORKSPACE_DIRECTORY "bazel-testlogs"
        if (Test-Path -LiteralPath $candidate) {{ $TestlogsDir = $candidate }}
    }}

    if (-not $TestlogsDir) {{
        $candidate = Join-Path (Get-Location) "bazel-testlogs"
        if (Test-Path -LiteralPath $candidate) {{ $TestlogsDir = $candidate }}
    }}

    if (-not $TestlogsDir) {{
        Log "warning: testlogs dir not found (nothing to upload)"
        Log "hint: set TESTLOGS_DIR env var, or ensure bazel-testlogs symlink exists"
        # Exit 0 by default (graceful no-op), but respect FailOnError to catch misconfigurations
        if ($FailOnError) {{
            Log "error: FailOnError is set and no testlogs found - this may indicate misconfiguration"
            Release-Lock
            exit 2  # Configuration error
        }}
        Release-Lock
        exit 0
    }}

    Dbg "auto-discovered TestlogsDir=$TestlogsDir"
}}

# Find all test.outputs directories (supports DD_TEST_OPTIMIZATION_MAX_DEPTH to limit search depth)
# Note: -Depth parameter requires PowerShell 7+; on older versions, depth limiting is ignored
function Find-TestOutputs {{
    $params = @{{
        Path = $TestlogsDir
        Recurse = $true
        Directory = $true
        Filter = "test.outputs"
        ErrorAction = 'SilentlyContinue'
    }}
    if ($MaxDepth -gt 0) {{
        # -Depth is only available in PowerShell 7+
        if ($PSVersionTable.PSVersion.Major -ge 7) {{
            $params['Depth'] = $MaxDepth
            Dbg "limiting search depth to $MaxDepth"
        }} else {{
            Dbg "warning: DD_TEST_OPTIMIZATION_MAX_DEPTH ignored (requires PowerShell 7+, have $($PSVersionTable.PSVersion))"
        }}
    }}
    Get-ChildItem @params
}}

# Cache the list of test.outputs directories for efficiency (avoid rescanning on each loop iteration)
$script:TestOutputsCache = @()
function Update-TestOutputsCache {{
    $script:TestOutputsCache = @(Find-TestOutputs)
}}

function Get-LatestMTimeAll {{
    $maxTime = [DateTime]::MinValue
    foreach ($outputsDir in $script:TestOutputsCache) {{
        foreach ($subdir in @("payloads/tests", "payloads/coverage")) {{
            $dir = Join-Path $outputsDir.FullName $subdir
            if (-not (Test-Path -LiteralPath $dir)) {{ continue }}
            $files = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue
            foreach ($file in $files) {{
                if ($file.LastWriteTime -gt $maxTime) {{
                    $maxTime = $file.LastWriteTime
                }}
            }}
        }}
    }}
    return $maxTime
}}

function Count-PayloadFiles {{
    $count = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $testsDir = Join-Path $outputsDir.FullName "payloads/tests"
        $covDir = Join-Path $outputsDir.FullName "payloads/coverage"
        if (Test-Path -LiteralPath $testsDir) {{
            $count += @(Get-ChildItem -Path $testsDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        }}
        if (Test-Path -LiteralPath $covDir) {{
            $count += @(Get-ChildItem -Path $covDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        }}
    }}
    return $count
}}

# Detect if tests actually ran by looking for test.log or test.xml files
# This helps distinguish "no payloads because tests didn't run" from "tests ran but dd-trace-go is misconfigured"
function Test-ExecutedTests {{
    $testFiles = Get-ChildItem -Path $TestlogsDir -Recurse -File -Include @("test.log", "test.xml") -ErrorAction SilentlyContinue | Select-Object -First 1
    return $null -ne $testFiles
}}

# Wait for quiescence (filesystem to settle)
# Since the uploader runs AFTER tests complete (via `bazel run` after `bazel test`),
# we just need a short quiescence period to ensure all files are written.
$start = Get-Date
Dbg "Uploader start time: $start"

# Initialize the cache
Update-TestOutputsCache

while ($true) {{
    $elapsed = ((Get-Date) - $start).TotalSeconds

    # Refresh cache in case new test.outputs dirs appeared (e.g., remote downloads)
    Update-TestOutputsCache
    $totalFiles = Count-PayloadFiles

    if ($totalFiles -eq 0) {{
        # No payloads yet. Branch behavior depends on max-wait configuration.
        if ($MaxWaitSec -eq 0) {{
            if (Test-ExecutedTests) {{
                Log "warning: tests ran but no payload files found"
                Log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
                if ($FailOnError) {{
                    Log "error: FailOnError is set; failing due to missing payloads"
                    Release-Lock
                    exit 1
                }}
            }} else {{
                Log "no payload files found and no test execution detected; nothing to upload"
            }}
            Release-Lock
            exit 0
        }}
        if ($elapsed -gt $MaxWaitSec) {{
            if (Test-ExecutedTests) {{
                Log "warning: tests ran but no payload files found"
                Log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
                if ($FailOnError) {{
                    Log "error: FailOnError is set; failing due to missing payloads"
                    Release-Lock
                    exit 1
                }}
            }} else {{
                Log "no payload files found and no test execution detected; nothing to upload"
            }}
            Release-Lock
            exit 0
        }}
        Dbg "no payload files yet; waiting"
        Start-Sleep -Seconds 2
        continue
    }}

    if ($elapsed -gt $MaxWaitSec) {{
        # Payloads are present; continue with upload once budget expires.
        Log "max wait exceeded ($MaxWaitSec s); proceeding to upload"
        break
    }}

    # Check if files have been stable for QuiescentSec
    $latestTime = Get-LatestMTimeAll
    $idle = ((Get-Date) - $latestTime).TotalSeconds
    Dbg "total_files=$totalFiles, idle=$idle s"

    if ($idle -ge $QuiescentSec) {{
        Log "outputs quiescent for $idle s ($totalFiles files); starting upload"
        break
    }}

    Start-Sleep -Seconds 2
}}

# Build endpoints
$Agentless = [string]::IsNullOrEmpty($env:DD_TRACE_AGENT_URL)
$DD_Site = if ([string]::IsNullOrEmpty($env:DD_SITE)) {{ 'datadoghq.com' }} else {{ $env:DD_SITE }}
# Allow tests/dev to override intake base without changing DD_SITE.
$IntakeBase = $env:DD_TEST_OPTIMIZATION_INTAKE_BASE
if ($Agentless) {{
  # Agentless mode posts directly to Datadog intake hosts.
  if (-not [string]::IsNullOrEmpty($IntakeBase)) {{
    $Base = $IntakeBase.TrimEnd('/')
    $TestUrl = "$Base/api/v2/citestcycle"
    $CovUrl = "$Base/api/v2/citestcov"
    Dbg "DD_TEST_OPTIMIZATION_INTAKE_BASE override active: $Base"
  }} else {{
    $TestUrl = "https://citestcycle-intake.$DD_Site/api/v2/citestcycle"
    $CovUrl = "https://citestcov-intake.$DD_Site/api/v2/citestcov"
  }}
}} else {{
  # EVP mode tunnels through agent endpoint and requires EVP subdomain headers.
  $TestUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcycle"
  $CovUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcov"
  if (-not [string]::IsNullOrEmpty($IntakeBase)) {{ Dbg "DD_TEST_OPTIMIZATION_INTAKE_BASE ignored in EVP mode" }}
}}
Dbg "mode: Agentless=$Agentless Site=$DD_Site"
Dbg "endpoints: TestUrl=$TestUrl CovUrl=$CovUrl"

$script:HeaderLangDefault = 'bazel-starlark'
$script:HeaderLangVersionDefault = 'n/a'
$script:HeaderLangInterpreterDefault = 'bazel-run'
$script:HeaderTracerVersionDefault = '{uploader_version}'
if ($Agentless) {{
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {{
    Log "error: DD_API_KEY required for agentless uploads"
    Log "hint: pass credentials via environment: `$env:DD_API_KEY=... `$env:DD_SITE=... bazel run //:dd_upload_payloads"
    Release-Lock
    exit 2  # Configuration error
  }}
}} else {{
  $TestEvp = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }}
  $CovEvp  = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }}
}}
Dbg "headers prepared (agentless=$Agentless; test headers can be derived from metadata)"

Dbg "context.json: $(if ([string]::IsNullOrEmpty($script:ContextJson)) {{ '<none>' }} else {{ $script:ContextJson }})"

# Optional check: verify fetch-time API key fingerprint matches uploader API key.
$ContextFingerprint = $null
if ($script:ContextJson -and (Test-Path -LiteralPath $script:ContextJson)) {{
  try {{
    $ctxForCheck = Get-Content -LiteralPath $script:ContextJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ContextFingerprint = $ctxForCheck.'topt.api_key_fingerprint'
  }} catch {{
    $ContextFingerprint = $null
  }}
}}
if ($ContextFingerprint) {{
  if ($Agentless) {{
    # Compare only non-secret fingerprints; never log raw DD_API_KEY.
    $LocalFp = Get-Fnv1a32Hex $env:DD_API_KEY
    if ($LocalFp -and ($LocalFp -ne $ContextFingerprint)) {{
      Log "warning: DD_API_KEY mismatch between fetch and uploader"
    }} else {{
      Dbg "DD_API_KEY fingerprint match"
    }}
  }} else {{
    Log "warning: DD_API_KEY fingerprint present but uploader running in EVP mode; check skipped"
  }}
}}

function Get-CommonHeaders([string]$PayloadPath) {{
  $lang = $script:HeaderLangDefault
  $langVersion = $script:HeaderLangVersionDefault
  $langInterpreter = $script:HeaderLangInterpreterDefault
  $tracerVersion = $script:HeaderTracerVersionDefault

  if (-not [string]::IsNullOrEmpty($PayloadPath) -and (Test-Path -LiteralPath $PayloadPath)) {{
    try {{
      $payloadObj = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $metaStar = $null
      if ($payloadObj.metadata) {{ $metaStar = $payloadObj.metadata.'*' }}
      if ($metaStar) {{
        $metaLang = $metaStar.language
        if (-not [string]::IsNullOrEmpty($metaLang)) {{ $lang = [string]$metaLang }}

        $metaTracerVersion = $metaStar.library_version
        if (-not [string]::IsNullOrEmpty($metaTracerVersion)) {{ $tracerVersion = [string]$metaTracerVersion }}

        $metaLangVersion = $metaStar.language_version
        if ([string]::IsNullOrEmpty($metaLangVersion)) {{ $metaLangVersion = $metaStar.runtime_version }}
        if (-not [string]::IsNullOrEmpty($metaLangVersion)) {{ $langVersion = [string]$metaLangVersion }}

        $metaLangInterpreter = $metaStar.language_interpreter
        if ([string]::IsNullOrEmpty($metaLangInterpreter)) {{ $metaLangInterpreter = $metaStar.runtime_name }}
        if (-not [string]::IsNullOrEmpty($metaLangInterpreter)) {{ $langInterpreter = [string]$metaLangInterpreter }}
      }}
    }} catch {{
      # Metadata extraction is best-effort; fall back to defaults on parse issues.
      Dbg "Get-CommonHeaders: failed to parse payload metadata from '$PayloadPath' ($_)"
    }}
  }}

  $headers = @{{
    'Datadog-Meta-Lang' = $lang
    'Datadog-Meta-Lang-Version' = $langVersion
    'Datadog-Meta-Lang-Interpreter' = $langInterpreter
    'Datadog-Meta-Tracer-Version' = $tracerVersion
    'Accept' = 'application/json'
  }}
  if ($Agentless) {{
    # DD-API-KEY is only required in direct agentless upload mode.
    $headers['DD-API-KEY'] = $env:DD_API_KEY
  }}
  return $headers
}}

function Convert-ToMutableObject($Value) {{
  if ($null -eq $Value) {{ return $null }}
  if ($Value -is [System.Collections.IDictionary]) {{
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($k in $Value.Keys) {{
      $map[[string]$k] = Convert-ToMutableObject $Value[$k]
    }}
    return $map
  }}
  if ($Value -is [PSCustomObject]) {{
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Value.PSObject.Properties) {{
      $map[$p.Name] = Convert-ToMutableObject $p.Value
    }}
    return $map
  }}
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {{
    $arr = @()
    foreach ($item in $Value) {{
      $arr += ,(Convert-ToMutableObject $item)
    }}
    return $arr
  }}
  return $Value
}}

function Ensure-Hashtable($Value) {{
  $converted = Convert-ToMutableObject $Value
  if ($converted -is [System.Collections.IDictionary]) {{
    return $converted
  }}
  return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}}

function Get-MapValue($MapObj, [string]$Key) {{
  if ($null -eq $MapObj -or [string]::IsNullOrEmpty($Key)) {{ return $null }}
  if ($MapObj -is [System.Collections.IDictionary]) {{
    if ($MapObj.Contains($Key)) {{ return $MapObj[$Key] }}
    return $null
  }}
  $prop = $MapObj.PSObject.Properties[$Key]
  if ($prop) {{ return $prop.Value }}
  return $null
}}

$script:CodeOwnersInitialized = $false
$script:CodeOwnersEnabled = $false
$script:CodeOwnersPath = $null
$script:CodeOwnersRules = @()
$script:CodeOwnersStats = @{{
  scanned = 0
  enriched = 0
  skipped_existing = 0
  skipped_missing_source = 0
  skipped_unmatched = 0
  skipped_errors = 0
}}

function Normalize-PathLike([string]$PathValue) {{
  if ([string]::IsNullOrEmpty($PathValue)) {{ return $null }}
  $v = $PathValue
  if ($v.StartsWith("file://")) {{ $v = $v.Substring(7) }}
  if ($v.Contains('%')) {{
    # Keep behavior aligned with Bash: avoid decoding NUL (%00) into paths.
    $containsNullEscape = ($v -match '(?i)%00')
    $stripped = [regex]::Replace($v, '%[0-9A-Fa-f]{{2}}', '')
    if (-not $containsNullEscape -and -not $stripped.Contains('%')) {{
      try {{ $v = [Uri]::UnescapeDataString($v) }} catch {{}}
    }}
  }}
  # Decode can re-introduce backslashes (for example %5C on Windows paths).
  # Normalize after decoding so slash-based matching stays consistent.
  $v = $v.Replace([char]92, [char]47)
  # Normalize duplicate separators and leading "./" fragments first.
  while ($v.Contains("//")) {{ $v = $v.Replace("//", "/") }}
  while ($v.StartsWith("./")) {{ $v = $v.Substring(2) }}
  if ($v -match '^/[A-Za-z]:/') {{
    # file:///C:/... style paths become /C:/... after scheme removal.
    # Drop only the leading slash to preserve the drive-qualified path.
    $v = $v.Substring(1)
  }}

  # Resolve dot segments. If ".." would traverse above root, return null so
  # callers can safely ignore this candidate.
  $isAbs = $v.StartsWith("/")
  if ($isAbs) {{ $v = $v.Substring(1) }}
  $parts = @($v.Split('/', [System.StringSplitOptions]::None))
  $stack = New-Object System.Collections.Generic.List[string]
  foreach ($part in $parts) {{
    if ([string]::IsNullOrEmpty($part) -or $part -eq ".") {{ continue }}
    if ($part -eq "..") {{
      if ($stack.Count -gt 0) {{
        $stack.RemoveAt($stack.Count - 1)
        continue
      }}
      return $null
    }}
    $stack.Add($part)
  }}
  $joined = [string]::Join("/", $stack.ToArray())
  if ($isAbs) {{ return "/$joined" }}
  return $joined
}}

function Add-PathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Candidate) {{
  $normalized = Normalize-PathLike $Candidate
  if ([string]::IsNullOrEmpty($normalized)) {{ return }}
  if ($normalized.StartsWith("/")) {{ $normalized = $normalized.Substring(1) }}
  while ($normalized.StartsWith("./")) {{ $normalized = $normalized.Substring(2) }}
  if ([string]::IsNullOrEmpty($normalized)) {{ return }}
  # Generated artifacts should not be matched against repo CODEOWNERS.
  if ($normalized.StartsWith("bazel-out/")) {{ return }}
  if (-not $Candidates.Contains($normalized)) {{ $Candidates.Add($normalized) | Out-Null }}
}}

function Add-DerivedPathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Candidate) {{
  if ([string]::IsNullOrEmpty($Candidate)) {{ return }}
  if ($Candidate.StartsWith("external/") -or $Candidate.StartsWith("_main/external/")) {{
    # Execroot/runfiles derived external paths belong to fetched dependencies,
    # not repository-owned source files. Skip to avoid false owner attribution.
    if ($script:DebugMode) {{ Dbg "codeowners: skip external source candidate '$Candidate'" }}
    return
  }}
  Add-PathCandidate $Candidates $Candidate
}}

function Strip-WorkspacePrefix([string]$PathValue, [string]$WorkspaceRoot) {{
  if ([string]::IsNullOrEmpty($PathValue) -or [string]::IsNullOrEmpty($WorkspaceRoot)) {{ return $null }}
  $pathNorm = Normalize-PathLike $PathValue
  $rootNorm = Normalize-PathLike $WorkspaceRoot
  if ([string]::IsNullOrEmpty($pathNorm) -or [string]::IsNullOrEmpty($rootNorm)) {{ return $null }}
  # Windows paths are case-insensitive; honor that when stripping repo roots.
  $pathComparison = if ($env:OS -eq 'Windows_NT') {{ [System.StringComparison]::OrdinalIgnoreCase }} else {{ [System.StringComparison]::Ordinal }}
  if ([string]::Equals($pathNorm, $rootNorm, $pathComparison)) {{ return "" }}
  if ($pathNorm.StartsWith("$rootNorm/", $pathComparison)) {{
    return $pathNorm.Substring($rootNorm.Length + 1)
  }}
  return $null
}}

function Get-PathCandidates([string]$SourcePath) {{
  $candidates = New-Object System.Collections.Generic.List[string]
  $normalized = Normalize-PathLike $SourcePath
  if ([string]::IsNullOrEmpty($normalized)) {{ return $candidates }}

  $workspaceRoot = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {{
    $workspaceRoot = $env:BUILD_WORKSPACE_DIRECTORY
  }} elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {{
    $workspaceRoot = $Matches[1]
  }} else {{
    $workspaceRoot = (Get-Location).Path
  }}

  # Candidate order is deliberate: try repo-relative variants first, then
  # runfiles/execroot-derived forms, then absolute normalized fallback.
  $workspaceRoots = @(
    $(if ($script:ContextObj) {{ $script:ContextObj.'ci.workspace_path' }} else {{ $null }}),
    $workspaceRoot
  )
  foreach ($root in $workspaceRoots) {{
    $stripped = Strip-WorkspacePrefix $normalized $root
    if ($stripped -ne $null) {{ Add-PathCandidate $candidates $stripped }}
  }}

  if ($normalized -match '/execroot/[^/]+/_main/(.+)$') {{
    Add-DerivedPathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '/execroot/[^/]+/(.+)$') {{
    Add-DerivedPathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '\\.runfiles/_main/(.+)$') {{
    Add-DerivedPathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '\\.runfiles/[^/]+/(.+)$') {{
    Add-DerivedPathCandidate $candidates $Matches[1]
  }}
  # Keep only repository-relative fallback candidates. Absolute paths that are
  # not under known repo roots can incorrectly inherit broad CODEOWNERS rules.
  if (-not $normalized.StartsWith("/") -and -not ($normalized -match '^[A-Za-z]:/')) {{
    Add-PathCandidate $candidates $normalized
  }} elseif ($script:DebugMode) {{
    Dbg "codeowners: skip absolute source fallback candidate '$normalized'"
  }}
  return $candidates
}}

function Convert-CodeOwnersGlobToRegex([string]$Pattern) {{
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $Pattern.Length) {{
    $ch = $Pattern.Substring($i, 1)
    # Backslash escapes a literal glob metacharacter.
    if ([int][char]$ch -eq 92) {{
      if (($i + 1) -lt $Pattern.Length) {{
        $escapedCh = $Pattern.Substring($i + 1, 1)
        [void]$sb.Append([Regex]::Escape($escapedCh))
        $i += 2
      }} else {{
        [void]$sb.Append("\\\\")
        $i++
      }}
      continue
    }}
    if ($ch -eq '*' -and ($i + 1) -lt $Pattern.Length -and $Pattern.Substring($i + 1, 1) -eq '*') {{
      if (($i + 2) -lt $Pattern.Length -and $Pattern.Substring($i + 2, 1) -eq '/') {{
        # CODEOWNERS follows gitignore-style globbing: **/ matches zero or more directories.
        [void]$sb.Append("(.*/)?")
        $i += 3
      }} else {{
        [void]$sb.Append(".*")
        $i += 2
      }}
      continue
    }}
    if ($ch -eq '*') {{
      [void]$sb.Append("[^/]*")
      $i++
      continue
    }} elseif ($ch -eq '?') {{
      [void]$sb.Append("[^/]")
      $i++
      continue
    }}
    if ($ch -eq '[') {{
      # Preserve character classes (including negation), because repositories
      # frequently use patterns like [Tt]est*.cs in CODEOWNERS.
      $j = $i + 1
      $classSb = New-Object System.Text.StringBuilder
      $closed = $false
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '!') {{
        [void]$classSb.Append("^")
        $j++
      }} elseif ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '^') {{
        [void]$classSb.Append("\\^")
        $j++
      }}
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq ']') {{
        [void]$classSb.Append("\\]")
        $j++
      }}
      while ($j -lt $Pattern.Length) {{
        $classCh = $Pattern.Substring($j, 1)
        if ($classCh -eq ']') {{
          $closed = $true
          break
        }}
        if ([int][char]$classCh -eq 92) {{
          [void]$classSb.Append("\\\\")
        }} elseif ($classCh -eq '^') {{
          [void]$classSb.Append("\\^")
        }} elseif ($classCh -eq '[') {{
          [void]$classSb.Append("\\[")
        }} elseif ($classCh -eq '-') {{
          [void]$classSb.Append("-")
        }} else {{
          [void]$classSb.Append([Regex]::Escape($classCh))
        }}
        $j++
      }}
      if ($closed) {{
        [void]$sb.Append("[$classSb]")
        $i = $j + 1
        continue
      }}
      [void]$sb.Append("\\[")
      $i++
      continue
    }}
    if ($ch -eq '.') {{
      [void]$sb.Append("\\.")
    }} elseif ($ch -eq '+') {{
      [void]$sb.Append("\\+")
    }} elseif ($ch -eq '(') {{
      [void]$sb.Append("\\(")
    }} elseif ($ch -eq ')') {{
      [void]$sb.Append("\\)")
    }} elseif ($ch -eq '{') {{
      [void]$sb.Append("\\{")
    }} elseif ($ch -eq '}') {{
      [void]$sb.Append("\\}")
    }} elseif ($ch -eq '^') {{
      [void]$sb.Append("\\^")
    }} elseif ($ch -eq '$') {{
      [void]$sb.Append("\\$")
    }} elseif ($ch -eq '|') {{
      [void]$sb.Append("\\|")
    }} elseif ([int][char]$ch -eq 92) {{
      [void]$sb.Append("\\\\")
    }} elseif ($ch -eq ']') {{
      [void]$sb.Append("\\]")
    }} else {{
      [void]$sb.Append($ch)
    }}
    $i++
  }}
  return $sb.ToString()
}}

function Convert-CodeOwnersPatternToRegex([string]$Pattern) {{
  if ([string]::IsNullOrEmpty($Pattern)) {{ return $null }}
  $anchored = $false
  $dirOnly = $false
  $raw = $Pattern
  if ($raw.StartsWith("/")) {{
    $anchored = $true
    $raw = $raw.Substring(1)
  }}
  if ($raw.EndsWith("/")) {{
    $dirOnly = $true
    $raw = $raw.Substring(0, $raw.Length - 1)
  }}
  if ([string]::IsNullOrEmpty($raw)) {{ return $null }}
  $hasSlash = $raw.Contains("/")
  $body = Convert-CodeOwnersGlobToRegex $raw

  # Match semantics:
  # - anchored or slash-containing rules start at repo root
  # - simple names can match at any path segment boundary
  $prefix = if ($anchored -or $hasSlash) {{ "^" }} else {{ "(^|.*/)" }}
  $suffix = if ($dirOnly) {{ "/.*$" }} else {{ "($|/.*)" }}
  return "$prefix$body$suffix"
}}

function Split-CodeOwnersLine([string]$Line) {{
  if ([string]::IsNullOrEmpty($Line)) {{
    return [PSCustomObject]@{{ Pattern = ""; OwnersRaw = "" }}
  }}
  $sb = New-Object System.Text.StringBuilder
  $escaped = $false
  for ($i = 0; $i -lt $Line.Length; $i++) {{
    $ch = $Line.Substring($i, 1)
    if ($escaped) {{
      [void]$sb.Append($ch)
      $escaped = $false
      continue
    }}
    if ([int][char]$ch -eq 92) {{
      [void]$sb.Append($ch)
      $escaped = $true
      continue
    }}
    if ([char]::IsWhiteSpace($Line[$i])) {{
      $ownersRaw = $Line.Substring($i).TrimStart()
      return [PSCustomObject]@{{ Pattern = $sb.ToString(); OwnersRaw = $ownersRaw }}
    }}
    [void]$sb.Append($ch)
  }}
  return [PSCustomObject]@{{ Pattern = $sb.ToString(); OwnersRaw = "" }}
}}

function Test-IsGitLabSectionHeaderPattern([string]$Pattern) {{
  if ([string]::IsNullOrEmpty($Pattern)) {{ return $false }}
  if ($Pattern -notmatch '^\\[[^\\[\\]]+\\]$') {{ return $false }}
  $inner = $Pattern.Substring(1, $Pattern.Length - 2)
  # GitLab section headers can include whitespace (for example [Core Team]).
  if ($inner.Contains(" ") -or $inner.Contains("`t")) {{
    return $true
  }}
  # Heuristic to avoid class-only glob false positives:
  # keep range-like and short bracket classes (for example [xy], [A-Z]).
  if ($inner.Contains('-') -or $inner.Contains('!') -or $inner.Contains('^') -or $inner.Contains([string]([char]92))) {{
    return $false
  }}
  # Preserve all-uppercase/digit class sets such as [ABCD] and [A1B2C3].
  if ($inner -cmatch '^[A-Z0-9]+$') {{ return $false }}
  # Preserve short alnum bracket classes (for example [xy], [ABC], [Abc]).
  if ($inner.Length -le 3 -and $inner -cmatch '^[A-Za-z0-9]+$') {{ return $false }}
  # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
  if ($inner -cmatch '^[a-z0-9]+$') {{ return $false }}
  return $true
}}

function Test-IsGitLabSectionHeaderLine([string]$Line) {{
  if ([string]::IsNullOrEmpty($Line)) {{ return $false }}
  if ($Line -notmatch '^(\\[[^\\[\\]]+\\])(?:\\s+.*)?$') {{ return $false }}
  return (Test-IsGitLabSectionHeaderPattern $Matches[1])
}}

function Initialize-CodeOwnersRules {{
  if ($script:CodeOwnersInitialized) {{ return }}
  $script:CodeOwnersInitialized = $true

  $workspace = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {{
    $workspace = $env:BUILD_WORKSPACE_DIRECTORY
  }} elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {{
    $workspace = $Matches[1]
  }} else {{
    $workspace = (Get-Location).Path
  }}
  $explicitCodeOwners = $env:DD_TEST_OPTIMIZATION_CODEOWNERS_FILE
  if (-not [string]::IsNullOrEmpty($explicitCodeOwners)) {{
    Dbg "codeowners: explicit path candidate '$explicitCodeOwners'"
    if (Test-Path -LiteralPath $explicitCodeOwners -PathType Leaf) {{
      $script:CodeOwnersPath = $explicitCodeOwners
      Dbg "codeowners: using explicit CODEOWNERS file '$script:CodeOwnersPath'"
    }} else {{
      Dbg "codeowners: DD_TEST_OPTIMIZATION_CODEOWNERS_FILE is set but not readable: '$explicitCodeOwners' (falling back to discovery)"
    }}
  }}
  $compatWorkspace = if ($script:ContextObj) {{ $script:ContextObj.'ci.workspace_path' }} else {{ $null }}
  # Lookup order must mirror Bash implementation for cross-platform parity.
  if (-not $script:CodeOwnersPath) {{
    $lookupPaths = @(
      $(if ($compatWorkspace) {{ Join-Path $compatWorkspace "CODEOWNERS" }} else {{ $null }}),
      $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".github/CODEOWNERS" }} else {{ $null }}),
      $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".gitlab/CODEOWNERS" }} else {{ $null }}),
      $(if ($compatWorkspace) {{ Join-Path $compatWorkspace "docs/CODEOWNERS" }} else {{ $null }}),
      $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".docs/CODEOWNERS" }} else {{ $null }}),
      (Join-Path $workspace "CODEOWNERS"),
      (Join-Path $workspace ".github/CODEOWNERS"),
      (Join-Path $workspace ".gitlab/CODEOWNERS"),
      (Join-Path $workspace "docs/CODEOWNERS"),
      (Join-Path $workspace ".docs/CODEOWNERS"),
      (Join-Path (Get-Location).Path "CODEOWNERS"),
      (Join-Path $PSScriptRoot "CODEOWNERS")
    )

    foreach ($candidate in $lookupPaths) {{
      if ([string]::IsNullOrEmpty($candidate)) {{ continue }}
      $candidateExists = Test-Path -LiteralPath $candidate -PathType Leaf
      if ($candidateExists) {{
        Dbg "codeowners: discovery candidate hit '$candidate'"
      }}
      if ($candidateExists) {{
        $script:CodeOwnersPath = $candidate
        break
      }}
    }}
  }}
  if (-not $script:CodeOwnersPath) {{
    Dbg "codeowners: no CODEOWNERS file found (workspace='$workspace')"
    return
  }}

  try {{
    $lines = Get-Content -LiteralPath $script:CodeOwnersPath -Encoding UTF8 -ErrorAction Stop
  }} catch {{
    Dbg "codeowners: failed to read '$script:CodeOwnersPath' ($_)"
    return
  }}

  foreach ($line in $lines) {{
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) {{ continue }}
    # Section headers may include spaces (for example "[Core Team] @org/team").
    # Detect them from the full raw line before splitting on whitespace.
    if (Test-IsGitLabSectionHeaderLine $trimmed) {{
      continue
    }}
    $split = Split-CodeOwnersLine $trimmed
    $pattern = [string]$split.Pattern
    if ([string]::IsNullOrEmpty($pattern)) {{ continue }}
    $ownersRaw = [string]$split.OwnersRaw
    # Ignore GitLab-style section headers while preserving bracket-class globs.
    if (Test-IsGitLabSectionHeaderPattern $pattern) {{
      continue
    }}
    $ownersRaw = $ownersRaw.Trim()
    # Strip inline comments only when '#' begins a comment segment.
    if ($ownersRaw.StartsWith("#")) {{
      $ownersRaw = ""
    }} elseif ($ownersRaw -match '\\s#') {{
      $ownersRaw = ($ownersRaw -replace '\\s#.*$', '').TrimEnd()
    }}
    $ownerTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($ownersRaw)) {{
      $ownerTokens = @($ownersRaw -split '\\s+' | Where-Object {{ -not [string]::IsNullOrEmpty($_) }})
    }}
    $regex = Convert-CodeOwnersPatternToRegex $pattern
    if ([string]::IsNullOrEmpty($regex)) {{ continue }}
    # Best-effort hardening: malformed character classes can produce invalid
    # .NET regexes (for example "[z-a]"). Skip those rules here so one bad
    # line cannot force all candidate evaluations into catch paths.
    try {{
      [void][System.Text.RegularExpressions.Regex]::new($regex)
    }} catch {{
      Dbg "codeowners: skipping invalid regex '$regex' from pattern '$pattern'"
      continue
    }}
    $script:CodeOwnersRules += [PSCustomObject]@{{
      Regex = $regex
      Owners = $ownerTokens
      HasOwners = ($ownerTokens.Count -gt 0)
    }}
  }}

  if ($script:CodeOwnersRules.Count -gt 0) {{
    $script:CodeOwnersEnabled = $true
    Dbg "codeowners: using '$script:CodeOwnersPath' with $($script:CodeOwnersRules.Count) rule(s)"
  }} else {{
    Dbg "codeowners: file '$script:CodeOwnersPath' had no usable rules"
  }}
}}

function Get-CodeOwnersMatchForCandidate([string]$Candidate) {{
  $matched = $false
  $matchOwners = @()
  $matchHasOwners = $false
  # Last matching rule wins (GitHub CODEOWNERS behavior).
  foreach ($rule in $script:CodeOwnersRules) {{
    if ($Candidate -cmatch $rule.Regex) {{
      $matched = $true
      $matchOwners = @($rule.Owners)
      $matchHasOwners = [bool]$rule.HasOwners
    }}
  }}
  return [PSCustomObject]@{{
    Matched = $matched
    Owners = $matchOwners
    HasOwners = $matchHasOwners
  }}
}}

function Convert-OwnersToJsonString($Owners) {{
  if (-not $Owners -or $Owners.Count -eq 0) {{ return $null }}
  $dedup = New-Object System.Collections.Generic.List[string]
  foreach ($owner in $Owners) {{
    if (-not [string]::IsNullOrEmpty($owner) -and -not $dedup.Contains([string]$owner)) {{
      $dedup.Add([string]$owner) | Out-Null
    }}
  }}
  if ($dedup.Count -eq 0) {{ return $null }}
  # Keep JSON shape stable: always emit an array string, including a single owner.
  $dedupArr = @($dedup.ToArray())
  return (ConvertTo-Json -InputObject $dedupArr -Compress)
}}

function Get-CodeOwnersJsonForSource([string]$SourcePath) {{
  Initialize-CodeOwnersRules
  if (-not $script:CodeOwnersEnabled) {{ return $null }}
  $candidates = Get-PathCandidates $SourcePath
  # Return first candidate hit (candidate list is already priority-ordered).
  foreach ($candidate in $candidates) {{
    $match = Get-CodeOwnersMatchForCandidate $candidate
    if (-not $match.Matched) {{ continue }}
    if (-not $match.HasOwners) {{ return $null }}
    $jsonOwners = Convert-OwnersToJsonString $match.Owners
    if (-not [string]::IsNullOrEmpty($jsonOwners)) {{
      return $jsonOwners
    }}
  }}
  return $null
}}

function Get-EventSourcePath($EventObj) {{
  if (-not $EventObj) {{ return $null }}
  $content = Get-MapValue $EventObj 'content'
  if ($null -eq $content) {{ return $null }}
  $contentMap = Ensure-Hashtable $content

  # Accept both flattened meta keys and nested source objects.
  $meta = Ensure-Hashtable (Get-MapValue $contentMap 'meta')
  foreach ($k in @('test.source.file', 'test.source.path', 'source.file', 'source.path')) {{
    $v = Get-MapValue $meta $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) {{ return $v }}
  }}

  $source = Ensure-Hashtable (Get-MapValue $contentMap 'source')
  foreach ($k in @('file', 'path')) {{
    $v = Get-MapValue $source $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) {{ return $v }}
  }}
  return $null
}}

function Merge-With-Context([string]$infile, [string]$outfile) {{
  try {{
    $payload = Get-Content -LiteralPath $infile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  }} catch {{
    # If payload is not JSON, preserve original bytes and let upload attempt
    # proceed; validation/debugging layers surface the issue separately.
    Copy-Item -LiteralPath $infile -Destination $outfile -Force
    return
  }}

  if (-not $payload.metadata) {{ $payload | Add-Member -NotePropertyName metadata -NotePropertyValue @{{}} -Force }}
  $meta = Ensure-Hashtable $payload.metadata
  $star = Ensure-Hashtable (Get-MapValue $meta '*')

  # Compute runtime-id, language, library_version, env (fill missing only)
  $runtimeId = Get-MapValue $star 'runtime-id'
  if ([string]::IsNullOrEmpty($runtimeId)) {{
    if ($script:ContextObj) {{
      $runtimeId = $script:ContextObj.'runtime-id'
      if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:ContextObj.'runtime.id' }}
      if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:ContextObj.'runtime_id' }}
    }}
    if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:RuntimeId }}
  }}

  $language = Get-MapValue $star 'language'
  if ([string]::IsNullOrEmpty($language)) {{
    if ($script:ContextObj) {{
      $language = $script:ContextObj.language
      if ([string]::IsNullOrEmpty($language)) {{ $language = $script:ContextObj.'runtime.name' }}
      if ([string]::IsNullOrEmpty($language)) {{ $language = $script:ContextObj.'runtime_name' }}
    }}
    if ([string]::IsNullOrEmpty($language)) {{ $language = 'bazel' }}
  }}

  $libraryVersion = Get-MapValue $star 'library_version'
  if ([string]::IsNullOrEmpty($libraryVersion)) {{ $libraryVersion = $script:RulesVersion }}

  $envVal = Get-MapValue $star 'env'
  if ([string]::IsNullOrEmpty($envVal) -and $script:ContextObj) {{ $envVal = $script:ContextObj.env }}

  $newStar = @{{ 'runtime-id' = $runtimeId; 'language' = $language; 'library_version' = $libraryVersion }}
  if (-not [string]::IsNullOrEmpty($envVal)) {{ $newStar['env'] = $envVal }}

  # Prune top-level metadata keys
  # Keep only documented metadata sections to avoid propagating unexpected
  # large/unstable keys from upstream payload generators.
  $newMeta = @{{ '*' = $newStar }}
  foreach ($k in @('test', 'test_suite_end', 'test_module_end', 'test_session_end')) {{
    $metaVal = Get-MapValue $meta $k
    if ($null -ne $metaVal) {{ $newMeta[$k] = $metaVal }}
  }}
  $payload.metadata = $newMeta

  # Copy context tags into event meta/metrics, then inject CODEOWNERS.
  # Span events are intentionally excluded from enrichment.
  if ($payload.events) {{
    foreach ($evt in $payload.events) {{
      $evtType = Get-MapValue $evt 'type'
      if ($evtType -eq 'span') {{ continue }}
      if (-not (Get-MapValue $evt 'content')) {{ $evt | Add-Member -NotePropertyName content -NotePropertyValue @{{}} -Force }}
      $evt.content = Ensure-Hashtable $evt.content
      $evt.content.meta = Ensure-Hashtable $evt.content.meta
      $evt.content.metrics = Ensure-Hashtable $evt.content.metrics

      if ($script:ContextObj) {{
        foreach ($prop in $script:ContextObj.PSObject.Properties) {{
          # Keep API key fingerprint out of uploaded event content.
          if ($prop.Name -eq 'topt.api_key_fingerprint') {{ continue }}
          $val = $prop.Value
          if ($val -is [string]) {{
            $evt.content.meta[$prop.Name] = $val
          }} elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {{
            # Preserve numeric tags as metrics for Datadog queryability.
            $evt.content.metrics[$prop.Name] = [double]$val
          }} else {{
            try {{
              $evt.content.meta[$prop.Name] = ($val | ConvertTo-Json -Compress -Depth 100)
            }} catch {{
              $evt.content.meta[$prop.Name] = $val.ToString()
            }}
          }}
        }}
      }}

      $script:CodeOwnersStats.scanned++
      # Respect upstream/producer-specified ownership tags.
      if ($evt.content.meta.Contains('test.codeowners')) {{
        $script:CodeOwnersStats.skipped_existing++
        if ($script:DebugMode) {{ Dbg "codeowners: skip existing tag for event type '$evtType'" }}
        continue
      }}
      $sourcePath = Get-EventSourcePath $evt
      if ([string]::IsNullOrEmpty($sourcePath)) {{
        $script:CodeOwnersStats.skipped_missing_source++
        if ($script:DebugMode) {{ Dbg "codeowners: skip missing source for event type '$evtType'" }}
        continue
      }}
      try {{
        $ownersJson = Get-CodeOwnersJsonForSource $sourcePath
        if ([string]::IsNullOrEmpty($ownersJson)) {{
          $script:CodeOwnersStats.skipped_unmatched++
          if ($script:DebugMode) {{ Dbg "codeowners: skip unmatched source '$sourcePath' for event type '$evtType'" }}
          continue
        }}
        $evt.content.meta['test.codeowners'] = $ownersJson
        $script:CodeOwnersStats.enriched++
        if ($script:DebugMode) {{ Dbg "codeowners: assigned owners '$ownersJson' for event type '$evtType'" }}
      }} catch {{
        $script:CodeOwnersStats.skipped_errors++
        Dbg "codeowners: failed to resolve owners for '$sourcePath' ($_)"
      }}
    }}
  }}

  if ($script:DebugMode) {{
    Dbg "codeowners: scanned=$($script:CodeOwnersStats.scanned) enriched=$($script:CodeOwnersStats.enriched) skipped_existing=$($script:CodeOwnersStats.skipped_existing) skipped_missing_source=$($script:CodeOwnersStats.skipped_missing_source) skipped_unmatched=$($script:CodeOwnersStats.skipped_unmatched) skipped_errors=$($script:CodeOwnersStats.skipped_errors)"
  }}

  Dbg "Merge-With-Context: wrote enriched '$outfile'"
  $jsonPayload = $payload | ConvertTo-Json -Depth 100
  Write-Utf8NoBomFile -Path $outfile -Content $jsonPayload
}}

function Validate-Payload([string]$FilePath) {{
    if (-not $script:SchemaJson -or -not (Test-Path -LiteralPath $script:SchemaJson)) {{
        Dbg "schema validation skipped: schema not available"
        return
    }}
    if (-not $script:SchemaValidator -or -not (Test-Path -LiteralPath $script:SchemaValidator)) {{
        Dbg "schema validation skipped: validator not available"
        return
    }}
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) {{
        Dbg "schema validation skipped: python3 not available"
        return
    }}
    Dbg "schema validate: python3 $script:SchemaValidator $script:SchemaJson $FilePath"
    try {{
        # Suppress validator stdout/stderr so upload boolean control flow is not
        # polluted by non-empty command output streams.
        & $py.Source $script:SchemaValidator $script:SchemaJson $FilePath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {{
            # Warning-only contract: validation should not block uploads.
            Log "warning: schema validation failed for payload: $FilePath"
        }}
    }} catch {{
        Log "warning: schema validation failed for payload: $FilePath"
    }}
}}

# Check if file matches prefix filter (when enabled)
function Test-PrefixFilter([string]$FilePath, [string]$ExpectedPrefix) {{
    if (-not $FilterPrefix) {{ return $true }}  # No filtering, accept all
    $basename = Split-Path -Leaf $FilePath
    return $basename.StartsWith($ExpectedPrefix)
}}

# Delete file unless KeepPayloads is set
function Remove-PayloadFile([string]$FilePath) {{
    if (-not $KeepPayloads) {{
        # Best-effort cleanup: payload persistence is controlled by KeepPayloads,
        # not by upload success/failure of individual files.
        Remove-Item -LiteralPath $FilePath -Force
    }} else {{
        Dbg "keeping payload (KEEP_PAYLOADS=1): $FilePath"
    }}
}}

# Track upload failures globally
$script:UploadFailures = 0

function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {{
  $maxRetries = 3
  $retryDelay = 2
  if (-not (Ensure-HttpClientTypes)) {{
    Log "upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
    return [bool]$false
  }}
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {{
    $client = $null
    try {{
      # Build a fresh HttpClient per retry attempt to avoid carrying stale
      # request state or headers across attempts.
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {{
        # Add() returns bool; suppress pipeline output so callers receive only
        # the explicit boolean return from this function.
        $null = $client.DefaultRequestHeaders.Add($k, [string]$headers[$k])
      }}
      Dbg "Send-PostJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      if ($script:GzipPayloads) {{
        # Inline gzip keeps implementation dependency-free on Windows hosts.
        $bytes = [IO.File]::ReadAllBytes($file)
        $ms = New-Object System.IO.MemoryStream
        $gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()
        $compressed = $ms.ToArray()
        $content = New-Object System.Net.Http.ByteArrayContent($compressed)
        $content.Headers.ContentType = 'application/json'
        $null = $content.Headers.ContentEncoding.Add('gzip')
        Dbg "Send-PostJson: Content-Type=application/json; Content-Encoding=gzip (bytes=$($compressed.Length))"
      }} else {{
        $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
        $content.Headers.ContentType = 'application/json'
        Dbg "Send-PostJson: Content-Type=application/json"
      }}
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {{
        if ($script:DebugMode) {{
          $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          if ($body) {{ Dbg "Send-PostJson response: $body" }}
        }}
        return [bool]$true
      }} else {{
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Dbg "Send-PostJson: HTTP $([int]$resp.StatusCode) on attempt $attempt"
        if ($attempt -eq $maxRetries) {{
          # Emit user-facing failure only after retry budget is exhausted.
          Log "upload failed: HTTP $([int]$resp.StatusCode) $body"
          return [bool]$false
        }}
      }}
    }} catch {{
      Dbg "Send-PostJson: Exception on attempt $attempt - $_"
      if ($attempt -eq $maxRetries) {{
        Log "upload failed: $_"
        return [bool]$false
      }}
    }} finally {{
      # Dispose HttpClient each attempt to release sockets promptly in long runs.
      if ($client) {{ $client.Dispose() }}
    }}
    # Fixed retry delay keeps behavior deterministic across hosts/CI lanes.
    Start-Sleep -Seconds $retryDelay
  }}
  return [bool]$false
}}

function Upload-SingleTest([string]$FilePath) {{
    $body = Join-Path $script:TmpPayloadDir ("test_payload_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Merge-With-Context $FilePath $body
    Validate-Payload $body
    $hdrs = Get-CommonHeaders $body
    if (-not $Agentless) {{ $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }}
    Dbg "Upload-SingleTest: posting '$FilePath' (body '$body')"
    if ($script:DebugMode) {{
        Write-Host "[dd-uploader][dbg] payload content (enriched) for '$FilePath':"
        Write-Host (Get-Content -LiteralPath $body -Raw)
        Dbg "request: POST $TestUrl"
        Dbg-Headers "common" $hdrs
        Log-StartTimeStats $body
    }}
    $result = [bool](Send-PostJson $TestUrl $hdrs $body)
    # Enriched temp payload is always ephemeral.
    Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    return [bool]$result
}}

function Upload-SingleCoverage([string]$FilePath) {{
    $eventFile = Join-Path $script:TmpPayloadDir ("coverage_event_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    # Coverage endpoint expects multipart with an `event` part; a small dummy
    # object is sufficient and matches agentless/EVP server expectations.
    Write-Utf8NoBomFile -Path $eventFile -Content '{{"dummy":true}}'

    $client = $null
    $fs = $null
    $maxRetries = 3
    $retryDelay = 2
    $uploaded = $false

    try {{
        if (-not (Ensure-HttpClientTypes)) {{
            Log "coverage upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
            return [bool]$false
        }}
        $covHeaders = Get-CommonHeaders $null
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        foreach ($k in $covHeaders.Keys) {{
            # Add() returns bool; suppress pipeline output to preserve boolean semantics.
            $null = $client.DefaultRequestHeaders.Add($k, [string]$covHeaders[$k])
        }}
        if (-not $Agentless) {{ $null = $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }}
        if ($script:DebugMode) {{
            Dbg "request: POST $CovUrl"
            Dbg-Headers "common" $covHeaders
            if (-not $Agentless) {{ Dbg "header[evp]: X-Datadog-EVP-Subdomain: citestcov-intake" }}
        }}

        for ($attempt = 1; $attempt -le $maxRetries -and -not $uploaded; $attempt++) {{
            try {{
                # Recreate multipart content on each retry; StreamContent cannot
                # be safely reused once a request has been sent.
                $content = New-Object System.Net.Http.MultipartFormDataContent
                $eventContent = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($eventFile, [System.Text.Encoding]::UTF8))
                $eventContent.Headers.ContentType = 'application/json'
                $content.Add($eventContent, 'event', 'fileevent.json')
                $fs = [System.IO.File]::OpenRead($FilePath)
                $covContent = New-Object System.Net.Http.StreamContent($fs)
                $covContent.Headers.ContentType = 'application/json'
                $content.Add($covContent, 'coveragex', 'filecoveragex.json')
                Dbg "Upload-SingleCoverage: posting '$FilePath' (attempt $attempt/$maxRetries; Content-Type=multipart/form-data)"
                $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) {{
                    $uploaded = $true
                    if ($script:DebugMode) {{
                        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if ($respBody) {{ Dbg "Upload-SingleCoverage response: $respBody" }}
                    }}
                }} else {{
                    $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    Dbg "Upload-SingleCoverage: HTTP $([int]$resp.StatusCode) on attempt $attempt"
                    if ($attempt -eq $maxRetries) {{
                        # Only emit user-facing error after final retry to avoid
                        # noisy logs for transient first-attempt failures.
                        Log "coverage upload failed: HTTP $([int]$resp.StatusCode) $respBody"
                    }}
                }}
            }} catch {{
                Dbg "Upload-SingleCoverage: Exception on attempt $attempt - $_"
                if ($attempt -eq $maxRetries) {{
                    Log "coverage upload failed: $_"
                }}
            }} finally {{
                # Close file handle every attempt before retrying.
                if ($fs) {{ $fs.Dispose(); $fs = $null }}
            }}
            if (-not $uploaded -and $attempt -lt $maxRetries) {{ Start-Sleep -Seconds $retryDelay }}
        }}
    }} finally {{
        if ($client) {{ $client.Dispose() }}
        Remove-Item -LiteralPath $eventFile -Force -ErrorAction SilentlyContinue
    }}
    return [bool]$uploaded
}}

function Upload-AllTests {{
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $testsDir = Join-Path $outputsDir.FullName "payloads/tests"
        if (-not (Test-Path -LiteralPath $testsDir)) {{ continue }}
        $files = Get-ChildItem -Path $testsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {{
            if (-not (Test-PrefixFilter $f.FullName "span_events_")) {{
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                continue
            }}
            $uploaded = (Upload-SingleTest $f.FullName) -eq $true
            if ($uploaded) {{
                Log "uploaded test payload: $($f.FullName)"
                Remove-PayloadFile $f.FullName
                $total++
            }} else {{
                # Continue best-effort upload and report aggregate failures at end.
                Log "warning: failed to upload $($f.FullName)"
                $failed++
                $script:UploadFailures++
            }}
        }}
    }}
    Log "uploaded $total test payloads"
    if ($failed -gt 0) {{ Log "warning: $failed test payloads failed to upload" }}
    if ($skipped -gt 0) {{ Dbg "skipped $skipped files (prefix filter)" }}
}}

function Upload-AllCoverage {{
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $covDir = Join-Path $outputsDir.FullName "payloads/coverage"
        if (-not (Test-Path -LiteralPath $covDir)) {{ continue }}
        $files = Get-ChildItem -Path $covDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {{
            if (-not (Test-PrefixFilter $f.FullName "coverage_")) {{
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                continue
            }}
            $uploaded = (Upload-SingleCoverage $f.FullName) -eq $true
            if ($uploaded) {{
                Log "uploaded coverage payload: $($f.FullName)"
                Remove-PayloadFile $f.FullName
                $total++
            }} else {{
                # Preserve symmetry with test uploads: keep going, count failures.
                Log "warning: failed to upload $($f.FullName)"
                $failed++
                $script:UploadFailures++
            }}
        }}
    }}
    Log "uploaded $total coverage payloads"
    if ($failed -gt 0) {{ Log "warning: $failed coverage payloads failed to upload" }}
    if ($skipped -gt 0) {{ Dbg "skipped $skipped files (prefix filter)" }}
}}

# Main upload logic wrapped in try/finally for proper cleanup
try {{
    # Run tests first, then coverage. This ordering mirrors historical behavior
    # and keeps log/snapshot expectations stable across platforms.
    Upload-AllTests
    Upload-AllCoverage

    # Exit with appropriate code based on upload results
    if ($script:UploadFailures -gt 0) {{
        Log "done with $($script:UploadFailures) upload failures"
        exit 1
    }} else {{
        Log "done"
        exit 0
    }}
}} finally {{
    Release-Lock
}}
"""
