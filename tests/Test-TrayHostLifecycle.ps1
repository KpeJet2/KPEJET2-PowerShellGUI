#Requires -Version 5.1
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag
<#
.SYNOPSIS
    Test the TrayHost open/minimize/reopen/exit lifecycle.
    Validates: module import, smiley icon creation, ApplicationContext init,
    keyboard monitor start/stop, background pool, and form lifecycle.
#>
param([switch]$Interactive)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:results = @()

function Test-Step {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:results += @{ Step = $Name; Status = 'PASS'; Detail = '' }
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $script:results += @{ Step = $Name; Status = 'FAIL'; Detail = $_.ToString() }
        Write-Host "  [FAIL] $Name -- $_" -ForegroundColor Red
    }
}

Write-Host "`n=== PwShGUI-TrayHost Module Smoke Test ===" -ForegroundColor Cyan
Write-Host "PowerShell: $($PSVersionTable.PSVersion)`n"

# ── Step 1: Import modules ──
Test-Step "Import PwShGUICore" {
    Import-Module (Join-Path (Join-Path $scriptDir 'modules') 'PwShGUICore.psm1') -Force
    Initialize-CorePaths -ScriptDir $scriptDir
}

Test-Step "Import PwShGUI-TrayHost" {
    Import-Module (Join-Path (Join-Path $scriptDir 'modules') 'PwShGUI-TrayHost.psm1') -Force
}

# ── Step 2: Verify exported functions ──
$expectedFunctions = @(
    'New-SmileyTrayIcon', 'Initialize-TrayAppContext', 'Start-TrayApplicationLoop',
    'Stop-TrayHost', 'Start-KeyboardMonitor', 'Stop-KeyboardMonitor',
    'Initialize-BackgroundPool', 'Invoke-BackgroundTask',
    'Get-CompletedBackgroundTasks', 'Stop-BackgroundPool',
    'Set-VerboseLifecycle', 'Get-TrayHostStatus'
)
Test-Step "All 12 functions exported" {
    foreach ($fn in $expectedFunctions) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Missing function: $fn"
        }
    }
}

# ── Step 3: Load WinForms assemblies ──
Test-Step "Load WinForms assemblies" {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
}

# ── Step 4: Create smiley tray icon ──
Test-Step "New-SmileyTrayIcon creates valid icon" {
    $icon = New-SmileyTrayIcon
    if ($icon -eq $null) { throw "Icon was null" }
    if ($icon -isnot [System.Drawing.Icon]) { throw "Not a System.Drawing.Icon" }
    Write-Host "    Icon size: $($icon.Width)x$($icon.Height)" -ForegroundColor Gray
}

# ── Step 5: Background pool ──
Test-Step "Initialize-BackgroundPool" {
    Initialize-BackgroundPool -MinThreads 1 -MaxThreads 2
}

Test-Step "Invoke-BackgroundTask and collect result" {
    $taskId = Invoke-BackgroundTask -ScriptBlock { Start-Sleep -Milliseconds 200; return "BG-OK-$(Get-Date -Format 'ss')" } -TaskName 'TestTask'
    if (-not $taskId) { throw "No task ID returned" }
    Start-Sleep -Milliseconds 500
    $completed = Get-CompletedBackgroundTasks
    if ($completed.Count -eq 0) { throw "No completed tasks found" }
    Write-Host "    Task $taskId result: $($completed[0].Result)" -ForegroundColor Gray  # SIN-EXEMPT: P027 - array guarded by if(.Count -gt 0) / if($proc) on prior line
}

Test-Step "Stop-BackgroundPool" {
    Stop-BackgroundPool
}

# ── Step 6: Get status ──
Test-Step "Get-TrayHostStatus returns valid hashtable" {
    $status = Get-TrayHostStatus
    if ($status -isnot [hashtable]) { throw "Not a hashtable" }
    Write-Host "    Keys: $($status.Keys -join ', ')" -ForegroundColor Gray
}

# ── Step 7: Interactive lifecycle test (optional) ──
if ($Interactive) {
    Write-Host "`n--- Interactive Lifecycle Test ---" -ForegroundColor Yellow
    Write-Host "  Creating test form with TrayHost lifecycle..." -ForegroundColor Gray

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "TrayHost Lifecycle Test"
    $form.Size = New-Object System.Drawing.Size(400, 200)
    $form.StartPosition = 'CenterScreen'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "MINIMIZE this window to test tray behavior.`nPress SPACEBAR in shell to restore.`nClose with X button after _ForceClose."
    $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $lbl.Size = New-Object System.Drawing.Size(350, 60)
    $form.Controls.Add($lbl)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = "Force Exit"
    $btnExit.Location = New-Object System.Drawing.Point(150, 120)
    $btnExit.Size = New-Object System.Drawing.Size(100, 30)
    $btnExit.Add_Click({ $script:_ForceClose = $true; $form.Close() })
    $form.Controls.Add($btnExit)

    # Tray icon
    $script:_ForceClose = $false
    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Text = "TrayHost Test"
    $trayIcon.Icon = New-SmileyTrayIcon
    $trayIcon.Visible = $true

    # Restore action
    $restoreAction = {
        $form.Show()
        $form.ShowInTaskbar = $true
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Activate()
        Write-Host "  [RESTORED] GUI rehydrated" -ForegroundColor Green
    }

    # Double-click tray => restore
    $trayIcon.Add_DoubleClick($restoreAction)

    # Minimize => hide
    $form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $form.Hide()
            $form.ShowInTaskbar = $false
            $trayIcon.ShowBalloonTip(1000, "TrayHost Test", "Press SPACEBAR or double-click icon", [System.Windows.Forms.ToolTipIcon]::Info)
            Write-Host "  [HIDDEN] Form hidden to tray" -ForegroundColor Yellow
        }
    })

    # FormClosing
    $form.Add_FormClosing({
        param($s, $e)
        if (-not $script:_ForceClose) {
            $e.Cancel = $true
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            return
        }
        $trayIcon.Visible = $false; $trayIcon.Dispose()
        Stop-TrayHost
    })

    # Init TrayHost
    $null = Initialize-TrayAppContext -Form $form -RestoreAction $restoreAction
    Start-KeyboardMonitor -IntervalMs 300

    Write-Host "  [RUNNING] Form shown. Test lifecycle now..." -ForegroundColor Cyan
    Start-TrayApplicationLoop

    Write-Host "  [EXITED] Application loop ended" -ForegroundColor Cyan
} else {
    Write-Host "`nSkipping interactive test (use -Interactive to run)" -ForegroundColor DarkGray
}

# Summary
$passCount = @($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($script:results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host "`n=== Results: $passCount PASS, $failCount FAIL ===" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
exit $failCount


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





