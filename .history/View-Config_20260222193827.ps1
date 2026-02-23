# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
# VersionTag: 2602.a.7
<#
.SYNOPSIS
Configuration and Logs Viewer

.DESCRIPTION
Utility script to view system variables configuration and recent logs.
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $scriptDir "config"
$logsDir = Join-Path $scriptDir "logs"
$configFile = Join-Path $configDir "system-variables.xml"

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












