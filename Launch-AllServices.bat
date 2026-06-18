@echo off
REM VersionTag: 2605.B5.V51.2
REM VersionBuildHistory:
REM   2605.B5.V51.2  2026-05-25  Created: unified all-services launcher (8042, 8099, 2x CronProcessor, tray)
REM ==============================================================
REM  Launch-AllServices.bat
REM  One-click launcher for ALL core services + tray bootstraps:
REM    1. Port 8099  Service Cluster Dashboard (Python/uvicorn)
REM    2. Port 8042  Local Web Engine (PS HttpListener) + Tray
REM    3. 2x         CronAiAthon pipeline processors
REM    4. (Optional) CronAiAthon WinForms GUI dashboard
REM
REM  The 8042 tray is preloaded with all service entries
REM  (8099, EngineBootstrap, EngineMonitor, 2x CronProcessor)
REM  and polls their live running state every 20 seconds.
REM
REM  Usage: Launch-AllServices.bat [notray] [nocron] [gui] [help]
REM  Flags (any order, space-separated):
REM    notray   Skip the tray icon (run engine only, no blocking tray)
REM    nocron   Skip both CronAiAthon processor instances
REM    gui      Also open the CronAiAthon WinForms dashboard
REM    help     Show this help and exit
REM
REM  Examples:
REM    Launch-AllServices.bat                 -- full stack + tray
REM    Launch-AllServices.bat notray          -- headless, no tray
REM    Launch-AllServices.bat gui             -- full stack + GUI dashboard
REM    Launch-AllServices.bat nocron gui      -- skip processors, show GUI
REM ==============================================================

setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "WS=%%~fI"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

if not exist "%WS%\scripts" (
    echo [ERROR] Cannot resolve workspace root from launcher path "%SCRIPT_DIR%".
    exit /b 1
)

REM --- Flag defaults ---
set "DO_TRAY=1"
set "DO_CRON=1"
set "DO_GUI=0"

REM --- Parse args ---
for %%A in (%*) do (
    if /I "%%A"=="notray" set "DO_TRAY=0"
    if /I "%%A"=="nocron" set "DO_CRON=0"
    if /I "%%A"=="gui"    set "DO_GUI=1"
    if /I "%%A"=="help"   goto :Usage
    if /I "%%A"=="/?"     goto :Usage
)

REM --- Detect PowerShell host ---
set "PS_EXE=pwsh"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PS_EXE=powershell"
where %PS_EXE%.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Neither pwsh.exe nor powershell.exe found in PATH.
    exit /b 1
)

echo.
echo  ===================================================
echo   Launch-AllServices -- PwShGUI Service Stack
echo  ===================================================
echo   Workspace  : %WS%
echo   PS host    : %PS_EXE%
echo   Tray       : %DO_TRAY%
echo   CronProc   : %DO_CRON%
echo   GUI dash   : %DO_GUI%
echo  ---------------------------------------------------
echo.

REM --- Step 1: Clean stale session lock (no live PID owns it) ---
set "LOCK_FILE=%WS%\.pwshgui-session.lock"
if exist "%LOCK_FILE%" (
    for /f "usebackq tokens=*" %%L in ("%LOCK_FILE%") do set "LOCK_PID=%%L"
    if defined LOCK_PID (
        tasklist /FI "PID eq !LOCK_PID!" 2>nul | find "!LOCK_PID!" >nul 2>&1
        if errorlevel 1 (
            echo [INFO] Removing stale session lock ^(PID !LOCK_PID! not found^).
            del /f /q "%LOCK_FILE%" >nul 2>&1
        ) else (
            echo [WARN] Session lock held by PID !LOCK_PID! -- Main GUI may already be active.
        )
    )
)

REM --- Step 2: Clear engine.stop signal if present (allows cron to run) ---
set "STOP_SIGNAL=%WS%\logs\engine.stop"
if exist "%STOP_SIGNAL%" (
    echo [INFO] Removing stale engine.stop signal.
    del /f /q "%STOP_SIGNAL%" >nul 2>&1
)

REM --- Step 3: Start Port 8099 Service Cluster Dashboard (Python/uvicorn, hidden) ---
set "DASHBOARD_BAT=%WS%\scripts\service-cluster-dashboard\Launch-ServiceClusterDashboard.bat"
if exist "%DASHBOARD_BAT%" (
    echo [START] Port 8099 Service Cluster Dashboard...
    start "SvcDash8099" /min cmd /c ""%DASHBOARD_BAT%""
    echo [OK]    Dashboard started in background.
) else (
    echo [WARN]  Dashboard bat not found: %DASHBOARD_BAT%
    echo         Port 8099 service will not be started.
)

REM --- Step 4: Start CronAiAthon pipeline processors (background, hidden) ---
set "CRON_SCRIPT=%WS%\scripts\Invoke-CronProcessor.ps1"
if "%DO_CRON%"=="1" (
    if exist "%CRON_SCRIPT%" (
        echo [START] CronAiAthon processor ^#1...
        start "CronProc1" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CRON_SCRIPT%" -WorkspacePath "%WS%"
        echo [OK]    Processor #1 started.

        REM Small gap so both instances get distinct start timestamps in logs
        timeout /t 2 /nobreak >nul

        echo [START] CronAiAthon processor ^#2...
        start "CronProc2" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CRON_SCRIPT%" -WorkspacePath "%WS%"
        echo [OK]    Processor #2 started.
    ) else (
        echo [WARN]  CronProcessor not found: %CRON_SCRIPT%
        echo         CronAiAthon pipelines will not run.
    )
) else (
    echo [SKIP]  CronAiAthon processors ^(nocron flag set^).
)

REM --- Step 5: (Optional) Open CronAiAthon WinForms GUI dashboard ---
set "CRON_GUI=%WS%\scripts\Show-CronAiAthonTool.ps1"
if "%DO_GUI%"=="1" (
    if exist "%CRON_GUI%" (
        echo [START] CronAiAthon GUI dashboard...
        start "CronAiAthonGUI" %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%CRON_GUI%" -WorkspacePath "%WS%"
        echo [OK]    CronAiAthon GUI launched.
    ) else (
        echo [WARN]  CronAiAthon GUI not found: %CRON_GUI%
    )
)

REM --- Step 6: Start Port 8042 Local Web Engine + Tray (foreground -- holds console) ---
REM  -Action Start  => starts the engine in a hidden background process, then
REM                    runs Start-ServiceTray (blocking WinForms message pump).
REM  The tray preloads ALL 5 service entries from Get-TrayServiceDefinitions:
REM    ServiceClusterDashboard  (8099 Python service)
REM    EngineBootstrap          (Start-Engines.ps1)
REM    Start-EngineServiceMonitor
REM    Invoke-CronProcessor #1
REM    Invoke-CronProcessor #2
REM  Each entry is checked live every 20 s and shows a tick when running.
set "ENGINE_SERVICE=%WS%\scripts\Start-LocalWebEngineService.ps1"
if not exist "%ENGINE_SERVICE%" (
    echo [ERROR] Engine service script not found: %ENGINE_SERVICE%
    exit /b 1
)

echo.
if "%DO_TRAY%"=="1" (
    echo [START] Port 8042 Local Web Engine + Task Tray ^(this console will block while tray is open^)...
    echo         Close the tray icon or press Ctrl+C here to stop.
    echo.
    %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%ENGINE_SERVICE%" -Action Start -Port 8042 -WorkspacePath "%WS%"
) else (
    echo [START] Port 8042 Local Web Engine ^(no tray, background^)...
    start "WebEngine8042" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%ENGINE_SERVICE%" -Action Start -Port 8042 -WorkspacePath "%WS%" -NoTray
    echo [OK]    Engine started headless. Use Status action or logs to monitor.
    echo.
    echo  All services started. Console can be closed.
)

endlocal
exit /b 0

:Usage
echo.
echo  Launch-AllServices.bat [flags]
echo.
echo  Starts the full PwShGUI service stack in the correct order:
echo    1. Port 8099  Service Cluster Dashboard ^(Python/uvicorn, hidden^)
echo    2. 2x         CronAiAthon pipeline processor instances ^(hidden^)
echo    3. Port 8042  Local Web Engine + Task Tray
echo         Tray preloads all services; polls running state every 20 s.
echo.
echo  Flags ^(any order^):
echo    notray   Skip tray; start engine headless in background
echo    nocron   Skip both CronAiAthon processor instances
echo    gui      Also open the CronAiAthon WinForms GUI dashboard
echo    help     Show this help
echo.
echo  Examples:
echo    Launch-AllServices.bat
echo    Launch-AllServices.bat notray
echo    Launch-AllServices.bat gui
echo    Launch-AllServices.bat nocron gui
echo.
endlocal
exit /b 0
