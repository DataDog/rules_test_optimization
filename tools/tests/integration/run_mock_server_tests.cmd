@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%run_mock_server_tests.ps1"

if not exist "%PS_SCRIPT%" (
  echo error: missing PowerShell entrypoint: "%PS_SCRIPT%"
  exit /b 1
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
