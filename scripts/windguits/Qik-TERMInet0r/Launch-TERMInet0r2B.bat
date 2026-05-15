@echo off
REM VersionTag: 2605.B5.V46.0
REM Launch-TERMInet0r2B.bat — Launches Windguit_Qik-TERMInet0r2-B_TerminalLayoutManager.ps1
REM Requires: PowerShell 5.1, Windows Terminal, .NET WPF
setlocal

set "SCRIPT=%~dp0Windguit_Qik-TERMInet0r2-B_TerminalLayoutManager.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Script not found: %SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
if %ERRORLEVEL% neq 0 (
    echo Script exited with code %ERRORLEVEL%
    pause
)
endlocal
