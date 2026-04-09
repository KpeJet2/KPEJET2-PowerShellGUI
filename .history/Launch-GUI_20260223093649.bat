REM VersionTag: 2602.a.11
REM ============================================================
REM  Launch-GUI.bat  |  PowerShell GUI Application Loader
REM  Author   : The Establishment
REM  Version  : 2602.a.11
REM  Modified : 22 Feb 2026
REM  Purpose  : Top-level launcher. Presents a numbered menu to
REM             select quik_jnr, slow_snr, or any discovered
REM             .bat / .ps1 / .html file in the root folder.
REM  Usage    : Double-click or run from any prompt.
REM             Default (7 s timeout): 1 = quik_jnr fast mode
REM ============================================================
@echo off

setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "quickLauncher=%scriptDir%Launch-GUI-quik_jnr.bat"
set "slowLauncher=%scriptDir%Launch-GUI-slow_snr.bat"

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

cls
echo ============================================================
echo  PowerShell GUI Application Loader
echo ============================================================
echo.
echo Select startup profile:
echo.
echo  1^) Launch-GUI-quik_jnr   ^(fast startup mode^)
echo  2^) Launch-GUI-slow_snr   ^(full checks mode^)
echo.

REM --- Dynamically list files from each DynamicMenuFolder ---
set "idx=2"
for /L %%D in (1,1,%DynamicMenuFolderCount%) do (
    call :scanFolder "!DynamicMenuFolder%%D!"
)

echo.
echo Default in 7 seconds: 1 ^(quik_jnr^)
echo.

REM Build valid choice string dynamically
set "choices=12"
set "maxIdx=!idx!"
for /L %%N in (3,1,!maxIdx!) do set "choices=!choices!%%N"

choice /C !choices! /N /T 7 /D 1 /M "Enter number to select: "
set "userChoice=!errorlevel!"

REM --- Handle fixed selections ---
if "!userChoice!"=="1" (
    call "%quickLauncher%"
    goto end
)
if "!userChoice!"=="2" (
    call "%slowLauncher%"
    goto end
)

REM --- Handle dynamic file selections ---
for /L %%N in (3,1,%maxIdx%) do (
    if "!userChoice!"=="%%N" (
        set "selectedFile=!file%%N!"
        set "selectedLabel=!label%%N!"

        echo !selectedLabel! | findstr /I "\[PS1\]" >nul
        if !errorlevel!==0 (
            powershell.exe -ExecutionPolicy Bypass -File "!selectedFile!"
            goto end
        )

        echo !selectedLabel! | findstr /I "\[HTML\]" >nul
        if !errorlevel!==0 (
            start "" "!selectedFile!"
            goto end
        )

        echo !selectedLabel! | findstr /I "\[XHTML\]" >nul
        if !errorlevel!==0 (
            start "" "!selectedFile!"
            goto end
        )

        REM Default: run as .bat
        call "!selectedFile!"
        goto end
    )
)

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
                set /a idx+=1
                set "file!idx!=%%~fF"
                set "label!idx!=!fname! [BAT]"
                echo  !idx!^) !fname!  [BAT]
            )
        )
    )
)
for %%F in ("!scanDir!*.ps1") do (
    set /a idx+=1
    set "file!idx!=%%~fF"
    set "label!idx!=%%~nxF [PS1]"
    echo  !idx!^) %%~nxF  [PS1]
)
for %%F in ("!scanDir!*.html") do (
    set /a idx+=1
    set "file!idx!=%%~fF"
    set "label!idx!=%%~nxF [HTML]"
    echo  !idx!^) %%~nxF  [HTML]
)
for %%F in ("!scanDir!*.xhtml") do (
    set /a idx+=1
    set "file!idx!=%%~fF"
    set "label!idx!=%%~nxF [XHTML]"
    echo  !idx!^) %%~nxF  [XHTML]
)
goto :eof

:end
endlocal












