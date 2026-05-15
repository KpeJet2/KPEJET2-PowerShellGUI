# VersionTag: 2605.B5.V46.0
@echo off
REM ============================================================
REM  Launch-SandboxInteractive.bat -- Interactive iterative GUI
REM  testing inside Windows Sandbox with total system isolation.
REM  Author   : The Establishment
REM  Version  : 2604.B2.V31.0
REM  Requires : Windows 10/11 Pro/Enterprise, Sandbox enabled
REM ============================================================
title PwShGUI Interactive Sandbox
echo.
echo ============================================================
echo   PwShGUI Interactive Sandbox Test Environment
echo   Total system isolation with iterative GUI testing
echo ============================================================
echo.

REM Check if WindowsSandbox.exe exists
where WindowsSandbox.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%SystemRoot%\System32\WindowsSandbox.exe" (
        echo [FAIL] Windows Sandbox not found.
        echo        Enable via: Settings ^> Apps ^> Optional Features ^> More Windows Features
        echo        Requires Windows 10/11 Pro or Enterprise.
        echo.
        pause
        exit /b 1
    )
)

REM Detect PowerShell 7
set PS_CMD=powershell.exe
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] PowerShell 7 detected -- using pwsh.exe
    set PS_CMD=pwsh.exe
) else (
    echo [INFO] Using PowerShell 5.1
)

echo.
echo Select mode:
echo   1. Launch sandbox (isolated, no network)
echo   2. Launch sandbox + auto-open GUI
echo   3. Launch sandbox with networking enabled
echo   4. Launch sandbox + GUI + networking
echo.
set /p CHOICE="Choice [1-4]: "

if "%CHOICE%"=="1" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\sandbox\Start-InteractiveSandbox.ps1"
) else if "%CHOICE%"=="2" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\sandbox\Start-InteractiveSandbox.ps1" -AutoLaunchGUI
) else if "%CHOICE%"=="3" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\sandbox\Start-InteractiveSandbox.ps1" -Networking Enable
) else if "%CHOICE%"=="4" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\sandbox\Start-InteractiveSandbox.ps1" -AutoLaunchGUI -Networking Enable
) else (
    echo Invalid choice. Running default: isolated, no network.
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\sandbox\Start-InteractiveSandbox.ps1"
)

echo.
echo ============================================================
echo   Sandbox session ended.
echo   Use Send-SandboxCommand.ps1 to iterate while sandbox runs.
echo ============================================================
echo.
pause

