Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "..\common\runtests_common.ps1")

Invoke-ExampleRunTests -ScriptDir $scriptDir
