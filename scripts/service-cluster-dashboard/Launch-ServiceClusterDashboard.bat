REM VersionTag: 2605.B5.V46.2
@echo off
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
set "WORKSPACE=%ROOT%..\.."
set "VENV=%WORKSPACE%\.venv"
set "PYTHON=%VENV%\Scripts\python.exe"
set "PIP=%VENV%\Scripts\pip.exe"
set "ENGINE_URL=http://127.0.0.1:8042/api/engine/status"
set "MONITOR_SCRIPT=%WORKSPACE%\scripts\Invoke-EngineServiceMonitor.ps1"

set "PWSH_EXE=pwsh.exe"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PWSH_EXE=powershell.exe"

if not exist "%PYTHON%" (
  echo [ERROR] Python virtual environment not found at "%VENV%".
  echo Create it first: py -3 -m venv "%VENV%"
  exit /b 1
)

call :CheckEngine
if /I "%ENGINE_STATE%"=="OFFLINE" (
  echo [WARN] Local web engine appears offline. Running engine monitor auto recovery...
  if exist "%MONITOR_SCRIPT%" (
    "%PWSH_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%MONITOR_SCRIPT%" /AUTO
  ) else (
    echo [WARN] Engine monitor script not found at "%MONITOR_SCRIPT%".
  )

  set /a OFFLINE_STREAK=0
  for /L %%I in (1,1,4) do (
    call :CheckEngine
    if /I "!ENGINE_STATE!"=="ONLINE" goto :EngineRecovered
    set /a OFFLINE_STREAK+=1
  )

  if !OFFLINE_STREAK! GEQ 4 (
    echo [WARN] Engine remained offline for multiple heartbeats. Dashboard auto-recover action is available in the Engine blade.
  )
)

:EngineRecovered

echo [INFO] Installing dashboard dependencies...
"%PIP%" install -r "%ROOT%requirements.txt"
if errorlevel 1 (
  echo [ERROR] Failed to install requirements.
  exit /b 1
)

if "%PWSHGUI_CLUSTER_TOKEN%"=="" (
  echo [WARN] PWSHGUI_CLUSTER_TOKEN not set. server.py will use/create cluster.token.
)

rem Strip trailing backslash from ROOT so the quoted path doesn't escape the closing quote
set "APPDIR=%ROOT%"
if "%APPDIR:~-1%"=="\" set "APPDIR=%APPDIR:~0,-1%"

echo [INFO] Launching Service Cluster Dashboard...
pushd "%APPDIR%"
"%PYTHON%" "%APPDIR%\server.py"
set "EXITCODE=%ERRORLEVEL%"
popd

endlocal & exit /b %EXITCODE%

:CheckEngine
set "ENGINE_STATE=OFFLINE"
"%PWSH_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$u='%ENGINE_URL%'; try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if($r.StatusCode -ge 200 -and $r.StatusCode -lt 500){ exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 set "ENGINE_STATE=ONLINE"
exit /b 0

