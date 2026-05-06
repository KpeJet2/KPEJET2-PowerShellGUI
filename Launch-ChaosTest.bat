# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
@echo off
REM  Launch-ChaosTest.bat -- Run chaos test conditions (headless)
REM  Applies all 12 chaos conditions against a staged workspace copy,
REM  then runs the smoke test against the mutated copy.
title PwShGUI Chaos Test
echo.
echo ============================================================
echo   PwShGUI Chaos Test Launcher
echo ============================================================
echo.

REM Detect PowerShell 7
set PS_CMD=powershell.exe
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] PowerShell 7 detected -- using pwsh.exe
    set PS_CMD=pwsh.exe
) else (
    echo [INFO] Using PowerShell 5.1
)

%PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-ChaosTestConditions.ps1" -RunSmokeTest -HeadlessOnly

echo.
echo Exit code: %ERRORLEVEL%
pause
