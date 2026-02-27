@echo off
REM Diagnostic script for Windows
REM Run this to test BLE client and get detailed debug output

cd /d "%~dp0"
echo Running BLE diagnostic...
echo.

python diagnose.py

echo.
echo Press any key to exit...
pause >nul
