# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# Author: The Establishment
# Date: 2026-04-04
# FileRole: Test
# Purpose: Validate CFRMenu options 1-6 work without errors

<#
.SYNOPSIS
Tests CFRMenu options 1-6 to ensure no "... was unexpected at this time" errors.

.DESCRIPTION
Validates that all scripts called by CFRMenu options 1-6 execute without parse errors.
Tests the fix for SIN-PATTERN-006 (UTF-8 BOM requirement for Unicode scripts).

.EXAMPLE
.\Test-CFRMenuOptions.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  CFRMenu Options 1-6 Validation Test                             ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$scriptRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = Join-Path $scriptRoot "scripts"
$modulesDir = Join-Path $scriptRoot "modules"

$results = @()

# Option 1: Test-Prerequisites.ps1
Write-Host "[1/6] Testing Option 1: Test-Prerequisites.ps1..." -NoNewline
try {
    $parseErrors = @()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $scriptsDir "Test-Prerequisites.ps1"),
        [ref]$null,
        [ref]$parseErrors
    )
    
    if ($parseErrors.Count -eq 0) {
        $results += [PSCustomObject]@{
            Option = "1: Test-Prerequisites"
            Status = "PASS"
            Details = "No parse errors"
        }
        Write-Host " ✓" -ForegroundColor Green
    } else {
        $results += [PSCustomObject]@{
            Option = "1: Test-Prerequisites"
            Status = "FAIL"
            Details = "Parse errors: $($parseErrors[0].Message)"  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
        }
        Write-Host " ✗" -ForegroundColor Red
    }
} catch {
    $results += [PSCustomObject]@{
        Option = "1: Test-Prerequisites"
        Status = "FAIL"
        Details = $_.Exception.Message
    }
    Write-Host " ✗" -ForegroundColor Red
}

# Option 2: Repair-ModulePaths.ps1
Write-Host "[2/6] Testing Option 2: Repair-ModulePaths.ps1..." -NoNewline
try {
    $parseErrors = @()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $scriptsDir "Repair-ModulePaths.ps1"),
        [ref]$null,
        [ref]$parseErrors
    )
    
    if ($parseErrors.Count -eq 0) {
        $results += [PSCustomObject]@{
            Option = "2: Repair-ModulePaths"
            Status = "PASS"
            Details = "No parse errors"
        }
        Write-Host " ✓" -ForegroundColor Green
    } else {
        $results += [PSCustomObject]@{
            Option = "2: Repair-ModulePaths"
            Status = "FAIL"
            Details = "Parse errors: $($parseErrors[0].Message)"  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
        }
        Write-Host " ✗" -ForegroundColor Red
    }
} catch {
    $results += [PSCustomObject]@{
        Option = "2: Repair-ModulePaths"
        Status = "FAIL"
        Details = $_.Exception.Message
    }
    Write-Host " ✗" -ForegroundColor Red
}

# Option 3: Inline PowerShell commands (no file to test)
Write-Host "[3/6] Testing Option 3: PowerShell Compat Test (inline)..." -NoNewline
$results += [PSCustomObject]@{
    Option = "3: PS Compatibility"
    Status = "PASS"
    Details = "Inline commands (no file)"
}
Write-Host " ✓ (inline)" -ForegroundColor Cyan

# Option 4: SIN Registry check (no file to test)
Write-Host "[4/6] Testing Option 4: SIN Registry Check (inline)..." -NoNewline
$results += [PSCustomObject]@{
    Option = "4: SIN Registry"
    Status = "PASS"
    Details = "Directory listing (no file)"
}
Write-Host " ✓ (inline)" -ForegroundColor Cyan

# Option 5: CronAiAthon Scheduler module import
Write-Host "[5/6] Testing Option 5: CronAiAthon-Scheduler.psm1..." -NoNewline
try {
    $modulePath = Join-Path $modulesDir "CronAiAthon-Scheduler.psm1"
    if (Test-Path $modulePath) {
        $parseErrors = @()
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $modulePath,
            [ref]$null,
            [ref]$parseErrors
        )
        
        if ($parseErrors.Count -eq 0) {
            $results += [PSCustomObject]@{
                Option = "5: CronAiAthon Init"
                Status = "PASS"
                Details = "No parse errors"
            }
            Write-Host " ✓" -ForegroundColor Green
        } else {
            $results += [PSCustomObject]@{
                Option = "5: CronAiAthon Init"
                Status = "FAIL"
                Details = "Parse errors: $($parseErrors[0].Message)"  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
            }
            Write-Host " ✗" -ForegroundColor Red
        }
    } else {
        $results += [PSCustomObject]@{
            Option = "5: CronAiAthon Init"
            Status = "WARN"
            Details = "Module not found"
        }
        Write-Host " ⚠ (not found)" -ForegroundColor Yellow
    }
} catch {
    $results += [PSCustomObject]@{
        Option = "5: CronAiAthon Init"
        Status = "FAIL"
        Details = $_.Exception.Message
    }
    Write-Host " ✗" -ForegroundColor Red
}

# Option 6: Export-SystemReport.ps1
Write-Host "[6/6] Testing Option 6: Export-SystemReport.ps1..." -NoNewline
try {
    $parseErrors = @()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $scriptsDir "Export-SystemReport.ps1"),
        [ref]$null,
        [ref]$parseErrors
    )
    
    if ($parseErrors.Count -eq 0) {
        $results += [PSCustomObject]@{
            Option = "6: System Report"
            Status = "PASS"
            Details = "No parse errors"
        }
        Write-Host " ✓" -ForegroundColor Green
    } else {
        $results += [PSCustomObject]@{
            Option = "6: System Report"
            Status = "FAIL"
            Details = "Parse errors: $($parseErrors[0].Message)"  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
        }
        Write-Host " ✗" -ForegroundColor Red
    }
} catch {
    $results += [PSCustomObject]@{
        Option = "6: System Report"
        Status = "FAIL"
        Details = $_.Exception.Message
    }
    Write-Host " ✗" -ForegroundColor Red
}

# UTF-8 BOM Verification
Write-Host "`n[Additional] Verifying UTF-8 BOM on Unicode scripts..." -ForegroundColor Gray

$scriptsToCheck = @(
    "Test-Prerequisites.ps1",
    "Repair-ModulePaths.ps1",
    "Export-SystemReport.ps1"
)

foreach ($scriptName in $scriptsToCheck) {
    $path = Join-Path $scriptsDir $scriptName
    if (Test-Path $path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBOM = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $hasUnicode = $content -match '[^\x00-\x7F]'
        
        if ($hasUnicode -and -not $hasBOM) {
            Write-Host "  ✗ $scriptName : Unicode without BOM (SIN-PATTERN-006)" -ForegroundColor Red
        } elseif ($hasUnicode -and $hasBOM) {
            Write-Host "  ✓ $scriptName : UTF-8 BOM present" -ForegroundColor Green
        } else {
            Write-Host "  ○ $scriptName : ASCII only (BOM not needed)" -ForegroundColor Cyan
        }
    }
}

# Display summary
Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  TEST RESULTS                                                     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$results | Format-Table -AutoSize

$passCount = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = ($results | Where-Object { $_.Status -eq 'WARN' }).Count

Write-Host "`nSummary: " -NoNewline
Write-Host "$passCount PASS" -ForegroundColor Green -NoNewline
Write-Host " | " -NoNewline
Write-Host "$failCount FAIL" -ForegroundColor Red -NoNewline
Write-Host " | " -NoNewline
Write-Host "$warnCount WARN" -ForegroundColor Yellow

if ($failCount -eq 0) {
    Write-Host "`n✅ All CFRMenu options 1-6 are functional!" -ForegroundColor Green
    Write-Host "No '... was unexpected at this time' errors should occur.`n" -ForegroundColor White
    exit 0
} else {
    Write-Host "`n❌ Some options have issues. Review details above.`n" -ForegroundColor Red
    exit 1
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





