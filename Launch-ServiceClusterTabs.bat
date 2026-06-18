@echo off
setlocal EnableExtensions
REM VersionTag: 2605.B5.V51.3
REM ==============================================================
REM  Launch-ServiceClusterTabs.bat
REM  Opens Windows Terminal (wt.exe) with one tab per service.
REM  Each tab spawns its script inside the SAME terminal window.
REM
REM  Requires: Windows Terminal (wt.exe) accessible in PATH.
REM  WorkspacePath: launcher-relative root
REM  Usage: Launch-ServiceClusterTabs.bat [lite|standard|full|ops|help]
REM ==============================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "WS=%%~fI"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

if not exist "%WS%\scripts" (
  echo [ERROR] Could not resolve workspace root from launcher path "%SCRIPT_DIR%".
  exit /b 1
)

set "PS_EXE=pwsh"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PS_EXE=powershell"

where %PS_EXE%.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Neither pwsh.exe nor powershell.exe was found in PATH.
  exit /b 1
)

REM Profile toggles (1=enabled, 0=disabled)
REM Core tabs are always launched.
set "INCLUDE_HEAVY_SCANS=0"
set "INCLUDE_ENGINE_OPS=1"
set "INCLUDE_UI_TOOLS=1"
set "INCLUDE_CRASH_CLEANUP=0"
set "INCLUDE_EVENTLOG_VIEWER=0"
set "WT_ROOT_CREATED=0"
set "PROFILE=%~1"

if "%PROFILE%"=="" set "PROFILE=standard"

if /I "%PROFILE%"=="help" goto :Usage
if /I "%PROFILE%"=="/?" goto :Usage

if /I "%PROFILE%"=="lite" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=0"
  set "INCLUDE_UI_TOOLS=0"
  set "INCLUDE_CRASH_CLEANUP=0"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else if /I "%PROFILE%"=="standard" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=1"
  set "INCLUDE_CRASH_CLEANUP=0"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else if /I "%PROFILE%"=="full" (
  set "INCLUDE_HEAVY_SCANS=1"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=1"
  set "INCLUDE_CRASH_CLEANUP=1"
  set "INCLUDE_EVENTLOG_VIEWER=1"
) else if /I "%PROFILE%"=="ops" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=0"
  set "INCLUDE_CRASH_CLEANUP=1"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else (
  echo [ERROR] Unknown profile "%PROFILE%".
  goto :Usage
)

echo [INFO] Launch profile: %PROFILE%
echo [INFO] HeavyScans=%INCLUDE_HEAVY_SCANS% EngineOps=%INCLUDE_ENGINE_OPS% UiTools=%INCLUDE_UI_TOOLS%
echo [INFO] CrashCleanup=%INCLUDE_CRASH_CLEANUP% EventLogViewer=%INCLUDE_EVENTLOG_VIEWER%

REM Verify wt is available before proceeding
where wt.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows Terminal ^(wt.exe^) not found in PATH.
    echo Install from the Microsoft Store or add to PATH, then retry.
    pause
    exit /b 1
)

REM Core tabs (always on)
call :AddTab "VersionScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Scan-WorkspaceVersions.ps1"
call :AddTab "EngineMonitor" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Invoke-EngineServiceMonitor.ps1 -WorkspacePath %WS%"
call :AddTab "AiActionLog" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-AiActionLogReport.ps1 -WorkspacePath %WS%"
call :AddTab "DepScanMgr" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-DependencyScanManager.ps1 -WorkspacePath %WS%"
call :AddTab "StaticScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-StaticWorkspaceScan.ps1 -WorkspacePath %WS%"
call :AddTab "WebEngine" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Start-LocalWebEngineService.ps1 -Action Start -WorkspacePath %WS%"
call :AddTab "TaskTrayStatus" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -Command Import-Module '%WS%\modules\PwShGUI-TrayHost.psm1' -Force; $status = Get-TrayHostStatus; $status"
call :AddTab "AgentCallStats" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-AgentCallStats.ps1 -WorkspacePath %WS%"
call :AddTab "CronAiAthon" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-CronAiAthonTool.ps1 -WorkspacePath %WS%"
call :AddTab "CronProc1" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-CronProcessor.ps1 -WorkspacePath %WS%"
call :AddTab "CronProc2" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-CronProcessor.ps1 -WorkspacePath %WS%"
call :AddTab "SvcDashboard" "%WS%\scripts\service-cluster-dashboard" "cmd /k \"%WS%\scripts\service-cluster-dashboard\Launch-ServiceClusterDashboard.bat\""

echo [INFO] Waiting for core services to converge...
call :WaitForHttp "LocalWebEngine" "http://127.0.0.1:8042/api/engine/status" 20 2
if errorlevel 1 call :ProbeEngineStatus "LocalWebEngine" "%WS%\scripts\Start-LocalWebEngine.ps1" 8042
call :WaitForHttp "ServiceClusterDashboard" "http://127.0.0.1:8099/api/ping" 20 2

REM Heavy scan tabs (optional)
if /I "%INCLUDE_HEAVY_SCANS%"=="1" (
  call :AddTab "FullSysScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-FullSystemsScan.ps1 -WorkspacePath %WS%"
  call :AddTab "PSEnvScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-PSEnvironmentScanner.ps1 -WorkspacePath %WS%"
)

REM Engine ops tabs (optional)
if /I "%INCLUDE_ENGINE_OPS%"=="1" (
  call :AddTab "EngineBootstrap" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-Engines.ps1"
  call :AddTab "WebStatus" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-LocalWebEngine.ps1 -Action Status -Port 8042 -WorkspacePath %WS%"
  if /I "%INCLUDE_CRASH_CLEANUP%"=="1" (
    call :AddTab "CrashCleanupDry" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-EngineCrashCleanup.ps1 -DryRun -WorkspacePath %WS%"
  )
)

REM UI tools tabs (optional)
if /I "%INCLUDE_UI_TOOLS%"=="1" (
  call :AddTab "ScanDashboard" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-ScanDashboard.ps1"
  if /I "%INCLUDE_EVENTLOG_VIEWER%"=="1" (
    call :AddTab "EventLogViewer" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-EventLogViewer.ps1"
  )
  call :AddTab "MCPConfig" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-MCPServiceConfig.ps1"
)

endlocal
exit /b 0

:Usage
echo.
echo Launch-ServiceClusterTabs.bat [profile]
echo.
echo Profiles:
echo   lite      = core tabs only
echo   standard  = core + engine ops + UI tools
echo   full      = standard + heavy scan tabs
echo   ops       = core + engine ops only
echo   help      = show this help
echo.
echo Example:
echo   Launch-ServiceClusterTabs.bat full
endlocal
exit /b 1

:AddTab
set "TAB_TITLE=%~1"
set "TAB_DIR=%~2"
set "TAB_CMD=%~3"

if "%WT_ROOT_CREATED%"=="0" (
  start "" wt --window new new-tab --title "%TAB_TITLE%" --startingDirectory "%TAB_DIR%" %TAB_CMD%
  set "WT_ROOT_CREATED=1"
  timeout /t 1 /nobreak >nul
) else (
  start "" wt -w 0 new-tab --title "%TAB_TITLE%" --startingDirectory "%TAB_DIR%" %TAB_CMD%
)
exit /b 0

:WaitForHttp
setlocal EnableDelayedExpansion
set "HEALTH_NAME=%~1"
set "HEALTH_URL=%~2"
set "HEALTH_ATTEMPTS=%~3"
set "HEALTH_TIMEOUT=%~4"

if "!HEALTH_ATTEMPTS!"=="" set "HEALTH_ATTEMPTS=15"
if "!HEALTH_TIMEOUT!"=="" set "HEALTH_TIMEOUT=2"

set "HEALTH_OK=0"
for /L %%I in (1,1,!HEALTH_ATTEMPTS!) do (
  call :ProbeUrl "!HEALTH_URL!" "!HEALTH_TIMEOUT!"
  if "!ERRORLEVEL!"=="0" (
    set "HEALTH_OK=1"
    goto :WaitForHttpDone
  )
)

:WaitForHttpDone
if "!HEALTH_OK!"=="1" (
  echo [PASS] !HEALTH_NAME! online at !HEALTH_URL!.
  endlocal & exit /b 0
) else (
  echo [WARN] !HEALTH_NAME! not ready after !HEALTH_ATTEMPTS! attempts: !HEALTH_URL!
  endlocal & exit /b 1
)

:ProbeEngineStatus
setlocal
set "STATUS_NAME=%~1"
set "STATUS_SCRIPT=%~2"
set "STATUS_PORT=%~3"

echo [INFO] Probing %STATUS_NAME% via status script...
%PS_EXE% -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%STATUS_SCRIPT%" -Action Status -Port %STATUS_PORT% -WorkspacePath "%WS%"
set "STATUS_CODE=%ERRORLEVEL%"
if not "%STATUS_CODE%"=="0" (
  echo [WARN] %STATUS_NAME% status probe reported offline or stale state.
)
endlocal & exit /b %STATUS_CODE%

:ProbeUrl
setlocal
set "PROBE_URL=%~1"
set "PROBE_TIMEOUT=%~2"
if "%PROBE_TIMEOUT%"=="" set "PROBE_TIMEOUT=2"

%PS_EXE% -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$u='%PROBE_URL%'; $t=%PROBE_TIMEOUT%; try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec $t -ErrorAction Stop; if($r.StatusCode -ge 200 -and $r.StatusCode -lt 500){ exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
set "PROBE_CODE=%ERRORLEVEL%"
endlocal & exit /b %PROBE_CODE%
