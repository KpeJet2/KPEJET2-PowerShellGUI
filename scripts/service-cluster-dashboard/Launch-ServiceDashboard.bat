# VersionTag: 2605.B5.V46.0
@echo off
setlocal

set "ROOT=%~dp0"
set "WORKSPACE=%ROOT%..\.."
set "VENV=%WORKSPACE%\.venv"
set "PYTHON=%VENV%\Scripts\python.exe"
set "PIP=%VENV%\Scripts\pip.exe"

if not exist "%PYTHON%" (
  echo [ERROR] Python virtual environment not found at "%VENV%".
  echo Create it first: py -3 -m venv "%VENV%"
  exit /b 1
)

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
"%PYTHON%" -m uvicorn server:app --host 127.0.0.1 --port 8099 --app-dir "%APPDIR%"
set "EXITCODE=%ERRORLEVEL%"
popd

endlocal & exit /b %EXITCODE%

