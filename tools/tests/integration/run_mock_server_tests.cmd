@REM Unless explicitly stated otherwise all files in this repository are licensed under
@REM the Apache 2.0 License.
@REM
@REM This product includes software developed at Datadog
@REM (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%run_mock_server_tests.ps1"

if not exist "%PS_SCRIPT%" (
  echo error: missing PowerShell entrypoint: "%PS_SCRIPT%"
  exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo error: powershell.exe not found in PATH
  exit /b 1
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
