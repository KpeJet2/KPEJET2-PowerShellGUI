# VersionTag: 2604.B0.v1
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries)
REM ============================================================
REM  Launch-GUI-SmokeTest.bat  |  Automated GUI Smoke Test
REM  Author   : The Establishment
REM  Version  : 2603.B0.v27.0
REM  Modified : 24 Mar 2026
REM  Purpose  : Launches Invoke-GUISmokeTest.ps1 which exercises
REM             every menu, button and dialog in Main-GUI.ps1
REM             using UI Automation, then logs pass/fail results.
REM             Falls back to powershell.exe if pwsh 7+ absent.
REM ============================================================
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "TASKTRAY_ARG="

REM --- Parse /TASKTRAY switch ---
for %%A in (%*) do (
    if /I "%%~A"=="/TASKTRAY" set "TASKTRAY_ARG=-TaskTray"
)

if not exist "%scriptDir%tests\Invoke-GUISmokeTest.ps1" (
    echo Error: tests\Invoke-GUISmokeTest.ps1 not found in %scriptDir%
    pause
    exit /b 1
)

cls
echo ============================================================
echo  GUI Smoke Test  ^| Automated Function Walkthrough
echo ============================================================
echo  Mode: Shell matrix ^(PowerShell 5.1 + PowerShell 7 where available^)
echo.

for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "pwshVersion=%%A"
if defined pwshVersion (
    echo [OK] PowerShell 7+ detected: Version !pwshVersion!
    echo Launching smoke test matrix...
    echo.
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%tests\Invoke-GUISmokeTest.ps1" -RunShellMatrix
    set "exitCode=!errorlevel!"
    goto end
)

echo [WARNING] PowerShell 7+ not found. Falling back to Windows PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%tests\Invoke-GUISmokeTest.ps1" -RunShellMatrix
set "exitCode=!errorlevel!"

:end
echo.
if "!exitCode!"=="0" (
    echo Smoke test complete: ALL PASSED.
) else (
    echo Smoke test complete: EXIT CODE !exitCode! -- some tests may have failed.
)
echo Press any key to close.
pause >nul
exit /b !exitCode!






