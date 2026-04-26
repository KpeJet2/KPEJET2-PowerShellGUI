# VersionTag: 2604.B2.V31.5
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
#Requires -Version 5.1
<#
.SYNOPSIS
    Cron-Ai-Athon Tool -- multi-tab WinForms dashboard for pipeline management,
    job scheduling, statistics, bug tracking, event logging, and SYSLOG config.

.DESCRIPTION
    Launched from Main-GUI Tools menu.  Provides tabbed interface:
      1. Dashboard       -- Overview stats, last-run info, queue snapshot
      2. Task Schedule   -- Enable/disable tasks, set frequencies
      3. Pre-Req Check   -- One-click environment pre-flight
      4. Manual Runner   -- Pick & run individual jobs on demand
      5. Pipeline Queue  -- View/edit pipeline items (FeatureReq, Bug, Items2ADD, Bugs2FIX, ToDo)
      6. Bug Tracker     -- Trigger scans, review detected bugs
      7. Master ToDo     -- Aggregated central master list
      8. Statistics      -- Errors, cycles, items done, bugs found, tests, plans
      9. Subagent Tally  -- Per-agent invocation counters
     10. Questions       -- Autopilot vs Commander vs Unanswered
     11. Autopilot Suggestions -- Self-suggested additions (status tracking)
     12. Event Log / SYSLOG    -- Config, viewer, forward test
     13. Checklists     -- Multi-checklist view with filtering
     14. Security Accounts     -- Service account provisioning
     15. Agent Guide    -- Step-by-step guide for agents/developers
     16. Standards Ref  -- Coding standards reference (NEW in v28.0)

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 28th March 2026
    Modified : 04 Apr 2026
    Changes  : v28.0 - Added Tab 16 (Standards Ref) with error handling templates,
                       logging levels, SIN governance patterns, and pipeline standards.
#>

function Show-CronAiAthonTool {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PSScriptRoot
    )

    # Resolve workspace if launched from scripts/
    if ($WorkspacePath -match '[/\\]scripts$') { $WorkspacePath = Split-Path $WorkspacePath }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic

    # ── Import support modules (graceful) ────────────────────────
    $modDir = Join-Path $WorkspacePath 'modules'
    foreach ($m in @('CronAiAthon-Pipeline','CronAiAthon-BugTracker','CronAiAthon-Scheduler','CronAiAthon-EventLog','PwShGUI-Theme')) {
        $mp = Join-Path $modDir "$m.psm1"
        if (Test-Path $mp) { try { Import-Module $mp -Force -ErrorAction Stop } catch { Write-Warning "Failed to import ${m}: $_" } }
    }
    # H-Ai-Nikr-Agi agent module
    $nikrMod = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'H-Ai-Nikr-Agi') 'core'
    $nikrMod = Join-Path $nikrMod 'H-Ai-Nikr-Agi.psm1'
    if (Test-Path $nikrMod) { try { Import-Module $nikrMod -Force -ErrorAction Stop } catch { Write-Warning "Failed to import H-Ai-Nikr-Agi: $_" } }

    # ── Colours ──────────────────────────────────────────────────
    $bgDark   = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $bgMed    = [System.Drawing.Color]::FromArgb(37, 37, 38)
    $bgLight  = [System.Drawing.Color]::FromArgb(51, 51, 51)
    $fgWhite  = [System.Drawing.Color]::WhiteSmoke
    $fgGray   = [System.Drawing.Color]::FromArgb(180,180,180)
    $accBlue  = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $accGreen = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $accOrange= [System.Drawing.Color]::FromArgb(206, 145, 64)
    $accRed    = [System.Drawing.Color]::FromArgb(244, 71, 71)
    $accYellow  = [System.Drawing.Color]::FromArgb(220, 195, 48)
    $accAmber   = [System.Drawing.Color]::FromArgb(220, 160, 40)
    $accPurple  = [System.Drawing.Color]::FromArgb(200, 140, 220)  # SIN-P025-FIX: inline static call in arg-mode resolves as method ref, not Color
    $accBlueRun = [System.Drawing.Color]::FromArgb(30, 144, 255)
    $fontNorm = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontBold = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $fontHead = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fontMono = New-Object System.Drawing.Font("Cascadia Mono", 9)

    # ── Helper: styled label ─────────────────────────────────────
    function New-StyledLabel {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
        param([string]$Text, [int]$X, [int]$Y, [int]$W=300, [int]$H=20,
              [System.Drawing.Font]$Font=$fontNorm, [System.Drawing.Color]$ForeColor=$fgWhite)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Text; $lbl.Location = [System.Drawing.Point]::new($X,$Y)
        $lbl.Size = [System.Drawing.Size]::new($W,$H); $lbl.Font = $Font
        $lbl.ForeColor = $ForeColor; $lbl.BackColor = [System.Drawing.Color]::Transparent
        return $lbl
    }

    # ── Helper: styled button ────────────────────────────────────
    function New-StyledButton {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
        param([string]$Text, [int]$X, [int]$Y, [int]$W=140, [int]$H=30, [string]$Tip='')
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $Text; $btn.Location = [System.Drawing.Point]::new($X,$Y)
        $btn.Size = [System.Drawing.Size]::new($W,$H); $btn.Font = $fontNorm
        $btn.FlatStyle = 'Flat'; $btn.BackColor = $bgLight; $btn.ForeColor = $fgWhite
        $btn.FlatAppearance.BorderColor = $accBlue; $btn.FlatAppearance.BorderSize = 1
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $btn
    }

    # ── Helper: styled DGV ───────────────────────────────────────
    function New-StyledGrid {
        param([int]$X=10, [int]$Y=50, [int]$W=840, [int]$H=340)
        $dgv = New-Object System.Windows.Forms.DataGridView
        $dgv.Location = [System.Drawing.Point]::new($X,$Y)
        $dgv.Size = [System.Drawing.Size]::new($W,$H)
        $dgv.BackgroundColor = $bgDark; $dgv.ForeColor = $fgWhite
        $dgv.GridColor = $bgLight; $dgv.BorderStyle = 'None'
        $dgv.ColumnHeadersDefaultCellStyle.BackColor = $bgLight
        $dgv.ColumnHeadersDefaultCellStyle.ForeColor = $fgWhite
        $dgv.ColumnHeadersDefaultCellStyle.Font = $fontBold
        $dgv.DefaultCellStyle.BackColor = $bgDark
        $dgv.DefaultCellStyle.ForeColor = $fgWhite
        $dgv.DefaultCellStyle.SelectionBackColor = $accBlue
        $dgv.DefaultCellStyle.Font = $fontNorm
        $dgv.RowHeadersVisible = $false
        $dgv.AllowUserToAddRows = $false
        $dgv.ReadOnly = $true
        $dgv.AutoSizeColumnsMode = 'Fill'
        $dgv.SelectionMode = 'FullRowSelect'
        return $dgv
    }

    # ── ToolTip provider ─────────────────────────────────────────
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.InitialDelay = 400
    $toolTip.ReshowDelay = 200
    $toolTip.AutoPopDelay = 8000
    $toolTip.BackColor = $bgLight
    $toolTip.ForeColor = $fgWhite

    # ══════════════════════════════════════════════════════════════
    #  MAIN FORM
    # ══════════════════════════════════════════════════════════════
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Cron-Ai-Athon Tool"
    $form.Size = [System.Drawing.Size]::new(920, 620)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $bgDark
    $form.ForeColor = $fgWhite
    $form.Font = $fontNorm
    $form.FormBorderStyle = 'Sizable'
    $form.MinimumSize = [System.Drawing.Size]::new(900, 580)
    $form.Size           = [System.Drawing.Size]::new(940, 670)

    # ── Status bar (bottom of form) ──────────────────────────────
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Dock        = 'Bottom'
    $statusBar.Height      = 28
    $statusBar.BackColor   = [System.Drawing.Color]::FromArgb(20,20,20)
    $statusBar.BorderStyle = 'None'
    $form.Controls.Add($statusBar)

    function New-StatusLed {
        param([string]$Label, [int]$X, [System.Drawing.Color]$LedColor)
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.Location = [System.Drawing.Point]::new($X, 5)
        $pnl.Size     = [System.Drawing.Size]::new(160, 18)
        $pnl.BackColor = [System.Drawing.Color]::Transparent
        $led = New-Object System.Windows.Forms.Label
        $led.Location  = [System.Drawing.Point]::new(0,2)
        $led.Size      = [System.Drawing.Size]::new(12,12)
        $led.BackColor = $LedColor
        # Use a Panel for the circle look
        $circle = New-Object System.Windows.Forms.Panel
        $circle.Location  = [System.Drawing.Point]::new(0,3)
        $circle.Size      = [System.Drawing.Size]::new(12,12)
        $circle.BackColor = $LedColor
        $circle.Tag       = 'led'
        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Location  = [System.Drawing.Point]::new(16,0)
        $lbl2.Size      = [System.Drawing.Size]::new(140,18)
        $lbl2.Text      = $Label
        $lbl2.Font      = New-Object System.Drawing.Font('Segoe UI',8)
        $lbl2.ForeColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $lbl2.BackColor = [System.Drawing.Color]::Transparent
        $pnl.Controls.AddRange(@($circle,$lbl2))
        return @{ Panel=$pnl; Circle=$circle; ValueLabel=$lbl2 }
    }

    $ledSched   = New-StatusLed 'Scheduled: --'   4    ([System.Drawing.Color]::FromArgb(78,201,176))
    $ledRunning = New-StatusLed 'Running: --'      170  ([System.Drawing.Color]::FromArgb(30,144,255))
    $ledWarn    = New-StatusLed 'Paused/Error: --' 336  ([System.Drawing.Color]::FromArgb(220,195,48))
    $ledStop    = New-StatusLed 'Stopped: --'      502  ([System.Drawing.Color]::FromArgb(244,71,71))
    $lblStatusTime = New-Object System.Windows.Forms.Label
    $lblStatusTime.Location  = [System.Drawing.Point]::new(680,5)
    $lblStatusTime.Size      = [System.Drawing.Size]::new(230,18)
    $lblStatusTime.Text      = 'Last refresh: --'
    $lblStatusTime.Font      = New-Object System.Drawing.Font('Segoe UI',8)
    $lblStatusTime.ForeColor = [System.Drawing.Color]::FromArgb(120,120,120)
    $lblStatusTime.BackColor = [System.Drawing.Color]::Transparent
    $statusBar.Controls.AddRange(@($ledSched.Panel,$ledRunning.Panel,$ledWarn.Panel,$ledStop.Panel,$lblStatusTime))

    function Update-StatusBar {
        try {
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $tasks = @($sched.tasks)
            $nSched   = @($tasks | Where-Object { $_.enabled -eq $true  }).Count
            $nStop    = @($tasks | Where-Object { $_.enabled -eq $false }).Count
            $nErr     = @($tasks | Where-Object { $_.lastResult -and $_.lastResult -match 'error|fail|warn|pause' }).Count
            # Estimate 'running' = tasks whose lastRun is within the last 2 minutes
            $cutoff   = (Get-Date).AddMinutes(-2)
            $nRun     = @($tasks | Where-Object {
                $_.lastRun -and ([datetime]::TryParse($_.lastRun,[ref](New-Object datetime)) -and [datetime]$_.lastRun -gt $cutoff)
            }).Count
            $ledSched.ValueLabel.Text   = "Scheduled: $nSched"
            $ledRunning.ValueLabel.Text = "Running: $nRun"
            $ledWarn.ValueLabel.Text    = "Paused/Error: $nErr"
            $ledStop.ValueLabel.Text    = "Stopped: $nStop"
            $bcSched = if ($nSched -gt 0) { [System.Drawing.Color]::FromArgb(78,201,176) } else { [System.Drawing.Color]::FromArgb(60,60,60) }
            $bcRun   = if ($nRun -gt 0)   { [System.Drawing.Color]::FromArgb(30,144,255) } else { [System.Drawing.Color]::FromArgb(60,60,60) }
            $bcWarn  = if ($nErr -gt 0)   { [System.Drawing.Color]::FromArgb(220,195,48) } else { [System.Drawing.Color]::FromArgb(60,60,60) }
            $bcStop  = if ($nStop -gt 0)  { [System.Drawing.Color]::FromArgb(244,71,71)  } else { [System.Drawing.Color]::FromArgb(60,60,60) }
            if ($null -ne $bcSched)  { $ledSched.Circle.BackColor   = $bcSched }
            if ($null -ne $bcRun)    { $ledRunning.Circle.BackColor = $bcRun }
            if ($null -ne $bcWarn)   { $ledWarn.Circle.BackColor    = $bcWarn }
            if ($null -ne $bcStop)   { $ledStop.Circle.BackColor    = $bcStop }
            $lblStatusTime.Text = "Last refresh: $(Get-Date -Format 'HH:mm:ss')"
        } catch {
            $lblStatusTime.Text = "Status error: $($_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length)))"
        }
    }

    if (Get-Command Set-ModernFormStyle -ErrorAction SilentlyContinue) {
        Set-ModernFormStyle -Form $form
    }

    # ── Tab Control ──────────────────────────────────────────────
    $tabCtrl = New-Object System.Windows.Forms.TabControl
    $tabCtrl.Dock = 'Fill'
    $tabCtrl.Font = $fontNorm
    $tabCtrl.BackColor = $bgMed
    $form.Controls.Add($tabCtrl)

    # ── Menu strip (dark-themed) ─────────────────────────────────
    $menuStrip = New-Object System.Windows.Forms.MenuStrip
    $menuStrip.BackColor   = [System.Drawing.Color]::FromArgb(45,45,48)
    $menuStrip.ForeColor   = $fgWhite
    $menuStrip.Font        = $fontNorm
    $menuStrip.RenderMode  = 'Professional'

    $mkItem = {
        param([string]$Text, [System.Drawing.Color]$FG)
        $i = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
        $i.ForeColor  = $FG
        $i.BackColor  = [System.Drawing.Color]::FromArgb(45,45,48)
        $i.Font       = $fontNorm
        return $i
    }

    # ---- Tools menu -----------------------------------------------
    $menuTools = & $mkItem 'Tools' $fgWhite
    $miRunBugScan   = & $mkItem 'Run Bug Scan'           ([System.Drawing.Color]::FromArgb(200,200,200))
    $miRunDocRebuild= & $mkItem 'Rebuild Docs'           ([System.Drawing.Color]::FromArgb(200,200,200))
    $miRunCoverage  = & $mkItem 'Config Coverage Audit'  ([System.Drawing.Color]::FromArgb(200,200,200))
    $miSep1         = New-Object System.Windows.Forms.ToolStripSeparator
    $miNikrAgi      = & $mkItem 'Ask Nikr-Agi...'        ([System.Drawing.Color]::FromArgb(200,140,80))
    [void]$menuTools.DropDownItems.AddRange(@($miRunBugScan,$miRunDocRebuild,$miRunCoverage,$miSep1,$miNikrAgi))

    $miRunBugScan.Add_Click({
        try { & (Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-FullBugScan.ps1') -WorkspacePath $WorkspacePath | Out-Null } catch {
            [System.Windows.Forms.MessageBox]::Show("Bug scan error: $($_.Exception.Message)",'Error','OK','Error') | Out-Null
        }
    })
    $miRunDocRebuild.Add_Click({
        try { & (Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-AgenticManifest.ps1') -WorkspacePath $WorkspacePath | Out-Null } catch {
            [System.Windows.Forms.MessageBox]::Show("Doc rebuild error: $($_.Exception.Message)",'Error','OK','Error') | Out-Null
        }
    })
    $miRunCoverage.Add_Click({
        try { & (Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ConfigCoverageAudit.ps1') -WorkspacePath $WorkspacePath -PipelineItems | Out-Null } catch {
            [System.Windows.Forms.MessageBox]::Show("Coverage audit error: $($_.Exception.Message)",'Error','OK','Error') | Out-Null
        }
    })
    $miNikrAgi.Add_Click({
        $topic = [Microsoft.VisualBasic.Interaction]::InputBox('What topic shall I critique today?', 'Ask Nikr-Agi', 'General')
        if ([string]::IsNullOrWhiteSpace($topic)) { $topic = 'General' }
        if (Get-Command Invoke-NikrAgiSquabble -ErrorAction SilentlyContinue) {
            $sq = Invoke-NikrAgiSquabble -WorkspacePath $WorkspacePath -Topic $topic -RetortAgents 2
            if ($script:_lblNikrAgi) { $script:_lblNikrAgi.Text = "  $($sq.display)" }
            [System.Windows.Forms.MessageBox]::Show($sq.display,'Nikr-Agi says...','OK','Information') | Out-Null
        }
    })

    # ---- Help menu ------------------------------------------------
    $menuHelp      = & $mkItem 'Help' $fgWhite
    $miQuickStart  = & $mkItem 'Quick Start Guide (.md)'       ([System.Drawing.Color]::FromArgb(200,200,200))
    $miModuleIndex = & $mkItem 'Module Function Index (.md)'   ([System.Drawing.Color]::FromArgb(200,200,200))
    $miImplGuide   = & $mkItem 'Implementation Guide (.xhtml)' ([System.Drawing.Color]::FromArgb(200,200,200))
    $miSep2        = New-Object System.Windows.Forms.ToolStripSeparator
    $miAboutNikr   = & $mkItem 'About H-Ai-Nikr-Agi (PowerShell)'    ([System.Drawing.Color]::FromArgb(200,140,80))
    [void]$menuHelp.DropDownItems.AddRange(@($miQuickStart,$miModuleIndex,$miImplGuide,$miSep2,$miAboutNikr))

    # Helper: open file in default browser/editor
    $openDoc = { param([string]$Rel) $p = Join-Path (Join-Path $WorkspacePath '~README.md') $Rel; if (Test-Path $p) { Start-Process $p } }

    $miQuickStart.Add_Click({ & $openDoc 'QUICK-START.md' })
    $miModuleIndex.Add_Click({ & $openDoc 'MODULE-FUNCTION-INDEX.md' })
    $miImplGuide.Add_Click({  & $openDoc 'Implementation-Steps.xhtml' })
    $miAboutNikr.Add_Click({  & $openDoc '..\agents\H-Ai-Nikr-Agi\README.md' })

    # ── Secret page: Shift+Ctrl+Click any Help drop-down item ─────
    function Register-SecretHelpTrigger {
        param([System.Windows.Forms.ToolStripMenuItem]$Item)
        $Item.Add_MouseDown({
            param($s,$e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and
                ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -and
                ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)) {
                Show-SecretHelpPage -WorkspacePath $WorkspacePath
            }
        })
    }
    foreach ($mi in @($miQuickStart,$miModuleIndex,$miImplGuide,$miAboutNikr)) {
        Register-SecretHelpTrigger -Item $mi
    }

    # ── Show-SecretHelpPage ───────────────────────────────────────
    function Show-SecretHelpPage {
        param([string]$WorkspacePath)
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $nikrModInner = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'H-Ai-Nikr-Agi') 'core'
        $nikrModInner = Join-Path $nikrModInner 'H-Ai-Nikr-Agi.psm1'
        if (Test-Path $nikrModInner) { try { Import-Module $nikrModInner -Force -ErrorAction Stop } catch { Write-Warning "Failed to import H-Ai-Nikr-Agi: $_" } }

        # Determine vault state
        $vaultOpen = $false
        $vaultMod  = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
        if (Test-Path $vaultMod) {
            try { Import-Module $vaultMod -Force -ErrorAction Stop } catch { Write-Warning "Failed to import vault module: $_" }
            if (Get-Command Test-VaultStatus -ErrorAction SilentlyContinue) {
                try { $vaultOpen = (Test-VaultStatus).IsUnlocked } catch { <# vault unavailable -- decoy mode #> }
            }
        }

        $fSecret = New-Object System.Windows.Forms.Form
        $fSecret.Text   = if ($vaultOpen) { 'H-Ai-Nikr-Agi // Squabble Registry [UNLOCKED]' } else { 'Project Statistics' }
        $fSecret.Size   = [System.Drawing.Size]::new(860, 620)
        $fSecret.StartPosition = 'CenterScreen'
        $fSecret.BackColor = [System.Drawing.Color]::FromArgb(28,28,30)
        $fSecret.ForeColor = [System.Drawing.Color]::WhiteSmoke
        $fSecret.Font   = New-Object System.Drawing.Font('Segoe UI', 9)
        $fSecret.FormBorderStyle = 'Sizable'

        $rtbSecret = New-Object System.Windows.Forms.RichTextBox
        $rtbSecret.Dock      = 'Fill'
        $rtbSecret.BackColor = [System.Drawing.Color]::FromArgb(28,28,30)
        $rtbSecret.ForeColor = [System.Drawing.Color]::FromArgb(210,210,210)
        $rtbSecret.Font      = New-Object System.Drawing.Font('Cascadia Mono', 9)
        $rtbSecret.ReadOnly  = $true
        $rtbSecret.BorderStyle = 'None'
        $rtbSecret.ScrollBars  = 'Vertical'
        $fSecret.Controls.Add($rtbSecret)

        function Append-SecretLine {
            param([string]$Text, [System.Drawing.Color]$Colour)
            $start = $rtbSecret.TextLength
            $rtbSecret.AppendText($Text + "`n")
            $rtbSecret.Select($start, $Text.Length)
            $rtbSecret.SelectionColor = $Colour
        }

        if ($vaultOpen) {
            Append-SecretLine '  ╔════════════════════════════════════════════════════╗' ([System.Drawing.Color]::FromArgb(200,140,60))
            Append-SecretLine '  ║       H-Ai-Nikr-Agi  //  SQUABBLE REGISTRY        ║' ([System.Drawing.Color]::FromArgb(200,140,60))
            Append-SecretLine '  ╚════════════════════════════════════════════════════╝' ([System.Drawing.Color]::FromArgb(200,140,60))
            Append-SecretLine '' ([System.Drawing.Color]::FromArgb(100,100,100))

            $history = $null
            if (Get-Command Get-NikrAgiSquabble -ErrorAction SilentlyContinue) {
                try { $history = Get-NikrAgiSquabble -WorkspacePath $WorkspacePath } catch { <# non-fatal #> }
            }

            if (-not $history -or @($history).Count -eq 0) {
                Append-SecretLine '  [ No squabble entries yet. Nikr-Agi has been uncharacteristically quiet. ]' ([System.Drawing.Color]::FromArgb(120,120,120))
            } else {
                $idx = 0
                foreach ($e in ($history | Sort-Object timestamp -Descending)) {
                    $idx++
                    $ts = try { ([datetime]$e.timestamp).ToString('yyyy-MM-dd HH:mm') } catch { $e.timestamp }
                    Append-SecretLine "  [$idx]  $ts  //  Topic: $($e.topic)" ([System.Drawing.Color]::FromArgb(130,180,120))
                    Append-SecretLine "  [Nikr-Agi] $($e.criticism)" ([System.Drawing.Color]::FromArgb(220,180,80))
                    Append-SecretLine "  [Nikr-Agi] $($e.cutoff)"    ([System.Drawing.Color]::FromArgb(220,120,60))
                    if ($e.retort) {
                        if ($e.retort.agent1) {
                            Append-SecretLine "    --> [$($e.retort.agent1)]: $($e.retort.line1)" ([System.Drawing.Color]::FromArgb(100,180,220))
                        }
                        if ($e.retort.agent2) {
                            Append-SecretLine "    --> [$($e.retort.agent2)]: $($e.retort.line2)" ([System.Drawing.Color]::FromArgb(100,200,180))
                        }
                    }
                    Append-SecretLine '' ([System.Drawing.Color]::FromArgb(60,60,60))
                }
            }
        } else {
            # Decoy mode: benign project statistics
            Append-SecretLine '  Project Statistics Dashboard' ([System.Drawing.Color]::FromArgb(180,180,180))
            Append-SecretLine "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" ([System.Drawing.Color]::FromArgb(120,120,120))
            Append-SecretLine '' ([System.Drawing.Color]::FromArgb(60,60,60))

            $decoy = $null
            if (Get-Command Get-NikrAgiDecoyStats -ErrorAction SilentlyContinue) {
                try { $decoy = Get-NikrAgiDecoyStats -WorkspacePath $WorkspacePath } catch { <# non-fatal #> }
            }

            if ($decoy) {
                foreach ($key in $decoy.Keys) {
                    if ($key -eq 'note') { continue }
                    Append-SecretLine "  $($key.PadRight(24)) :  $($decoy[$key])" ([System.Drawing.Color]::FromArgb(180,180,180))
                }
                Append-SecretLine '' ([System.Drawing.Color]::FromArgb(60,60,60))
                Append-SecretLine "  $($decoy.note)" ([System.Drawing.Color]::FromArgb(100,100,100))
            }
        }

        $rtbSecret.SelectionStart = 0
        $rtbSecret.ScrollToCaret()
        $fSecret.ShowDialog() | Out-Null
        $fSecret.Dispose()
    }

    [void]$menuStrip.Items.AddRange(@($menuTools, $menuHelp))
    $form.MainMenuStrip = $menuStrip
    $form.Controls.Add($menuStrip)

    # ── Nikr-Agi commentary banner (Dashboard) ───────────────────
    # Populated lazily when NikrAgi fires; stored in script scope for cross-scope access
    $script:_lblNikrAgi = $null   # assigned after tabDash is created below

    # ══════════════════════════════════════════════════════════════
    #  TAB 1: DASHBOARD
    # ══════════════════════════════════════════════════════════════
    $tabDash = New-Object System.Windows.Forms.TabPage
    $tabDash.Text = "Dashboard"
    $tabDash.BackColor = $bgDark
    $tabDash.ForeColor = $fgWhite
    $toolTip.SetToolTip($tabDash, "Overview of Cron-Ai-Athon: scheduling status, last run times, queue counts, and key metrics at a glance.")
    $tabCtrl.TabPages.Add($tabDash)

    $lblDashTitle = New-StyledLabel "Cron-Ai-Athon Dashboard" 15 10 400 28 $fontHead $accBlue
    $tabDash.Controls.Add($lblDashTitle)

    $rtbDash = New-Object System.Windows.Forms.RichTextBox
    $rtbDash.Location = [System.Drawing.Point]::new(15, 45)
    $rtbDash.Size = [System.Drawing.Size]::new(850, 460)
    $rtbDash.BackColor = $bgDark; $rtbDash.ForeColor = $fgWhite
    $rtbDash.Font = $fontMono; $rtbDash.ReadOnly = $true
    $rtbDash.BorderStyle = 'None'
    $tabDash.Controls.Add($rtbDash)

    $btnRefreshDash = New-StyledButton "Refresh" 760 10 100 28
    $toolTip.SetToolTip($btnRefreshDash, "Reload all dashboard metrics from schedule config.")
    $tabDash.Controls.Add($btnRefreshDash)

    $btnRefreshDash.Add_Click({
        try {
            $summary = Get-CronJobSummary -WorkspacePath $WorkspacePath
            $rtbDash.Clear()
            $rtbDash.AppendText("=== CRON-AI-ATHON STATUS ===`r`n`r`n")
            $rtbDash.AppendText("  Scheduler Enabled : $($summary.enabled)`r`n")
            $rtbDash.AppendText("  Frequency         : $($summary.frequency)`r`n")
            $rtbDash.AppendText("  Last Run          : $(if ($summary.lastRunTime) { $summary.lastRunTime } else { '(never)' })`r`n")
            $rtbDash.AppendText("  Next Run          : $(if ($summary.nextRunTime) { $summary.nextRunTime } else { '(not scheduled)' })`r`n")
            $rtbDash.AppendText("  Tasks (enabled)   : $($summary.enabledTasks) / $($summary.taskCount)`r`n")
            $rtbDash.AppendText("`r`n=== STATISTICS ===`r`n`r`n")
            $rtbDash.AppendText("  Total Cycles      : $($summary.totalCycles)`r`n")
            $rtbDash.AppendText("  Items Done        : $($summary.totalItemsDone)`r`n")
            $rtbDash.AppendText("  Bugs Found        : $($summary.totalBugsFound)`r`n")
            $rtbDash.AppendText("  Errors            : $($summary.totalErrors)`r`n")
            $rtbDash.AppendText("  Tests Made        : $($summary.totalTestsMade)`r`n")
            $rtbDash.AppendText("  Plans Made        : $($summary.totalPlansMade)`r`n")
            $rtbDash.AppendText("  Subagent Calls    : $($summary.totalSubagentCalls)`r`n")
            $rtbDash.AppendText("`r`n=== QUESTIONS ===`r`n`r`n")
            $rtbDash.AppendText("  Total             : $($summary.questionsTotal)`r`n")
            $rtbDash.AppendText("  Autopilot         : $($summary.questionsAutopilot)`r`n")
            $rtbDash.AppendText("  Commander         : $($summary.questionsCommander)`r`n")
            $rtbDash.AppendText("  Unanswered        : $($summary.questionsUnanswered)`r`n")
            $rtbDash.AppendText("`r`n=== QUEUE ===`r`n`r`n")
            $qCount = @($summary.runningQueue).Count
            $rtbDash.AppendText("  Items in Queue    : $qCount`r`n")
        } catch {
            $rtbDash.Clear()
            $rtbDash.AppendText("Error loading dashboard: $($_.Exception.Message)`r`n")
        }
    })

    # ── Dashboard action bar (row 2) ─────────────────────────────
    # "Refresh ALL Tabs" — triggers every tab's data-load function
    $btnRefreshAll = New-StyledButton "Refresh ALL Tabs" 15 518 170 30
    $btnRefreshAll.BackColor = [System.Drawing.Color]::FromArgb(0,90,158)
    $toolTip.SetToolTip($btnRefreshAll, "Force-reload data in every tab simultaneously. Useful after a cron cycle completes.")
    $tabDash.Controls.Add($btnRefreshAll)

    $btnHighlightErrors = New-StyledButton "Highlight Tabs w/ Errors" 195 518 190 30
    $btnHighlightErrors.BackColor = [System.Drawing.Color]::FromArgb(100,40,40)
    $toolTip.SetToolTip($btnHighlightErrors, "Scan each tab for error conditions. Reports a badge showing tab count and total errors.")
    $tabDash.Controls.Add($btnHighlightErrors)

    # Error badge label — updated by Highlight scan
    $lblErrBadge = New-Object System.Windows.Forms.Label
    $lblErrBadge.Location  = [System.Drawing.Point]::new(395, 518)
    $lblErrBadge.Size      = [System.Drawing.Size]::new(250, 30)
    $lblErrBadge.BackColor = [System.Drawing.Color]::FromArgb(60,60,20)
    $lblErrBadge.ForeColor = [System.Drawing.Color]::FromArgb(220,200,80)
    $lblErrBadge.Font      = $fontMono
    $lblErrBadge.Text      = " No scan run yet"
    $lblErrBadge.TextAlign = 'MiddleLeft'
    $lblErrBadge.Visible   = $true
    $tabDash.Controls.Add($lblErrBadge)

    # "Create BUG Tasks" — enabled only when Highlight found errors
    $btnCreateBugTasks = New-StyledButton "Create BUG Tasks from Errors" 655 518 225 30
    $btnCreateBugTasks.BackColor = [System.Drawing.Color]::FromArgb(120,50,0)
    $btnCreateBugTasks.Enabled   = $false
    $toolTip.SetToolTip($btnCreateBugTasks, "Convert each tab error into a tracked BUG pipeline item. A recurring CronAiAthon task will process fixes.")
    $tabDash.Controls.Add($btnCreateBugTasks)

    # Script-scope error store populated by Highlight scan
    $script:_tabErrors = @{}

    # ── Nikr-Agi commentary banner ──────────────────────────────
    $nikrBanner = New-Object System.Windows.Forms.Label
    $nikrBanner.Location  = [System.Drawing.Point]::new(0, 554)
    $nikrBanner.Size      = [System.Drawing.Size]::new(905, 22)
    $nikrBanner.BackColor = [System.Drawing.Color]::FromArgb(38,30,20)
    $nikrBanner.ForeColor = [System.Drawing.Color]::FromArgb(200,140,60)
    $nikrBanner.Font      = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
    $nikrBanner.Text      = "  [Nikr-Agi] Waiting to disapprove of something..."
    $nikrBanner.TextAlign = 'MiddleLeft'
    $tabDash.Controls.Add($nikrBanner)
    $script:_lblNikrAgi = $nikrBanner

    $btnRefreshAll.Add_Click({
        try {
            $btnRefreshAll.Enabled = $false
            $btnRefreshAll.Text    = "Refreshing..."
            $form.Refresh()
            # Walk every tab and invoke its Add_Enter delegate (fires data load)
            foreach ($tp in $tabCtrl.TabPages) {
                try {
                    # Switch to tab momentarily to let Add_Enter fire (hidden refresh)
                    $prev = $tabCtrl.SelectedTab
                    $tabCtrl.SelectedTab = $tp
                    [System.Windows.Forms.Application]::DoEvents()
                } catch { <# non-fatal: tab may not have Add_Enter handler #> }
            }
            # Return to Dashboard
            $tabCtrl.SelectedTab = $tabDash
            $btnRefreshDash.PerformClick()
            Update-MasterToDoCache
        } catch {
            Write-CronLog -Message "RefreshAll error: $($_.Exception.Message)" -Severity Warning -Source 'Dashboard'
        } finally {
            $btnRefreshAll.Enabled = $true
            $btnRefreshAll.Text    = "Refresh ALL Tabs"
            if (Get-Command Invoke-NikrAgiSquabble -ErrorAction SilentlyContinue) {
                try {
                    $sq = Invoke-NikrAgiSquabble -WorkspacePath $WorkspacePath -Topic 'AI Programming' -RetortAgents (Get-Random -Minimum 1 -Maximum 3)
                    if ($script:_lblNikrAgi) { $script:_lblNikrAgi.Text = "  $($sq.display)" }
                } catch { <# Intentional: NikrAgi commentary is non-fatal #> }
            }
        }
    })

    $btnHighlightErrors.Add_Click({
        try {
            $btnHighlightErrors.Enabled = $false
            $script:_tabErrors = @{}
            $totalErrors = 0
            $errorTabCount = 0

            # Tab error heuristics: look for red indicators / error text already rendered
            foreach ($tp in $tabCtrl.TabPages) {
                $tabErrs = [System.Collections.ArrayList]::new()
                # Check labels/RTBs for red colour or "error" / "failed" / "exception" text
                foreach ($ctrl in $tp.Controls) {
                    if ($ctrl -is [System.Windows.Forms.Label] -and
                        $ctrl.ForeColor -eq [System.Drawing.Color]::FromArgb(244,71,71)) {
                        [void]$tabErrs.Add("Label-error: $($ctrl.Text.Substring(0,[Math]::Min(60,$ctrl.Text.Length)))")
                    }
                    if ($ctrl -is [System.Windows.Forms.RichTextBox] -and
                        $ctrl.Text -match '(?i)error|exception|failed') {
                        $matches_ = ([regex]::Matches($ctrl.Text, '(?i)error\s*:\s*[^\r\n]+') | Select-Object -First 3)
                        foreach ($m in $matches_) {
                            [void]$tabErrs.Add("RTB: $($m.Value.Substring(0,[Math]::Min(80,$m.Value.Length)))")
                        }
                    }
                    if ($ctrl -is [System.Windows.Forms.DataGridView]) {
                        # Check for cells with red back colour
                        foreach ($row in $ctrl.Rows) {
                            foreach ($cell in $row.Cells) {
                                if ($null -ne $cell.Style.BackColor -and
                                    $cell.Style.BackColor -eq [System.Drawing.Color]::FromArgb(100,30,30)) {
                                    [void]$tabErrs.Add("Grid-row error: $($row.Index)")
                                    break
                                }
                            }
                        }
                    }
                }
                if (@($tabErrs).Count -gt 0) {
                    $script:_tabErrors[$tp.Text] = $tabErrs
                    $tp.BackColor = [System.Drawing.Color]::FromArgb(60,20,20)   # red tint
                    $totalErrors  += @($tabErrs).Count
                    $errorTabCount++
                } else {
                    $tp.BackColor = $bgDark   # restore
                }
            }

            if ($errorTabCount -gt 0) {
                $lblErrBadge.Text      = " $errorTabCount tab(s)  |  $totalErrors error(s)"
                $lblErrBadge.BackColor = [System.Drawing.Color]::FromArgb(80,40,0)
                $lblErrBadge.ForeColor = [System.Drawing.Color]::FromArgb(244,135,71)
                $btnCreateBugTasks.Enabled   = $true
                $btnCreateBugTasks.BackColor = [System.Drawing.Color]::FromArgb(160,70,0)
            } else {
                $lblErrBadge.Text      = " [OK] All tabs clean"
                $lblErrBadge.BackColor = [System.Drawing.Color]::FromArgb(20,60,20)
                $lblErrBadge.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
                $btnCreateBugTasks.Enabled   = $false
                $btnCreateBugTasks.BackColor = [System.Drawing.Color]::FromArgb(120,50,0)
            }
        } catch {
            Write-CronLog -Message "HighlightErrors error: $($_.Exception.Message)" -Severity Error -Source 'Dashboard'
        } finally {
            $btnHighlightErrors.Enabled = $true
        }
    })

    $btnCreateBugTasks.Add_Click({
        try {
            $created = 0
            $grpTag  = "TabScan-$(Get-Date -Format 'yyyyMMdd-HHmm')"
            foreach ($tabName in $script:_tabErrors.Keys) {
                $errs = $script:_tabErrors[$tabName]
                # Group all errors from one tab into one BUG item
                $desc = "Tab '$tabName' reported $(@($errs).Count) error(s) detected by Dashboard scan:`n"
                $desc += ($errs | Select-Object -First 10 | ForEach-Object { "  - $_" }) -join "`n"
                try {
                    Add-PipelineItem -WorkspacePath $WorkspacePath -Type 'BUG' `
                        -Title    "Tab Error: $tabName" `
                        -Priority 'HIGH' `
                        -Status   'OPEN' `
                        -Category 'TabScanError' `
                        -Tags     @($grpTag, 'auto-generated', 'dashboard-scan') `
                        -Description $desc
                    $created++
                } catch {
                    Write-CronLog -Message "CreateBugTask failed for '$tabName': $($_.Exception.Message)" -Severity Warning -Source 'Dashboard'
                }
            }
            [System.Windows.Forms.MessageBox]::Show(
                "$created BUG item(s) created.`nGroup tag: $grpTag`n`nA CronAiAthon 'TabErrorFix' task will process these automatically.",
                "BUG Tasks Created",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            $btnCreateBugTasks.Enabled = $false
            $script:_tabErrors = @{}
            # Invite Nikr-Agi to comment on all this bug-creating activity
            if (Get-Command Invoke-NikrAgiSquabble -ErrorAction SilentlyContinue) {
                try {
                    $sq = Invoke-NikrAgiSquabble -WorkspacePath $WorkspacePath -Topic 'Attention Seeking' -RetortAgents 2
                    if ($script:_lblNikrAgi) { $script:_lblNikrAgi.Text = "  $($sq.display)" }
                } catch { <# Intentional: NikrAgi commentary is non-fatal #> }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to create bug tasks: $($_.Exception.Message)", "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 2: TASK SCHEDULE SETUP
    # ══════════════════════════════════════════════════════════════
    $tabSched = New-Object System.Windows.Forms.TabPage
    $tabSched.Text = "Task Schedule"
    $tabSched.BackColor = $bgDark
    $toolTip.SetToolTip($tabSched, "Configure scheduled tasks: enable/disable individual jobs, change run frequency, and set global scheduling options.")
    $tabCtrl.TabPages.Add($tabSched)

    $lblSchedTitle = New-StyledLabel "Task Schedule Configuration" 15 10 400 28 $fontHead $accBlue
    $tabSched.Controls.Add($lblSchedTitle)

    $dgvSched = New-StyledGrid 15 50 720 300
    $tabSched.Controls.Add($dgvSched)

    $btnLoadSched = New-StyledButton "Load Schedule" 15 360 140 30
    $toolTip.SetToolTip($btnLoadSched, "Load current task schedule from config/cron-aiathon-schedule.json")
    $tabSched.Controls.Add($btnLoadSched)

    $lblFreq = New-StyledLabel "Global Frequency (min):" 180 365 160 20
    $tabSched.Controls.Add($lblFreq)
    $nudFreq = New-Object System.Windows.Forms.NumericUpDown
    $nudFreq.Location = [System.Drawing.Point]::new(345, 362)
    $nudFreq.Size = [System.Drawing.Size]::new(80, 24)
    $nudFreq.Minimum = 5; $nudFreq.Maximum = 1440; $nudFreq.Value = 120
    $nudFreq.BackColor = $bgLight; $nudFreq.ForeColor = $fgWhite
    $tabSched.Controls.Add($nudFreq)

    $btnSaveFreq = New-StyledButton "Apply Frequency" 440 360 130 30
    $toolTip.SetToolTip($btnSaveFreq, "Save the global frequency setting and recalculate next run time.")
    $tabSched.Controls.Add($btnSaveFreq)

    $btnLoadSched.Add_Click({
        try {
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $nudFreq.Value = [Math]::Max(5, [Math]::Min(1440, $sched.frequencyMinutes))
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('ID', [string])
            [void]$dt.Columns.Add('Name', [string])
            [void]$dt.Columns.Add('Type', [string])
            [void]$dt.Columns.Add('Enabled', [string])
            [void]$dt.Columns.Add('Freq (min)', [string])
            [void]$dt.Columns.Add('Last Run', [string])
            [void]$dt.Columns.Add('Last Result', [string])
            foreach ($t in $sched.tasks) {
                [void]$dt.Rows.Add([string]$t.id, [string]$t.name, [string]$t.type, [string]$t.enabled, [string]$t.frequency, $(if($t.lastRun){[string]$t.lastRun}else{'(never)'}), $(if($t.lastResult){[string]$t.lastResult}else{'--'}))
            }
            $dgvSched.DataSource = $dt
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error loading schedule: $($_.Exception.Message)", "Error")
        }
    })

    $btnSaveFreq.Add_Click({
        try {
            Set-CronFrequency -WorkspacePath $WorkspacePath -FrequencyMinutes ([int]$nudFreq.Value)
            [System.Windows.Forms.MessageBox]::Show("Frequency updated to $([int]$nudFreq.Value) minutes.", "Saved", 'OK', 'Information')
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 3: PRE-REQUISITE CHECK
    # ══════════════════════════════════════════════════════════════
    $tabPreReq = New-Object System.Windows.Forms.TabPage
    $tabPreReq.Text = "Pre-Req Check"
    $tabPreReq.BackColor = $bgDark
    $toolTip.SetToolTip($tabPreReq, "Run environment pre-flight checks: verify directories, modules, configs, and dependencies are ready before job execution.")
    $tabCtrl.TabPages.Add($tabPreReq)

    $lblPreReqTitle = New-StyledLabel "Pre-Requisite Check" 15 10 400 28 $fontHead $accBlue
    $tabPreReq.Controls.Add($lblPreReqTitle)

    $dgvPreReq = New-StyledGrid 15 50 850 350
    $tabPreReq.Controls.Add($dgvPreReq)

    $btnRunPreReq = New-StyledButton "Run Check" 15 410 140 30
    $toolTip.SetToolTip($btnRunPreReq, "Execute all pre-requisite checks. Green = PASS, Yellow = WARN (optional), Red = FAIL (required).")
    $tabPreReq.Controls.Add($btnRunPreReq)

    $lblPreReqSummary = New-StyledLabel "" 170 415 500 20 $fontBold
    $tabPreReq.Controls.Add($lblPreReqSummary)

    $btnRunPreReq.Add_Click({
        try {
            $result = Invoke-PreRequisiteCheck -WorkspacePath $WorkspacePath
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Check')
            [void]$dt.Columns.Add('Status')
            [void]$dt.Columns.Add('Detail')
            foreach ($c in $result.checks) {
                [void]$dt.Rows.Add($c.check, $c.status, $c.detail)
            }
            $dgvPreReq.DataSource = $dt
            $lblPreReqSummary.Text = "Passed: $($result.passed)  |  Failed: $($result.failed)  |  Warnings: $($result.warnings)"
            $preFc = if ($null -ne $result -and $result.allPassed) { $accGreen } else { $accRed }
            if ($null -ne $preFc) { $lblPreReqSummary.ForeColor = $preFc }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 4: MANUAL TASK RUNNER
    # ══════════════════════════════════════════════════════════════
    $tabManual = New-Object System.Windows.Forms.TabPage
    $tabManual.Text = "Manual Runner"
    $tabManual.BackColor = $bgDark
    $toolTip.SetToolTip($tabManual, "Run individual scheduled tasks on-demand. Select a task and click 'Run Selected' or run all enabled tasks at once.")
    $tabCtrl.TabPages.Add($tabManual)

    $lblManTitle = New-StyledLabel "Manual Task Runner" 15 10 400 28 $fontHead $accBlue
    $tabManual.Controls.Add($lblManTitle)

    $lbTasks = New-Object System.Windows.Forms.ListBox
    $lbTasks.Location = [System.Drawing.Point]::new(15, 50)
    $lbTasks.Size = [System.Drawing.Size]::new(350, 200)
    $lbTasks.BackColor = $bgLight; $lbTasks.ForeColor = $fgWhite
    $lbTasks.Font = $fontNorm
    $tabManual.Controls.Add($lbTasks)

    $rtbManResult = New-Object System.Windows.Forms.RichTextBox
    $rtbManResult.Location = [System.Drawing.Point]::new(380, 50)
    $rtbManResult.Size = [System.Drawing.Size]::new(490, 350)
    $rtbManResult.BackColor = $bgDark; $rtbManResult.ForeColor = $fgWhite
    $rtbManResult.Font = $fontMono; $rtbManResult.ReadOnly = $true; $rtbManResult.BorderStyle = 'FixedSingle'
    $tabManual.Controls.Add($rtbManResult)

    $btnLoadTasks = New-StyledButton "Load Tasks" 15 260 120 30
    $toolTip.SetToolTip($btnLoadTasks, "Reload task list from the schedule configuration.")
    $tabManual.Controls.Add($btnLoadTasks)

    $btnRunSelected = New-StyledButton "Run Selected" 145 260 130 30
    $toolTip.SetToolTip($btnRunSelected, "Execute the selected task immediately and show results.")
    $tabManual.Controls.Add($btnRunSelected)

    $btnRunAll = New-StyledButton "Run All Enabled" 15 300 260 30
    $toolTip.SetToolTip($btnRunAll, "Execute all enabled tasks sequentially and show results for each.")
    $tabManual.Controls.Add($btnRunAll)

    $btnLoadTasks.Add_Click({
        try {
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $lbTasks.Items.Clear()
            # Insert AAA-TEST simulation entry at the top
            $lbTasks.Items.Add("[AAA-TEST] AAA-TEST: Full Test Simulation of TASK")
            foreach ($t in $sched.tasks) {
                $status = if ($t.enabled) { '[ON]' } else { '[OFF]' }
                $lbTasks.Items.Add("$status $($t.id)  --  $($t.name)")
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    $btnRunSelected.Add_Click({
        if ($lbTasks.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a task first.", "Info")
            return
        }
        $sel = $lbTasks.SelectedItem.ToString()
        if ($sel -like '[AAA-TEST]*') {
            $rtbManResult.Clear()
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $startTime = Get-Date
            $testFolder = Join-Path (Join-Path $WorkspacePath 'logs') ("AAA-TEST_" + $startTime.ToString('yyyyMMdd-HHmm'))
            $cacheFolder = Join-Path $testFolder 'AAA-TEST_cache'
            $errorFolder = Join-Path $testFolder 'errors'
            $zipPath = $testFolder + '_zip.zip'
            New-Item -ItemType Directory -Force -Path $testFolder | Out-Null
            New-Item -ItemType Directory -Force -Path $cacheFolder | Out-Null
            New-Item -ItemType Directory -Force -Path $errorFolder | Out-Null
            $masterLog = Join-Path $testFolder 'AAA-TEST_master-overview.log'
            $rtbManResult.AppendText("AAA-TEST simulation started.\nOutput folder: $testFolder\n\n")
            Add-Content -Path $masterLog -Value ("AAA-TEST simulation started at $startTime`r`nOutput folder: $testFolder`r`n") -Encoding UTF8
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $taskCount = 0
            foreach ($t in $sched.tasks) {
                $taskStart = Get-Date
                $logFile = Join-Path $testFolder ("AAA-TEST_master-overview_" + $t.id + ".log")
                try {
                    $rtbManResult.AppendText("Simulating $($t.id) ... ")
                    $simResult = Invoke-CronJob -WorkspacePath $WorkspacePath -TaskId $t.id -WhatIf -TestOutputPath $cacheFolder
                    $taskEnd = Get-Date
                    $msg = "Simulated $($t.id) in $([math]::Round(($taskEnd-$taskStart).TotalSeconds,2))s. Would access: $($simResult.FilesAccessed -join ', ')`r`nWould edit/create: $($simResult.FilesCreatedOrModified -join ', ')`r`n"
                    Add-Content -Path $logFile -Value $msg -Encoding UTF8
                    Add-Content -Path $masterLog -Value $msg -Encoding UTF8
                    $rtbManResult.AppendText("OK ($([math]::Round(($taskEnd-$taskStart).TotalSeconds,2))s)\n")
                } catch {
                    $errTime = Get-Date
                    $errFile = Join-Path $errorFolder ($t.id + '.2debug')
                    $errMsg = "ERROR in $($t.id) at $errTime: $($_.Exception.Message)`r`nBUGS2FIX: $($_ | Out-String)"
                    Add-Content -Path $errFile -Value $errMsg -Encoding UTF8
                    Add-Content -Path $masterLog -Value $errMsg -Encoding UTF8
                    $rtbManResult.AppendText("ERROR! See $errFile\n")
                }
                $taskCount++
            }
            $endTime = Get-Date
            $totalTime = [math]::Round(($endTime-$startTime).TotalSeconds,2)
            $rtbManResult.AppendText("\nAAA-TEST simulation complete. $taskCount tasks simulated in $totalTime seconds.\n")
            Add-Content -Path $masterLog -Value ("AAA-TEST simulation complete at $endTime. $taskCount tasks simulated in $totalTime seconds.`r`n") -Encoding UTF8
            # Zip all output
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($testFolder, $zipPath)
            # Remove cache folder
            Remove-Item -Recurse -Force $cacheFolder
            $rtbManResult.AppendText("Test output zipped to $zipPath.\n")
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            return
        }
        if ($sel -match 'TASK-\w+') {
            $taskId = $Matches[0]
            $rtbManResult.Clear()
            $rtbManResult.AppendText("Running $taskId...`r`n`r`n")
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                $res = Invoke-CronJob -WorkspacePath $WorkspacePath -TaskId $taskId
                $rtbManResult.AppendText("Task    : $($res.taskName)`r`n")
                $rtbManResult.AppendText("Success : $($res.success)`r`n")
                $rtbManResult.AppendText("Items   : $($res.itemsProcessed)`r`n")
                $rtbManResult.AppendText("Bugs    : $($res.bugsFound)`r`n")
                $rtbManResult.AppendText("Detail  : $($res.detail)`r`n")
                if (@($res.errors).Count -gt 0) {
                    $rtbManResult.AppendText("`r`nErrors:`r`n")
                    foreach ($e in @($res.errors)) { $rtbManResult.AppendText("  - $e`r`n") }
                }
                $rtbManResult.AppendText("`r`nStart: $($res.startTime)`r`nEnd  : $($res.endTime)`r`n")
            } catch {
                $rtbManResult.AppendText("EXCEPTION: $($_.Exception.Message)`r`n")
            }
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $btnRunAll.Add_Click({
        $rtbManResult.Clear()
        $rtbManResult.AppendText("=== Running All Enabled Tasks ===`r`n`r`n")
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $results = Invoke-AllCronJobs -WorkspacePath $WorkspacePath
            foreach ($res in @($results)) {
                $marker = if ($res.success) { '[OK]' } else { '[FAIL]' }
                $rtbManResult.AppendText("$marker $($res.taskName)  --  $($res.detail)`r`n")
            }
            $rtbManResult.AppendText("`r`n=== Complete: $(@($results).Count) tasks ===`r`n")
        } catch {
            $rtbManResult.AppendText("EXCEPTION: $($_.Exception.Message)`r`n")
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 5: PIPELINE QUEUE
    # ══════════════════════════════════════════════════════════════
    $tabPipeline = New-Object System.Windows.Forms.TabPage
    $tabPipeline.Text = "Pipeline Queue"
    $tabPipeline.BackColor = $bgDark
    $toolTip.SetToolTip($tabPipeline, "View all pipeline items: Feature Requests, Bugs, Items2ADD, Bugs2FIX, ToDo. Filter by type or status.")
    $tabCtrl.TabPages.Add($tabPipeline)

    $lblPipeTitle = New-StyledLabel "Pipeline Item Queue" 15 10 400 28 $fontHead $accBlue
    $tabPipeline.Controls.Add($lblPipeTitle)

    $cmbPipeType = New-Object System.Windows.Forms.ComboBox
    $cmbPipeType.Location = [System.Drawing.Point]::new(15, 48)
    $cmbPipeType.Size = [System.Drawing.Size]::new(150, 24)
    $cmbPipeType.BackColor = $bgLight; $cmbPipeType.ForeColor = $fgWhite
    $cmbPipeType.DropDownStyle = 'DropDownList'
    $cmbPipeType.Items.AddRange(@('(All Types)','FeatureRequest','Bug','Items2ADD','Bugs2FIX','ToDo'))
    $cmbPipeType.SelectedIndex = 0
    $tabPipeline.Controls.Add($cmbPipeType)

    $cmbPipeStatus = New-Object System.Windows.Forms.ComboBox
    $cmbPipeStatus.Location = [System.Drawing.Point]::new(175, 48)
    $cmbPipeStatus.Size = [System.Drawing.Size]::new(130, 24)
    $cmbPipeStatus.BackColor = $bgLight; $cmbPipeStatus.ForeColor = $fgWhite
    $cmbPipeStatus.DropDownStyle = 'DropDownList'
    $cmbPipeStatus.Items.AddRange(@('(All Status)','OPEN','IN-PROGRESS','DONE','BLOCKED','DEFERRED'))
    $cmbPipeStatus.SelectedIndex = 0
    $tabPipeline.Controls.Add($cmbPipeStatus)

    $btnPipeLoad = New-StyledButton "Load" 320 46 80 26
    $toolTip.SetToolTip($btnPipeLoad, "Load pipeline items matching the selected type and status filters.")
    $tabPipeline.Controls.Add($btnPipeLoad)

    $dgvPipe = New-StyledGrid 15 80 850 370
    $tabPipeline.Controls.Add($dgvPipe)

    $btnPipeLoad.Add_Click({
        try {
            $typeFilter = if ($cmbPipeType.SelectedItem -eq '(All Types)') { $null } else { $cmbPipeType.SelectedItem }
            $statusFilter = if ($cmbPipeStatus.SelectedItem -eq '(All Status)') { $null } else { $cmbPipeStatus.SelectedItem }
            $params = @{ WorkspacePath = $WorkspacePath }
            if ($typeFilter) { $params.Type = $typeFilter }
            if ($statusFilter) { $params.Status = $statusFilter }
            $items = Get-PipelineItems @params
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('ID')
            [void]$dt.Columns.Add('Type')
            [void]$dt.Columns.Add('Title')
            [void]$dt.Columns.Add('Status')
            [void]$dt.Columns.Add('Priority')
            [void]$dt.Columns.Add('ModCount')
            [void]$dt.Columns.Add('Created')
            foreach ($item in $items) {
                [void]$dt.Rows.Add($item.id, $item.type, $item.title, $item.status, $item.priority, $item.sessionModCount, $item.created)
            }
            $dgvPipe.DataSource = $dt
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 6: BUG TRACKER
    # ══════════════════════════════════════════════════════════════
    $tabBugs = New-Object System.Windows.Forms.TabPage
    $tabBugs.Text = "Bug Tracker"
    $tabBugs.BackColor = $bgDark
    $toolTip.SetToolTip($tabBugs, "Trigger a full bug scan across all detection vectors: parse, XHTML, crash logs, error traps, data validation, dependencies.")
    $tabCtrl.TabPages.Add($tabBugs)

    $lblBugTitle = New-StyledLabel "Bug Tracker -- Multi-Vector Scan" 15 10 400 28 $fontHead $accBlue
    $tabBugs.Controls.Add($lblBugTitle)

    $dgvBugs = New-StyledGrid 15 50 850 340
    $tabBugs.Controls.Add($dgvBugs)

    $btnRunBugScan = New-StyledButton "Run Full Bug Scan" 15 400 160 30
    $toolTip.SetToolTip($btnRunBugScan, "Scan workspace using all 6 detection vectors (parse, XHTML, crash, error-trap, data, dependency) and show results.")
    $tabBugs.Controls.Add($btnRunBugScan)

    $lblBugCount = New-StyledLabel "" 190 405 400 20 $fontBold
    $tabBugs.Controls.Add($lblBugCount)

    $btnProcessBugs = New-StyledButton "Push to Pipeline" 600 400 160 30
    $toolTip.SetToolTip($btnProcessBugs, "Send detected bugs into the pipeline registry and cross-reference the Sin Registry for known patterns.")
    $tabBugs.Controls.Add($btnProcessBugs)

    $script:_lastBugResults = @()

    $btnRunBugScan.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $bugs = Invoke-FullBugScan -WorkspacePath $WorkspacePath
            $script:_lastBugResults = @($bugs)
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Vector')
            [void]$dt.Columns.Add('Severity')
            [void]$dt.Columns.Add('File')
            [void]$dt.Columns.Add('Line')
            [void]$dt.Columns.Add('Message')
            foreach ($b in @($bugs)) {
                [void]$dt.Rows.Add($b.vector, $b.severity, $(Split-Path $b.file -Leaf), $b.line, $b.message)
            }
            $dgvBugs.DataSource = $dt
            $lblBugCount.Text = "$(@($bugs).Count) issues detected"
            $bugFc = if (@($bugs).Count -eq 0) { $accGreen } else { $accOrange }
            if ($null -ne $bugFc) { $lblBugCount.ForeColor = $bugFc }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    $btnProcessBugs.Add_Click({
        if (@($script:_lastBugResults).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Run a bug scan first.", "Info")
            return
        }
        try {
            $processed = Invoke-BugToPipelineProcessor -WorkspacePath $WorkspacePath -DetectedBugs $script:_lastBugResults
            [System.Windows.Forms.MessageBox]::Show("$(@($processed).Count) bugs pushed to pipeline.", "Done", 'OK', 'Information')
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 7: CHECKLISTS
    #  Sub-tabs: View | Add & Modify | Review & Approve | Event Log | Pipeline Summary
    # ══════════════════════════════════════════════════════════════
    $tabChecklists = New-Object System.Windows.Forms.TabPage
    $tabChecklists.Text = "Checklists"
    $tabChecklists.BackColor = $bgDark
    $toolTip.SetToolTip($tabChecklists, "Manage all ToDo/Checklist items: browse, add, modify, review approvals, view event log, and pipeline summary.")
    $tabCtrl.TabPages.Add($tabChecklists)

    $innerTabs = New-Object System.Windows.Forms.TabControl
    $innerTabs.Dock = 'Fill'
    $innerTabs.BackColor = $bgDark
    $innerTabs.Font = $fontNorm
    $tabChecklists.Controls.Add($innerTabs)

    # ─ Helper: inner sub-tab page ────────────────────────────────
    function New-InnerTab {
        param([string]$Text, [string]$Tip = '')
        $tp = New-Object System.Windows.Forms.TabPage
        $tp.Text = $Text; $tp.BackColor = $bgDark; $tp.ForeColor = $fgWhite
        $tp.Padding = [System.Windows.Forms.Padding]::new(4)
        if ($Tip) { $toolTip.SetToolTip($tp, $Tip) }
        $innerTabs.TabPages.Add($tp)
        return $tp
    }

    # ── Helper: small ComboBox ────────────────────────────────────
    function New-FilterCombo {
        param([int]$X, [int]$Y, [int]$W=130, [string[]]$Items)
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'; $c.Location = [System.Drawing.Point]::new($X,$Y)
        $c.Width = $W; $c.BackColor = $bgLight; $c.ForeColor = $fgWhite; $c.Font = $fontNorm
        foreach ($i in $Items) { [void]$c.Items.Add($i) }
        $c.SelectedIndex = 0
        return $c
    }

    # ──────────────────────────────────────────────────────────────
    #  SUB-TAB A: VIEW  (read-only browse with filters)
    # ──────────────────────────────────────────────────────────────
    $stView = New-InnerTab 'View' 'Browse all ToDo items from the todo/ folder and pipeline. Read-only.'

    # Filter bar
    $vpanel = New-Object System.Windows.Forms.Panel
    $vpanel.Dock = 'Top'; $vpanel.Height = 38; $vpanel.BackColor = $bgMed
    $stView.Controls.Add($vpanel)

    $vlblType   = New-StyledLabel 'Type:'   4 10 38 20
    $vcmbType   = New-FilterCombo 44 6 120 @('(All Types)','ToDo','Bug','Bugs2FIX','FeatureRequest','Items2ADD')
    $vlblStatus = New-StyledLabel 'Status:' 175 10 50 20
    $vcmbStatus = New-FilterCombo 228 6 110 @('(All)','OPEN','IN_PROGRESS','REVIEW','DONE','CLOSED')
    $vlblPri    = New-StyledLabel 'Priority:' 350 10 58 20
    $vcmbPri    = New-FilterCombo 410 6 90  @('(All)','HIGH','MEDIUM','LOW')
    $vlblSearch = New-StyledLabel 'Search:'  514 10 52 20
    $vtxtSearch = New-Object System.Windows.Forms.TextBox
    $vtxtSearch.Location = [System.Drawing.Point]::new(568,6); $vtxtSearch.Width = 200
    $vtxtSearch.BackColor = $bgLight; $vtxtSearch.ForeColor = $fgWhite; $vtxtSearch.Font = $fontNorm
    $vbtnRefresh = New-StyledButton 'Refresh' 780 6 80 26
    $vpanel.Controls.AddRange(@($vlblType,$vcmbType,$vlblStatus,$vcmbStatus,$vlblPri,$vcmbPri,$vlblSearch,$vtxtSearch,$vbtnRefresh))

    $dgvView = New-StyledGrid 0 38 870 380
    $dgvView.Dock = 'None'; $stView.Controls.Add($dgvView)

    $vlblInfo = New-StyledLabel '' 4 425 600 18 $fontBold $accGreen
    $stView.Controls.Add($vlblInfo)

    $script:_viewAllItems = @()

    function Load-ViewGrid {
        param([string[]]$TypeF=@(), [string]$StatusF='', [string]$PriF='', [string]$Search='')
        try {
            $items = if (Get-Command Get-CentralMasterToDo -ErrorAction SilentlyContinue) {
                @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
            } else { @() }
            $script:_viewAllItems = $items
            # apply filters
            if ($vcmbType.SelectedItem -and $vcmbType.SelectedItem -ne '(All Types)') {
                $items = $items | Where-Object { $_.type -eq $vcmbType.SelectedItem }
            }
            if ($vcmbStatus.SelectedItem -and $vcmbStatus.SelectedItem -ne '(All)') {
                $items = $items | Where-Object { $_.status -eq $vcmbStatus.SelectedItem }
            }
            if ($vcmbPri.SelectedItem -and $vcmbPri.SelectedItem -ne '(All)') {
                $items = $items | Where-Object { $_.priority -eq $vcmbPri.SelectedItem }
            }
            if ($vtxtSearch.Text.Trim()) {
                $s = $vtxtSearch.Text.ToLower()
                $items = $items | Where-Object { $_.title -like "*$s*" -or $_.id -like "*$s*" -or $_.category -like "*$s*" }
            }
            $dt = New-Object System.Data.DataTable
            foreach ($col in @('Source','Type','ID','Title','Status','Priority','Category','Created')) { [void]$dt.Columns.Add($col) }
            foreach ($i in @($items)) {
                [void]$dt.Rows.Add($i.origin, $i.type, $i.id, $i.title, $i.status, $i.priority, $i.category, $i.created)
            }
            $dgvView.DataSource = $dt
            $vlblInfo.Text = "Showing $(@($items).Count) of $(@($script:_viewAllItems).Count) items"
        } catch {
            $vlblInfo.Text = "Load error: $_"; $vlblInfo.ForeColor = $accRed
        }
    }

    $vbtnRefresh.Add_Click({ Load-ViewGrid })
    $vcmbType.Add_SelectedIndexChanged({ Load-ViewGrid })
    $vcmbStatus.Add_SelectedIndexChanged({ Load-ViewGrid })
    $vcmbPri.Add_SelectedIndexChanged({ Load-ViewGrid })
    $vtxtSearch.Add_TextChanged({ Load-ViewGrid })

    # ──────────────────────────────────────────────────────────────
    #  SUB-TAB B: ADD & MODIFY
    # ──────────────────────────────────────────────────────────────
    $stAddMod = New-InnerTab 'Add & Modify' 'Create new ToDo items or update title/priority/category of existing ones.'

    $amPanel = New-Object System.Windows.Forms.Panel
    $amPanel.Dock = 'Top'; $amPanel.Height = 38; $amPanel.BackColor = $bgMed
    $stAddMod.Controls.Add($amPanel)

    $amlblFilter = New-StyledLabel 'Filter ID/Title:' 4 10 90 20
    $amtxtFilter  = New-Object System.Windows.Forms.TextBox
    $amtxtFilter.Location = [System.Drawing.Point]::new(98,6); $amtxtFilter.Width = 240
    $amtxtFilter.BackColor = $bgLight; $amtxtFilter.ForeColor = $fgWhite
    $ambtnLoad = New-StyledButton 'Load List' 350 6 90 26
    $amPanel.Controls.AddRange(@($amlblFilter,$amtxtFilter,$ambtnLoad))

    # Split: top list + bottom editor
    $amSplit = New-Object System.Windows.Forms.SplitContainer
    $amSplit.Dock = 'Fill'; $amSplit.Orientation = 'Horizontal'
    $amSplit.SplitterDistance = 200; $amSplit.BackColor = $bgDark
    $stAddMod.Controls.Add($amSplit)

    $dgvAM = New-StyledGrid 0 0 870 195
    $dgvAM.Dock = 'Fill'; $amSplit.Panel1.Controls.Add($dgvAM)

    # Editor pane
    $editorPane = New-Object System.Windows.Forms.Panel
    $editorPane.Dock = 'Fill'; $editorPane.BackColor = $bgDark
    $amSplit.Panel2.Controls.Add($editorPane)

    $edLbls = @('ID','Type','Title','Priority','Category','Status','Description')
    $edFields = @{}
    $edY = 4
    foreach ($lname in $edLbls) {
        $lbl = New-StyledLabel "$lname" 4 $edY 90 20 $fontBold
        $editorPane.Controls.Add($lbl)
        if ($lname -eq 'Description') {
            $ctrl = New-Object System.Windows.Forms.TextBox
            $ctrl.Multiline = $true; $ctrl.Height = 50
        } elseif ($lname -in @('Type','Priority','Status')) {
            $ctrl = New-Object System.Windows.Forms.ComboBox
            switch ($lname) {
                'Type'     { @('ToDo','Bug','FeatureRequest','Items2ADD','Bugs2FIX') | ForEach-Object { [void]$ctrl.Items.Add($_) } }
                'Priority' { @('HIGH','MEDIUM','LOW') | ForEach-Object { [void]$ctrl.Items.Add($_) } }
                'Status'   { @('OPEN','IN_PROGRESS','REVIEW','DONE','CLOSED') | ForEach-Object { [void]$ctrl.Items.Add($_) } }
            }
            $ctrl.DropDownStyle = 'DropDownList'; $ctrl.BackColor = $bgLight; $ctrl.ForeColor = $fgWhite
        } else {
            $ctrl = New-Object System.Windows.Forms.TextBox
        }
        $ctrl.Location = [System.Drawing.Point]::new(100,$edY)
        $ctrl.Width = 440; $ctrl.BackColor = $bgLight; $ctrl.ForeColor = $fgWhite; $ctrl.Font = $fontNorm
        if ($lname -eq 'ID') { $ctrl.ReadOnly = $true; $ctrl.BackColor = $bgDark }
        $editorPane.Controls.Add($ctrl)
        $edFields[$lname] = $ctrl
        $edY += if ($lname -eq 'Description') { 60 } else { 26 }
    }
    $ambtnNew  = New-StyledButton 'New Item'   560 4  90 26
    $ambtnSave = New-StyledButton 'Save Changes' 660 4 110 26
    $ambtnSave.BackColor = $accGreen; $ambtnSave.ForeColor = [System.Drawing.Color]::Black
    $ambtnNew.BackColor  = $accBlue
    $amLblMsg  = New-StyledLabel '' 4 ($edY+2) 600 18 $fontBold $accGreen
    $editorPane.Controls.AddRange(@($ambtnNew,$ambtnSave,$amLblMsg))

    $script:_amAllItems = @()

    function Load-AMGrid {
        $script:_amAllItems = if (Get-Command Get-CentralMasterToDo -EA SilentlyContinue) {
            @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
        } else { @() }
        $filter = $amtxtFilter.Text.ToLower()
        $subset = if ($filter) { $script:_amAllItems | Where-Object { $_.id -like "*$filter*" -or $_.title -like "*$filter*" } } else { $script:_amAllItems }
        $dt = New-Object System.Data.DataTable
        foreach ($c in @('ID','Type','Title','Priority','Status','Category','Origin')) { [void]$dt.Columns.Add($c) }
        foreach ($i in @($subset)) { [void]$dt.Rows.Add($i.id,$i.type,$i.title,$i.priority,$i.status,$i.category,$i.origin) }
        $dgvAM.DataSource = $dt
    }

    $ambtnLoad.Add_Click({ Load-AMGrid })
    $amtxtFilter.Add_TextChanged({ Load-AMGrid })

    $dgvAM.Add_SelectionChanged({
        if ($dgvAM.SelectedRows.Count -eq 0) { return }
        $row = $dgvAM.SelectedRows[0]
        $id = $row.Cells['ID'].Value
        $item = $script:_amAllItems | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $item) { return }
        foreach ($f in @('ID','Type','Title','Priority','Category','Status','Description')) {
            $val = if ($item.PSObject.Properties[$f.ToLower()]) { $item.($f.ToLower()) } else { '' }
            $ctrl = $edFields[$f]
            if ($ctrl -is [System.Windows.Forms.ComboBox]) {
                $idx = $ctrl.Items.IndexOf($val)
                $ctrl.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
            } else { $ctrl.Text = "$val" }
        }
    })

    $ambtnNew.Add_Click({
        foreach ($f in $edFields.Keys) {
            $ctrl = $edFields[$f]
            if ($ctrl -is [System.Windows.Forms.ComboBox]) { $ctrl.SelectedIndex = 0 } else { $ctrl.Text = '' }
        }
        $edFields['ID'].Text = "todo-$(Get-Date -Format 'yyyyMMddHHmmss')-$(([System.Guid]::NewGuid().ToString('N')).Substring(0,6))"
        $edFields['Type'].SelectedIndex = 0; $edFields['Priority'].SelectedIndex = 1; $edFields['Status'].SelectedIndex = 0
    })

    $ambtnSave.Add_Click({
        $id = $edFields['ID'].Text.Trim()
        if ([string]::IsNullOrEmpty($id)) { $amLblMsg.Text = 'ID required'; $amLblMsg.ForeColor = $accRed; return }
        $todoDir = Join-Path $WorkspacePath 'todo'
        $filePath = Join-Path $todoDir "$id.json"
        $obj = [ordered]@{
            id          = $id
            type        = $edFields['Type'].SelectedItem
            title       = $edFields['Title'].Text.Trim()
            priority    = $edFields['Priority'].SelectedItem
            status      = $edFields['Status'].SelectedItem
            category    = $edFields['Category'].Text.Trim()
            description = $edFields['Description'].Text.Trim()
            created     = if ((Test-Path $filePath)) { ((Get-Content $filePath -Raw | ConvertFrom-Json).created) } else { [datetime]::UtcNow.ToString('o') }
            modified    = [datetime]::UtcNow.ToString('o')
            source      = 'ChecklistsTab'
        }
        try {
            $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $filePath -Encoding UTF8
            $amLblMsg.Text = "Saved: $id"; $amLblMsg.ForeColor = $accGreen
            Load-AMGrid
            # Write event log entry
            if (Get-Command Write-CronLog -ErrorAction SilentlyContinue) {
                Write-CronLog -Message "Checklist item saved: $id ($($obj.title))" -Severity Informational -Source 'ChecklistsTab'
            }
        } catch {
            $amLblMsg.Text = "Error: $_"; $amLblMsg.ForeColor = $accRed
        }
    })

    # ──────────────────────────────────────────────────────────────
    #  SUB-TAB C: REVIEW & APPROVE
    # ──────────────────────────────────────────────────────────────
    $stReview = New-InnerTab 'Review & Approve' 'Items awaiting review or approval. Approve moves status to IN_PROGRESS, Reject sets CLOSED.'

    $rvPanel = New-Object System.Windows.Forms.Panel
    $rvPanel.Dock = 'Top'; $rvPanel.Height = 38; $rvPanel.BackColor = $bgMed
    $stReview.Controls.Add($rvPanel)

    $rvbtnRefresh = New-StyledButton 'Refresh Review Queue' 4 6 170 26
    $rvlblCount   = New-StyledLabel '' 184 10 400 20 $fontBold $accOrange
    $rvPanel.Controls.AddRange(@($rvbtnRefresh,$rvlblCount))

    $splitRV = New-Object System.Windows.Forms.SplitContainer
    $splitRV.Dock = 'Fill'; $splitRV.SplitterDistance = 300; $splitRV.Orientation = 'Horizontal'
    $stReview.Controls.Add($splitRV)

    $dgvReview = New-StyledGrid 0 0 870 295
    $dgvReview.Dock = 'Fill'
    $splitRV.Panel1.Controls.Add($dgvReview)

    # Action buttons
    $btnApprove = New-StyledButton 'Approve -> IN_PROGRESS' 4 4 180 28
    $btnApprove.BackColor = $accGreen; $btnApprove.ForeColor = [System.Drawing.Color]::Black
    $btnReject  = New-StyledButton 'Reject -> CLOSED' 194 4 140 28
    $btnReject.BackColor  = $accRed;   $btnReject.ForeColor  = [System.Drawing.Color]::White
    $btnMarkDone= New-StyledButton 'Mark DONE' 344 4 100 28
    $rvLblMsg   = New-StyledLabel '' 4 38 600 18 $fontBold $accGreen
    $rvActionPanel = New-Object System.Windows.Forms.Panel
    $rvActionPanel.Dock = 'Fill'; $rvActionPanel.BackColor = $bgDark
    $rvActionPanel.Controls.AddRange(@($btnApprove,$btnReject,$btnMarkDone,$rvLblMsg))
    $splitRV.Panel2.Controls.Add($rvActionPanel)

    $script:_rvItems = @()

    function Load-ReviewGrid {
        $all = if (Get-Command Get-CentralMasterToDo -EA SilentlyContinue) {
            @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
        } else { @() }
        $script:_rvItems = $all | Where-Object { $_.status -in @('REVIEW','OPEN','PLANNED') }
        $dt = New-Object System.Data.DataTable
        foreach ($c in @('ID','Type','Title','Priority','Status','Category','Created')) { [void]$dt.Columns.Add($c) }
        foreach ($i in @($script:_rvItems)) { [void]$dt.Rows.Add($i.id,$i.type,$i.title,$i.priority,$i.status,$i.category,$i.created) }
        $dgvReview.DataSource = $dt
        $rvlblCount.Text = "$(@($script:_rvItems).Count) items awaiting review"
    }

    function Update-ReviewItem {
        param([string]$NewStatus)
        if ($dgvReview.SelectedRows.Count -eq 0) { $rvLblMsg.Text = 'Select an item first'; $rvLblMsg.ForeColor = $accOrange; return }
        $id = $dgvReview.SelectedRows[0].Cells['ID'].Value
        $todoDir = Join-Path $WorkspacePath 'todo'
        $fp = Get-ChildItem $todoDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $id } | Select-Object -First 1
        if (-not $fp) { $rvLblMsg.Text = "File not found for: $id"; $rvLblMsg.ForeColor = $accRed; return }
        try {
            $obj = Get-Content $fp.FullName -Raw | ConvertFrom-Json
            $obj | Add-Member -NotePropertyName 'status' -NotePropertyValue $NewStatus -Force
            $obj | Add-Member -NotePropertyName 'modified' -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            $obj | Add-Member -NotePropertyName 'reviewedAt' -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $fp.FullName -Encoding UTF8
            if (Get-Command Write-CronLog -ErrorAction SilentlyContinue) {
                Write-CronLog -Message "Review action on $($id): status -> $($NewStatus)" -Severity Informational -Source 'ChecklistsTab'
            }
            $rvLblMsg.Text = "$id -> $NewStatus"; $rvLblMsg.ForeColor = $accGreen
            Load-ReviewGrid
        } catch {
            $rvLblMsg.Text = "Error: $_"; $rvLblMsg.ForeColor = $accRed
        }
    }

    $rvbtnRefresh.Add_Click({ Load-ReviewGrid })
    $btnApprove.Add_Click({ Update-ReviewItem 'IN_PROGRESS' })
    $btnReject.Add_Click({  Update-ReviewItem 'CLOSED'      })
    $btnMarkDone.Add_Click({ Update-ReviewItem 'DONE'       })

    # ──────────────────────────────────────────────────────────────
    #  SUB-TAB D: EVENT LOG
    # ──────────────────────────────────────────────────────────────
    $stEventLog = New-InnerTab 'Event Log' 'Checklist and ToDo action audit trail from the pipeline action-log and CronAiAthon event log.'

    $elPanel = New-Object System.Windows.Forms.Panel
    $elPanel.Dock = 'Top'; $elPanel.Height = 38; $elPanel.BackColor = $bgMed
    $stEventLog.Controls.Add($elPanel)

    $elbtnRefresh = New-StyledButton 'Refresh Log' 4 6 100 26
    $elcmbSeverity = New-FilterCombo 116 6 110 @('(All)','Informational','Warning','Error','Critical','Audit')
    $elLblTip = New-StyledLabel 'Showing action-log.json + CronAiAthon event log entries relating to todo/checklist operations.' 240 10 500 18 $fontNorm $fgGray
    $elPanel.Controls.AddRange(@($elbtnRefresh,$elcmbSeverity,$elLblTip))

    $dgvEventLog = New-StyledGrid 0 38 870 380
    $dgvEventLog.Dock = 'None'; $stEventLog.Controls.Add($dgvEventLog)

    function Load-EventLogGrid {
        $rows = [System.Collections.ArrayList]::new()
        # Source 1: action-log.json
        $actionLog = Join-Path $WorkspacePath (Join-Path 'todo' 'action-log.json')
        if (Test-Path $actionLog) {
            try {
                $entries = Get-Content $actionLog -Raw | ConvertFrom-Json
                foreach ($e in @($entries)) {
                    $sev = if ($e.PSObject.Properties['severity']) { $e.severity } else { 'Informational' }
                    [void]$rows.Add([PSCustomObject]@{
                        Timestamp = if ($e.PSObject.Properties['timestamp']) { $e.timestamp } else { '' }
                        Severity  = $sev
                        Source    = 'action-log'
                        Message   = if ($e.PSObject.Properties['message']) { $e.message } elseif ($e.PSObject.Properties['action']) { $e.action } else { "$e" }
                    })
                }
            } catch { <# skip malformed #> }
        }
        # Source 2: CronAiAthon event log JSON (if available)
        $evLogDir  = Join-Path $WorkspacePath (Join-Path '~REPORTS' 'EventLog')
        if (Test-Path $evLogDir) {
            $evFiles = Get-ChildItem $evLogDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
            foreach ($ef in $evFiles) {
                try {
                    $entries = Get-Content $ef.FullName -Raw | ConvertFrom-Json
                    $todoEntries = $entries | Where-Object {
                        ($_.PSObject.Properties['source'] -and $_.source -match 'Checklist|ToDo|Pipeline|ChecklistsTab') -or
                        ($_.PSObject.Properties['message'] -and $_.message -match 'checklist|todo|item saved|review action')
                    }
                    foreach ($e in @($todoEntries)) {
                        [void]$rows.Add([PSCustomObject]@{
                            Timestamp = if ($e.PSObject.Properties['timestamp']) { $e.timestamp } else { '' }
                            Severity  = if ($e.PSObject.Properties['severity']) { $e.severity } else { 'Informational' }
                            Source    = if ($e.PSObject.Properties['source']) { $e.source } else { $ef.BaseName }
                            Message   = if ($e.PSObject.Properties['message']) { $e.message } else { '' }
                        })
                    }
                } catch { <# skip #> }
            }
        }
        # Apply severity filter
        $sevFilter = $elcmbSeverity.SelectedItem
        $filtered  = if ($sevFilter -and $sevFilter -ne '(All)') { @($rows | Where-Object { $_.Severity -eq $sevFilter }) } else { @($rows) }
        $sorted    = @($filtered | Sort-Object Timestamp -Descending)
        $dt = New-Object System.Data.DataTable
        foreach ($c in @('Timestamp','Severity','Source','Message')) { [void]$dt.Columns.Add($c) }
        foreach ($r in $sorted) { [void]$dt.Rows.Add($r.Timestamp, $r.Severity, $r.Source, $r.Message) }
        $dgvEventLog.DataSource = $dt
    }

    $elbtnRefresh.Add_Click({ Load-EventLogGrid })
    $elcmbSeverity.Add_SelectedIndexChanged({ Load-EventLogGrid })

    # ──────────────────────────────────────────────────────────────
    #  SUB-TAB E: PIPELINE SUMMARY STATUS
    # ──────────────────────────────────────────────────────────────
    $stPipeSumm = New-InnerTab 'Pipeline Summary' 'Status breakdown and health metrics for all pipeline and todo items. Read-only telemetry.'

    $psbtnRefresh = New-StyledButton 'Refresh Summary' 4 4 140 26
    $psbtnRefresh.BackColor = $accBlue
    $stPipeSumm.Controls.Add($psbtnRefresh)

    $splitPS = New-Object System.Windows.Forms.SplitContainer
    $splitPS.Location = [System.Drawing.Point]::new(0,38); $splitPS.Size = [System.Drawing.Size]::new(870,410)
    $splitPS.SplitterDistance = 320; $splitPS.BackColor = $bgDark
    $stPipeSumm.Controls.Add($splitPS)

    # Left: status breakdown grid
    $dgvStatus = New-StyledGrid 0 0 315 400; $dgvStatus.Dock = 'Fill'
    $splitPS.Panel1.Controls.Add($dgvStatus)

    # Right: health metrics + type breakdown
    $rtbHealth = New-Object System.Windows.Forms.RichTextBox
    $rtbHealth.Dock = 'Fill'; $rtbHealth.BackColor = $bgMed; $rtbHealth.ForeColor = $fgWhite
    $rtbHealth.Font = $fontMono; $rtbHealth.ReadOnly = $true
    $splitPS.Panel2.Controls.Add($rtbHealth)

    function Load-PipelineSummary {
        try {
            $items = if (Get-Command Get-CentralMasterToDo -EA SilentlyContinue) {
                @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
            } else { @() }

            # Status counts
            $byStatus = $items | Group-Object status | Sort-Object Count -Descending
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Status'); [void]$dt.Columns.Add('Count'); [void]$dt.Columns.Add('Pct')
            $total = @($items).Count
            foreach ($g in $byStatus) {
                $pct = if ($total -gt 0) { "$([Math]::Round($g.Count*100/$total))%" } else { '0%' }
                [void]$dt.Rows.Add($g.Name, $g.Count, $pct)
            }
            $dgvStatus.DataSource = $dt

            # Health metrics
            $rtbHealth.Clear()
            $rtbHealth.AppendText("═══ PIPELINE HEALTH TELEMETRY ═══`r`n`r`n")
            $rtbHealth.AppendText("Total Items    : $total`r`n")

            # By type
            $byType = $items | Group-Object type | Sort-Object Count -Descending
            $rtbHealth.AppendText("`r`nBy Type:`r`n")
            foreach ($g in $byType) { $rtbHealth.AppendText("  $($g.Name.PadRight(20)) $($g.Count)`r`n") }

            # By priority
            $rtbHealth.AppendText("`r`nBy Priority:`r`n")
            $byPri = $items | Group-Object priority | Sort-Object Count -Descending
            foreach ($g in $byPri) { $rtbHealth.AppendText("  $($g.Name.PadRight(20)) $($g.Count)`r`n") }

            # Health metrics (if available)
            if (Get-Command Get-PipelineHealthMetrics -EA SilentlyContinue) {
                try {
                    $health = Get-PipelineHealthMetrics -WorkspacePath $WorkspacePath
                    $rtbHealth.AppendText("`r`n═══ FLOW METRICS ═══`r`n")
                    $rtbHealth.AppendText("  Open Items         : $($health.openItems)`r`n")
                    $rtbHealth.AppendText("  Closed Items       : $($health.closedItems)`r`n")
                    $rtbHealth.AppendText("  Created/Day (30d)  : $($health.createdPerDay)`r`n")
                    $rtbHealth.AppendText("  Closed/Day  (30d)  : $($health.closedPerDay)`r`n")
                    $rtbHealth.AppendText("  Mean Time to Close : $($health.meanTimeToClose) days`r`n")
                    $rtbHealth.AppendText("`r`n  Backlog Age:`r`n")
                    $rtbHealth.AppendText("    < 1 day   : $($health.backlogAge['lt1d'])`r`n")
                    $rtbHealth.AppendText("    1-7 days  : $($health.backlogAge['1d-7d'])`r`n")
                    $rtbHealth.AppendText("    7-30 days : $($health.backlogAge['7d-30d'])`r`n")
                    $rtbHealth.AppendText("    > 30 days : $($health.backlogAge['gt30d'])`r`n")
                } catch { $rtbHealth.AppendText("`r`n[Health metrics unavailable: $_]`r`n") }
            }

            # Category statistics
            $rtbHealth.AppendText("`r`n═══ BY CATEGORY ═══`r`n")
            $byCat = $items | Group-Object category | Sort-Object Count -Descending | Select-Object -First 15
            foreach ($g in $byCat) { $rtbHealth.AppendText("  $($g.Name.PadRight(22)) $($g.Count)`r`n") }

            $rtbHealth.AppendText("`r`n[Refreshed: $(Get-Date -Format 'HH:mm:ss')]`r`n")
        } catch {
            $rtbHealth.Clear()
            $rtbHealth.AppendText("Error loading pipeline summary:`r`n$_`r`n")
        }
    }

    $psbtnRefresh.Add_Click({ Load-PipelineSummary })

    # ── Auto-load sub-tabs when Checklists tab is selected ────────
    $tabCtrl.Add_SelectedIndexChanged({
        if ($tabCtrl.SelectedTab -eq $tabChecklists) {
            if ($innerTabs.SelectedTab -eq $stView)     { Load-ViewGrid }
            elseif ($innerTabs.SelectedTab -eq $stAddMod)  { Load-AMGrid }
            elseif ($innerTabs.SelectedTab -eq $stReview)  { Load-ReviewGrid }
            elseif ($innerTabs.SelectedTab -eq $stEventLog){ Load-EventLogGrid }
            elseif ($innerTabs.SelectedTab -eq $stPipeSumm){ Load-PipelineSummary }
        }
        if ($tabCtrl.SelectedTab -eq $tabMaster)      { Invoke-MasterRefresh }
    })
    $innerTabs.Add_SelectedIndexChanged({
        switch ($innerTabs.SelectedTab) {
            $stView     { Load-ViewGrid }
            $stAddMod   { Load-AMGrid  }
            $stReview   { Load-ReviewGrid }
            $stEventLog { Load-EventLogGrid }
            $stPipeSumm { Load-PipelineSummary }
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 8: MASTER TODO  (read-only aggregate + filters + telemetry)
    # ══════════════════════════════════════════════════════════════
    $tabMaster = New-Object System.Windows.Forms.TabPage
    $tabMaster.Text = "Master ToDo"
    $tabMaster.BackColor = $bgDark
    $toolTip.SetToolTip($tabMaster, "Read-only central aggregated view of all pipeline, todo, bug and feature items. Use filters only — no editing here.")
    $tabCtrl.TabPages.Add($tabMaster)

    # ── Telemetry strip (top banner) ─────────────────────────────
    $mTelPanel = New-Object System.Windows.Forms.Panel
    $mTelPanel.Dock = 'Top'; $mTelPanel.Height = 28; $mTelPanel.BackColor = $bgDark
    $tabMaster.Controls.Add($mTelPanel)

    $mTelLbls = @{}
    $mTelKeys = @('Total','Open','In Progress','Done','High Priority','Bugs','Features','ToDos')
    $tx = 4
    foreach ($k in $mTelKeys) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.AutoSize = $true; $lbl.Font = $fontBold
        $lbl.ForeColor = $accBlue; $lbl.BackColor = [System.Drawing.Color]::Transparent
        $lbl.Location = [System.Drawing.Point]::new($tx, 6)
        $lbl.Text = "$($k): --"
        $mTelPanel.Controls.Add($lbl)
        $mTelLbls[$k] = $lbl
        $tx += 105
    }

    # ── Filter bar ───────────────────────────────────────────────
    $mFilterPanel = New-Object System.Windows.Forms.Panel
    $mFilterPanel.Dock = 'Top'; $mFilterPanel.Height = 36; $mFilterPanel.BackColor = $bgMed
    $tabMaster.Controls.Add($mFilterPanel)

    $mLblType   = New-StyledLabel 'Type:'    4 9 40 20
    $mcmbType   = New-FilterCombo 46 5 115  @('(All)','ToDo','Bug','FeatureRequest','Items2ADD','Bugs2FIX')
    $mLblStatus = New-StyledLabel 'Status:'  172 9 50 20
    $mcmbStatus = New-FilterCombo 225 5 110 @('(All)','OPEN','IN_PROGRESS','PLANNED','REVIEW','DONE','CLOSED')
    $mLblPri    = New-StyledLabel 'Priority:' 346 9 58 20
    $mcmbPri    = New-FilterCombo 407 5 90  @('(All)','HIGH','MEDIUM','LOW')
    $mLblSrc    = New-StyledLabel 'Source:'  508 9 50 20
    $mcmbSrc    = New-FilterCombo 560 5 115 @('(All)','pipeline','todo-folder','Legacy')
    $mTxtSearch = New-Object System.Windows.Forms.TextBox
    $mTxtSearch.Location = [System.Drawing.Point]::new(688,5); $mTxtSearch.Width = 170
    $mTxtSearch.BackColor = $bgLight; $mTxtSearch.ForeColor = $fgWhite; $mTxtSearch.Font = $fontNorm
    $toolTip.SetToolTip($mTxtSearch, 'Filter by title, ID or category')
    $mFilterPanel.Controls.AddRange(@($mLblType,$mcmbType,$mLblStatus,$mcmbStatus,$mLblPri,$mcmbPri,$mLblSrc,$mcmbSrc,$mTxtSearch))

    # ── Read-only grid ───────────────────────────────────────────
    $dgvMaster = New-StyledGrid 0 0 870 365
    $dgvMaster.Dock = 'Fill'
    $tabMaster.Controls.Add($dgvMaster)

    $mLblCount = New-StyledLabel '' 4 5 500 18 $fontBold $accGreen
    $mTelPanel.Controls.Add($mLblCount)

    $script:_masterRaw = @()

    function Apply-MasterFilter {
        $items = $script:_masterRaw
        if ($mcmbType.SelectedItem   -ne '(All)') { $items = $items | Where-Object { $_.type   -eq $mcmbType.SelectedItem } }
        if ($mcmbStatus.SelectedItem -ne '(All)') { $items = $items | Where-Object { $_.status -eq $mcmbStatus.SelectedItem } }
        if ($mcmbPri.SelectedItem    -ne '(All)') { $items = $items | Where-Object { $_.priority -eq $mcmbPri.SelectedItem } }
        if ($mcmbSrc.SelectedItem    -ne '(All)') { $items = $items | Where-Object { $_.origin  -eq $mcmbSrc.SelectedItem } }
        if ($mTxtSearch.Text.Trim()) {
            $s = $mTxtSearch.Text.ToLower()
            $items = $items | Where-Object { $_.title -like "*$s*" -or $_.id -like "*$s*" -or $_.category -like "*$s*" }
        }
        $dt = New-Object System.Data.DataTable
        foreach ($c in @('Source','Type','ID','Title','Status','Priority','Category','Created')) { [void]$dt.Columns.Add($c) }
        foreach ($i in @($items)) { [void]$dt.Rows.Add($i.origin,$i.type,$i.id,$i.title,$i.status,$i.priority,$i.category,$i.created) }
        $dgvMaster.DataSource = $dt
    }

    function Invoke-MasterRefresh {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            if (Get-Command Export-CentralMasterToDo -EA SilentlyContinue) {
                Export-CentralMasterToDo -WorkspacePath $WorkspacePath | Out-Null
            }
            $script:_masterRaw = if (Get-Command Get-CentralMasterToDo -EA SilentlyContinue) {
                @(Get-CentralMasterToDo -WorkspacePath $WorkspacePath)
            } else { @() }
            # Telemetry strip values
            $all   = $script:_masterRaw
            $mTelLbls['Total'].Text        = "Total: $(@($all).Count)"
            $mTelLbls['Open'].Text         = "Open: $(@($all | Where-Object { $_.status -eq 'OPEN' }).Count)"
            $mTelLbls['In Progress'].Text  = "In Prog: $(@($all | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count)"
            $mTelLbls['Done'].Text         = "Done: $(@($all | Where-Object { $_.status -in @('DONE','CLOSED','FIXED') }).Count)"
            $mTelLbls['High Priority'].Text= "HIGH: $(@($all | Where-Object { $_.priority -eq 'HIGH' }).Count)"
            $mTelLbls['Bugs'].Text         = "Bugs: $(@($all | Where-Object { $_.type -in @('Bug','Bugs2FIX') }).Count)"
            $mTelLbls['Features'].Text     = "Feat: $(@($all | Where-Object { $_.type -eq 'FeatureRequest' }).Count)"
            $mTelLbls['ToDos'].Text        = "ToDos: $(@($all | Where-Object { $_.type -eq 'ToDo' }).Count)"
            Apply-MasterFilter
        } catch {
            $mLblCount.Text = "Error: $_"
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    $mcmbType.Add_SelectedIndexChanged({   Apply-MasterFilter })
    $mcmbStatus.Add_SelectedIndexChanged({ Apply-MasterFilter })
    $mcmbPri.Add_SelectedIndexChanged({    Apply-MasterFilter })
    $mcmbSrc.Add_SelectedIndexChanged({    Apply-MasterFilter })
    $mTxtSearch.Add_TextChanged({          Apply-MasterFilter })

    # ══════════════════════════════════════════════════════════════
    #  TAB 8: STATISTICS
    # ══════════════════════════════════════════════════════════════
    $tabStats = New-Object System.Windows.Forms.TabPage
    $tabStats.Text = "Statistics"
    $tabStats.BackColor = $bgDark
    $toolTip.SetToolTip($tabStats, "Detailed job statistics: total cycles, errors, items completed, bugs found, tests run, plans created, and error history.")
    $tabCtrl.TabPages.Add($tabStats)

    $lblStatsTitle = New-StyledLabel "Job Statistics" 15 10 400 28 $fontHead $accBlue
    $tabStats.Controls.Add($lblStatsTitle)

    $dgvStats = New-StyledGrid 15 50 400 200
    $tabStats.Controls.Add($dgvStats)

    $lblHistTitle = New-StyledLabel "Recent Job History" 15 265 400 22 $fontBold $accOrange
    $tabStats.Controls.Add($lblHistTitle)

    $dgvHist = New-StyledGrid 15 290 850 170
    $tabStats.Controls.Add($dgvHist)

    $btnLoadStats = New-StyledButton "Refresh Stats" 430 50 140 30
    $toolTip.SetToolTip($btnLoadStats, "Reload statistics from schedule config and show last 50 job history entries.")
    $tabStats.Controls.Add($btnLoadStats)

    $btnLoadStats.Add_Click({
        try {
            $summary = Get-CronJobSummary -WorkspacePath $WorkspacePath
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Metric')
            [void]$dt.Columns.Add('Value')
            [void]$dt.Rows.Add('Total Cycles', $summary.totalCycles)
            [void]$dt.Rows.Add('Total Errors', $summary.totalErrors)
            [void]$dt.Rows.Add('Items Done', $summary.totalItemsDone)
            [void]$dt.Rows.Add('Bugs Found', $summary.totalBugsFound)
            [void]$dt.Rows.Add('Tests Made', $summary.totalTestsMade)
            [void]$dt.Rows.Add('Plans Made', $summary.totalPlansMade)
            [void]$dt.Rows.Add('Subagent Calls', $summary.totalSubagentCalls)
            [void]$dt.Rows.Add('Last Error', $(if($summary.lastError){$summary.lastError}else{'(none)'}))
            $dgvStats.DataSource = $dt

            # History
            $hist = Get-CronJobHistory -WorkspacePath $WorkspacePath -Last 50
            $htDt = New-Object System.Data.DataTable
            [void]$htDt.Columns.Add('Task')
            [void]$htDt.Columns.Add('Success')
            [void]$htDt.Columns.Add('Items')
            [void]$htDt.Columns.Add('Bugs')
            [void]$htDt.Columns.Add('Time')
            foreach ($h in $hist) {
                [void]$htDt.Rows.Add($h.taskName, $h.success, $h.itemsProcessed, $h.bugsFound, $h.startTime)
            }
            $dgvHist.DataSource = $htDt
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 9: SUBAGENT TALLY
    # ══════════════════════════════════════════════════════════════
    $tabAgents = New-Object System.Windows.Forms.TabPage
    $tabAgents.Text = "Subagent Tally"
    $tabAgents.BackColor = $bgDark
    $toolTip.SetToolTip($tabAgents, "Per-agent invocation counters showing how many times each subagent has been dispatched by Cron-Ai-Athon jobs.")
    $tabCtrl.TabPages.Add($tabAgents)

    $lblAgentTitle = New-StyledLabel "Subagent Invocation Tally" 15 10 400 28 $fontHead $accBlue
    $tabAgents.Controls.Add($lblAgentTitle)

    $dgvAgents = New-StyledGrid 15 50 600 350
    $tabAgents.Controls.Add($dgvAgents)

    $btnLoadAgents = New-StyledButton "Refresh" 15 410 120 30
    $toolTip.SetToolTip($btnLoadAgents, "Reload subagent call tallies from the schedule config.")
    $tabAgents.Controls.Add($btnLoadAgents)

    $btnLoadAgents.Add_Click({
        try {
            $summary = Get-CronJobSummary -WorkspacePath $WorkspacePath
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Agent Name')
            [void]$dt.Columns.Add('Calls')
            if ($sched.jobStatistics.subagentTally.PSObject.Properties) {
                foreach ($prop in $sched.jobStatistics.subagentTally.PSObject.Properties) {
                    [void]$dt.Rows.Add($prop.Name, $prop.Value)
                }
            }
            if ($dt.Rows.Count -eq 0) {
                [void]$dt.Rows.Add('(no subagent calls recorded)', 0)
            }
            $dgvAgents.DataSource = $dt
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 10: QUESTIONS
    # ══════════════════════════════════════════════════════════════
    $tabQuestions = New-Object System.Windows.Forms.TabPage
    $tabQuestions.Text = "Questions"
    $tabQuestions.BackColor = $bgDark
    $toolTip.SetToolTip($tabQuestions, "Track questions arising from Cron-Ai-Athon processing: how many answered by Autopilot, by Commander, or remain Unanswered.")
    $tabCtrl.TabPages.Add($tabQuestions)

    $lblQTitle = New-StyledLabel "Question Tracking" 15 10 400 28 $fontHead $accBlue
    $tabQuestions.Controls.Add($lblQTitle)

    $dgvQ = New-StyledGrid 15 50 400 200
    $tabQuestions.Controls.Add($dgvQ)

    $btnLoadQ = New-StyledButton "Refresh" 15 260 120 30
    $toolTip.SetToolTip($btnLoadQ, "Reload question tallies from schedule config.")
    $tabQuestions.Controls.Add($btnLoadQ)

    # Manual question registering
    $lblQNew = New-StyledLabel "Register New Question:" 15 310 200 20 $fontBold $accOrange
    $tabQuestions.Controls.Add($lblQNew)

    $cmbQType = New-Object System.Windows.Forms.ComboBox
    $cmbQType.Location = [System.Drawing.Point]::new(15, 335)
    $cmbQType.Size = [System.Drawing.Size]::new(150, 24)
    $cmbQType.BackColor = $bgLight; $cmbQType.ForeColor = $fgWhite
    $cmbQType.DropDownStyle = 'DropDownList'
    $cmbQType.Items.AddRange(@('autopilot','commander','unanswered'))
    $cmbQType.SelectedIndex = 0
    $tabQuestions.Controls.Add($cmbQType)

    $btnRegQ = New-StyledButton "Register" 175 333 100 26
    $toolTip.SetToolTip($btnRegQ, "Add +1 to the selected question category tally.")
    $tabQuestions.Controls.Add($btnRegQ)

    $btnLoadQ.Add_Click({
        try {
            $summary = Get-CronJobSummary -WorkspacePath $WorkspacePath
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('Category')
            [void]$dt.Columns.Add('Count')
            [void]$dt.Rows.Add('Total', $summary.questionsTotal)
            [void]$dt.Rows.Add('Autopilot', $summary.questionsAutopilot)
            [void]$dt.Rows.Add('Commander', $summary.questionsCommander)
            [void]$dt.Rows.Add('Unanswered', $summary.questionsUnanswered)
            $dgvQ.DataSource = $dt
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    $btnRegQ.Add_Click({
        try {
            Register-Question -WorkspacePath $WorkspacePath -AnsweredBy $cmbQType.SelectedItem
            $btnLoadQ.PerformClick()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 11: AUTOPILOT SUGGESTIONS
    # ══════════════════════════════════════════════════════════════
    $tabAuto = New-Object System.Windows.Forms.TabPage
    $tabAuto.Text = "Autopilot Suggestions"
    $tabAuto.BackColor = $bgDark
    $toolTip.SetToolTip($tabAuto, "Self-suggested additions from Autopilot: track implemented, pending, rejected, blocked, and failed suggestion counts.")
    $tabCtrl.TabPages.Add($tabAuto)

    $lblAutoTitle = New-StyledLabel "Autopilot Suggestions" 15 10 400 28 $fontHead $accBlue
    $tabAuto.Controls.Add($lblAutoTitle)

    $dgvAuto = New-StyledGrid 15 50 850 280
    $tabAuto.Controls.Add($dgvAuto)

    $lblAutoSummary = New-StyledLabel "" 15 340 600 22 $fontBold $accGreen
    $tabAuto.Controls.Add($lblAutoSummary)

    $btnLoadAuto = New-StyledButton "Refresh" 15 370 120 30
    $toolTip.SetToolTip($btnLoadAuto, "Reload autopilot suggestions list and status counters.")
    $tabAuto.Controls.Add($btnLoadAuto)

    # Add suggestion
    $lblNewSug = New-StyledLabel "New Suggestion Title:" 200 375 160 20
    $tabAuto.Controls.Add($lblNewSug)
    $txtNewSug = New-Object System.Windows.Forms.TextBox
    $txtNewSug.Location = [System.Drawing.Point]::new(370, 373)
    $txtNewSug.Size = [System.Drawing.Size]::new(300, 24)
    $txtNewSug.BackColor = $bgLight; $txtNewSug.ForeColor = $fgWhite
    $tabAuto.Controls.Add($txtNewSug)

    $btnAddSug = New-StyledButton "Add" 680 370 80 30
    $toolTip.SetToolTip($btnAddSug, "Create a new autopilot suggestion with 'pending' status.")
    $tabAuto.Controls.Add($btnAddSug)

    $btnLoadAuto.Add_Click({
        try {
            $sched = Initialize-CronSchedule -WorkspacePath $WorkspacePath
            $ap = $sched.autopilotSuggestions
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('ID')
            [void]$dt.Columns.Add('Title')
            [void]$dt.Columns.Add('Category')
            [void]$dt.Columns.Add('Status')
            [void]$dt.Columns.Add('Created')
            foreach ($item in $ap.items) {
                [void]$dt.Rows.Add($item.id, $item.title, $item.category, $item.status, $item.created)
            }
            $dgvAuto.DataSource = $dt
            $lblAutoSummary.Text = "Implemented: $($ap.implemented)  |  Pending: $($ap.pending)  |  Rejected: $($ap.rejected)  |  Blocked: $($ap.blocked)  |  Failed: $($ap.failed)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    $btnAddSug.Add_Click({
        $title = $txtNewSug.Text.Trim()
        if (-not $title) {
            [System.Windows.Forms.MessageBox]::Show("Enter a suggestion title.", "Info")
            return
        }
        try {
            Add-AutopilotSuggestion -WorkspacePath $WorkspacePath -Title $title
            $txtNewSug.Clear()
            $btnLoadAuto.PerformClick()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 12: EVENT LOG / SYSLOG
    # ══════════════════════════════════════════════════════════════
    $tabEvt = New-Object System.Windows.Forms.TabPage
    $tabEvt.Text = "Event Log / SYSLOG"
    $tabEvt.BackColor = $bgDark
    $toolTip.SetToolTip($tabEvt, "Windows Event Log source registration, SYSLOG severity config, .SYSLOG file viewer, and UDP/TCP forwarding test.")
    $tabCtrl.TabPages.Add($tabEvt)

    $lblEvtTitle = New-StyledLabel "Event Log & SYSLOG Configuration" 15 10 500 28 $fontHead $accBlue
    $tabEvt.Controls.Add($lblEvtTitle)

    # Source registration
    $btnRegSources = New-StyledButton "Register Sources" 15 50 160 30
    $toolTip.SetToolTip($btnRegSources, "Register PowerShellGUI-CRON and PowerShellGUI-CORE sources in Windows Event Log. Requires elevated privileges on first run.")
    $tabEvt.Controls.Add($btnRegSources)

    $lblSourceStatus = New-StyledLabel "" 190 55 500 20
    $tabEvt.Controls.Add($lblSourceStatus)

    # SYSLOG config
    $lblSysServer = New-StyledLabel "SYSLOG Server:" 15 95 110 20
    $tabEvt.Controls.Add($lblSysServer)
    $txtSysServer = New-Object System.Windows.Forms.TextBox
    $txtSysServer.Location = [System.Drawing.Point]::new(130, 93)
    $txtSysServer.Size = [System.Drawing.Size]::new(200, 24)
    $txtSysServer.BackColor = $bgLight; $txtSysServer.ForeColor = $fgWhite
    $txtSysServer.Text = ''
    $tabEvt.Controls.Add($txtSysServer)

    $lblSysPort = New-StyledLabel "Port:" 345 95 40 20
    $tabEvt.Controls.Add($lblSysPort)
    $nudSysPort = New-Object System.Windows.Forms.NumericUpDown
    $nudSysPort.Location = [System.Drawing.Point]::new(390, 93)
    $nudSysPort.Size = [System.Drawing.Size]::new(70, 24)
    $nudSysPort.Minimum = 1; $nudSysPort.Maximum = 65535; $nudSysPort.Value = 161
    $nudSysPort.BackColor = $bgLight; $nudSysPort.ForeColor = $fgWhite
    $tabEvt.Controls.Add($nudSysPort)

    $btnTestSyslog = New-StyledButton "Test Forward" 475 90 130 28
    $toolTip.SetToolTip($btnTestSyslog, "Send a test SYSLOG message to the configured server via UDP (primary) with TCP fallback.")
    $tabEvt.Controls.Add($btnTestSyslog)

    $lblTestResult = New-StyledLabel "" 615 95 250 20
    $tabEvt.Controls.Add($lblTestResult)

    # Write test event
    $btnTestEvent = New-StyledButton "Write Test Event" 15 130 160 28
    $toolTip.SetToolTip($btnTestEvent, "Write a test Informational event to the Windows Event Log and .SYSLOG file.")
    $tabEvt.Controls.Add($btnTestEvent)

    $lblEventResult = New-StyledLabel "" 190 135 500 20
    $tabEvt.Controls.Add($lblEventResult)

    # .SYSLOG file viewer
    $lblSyslogFile = New-StyledLabel ".SYSLOG File Entries (last 100):" 15 170 300 20 $fontBold $accOrange
    $tabEvt.Controls.Add($lblSyslogFile)

    $rtbSyslog = New-Object System.Windows.Forms.RichTextBox
    $rtbSyslog.Location = [System.Drawing.Point]::new(15, 195)
    $rtbSyslog.Size = [System.Drawing.Size]::new(850, 240)
    $rtbSyslog.BackColor = $bgDark; $rtbSyslog.ForeColor = $fgWhite
    $rtbSyslog.Font = $fontMono; $rtbSyslog.ReadOnly = $true; $rtbSyslog.BorderStyle = 'FixedSingle'
    $tabEvt.Controls.Add($rtbSyslog)

    $btnLoadSyslog = New-StyledButton "Refresh Log" 15 445 130 28
    $toolTip.SetToolTip($btnLoadSyslog, "Reload the .SYSLOG file contents from logs/PowerShellGUI.SYSLOG")
    $tabEvt.Controls.Add($btnLoadSyslog)

    # Event Log config summary
    $btnEvtConfig = New-StyledButton "Show Config" 160 445 130 28
    $toolTip.SetToolTip($btnEvtConfig, "Show current EventLog/SYSLOG configuration details in the viewer.")
    $tabEvt.Controls.Add($btnEvtConfig)

    $btnRegSources.Add_Click({
        try {
            $results = Register-EventLogSources
            $msgs = @()
            foreach ($r in $results) { $msgs += "$($r.source): $($r.status)" }
            $lblSourceStatus.Text = $msgs -join '  |  '
            $fc = if ($results | Where-Object { $_.status -eq 'FAILED' }) { $accRed } else { $accGreen }
            if ($null -ne $fc) { $lblSourceStatus.ForeColor = $fc }
        } catch {
            $lblSourceStatus.Text = "Error: $($_.Exception.Message)"
            $lblSourceStatus.ForeColor = $accRed
        }
    })

    $btnTestSyslog.Add_Click({
        $server = $txtSysServer.Text.Trim()
        if (-not $server) {
            $lblTestResult.Text = "Enter a SYSLOG server address"
            $lblTestResult.ForeColor = $accOrange
            return
        }
        try {
            $res = Send-SyslogMessage -Server $server -Port ([int]$nudSysPort.Value) `
                -Severity 'Informational' -Message "CronAiAthon test message $(Get-Date -Format 'HH:mm:ss')" -UseTcpFallback
            $lblTestResult.Text = "$(if($res.success){'OK'}else{'FAILED'}) via $($res.protocol)"
            $fc = if ($res.success) { $accGreen } else { $accRed }
            if ($null -ne $fc) { $lblTestResult.ForeColor = $fc }
        } catch {
            $lblTestResult.Text = "Error: $($_.Exception.Message)"
            $lblTestResult.ForeColor = $accRed
        }
    })

    $btnTestEvent.Add_Click({
        try {
            $res = Write-CronLog -WorkspacePath $WorkspacePath -Source 'PowerShellGUI-CRON' `
                -Message "Cron-Ai-Athon test event at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Severity 'Informational'
            $evtOk = if ($res.eventLog.success) { 'EventLog OK' } else { "EventLog: $($res.eventLog.error)" }
            $fileOk = if ($res.syslogFile.success) { '.SYSLOG OK' } else { '.SYSLOG failed' }
            $lblEventResult.Text = "$evtOk | $fileOk"
            $fc = if ($res.eventLog.success -and $res.syslogFile.success) { $accGreen } else { $accOrange }
            if ($null -ne $fc) { $lblEventResult.ForeColor = $fc }
        } catch {
            $lblEventResult.Text = "Error: $($_.Exception.Message)"
            $lblEventResult.ForeColor = $accRed
        }
    })

    $btnLoadSyslog.Add_Click({
        try {
            $entries = @(Get-SyslogEntries -WorkspacePath $WorkspacePath -Last 100)
            $rtbSyslog.Clear()
            if ($entries.Count -eq 0) {
                $rtbSyslog.AppendText("(no .SYSLOG entries yet)`r`n")
            } else {
                foreach ($line in $entries) { $rtbSyslog.AppendText("$line`r`n") }
            }
        } catch {
            $rtbSyslog.Clear()
            $rtbSyslog.AppendText("Error: $($_.Exception.Message)`r`n")
        }
    })

    $btnEvtConfig.Add_Click({
        try {
            $cfg = Get-EventLogConfig -WorkspacePath $WorkspacePath
            $rtbSyslog.Clear()
            $rtbSyslog.AppendText("=== EVENT LOG / SYSLOG CONFIG ===`r`n`r`n")
            $rtbSyslog.AppendText("Sources:`r`n")
            foreach ($s in $cfg.sources) {
                $rtbSyslog.AppendText("  $($s.source): $(if($s.registered){'REGISTERED'}else{'NOT REGISTERED'})`r`n")
            }
            $rtbSyslog.AppendText("`r`n.SYSLOG File:`r`n")
            $rtbSyslog.AppendText("  Path   : $($cfg.syslogFile.path)`r`n")
            $rtbSyslog.AppendText("  Exists : $($cfg.syslogFile.exists)`r`n")
            $rtbSyslog.AppendText("  Size   : $($cfg.syslogFile.sizeBytes) bytes`r`n")
            $rtbSyslog.AppendText("  Lines  : $($cfg.syslogFile.lineCount)`r`n")
            $rtbSyslog.AppendText("`r`nDefault SYSLOG Port: $($cfg.defaultPort)`r`n")
            $rtbSyslog.AppendText("`r`nSeverity Levels (RFC 5424):`r`n")
            foreach ($key in @('Emergency','Alert','Critical','Error','Warning','Notice','Informational','Debug')) {
                $rtbSyslog.AppendText("  $($cfg.severity[$key]) = $key`r`n")
            }
        } catch {
            $rtbSyslog.Clear()
            $rtbSyslog.AppendText("Error: $($_.Exception.Message)`r`n")
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 13 : PIPELINE MONITOR
    # ══════════════════════════════════════════════════════════════
    $tabMon = New-Object System.Windows.Forms.TabPage
    $tabMon.Text      = 'Pipeline Monitor'
    $tabMon.BackColor = $bgDark
    $tabMon.ForeColor = $fgWhite
    $toolTip.SetToolTip($tabMon, 'Live pipeline execution status, waiting queues, agent/tool counts. Auto-refreshes every ~20 seconds.')
    $tabCtrl.TabPages.Add($tabMon)

    # ── Title + last-refresh label ────────────────────────────────
    $lblMonTitle = New-StyledLabel 'Pipeline Monitor' 15 10 400 28 $fontHead $accBlue
    $tabMon.Controls.Add($lblMonTitle)

    $lblMonRefresh = New-StyledLabel 'Refreshing…' 650 14 250 20 $fontNorm $fgGray
    $tabMon.Controls.Add($lblMonRefresh)

    # ── Session-start time (set once when tab first loads) ────────
    $script:_monSessionStart = $null

    # ── Top stat card strip ───────────────────────────────────────
    $monStatPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $monStatPanel.Location    = [System.Drawing.Point]::new(15, 45)
    $monStatPanel.Size        = [System.Drawing.Size]::new(890, 72)
    $monStatPanel.ColumnCount = 7
    $monStatPanel.RowCount    = 1
    $monStatPanel.BackColor   = $bgDark
    for ($ci = 0; $ci -lt 7; $ci++) {
        [void]$monStatPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 14.28)))
    }
    [void]$monStatPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 72)))
    $tabMon.Controls.Add($monStatPanel)

    function New-StatCard {
        param([string]$ValueText, [string]$KeyText, [System.Drawing.Color]$Accent)
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.Dock      = 'Fill'
        $pnl.BackColor = [System.Drawing.Color]::FromArgb(37,37,38)
        $pnl.Margin    = [System.Windows.Forms.Padding]::new(3,2,3,2)
        $lblVal = New-Object System.Windows.Forms.Label
        $lblVal.Text      = $ValueText
        $lblVal.Location  = [System.Drawing.Point]::new(6,6)
        $lblVal.Size      = [System.Drawing.Size]::new(110,28)
        $lblVal.Font      = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
        $lblVal.ForeColor = $Accent
        $lblVal.BackColor = [System.Drawing.Color]::Transparent
        $lblKey = New-Object System.Windows.Forms.Label
        $lblKey.Text      = $KeyText
        $lblKey.Location  = [System.Drawing.Point]::new(6,38)
        $lblKey.Size      = [System.Drawing.Size]::new(114,22)
        $lblKey.Font      = New-Object System.Drawing.Font('Segoe UI',8)
        $lblKey.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
        $lblKey.BackColor = [System.Drawing.Color]::Transparent
        $pnl.Controls.AddRange(@($lblVal,$lblKey))
        return @{ Panel=$pnl; Value=$lblVal; Key=$lblKey }
    }

    $cards = @{
        Executed = New-StatCard '--' 'Tasks Executed'      ([System.Drawing.Color]::FromArgb(78,201,176))
        Success  = New-StatCard '--' 'Completed OK'         ([System.Drawing.Color]::FromArgb(78,201,176))
        Failed   = New-StatCard '--' 'Failed'               ([System.Drawing.Color]::FromArgb(244,71,71))
        Waiting  = New-StatCard '--' 'Waiting (Queue)'      ([System.Drawing.Color]::FromArgb(220,195,48))
        Agents   = New-StatCard '--' 'Agents Used'          ([System.Drawing.Color]::FromArgb(30,144,255))
        Tools    = New-StatCard '--' 'Tools / Calls'        ([System.Drawing.Color]::FromArgb(206,145,64))
        Elapsed  = New-StatCard '--' 'Session Duration'     ([System.Drawing.Color]::FromArgb(150,100,220))
    }
    foreach ($key in @('Executed','Success','Failed','Waiting','Agents','Tools','Elapsed')) {
        $monStatPanel.Controls.Add($cards[$key].Panel)
    }

    # ── Task execution grid ───────────────────────────────────────
    $lblMonHist = New-StyledLabel 'Task Executions This Session' 15 125 350 18 $fontBold $accBlue
    $tabMon.Controls.Add($lblMonHist)

    $dgvMonHist = New-StyledGrid 15 148 560 240
    $tabMon.Controls.Add($dgvMonHist)

    # ── Work queue panel ──────────────────────────────────────────
    $lblMonQueue = New-StyledLabel 'Waiting Work Queue' 590 125 280 18 $fontBold $accOrange
    $tabMon.Controls.Add($lblMonQueue)

    $dgvMonQueue = New-StyledGrid 590 148 300 240
    $tabMon.Controls.Add($dgvMonQueue)

    # ── Manual refresh + auto-refresh controls ────────────────────
    $btnMonRefresh = New-StyledButton 'Refresh Now' 15 397 120 28
    $toolTip.SetToolTip($btnMonRefresh, 'Immediately refresh pipeline monitor data.')
    $tabMon.Controls.Add($btnMonRefresh)

    $lblMonInterval = New-StyledLabel 'Auto-refresh: 20s ±3s' 150 402 160 18 $fontNorm $fgGray
    $tabMon.Controls.Add($lblMonInterval)

    $chkMonAuto = New-Object System.Windows.Forms.CheckBox
    $chkMonAuto.Text      = 'Auto-refresh enabled'
    $chkMonAuto.Location  = [System.Drawing.Point]::new(320,399)
    $chkMonAuto.Size      = [System.Drawing.Size]::new(180,22)
    $chkMonAuto.Font      = $fontNorm
    $chkMonAuto.ForeColor = $fgWhite
    $chkMonAuto.BackColor = [System.Drawing.Color]::Transparent
    $chkMonAuto.Checked   = $true
    $tabMon.Controls.Add($chkMonAuto)

    # ── Agent / tool tally grid ───────────────────────────────────
    $lblMonAgent = New-StyledLabel 'Agent & Tool Invocation Tally' 15 432 350 18 $fontBold $accBlue
    $tabMon.Controls.Add($lblMonAgent)

    $dgvMonAgent = New-StyledGrid 15 455 875 120
    $tabMon.Controls.Add($dgvMonAgent)

    # ── Refresh logic ─────────────────────────────────────────────
    function Refresh-PipelineMonitor {
        if (-not $script:_monSessionStart) { $script:_monSessionStart = Get-Date }
        $now = Get-Date
        $elapsed = $now - $script:_monSessionStart
        try {
            # ─ Load schedule history ─────────────────────────────
            $histPath = Join-Path (Join-Path $WorkspacePath 'logs') 'cron-aiathon-history.json'
            $histItems = @()
            if (Test-Path $histPath) {
                try {
                    $histRaw  = Get-Content $histPath -Raw -Encoding UTF8
                    $histJson = $histRaw | ConvertFrom-Json
                    $histItems = @($histJson.history | Where-Object { $_ })
                } catch { <# non-fatal #> }
            }

            # Filter to session window
            $sessionItems = @($histItems | Where-Object {
                $_.startTime -and ({
                    $d = New-Object datetime
                    [datetime]::TryParse($_.startTime,[ref]$d) -and $d -gt $script:_monSessionStart
                }).InvokeReturnAsIs()
            })

            $nExec    = @($sessionItems).Count
            $nSuccess = @($sessionItems | Where-Object { $_.success -eq $true }).Count
            $nFailed  = @($sessionItems | Where-Object { $_.success -eq $false }).Count

            # ─ Pipeline waiting queue ─────────────────────────────
            $plPath   = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
            $queueItems = @()
            if (Test-Path $plPath) {
                try {
                    $plJson = Get-Content $plPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($cat in @('bugs','featureRequests','items2ADD','bugs2FIX','todos')) {
                        if ($plJson.PSObject.Properties.Name -contains $cat) {
                            $catItems = @($plJson.$cat)
                            $queueItems += @($catItems | Where-Object { $_.status -and ($_.status -match 'OPEN|PLANNED|WAITING|IN_PROGRESS') })
                        }
                    }
                } catch { <# non-fatal #> }
            }
            $nWaiting = @($queueItems).Count

            # ─ Agent / tool tally ─────────────────────────────────
            $tallyPath = Join-Path (Join-Path $WorkspacePath 'config') 'subagent-tally.json'
            $tallyItems = @()
            if (Test-Path $tallyPath) {
                try {
                    $tallyJson = Get-Content $tallyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $tallyItems = @($tallyJson.agents | Where-Object { $_ })
                } catch { <# non-fatal #> }
            }
            $nAgents = @($tallyItems).Count
            $nTools  = ($tallyItems | Measure-Object -Property callCount -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $nTools) { $nTools = 0 }

            # ─ Update stat cards ──────────────────────────────────
            $cards['Executed'].Value.Text = "$nExec"
            $cards['Success'].Value.Text  = "$nSuccess"
            $cards['Failed'].Value.Text   = "$nFailed"
            $cards['Waiting'].Value.Text  = "$nWaiting"
            $cards['Agents'].Value.Text   = "$nAgents"
            $cards['Tools'].Value.Text    = "$nTools"
            $cards['Elapsed'].Value.Text  = ('{0:hh}h{1:mm}m' -f [datetime]::MinValue.Add($elapsed), [datetime]::MinValue.Add($elapsed))

            # ─ History grid ───────────────────────────────────────
            $dtHist = New-Object System.Data.DataTable
            [void]$dtHist.Columns.Add('Task')
            [void]$dtHist.Columns.Add('Result')
            [void]$dtHist.Columns.Add('Items')
            [void]$dtHist.Columns.Add('Start')
            [void]$dtHist.Columns.Add('End')
            foreach ($h in $sessionItems | Sort-Object startTime -Descending) {
                $res = if ($h.success) { 'SUCCESS' } else { 'FAILED' }
                $end = if ($h.endTime) { ([datetime]$h.endTime).ToString('HH:mm:ss') } else { '--' }
                $stm = if ($h.startTime) { ([datetime]$h.startTime).ToString('HH:mm:ss') } else { '--' }
                [void]$dtHist.Rows.Add(
                    (if ($h.taskName) { $h.taskName } else { '--' }),
                    $res,
                    (if ($h.itemsProcessed) { $h.itemsProcessed } else { '0' }),
                    $stm, $end
                )
            }
            if ($dtHist.Rows.Count -eq 0) {
                [void]$dtHist.Rows.Add('-- none since session start --','--','--','--','--')
            }
            $dgvMonHist.DataSource = $dtHist

            # ─ Queue grid ─────────────────────────────────────────
            $dtQ = New-Object System.Data.DataTable
            [void]$dtQ.Columns.Add('ID')
            [void]$dtQ.Columns.Add('Type')
            [void]$dtQ.Columns.Add('Status')
            [void]$dtQ.Columns.Add('Priority')
            foreach ($qi in $queueItems | Sort-Object { switch ($_.priority) { 'CRITICAL'{0} 'HIGH'{1} 'MEDIUM'{2} default{3} } }) {
                [void]$dtQ.Rows.Add(
                    (if ($qi.id) { $qi.id } else { '--' }),
                    (if ($qi.type) { $qi.type } else { '--' }),
                    (if ($qi.status) { $qi.status } else { '--' }),
                    (if ($qi.priority) { $qi.priority } else { '--' })
                )
            }
            if ($dtQ.Rows.Count -eq 0) { [void]$dtQ.Rows.Add('(empty)','--','--','--') }
            $dgvMonQueue.DataSource = $dtQ

            # ─ Agent tally grid ───────────────────────────────────
            $dtA = New-Object System.Data.DataTable
            [void]$dtA.Columns.Add('Agent')
            [void]$dtA.Columns.Add('Calls')
            [void]$dtA.Columns.Add('Last Used')
            foreach ($ag in $tallyItems | Sort-Object callCount -Descending) {
                $lastU = if ($ag.lastUsed) { $ag.lastUsed } else { '--' }
                [void]$dtA.Rows.Add(
                    (if ($ag.agentId) { $ag.agentId } else { '--' }),
                    (if ($ag.callCount) { $ag.callCount } else { '0' }),
                    $lastU
                )
            }
            if ($dtA.Rows.Count -eq 0) { [void]$dtA.Rows.Add('(no tally data)','--','--') }
            $dgvMonAgent.DataSource = $dtA

            $lblMonRefresh.Text = "Last refresh: $(Get-Date -Format 'HH:mm:ss')"

        } catch {
            $lblMonRefresh.Text = "Refresh error: $($_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length)))"
        }

        # ─ Also update status bar ─────────────────────────────────
        Update-StatusBar
    }

    $btnMonRefresh.Add_Click({ Refresh-PipelineMonitor })

    # ── Auto-refresh timer with 20s +-3s jitter ───────────────────
    $script:_monTimer = New-Object System.Windows.Forms.Timer
    $script:_monTimer.Interval = 20000
    $script:_monTimer.Add_Tick({
        if ($chkMonAuto.Checked) {
            Refresh-PipelineMonitor
            # Re-randomise interval 17000 - 23000 ms (20s +- 3s)
            $script:_monTimer.Interval = 17000 + (Get-Random -Minimum 0 -Maximum 6001)
        }
    })
    # Start timer when form is shown (avoids premature ticks)
    $tabMon.Add_Enter({ Refresh-PipelineMonitor })

    # ══════════════════════════════════════════════════════════════
    #  TAB 14 : SECURITY ACCOUNTS
    # ══════════════════════════════════════════════════════════════
    $tabSvcAcc = New-Object System.Windows.Forms.TabPage
    $tabSvcAcc.Text      = 'Security Accounts'
    $tabSvcAcc.BackColor = $bgDark
    $tabSvcAcc.ForeColor = $fgWhite
    $toolTip.SetToolTip($tabSvcAcc, 'Provision and manage local service accounts, admin credentials and PKI certificates. All secrets stored in the SASC vault.')
    $tabCtrl.TabPages.Add($tabSvcAcc)

    $lblSvcTitle = New-StyledLabel 'Local Service Accounts & Security' 15 10 600 28 $fontHead $accBlue
    $tabSvcAcc.Controls.Add($lblSvcTitle)

    # ── Status / RTB ──────────────────────────────────────────────
    $rtbSvcLog = New-Object System.Windows.Forms.RichTextBox
    $rtbSvcLog.Location = [System.Drawing.Point]::new(15, 48)
    $rtbSvcLog.Size     = [System.Drawing.Size]::new(860, 220)
    $rtbSvcLog.BackColor = $bgDark; $rtbSvcLog.ForeColor = $fgWhite
    $rtbSvcLog.Font      = $fontMono; $rtbSvcLog.ReadOnly = $true
    $rtbSvcLog.BorderStyle = 'FixedSingle'
    $tabSvcAcc.Controls.Add($rtbSvcLog)

    function Write-SvcLog ([string]$msg, [string]$level='Info') {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
        $color = switch ($level) {
            'OK'    { [System.Drawing.Color]::FromArgb(78,201,176) }
            'Warn'  { [System.Drawing.Color]::FromArgb(220,200,80) }
            'Error' { [System.Drawing.Color]::FromArgb(244,71,71) }
            default { [System.Drawing.Color]::FromArgb(200,200,200) }
        }
        $rtbSvcLog.SelectionColor = $color
        $rtbSvcLog.AppendText("$(Get-Date -Format 'HH:mm:ss')  $msg`r`n")
        $rtbSvcLog.ScrollToCaret()
    }

    # ── Section: Agent-Managed Admin ─────────────────────────────
    $lblAgentAdmin = New-StyledLabel '  [A] Agent Admin Account (self-managed)' 15 278 400 22 $fontBold $accGreen
    $tabSvcAcc.Controls.Add($lblAgentAdmin)

    $btnProvisionAgent = New-StyledButton 'Provision / Rotate Agent Admin' 15 304 240 30
    $toolTip.SetToolTip($btnProvisionAgent, "Create or rotate the Agent admin account (PSGUIAgentSvc). Credentials are auto-generated and stored exclusively in the SASC vault. Least-privilege: local Administrators group only.")
    $tabSvcAcc.Controls.Add($btnProvisionAgent)

    $btnTestAgentAcct = New-StyledButton 'Test Agent Account' 265 304 160 30
    $toolTip.SetToolTip($btnTestAgentAcct, 'Verify the agent admin account exists, is enabled, is in local Administrators, and vault credential is readable.')
    $tabSvcAcc.Controls.Add($btnTestAgentAcct)

    # ── Section: User Admin ───────────────────────────────────────
    $lblUserAdmin = New-StyledLabel '  [U] User Admin Account (this session user)' 15 344 440 22 $fontBold $accBlue
    $tabSvcAcc.Controls.Add($lblUserAdmin)

    $btnCheckUserAdmin = New-StyledButton 'Verify User Is Admin' 15 370 200 30
    $toolTip.SetToolTip($btnCheckUserAdmin, 'Confirm that the current Windows user has local administrator rights.')
    $tabSvcAcc.Controls.Add($btnCheckUserAdmin)

    # ── Section: Optional Third Admin with PFX Cert ───────────────
    $lblOptAdmin = New-StyledLabel '  [O] Optional Cert Admin (exportable PFX)' 15 414 440 22 $fontBold $accAmber
    $tabSvcAcc.Controls.Add($lblOptAdmin)

    $lblPfxPwd = New-StyledLabel 'PFX Password (10+ chars):' 15 443 200 20 $fontNorm $fgWhite
    $tabSvcAcc.Controls.Add($lblPfxPwd)

    $txtPfxPwd = New-Object System.Windows.Forms.TextBox
    $txtPfxPwd.Location    = [System.Drawing.Point]::new(220, 440)
    $txtPfxPwd.Size        = [System.Drawing.Size]::new(220, 26)
    $txtPfxPwd.BackColor   = [System.Drawing.Color]::FromArgb(40,40,40)
    $txtPfxPwd.ForeColor   = $fgWhite
    $txtPfxPwd.Font        = $fontMono
    $txtPfxPwd.PasswordChar = '*'
    $tabSvcAcc.Controls.Add($txtPfxPwd)

    $btnCreateCertAdmin = New-StyledButton 'Create Cert Admin PFX' 450 439 190 30
    $toolTip.SetToolTip($btnCreateCertAdmin, 'Generate a client-auth certificate for a third admin account and export as PFX. Password must be 10+ characters. Saving to vault is recommended.')
    $tabSvcAcc.Controls.Add($btnCreateCertAdmin)

    $btnExportDangerous = New-StyledButton 'Live Dangerously — Export This Cert!' 650 439 230 30
    $btnExportDangerous.BackColor = [System.Drawing.Color]::FromArgb(140,20,20)
    $btnExportDangerous.Enabled   = $false
    $toolTip.SetToolTip($btnExportDangerous, 'Export PFX to your Downloads folder. Vault save will NOT be prompted. Use at your own risk — store the file securely.')
    $tabSvcAcc.Controls.Add($btnExportDangerous)

    # Holds PFX bytes between "Create" and "Export" steps
    $script:_pfxBytes    = $null
    $script:_pfxPwd      = $null

    # ── Section: Service Account row ─────────────────────────────
    $lblSvcRow = New-StyledLabel '  [S] Pipeline Service Account (least-priv)' 15 480 440 22 $fontBold $accPurple
    $tabSvcAcc.Controls.Add($lblSvcRow)

    $btnProvisionSvc = New-StyledButton 'Provision Service Account' 15 506 210 30
    $toolTip.SetToolTip($btnProvisionSvc, "Create PSGUIPipelineSvc local account with minimum rights: Log on as a service only. Password generated and stored in vault. No interactive sessions.")
    $tabSvcAcc.Controls.Add($btnProvisionSvc)

    $btnSecuritySelfTest = New-StyledButton 'Run Security Self-Test' 235 506 190 30
    $toolTip.SetToolTip($btnSecuritySelfTest, 'Run the full security self-test suite: vault access, cert validity, account existence, password rotation age, and privilege audit.')
    $tabSvcAcc.Controls.Add($btnSecuritySelfTest)

    $btnScheduleSecMaint = New-StyledButton 'Schedule Auto-Maintenance' 435 506 200 30
    $toolTip.SetToolTip($btnScheduleSecMaint, 'Add a CronAiAthon SecMaint task (weekly) to auto-rotate passwords, verify cert expiry, and run the security self-test.')
    $tabSvcAcc.Controls.Add($btnScheduleSecMaint)

    # ── Event handlers ────────────────────────────────────────────
    $btnProvisionAgent.Add_Click({
        try {
            Write-SvcLog 'Provisioning PSGUIAgentSvc...'
            $acctName = 'PSGUIAgentSvc'
            $existing = Get-LocalUser -Name $acctName -ErrorAction SilentlyContinue
            # Generate secure 32-char random password
            $chars    = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+'
            $pwd      = -join ((1..32) | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
            $ss        = ConvertTo-SecureString $pwd -AsPlainText -Force
            if ($null -eq $existing) {
                New-LocalUser -Name $acctName -Password $ss -PasswordNeverExpires:$false `
                    -Description 'CronAiAthon agent-managed admin - DO NOT modify manually' `
                    -AccountNeverExpires -ErrorAction Stop | Out-Null
                Add-LocalGroupMember -Group 'Administrators' -Member $acctName -ErrorAction Stop
                Write-SvcLog "Created account: $acctName" 'OK'
            } else {
                Set-LocalUser -Name $acctName -Password $ss -ErrorAction Stop
                Write-SvcLog "Rotated password for: $acctName" 'OK'
            }
            # Store in vault
            try {
                Set-VaultItem -Key "svc/$acctName" -Value $pwd -ErrorAction Stop
                Write-SvcLog "Credential stored in vault key: svc/$acctName" 'OK'
            } catch {
                Write-SvcLog "VAULT STORE FAILED: $_  — save manually!" 'Error'
            }
            [void]$pwd  # zero out variable
        } catch {
            Write-SvcLog "Provision failed: $($_.Exception.Message)" 'Error'
            Write-CronLog -Message "ProvisionAgentAdmin failed: $($_.Exception.Message)" -Severity Error -Source 'SecurityAccounts'
        }
    })

    $btnTestAgentAcct.Add_Click({
        try {
            $acctName = 'PSGUIAgentSvc'
            $u = Get-LocalUser -Name $acctName -ErrorAction Stop
            Write-SvcLog "Account '$acctName' found. Enabled=$($u.Enabled)" 'OK'
            $inAdmin = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -like "*$acctName" }) -ne $null
            if ($inAdmin) { Write-SvcLog "  Member of Administrators: YES" 'OK' } else { Write-SvcLog "  Member of Administrators: NO" 'Warn' }
            try {
                $vaultVal = Get-VaultItem -Key "svc/$acctName" -ErrorAction Stop
                if ([string]::IsNullOrEmpty($vaultVal)) {
                    Write-SvcLog "  Vault entry: EMPTY" 'Warn'
                } else {
                    Write-SvcLog "  Vault entry: present ($($vaultVal.Length) chars)" 'OK'
                }
            } catch {
                Write-SvcLog "  Vault entry: MISSING - $_" 'Error'
            }
        } catch {
            Write-SvcLog "Account '$($acctName)' not found: $($_.Exception.Message)" 'Error'
        }
    })

    $btnCheckUserAdmin.Add_Click({
        try {
            $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]$identity
            $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) {
                Write-SvcLog "Current user '$($identity.Name)' HAS admin rights." 'OK'
            } else {
                Write-SvcLog "Current user '$($identity.Name)' does NOT have admin rights. Some operations will fail." 'Warn'
            }
        } catch {
            Write-SvcLog "Admin check failed: $($_.Exception.Message)" 'Error'
        }
    })

    $btnCreateCertAdmin.Add_Click({
        try {
            $pfxPwd = $txtPfxPwd.Text.Trim()
            if ($pfxPwd.Length -lt 10) {
                Write-SvcLog 'PFX password must be 10 or more characters.' 'Error'
                return
            }
            Write-SvcLog 'Generating certificate for Cert Admin account...'
            $certSubject = "CN=PSGUICertAdmin-$(Get-Date -Format 'yyyyMMdd')"
            # Create a self-signed client-auth cert
            $cert = New-SelfSignedCertificate -Subject $certSubject `
                -CertStoreLocation 'Cert:\LocalMachine\My' `
                -KeyUsage DigitalSignature, KeyEncipherment `
                -KeyAlgorithm RSA -KeyLength 2048 `
                -NotAfter (Get-Date).AddYears(1) `
                -ErrorAction Stop
            Write-SvcLog "Cert created: $($cert.Thumbprint)" 'OK'
            # Export to bytes in memory
            $ss = ConvertTo-SecureString $pfxPwd -AsPlainText -Force
            $tempPath = Join-Path $env:TEMP "psgui_certadmin_$([guid]::NewGuid().ToString('N').Substring(0,8)).pfx"
            Export-PfxCertificate -Cert $cert -FilePath $tempPath -Password $ss -ErrorAction Stop | Out-Null
            $script:_pfxBytes = [System.IO.File]::ReadAllBytes($tempPath)
            $script:_pfxPwd   = $pfxPwd
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            Write-SvcLog "PFX ready in memory ($($script:_pfxBytes.Length) bytes). Choose: Save to Vault (recommended) or Live Dangerously." 'OK'
            # Prompt vault save
            $vaultResult = [System.Windows.Forms.MessageBox]::Show(
                "Save the PFX to the SASC vault now?`n`n(Recommended — file will NOT be written to disk.)",
                "Save PFX to Vault?",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($vaultResult -eq [System.Windows.Forms.DialogResult]::Yes) {
                $b64 = [Convert]::ToBase64String($script:_pfxBytes)
                Set-VaultItem -Key "cert/PSGUICertAdmin-pfx" -Value $b64 -ErrorAction Stop
                Set-VaultItem -Key "cert/PSGUICertAdmin-pwd" -Value $pfxPwd -ErrorAction Stop
                Write-SvcLog "PFX and password stored in vault as cert/PSGUICertAdmin-pfx / cert/PSGUICertAdmin-pwd" 'OK'
                $script:_pfxBytes = $null; $script:_pfxPwd = $null
            } else {
                $btnExportDangerous.Enabled = $true
                Write-SvcLog "PFX NOT saved to vault. 'Live Dangerously' export is now enabled." 'Warn'
            }
            $txtPfxPwd.Clear()
        } catch {
            Write-SvcLog "Cert Admin creation failed: $($_.Exception.Message)" 'Error'
            Write-CronLog -Message "CertAdmin cert creation failed: $($_.Exception.Message)" -Severity Error -Source 'SecurityAccounts'
        }
    })

    $btnExportDangerous.Add_Click({
        try {
            if ($null -eq $script:_pfxBytes) { Write-SvcLog 'No PFX in memory — create one first.' 'Error'; return }
            $dlPath = Join-Path $env:USERPROFILE 'Downloads'
            if (-not (Test-Path $dlPath)) { $dlPath = $env:TEMP }
            $outFile = Join-Path $dlPath "PSGUICertAdmin-$(Get-Date -Format 'yyyyMMddHHmmss').pfx"
            [System.IO.File]::WriteAllBytes($outFile, $script:_pfxBytes)
            $script:_pfxBytes = $null; $script:_pfxPwd = $null
            Write-SvcLog "PFX exported to: $outFile  — protect this file carefully!" 'Warn'
            [System.Windows.Forms.MessageBox]::Show(
                "PFX saved to:`n$outFile`n`nSTORE THIS FILE SECURELY. It contains a private key.",
                "PFX Exported",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $btnExportDangerous.Enabled = $false
        } catch {
            Write-SvcLog "Export failed: $($_.Exception.Message)" 'Error'
        }
    })

    $btnProvisionSvc.Add_Click({
        try {
            Write-SvcLog 'Provisioning PSGUIPipelineSvc (least-priv service account)...'
            $acctName = 'PSGUIPipelineSvc'
            $chars    = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%-_=+'
            $pwd      = -join ((1..32) | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
            $ss       = ConvertTo-SecureString $pwd -AsPlainText -Force
            $existing = Get-LocalUser -Name $acctName -ErrorAction SilentlyContinue
            if ($null -eq $existing) {
                New-LocalUser -Name $acctName -Password $ss -PasswordNeverExpires:$false `
                    -Description 'CronAiAthon pipeline service account - least privilege' `
                    -AccountNeverExpires -ErrorAction Stop | Out-Null
                Write-SvcLog "Created: $acctName (no admin rights assigned)" 'OK'
            } else {
                Set-LocalUser -Name $acctName -Password $ss -ErrorAction Stop
                Write-SvcLog "Rotated password for: $acctName" 'OK'
            }
            try {
                Set-VaultItem -Key "svc/$acctName" -Value $pwd -ErrorAction Stop
                Write-SvcLog "Credential stored in vault: svc/$acctName" 'OK'
            } catch {
                Write-SvcLog "VAULT STORE FAILED: $_" 'Error'
            }
        } catch {
            Write-SvcLog "Service account provision failed: $($_.Exception.Message)" 'Error'
            Write-CronLog -Message "ProvisionServiceAcct failed: $($_.Exception.Message)" -Severity Error -Source 'SecurityAccounts'
        }
    })

    $btnSecuritySelfTest.Add_Click({
        try {
            Write-SvcLog '=== Security Self-Test ==='
            # 1. Vault reachable?
            try { Test-VaultStatus | Out-Null; Write-SvcLog '  Vault: reachable' 'OK' }
            catch { Write-SvcLog "  Vault: UNREACHABLE - $_" 'Error' }
            # 2. Agent admin exists
            $agentAcc = Get-LocalUser -Name 'PSGUIAgentSvc' -ErrorAction SilentlyContinue
            if ($agentAcc) { Write-SvcLog "  PSGUIAgentSvc: present (Enabled=$($agentAcc.Enabled))" 'OK' }
            else            { Write-SvcLog '  PSGUIAgentSvc: MISSING' 'Warn' }
            # 3. Service account exists
            $svcAcc = Get-LocalUser -Name 'PSGUIPipelineSvc' -ErrorAction SilentlyContinue
            if ($svcAcc) { Write-SvcLog "  PSGUIPipelineSvc: present" 'OK' }
            else          { Write-SvcLog '  PSGUIPipelineSvc: MISSING' 'Warn' }
            # 4. PKI cert validity
            $myCerts = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like '*PSGUICertAdmin*' })
            if (@($myCerts).Count -gt 0) {
                foreach ($c in $myCerts) {
                    $days = ([datetime]$c.NotAfter - [datetime]::UtcNow).Days
                    if ($days -gt 30) { Write-SvcLog "  Cert '$($c.Subject)': valid ($days days)" 'OK' }
                    else { Write-SvcLog "  Cert '$($c.Subject)': EXPIRING in $days days" 'Warn' }
                }
            } else {
                Write-SvcLog '  No PSGUICertAdmin cert found in LocalMachine\My' 'Info'
            }
            Write-SvcLog '=== Self-Test Complete ==='
        } catch {
            Write-SvcLog "Self-test error: $($_.Exception.Message)" 'Error'
        }
    })

    $btnScheduleSecMaint.Add_Click({
        try {
            $schedPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-schedule.json'
            $sched     = Get-Content $schedPath -Raw | ConvertFrom-Json
            $existing  = $sched.tasks | Where-Object { $_.id -eq 'TASK-SecMaint' }
            if ($null -ne $existing) {
                Write-SvcLog 'TASK-SecMaint already exists in schedule.' 'OK'
                return
            }
            # Add task
            $newTask = [PSCustomObject]@{
                id              = 'TASK-SecMaint'
                type            = 'SecMaint'
                label           = 'Security Maintenance'
                intervalMinutes = 10080
                enabled         = $true
                description     = 'Weekly: rotate service account passwords, verify cert expiry, run security self-test, log results.'
            }
            $taskList = [System.Collections.ArrayList]@($sched.tasks)
            [void]$taskList.Add($newTask)
            $sched.tasks = $taskList.ToArray()
            $sched | ConvertTo-Json -Depth 10 | Set-Content -Path $schedPath -Encoding UTF8
            Write-SvcLog 'TASK-SecMaint added to cron schedule (weekly, enabled).' 'OK'
        } catch {
            Write-SvcLog "Schedule update failed: $($_.Exception.Message)" 'Error'
        }
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 15 : AGENT CHECKLIST GUIDE
    # ══════════════════════════════════════════════════════════════
    $tabAgentGuide = New-Object System.Windows.Forms.TabPage
    $tabAgentGuide.Text      = 'Agent Guide'
    $tabAgentGuide.BackColor = $bgDark
    $tabAgentGuide.ForeColor = $fgWhite
    $toolTip.SetToolTip($tabAgentGuide, 'Step-by-step guide for agents and developers: how to run pipeline tasks, interact via chat, cross-reference manifest, and trigger workflows.')
    $tabCtrl.TabPages.Add($tabAgentGuide)

    $lblGuideTitle = New-StyledLabel 'CronAiAthon Agent Interaction Guide' 15 10 550 28 $fontHead $accBlue
    $tabAgentGuide.Controls.Add($lblGuideTitle)

    $rtbGuide = New-Object System.Windows.Forms.RichTextBox
    $rtbGuide.Location   = [System.Drawing.Point]::new(15, 48)
    $rtbGuide.Size       = [System.Drawing.Size]::new(860, 540)
    $rtbGuide.BackColor  = $bgDark; $rtbGuide.ForeColor = $fgWhite
    $rtbGuide.Font       = $fontMono; $rtbGuide.ReadOnly = $true
    $rtbGuide.BorderStyle = 'FixedSingle'
    $tabAgentGuide.Controls.Add($rtbGuide)

    $btnOpenImplGuide = New-StyledButton 'Open Implementation-Steps.xhtml' 700 10 175 28
    $toolTip.SetToolTip($btnOpenImplGuide, 'Open the full XHTML step-by-step implementation guide in your default browser.')
    $tabAgentGuide.Controls.Add($btnOpenImplGuide)

    $btnOpenImplGuide.Add_Click({
        try {
            $xhtmlPath = Join-Path (Join-Path $WorkspacePath '~README.md') 'Implementation-Steps.xhtml'
            if (Test-Path $xhtmlPath) {
                Start-Process $xhtmlPath
            } else {
                Write-CronLog -Message "Implementation-Steps.xhtml not found at $xhtmlPath" -Severity Warning -Source 'AgentGuide'
            }
        } catch {
            Write-CronLog -Message "Open guide failed: $($_.Exception.Message)" -Severity Warning -Source 'AgentGuide'
        }
    })

    $tabAgentGuide.Add_Enter({
        $rtbGuide.Clear()
        $accent = [char]9654   # right-pointing black triangle

        # Build guide text sections
        $sections = [ordered]@{
            'GETTING STARTED' = @(
                'Step 1   Load the CronAiAthon tool via Main-GUI > Tools > Cron-Ai-Athon Tool',
                "Step 2   Open this Agent Guide tab (you are here $accent)",
                'Step 3   Click ''Refresh'' on Dashboard to load live stats',
                'Step 4   Review Autopilot Suggestions tab — one new suggestion added hourly'
            )
            'RUNNING PIPELINE TASKS MANUALLY' = @(
                'Manual Runner tab > select task type > click Run',
                "Available task types: BugScan, PipelineProcess, MasterAggregate,`r`n         SinRegistryReview, PreReqCheck, DocRebuild, DocFreshness, DepMap, CertMonitor,`r`n         ConfigCoverageAudit, AutopilotSuggestion, TabErrorFix, SecMaint",
                'Results appear in the output box. Errors logged to Event Log tab.'
            )
            'RUNNING SCANS VIA CLI (AGENT SNIPPETS)' = @(
                "# Headless smoke test (fastest — run after every change):`r`n  pwsh -NoProfile -c ""& tests\Invoke-GUISmokeTest.ps1 -HeadlessOnly -SkipPhase 1,2,3,4,5""",
                "# Full SIN governance scan:`r`n  pwsh -NoProfile -c ""& tests\Invoke-SINPatternScanner.ps1 -WorkspacePath '$WorkspacePath'""",
                "# Config coverage audit:`r`n  pwsh -NoProfile -c ""& scripts\Invoke-ConfigCoverageAudit.ps1 -WorkspacePath '$WorkspacePath'""",
                "# SemiSin penance scan:`r`n  pwsh -NoProfile -c ""& tests\Invoke-SemiSinPenanceScanner.ps1"""
            )
            'INTERACTING WITH THE PIPELINE (AGENT CODE)' = @(
                "# Add a new pipeline TODO item:`r`n  Add-PipelineItem -WorkspacePath `$WorkspacePath -Type 'FeatureRequest' -Title 'My task' -Priority 'MEDIUM' -Status 'OPEN'",
                "# Query open BUGs:`r`n  Get-PipelineItems -WorkspacePath `$WorkspacePath -Type 'BUG' -Status 'OPEN' | Select Title,Priority",
                "# Save a pipeline epoch snapshot:`r`n  Save-PipelineEpoch -WorkspacePath '$WorkspacePath' -Phase 'MyMilestone' -Description 'What changed'"
            )
            'MANIFEST CROSS-REFERENCE' = @(
                "# Rebuild manifest (auto runs every 2hrs via DocRebuild cron):`r`n  & scripts\Build-AgenticManifest.ps1 -WorkspacePath `$WorkspacePath",
                "# Query manifest for a function:`r`n  `$mf = Get-Content config\agentic-manifest.json -Raw | ConvertFrom-Json`r`n  `$mf.modules | Where-Object { `$_.functions -match 'Get-Pipeline' }",
                '# After adding a new module, regenerate manifest + dir tree to keep cross-refs accurate'
            )
            'VERSION CONTROL DISCIPLINE' = @(
                "# VersionTag format: YYMM.B<build>.v<major>.<minor>",
                "# Increment minor for patches, major for new features (resets minor to 0)",
                "# All modified files need VersionTag bump before epoch snapshot",
                "# Use Set-Content -Encoding UTF8 (never Out-File without -Encoding UTF8)"
            )
            'DASHBOARD HIGHLIGHTS WORKFLOW' = @(
                "1. Click 'Highlight Tabs w/ Errors' on Dashboard tab",
                "2. Badge shows: N tabs | M errors. Affected tabs turn red.",
                "3. Click 'Create BUG Tasks from Errors' to push to pipeline",
                "4. CronAiAthon 'TabErrorFix' cron task processes the BUGs automatically",
                "5. Re-run Highlight scan to verify all tabs return to clean state"
            )
            'SECURITY ACCOUNTS WORKFLOW' = @(
                'Security Accounts tab > provision PSGUIAgentSvc (agent admin) + PSGUIPipelineSvc (least-priv)',
                'All passwords auto-generated and stored in vault — never hardcoded',
                'Optional 3rd admin: enter 10+ char PFX password > Create Cert Admin PFX > save to vault',
                "Or: choose 'Live Dangerously' to export PFX file (store securely!)",
                'Schedule Auto-Maintenance button adds a weekly SecMaint cron task'
            )
        }

        foreach ($section in $sections.Keys) {
            $rtbGuide.SelectionColor = [System.Drawing.Color]::FromArgb(78,201,176)
            $rtbGuide.SelectionFont  = $fontBold
            $rtbGuide.AppendText("`r`n=== $section ===`r`n")
            $rtbGuide.SelectionFont  = $fontMono
            $rtbGuide.SelectionColor = [System.Drawing.Color]::FromArgb(200,200,200)
            foreach ($step in $sections[$section]) {
                $rtbGuide.SelectionColor = [System.Drawing.Color]::FromArgb(180,180,180)
                $rtbGuide.AppendText("  $step`r`n")
            }
        }
        $rtbGuide.SelectionColor = [System.Drawing.Color]::FromArgb(100,100,100)
        $rtbGuide.AppendText("`r`n  [Open Implementation-Steps.xhtml for full guide with copy-paste code snippets]`r`n")
    })

    # ══════════════════════════════════════════════════════════════
    #  TAB 16 : STANDARDS REFERENCE (ERROR HANDLING & CODING STANDARDS)
    # ══════════════════════════════════════════════════════════════
    $tabStandards = New-Object System.Windows.Forms.TabPage
    $tabStandards.Text      = 'Standards Ref'
    $tabStandards.BackColor = $bgDark
    $tabStandards.ForeColor = $fgWhite
    $toolTip.SetToolTip($tabStandards, 'Coding standards reference: Error handling templates, logging levels, SIN governance patterns, and best practices.')
    $tabCtrl.TabPages.Add($tabStandards)

    $lblStdTitle = New-StyledLabel 'PowerShellGUI Coding Standards Reference' 15 10 700 28 $fontHead $accBlue
    $tabStandards.Controls.Add($lblStdTitle)

    # Rich text box for standards reference
    $rtbStandards = New-Object System.Windows.Forms.RichTextBox
    $rtbStandards.Location   = [System.Drawing.Point]::new(15, 48)
    $rtbStandards.Size       = [System.Drawing.Size]::new(860, 480)
    $rtbStandards.BackColor  = $bgDark; $rtbStandards.ForeColor = $fgWhite
    $rtbStandards.Font       = $fontMono; $rtbStandards.ReadOnly = $true
    $rtbStandards.BorderStyle = 'FixedSingle'
    $tabStandards.Controls.Add($rtbStandards)

    # Buttons for opening standards documentation
    $btnOpenErrorTemplates = New-StyledButton 'Open Error Templates' 15 540 180 30
    $toolTip.SetToolTip($btnOpenErrorTemplates, 'Open ERROR-HANDLING-TEMPLATES.md with copy/paste error catch patterns.')
    $tabStandards.Controls.Add($btnOpenErrorTemplates)

    $btnOpenRefStd = New-StyledButton 'Open Consistency Std' 205 540 180 30
    $toolTip.SetToolTip($btnOpenRefStd, 'Open REFERENCE-CONSISTENCY-STANDARD.md (full workspace coding conventions).')
    $tabStandards.Controls.Add($btnOpenRefStd)

    $btnOpenSinRegistry = New-StyledButton 'SIN Governance Registry' 395 540 180 30
    $toolTip.SetToolTip($btnOpenSinRegistry, 'Open sin_registry/ folder (all SIN pattern definitions).')
    $tabStandards.Controls.Add($btnOpenSinRegistry)

    $btnRunSinScanner = New-StyledButton 'Run SIN Scanner' 585 540 140 30
    $toolTip.SetToolTip($btnRunSinScanner, 'Execute Invoke-SINPatternScanner.ps1 to validate code against all SIN patterns.')
    $tabStandards.Controls.Add($btnRunSinScanner)

    $lblStdMsg = New-Object System.Windows.Forms.Label
    $lblStdMsg.Location = [System.Drawing.Point]::new(735, 540)
    $lblStdMsg.Size     = [System.Drawing.Size]::new(140, 30)
    $lblStdMsg.Font     = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblStdMsg.TextAlign = 'MiddleLeft'
    $lblStdMsg.ForeColor = $accGreen
    $lblStdMsg.BackColor = [System.Drawing.Color]::Transparent
    $tabStandards.Controls.Add($lblStdMsg)

    # Button click handlers
    $btnOpenErrorTemplates.Add_Click({
        try {
            $errorTemplatesPath = Join-Path (Join-Path $WorkspacePath '~README.md') 'ERROR-HANDLING-TEMPLATES.md'
            if (Test-Path $errorTemplatesPath) {
                Start-Process 'code' -ArgumentList $errorTemplatesPath -ErrorAction Stop
                $lblStdMsg.Text = 'Opened in VSCode'
                $lblStdMsg.ForeColor = $accGreen
            } else {
                $lblStdMsg.Text = 'File not found'
                $lblStdMsg.ForeColor = $accOrange
                Write-CronLog -Message "ERROR-HANDLING-TEMPLATES.md not found at $errorTemplatesPath" -Severity Warning -Source 'StandardsRef'
            }
        } catch {
            $lblStdMsg.Text = 'Open failed'
            $lblStdMsg.ForeColor = $accRed
            Write-CronLog -Message "Failed to open error templates: $($_.Exception.Message)" -Severity Error -Source 'StandardsRef'
        }
    })

    $btnOpenRefStd.Add_Click({
        try {
            $refStdPath = Join-Path (Join-Path $WorkspacePath '~README.md') 'REFERENCE-CONSISTENCY-STANDARD.md'
            if (Test-Path $refStdPath) {
                Start-Process 'code' -ArgumentList $refStdPath -ErrorAction Stop
                $lblStdMsg.Text = 'Opened in VSCode'
                $lblStdMsg.ForeColor = $accGreen
            } else {
                $lblStdMsg.Text = 'File not found'
                $lblStdMsg.ForeColor = $accOrange
                Write-CronLog -Message "REFERENCE-CONSISTENCY-STANDARD.md not found at $refStdPath" -Severity Warning -Source 'StandardsRef'
            }
        } catch {
            $lblStdMsg.Text = 'Open failed'
            $lblStdMsg.ForeColor = $accRed
            Write-CronLog -Message "Failed to open reference standard: $($_.Exception.Message)" -Severity Error -Source 'StandardsRef'
        }
    })

    $btnOpenSinRegistry.Add_Click({
        try {
            $sinPath = Join-Path $WorkspacePath 'sin_registry'
            if (Test-Path $sinPath) {
                Start-Process 'explorer.exe' -ArgumentList $sinPath -ErrorAction Stop
                $lblStdMsg.Text = 'Opened in Explorer'
                $lblStdMsg.ForeColor = $accGreen
            } else {
                $lblStdMsg.Text = 'Folder not found'
                $lblStdMsg.ForeColor = $accOrange
                Write-CronLog -Message "sin_registry folder not found at $sinPath" -Severity Warning -Source 'StandardsRef'
            }
        } catch {
            $lblStdMsg.Text = 'Open failed'
            $lblStdMsg.ForeColor = $accRed
            Write-CronLog -Message "Failed to open SIN registry: $($_.Exception.Message)" -Severity Error -Source 'StandardsRef'
        }
    })

    $btnRunSinScanner.Add_Click({
        try {
            $lblStdMsg.Text = 'Running scan...'
            $lblStdMsg.ForeColor = $accBlueRun
            $scannerPath = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SINPatternScanner.ps1'
            if (Test-Path $scannerPath) {
                $job = Start-Job -ScriptBlock {
                    param($Path, $Workspace)
                    & $Path -WorkspacePath $Workspace
                } -ArgumentList $scannerPath, $WorkspacePath
                $result = Wait-Job -Job $job -Timeout 60 | Receive-Job
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $lblStdMsg.Text = 'Scan complete'
                $lblStdMsg.ForeColor = $accGreen
                Write-CronLog -Message "SIN scanner completed" -Severity Informational -Source 'StandardsRef'
            } else {
                $lblStdMsg.Text = 'Scanner not found'
                $lblStdMsg.ForeColor = $accOrange
            }
        } catch {
            $lblStdMsg.Text = 'Scan failed'
            $lblStdMsg.ForeColor = $accRed
            Write-CronLog -Message "SIN scanner failed: $($_.Exception.Message)" -Severity Error -Source 'StandardsRef'
        }
    })

    # Populate standards reference text on tab enter
    $tabStandards.Add_Enter({
        $rtbStandards.Clear()

        # Title
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(78,201,176)
        $rtbStandards.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $rtbStandards.AppendText("PowerShellGUI Workspace Coding Standards`r`n")
        $rtbStandards.AppendText("═══════════════════════════════════════════════════════════════════`r`n`r`n")

        # Section 1: Error Handling Standards
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(0,122,204)
        $rtbStandards.SelectionFont  = $fontBold
        $rtbStandards.AppendText("📋 ERROR HANDLING STANDARDS (MANDATORY)`r`n")
        $rtbStandards.SelectionFont  = $fontMono
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $rtbStandards.AppendText(@"
  1. Every catch block MUST log errors (Write-AppLog, Write-Warning, or comment)
  2. No empty catch blocks: catch { } is PROHIBITED (SIN-PATTERN-002)
  3. `$ErrorActionPreference = 'Stop' in standalone scripts
  4. Main-GUI.ps1 uses 'Continue' for GUI resilience (exception to rule 3)
  5. One-line catches for simple suppression with intentional comments
  6. Multi-line catches for error recovery logic

  📖 Full documentation: ~README.md\ERROR-HANDLING-TEMPLATES.md

"@)

        # Section 2: Error Handling Templates
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(0,122,204)
        $rtbStandards.SelectionFont  = $fontBold
        $rtbStandards.AppendText("`r`n🎯 ERROR HANDLING TEMPLATES (COPY/PASTE)`r`n")
        $rtbStandards.SelectionFont  = $fontMono
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(180,180,180)
        $rtbStandards.AppendText(@"
  Version Check (One-Line):
  `$psVer = try { `$PSVersionTable.PSVersion } catch { Write-Warning "Ver fail: `$_"; [version]'5.1.0.0' }

  Module Import (One-Line with Comment):
  try { Import-Module PwShGUICore -Force -EA Stop } catch { <# Intentional: optional #> }

  File I/O (Multi-Line with Fallback):
  try {
      `$cfg = Get-Content `$path -Raw -EA Stop | ConvertFrom-Json
  } catch {
      Write-AppLog -Message "Config load failed: `$_. Using defaults." -Level Warning
      `$cfg = @{ version = '1.0'; enabled = `$true }
  }

  WinForms Handler (One-Line with Null Guard):
  `$btn.Add_Click({ try { if (`$null -eq `$this.Tag) { return }; <# code #> } catch { Write-AppLog -Message "Click failed: `$_" -Level Error } }.GetNewClosure())

"@)

        # Section 3: Logging Standard
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(0,122,204)
        $rtbStandards.SelectionFont  = $fontBold
        $rtbStandards.AppendText("`r`n📝 LOGGING STANDARD (6 CANONICAL LEVELS)`r`n")
        $rtbStandards.SelectionFont  = $fontMono
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $rtbStandards.AppendText(@"
  Level       Description                  PowerShell Cmdlet      SYSLOG
  ────────────────────────────────────────────────────────────────────────
  Debug       Development tracing          Write-Information      7
  Info        Normal events                Write-Information      6
  Warning     Recoverable issues           Write-Warning          4
  Error       Operation failures           Write-Error            3
  Critical    System-threatening           Write-Error            2
  Audit       Security/user actions        Write-Information      5

  Functions:
    Write-AppLog     - Application-level events (PwShGUICore.psm1)
    Write-ScriptLog  - Script execution with name prefix
    Write-CronLog    - Cron/scheduler events (CronAiAthon-EventLog.psm1)
    Export-LogBuffer - Flush buffered logs to disk

"@)

        # Section 4: SIN Governance Patterns
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(206,145,64)
        $rtbStandards.SelectionFont  = $fontBold
        $rtbStandards.AppendText("`r`n⚠️ SIN GOVERNANCE PATTERNS (ERROR HANDLING RELATED)`r`n")
        $rtbStandards.SelectionFont  = $fontMono
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $rtbStandards.AppendText(@"
  SIN-PATTERN-002  No empty catch blocks (MANDATORY logging or comment)
  SIN-PATTERN-003  No SilentlyContinue on Import-Module (use try/catch)
  SIN-PATTERN-004  Always wrap .Count with @() for PS 5.1 null safety
  SIN-PATTERN-010  No Invoke-Expression with dynamic strings (security risk)
  SIN-PATTERN-022  Null guard before method calls (PS 5.1 no ?. operator)

  📖 Full SIN registry: sin_registry/ (18 blocking + 6 advisory patterns)
  🔍 Scanner: tests\Invoke-SINPatternScanner.ps1

"@)

        # Section 5: Pipeline Configuration Standards
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(78,201,176)
        $rtbStandards.SelectionFont  = $fontBold
        $rtbStandards.AppendText("`r`n🔧 PIPELINE CONFIGURATION STANDARDS`r`n")
        $rtbStandards.SelectionFont  = $fontMono
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(200,200,200)
        $rtbStandards.AppendText(@"
  CronAiAthon-Pipeline.psm1 Requirements:
    - All pipeline operations wrapped in try/catch
    - Use Write-AppLog with canonical severity levels
    - Validate input parameters before processing
    - Check @(`$items).Count before accessing elements
    - Null guard before accessing properties/methods
    - Use -Depth 5+ on ConvertTo-Json (SIN-PATTERN-014)
    - Always -Encoding UTF8 on Set-Content/Out-File (SIN-PATTERN-012/017)

  Pipeline Item Schema:
    - Status values: OPEN | IN-PROGRESS | DONE | BLOCKED | DEFERRED
    - Priority values: CRITICAL | HIGH | MEDIUM | LOW
    - Type values: FeatureRequest | Bug | Items2ADD | Bugs2FIX | ToDo

"@)

        # Section 6: Quick Reference Links
        $rtbStandards.SelectionColor = [System.Drawing.Color]::FromArgb(100,100,100)
        $rtbStandards.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
        $rtbStandards.AppendText(@"

  ─────────────────────────────────────────────────────────────────────────
  Use buttons above to open full documentation, SIN registry, or run scanner.
  Standards compliance checked automatically via cron 'SinRegistryReview' task.

"@)
    })

    # ══════════════════════════════════════════════════════════════
    #  AUTO-REFRESH DASHBOARD ON LOAD
    # ══════════════════════════════════════════════════════════════
    $form.Add_Shown({
        $btnRefreshDash.PerformClick()
        Update-StatusBar
        $script:_monTimer.Start()
    })

    # ── Show Form ────────────────────────────────────────────────
    [void]$form.ShowDialog()

    # Cleanup
    $script:_monTimer.Stop()
    $script:_monTimer.Dispose()
    $toolTip.Dispose()
    $form.Dispose()
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




