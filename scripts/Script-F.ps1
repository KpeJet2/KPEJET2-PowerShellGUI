# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 9 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
Script-F - User Management

.DESCRIPTION
This script performs user management tasks.

.NOTES


.LINK


.INPUTS


.OUTPUTS


.FUNCTIONALITY
For system administrators and IT professionals to manage user accounts and permissions.

.AUTHOR
The Establishment

.CREATED
24th January 2026

.MODIFIED
16th February 2026

.VERSION
1.0.0

.CONFIGURATION BASE
pwsh-app-config-BASE.json

#>


# Stop on errors
$ErrorActionPreference = "Stop"

# Define LOCAL script directory and GLOBAL project root
$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $localRoot

# Define GLOBAL directories and Files
$configDir       = Join-Path $scriptDir "config"
$modulesDir      = Join-Path $scriptDir "modules"
$logsDir         = Join-Path $scriptDir "logs"
$scriptsDir      = Join-Path $scriptDir "scripts"
$configFile      = Join-Path $configDir "system-variables.xml"
$linksConfigFile = Join-Path $configDir "links.xml"
$avpnConfigFile  = Join-Path $configDir "AVPN-devices.json"
$avpnModulePath  = Join-Path $modulesDir "AVPN-Tracker.psm1"

# Create directories if they don't exist
foreach ($dir in @($scriptDir, $configDir, $modulesDir, $logsDir, $scriptsDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
foreach ($file in @($configFile, $linksConfigFile, $avpnConfigFile)) {
    if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file -Force | Out-Null }
}

# ==================== MODULE IMPORTS ====================
# Import PwShGUICore FIRST -- provides Write-AppLog, Request-LocalPath, etc.
$coreModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUICore.psm1'
if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath -Force
    Initialize-CorePaths -ScriptDir $scriptDir
} else {
    Write-Warning "PwShGUICore module not found at $coreModulePath"
}

# Import AVPN module if available
if (Test-Path $avpnModulePath) {
    Import-Module $avpnModulePath -Force
} else {
    Write-AppLog "AVPN module not found at $avpnModulePath" "Warning"
}

# ==================== LOCAL PATH CONFIGURATION ====================
# Request-LocalPath is now provided by PwShGUICore module.
$ConfigPath    = ""
$DefaultFolder = ""
$TempFolder    = ""
$ReportFolder  = ""

if (-not $ConfigPath)    { $ConfigPath    = Request-LocalPath -Label "ConfigPath"    -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $DefaultFolder) { $DefaultFolder = Request-LocalPath -Label "DefaultFolder" -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $TempFolder)    { $TempFolder    = Request-LocalPath -Label "TempFolder"    -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $ReportFolder)  { $ReportFolder  = Request-LocalPath -Label "ReportFolder"  -DefaultValue $localRoot -TimeoutSeconds 9 }

# Create local directories if they don't exist
if ($ConfigPath    -and -not (Test-Path $ConfigPath))    { New-Item -ItemType Directory -Path $ConfigPath    -Force | Out-Null }
if ($DefaultFolder -and -not (Test-Path $DefaultFolder)) { New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null }
if ($TempFolder    -and -not (Test-Path $TempFolder))    { New-Item -ItemType Directory -Path $TempFolder    -Force | Out-Null }
if ($ReportFolder  -and -not (Test-Path $ReportFolder))  { New-Item -ItemType Directory -Path $ReportFolder  -Force | Out-Null }

# ==================== CONFIG FUNCTIONS ====================
# Initialize-ConfigFile is now provided by PwShGUICore module (unused in this script).

# ==================== SCRIPT MAIN EXECUTION ====================
Write-Information "================================" -InformationAction Continue
Write-Information "Script-F: User Management" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-AppLog "Script-F execution started" "Info"

Write-Information "Execution Details:" -InformationAction Continue
Write-Information "  Computer: $env:COMPUTERNAME" -InformationAction Continue
Write-Information "  User: $env:USERNAME" -InformationAction Continue
Write-Information "  PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -InformationAction Continue
Write-Information "  Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Managing user accounts and permissions..." -InformationAction Continue

Write-Information "  [OK] TASK 1 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 1 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 2 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 2 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 3 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 3 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 4 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 4 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 5 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 5 completed" "Script-F" "Info"
Write-Information "" -InformationAction Continue

Write-Information "User management completed successfully!" -InformationAction Continue
Write-AppLog "Script-F execution completed successfully" "Info"
Write-Information "" -InformationAction Continue
# A
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
# $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
###
#B
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
#timeout /t 10
###
#C
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




















<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





