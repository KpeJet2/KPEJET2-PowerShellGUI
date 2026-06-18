@echo off
setlocal EnableExtensions

REM VersionTag: 2605.B5.V46.0
set "ROOT=%~dp0.."
set "MD=%ROOT%\docs\Qik-GU-ide-CheatSheet.md"
set "XHTML=%ROOT%\docs\Qik-GU-ide-CheatSheet.xhtml"
set "PDF=%ROOT%\docs\Qik-GU-ide-CheatSheet.pdf"

echo.
echo Qik-GU-ide CLI
if "%~1"=="open-md" goto openmd
if "%~1"=="open-xhtml" goto openxhtml
if "%~1"=="open-pdf" goto openpdf
if "%~1"=="build-pdf" goto buildpdf
if "%~1"=="help" goto usage

echo Usage:
echo   %~n0 open-md
echo   %~n0 open-xhtml
echo   %~n0 open-pdf
echo   %~n0 build-pdf
echo   %~n0 help
goto :eof

:openmd
if exist "%MD%" start "" "%MD%"
goto :eof

:openxhtml
if exist "%XHTML%" start "" "%XHTML%"
goto :eof

:openpdf
if exist "%PDF%" (
  start "" "%PDF%"
) else (
  echo PDF not found. Run: %~n0 build-pdf
)
goto :eof

:buildpdf
if not exist "%XHTML%" (
  echo Source XHTML not found: %XHTML%
  exit /b 1
)

set "EDGE1=C:\Program Files\Microsoft\Edge\Application\msedge.exe"
set "EDGE2=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "CHROME1=C:\Program Files\Google\Chrome\Application\chrome.exe"
set "CHROME2=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"

if exist "%EDGE1%" goto edge
if exist "%EDGE2%" (
  set "EDGE1=%EDGE2%"
  goto edge
)
if exist "%CHROME1%" goto chrome
if exist "%CHROME2%" (
  set "CHROME1=%CHROME2%"
  goto chrome
)

echo No Edge or Chrome executable found for headless PDF generation.
exit /b 2

:edge
"%EDGE1%" --headless --disable-gpu --print-to-pdf="%PDF%" "file:///%XHTML:\=/%"
if errorlevel 1 exit /b 3
echo Generated: %PDF%
exit /b 0

:chrome
"%CHROME1%" --headless --disable-gpu --print-to-pdf="%PDF%" "file:///%XHTML:\=/%"
if errorlevel 1 exit /b 4
echo Generated: %PDF%
exit /b 0

:usage
echo Qik-GU-ide CLI helper for markdown/xhtml/pdf assets.
exit /b 0
