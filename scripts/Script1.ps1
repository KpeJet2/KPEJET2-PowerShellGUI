# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Scaffolding
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 9 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
Script1 - Account & User Management

.DESCRIPTION
This script performs local user and group account management tasks including listing users,
groups, administrators, disabled accounts, and user privileges.

.NOTES


.LINK


.INPUTS


.OUTPUTS


.FUNCTIONALITY
For system administrators to audit and manage local user accounts and group memberships.

.AUTHOR
The Establishment

.VERSION
1.0.0

.CREATED
24th January 2026

.MODIFIED
16th February 2026

.VERSION HISTORY
1.0.0 - Initial version

.CONFIGURATION BASE
pwsh-app-config-BASE.json

#>


# Stop on errors
$ErrorActionPreference = "Stop"

# Define LOCAL script directory and GLOBAL project root
$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentDir = Split-Path -Parent $localRoot
$scriptDir = $parentDir

# Define GLOBAL directories and Files
$configDir       = Join-Path $scriptDir "config"
$modulesDir      = Join-Path $scriptDir "modules"
$logsDir         = Join-Path $scriptDir "logs"
$scriptsDir      = Join-Path $scriptDir "scripts"
$reportsDir      = Join-Path $scriptDir "~REPORTS"
$configFile      = Join-Path $configDir "system-variables.xml"
$linksConfigFile = Join-Path $configDir "links.xml"
$avpnConfigFile  = Join-Path $configDir "AVPN-devices.json"
$avpnModulePath  = Join-Path $modulesDir "AVPN-Tracker.psm1"

# Create GLOBAL directories if they don't exist
foreach ($dir in @($scriptDir, $configDir, $modulesDir, $logsDir, $reportsDir, $scriptsDir)) {
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

# ==================== LOCAL PATH CONFIGURATION ====================
# Request-LocalPath is now provided by PwShGUICore module.
$ConfigPath     = Join-Path $parentDir "config"
$DefaultFolder  = $parentDir
$TempFolder     = Join-Path $parentDir "temp"
$ReportFolder   = Join-Path $parentDir "~REPORTS"
$DownloadFolder = Join-Path $parentDir "~DOWNLOADS"

if (-not $ConfigPath)    { $ConfigPath    = Request-LocalPath -Label "ConfigPath"    -DefaultValue $ConfigPath    -TimeoutSeconds 9 }
if (-not $DefaultFolder) { $DefaultFolder = Request-LocalPath -Label "DefaultFolder" -DefaultValue $DefaultFolder -TimeoutSeconds 9 }
if (-not $TempFolder)    { $TempFolder    = Request-LocalPath -Label "TempFolder"    -DefaultValue $TempFolder    -TimeoutSeconds 9 }
if (-not $ReportFolder)  { $ReportFolder  = Request-LocalPath -Label "ReportFolder"  -DefaultValue $ReportFolder  -TimeoutSeconds 9 }
if (-not $DownloadFolder) { $DownloadFolder = Request-LocalPath -Label "DownloadFolder" -DefaultValue $DownloadFolder -TimeoutSeconds 9 }

# Local path validation log buffer
$localPathValidation = @()
function Add-LocalPathValidation {
    param([string]$Message)
    $script:localPathValidation += $Message
}

# Create local directories if they don't exist
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) {
        New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null
        Add-LocalPathValidation "Created local path: ConfigPath = $ConfigPath"
    } else {
        Add-LocalPathValidation "Verified local path: ConfigPath = $ConfigPath"
    }
} else {
    Add-LocalPathValidation "Missing local path: ConfigPath not set"
}

if ($DefaultFolder) {
    if (-not (Test-Path $DefaultFolder)) {
        New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null
        Add-LocalPathValidation "Created local path: DefaultFolder = $DefaultFolder"
    } else {
        Add-LocalPathValidation "Verified local path: DefaultFolder = $DefaultFolder"
    }
} else {
    Add-LocalPathValidation "Missing local path: DefaultFolder not set"
}

if ($TempFolder) {
    if (-not (Test-Path $TempFolder)) {
        New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null
        Add-LocalPathValidation "Created local path: TempFolder = $TempFolder"
    } else {
        Add-LocalPathValidation "Verified local path: TempFolder = $TempFolder"
    }
} else {
    Add-LocalPathValidation "Missing local path: TempFolder not set"
}

if ($ReportFolder) {
    if (-not (Test-Path $ReportFolder)) {
        New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
        Add-LocalPathValidation "Created local path: ReportFolder = $ReportFolder"
    } else {
        Add-LocalPathValidation "Verified local path: ReportFolder = $ReportFolder"
    }
} else {
    Add-LocalPathValidation "Missing local path: ReportFolder not set"
}

if ($DownloadFolder) {
    if (-not (Test-Path $DownloadFolder)) {
        New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null
        Add-LocalPathValidation "Created local path: DownloadFolder = $DownloadFolder"
    } else {
        Add-LocalPathValidation "Verified local path: DownloadFolder = $DownloadFolder"
    }
} else {
    Add-LocalPathValidation "Missing local path: DownloadFolder not set"
}

# Flush path validation to logs
if ($localPathValidation.Count -gt 0) {
    foreach ($entry in $localPathValidation) {
        Write-AppLog $entry "Info"
        Write-ScriptLog $entry "Script1" "Info"
    }
}

# Import AVPN module if available
if (Test-Path $avpnModulePath) {
    Import-Module $avpnModulePath -Force
} else {
    Write-AppLog "AVPN module not found at $avpnModulePath" "Warning"
}

# ==================== PROGRESS & DISPLAY FUNCTIONS ====================
# Get-RainbowColor and Write-RainbowProgress are now provided by PwShGUICore module.

function Invoke-CommandWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $true)]
        [string]$Activity,
        
        [Parameter(Mandatory = $true)]
        [string]$StepName,
        
        [Parameter(Mandatory = $true)]
        [int]$StepNumber,
        
        [Parameter(Mandatory = $true)]
        [int]$TotalSteps,
        
        [int]$EstimatedSeconds = 5
    )
    
    $startTime = Get-Date
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "▶ STEP ${StepNumber} of ${TotalSteps}: ${StepName}" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    Write-AppLog "Starting: $StepName" "Info"
    Write-ScriptLog "Executing step ${StepNumber} - ${StepName}" "Script1" "Info"
    
    # Progress initialization
    $elapsedBlocks = 0
    $percentComplete = 0
    
    # Start background job for command execution
    $job = Start-Job -ScriptBlock $ScriptBlock
    
    # Monitor progress with rainbow bar
    while ($job.State -eq 'Running') {
        $elapsed = (Get-Date) - $startTime
        $elapsedSeconds = [Math]::Floor($elapsed.TotalSeconds)
        
        # Update progress every second
        if ($elapsedSeconds -lt $EstimatedSeconds -and $EstimatedSeconds -gt 0) {
            $percentComplete = [Math]::Floor(($elapsedSeconds / $EstimatedSeconds) * 100)
        } else {
            $percentComplete = 95 + ($elapsedSeconds - $EstimatedSeconds)
            if ($percentComplete -gt 99) { $percentComplete = 99 }
        }
        
        # Check for 5-second blocks
        $currentBlock = [Math]::Floor($elapsedSeconds / 5)
        if ($currentBlock -gt $elapsedBlocks) {
            $elapsedBlocks = $currentBlock
            Write-Host "`n⏱  Elapsed: $($elapsedBlocks * 5) seconds" -ForegroundColor Magenta
        }
        
        $status = "Processing... Elapsed: $elapsedSeconds s"
        Write-RainbowProgress -Activity $Activity -PercentComplete $percentComplete -Status $status -Step $elapsedSeconds
        
        Start-Sleep -Milliseconds 500
    }
    
    # Get the result
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    
    # Show completion at 101%
    $finalElapsed = ((Get-Date) - $startTime).TotalSeconds
    Write-RainbowProgress -Activity $Activity -PercentComplete 101 -Status "COMPLETED!" -Step ($StepNumber * 10)
    
    Write-Host "`n✓ COMPLETED: $StepName" -ForegroundColor Green
    Write-Host "  Duration: $([Math]::Round($finalElapsed, 2)) seconds" -ForegroundColor Gray
    
    if ($result) {
        $itemCount = if ($result -is [Array]) { $result.Count } else { 1 }
        Write-Host "  Items processed: $itemCount" -ForegroundColor Gray
    }
    
    Write-AppLog "Completed: $StepName (Duration: $([Math]::Round($finalElapsed, 2))s)" "Info"
    Write-ScriptLog "Step $StepNumber completed with $itemCount items" "Script1" "Info"
    
    return $result
}

function Show-DetailedOutput {
    param(
        [Parameter(Mandatory = $true)]
        $Data,
        
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    
    Write-Host "`n╔═══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║ 📊 $Title" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    if ($Data) {
        $Data | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor White
        Write-Host "Total items: $($Data.Count)" -ForegroundColor Yellow
    } else {
        Write-Host "  No data available" -ForegroundColor Gray
    }
}

function Export-XHTMLReport {
    param(
        [Parameter(Mandatory = $true)]
        $Data,
        
        [Parameter(Mandatory = $true)]
        [string]$ReportTitle,
        
        [Parameter(Mandatory = $true)]
        [string]$ReportType,
        
        [string]$ScriptSynopsis = "Script1-Account-User-Management"
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
    $hostname = $env:COMPUTERNAME
    $fileName = "${hostname}_${timestamp}_${ScriptSynopsis}_${ReportType}.xhtml"
    $reportPath = Join-Path $reportsDir $fileName
    
    # Build HTML table from data
    $tableRows = ""
    if ($Data -and $Data.Count -gt 0) {
        # Get properties from first object
        $properties = if ($Data[0] -is [string]) {
            @("Value")
        } else {
            $Data[0].PSObject.Properties.Name
        }
        
        # Build table header
        $tableHeader = "<tr>"
        foreach ($prop in $properties) {
            $tableHeader += "<th>$prop</th>"
        }
        $tableHeader += "</tr>"
        
        # Build table rows
        foreach ($item in $Data) {
            $tableRows += "<tr>"
            if ($item -is [string]) {
                $tableRows += "<td>$([System.Web.HttpUtility]::HtmlEncode($item))</td>"
            } else {
                foreach ($prop in $properties) {
                    $value = $item.$prop
                    if ($null -eq $value) { $value = "" }
                    $tableRows += "<td>$([System.Web.HttpUtility]::HtmlEncode($value))</td>"
                }
            }
            $tableRows += "</tr>"
        }
        
        $tableContent = $tableHeader + $tableRows
        $itemCount = $Data.Count
    } else {
        $tableContent = "<tr><td colspan='10'>No data available</td></tr>"
        $itemCount = 0
    }
    
    $generatedTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Create fancy XHTML with CSS
    $xhtml = @"
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8" />
    <title>$ReportTitle - $hostname</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            color: #333;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }
        
        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }
        
        .info-bar {
            background: #f8f9fa;
            padding: 20px 30px;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            border-bottom: 3px solid #667eea;
        }
        
        .info-item {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .info-label {
            font-weight: bold;
            color: #667eea;
        }
        
        .info-value {
            color: #555;
        }
        
        .stats-bar {
            background: linear-gradient(90deg, #56ccf2 0%, #2f80ed 100%);
            color: white;
            padding: 15px 30px;
            text-align: center;
            font-size: 1.3em;
            font-weight: bold;
        }
        
        .content {
            padding: 30px;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        thead {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        
        th {
            padding: 15px;
            text-align: left;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.9em;
            letter-spacing: 0.5px;
        }
        
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
        }
        
        tbody tr:hover {
            background-color: #f5f5ff;
            transition: background-color 0.3s ease;
        }
        
        tbody tr:nth-child(even) {
            background-color: #f9f9f9;
        }
        
        tbody tr:nth-child(even):hover {
            background-color: #f0f0ff;
        }
        
        .footer {
            background: #2d3436;
            color: #b2bec3;
            padding: 20px 30px;
            text-align: center;
            font-size: 0.9em;
        }
        
        .footer .generated {
            margin-top: 10px;
            font-size: 0.85em;
            opacity: 0.8;
        }
        
        .badge {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 20px;
            background: #667eea;
            color: white;
            font-size: 0.85em;
            font-weight: bold;
        }
        
        .no-data {
            text-align: center;
            padding: 40px;
            color: #999;
            font-size: 1.2em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🖥️ $ReportTitle</h1>
            <div class="subtitle">$ReportType Report</div>
        </div>
        
        <div class="info-bar">
            <div class="info-item">
                <span class="info-label">Computer:</span>
                <span class="info-value">$hostname</span>
            </div>
            <div class="info-item">
                <span class="info-label">User:</span>
                <span class="info-value">$env:USERNAME</span>
            </div>
            <div class="info-item">
                <span class="info-label">Generated:</span>
                <span class="info-value">$generatedTime</span>
            </div>
            <div class="info-item">
                <span class="info-label">PowerShell:</span>
                <span class="info-value">$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)</span>
            </div>
        </div>
        
        <div class="stats-bar">
            📊 Total Items: <span class="badge">$itemCount</span>
        </div>
        
        <div class="content">
            <table>
                <thead>
                    $tableContent
                </thead>
                <tbody>
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <div>PowerShell GUI Application - Script1: Account & User Management</div>
            <div class="generated">Report generated by $env:USERNAME on $hostname at $generatedTime</div>
            <div class="generated">File: $fileName</div>
        </div>
    </div>
</body>
</html>
"@
    
    # Save XHTML report
    Add-Type -AssemblyName System.Web
    $xhtml | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    
    Write-Host "  📄 Report saved: $fileName" -ForegroundColor Green
    Write-AppLog "XHTML report generated: $reportPath" "Info"
    Write-ScriptLog "Generated $ReportType report with $itemCount items" "Script1" "Info"
    
    # Open in default browser
    Start-Process $reportPath
    
    return $reportPath
}

# ==================== COMPREHENSIVE XHTML REPORT FUNCTION ====================
function Export-ComprehensiveXHTMLReport {
    <#
    .SYNOPSIS
        Generates a comprehensive XHTML report with multiple sections
    .PARAMETER ReportSections
        Array of hashtables containing section data (Title, Data)
    .PARAMETER ScriptSynopsis
        Brief description of the script for the report title
    .PARAMETER SummaryData
        Hashtable containing summary statistics
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$ReportSections,
        
        [Parameter(Mandatory=$false)]
        [string]$ScriptSynopsis = "PowerShell-Report",
        
        [Parameter(Mandatory=$false)]
        [hashtable]$SummaryData
    )
    
    # Generate report metadata
    $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
    $hostname = $env:COMPUTERNAME
    $currentUser = $env:USERNAME
    $psVersion = $PSVersionTable.PSVersion.ToString()
    $generatedTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Create filename
    $fileName = "${hostname}_${timestamp}_${ScriptSynopsis}.xhtml"
    $reportPath = Join-Path $reportsDir $fileName
    
    Write-Host "`n📊 Generating comprehensive XHTML report..." -ForegroundColor Cyan
    
    # Count total items across all sections
    $totalItems = 0
    foreach ($section in $ReportSections) {
        if ($section.Data) {
            $totalItems += @($section.Data).Count
        }
    }
    
    # Build HTML sections
    $sectionsHtml = ""
    $sectionNumber = 1
    
    foreach ($section in $ReportSections) {
        $sectionTitle = $section.Title
        $sectionData = $section.Data
        
        if (-not $sectionData) {
            $sectionsHtml += @"
        <div class="section">
            <h2>$sectionNumber. $sectionTitle</h2>
            <p class="no-data">No data available for this section.</p>
        </div>
"@
            $sectionNumber++
            continue
        }
        
        $sectionItemCount = @($sectionData).Count
        
        # Convert data to HTML table
        $tableHtml = "<table>`n<thead><tr>"
        
        # Get properties from first object
        $firstItem = $sectionData | Select-Object -First 1
        $properties = $firstItem.PSObject.Properties.Name
        
        # Generate table headers
        foreach ($prop in $properties) {
            $tableHtml += "<th>$([System.Web.HttpUtility]::HtmlEncode($prop))</th>"
        }
        $tableHtml += "</tr></thead>`n<tbody>`n"
        
        # Generate table rows
        foreach ($item in $sectionData) {
            $tableHtml += "<tr>"
            foreach ($prop in $properties) {
                $value = $item.$prop
                if ($null -eq $value) { $value = "" }
                $tableHtml += "<td>$([System.Web.HttpUtility]::HtmlEncode($value.ToString()))</td>"
            }
            $tableHtml += "</tr>`n"
        }
        $tableHtml += "</tbody>`n</table>"
        
        $sectionsHtml += @"
        <div class="section">
            <h2>$sectionNumber. $sectionTitle <span class="badge">$sectionItemCount items</span></h2>
            $tableHtml
        </div>
"@
        $sectionNumber++
    }
    
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $adminWarningHtml = ""
    if (-not $isAdmin) {
        $adminWarningHtml = '<div class="admin-warning">WARNING - THIS WAS NOT RAN WITH ADMIN RIGHTS - Admin execution rights are required for the correct Exec values</div>'
    }

    # Build summary section if provided
    $summaryHtml = ""
    if ($SummaryData) {
        $summaryHtml = @"
        <div class="summary-section">
            <h2>📊 Executive Summary</h2>
            $adminWarningHtml
            <div class="summary-grid">
"@
        foreach ($key in $SummaryData.Keys) {
            $value = $SummaryData[$key]
            $summaryHtml += @"
                <div class="summary-item">
                    <div class="summary-label">$([System.Web.HttpUtility]::HtmlEncode($key))</div>
                    <div class="summary-value">$([System.Web.HttpUtility]::HtmlEncode($value.ToString()))</div>
                </div>
"@
        }
        $summaryHtml += @"
            </div>
        </div>
"@
    }
    
    # Build complete XHTML document
    $xhtml = @"
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>$ScriptSynopsis - Comprehensive Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.2em;
            margin-bottom: 15px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        
        .info-bar {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            background: rgba(255,255,255,0.1);
            padding: 20px;
            border-radius: 8px;
            margin-top: 20px;
        }
        
        .info-item {
            text-align: center;
        }
        
        .info-label {
            font-size: 0.9em;
            opacity: 0.9;
            margin-bottom: 5px;
        }
        
        .info-value {
            font-size: 1.1em;
            font-weight: bold;
        }
        
        .content {
            padding: 30px;
        }
        
        .summary-section {
            background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%);
            padding: 25px;
            border-radius: 8px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        
        .summary-section h2 {
            color: #333;
            margin-bottom: 20px;
            font-size: 1.8em;
        }

        .admin-warning {
            margin: 0 0 20px 0;
            padding: 12px 16px;
            background: #ffe5e5;
            color: #b00020;
            border: 1px solid #f5b5b5;
            border-radius: 6px;
            font-weight: 700;
            text-align: center;
        }
        
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
        }
        
        .summary-item {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: transform 0.2s;
        }
        
        .summary-item:hover {
            transform: translateY(-5px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }
        
        .summary-label {
            font-size: 0.9em;
            color: #666;
            margin-bottom: 8px;
        }
        
        .summary-value {
            font-size: 1.5em;
            font-weight: bold;
            color: #667eea;
        }
        
        .section {
            margin-bottom: 40px;
            background: #f8f9fa;
            padding: 25px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        }
        
        .section h2 {
            color: #333;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #667eea;
            font-size: 1.6em;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .badge {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.7em;
            font-weight: normal;
        }
        
        .no-data {
            color: #999;
            font-style: italic;
            padding: 20px;
            text-align: center;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        }
        
        thead {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        
        th {
            padding: 15px;
            text-align: left;
            font-weight: 600;
            font-size: 0.95em;
            letter-spacing: 0.5px;
        }
        
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
            color: #333;
        }
        
        tbody tr {
            transition: background-color 0.2s;
        }
        
        tbody tr:nth-child(even) {
            background-color: #f8f9fa;
        }
        
        tbody tr:hover {
            background-color: #e3f2fd;
        }
        
        .footer {
            background: #2c3e50;
            color: white;
            padding: 20px;
            text-align: center;
            font-size: 0.9em;
        }
        
        .footer-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        
        @media print {
            body {
                background: white;
                padding: 0;
            }
            .container {
                box-shadow: none;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📋 $ScriptSynopsis</h1>
            <h3>Comprehensive System Report</h3>
            <div class="info-bar">
                <div class="info-item">
                    <div class="info-label">🖥 Computer</div>
                    <div class="info-value">$hostname</div>
                </div>
                <div class="info-item">
                    <div class="info-label">👤 Generated By</div>
                    <div class="info-value">$currentUser</div>
                </div>
                <div class="info-item">
                    <div class="info-label">📅 Generated</div>
                    <div class="info-value">$generatedTime</div>
                </div>
                <div class="info-item">
                    <div class="info-label">⚡ PowerShell</div>
                    <div class="info-value">$psVersion</div>
                </div>
                <div class="info-item">
                    <div class="info-label">📊 Total Items</div>
                    <div class="info-value">$totalItems</div>
                </div>
            </div>
        </div>
        
        <div class="content">
            $summaryHtml
            $sectionsHtml
        </div>
        
        <div class="footer">
            <strong>PowerShell Report System</strong>
            <div class="footer-grid">
                <div>Script: $ScriptSynopsis</div>
                <div>User: $currentUser@$hostname</div>
                <div>Generated: $generatedTime</div>
                <div>File: $fileName</div>
            </div>
        </div>
    </div>
</body>
</html>
"@
    
    # Save XHTML report
    Add-Type -AssemblyName System.Web
    $xhtml | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    
    Write-Host "  ✓ Comprehensive report saved: $fileName" -ForegroundColor Green
    Write-Host "  ✓ Total sections: $($ReportSections.Count)" -ForegroundColor Cyan
    Write-Host "  ✓ Total items: $totalItems" -ForegroundColor Cyan
    Write-AppLog "Comprehensive XHTML report generated: $reportPath" "Info"
    Write-ScriptLog "Generated comprehensive report with $($ReportSections.Count) sections and $totalItems items" "Script1" "Info"
    
    # Open in default browser
    Start-Process $reportPath
    
    return $reportPath
}

# ==================== CONFIG FUNCTIONS ====================
# Initialize-ConfigFile is now provided by PwShGUICore module (unused in this script).

# ==================== SCRIPT MAIN EXECUTION ====================
$scriptStartTime = Get-Date
Write-AppLog "Script1 execution started" "Info"

Write-Host "`n" -NoNewline
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                                                                ║" -ForegroundColor Cyan
Write-Host "║     SCRIPT1: ACCOUNTS - LOCAL USER MANAGEMENT                 ║" -ForegroundColor Yellow
Write-Host "║                                                                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n📋 Execution Details:" -ForegroundColor Cyan
Write-Host "  🖥  Computer:        $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  👤 User:            $env:USERNAME" -ForegroundColor White
Write-Host "  🔧 PowerShell:      $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -ForegroundColor White
Write-Host "  📅 Execution Time:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  📂 Log Directory:   $logsDir" -ForegroundColor White
Write-Host "  📊 Reports Folder:  $reportsDir" -ForegroundColor Cyan

$scriptSynopsis = "Script1-Account-User-Management"

$totalSteps = 6
Write-Host "`n🔄 Total Steps to Execute: $totalSteps" -ForegroundColor Yellow
Write-Host ""

Write-ScriptLog "Starting user account management tasks" "Script1" "Info"

# ==================== STEP 1: Get Local Users ====================
$users = Invoke-CommandWithProgress -Activity "User Management" -StepName "Retrieving Local Users" -StepNumber 1 -TotalSteps $totalSteps -EstimatedSeconds 3 -ScriptBlock {
    net user
}

$userData = @()
if ($users) {
    $userCount = [Math]::Max(0, $users.Count - 8)
    if ($userCount -gt 0) {
        $userData = $users | Select-Object -Skip 4 | Select-Object -First $userCount | ForEach-Object { [PSCustomObject]@{UserName = $_.Trim()} }
        Show-DetailedOutput -Data $userData -Title "LOCAL USERS"
    }
}
Write-ScriptLog "Listed $($users.Count) local users" "Script1" "Info"

# ==================== STEP 2: Get Local Groups ====================
$groups = Invoke-CommandWithProgress -Activity "Group Management" -StepName "Retrieving Local Groups" -StepNumber 2 -TotalSteps $totalSteps -EstimatedSeconds 2 -ScriptBlock {
    net localgroup
}

$groupData = @()
if ($groups) {
    $groupCount = [Math]::Max(0, $groups.Count - 6)
    if ($groupCount -gt 0) {
        $groupData = $groups | Select-Object -Skip 4 | Select-Object -First $groupCount | ForEach-Object { [PSCustomObject]@{GroupName = $_.Trim()} }
        Show-DetailedOutput -Data $groupData -Title "LOCAL GROUPS"
    }
}
Write-ScriptLog "Listed $($groups.Count) local groups" "Script1" "Info"

# ==================== STEP 3: Get Administrators ====================
$admins = Invoke-CommandWithProgress -Activity "Administrator Audit" -StepName "Retrieving Administrator Group Members" -StepNumber 3 -TotalSteps $totalSteps -EstimatedSeconds 2 -ScriptBlock {
    net localgroup administrators
}

$adminData = @()
if ($admins) {
    $adminCount = [Math]::Max(0, $admins.Count - 8)
    if ($adminCount -gt 0) {
        $adminData = $admins | Select-Object -Skip 6 | Select-Object -First $adminCount | ForEach-Object { [PSCustomObject]@{Administrator = $_.Trim()} }
        Show-DetailedOutput -Data $adminData -Title "ADMINISTRATORS GROUP MEMBERS"
    }
}
Write-ScriptLog "Listed administrators group members" "Script1" "Info"

# ==================== STEP 4: Get Disabled Accounts ====================
$disabledAccounts = Invoke-CommandWithProgress -Activity "Account Status Check" -StepName "Identifying Disabled/Inactive Accounts" -StepNumber 4 -TotalSteps $totalSteps -EstimatedSeconds 4 -ScriptBlock {
    Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True and Disabled=True" | 
        Select-Object Name, Disabled, Description, LocalAccount, SID
}

if ($disabledAccounts) {
    Show-DetailedOutput -Data $disabledAccounts -Title "DISABLED ACCOUNTS"
    Write-Host "⚠  Found $($disabledAccounts.Count) disabled account(s)" -ForegroundColor Yellow
} else {
    Write-Host "✓ No disabled accounts found" -ForegroundColor Green
}
Write-ScriptLog "Found $($disabledAccounts.Count) disabled accounts" "Script1" "Info"

# ==================== STEP 5: Get User Privileges ====================
$privileges = Invoke-CommandWithProgress -Activity "Security Audit" -StepName "Auditing Current User Privileges" -StepNumber 5 -TotalSteps $totalSteps -EstimatedSeconds 3 -ScriptBlock {
    whoami /all
}

$privilegeData = @()
if ($privileges) {
    Write-Host "`n╔═══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║ 🔐 CURRENT USER PRIVILEGES & SECURITY INFORMATION" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    $privileges | Write-Host -ForegroundColor White
    $privilegeData = $privileges | ForEach-Object { [PSCustomObject]@{PrivilegeInfo = $_.Trim()} }
}
Write-ScriptLog "Listed user privileges and security information" "Script1" "Info"

# ==================== STEP 6: Generate Summary Report ====================
$summaryReport = Invoke-CommandWithProgress -Activity "Report Generation" -StepName "Generating Summary Report" -StepNumber 6 -TotalSteps $totalSteps -EstimatedSeconds 2 -ScriptBlock {
    @{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Computer = $env:COMPUTERNAME
        User = $env:USERNAME
        TotalUsers = $userData.Count
        TotalGroups = $groupData.Count
        AdminCount = $adminData.Count
        DisabledAccounts = if ($disabledAccounts) { $disabledAccounts.Count } else { 0 }
    }
}

$scriptEndTime = Get-Date
$totalDuration = ($scriptEndTime - $scriptStartTime).TotalSeconds

# Save summary to log
$summaryText = @"
=== SCRIPT1 EXECUTION SUMMARY ===
Timestamp: $($summaryReport.Timestamp)
Computer: $($summaryReport.Computer)
User: $($summaryReport.User)
Total Users: $($summaryReport.TotalUsers)
Total Groups: $($summaryReport.TotalGroups)
Administrators: $($summaryReport.AdminCount)
Disabled Accounts: $($summaryReport.DisabledAccounts)
Duration: $([Math]::Round($totalDuration, 2)) seconds
================================
"@

Add-Content -Path (Join-Path $logsDir "Script1-Summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt") -Value $summaryText -Encoding UTF8

$reportSections = @(
    @{ Title = "Local User Accounts"; Data = $userData },
    @{ Title = "Local Groups"; Data = $groupData },
    @{ Title = "Administrator Group Members"; Data = $adminData },
    @{ Title = "Disabled User Accounts"; Data = $disabledAccounts },
    @{ Title = "Current User Privileges & Security"; Data = $privilegeData }
)

$summaryData = [ordered]@{
    "Computer" = $summaryReport.Computer
    "Audited By" = $summaryReport.User
    "Total Users" = $summaryReport.TotalUsers
    "Total Groups" = $summaryReport.TotalGroups
    "Administrators" = $summaryReport.AdminCount
    "Disabled Accounts" = $summaryReport.DisabledAccounts
    "Duration (seconds)" = [Math]::Round($totalDuration, 2)
}

$reportPath = Export-ComprehensiveXHTMLReport -ReportSections $reportSections -ScriptSynopsis $scriptSynopsis -SummaryData $summaryData
Write-Host "📄 Aggregated report: $reportPath" -ForegroundColor Cyan

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                     📊 EXECUTION SUMMARY                       ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  Computer:          $($summaryReport.Computer)" -ForegroundColor White
Write-Host "  Audited By:        $($summaryReport.User)" -ForegroundColor White
Write-Host "  Total Users:       $($summaryReport.TotalUsers)" -ForegroundColor Cyan
Write-Host "  Total Groups:      $($summaryReport.TotalGroups)" -ForegroundColor Cyan
Write-Host "  Administrators:    $($summaryReport.AdminCount)" -ForegroundColor Yellow
Write-Host "  Disabled Accounts: $($summaryReport.DisabledAccounts)" -ForegroundColor $(if ($summaryReport.DisabledAccounts -gt 0) { "Red" } else { "Green" })
Write-Host "  Report File:       $reportPath" -ForegroundColor Cyan
Write-Host "`n⏱  Total Execution Time: $([Math]::Round($totalDuration, 2)) seconds" -ForegroundColor Magenta
Write-Host ""

Write-Host "✓ USER MANAGEMENT AUDIT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-AppLog "Script1 execution completed successfully. Duration: $([Math]::Round($totalDuration, 2))s" "Info"
Write-ScriptLog "All steps completed. Summary saved to logs." "Script1" "Info"

Write-Host "`nPress any key to continue (will auto-continue in 7 seconds)..." -ForegroundColor Gray
$timeout = 7
$timer = [Diagnostics.Stopwatch]::StartNew()
while ($timer.Elapsed.TotalSeconds -lt $timeout) {
    if ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
        break
    }
    $remaining = $timeout - [Math]::Floor($timer.Elapsed.TotalSeconds)
    Write-Host "`r⏳ Auto-continuing in $remaining seconds..." -NoNewline -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
}
$timer.Stop()
Write-Host "`n"





















<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





