# VersionTag: 2604.B1.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Setup
<#
.SYNOPSIS
    Registers / unregisters the PwShGUI 48-hour Cyclic Rename Check as a Windows Scheduled Task.
.DESCRIPTION
    Creates a scheduled task "PwShGUI-CyclicRenameCheck" that runs every 48 hours
    when the user is logged on. The task calls Invoke-CyclicRenameCheck.ps1.
.PARAMETER Unregister
    Removes the scheduled task if it exists.
.PARAMETER Status
    Shows current task status and last run time.
.EXAMPLE
    .\Register-CyclicRenameTask.ps1              # Register the task
    .\Register-CyclicRenameTask.ps1 -Status      # Check status
    .\Register-CyclicRenameTask.ps1 -Unregister  # Remove the task
.NOTES
    VersionTag: 2603.B0.v27.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Unregister,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = 'PwShGUI-CyclicRenameCheck'
$ScriptRoot = Split-Path -Parent $PSScriptRoot
$CyclicScript = Join-Path $ScriptRoot 'scripts\Invoke-CyclicRenameCheck.ps1'

# -- Status check --
if ($Status) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' is NOT registered." -ForegroundColor Yellow
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host "Task '$TaskName' status:" -ForegroundColor Cyan
    Write-Host "  State       : $($task.State)"
    Write-Host "  Last Run    : $($info.LastRunTime)"
    Write-Host "  Last Result : $($info.LastTaskResult)"
    Write-Host "  Next Run    : $($info.NextRunTime)"

    # Also show cyclic state
    $stateFile = Join-Path $ScriptRoot 'config\cyclic-tasks.json'
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.cyclicRenameCheck) {
            Write-Host "`n  Cyclic State:" -ForegroundColor Cyan
            Write-Host "    Last Run       : $($state.cyclicRenameCheck.lastRun)"
            Write-Host "    Interval Hours : $($state.cyclicRenameCheck.intervalHours)"
            if ($state.cyclicRenameCheck.lastResult) {
                Write-Host "    Proposals      : $($state.cyclicRenameCheck.lastResult.proposals)"
                Write-Host "    Todos Created  : $($state.cyclicRenameCheck.lastResult.todosCreated)"
            }
        }
    }
    return
}

# -- Unregister --
if ($Unregister) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' does not exist, nothing to remove." -ForegroundColor Yellow
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' unregistered successfully." -ForegroundColor Green
    return
}

# -- Register --
if (-not (Test-Path $CyclicScript)) {
    Write-Error "Cyclic rename check script not found at: $CyclicScript"
    return
}

$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    (Get-Command pwsh).Source
} else {
    (Get-Command powershell).Source
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Task '$TaskName' already exists (State: $($existing.State))." -ForegroundColor Yellow
    $confirm = Read-Host 'Re-register? (y/N)'
    if ($confirm -ne 'y') { return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action   = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -NonInteractive -File `"$CyclicScript`"" -WorkingDirectory $ScriptRoot
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 48) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'PwShGUI 48-hour cyclic rename-proposal scanner. Creates Items2Do for naming violations.' | Out-Null

Write-Host "Task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host "  Interval : Every 48 hours"
Write-Host "  Engine   : $pwshExe"
Write-Host "  Script   : $CyclicScript"
Write-Host ""
Write-Host "Use -Status to check, -Unregister to remove." -ForegroundColor Cyan

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




