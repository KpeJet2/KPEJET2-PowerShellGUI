@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM VersionTag: 2607.B1.V51.8
REM ==============================================================
REM  Launch-ServiceClusterTabs.bat
REM  Opens Windows Terminal (wt.exe) with one tab per service.
REM
REM  Interactive mode (default):
REM    - Shows selectable launch elements
REM    - Lets user test each selected element one-by-one
REM    - Lets user launch selected elements
REM
REM  Automation mode:
REM    Launch-ServiceClusterTabs.bat /AUTO [lite|standard|full|ops]
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

REM --- mode/profile defaults ---
set "MODE=INTERACTIVE"
set "PROFILE=standard"
set "STEP_MODE=RUN"
set "MENU_ACTION=RUN"

REM --- profile toggles ---
set "INCLUDE_HEAVY_SCANS=0"
set "INCLUDE_ENGINE_OPS=1"
set "INCLUDE_UI_TOOLS=1"
set "INCLUDE_CRASH_CLEANUP=0"
set "INCLUDE_EVENTLOG_VIEWER=0"

REM --- launch element toggles ---
set "STEP1=1"
set "STEP2=1"
set "STEP3=1"
set "STEP4=1"
set "STEP5=1"
set "STEP6=1"

REM parse args
for %%A in (%*) do (
  if /I "%%A"=="/AUTO" set "MODE=AUTO"
  if /I "%%A"=="/INTERACTIVE" set "MODE=INTERACTIVE"
  if /I "%%A"=="help" goto :Usage
  if /I "%%A"=="/?" goto :Usage
  if /I "%%A"=="lite" set "PROFILE=lite"
  if /I "%%A"=="standard" set "PROFILE=standard"
  if /I "%%A"=="full" set "PROFILE=full"
  if /I "%%A"=="ops" set "PROFILE=ops"
)

call :ApplyProfile "%PROFILE%"
if errorlevel 1 goto :Usage

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

echo [INFO] Launch profile: %PROFILE%
echo [INFO] Mode=%MODE% StepMode=!STEP_MODE!
echo [INFO] HeavyScans=%INCLUDE_HEAVY_SCANS% EngineOps=%INCLUDE_ENGINE_OPS% UiTools=%INCLUDE_UI_TOOLS%
echo [INFO] CrashCleanup=%INCLUDE_CRASH_CLEANUP% EventLogViewer=%INCLUDE_EVENTLOG_VIEWER%

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
echo  Launch-ServiceClusterTabs CLI Load Screen
echo  Workspace: %WS%
echo ============================================================
echo  Launch elements:
call :RenderStep 1 "Verify Windows Terminal availability" STEP1
call :RenderStep 2 "Open core service tabs" STEP2
call :RenderStep 3 "Wait for core services to converge" STEP3
call :RenderStep 4 "Open heavy scan tabs" STEP4
call :RenderStep 5 "Open engine-ops tabs" STEP5
call :RenderStep 6 "Open UI-tools tabs" STEP6
echo.
echo  Current profile: %PROFILE%
echo  Profile flags: Heavy=%INCLUDE_HEAVY_SCANS% EngineOps=%INCLUDE_ENGINE_OPS% UI=%INCLUDE_UI_TOOLS% Crash=%INCLUDE_CRASH_CLEANUP% EventLog=%INCLUDE_EVENTLOG_VIEWER%
echo.
echo  Commands:
echo    1-6 = toggle launch element
echo    P   = cycle profile ^(lite^>standard^>full^>ops^)
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
if /I "!MENU_CHOICE!"=="P" call :CycleProfile & goto :MenuLoop
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
set "STEP1=%~1"
set "STEP2=%~1"
set "STEP3=%~1"
set "STEP4=%~1"
set "STEP5=%~1"
set "STEP6=%~1"
exit /b 0

:CycleProfile
if /I "%PROFILE%"=="lite" (
  set "PROFILE=standard"
) else if /I "%PROFILE%"=="standard" (
  set "PROFILE=full"
) else if /I "%PROFILE%"=="full" (
  set "PROFILE=ops"
) else (
  set "PROFILE=lite"
)
call :ApplyProfile "%PROFILE%"
exit /b 0

:ApplyProfile
set "INCLUDE_HEAVY_SCANS=0"
set "INCLUDE_ENGINE_OPS=1"
set "INCLUDE_UI_TOOLS=1"
set "INCLUDE_CRASH_CLEANUP=0"
set "INCLUDE_EVENTLOG_VIEWER=0"

if /I "%~1"=="lite" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=0"
  set "INCLUDE_UI_TOOLS=0"
  set "INCLUDE_CRASH_CLEANUP=0"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else if /I "%~1"=="standard" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=1"
  set "INCLUDE_CRASH_CLEANUP=0"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else if /I "%~1"=="full" (
  set "INCLUDE_HEAVY_SCANS=1"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=1"
  set "INCLUDE_CRASH_CLEANUP=1"
  set "INCLUDE_EVENTLOG_VIEWER=1"
) else if /I "%~1"=="ops" (
  set "INCLUDE_HEAVY_SCANS=0"
  set "INCLUDE_ENGINE_OPS=1"
  set "INCLUDE_UI_TOOLS=0"
  set "INCLUDE_CRASH_CLEANUP=1"
  set "INCLUDE_EVENTLOG_VIEWER=0"
) else (
  echo [ERROR] Unknown profile "%~1".
  exit /b 1
)
exit /b 0

:RunSelectedSteps
set "WT_ROOT_CREATED=0"

if "%STEP1%"=="1" call :ExecuteStep "Verify Windows Terminal availability" Step1_CheckWt
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

if "%STEP2%"=="1" call :ExecuteStep "Open core service tabs" Step2_OpenCoreTabs
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

if "%STEP3%"=="1" call :ExecuteStep "Wait for core services to converge" Step3_WaitCore
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

if "%STEP4%"=="1" call :ExecuteStep "Open heavy scan tabs" Step4_OpenHeavyTabs
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

if "%STEP5%"=="1" call :ExecuteStep "Open engine-ops tabs" Step5_OpenEngineOps
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

if "%STEP6%"=="1" call :ExecuteStep "Open UI-tools tabs" Step6_OpenUiTabs
if errorlevel 90 exit /b 0
if errorlevel 1 exit /b 1

exit /b 0

:ExecuteStep
echo.
echo ------------------------------------------------------------
echo [!STEP_MODE!] %~1
echo ------------------------------------------------------------

if /I "!STEP_MODE!"=="RUN" if /I "%MODE%"=="INTERACTIVE" (
  echo [PROMPT] Select action for: %~1
  choice /C RBC /N /T 30 /D B /M "Run [R], Bypass [B], Close launcher [C]? (auto-bypass in 30s) "
  if errorlevel 3 (
    echo [INFO] Launcher closed by user before step execution.
    exit /b 90
  )
  if errorlevel 2 (
    echo [SKIP] Bypassed by user: %~1
    exit /b 0
  )
)

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

:Step1_CheckWt
where wt.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Windows Terminal ^(wt.exe^) not found in PATH.
  echo         Install from Microsoft Store or add to PATH.
  exit /b 1
)
if /I "!STEP_MODE!"=="TEST" (
  echo [OK] wt.exe detected.
)
exit /b 0

:Step2_OpenCoreTabs
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] Core tabs that would launch:
  echo   - VersionScan
  echo   - EngineMonitor
  echo   - AiActionLog
  echo   - DepScanMgr
  echo   - WebEngine
  echo   - TaskTrayStatus
  echo   - CronAiAthon
  echo   - CronProc1
  echo   - SvcDashboard
  exit /b 0
)

call :AddTab "VersionScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Scan-WorkspaceVersions.ps1"
call :AddTab "EngineMonitor" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Invoke-EngineServiceMonitor.ps1 -WorkspacePath %WS%"
call :AddTab "AiActionLog" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-AiActionLogReport.ps1 -WorkspacePath %WS%"
call :AddTab "DepScanMgr" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-DependencyScanManager.ps1 -WorkspacePath %WS%"
call :AddTab "WebEngine" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -File %WS%\scripts\Start-LocalWebEngineService.ps1 -Action Start -WorkspacePath %WS%"
call :AddTab "TaskTrayStatus" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -Command Import-Module '%WS%\modules\PwShGUI-TrayHost.psm1' -Force; $status = Get-TrayHostStatus; $status"
call :CanParseScript "%WS%\scripts\Show-CronAiAthonTool.ps1"
if errorlevel 1 (
  echo [WARN] Skipping CronAiAthon tab: parse check failed for Show-CronAiAthonTool.ps1
) else (
  call :AddTab "CronAiAthon" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-CronAiAthonTool.ps1 -WorkspacePath %WS%"
)

call :CanParseScript "%WS%\scripts\Invoke-CronProcessor.ps1"
if errorlevel 1 (
  echo [WARN] Skipping CronProc1 tab: parse check failed for Invoke-CronProcessor.ps1
) else (
  call :AddTab "CronProc1" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-CronProcessor.ps1 -WorkspacePath %WS% -BatchSize 25 -SkipPesterGate"
)

call :ProbeUrl "http://127.0.0.1:8099/api/ping" 2
if errorlevel 1 (
  call :AddTab "SvcDashboard" "%WS%\scripts\service-cluster-dashboard" "cmd /k \"%WS%\scripts\service-cluster-dashboard\Launch-ServiceClusterDashboard.bat /AUTO\""
) else (
  echo [INFO] SvcDashboard already online at http://127.0.0.1:8099/api/ping; skipping duplicate launch.
)
exit /b 0

:Step3_WaitCore
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] Would probe:
  echo   - http://127.0.0.1:8042/api/engine/status
  echo   - http://127.0.0.1:8099/api/ping
  exit /b 0
)

echo [INFO] Waiting for core services to converge...
call :WaitForHttp "LocalWebEngine" "http://127.0.0.1:8042/api/engine/status" 20 2
if errorlevel 1 call :ProbeEngineStatus "LocalWebEngine" "%WS%\scripts\Start-LocalWebEngine.ps1" 8042
call :WaitForHttp "ServiceClusterDashboard" "http://127.0.0.1:8099/api/ping" 20 2
exit /b 0

:Step4_OpenHeavyTabs
if "%INCLUDE_HEAVY_SCANS%"=="0" (
  echo [SKIP] Heavy scan tabs disabled by profile.
  exit /b 0
)
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] Heavy scan tabs enabled: FullSysScan (user-confirmed), PSEnvScan
  exit /b 0
)

echo [PROMPT] FullSystemsScan is heavy.
choice /C YN /N /T 30 /D N /M "Launch FullSystemsScan now? [Y/N] (auto-skip in 30s) "
if errorlevel 2 (
  echo [SKIP] FullSystemsScan skipped by user/timeout.
) else (
  call :CanParseScript "%WS%\scripts\Invoke-FullSystemsScan.ps1"
  if errorlevel 1 (
    echo [WARN] Skipping FullSysScan tab: parse check failed for Invoke-FullSystemsScan.ps1
  ) else (
    call :AddTab "FullSysScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-FullSystemsScan.ps1 -WorkspacePath %WS%"
  )
)

call :AddTab "PSEnvScan" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-PSEnvironmentScanner.ps1 -WorkspacePath %WS%"
exit /b 0

:Step5_OpenEngineOps
if "%INCLUDE_ENGINE_OPS%"=="0" (
  echo [SKIP] Engine-ops tabs disabled by profile.
  exit /b 0
)
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] Engine-ops tabs enabled: EngineBootstrap, WebStatus
  if "%INCLUDE_CRASH_CLEANUP%"=="1" echo [INFO] CrashCleanupDry tab also enabled.
  exit /b 0
)

call :ProbeUrl "http://127.0.0.1:8042/api/engine/status" 2
if errorlevel 1 (
  call :CanParseScript "%WS%\scripts\Start-Engines.ps1"
  if errorlevel 1 (
    echo [WARN] Skipping EngineBootstrap tab: parse check failed for Start-Engines.ps1
  ) else (
    call :AddTab "EngineBootstrap" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-Engines.ps1"
  )
) else (
  echo [INFO] LocalWebEngine already online; skipping EngineBootstrap launch.
)

call :AddTab "WebStatus" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Start-LocalWebEngine.ps1 -Action Status -Port 8042 -WorkspacePath %WS%"
if "%INCLUDE_CRASH_CLEANUP%"=="1" (
  call :AddTab "CrashCleanupDry" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Invoke-EngineCrashCleanup.ps1 -DryRun -WorkspacePath %WS%"
)
exit /b 0

:CanParseScript
setlocal
set "PARSE_PATH=%~1"
if not exist "%PARSE_PATH%" endlocal & exit /b 1

%PS_EXE% -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$p='%PARSE_PATH%'; $t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e); if(@($e).Count -gt 0){ exit 1 } else { exit 0 }" >nul 2>&1
set "PARSE_CODE=%ERRORLEVEL%"
endlocal & exit /b %PARSE_CODE%

:Step6_OpenUiTabs
if "%INCLUDE_UI_TOOLS%"=="0" (
  echo [SKIP] UI-tools tabs disabled by profile.
  exit /b 0
)
if /I "!STEP_MODE!"=="TEST" (
  echo [INFO] UI-tools tabs enabled: ScanDashboard, MCPConfig
  if "%INCLUDE_EVENTLOG_VIEWER%"=="1" echo [INFO] EventLogViewer tab also enabled.
  exit /b 0
)
call :AddTab "ScanDashboard" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-ScanDashboard.ps1"
if "%INCLUDE_EVENTLOG_VIEWER%"=="1" (
  call :AddTab "EventLogViewer" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-EventLogViewer.ps1"
)
call :AddTab "MCPConfig" "%WS%" "%PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -File %WS%\scripts\Show-MCPServiceConfig.ps1"
exit /b 0

:Usage
echo.
echo Launch-ServiceClusterTabs.bat [profile] [mode]
echo.
echo Profiles:
echo   lite      = core tabs only
echo   standard  = core + engine ops + UI tools
echo   full      = standard + heavy scan tabs
echo   ops       = core + engine ops only
echo.
echo Modes:
echo   (default)      Interactive load screen with selectable/testable elements
echo   /AUTO          Non-interactive run using selected profile defaults
echo   /INTERACTIVE   Force interactive mode
echo.
echo Examples:
echo   Launch-ServiceClusterTabs.bat
echo   Launch-ServiceClusterTabs.bat full
echo   Launch-ServiceClusterTabs.bat /AUTO standard
echo.
endlocal
exit /b 0

:AddTab
set "TAB_TITLE=%~1"
set "TAB_DIR=%~2"
set "TAB_CMD=%~3"

if "%WT_ROOT_CREATED%"=="0" (
  start "" wt -w new nt --title "%TAB_TITLE%" --startingDirectory "%TAB_DIR%" -- %TAB_CMD%
  set "WT_ROOT_CREATED=1"
  timeout /t 1 /nobreak >nul
) else (
  start "" wt -w 0 nt --title "%TAB_TITLE%" --startingDirectory "%TAB_DIR%" -- %TAB_CMD%
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
