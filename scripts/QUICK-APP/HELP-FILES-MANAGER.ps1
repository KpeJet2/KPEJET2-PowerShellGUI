# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
PowerShell Help Files Manager - Quick App Launcher

.DESCRIPTION
Launches the PwSh-HelpFilesUpdateSource-ReR GUI for managing PowerShell help files.

.NOTES

.LINK

.INPUTS

.OUTPUTS

.FUNCTIONALITY
Provides convenient access to the Help Files Manager GUI.

.AUTHOR
The Establishment

.CREATED
16th February 2026

.MODIFIED
16th February 2026

.VERSION
1.0.0

#>

# Stop on errors
$ErrorActionPreference = "Stop"

# Define paths
$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentDir = Split-Path -Parent $localRoot
$scriptDir = Split-Path -Parent $parentDir

# Define directories
$modulesDir = Join-Path $scriptDir "modules"
$logsDir = Join-Path $scriptDir "logs"
$downloadDir = Join-Path $parentDir "~DOWNLOADS"

# Create directories if missing
@($modulesDir, $logsDir, $downloadDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# Define module path
$helpFilesModulePath = Join-Path $modulesDir "PwSh-HelpFilesUpdateSource-ReR.psm1"

# Import module
if (Test-Path $helpFilesModulePath) {
    try {
        Import-Module $helpFilesModulePath -Force
        Write-Host "Help Files Manager module loaded successfully" -ForegroundColor Green
        
        # Show the GUI
        Show-HelpFilesGUI -InitialPath $downloadDir
    } catch {
        Write-Host "Error loading Help Files Manager module: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Error: Help Files Manager module not found at $helpFilesModulePath" -ForegroundColor Red
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





