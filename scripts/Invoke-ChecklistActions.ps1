# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v24  2026-06-10  Initial: checklist action invoker with progress tracking
#Requires -Version 5.1
<#
.SYNOPSIS
    Automated checklist action invoker for PwShGUI Getting Started and Windows System Repairs.

.DESCRIPTION
    Executes selected checklist items from the PwShGUI-Checklists.xhtml tabs.
    Tracks progress with three metrics:
      - % to attempt  = queued items / total items
      - % completed   = succeeded items / attempted items
      - Tally: Pass / Fail counts in real-time
    Outputs a summary table: Item | Status | Duration | Detail

.PARAMETER Tab
    Which checklist tab to run: 'GettingStarted' or 'WindowsSystemRepairs'.

.PARAMETER Items
    Array of item IDs to run (e.g. 'gs01','gs05','gs10'). If omitted, runs all items for the tab.

.PARAMETER WhatIf
    Show what would be executed without actually running anything.

.PARAMETER ScriptRoot
    Override the workspace root path. Defaults to parent of this script's directory.

.NOTES
    Author   : The Establishment
    Requires : PowerShell 5.1+

.EXAMPLE
    .\scripts\Invoke-ChecklistActions.ps1 -Tab GettingStarted -WhatIf
    Shows all Getting Started actions without executing.

.EXAMPLE
    .\scripts\Invoke-ChecklistActions.ps1 -Tab WindowsSystemRepairs -Items sr01,sr04,sr08
    Runs only SFC verify, DISM ScanHealth, and chkdsk scan.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('GettingStarted','WindowsSystemRepairs')]
    [string]$Tab,

    [string[]]$Items,

    [string]$ScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

# ── Action Definitions ────────────────────────────────────────────────────────

function Get-GettingStartedActions {
    param([string]$Root)
    return @(
        # Security Setup
        @{ Id='gs01'; Group='Security'; Label='Install Bitwarden CLI'; Action={
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install --id Bitwarden.CLI --accept-package-agreements --accept-source-agreements 2>&1
            } else { throw 'winget not available' }
        }}
        @{ Id='gs02'; Group='Security'; Label='Bitwarden login'; Action={
            if (Get-Command bw -ErrorAction SilentlyContinue) {
                $status = bw status 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($status.status -eq 'unauthenticated') {
                    Write-Output 'Run "bw login" interactively -- cannot automate credentials'
                    return 'Manual step required'
                }
                return "Status: $($status.status)"
            } else { throw 'bw CLI not installed' }
        }}
        @{ Id='gs03'; Group='Security'; Label='Unlock vault'; Action={
            $sascModule = Join-Path $Root 'modules\AssistedSASC.psm1'
            if (Test-Path $sascModule) {
                Import-Module $sascModule -Force -DisableNameChecking -ErrorAction Stop
                if (Get-Command Unlock-Vault -ErrorAction SilentlyContinue) {
                    Unlock-Vault
                    return 'Vault unlock invoked'
                }
            }
            throw 'AssistedSASC module or Unlock-Vault not available'
        }}
        @{ Id='gs04'; Group='Security'; Label='Generate integrity manifest'; Action={
            $sascModule = Join-Path $Root 'modules\AssistedSASC.psm1'
            if (Test-Path $sascModule) {
                Import-Module $sascModule -Force -DisableNameChecking -ErrorAction Stop
                if (Get-Command New-IntegrityManifest -ErrorAction SilentlyContinue) {
                    New-IntegrityManifest
                    return 'Integrity manifest generated'
                }
            }
            throw 'New-IntegrityManifest not available'
        }}
        @{ Id='gs05'; Group='Security'; Label='Vault security audit'; Action={
            $sascModule = Join-Path $Root 'modules\AssistedSASC.psm1'
            if (Test-Path $sascModule) {
                Import-Module $sascModule -Force -DisableNameChecking -ErrorAction Stop
                if (Get-Command Invoke-VaultSecurityAudit -ErrorAction SilentlyContinue) {
                    $result = Invoke-VaultSecurityAudit
                    return "Audit complete: $result"
                }
            }
            throw 'Invoke-VaultSecurityAudit not available'
        }}

        # App Installs
        @{ Id='gs06'; Group='AppInstalls'; Label='Open App Template Manager'; Action={
            return 'GUI action -- open WinGets > App Template Manager from Main-GUI'
        }}
        @{ Id='gs07'; Group='AppInstalls'; Label='Load install template'; Action={
            $templateDir = Join-Path $Root 'config\APP-INSTALL-TEMPLATES'
            if (Test-Path $templateDir) {
                $templates = @(Get-ChildItem -Path $templateDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
                return "Found $($templates.Count) template(s): $($templates.Name -join ', ')"
            }
            return 'No APP-INSTALL-TEMPLATES directory found'
        }}
        @{ Id='gs08'; Group='AppInstalls'; Label='Run gap analysis'; Action={
            return 'GUI action -- run gap analysis from App Template Manager Pane 2'
        }}
        @{ Id='gs09'; Group='AppInstalls'; Label='Save baseline template'; Action={
            return 'GUI action -- save baseline from installed apps list'
        }}

        # Scans
        @{ Id='gs10'; Group='Scans'; Label='Run Environment Scanner'; Action={
            $scanner = Join-Path $Root 'scripts\Invoke-PSEnvironmentScanner.ps1'
            if (Test-Path $scanner) {
                & $scanner -AutoScan -ErrorAction Stop
                return 'Environment scan completed'
            }
            throw 'Invoke-PSEnvironmentScanner.ps1 not found'
        }}
        @{ Id='gs11'; Group='Scans'; Label='Run Dependency Matrix'; Action={
            $depMatrix = Join-Path $Root 'scripts\Invoke-ScriptDependencyMatrix.ps1'
            if (Test-Path $depMatrix) {
                & $depMatrix -ErrorAction Stop
                return 'Dependency matrix generated'
            }
            throw 'Invoke-ScriptDependencyMatrix.ps1 not found'
        }}
        @{ Id='gs12'; Group='Scans'; Label='Run Orphan Audit'; Action={
            return 'Orphan audit runs as part of smoke test Phase 0 (OrphanDetect)'
        }}
        @{ Id='gs13'; Group='Scans'; Label='Run Reference Integrity Check'; Action={
            return 'Reference integrity runs as part of smoke test Phase 0 (ScriptFnMap)'
        }}

        # Tests
        @{ Id='gs14'; Group='Tests'; Label='Run Version Check'; Action={
            return 'GUI action -- run Tests > Version Check from Main-GUI'
        }}
        @{ Id='gs15'; Group='Tests'; Label='Run App Testing'; Action={
            return 'GUI action -- run Tests > App Testing from Main-GUI'
        }}
        @{ Id='gs16'; Group='Tests'; Label='Run Safety Scrutiny'; Action={
            return 'GUI action -- run Tests > Safety Scrutiny from Main-GUI'
        }}
        @{ Id='gs17'; Group='Tests'; Label='Run Smoke Test'; Action={
            $smokeTest = Join-Path $Root 'tests\Invoke-GUISmokeTest.ps1'
            if (Test-Path $smokeTest) {
                & $smokeTest -HeadlessOnly -ErrorAction Stop
                return 'Smoke test (headless) completed'
            }
            throw 'Invoke-GUISmokeTest.ps1 not found'
        }}
    )
}

function Get-WindowsSystemRepairsActions {
    return @(
        # SFC
        @{ Id='sr01'; Group='SFC'; Label='sfc /verifyonly'; Elevated=$true; Action={
            $output = sfc /verifyonly 2>&1 | Out-String
            return $output.Trim()
        }}
        @{ Id='sr02'; Group='SFC'; Label='Review CBS.log'; Action={
            $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
            if (Test-Path $cbsLog) {
                $lines = @(Select-String -Path $cbsLog -Pattern '\[SR\]' -ErrorAction SilentlyContinue | Select-Object -Last 20)
                return "Found $($lines.Count) [SR] entries (last 20 shown)"
            }
            return 'CBS.log not found'
        }}
        @{ Id='sr03'; Group='SFC'; Label='sfc /scannow'; Elevated=$true; Action={
            $output = sfc /scannow 2>&1 | Out-String
            return $output.Trim()
        }}

        # DISM
        @{ Id='sr04'; Group='DISM'; Label='DISM ScanHealth'; Elevated=$true; Action={
            $output = DISM /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String
            return $output.Trim()
        }}
        @{ Id='sr05'; Group='DISM'; Label='DISM CheckHealth'; Elevated=$true; Action={
            $output = DISM /Online /Cleanup-Image /CheckHealth 2>&1 | Out-String
            return $output.Trim()
        }}
        @{ Id='sr06'; Group='DISM'; Label='DISM RestoreHealth'; Elevated=$true; Action={
            $output = DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
            return $output.Trim()
        }}
        @{ Id='sr07'; Group='DISM'; Label='Re-run sfc after DISM'; Elevated=$true; Action={
            $output = sfc /scannow 2>&1 | Out-String
            return $output.Trim()
        }}

        # Disk
        @{ Id='sr08'; Group='Disk'; Label='chkdsk C: /scan'; Elevated=$true; Action={
            $output = chkdsk C: /scan 2>&1 | Out-String
            return $output.Trim()
        }}
        @{ Id='sr09'; Group='Disk'; Label='SMART disk health'; Action={
            $disks = Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, HealthStatus, Size
            return ($disks | Format-Table -AutoSize | Out-String).Trim()
        }}
        @{ Id='sr10'; Group='Disk'; Label='Volume free space'; Action={
            $vols = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystemLabel, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}}, HealthStatus
            return ($vols | Format-Table -AutoSize | Out-String).Trim()
        }}
        @{ Id='sr11'; Group='Disk'; Label='Disk Cleanup'; Elevated=$true; Action={
            Start-Process cleanmgr -ArgumentList '/d','C:' -Wait -ErrorAction Stop
            return 'Disk Cleanup launched for C:'
        }}

        # Event Logs
        @{ Id='sr12'; Group='EventLogs'; Label='System critical/error events (24h)'; Action={
            $events = @(Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddDays(-1)} -MaxEvents 20 -ErrorAction SilentlyContinue)
            if ($events.Count -eq 0) { return 'No critical/error system events in last 24h' }
            return ($events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -AutoSize -Wrap | Out-String).Trim()
        }}
        @{ Id='sr13'; Group='EventLogs'; Label='Application errors (24h)'; Action={
            $events = @(Get-WinEvent -FilterHashtable @{LogName='Application';Level=1,2;StartTime=(Get-Date).AddDays(-1)} -MaxEvents 20 -ErrorAction SilentlyContinue)
            if ($events.Count -eq 0) { return 'No critical/error application events in last 24h' }
            return ($events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -AutoSize -Wrap | Out-String).Trim()
        }}
        @{ Id='sr14'; Group='EventLogs'; Label='Unexpected reboots'; Action={
            $events = @(Get-WinEvent -FilterHashtable @{LogName='System';Id=6008} -MaxEvents 5 -ErrorAction SilentlyContinue)
            if ($events.Count -eq 0) { return 'No unexpected shutdown events found' }
            return ($events | Select-Object TimeCreated, Message | Format-Table -AutoSize -Wrap | Out-String).Trim()
        }}
        @{ Id='sr15'; Group='EventLogs'; Label='Windows Update status'; Action={
            $wuService = Get-Service wuauserv -ErrorAction SilentlyContinue
            $status = if ($wuService) { $wuService.Status } else { 'Not found' }
            return "Windows Update service: $status"
        }}

        # Security
        @{ Id='sr16'; Group='Security'; Label='Windows Defender status'; Action={
            $mp = Get-MpComputerStatus -ErrorAction Stop
            return "AV Enabled: $($mp.AntivirusEnabled), RealTime: $($mp.RealTimeProtectionEnabled), Sigs: $($mp.AntivirusSignatureLastUpdated)"
        }}
        @{ Id='sr17'; Group='Security'; Label='Firewall profiles'; Action={
            $fw = Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled
            return ($fw | Format-Table -AutoSize | Out-String).Trim()
        }}
        @{ Id='sr18'; Group='Security'; Label='BitLocker status'; Action={
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            return "C: Protection: $($bl.ProtectionStatus), Encryption: $($bl.VolumeStatus)"
        }}
    )
}

# ── Execution Engine ──────────────────────────────────────────────────────────

function Invoke-ChecklistItem {
    param(
        [hashtable]$Item,
        [switch]$WhatIfMode
    )

    $result = [pscustomobject]@{
        Id       = $Item.Id
        Group    = $Item.Group
        Label    = $Item.Label
        Status   = 'Queued'
        Duration = ''
        Detail   = ''
    }

    if ($WhatIfMode) {
        $result.Status = 'WhatIf'
        $elevated = if ($Item.ContainsKey('Elevated') -and $Item.Elevated) { ' [ELEVATED]' } else { '' }
        $result.Detail = "Would execute: $($Item.Label)$elevated"
        return $result
    }

    # Check elevation requirement
    if ($Item.ContainsKey('Elevated') -and $Item.Elevated) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            $result.Status = 'Skip'
            $result.Detail = 'Requires elevation (run as Administrator)'
            return $result
        }
    }

    $result.Status = 'Running'
    $itemSw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $output = & $Item.Action
        $itemSw.Stop()
        $result.Status   = 'Pass'
        $result.Duration = '{0:N1}s' -f $itemSw.Elapsed.TotalSeconds
        $result.Detail   = if ($output) { "$output".Substring(0, [math]::Min("$output".Length, 200)) } else { 'OK' }
    } catch {
        $itemSw.Stop()
        $result.Status   = 'Fail'
        $result.Duration = '{0:N1}s' -f $itemSw.Elapsed.TotalSeconds
        $result.Detail   = "$_".Substring(0, [math]::Min("$_".Length, 200))
    }

    return $result
}

# ── Main ──────────────────────────────────────────────────────────────────────

$allActions = if ($Tab -eq 'GettingStarted') {
    Get-GettingStartedActions -Root $ScriptRoot
} else {
    Get-WindowsSystemRepairsActions
}

# Filter to selected items
if ($Items -and $Items.Count -gt 0) {
    $allActions = @($allActions | Where-Object { $_.Id -in $Items })
}

$totalItems   = $allActions.Count
$queuedCount  = $allActions.Count
$attemptPct   = if ($totalItems -gt 0) { [math]::Round(($queuedCount / $totalItems) * 100, 1) } else { 0 }

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "  CHECKLIST ACTION INVOKER -- $Tab" -ForegroundColor Yellow
Write-Host "  Items: $queuedCount / $totalItems ($attemptPct% to attempt)" -ForegroundColor DarkGray
Write-Host "$('=' * 60)`n" -ForegroundColor Cyan

$isWhatIf = $PSCmdlet.ShouldProcess('Checklist items', 'Execute') -eq $false
if ($WhatIfPreference) { $isWhatIf = $true }

$resultsList = [System.Collections.Generic.List[pscustomobject]]::new()
$passCount   = 0
$failCount   = 0
$skipCount   = 0
$idx         = 0

foreach ($action in $allActions) {
    $idx++
    $pctComplete = if ($totalItems -gt 0) { [math]::Round(($idx / $totalItems) * 100, 0) } else { 0 }
    Write-Progress -Activity "Running $Tab checklist" -Status "$($action.Label) ($idx/$totalItems)" -PercentComplete $pctComplete

    $colours = @{ Pass='Green'; Fail='Red'; Skip='DarkYellow'; WhatIf='Gray'; Running='Cyan' }
    $itemResult = Invoke-ChecklistItem -Item $action -WhatIfMode:$isWhatIf
    $resultsList.Add($itemResult)

    switch ($itemResult.Status) {
        'Pass'   { $passCount++ }
        'Fail'   { $failCount++ }
        'Skip'   { $skipCount++ }
    }

    $statusColor = $colours[$itemResult.Status]
    if (-not $statusColor) { $statusColor = 'Gray' }
    $line = "[{0,-6}] {1,-4} {2,-40} {3}" -f $itemResult.Status, $itemResult.Id, $itemResult.Label, $itemResult.Detail
    Write-Host $line -ForegroundColor $statusColor
}

Write-Progress -Activity "Running $Tab checklist" -Completed

# ── Summary ───────────────────────────────────────────────────────────────────
$attempted    = $passCount + $failCount
$completedPct = if ($attempted -gt 0) { [math]::Round(($passCount / $attempted) * 100, 1) } else { 0 }

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "  SUMMARY -- $Tab" -ForegroundColor Yellow
Write-Host "  % to attempt : $attemptPct% ($queuedCount of $totalItems items queued)" -ForegroundColor DarkGray
Write-Host "  % completed  : $completedPct% ($passCount of $attempted attempted)" -ForegroundColor $(if ($completedPct -ge 80) { 'Green' } else { 'Yellow' })
Write-Host "  Pass: $passCount  Fail: $failCount  Skip: $skipCount" -ForegroundColor DarkCyan
Write-Host "$('=' * 60)" -ForegroundColor Cyan

$resultsList | Format-Table -AutoSize Id, Group, Label, Status, Duration, Detail


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




