@echo off
setlocal EnableExtensions
REM VersionTag: 2608.B1.V54.2
REM Compatibility shim: forwards legacy launcher name to renamed menu file.
set "SCRIPT_DIR=%~dp0"
set "TARGET=%SCRIPT_DIR%ALL-Start-Menu_Service_Checks-n-Trays.bat"
if not exist "%TARGET%" (
    echo [ERROR] Renamed launcher not found: %TARGET%
    exit /b 1
)
call "%TARGET%" %*
exit /b %ERRORLEVEL%
