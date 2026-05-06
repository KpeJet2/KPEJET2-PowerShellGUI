REM VersionTag: 2604.B2.V31.1
REM VersionBuildHistory:
REM   2604.B2.V31.1  2026-04-12  Inject PSModulePath; option 2 now auto-persists
REM   2604.B2.V31.0  2026-04-04  Initial creation - First Run Configuration Menu
REM ============================================================
REM  Launch-CFRMenu.bat  |  First Run Configuration Menu
REM  Author   : The Establishment
REM  Version  : 2604.B2.V31.0
REM  Modified : 04 Apr 2026
REM  Purpose  : First-time user configuration and diagnostic menu.
REM             Provides 14 pre-flight checks, diagnostics, security
REM             scans, and quick launchers. Automatically triggered on
REM             first Launch-GUI.bat run. ESC returns to main menu.
REM  Usage    : Auto-launched on first run, or call directly.
REM ============================================================
@echo off

setlocal enabledelayedexpansion

set "scriptDir=%~dp0"
set "modulesDir=%scriptDir%modules"
set "scriptsDir=%scriptDir%scripts"
set "testsDir=%scriptDir%tests"

REM ── Bootstrap: ensure modules are findable by all child PowerShell processes.
set "PSModulePath=%scriptDir%modules;%PSModulePath%"

REM ============================================================
REM  Main Menu Loop
REM ============================================================
:menu
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  FIRST RUN CONFIGURATION MENU (CFRMenu)                               ║
echo ║  PowerShellGUI v2604.B1 - Initial Setup Assistant                     ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo  PRE-FLIGHT CHECKS ^& FIXES
echo  ──────────────────────────────────────────────────────────────────────
echo   1^) Run Full Prerequisite Check ^(modules, paths, permissions^)
echo   2^) Repair Module Import Paths ^(fix missing PSModulePath entries^)
echo   3^) Test PowerShell Compatibility ^(PS 5.1 vs PS 7 feature check^)
echo   4^) Validate SIN Governance Registry ^(integrity check^)
echo   5^) Initialize CronAiAthon Scheduler ^(first-run setup^)
echo.
echo  SYSTEM DIAGNOSTICS ^& REPORTS
echo  ──────────────────────────────────────────────────────────────────────
echo   6^) Generate Full System Report ^(save to ~REPORTS/^)
echo   7^) Export Module Dependency Graph ^(HTML visualization^)
echo   8^) Run Network Connectivity Tests ^(DNS, HTTP, Azure endpoints^)
echo   9^) Check Disk Space ^& Clean Temp Files
echo  10^) Baseline Performance Metrics ^(CPU/RAM/Disk for comparison^)
echo.
echo  SECURITY ^& COMPLIANCE
echo  ──────────────────────────────────────────────────────────────────────
echo  11^) Run SIN Pattern Scanner ^(find blocking anti-patterns^)
echo  12^) Audit Execution Policy Configuration ^(current settings^)
echo  13^) Check for Hardcoded Secrets ^(security scan^)
echo  14^) Validate File Encodings ^(UTF-8 BOM check for Unicode files^)
echo.
echo  QUICK LAUNCHER WIDGETS
echo  ──────────────────────────────────────────────────────────────────────  
echo   A^) Launch-GUI-quik_jnr.bat ^(fast startup^)
echo   B^) Launch-GUI-slow_snr.bat ^(full checks^)
echo   C^) Launch-SandboxInteractive.bat
echo   D^) Launch-ChaosTest.bat
echo   E^) Launch-CarGame.bat
echo   F^) View-Config.ps1
echo.
echo   0^) Exit to Main GUI Menu
echo.
echo ═══════════════════════════════════════════════════════════════════════

REM Use choice with expanded character set
choice /C 1234567890ABCDEF /N /M "Enter choice [1-14, A-F, 0=Exit]: "
set "userChoice=%errorlevel%"

REM Map errorlevel to selections
if "%userChoice%"=="1" goto option1
if "%userChoice%"=="2" goto option2
if "%userChoice%"=="3" goto option3
if "%userChoice%"=="4" goto option4
if "%userChoice%"=="5" goto option5
if "%userChoice%"=="6" goto option6
if "%userChoice%"=="7" goto option7
if "%userChoice%"=="8" goto option8
if "%userChoice%"=="9" goto option9
if "%userChoice%"=="10" goto option0_exit
if "%userChoice%"=="11" goto optionA
if "%userChoice%"=="12" goto optionB
if "%userChoice%"=="13" goto optionC
if "%userChoice%"=="14" goto optionD
if "%userChoice%"=="15" goto optionE
if "%userChoice%"=="16" goto optionF

REM Default fallback
goto menu

REM ============================================================
REM  Option 1: Run Full Prerequisite Check
REM ============================================================
:option1
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Running Full Prerequisite Check...                                  ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptsDir%\Test-Prerequisites.ps1"
echo.
pause
goto menu

REM ============================================================
REM  Option 2: Repair Module Import Paths
REM ============================================================
:option2
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Repairing Module Import Paths...                                    ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptsDir%\Repair-ModulePaths.ps1" -Persist
echo.
pause
goto menu

REM ============================================================
REM  Option 3: Test PowerShell Compatibility
REM ============================================================
:option3
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  PowerShell Compatibility Test                                       ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Current PowerShell Version:
powershell -NoProfile -Command "$PSVersionTable | Format-List PSVersion, PSEdition, CLRVersion, BuildVersion"
echo.
echo Testing PS 5.1 vs PS 7 Features:
powershell -NoProfile -Command "Write-Host '  - Null-coalescing operator (??):' -NoNewline; try { $null -as [string] ?? 'default' | Out-Null; Write-Host ' AVAILABLE (PS7)' -ForegroundColor Green } catch { Write-Host ' NOT AVAILABLE (PS5.1)' -ForegroundColor Yellow }"
powershell -NoProfile -Command "Write-Host '  - Null-conditional operator (?.):' -NoNewline; try { $null?.Property | Out-Null; Write-Host ' AVAILABLE (PS7)' -ForegroundColor Green } catch { Write-Host ' NOT AVAILABLE (PS5.1)' -ForegroundColor Yellow }"
powershell -NoProfile -Command "Write-Host '  - ForEach-Object -Parallel:' -NoNewline; if ($PSVersionTable.PSVersion.Major -ge 7) { Write-Host ' AVAILABLE (PS7)' -ForegroundColor Green } else { Write-Host ' NOT AVAILABLE (PS5.1)' -ForegroundColor Yellow }"
echo.
pause
goto menu

REM ============================================================
REM  Option 4: Validate SIN Governance Registry
REM ============================================================
:option4
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Validating SIN Governance Registry...                               ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Checking SIN pattern definition files...
if exist "%scriptDir%sin_registry\" (
    dir /B "%scriptDir%sin_registry\SIN-PATTERN-*.json" 2>nul
    dir /B "%scriptDir%sin_registry\SEMI-SIN-*.json" 2>nul
    echo.
    echo SIN Registry Integrity: OK
) else (
    echo ERROR: sin_registry directory not found!
)
echo.
pause
goto menu

REM ============================================================
REM  Option 5: Initialize CronAiAthon Scheduler
REM ============================================================
:option5
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Initializing CronAiAthon Scheduler...                               ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
powershell -ExecutionPolicy Bypass -NoProfile -Command "Import-Module '%modulesDir%\CronAiAthon-Scheduler.psm1' -Force; Start-CronScheduler -Verbose"
echo.
pause
goto menu

REM ============================================================
REM  Option 6: Generate Full System Report
REM ============================================================
:option6
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Generating Full System Report...                                    ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptsDir%\Export-SystemReport.ps1"
echo.
pause
goto menu

REM ============================================================
REM  Option 7: Export Module Dependency Graph
REM ============================================================
:option7
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Exporting Module Dependency Graph...                                ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
if exist "%scriptDir%Dependency-Visualisation.html" (
    echo Opening existing dependency visualization...
    start "" "%scriptDir%Dependency-Visualisation.html"
) else (
    echo Dependency visualization HTML not found.
    echo Check for Build-DependencyGraph.ps1 or similar script.
)
echo.
pause
goto menu

REM ============================================================
REM  Option 8: Run Network Connectivity Tests
REM ============================================================
:option8
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Running Network Connectivity Tests...                               ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo [1/4] Testing DNS resolution (8.8.8.8)...
powershell -NoProfile -Command "if (Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet) { Write-Host '  ✓ DNS OK' -ForegroundColor Green } else { Write-Host '  ✗ DNS FAILED' -ForegroundColor Red }"
echo.
echo [2/4] Testing HTTP connectivity (google.com)...
powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://www.google.com' -UseBasicParsing -TimeoutSec 5 | Out-Null; Write-Host '  ✓ HTTP OK' -ForegroundColor Green } catch { Write-Host '  ✗ HTTP FAILED' -ForegroundColor Red }"
echo.
echo [3/4] Testing Azure endpoint (azure.microsoft.com)...
powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://azure.microsoft.com' -UseBasicParsing -TimeoutSec 5 | Out-Null; Write-Host '  ✓ Azure OK' -ForegroundColor Green } catch { Write-Host '  ✗ Azure FAILED' -ForegroundColor Red }"
echo.
echo [4/4] Resolving DNS for github.com...
powershell -NoProfile -Command "try { Resolve-DnsName -Name 'github.com' -ErrorAction Stop | Out-Null; Write-Host '  ✓ GitHub DNS OK' -ForegroundColor Green } catch { Write-Host '  ✗ GitHub DNS FAILED' -ForegroundColor Red }"
echo.
pause
goto menu

REM ============================================================
REM  Option 9: Check Disk Space & Clean Temp Files
REM ============================================================
:option9
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Disk Space Check ^& Temp File Cleanup                                ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Current Disk Space:
powershell -NoProfile -Command "Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free } | Format-Table Name, @{Label='Used(GB)';Expression={[math]::Round(($_.Used/1GB),2)}}, @{Label='Free(GB)';Expression={[math]::Round(($_.Free/1GB),2)}}, @{Label='Total(GB)';Expression={[math]::Round((($_.Used+$_.Free)/1GB),2)}} -AutoSize"
echo.
echo Temp Directory Sizes:
powershell -NoProfile -Command "$tempSize = (Get-ChildItem -Path $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum; Write-Host \"  User Temp ($env:TEMP): $([math]::Round($tempSize/1MB,2)) MB\""
echo.
set /P "cleanTemp=Do you want to clean temp files? [Y/N]: "
if /I "%cleanTemp%"=="Y" (
    echo Cleaning temp files...
    del /F /Q "%TEMP%\*" 2>nul
    echo Done.
)
echo.
pause
goto menu

REM ============================================================
REM  Option 10: Baseline Performance Metrics
REM ============================================================
:option10
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Capturing Baseline Performance Metrics...                           ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
powershell -NoProfile -Command "$baseline = @{}; $baseline.Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $os = Get-CimInstance Win32_OperatingSystem; $baseline.MemoryUsedGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2); $baseline.MemoryTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2); $cpu = Get-CimInstance Win32_Processor; $baseline.CPULoad = $cpu.LoadPercentage; $baseline.ProcessCount = (Get-Process).Count; $baseline | Format-List; $reportPath = Join-Path '%scriptDir%~REPORTS' 'Baseline_Metrics.txt'; if (-not (Test-Path (Split-Path $reportPath))) { New-Item -ItemType Directory -Path (Split-Path $reportPath) -Force | Out-Null }; $baseline | Out-File -FilePath $reportPath -Encoding UTF8 -Append; Write-Host \"`nBaseline saved to: $reportPath\" -ForegroundColor Green"
echo.
pause
goto menu

REM ============================================================
REM  Option 11: Run SIN Pattern Scanner
REM ============================================================
:option11
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Running SIN Pattern Scanner...                                      ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
if exist "%testsDir%\Invoke-SINPatternScanner.ps1" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%testsDir%\Invoke-SINPatternScanner.ps1"
) else (
    echo ERROR: SIN Pattern Scanner not found at:
    echo %testsDir%\Invoke-SINPatternScanner.ps1
)
echo.
pause
goto menu

REM ============================================================
REM  Option 12: Audit Execution Policy Configuration
REM ============================================================
:option12
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Execution Policy Audit                                              ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Current Execution Policies by Scope:
powershell -NoProfile -Command "Get-ExecutionPolicy -List | Format-Table -AutoSize"
echo.
echo Effective Execution Policy:
powershell -NoProfile -Command "Write-Host '  ' (Get-ExecutionPolicy) -ForegroundColor Cyan"
echo.
pause
goto menu

REM ============================================================
REM  Option 13: Check for Hardcoded Secrets
REM ============================================================
:option13
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Scanning for Hardcoded Secrets...                                   ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Searching for common secret patterns in PowerShell files...
powershell -NoProfile -Command "$patterns = @('API_KEY', 'APIKEY', 'PASSWORD', 'SECRET', 'TOKEN', 'CREDENTIAL'); $files = Get-ChildItem -Path '%scriptDir%' -Filter '*.ps*1' -Recurse -ErrorAction SilentlyContinue; $findings = @(); foreach ($file in $files) { $content = Get-Content $file.FullName -ErrorAction SilentlyContinue; foreach ($line in $content) { foreach ($pattern in $patterns) { if ($line -match \"$pattern\s*=\") { $findings += \"$($file.Name): $line\"; } } } }; if ($findings.Count -gt 0) { Write-Host \"Found $($findings.Count) potential secret references:\" -ForegroundColor Yellow; $findings | ForEach-Object { Write-Host \"  $_\" -ForegroundColor Yellow }; } else { Write-Host \"No obvious hardcoded secrets found.\" -ForegroundColor Green; }"
echo.
pause
goto menu

REM ============================================================
REM  Option 14: Validate File Encodings
REM ============================================================
:option14
cls
echo ╔═══════════════════════════════════════════════════════════════════════╗
echo ║  Validating File Encodings ^(UTF-8 BOM Check^)...                      ║
echo ╚═══════════════════════════════════════════════════════════════════════╝
echo.
echo Checking PowerShell files for UTF-8 BOM...
powershell -NoProfile -Command "$files = Get-ChildItem -Path '%scriptDir%' -Include '*.ps1','*.psm1' -Recurse -ErrorAction SilentlyContinue; $noBomFiles = @(); foreach ($file in $files) { $bytes = [System.IO.File]::ReadAllBytes($file.FullName); if ($bytes.Length -ge 3) { $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF); if (-not $hasBom) { $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue; if ($content -match '[^\x00-\x7F]') { $noBomFiles += $file.FullName; } } } }; if ($noBomFiles.Count -gt 0) { Write-Host \"Found $($noBomFiles.Count) files with Unicode chars but no BOM:\" -ForegroundColor Yellow; $noBomFiles | ForEach-Object { Write-Host \"  $_\" -ForegroundColor Yellow }; } else { Write-Host \"All files with Unicode characters have UTF-8 BOM.\" -ForegroundColor Green; }"
echo.
pause
goto menu

REM ============================================================
REM  Quick Launcher Options (A-F)
REM ============================================================
:optionA
call "%scriptDir%Launch-GUI-quik_jnr.bat"
goto menu

:optionB
call "%scriptDir%Launch-GUI-slow_snr.bat"
goto menu

:optionC
if exist "%scriptDir%Launch-SandboxInteractive.bat" (
    call "%scriptDir%Launch-SandboxInteractive.bat"
) else (
    echo File not found: Launch-SandboxInteractive.bat
    pause
)
goto menu

:optionD
if exist "%scriptDir%Launch-ChaosTest.bat" (
    call "%scriptDir%Launch-ChaosTest.bat"
) else (
    echo File not found: Launch-ChaosTest.bat
    pause
)
goto menu

:optionE
if exist "%scriptDir%CarGame" (
    call "%scriptDir%Launch-CarGame.bat"
) else (
    echo File not found: Launch-CarGame.bat
    pause
)
goto menu

:optionF
if exist "%scriptDir%View-Config.ps1" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%scriptDir%View-Config.ps1"
) else (
    echo File not found: View-Config.ps1
    pause
)
goto menu

REM ============================================================
REM  Option 0: Exit to Main GUI Menu
REM ============================================================
:option0_exit
cls
echo.
echo Exiting First Run Configuration Menu...
echo Returning to main Launch-GUI menu.
timeout /t 2 /nobreak >nul
endlocal
exit /b 0
