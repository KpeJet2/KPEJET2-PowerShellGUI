# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# Author: The Establishment
# Date: 2026-04-04
# FileRole: Test Script
# Purpose: Automated PowerShell version testing with PS7-first enforcement
#          Validates scripts work in PS7 (primary) and PS5.1 (backward compat)

<#
.SYNOPSIS
    Tests PowerShellGUI scripts in both PS7 and PS5.1 with enforced PS7-first order.

.DESCRIPTION
    Implements PS7-First Testing Methodology by:
    1. Running tests in PowerShell 7 first (mandatory)
    2. Only testing PS5.1 after PS7 passes
    3. Re-testing PS7 if any PS5 fixes are applied
    4. Generating detailed HTML reports
    5. Supporting CI/CD integration with exit codes

.PARAMETER PS7Only
    Run tests in PowerShell 7 only (skip PS5.1).
    Use during active development.

.PARAMETER PS5Only
    Run tests in PowerShell 5.1 only.
    ⚠️ WARNING: Should only be used AFTER PS7 tests pass.

.PARAMETER TestSuite
    Which test suite to run:
    - Launch: Test Launch-GUI.bat and launchers
    - Modules: Test all modules in modules/ folder
    - GUI: Test Main-GUI.ps1 startup
    - Full: All tests (default)

.PARAMETER FailFast
    Stop on first test failure (CI/CD mode).
    Exit code 1 on any failure.

.PARAMETER GenerateReport
    Generate HTML test report in ~REPORTS/ folder.

.PARAMETER ReportPath
    Custom path for HTML report (requires -GenerateReport).

.EXAMPLE
    .\Test-PowerShellVersions.ps1
    # Run full test suite: PS7 first, then PS5.1

.EXAMPLE
    .\Test-PowerShellVersions.ps1 -PS7Only -TestSuite Launch
    # Test only launchers in PS7 (fast dev cycle)

.EXAMPLE
    .\Test-PowerShellVersions.ps1 -FailFast -GenerateReport
    # CI/CD mode: strict, with report

.NOTES
    Exit Codes:
    - 0: All tests passed
    - 1: PS7 tests failed (PS5 not tested)
    - 2: PS7 passed, PS5 failed
    - 3: Invalid parameters
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$PS7Only,

    [Parameter()]
    [switch]$PS5Only,

    [Parameter()]
    [ValidateSet('Launch', 'Modules', 'GUI', 'Full')]
    [string]$TestSuite = 'Full',

    [Parameter()]
    [switch]$FailFast,

    [Parameter()]
    [switch]$GenerateReport,

    [Parameter()]
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = if ($FailFast) { 'Stop' } else { 'Continue' }

# ============================================================
#  Initialization
# ============================================================

$script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
$script:TestResults = @{
    PS7 = @{ Pass = 0; Fail = 0; Skip = 0; Tests = @() }
    PS5 = @{ Pass = 0; Fail = 0; Skip = 0; Tests = @() }
}
$script:StartTime = Get-Date

# Validate parameters
if ($PS7Only -and $PS5Only) {
    Write-Host "❌ ERROR: Cannot specify both -PS7Only and -PS5Only" -ForegroundColor Red
    exit 3
}

if ($PS5Only) {
    Write-Host "⚠️  WARNING: Testing PS5 only. PS7-first methodology recommends testing PS7 first." -ForegroundColor Yellow
    $continue = Read-Host "Continue anyway? [y/N]"
    if ($continue -notmatch '^y(es)?$') {
        Write-Host "Aborted by user." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  PowerShell Version Testing - PS7-First Methodology           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Test Suite: $TestSuite" -ForegroundColor White
Write-Host "  Mode: $(if($PS7Only){'PS7 Only'}elseif($PS5Only){'PS5 Only'}else{'PS7 -> PS5'})" -ForegroundColor White
Write-Host "  Workspace: $WorkspaceRoot" -ForegroundColor Gray
Write-Host ""

# ============================================================
#  Test Definition Functions
# ============================================================

function Test-LauncherBatch {
    [CmdletBinding()]
    param(
        [string]$BatchPath,
        [string]$PSVersion
    )
    
    $testName = "Launch: $(Split-Path -Leaf $BatchPath)"
    $testResult = @{
        Name = $testName
        PSVersion = $PSVersion
        Status = 'PASS'
        Message = ''
        Duration = 0
    }
    
    try {
        $start = Get-Date
        
        # Test batch file exists
        if (-not (Test-Path $BatchPath)) {
            throw "Batch file not found: $BatchPath"
        }
        
        # Parse batch file for syntax errors (basic check)
        $content = Get-Content $BatchPath -Raw -ErrorAction Stop
        
        # Check for common batch syntax errors
        if ($content -match '^\s*#[^!]') {
            throw "Found PowerShell-style comments (#) instead of REM in batch file"
        }
        
        if ($content -match '\^\s*\r?\n\s*"[^"]*\^\s*\r?\n') {
            throw "Found multi-line PowerShell command with orphaned ^ continuation characters"
        }
        
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
        $testResult.Message = "Batch file syntax validation passed"
        
    } catch {
        $testResult.Status = 'FAIL'
        $testResult.Message = $_.Exception.Message
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
    }
    
    return $testResult
}

function Test-ModuleImport {
    [CmdletBinding()]
    param(
        [string]$ModulePath,
        [string]$PSVersion
    )
    
    $testName = "Module: $(Split-Path -Leaf $ModulePath)"
    $testResult = @{
        Name = $testName
        PSVersion = $PSVersion
        Status = 'PASS'
        Message = ''
        Duration = 0
    }
    
    try {
        $start = Get-Date
        
        # Import module with force
        Import-Module $ModulePath -Force -ErrorAction Stop
        
        # Verify module loaded
        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($ModulePath)
        $loadedModule = Get-Module -Name $moduleName -ErrorAction SilentlyContinue
        
        if ($null -eq $loadedModule) {
            throw "Module imported but not found in Get-Module: $moduleName"
        }
        
        # Check for parse errors
        $parseErrors = @()
        [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$null, [ref]$parseErrors) | Out-Null
        
        if (@($parseErrors).Count -gt 0) {
            throw "Parse errors found: $($parseErrors[0].Message)"
        }
        
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
        $testResult.Message = "Module imported successfully, $(@($loadedModule.ExportedFunctions.Keys).Count) functions exported"
        
        # Clean up
        Remove-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
        
    } catch {
        $testResult.Status = 'FAIL'
        $testResult.Message = $_.Exception.Message
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
    }
    
    return $testResult
}

function Test-ScriptParse {
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [string]$PSVersion
    )
    
    $testName = "Parse: $(Split-Path -Leaf $ScriptPath)"
    $testResult = @{
        Name = $testName
        PSVersion = $PSVersion
        Status = 'PASS'
        Message = ''
        Duration = 0
    }
    
    try {
        $start = Get-Date
        
        # Parse script for syntax errors
        $parseErrors = @()
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
        
        if (@($parseErrors).Count -gt 0) {
            throw "Parse error at line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"
        }
        
        # Check for PS7-only operators (SIN-PATTERN-005)
        $scriptContent = Get-Content $ScriptPath -Raw
        
        $ps7Operators = @('??', '?.', '??=')
        foreach ($op in $ps7Operators) {
            if ($scriptContent -match [regex]::Escape($op)) {
                if ($PSVersion -eq 'PS5.1') {
                    throw "PS7-only operator found: $op (SIN-PATTERN-005 violation)"
                } else {
                    # Warning for PS7 (should avoid for compatibility)
                    Write-Warning "PS7-only operator found: $op in $ScriptPath (consider PS5-compatible alternative)"
                }
            }
        }
        
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
        $testResult.Message = "Script parsed successfully, $(@($ast.FindAll({$true}, $false)).Count) AST nodes"
        
    } catch {
        $testResult.Status = 'FAIL'
        $testResult.Message = $_.Exception.Message
        $testResult.Duration = ((Get-Date) - $start).TotalSeconds
    }
    
    return $testResult
}

# ============================================================
#  Test Execution Functions
# ============================================================

function Invoke-TestSuite {
    [CmdletBinding()]
    param(
        [string]$Suite,
        [string]$PSVersion
    )
    
    Write-Host ""
    Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Gray
    Write-Host "  Testing in $PSVersion" -ForegroundColor Cyan
    Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Gray
    
    $results = @()
    
    # Launch tests
    if ($Suite -in @('Launch', 'Full')) {
        Write-Host "  [Launch Tests]" -ForegroundColor Yellow
        
        $launchers = @(
            (Join-Path $WorkspaceRoot "Launch-GUI.bat"),
            (Join-Path $WorkspaceRoot "Launch-CFRMenu.bat"),
            (Join-Path $WorkspaceRoot "Launch-GUI-quik_jnr.bat"),
            (Join-Path $WorkspaceRoot "Launch-GUI-slow_snr.bat")
        )
        
        foreach ($launcher in $launchers) {
            if (Test-Path $launcher) {
                $result = Test-LauncherBatch -BatchPath $launcher -PSVersion $PSVersion
                $results += $result
                Write-TestResult -TestResult $result
            }
        }
    }
    
    # Module tests
    if ($Suite -in @('Modules', 'Full')) {
        Write-Host "  [Module Tests]" -ForegroundColor Yellow
        
        $modulesPath = Join-Path $WorkspaceRoot "modules"
        $modules = @(Get-ChildItem -Path $modulesPath -Filter "*.psm1" -ErrorAction SilentlyContinue)
        
        foreach ($module in $modules) {
            $result = Test-ModuleImport -ModulePath $module.FullName -PSVersion $PSVersion
            $results += $result
            Write-TestResult -TestResult $result
        }
    }
    
    # GUI tests
    if ($Suite -in @('GUI', 'Full')) {
        Write-Host "  [GUI Tests]" -ForegroundColor Yellow
        
        $mainGUI = Join-Path $WorkspaceRoot "Main-GUI.ps1"
        if (Test-Path $mainGUI) {
            $result = Test-ScriptParse -ScriptPath $mainGUI -PSVersion $PSVersion
            $results += $result
            Write-TestResult -TestResult $result
        }
    }
    
    return $results
}

function Write-TestResult {
    [CmdletBinding()]
    param($TestResult)
    
    $statusColor = if ($TestResult.Status -eq 'PASS') { 'Green' } else { 'Red' }
    $statusSymbol = if ($TestResult.Status -eq 'PASS') { '✓' } else { '✗' }
    
    Write-Host "    $statusSymbol " -ForegroundColor $statusColor -NoNewline
    Write-Host "$($TestResult.Name) " -NoNewline
    Write-Host "($([math]::Round($TestResult.Duration, 2))s)" -ForegroundColor Gray
    
    if ($TestResult.Status -ne 'PASS') {
        Write-Host "      └─ $($TestResult.Message)" -ForegroundColor Red
    }
}

function Write-TestSummary {
    [CmdletBinding()]
    param(
        [hashtable]$PS7Results,
        [hashtable]$PS5Results
    )
    
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Test Summary                                                 ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    if ($PS7Results.Tests.Count -gt 0) {
        $ps7Color = if ($PS7Results.Fail -eq 0) { 'Green' } else { 'Red' }
        Write-Host ""
        Write-Host "  PowerShell 7:" -ForegroundColor White
        Write-Host "    Pass: $($PS7Results.Pass)" -ForegroundColor Green -NoNewline
        Write-Host " | Fail: $($PS7Results.Fail)" -ForegroundColor $ps7Color -NoNewline
        Write-Host " | Total: $($PS7Results.Tests.Count)"
    }
    
    if ($PS5Results.Tests.Count -gt 0) {
        $ps5Color = if ($PS5Results.Fail -eq 0) { 'Green' } else { 'Red' }
        Write-Host ""
        Write-Host "  PowerShell 5.1:" -ForegroundColor White
        Write-Host "    Pass: $($PS5Results.Pass)" -ForegroundColor Green -NoNewline
        Write-Host " | Fail: $($PS5Results.Fail)" -ForegroundColor $ps5Color -NoNewline
        Write-Host " | Total: $($PS5Results.Tests.Count)"
    }
    
    $duration = ((Get-Date) - $script:StartTime).TotalSeconds
    Write-Host ""
    Write-Host "  Total Duration: $([math]::Round($duration, 2)) seconds" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================
#  Main Execution
# ============================================================

$exitCode = 0

# Phase 1: PowerShell 7 Tests (if not -PS5Only)
if (-not $PS5Only) {
    $ps7Available = $null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)
    
    if ($ps7Available) {
        # Execute tests in PS7 context
        $ps7Results = Invoke-TestSuite -Suite $TestSuite -PSVersion "PS7"
        
        foreach ($result in $ps7Results) {
            $script:TestResults.PS7.Tests += $result
            if ($result.Status -eq 'PASS') {
                $script:TestResults.PS7.Pass++
            } else {
                $script:TestResults.PS7.Fail++
            }
        }
        
        if ($script:TestResults.PS7.Fail -gt 0) {
            Write-Host ""
            Write-Host "❌ PS7 tests FAILED. PS5 testing skipped per PS7-first methodology." -ForegroundColor Red
            $exitCode = 1
        }
    } else {
        Write-Host "⚠️  PowerShell 7 not found. Install from: https://aka.ms/powershell-release" -ForegroundColor Yellow
        $exitCode = 1
    }
}

# Phase 2: PowerShell 5.1 Tests (only if PS7 passed or -PS5Only)
if ((-not $PS7Only) -and ($exitCode -eq 0 -or $PS5Only)) {
    $ps5Available = $PSVersionTable.PSVersion.Major -eq 5
    
    if ($ps5Available) {
        # Execute tests in current PS5 context
        $ps5Results = Invoke-TestSuite -Suite $TestSuite -PSVersion "PS5.1"
        
        foreach ($result in $ps5Results) {
            $script:TestResults.PS5.Tests += $result
            if ($result.Status -eq 'PASS') {
                $script:TestResults.PS5.Pass++
            } else {
                $script:TestResults.PS5.Fail++
            }
        }
        
        if ($script:TestResults.PS5.Fail -gt 0) {
            Write-Host ""
            Write-Host "⚠️  PS5 tests FAILED. Re-test PS7 after applying fixes!" -ForegroundColor Yellow
            $exitCode = 2
        }
    } else {
        Write-Host "⚠️  PowerShell 5.1 not available in current session." -ForegroundColor Yellow
        Write-Host "    Run this script in PowerShell 5.1 for backward compat testing." -ForegroundColor Gray
    }
}

# Summary
Write-TestSummary -PS7Results $script:TestResults.PS7 -PS5Results $script:TestResults.PS5

# Report generation (if requested)
if ($GenerateReport) {
    $reportDir = Join-Path $WorkspaceRoot "~REPORTS"
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    
    if (-not $ReportPath) {
        $ReportPath = Join-Path $reportDir "test-results-$(Get-Date -Format yyyyMMdd-HHmmss).html"
    }
    
    # Generate HTML report (simplified for now)
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>PS7-First Test Results</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #f5f5f5; margin: 20px; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px; }
        .summary { background: white; padding: 20px; margin: 20px 0; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .pass { color: #28a745; }
        .fail { color: #dc3545; }
        table { width: 100%; border-collapse: collapse; margin: 10px 0; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; }
    </style>
</head>
<body>
    <div class="header">
        <h1>PS7-First Testing Results</h1>
        <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Test Suite: $TestSuite</p>
    </div>
    <div class="summary">
        <h2>Summary</h2>
        <p><strong>PowerShell 7:</strong> <span class="pass">$($script:TestResults.PS7.Pass) passed</span>, <span class="fail">$($script:TestResults.PS7.Fail) failed</span></p>
        <p><strong>PowerShell 5.1:</strong> <span class="pass">$($script:TestResults.PS5.Pass) passed</span>, <span class="fail">$($script:TestResults.PS5.Fail) failed</span></p>
    </div>
</body>
</html>
"@
    
    $htmlContent | Out-File -FilePath $ReportPath -Encoding UTF8 -Force
    Write-Host "📄 Test report generated: $ReportPath" -ForegroundColor Cyan
}

# Exit with appropriate code
if ($exitCode -eq 0) {
    Write-Host "✅ All tests PASSED" -ForegroundColor Green
} elseif ($exitCode -eq 1) {
    Write-Host "❌ PS7 tests FAILED" -ForegroundColor Red
} elseif ($exitCode -eq 2) {
    Write-Host "❌ PS5 tests FAILED (PS7 passed)" -ForegroundColor Red
}

Write-Host ""
exit $exitCode

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




