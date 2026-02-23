# VersionTag: 2602.a.10
REM VersionTag: 2602.a.9
REM VersionTag: 2602.a.8
REM VersionTag: 2602.a.7
@echo off
REM Loader launcher for PowerShell GUI Application modes

setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "quickLauncher=%scriptDir%Launch-GUI-quick_jnr.bat"
set "slowLauncher=%scriptDir%Launch-GUI-slow_snr.bat"

if not exist "%quickLauncher%" (
    echo Error: Launch-GUI-quick_jnr.bat not found in %scriptDir%
    pause
    exit /b 1
)

if not exist "%slowLauncher%" (
    echo Error: Launch-GUI-slow_snr.bat not found in %scriptDir%
    pause
    exit /b 1
)

cls
echo ============================================================
echo  PowerShell GUI Application Loader
echo ============================================================
echo.
echo Select startup profile:
echo.
echo  1^) Launch-GUI-quick_jnr  ^(fast startup mode^)
echo  2^) Launch-GUI-slow_snr   ^(full checks mode^)
echo.
echo Default in 7 seconds: 1 ^(quick_jnr^)
echo.

choice /C 12 /N /T 7 /D 1 /M "Press 1 for quick_jnr or 2 for slow_snr: "
set "launcherChoice=!errorlevel!"

if "!launcherChoice!"=="2" (
    call "%slowLauncher%"
) else (
    call "%quickLauncher%"
)

:end
endlocal












