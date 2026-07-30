REM VersionTag: 2605.B5.V46.2
@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
set "WORKSPACE=%ROOT%..\.."
set "VENV=%WORKSPACE%\.venv"
set "PYTHON=%VENV%\Scripts\python.exe"
set "PIP=%VENV%\Scripts\pip.exe"
set "ENGINE_URL=http://127.0.0.1:8042/api/engine/status"
set "MONITOR_SCRIPT=%WORKSPACE%\scripts\Invoke-EngineServiceMonitor.ps1"
set "REQ_FILE=%ROOT%requirements.txt"
set "DASHBOARD_PORT=8099"

set "PWSH_EXE=pwsh.exe"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PWSH_EXE=powershell.exe"

set "STEP_VALIDATE_VENV=1"
set "STEP_ENGINE_CHECK=1"
set "STEP_ENGINE_RECOVERY=1"
set "STEP_INSTALL_DEPS=1"
set "STEP_TOKEN_NOTICE=1"
set "STEP_LAUNCH_SERVER=1"

set "MODE=INTERACTIVE"
if /I "%~1"=="/AUTO" set "MODE=AUTO"
if /I "%~1"=="/INTERACTIVE" set "MODE=INTERACTIVE"
if /I "%~1"=="/?" goto :Usage
if /I "%~1"=="-h" goto :Usage
if /I "%~1"=="--help" goto :Usage

if /I "%MODE%"=="AUTO" (
  set "STEP_MODE=RUN"
  call :RunSelectedSteps
  set "FINAL_EXITCODE=!ERRORLEVEL!"
  endlocal & exit /b %FINAL_EXITCODE%
)

call :ShowLoadScreen
if /I "!MENU_ACTION!"=="QUIT" (
  endlocal & exit /b 0
)

if /I "!MENU_ACTION!"=="TEST" (
  set "STEP_MODE=TEST"
) else (
  set "STEP_MODE=RUN"
)

call :RunSelectedSteps
set "FINAL_EXITCODE=!ERRORLEVEL!"
echo.
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] Test sequence completed. ExitCode=!FINAL_EXITCODE!
) else (
  echo [INFO] Launch sequence completed. ExitCode=!FINAL_EXITCODE!
)
endlocal & exit /b %FINAL_EXITCODE%

:ShowLoadScreen
set "MENU_ACTION=RUN"

:MenuLoop
cls
echo ============================================================
echo  Service Cluster Dashboard CLI Load Screen
echo  Workspace: %WORKSPACE%
echo  Dashboard Port: %DASHBOARD_PORT%
echo ============================================================
echo  Select launch elements:
call :RenderStep 1 "Validate Python virtual environment" STEP_VALIDATE_VENV
call :RenderStep 2 "Probe local web engine (8042)" STEP_ENGINE_CHECK
call :RenderStep 3 "Run engine auto-recovery when offline" STEP_ENGINE_RECOVERY
call :RenderStep 4 "Install dashboard dependencies" STEP_INSTALL_DEPS
call :RenderStep 5 "Check cluster token configuration" STEP_TOKEN_NOTICE
call :RenderStep 6 "Launch dashboard server (port 8099)" STEP_LAUNCH_SERVER
echo.
echo  Commands:
echo    1-6 = toggle item on/off
echo    A   = select all items
echo    N   = clear all items
echo    T   = test selected items one at a time
echo    L   = launch selected items
echo    Q   = quit
echo.
set /p "MENU_CHOICE=Enter selection: "

if /I "!MENU_CHOICE!"=="1" call :Toggle STEP_VALIDATE_VENV & goto :MenuLoop
if /I "!MENU_CHOICE!"=="2" call :Toggle STEP_ENGINE_CHECK & goto :MenuLoop
if /I "!MENU_CHOICE!"=="3" call :Toggle STEP_ENGINE_RECOVERY & goto :MenuLoop
if /I "!MENU_CHOICE!"=="4" call :Toggle STEP_INSTALL_DEPS & goto :MenuLoop
if /I "!MENU_CHOICE!"=="5" call :Toggle STEP_TOKEN_NOTICE & goto :MenuLoop
if /I "!MENU_CHOICE!"=="6" call :Toggle STEP_LAUNCH_SERVER & goto :MenuLoop
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

:SetAll
set "STEP_VALIDATE_VENV=%~1"
set "STEP_ENGINE_CHECK=%~1"
set "STEP_ENGINE_RECOVERY=%~1"
set "STEP_INSTALL_DEPS=%~1"
set "STEP_TOKEN_NOTICE=%~1"
set "STEP_LAUNCH_SERVER=%~1"
exit /b 0

:RunSelectedSteps
if /I "!STEP_VALIDATE_VENV!"=="1" call :ExecuteStep "Validate Python virtual environment" StepValidateVenv
if errorlevel 1 exit /b 1

if /I "!STEP_ENGINE_CHECK!"=="1" call :ExecuteStep "Probe local web engine" StepCheckEngine
if errorlevel 1 exit /b 1

if /I "!STEP_ENGINE_RECOVERY!"=="1" call :ExecuteStep "Run engine auto-recovery when offline" StepRecoverEngine
if errorlevel 1 exit /b 1

if /I "!STEP_INSTALL_DEPS!"=="1" call :ExecuteStep "Install dashboard dependencies" StepInstallDependencies
if errorlevel 1 exit /b 1

if /I "!STEP_TOKEN_NOTICE!"=="1" call :ExecuteStep "Check cluster token configuration" StepTokenNotice
if errorlevel 1 exit /b 1

if /I "!STEP_LAUNCH_SERVER!"=="1" call :ExecuteStep "Launch dashboard server" StepLaunchServer
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

:StepValidateVenv
if not exist "%PYTHON%" (
  echo [ERROR] Python virtual environment not found at "%VENV%".
  echo         Create it first: py -3 -m venv "%VENV%"
  exit /b 1
)
if not exist "%PIP%" (
  echo [ERROR] pip executable not found at "%PIP%".
  exit /b 1
)
if /I "!STEP_MODE!"=="TEST" (
  "%PYTHON%" --version
  "%PIP%" --version
)
exit /b 0

:StepCheckEngine
call :CheckEngine
if /I "!ENGINE_STATE!"=="ONLINE" (
  echo [OK] Local web engine is ONLINE at %ENGINE_URL%.
) else (
  echo [WARN] Local web engine appears OFFLINE at %ENGINE_URL%.
)
exit /b 0

:StepRecoverEngine
if /I "!ENGINE_STATE!"=="ONLINE" (
  echo [INFO] Engine recovery skipped: engine is already online.
  exit /b 0
)

if /I "!STEP_MODE!"=="TEST" (
  if exist "%MONITOR_SCRIPT%" (
    echo [OK] Recovery script available: "%MONITOR_SCRIPT%"
  ) else (
    echo [WARN] Recovery script missing: "%MONITOR_SCRIPT%"
  )
  exit /b 0
)

echo [WARN] Local web engine appears offline. Running engine monitor auto recovery...
if exist "%MONITOR_SCRIPT%" (
  start "EngineMonitorAuto" /min "%PWSH_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%MONITOR_SCRIPT%" /AUTO
  echo [INFO] Engine monitor launched in background; dashboard startup will continue.
) else (
  echo [WARN] Engine monitor script not found at "%MONITOR_SCRIPT%".
  exit /b 0
)

set /a OFFLINE_STREAK=0
for /L %%I in (1,1,4) do (
  timeout /t 2 /nobreak >nul
  call :CheckEngine
  if /I "!ENGINE_STATE!"=="ONLINE" goto :RecoverDone
  set /a OFFLINE_STREAK+=1
)

:RecoverDone
if !OFFLINE_STREAK! GEQ 4 (
  echo [WARN] Engine remained offline for multiple heartbeats; launching dashboard anyway.
) else (
  echo [OK] Engine recovered and is online.
)
exit /b 0

:StepInstallDependencies
if not exist "%REQ_FILE%" (
  echo [ERROR] Requirements file not found: "%REQ_FILE%"
  exit /b 1
)

"%PYTHON%" -c "import fastapi, uvicorn" >nul 2>&1
if not errorlevel 1 (
  echo [INFO] Dashboard dependencies already available; skipping pip install.
  exit /b 0
)

if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] requirements.txt found: "%REQ_FILE%"
  "%PIP%" --version >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] Unable to run pip from "%PIP%".
    exit /b 1
  )
  echo [OK] pip is available for dependency install.
  exit /b 0
)

if /I "%MODE%"=="AUTO" (
  echo [WARN] AUTO mode: skipping pip install to avoid blocking startup.
  echo [WARN] If startup fails due missing modules, run launcher interactively and test/install dependencies.
  exit /b 0
)

echo [INFO] Installing dashboard dependencies...
"%PIP%" install -r "%REQ_FILE%"
if errorlevel 1 (
  echo [ERROR] Failed to install requirements.
  exit /b 1
)
exit /b 0

:StepTokenNotice
if "%PWSHGUI_CLUSTER_TOKEN%"=="" (
  echo [WARN] PWSHGUI_CLUSTER_TOKEN not set. server.py will use/create cluster.token.
) else (
  echo [OK] PWSHGUI_CLUSTER_TOKEN detected.
)
exit /b 0

:StepLaunchServer
set "APPDIR=%ROOT%"
if "%APPDIR:~-1%"=="\" set "APPDIR=%APPDIR:~0,-1%"

if /I "!STEP_MODE!"=="TEST" (
  if not exist "%APPDIR%\server.py" (
    echo [ERROR] Dashboard entrypoint not found: "%APPDIR%\server.py"
    exit /b 1
  )
  echo [OK] Dashboard entrypoint found: "%APPDIR%\server.py"
  echo [INFO] Health endpoint after launch: http://127.0.0.1:%DASHBOARD_PORT%/api/ping
  exit /b 0
)

echo [INFO] Launching Service Cluster Dashboard...
pushd "%APPDIR%"
"%PYTHON%" "%APPDIR%\server.py"
set "DASHBOARD_EXIT=!ERRORLEVEL!"
popd
exit /b !DASHBOARD_EXIT!

:CheckEngine
set "ENGINE_STATE=OFFLINE"
"%PWSH_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$u='%ENGINE_URL%'; try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if($r.StatusCode -ge 200 -and $r.StatusCode -lt 500){ exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 set "ENGINE_STATE=ONLINE"
exit /b 0

:Usage
echo Launch-ServiceClusterDashboard.bat usage:
echo.
echo   Launch-ServiceClusterDashboard.bat
echo      Interactive CLI load screen. Toggle elements, test one-by-one, then launch.
echo.
echo   Launch-ServiceClusterDashboard.bat /AUTO
echo      Non-interactive launch path for automation and background runners.
echo.
echo   Launch-ServiceClusterDashboard.bat /INTERACTIVE
echo      Force interactive mode.
echo.
exit /b 0

