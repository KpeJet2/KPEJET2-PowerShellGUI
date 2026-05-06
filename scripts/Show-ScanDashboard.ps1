# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS  Scan Dashboard -- one-stop multi-tabbed form for all scan & analysis scripts.
.DESCRIPTION
    Per-scan tabs for each scan set. Scans execute in background jobs (non-blocking UI).
    Tabs: per-scan, Workspace Dependency Map, Module References, CPSR Reports, Summary, Reports.
    Summary tab: counts, disk usage, cleanup.
    Reports tab: links to all output formats (greyed when data missing).
#>

# ── Module import ─────────────────────────────────────────────────────────────
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUICore.psm1'
if (Test-Path $modulePath) { try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Background job registry (name -> @{Job; Timer; Grid; Btn; PBar; Def}) ─────
$script:RunningJobs = @{}

# ── Scanset Definitions ───────────────────────────────────────────────────────
$script:ScanSetDefs = @(
    @{
        Name       = 'Environment Scanner'
        Script     = 'Invoke-PSEnvironmentScanner.ps1'
        Prefix     = ''
        Pattern    = '*-*-*-*-*.json'
        Exclude    = @('pointer','matrix','edge','orphan','cleanup','triage','retention','module-','script-dep','dependency-vis','manifest-','codebase-audit','install-missing','shop-listed','bg-test','ping')
        Formats    = @('json')
    },
    @{
        Name       = 'Script Dependency Matrix'
        Script     = 'Invoke-ScriptDependencyMatrix.ps1'
        Prefix     = 'script-dependency-matrix'
        Pattern    = 'script-dependency-matrix-*.json'
        Formats    = @('json','md','csv','mmd','txt')
        Related    = @('script-dependency-edges-*.csv','script-dependency-graph-*.mmd','script-dependency-errors-*.txt','script-dependency-error-analysis-*.md','module-references-*.json','Dependency-Visualisation_*.html')
    },
    @{
        Name       = 'Orphan Audit'
        Script     = 'Invoke-OrphanAudit.ps1'
        Prefix     = 'orphan-audit'
        Pattern    = 'orphan-audit-*.json'
        Formats    = @('json','md')
        Related    = @('orphan-audit-core-*.md')
    },
    @{
        Name       = 'Orphan Cleanup'
        Script     = 'Invoke-OrphanCleanup.ps1'
        Prefix     = 'orphan-cleanup'
        Pattern    = 'orphan-cleanup-*.json'
        Formats    = @('json','md')
    },
    @{
        Name       = 'XHTML Report Triage'
        Script     = 'Invoke-XhtmlReportTriage.ps1'
        Prefix     = 'xhtml-triage'
        Pattern    = 'xhtml-triage-*.json'
        Formats    = @('json','md')
    },
    @{
        Name       = 'Report Retention'
        Script     = 'Invoke-ReportRetention.ps1'
        Prefix     = 'report-retention'
        Pattern    = 'report-retention-*.json'
        Formats    = @('json','md')
    },
    @{
        Name       = 'Reference Integrity'
        Script     = 'Invoke-ReferenceIntegrityCheck.ps1'
        Prefix     = 'reference-integrity'
        Pattern    = ''
        Formats    = @()
        LiveOnly   = $true
    },
    @{
        Name       = 'Workspace Dependency Map'
        Script     = 'Invoke-WorkspaceDependencyMap.ps1'
        Prefix     = 'workspace-dependency-map'
        Pattern    = 'workspace-dependency-map-*.json'
        Formats    = @('json','html')
        Related    = @()
        HtmlOutput = '~README.md\Dependency-Visualisation.html'
    },
    @{
        Name       = 'Module References'
        Script     = 'Invoke-ScriptDependencyMatrix.ps1'
        Prefix     = 'module-references'
        Pattern    = 'module-references-*.json'
        Formats    = @('json')
        Related    = @()
        Note       = 'Produced as a side-output of Script Dependency Matrix'
    }
)

# ── Helper Functions ──────────────────────────────────────────────────────────

function Get-ScanFiles {
    param([hashtable]$Def, [string]$ReportPath)
    $files = @()
    if (-not $Def.Pattern -or $Def.LiveOnly) { return $files }

    $candidates = Get-ChildItem -Path $ReportPath -Filter $Def.Pattern -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($Def.Exclude) {
        $candidates = $candidates | Where-Object {
            $fn = $_.Name.ToLower()
            $keep = $true
            foreach ($ex in $Def.Exclude) {
                if ($fn -match $ex) { $keep = $false; break }
            }
            $keep
        }
    }
    foreach ($f in $candidates) { $files += $f }
    return $files
}

function Get-ScansetDiskSize {
    param([hashtable]$Def, [string]$ReportPath)
    $totalBytes = 0
    if ($Def.LiveOnly) { return 0 }

    $allPatterns = @()
    if ($Def.Pattern) { $allPatterns += $Def.Pattern }
    if ($Def.Related) { $allPatterns += $Def.Related }
    if ($Def.Prefix) {
        $allPatterns += "$($Def.Prefix)-*.md"
        $allPatterns += "$($Def.Prefix)-*.csv"
    }

    foreach ($pat in $allPatterns) {
        $hits = Get-ChildItem -Path $ReportPath -Filter $pat -File -ErrorAction SilentlyContinue
        foreach ($h in $hits) { $totalBytes += $h.Length }
    }
    return $totalBytes
}

function Get-AllRelatedFiles {
    param([hashtable]$Def, [string]$ReportPath, [string]$Timestamp)
    $related = @()
    if (-not $Timestamp) { return $related }

    $allPatterns = @()
    if ($Def.Prefix) {
        $allPatterns += "$($Def.Prefix)-$Timestamp.*"
    }
    if ($Def.Related) {
        foreach ($rp in $Def.Related) {
            $base2 = $rp -replace '-\*\.', "-$Timestamp."
            $allPatterns += $base2
        }
    }

    foreach ($pat in ($allPatterns | Select-Object -Unique)) {
        $hits = Get-ChildItem -Path $ReportPath -Filter $pat -File -ErrorAction SilentlyContinue
        foreach ($h in $hits) { $related += $h }
    }
    return $related
}

function Extract-Timestamp {
    param([string]$FileName)
    if ($FileName -match '(\d{8}-\d{6})') { return $Matches[1] }
    return ''
}

# ── Main Form ─────────────────────────────────────────────────────────────────

function Show-ScanDashboard {
    [CmdletBinding()]
    param()

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $reportPath  = Join-Path $projectRoot '~REPORTS'
    $scriptsDir  = $PSScriptRoot
    if (-not (Test-Path $reportPath)) { New-Item -ItemType Directory -Path $reportPath -Force | Out-Null }

    # ══════════════════════════════════════════════════════════════════════════
    #  FORM
    # ══════════════════════════════════════════════════════════════════════════
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Scan Dashboard -- One-Stop Scan & Analysis Center'
    $form.Size            = New-Object System.Drawing.Size(1020, 720)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimumSize     = New-Object System.Drawing.Size(900, 600)
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready'
    $statusBar.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusBar)

    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = 'Fill'

    # ══════════════════════════════════════════════════════════════════════════
    #  PER-SCAN TABS
    # ══════════════════════════════════════════════════════════════════════════
    $scanGrids    = @{}  # name -> DataGridView
    $progressBars = @{}  # name -> ProgressBar

    # Shared state hashtable -- GetNewClosure() creates a new SessionState where
    # $script: scope is inaccessible. Pass mutable references via captured local.
    $shared = @{
        RunningJobs    = $script:RunningJobs
        RefreshSummary = $null  # populated after scriptblock definition below
    }

    # RefreshScanGrid defined as scriptblock variable so .GetNewClosure() event handlers can capture it
    $RefreshScanGrid = {
        param(
            [System.Windows.Forms.DataGridView]$Grid,
            [hashtable]$Def
        )
        $Grid.Rows.Clear()
        if ($Def.LiveOnly) {
            $Grid.Rows.Add('(Live scan only -- no stored files)', '', '', '') | Out-Null
            return
        }
        $files = Get-ScanFiles -Def $Def -ReportPath $reportPath
        foreach ($f in $files) {
            $ts = Extract-Timestamp $f.Name
            $sizeKB = [math]::Round($f.Length / 1KB, 1)
            $fmt = $f.Extension.TrimStart('.')
            $Grid.Rows.Add($f.Name, $ts, $sizeKB, $fmt) | Out-Null
        }
        # Also show related files
        if ($Def.Related) {
            foreach ($relPat in $Def.Related) {
                $relFiles = Get-ChildItem -Path $reportPath -Filter $relPat -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending
                foreach ($rf in $relFiles) {
                    $ts = Extract-Timestamp $rf.Name
                    $sizeKB = [math]::Round($rf.Length / 1KB, 1)
                    $fmt = $rf.Extension.TrimStart('.')
                    $Grid.Rows.Add($rf.Name, $ts, $sizeKB, $fmt) | Out-Null
                }
            }
        }
    }

    foreach ($def in $script:ScanSetDefs) {
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $def.Name
        $tab.Tag  = $def

        # Button panel + ProgressBar
        $pnlButtons = New-Object System.Windows.Forms.Panel
        $pnlButtons.Dock   = 'Top'
        $pnlButtons.Height = 58

        $btnRun = New-Object System.Windows.Forms.Button
        $btnRun.Text     = "Run $($def.Name)"
        $btnRun.Location = New-Object System.Drawing.Point(4, 4)
        $btnRun.Size     = New-Object System.Drawing.Size(180, 26)
        $btnRun.Tag      = $def

        $btnRefresh = New-Object System.Windows.Forms.Button
        $btnRefresh.Text     = 'Refresh List'
        $btnRefresh.Location = New-Object System.Drawing.Point(190, 4)
        $btnRefresh.Size     = New-Object System.Drawing.Size(100, 26)
        $btnRefresh.Tag      = $def

        $btnOpenReport = New-Object System.Windows.Forms.Button
        $btnOpenReport.Text     = 'Open Selected'
        $btnOpenReport.Location = New-Object System.Drawing.Point(296, 4)
        $btnOpenReport.Size     = New-Object System.Drawing.Size(110, 26)
        $btnOpenReport.Tag      = $def

        # "Open Visualisation" button -- only for Workspace Dependency Map
        $btnViewHtml = $null
        if ($def.HtmlOutput) {
            $btnViewHtml = New-Object System.Windows.Forms.Button
            $btnViewHtml.Text     = 'Open Visualisation'
            $btnViewHtml.Location = New-Object System.Drawing.Point(412, 4)
            $btnViewHtml.Size     = New-Object System.Drawing.Size(130, 26)
            $btnViewHtml.Tag      = $def
        }

        # ProgressBar (marquee during background job run)
        $pbar = New-Object System.Windows.Forms.ProgressBar
        $pbar.Style   = 'Marquee'
        $pbar.Visible = $false
        $pbar.Location = New-Object System.Drawing.Point(4, 34)
        $pbar.Size     = New-Object System.Drawing.Size(960, 18)
        $pbar.Anchor   = 'Left,Right,Bottom'

        $pnlButtons.Controls.AddRange(@($btnRun, $btnRefresh, $btnOpenReport, $pbar))
        if ($btnViewHtml) { $pnlButtons.Controls.Add($btnViewHtml) }

        # Data grid
        $dgv = New-Object System.Windows.Forms.DataGridView
        $dgv.Dock = 'Fill'
        $dgv.ReadOnly = $true
        $dgv.AllowUserToAddRows = $false
        $dgv.AutoSizeColumnsMode = 'Fill'
        $dgv.SelectionMode = 'FullRowSelect'
        $dgv.RowHeadersVisible = $false
        $dgv.Tag = $def

        @('File Name','Timestamp','Size (KB)','Format') | ForEach-Object {
            $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $col.HeaderText = $_
            $col.Name = $_ -replace '[() ]',''
            $dgv.Columns.Add($col) | Out-Null
        }

        $scanGrids[$def.Name]    = $dgv
        $progressBars[$def.Name] = $pbar
        # Add DGV first, then button panel -- WinForms Dock Z-order requires Fill before Top
        $tab.Controls.Add($dgv)
        $tab.Controls.Add($pnlButtons)

        # Wire events
        $btnRun.Add_Click({
            $runDef     = $this.Tag
            $defName    = $runDef.Name
            $scriptPath = Join-Path $scriptsDir $runDef.Script
            if (-not (Test-Path $scriptPath)) {
                [System.Windows.Forms.MessageBox]::Show("Script not found:`n$scriptPath", 'Missing Script',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ($shared.RunningJobs.ContainsKey($defName)) {
                [System.Windows.Forms.MessageBox]::Show("$defName is already running.", 'In Progress',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            # Disable button + show progress bar
            $this.Enabled  = $false
            $capturedPBar  = $progressBars[$defName]
            if ($capturedPBar) { $capturedPBar.Visible = $true }
            $statusLabel.Text = "Running $defName in background..."

            # Launch in background job -- non-blocking (SS-004 compliant)
            $capturedWS   = $projectRoot
            $capturedPath = $scriptPath
            $job = Start-Job -ScriptBlock {
                & $using:capturedPath -WorkspacePath $using:capturedWS
            }

            $capturedBtn    = $this
            $capturedGrid   = $scanGrids[$defName]
            $capturedRefSG  = $RefreshScanGrid
            $capturedSL     = $statusLabel

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 500
            $timer.Add_Tick({
                $ji = $shared.RunningJobs[$defName]
                if (-not $ji) { $this.Stop(); return }
                $st = $ji.Job.State
                if ($st -in @('Completed','Failed','Stopped')) {
                    $this.Stop()
                    if ($null -ne $ji.PBar)   { $ji.PBar.Visible   = $false }
                    if ($null -ne $ji.Button) { $ji.Button.Enabled = $true }
                    if ($st -eq 'Completed') {
                        & $capturedRefSG -Grid $ji.Grid -Def $ji.Def
                        if ($shared.RefreshSummary) { & $shared.RefreshSummary }
                        $capturedSL.Text = "$defName completed."
                    } else {
                        $errMsg = (Receive-Job $ji.Job 2>&1 | Out-String).Trim()
                        $capturedSL.Text = "$defName failed: $errMsg"
                        [System.Windows.Forms.MessageBox]::Show(
                            "$defName failed:`n$errMsg", 'Scan Error',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Warning)
                    }
                    Remove-Job $ji.Job -Force -ErrorAction SilentlyContinue
                    $shared.RunningJobs.Remove($defName)
                }
            }.GetNewClosure())

            $shared.RunningJobs[$defName] = @{
                Job    = $job
                Timer  = $timer
                Grid   = $capturedGrid
                Button = $capturedBtn
                PBar   = $capturedPBar
                Def    = $runDef
            }
            $timer.Start()
        }.GetNewClosure())

        $btnRefresh.Add_Click({
            $refDef = $this.Tag
            if ($null -eq $refDef) { return }
            $defName = $refDef.Name
            if (-not $defName) { return }
            $grid = $scanGrids[$defName]
            if ($null -ne $grid) { & $RefreshScanGrid -Grid $grid -Def $refDef }
        }.GetNewClosure())

        $btnOpenReport.Add_Click({
            $openDef = $this.Tag
            if ($null -eq $openDef) { return }
            $defName = $openDef.Name
            if (-not $defName) { return }
            $grid = $scanGrids[$defName]
            if ($null -ne $grid -and @($grid.SelectedRows).Count -gt 0) {
                $selectedRow = $grid.SelectedRows[0]
                if ($null -eq $selectedRow) { return }
                $fileNameCell = $selectedRow.Cells['FileName']
                if ($null -eq $fileNameCell) { return }
                $fileName = $fileNameCell.Value
                if (-not $fileName) { return }
                $filePath = Join-Path $reportPath $fileName
                if (Test-Path $filePath) {
                    Invoke-Item $filePath
                } else {
                    [System.Windows.Forms.MessageBox]::Show("File not found:`n$filePath", 'Missing')
                }
            }
        }.GetNewClosure())

        # Wire View HTML button (Workspace Dependency Map only)
        if ($btnViewHtml) {
            $btnViewHtml.Add_Click({
                $htmlDef  = $this.Tag
                $htmlFile = Join-Path $projectRoot $htmlDef.HtmlOutput
                if (Test-Path $htmlFile) {
                    Invoke-Item $htmlFile
                } else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Visualisation not yet generated.`nRun '$($htmlDef.Name)' first.",
                        'File Not Found',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            }.GetNewClosure())
        }

        $tabControl.TabPages.Add($tab)
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  SUMMARY TAB
    # ══════════════════════════════════════════════════════════════════════════
    $tabSummary = New-Object System.Windows.Forms.TabPage
    $tabSummary.Text = 'Summary'

    $pnlSummaryButtons = New-Object System.Windows.Forms.Panel
    $pnlSummaryButtons.Dock   = 'Top'
    $pnlSummaryButtons.Height = 36

    $btnRefreshSummary = New-Object System.Windows.Forms.Button
    $btnRefreshSummary.Text     = 'Refresh Summary'
    $btnRefreshSummary.Location = New-Object System.Drawing.Point(4, 4)
    $btnRefreshSummary.Size     = New-Object System.Drawing.Size(130, 28)

    $btnRunAll = New-Object System.Windows.Forms.Button
    $btnRunAll.Text     = 'Run All Scans (Background)'
    $btnRunAll.Location = New-Object System.Drawing.Point(140, 4)
    $btnRunAll.Size     = New-Object System.Drawing.Size(180, 28)

    $btnCleanup = New-Object System.Windows.Forms.Button
    $btnCleanup.Text     = 'Cleanup Old Scans'
    $btnCleanup.Location = New-Object System.Drawing.Point(326, 4)
    $btnCleanup.Size     = New-Object System.Drawing.Size(140, 28)
    $btnCleanup.ForeColor = [System.Drawing.Color]::DarkRed

    $pnlSummaryButtons.Controls.AddRange(@($btnRefreshSummary, $btnRunAll, $btnCleanup))

    $dgvSummary = New-Object System.Windows.Forms.DataGridView
    $dgvSummary.Dock = 'Fill'
    $dgvSummary.ReadOnly = $true
    $dgvSummary.AllowUserToAddRows = $false
    $dgvSummary.AutoSizeColumnsMode = 'Fill'
    $dgvSummary.RowHeadersVisible = $false
    @('Scan Set','File Count','Disk Size','Latest Scan','Script Available') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_
        $col.Name = $_ -replace ' ',''
        $dgvSummary.Columns.Add($col) | Out-Null
    }
    # Add DGV first, then button panel -- WinForms Dock Z-order requires Fill before Top
    $tabSummary.Controls.Add($dgvSummary)
    $tabSummary.Controls.Add($pnlSummaryButtons)
    $tabControl.TabPages.Add($tabSummary)

    # ══════════════════════════════════════════════════════════════════════════
    #  REPORTS TAB
    # ══════════════════════════════════════════════════════════════════════════
    $tabReports = New-Object System.Windows.Forms.TabPage
    $tabReports.Text = 'Reports'

    $pnlReportsTop = New-Object System.Windows.Forms.Panel
    $pnlReportsTop.Dock   = 'Top'
    $pnlReportsTop.Height = 36

    $btnRefreshReports = New-Object System.Windows.Forms.Button
    $btnRefreshReports.Text     = 'Refresh'
    $btnRefreshReports.Location = New-Object System.Drawing.Point(4, 4)
    $btnRefreshReports.Size     = New-Object System.Drawing.Size(90, 28)

    $btnOpenSelected = New-Object System.Windows.Forms.Button
    $btnOpenSelected.Text     = 'Open Selected Report'
    $btnOpenSelected.Location = New-Object System.Drawing.Point(100, 4)
    $btnOpenSelected.Size     = New-Object System.Drawing.Size(150, 28)

    $pnlReportsTop.Controls.AddRange(@($btnRefreshReports, $btnOpenSelected))

    $dgvReports = New-Object System.Windows.Forms.DataGridView
    $dgvReports.Dock = 'Fill'
    $dgvReports.ReadOnly = $true
    $dgvReports.AllowUserToAddRows = $false
    $dgvReports.AutoSizeColumnsMode = 'Fill'
    $dgvReports.SelectionMode = 'FullRowSelect'
    $dgvReports.RowHeadersVisible = $false
    @('Scan Set','Format','File','Date','Size (KB)','Available') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_
        $col.Name = $_ -replace '[() ]',''
        $dgvReports.Columns.Add($col) | Out-Null
    }
    # Add DGV first, then button panel -- WinForms Dock Z-order requires Fill before Top
    $tabReports.Controls.Add($dgvReports)
    $tabReports.Controls.Add($pnlReportsTop)
    $tabControl.TabPages.Add($tabReports)

    # ══════════════════════════════════════════════════════════════════════════
    #  CPSR REPORTS TAB  (read-only viewer for ~REPORTS/CPSR/ subfolder)
    # ══════════════════════════════════════════════════════════════════════════
    $tabCpsr = New-Object System.Windows.Forms.TabPage
    $tabCpsr.Text = 'CPSR Reports'

    $pnlCpsrTop = New-Object System.Windows.Forms.Panel
    $pnlCpsrTop.Dock   = 'Top'
    $pnlCpsrTop.Height = 36

    $btnRefreshCpsr = New-Object System.Windows.Forms.Button
    $btnRefreshCpsr.Text     = 'Refresh'
    $btnRefreshCpsr.Location = New-Object System.Drawing.Point(4, 4)
    $btnRefreshCpsr.Size     = New-Object System.Drawing.Size(90, 28)

    $btnOpenCpsr = New-Object System.Windows.Forms.Button
    $btnOpenCpsr.Text     = 'Open Selected'
    $btnOpenCpsr.Location = New-Object System.Drawing.Point(100, 4)
    $btnOpenCpsr.Size     = New-Object System.Drawing.Size(120, 28)

    $btnOpenCpsrFolder = New-Object System.Windows.Forms.Button
    $btnOpenCpsrFolder.Text     = 'Open CPSR Folder'
    $btnOpenCpsrFolder.Location = New-Object System.Drawing.Point(226, 4)
    $btnOpenCpsrFolder.Size     = New-Object System.Drawing.Size(130, 28)

    $pnlCpsrTop.Controls.AddRange(@($btnRefreshCpsr, $btnOpenCpsr, $btnOpenCpsrFolder))

    $dgvCpsr = New-Object System.Windows.Forms.DataGridView
    $dgvCpsr.Dock = 'Fill'
    $dgvCpsr.ReadOnly = $true
    $dgvCpsr.AllowUserToAddRows = $false
    $dgvCpsr.AutoSizeColumnsMode = 'Fill'
    $dgvCpsr.SelectionMode = 'FullRowSelect'
    $dgvCpsr.RowHeadersVisible = $false
    @('File','Subfolder','Date','Size (KB)') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_
        $col.Name = $_ -replace '[() ]',''
        $dgvCpsr.Columns.Add($col) | Out-Null
    }
    $tabCpsr.Controls.Add($dgvCpsr)
    $tabCpsr.Controls.Add($pnlCpsrTop)
    $tabControl.TabPages.Add($tabCpsr)

    $RefreshCpsrGrid = {
        $dgvCpsr.Rows.Clear()
        $cpsrRoot = Join-Path $reportPath 'CPSR'
        if (-not (Test-Path $cpsrRoot)) {
            $dgvCpsr.Rows.Add('(no CPSR folder found)', '', '', '') | Out-Null
            return
        }
        $cpsrFiles = @(Get-ChildItem -Path $cpsrRoot -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($cf in $cpsrFiles) {
            $subfolder = $cf.Directory.Name
            $date      = $cf.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            $sizeKB    = [math]::Round($cf.Length / 1KB, 1)
            $dgvCpsr.Rows.Add($cf.Name, $subfolder, $date, $sizeKB) | Out-Null
        }
        if ($cpsrFiles.Count -eq 0) {
            $dgvCpsr.Rows.Add('(no CPSR report files found)', '', '', '') | Out-Null
        }
    }

    $btnRefreshCpsr.Add_Click({ & $RefreshCpsrGrid })

    $btnOpenCpsr.Add_Click({
        if ($null -ne $dgvCpsr -and @($dgvCpsr.SelectedRows).Count -gt 0) {
            $selectedRow = $dgvCpsr.SelectedRows[0]
            if ($null -eq $selectedRow) { return }
            $fileCell = $selectedRow.Cells['File']
            $subCell = $selectedRow.Cells['Subfolder']
            if ($null -eq $fileCell -or $null -eq $subCell) { return }
            $selFile   = $fileCell.Value
            $selSub    = $subCell.Value
            if (-not $selFile) { return }
            $cpsrRoot  = Join-Path $reportPath 'CPSR'
            $fullPath  = Join-Path (Join-Path $cpsrRoot $selSub) $selFile
            if (Test-Path $fullPath) { Invoke-Item $fullPath }
            else { [System.Windows.Forms.MessageBox]::Show("File not found:`n$fullPath", 'Missing') }
        }
    })

    $btnOpenCpsrFolder.Add_Click({
        $cpsrRoot = Join-Path $reportPath 'CPSR'
        if (Test-Path $cpsrRoot) { Invoke-Item $cpsrRoot }
        else { [System.Windows.Forms.MessageBox]::Show('CPSR folder not found.', 'Missing') }
    })

    $form.Controls.Add($tabControl)

    # ══════════════════════════════════════════════════════════════════════════
    #  SHARED SCRIPTBLOCKS (RefreshSummary / RefreshReportsTab -- non-closure handlers only)
    # ══════════════════════════════════════════════════════════════════════════

    $RefreshSummary = {
        $dgvSummary.Rows.Clear()
        $totalFiles = 0
        $totalBytes = 0
        foreach ($def in $script:ScanSetDefs) {
            $files = Get-ScanFiles -Def $def -ReportPath $reportPath
            $count = $files.Count
            $bytes = Get-ScansetDiskSize -Def $def -ReportPath $reportPath
            $latest = if ($files.Count -gt 0) { Extract-Timestamp $files[0].Name } else { '(none)' }
            $scriptAvail = if (Test-Path (Join-Path $scriptsDir $def.Script)) { 'Yes' } else { 'No' }
            $sizeDisp = '{0:N1} KB' -f ($bytes / 1KB)
            $dgvSummary.Rows.Add($def.Name, $count, $sizeDisp, $latest, $scriptAvail) | Out-Null
            $totalFiles += $count
            $totalBytes += $bytes
        }
        $dgvSummary.Rows.Add('TOTAL', $totalFiles, ('{0:N1} KB' -f ($totalBytes / 1KB)), '', '') | Out-Null
        $dgvSummary.Rows[$dgvSummary.Rows.Count - 1].DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $statusLabel.Text = "Summary: $totalFiles scan files, $([math]::Round($totalBytes / 1KB, 1)) KB total"
    }
    $shared.RefreshSummary = $RefreshSummary

    $RefreshReportsTab = {
        $dgvReports.Rows.Clear()
        foreach ($def in $script:ScanSetDefs) {
            if ($def.LiveOnly) {
                $rowIdx = $dgvReports.Rows.Add($def.Name, '(live)', '(run scan to view)', '', '', 'No')
                $dgvReports.Rows[$rowIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                continue
            }
            $files = Get-ScanFiles -Def $def -ReportPath $reportPath
            if ($files.Count -eq 0) {
                $rowIdx = $dgvReports.Rows.Add($def.Name, '-', '(no scanset data)', '', '', 'No')
                $dgvReports.Rows[$rowIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                continue
            }
            # Show latest of each format
            $latestTs = Extract-Timestamp $files[0].Name
            $seenFormats = @{}
            $allFiles = @($files)
            if ($def.Related) {
                foreach ($rp in $def.Related) {
                    $allFiles += @(Get-ChildItem -Path $reportPath -Filter $rp -File -ErrorAction SilentlyContinue)
                }
            }
            if ($def.Prefix) {
                foreach ($ext in @('md','csv','txt','html')) {
                    $allFiles += @(Get-ChildItem -Path $reportPath -Filter "$($def.Prefix)-*.$ext" -File -ErrorAction SilentlyContinue)
                }
            }
            $allFiles = $allFiles | Sort-Object Name -Descending
            foreach ($f in $allFiles) {
                $fTs = Extract-Timestamp $f.Name
                if ($fTs -ne $latestTs) { continue }
                $ext = $f.Extension.TrimStart('.').ToUpper()
                if ($seenFormats.ContainsKey($ext)) { continue }
                $seenFormats[$ext] = $true
                $sizeKB = [math]::Round($f.Length / 1KB, 1)
                $dgvReports.Rows.Add($def.Name, $ext, $f.Name, $fTs, $sizeKB, 'Yes') | Out-Null
            }
        }
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  SUMMARY / REPORTS EVENT HANDLERS
    # ══════════════════════════════════════════════════════════════════════════

    $btnRefreshSummary.Add_Click({ & $RefreshSummary })

    $btnRunAll.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Launch all scan scripts as background jobs?`nScans run in parallel -- UI remains responsive.",
            'Run All Scans', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { return }

        $launched = 0
        foreach ($def in $script:ScanSetDefs) {
            if ($def.LiveOnly) { continue }
            if ($script:RunningJobs.ContainsKey($def.Name)) { continue }  # already running
            $scriptPath = Join-Path $scriptsDir $def.Script
            if (-not (Test-Path $scriptPath)) { continue }
            $capturedWS    = $projectRoot
            $capturedPath  = $scriptPath
            $capturedName  = $def.Name
            $capturedDef   = $def
            $capturedGrid  = $scanGrids[$def.Name]
            $capturedBtn   = $null  # no per-tab button to re-enable from Run All
            $capturedPBar  = $progressBars[$def.Name]
            if ($capturedPBar) { $capturedPBar.Visible = $true }

            $job = Start-Job -ScriptBlock { & $using:capturedPath -WorkspacePath $using:capturedWS }

            $capturedRefSG  = $RefreshScanGrid
            $capturedSL     = $statusLabel

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 500
            $timer.Add_Tick({
                $ji = $shared.RunningJobs[$capturedName]
                if (-not $ji) { $this.Stop(); return }
                $st = $ji.Job.State
                if ($st -in @('Completed','Failed','Stopped')) {
                    $this.Stop()
                    if ($null -ne $ji.PBar)   { $ji.PBar.Visible   = $false }
                    if ($null -ne $ji.Button) { $ji.Button.Enabled = $true }
                    if ($st -eq 'Completed') {
                        & $capturedRefSG -Grid $ji.Grid -Def $ji.Def
                        if ($shared.RefreshSummary) { & $shared.RefreshSummary }
                    }
                    Remove-Job $ji.Job -Force -ErrorAction SilentlyContinue
                    $shared.RunningJobs.Remove($capturedName)
                    $capturedSL.Text = "$capturedName done. Running: $(@($shared.RunningJobs.Keys).Count) remaining"
                }
            }.GetNewClosure())

            $shared.RunningJobs[$capturedName] = @{
                Job    = $job
                Timer  = $timer
                Grid   = $capturedGrid
                Button = $capturedBtn
                PBar   = $capturedPBar
                Def    = $capturedDef
            }
            $timer.Start()
            $launched++
        }
        $statusLabel.Text = "Launched $launched background scans. UI remains responsive."
    })

    $btnCleanup.Add_Click({
        # Calculate what would be removed
        $totalReclaim = 0
        $filesToRemove = @()
        foreach ($def in $script:ScanSetDefs) {
            if ($def.LiveOnly) { continue }
            $files = Get-ScanFiles -Def $def -ReportPath $reportPath
            if ($files.Count -le 1) { continue }
            # Keep newest, remove rest
            $oldest = $files[1..($files.Count - 1)]
            foreach ($f in $oldest) {
                $totalReclaim += $f.Length
                $filesToRemove += $f
                # Find related files for same timestamp
                $ts = Extract-Timestamp $f.Name
                $related = Get-AllRelatedFiles -Def $def -ReportPath $reportPath -Timestamp $ts
                foreach ($rf in $related) {
                    if ($rf.FullName -ne $f.FullName) {
                        $totalReclaim += $rf.Length
                        $filesToRemove += $rf
                    }
                }
            }
        }

        if ($filesToRemove.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No old scans to clean up. Only the most recent scanset exists for each type.', 'Nothing to Clean')
            return
        }

        $reclaimMB = [math]::Round($totalReclaim / 1MB, 2)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Remove $($filesToRemove.Count) old scan files?`nSpace reclaimed: $reclaimMB MB`n`nThe most recent scan for each set will be kept.",
            'Cleanup Old Scans', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }

        $removed = 0
        foreach ($f in ($filesToRemove | Select-Object -Unique -Property FullName)) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
            } catch { <# Intentional: non-fatal -- file may be locked #> }
        }
        $statusLabel.Text = "Cleaned up $removed files, reclaimed ~$reclaimMB MB"

        # Refresh
        foreach ($def in $script:ScanSetDefs) {
            $grid = $scanGrids[$def.Name]
            if ($grid) { & $RefreshScanGrid -Grid $grid -Def $def }
        }
        & $RefreshSummary
        & $RefreshReportsTab
    })

    $btnRefreshReports.Add_Click({ & $RefreshReportsTab })

    $btnOpenSelected.Add_Click({
        if ($null -ne $dgvReports -and @($dgvReports.SelectedRows).Count -gt 0) {
            $selectedRow = $dgvReports.SelectedRows[0]
            if ($null -eq $selectedRow) { return }
            $fileCell = $selectedRow.Cells['File']
            $availCell = $selectedRow.Cells['Available']
            if ($null -eq $fileCell -or $null -eq $availCell) { return }
            $fileName = $fileCell.Value
            $avail    = $availCell.Value
            if (-not $fileName) { return }
            if ($avail -ne 'Yes') {
                [System.Windows.Forms.MessageBox]::Show('This report is not available. Run the scan first.', 'Not Available')
                return
            }
            $filePath = Join-Path $reportPath $fileName
            if (Test-Path $filePath) {
                Invoke-Item $filePath
            } else {
                [System.Windows.Forms.MessageBox]::Show("File not found:`n$filePath", 'Missing')
            }
        }
    })

    # ── Initial load ──────────────────────────────────────────────────────────
    foreach ($def in $script:ScanSetDefs) {
        $grid = $scanGrids[$def.Name]
        if ($grid) { & $RefreshScanGrid -Grid $grid -Def $def }
    }
    & $RefreshSummary
    & $RefreshReportsTab
    & $RefreshCpsrGrid

    # ── FormClosing: stop and remove any running background jobs ─────────────
    $form.Add_FormClosing({
        foreach ($jiName in @($script:RunningJobs.Keys)) {
            $ji = $script:RunningJobs[$jiName]
            if ($ji.Timer) { try { $ji.Timer.Stop() } catch { <# Intentional: non-fatal #> } }
            if ($ji.Job)   { Remove-Job $ji.Job -Force -ErrorAction SilentlyContinue }
        }
        $script:RunningJobs.Clear()
    })

    # ── Show ──────────────────────────────────────────────────────────────────
    [void]$form.ShowDialog()
    $form.Dispose()
}

# If run directly, launch the dashboard
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    Show-ScanDashboard
}


