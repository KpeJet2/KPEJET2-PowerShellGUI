# VersionTag: 2605.B2.V31.7
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

echo [INFO] Launching Service Cluster Dashboard...
"%PYTHON%" -m uvicorn server:app --host 127.0.0.1 --port 8099 --app-dir "%ROOT%"

endlocal

