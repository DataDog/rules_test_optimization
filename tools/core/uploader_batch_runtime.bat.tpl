@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%__DDTPL_PS_NAME__"
exit /b %ERRORLEVEL%
