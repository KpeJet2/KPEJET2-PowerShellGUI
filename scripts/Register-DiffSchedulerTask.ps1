# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    Register / unregister / status the Windows Scheduled Task that runs
    Invoke-DiffScheduler.ps1 hourly.

.PARAMETER Action
    Register | Unregister | Status

.PARAMETER TaskName
    Default 'PwShGUI-DiffScheduler'

.PARAMETER WorkspacePath
    Workspace root.

.PARAMETER IntervalMinutes
    Trigger interval. Default 60.
#>
[CmdletBinding()]
param(
    [ValidateSet('Register','Unregister','Status','Run')]
    [string]$Action = 'Status',
    [string]$TaskName = 'PwShGUI-DiffScheduler',
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [int]$IntervalMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$diffScript = Join-Path $WorkspacePath 'scripts\Invoke-DiffScheduler.ps1'
if (-not (Test-Path -LiteralPath $diffScript)) {
    Write-Error "DiffScheduler script not found: $diffScript"
    exit 1
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) { Write-Error 'No PowerShell host found.'; exit 1 }

switch ($Action) {
    'Status' {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $existing) { Write-Host "Task $TaskName not registered." -ForegroundColor Yellow; exit 0 }
        $existing | Format-List TaskName,State,Author,Description
        Get-ScheduledTaskInfo -TaskName $TaskName | Format-List LastRunTime,LastTaskResult,NextRunTime,NumberOfMissedRuns
        exit 0
    }
    'Unregister' {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Unregistered: $TaskName" -ForegroundColor Green
        } else { Write-Host "Task $TaskName was not registered."  -ForegroundColor Yellow }
        exit 0
    }
    'Run' {
        if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
            Write-Error "Task $TaskName not registered."; exit 1
        }
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Triggered: $TaskName" -ForegroundColor Green
        exit 0
    }
    'Register' {
        $taskAction = New-ScheduledTaskAction -Execute $pwsh `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -WorkspacePath "{1}" -Once' -f $diffScript, $WorkspacePath)
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        # Interactive logon avoids needing admin elevation for current-user task registration.
        # If S4U is desired (run when not logged in), re-run elevated and edit logon type.
        $principal = New-ScheduledTaskPrincipal -UserId ("$env:USERDOMAIN\$env:USERNAME") -LogonType Interactive -RunLevel Limited
        $task = New-ScheduledTask -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal `
            -Description 'PwShGUI Diff Scheduler -- runs Invoke-DiffScheduler.ps1 hourly. See config/diff-scheduler.json.'
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Set-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
            Write-Host "Updated: $TaskName" -ForegroundColor Green
        } else {
            Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
            Write-Host "Registered: $TaskName (every $IntervalMinutes min)" -ForegroundColor Green
        }
        exit 0
    }
}

