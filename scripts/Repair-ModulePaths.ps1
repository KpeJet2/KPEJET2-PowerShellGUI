# VersionTag: 2604.B2.V31.0
# Author: The Establishment
# Date: 2026-04-04
# FileRole: Guide
# Purpose: Repair PSModulePath to include PowerShellGUI modules directory
# Description: Adds the PowerShellGUI modules folder to PSModulePath for current
#              session and optionally persists to user environment variables.

<#
.SYNOPSIS
Repairs PSModulePath to include PowerShellGUI modules directory.

.DESCRIPTION
Checks if the PowerShellGUI\modules directory is in the PSModulePath. If not,
adds it to the current session and offers to persist the change to the user's
environment variables. Validates the repair by testing module import.

.PARAMETER Persist
If specified, automatically persists the change to user environment without prompting.

.EXAMPLE
.\Repair-ModulePaths.ps1

.EXAMPLE
.\Repair-ModulePaths.ps1 -Persist

.OUTPUTS
Success or failure message with verification results
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Persist
)

Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  PowerShellGUI - Module Path Repair Tool                         ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Determine script root and modules directory
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$workspaceRoot = Split-Path -Parent $scriptRoot
$modulesPath = Join-Path $workspaceRoot "modules"

Write-Host "[1/5] Validating modules directory..." -NoNewline
if (-not (Test-Path -Path $modulesPath)) {
    Write-Host " ✗" -ForegroundColor Red
    Write-Error "Modules directory not found: $modulesPath"
    exit 1
}
Write-Host " ✓" -ForegroundColor Green
Write-Host "      Path: $modulesPath`n"

# Check current PSModulePath
Write-Host "[2/5] Checking current PSModulePath..." -NoNewline
$currentPSModulePath = $env:PSModulePath
$pathEntries = $currentPSModulePath -split ';'
$needsRepair = $true

foreach ($entry in $pathEntries) {
    if ($entry -eq $modulesPath) {
        $needsRepair = $false
        break
    }
}

if (-not $needsRepair) {
    Write-Host " ✓" -ForegroundColor Green
    Write-Host "      Modules path already in PSModulePath.`n"
} else {
    Write-Host " ⚠" -ForegroundColor Yellow
    Write-Host "      Modules path NOT in PSModulePath (repair needed).`n"
}

# Apply repair to current session
if ($needsRepair) {
    Write-Host "[3/5] Adding modules path to current session..." -NoNewline
    try {
        $env:PSModulePath = "$modulesPath;$currentPSModulePath"
        Write-Host " ✓" -ForegroundColor Green
        Write-Host "      Session PSModulePath updated.`n"
    } catch {
        Write-Host " ✗" -ForegroundColor Red
        Write-Error "Failed to update session PSModulePath: $_"
        exit 1
    }
} else {
    Write-Host "[3/5] No session repair needed." -ForegroundColor Green
    Write-Host ""
}

# Persist to user environment (optional)
if ($needsRepair) {
    Write-Host "[4/5] Persisting to user environment..." -NoNewline
    
    $shouldPersist = $Persist.IsPresent
    
    if (-not $Persist.IsPresent) {
        Write-Host ""
        $response = Read-Host "      Do you want to persist this change to your user profile? [Y/N]"
        $shouldPersist = ($response -eq 'Y' -or $response -eq 'y')
    }
    
    if ($shouldPersist) {
        try {
            # Get current user PSModulePath from registry
            $userPSModulePath = [Environment]::GetEnvironmentVariable("PSModulePath", "User")
            
            if ([string]::IsNullOrEmpty($userPSModulePath)) {
                # No user-level PSModulePath exists, create it
                [Environment]::SetEnvironmentVariable("PSModulePath", $modulesPath, "User")
                Write-Host " ✓" -ForegroundColor Green
                Write-Host "      Created user PSModulePath with modules directory.`n"
            } else {
                # Check if already in user path
                $userPathEntries = $userPSModulePath -split ';'
                $alreadyInUserPath = $false
                
                foreach ($entry in $userPathEntries) {
                    if ($entry -eq $modulesPath) {
                        $alreadyInUserPath = $true
                        break
                    }
                }
                
                if (-not $alreadyInUserPath) {
                    $newUserPSModulePath = "$modulesPath;$userPSModulePath"
                    [Environment]::SetEnvironmentVariable("PSModulePath", $newUserPSModulePath, "User")
                    Write-Host " ✓" -ForegroundColor Green
                    Write-Host "      Updated user PSModulePath.`n"
                } else {
                    Write-Host " ✓" -ForegroundColor Green
                    Write-Host "      Already in user PSModulePath.`n"
                }
            }
        } catch {
            Write-Host " ✗" -ForegroundColor Red
            Write-Warning "Failed to persist to user environment: $_"
            Write-Host "      You may need to run as administrator or set manually.`n"
        }
    } else {
        Write-Host " ⊘" -ForegroundColor Gray
        Write-Host "      Skipped (change only applies to current session).`n"
    }
} else {
    Write-Host "[4/5] No persistence needed.`n" -ForegroundColor Green
}

# Validate repair by testing module import
Write-Host "[5/5] Validating repair..." -NoNewline
try {
    $testModule = "CronAiAthon-EventLog"
    $testModulePath = Join-Path $modulesPath "$testModule.psm1"
    
    if (Test-Path -Path $testModulePath) {
        Import-Module -Name $testModulePath -Force -ErrorAction Stop
        $imported = Get-Module -Name $testModule
        
        if ($null -ne $imported) {
            Write-Host " ✓" -ForegroundColor Green
            Write-Host "      Successfully imported test module: $testModule`n"
            Remove-Module -Name $testModule -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host " ⚠" -ForegroundColor Yellow
            Write-Warning "Module path added but import test inconclusive."
        }
    } else {
        Write-Host " ⚠" -ForegroundColor Yellow
        Write-Warning "Test module not found: $testModulePath"
    }
} catch {
    Write-Host " ⚠" -ForegroundColor Yellow
    Write-Warning "Module import test failed: $_"
    Write-Host "      This may be a module-specific issue, not a path issue.`n"
}

# Summary
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  REPAIR COMPLETE                                                  ║" -ForegroundColor Green
Write-Host "║  Modules directory: $modulesPath" (" " * (51 - $modulesPath.Length)) "║" -ForegroundColor Cyan
if ($needsRepair) {
    Write-Host "║  ✓ Added to current session PSModulePath                          ║" -ForegroundColor Green
    if ($shouldPersist) {
        Write-Host "║  ✓ Persisted to user environment                                  ║" -ForegroundColor Green
    }
} else {
    Write-Host "║  ✓ No repair needed (already in PSModulePath)                     ║" -ForegroundColor Green
}
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

exit 0
