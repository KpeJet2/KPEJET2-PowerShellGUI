@echo off
setlocal EnableExtensions
REM VersionTag: 2605.B5.V46.1
REM ==============================================================
REM  Launch-ServiceClusterTabs.bat
REM  Opens Windows Terminal (wt.exe) with one tab per service.
REM  Each tab spawns its script inside the SAME terminal window.
REM
REM  Requires: Windows Terminal (wt.exe) accessible in PATH.
REM  WorkspacePath: C:\PowerShellGUI
REM  Usage: Launch-ServiceClusterTabs.bat [lite|standard|full|ops|help]
REM ==============================================================

set "WS=C:\PowerShellGUI"

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
call :AddTab "VersionScan" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Scan-WorkspaceVersions.ps1"
call :AddTab "EngineMonitor" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Invoke-EngineServiceMonitor.ps1"
call :AddTab "AiActionLog" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-AiActionLogReport.ps1"
call :AddTab "DepScanMgr" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-DependencyScanManager.ps1"
call :AddTab "StaticScan" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-StaticWorkspaceScan.ps1"
call :AddTab "WebEngine" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Start-LocalWebEngineService.ps1 -Action Start"
call :AddTab "TaskTrayStatus" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -Command Import-Module %WS%\modules\PwShGUI-TrayHost.psd1 -Force; Get-TrayHostStatus | Format-List *"
call :AddTab "AgentCallStats" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-AgentCallStats.ps1"
call :AddTab "CronAiAthon" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-CronAiAthonTool.ps1 -WorkspacePath %WS%"
call :AddTab "SvcDashboard" "%WS%\scripts\service-cluster-dashboard" "cmd /k Launch-ServiceDashboard.bat"

REM Heavy scan tabs (optional)
if /I "%INCLUDE_HEAVY_SCANS%"=="1" (
  call :AddTab "FullSysScan" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-FullSystemsScan.ps1"
  call :AddTab "PSEnvScan" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-PSEnvironmentScanner.ps1"
)

REM Engine ops tabs (optional)
if /I "%INCLUDE_ENGINE_OPS%"=="1" (
  call :AddTab "EngineBootstrap" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-Engines.ps1"
  call :AddTab "WebStatus" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-LocalWebEngine.ps1 -Action Status -Port 8042"
  if /I "%INCLUDE_CRASH_CLEANUP%"=="1" (
    call :AddTab "CrashCleanupDry" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-EngineCrashCleanup.ps1 -DryRun"
  )
)

REM UI tools tabs (optional)
if /I "%INCLUDE_UI_TOOLS%"=="1" (
  call :AddTab "ScanDashboard" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-ScanDashboard.ps1"
  if /I "%INCLUDE_EVENTLOG_VIEWER%"=="1" (
    call :AddTab "EventLogViewer" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-EventLogViewer.ps1"
  )
  call :AddTab "MCPConfig" "%WS%" "pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-MCPServiceConfig.ps1"
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
