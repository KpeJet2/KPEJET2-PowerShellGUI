# VersionTag: 2605.B5.V46.0
@echo off
REM  Launch-SandboxBrowserTest.bat -- Run browser compatibility tests in Windows Sandbox
REM  Tests all HTML/XHTML files and README.md content in Edge, Chrome, and Firefox.
REM  Results are archived in encrypted 7zip on sandbox desktop.
title PwShGUI Sandbox Browser Compatibility Test
echo.
echo ============================================================
echo   PwShGUI Sandbox Browser Compatibility Test
echo ============================================================
echo.
echo   Tests ALL HTML/XHTML files in Edge (mandatory),
echo   Chrome and Firefox (if available, auto-installs Firefox).
echo   Validates links, tabs, forms, tooltips, invocations,
echo   resources, and data-state changes. Logs failures as
echo   Bugs2FIX and gaps as 2DO tasks. Archives results in
echo   encrypted 7zip.
echo.

REM Check Windows Sandbox
where WindowsSandbox.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%SystemRoot%\System32\WindowsSandbox.exe" (
        echo [FAIL] Windows Sandbox not found.
        echo        Enable via: Settings - Apps - Optional Features - More Windows Features
        echo        Requires Windows 10/11 Pro or Enterprise.
        pause
        exit /b 1
    )
)

REM Detect PowerShell 7
set PS_CMD=powershell.exe
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] PowerShell 7 detected -- using pwsh.exe
    set PS_CMD=pwsh.exe
) else (
    echo [INFO] Using PowerShell 5.1
)

echo.
echo Select test mode:
echo   1. Full browser test (Edge + Chrome + Firefox, HTML + README)
echo   2. Edge-only quick test (HTML only)
echo   3. HTML/XHTML only (all browsers, no README)
echo   4. Full test with data-state polling (adds ~10 min per file)
echo.
set /p CHOICE="Choice [1-4]: "

set EXTRA_ARGS=
if "%CHOICE%"=="1" (
    set EXTRA_ARGS=-IncludeReadme -SkipDataState
) else if "%CHOICE%"=="2" (
    set EXTRA_ARGS=-EdgeOnly -HtmlOnly -SkipDataState
) else if "%CHOICE%"=="3" (
    set EXTRA_ARGS=-HtmlOnly -SkipDataState
) else if "%CHOICE%"=="4" (
    set EXTRA_ARGS=-IncludeReadme
) else (
    echo Invalid choice. Running default: Edge-only quick test.
    set EXTRA_ARGS=-EdgeOnly -HtmlOnly -SkipDataState
)

echo.
echo [INFO] Launching sandbox browser test...
echo [INFO] This will open a Windows Sandbox, install browsers/drivers,
echo [INFO] and run automated tests. This may take 15-60 minutes.
echo.

REM Generate a temporary bootstrap that chains: Install deps -> Run tests -> Archive
set BOOTSTRAP_SCRIPT=%TEMP%\pwshgui-browser-test-bootstrap.ps1
(
echo param([string]$SourcePath = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source'^)
echo $OutputPath = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output'
echo $LocalPath = 'C:\PwShGUI-Test'
echo New-Item -ItemType Directory -Path $OutputPath -Force ^| Out-Null
echo Write-Host '[1/4] Copying workspace...' -ForegroundColor Cyan
echo Copy-Item $SourcePath $LocalPath -Recurse -Force
echo Write-Host '[2/4] Installing browser dependencies...' -ForegroundColor Cyan
echo $manifest = ^& "$LocalPath\tests\sandbox\Install-BrowserTestDependencies.ps1" -WorkspacePath $LocalPath -OutputPath $OutputPath
echo Write-Host '[3/4] Running browser test suite...' -ForegroundColor Cyan
echo ^& "$LocalPath\tests\sandbox\Invoke-SandboxBrowserTestSuite.ps1" -WorkspacePath $LocalPath -OutputPath $OutputPath %EXTRA_ARGS%
echo Write-Host '[4/4] Creating encrypted archive...' -ForegroundColor Cyan
echo ^& "$LocalPath\tests\sandbox\Export-SandboxTestArchive.ps1" -OutputPath $OutputPath
echo Write-Host 'Browser test complete. Results on Desktop.' -ForegroundColor Green
echo Start-Sleep -Seconds 5
) > "%BOOTSTRAP_SCRIPT%"

REM Generate .wsb configuration
set WSB_FILE=%TEMP%\PwShGUI-BrowserTest.wsb
(
echo ^<Configuration^>
echo   ^<MappedFolders^>
echo     ^<MappedFolder^>
echo       ^<HostFolder^>%~dp0^</HostFolder^>
echo       ^<SandboxFolder^>C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source^</SandboxFolder^>
echo       ^<ReadOnly^>true^</ReadOnly^>
echo     ^</MappedFolder^>
echo   ^</MappedFolders^>
echo   ^<LogonCommand^>
echo     ^<Command^>powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source\tests\sandbox\Invoke-SandboxBootstrap.ps1" -SourcePath "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source" -LocalPath "C:\PwShGUI-Test"^</Command^>
echo   ^</LogonCommand^>
echo   ^<MemoryInMB^>4096^</MemoryInMB^>
echo   ^<Networking^>Enable^</Networking^>
echo   ^<vGPU^>Enable^</vGPU^>
echo ^</Configuration^>
) > "%WSB_FILE%"

echo [INFO] Starting Windows Sandbox...
start "" "%WSB_FILE%"

echo.
echo [INFO] Sandbox launched. Use Send-SandboxCommand.ps1 to send:
echo        ^& tests\sandbox\Send-SandboxCommand.ps1 -Action BrowserTest
echo.
echo [INFO] Or wait for tests to complete. Results will appear on sandbox desktop.
echo [INFO] Archive will be in: C:\Users\WDAGUtilityAccount\Desktop\
echo.
pause
exit /b 0

