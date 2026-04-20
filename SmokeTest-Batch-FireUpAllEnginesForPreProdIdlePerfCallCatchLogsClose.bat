REM VersionTag: 2604.B2.V31.1
REM VersionBuildHistory:
REM   2604.B2.V31.1  2026-04-12  Bootstrap PSModulePath so engine scripts find modules by name
REM   2604.B2.V31.0  2026-04-12  Initial final smoke-chain engine batch orchestrator
REM ============================================================
REM  SmokeTest-Batch-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose.bat
REM  Purpose  : Final step in smoke-test chains. Runs core validation engines
REM             one-by-one, captures pass/fail, logs results, and returns a
REM             non-zero exit code when any engine fails.
REM ============================================================
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "workspacePath=%scriptDir:~0,-1%"
set "noPause=FALSE"

REM ── Bootstrap: modules must be findable when engine test scripts load them by name.
set "PSModulePath=%scriptDir%modules;%PSModulePath%"

for %%A in (%*) do (
    if /I "%%~A"=="/NOPAUSE" set "noPause=TRUE"
)

if not exist "%scriptDir%logs" mkdir "%scriptDir%logs" >nul 2>&1
set "logFile=%scriptDir%logs\SmokeTest-Batch-FireUpAllEngines.log"

echo ============================================================>>"%logFile%"
echo [%date% %time%] FireUpAllEngines run started>>"%logFile%"
echo ============================================================>>"%logFile%"

set "PS_CMD=powershell.exe"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 set "PS_CMD=pwsh.exe"

set /a total=0
set /a failed=0

echo.
echo ============================================================
echo  FireUpAllEngines -- PreProd Idle Perf Call Catch Logs Close
echo ============================================================
echo Host: %PS_CMD%
echo Log : %logFile%
echo.

call :RunStep "PreCommitValidation" "tests\Invoke-PreCommitValidation.ps1" -WorkspacePath "%workspacePath%" -Quiet
call :RunStep "SINPatternScanner" "tests\Invoke-SINPatternScanner.ps1" -WorkspacePath "%workspacePath%"
call :RunStep "SecurityIntegrityTests" "tests\Invoke-SecurityIntegrityTests.ps1" -WorkspacePath "%workspacePath%" -Mode Advisory
call :RunStep "RunAllTests-PesterOnly" "tests\Run-AllTests.ps1" -PesterOnly
call :RunStep "RunAllTests-SmokeShellMatrix" "tests\Run-AllTests.ps1" -SmokeOnly -IncludeShellMatrix
call :RunStep "ChaosConditions-Headless" "tests\Invoke-ChaosTestConditions.ps1" -WorkspacePath "%workspacePath%" -RunSmokeTest -HeadlessOnly
call :RunStep "ScriptsFileTypeRoutine" "SmokeTest-Scripts-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose.bat"
call :RunStep "HtmlFileTypeRoutine" "SmokeTest-HTML-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose.bat"

echo.>>"%logFile%"
echo [%date% %time%] FireUpAllEngines completed: total=%total%, failed=%failed%>>"%logFile%"
echo.
echo Summary: total=%total%, failed=%failed%

if "%noPause%"=="FALSE" (
    echo.
    echo Press any key to close.
    pause >nul
)

if %failed% gtr 0 (
    exit /b 1
)
exit /b 0

:RunStep
set /a total+=1
set "stepName=%~1"
set "stepScript=%~2"
shift
shift
set "stepArgs=%*"

echo ------------------------------------------------------------
echo [STEP %total%] %stepName%
echo ------------------------------------------------------------
echo [%date% %time%] START %stepName%>>"%logFile%"
echo CMD: %PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%%stepScript%" %stepArgs%>>"%logFile%"

%PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%scriptDir%%stepScript%" %stepArgs%
set "rc=%errorlevel%"

if not "!rc!"=="0" (
    set /a failed+=1
    echo [FAIL] %stepName% exit=!rc!
    echo [%date% %time%] FAIL  %stepName%  rc=!rc!>>"%logFile%"
) else (
    echo [PASS] %stepName%
    echo [%date% %time%] PASS  %stepName%>>"%logFile%"
)
exit /b 0
