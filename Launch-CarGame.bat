REM VersionTag: 2605.B5.V46.0
REM ============================================================
REM  Launch-CarGame.bat  |  Slipstream City Launcher
REM  Author   : GitHub Copilot
REM  Version  : 2603.B0.v1.0
REM  Modified : 31 Mar 2026
REM  Purpose  : Launches CarGame with a pygame-capable Python env.
REM             Priority order:
REM             1) .venv-pygame312
REM             2) .venv
REM             3) py -3.12
REM             4) python
REM ============================================================
@echo off
setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "gameFile=%scriptDir%CarGame"
set "pythonExe="
set "args=%*"

if not exist "%gameFile%" (
    echo Error: CarGame not found in %scriptDir%
    pause
    exit /b 1
)

if exist "%scriptDir%.venv-pygame312\Scripts\python.exe" (
    set "pythonExe=%scriptDir%.venv-pygame312\Scripts\python.exe"
) else if exist "%scriptDir%.venv\Scripts\python.exe" (
    set "pythonExe=%scriptDir%.venv\Scripts\python.exe"
)

if defined pythonExe goto run_game

where py >nul 2>nul
if not errorlevel 1 (
    set "pythonExe=py -3.12"
    goto run_game
)

where python >nul 2>nul
if not errorlevel 1 (
    set "pythonExe=python"
    goto run_game
)

echo Error: No Python runtime found.
echo Install Python 3.12 and run: py -3.12 -m venv .venv-pygame312
pause
exit /b 1

:run_game
cls
echo ============================================================
echo  Slipstream City Launcher
echo ============================================================
echo Runtime: %pythonExe%
echo Args   : %args%
echo.

%pythonExe% "%gameFile%" %args%
set "exitCode=%errorlevel%"

if not "%exitCode%"=="0" (
    echo.
    echo CarGame exited with code %exitCode%
)

endlocal & exit /b %exitCode%
