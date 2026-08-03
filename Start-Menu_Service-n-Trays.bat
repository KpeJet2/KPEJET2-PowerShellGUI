@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM VersionTag: 2608.B1.V54.0
REM VersionBuildHistory:
REM   2608.B1.V54.0  2026-08-03  Added unified Services+Trays menu taxonomy launcher.
REM ==================================================================
REM  Start-Menu_Service-n-Trays.bat
REM  Quick taxonomy launcher for services, trays, setup, tests,
REM  sandbox, pipeline, tools, engines, and README references.
REM ==================================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "WS=%%~fI"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

if not exist "%WS%\scripts" (
    echo [ERROR] Workspace root not resolved from %SCRIPT_DIR%
    exit /b 1
)

set "PS_EXE=pwsh.exe"
where pwsh.exe >nul 2>&1
if errorlevel 1 set "PS_EXE=powershell.exe"

title PwShGUI Services and Trays Start Menu

:MENU
cls
echo ================================================================
echo   PwShGUI Start Menu - Services n Trays
echo ================================================================
echo   Workspace: %WS%
echo   Host     : %PS_EXE%
echo.
echo   [Services and Trays]
echo     A  Launch-AllServices.bat
echo     a  Launch-AllServices.bat /AUTO notray
echo     B  Launch-ServiceClusterTabs.bat /AUTO standard
echo     b  Launch-ServiceClusterTabs.bat /AUTO full
echo     C  Start-LocalWebEngineService.ps1 -Action Start
echo     c  Start-LocalWebEngineService.ps1 -Action Start -NoTray
echo     D  Start-LocalWebEngineService.ps1 -Action RunTray
echo     d  Start-LocalWebEngineService.ps1 -Action Status
echo.
echo   [Setup and GUI]
echo     E  Launch-GUI.bat
echo     e  Launch-GUI.bat /TASKTRAY
echo     F  Launch-CFRMenu.bat
echo     f  View-Config.ps1
echo.
echo   [Testing and Sandbox]
echo     G  Launch-GUI-SmokeTest.bat /HEADLESSONLY /NOENGINES
echo     g  Launch-GUI-SmokeTest.bat /NOENGINES
echo     H  Launch-ChaosTest.bat
echo     h  Launch-SandboxSmokeTest.bat
echo     I  Launch-SandboxInteractive.bat
echo     i  Launch-SandboxBrowserTest.bat
echo.
echo   [Pipeline, Tools, Engines]
echo     J  scripts\Start-Engines.ps1
echo     j  scripts\Invoke-EngineServiceMonitor.ps1
echo     K  scripts\Invoke-PipelineContinuousRefine.ps1 (staged)
echo     k  scripts\Invoke-ValidateCanonicalPaths.ps1
echo     L  scripts\Invoke-NetMonCollector.ps1 (one-shot)
echo     l  scripts\Invoke-CronProcessor.ps1 -DryRun
echo.
echo   [README and Taxonomy]
echo     R  README.md
echo     r  scripts\README.md
echo     S  tests\README-SmokeTest.md
echo     s  tests\sandbox\README.md
echo     T  tools\README-SIN-Scan.md
echo     t  modules\README.md
echo     U  Switch matrix reference
echo     u  Taxonomy map for query references
echo.
echo   Q/q Exit
echo ================================================================
set "OPT="
set /p "OPT=Select option: "
if "%OPT%"=="" goto MENU

if "%OPT%"=="A" call "%WS%\Launch-AllServices.bat" & goto POST
if "%OPT%"=="a" call "%WS%\Launch-AllServices.bat" /AUTO notray & goto POST
if "%OPT%"=="B" call "%WS%\Launch-ServiceClusterTabs.bat" /AUTO standard & goto POST
if "%OPT%"=="b" call "%WS%\Launch-ServiceClusterTabs.bat" /AUTO full & goto POST
if "%OPT%"=="C" start "WebEngine-Start" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Start -WorkspacePath "%WS%" -Port 8042 & goto POST
if "%OPT%"=="c" start "WebEngine-Headless" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Start -WorkspacePath "%WS%" -Port 8042 -NoTray & goto POST
if "%OPT%"=="D" start "WebEngine-RunTray" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action RunTray -WorkspacePath "%WS%" -Port 8042 & goto POST
if "%OPT%"=="d" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Status -WorkspacePath "%WS%" -Port 8042 & goto POST

if "%OPT%"=="E" call "%WS%\Launch-GUI.bat" & goto POST
if "%OPT%"=="e" call "%WS%\Launch-GUI.bat" /TASKTRAY & goto POST
if "%OPT%"=="F" call "%WS%\Launch-CFRMenu.bat" & goto POST
if "%OPT%"=="f" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\View-Config.ps1" & goto POST

if "%OPT%"=="G" call "%WS%\Launch-GUI-SmokeTest.bat" /HEADLESSONLY /NOENGINES & goto POST
if "%OPT%"=="g" call "%WS%\Launch-GUI-SmokeTest.bat" /NOENGINES & goto POST
if "%OPT%"=="H" call "%WS%\Launch-ChaosTest.bat" & goto POST
if "%OPT%"=="h" call "%WS%\Launch-SandboxSmokeTest.bat" & goto POST
if "%OPT%"=="I" call "%WS%\Launch-SandboxInteractive.bat" & goto POST
if "%OPT%"=="i" call "%WS%\Launch-SandboxBrowserTest.bat" & goto POST

if "%OPT%"=="J" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-Engines.ps1" & goto POST
if "%OPT%"=="j" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-EngineServiceMonitor.ps1" -WorkspacePath "%WS%" & goto POST
if "%OPT%"=="K" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-PipelineContinuousRefine.ps1" -WorkspacePath "%WS%" -StagedOnly -BaselineProfile staged -BaselineJson "%WS%\config\pipeline-refine-baseline-staged.json" -FailOnDrift & goto POST
if "%OPT%"=="k" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-ValidateCanonicalPaths.ps1" -WorkspacePath "%WS%" -RegistryPath "%WS%\config\pipeline-canonical-paths.json" -FailOnMissing & goto POST
if "%OPT%"=="L" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-NetMonCollector.ps1" -WorkspacePath "%WS%" -EngineBaseUrl http://127.0.0.1:8042 -SampleLimit 120 & goto POST
if "%OPT%"=="l" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-CronProcessor.ps1" -WorkspacePath "%WS%" -DryRun & goto POST

if "%OPT%"=="R" start "" "%WS%\README.md" & goto POST
if "%OPT%"=="r" start "" "%WS%\scripts\README.md" & goto POST
if "%OPT%"=="S" start "" "%WS%\tests\README-SmokeTest.md" & goto POST
if "%OPT%"=="s" start "" "%WS%\tests\sandbox\README.md" & goto POST
if "%OPT%"=="T" start "" "%WS%\tools\README-SIN-Scan.md" & goto POST
if "%OPT%"=="t" start "" "%WS%\modules\README.md" & goto POST
if "%OPT%"=="U" goto SWITCH_HELP
if "%OPT%"=="u" goto TAXONOMY
if "%OPT%"=="Q" goto :EOF
if "%OPT%"=="q" goto :EOF

echo.
echo [WARN] Unknown option: %OPT%
pause
goto MENU

:SWITCH_HELP
cls
echo ================================================================
echo   Switch Matrix Reference
echo ================================================================
echo  Launch-AllServices.bat
echo    /AUTO [notray] [nocron] [gui] [/INTERACTIVE] [help /^?]
echo.
echo  Launch-ServiceClusterTabs.bat
echo    /AUTO [lite^|standard^|full^|ops] [/INTERACTIVE] [help /^?]
echo.
echo  Launch-GUI.bat
echo    /TASKTRAY /usepsv:5 /usepsv7 /scriptsec:1..6 /skipps7 /skippolicy
echo    /suppressfooter /nosuppressfooter
echo.
echo  Launch-GUI-quik_jnr.bat and Launch-GUI-slow_snr.bat
echo    /TASKTRAY /SUPPRESSFOOTER /NOSUPPRESSFOOTER
echo.
echo  scripts\Start-LocalWebEngineService.ps1
echo    -Action Start^|Stop^|Restart^|Status^|LaunchWebpage^|RunTray^|Help
echo    -NoTray -WorkspacePath -Port -TrayPollSec
echo ================================================================
pause
goto MENU

:TAXONOMY
cls
echo ================================================================
echo   PwShGUI Launcher Taxonomy Map
echo ================================================================
echo  services.core
echo    A/a -> Launch-AllServices.bat
echo    B/b -> Launch-ServiceClusterTabs.bat
echo    C/c -> scripts\Start-LocalWebEngineService.ps1 Start variants
echo    D/d -> scripts\Start-LocalWebEngineService.ps1 tray/status
echo.
echo  setup.gui
echo    E/e -> Launch-GUI.bat normal/tasktray
echo    F/f -> Launch-CFRMenu.bat and View-Config.ps1
echo.
echo  testing.sandbox
echo    G/g -> Launch-GUI-SmokeTest variants
echo    H/h -> Chaos + Sandbox smoke
echo    I/i -> Sandbox interactive + browser suite
echo.
echo  pipeline.tools.engines
echo    J/j -> Engine bootstrap + monitor
echo    K/k -> Pipeline refine staged + canonical path validation
echo    L/l -> NetMon collector + Cron dry-run
echo.
echo  docs.readme
echo    R/r/S/s/T/t -> README links by domain
echo.
echo  references
echo    U -> switch matrix
echo ================================================================
pause
goto MENU

:POST
echo.
echo [INFO] Command completed or launched. Press any key to return to menu.
pause >nul
goto MENU
