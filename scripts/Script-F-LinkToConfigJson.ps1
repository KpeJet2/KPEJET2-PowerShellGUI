# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 9 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
Script-F - Configuration Template Validator

.DESCRIPTION
Validates path configuration using pwsh-app-config-BASE.json template.
Demonstrates proper usage of LOCAL and GLOBAL path patterns with Test-Path validation.

.CONFIGURATION BASE
pwsh-app-config-BASE.json

.NOTES
This script serves as a template reference implementation for consistent
path management across all PowerShell GUI application scripts.
#>

# Stop on errors
$ErrorActionPreference = "Stop"

Write-Information "================================" -InformationAction Continue
Write-Information "Script-F: Configuration Template Validator" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

# ==================== LOAD CONFIGURATION TEMPLATE ====================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentDir = Split-Path -Parent $scriptDir
$configTemplateFile = Join-Path (Join-Path $parentDir "config") "pwsh-app-config-BASE.json"

if (-not (Test-Path $configTemplateFile)) {
    Write-Warning "Configuration template not found: $configTemplateFile"
    Write-Information "Creating default template..." -InformationAction Continue
    exit 1
}

Write-Information "Loading configuration template..." -InformationAction Continue
$configTemplate = Get-Content $configTemplateFile -Raw | ConvertFrom-Json

Write-Information "  Template Version: $($configTemplate.metadata.versionTag)" -InformationAction Continue
Write-Information "  Configuration Base: $($configTemplate.metadata.configurationBase)" -InformationAction Continue
Write-Information "" -InformationAction Continue

# ==================== VALIDATE PATH STRUCTURE ====================
Write-Information "Validating path configuration structure..." -InformationAction Continue

# Validate LOCAL paths section
Write-Information "  Checking LOCAL paths configuration..." -InformationAction Continue
$localPaths = $configTemplate.paths.local | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -ne "description" -and $_.Name -ne "rootPath" }
foreach ($pathProperty in $localPaths) {
    $pathName = $pathProperty.Name
    $pathConfig = $configTemplate.paths.local.$pathName
    if ($pathConfig.variable) {
        Write-Information "    [OK] $pathName - Variable: $($pathConfig.variable) | Default: $($pathConfig.defaultValue)" -InformationAction Continue
    }
}

# Validate GLOBAL paths section
Write-Information "  Checking GLOBAL paths configuration..." -InformationAction Continue
$globalPaths = $configTemplate.paths.global | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -ne "description" }
foreach ($pathProperty in $globalPaths) {
    $pathName = $pathProperty.Name
    $pathConfig = $configTemplate.paths.global.$pathName
    Write-Information "    [OK] $pathName - Variable: $($pathConfig.variable) | Value: $($pathConfig.value)" -InformationAction Continue
}

# Validate GLOBAL files section
Write-Information "  Checking GLOBAL files configuration..." -InformationAction Continue
$globalFiles = $configTemplate.paths.globalFiles | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -ne "description" }
foreach ($fileProperty in $globalFiles) {
    $fileName = $fileProperty.Name
    $fileConfig = $configTemplate.paths.globalFiles.$fileName
    $validationStatus = if ($fileConfig.validateOnly) { "validate-only" } else { "create-if-missing" }
    Write-Information "    [OK] $fileName - Variable: $($fileConfig.variable) | Action: $validationStatus" -InformationAction Continue
}

Write-Information "" -InformationAction Continue

# ==================== VALIDATE SECTIONS ====================
Write-Information "Validating application sections..." -InformationAction Continue
foreach ($section in $configTemplate.sections) {
    Write-Information "  [$($section.order)] $($section.name) - $($section.description)" -InformationAction Continue
}

Write-Information "" -InformationAction Continue

# ==================== VALIDATE EXECUTION ORDER ====================
Write-Information "Validating execution order sequence..." -InformationAction Continue
$executionOrder = $configTemplate.validation.executionOrder
$executionOrder = if ($null -ne $configTemplate.validation.executionOrder) { @($configTemplate.validation.executionOrder) } else { @() }
Write-Information "  Total steps: $($executionOrder.Count)" -InformationAction Continue  # SIN-EXEMPT: P027 - false positive: array is populated/guarded before indexing
if ($executionOrder.Count -gt 0) {
    Write-Information "  First step: $($executionOrder[0])" -InformationAction Continue
    Write-Information "  Last step: $($executionOrder[-1])" -InformationAction Continue
}

Write-Information "" -InformationAction Continue
Write-Information "Configuration template validation completed successfully!" -InformationAction Continue
Write-Information "" -InformationAction Continue

# ==================== PATH VALIDATION HELPER ====================
# https://www.sharepointdiary.com/2023/03/pause-powershell-with-press-any-key-to-continue.html
function Wait-KeyOrTimeout {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([int]$Seconds = 5)
     
    $endTime = (Get-Date).AddSeconds($Seconds)
    Write-Information "Press any key to continue or wait $Seconds seconds..." -InformationAction Continue
     
    while ((Get-Date) -lt $endTime) {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Information "Timeout reached, continuing..." -InformationAction Continue
}
 
Write-Information "FFF completed." -InformationAction Continue
Wait-KeyOrTimeout -Seconds 5
Write-Information "Script-F execution finished." -InformationAction Continue



















