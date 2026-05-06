REM VersionTag: 2604.B2.V31.1
REM VersionBuildHistory:
REM   2604.B2.V31.1  2026-04-12  Inject PSModulePath for all child PowerShell processes
REM   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 6 entries)
REM ============================================================
REM  Launch-GUI-slow_snr.bat  |  Full Checks Mode
REM  Author   : The Establishment
REM  Version  : 2603.B0.v27.0
REM  Modified : 24 Mar 2026
REM  Purpose  : Launches Main-GUI.ps1 -StartupMode slow_snr
REM             (full path validation, version check, and manifest
REM             generation before GUI appears).
REM             Falls back to powershell.exe if pwsh 7+ absent.
REM ============================================================
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "TASKTRAY_ARG="

REM ── Bootstrap: ensure PowerShellGUI modules are findable by all child PowerShell processes.
REM    Prepending to PSModulePath here means pwsh/powershell will inherit it immediately,
REM    without requiring Main-GUI.ps1 to have run first (solves first-launch & -NoProfile issue).
set "PSModulePath=%scriptDir%modules;%PSModulePath%"

REM --- Parse /TASKTRAY switch ---
for %%A in (%*) do (
    if /I "%%~A"=="/TASKTRAY" set "TASKTRAY_ARG=-TaskTray"
)

if not exist "%scriptDir%Main-GUI.ps1" (
    echo Error: Main-GUI.ps1 not found in %scriptDir%
    pause
    exit /b 1
)

cls
title PowerShellGUI - slow_snr
echo ============================================================
echo  Launch-GUI-slow_snr ^(Full Checks^)
echo ============================================================
echo.

if defined TASKTRAY_ARG (
    echo [MODE] TaskTray -- GUI will start minimized to system tray
    echo.
)

for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "pwshVersion=%%A"
if defined pwshVersion (
    echo [OK] PowerShell 7+ detected: Version !pwshVersion!
    echo Launching full checks mode...
    echo.
    echo ============================================================
    echo  DO NOT CLOSE THIS WINDOW -- GUI process is running.
    echo  This window will close automatically when GUI exits.
    echo ============================================================
    echo.
    if defined TASKTRAY_ARG (
        echo ***GUI-is-MINI-on-TASKTRAY***
        echo ##SEE TASK TRAY ICON##
        echo.
    )
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode slow_snr !TASKTRAY_ARG!
    goto end
)

echo [WARNING] PowerShell 7+ not found. Falling back to Windows PowerShell.
echo.
echo ============================================================
echo  DO NOT CLOSE THIS WINDOW -- GUI process is running.
echo  This window will close automatically when GUI exits.
echo ============================================================
echo.
if defined TASKTRAY_ARG (
    echo ***GUI-is-MINI-on-TASKTRAY***
    echo ##SEE TASK TRAY ICON##
    echo.
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode slow_snr !TASKTRAY_ARG!

:end
echo.
echo GUI process has ended.
endlocal









