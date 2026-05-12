@REM Unless explicitly stated otherwise all files in this repository are licensed under
@REM the Apache 2.0 License.
@REM
@REM This product includes software developed at Datadog
@REM (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%__DDTPL_PS_NAME__"
exit /b %ERRORLEVEL%
