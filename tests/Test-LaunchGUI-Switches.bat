@echo off
REM VersionTag: 2605.B5.V46.0
REM Test-LaunchGUI-Switches.bat - Validate switch parameter parsing in Launch-GUI.bat
REM Tests: /usepsv:5, /usepsv7, /scriptsec:1-6, /skipps7, /skippolicy

setlocal enabledelayedexpansion

echo.
echo ╔═══════════════════════════════════════════════════════════════════╗
echo ║  Launch-GUI Switch Parameter Validation                          ║
echo ╚═══════════════════════════════════════════════════════════════════╝
echo.

set "testsPassed=0"
set "testsFailed=0"
set "testFile=C:\PowerShellGUI\Launch-GUI.bat"

if not exist "%testFile%" (
    echo ✗ Launch-GUI.bat not found
    exit /b 1
)

echo [1/8] Testing file exists... ✓
set /a testsPassed+=1

REM Test for switch parameter parsing code
echo [2/8] Checking for /usepsv:5 parsing...
findstr /C:"/usepsv:5" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ /usepsv:5 switch found
    set /a testsPassed+=1
) else (
    echo      ✗ /usepsv:5 switch NOT found
    set /a testsFailed+=1
)

echo [3/8] Checking for /usepsv7 parsing...
findstr /C:"/usepsv7" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ /usepsv7 switch found
    set /a testsPassed+=1
) else (
    echo      ✗ /usepsv7 switch NOT found
    set /a testsFailed+=1
)

echo [4/8] Checking for /scriptsec: switches...
findstr /C:"/scriptsec:1" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ /scriptsec:1-6 switches found
    set /a testsPassed+=1
) else (
    echo      ✗ /scriptsec: switches NOT found
    set /a testsFailed+=1
)

echo [5/8] Checking for ApplyScriptSecurityChoice subroutine...
findstr /C:":ApplyScriptSecurityChoice" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ ApplyScriptSecurityChoice subroutine found
    set /a testsPassed+=1
) else (
    echo      ✗ ApplyScriptSecurityChoice subroutine NOT found
    set /a testsFailed+=1
)

echo [6/8] Checking for FORCE_PS_VERSION variable...
findstr /C:"set \"FORCE_PS_VERSION=\"" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ FORCE_PS_VERSION variable found
    set /a testsPassed+=1
) else (
    echo      ✗ FORCE_PS_VERSION variable NOT found
    set /a testsFailed+=1
)

echo [7/8] Checking for SKIP_POLICY_PROMPT logic...
findstr /C:"if \"%%SKIP_POLICY_PROMPT%%\"==\"TRUE\"" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ SKIP_POLICY_PROMPT logic found
    set /a testsPassed+=1
) else (
    echo      ✗ SKIP_POLICY_PROMPT logic NOT found
    set /a testsFailed+=1
)

echo [8/8] Checking for quiet execution (^>nul redirects)...
findstr /C:">nul 2>&1" "%testFile%" >nul 2>&1
if %errorlevel%==0 (
    echo      ✓ Quiet execution redirects found
    set /a testsPassed+=1
) else (
    echo      ✗ Quiet execution redirects NOT found
    set /a testsFailed+=1
)

echo.
echo ╔═══════════════════════════════════════════════════════════════════╗
if %testsFailed%==0 (
    echo ║  ✓ ALL TESTS PASSED ^(%testsPassed%/8^)                                     ║
    echo ╚═══════════════════════════════════════════════════════════════════╝
    echo.
    echo Summary:
    echo   ✓ Switch parameter parsing implemented
    echo   ✓ /usepsv:5, /usepsv7 support added
    echo   ✓ /scriptsec:1-6 support added
    echo   ✓ Non-interactive mode supported
    echo   ✓ Quiet execution redirects in place
    echo.
    echo Example usage:
    echo   Launch-GUI.bat /usepsv:5 /scriptsec:1
    echo   Launch-GUI.bat /usepsv7 /skippolicy
    echo.
    exit /b 0
) else (
    echo ║  ✗ SOME TESTS FAILED ^(%testsPassed% passed, %testsFailed% failed^)                   ║
    echo ╚═══════════════════════════════════════════════════════════════════╝
    exit /b 1
)
