# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Setup
<#
.SYNOPSIS
# --- Structured lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Started: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
    Registers / unregisters the PwShGUI Cron Processor as a Windows Scheduled Task.
.DESCRIPTION
    Creates a scheduled task "PwShGUI-CronProcessor" that runs every 10 minutes
    when the user is logged on. The task calls Invoke-CronProcessor.ps1.
.PARAMETER Unregister
    Removes the scheduled task if it exists.
.PARAMETER Status
    Shows current task status and last run time.
.EXAMPLE
    .\Register-CronTask.ps1              # Register the task
    .\Register-CronTask.ps1 -Status      # Check status
    .\Register-CronTask.ps1 -Unregister  # Remove the task
.NOTES
    VersionTag: 2605.B5.V46.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Unregister,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = 'PwShGUI-CronProcessor'
$ScriptRoot = Split-Path -Parent $PSScriptRoot   # c:\PowerShellGUI
$CronScript = Join-Path $ScriptRoot 'scripts\Invoke-CronProcessor.ps1'

# ── Status check ───────────────────────────────────────────
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
    return
}

# ── Unregister ─────────────────────────────────────────────
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

# ── Register ───────────────────────────────────────────────
if (-not (Test-Path $CronScript)) {
    Write-Error "Cron processor script not found at: $CronScript"
    return
}

# Detect pwsh vs powershell
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

$action  = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -NonInteractive -File `"$CronScript`"" -WorkingDirectory $ScriptRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 8)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'PwShGUI 10-minute maintenance cycle (feature check, deep test, bug discovery, smoke test, XHTML rebuild, reindex)' | Out-Null

Write-Host "Task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host "  Interval : Every 10 minutes"
Write-Host "  Engine   : $pwshExe"
Write-Host "  Script   : $CronScript"
Write-Host ""
Write-Host "Use -Status to check, -Unregister to remove." -ForegroundColor Cyan

# --- End lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Completed: $($MyInvocation.MyCommand.Name)" -Level 'Info'
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





