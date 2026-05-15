# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Test
# Author: The Establishment
# Date: 2026-04-04
# Modified: 2026-04-04
# FileRole: Guide
# Purpose: Validate system prerequisites for PowerShellGUI application
# Description: Comprehensive check of PowerShell version, required modules,
#              directories, disk space, and network connectivity.
#              v1.1: Added one-line error catch to version check (ERROR-HANDLING-TEMPLATES.md compliant)

<#
.SYNOPSIS
Validates system prerequisites for PowerShellGUI application.

.DESCRIPTION
Performs comprehensive validation checks including:
- PowerShell version compatibility (>= 5.1)
- Required module file existence
- Critical directory structure
- Disk space availability (minimum 1GB)
- Network connectivity

.EXAMPLE
.\Test-Prerequisites.ps1

.OUTPUTS
Formatted table with Check, Status, and Details columns
Exit code 0 if all checks pass, 1 if any fail
#>

[CmdletBinding()]
param()

# Initialize results array
$results = @()

Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  PowerShellGUI - Prerequisite Validation Check                   ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Determine script root
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$workspaceRoot = Split-Path -Parent $scriptRoot

# Check 1: PowerShell Version (One-line error catch - compliant with ERROR-HANDLING-TEMPLATES.md)
Write-Host "[1/10] Checking PowerShell version..." -NoNewline
$psVersion = try { $PSVersionTable.PSVersion } catch { Write-Warning "Version check failed: $_"; [version]'5.1.0.0' }
if ($psVersion.Major -ge 5 -and ($psVersion.Major -gt 5 -or $psVersion.Minor -ge 1)) {
    $results += [PSCustomObject]@{
        Check = "PowerShell Version"
        Status = "PASS"
        Details = "v$($psVersion.Major).$($psVersion.Minor) (>= 5.1 required)"
    }
    Write-Host " ✓" -ForegroundColor Green
} else {
    $results += [PSCustomObject]@{
        Check = "PowerShell Version"
        Status = "FAIL"
        Details = "v$($psVersion.Major).$($psVersion.Minor) (5.1+ required)"
    }
    Write-Host " ✗" -ForegroundColor Red
}

# Check 2-7: Required Modules
$requiredModules = @(
    "CronAiAthon-EventLog",
    "CronAiAthon-Pipeline",
    "CronAiAthon-Scheduler",
    "PwShGUI-Theme",
    "PwShGUI-NetworkTools",
    "PwShGUI-SecretStore"
)

$moduleCheckNum = 2
foreach ($moduleName in $requiredModules) {
    Write-Host "[$moduleCheckNum/10] Checking module: $moduleName..." -NoNewline
    $modulePath = Join-Path (Join-Path $workspaceRoot "modules") "$moduleName.psm1"
    
    if (Test-Path -Path $modulePath) {
        $results += [PSCustomObject]@{
            Check = "Module: $moduleName"
            Status = "PASS"
            Details = "Found"
        }
        Write-Host " ✓" -ForegroundColor Green
    } else {
        $results += [PSCustomObject]@{
            Check = "Module: $moduleName"
            Status = "FAIL"
            Details = "Not found at: $modulePath"
        }
        Write-Host " ✗" -ForegroundColor Red
    }
    $moduleCheckNum++
}

# Check 8: Logs Directory
Write-Host "[8/10] Checking logs directory..." -NoNewline
$logsDir = Join-Path $workspaceRoot "logs"
if (Test-Path -Path $logsDir) {
    $results += [PSCustomObject]@{
        Check = "Logs Directory"
        Status = "PASS"
        Details = $logsDir
    }
    Write-Host " ✓" -ForegroundColor Green
} else {
    # Create logs directory if missing
    try {
        New-Item -Path $logsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $results += [PSCustomObject]@{
            Check = "Logs Directory"
            Status = "WARN"
            Details = "Created: $logsDir"
        }
        Write-Host " ⚠ (Created)" -ForegroundColor Yellow
    } catch {
        $results += [PSCustomObject]@{
            Check = "Logs Directory"
            Status = "FAIL"
            Details = "Cannot create: $logsDir"
        }
        Write-Host " ✗" -ForegroundColor Red
    }
}

# Check 9: Disk Space (minimum 1GB free)
Write-Host "[9/10] Checking disk space..." -NoNewline
try {
    $systemDrive = $env:SystemDrive -replace ':', ''
    $drive = Get-PSDrive -Name $systemDrive -ErrorAction Stop
    if ($null -ne $drive -and $null -ne $drive.Free) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -gt 1) {
            $results += [PSCustomObject]@{
                Check = "Disk Space"
                Status = "PASS"
                Details = "$freeGB GB free on $systemDrive`: (>1GB required)"
            }
            Write-Host " ✓" -ForegroundColor Green
        } else {
            $results += [PSCustomObject]@{
                Check = "Disk Space"
                Status = "WARN"
                Details = "$freeGB GB free on $systemDrive`: (low space)"
            }
            Write-Host " ⚠" -ForegroundColor Yellow
        }
    } else {
        $results += [PSCustomObject]@{
            Check = "Disk Space"
            Status = "WARN"
            Details = "Unable to determine free space"
        }
        Write-Host " ⚠" -ForegroundColor Yellow
    }
} catch {
    $results += [PSCustomObject]@{
        Check = "Disk Space"
        Status = "WARN"
        Details = "Error checking: $_"
    }
    Write-Host " ⚠" -ForegroundColor Yellow
}

# Check 10: Network Connectivity
Write-Host "[10/10] Checking network connectivity..." -NoNewline
try {
    $pingResult = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingResult) {
        $results += [PSCustomObject]@{
            Check = "Network Connectivity"
            Status = "PASS"
            Details = "Internet accessible (8.8.8.8)"
        }
        Write-Host " ✓" -ForegroundColor Green
    } else {
        $results += [PSCustomObject]@{
            Check = "Network Connectivity"
            Status = "WARN"
            Details = "No internet connection detected"
        }
        Write-Host " ⚠" -ForegroundColor Yellow
    }
} catch {
    $results += [PSCustomObject]@{
        Check = "Network Connectivity"
        Status = "WARN"
        Details = "Unable to test connectivity"
    }
    Write-Host " ⚠" -ForegroundColor Yellow
}

# Display results table
Write-Host "`n" -NoNewline
$results | Format-Table -Property @{
    Label = "Check"
    Expression = { $_.Check }
    Width = 30
}, @{
    Label = "Status"
    Expression = { 
        switch ($_.Status) {
            "PASS" { $color = "Green"; $symbol = "✓ PASS" }
            "WARN" { $color = "Yellow"; $symbol = "⚠ WARN" }
            "FAIL" { $color = "Red"; $symbol = "✗ FAIL" }
            default { $color = "Gray"; $symbol = $_.Status }
        }
        $host.UI.RawUI.ForegroundColor = $color
        $symbol
    }
    Width = 10
}, @{
    Label = "Details"
    Expression = { $_.Details }
} -AutoSize

# Reset color
$host.UI.RawUI.ForegroundColor = "Gray"

# Summary
$passCount = @($results | Where-Object { $_.Status -eq "PASS" }).Count
$warnCount = @($results | Where-Object { $_.Status -eq "WARN" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
$totalCount = @($results).Count

Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SUMMARY: $passCount/$totalCount checks passed" (" " * (51 - "SUMMARY: $passCount/$totalCount checks passed".Length)) "║" -ForegroundColor Cyan
if ($failCount -gt 0) {
    Write-Host "║  ✗ $failCount critical failures detected" (" " * (51 - "✗ $failCount critical failures detected".Length)) "║" -ForegroundColor Red
}
if ($warnCount -gt 0) {
    Write-Host "║  ⚠ $warnCount warnings detected" (" " * (51 - "⚠ $warnCount warnings detected".Length)) "║" -ForegroundColor Yellow
}
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Return exit code
if ($failCount -gt 0) {
    Write-Host "Prerequisite check FAILED. Please address critical issues above.`n" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Prerequisite check PASSED. System is ready.`n" -ForegroundColor Green
    exit 0
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





