@echo off
REM VersionTag: 2605.B5.V51.2
REM VersionBuildHistory:
REM   2605.B5.V51.2  2026-05-25  Created: unified all-services launcher (8042, 8099, 2x CronProcessor, tray)
REM ==============================================================
REM  Launch-AllServices.bat
REM  One-click launcher for ALL core services + tray bootstraps.
REM
REM  Interactive mode (default):
REM    - Shows launch elements with checkbox-style toggles
REM    - Lets user test selected elements one-by-one
REM    - Lets user launch selected elements
REM
REM  Automation mode:
REM    Launch-AllServices.bat /AUTO [notray] [nocron] [gui]
REM
REM  Legacy flags (still supported in all modes):
REM    notray   Skip tray icon (start engine headless)
REM    nocron   Skip both CronAiAthon processors
REM    gui      Also open CronAiAthon WinForms dashboard
REM    help     Show help and exit
REM ==============================================================

setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "WS=%%~fI"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

if not exist "%WS%\scripts" (
    echo [ERROR] Cannot resolve workspace root from launcher path "%SCRIPT_DIR%".
    exit /b 1
)

REM --- Runtime options ---
set "DO_TRAY=1"
set "DO_CRON=1"
set "DO_GUI=0"
set "MODE=INTERACTIVE"
set "STEP_MODE=RUN"
set "MENU_ACTION=RUN"

REM --- Step toggles ---
set "STEP1=1"
set "STEP2=1"
set "STEP3=1"
set "STEP4=1"
set "STEP5=1"
set "STEP6=1"

REM --- Parse args ---
for %%A in (%*) do (
    if /I "%%A"=="notray" set "DO_TRAY=0"
    if /I "%%A"=="nocron" set "DO_CRON=0"
    if /I "%%A"=="gui"    set "DO_GUI=1"
    if /I "%%A"=="/AUTO"  set "MODE=AUTO"
    if /I "%%A"=="/INTERACTIVE" set "MODE=INTERACTIVE"
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

if /I "%MODE%"=="INTERACTIVE" (
    call :ShowLoadScreen
    if /I "!MENU_ACTION!"=="QUIT" (
        endlocal
        exit /b 0
    )
    if /I "!MENU_ACTION!"=="TEST" (
        set "STEP_MODE=TEST"
    ) else (
        set "STEP_MODE=RUN"
    )
)

echo.
echo  ===================================================
echo   Launch-AllServices -- PwShGUI Service Stack
echo  ===================================================
echo   Workspace  : %WS%
echo   PS host    : %PS_EXE%
echo   Mode       : %MODE%
echo   Step mode  : !STEP_MODE!
echo   Tray       : !DO_TRAY!
echo   CronProc   : !DO_CRON!
echo   GUI dash   : !DO_GUI!
echo  ---------------------------------------------------
echo.

call :RunSelectedSteps
set "FINAL_EXIT=%ERRORLEVEL%"

if /I "!STEP_MODE!"=="TEST" (
    echo [INFO] Test sequence complete. ExitCode=!FINAL_EXIT!
) else (
    echo [INFO] Launch sequence complete. ExitCode=!FINAL_EXIT!
)

endlocal
exit /b %FINAL_EXIT%

:ShowLoadScreen
:MenuLoop
cls
echo ============================================================
echo  Launch-AllServices CLI Load Screen
echo  Workspace: %WS%
echo ============================================================
echo  Launch elements:
call :RenderStep 1 "Clean stale session lock" STEP1
call :RenderStep 2 "Clear engine.stop signal" STEP2
call :RenderStep 3 "Start Service Cluster Dashboard (8099)" STEP3
call :RenderStep 4 "Start Cron processors (#1/#2)" STEP4
call :RenderStep 5 "Open CronAiAthon GUI dashboard" STEP5
call :RenderStep 6 "Start Local Web Engine service (8042)" STEP6
echo.
echo  Runtime options:
echo    [TRAY] !DO_TRAY!   [CRON] !DO_CRON!   [GUI] !DO_GUI!
echo.
echo  Commands:
echo    1-6 = toggle launch element
echo    R   = toggle tray option ^(notray^)
echo    C   = toggle cron option ^(nocron^)
echo    G   = toggle gui option
echo    A   = select all elements
echo    N   = clear all elements
echo    T   = test selected elements one-by-one
echo    L   = launch selected elements
echo    Q   = quit
echo.
set /p "MENU_CHOICE=Enter selection: "

if /I "!MENU_CHOICE!"=="1" call :Toggle STEP1 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="2" call :Toggle STEP2 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="3" call :Toggle STEP3 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="4" call :Toggle STEP4 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="5" call :Toggle STEP5 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="6" call :Toggle STEP6 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="R" call :ToggleOption DO_TRAY & goto :MenuLoop
if /I "!MENU_CHOICE!"=="C" call :ToggleOption DO_CRON & goto :MenuLoop
if /I "!MENU_CHOICE!"=="G" call :ToggleOption DO_GUI & goto :MenuLoop
if /I "!MENU_CHOICE!"=="A" call :SetAll 1 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="N" call :SetAll 0 & goto :MenuLoop
if /I "!MENU_CHOICE!"=="T" set "MENU_ACTION=TEST" & exit /b 0
if /I "!MENU_CHOICE!"=="L" set "MENU_ACTION=RUN" & exit /b 0
if /I "!MENU_CHOICE!"=="Q" set "MENU_ACTION=QUIT" & exit /b 0
goto :MenuLoop

:RenderStep
set "STEP_STATE=[ ]"
if /I "!%~3!"=="1" set "STEP_STATE=[X]"
echo    %~1. !STEP_STATE! %~2
exit /b 0

:Toggle
if /I "!%~1!"=="1" (
    set "%~1=0"
) else (
    set "%~1=1"
)
exit /b 0

:ToggleOption
if /I "!%~1!"=="1" (
    set "%~1=0"
) else (
    set "%~1=1"
)
exit /b 0

:SetAll
set "STEP1=%~1"
set "STEP2=%~1"
set "STEP3=%~1"
set "STEP4=%~1"
set "STEP5=%~1"
set "STEP6=%~1"
exit /b 0

:RunSelectedSteps
if "%STEP1%"=="1" call :ExecuteStep "Clean stale session lock" Step1_CleanSessionLock
if errorlevel 1 exit /b 1

if "%STEP2%"=="1" call :ExecuteStep "Clear engine.stop signal" Step2_ClearStopSignal
if errorlevel 1 exit /b 1

if "%STEP3%"=="1" call :ExecuteStep "Start Service Cluster Dashboard (8099)" Step3_StartDashboard
if errorlevel 1 exit /b 1

if "%STEP4%"=="1" call :ExecuteStep "Start Cron processors" Step4_StartCron
if errorlevel 1 exit /b 1

if "%STEP5%"=="1" call :ExecuteStep "Open CronAiAthon GUI dashboard" Step5_OpenGui
if errorlevel 1 exit /b 1

if "%STEP6%"=="1" call :ExecuteStep "Start Local Web Engine service (8042)" Step6_StartEngine
if errorlevel 1 exit /b 1

exit /b 0

:ExecuteStep
echo.
echo ------------------------------------------------------------
echo [!STEP_MODE!] %~1
echo ------------------------------------------------------------
call :%~2
set "STEP_RC=!ERRORLEVEL!"
if not "!STEP_RC!"=="0" (
    echo [ERROR] Step failed: %~1
    exit /b !STEP_RC!
)
if /I "!STEP_MODE!"=="TEST" (
    echo [PASS] Test passed: %~1
    set /p "_stepContinue=Press ENTER for next selected step..."
)
exit /b 0

:Step1_CleanSessionLock
set "LOCK_FILE=%WS%\.pwshgui-session.lock"
if not exist "%LOCK_FILE%" (
    echo [INFO] Session lock file not present.
    exit /b 0
)

for /f "usebackq tokens=*" %%L in ("%LOCK_FILE%") do set "LOCK_PID=%%L"
if not defined LOCK_PID (
    echo [WARN] Session lock exists but contains no PID.
    if /I "!STEP_MODE!"=="RUN" del /f /q "%LOCK_FILE%" >nul 2>&1
    exit /b 0
)

tasklist /FI "PID eq !LOCK_PID!" 2>nul | find "!LOCK_PID!" >nul 2>&1
if errorlevel 1 (
    echo [INFO] Stale session lock detected for PID !LOCK_PID!.
    if /I "!STEP_MODE!"=="RUN" (
        del /f /q "%LOCK_FILE%" >nul 2>&1
        echo [OK] Stale lock removed.
    )
) else (
    echo [WARN] Session lock held by active PID !LOCK_PID!.
)
exit /b 0

:Step2_ClearStopSignal
set "STOP_SIGNAL=%WS%\logs\engine.stop"
if not exist "%STOP_SIGNAL%" (
    echo [INFO] engine.stop signal not present.
    exit /b 0
)

echo [INFO] engine.stop signal detected.
if /I "!STEP_MODE!"=="RUN" (
    del /f /q "%STOP_SIGNAL%" >nul 2>&1
    echo [OK] engine.stop signal removed.
)
exit /b 0

:Step3_StartDashboard
set "DASHBOARD_BAT=%WS%\scripts\service-cluster-dashboard\Launch-ServiceClusterDashboard.bat"
if not exist "%DASHBOARD_BAT%" (
    echo [WARN] Dashboard launcher not found: %DASHBOARD_BAT%
    exit /b 0
)

if /I "!STEP_MODE!"=="TEST" (
    echo [INFO] Dashboard launcher ready: %DASHBOARD_BAT%
    echo [INFO] Health endpoint expected: http://127.0.0.1:8099/api/ping
    exit /b 0
)

echo [START] Port 8099 Service Cluster Dashboard...
start "SvcDash8099" /min cmd /c ""%DASHBOARD_BAT%" /AUTO"
echo [OK] Dashboard started in background.
exit /b 0

:Step4_StartCron
set "CRON_SCRIPT=%WS%\scripts\Invoke-CronProcessor.ps1"
if "%DO_CRON%"=="0" (
    echo [SKIP] Cron processors disabled by option.
    exit /b 0
)

if not exist "%CRON_SCRIPT%" (
    echo [WARN] CronProcessor not found: %CRON_SCRIPT%
    exit /b 0
)

if /I "!STEP_MODE!"=="TEST" (
    echo [INFO] Cron processor script ready: %CRON_SCRIPT%
    echo [INFO] Would launch 2 instances with -WorkspacePath "%WS%".
    exit /b 0
)

echo [START] CronAiAthon processor #1...
start "CronProc1" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CRON_SCRIPT%" -WorkspacePath "%WS%"
echo [OK] Processor #1 started.

timeout /t 2 /nobreak >nul

echo [START] CronAiAthon processor #2...
start "CronProc2" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CRON_SCRIPT%" -WorkspacePath "%WS%"
echo [OK] Processor #2 started.
exit /b 0

:Step5_OpenGui
set "CRON_GUI=%WS%\scripts\Show-CronAiAthonTool.ps1"
if "%DO_GUI%"=="0" (
    echo [SKIP] CronAiAthon GUI disabled by option.
    exit /b 0
)

if not exist "%CRON_GUI%" (
    echo [WARN] CronAiAthon GUI not found: %CRON_GUI%
    exit /b 0
)

if /I "!STEP_MODE!"=="TEST" (
    echo [INFO] CronAiAthon GUI script ready: %CRON_GUI%
    exit /b 0
)

echo [START] CronAiAthon GUI dashboard...
start "CronAiAthonGUI" %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%CRON_GUI%" -WorkspacePath "%WS%"
echo [OK] CronAiAthon GUI launched.
exit /b 0

:Step6_StartEngine
set "ENGINE_SERVICE=%WS%\scripts\Start-LocalWebEngineService.ps1"
if not exist "%ENGINE_SERVICE%" (
    echo [ERROR] Engine service script not found: %ENGINE_SERVICE%
    exit /b 1
)

if /I "!STEP_MODE!"=="TEST" (
    if "%DO_TRAY%"=="1" (
        echo [INFO] Would run foreground with tray:
        echo        %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%ENGINE_SERVICE%" -Action Start -Port 8042 -WorkspacePath "%WS%"
    ) else (
        echo [INFO] Would run headless background with -NoTray.
    )
    exit /b 0
)

echo.
if "%DO_TRAY%"=="1" (
    echo [START] Port 8042 Local Web Engine + Task Tray ^(foreground^)...
    echo         Close the tray icon or press Ctrl+C here to stop.
    %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%ENGINE_SERVICE%" -Action Start -Port 8042 -WorkspacePath "%WS%"
) else (
    echo [START] Port 8042 Local Web Engine ^(no tray, background^)...
    start "WebEngine8042" /min %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%ENGINE_SERVICE%" -Action Start -Port 8042 -WorkspacePath "%WS%" -NoTray
    echo [OK] Engine started headless.
)
exit /b 0

:Usage
echo.
echo Launch-AllServices.bat [flags]
echo.
echo Modes:
echo   (default)        Interactive load screen with selectable/testable elements
echo   /AUTO            Run selected defaults non-interactively
echo.
echo Flags (any order):
echo   notray           Skip tray; start engine headless in background
echo   nocron           Skip both CronAiAthon processor instances
echo   gui              Also open the CronAiAthon WinForms GUI dashboard
echo   /INTERACTIVE     Force interactive mode
echo   help or /?       Show this help
echo.
echo Examples:
echo   Launch-AllServices.bat
echo   Launch-AllServices.bat /AUTO
echo   Launch-AllServices.bat /AUTO notray nocron
echo   Launch-AllServices.bat /AUTO gui
endlocal
exit /b 0
