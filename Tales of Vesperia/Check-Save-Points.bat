@echo off
rem Keep the matching Read-Save-Points.ps1 beside this read-only launcher.
setlocal DisableDelayedExpansion
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto missingPowerShell
if not exist "%~dp0Read-Save-Points.ps1" goto missingReader
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Read-Save-Points.ps1"
set "vesperiaExitCode=%ERRORLEVEL%"
goto finish
:missingPowerShell
echo Windows PowerShell could not be found.
set "vesperiaExitCode=1"
goto finish
:missingReader
echo Keep Read-Save-Points.ps1 in the same folder as this launcher.
set "vesperiaExitCode=1"
:finish
echo(
if /I not "%~1"=="--no-pause" pause
exit /b %vesperiaExitCode%
