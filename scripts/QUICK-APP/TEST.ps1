# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
#Requires -Version 5.1
<#[
.SYNOPSIS
Quick App - Test Runner

.DESCRIPTION
Runs a curated list of diagnostic tests and produces a consolidated XHTML report.

.NOTES

.LINK

.INPUTS

.OUTPUTS

.FUNCTIONALITY
Diagnostics and health checks for a local system with report output.

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

# Create local directories if they don't exist
if ($ConfigPath -and -not (Test-Path $ConfigPath)) { New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null }
if ($DefaultFolder -and -not (Test-Path $DefaultFolder)) { New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null }
if ($TempFolder -and -not (Test-Path $TempFolder)) { New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null }
if ($ReportFolder -and -not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

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

# ==================== TEST HELPERS ======================================
function Compare-WinVer {
    $results = @()
    $localOs = Get-CimInstance -ClassName Win32_OperatingSystem
    $localInfo = [PSCustomObject]@{
        Scope = "Local"
        Computer = $env:COMPUTERNAME
        Version = $localOs.Version
        Build = $localOs.BuildNumber
        Caption = $localOs.Caption
    }
    $results += $localInfo

    $neighbors = @()
    try {
        $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty IPAddress -Unique
    } catch {
        $neighbors = @()
    }

    foreach ($ip in $neighbors) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ip -ErrorAction Stop
            $results += [PSCustomObject]@{
                Scope = "LAN"
                Computer = $ip
                Version = $os.Version
                Build = $os.BuildNumber
                Caption = $os.Caption
            }
        } catch {
            continue
        }
    }

    if ($results.Count -eq 0) {
        $results = @([PSCustomObject]@{
            Scope = "Local"
            Computer = $env:COMPUTERNAME
            Version = $localOs.Version
            Build = $localOs.BuildNumber
            Caption = $localOs.Caption
        })
    }

    return $results
}

function Get-CriticalEventSummary {
    $startTime = (Get-Date).AddDays(-7)
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = @("System", "Application"); Level = 1,2; StartTime = $startTime } -ErrorAction Stop
        if (-not $events) {
            return @()
        }

        $grouped = $events | Group-Object -Property Id, ProviderName, LogName
        $summary = foreach ($group in $grouped) {
            $first = ($group.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            $last = ($group.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            [PSCustomObject]@{
                EventId = $group.Group[0].Id
                Source = $group.Group[0].ProviderName
                LogName = $group.Group[0].LogName
                FirstOccurrence = $first
                LastOccurrence = $last
                Count = $group.Count
                Error = ""
            }
        }

        return $summary
    } catch {
        try {
            $fallback = Get-EventLog -LogName System, Application -EntryType Error, Critical -After $startTime -ErrorAction Stop
            if (-not $fallback) {
                return @()
            }

            $grouped = $fallback | Group-Object -Property EventID, Source, Log
            $summary = foreach ($group in $grouped) {
                $first = ($group.Group | Sort-Object TimeGenerated | Select-Object -First 1).TimeGenerated
                $last = ($group.Group | Sort-Object TimeGenerated -Descending | Select-Object -First 1).TimeGenerated
                [PSCustomObject]@{
                    EventId = $group.Group[0].EventID
                    Source = $group.Group[0].Source
                    LogName = $group.Group[0].Log
                    FirstOccurrence = $first
                    LastOccurrence = $last
                    Count = $group.Count
                    Error = ""
                }
            }

            return $summary
        } catch {
            return @([PSCustomObject]@{
                EventId = ""
                Source = ""
                LogName = ""
                FirstOccurrence = ""
                LastOccurrence = ""
                Count = 0
                Error = "Event log query failed: $($_.Exception.Message)"
            })
        }
    }
}

function Evaluate-TestResult {
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

    if ($ExitCode -ne 0) {
        return @{ Status = "Fail"; Summary = "Non-zero exit code: $ExitCode" }
    }

    if ($lower -match "error|failed|corrupt|cannot|denied") {
        return @{ Status = "Fail"; Summary = "Detected error indicators" }
    }

    if ($Name -match "sfc" -and $lower -match "did not find any integrity violations") {
        return @{ Status = "Success"; Summary = "No integrity violations found" }
    }

    if ($Name -match "dism" -and $lower -match "no component store corruption") {
        return @{ Status = "Success"; Summary = "Component store healthy" }
    }

    if ($Name -match "dism" -and $lower -match "the operation completed successfully") {
        return @{ Status = "Success"; Summary = "DISM completed successfully" }
    }

    if ($Name -match "dism" -and $lower -match "elevation|required|access is denied") {
        return @{ Status = "Fail"; Summary = "DISM requires elevated rights" }
    }

    if ($Name -match "chkdsk" -and $lower -match "found no problems") {
        return @{ Status = "Success"; Summary = "No file system problems" }
    }

    return @{ Status = "Success"; Summary = "Completed without detected errors" }
}

function Add-TestStep {
    param([array]$Steps)

    $type = Read-Host "Add step type (pwsh/cmd)"
    if ([string]::IsNullOrWhiteSpace($type)) { return $Steps }
    $type = $type.ToLowerInvariant()

    if ($type -ne "pwsh" -and $type -ne "cmd") {
        Write-Warning "Invalid type"
        return $Steps
    }

    $command = Read-Host "Enter exact command"
    if ([string]::IsNullOrWhiteSpace($command)) { return $Steps }

    if ($type -eq "pwsh") {
        $testCommand = $command
        if ($testCommand -notmatch "\-WhatIf\b") {
            $testCommand = "$testCommand -WhatIf"
        }
        try {
            & ([scriptblock]::Create($testCommand)) | Out-Null
            Write-Host "WhatIf simulation executed. Review output above." -ForegroundColor Yellow
        } catch {
            Write-Warning "WhatIf simulation failed: $_"
        }
        $confirm = Read-Host "Add as TEST-step without -WhatIf? (Y/N)"
        if ($confirm -notin @("Y", "y")) { return $Steps }
    }

    if ($type -eq "cmd") {
        $testCommand = $command
        if ($testCommand -notmatch "/\?") {
            $testCommand = "$testCommand /?"
        }
        try {
            $null = & cmd.exe /c $testCommand 2>&1
            Write-Host "Command help check executed. Review output above." -ForegroundColor Yellow
        } catch {
            Write-Warning "Command help check failed: $_"
        }
        $confirm = Read-Host "If unsure, proceed at your own risk. Add TEST-step? (Y/N)"
        if ($confirm -notin @("Y", "y")) { return $Steps }
    }

    $newStep = [PSCustomObject]@{
        Name = "Custom Step"
        Type = $type
        Command = $command
        Description = "User-added step"
    }

    return $Steps + $newStep
}

function Get-SelectedSteps {
    param([array]$Steps)

    while ($true) {
        Write-Host "" 
        Write-Host "TEST-STEPS (all selected by default):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            $step = $Steps[$i]
            Write-Host ("  [{0}] {1}. {2}" -f "X", ($i + 1), $step.Name)
        }
        Write-Host "" 
        $input = Read-Host "Press Enter to run all, type 'add' to add, or list numbers (e.g. 1,3)"

        if ([string]::IsNullOrWhiteSpace($input)) {
            return $Steps
        }

        if ($input.Trim().ToLowerInvariant() -eq "add") {
            $Steps = Add-TestStep -Steps $Steps
            continue
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

function Export-TestReport {
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
    <title>Quick App TEST Report</title>
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
        <h1>Quick App - TEST Report</h1>
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
$testSteps = @(
    [PSCustomObject]@{ Name = "Compare WinVer with LAN/WAN"; Type = "Pwsh"; Command = "Compare-WinVer"; Description = "Compare local and LAN Windows versions" },
    [PSCustomObject]@{ Name = "SFC VerifyOnly"; Type = "Cmd"; Command = "sfc /verifyonly"; Description = "System file integrity check" },
    [PSCustomObject]@{ Name = "CHKDSK Scan"; Type = "Cmd"; Command = "chkdsk c: /scan"; Description = "Check disk for errors" },
    [PSCustomObject]@{ Name = "DISM CheckHealth"; Type = "Cmd"; Command = "dism /Online /Cleanup-Image /CheckHealth"; Description = "Component store health" },
    [PSCustomObject]@{ Name = "Event Logs Critical/Error"; Type = "Pwsh"; Command = "Get-CriticalEventSummary"; Description = "Summarize critical and error events" }
)

$selectedSteps = Get-SelectedSteps -Steps $testSteps

$results = @()
$stepNumber = 1
foreach ($step in $selectedSteps) {
    Write-Host "`n--- Running Step ${stepNumber}: $($step.Name) ---" -ForegroundColor Cyan
    $start = Get-Date
    $output = @()
    $exitCode = 0

    try {
        if ($step.Type -eq "Pwsh") {
            if ($step.Command -eq "Compare-WinVer") {
                $output = Compare-WinVer | Format-Table -AutoSize | Out-String
                $output = $output -split "`n"
            } elseif ($step.Command -eq "Get-CriticalEventSummary") {
                $eventData = Get-CriticalEventSummary
                if ($eventData.Count -eq 0) {
                    $output = @("No critical or error events found in last 7 days")
                } else {
                    $output = $eventData | Format-Table -AutoSize | Out-String
                    $output = $output -split "`n"
                }
            } else {
                $output = & ([scriptblock]::Create($step.Command)) 2>&1
            }
        } else {
            $output = @()
            if ($step.Name -match "DISM") {
                $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
                $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
                if (-not $isAdmin) {
                    $output = @("DISM requires elevated rights. Please run Quick App as Administrator.")
                    $exitCode = 5
                } else {
                    & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | ForEach-Object {
                        Write-Host $_
                        $output += $_
                    }
                    $exitCode = $LASTEXITCODE
                }
            } else {
                & cmd.exe /c $step.Command 2>&1 | ForEach-Object {
                    Write-Host $_
                    $output += $_
                }
                $exitCode = $LASTEXITCODE
            }
        }
    } catch {
        $output = @("Error: $_")
        $exitCode = 1
    }

    $elapsed = [Math]::Round(((Get-Date) - $start).TotalSeconds, 2)
    $evaluation = Evaluate-TestResult -Name $step.Name -Output $output -ExitCode $exitCode

    if ($step.Name -match "Event Logs" -and $output -match "No critical") {
        $evaluation = @{ Status = "Success"; Summary = "No critical or error events found" }
    }

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
$reportName = "$($env:COMPUTERNAME)_${timestamp}_Quick-APP-TEST.xhtml"
$reportPath = Join-Path $ReportFolder $reportName
Export-TestReport -Results $results -ReportPath $reportPath

Write-Host "`nReport saved to: $reportPath" -ForegroundColor Cyan
Start-Process $reportPath











<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





