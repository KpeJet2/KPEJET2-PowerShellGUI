# VersionTag: 2602.a.10
REM VersionTag: 2602.a.9
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
echo  Launch-GUI-BUILD- ^(Fast Startup^)
echo ============================================================
echo.

for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "pwshVersion=%%A"
if defined pwshVersion (
    echo [OK] PowerShell 7+ detected: Version !pwshVersion!
    echo Launching fast startup mode...
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode quick_jnr
    goto end
)

echo [WARNING] PowerShell 7+ not found. Falling back to Windows PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%Main-GUI.ps1" -StartupMode quick_jnr

:end
endlocal

