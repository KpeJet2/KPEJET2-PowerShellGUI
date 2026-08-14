@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM VersionTag: 2608.B1.V54.3
REM VersionBuildHistory:
REM   2608.B1.V54.3  2026-08-14  Hardened wt.exe launch syntax for tray trio to prevent Windows Terminal help dialog fallback.
REM   2608.B1.V54.2  2026-08-14  Renamed launcher file; added Check/Setup PreReqs CLI options with lowercase check, uppercase setup, and ! master flow.
REM   2608.B1.V54.1  2026-08-04  Added option T to launch LocalWebEngine, ClusterTabController, and MainGui in minimized color-coded WT tabs.
REM   2608.B1.V54.0  2026-08-03  Added unified Services+Trays menu taxonomy launcher.
REM ==================================================================
REM  ALL-Start-Menu_Service_Checks-n-Trays.bat
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

title PwShGUI Services Checks and Trays Start Menu

:MENU
cls
echo ================================================================
echo   PwShGUI Start Menu - Services Checks n Trays
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
echo     T  Tray trio in WT ^(LocalWebEngine + ClusterTabController + MainGui^)
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
echo   [Checks and PreReqs CLI]
echo     y  Check setup prerequisites report (lowercase = check)
echo     Y  Setup/upgrade prerequisites (uppercase = setup)
echo     !  Master: check report then setup/upgrade
echo.
echo   [README and Taxonomy]
echo     R  README.md
echo     r  scripts\README.md
echo     S  tests\README-SmokeTest.md
echo     s  tests\sandbox\README.md
echo     V  tools\README-SIN-Scan.md
echo     t  modules\README.md
echo     U  Switch matrix reference
echo     u  Taxonomy map for query references
echo.
echo   Q/q Exit
echo ================================================================
set "OPT="
setlocal DisableDelayedExpansion
set /p "OPT=Select option: "
endlocal & set "OPT=%OPT%"
if "%OPT%"=="" goto MENU

if "%OPT%"=="A" call "%WS%\Launch-AllServices.bat" & goto POST
if "%OPT%"=="a" call "%WS%\Launch-AllServices.bat" /AUTO notray & goto POST
if "%OPT%"=="B" call "%WS%\Launch-ServiceClusterTabs.bat" /AUTO standard & goto POST
if "%OPT%"=="b" call "%WS%\Launch-ServiceClusterTabs.bat" /AUTO full & goto POST
if "%OPT%"=="C" start "WebEngine-Start" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Start -WorkspacePath "%WS%" -Port 8042 & goto POST
if "%OPT%"=="c" start "WebEngine-Headless" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Start -WorkspacePath "%WS%" -Port 8042 -NoTray & goto POST
if "%OPT%"=="D" start "WebEngine-RunTray" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action RunTray -WorkspacePath "%WS%" -Port 8042 & goto POST
if "%OPT%"=="d" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action Status -WorkspacePath "%WS%" -Port 8042 & goto POST
if "%OPT%"=="T" call :LaunchTrayTrioWT & goto POST

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

if "%OPT%"=="y" call "%WS%\Check-Setup-and-PreReqs.bat" /CHECK & goto POST
if "%OPT%"=="Y" call "%WS%\Check-Setup-and-PreReqs.bat" /SETUP & goto POST
if "%OPT%"=="!" call "%WS%\Check-Setup-and-PreReqs.bat" /MASTER & goto POST

if "%OPT%"=="R" start "" "%WS%\README.md" & goto POST
if "%OPT%"=="r" start "" "%WS%\scripts\README.md" & goto POST
if "%OPT%"=="S" start "" "%WS%\tests\README-SmokeTest.md" & goto POST
if "%OPT%"=="s" start "" "%WS%\tests\sandbox\README.md" & goto POST
if "%OPT%"=="V" start "" "%WS%\tools\README-SIN-Scan.md" & goto POST
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
echo.
echo  Check-Setup-and-PreReqs.bat
echo    /CHECK /SETUP /MASTER
echo    CLI selectors: lowercase=check, uppercase=setup/upgrade, ! master
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
echo    T   -> Minimized WT tray trio launcher
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
echo  checks.prereqs
echo    y/Y/! -> Check-Setup-and-PreReqs CLI and master remediation flow
echo.
echo  docs.readme
echo    R/r/S/s/V/t -> README links by domain
echo.
echo  references
echo    U -> switch matrix
echo ================================================================
pause
goto MENU

:LaunchTrayTrioWT
where wt.exe >nul 2>&1
if errorlevel 1 (
        echo [WARN] Windows Terminal ^(wt.exe^) not found in PATH.
        echo [INFO] Falling back to minimized direct launches.
        start "WebEngine-RunTray" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action RunTray -WorkspacePath "%WS%" -Port 8042
    start "ClusterTabController" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-ServiceClusterTabs.bat' /AUTO standard"
    start "MainGUI-TaskTray" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-GUI-quik_jnr.bat' /TASKTRAY /SUPPRESSFOOTER"
        goto :eof
)

echo [INFO] Launching tray trio in minimized WT tabs...
start "WT-TrayTrio" /min wt.exe -w new new-tab --title "[ROSE] LocalWebEngine Tray" --tabColor "#BE123C" --startingDirectory "%WS%" -- %PS_EXE% -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action RunTray -WorkspacePath "%WS%" -Port 8042
if errorlevel 1 goto WT_FALLBACK

timeout /t 1 /nobreak >nul
start "" /min wt.exe -w 0 new-tab --title "[AZUR] ClusterTabController" --tabColor "#1D4ED8" --startingDirectory "%WS%" -- %PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-ServiceClusterTabs.bat' /AUTO standard"
start "" /min wt.exe -w 0 new-tab --title "[GRN] MainGui Tray" --tabColor "#15803D" --startingDirectory "%WS%" -- %PS_EXE% -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-GUI-quik_jnr.bat' /TASKTRAY /SUPPRESSFOOTER"
goto :eof

:WT_FALLBACK
echo [WARN] WT tray trio launch failed. Falling back to minimized direct launches.
start "WebEngine-RunTray" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Start-LocalWebEngineService.ps1" -Action RunTray -WorkspacePath "%WS%" -Port 8042
start "ClusterTabController" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-ServiceClusterTabs.bat' /AUTO standard"
start "MainGUI-TaskTray" /min "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '%WS%\Launch-GUI-quik_jnr.bat' /TASKTRAY /SUPPRESSFOOTER"
goto :eof

:POST
echo.
echo [INFO] Command completed or launched. Press any key to return to menu.
pause >nul
goto MENU
