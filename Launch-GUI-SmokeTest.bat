REM VersionTag: 2608.B1.V54.2
REM VersionBuildHistory:
REM   2608.B1.V54.2  2026-08-04  Fixed batch header parsing noise and added resilient smoke script path fallback.
REM   2604.B2.V31.0  2026-04-12  Added /HEADLESSONLY, /NOPAUSE, and final FireUpAllEngines chain step
REM   2603.B0.V27.0  2026-03-24 03:28  (deduplicated from 4 entries)
REM Show-Objectives: Run dual-engine smoke quickly, preserve fallback behavior, and keep final engine-chain invocation optional.
REM ============================================================
REM  Launch-GUI-SmokeTest.bat  |  Automated GUI Smoke Test
REM  Author   : The Establishment
REM  Version  : 2603.B0.V27.0
REM  Modified : 24 Mar 2026
REM  Purpose  : Launches Invoke-GUISmokeTest.ps1 which exercises
REM             every menu, button and dialog in Main-GUI.ps1
REM             using UI Automation, then logs pass/fail results.
REM             Falls back to powershell.exe if pwsh 7+ absent.
REM ============================================================
REM Outline: Host-detect -> run shell-matrix smoke -> optionally invoke engine-chain -> return consolidated exit code.
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "TASKTRAY_ARG="
set "HEADLESS_ARG="
set "NO_PAUSE=FALSE"
set "RUN_ENGINE_BATCH=TRUE"
set "ENGINE_BATCH=%scriptDir%SmokeTest-Batch-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose.bat"
set "SMOKE_SCRIPT=%scriptDir%tests\Invoke-GUISmokeTest.ps1"
set "SMOKE_SCRIPT_FALLBACK=%scriptDir%~ARCHIVED\orphaned-cleanup-20260709\Invoke-GUISmokeTest.ps1"

REM --- Parse switches ---
REM /TASKTRAY kept for compatibility; smoke harness does not consume it directly.
REM /HEADLESSONLY runs phase-0-only smoke validation.
REM /NOPAUSE closes without keypress prompt.
REM /NOENGINES skips final FireUpAllEngines batch chain.
for %%A in (%*) do (
    if /I "%%~A"=="/TASKTRAY" set "TASKTRAY_ARG=-TaskTray"
    if /I "%%~A"=="/HEADLESSONLY" set "HEADLESS_ARG=-HeadlessOnly"
    if /I "%%~A"=="/NOPAUSE" set "NO_PAUSE=TRUE"
    if /I "%%~A"=="/NOENGINES" set "RUN_ENGINE_BATCH=FALSE"
)

if not exist "%SMOKE_SCRIPT%" (
    if exist "%SMOKE_SCRIPT_FALLBACK%" (
        set "SMOKE_SCRIPT=%SMOKE_SCRIPT_FALLBACK%"
        echo [WARN] tests\Invoke-GUISmokeTest.ps1 not found; using archived fallback.
        echo [WARN] Fallback: %SMOKE_SCRIPT_FALLBACK%
    ) else (
        echo Error: Invoke-GUISmokeTest.ps1 not found in tests or fallback archive.
        if /I not "!NO_PAUSE!"=="TRUE" pause
        exit /b 1
    )
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
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SMOKE_SCRIPT%" -RunShellMatrix !HEADLESS_ARG!
    set "exitCode=!errorlevel!"
    goto end
)

echo [WARNING] PowerShell 7+ not found. Falling back to Windows PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SMOKE_SCRIPT%" -RunShellMatrix !HEADLESS_ARG!
set "exitCode=!errorlevel!"

:end
echo.
if "!exitCode!"=="0" (
    echo Smoke test complete: ALL PASSED.
    if /I "!RUN_ENGINE_BATCH!"=="TRUE" (
        if exist "!ENGINE_BATCH!" (
            echo.
            echo Running final chain step: FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose
            call "!ENGINE_BATCH!" /NOPAUSE
            set "engineExit=!errorlevel!"
            if not "!engineExit!"=="0" (
                echo Final chain step reported failures: !engineExit!
                set "exitCode=!engineExit!"
            )
        ) else (
            echo Final chain step not found: !ENGINE_BATCH!
        )
    )
) else (
    echo Smoke test complete: EXIT CODE !exitCode! -- some tests may have failed.
)
if /I not "!NO_PAUSE!"=="TRUE" (
    echo Press any key to close.
    pause >nul
)
exit /b !exitCode!









