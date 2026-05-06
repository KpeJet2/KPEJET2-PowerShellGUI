@echo off
REM VersionTag: 2604.B2.V31.1
REM VersionBuildHistory:
REM   2604.B2.V31.1  2026-04-12  Bootstrap PSModulePath so all child PowerShell processes find modules
REM   2604.B2.V31.0  2026-04-04  Added switch parameters (/usepsv:5|7, /scriptsec:1-6, /skipps7, /skippolicy), cleaned echo output
REM   2604.B2.V31.0  2026-04-04  PS7 detection, exec policy diagnostics, launch logging, CFRMenu
REM   2603.B0.V27.0  2026-03-24 03:28  (deduplicated from 6 entries)
REM ============================================================
REM  Launch-GUI.bat  |  PowerShell GUI Application Loader
REM  Author   : The Establishment
REM  Version  : 2604.B2.V31.0
REM  Modified : 04 Apr 2026
REM  Purpose  : Top-level launcher with PS7 detection, execution
REM             policy diagnostics, comprehensive launch logging,
REM             and First Run Configuration Menu (CFRMenu).
REM             Presents a numbered menu to select quik_jnr,
REM             slow_snr, or any discovered .bat / .ps1 / .html.
REM  Usage    : Double-click or run from any prompt.
REM             Default (7 s timeout): 1 = quik_jnr fast mode
REM  Features : - Auto-detect PS7, offer winget installation
REM             - Detect execution policy blocks, show solutions
REM             - Log every launch with 14 telemetry fields
REM             - Launch CFRMenu on first run for setup
REM ============================================================


setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "quickLauncher=%scriptDir%Launch-GUI-quik_jnr.bat"
set "slowLauncher=%scriptDir%Launch-GUI-slow_snr.bat"

REM ── Bootstrap: ensure PowerShellGUI modules are findable by all child PowerShell processes.
REM    This top-level bat is the entry point; injecting here means quik_jnr/slow_snr and any
REM    directly launched pwsh/powershell calls will all inherit the modules directory in PSModulePath.

REM --- Ensure workspace PowerShell environment is set up ---
if exist "%scriptDir%scripts\Set-WorkspaceModulePath.ps1" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptDir%scripts\Set-WorkspaceModulePath.ps1"
)
if exist "%scriptDir%scripts\Register-WorkspaceRepository.ps1" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptDir%scripts\Register-WorkspaceRepository.ps1"
)
set "PSModulePath=%scriptDir%modules;%PSModulePath%"

set "featureRequests=%scriptDir%scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml"
set "PASSTHRU_ARGS="
set "PS7_DETECTED=FALSE"
set "EXEC_POLICY_BLOCKED=FALSE"
set "FIRST_LAUNCH=FALSE"
set "USE_BYPASS_FLAG=FALSE"
set "FORCE_PS_VERSION="
set "FORCE_SCRIPT_SEC="
set "SKIP_PS7_PROMPT=FALSE"
set "SKIP_POLICY_PROMPT=FALSE"
set "SUPPRESS_FOOTER_MODE=ON"

REM --- Parse command-line switches ---
REM Supported: /TASKTRAY  /usepsv:5  /usepsv7  /scriptsec:1-6  /skipps7  /skippolicy  /suppressfooter  /nosuppressfooter
for %%A in (%*) do (
    if /I "%%~A"=="/TASKTRAY" set "PASSTHRU_ARGS=/TASKTRAY"
    if /I "%%~A"=="/usepsv:5" (
        set "FORCE_PS_VERSION=5"
        set "SKIP_PS7_PROMPT=TRUE"
    )
    if /I "%%~A"=="/usepsv7" (
        set "FORCE_PS_VERSION=7"
        set "SKIP_PS7_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:1" (
        set "FORCE_SCRIPT_SEC=1"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:2" (
        set "FORCE_SCRIPT_SEC=2"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:3" (
        set "FORCE_SCRIPT_SEC=3"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:4" (
        set "FORCE_SCRIPT_SEC=4"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:5" (
        set "FORCE_SCRIPT_SEC=5"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/scriptsec:6" (
        set "FORCE_SCRIPT_SEC=6"
        set "SKIP_POLICY_PROMPT=TRUE"
    )
    if /I "%%~A"=="/skipps7" set "SKIP_PS7_PROMPT=TRUE"
    if /I "%%~A"=="/skippolicy" set "SKIP_POLICY_PROMPT=TRUE"
    if /I "%%~A"=="/suppressfooter" set "SUPPRESS_FOOTER_MODE=ON"
    if /I "%%~A"=="/nosuppressfooter" set "SUPPRESS_FOOTER_MODE=OFF"
)

REM ============================================================
REM  ENHANCEMENT PHASE 0: SASC Integrity Preflight
REM ============================================================
if exist "%scriptDir%scripts\Invoke-SASCIntegrityPreflight.ps1" (
    echo [CHECK] Running SASC integrity preflight...
    set "SASC_PREFLIGHT_SHELL=powershell"
    for /f "tokens=*" %%A in ('pwsh -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "SASC_PWSH_VERSION=%%A"
    if defined SASC_PWSH_VERSION set "SASC_PREFLIGHT_SHELL=pwsh"
    !SASC_PREFLIGHT_SHELL! -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%scripts\Invoke-SASCIntegrityPreflight.ps1" -WorkspacePath "%scriptDir%" -Interactive -Quiet
    set "SASC_PREFLIGHT_EXIT=!errorlevel!"
    if "!SASC_PREFLIGHT_EXIT!"=="0" (
        echo [OK] SASC integrity preflight passed.
    ) else if "!SASC_PREFLIGHT_EXIT!"=="2" (
        echo [WARNING] SASC integrity preflight reported unresolved drift. Continuing in advisory mode.
    ) else (
        echo [WARNING] SASC integrity preflight returned exit code !SASC_PREFLIGHT_EXIT!. Continuing launch.
    )
    echo.
) else (
    echo [INFO] SASC preflight script not found. Skipping preflight.
    echo.
)

REM ============================================================
REM  ENHANCEMENT PHASE 1: PowerShell 7 Detection
REM ============================================================
call :DetectPS7 >nul 2>&1
if "%SKIP_PS7_PROMPT%" NEQ "TRUE" (
    if "%PS7_DETECTED%" NEQ "TRUE" (
        call :PromptPS7Install
    )
)

REM ============================================================
REM  ENHANCEMENT PHASE 2: Execution Policy Check
REM ============================================================
call :DetectExecutionPolicy >nul 2>&1
if "%SKIP_POLICY_PROMPT%"=="TRUE" (
    if "%FORCE_SCRIPT_SEC%" NEQ "" (
        call :ApplyScriptSecurityChoice !FORCE_SCRIPT_SEC! >nul
    )
) else (
    if "%EXEC_POLICY_BLOCKED%"=="TRUE" (
        call :ShowExecutionPolicyMenu
    )
)

REM ============================================================
REM  ENHANCEMENT PHASE 3: Launch Logging
REM ============================================================
call :LogLaunch

REM ============================================================
REM  ENHANCEMENT PHASE 4: First Launch CFRMenu Trigger
REM ============================================================
if "%FIRST_LAUNCH%"=="TRUE" (
    cls
    echo.
    echo ╔═══════════════════════════════════════════════════════════════╗
    echo ║  FIRST LAUNCH DETECTED                                        ║
    echo ║  Launching First Run Configuration Menu...                    ║
    echo ╚═══════════════════════════════════════════════════════════════╝
    timeout /t 3 /nobreak >nul
    call "%scriptDir%Launch-CFRMenu.bat"
)

REM ============================================================
REM  Validate required launchers
REM ============================================================
if not exist "%quickLauncher%" (
    echo Error: Launch-GUI-quik_jnr.bat not found in %scriptDir%
    pause
    exit /b 1
)

if not exist "%slowLauncher%" (
    echo Error: Launch-GUI-slow_snr.bat not found in %scriptDir%
    pause
    exit /b 1
)

REM ============================================================
REM  DynamicMenuFolders - folders scanned for selectable files
REM  Supported types : .bat  .ps1  .html  .xhtml
REM  To add a folder : set "DynamicMenuFolder3=C:\your\path\"
REM                   set /a DynamicMenuFolderCount+=1
REM ============================================================
set "DynamicMenuFolder1=%scriptDir%"
set "DynamicMenuFolder2=%scriptDir%scripts\QUICK-APP\"
set "DynamicMenuFolderCount=2"

:MainMenu
cls
set "SUPPRESS_FOOTER_SWITCH=/SUPPRESSFOOTER"
if /I "!SUPPRESS_FOOTER_MODE!"=="OFF" set "SUPPRESS_FOOTER_SWITCH=/NOSUPPRESSFOOTER"
echo ============================================================
echo  PowerShell GUI Application Loader
echo ============================================================
echo.
echo Select startup profile:
echo.
echo  1^) Launch-GUI-quik_jnr   ^(fast startup mode^)
echo  2^) Launch-GUI-slow_snr   ^(full checks mode^)
echo  3^) Feature Requests       ^(XHTML task pad^)
echo  4^) Toggle Footer Suppression ^(diagnostics^) [!SUPPRESS_FOOTER_MODE!]
echo.

REM --- Letter lookup: dynamic item 1=A, 2=B, ... (add more rows for >26 files) ---
set "_L1=A"  & set "_L2=B"  & set "_L3=C"  & set "_L4=D"  & set "_L5=E"
set "_L6=F"  & set "_L7=G"  & set "_L8=H"  & set "_L9=I"  & set "_L10=J"
set "_L11=K" & set "_L12=L" & set "_L13=M" & set "_L14=N" & set "_L15=O"
set "_L16=P" & set "_L17=Q" & set "_L18=R" & set "_L19=S" & set "_L20=T"
set "_L21=U" & set "_L22=V" & set "_L23=W" & set "_L24=X" & set "_L25=Y"
set "_L26=Z"
set "dynCount=0"
set "choices=1234"

REM --- Dynamically list files from each DynamicMenuFolder ---
for /L %%D in (1,1,%DynamicMenuFolderCount%) do (
    call :scanFolder "!DynamicMenuFolder%%D!"
)

echo.
echo Default in 7 seconds: 1 ^(quik_jnr^)
echo.

choice /C !choices! /N /T 7 /D 1 /M "Enter choice [1-4] or letter [A-Z]: "
set "userChoice=!errorlevel!"

REM --- Handle fixed selections ---
if "!userChoice!"=="1" (
    call "%quickLauncher%" !PASSTHRU_ARGS! !SUPPRESS_FOOTER_SWITCH!
    goto end
)
if "!userChoice!"=="2" (
    call "%slowLauncher%" !PASSTHRU_ARGS! !SUPPRESS_FOOTER_SWITCH!
    goto end
)
if "!userChoice!"=="3" (
    start "" "%featureRequests%"
    goto end
)
if "!userChoice!"=="4" (
    if /I "!SUPPRESS_FOOTER_MODE!"=="ON" (
        set "SUPPRESS_FOOTER_MODE=OFF"
    ) else (
        set "SUPPRESS_FOOTER_MODE=ON"
    )
    goto MainMenu
)

REM --- Handle dynamic selections (errorlevel 5=A=dynCount 1, 6=B=dynCount 2 ...) ---
set /a "dIdx=!userChoice!-4"
if !dIdx! LSS 1 goto end
if !dIdx! GTR !dynCount! goto end
for /f %%I in ("!dIdx!") do (
    call set "selectedFile=%%file%%I%%"
    call set "selectedLabel=%%label%%I%%"
)

echo !selectedLabel! | findstr /I "\[PS1\]" >nul
if !errorlevel!==0 (
    if "%USE_BYPASS_FLAG%"=="TRUE" (
        powershell.exe -ExecutionPolicy Bypass -File "!selectedFile!"
    ) else (
        powershell.exe -File "!selectedFile!"
    )
    goto end
)
echo !selectedLabel! | findstr /I "\[HTML\]\|\[XHTML\]" >nul
if !errorlevel!==0 (
    start "" "!selectedFile!"
    goto end
)
REM Default: run as .bat
call "!selectedFile!"
goto end

REM ============================================================
REM  :scanFolder  <folderPath>
REM  Scans one folder for .bat .ps1 .html .xhtml and appends
REM  entries to the dynamic menu.  Called once per
REM  DynamicMenuFolder variable.
REM ============================================================
:scanFolder
set "scanDir=%~1"
if not exist "!scanDir!" goto :eof
for %%F in ("!scanDir!*.bat") do (
    set "fname=%%~nxF"
    if /I "!fname!" NEQ "Launch-GUI.bat" (
        if /I "!fname!" NEQ "Launch-GUI-quik_jnr.bat" (
            if /I "!fname!" NEQ "Launch-GUI-slow_snr.bat" (
                set /a dynCount+=1
                for /f %%K in ("!dynCount!") do call set "menuKey=%%_L%%K%%"
                set "file!dynCount!=%%~fF"
                set "label!dynCount!=!fname! [BAT]"
                set "choices=!choices!!menuKey!"
                echo  !menuKey!^) !fname!  [BAT]
            )
        )
    )
)
for %%F in ("!scanDir!*.ps1") do (
    set /a dynCount+=1
    for /f %%K in ("!dynCount!") do call set "menuKey=%%_L%%K%%"
    set "file!dynCount!=%%~fF"
    set "label!dynCount!=%%~nxF [PS1]"
    set "choices=!choices!!menuKey!"
    echo  !menuKey!^) %%~nxF  [PS1]
)
for %%F in ("!scanDir!*.html") do (
    set /a dynCount+=1
    for /f %%K in ("!dynCount!") do call set "menuKey=%%_L%%K%%"
    set "file!dynCount!=%%~fF"
    set "label!dynCount!=%%~nxF [HTML]"
    set "choices=!choices!!menuKey!"
    echo  !menuKey!^) %%~nxF  [HTML]
)
for %%F in ("!scanDir!*.xhtml") do (
    set /a dynCount+=1
    for /f %%K in ("!dynCount!") do call set "menuKey=%%_L%%K%%"
    set "file!dynCount!=%%~fF"
    set "label!dynCount!=%%~nxF [XHTML]"
    set "choices=!choices!!menuKey!"
    echo  !menuKey!^) %%~nxF  [XHTML]
)
goto :eof

:end
endlocal
exit /b 0

REM ============================================================
REM  SUBROUTINES - PS7 Detection & Installation
REM ============================================================

:DetectPS7
REM Check if PowerShell 7 (pwsh.exe) is available
where pwsh >nul 2>&1
if %errorlevel%==0 (
    set "PS7_DETECTED=TRUE"
    goto :eof
)

REM Check registry for PS7 installation
reg query "HKLM\SOFTWARE\Microsoft\PowerShell\7\Install" /v Path >nul 2>&1
if %errorlevel%==0 (
    set "PS7_DETECTED=TRUE"
    goto :eof
)

REM Check common install path
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PS7_DETECTED=TRUE"
    goto :eof
)

set "PS7_DETECTED=FALSE"
goto :eof

:PromptPS7Install
cls
echo.
echo ╔═══════════════════════════════════════════════════════════════╗
echo ║  PowerShell 7 Not Detected                                    ║
echo ║  Install via winget for enhanced performance and features?    ║
echo ╚═══════════════════════════════════════════════════════════════╝
echo.
echo Press Y to install PowerShell 7 automatically
echo Press N (or wait 7 seconds) to skip and continue with PS 5.1
echo.

choice /C YN /T 7 /D N /N /M "Install PowerShell 7? [Y/N]: "
if %errorlevel%==1 (
    echo.
    echo Installing PowerShell 7 via winget...
    echo This may take a few minutes. Please wait...
    echo.
    winget install --id Microsoft.Powershell --source winget --silent --accept-package-agreements --accept-source-agreements
    
    if %errorlevel%==0 (
        echo.
        echo ╔═══════════════════════════════════════════════════════════════╗
        echo ║  Installation Successful!                                     ║
        echo ║  Restarting launcher with PowerShell 7...                     ║
        echo ╚═══════════════════════════════════════════════════════════════╝
        timeout /t 3 /nobreak >nul
        start "" "%~f0" %*
        exit /b 0
    ) else (
        echo.
        echo ╔═══════════════════════════════════════════════════════════════╗
        echo ║  Installation Failed                                          ║
        echo ║  Continuing with PowerShell 5.1...                            ║
        echo ╚═══════════════════════════════════════════════════════════════╝
        echo.
        echo Manual download available at: https://aka.ms/powershell-release?tag=stable
        timeout /t 5 /nobreak >nul
    )
) else (
    echo.
    echo Skipping PowerShell 7 installation. Continuing with PS 5.1...
    timeout /t 2 /nobreak >nul
)
goto :eof

REM ============================================================
REM  SUBROUTINES - Execution Policy Detection & Solution Menu
REM ============================================================

:DetectExecutionPolicy
powershell -NoProfile -Command "Get-ExecutionPolicy" > "%temp%\execpol.txt" 2>&1
set /p CURRENT_POLICY=<"%temp%\execpol.txt"
del "%temp%\execpol.txt" 2>nul

if /I "%CURRENT_POLICY%"=="Restricted" (
    set "EXEC_POLICY_BLOCKED=TRUE"
) else (
    set "EXEC_POLICY_BLOCKED=FALSE"
)
goto :eof

:ShowExecutionPolicyMenu
cls
echo.
echo ╔═════════════════════════════════════════════════════════════════════╗
echo ║  SCRIPT EXECUTION POLICY BLOCKED                                    ║
echo ║  Current Policy: %CURRENT_POLICY%                                           ║
echo ╚═════════════════════════════════════════════════════════════════════╝
echo.
echo  Select a solution method:
echo.
echo  1^) Bypass (Current Session Only) - ✓ RECOMMENDED
echo      Risk: LOW  │ Scope: This session only
echo      Use Case: Quick testing, no permanent changes
echo.
echo  2^) RemoteSigned (CurrentUser) - BALANCED
echo      Risk: MEDIUM  │ Scope: Current user only
echo      Use Case: Regular development, protects from remote scripts
echo      Admin: NOT REQUIRED
echo.
echo  3^) RemoteSigned (LocalMachine) - ENTERPRISE
echo      Risk: MEDIUM  │ Scope: All users on this machine
echo      Use Case: Organizational standard
echo      Admin: REQUIRED
echo.
echo  4^) Unrestricted (CurrentUser) - PERMISSIVE
echo      Risk: HIGH  │ Scope: Current user only
echo      Use Case: Heavy development, accepts all unsigned scripts
echo      Admin: NOT REQUIRED
echo.
echo  5^) View Manual Instructions
echo  6^) Continue Anyway (may fail)
echo.
echo ═════════════════════════════════════════════════════════════════════

choice /C 123456 /N /M "Select solution [1-6]: "
set "policyChoice=%errorlevel%"

call :ApplyScriptSecurityChoice %policyChoice%
goto :eof

REM ============================================================
REM  :ApplyScriptSecurityChoice <choice> - non-interactive apply
REM ============================================================
:ApplyScriptSecurityChoice
set "choice=%~1"

if "%choice%"=="1" (
    set "USE_BYPASS_FLAG=TRUE"
    goto :eof
)

if "%choice%"=="2" (
    powershell -NoProfile -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force" >nul 2>&1
    if %errorlevel%==0 (
        echo ✓ Execution policy set to RemoteSigned (CurrentUser)
    ) else (
        set "USE_BYPASS_FLAG=TRUE"
    )
    goto :eof
)

if "%choice%"=="3" (
    powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -Command Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force' -Wait" >nul 2>&1
    if %errorlevel%==0 (
        echo ✓ Execution policy set to RemoteSigned (LocalMachine)
    ) else (
        set "USE_BYPASS_FLAG=TRUE"
    )
    goto :eof
)

if "%choice%"=="4" (
    powershell -NoProfile -Command "Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force" >nul 2>&1
    if %errorlevel%==0 (
        echo ✓ Execution policy set to Unrestricted (CurrentUser)
    ) else (
        set "USE_BYPASS_FLAG=TRUE"
    )
    goto :eof
)

if "%choice%"=="5" (
    cls
    echo.
    echo ════════════════════════════════════════════════════════════════════
    echo  MANUAL EXECUTION POLICY INSTRUCTIONS
    echo ════════════════════════════════════════════════════════════════════
    echo.
    echo To manually set execution policy, open PowerShell and run:
    echo.
    echo   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    echo.
    echo Or to set for all users (requires admin):
    echo.
    echo   Set-ExecutionPolicy RemoteSigned -Scope LocalMachine
    echo.
    echo For more information, see:
    echo   https://docs.microsoft.com/powershell/module/microsoft.powershell.security/set-executionpolicy
    echo.
    pause
    REM Return to menu if interactive
    goto ShowExecutionPolicyMenu
)

if "%choice%"=="6" (
    set "USE_BYPASS_FLAG=TRUE"
    goto :eof
)

REM Default: bypass
set "USE_BYPASS_FLAG=TRUE"
goto :eof

REM ============================================================
REM  SUBROUTINES - Launch Logging
REM ============================================================

:LogLaunch
REM Ensure logs directory exists
if not exist "%scriptDir%logs\" mkdir "%scriptDir%logs\" 2>nul

REM Check if this is first launch (log file doesn't exist)
if not exist "%scriptDir%logs\Main-GUI_BATCH-LOG.log" (
    set "FIRST_LAUNCH=TRUE"
    REM Create CSV header
    echo Timestamp,BatchName,VersionTag,MachineName,Username,IPAddress,BatchPath,SystemVolume,SystemVolFreeSpace,MemoryUsedOfTotal,CPULoad,GPULoad,TotalProcesses,IsAdmin > "%scriptDir%logs\Main-GUI_BATCH-LOG.log"
)

REM Collect and append telemetry
powershell -ExecutionPolicy Bypass -NoProfile -Command "Import-Module '%scriptDir%modules\Get-LaunchTelemetry.psm1' -Force; Get-LaunchTelemetry -BatchName 'Launch-GUI.bat' -VersionTag '2604.B2.V31.0' -BatchPath '%~f0' | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Out-File '%scriptDir%logs\Main-GUI_BATCH-LOG.log' -Append -Encoding UTF8"

goto :eof
