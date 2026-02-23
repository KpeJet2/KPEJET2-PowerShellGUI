# VersionTag: 2602.a.11
# VersionTag: 2602.a.11
#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration and Logs Viewer

.DESCRIPTION
    Displays system variables from config\system-variables.xml and tails the
    most recent log files. Paths are sourced from the XML as the single source
    of truth, with relative-path fallbacks if XML is not yet initialised.

.NOTES
    Author   : The Establishment
    Version  : 2602.a.11
    Created  : January 2026
    Modified : 22nd February 2026

.INPUTS
    None. Run directly from PowerShell or via Launch-GUI.bat menu.

.OUTPUTS
    Console: system variables, recent log entries (last 10 lines each), paths.

.LINK
    ~README.md/README.md

.LINK
    ~README.md/QUICK-START.md

.LINK
    ~README.md/SETUP-GUIDE.md
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "config\system-variables.xml"

# Source configDir and logsDir from XML (single source of truth)
# fallback to relative paths if XML is not yet initialised
$configDir = Join-Path $scriptDir "config"
$logsDir   = Join-Path $scriptDir "logs"
if (Test-Path $configFile) {
    [xml]$_sysVars = Get-Content $configFile -ErrorAction SilentlyContinue
    if ($_sysVars.SystemVariables.ConfigDirectory) { $configDir = $_sysVars.SystemVariables.ConfigDirectory }
    if ($_sysVars.SystemVariables.LogDirectory)    { $logsDir   = $_sysVars.SystemVariables.LogDirectory }
}

Write-Host "PowerShell GUI - Configuration & Logs Viewer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Display Configuration
if (Test-Path $configFile) {
    Write-Host "SYSTEM CONFIGURATION" -ForegroundColor Yellow
    Write-Host "-------------------" -ForegroundColor Gray
    Write-Host ""
    
    [xml]$xml = Get-Content $configFile
    foreach ($node in $xml.SystemVariables.ChildNodes) {
        Write-Host "  $($node.LocalName): " -NoNewline -ForegroundColor Green
        Write-Host $node.InnerText -ForegroundColor White
    }
}
else {
    Write-Host "Configuration file not found. Run the main GUI application first." -ForegroundColor Red
}

Write-Host ""
Write-Host "RECENT LOG ENTRIES" -ForegroundColor Yellow
Write-Host "------------------" -ForegroundColor Gray
Write-Host ""

# Display Recent Logs
$logFiles = Get-ChildItem $logsDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5

if ($logFiles) {
    foreach ($logFile in $logFiles) {
        Write-Host "Log File: $($logFile.Name)" -ForegroundColor Cyan
        Write-Host ""
        
        $content = Get-Content $logFile.FullName -Tail 10
        foreach ($line in $content) {
            if ($line -match "Error") {
                Write-Host $line -ForegroundColor Red
            }
            elseif ($line -match "Warning") {
                Write-Host $line -ForegroundColor Yellow
            }
            elseif ($line -match "Success") {
                Write-Host $line -ForegroundColor Green
            }
            else {
                Write-Host $line -ForegroundColor White
            }
        }
        Write-Host ""
    }
}
else {
    Write-Host "No log files found yet." -ForegroundColor Gray
}

Write-Host ""
Write-Host "DIRECTORIES:" -ForegroundColor Yellow
Write-Host "  Config Directory: $configDir" -ForegroundColor Gray
Write-Host "  Logs Directory:   $logsDir" -ForegroundColor Gray
Write-Host "  Scripts Directory: $(Join-Path $scriptDir 'scripts')" -ForegroundColor Gray
Write-Host ""













