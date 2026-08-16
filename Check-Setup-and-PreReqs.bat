@echo off
chcp 65001 >nul
setlocal EnableExtensions
REM VersionTag: 2608.B1.V54.2
REM VersionBuildHistory:
REM   2608.B1.V54.2  2026-08-14  Added lowercase check, uppercase setup/upgrade selectors and ! master flow.
REM ==============================================================
REM  Check-Setup-and-PreReqs.bat
REM  Lowercase = check only
REM  Uppercase = setup/upgrade
REM  !         = master check/report then setup/upgrade and recheck
REM ==============================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "WS=%%~fI"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

if not exist "%WS%\scripts\Invoke-WorkspacePreReqs.ps1" (
    echo [ERROR] Prereq manager script not found:
    echo         %WS%\scripts\Invoke-WorkspacePreReqs.ps1
    exit /b 1
)

set "PS_EXE=pwsh.exe"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PS_EXE=powershell.exe"

if /I "%~1"=="/CHECK" goto CHECK_ALL
if /I "%~1"=="/SETUP" goto SETUP_ALL
if /I "%~1"=="/MASTER" goto MASTER

:MENU
cls
echo ============================================================================
echo   PowerShellGUI - Check Setup and PreReqs CLI
echo ============================================================================
echo   Workspace: %WS%
echo   Host     : %PS_EXE%
echo.
echo   [Windows runtimes]
echo     r  Check runtimes
echo     R  Setup/upgrade runtimes
echo.
echo   [Packages and CLI tools]
echo     p  Check packages
echo     P  Setup/upgrade packages
echo.
echo   [PowerShell modules]
echo     m  Check modules
echo     M  Setup/upgrade modules
echo.
echo   [Galleries and repositories]
echo     g  Check galleries/repositories
echo     G  Setup/upgrade galleries/repositories
echo.
echo   [Windows features]
echo     f  Check Sandbox and VM features
echo     F  Setup/upgrade Sandbox and VM features
echo.
echo   [Environment wiring]
echo     e  Check environment setup
echo     E  Setup environment wiring
echo.
echo   [Global]
echo     a  Check all prerequisites + report
echo     A  Setup/upgrade all prerequisites
echo     !  MASTER check report then setup/upgrade


echo   q  Exit
echo ============================================================================
set "OPT="
setlocal DisableDelayedExpansion
set /p "OPT=Select option: "
endlocal & set "OPT=%OPT%"
if "%OPT%"=="" goto MENU

if /I "%OPT%"=="q" exit /b 0
if "%OPT%"=="r" set "RUN_ACTION=CheckRuntimes" & goto RUN_ACTION_MENU
if "%OPT%"=="R" set "RUN_ACTION=SetupRuntimes" & goto RUN_ACTION_MENU
if "%OPT%"=="p" set "RUN_ACTION=CheckPackages" & goto RUN_ACTION_MENU
if "%OPT%"=="P" set "RUN_ACTION=SetupPackages" & goto RUN_ACTION_MENU
if "%OPT%"=="m" set "RUN_ACTION=CheckModules" & goto RUN_ACTION_MENU
if "%OPT%"=="M" set "RUN_ACTION=SetupModules" & goto RUN_ACTION_MENU
if "%OPT%"=="g" set "RUN_ACTION=CheckRepositories" & goto RUN_ACTION_MENU
if "%OPT%"=="G" set "RUN_ACTION=SetupRepositories" & goto RUN_ACTION_MENU
if "%OPT%"=="f" set "RUN_ACTION=CheckFeatures" & goto RUN_ACTION_MENU
if "%OPT%"=="F" set "RUN_ACTION=SetupFeatures" & goto RUN_ACTION_MENU
if "%OPT%"=="e" set "RUN_ACTION=CheckEnvironment" & goto RUN_ACTION_MENU
if "%OPT%"=="E" set "RUN_ACTION=SetupEnvironment" & goto RUN_ACTION_MENU
if "%OPT%"=="a" set "RUN_ACTION=CheckAll" & goto RUN_ACTION_MENU
if "%OPT%"=="A" set "RUN_ACTION=SetupAll" & goto RUN_ACTION_MENU
if "%OPT%"=="!" set "RUN_ACTION=Master" & goto RUN_ACTION_MENU

echo [WARN] Unknown option: %OPT%
pause
goto MENU

:CHECK_ALL
set "RUN_ACTION=CheckAll"
goto RUN_ACTION_DIRECT

:SETUP_ALL
set "RUN_ACTION=SetupAll"
goto RUN_ACTION_DIRECT

:MASTER
set "RUN_ACTION=Master"
goto RUN_ACTION_DIRECT

:RUN_ACTION_MENU
call :RunAction "%RUN_ACTION%"
set "RC=%ERRORLEVEL%"
echo.
echo [INFO] Action finished with exit code %RC%.
pause
goto MENU

:RUN_ACTION_DIRECT
call :RunAction "%RUN_ACTION%"
exit /b %ERRORLEVEL%

:RunAction
set "ACTION_NAME=%~1"
echo.
echo [RUN] %ACTION_NAME%
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-WorkspacePreReqs.ps1" -WorkspacePath "%WS%" -Action %ACTION_NAME%
exit /b %ERRORLEVEL%
