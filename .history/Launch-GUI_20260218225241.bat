# VersionTag: 2602.a.10
REM VersionTag: 2602.a.9
REM VersionTag: 2602.a.8
REM VersionTag: 2602.a.7
@echo off
REM Quick launcher for PowerShell GUI Application
REM This batch file enables proper execution of the PowerShell GUI script

setlocal enabledelayedexpansion

REM Get the directory where this batch file is located
set "scriptDir=%~dp0"

REM Check if the main GUI script exists
if not exist "%scriptDir%Main-GUI.ps1" (
    echo Error: Main-GUI.ps1 not found in %scriptDir%
    echo Please ensure Main-GUI.ps1 is in the same directory as this launcher.
    pause
    exit /b 1
)

cls
echo ============================================================
echo  PowerShell GUI Application Launcher
echo ============================================================
echo.

REM Check PowerShell versions and display to user
echo Checking PowerShell versions...
echo.

REM Check for PWSH7 (PowerShell 7+)
for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "pwshVersion=%%A"

if defined pwshVersion (
    echo [OK] PowerShell 7+ detected: Version %pwshVersion%
    echo.
    echo Launching PowerShell GUI...
    echo.
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1"
    goto end
)

REM Check for legacy PowerShell 5 or lower
for /f "tokens=*" %%A in ('powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "psVersion=%%A"

if defined psVersion (
    echo [WARNING] PowerShell !psVersion! detected - PWSH7 ^(PowerShell 7+^) not found
) else (
    echo [WARNING] PowerShell 5 or lower detected - PWSH7 ^(PowerShell 7+^) not found
)

echo.
echo ============================================================
echo  PWSH7 INSTALLATION REQUIRED
echo ============================================================
echo.
echo PowerShell 7+ is required for optimal performance.
echo You can install it using Windows Package Manager ^(winget^).
echo.
echo Press 'P' within 7 seconds to install PowerShell 7 as admin,
echo or press any other key to continue anyway.
echo.

REM 7 second timeout with choice command
choice /C PN /N /T 7 /D N /M "Press P to install, or wait 7 seconds to continue: "
set "userChoice=!errorlevel!"

REM errorlevel 1 = P pressed, errorlevel 2 = N pressed or timeout
if !userChoice! EQU 1 (
    echo.
    echo Installing PowerShell 7+...
    echo Please wait, this may take a few minutes...
    echo.
    powershell -Command "Start-Process cmd -ArgumentList '/c winget install powershell.powershell' -Verb RunAs -Wait"
    echo.
    echo Installation complete. Launching PowerShell GUI...
    echo.
    timeout /t 2 /nobreak
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1"
    goto end
)

echo.
echo Continuing with PowerShell 5...
echo Note: Some features may not work as expected.
echo.
timeout /t 2 /nobreak
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1"

:end
endlocal












