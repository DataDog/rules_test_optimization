"""Batch launcher template for dd_payload_uploader."""

UPLOADER_BATCH_TEMPLATE = """@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%{ps_name}"
exit /b %ERRORLEVEL%
"""
