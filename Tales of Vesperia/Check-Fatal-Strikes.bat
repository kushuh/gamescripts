@echo off
rem Keep the matching Read-Fatal-Strikes.ps1 beside this read-only launcher.
rem The script path is relative to this file, not the terminal's folder.
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Read-Fatal-Strikes.ps1"
set "vesperiaExitCode=%ERRORLEVEL%"
echo(
if /I not "%~1"=="--no-pause" pause
exit /b %vesperiaExitCode%
