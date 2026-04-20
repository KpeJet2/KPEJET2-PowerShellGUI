REM VersionTag: 2604.B2.V32.0
REM VersionBuildHistory:
REM   2604.B2.V32.0  2026-04-12  Script-only post-smoke routine wrapper
@echo off
setlocal

set "scriptDir=%~dp0"
set "PS_CMD=powershell.exe"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 set "PS_CMD=pwsh.exe"

%PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%tests\Invoke-FileTypeFireUpAllEnginesRoutine.ps1" -FileType Script -WorkspacePath "%scriptDir:~0,-1%" -Limit 10 -UseExitCode
exit /b %ERRORLEVEL%