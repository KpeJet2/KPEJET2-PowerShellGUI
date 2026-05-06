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
Quick App - System Repair Tool

.DESCRIPTION
Performs system repair operations including System File Checker, DISM, and Disk Check.

.NOTES

.LINK

.INPUTS

.OUTPUTS

.FUNCTIONALITY
System repair and restoration for local system health.

.AUTHOR
The Establishment

.CREATED
16th February 2026

.MODIFIED
16th February 2026

.VERSION
1.0.0

.CONFIG-BASE
pwsh-app-config-BASE.json
#>

# Stop on errors
$ErrorActionPreference = "Stop"

# Define LOCAL script directory and paths
$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentDir = Split-Path -Parent $localRoot

# Define LOCAL region Configuration
$ConfigPath = Join-Path $parentDir "config"
$DefaultFolder = $parentDir
$TempFolder = Join-Path $parentDir "temp"
$ReportFolder = Join-Path $parentDir "~REPORTS"
$DownloadFolder = Join-Path $parentDir "~DOWNLOADS"

# Create local directories if they don't exist
if ($ConfigPath -and -not (Test-Path $ConfigPath)) { New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null }
if ($DefaultFolder -and -not (Test-Path $DefaultFolder)) { New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null }
if ($TempFolder -and -not (Test-Path $TempFolder)) { New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null }
if ($ReportFolder -and -not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
if ($DownloadFolder -and -not (Test-Path $DownloadFolder)) { New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null }

# Define GLOBAL script directory and Files
$scriptDir = Split-Path -Parent $parentDir
$configDir = Join-Path $scriptDir "config"
$modulesDir = Join-Path $scriptDir "modules"
$logsDir = Join-Path $scriptDir "logs"
$scriptsDir = Join-Path $scriptDir "scripts"
$configFile = Join-Path $configDir "system-variables.xml"
$linksConfigFile = Join-Path $configDir "links.xml"
$avpnConfigFile = Join-Path $configDir "AVPN-devices.json"
$avpnModulePath = Join-Path $modulesDir "AVPN-Tracker.psm1"

# Create GLOBAL directories if they don't exist
if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null }
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
if (-not (Test-Path $modulesDir)) { New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
if (-not (Test-Path $configFile)) { New-Item -ItemType File -Path $configFile -Force | Out-Null }
if (-not (Test-Path $linksConfigFile)) { New-Item -ItemType File -Path $linksConfigFile -Force | Out-Null }
if (-not (Test-Path $avpnConfigFile)) { New-Item -ItemType File -Path $avpnConfigFile -Force | Out-Null }

# ==================== LOGGING FUNCTIONS ====================
# Write-AppLog, Write-ScriptLog -- now provided by PwShGUICore module
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

# ==================== CONFIG FUNCTIONS ====================
function Load-ConfigFile {
    if (Test-Path $configFile) {
        try {
            [xml]$xml = Get-Content $configFile
            return $xml
        } catch {
            Write-AppLog "Error loading config file: $_" "Warning"
            return $null
        }
    }
    return $null
}

function Get-ConfigValue {
    param([string]$Path)
    
    $config = Load-ConfigFile
    if ($config) {
        try {
            $value = $config.SelectSingleNode("/SystemVariables/$Path")
            return $value.InnerText
        } catch {
            return $null
        }
    }
    return $null
}

function Save-ConfigValue {
    param(
        [string]$Path,
        [string]$Value
    )
    
    $config = Load-ConfigFile
    if (-not $config) {
        $config = New-Object Xml
        $root = $config.CreateElement("SystemVariables")
        $config.AppendChild($root) | Out-Null
    }
    
    try {
        $node = $config.SelectSingleNode("/SystemVariables/$Path")
        if ($node) {
            $node.InnerText = $Value
        } else {
            $parent = $config.SelectSingleNode("/SystemVariables")
            $newNode = $config.CreateElement("Config")
            $newNode.InnerText = $Value
            $parent.AppendChild($newNode) | Out-Null
        }
        
        $config.Save($configFile)
        Write-AppLog "Config saved: $Path = $Value" "Info"
    } catch {
        Write-AppLog "Error saving config: $_" "Error"
    }
}

# ==================== REPAIR HELPERS ====================
function Evaluate-RepairResult {
    param(
        [string]$Name,
        [string[]]$Output,
        [int]$ExitCode
    )

    if (-not $Output -or $Output.Count -eq 0) {
        return @{ Status = "Null"; Summary = "No output returned" }
    }

    $text = ($Output -join "`n")
    $lower = $text.ToLowerInvariant()

    if ($ExitCode -ne 0 -and $Name -notmatch "chkdsk") {
        return @{ Status = "Fail"; Summary = "Non-zero exit code: $ExitCode" }
    }

    if ($lower -match "error|failed|corrupt" -and $lower -notmatch "no corruption|no errors") {
        return @{ Status = "Fail"; Summary = "Detected error indicators" }
    }

    if ($Name -match "sfc" -and $lower -match "integrity was verified") {
        return @{ Status = "Success"; Summary = "SFC verified integrity successfully" }
    }

    if ($Name -match "dism" -and $lower -match "operation completed successfully") {
        return @{ Status = "Success"; Summary = "DISM repair completed successfully" }
    }

    if ($Name -match "chkdsk" -and $lower -match "no errors|repair complete") {
        return @{ Status = "Success"; Summary = "CHKDSK repair completed successfully" }
    }

    return @{ Status = "Success"; Summary = "Repair step completed" }
}

function Get-SelectedRepairSteps {
    param([array]$Steps)

    while ($true) {
        Write-Host "" 
        Write-Host "REPAIR-STEPS (all selected by default - requires Admin):" -ForegroundColor Cyan
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Host "WARNING: Not running as Administrator. Repair steps will fail." -ForegroundColor Red
        }
        
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            $step = $Steps[$i]
            Write-Host ("  [{0}] {1}. {2}" -f "X", ($i + 1), $step.Name)
        }
        Write-Host "" 
        $input = Read-Host "Press Enter to run all, or list numbers (e.g. 1,3)"

        if ([string]::IsNullOrWhiteSpace($input)) {
            return $Steps
        }

        $indices = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' }
        if ($indices.Count -gt 0) {
            $selected = @()
            foreach ($idx in $indices) {
                $i = [int]$idx - 1
                if ($i -ge 0 -and $i -lt $Steps.Count) {
                    $selected += $Steps[$i]
                }
            }
            if ($selected.Count -gt 0) {
                return $selected
            }
        }

        Write-Warning "Invalid input. Try again."
    }
}

function Export-RepairReport {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $hostname = $env:COMPUTERNAME
    $user = $env:USERNAME

    $rows = ""
    foreach ($result in $Results) {
        $statusClass = if ($result.Status -in @("Fail", "Null")) { "attention" } else { "" }
        $statusLabelClass = if ($result.Status -eq "Fail") { "status-fail" } else { "" }
        $rows += "<tr class='$statusClass'><td>$($result.Step)</td><td>$($result.Name)</td><td class='$statusLabelClass'>$($result.Status)</td><td>$($result.Summary)</td><td>$($result.Duration)</td></tr>"
    }

    $detailSections = ""
    foreach ($result in $Results) {
        $output = [System.Web.HttpUtility]::HtmlEncode(($result.Output -join "`n"))
        $detailSections += "<div class='section'><h3>$($result.Step). $($result.Name)</h3><pre>$output</pre></div>"
    }

    $html = @"
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Quick App REPAIR Report</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f2f4f8; margin: 0; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 6px 18px rgba(0,0,0,0.1); }
        h1 { margin: 0 0 10px 0; }
        .meta { color: #666; margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
        th, td { border-bottom: 1px solid #eee; padding: 10px; text-align: left; }
        th { background: #f5f7fb; }
        .attention { animation: pulse 180s ease-in-out; background: #ffe5e5; }
        .status-fail { color: #b00020; font-weight: bold; }
        @keyframes pulse { 0% { background: #ffe5e5; } 100% { background: #ffffff; } }
        .section { margin-top: 20px; }
        pre { background: #0f172a; color: #e2e8f0; padding: 12px; border-radius: 6px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Quick App - REPAIR Report</h1>
        <div class="meta">Computer: $hostname | User: $user | Generated: $timestamp</div>
        <table>
            <thead>
                <tr>
                    <th>Step</th>
                    <th>Name</th>
                    <th>Status</th>
                    <th>Summary</th>
                    <th>Duration (s)</th>
                </tr>
            </thead>
            <tbody>
                $rows
            </tbody>
        </table>
        $detailSections
    </div>
</body>
</html>
"@

    Add-Type -AssemblyName System.Web
    $html | Out-File -FilePath $ReportPath -Encoding UTF8 -Force
}

# ==================== MAIN ====================
$repairSteps = @(
    [PSCustomObject]@{ Name = "System File Checker (SFC)"; Type = "Cmd"; Command = "sfc /scannow"; Description = "Scan and repair system files" },
    [PSCustomObject]@{ Name = "DISM Restore Health"; Type = "Cmd"; Command = "dism /Online /Cleanup-Image /RestoreHealth"; Description = "Restore Windows image health" },
    [PSCustomObject]@{ Name = "Check Disk Spot Fix"; Type = "Cmd"; Command = "chkdsk c: /spotfix"; Description = "Fix file system errors on C: drive" }
)

$selectedSteps = Get-SelectedRepairSteps -Steps $repairSteps

$results = @()
$stepNumber = 1
foreach ($step in $selectedSteps) {
    Write-Host "`n--- Running Step ${stepNumber}: $($step.Name) ---" -ForegroundColor Cyan
    $start = Get-Date
    $output = @()
    $exitCode = 0

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            $output = @("This repair step requires elevated administrator rights.")
            $exitCode = 5
        } else {
            $output = @()
            & cmd.exe /c $step.Command 2>&1 | ForEach-Object {
                Write-Host $_
                $output += $_
            }
            $exitCode = $LASTEXITCODE
        }
    } catch {
        $output = @("Error: $_")
        $exitCode = 1
    }

    $elapsed = [Math]::Round(((Get-Date) - $start).TotalSeconds, 2)
    $evaluation = Evaluate-RepairResult -Name $step.Name -Output $output -ExitCode $exitCode

    $results += [PSCustomObject]@{
        Step = $stepNumber
        Name = $step.Name
        Status = $evaluation.Status
        Summary = $evaluation.Summary
        Duration = $elapsed
        Output = $output
    }

    $statusColor = if ($evaluation.Status -eq "Fail") { "Red" } elseif ($evaluation.Status -eq "Null") { "Yellow" } else { "Green" }
    Write-Host "Status: $($evaluation.Status) - $($evaluation.Summary)" -ForegroundColor $statusColor
    $stepNumber++
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$reportName = "$($env:COMPUTERNAME)_${timestamp}_Quick-APP-REPAIR.xhtml"
$reportPath = Join-Path $ReportFolder $reportName
Export-RepairReport -Results $results -ReportPath $reportPath

Write-Host "`nReport saved to: $reportPath" -ForegroundColor Cyan
Start-Process $reportPath

Write-Host "`nRepair steps completed. Please review the report for details." -ForegroundColor Green
Write-AppLog "REPAIR script execution completed" "Info"
Write-ScriptLog "All repair steps completed" "REPAIR" "Info"





















<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





