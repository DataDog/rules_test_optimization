# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$UploaderArgs
)

$ErrorActionPreference = "Stop"
$script:LauncherPath = $MyInvocation.MyCommand.Path
$script:LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-UploaderRunfile {
    param(
        [string]$DirectPath,
        [string]$LogicalPath,
        [string]$SiblingName = ""
    )
    if ($SiblingName) {
        $sibling = Join-Path $script:LauncherDir $SiblingName
        if (Test-Path -LiteralPath $sibling -PathType Leaf) {
            return (Resolve-Path -LiteralPath $sibling).Path
        }
    }
    if ($DirectPath -and (Test-Path -LiteralPath $DirectPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $DirectPath).Path
    }

    $normalized = $LogicalPath.Replace("\", "/")
    while ($normalized.StartsWith("../")) {
        $normalized = $normalized.Substring(3)
    }
    $logicalCandidates = [System.Collections.Generic.List[string]]::new()
    [void]$logicalCandidates.Add($normalized)
    if ($normalized.StartsWith("external/")) {
        [void]$logicalCandidates.Add($normalized.Substring(9))
    } else {
        [void]$logicalCandidates.Add("external/$normalized")
    }
    [void]$logicalCandidates.Add("_main/$normalized")

    $roots = @($env:RUNFILES_DIR, $env:TEST_SRCDIR, "$script:LauncherPath.runfiles")
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($candidate in $logicalCandidates) {
            $paths = @((Join-Path $root $candidate))
            if ($env:TEST_WORKSPACE) {
                $paths += (Join-Path (Join-Path $root $env:TEST_WORKSPACE) $candidate)
            }
            foreach ($path in $paths) {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    return (Resolve-Path -LiteralPath $path).Path
                }
            }
        }
    }

    $manifests = @(
        $env:RUNFILES_MANIFEST_FILE,
        "$script:LauncherPath.runfiles_manifest",
        "$script:LauncherPath.runfiles\MANIFEST"
    )
    foreach ($manifest in $manifests) {
        if (-not $manifest -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            continue
        }
        foreach ($line in [System.IO.File]::ReadLines($manifest)) {
            $separator = $line.IndexOf(" ")
            if ($separator -le 0) { continue }
            $key = $line.Substring(0, $separator).Replace("\", "/")
            $value = $line.Substring($separator + 1)
            foreach ($candidate in $logicalCandidates) {
                if (($key -eq $candidate -or $key.EndsWith("/$candidate")) -and
                    (Test-Path -LiteralPath $value -PathType Leaf)) {
                    return (Resolve-Path -LiteralPath $value).Path
                }
            }
        }
    }
    throw "runfile could not be resolved: $LogicalPath"
}

$python = $null
foreach ($candidate in @($env:DD_TEST_OPTIMIZATION_PYTHON, $env:PYTHON, "python3", "python")) {
    if (-not $candidate) { continue }
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
        $python = $command.Source
        break
    }
}
if (-not $python) {
    [Console]::Error.WriteLine("[dd-uploader] error: Python 3.10 or newer was not found")
    exit 2
}

try {
    $mainPath = Resolve-UploaderRunfile `
        -DirectPath "__DDTPL_PYTHON_MAIN_PATH__" `
        -LogicalPath "__DDTPL_PYTHON_MAIN_RLOC__"
    $configPath = Resolve-UploaderRunfile `
        -DirectPath "__DDTPL_PYTHON_CONFIG_PATH__" `
        -LogicalPath "__DDTPL_PYTHON_CONFIG_RLOC__" `
        -SiblingName "__DDTPL_PYTHON_CONFIG_NAME__"
} catch {
    [Console]::Error.WriteLine("[dd-uploader] error: $($_.Exception.Message)")
    exit 2
}

& $python $mainPath --config $configPath @UploaderArgs
exit $LASTEXITCODE
