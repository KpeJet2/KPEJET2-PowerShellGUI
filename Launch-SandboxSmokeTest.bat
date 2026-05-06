# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
@echo off
REM  Launch-SandboxSmokeTest.bat -- Run smoke test inside Windows Sandbox
REM  Isolated environment for hyper-extended testing. Requires Windows
REM  Sandbox feature (Pro/Enterprise only).
title PwShGUI Sandbox Smoke Test
echo.
echo ============================================================
echo   PwShGUI Windows Sandbox Smoke Test Launcher
echo ============================================================
echo.

REM Check if WindowsSandbox.exe exists
where WindowsSandbox.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%SystemRoot%\System32\WindowsSandbox.exe" (
        echo [FAIL] Windows Sandbox not found.
        echo        Enable via: Settings - Apps - Optional Features - More Windows Features
        echo        Requires Windows 10/11 Pro or Enterprise.
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
echo Select test mode:
echo   1. Headless smoke test only
echo   2. Headless smoke test + chaos conditions
echo   3. Full smoke test + chaos (keep sandbox open)
echo.
set /p CHOICE="Choice [1-3]: "

if "%CHOICE%"=="1" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-SandboxSmokeTest.ps1" -HeadlessOnly -SkipPS7Install
) else if "%CHOICE%"=="2" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-SandboxSmokeTest.ps1" -HeadlessOnly -ChaosMode -SkipPS7Install
) else if "%CHOICE%"=="3" (
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-SandboxSmokeTest.ps1" -ChaosMode -KeepSandbox -SkipPS7Install
) else (
    echo Invalid choice. Running default: headless only.
    %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-SandboxSmokeTest.ps1" -HeadlessOnly -SkipPS7Install
)

echo.
echo Exit code: %ERRORLEVEL%
pause
