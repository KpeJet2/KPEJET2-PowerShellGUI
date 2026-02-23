# VersionTag: 2602.a.11
REM VersionTag: 2602.a.11
REM ============================================================
REM  Launch-GUI-BUILD-VER.bat  |  Build / Version Mode
REM  Author   : The Establishment
REM  Version  : 2602.a.11
REM  Modified : 22 Feb 2026
REM  Purpose  : Launches Main-GUI.ps1 in quik_jnr mode for
REM             build and version-tag update operations.
REM             Falls back to powershell.exe if pwsh 7+ absent.
REM ============================================================
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"

if not exist "%scriptDir%Main-GUI.ps1" (
    echo Error: Main-GUI.ps1 not found in %scriptDir%
    pause
    exit /b 1
)

cls
echo ============================================================
echo  Launch-GUI-BUILD-VER ^(Build Version Mode^)
echo ============================================================
echo.

for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "pwshVersion=%%A"
if defined pwshVersion (
    echo [OK] PowerShell 7+ detected: Version !pwshVersion!
    echo Launching build version mode...
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode quik_jnr
    goto end
)

echo [WARNING] PowerShell 7+ not found. Falling back to Windows PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode quik_jnr

:end
endlocal


