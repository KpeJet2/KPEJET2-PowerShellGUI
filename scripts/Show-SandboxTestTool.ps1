# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive Sandbox Test Tool -- WinForms dashboard for iterative GUI testing
    in total system isolation using Windows Sandbox.

.DESCRIPTION
    Launched from Main-GUI Tools menu. Provides tabbed interface for:
      1. Dashboard       -- Session status, active sandbox info, quick actions
      2. Session Control -- Launch, monitor, terminate sandbox sessions
      3. Iteration Tools -- Sync, Test, GUI launch, custom commands
      4. Results Viewer  -- View test logs, screenshots, result files
      5. Settings        -- Sandbox config: memory, networking, vGPU, timeouts

    Backend: Uses Start-InteractiveSandbox.ps1, Send-SandboxCommand.ps1, and
             Invoke-SandboxBootstrap.ps1 (runs inside sandbox).

.PARAMETER WorkspacePath
    Root of the PwShGUI workspace. Auto-detected from Main-GUI launch context.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 04 Apr 2026
    Requires : Windows 10/11 Pro/Enterprise, Windows Sandbox feature enabled
#>

function Show-SandboxTestTool {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PSScriptRoot
    )

    # Resolve workspace if launched from scripts/
    if ($WorkspacePath -match '[/\\]scripts$') { $WorkspacePath = Split-Path $WorkspacePath }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ── Paths ──────────────────────────────────────────────────
    $testDir = Join-Path $WorkspacePath 'tests\sandbox'
    $startScript = Join-Path $testDir 'Start-InteractiveSandbox.ps1'
    $sendScript  = Join-Path $testDir 'Send-SandboxCommand.ps1'
    $tempDir     = Join-Path $WorkspacePath 'temp'

    # Pre-flight check
    if (-not (Test-Path $startScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Sandbox scripts not found at:`n$testDir`n`nInstall the Interactive Sandbox Test framework first.",
            "Missing Components",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    # ── Color palette ──────────────────────────────────────────
    $bgDark   = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $bgMed    = [System.Drawing.Color]::FromArgb(37, 37, 38)
    $bgLight  = [System.Drawing.Color]::FromArgb(51, 51, 51)
    $fgWhite  = [System.Drawing.Color]::WhiteSmoke
    $fgGray   = [System.Drawing.Color]::FromArgb(180,180,180)
    $accBlue  = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $accGreen = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $accOrange= [System.Drawing.Color]::FromArgb(206, 145, 64)
    $accRed   = [System.Drawing.Color]::FromArgb(244, 71, 71)
    $fontNorm = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontBold = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $fontHead = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fontMono = New-Object System.Drawing.Font("Cascadia Mono", 9)

    # ── Session state tracking ─────────────────────────────────
    $script:currentSession = $null
    $script:statusTimer = $null

    # ── Form ───────────────────────────────────────────────────
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Interactive Sandbox Test Tool'
    $form.Size = New-Object System.Drawing.Size(1000, 700)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $bgDark
    $form.ForeColor = $fgWhite
    $form.Font = $fontNorm

    # ── Tab control ────────────────────────────────────────────
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Font = $fontBold
    $tabs.ForeColor = $fgWhite
    $form.Controls.Add($tabs)

    # ── TAB 1: Dashboard ───────────────────────────────────────
    $tab1 = New-Object System.Windows.Forms.TabPage('Dashboard')
    $tab1.BackColor = $bgDark
    $tab1.ForeColor = $fgWhite
    $tabs.Controls.Add($tab1)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'Interactive Sandbox Test Dashboard'
    $lblTitle.Location = [System.Drawing.Point]::new(20, 20)
    $lblTitle.Size = [System.Drawing.Size]::new(700, 30)
    $lblTitle.Font = $fontHead
    $lblTitle.ForeColor = $accBlue
    $tab1.Controls.Add($lblTitle)

    $statusPanel = New-Object System.Windows.Forms.GroupBox
    $statusPanel.Text = 'Session Status'
    $statusPanel.Location = [System.Drawing.Point]::new(20, 60)
    $statusPanel.Size = [System.Drawing.Size]::new(940, 140)
    $statusPanel.ForeColor = $fgGray
    $tab1.Controls.Add($statusPanel)

    $lblSessionStatus = New-Object System.Windows.Forms.Label
    $lblSessionStatus.Text = 'No active sandbox session'
    $lblSessionStatus.Location = [System.Drawing.Point]::new(15, 25)
    $lblSessionStatus.Size = [System.Drawing.Size]::new(900, 50)
    $lblSessionStatus.Font = $fontNorm
    $lblSessionStatus.ForeColor = $fgWhite
    $statusPanel.Controls.Add($lblSessionStatus)

    $btnRefreshStatus = New-Object System.Windows.Forms.Button
    $btnRefreshStatus.Text = 'Refresh Status'
    $btnRefreshStatus.Location = [System.Drawing.Point]::new(15, 85)
    $btnRefreshStatus.Size = [System.Drawing.Size]::new(140, 35)
    $btnRefreshStatus.FlatStyle = 'Flat'
    $btnRefreshStatus.BackColor = $bgLight
    $btnRefreshStatus.ForeColor = $fgWhite
    $btnRefreshStatus.FlatAppearance.BorderColor = $accBlue
    $statusPanel.Controls.Add($btnRefreshStatus)

    $btnOpenOutputDir = New-Object System.Windows.Forms.Button
    $btnOpenOutputDir.Text = 'Open Output Folder'
    $btnOpenOutputDir.Location = [System.Drawing.Point]::new(165, 85)
    $btnOpenOutputDir.Size = [System.Drawing.Size]::new(150, 35)
    $btnOpenOutputDir.FlatStyle = 'Flat'
    $btnOpenOutputDir.BackColor = $bgLight
    $btnOpenOutputDir.ForeColor = $fgWhite
    $btnOpenOutputDir.FlatAppearance.BorderColor = $accGreen
    $btnOpenOutputDir.Enabled = $false
    $statusPanel.Controls.Add($btnOpenOutputDir)

    # Quick actions panel
    $actionsPanel = New-Object System.Windows.Forms.GroupBox
    $actionsPanel.Text = 'Quick Actions'
    $actionsPanel.Location = [System.Drawing.Point]::new(20, 210)
    $actionsPanel.Size = [System.Drawing.Size]::new(940, 200)
    $actionsPanel.ForeColor = $fgGray
    $tab1.Controls.Add($actionsPanel)

    $btnLaunch = New-Object System.Windows.Forms.Button
    $btnLaunch.Text = 'Launch Sandbox'
    $btnLaunch.Location = [System.Drawing.Point]::new(15, 30)
    $btnLaunch.Size = [System.Drawing.Size]::new(200, 50)
    $btnLaunch.FlatStyle = 'Flat'
    $btnLaunch.BackColor = $accGreen
    $btnLaunch.ForeColor = [System.Drawing.Color]::White
    $btnLaunch.FlatAppearance.BorderSize = 0
    $btnLaunch.Font = $fontBold
    $btnLaunch.Cursor = [System.Windows.Forms.Cursors]::Hand
    $actionsPanel.Controls.Add($btnLaunch)

    $btnIterate = New-Object System.Windows.Forms.Button
    $btnIterate.Text = 'Iterate (Sync+Test+GUI)'
    $btnIterate.Location = [System.Drawing.Point]::new(225, 30)
    $btnIterate.Size = [System.Drawing.Size]::new(200, 50)
    $btnIterate.FlatStyle = 'Flat'
    $btnIterate.BackColor = $accBlue
    $btnIterate.ForeColor = [System.Drawing.Color]::White
    $btnIterate.FlatAppearance.BorderSize = 0
    $btnIterate.Font = $fontBold
    $btnIterate.Enabled = $false
    $actionsPanel.Controls.Add($btnIterate)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = 'Sync Code'
    $btnSync.Location = [System.Drawing.Point]::new(15, 90)
    $btnSync.Size = [System.Drawing.Size]::new(130, 40)
    $btnSync.FlatStyle = 'Flat'
    $btnSync.BackColor = $bgLight
    $btnSync.ForeColor = $fgWhite
    $btnSync.FlatAppearance.BorderColor = $accOrange
    $btnSync.Enabled = $false
    $actionsPanel.Controls.Add($btnSync)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = 'Run Tests'
    $btnTest.Location = [System.Drawing.Point]::new(155, 90)
    $btnTest.Size = [System.Drawing.Size]::new(130, 40)
    $btnTest.FlatStyle = 'Flat'
    $btnTest.BackColor = $bgLight
    $btnTest.ForeColor = $fgWhite
    $btnTest.FlatAppearance.BorderColor = $accOrange
    $btnTest.Enabled = $false
    $actionsPanel.Controls.Add($btnTest)

    $btnGUI = New-Object System.Windows.Forms.Button
    $btnGUI.Text = 'Launch GUI'
    $btnGUI.Location = [System.Drawing.Point]::new(295, 90)
    $btnGUI.Size = [System.Drawing.Size]::new(130, 40)
    $btnGUI.FlatStyle = 'Flat'
    $btnGUI.BackColor = $bgLight
    $btnGUI.ForeColor = $fgWhite
    $btnGUI.FlatAppearance.BorderColor = $accGreen
    $btnGUI.Enabled = $false
    $actionsPanel.Controls.Add($btnGUI)

    $btnShutdown = New-Object System.Windows.Forms.Button
    $btnShutdown.Text = 'Shutdown Sandbox'
    $btnShutdown.Location = [System.Drawing.Point]::new(15, 140)
    $btnShutdown.Size = [System.Drawing.Size]::new(200, 40)
    $btnShutdown.FlatStyle = 'Flat'
    $btnShutdown.BackColor = $bgLight
    $btnShutdown.ForeColor = $accRed
    $btnShutdown.FlatAppearance.BorderColor = $accRed
    $btnShutdown.Enabled = $false
    $actionsPanel.Controls.Add($btnShutdown)

    # Recent results box
    $lblRecent = New-Object System.Windows.Forms.Label
    $lblRecent.Text = 'Recent Activity Log'
    $lblRecent.Location = [System.Drawing.Point]::new(20, 420)
    $lblRecent.Size = [System.Drawing.Size]::new(300, 20)
    $lblRecent.Font = $fontBold
    $lblRecent.ForeColor = $fgGray
    $tab1.Controls.Add($lblRecent)

    $txtRecentLog = New-Object System.Windows.Forms.RichTextBox
    $txtRecentLog.Location = [System.Drawing.Point]::new(20, 445)
    $txtRecentLog.Size = [System.Drawing.Size]::new(940, 150)
    $txtRecentLog.BackColor = $bgMed
    $txtRecentLog.ForeColor = $fgWhite
    $txtRecentLog.Font = $fontMono
    $txtRecentLog.ReadOnly = $true
    $tab1.Controls.Add($txtRecentLog)

    # ── Helper: Log to recent activity ────────────────────────
    function Write-ActivityLog {
        param([string]$Message, [string]$Color = 'White')
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $line = "[$timestamp] $Message`r`n"
        $txtRecentLog.SelectionStart = $txtRecentLog.TextLength
        $txtRecentLog.SelectionColor = [System.Drawing.Color]::$Color
        $txtRecentLog.AppendText($line)
        $txtRecentLog.SelectionColor = $txtRecentLog.ForeColor
        $txtRecentLog.ScrollToCaret()
    }

    # ── Helper: Update session status ─────────────────────────
    function Update-SessionStatus {
        if (-not $script:currentSession) {
            $lblSessionStatus.Text = "No active sandbox session`n`nClick 'Launch Sandbox' to start a new isolated testing environment."
            $lblSessionStatus.ForeColor = $fgGray
            $btnOpenOutputDir.Enabled = $false
            $btnIterate.Enabled = $false
            $btnSync.Enabled = $false
            $btnTest.Enabled = $false
            $btnGUI.Enabled = $false
            $btnShutdown.Enabled = $false
            return
        }

        $sessionDir = $script:currentSession.SessionDir
        $outputDir  = $script:currentSession.OutputDir
        $statusFile = Join-Path $outputDir 'sandbox-status.json'
        $statusText = "Session: $($script:currentSession.SessionName)`nDir: $sessionDir`n"

        if (Test-Path $statusFile) {
            try {
                $st = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $statusText += "Status: $($st.status)  |  Detail: $($st.detail)`nLast Update: $($st.timestamp)"
                $lblSessionStatus.ForeColor = switch ($st.status) {
                    'READY'       { $accGreen }
                    'RUNNING'     { $accBlue }
                    'ERROR'       { $accRed }
                    'SHUTDOWN'    { $fgGray }
                    'IDLE_TIMEOUT'{ $accOrange }
                    default       { $fgWhite }
                }
                if ($st.status -in @('READY', 'RUNNING')) {
                    $btnIterate.Enabled = $true
                    $btnSync.Enabled = $true
                    $btnTest.Enabled = $true
                    $btnGUI.Enabled = $true
                    $btnShutdown.Enabled = $true
                }
            } catch {
                $statusText += "Status file unreadable"
                $lblSessionStatus.ForeColor = $accOrange
            }
        } else {
            $statusText += "Status: Initializing..."
            $lblSessionStatus.ForeColor = $accOrange
        }

        $lblSessionStatus.Text = $statusText
        $btnOpenOutputDir.Enabled = (Test-Path $outputDir)
    }

    # ── Launch sandbox button ──────────────────────────────────
    $btnLaunch.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        Write-ActivityLog 'Launching new sandbox session...' 'Cyan'
        $btnLaunch.Enabled = $false
        $form.Refresh()

        try {
            $result = & $startScript -WorkspacePath $WorkspacePath -MaxIdleMinutes 120 -NoWait
            $script:currentSession = $result
            Write-ActivityLog "Sandbox launched: $($result.SessionName)" 'Green'
            Write-ActivityLog "Session dir: $($result.SessionDir)" 'Gray'
            Update-SessionStatus

            # Start status polling timer
            if ($script:statusTimer) { $script:statusTimer.Stop(); $script:statusTimer.Dispose() }
            $script:statusTimer = New-Object System.Windows.Forms.Timer
            $script:statusTimer.Interval = 5000  # 5 sec
            $script:statusTimer.Add_Tick({ Update-SessionStatus })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
            $script:statusTimer.Start()

        } catch {
            Write-ActivityLog "Launch failed: $($_.Exception.Message)" 'Red'
        } finally {
            $btnLaunch.Enabled = $true
        }
    })

    # ── Refresh status button ──────────────────────────────────
    $btnRefreshStatus.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        Write-ActivityLog 'Refreshing status...' 'Gray'
        Update-SessionStatus
    })

    # ── Open output folder button ──────────────────────────────
    $btnOpenOutputDir.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if ($script:currentSession -and (Test-Path $script:currentSession.OutputDir)) {
            Write-ActivityLog "Opening output: $($script:currentSession.OutputDir)" 'Gray'
            Invoke-Item $script:currentSession.OutputDir
        }
    })

    # ── Iterate button ─────────────────────────────────────────
    $btnIterate.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $script:currentSession) { return }
        Write-ActivityLog 'Sending Iterate command (Sync+Test+GUI)...' 'Cyan'
        $btnIterate.Enabled = $false
        $form.Refresh()

        try {
            & $sendScript -SessionDir $script:currentSession.SessionDir -Action Iterate -NoWait
            Write-ActivityLog 'Iterate command sent. Check sandbox window for GUI.' 'Green'
        } catch {
            Write-ActivityLog "Iterate failed: $($_.Exception.Message)" 'Red'
        } finally {
            $btnIterate.Enabled = $true
        }
    })

    # ── Sync, Test, GUI buttons ────────────────────────────────
    $btnSync.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $script:currentSession) { return }
        Write-ActivityLog 'Syncing code to sandbox...' 'Cyan'
        try {
            & $sendScript -SessionDir $script:currentSession.SessionDir -Action Sync -NoWait
            Write-ActivityLog 'Sync command sent' 'Green'
        } catch { Write-ActivityLog "Sync failed: $_" 'Red' }
    })

    $btnTest.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $script:currentSession) { return }
        Write-ActivityLog 'Running tests in sandbox...' 'Cyan'
        try {
            & $sendScript -SessionDir $script:currentSession.SessionDir -Action Test -Headless -NoWait
            Write-ActivityLog 'Test command sent' 'Green'
        } catch { Write-ActivityLog "Test failed: $_" 'Red' }
    })

    $btnGUI.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $script:currentSession) { return }
        Write-ActivityLog 'Launching GUI in sandbox...' 'Cyan'
        try {
            & $sendScript -SessionDir $script:currentSession.SessionDir -Action GUI -NoWait
            Write-ActivityLog 'GUI launch sent. Check sandbox window.' 'Green'
        } catch { Write-ActivityLog "GUI launch failed: $_" 'Red' }
    })

    # ── Shutdown button ────────────────────────────────────────
    $btnShutdown.Add_Click({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if (-not $script:currentSession) { return }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Shutdown the active sandbox session?`n`nAll sandbox state will be lost.",
            "Confirm Shutdown",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq 'Yes') {
            Write-ActivityLog 'Sending shutdown command...' 'Yellow'
            try {
                & $sendScript -SessionDir $script:currentSession.SessionDir -Action Shutdown -NoWait
                Write-ActivityLog 'Shutdown command sent. Session will terminate.' 'Yellow'
                Start-Sleep -Seconds 2
                $script:currentSession = $null
                if ($script:statusTimer) { $script:statusTimer.Stop() }
                Update-SessionStatus
            } catch { Write-ActivityLog "Shutdown failed: $_" 'Red' }
        }
    })

    # ── TAB 2: Results Viewer (placeholder) ───────────────────
    $tab2 = New-Object System.Windows.Forms.TabPage('Results Viewer')
    $tab2.BackColor = $bgDark
    $tab2.ForeColor = $fgWhite
    $tabs.Controls.Add($tab2)

    $lblResults = New-Object System.Windows.Forms.Label
    $lblResults.Text = 'Test results and logs from the sandbox will appear here.'
    $lblResults.Dock = 'Fill'
    $lblResults.TextAlign = 'MiddleCenter'
    $lblResults.ForeColor = $fgGray
    $tab2.Controls.Add($lblResults)

    # ── Form cleanup ───────────────────────────────────────────
    $form.Add_FormClosing({  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
        if ($script:statusTimer) { $script:statusTimer.Stop(); $script:statusTimer.Dispose() }
    })

    # ── Initial status ─────────────────────────────────────────
    Write-ActivityLog 'Interactive Sandbox Test Tool ready' 'Cyan'
    Write-ActivityLog "Workspace: $WorkspacePath" 'Gray'
    Write-ActivityLog "Scripts: $testDir" 'Gray'

    # Discover existing sessions in temp/
    $existingSessions = Get-ChildItem $tempDir -Directory -Filter 'sandbox-interactive-*' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($existingSessions) {
        $metaPath = Join-Path $existingSessions.FullName 'session-meta.json'
        if (Test-Path $metaPath) {
            try {
                $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:currentSession = [PSCustomObject]@{
                    SessionName = $meta.sessionName
                    SessionDir  = $meta.sessionDir
                    CommandDir  = $meta.commandDir
                    OutputDir   = $meta.outputDir
                }
                Write-ActivityLog "Found existing session: $($meta.sessionName)" 'Yellow'
                Update-SessionStatus

                # Start polling
                $script:statusTimer = New-Object System.Windows.Forms.Timer
                $script:statusTimer.Interval = 5000
                $script:statusTimer.Add_Tick({ Update-SessionStatus })  # SIN-EXEMPT:P029 -- handler pending try/catch wrap
                $script:statusTimer.Start()
            } catch {
                Write-ActivityLog "Could not load existing session metadata" 'Yellow'
            }
        }
    }

    # Show form
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# If dot-sourced from Main-GUI, export the function

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function Show-SandboxTestTool -ErrorAction SilentlyContinue





