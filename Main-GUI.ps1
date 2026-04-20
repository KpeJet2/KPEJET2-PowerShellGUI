# VersionTag: 2604.B2.V31.3
# VersionBuildHistory:
#   2603.B0.v24  2026-06-10       Phase A-F implementation: dep visualiser, smoke test, checklist invoker
#   2603.B0.v23  2026-03-28 09:15  TrayHost/PShellCore: ApplicationContext lifecycle, custom smiley tray icon, spacebar rehydration, verbose logging
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell GUI Application with Admin Elevation Support

.DESCRIPTION
    A Windows Forms GUI application providing a menu-driven interface to launch
    PowerShell scripts with optional admin elevation, config management, and
    comprehensive logging.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 24th January 2026
    Modified : 3rd March 2026
    Config   : config\system-variables.xml

.PARAMETER StartupMode
    quik_jnr  - Fast startup, skips manifest generation.
    slow_snr  - Full checks: path validation, version check, manifest. (default)

.INPUTS
    -StartupMode [quik_jnr | slow_snr]

.OUTPUTS
    Windows Forms GUI window. Logs written to logs\

.FUNCTIONALITY
    For system administrators and IT professionals to access and run common
    maintenance scripts from a unified GUI interface.

.LINK
    ~README.md/README.md

.LINK
    ~README.md/QUICK-START.md

.LINK
    ~README.md/SETUP-GUIDE.md
#>

param(
    [ValidateSet('quik_jnr', 'slow_snr')]
    [string]$StartupMode = 'slow_snr',
    [switch]$TaskTray
)

# Continue on errors (GUI app should not terminate on unhandled errors)
$ErrorActionPreference = "Continue"

# ==================== GLOBAL ERROR TRAP ====================
trap {
    try { Write-AppLog "FATAL unhandled exception: $_" "Error" } catch { <# Intentional: non-fatal #> }
    try { Export-LogBuffer } catch { <# Intentional: non-fatal #> }
    try { Remove-SessionLock } catch { <# Intentional: non-fatal #> }
    continue
}

# ==================== PERFORMANCE OPTIMIZATION: ASSEMBLY LOADING ====================
# IMPL-20260405-007: Startup timing — Stopwatch probes for load phase analysis
$script:_StartupSW = [System.Diagnostics.Stopwatch]::StartNew()
$script:_StartupMilestones = [System.Collections.Generic.List[PSCustomObject]]::new()
function _SwMark {
    param([string]$Label)
    $script:_StartupMilestones.Add([PSCustomObject]@{
        label   = $Label
        elapsed = $script:_StartupSW.Elapsed.TotalMilliseconds
    })
}
_SwMark 'process-start'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.IO.Compression.FileSystem
_SwMark 'assemblies-loaded'

# ==================== PERFORMANCE OPTIMIZATION: CACHING ====================
# XML Document Cache
$script:_XmlCache = @{
    ConfigFile = $null
    LinksConfig = $null
    LastConfigLoad = $null
    LastLinksLoad = $null
}

# Workspace File-List Cache -- avoids redundant Get-ChildItem -Recurse scans
$script:_FileListCache = @{
    ScriptFiles = $null   # *.ps1, *.psm1, *.psd1
    AllFiles    = $null   # All files
    CachedAt    = $null   # [datetime] when last refreshed
    MaxAgeSec   = 120     # Cache validity in seconds
}
$script:_ScanExclude = @('.git', '.history', 'node_modules', '~REPORTS\archive')

function Get-CachedScriptFiles {
    <# Returns cached list of *.ps1/*.psm1/*.psd1 in workspace, excluding .git/.history #>
    $now = [datetime]::UtcNow
    if ($script:_FileListCache.ScriptFiles -and $script:_FileListCache.CachedAt -and
        ($now - $script:_FileListCache.CachedAt).TotalSeconds -lt $script:_FileListCache.MaxAgeSec) {
        return $script:_FileListCache.ScriptFiles
    }
    $root = $scriptDir
    $files = Get-ChildItem -Path $root -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue |
        Where-Object {
            foreach ($ex in $script:_ScanExclude) { if ($_.FullName -like "$root\$ex\*") { return $false } }
            return $true
        }
    $script:_FileListCache.ScriptFiles = @($files)
    $script:_FileListCache.CachedAt = $now
    return $script:_FileListCache.ScriptFiles
}

function Get-CachedAllFiles {
    <# Returns cached list of all files in workspace, excluding .git/.history #>
    $now = [datetime]::UtcNow
    if ($script:_FileListCache.AllFiles -and $script:_FileListCache.CachedAt -and
        ($now - $script:_FileListCache.CachedAt).TotalSeconds -lt $script:_FileListCache.MaxAgeSec) {
        return $script:_FileListCache.AllFiles
    }
    $root = $scriptDir
    $exclude = @(Get-ConfigList "Do-Not-VersionTag-FoldersFiles") + '.git'
    $files = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart("\\")
            foreach ($ex in $exclude) { if ($rel -like "${ex}*") { return $false } }
            return $true
        }
    $script:_FileListCache.AllFiles = @($files)
    $script:_FileListCache.CachedAt = $now
    return $script:_FileListCache.AllFiles
}

function Clear-FileListCache {
    <# Invalidates the workspace file cache (call after file create/delete operations) #>
    $script:_FileListCache.ScriptFiles = $null
    $script:_FileListCache.AllFiles = $null
    $script:_FileListCache.CachedAt = $null
}

# Log Stream -- managed by PwShGUICore module (import below)
# (Buffer variables removed -- now in PwShGUICore.psm1)

# Define LOCAL script directory and paths (used before the global $scriptDir block)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==================== IMPORT SHARED CORE MODULE ====================
$coreModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUICore.psm1'
if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath -Force
    if (-not (Get-Command Write-AppLog -ErrorAction SilentlyContinue)) {
        throw "PwShGUICore imported but Write-AppLog not available -- module may be corrupt"
    }
    Initialize-CorePaths -ScriptDir $scriptDir

    # ── Persist modules directory to User-level PSModulePath so all future sessions
    #    (terminals, scripts, bat launchers) can Import-Module by name without full paths.
    $modsDir = Join-Path $scriptDir 'modules'
    $userPath = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'User')
    if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
    if ($userPath.Split(';') -notcontains $modsDir) {
        $newUserPath = ($modsDir + ';' + $userPath).TrimEnd(';')
        [System.Environment]::SetEnvironmentVariable('PSModulePath', $newUserPath, 'User')
        Write-AppLog "PSModulePath: added '$modsDir' to User scope (persists across sessions)" 'Info'
    }
    # Also register for the current process so this session benefits immediately
    $procPath = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    if ($procPath.Split(';') -notcontains $modsDir) {
        [System.Environment]::SetEnvironmentVariable('PSModulePath', "$modsDir;$procPath", 'Process')
    }
} else {
    Write-Warning "PwShGUICore module not found at $coreModulePath -- falling back to inline functions"
}
_SwMark 'module-core-loaded'

# ==================== IMPORT THEME MODULE ====================
$themeModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUI-Theme.psm1'
if (Test-Path $themeModulePath) {
    Import-Module $themeModulePath -Force
    if (-not (Get-Command Set-ModernFormTheme -ErrorAction SilentlyContinue)) {
        Write-AppLog 'PwShGUI-Theme imported but Set-ModernFormTheme not available' 'Warning'
    }
}
_SwMark 'module-theme-loaded'

# ==================== IMPORT TRAY HOST MODULE (PShellCore) ====================
$trayHostModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUI-TrayHost.psm1'
if (Test-Path $trayHostModulePath) {
    Import-Module $trayHostModulePath -Force
    if (-not (Get-Command Initialize-TrayAppContext -ErrorAction SilentlyContinue)) {
        Write-AppLog 'PwShGUI-TrayHost imported but Initialize-TrayAppContext not available' 'Warning'
    } else {
        Write-AppLog "[Init] PwShGUI-TrayHost module loaded (PShellCore background host)" "Debug"
    }
}
_SwMark 'module-trayhost-loaded'

# ==================== IMPORT INTEGRITY CORE MODULE ====================
$integrityCoreModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUI-IntegrityCore.psm1'
if (Test-Path $integrityCoreModulePath) {
    try {
        Import-Module $integrityCoreModulePath -Force -ErrorAction Stop
        Write-AppLog "[Init] PwShGUI-IntegrityCore module loaded" "Debug"
    } catch {
        Write-AppLog "PwShGUI-IntegrityCore failed to load: $($_.Exception.Message)" "Warning"
    }
} else {
    Write-AppLog "PwShGUI-IntegrityCore.psm1 not found -- startup integrity check will run inline fallback" "Warning"
}
_SwMark 'module-integritycore-loaded'

# Request-LocalPath -- now provided by PwShGUICore module
# (Inline definition removed -- see modules/PwShGUICore.psm1)

function Show-ConfigMaintenanceForm {
    <#
    .SYNOPSIS
    Displays a comprehensive Config Maintenance Form for managing all application folders and settings.
    
    .DESCRIPTION
    Shows current config paths with validation, file counts, and folder management options including:
    - Nest folders within DefaultFolder
    - Content management: Move/Copy/Abandon workflows
    - Archive operations: InPlace (high compression), OutYonder (user location), Clear-Clean
    - Config actions: Export/Import/Reset
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$CurrentPaths
    )
    
    Write-AppLog "Opening Config Maintenance Form" "Audit"

    $defaultBase = $scriptDir
    $defaultDownloads = Join-Path $scriptDir "~DOWNLOADS"

    function Get-DefaultPathForKey {
        param([string]$Key)
        if ($Key -eq "DownloadFolder") { return $defaultDownloads }
        return $defaultBase
    }

    function Set-PathForKey {
        param(
            [string]$Key,
            [string]$Path
        )

        switch ($Key) {
            "ConfigPath" { $script:ConfigPath = $Path }
            "DefaultFolder" { $script:DefaultFolder = $Path }
            "TempFolder" { $script:TempFolder = $Path }
            "ReportFolder" { $script:ReportFolder = $Path }
            "DownloadFolder" { $script:DownloadFolder = $Path }
        }
        $CurrentPaths[$Key] = $Path
    }

    function Save-CurrentPaths {
        Save-ConfigPathValues -Paths $CurrentPaths
    }

    function Update-RowStats {
        param(
            [System.Windows.Forms.DataGridViewRow]$Row,
            [string]$Path
        )

        $exists = Test-Path $Path
        $fileCount = 0
        $sizeMB = 0
        if ($exists) {
            try {
                $items = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue
                $fileCount = ($items | Measure-Object).Count
                $sizeBytes = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                $sizeMB = [math]::Round($sizeBytes / 1MB, 2)
            } catch {
                Write-AppLog "Error scanning folder $Path : $_" "Warning"
            }
        }

        $configKey = $Row.Cells["ConfigKey"].Value
        $canNest = if ($configKey -like '[Folder]*') { "-" }
        elseif ($configKey -ne "DefaultFolder" -and $CurrentPaths.ContainsKey("DefaultFolder")) {
            $defaultFolder = $CurrentPaths["DefaultFolder"]
            if (-not $Path.StartsWith($defaultFolder, [StringComparison]::OrdinalIgnoreCase)) { "Yes" } else { "No" }
        } else { "No" }

        $folderCount = 0
        if ($exists) {
            try {
                $folderCount = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue).Count
            } catch { <# Intentional: non-fatal #> }
        }

        $Row.Cells["Path"].Value = $Path
        $Row.Cells["Exists"].Value = $(if ($exists) { "Y" } else { "N" })
        $Row.Cells["Files"].Value = $fileCount
        $Row.Cells["Folders"].Value = $folderCount
        $Row.Cells["SizeMB"].Value = $sizeMB
        $Row.Cells["CanNest"].Value = $canNest
    }

    function Get-SelectedConfigRows {
        # Returns an array of @{ Row; Key; Path } for checked config rows in the DGV (excludes [Folder] rows)
        $result = @()
        foreach ($row in $dgv.Rows) {
            if ($row.IsNewRow) { continue }
            $key = $row.Cells["ConfigKey"].Value
            if ($row.Cells["Select"].Value -eq $true -and $key -notlike '[Folder]*') {
                $result += @{ Row = $row; Key = $key; Path = $row.Cells["Path"].Value }
            }
        }
        return $result
    }
    
    # Create main form
    $mainForm = New-Object System.Windows.Forms.Form
    $mainForm.Text = "Config Maintenance & Folder Management"
    $mainForm.Width = 920
    $mainForm.Height = 950
    $mainForm.MinimumSize = New-Object System.Drawing.Size(820, 700)
    $mainForm.StartPosition = "CenterScreen"
    $mainForm.FormBorderStyle = "Sizable"
    $mainForm.MaximizeBox = $true
    $mainForm.GetType().GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($mainForm, $true, $null)
    
    # Header label
    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = "Manage Configuration Paths and Folder Content"
    $headerLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerLabel.Height = 28
    $headerLabel.Padding = New-Object System.Windows.Forms.Padding(10, 6, 0, 0)
    $headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $mainForm.Controls.Add($headerLabel)
    
    # Split container: DGV top, tabs bottom
    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $splitContainer.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $splitContainer.SplitterDistance = 460
    $splitContainer.SplitterWidth = 6
    $splitContainer.Panel1MinSize = 200
    $splitContainer.Panel2MinSize = 150

    # Create DataGridView for folder paths
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $dgv.AllowUserToAddRows = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.SelectionMode = "FullRowSelect"
    $dgv.MultiSelect = $true
    $dgv.ReadOnly = $false
    $dgv.AutoSizeColumnsMode = "Fill"
    $dgv.RowHeadersVisible = $false
    
    # Add columns – optimised widths: checkbox narrow, numerics right-aligned
    $colSelect = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn -Property @{
        Name = "Select"; HeaderText = [char]0x2611; Width = 35; ReadOnly = $false
    }
    $null = $dgv.Columns.Add($colSelect)

    $colKey = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
        Name = "ConfigKey"; HeaderText = "Name"; Width = 140; ReadOnly = $true
    }
    $null = $dgv.Columns.Add($colKey)

    $colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
        Name = "Path"; HeaderText = "Current Path"; Width = 320; ReadOnly = $true; AutoSizeMode = "Fill"
    }
    $null = $dgv.Columns.Add($colPath)

    $colExists = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
        Name = "Exists"; HeaderText = "?"; Width = 28; ReadOnly = $true
    }
    $colExists.DefaultCellStyle.Alignment = "MiddleCenter"
    $null = $dgv.Columns.Add($colExists)

    foreach ($numCol in @(
        @{ N = "Files";   H = "Files";   W = 55 },
        @{ N = "Folders"; H = "Dirs";    W = 45 },
        @{ N = "SizeMB";  H = "MB";      W = 60 }
    )) {
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
            Name = $numCol.N; HeaderText = $numCol.H; Width = $numCol.W; ReadOnly = $true
        }
        $c.DefaultCellStyle.Alignment = "MiddleRight"
        $null = $dgv.Columns.Add($c)
    }

    $colNest = New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{
        Name = "CanNest"; HeaderText = "Nest"; Width = 40; ReadOnly = $true
    }
    $colNest.DefaultCellStyle.Alignment = "MiddleCenter"
    $null = $dgv.Columns.Add($colNest)

    # ── Helper: compute row stats and add a DGV row ──
    function Add-FolderRow {
        param([string]$Key, [string]$FolderPath, [string]$NestDefault = "No")
        $exists = Test-Path $FolderPath
        $fileCount = 0; $sizeMB = 0; $folderCount = 0; $canNest = $NestDefault
        if ($exists) {
            try {
                $items = Get-ChildItem -LiteralPath $FolderPath -File -Recurse -ErrorAction SilentlyContinue
                $fileCount  = ($items | Measure-Object).Count
                $sizeBytes  = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                $sizeMB     = [math]::Round($sizeBytes / 1MB, 2)
                $folderCount = @(Get-ChildItem -LiteralPath $FolderPath -Directory -ErrorAction SilentlyContinue).Count
            } catch {
                Write-AppLog "Error scanning folder $FolderPath : $_" "Warning"
            }
        }
        if ($NestDefault -ne "-" -and $Key -ne "DefaultFolder" -and $CurrentPaths.ContainsKey("DefaultFolder")) {
            $defPath = $CurrentPaths["DefaultFolder"]
            $canNest = if (-not $FolderPath.StartsWith($defPath, [StringComparison]::OrdinalIgnoreCase)) { "Yes" } else { "No" }
        }
        $null = $dgv.Rows.Add($false, $Key, $FolderPath,
            $(if ($exists) { "Y" } else { "N" }),
            $fileCount, $folderCount, $sizeMB, $canNest)
    }

    # ── Populate data in hierarchical order ──
    # 1  Workspace root (DefaultFolder / ConfigPath)
    $hierarchicalConfigOrder = @('DefaultFolder','ConfigPath','TempFolder','ReportFolder','DownloadFolder')
    foreach ($key in $hierarchicalConfigOrder) {
        if ($CurrentPaths.ContainsKey($key)) {
            Add-FolderRow -Key $key -FolderPath $CurrentPaths[$key]
        }
    }
    # Any remaining config keys not in the ordered list
    foreach ($key in ($CurrentPaths.Keys | Sort-Object)) {
        if ($hierarchicalConfigOrder -contains $key) { continue }
        Add-FolderRow -Key $key -FolderPath $CurrentPaths[$key]
    }

    # 2  Workspace subfolders – alphabetical within group
    $workspaceFolders = @('agents','checkpoints','config','logs','modules','pki','Report',
                          'scripts','sin_registry','temp','todo','UPM','~DOWNLOADS','~README.md','~REPORTS')
    foreach ($folderName in $workspaceFolders) {
        $folderPath = Join-Path $scriptDir $folderName
        Add-FolderRow -Key "[Folder] $folderName" -FolderPath $folderPath -NestDefault "-"
    }

    # Colour-code: grey background for [Folder] info rows
    foreach ($row in $dgv.Rows) {
        if ($row.Cells["ConfigKey"].Value -like '[Folder]*') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        }
    }

    $splitContainer.Panel1.Controls.Add($dgv)
    
    # ══════════════════════════════════════════════════════════════
    # TabControl – replaces flat action panel with tabbed panes
    # ══════════════════════════════════════════════════════════════
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $splitContainer.Panel2.Controls.Add($tabControl)

    $mainForm.Controls.Add($splitContainer)

    # ─── TAB 1: Folder Actions ───────────────────────────────────
    $tabFolderActions = New-Object System.Windows.Forms.TabPage
    $tabFolderActions.Text = "Folder Actions"
    $tabFolderActions.Padding = New-Object System.Windows.Forms.Padding(8)
    $tabControl.TabPages.Add($tabFolderActions)

    # Nest section
    $nestLabel = New-Object System.Windows.Forms.Label
    $nestLabel.Text = "Nest Selected Config Folders into DefaultFolder:"
    $nestLabel.Location = New-Object System.Drawing.Point(10, 12)
    $nestLabel.Size = New-Object System.Drawing.Size(320, 20)
    $tabFolderActions.Controls.Add($nestLabel)

    $nestButton = New-Object System.Windows.Forms.Button
    $nestButton.Text = "Nest Folders →"
    $nestButton.Location = New-Object System.Drawing.Point(340, 9)
    $nestButton.Size = New-Object System.Drawing.Size(140, 25)
    $nestButton.Add_Click({
        $selectedRows = @()
        foreach ($row in $dgv.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells["Select"].Value -eq $true -and $row.Cells["CanNest"].Value -eq "Yes") {
                $selectedRows += $row
            }
        }
        if ($selectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No nestable folders selected.", "Info", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $selectedKeys = $selectedRows | ForEach-Object { $_.Cells["ConfigKey"].Value }
        $confirmMsg = "Nest $($selectedKeys.Count) folder(s) into DefaultFolder?`n`nSelected: $($selectedKeys -join ', ')`n`nThis will move folder contents and update config."
        $confirm = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Nest", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $defaultFolder = $CurrentPaths["DefaultFolder"]
        foreach ($row in $selectedRows) {
            $key = $row.Cells["ConfigKey"].Value
            $path = $row.Cells["Path"].Value
            if (-not (Test-Path $path)) { continue }
            $dest = Join-Path $defaultFolder $key
            if (Test-Path $dest) { $dest = Join-Path $defaultFolder ("{0}-{1}" -f $key, (Get-Date -Format "yyyyMMdd-HHmmss")) }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            try {
                Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                }
                $remaining = Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
                if (-not $remaining) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                Set-PathForKey -Key $key -Path $dest
                Update-RowStats -Row $row -Path $dest
                Save-CurrentPaths
                Write-AppLog "Nested folder $key into $dest" "Info"
            } catch { Write-AppLog "Nest operation failed for $path : $_" "Error" }
        }
    })
    $tabFolderActions.Controls.Add($nestButton)

    # Content management section
    $contentLabel = New-Object System.Windows.Forms.Label
    $contentLabel.Text = "Content Management (Selected Config Folders):"
    $contentLabel.Location = New-Object System.Drawing.Point(10, 48)
    $contentLabel.Size = New-Object System.Drawing.Size(320, 20)
    $tabFolderActions.Controls.Add($contentLabel)

    $moveButton = New-Object System.Windows.Forms.Button
    $moveButton.Text = "Move Content..."
    $moveButton.Location = New-Object System.Drawing.Point(10, 72)
    $moveButton.Size = New-Object System.Drawing.Size(120, 25)
    $moveButton.Add_Click({
        $selected = Get-SelectedConfigRows
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No config folders selected.", "Info"); return }
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select destination folder for content move"
        if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $folderBrowser.Dispose(); return }
        $dest = $folderBrowser.SelectedPath; $folderBrowser.Dispose()
        $confirmMsg = "Move content from $($selected.Count) folder(s) to:`n$dest`n`nContinue?"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Move", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $selected) {
            if (-not (Test-Path $item.Path)) { continue }
            $target = Join-Path $dest $item.Key
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            try {
                Get-ChildItem -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
                $remaining = Get-ChildItem -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue
                if (-not $remaining) { Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue }
                Update-RowStats -Row $item.Row -Path $item.Path
                Write-AppLog "Moved content from $($item.Path) to $target" "Info"
            } catch { Write-AppLog "Move content failed for $($item.Path) : $_" "Error" }
        }
    })
    $tabFolderActions.Controls.Add($moveButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = "Copy Content..."
    $copyButton.Location = New-Object System.Drawing.Point(140, 72)
    $copyButton.Size = New-Object System.Drawing.Size(120, 25)
    $copyButton.Add_Click({
        $selected = Get-SelectedConfigRows
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No config folders selected.", "Info"); return }
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select destination folder for content copy"
        if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $folderBrowser.Dispose(); return }
        $dest = $folderBrowser.SelectedPath; $folderBrowser.Dispose()
        $confirmMsg = "Copy content from $($selected.Count) folder(s) to:`n$dest`n`nContinue?"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Copy", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $selected) {
            if (-not (Test-Path $item.Path)) { continue }
            $target = Join-Path $dest $item.Key
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            try {
                Get-ChildItem -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.PSIsContainer) { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Recurse -Force -ErrorAction SilentlyContinue }
                    else { Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
                }
                Update-RowStats -Row $item.Row -Path $item.Path
                Write-AppLog "Copied content from $($item.Path) to $target" "Info"
            } catch { Write-AppLog "Copy content failed for $($item.Path) : $_" "Error" }
        }
    })
    $tabFolderActions.Controls.Add($copyButton)

    $abandonButton = New-Object System.Windows.Forms.Button
    $abandonButton.Text = "Abandon Folders"
    $abandonButton.Location = New-Object System.Drawing.Point(270, 72)
    $abandonButton.Size = New-Object System.Drawing.Size(120, 25)
    $abandonButton.Add_Click({
        $selected = Get-SelectedConfigRows
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No config folders selected.", "Info"); return }
        $confirmMsg = "ABANDON WARNING`n`nMark $($selected.Count) folder(s) as abandoned (config reset to defaults).`nContent remains on disk.`n`nFolders: $(($selected | ForEach-Object { $_.Key }) -join ', ')`n`nContinue?"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Abandon", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if ([System.Windows.Forms.MessageBox]::Show("Final confirmation: abandon selected folders?", "Final", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $selected) {
            $defaultPath = Get-DefaultPathForKey -Key $item.Key
            if (-not (Test-Path $defaultPath)) { New-Item -ItemType Directory -Path $defaultPath -Force | Out-Null }
            Set-PathForKey -Key $item.Key -Path $defaultPath
            Update-RowStats -Row $item.Row -Path $defaultPath
            Save-CurrentPaths
            Write-AppLog "Abandoned $($item.Key) and reset to default $defaultPath" "Warning"
        }
    })
    $tabFolderActions.Controls.Add($abandonButton)

    # ─── TAB 2: Archive Operations ───────────────────────────────
    $tabArchive = New-Object System.Windows.Forms.TabPage
    $tabArchive.Text = "Archive Operations"
    $tabArchive.Padding = New-Object System.Windows.Forms.Padding(8)
    $tabControl.TabPages.Add($tabArchive)

    $archiveInPlaceButton = New-Object System.Windows.Forms.Button
    $archiveInPlaceButton.Text = "Archive In-Place"
    $archiveInPlaceButton.Location = New-Object System.Drawing.Point(10, 14)
    $archiveInPlaceButton.Size = New-Object System.Drawing.Size(140, 28)
    $archiveInPlaceButton.Add_Click({
        $selected = @()
        foreach ($row in $dgv.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells["Select"].Value -eq $true -and $row.Cells["Exists"].Value -eq "Y") {
                $selected += @{ Key = $row.Cells["ConfigKey"].Value; Path = $row.Cells["Path"].Value }
            }
        }
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No existing folders selected.", "Info"); return }

        # Collect root-level files for each selected folder
        $folderSummary = @()
        foreach ($item in $selected) {
            if (-not (Test-Path $item.Path)) { continue }
            $rootFiles = @(Get-ChildItem -Path $item.Path -File -ErrorAction SilentlyContinue)
            $folderSummary += @{ Key = $item.Key; Path = $item.Path; Files = $rootFiles }
        }
        $totalFiles = ($folderSummary | ForEach-Object { $_.Files.Count } | Measure-Object -Sum).Sum
        if ($totalFiles -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No root-level files found in the selected folder(s).", "Info")
            return
        }

        $confirmMsg = "Archive In-Place for $($folderSummary.Count) folder(s)?`n" +
                      "Root-level files to archive: $totalFiles`n" +
                      "Files will be zipped into each folder's 'archive' subfolder.`n" +
                      "Originals are deleted ONLY after the zip is verified."
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Archive In-Place", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $successCount = 0; $failCount = 0
        foreach ($entry in $folderSummary) {
            if ($entry.Files.Count -eq 0) { continue }
            $archiveDir = Join-Path $entry.Path 'archive'
            if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
            $zipName = "{0}-archive-v02-{1}.zip" -f $entry.Key, (Get-Date -Format "yyMMddHHmm")
            $zipPath = Join-Path $archiveDir $zipName
            $sourceCount = $entry.Files.Count
            try {
                Compress-Archive -Path ($entry.Files | ForEach-Object { $_.FullName }) -DestinationPath $zipPath -CompressionLevel Optimal -Force
                # Verify: zip exists and contains the expected file count
                if (-not (Test-Path $zipPath)) { throw "Zip file was not created at $zipPath" }
                $zipCheck = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
                $zipEntryCount = $zipCheck.Entries.Count
                $zipCheck.Dispose()
                if ($zipEntryCount -ne $sourceCount) {
                    throw "Zip contains $zipEntryCount entries but expected $sourceCount"
                }
                # Verified -- safe to delete originals
                foreach ($f in $entry.Files) {
                    Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                }
                Write-AppLog "Archive in-place OK: $zipPath ($sourceCount files archived, originals removed)" "Info"
                $successCount++
            }
            catch {
                Write-AppLog "Archive in-place failed for $($entry.Path): $_" "Error"
                $failCount++
            }
        }
        $resultMsg = "Archive In-Place complete.`nSucceeded: $successCount folder(s), Failed: $failCount folder(s).`nCheck logs for details."
        [System.Windows.Forms.MessageBox]::Show($resultMsg, "Archive In-Place")
    })
    $tabArchive.Controls.Add($archiveInPlaceButton)

    $archiveOutYonderButton = New-Object System.Windows.Forms.Button
    $archiveOutYonderButton.Text = "Archive Out-Yonder..."
    $archiveOutYonderButton.Location = New-Object System.Drawing.Point(160, 14)
    $archiveOutYonderButton.Size = New-Object System.Drawing.Size(160, 28)
    $archiveOutYonderButton.Add_Click({
        $selected = @()
        foreach ($row in $dgv.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells["Select"].Value -eq $true -and $row.Cells["Exists"].Value -eq "Y") {
                $selected += @{ Key = $row.Cells["ConfigKey"].Value; Path = $row.Cells["Path"].Value }
            }
        }
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No existing folders selected.", "Info"); return }
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select destination for archive files"
        if ($folderBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $folderBrowser.Dispose(); return }
        $dest = $folderBrowser.SelectedPath; $folderBrowser.Dispose()
        $confirmMsg = "Create archives for $($selected.Count) folder(s) in:  $dest"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Archive Out-Yonder", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $selected) {
            if (-not (Test-Path $item.Path)) { continue }
            $zipName = "{0}-archive-v02-{1}.zip" -f $item.Key, (Get-Date -Format "yyMMddHHmm")
            $zipPath = Join-Path $dest $zipName
            try { Compress-Archive -Path (Join-Path $item.Path "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force; Write-AppLog "Archive created: $zipPath" "Info" }
            catch { Write-AppLog "Archive out-yonder failed for $($item.Path) : $_" "Error" }
        }
        [System.Windows.Forms.MessageBox]::Show("Archive complete. Check logs for details.", "Archive Out-Yonder")
    })
    $tabArchive.Controls.Add($archiveOutYonderButton)

    $clearCleanButton = New-Object System.Windows.Forms.Button
    $clearCleanButton.Text = "Clear-Clean"
    $clearCleanButton.Location = New-Object System.Drawing.Point(330, 14)
    $clearCleanButton.Size = New-Object System.Drawing.Size(120, 28)
    $clearCleanButton.ForeColor = [System.Drawing.Color]::DarkRed
    $clearCleanButton.Add_Click({
        $selected = @()
        foreach ($row in $dgv.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells["Select"].Value -eq $true -and $row.Cells["Exists"].Value -eq "Y") {
                $selected += @{ Row = $row; Key = $row.Cells["ConfigKey"].Value; Path = $row.Cells["Path"].Value; Files = $row.Cells["Files"].Value }
            }
        }
        if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No existing folders selected.", "Info"); return }
        $totalFiles = ($selected | ForEach-Object { [int]$_.Files } | Measure-Object -Sum).Sum
        $confirmMsg = "CLEAR-CLEAN WARNING`n`nDELETE ALL CONTENT from $($selected.Count) folder(s)!`nTotal files: $totalFiles`n`nTHIS CANNOT BE UNDONE!"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Clear-Clean", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if ([System.Windows.Forms.MessageBox]::Show("Final confirmation: permanently delete all content?", "Final", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Stop) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $selected) {
            if (-not (Test-Path $item.Path)) { continue }
            try {
                Get-ChildItem -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                Update-RowStats -Row $item.Row -Path $item.Path
                Write-AppLog "Cleared content for $($item.Path)" "Warning"
            } catch { Write-AppLog "Clear-clean failed for $($item.Path) : $_" "Error" }
        }
    })
    $tabArchive.Controls.Add($clearCleanButton)

    # ─── TAB 3: Config Management ────────────────────────────────
    $tabConfig = New-Object System.Windows.Forms.TabPage
    $tabConfig.Text = "Config Management"
    $tabConfig.Padding = New-Object System.Windows.Forms.Padding(8)
    $tabControl.TabPages.Add($tabConfig)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = "Export Config"
    $exportButton.Location = New-Object System.Drawing.Point(10, 14)
    $exportButton.Size = New-Object System.Drawing.Size(120, 28)
    $exportButton.Add_Click({
        Write-AppLog "User clicked Export Config" "Audit"
        if (-not (Test-Path $configFile)) { [System.Windows.Forms.MessageBox]::Show("Config file not found: $configFile", "Error"); return }
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*"
        $saveDialog.Title = "Export Configuration"
        $saveDialog.FileName = "config-export-$(Get-Date -Format 'yyyyMMdd-HHmmss').xml"
        if ($saveDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $saveDialog.Dispose(); return }
        try { Copy-Item -LiteralPath $configFile -Destination $saveDialog.FileName -Force; Write-AppLog "Config export to: $($saveDialog.FileName)" "Info"; [System.Windows.Forms.MessageBox]::Show("Config exported successfully.", "Export") }
        catch { Write-AppLog "Config export failed: $_" "Error"; [System.Windows.Forms.MessageBox]::Show("Export failed: $_", "Error") }
        finally { $saveDialog.Dispose() }
    })
    $tabConfig.Controls.Add($exportButton)

    $importButton = New-Object System.Windows.Forms.Button
    $importButton.Text = "Import Config"
    $importButton.Location = New-Object System.Drawing.Point(140, 14)
    $importButton.Size = New-Object System.Drawing.Size(120, 28)
    $importButton.Add_Click({
        Write-AppLog "User clicked Import Config" "Audit"
        $openDialog = New-Object System.Windows.Forms.OpenFileDialog
        $openDialog.Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*"
        $openDialog.Title = "Import Configuration"
        if ($openDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $openDialog.Dispose(); return }
        $confirmMsg = "Import configuration from:`n$($openDialog.FileName)`n`nCurrent config will be backed up first. Continue?"
        if ([System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirm Import", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { $openDialog.Dispose(); return }
        try {
            if (Test-Path $configFile) {
                $backup = Join-Path $configDir ("system-variables-backup-{0}.xml" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
                Copy-Item -LiteralPath $configFile -Destination $backup -Force
                Write-AppLog "Config backup created: $backup" "Info"
            }
            Copy-Item -LiteralPath $openDialog.FileName -Destination $configFile -Force
            $script:_XmlCache.ConfigFile = $null; $script:_XmlCache.LastConfigLoad = $null
            $CurrentPaths["ConfigPath"] = $ConfigPath; $CurrentPaths["DefaultFolder"] = $DefaultFolder
            $CurrentPaths["TempFolder"] = $TempFolder; $CurrentPaths["ReportFolder"] = $ReportFolder
            $CurrentPaths["DownloadFolder"] = $DownloadFolder
            Write-AppLog "Config imported from: $($openDialog.FileName)" "Info"
            [System.Windows.Forms.MessageBox]::Show("Config imported successfully.", "Import")
        } catch { Write-AppLog "Config import failed: $_" "Error"; [System.Windows.Forms.MessageBox]::Show("Import failed: $_", "Error") }
        finally { $openDialog.Dispose() }
    })
    $tabConfig.Controls.Add($importButton)

    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = "Reset to Defaults"
    $resetButton.Location = New-Object System.Drawing.Point(270, 14)
    $resetButton.Size = New-Object System.Drawing.Size(130, 28)
    $resetButton.ForeColor = [System.Drawing.Color]::DarkRed
    $resetButton.Add_Click({
        Write-AppLog "User clicked Reset to Defaults" "Audit"
        if ([System.Windows.Forms.MessageBox]::Show("RESET WARNING`n`nReset ALL configuration to factory defaults?`nCurrent config backed up.", "Confirm Reset", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            if (Test-Path $configFile) {
                $backup = Join-Path $configDir ("system-variables-backup-{0}.xml" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
                Copy-Item -LiteralPath $configFile -Destination $backup -Force
                Write-AppLog "Config backup created: $backup" "Info"
            }
            Initialize-ConfigFile -ConfigFile $configFile -LogsDir $logsDir -ConfigDir $configDir -ScriptsDir $scriptsDir
            $script:_XmlCache.ConfigFile = $null; $script:_XmlCache.LastConfigLoad = $null
            $CurrentPaths["ConfigPath"] = $ConfigPath; $CurrentPaths["DefaultFolder"] = $DefaultFolder
            $CurrentPaths["TempFolder"] = $TempFolder; $CurrentPaths["ReportFolder"] = $ReportFolder
            $CurrentPaths["DownloadFolder"] = $DownloadFolder
            Write-AppLog "Config reset to defaults" "Warning"
            [System.Windows.Forms.MessageBox]::Show("Config reset to defaults.", "Reset")
        } catch { Write-AppLog "Config reset failed: $_" "Error"; [System.Windows.Forms.MessageBox]::Show("Reset failed: $_", "Error") }
    })
    $tabConfig.Controls.Add($resetButton)

    # ─── TAB 4: Remote Paths ─────────────────────────────────────
    $tabRemote = New-Object System.Windows.Forms.TabPage
    $tabRemote.Text = "Remote Paths"
    $tabRemote.Padding = New-Object System.Windows.Forms.Padding(8)
    $tabRemote.AutoScroll = $true
    $tabControl.TabPages.Add($tabRemote)

    $remotePathDefs = @(
        @{ Label = "RemoteUpdatePath";   XPath = "RemoteUpdatePath"   },
        @{ Label = "RemoteConfigPath";   XPath = "RemoteConfigPath"   },
        @{ Label = "RemoteTemplatePath"; XPath = "RemoteTemplatePath" },
        @{ Label = "RemoteBackupPath";   XPath = "RemoteBackupPath"   },
        @{ Label = "RemoteArchivePath";  XPath = "RemoteArchivePath"  },
        @{ Label = "RemoteLinksPath";    XPath = "RemoteLinksPath"    },
        @{ Label = "RemoteDownloadPath"; XPath = "RemoteDownloadPath" }
    )
    $remoteTextBoxes = @{}
    $ry = 12
    foreach ($def in $remotePathDefs) {
        $rLabel = New-Object System.Windows.Forms.Label
        $rLabel.Text = $def.Label + ":"
        $rLabel.Location = New-Object System.Drawing.Point(6, $ry)
        $rLabel.Size = New-Object System.Drawing.Size(145, 20)
        $rLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $tabRemote.Controls.Add($rLabel)

        $rTextBox = New-Object System.Windows.Forms.TextBox
        $rTextBox.Location = New-Object System.Drawing.Point(154, ($ry - 1))
        $rTextBox.Size = New-Object System.Drawing.Size(560, 22)
        $cfgVal = try { [string](Get-ConfigSubValue $def.XPath) } catch { "" }
        $rTextBox.Text = if ($cfgVal) { $cfgVal } else { "" }
        $tabRemote.Controls.Add($rTextBox)
        $remoteTextBoxes[$def.XPath] = $rTextBox

        $rBrowse = New-Object System.Windows.Forms.Button
        $rBrowse.Text = "..."
        $rBrowse.Location = New-Object System.Drawing.Point(720, ($ry - 2))
        $rBrowse.Size = New-Object System.Drawing.Size(60, 24)
        $defCopy = $def; $tbCopy = $rTextBox
        $browseHandler = {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = "Select path for $($defCopy.Label)"
            $fb.SelectedPath = if ([string]::IsNullOrWhiteSpace($tbCopy.Text)) { $scriptDir } else { $tbCopy.Text }
            if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tbCopy.Text = $fb.SelectedPath }
            $fb.Dispose()
        }.GetNewClosure()
        $rBrowse.Add_Click($browseHandler)
        $tabRemote.Controls.Add($rBrowse)
        $ry += 32
    }

    $saveRemoteButton = New-Object System.Windows.Forms.Button
    $saveRemoteButton.Text = "Save All Remote Paths"
    $saveRemoteButton.Location = New-Object System.Drawing.Point(6, ($ry + 6))
    $saveRemoteButton.Size = New-Object System.Drawing.Size(170, 26)
    $saveRemoteButton.Add_Click({
        foreach ($def in $remotePathDefs) {
            $val = $remoteTextBoxes[$def.XPath].Text.Trim()
            try { Set-ConfigSubValue -XPath $def.XPath -Value $val; Set-Variable -Name $def.Label -Value $val -Scope Script -ErrorAction SilentlyContinue; Write-AppLog "Remote path saved: $($def.XPath) = $val" "Info" }
            catch { Write-AppLog "Failed to save $($def.XPath): $_" "Warning" }
        }
        [System.Windows.Forms.MessageBox]::Show("Remote paths saved to config.", "Saved", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $tabRemote.Controls.Add($saveRemoteButton)

    $clearRemoteButton = New-Object System.Windows.Forms.Button
    $clearRemoteButton.Text = "Clear All"
    $clearRemoteButton.Location = New-Object System.Drawing.Point(186, ($ry + 6))
    $clearRemoteButton.Size = New-Object System.Drawing.Size(90, 26)
    $clearRemoteButton.ForeColor = [System.Drawing.Color]::DarkRed
    $clearRemoteButton.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show("Clear all remote path fields?", "Confirm", "YesNo", [System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($tb in $remoteTextBoxes.Values) { $tb.Text = "" }
        }
    })
    $tabRemote.Controls.Add($clearRemoteButton)

    $compareRemoteButton = New-Object System.Windows.Forms.Button
    $compareRemoteButton.Text = "Compare && Sync from RemoteUpdatePath..."
    $compareRemoteButton.Location = New-Object System.Drawing.Point(6, ($ry + 38))
    $compareRemoteButton.Size = New-Object System.Drawing.Size(280, 26)
    $compareRemoteButton.Add_Click({
        $remotePath = $remoteTextBoxes["RemoteUpdatePath"].Text.Trim()
        if ([string]::IsNullOrWhiteSpace($remotePath)) {
            [System.Windows.Forms.MessageBox]::Show("RemoteUpdatePath is not set.", "Not Set", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning); return
        }
        if (-not (Test-Path $remotePath)) {
            [System.Windows.Forms.MessageBox]::Show("RemoteUpdatePath is not accessible:`n$remotePath", "Cannot Read Remote", "OK", [System.Windows.Forms.MessageBoxIcon]::Error); return
        }
        $localRoot = $scriptDir
        Write-AppLog "Comparing RemoteUpdatePath '$remotePath' with local root '$localRoot'" "Info"
        $whatIfLines = [System.Collections.Generic.List[string]]::new()
        $copyQueue   = [System.Collections.Generic.List[hashtable]]::new()
        try { $remoteFiles = Get-ChildItem -Path $remotePath -File -Recurse -ErrorAction Stop }
        catch { [System.Windows.Forms.MessageBox]::Show("Failed to enumerate remote path:`n$_", "Error", "OK", [System.Windows.Forms.MessageBoxIcon]::Error); return }
        foreach ($rf in $remoteFiles) {
            $relPath = $rf.FullName.Substring($remotePath.TrimEnd('\').Length).TrimStart('\')
            if ($relPath -match '\.\.' -or $relPath -match '^[\\/]') { Write-AppLog "Skipped unsafe relative path: $relPath" "Warning"; continue }
            if ($rf.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { Write-AppLog "Skipped reparse point: $relPath" "Warning"; continue }
            $localFile = Join-Path $localRoot $relPath
            if (-not (Test-Path $localFile)) {
                $whatIfLines.Add("  [NEW]     $relPath"); $copyQueue.Add(@{ Src = $rf.FullName; Dst = $localFile })
            } else {
                $lf = Get-Item $localFile
                if ($rf.LastWriteTime -gt $lf.LastWriteTime) {
                    $diff = [math]::Round(($rf.LastWriteTime - $lf.LastWriteTime).TotalMinutes, 1)
                    $whatIfLines.Add("  [NEWER +${diff}m] $relPath"); $copyQueue.Add(@{ Src = $rf.FullName; Dst = $localFile })
                }
            }
        }
        if ($copyQueue.Count -eq 0) {
            Write-AppLog "Remote compare: no differences found" "Info"
            [System.Windows.Forms.MessageBox]::Show("No differences found.", "Up To Date", "OK", [System.Windows.Forms.MessageBoxIcon]::Information); return
        }
        $whatIfText = "WhatIf - Files to copy from RemoteUpdatePath:`nRemote : $remotePath`nLocal  : $localRoot`nFiles  : $($copyQueue.Count)`n`n" + ($whatIfLines -join "`n")
        $previewForm = New-Object System.Windows.Forms.Form
        $previewForm.Text = "Compare Result - WhatIf Preview"
        $previewForm.Size = New-Object System.Drawing.Size(820, 500)
        $previewForm.StartPosition = "CenterScreen"
        $previewForm.FormBorderStyle = "FixedDialog"
        $previewTb = New-Object System.Windows.Forms.TextBox
        $previewTb.Multiline = $true; $previewTb.ReadOnly = $true; $previewTb.ScrollBars = "Both"
        $previewTb.Font = New-Object System.Drawing.Font("Consolas", 9)
        $previewTb.Location = New-Object System.Drawing.Point(10, 10)
        $previewTb.Size = New-Object System.Drawing.Size(790, 390)
        $previewTb.Text = $whatIfText
        $previewForm.Controls.Add($previewTb)
        $applySyncBtn = New-Object System.Windows.Forms.Button
        $applySyncBtn.Text = "Apply Sync Now"
        $applySyncBtn.Location = New-Object System.Drawing.Point(600, 410)
        $applySyncBtn.Size = New-Object System.Drawing.Size(120, 30)
        $applySyncBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $previewForm.Controls.Add($applySyncBtn)
        $cancelSyncBtn = New-Object System.Windows.Forms.Button
        $cancelSyncBtn.Text = "Cancel"
        $cancelSyncBtn.Location = New-Object System.Drawing.Point(490, 410)
        $cancelSyncBtn.Size = New-Object System.Drawing.Size(100, 30)
        $cancelSyncBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $previewForm.Controls.Add($cancelSyncBtn)
        $previewForm.AcceptButton = $applySyncBtn; $previewForm.CancelButton = $cancelSyncBtn
        if ($previewForm.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $previewForm.Dispose(); return }
        $previewForm.Dispose()
        $successCount = 0; $errorCount = 0
        foreach ($entry in $copyQueue) {
            $dir = Split-Path -Parent $entry.Dst
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            try { Copy-Item -LiteralPath $entry.Src -Destination $entry.Dst -Force; $successCount++ }
            catch { Write-AppLog "Sync copy failed: $($entry.Src) -> $($entry.Dst) : $_" "Error"; $errorCount++ }
        }
        $summary = "Sync complete.`n`nCopied : $successCount file(s)`nFailed : $errorCount file(s)"
        Write-AppLog $summary "Info"
        [System.Windows.Forms.MessageBox]::Show($summary, "Sync Complete", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $tabRemote.Controls.Add($compareRemoteButton)

    # ─── TAB 5: Build Package ────────────────────────────────────
    $tabPackage = New-Object System.Windows.Forms.TabPage
    $tabPackage.Text = "Build Package"
    $tabPackage.Padding = New-Object System.Windows.Forms.Padding(8)
    $tabPackage.AutoScroll = $true
    $tabControl.TabPages.Add($tabPackage)

    # Description label
    $pkgInfo = New-Object System.Windows.Forms.Label
    $pkgInfo.Text = "Build a distributable .zip package from the workspace. Select/deselect folders to include."
    $pkgInfo.Location = New-Object System.Drawing.Point(10, 8)
    $pkgInfo.Size = New-Object System.Drawing.Size(820, 18)
    $tabPackage.Controls.Add($pkgInfo)

    # Folder inclusion checklist (CheckedListBox)
    $pkgFolderList = New-Object System.Windows.Forms.CheckedListBox
    $pkgFolderList.Location = New-Object System.Drawing.Point(10, 30)
    $pkgFolderList.Size = New-Object System.Drawing.Size(520, 240)
    $pkgFolderList.CheckOnClick = $true
    $pkgFolderList.Font = New-Object System.Drawing.Font("Consolas", 9)

    # Uncompressed size label
    $pkgSizeLabel = New-Object System.Windows.Forms.Label
    $pkgSizeLabel.Text = "Estimated uncompressed size: calculating..."
    $pkgSizeLabel.Location = New-Object System.Drawing.Point(10, 276)
    $pkgSizeLabel.Size = New-Object System.Drawing.Size(520, 20)
    $pkgSizeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $tabPackage.Controls.Add($pkgSizeLabel)

    # Build the folder list from workspace contents
    $pkgExcludeDefaults = @(Get-ConfigList "Do-Not-VersionTag-FoldersFiles") + '.git'
    $allWorkspaceItems = @(Get-ChildItem -Path $scriptDir -Force -ErrorAction SilentlyContinue)
    $pkgFolderSizes = @{}   # name -> bytes
    foreach ($wi in $allWorkspaceItems) {
        $displayName = $wi.Name
        $sizeBytes = 0
        if ($wi.PSIsContainer) {
            try {
                $measurement = Get-ChildItem -LiteralPath $wi.FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
                $sizeBytes = if ($measurement.Sum) { $measurement.Sum } else { 0 }
            }
            catch { $sizeBytes = 0 }
            $sizeMBDisp = [math]::Round($sizeBytes / 1MB, 2)
            $displayName = "{0,-30} {1,8} MB  (dir)" -f $wi.Name, $sizeMBDisp
        } else {
            $sizeBytes = $wi.Length
            $sizeMBDisp = [math]::Round($sizeBytes / 1MB, 2)
            $displayName = "{0,-30} {1,8} MB" -f $wi.Name, $sizeMBDisp
        }
        $pkgFolderSizes[$wi.Name] = $sizeBytes
        $idx = $pkgFolderList.Items.Add($displayName)
        # Pre-check items NOT in exclude list
        $isIncluded = ($pkgExcludeDefaults -notcontains $wi.Name)
        $pkgFolderList.SetItemChecked($idx, $isIncluded)
    }
    $tabPackage.Controls.Add($pkgFolderList)

    # Update size estimate when selections change
    function Update-PackageSizeEstimate {
        $totalBytes = 0
        for ($i = 0; $i -lt $pkgFolderList.Items.Count; $i++) {
            if ($pkgFolderList.GetItemChecked($i)) {
                $itemName = ($allWorkspaceItems[$i]).Name
                if ($pkgFolderSizes.ContainsKey($itemName)) { $totalBytes += $pkgFolderSizes[$itemName] }
            }
        }
        $totalMB = [math]::Round($totalBytes / 1MB, 2)
        $pkgSizeLabel.Text = "Estimated uncompressed size: $totalMB MB  ($($totalBytes.ToString('N0')) bytes)"
    }
    Update-PackageSizeEstimate
    $pkgFolderList.Add_ItemCheck({
        # ItemCheck fires before state changes, so use BeginInvoke to defer
        $pkgFolderList.BeginInvoke([Action]{ Update-PackageSizeEstimate })
    })

    # Right side – options panel
    $pkgOptGroup = New-Object System.Windows.Forms.GroupBox
    $pkgOptGroup.Text = "Package Options"
    $pkgOptGroup.Location = New-Object System.Drawing.Point(545, 30)
    $pkgOptGroup.Size = New-Object System.Drawing.Size(280, 240)
    $tabPackage.Controls.Add($pkgOptGroup)

    # Drop folder contents before packaging
    $chkDropContents = New-Object System.Windows.Forms.CheckBox
    $chkDropContents.Text = "Clear temp/logs/reports first"
    $chkDropContents.Location = New-Object System.Drawing.Point(12, 22)
    $chkDropContents.Size = New-Object System.Drawing.Size(250, 20)
    $pkgOptGroup.Controls.Add($chkDropContents)

    # Sign scripts in package
    $chkSign = New-Object System.Windows.Forms.CheckBox
    $chkSign.Text = "Sign scripts (.ps1/.psm1/.psd1)"
    $chkSign.Location = New-Object System.Drawing.Point(12, 46)
    $chkSign.Size = New-Object System.Drawing.Size(250, 20)
    $pkgOptGroup.Controls.Add($chkSign)

    # Bake in remote update path
    $chkBakeRemote = New-Object System.Windows.Forms.CheckBox
    $chkBakeRemote.Text = "Bake in RemoteUpdatePath"
    $chkBakeRemote.Location = New-Object System.Drawing.Point(12, 70)
    $chkBakeRemote.Size = New-Object System.Drawing.Size(250, 20)
    $pkgOptGroup.Controls.Add($chkBakeRemote)

    # Compression level
    $lblCompression = New-Object System.Windows.Forms.Label
    $lblCompression.Text = "Compression:"
    $lblCompression.Location = New-Object System.Drawing.Point(12, 100)
    $lblCompression.Size = New-Object System.Drawing.Size(90, 20)
    $pkgOptGroup.Controls.Add($lblCompression)

    $cboCompression = New-Object System.Windows.Forms.ComboBox
    $cboCompression.DropDownStyle = "DropDownList"
    $cboCompression.Location = New-Object System.Drawing.Point(105, 97)
    $cboCompression.Size = New-Object System.Drawing.Size(160, 22)
    $cboCompression.Items.AddRange(@("Optimal","Fastest","NoCompression"))
    $cboCompression.SelectedIndex = 0
    $pkgOptGroup.Controls.Add($cboCompression)

    # Encryption
    $chkEncrypt = New-Object System.Windows.Forms.CheckBox
    $chkEncrypt.Text = "Encrypt zip (requires 7-Zip)"
    $chkEncrypt.Location = New-Object System.Drawing.Point(12, 130)
    $chkEncrypt.Size = New-Object System.Drawing.Size(250, 20)
    $pkgOptGroup.Controls.Add($chkEncrypt)

    $lblEncMethod = New-Object System.Windows.Forms.Label
    $lblEncMethod.Text = "Method:"
    $lblEncMethod.Location = New-Object System.Drawing.Point(30, 155)
    $lblEncMethod.Size = New-Object System.Drawing.Size(55, 20)
    $lblEncMethod.Enabled = $false
    $pkgOptGroup.Controls.Add($lblEncMethod)

    $cboEncMethod = New-Object System.Windows.Forms.ComboBox
    $cboEncMethod.DropDownStyle = "DropDownList"
    $cboEncMethod.Location = New-Object System.Drawing.Point(88, 152)
    $cboEncMethod.Size = New-Object System.Drawing.Size(177, 22)
    $cboEncMethod.Items.AddRange(@("AES-256 (7z -mem=AES256)","ZipCrypto (legacy)"))
    $cboEncMethod.SelectedIndex = 0
    $cboEncMethod.Enabled = $false
    $pkgOptGroup.Controls.Add($cboEncMethod)

    $lblPassword = New-Object System.Windows.Forms.Label
    $lblPassword.Text = "Password:"
    $lblPassword.Location = New-Object System.Drawing.Point(30, 180)
    $lblPassword.Size = New-Object System.Drawing.Size(55, 20)
    $lblPassword.Enabled = $false
    $pkgOptGroup.Controls.Add($lblPassword)

    $txtPassword = New-Object System.Windows.Forms.TextBox
    $txtPassword.Location = New-Object System.Drawing.Point(88, 177)
    $txtPassword.Size = New-Object System.Drawing.Size(177, 22)
    $txtPassword.UseSystemPasswordChar = $true
    $txtPassword.Enabled = $false
    $pkgOptGroup.Controls.Add($txtPassword)

    # Toggle encryption controls
    $chkEncrypt.Add_CheckedChanged({
        $en = $chkEncrypt.Checked
        $cboEncMethod.Enabled = $en; $lblEncMethod.Enabled = $en
        $txtPassword.Enabled  = $en; $lblPassword.Enabled  = $en
    })

    # Copy to remote
    $chkCopyRemote = New-Object System.Windows.Forms.CheckBox
    $chkCopyRemote.Text = "Copy zip to RemoteUpdatePath"
    $chkCopyRemote.Location = New-Object System.Drawing.Point(12, 210)
    $chkCopyRemote.Size = New-Object System.Drawing.Size(250, 20)
    $pkgOptGroup.Controls.Add($chkCopyRemote)

    # ── Build button ──
    $btnBuildPackage = New-Object System.Windows.Forms.Button
    $btnBuildPackage.Text = "Build Package"
    $btnBuildPackage.Location = New-Object System.Drawing.Point(545, 276)
    $btnBuildPackage.Size = New-Object System.Drawing.Size(140, 30)
    $btnBuildPackage.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnBuildPackage.Add_Click({
        Write-AppLog "User initiated Build Package from Config Maintenance" "Audit"

        # Gather selected folder names
        $selectedItems = @()
        for ($i = 0; $i -lt $pkgFolderList.Items.Count; $i++) {
            if ($pkgFolderList.GetItemChecked($i)) {
                $selectedItems += $allWorkspaceItems[$i].FullName
            }
        }
        if ($selectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No folders/files selected for packaging.", "Info"); return
        }

        # Version info for zip name
        $versionString = Get-VersionString
        $zipName = "pwshGUI-v02-$versionString-$(Get-Date -Format 'yyMMddHHmm').zip"
        $destinationPath = Join-Path $DownloadFolder $zipName

        # Clear temp folders if requested
        if ($chkDropContents.Checked) {
            Clear-FolderContents -Path $DownloadFolder -Label "~DOWNLOADS"
            Clear-FolderContents -Path $ReportFolder -Label "~REPORTS"
            Clear-FolderContents -Path $logsDir -Label "logs"
            Clear-FolderContents -Path $TempFolder -Label "temp"
        }

        # Bake-in remote path
        $configBackup = $null; $configUpdated = $false
        if ($chkBakeRemote.Checked) {
            $remoteVal = try { $remoteTextBoxes["RemoteUpdatePath"].Text.Trim() } catch { "" }
            if ($remoteVal) {
                $configBackup = Get-ConfigSubValue "RemoteUpdatePath"
                Set-ConfigSubValue -XPath "RemoteUpdatePath" -Value $remoteVal
                $configUpdated = $true
                Write-AppLog "Bake-in RemoteUpdatePath set to $remoteVal" "Info"
            }
        }

        # Sign scripts
        if ($chkSign.Checked) {
            $signingSubject = try { Get-ConfigSubValue "CodeSigningSubject" } catch { "CN=PowerShellGUI" }
            $cert = Initialize-CodeSigningCert -Subject $signingSubject
            if ($cert) {
                Write-AppLog "Signing scripts in place using $($cert.Subject)" "Info"
                Get-CachedScriptFiles | ForEach-Object {
                    try { Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert | Out-Null }
                    catch { Write-AppLog "Failed to sign $($_.FullName): $_" "Warning" }
                }
                Clear-FileListCache  # Invalidate after signing changes
            }
        }

        # Build package
        $compressionLevel = $cboCompression.SelectedItem
        Write-AppLog "Packaging workspace to $destinationPath (compression: $compressionLevel)" "Info"

        if ($chkEncrypt.Checked) {
            $password = $txtPassword.Text
            if ([string]::IsNullOrWhiteSpace($password)) {
                [System.Windows.Forms.MessageBox]::Show("Encryption requires a password.", "Password Required", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $sevenZipPath = Resolve-7ZipPath
            if (-not $sevenZipPath) {
                [System.Windows.Forms.MessageBox]::Show("7-Zip not found. Install 7-Zip or disable encryption.", "7-Zip Required", "OK", [System.Windows.Forms.MessageBoxIcon]::Error)
                return
            }
            $encMethod = if ($cboEncMethod.SelectedIndex -eq 0) { "AES256" } else { "ZipCrypto" }
            # Build list file for 7-Zip
            $listFile = Join-Path $env:TEMP ("pwshgui_packlist_{0}.txt" -f ([guid]::NewGuid().ToString("N")))
            try {
                $relItems = $selectedItems | ForEach-Object { $_.Substring($scriptDir.Length).TrimStart("\") }
                Set-Content -Path $listFile -Value $relItems -Encoding ASCII
                $zipArgs = @("a", "-tzip", "-mem=$encMethod", "-mhe=on", "-p$password", $destinationPath, "@$listFile")
                Push-Location $scriptDir
                & $sevenZipPath @zipArgs | Out-Null
                Pop-Location
                Write-AppLog "Encrypted package created ($encMethod): $destinationPath" "Info"
            } finally { if (Test-Path $listFile) { Remove-Item $listFile -Force } }
        } else {
            Compress-Archive -Path $selectedItems -DestinationPath $destinationPath -CompressionLevel $compressionLevel -Force
        }

        # Restore baked config
        if ($configUpdated -and $configBackup) {
            Set-ConfigSubValue -XPath "RemoteUpdatePath" -Value $configBackup
        }

        # Copy to remote
        if ($chkCopyRemote.Checked) {
            $remoteVal = try { $remoteTextBoxes["RemoteUpdatePath"].Text.Trim() } catch { "" }
            if ($remoteVal) {
                $remoteBuildDir = Join-Path $remoteVal "~BUILD-ZIPS"
                try {
                    if (-not (Test-Path $remoteBuildDir)) { New-Item -ItemType Directory -Path $remoteBuildDir -Force | Out-Null }
                    Copy-Item -Path $destinationPath -Destination $remoteBuildDir -Force
                    Write-AppLog "Copied build zip to $remoteBuildDir" "Info"
                } catch { Write-AppLog "Failed to copy build zip to ${remoteBuildDir}: $_" "Warning" }
            }
        }

        Write-AppLog "Package created: $destinationPath" "Info"
        [System.Windows.Forms.MessageBox]::Show("Package created successfully:`n$destinationPath", "Build Package", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $tabPackage.Controls.Add($btnBuildPackage)

    # Select All / Deselect All buttons
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select All"
    $btnSelectAll.Location = New-Object System.Drawing.Point(700, 276)
    $btnSelectAll.Size = New-Object System.Drawing.Size(56, 30)
    $btnSelectAll.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $btnSelectAll.Add_Click({
        for ($i = 0; $i -lt $pkgFolderList.Items.Count; $i++) { $pkgFolderList.SetItemChecked($i, $true) }
        Update-PackageSizeEstimate
    })
    $tabPackage.Controls.Add($btnSelectAll)

    $btnDeselectAll = New-Object System.Windows.Forms.Button
    $btnDeselectAll.Text = "Clear"
    $btnDeselectAll.Location = New-Object System.Drawing.Point(762, 276)
    $btnDeselectAll.Size = New-Object System.Drawing.Size(56, 30)
    $btnDeselectAll.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $btnDeselectAll.Add_Click({
        for ($i = 0; $i -lt $pkgFolderList.Items.Count; $i++) { $pkgFolderList.SetItemChecked($i, $false) }
        Update-PackageSizeEstimate
    })
    $tabPackage.Controls.Add($btnDeselectAll)

    # Close button
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(750, 878)
    $closeButton.Size = New-Object System.Drawing.Size(120, 30)
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $mainForm.Controls.Add($closeButton)
    $mainForm.CancelButton = $closeButton

    # Show form
    $null = $mainForm.ShowDialog()
    $mainForm.Dispose()
}

# Define LOCAL region Configuration
$ConfigPath = Join-Path $scriptDir "config"
$DefaultFolder = $scriptDir
$TempFolder = Join-Path $scriptDir "temp"
$ReportFolder = Join-Path $scriptDir "~REPORTS"
$DownloadFolder = Join-Path $scriptDir "~DOWNLOADS"

$localPathDefaults = @{
    ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $scriptDir } else { $ConfigPath }
    DefaultFolder = if ([string]::IsNullOrWhiteSpace($DefaultFolder)) { $scriptDir } else { $DefaultFolder }
    TempFolder = if ([string]::IsNullOrWhiteSpace($TempFolder)) { $scriptDir } else { $TempFolder }
    ReportFolder = if ([string]::IsNullOrWhiteSpace($ReportFolder)) { $scriptDir } else { $ReportFolder }
    DownloadFolder = if ([string]::IsNullOrWhiteSpace($DownloadFolder)) { (Join-Path $scriptDir "~DOWNLOADS") } else { $DownloadFolder }
}

# For now use default paths directly to bypass unified form issues
$ConfigPath = $localPathDefaults.ConfigPath
$DefaultFolder = $localPathDefaults.DefaultFolder
$TempFolder = $localPathDefaults.TempFolder
$ReportFolder = $localPathDefaults.ReportFolder
$DownloadFolder = $localPathDefaults.DownloadFolder

# Create local directories if they don't exist
Assert-DirectoryExists $ConfigPath, $DefaultFolder, $TempFolder, $ReportFolder, $DownloadFolder

# Define GLOBAL script directory and Files (already set above; re-affirmed here for clarity)
# NOTE: Individual $xxxDir vars are retained for backward compatibility.
#       The path registry in PwShGUICore (Get-ProjectPath / Get-AllProjectPaths) is the
#       canonical source for new code.  Initialize-CorePaths populates it above.
$configDir = Join-Path $scriptDir "config"
$modulesDir = Join-Path $scriptDir "modules"
$logsDir = Join-Path $scriptDir "logs"
$scriptsDir = Join-Path $scriptDir "scripts"
$versionsDir = Join-Path $scriptDir '.history\PwShGUI-Versions'
if (-not (Test-Path $versionsDir)) { New-Item -ItemType Directory -Path $versionsDir -Force | Out-Null }
$configFile = Join-Path $configDir "system-variables.xml"
$linksConfigFile = Join-Path $configDir "links.xml"
$avpnConfigFile = Join-Path $configDir "AVPN-devices.json"
$avpnModulePath = Join-Path $modulesDir "AVPN-Tracker.psm1"

# Defined REMOTE script directory and Files
$RemoteUpdatePath = ""
$RemoteConfigPath = ""
$RemoteTemplatePath = ""
$RemoteBackupPath = ""
$RemoteArchivePath = ""
$RemoteLinksPath = ""
$RemoteDownloadPath = ""

# ── Load remote paths from config (so status bar shows correct state) ──
try {
    if (Get-Command Get-ConfigSubValue -ErrorAction SilentlyContinue) {
        foreach ($rpKey in @('RemoteUpdatePath','RemoteConfigPath','RemoteTemplatePath',
                             'RemoteBackupPath','RemoteArchivePath','RemoteLinksPath','RemoteDownloadPath')) {
            $val = try { [string](Get-ConfigSubValue $rpKey) } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                Set-Variable -Name $rpKey -Value $val -Scope Script
            }
        }
    }
} catch { <# Non-fatal: remote paths stay empty #> }

# Create GLOBAL directories if they don't exist
$logsArchiveDir = Join-Path $logsDir "archive"
Assert-DirectoryExists $scriptDir, $configDir, $modulesDir, $logsDir, $logsArchiveDir, $scriptsDir
if (-not (Test-Path $configFile)) { New-Item -ItemType File -Path $configFile -Force | Out-Null }
if (-not (Test-Path $linksConfigFile)) { New-Item -ItemType File -Path $linksConfigFile -Force | Out-Null }
if (-not (Test-Path $avpnConfigFile)) { New-Item -ItemType File -Path $avpnConfigFile -Force | Out-Null }
if (-not (Test-Path $avpnModulePath)) { Write-Warning "AVPN module not found at $avpnModulePath" }

# ==================== LOGGING FUNCTIONS ====================
# Write-AppLog, Write-ScriptLog, Export-LogBuffer -- now provided by PwShGUICore module
# (Inline definitions removed -- see modules/PwShGUICore.psm1)

# Import AVPN module if available
if (Test-Path $avpnModulePath) {
    Import-Module $avpnModulePath -Force
} else {
    Write-AppLog "AVPN module not found at $avpnModulePath" "Warning"
}

# Import SASC (Secrets Access & Security Checks) modules if available
$sascModulePath = Get-ProjectPath SascModule
$sascAdaptersPath = Get-ProjectPath SascAdapters
if (Test-Path $sascModulePath) {
    Import-Module $sascModulePath -Force
    Write-AppLog "SASC module loaded from $sascModulePath" "Info"
} else {
    Write-AppLog "SASC module not found at $sascModulePath" "Warning"
}
if (Test-Path $sascAdaptersPath) {
    Import-Module $sascAdaptersPath -Force
    Write-AppLog "SASC-Adapters module loaded from $sascAdaptersPath" "Info"
} else {
    Write-AppLog "SASC-Adapters module not found at $sascAdaptersPath" "Warning"
}
# Initialize SASC module state
try {
    if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
        $script:_SASCAvailable = Initialize-SASCModule -ScriptDir $scriptDir
        Write-AppLog "SASC initialized: $_SASCAvailable" "Info"
    } else {
        $script:_SASCAvailable = $false
    }
} catch {
    $script:_SASCAvailable = $false
    Write-AppLog "SASC initialization failed: $($_.Exception.Message)" "Warning"
}

# ==================== CONFIG FUNCTIONS ====================
# Initialize-ConfigFile is now provided by PwShGUICore module.
# Call sites pass $configFile, $logsDir, $configDir, $scriptsDir explicitly.

function Get-ConfigVariable {
    param([string]$VariableName)
    
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return $null
    }
    
    [xml]$xml = Get-Content $configFile
    return $xml.SystemVariables.$VariableName.InnerText
}

function Get-ButtonConfiguration {
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return @{ Left = @(); Right = @() }
    }
    
    [xml]$xml = Get-Content $configFile
    $buttonConfig = @{ Left = @(); Right = @() }
    
    # Load left column buttons
    if ($xml.SystemVariables.Buttons.LeftColumn) {
        foreach ($btn in $xml.SystemVariables.Buttons.LeftColumn.Button) {
            $buttonConfig.Left += @{
                ScriptName = $btn.ScriptName
                DisplayName = $btn.DisplayName
            }
        }
    }
    
    # Load right column buttons
    if ($xml.SystemVariables.Buttons.RightColumn) {
        foreach ($btn in $xml.SystemVariables.Buttons.RightColumn.Button) {
            $buttonConfig.Right += @{
                ScriptName = $btn.ScriptName
                DisplayName = $btn.DisplayName
                ScriptPath = $btn.ScriptPath
            }
        }
    }
    
    return $buttonConfig
}

# ------------------ configuration helpers ------------------
function Get-ConfigSubValue {
    param([string]$XPath)
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return $null
    }
    
    # Load config once and cache it
    if (-not $script:_XmlCache.ConfigFile -or -not $script:_XmlCache.LastConfigLoad -or (Test-Path $configFile -NewerThan $script:_XmlCache.LastConfigLoad)) {
        $script:_XmlCache.ConfigFile = [xml](Get-Content $configFile)
        $script:_XmlCache.LastConfigLoad = Get-Item $configFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    $node = $script:_XmlCache.ConfigFile.SelectSingleNode("/SystemVariables/$XPath")
    if ($node) { return $node.InnerText } else { return $null }
}

function Save-ConfigPathValues {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Paths
    )

    if (-not (Test-Path $configFile)) { Initialize-ConfigFile -ConfigFile $configFile -LogsDir $logsDir -ConfigDir $configDir -ScriptsDir $scriptsDir }

    try {
        [xml]$xml = Get-Content $configFile
        $root = $xml.SelectSingleNode('/SystemVariables')
        if (-not $root) {
            $root = $xml.CreateElement('SystemVariables')
            $xml.AppendChild($root) | Out-Null
        }

        foreach ($key in @('ConfigPath','DefaultFolder','TempFolder','ReportFolder','DownloadFolder')) {
            if (-not $Paths.ContainsKey($key)) { continue }
            $node = $root.SelectSingleNode($key)
            if (-not $node) {
                $node = $xml.CreateElement($key)
                $root.AppendChild($node) | Out-Null
            }
            $node.InnerText = [string]$Paths[$key]
        }

        $xml.Save($configFile)
        $script:_XmlCache.ConfigFile = $null
        $script:_XmlCache.LastConfigLoad = $null
        Write-AppLog "Config paths saved to system-variables.xml" "Info"
    } catch {
        Write-AppLog "Failed to save config paths: $_" "Error"
    }
}

function Get-ConfigList {
    param([string]$ListName)
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return @()
    }
    
    # Load config once and cache it
    if (-not $script:_XmlCache.ConfigFile -or -not $script:_XmlCache.LastConfigLoad -or (Test-Path $configFile -NewerThan $script:_XmlCache.LastConfigLoad)) {
        $script:_XmlCache.ConfigFile = [xml](Get-Content $configFile)
        $script:_XmlCache.LastConfigLoad = Get-Item $configFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    $nodes = $script:_XmlCache.ConfigFile.SelectNodes("/SystemVariables/$ListName/Folder")
    return $nodes | ForEach-Object { $_.InnerText }
}

function Initialize-LinksConfigFile {
    if (Test-Path $linksConfigFile) { return }
    $xmlDoc = New-Object System.Xml.XmlDocument
    $root = $xmlDoc.CreateElement("Links")
    $xmlDoc.AppendChild($root) | Out-Null

    $categories = @(
        @{ Name = "CORPORATE"; Links = @(@{ Name = "Intranet"; Url = "https://intranet.example.com" }, @{ Name = "HR Portal"; Url = "https://hr.example.com" }) },
        @{ Name = "PUBLIC-INFO"; Links = @(@{ Name = "Company Site"; Url = "https://example.com" }) },
        @{ Name = "LOCAL"; Links = @(@{ Name = "Local Dashboard"; Url = "http://localhost" }) },
        @{ Name = "M365"; Links = @(@{ Name = "Outlook"; Url = "https://outlook.office.com" }, @{ Name = "OneDrive"; Url = "https://onedrive.live.com" }) },
        @{ Name = "SEARCH"; Links = @(@{ Name = "Bing"; Url = "https://www.bing.com" }, @{ Name = "Google"; Url = "https://www.google.com" }) },
        @{ Name = "USERS-URLS"; Links = @(@{ Name = "User Link 1"; Url = "https://example.com" }) }
    )

    foreach ($cat in $categories) {
        $catElem = $xmlDoc.CreateElement("Category")
        $catElem.SetAttribute("name", $cat.Name)
        foreach ($link in $cat.Links) {
            $linkElem = $xmlDoc.CreateElement("Link")
            $linkElem.SetAttribute("name", $link.Name)
            $linkElem.SetAttribute("url", $link.Url)
            $catElem.AppendChild($linkElem) | Out-Null
        }
        $root.AppendChild($catElem) | Out-Null
    }

    $xmlDoc.Save($linksConfigFile)
}

function Get-LinksConfig {
    if (-not (Test-Path $linksConfigFile)) { Initialize-LinksConfigFile }
    
    # Load and cache links config
    if (-not $script:_XmlCache.LinksConfig -or -not $script:_XmlCache.LastLinksLoad -or (Test-Path $linksConfigFile -NewerThan $script:_XmlCache.LastLinksLoad)) {
        $script:_XmlCache.LinksConfig = [xml](Get-Content $linksConfigFile)
        $script:_XmlCache.LastLinksLoad = Get-Item $linksConfigFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    return $script:_XmlCache.LinksConfig
}

function Get-VersionInfo {
    # Consolidated version info retrieval (single cache load instead of 3)
    try {
        $major = Get-ConfigSubValue "Version/Major"
        $minor = Get-ConfigSubValue "Version/Minor"
        $build = Get-ConfigSubValue "Version/Build"

        if ([string]::IsNullOrWhiteSpace($major)) { $major = (Get-Date).ToString('yyMM') }
        if ([string]::IsNullOrWhiteSpace($minor)) { $minor = 'B0' }
        if ([string]::IsNullOrWhiteSpace($build)) { $build = '0' }

        $buildNumeric = 0
        if (-not [int]::TryParse(($build -replace '[^0-9]',''), [ref]$buildNumeric)) { $buildNumeric = 0 }

        return @{
            Major = $major
            Minor = $minor
            Build = $buildNumeric.ToString()
        }
    } catch {
        Write-AppLog "Error retrieving version info: $_" "Error"
        return @{ Major = (Get-Date).ToString('yyMM'); Minor = 'B0'; Build = '0' }
    }
}

function Get-VersionString {
    $versionInfo = Get-VersionInfo
    return "$($versionInfo.Major).$($versionInfo.Minor).v$($versionInfo.Build)"
}

function Build-LinksMenu {
    param([System.Windows.Forms.ToolStripMenuItem]$LinksMenu)
    $LinksMenu.DropDownItems.Clear() | Out-Null
    $xml = Get-LinksConfig
    foreach ($cat in $xml.Links.Category) {
        $catItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $catItem.Text = $cat.name
        foreach ($link in $cat.Link) {
            $linkItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $linkItem.Text = $link.name
            $urlCopy = $link.url
            $linkItem.Add_Click({ Start-Process $urlCopy })
            $catItem.DropDownItems.Add($linkItem) | Out-Null
        }
        $LinksMenu.DropDownItems.Add($catItem) | Out-Null
    }
}
function Show-DiskCheckDialog {
    Write-AppLog "User initiated Disk Check" "Audit"
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -ExpandProperty DeviceID
    if (-not $drives) {
        [System.Windows.Forms.MessageBox]::Show("No local fixed drives found.", "Disk Check") | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Disk Check"
    $form.Size = New-Object System.Drawing.Size(360, 320)
    $form.StartPosition = "CenterParent"

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Location = New-Object System.Drawing.Point(12, 12)
    $list.Size = New-Object System.Drawing.Size(320, 220)
    $list.CheckOnClick = $true
    foreach ($drive in $drives) { [void]$list.Items.Add($drive) }
    $form.Controls.Add($list)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Run"
    $okBtn.Location = New-Object System.Drawing.Point(176, 245)
    $okBtn.Add_Click({
        $selected = @($list.CheckedItems)
        if (-not $selected) {
            [System.Windows.Forms.MessageBox]::Show("Select at least one drive.", "Disk Check") | Out-Null
            return
        }
        foreach ($drive in $selected) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c chkdsk $drive /f" -Verb RunAs
        }
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(256, 245)
    $cancelBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($cancelBtn)

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Show-PrivacyCheck {
    Write-AppLog "User initiated Privacy Check" "Audit"
    Start-Process "ms-settings:privacy"
}

function Show-SystemCheck {
    Write-AppLog "User initiated System Check" "Audit"
    $tempFile = Join-Path $env:TEMP ("sfc-detectonly-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c sfc /detectonly > `"$tempFile`" 2>&1" -Wait -WindowStyle Hidden
    $output = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
    $issuesFound = $false
    if ($output -match "found corrupt files" -or $output -match "integrity violations") { $issuesFound = $true }

    if ($issuesFound) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "System file issues detected. Run elevated 'sfc /scannow' now?",
            "System Check",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c sfc /scannow" -Verb RunAs
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("No integrity violations detected.", "System Check") | Out-Null
    }
}

function Show-WingetInstalledApp {
    Write-AppLog "User initiated WinGet Installed Apps view" "Audit"
    $apps = @()
    $regSources = @(
        @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*";           Source = "HKLM (x64)" },
        @{ Path = "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"; Source = "HKLM (x86)" },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*";           Source = "HKCU" }
    )

    foreach ($src in $regSources) {
        Get-ItemProperty -Path $src.Path -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_.DisplayName) { return }
            $installDate = ''
            if ($_.InstallDate -match '^\d{8}$') {
                $installDate = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
            }
            $sizeMB = ''
            if ($_.EstimatedSize) { $sizeMB = [math]::Round($_.EstimatedSize / 1024, 2) }
            $lastUpdated = ''
            try { $lastUpdated = (Get-Item $_.PSPath).LastWriteTime.ToString('yyyy-MM-dd') } catch { $lastUpdated = '' }

            # Prefer QuietUninstallString, fall back to UninstallString
            $uninstallStr = if ($_.QuietUninstallString) { $_.QuietUninstallString }
                            elseif ($_.UninstallString)   { $_.UninstallString }
                            else                           { '' }

            # Installation source: InstallSource registry value, else derive from install location
            $installSrc = if ($_.InstallSource)   { $_.InstallSource }
                          elseif ($_.InstallLocation) { $_.InstallLocation }
                          else                        { '' }

            $apps += [pscustomobject]@{
                Name            = $_.DisplayName
                Publisher       = $_.Publisher
                Version         = $_.DisplayVersion
                InstallDate     = $installDate
                LastUpdated     = $lastUpdated
                SizeMB          = $sizeMB
                RegistrySource  = $src.Source
                InstallSource   = $installSrc
                UninstallString = $uninstallStr
            }
        }
    }

    $apps | Sort-Object Name | Out-GridView -Title "Installed Apps (Registry -- $($apps.Count) entries)"
}

function Show-WingetUpgradeCheck {
    Write-AppLog "User initiated WinGet update check" "Audit"
    $logFile = Join-Path $logsDir ("winget-upgrades-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c winget upgrade > `"$logFile`" 2>&1" -Wait -WindowStyle Hidden
    Invoke-Item $logFile
}

function Show-WingetUpdateAllDialog {
    Write-AppLog "User initiated WinGet update-all" "Audit"
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WinGet Update All"
    $form.Size = New-Object System.Drawing.Size(520, 220)
    $form.StartPosition = "CenterParent"

    $autoRadio = New-Object System.Windows.Forms.RadioButton
    $autoRadio.Text = "AUTO - winget upgrade --all --accept-source-agreements --accept-package-agreements"
    $autoRadio.Location = New-Object System.Drawing.Point(12, 12)
    $autoRadio.Size = New-Object System.Drawing.Size(480, 24)
    $autoRadio.Checked = $true
    $form.Controls.Add($autoRadio)

    $bugRadio = New-Object System.Windows.Forms.RadioButton
    $bugRadio.Text = "BUG - winget upgrade --all (prompt per package)"
    $bugRadio.Location = New-Object System.Drawing.Point(12, 44)
    $bugRadio.Size = New-Object System.Drawing.Size(480, 24)
    $form.Controls.Add($bugRadio)

    $adminCheck = New-Object System.Windows.Forms.CheckBox
    $adminCheck.Text = "Run as admin"
    $adminCheck.Location = New-Object System.Drawing.Point(12, 78)
    $adminCheck.Checked = $true
    $form.Controls.Add($adminCheck)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Run"
    $okBtn.Location = New-Object System.Drawing.Point(336, 120)
    $okBtn.Add_Click({
        $wingetArgs = "upgrade --all"
        if ($autoRadio.Checked) {
            $wingetArgs = "upgrade --all --accept-source-agreements --accept-package-agreements"
        } else {
            [System.Windows.Forms.MessageBox]::Show("You will be prompted to confirm updates.", "WinGet") | Out-Null
        }
        if ($adminCheck.Checked) {
            Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Verb RunAs
        } else {
            Start-Process -FilePath "winget" -ArgumentList $wingetArgs
        }
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(416, 120)
    $cancelBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($cancelBtn)

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# version helpers and tagging
function Update-VersionBuild {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Auto)
    if (-not (Test-Path $configFile)) { Initialize-ConfigFile -ConfigFile $configFile -LogsDir $logsDir -ConfigDir $configDir -ScriptsDir $scriptsDir }
    if (-not $PSCmdlet.ShouldProcess($configFile, "Update build number")) { return }
    [xml]$xml = Get-Content $configFile
    $versionNode = $xml.SelectSingleNode('/SystemVariables/Version')
    if (-not $versionNode) {
        $versionNode = $xml.CreateElement('Version')
        $xml.SystemVariables.AppendChild($versionNode) | Out-Null
    }

    $majorNode = $xml.SelectSingleNode('/SystemVariables/Version/Major')
    if (-not $majorNode) {
        $majorNode = $xml.CreateElement('Major')
        $versionNode.AppendChild($majorNode) | Out-Null
    }

    $minorNode = $xml.SelectSingleNode('/SystemVariables/Version/Minor')
    if (-not $minorNode) {
        $minorNode = $xml.CreateElement('Minor')
        $versionNode.AppendChild($minorNode) | Out-Null
    }

    $buildNode = $xml.SelectSingleNode('/SystemVariables/Version/Build')
    if (-not $buildNode) {
        $buildNode = $xml.CreateElement('Build')
        $versionNode.AppendChild($buildNode) | Out-Null
        $buildNode.InnerText = '0'
    }

    $currentPrefix = (Get-Date).ToString('yyMM')
    $storedPrefix = [string]$majorNode.InnerText
    if ([string]::IsNullOrWhiteSpace($storedPrefix) -or $storedPrefix -ne $currentPrefix) {
        $majorNode.InnerText = $currentPrefix
        Write-AppLog "Version month prefix moved to $currentPrefix" "Info"
    }

    if ([string]::IsNullOrWhiteSpace([string]$minorNode.InnerText)) {
        $minorNode.InnerText = 'B0'
    }

    $current = 0
    if (-not [int]::TryParse(([string]$buildNode.InnerText -replace '[^0-9]',''), [ref]$current)) { $current = 0 }
    $buildNode.InnerText = ($current + 1).ToString()
    $xml.Save($configFile)
    if ($Auto) { Write-AppLog "Auto-incremented build to $(Get-VersionString)" "Info" }
}

function Export-WorkspacePackage {
    param(
        [hashtable]$Options = @{}
    )

    $versionString = Get-VersionString
    $zipName = "pwshGUI-v02-$versionString-$(Get-Date -Format 'yyMMddHHmm').zip"
    $workspace = Get-Location

    if ($Options.DropFolderContents) {
        Clear-FolderContents -Path $DownloadFolder -Label "~DOWNLOADS"
        Clear-FolderContents -Path $ReportFolder -Label "~REPORTS"
        Clear-FolderContents -Path $logsDir -Label "logs"
        Clear-FolderContents -Path $TempFolder -Label "temp"
    }

    if ($Options.PurgeEnabled) {
        if ($Options.PurgeLogs) { Remove-ItemsOlderThan -Path $logsDir -BeforeDate $Options.PurgeBeforeDate -Label "logs" }
        if ($Options.PurgeReports) { Remove-ItemsOlderThan -Path $ReportFolder -BeforeDate $Options.PurgeBeforeDate -Label "~REPORTS" }
    }

    $configBackup = $null
    $configUpdated = $false
    if ($Options.BakeInRemoteUpdatePath -and $Options.RemoteUpdatePath) {
        $configBackup = Get-ConfigSubValue "RemoteUpdatePath"
        Set-ConfigSubValue -XPath "RemoteUpdatePath" -Value $Options.RemoteUpdatePath
        $configUpdated = $true
        Write-AppLog "Bake-in RemoteUpdatePath set to $($Options.RemoteUpdatePath)" "Info"
    }

    if ($Options.SignScriptsInPlace) {
        $cert = Initialize-CodeSigningCert -Subject $Options.CodeSigningSubject
        if ($cert) {
            Write-AppLog "Signing scripts in place using $($cert.Subject)" "Info"
            Get-CachedScriptFiles | ForEach-Object {
                try {
                    Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert | Out-Null
                } catch {
                    Write-AppLog "Failed to sign $($_.FullName): $_" "Warning"
                }
            }
            Clear-FileListCache  # Invalidate after signing changes
        }
    }

    $packageExcludeFolders = @(Get-ConfigList "Do-Not-VersionTag-FoldersFiles") + '.git'
    if ($Options.IncludeHistoryFolder) {
        $packageExcludeFolders = $packageExcludeFolders | Where-Object { $_ -ne ".history" }
    }
    if ($Options.IncludeVscodeFolder) {
        $packageExcludeFolders = $packageExcludeFolders | Where-Object { $_ -ne ".vscode" }
    }

    $packageItems = Get-ChildItem -Path $workspace.Path -Force | Where-Object {
        $packageExcludeFolders -notcontains $_.Name
    } | Select-Object -ExpandProperty FullName

    $destinationPath = Join-Path $DownloadFolder $zipName
    Write-AppLog "Packaging workspace to $destinationPath" "Info"

    if ($Options.EncryptZip) {
        $sevenZipPath = Resolve-7ZipPath -PreferredPath $Options.SevenZipPath
        if ($sevenZipPath) {
            New-EncryptedZip -SevenZipPath $sevenZipPath -WorkspacePath $workspace.Path -ItemPaths $packageItems -DestinationPath $destinationPath -Password $Options.ZipPassword
        } else {
            Write-AppLog "7-Zip not found; creating standard zip without encryption" "Warning"
            Compress-Archive -Path $packageItems -DestinationPath $destinationPath -Force
        }
    } else {
        Compress-Archive -Path $packageItems -DestinationPath $destinationPath -Force
    }

    if ($configUpdated) {
        Set-ConfigSubValue -XPath "RemoteUpdatePath" -Value $configBackup
    }

    if ($Options.CopyZipToRemote -and $Options.RemoteUpdatePath) {
        $remoteBuildDir = Join-Path $Options.RemoteUpdatePath "~BUILD-ZIPS"
        try {
            if (-not (Test-Path $remoteBuildDir)) { New-Item -ItemType Directory -Path $remoteBuildDir -Force | Out-Null }
            Copy-Item -Path $destinationPath -Destination $remoteBuildDir -Force
            Write-AppLog "Copied build zip to $remoteBuildDir" "Info"
        } catch {
            Write-AppLog "Failed to copy build zip to ${remoteBuildDir}: $_" "Warning"
        }
    }

    Write-AppLog "Package created" "Info"
}

function Clear-FolderContents {
    param(
        [string]$Path,
        [string]$Label
    )
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) { return }
    try {
        Get-ChildItem -Path $Path -Force | Remove-Item -Recurse -Force -ErrorAction Stop
        Write-AppLog "Cleared contents of ${Label} at ${Path}" "Info"
    } catch {
        Write-AppLog "Failed to clear contents of ${Label} at ${Path}: $_" "Warning"
    }
}

function Remove-ItemsOlderThan {
    param(
        [string]$Path,
        [datetime]$BeforeDate,
        [string]$Label
    )
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) { return }
    try {
        Get-ChildItem -Path $Path -Recurse -File -Force | Where-Object { $_.LastWriteTime -lt $BeforeDate } | Remove-Item -Force
        Write-AppLog "Purged ${Label} items older than $($BeforeDate.ToString('yyyy-MM-dd'))" "Info"
    } catch {
        Write-AppLog "Failed to purge ${Label} items older than $($BeforeDate.ToString('yyyy-MM-dd')): $_" "Warning"
    }
}

function Resolve-7ZipPath {
    param([string]$PreferredPath)
    if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "$env:ProgramFiles(x86)\7-Zip\7z.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function New-EncryptedZip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Password is passed to 7-Zip CLI as -p argument; SecureString conversion adds no security benefit')]
    param(
        [string]$SevenZipPath,
        [string]$WorkspacePath,
        [string[]]$ItemPaths,
        [string]$DestinationPath,
        [string]$Password
    )
    $listFile = Join-Path $env:TEMP ("pwshgui_packlist_{0}.txt" -f ([guid]::NewGuid().ToString("N")))
    try {
        $relativeItems = $ItemPaths | ForEach-Object { $_.Substring($WorkspacePath.Length).TrimStart("\\") }
        Set-Content -Path $listFile -Value $relativeItems -Encoding ASCII
        $sevenZipArgs = @(
            "a",
            "-tzip",
            "-mem=AES256",
            "-mhe=on",
            "-p$Password",
            $DestinationPath,
            ("@{0}" -f $listFile)
        )
        Write-AppLog "Creating encrypted zip with 7-Zip" "Info"
        Push-Location $WorkspacePath
        & $SevenZipPath @sevenZipArgs | Out-Null
        Pop-Location
    } finally {
        if (Test-Path $listFile) { Remove-Item $listFile -Force }
    }
}

function Initialize-CodeSigningCert {
    param([string]$Subject)
    if ([string]::IsNullOrWhiteSpace($Subject)) { return $null }
    $cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -eq $Subject } | Select-Object -First 1
    if (-not $cert) {
        try {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject -CertStoreLocation "Cert:\CurrentUser\My"
            Write-AppLog "Created self-signed code signing certificate: $Subject" "Info"
        } catch {
            Write-AppLog "Failed to create code signing certificate ${Subject}: $_" "Warning"
            return $null
        }
    }
    return $cert
}

function Set-ConfigSubValue {
    param(
        [string]$XPath,
        [string]$Value
    )
    if (-not (Test-Path $configFile)) { Initialize-ConfigFile -ConfigFile $configFile -LogsDir $logsDir -ConfigDir $configDir -ScriptsDir $scriptsDir }
    [xml]$xml = Get-Content $configFile
    $node = $xml.SelectSingleNode("/SystemVariables/$XPath")
    if (-not $node) {
        $parts = $XPath -split "/"
        $parent = $xml.SelectSingleNode("/SystemVariables")
        foreach ($part in $parts) {
            $child = $parent.SelectSingleNode($part)
            if (-not $child) {
                $child = $xml.CreateElement($part)
                $parent.AppendChild($child) | Out-Null
            }
            $parent = $child
        }
        $node = $parent
    }
    $node.InnerText = [string]$Value
    $xml.Save($configFile)
    $script:_XmlCache.ConfigFile = $null
    $script:_XmlCache.LastConfigLoad = $null
}

function Show-BuildPackageOptionsForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Build Package Options"
    $form.Size = New-Object System.Drawing.Size(760, 640)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Topmost = $true

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Build Package - Basic Options"
    $titleLabel.Location = New-Object System.Drawing.Point(16, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(720, 18)
    $form.Controls.Add($titleLabel)

    $purgeGroup = New-Object System.Windows.Forms.GroupBox
    $purgeGroup.Text = "Purge"
    $purgeGroup.Location = New-Object System.Drawing.Point(16, 40)
    $purgeGroup.Size = New-Object System.Drawing.Size(720, 100)

    $purgeEnable = New-Object System.Windows.Forms.CheckBox
    $purgeEnable.Text = "Purge items older than date"
    $purgeEnable.Location = New-Object System.Drawing.Point(12, 22)
    $purgeEnable.Size = New-Object System.Drawing.Size(260, 20)
    $purgeGroup.Controls.Add($purgeEnable)

    $purgeDate = New-Object System.Windows.Forms.DateTimePicker
    $purgeDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $purgeDate.Value = (Get-Date).AddDays(-30)
    $purgeDate.Location = New-Object System.Drawing.Point(280, 20)
    $purgeDate.Size = New-Object System.Drawing.Size(120, 20)
    $purgeGroup.Controls.Add($purgeDate)

    $purgeLogs = New-Object System.Windows.Forms.CheckBox
    $purgeLogs.Text = "Logs"
    $purgeLogs.Location = New-Object System.Drawing.Point(12, 52)
    $purgeLogs.Size = New-Object System.Drawing.Size(80, 20)
    $purgeGroup.Controls.Add($purgeLogs)

    $purgeReports = New-Object System.Windows.Forms.CheckBox
    $purgeReports.Text = "Reports"
    $purgeReports.Location = New-Object System.Drawing.Point(100, 52)
    $purgeReports.Size = New-Object System.Drawing.Size(80, 20)
    $purgeGroup.Controls.Add($purgeReports)

    $form.Controls.Add($purgeGroup)

    $dropGroup = New-Object System.Windows.Forms.GroupBox
    $dropGroup.Text = "Clean Folders"
    $dropGroup.Location = New-Object System.Drawing.Point(16, 150)
    $dropGroup.Size = New-Object System.Drawing.Size(720, 70)

    $dropContents = New-Object System.Windows.Forms.CheckBox
    $dropContents.Text = "Drop and delete all contents of ~DOWNLOADS, ~REPORTS, logs, temp"
    $dropContents.Location = New-Object System.Drawing.Point(12, 28)
    $dropContents.Size = New-Object System.Drawing.Size(680, 20)
    $dropGroup.Controls.Add($dropContents)
    $form.Controls.Add($dropGroup)

    $remoteGroup = New-Object System.Windows.Forms.GroupBox
    $remoteGroup.Text = "Bake-in Off-Net Updates"
    $remoteGroup.Location = New-Object System.Drawing.Point(16, 230)
    $remoteGroup.Size = New-Object System.Drawing.Size(720, 110)

    $bakeIn = New-Object System.Windows.Forms.CheckBox
    $bakeIn.Text = "Bake-in RemoteUpdatePath (config in build zip)"
    $bakeIn.Location = New-Object System.Drawing.Point(12, 22)
    $bakeIn.Size = New-Object System.Drawing.Size(380, 20)
    $bakeIn.Checked = $true
    $remoteGroup.Controls.Add($bakeIn)

    $remotePathLabel = New-Object System.Windows.Forms.Label
    $remotePathLabel.Text = "RemoteUpdatePath:"
    $remotePathLabel.Location = New-Object System.Drawing.Point(12, 52)
    $remotePathLabel.Size = New-Object System.Drawing.Size(140, 18)
    $remoteGroup.Controls.Add($remotePathLabel)

    $remotePathText = New-Object System.Windows.Forms.TextBox
    $remotePathText.Location = New-Object System.Drawing.Point(160, 50)
    $remotePathText.Size = New-Object System.Drawing.Size(520, 20)
    $remotePathText.Text = [string](Get-ConfigSubValue "RemoteUpdatePath")
    $remoteGroup.Controls.Add($remotePathText)

    $copyZip = New-Object System.Windows.Forms.CheckBox
    $copyZip.Text = "Copy build zip to RemoteUpdatePath\~BUILD-ZIPS"
    $copyZip.Location = New-Object System.Drawing.Point(12, 78)
    $copyZip.Size = New-Object System.Drawing.Size(380, 20)
    $copyZip.Checked = $true
    $remoteGroup.Controls.Add($copyZip)

    $form.Controls.Add($remoteGroup)

    $advancedToggle = New-Object System.Windows.Forms.CheckBox
    $advancedToggle.Text = "Show advanced options"
    $advancedToggle.Location = New-Object System.Drawing.Point(16, 350)
    $advancedToggle.Size = New-Object System.Drawing.Size(220, 20)
    $form.Controls.Add($advancedToggle)

    $advancedGroup = New-Object System.Windows.Forms.GroupBox
    $advancedGroup.Text = "Advanced Options"
    $advancedGroup.Location = New-Object System.Drawing.Point(16, 380)
    $advancedGroup.Size = New-Object System.Drawing.Size(720, 160)
    $advancedGroup.Visible = $false

    $includeHistory = New-Object System.Windows.Forms.CheckBox
    $includeHistory.Text = "Include .history folder"
    $includeHistory.Location = New-Object System.Drawing.Point(12, 24)
    $includeHistory.Size = New-Object System.Drawing.Size(220, 20)
    $advancedGroup.Controls.Add($includeHistory)

    $includeVscode = New-Object System.Windows.Forms.CheckBox
    $includeVscode.Text = "Include .vscode folder"
    $includeVscode.Location = New-Object System.Drawing.Point(240, 24)
    $includeVscode.Size = New-Object System.Drawing.Size(220, 20)
    $advancedGroup.Controls.Add($includeVscode)

    $signScripts = New-Object System.Windows.Forms.CheckBox
    $signScripts.Text = "Sign scripts in place using self-signed cert"
    $signScripts.Location = New-Object System.Drawing.Point(12, 52)
    $signScripts.Size = New-Object System.Drawing.Size(320, 20)
    $advancedGroup.Controls.Add($signScripts)

    $certSubjectLabel = New-Object System.Windows.Forms.Label
    $certSubjectLabel.Text = "Cert Subject:"
    $certSubjectLabel.Location = New-Object System.Drawing.Point(340, 52)
    $certSubjectLabel.Size = New-Object System.Drawing.Size(90, 18)
    $advancedGroup.Controls.Add($certSubjectLabel)

    $certSubjectText = New-Object System.Windows.Forms.TextBox
    $certSubjectText.Location = New-Object System.Drawing.Point(430, 50)
    $certSubjectText.Size = New-Object System.Drawing.Size(250, 20)
    $certSubjectText.Text = "CN=PowerShellGUI Build"
    $advancedGroup.Controls.Add($certSubjectText)

    $encryptZip = New-Object System.Windows.Forms.CheckBox
    $encryptZip.Text = "Encrypt zip (7-Zip AES-256)"
    $encryptZip.Location = New-Object System.Drawing.Point(12, 80)
    $encryptZip.Size = New-Object System.Drawing.Size(240, 20)
    $advancedGroup.Controls.Add($encryptZip)

    $zipPassLabel = New-Object System.Windows.Forms.Label
    $zipPassLabel.Text = "Password:"
    $zipPassLabel.Location = New-Object System.Drawing.Point(260, 80)
    $zipPassLabel.Size = New-Object System.Drawing.Size(70, 18)
    $advancedGroup.Controls.Add($zipPassLabel)

    $zipPassText = New-Object System.Windows.Forms.TextBox
    $zipPassText.Location = New-Object System.Drawing.Point(330, 78)
    $zipPassText.Size = New-Object System.Drawing.Size(140, 20)
    $zipPassText.UseSystemPasswordChar = $true
    $advancedGroup.Controls.Add($zipPassText)

    $zipPassConfirmLabel = New-Object System.Windows.Forms.Label
    $zipPassConfirmLabel.Text = "Confirm:"
    $zipPassConfirmLabel.Location = New-Object System.Drawing.Point(480, 80)
    $zipPassConfirmLabel.Size = New-Object System.Drawing.Size(60, 18)
    $advancedGroup.Controls.Add($zipPassConfirmLabel)

    $zipPassConfirmText = New-Object System.Windows.Forms.TextBox
    $zipPassConfirmText.Location = New-Object System.Drawing.Point(540, 78)
    $zipPassConfirmText.Size = New-Object System.Drawing.Size(140, 20)
    $zipPassConfirmText.UseSystemPasswordChar = $true
    $advancedGroup.Controls.Add($zipPassConfirmText)

    $sevenZipLabel = New-Object System.Windows.Forms.Label
    $sevenZipLabel.Text = "7z Path:"
    $sevenZipLabel.Location = New-Object System.Drawing.Point(12, 112)
    $sevenZipLabel.Size = New-Object System.Drawing.Size(70, 18)
    $advancedGroup.Controls.Add($sevenZipLabel)

    $sevenZipText = New-Object System.Windows.Forms.TextBox
    $sevenZipText.Location = New-Object System.Drawing.Point(80, 110)
    $sevenZipText.Size = New-Object System.Drawing.Size(600, 20)
    $sevenZipText.Text = Resolve-7ZipPath -PreferredPath ""
    $advancedGroup.Controls.Add($sevenZipText)

    $form.Controls.Add($advancedGroup)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Build"
    $okButton.Location = New-Object System.Drawing.Point(560, 560)
    $okButton.Size = New-Object System.Drawing.Size(80, 28)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(650, 560)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $advancedToggle.Add_CheckedChanged({
        $advancedGroup.Visible = $advancedToggle.Checked
    })

    $okButton.Add_Click({
        if ($bakeIn.Checked -and [string]::IsNullOrWhiteSpace($remotePathText.Text)) {
            [System.Windows.Forms.MessageBox]::Show("RemoteUpdatePath is required when Bake-in is enabled.", "Validation", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
        if ($copyZip.Checked -and [string]::IsNullOrWhiteSpace($remotePathText.Text)) {
            [System.Windows.Forms.MessageBox]::Show("RemoteUpdatePath is required to copy build zip.", "Validation", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
        if ($encryptZip.Checked) {
            if ([string]::IsNullOrWhiteSpace($zipPassText.Text) -or ($zipPassText.Text -ne $zipPassConfirmText.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Zip encryption requires matching passwords.", "Validation", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                $form.DialogResult = [System.Windows.Forms.DialogResult]::None
                return
            }
            if (-not (Resolve-7ZipPath -PreferredPath $sevenZipText.Text)) {
                [System.Windows.Forms.MessageBox]::Show("7-Zip not found. Provide a valid 7z.exe path or disable encryption.", "Validation", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                $form.DialogResult = [System.Windows.Forms.DialogResult]::None
                return
            }
        }
        if ($signScripts.Checked -and [string]::IsNullOrWhiteSpace($certSubjectText.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Cert subject is required for code signing.", "Validation", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            return
        }
    })

    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    return @{
        PurgeEnabled = $purgeEnable.Checked
        PurgeBeforeDate = $purgeDate.Value
        PurgeLogs = $purgeLogs.Checked
        PurgeReports = $purgeReports.Checked
        DropFolderContents = $dropContents.Checked
        BakeInRemoteUpdatePath = $bakeIn.Checked
        RemoteUpdatePath = $remotePathText.Text
        CopyZipToRemote = $copyZip.Checked
        IncludeHistoryFolder = $includeHistory.Checked
        IncludeVscodeFolder = $includeVscode.Checked
        SignScriptsInPlace = $signScripts.Checked
        CodeSigningSubject = $certSubjectText.Text
        EncryptZip = $encryptZip.Checked
        ZipPassword = $zipPassText.Text
        SevenZipPath = $sevenZipText.Text
    }
}

# update files in workspace with a version comment tag
function Update-VersionTag {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    # Auto-increment removed - now controlled by startup logic
    $versionString = Get-VersionString
    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"

    Write-AppLog "Updating version tags to $versionString" "Info"
    $workspace = Get-Location
    Get-CachedAllFiles | ForEach-Object {
        $file = $_
        # skip modifying the main launcher script and build manifests
        if ($file.FullName -ieq $MyInvocation.MyCommand.Path) { return }
        if ($file.Name -like 'PwShGUI-v-*') { return }
        if ($file.Extension -ieq ".json") {
            $txt = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt) {
                $clean = $txt -replace '(?m)^\s*#\s*VersionTag:.*$\r?\n?', ''
                if ($clean -ne $txt) {
                    if ($PSCmdlet.ShouldProcess($file.FullName, "Remove version tag")) {
                        Set-Content -Path $file.FullName -Value $clean -Encoding UTF8 -ErrorAction SilentlyContinue
                    }
                }
            }
            return
        }
        if ($file.Extension -ieq ".exe" -or $file.Extension -ieq ".dll") { return }
        $text = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { return }
        $commentPrefix = "#"
        $commentSuffix = ""
        $isXmlLike = $false
        switch -Regex ($file.Extension) {
            "\.xml$|\.xhtml$|\.html$|\.htm$" {
                $commentPrefix = "<!--"
                $commentSuffix = " -->"
                if ($file.Extension -ieq '.xml' -or $file.Extension -ieq '.xhtml') { $isXmlLike = $true }
            }
            "\.ps1$|\.psm1$|\.psd1$|\.txt$|\.md$" { $commentPrefix="#"; $commentSuffix="" }
            default { $commentPrefix="#"; $commentSuffix="" }
        }

        $tagLine = "$commentPrefix VersionTag: $versionString$commentSuffix"
        $newText = $text

        if ($isXmlLike) {
            # Ensure XHTML/XML stays parse-safe: no hash comments and no tags before XML declaration.
            $withoutTags = $text -replace '(?m)^\s*(#|<!--)\s*VersionTag:.*?(-->)?\s*$\r?\n?', ''
            if ($withoutTags -match '^\s*<\?xml[^>]*\?>') {
                $newText = [regex]::Replace(
                    $withoutTags,
                    '^\s*<\?xml[^>]*\?>\s*',
                    { param($m) "$($m.Value)$([Environment]::NewLine)$tagLine$([Environment]::NewLine)" },
                    [System.Text.RegularExpressions.RegexOptions]::Singleline,
                    [timespan]::FromSeconds(2)
                )
            } else {
                $newText = $tagLine + [Environment]::NewLine + $withoutTags
            }
        } else {
            if ($text -match 'VersionTag:\s*([0-9A-Za-z\._-]+)') {
                $existingVer = $Matches[1]
                if ($existingVer -ne $versionString) {
                    $newText = $text -replace '(?m)^\s*(#|<!--)\s*VersionTag:.*?(-->)?\s*$', $tagLine
                }
            } else {
                $newText = $tagLine + [Environment]::NewLine + $text
            }
        }
        if ($newText -ne $text) {
            if ($PSCmdlet.ShouldProcess($file.FullName, "Update version tag")) {
                Set-Content -Path $file.FullName -Value $newText -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }
    }
}
function New-BuildManifest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $versionString = Get-VersionString
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $fileName = "PwShGUI-v-$versionString~versionbuild-$stamp.txt"
    $workspace = Get-Location
    $manifestPath = Join-Path $versionsDir $fileName
    $manifestCachePath = Join-Path $configDir "manifest-cache.json"
    if (-not $PSCmdlet.ShouldProcess($manifestPath, "Create build manifest")) { return }
    Write-AppLog "Generating build manifest $fileName" "Info"

    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"

    $cacheIndex = @{}
    if (Test-Path $manifestCachePath) {
        try {
            $cachedManifest = Get-Content $manifestCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($entry in @($cachedManifest.entries)) {
                if ($entry.RelPath) {
                    $cacheIndex[$entry.RelPath] = $entry
                }
            }
        }
        catch {
            Write-AppLog "Manifest cache unreadable, rebuilding incrementally from scratch: $_" "Warning"
            $cacheIndex = @{}
        }
    }

    $manifestLines = @()
    $manifestLines += "Version: $versionString"
    $manifestLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    # header row
    $manifestLines += "Path,\tCreated,\tModified,\tSize,\tOwner,\tSHA256,\tMarkOfWeb,\tCert,\tCompressed,\tReadOnly,\tEncrypted"

    $newCacheEntries = New-Object System.Collections.Generic.List[object]
    $reusedCount = 0
    $refreshedCount = 0

    Get-CachedAllFiles | ForEach-Object {
        $f = $_
        $rel = $f.FullName.Substring($workspace.Path.Length).TrimStart('\\')
        $signature = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        $cachedEntry = $cacheIndex[$rel]

        if ($cachedEntry -and $cachedEntry.Signature -eq $signature) {
            $entry = [PSCustomObject]@{
                RelPath = $rel
                Signature = $signature
                Created = [string]$cachedEntry.Created
                Modified = [string]$cachedEntry.Modified
                Size = [string]$cachedEntry.Size
                Owner = [string]$cachedEntry.Owner
                SHA256 = [string]$cachedEntry.SHA256
                MarkOfWeb = [string]$cachedEntry.MarkOfWeb
                Cert = [string]$cachedEntry.Cert
                Compressed = [string]$cachedEntry.Compressed
                ReadOnly = [string]$cachedEntry.ReadOnly
                Encrypted = [string]$cachedEntry.Encrypted
            }
            $reusedCount++
        }
        else {
            $attrs = Get-Item $f.FullName
            $owner = (Get-Acl $f.FullName).Owner
            $sha256 = (Get-FileHash -Algorithm SHA256 $f.FullName).Hash
            $motw = if (Test-Path "$($f.FullName):Zone.Identifier") { 'Yes' } else {'No'}
            $auth = Get-AuthenticodeSignature $f.FullName
            $cert = if ($auth.SignerCertificate) { $auth.SignerCertificate.Subject } else {''}
            $compressed = if ($attrs.Attributes -band [IO.FileAttributes]::Compressed) {'Yes'} else {'No'}
            $readonly = if ($attrs.IsReadOnly) {'Yes'} else {'No'}
            $encrypted = if ($attrs.Attributes -band [IO.FileAttributes]::Encrypted) {'Yes'} else {'No'}

            $entry = [PSCustomObject]@{
                RelPath = $rel
                Signature = $signature
                Created = $f.CreationTime.ToString('s')
                Modified = $f.LastWriteTime.ToString('s')
                Size = [string]$f.Length
                Owner = [string]$owner
                SHA256 = [string]$sha256
                MarkOfWeb = [string]$motw
                Cert = [string]$cert
                Compressed = [string]$compressed
                ReadOnly = [string]$readonly
                Encrypted = [string]$encrypted
            }
            $refreshedCount++
        }

        $newCacheEntries.Add($entry) | Out-Null
        # separate fields with comma followed by tab
        $manifestLines += "$($entry.RelPath),`t$($entry.Created),`t$($entry.Modified),`t$($entry.Size),`t$($entry.Owner),`t$($entry.SHA256),`t$($entry.MarkOfWeb),`t$($entry.Cert),`t$($entry.Compressed),`t$($entry.ReadOnly),`t$($entry.Encrypted)"
    }

    $manifestLines | Out-File -FilePath $manifestPath -Encoding UTF8

    $cachePayload = @{
        Version = $versionString
        Generated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        Entries = @($newCacheEntries)
    }
    $cachePayload | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestCachePath -Encoding UTF8

    Write-AppLog "Manifest cache summary: reused=$reusedCount refreshed=$refreshedCount total=$($reusedCount + $refreshedCount)" "Info"
}

function Test-VersionTag {
    $expected = Get-VersionString
    $workspace = Get-Location
    Write-AppLog "Checking version tags against expected $expected" "Info"

    # build xml document
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('Diffs')
    $root.SetAttribute('version',$expected)
    $xml.AppendChild($root) | Out-Null
    $orphanCandidates = New-Object 'System.Collections.Generic.List[object]'

    Get-CachedAllFiles | Where-Object {
        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")
        # skip manifest itself
        if ($rel -like '.history\PwShGUI-Versions\*') { return $false }
        return $true
    } | ForEach-Object {
        $file = $_
        if (
            $file.Extension -ieq '.json' -or
            $file.Extension -ieq '.exe' -or
            $file.Extension -ieq '.dll' -or
            $file.Extension -ieq '.html' -or
            $file.Extension -ieq '.htm' -or
            $file.Extension -ieq '.xhtml' -or
            $file.Extension -ieq '.log'
        ) { return }
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { return }
        $rel = $file.FullName.Substring($workspace.Path.Length).TrimStart("\\")
        $folder = Split-Path $rel -Parent
        if (-not $folder) { $folder = '.' }
        if ($content -match 'VersionTag:\s*([0-9A-Za-z\._-]+)') {
            $tag = $Matches[1]
            if ($tag -ne $expected) {
                $folderNode = $root.SelectSingleNode("Folder[@path='$folder']")
                if (-not $folderNode) {
                    $folderNode = $xml.CreateElement('Folder')
                    $folderNode.SetAttribute('path',$folder)
                    $root.AppendChild($folderNode) | Out-Null
                }
                $fileNode = $xml.CreateElement('File')
                $fileNode.SetAttribute('name',$rel)
                $fileNode.SetAttribute('issue','tag mismatch')
                $fileNode.SetAttribute('found',$tag)
                $fileNode.SetAttribute('expected',$expected)
                $folderNode.AppendChild($fileNode) | Out-Null
                Write-AppLog "[$file] version tag mismatch: $tag vs $expected" "Error"
            }
        } else {
            $folderNode = $root.SelectSingleNode("Folder[@path='$folder']")
            if (-not $folderNode) {
                $folderNode = $xml.CreateElement('Folder')
                $folderNode.SetAttribute('path',$folder)
                $root.AppendChild($folderNode) | Out-Null
            }
            $fileNode = $xml.CreateElement('File')
            $fileNode.SetAttribute('name',$rel)
            $fileNode.SetAttribute('issue','missing tag')
            $folderNode.AppendChild($fileNode) | Out-Null
            Write-AppLog "[$file] missing version tag" "Warning"
        }
    }

    Compare-ExcludedFolder -workspace $workspace -xmlDoc $xml -orphanCandidates ([ref]$orphanCandidates)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $diffFile = Join-Path $versionsDir "PwShGUI-v-$expected~DIFFS-$stamp.xml"
    $xml.Save($diffFile)

    Write-OrphanAuditReport -workspace $workspace -version $expected -orphanCandidates $orphanCandidates
    return $diffFile
}

function Write-OrphanAuditReport {
    param(
        [Parameter(Mandatory = $true)]
        $workspace,

        [Parameter(Mandatory = $true)]
        [string]$version,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$orphanCandidates
    )

    $reportRoot = $script:ReportFolder
    if ([string]::IsNullOrWhiteSpace($reportRoot) -or -not (Test-Path $reportRoot)) {
        $reportRoot = Join-Path $workspace.Path "~REPORTS"
    }
    if (-not (Test-Path $reportRoot)) {
        New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $reportRoot "orphan-audit-$timestamp.json"
    $mdPath = Join-Path $reportRoot "orphan-audit-core-$timestamp.md"

    $candidateArray = @($orphanCandidates)
    $summary = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        workspace = $workspace.Path
        version = $version
        detectionModel = 'inventory-drift'
        note = 'Potential orphan candidates are files under excluded folders that are not listed in their local manifest text files.'
        candidateCount = $candidateArray.Count
    }

    $payload = [ordered]@{
        summary = $summary
        candidates = $candidateArray
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @(
        "# Orphan Audit (Inventory Drift)",
        "",
        "- Generated: $($summary.generatedAt)",
        "- Workspace: $($summary.workspace)",
        "- Version: $($summary.version)",
        "- Detection Model: $($summary.detectionModel)",
        "- Candidate Count: $($summary.candidateCount)",
        "",
        "## Scope",
        "",
        "This report uses inventory/drift detection. It does not perform reference-graph analysis.",
        ""
    )

    if ($candidateArray.Count -eq 0) {
        $lines += "## Candidates"
        $lines += ""
        $lines += "No orphan candidates detected in excluded-folder manifest comparisons."
    } else {
        $lines += "## Candidates"
        $lines += ""
        foreach ($candidate in $candidateArray) {
            $lines += "- $($candidate.relativePath) | issue=$($candidate.issue) | source=$($candidate.sourceManifest)"
        }
    }

    Set-Content -Path $mdPath -Value $lines -Encoding UTF8

    Write-AppLog "Orphan audit JSON generated: $jsonPath" "Info"
    Write-AppLog "Orphan audit Markdown generated: $mdPath" "Info"
    Write-AppLog "Orphan audit candidate count: $($candidateArray.Count)" "Info"
}

function Compare-ExcludedFolder {
    param(
        $workspace,
        [ref]$diffs,
        [xml]$xmlDoc,
        [ref]$orphanCandidates
    )
    $excludes = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"
    $reportedIssues = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($ex in $excludes) {
        if ($ex -ieq 'logs') { continue }
        $folderPath = Join-Path $workspace.Path $ex
        if (-not (Test-Path $folderPath)) { continue }
        Get-ChildItem -Path $folderPath -Filter *.txt -File | ForEach-Object {
            $manifest = $_
            $lines = Get-Content $manifest.FullName
            $listed = @{}
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                if ($line -match '^(Path,\s*\t|Version:|Generated:)') { continue }

                $relativePath = $null
                if ($line -match '^(?<path>[^,\t]+),\s*\t') {
                    $relativePath = $Matches['path']
                } elseif ($line -match '^(?<path>[^\t]+)\t') {
                    $relativePath = $Matches['path']
                }

                if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
                    $listed[$relativePath] = $true
                    $listed[(Split-Path $relativePath -Leaf)] = $true
                }
            }
            Get-ChildItem -Path $folderPath -File | ForEach-Object {
                $relname = $_.Name
                if ($relname -like 'PwShGUI-v-*') { return }
                if ($relname -like 'orphan-audit-*') { return }
                if ($relname -like 'orphan-audit-core-*') { return }
                if ($relname -like 'orphan-cleanup-*') { return }
                if ($relname -like 'report-retention-*') { return }
                if ($relname -like 'xhtml-triage-*') { return }
                if ($manifest.FullName -eq $_.FullName) { return }

                $relativeFromExcludedFolder = Join-Path $ex $relname
                $relativeFromExcludedFolder = $relativeFromExcludedFolder -replace '/', '\\'

                if ($listed.ContainsKey($relname) -or $listed.ContainsKey($relativeFromExcludedFolder)) {
                    return
                }

                $issueKey = "$ex|$relname"
                if (-not $reportedIssues.Add($issueKey)) { return }

                Write-AppLog "$relname exists but not in manifest" "Error"
                if ($diffs) { $diffs.Value += "$folderPath\$relname - not in manifest" }
                if ($orphanCandidates) {
                    $orphanCandidates.Value.Add([ordered]@{
                        folder = $ex
                        fileName = $relname
                        relativePath = $relativeFromExcludedFolder
                        fullPath = $_.FullName
                        issue = 'not in manifest'
                        sourceManifest = $manifest.FullName
                        detectedAt = (Get-Date).ToString('o')
                    }) | Out-Null
                }
                if ($xmlDoc) {
                    $root = $xmlDoc.DocumentElement
                    $folderNode = $root.SelectSingleNode("Folder[@path='$ex']")
                    if (-not $folderNode) {
                        $folderNode = $xmlDoc.CreateElement('Folder')
                        $folderNode.SetAttribute('path',$ex)
                        $root.AppendChild($folderNode) | Out-Null
                    }
                    $fileNode = $xmlDoc.CreateElement('File')
                    $fileNode.SetAttribute('name',$relname)
                    $fileNode.SetAttribute('issue','not in manifest')
                    $folderNode.AppendChild($fileNode) | Out-Null
                }
            }
        }
    }
}

# ==================== PROGRESS & PROCESS HELPERS ====================
# Get-RainbowColor and Write-RainbowProgress are now provided by PwShGUICore module.

function Get-FooterItemTooltip {
    <#
    .SYNOPSIS
        Builds a rich multi-line tooltip string showing file/folder metadata for
        a footer status-bar element.
    #>
    param(
        [string]$ItemPath,
        [string]$ItemLabel = ''
    )
    if ([string]::IsNullOrWhiteSpace($ItemPath)) {
        return "$ItemLabel`nPath: (not configured)"
    }
    if (-not (Test-Path -LiteralPath $ItemPath)) {
        return "$ItemLabel`nPath: $ItemPath`nStatus: Not accessible"
    }
    try {
        $item = Get-Item -LiteralPath $ItemPath -ErrorAction Stop
    } catch {
        return "$ItemLabel`nPath: $ItemPath`nStatus: Cannot read"
    }
    $lines = @()
    if ($ItemLabel) { $lines += $ItemLabel }
    $lines += "Path: $($item.FullName)"
    if ($item.PSIsContainer) {
        $childFiles = @(Get-ChildItem -LiteralPath $ItemPath -File -Recurse -ErrorAction SilentlyContinue)
        $childDirs  = @(Get-ChildItem -LiteralPath $ItemPath -Directory -ErrorAction SilentlyContinue)
        $totalBytes = 0
        foreach ($cf in $childFiles) { $totalBytes += $cf.Length }
        $sizeText = if ($totalBytes -ge 1GB) { '{0:N2} GB' -f ($totalBytes / 1GB) }
                    elseif ($totalBytes -ge 1MB) { '{0:N1} MB' -f ($totalBytes / 1MB) }
                    elseif ($totalBytes -ge 1KB) { '{0:N0} KB' -f ($totalBytes / 1KB) }
                    else { "$totalBytes bytes" }
        $lines += "Type: Directory"
        $lines += "Files: $(@($childFiles).Count) | Sub-folders: $(@($childDirs).Count)"
        $lines += "Total Size: $sizeText"
        $lines += "Created: $($item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        $lines += "Modified: $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        # Most recently changed file in directory
        $newest = $childFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $lines += "Last Changed File: $($newest.Name)"
            $lines += "  Changed: $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
    } else {
        $ext = $item.Extension.ToLower()
        $sizeText = if ($item.Length -ge 1GB) { '{0:N2} GB' -f ($item.Length / 1GB) }
                    elseif ($item.Length -ge 1MB) { '{0:N1} MB' -f ($item.Length / 1MB) }
                    elseif ($item.Length -ge 1KB) { '{0:N0} KB' -f ($item.Length / 1KB) }
                    else { "$($item.Length) bytes" }
        $lines += "Type: $ext file"
        $lines += "Size: $sizeText"
        # Count lines for text-based files
        $textExts = @('.ps1','.psm1','.psd1','.txt','.md','.json','.xml','.csv','.log','.xhtml','.html','.css','.bat','.cmd','.cfg','.ini')
        if ($ext -in $textExts) {
            $lineCount = 0
            try { $lineCount = @(Get-Content -LiteralPath $ItemPath -ErrorAction Stop).Count } catch { <# Intentional: non-fatal #> }
            $lines += "Lines: $lineCount"
        }
        $lines += "Created: $($item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        $lines += "Modified: $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        # Attempt to identify last modifier from action-log
        $actionLogPath = Join-Path $PSScriptRoot (Join-Path 'logs' 'action-log.json')
        if (Test-Path -LiteralPath $actionLogPath) {
            try {
                $logEntries = Get-Content -LiteralPath $actionLogPath -Raw -Encoding UTF8 -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
                $relName = $item.Name
                $match = @($logEntries | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'file' -and $_.file -like "*$relName*") -or
                    ($_.PSObject.Properties.Name -contains 'target' -and $_.target -like "*$relName*")
                } | Sort-Object { if ($_.PSObject.Properties.Name -contains 'timestamp') { $_.timestamp } else { '' } } -Descending |
                    Select-Object -First 1)
                if (@($match).Count -gt 0) {
                    $entry = $match[0]
                    $actor = if ($entry.PSObject.Properties.Name -contains 'script') { $entry.script }
                             elseif ($entry.PSObject.Properties.Name -contains 'agent') { $entry.agent }
                             elseif ($entry.PSObject.Properties.Name -contains 'process') { $entry.process }
                             else { 'unknown' }
                    $lines += "Last Actor: $actor"
                }
            } catch { <# Intentional: non-fatal — action log may not exist or be parseable #> }
        }
    }
    $lines += "`nClick to open in Explorer"
    return ($lines -join "`n")
}

function Invoke-LocalScriptWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [bool]$UseWhatIf = $false,

        [int]$EstimatedSeconds = 10
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "▶ STEP 1 of 1: Executing $ScriptName" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $job = Start-Job -ScriptBlock {
        param($path, $useWhatIf)
        if ($useWhatIf) {
            & $path -WhatIf *>&1
        } else {
            & $path *>&1
        }
    } -ArgumentList $ScriptPath, $UseWhatIf

    $startTime = Get-Date
    $lastOutputCount = 0
    $elapsedBlocks = 0
    $percentComplete = 0

    while ($job.State -eq 'Running') {
        $elapsed = (Get-Date) - $startTime
        $elapsedSeconds = [Math]::Floor($elapsed.TotalSeconds)

        if ($elapsedSeconds -lt $EstimatedSeconds -and $EstimatedSeconds -gt 0) {
            $percentComplete = [Math]::Floor(($elapsedSeconds / $EstimatedSeconds) * 100)
        } else {
            $percentComplete = 95 + ($elapsedSeconds - $EstimatedSeconds)
            if ($percentComplete -gt 99) { $percentComplete = 99 }
        }

        $currentBlock = [Math]::Floor($elapsedSeconds / 5)
        if ($currentBlock -gt $elapsedBlocks) {
            $elapsedBlocks = $currentBlock
            Write-Host "`n⏱  Elapsed: $($elapsedBlocks * 5) seconds" -ForegroundColor Magenta
        }

        $status = "Processing... Elapsed: $elapsedSeconds s"
        Write-RainbowProgress -Activity $ScriptName -PercentComplete $percentComplete -Status $status -Step $elapsedSeconds

        $output = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
        $outputArray = @($output)
        if ($outputArray.Count -gt $lastOutputCount) {
            $outputArray[$lastOutputCount..($outputArray.Count - 1)] | ForEach-Object { Write-Host $_ }
            $lastOutputCount = $outputArray.Count
        }

        Start-Sleep -Milliseconds 500
    }

    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    $finalElapsed = ((Get-Date) - $startTime).TotalSeconds
    Write-RainbowProgress -Activity $ScriptName -PercentComplete 100 -Status "COMPLETED!" -Step 10

    Write-Host "`n[DONE] COMPLETED: $ScriptName" -ForegroundColor Green
    Write-Host "  Duration: $([Math]::Round($finalElapsed, 2)) seconds" -ForegroundColor Gray
    Write-Host "  Items processed: $lastOutputCount" -ForegroundColor Gray
    Write-AppLog "Completed: $ScriptName in $([Math]::Round($finalElapsed,2))s ($lastOutputCount items)" "Info"

    return $result
}

function Wait-ProcessWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [int]$EstimatedSeconds = 10
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "▶ STEP 1 of 1: Executing $ScriptName (elevated)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $startTime = Get-Date
    $elapsedBlocks = 0
    $percentComplete = 0

    while (-not $Process.HasExited) {
        $elapsed = (Get-Date) - $startTime
        $elapsedSeconds = [Math]::Floor($elapsed.TotalSeconds)

        if ($elapsedSeconds -lt $EstimatedSeconds -and $EstimatedSeconds -gt 0) {
            $percentComplete = [Math]::Floor(($elapsedSeconds / $EstimatedSeconds) * 100)
        } else {
            $percentComplete = 95 + ($elapsedSeconds - $EstimatedSeconds)
            if ($percentComplete -gt 99) { $percentComplete = 99 }
        }

        $currentBlock = [Math]::Floor($elapsedSeconds / 5)
        if ($currentBlock -gt $elapsedBlocks) {
            $elapsedBlocks = $currentBlock
            Write-Host "`n⏱  Elapsed: $($elapsedBlocks * 5) seconds" -ForegroundColor Magenta
        }

        $status = "Processing... Elapsed: $elapsedSeconds s"
        Write-RainbowProgress -Activity $ScriptName -PercentComplete $percentComplete -Status $status -Step $elapsedSeconds
        Start-Sleep -Milliseconds 500
    }

    $finalElapsed = ((Get-Date) - $startTime).TotalSeconds
    Write-RainbowProgress -Activity $ScriptName -PercentComplete 100 -Status "COMPLETED!" -Step 10

    Write-Host "`n[DONE] COMPLETED: $ScriptName" -ForegroundColor Green
    Write-Host "  Duration: $([Math]::Round($finalElapsed, 2)) seconds" -ForegroundColor Gray
    Write-Host "  Items processed: Output not captured (elevated process)" -ForegroundColor Gray
    Write-AppLog "Completed (elevated): $ScriptName in $([Math]::Round($finalElapsed,2))s" "Info"
}

# ==================== SCRIPT EXECUTION FUNCTIONS ====================
function Invoke-ScriptWithElevation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        
        [bool]$RunAsAdmin = $false
    )
    
    $scriptPath = Join-Path $scriptsDir "$ScriptName.ps1"
    
    if (-not (Test-Path $scriptPath)) {
        Write-AppLog "Script not found: $scriptPath" "Error"
        Write-ScriptLog "Script not found: $scriptPath" $ScriptName "Error"
        [System.Windows.Forms.MessageBox]::Show("Script not found: $ScriptName.ps1", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
    
    $scriptContent = Get-Content $scriptPath -Raw -ErrorAction SilentlyContinue
    $scoreInfo = if ($scriptContent) { Get-ScriptSafetyScore -Content $scriptContent } else { $null }
    $safetyScore = if ($scoreInfo) { $scoreInfo.Score } else { 0 }
    $requiresInteractive = $false
    if ($scriptContent) {
        $requiresInteractive = $scriptContent -match '\bRead-Host\b|\bPromptForChoice\b|\bReadKey\b|Out-GridView\s+.*-OutputMode|\.ShowDialog\(|MessageBox\]::Show\('
    } else {
        $requiresInteractive = $ScriptName -match 'QUICK-APP' -or $scriptPath -match '\\QUICK-APP\\'
    }
    if (-not $requiresInteractive) {
        if ($ScriptName -match 'QUICK-APP' -or $scriptPath -match '\\QUICK-APP\\') {
            $requiresInteractive = $true
        }
    }
    Write-AppLog "Launching script: $ScriptName (RunAsAdmin: $RunAsAdmin)" "Info"
    Write-AppLog "Script safety score: $safetyScore | $scriptPath" "Info"
    Write-ScriptLog "Script launch initiated (RunAsAdmin: $RunAsAdmin)" $ScriptName "Audit"

    $supportsWhatIf = $false
    try {
        $cmd = Get-Command $scriptPath -ErrorAction Stop
        $supportsWhatIf = $cmd.Parameters.ContainsKey('WhatIf')
    } catch { $supportsWhatIf = $false }

    $useWhatIf = $false
    if ($safetyScore -gt 50 -and $supportsWhatIf) {
        $useWhatIf = $true
        Write-AppLog "Auto-enabling -WhatIf due to safety score > 50" "Info"
    }
    
    try {
        if ($RunAsAdmin) {
            # Check if already running as admin
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
            $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            
            if ($isAdmin) {
                Write-AppLog "Already running as admin, executing script directly" "Info"
                Write-ScriptLog "Executing as admin (current session elevated)" $ScriptName "Info"
                if ($requiresInteractive) {
                    Write-AppLog "Interactive input detected (Read-Host). Running without progress monitor." "Info"
                    Write-ScriptLog "Interactive input detected. Running without progress monitor." $ScriptName "Info"
                    if ($useWhatIf) {
                        & $scriptPath -WhatIf
                    } else {
                        & $scriptPath
                    }
                } else {
                    $null = Invoke-LocalScriptWithProgress -ScriptPath $scriptPath -ScriptName $ScriptName -UseWhatIf $useWhatIf -EstimatedSeconds 10
                }
            }
            else {
                Write-AppLog "Attempting to elevate script execution" "Info"
                Write-ScriptLog "Executing with elevation prompt" $ScriptName "Info"
                $whatIfArg = if ($useWhatIf) { " -WhatIf" } else { "" }
                $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"$whatIfArg" -Verb RunAs -PassThru
                if ($requiresInteractive) {
                    Write-AppLog "Interactive input detected (Read-Host). Skipping progress monitor for elevated run." "Info"
                    Write-ScriptLog "Interactive input detected. Skipping progress monitor for elevated run." $ScriptName "Info"
                    $proc.WaitForExit()
                } else {
                    Wait-ProcessWithProgress -Process $proc -ScriptName $ScriptName -EstimatedSeconds 10
                }
            }
        }
        else {
            Write-AppLog "Executing script without elevation" "Info"
            Write-ScriptLog "Executing without admin elevation" $ScriptName "Info"
            if ($requiresInteractive) {
                Write-AppLog "Interactive input detected (Read-Host). Running without progress monitor." "Info"
                Write-ScriptLog "Interactive input detected. Running without progress monitor." $ScriptName "Info"
                if ($useWhatIf) {
                    & $scriptPath -WhatIf
                } else {
                    & $scriptPath
                }
            } else {
                $null = Invoke-LocalScriptWithProgress -ScriptPath $scriptPath -ScriptName $ScriptName -UseWhatIf $useWhatIf -EstimatedSeconds 10
            }
        }
        
        Write-AppLog "Script execution completed: $ScriptName" "Info"
        Write-ScriptLog "Script execution completed successfully" $ScriptName "Info"
        return $true
    }
    catch {
        Write-AppLog "Error executing script: $_" "Error"
        Write-ScriptLog "Script execution failed: $_" $ScriptName "Error"
        [System.Windows.Forms.MessageBox]::Show("Error executing script: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

function Show-ElevationPrompt {
    param(
        [string]$ScriptName,
        [string]$ScriptPath
    )
    
    Write-AppLog "Displaying admin elevation prompt for script: $ScriptName" "Audit"
    
    # Calculate safety score
    $safetyScore = 0
    $scoreEmoji = "[ ]"
    $scoreColor = "Unknown"
    $scriptContent = ""
    
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        $scriptContent = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
        if ($scriptContent) {
            $scoreInfo = Get-ScriptSafetyScore -Content $scriptContent
            $safetyScore = $scoreInfo.Score
            
            # Determine color and emoji
            if ($safetyScore -ge 80) {
                $scoreEmoji = "[+]"
                $scoreColor = "Safe"
            } elseif ($safetyScore -ge 50) {
                $scoreEmoji = "[~]"
                $scoreColor = "Moderate"
            } else {
                $scoreEmoji = "[!]"
                $scoreColor = "Risky"
            }
        }
    }
    
    # Build message with safety badge
    $message = "=======================================`n"
    $message += "  Script: $ScriptName`n"
    $message += "  Safety Score: $safetyScore/100 $scoreEmoji`n"
    $message += "  Status: $scoreColor`n"
    $message += "=======================================`n`n"
    $message += "Run with administrator privileges?"
    
    if ($safetyScore -gt 50 -and $safetyScore -lt 100) {
        $message += "`n`nNOTE: Script will run with -WhatIf (preview mode)"
    }
    
    Write-AppLog "Script safety score displayed: $safetyScore ($scoreColor)" "Info"
    
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Admin Elevation Request",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    
    $shouldElevate = $result -eq [System.Windows.Forms.DialogResult]::Yes
    Write-AppLog "Admin elevation response: $(if ($shouldElevate) { 'YES' } else { 'NO' })" "Audit"
    
    return $shouldElevate
}

# ==================== NETWORK DIAGNOSTICS ====================
function Get-NetworkDiagnostic {
    $results = @()
    
    # Get local IP
    try {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        if (-not $localIP) {
            $localIP = ([System.Net.Dns]::GetHostByName([System.Net.Dns]::GetHostName()).AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0].IPAddress
        }
        $results += "Local IP: $localIP"
    }
    catch {
        $results += "Local IP: Unable to determine"
    }
    
    # Get gateway IP
    try {
        $gateway = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Select-Object -First 1).NextHop
        $results += "Gateway IP: $gateway"
    }
    catch {
        $results += "Gateway IP: Unable to determine"
    }
    
    # Get public WAN IP
    try {
        $wanIP = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 5 -ErrorAction Stop | Select-Object -ExpandProperty ip
        $results += "Public WAN IP: $wanIP"
    }
    catch {
        Write-AppLog "WAN IP lookup failed: $_" "Warning"
        $results += "Public WAN IP: Unable to determine"
    }
    
    # DNS servers
    $results += "`nDNS Configuration:"
    $dnsServers = @("1.1.1.1", "9.9.9.9", "8.8.8.8")
    
    foreach ($dns in $dnsServers) {
        $pingTest = $false
        $dnsTest = $false
        
        try {
            $ping = Test-Connection -ComputerName $dns -Count 1 -ErrorAction SilentlyContinue
            $pingTest = $null -ne $ping
        }
        catch { $pingTest = $false }
        
        try {
            $dnsResolve = Resolve-DnsName -Name "google.com" -Server $dns -ErrorAction SilentlyContinue
            $dnsTest = $null -ne $dnsResolve
        }
        catch { $dnsTest = $false }
        
        $pingStatus = if ($pingTest) { "OK Reachable" } else { "FAIL Unreachable" }
        $dnsStatus = if ($dnsTest) { "OK Working" } else { "FAIL Failed" }
        
        $results += "DNS $dns - Ping: $pingStatus | Lookup: $dnsStatus"
    }
    
    return $results
}

# ==================== GUI LAYOUT DISPLAY ====================
function Show-GUILayout {
    [System.Windows.Forms.MessageBox]::Show(
        @"
Scriptz n Portz N PowerShellD - Layout Information:

MAIN WINDOW (600x500)
+ Menu Bar
|  + File
|  |  - Exit (Ctrl+Q)
|  + Tests
|  |  - Version Check
|  |  - Network Diagnostics
|  |  - Disk Check
|  |  - Privacy Check
|  |  - System Check
|  + Links
|  |  - CORPORATE
|  |  - PUBLIC-INFO
|  |  - LOCAL
|  |  - M365
|  |  - SEARCH
|  |  - USERS-URLS
|  + WinGets
|  |  - Installed Apps (Grid View)
|  |  - Detect Updates (Check-Only)
|  |  - Update All (Admin Options)
|  + Tools
|  |  - View Config
|  |  - Open Logs Directory
|  |  - Scriptz n Portz N PowerShellD (Layout)
|  |  - Button Maintenance
|  |  - Network Details
|  |  - AVPN Connection Tracker
|  |  - Cron-Ai-Athon Tool
|  + Help
|     - Update-Help
|     - Package Workspace
|     - About
+ Title Label (560x30) - "Scriptz n Portz N PowerShellD"
+ Buttons Grid (2 columns x 3 rows)
|  - Script1 - Database Maintenance
|  - Script2 - System Cleanup
|  - Script3 - Network Diagnostics
|  - Script4 - User Management
|  - Script5 - Backup Operations
|  - Script6 - Configuration Sync
`- Status Bar (600x20)

CONFIGURATION
- Config File: $configFile
- AVPN Devices: $avpnConfigFile
``- Logs Directory: $logsDir

For more information, see the documentation files.
"@,
        "Scriptz n Portz N PowerShellD - Layout",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

# ==================== PATH MANAGEMENT FUNCTIONS ====================
function Test-PathReadWrite {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return @{ Readable = $false; Writable = $false; Exists = $false }
    }
    
    $canRead = $true
    $canWrite = $true
    
    try {
        $null = Get-ChildItem -Path $Path -ErrorAction Stop
    } catch {
        $canRead = $false
    }
    
    try {
        $testFile = Join-Path $Path ".access-test-$([guid]::NewGuid().ToString()).tmp"
        New-Item -ItemType File -Path $testFile -Force | Out-Null
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
    } catch {
        $canWrite = $false
    }
    
    return @{ Readable = $canRead; Writable = $canWrite; Exists = $true }
}

function Get-ScriptFoldersConfig {
    $scriptFoldersConfigPath = Get-ProjectPath ScriptFolders
    if ([string]::IsNullOrWhiteSpace($scriptFoldersConfigPath)) { return $null }
    if (Test-Path $scriptFoldersConfigPath) {
        try {
            $config = Get-Content -Path $scriptFoldersConfigPath -Raw | ConvertFrom-Json
            return $config
        } catch {
            Write-AppLog "Error reading script folders config: $_" "Warning"
            return $null
        }
    }
    return $null
}

function Save-ScriptFoldersConfig {
    param([object]$Config)

    $scriptFoldersConfigPath = Get-ProjectPath ScriptFolders
    if ([string]::IsNullOrWhiteSpace($scriptFoldersConfigPath)) {
        Write-AppLog 'Save-ScriptFoldersConfig: path registry not initialized, cannot save' 'Warning'
        return $false
    }
    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $scriptFoldersConfigPath -Encoding UTF8 -Force
        Write-AppLog "Script folders config saved successfully" "Info"
        return $true
    } catch {
        Write-AppLog "Error saving script folders config: $_" "Error"
        return $false
    }
}

function Show-PathSettingsGUI {
    $requiredPaths = @(
        @{ Key = "ConfigPath";    Label = "Configuration Folder";    Default = $ConfigPath    },
        @{ Key = "DefaultFolder"; Label = "Default Working Folder";  Default = $DefaultFolder },
        @{ Key = "TempFolder";    Label = "Temporary Folder";        Default = $TempFolder    },
        @{ Key = "ReportFolder";  Label = "Report Output Folder";    Default = $ReportFolder  },
        @{ Key = "DownloadFolder"; Label = "Download Folder";        Default = $DownloadFolder }
    )

    $remotePaths = @(
        @{ Key = "RemoteUpdatePath";   Label = "Remote Update Path";   XPath = "RemoteUpdatePath";   Default = $RemoteUpdatePath   },
        @{ Key = "RemoteConfigPath";   Label = "Remote Config Path";   XPath = "RemoteConfigPath";   Default = $RemoteConfigPath   },
        @{ Key = "RemoteTemplatePath"; Label = "Remote Template Path"; XPath = "RemoteTemplatePath"; Default = $RemoteTemplatePath },
        @{ Key = "RemoteBackupPath";   Label = "Remote Backup Path";   XPath = "RemoteBackupPath";   Default = $RemoteBackupPath   },
        @{ Key = "RemoteArchivePath";  Label = "Remote Archive Path";  XPath = "RemoteArchivePath";  Default = $RemoteArchivePath  },
        @{ Key = "RemoteLinksPath";    Label = "Remote Links Path";    XPath = "RemoteLinksPath";    Default = $RemoteLinksPath    }
    )

    # Load current remote path values from config, overriding empty script-scope defaults
    foreach ($rp in $remotePaths) {
        $cfgVal = try { [string](Get-ConfigSubValue $rp.XPath) } catch { "" }
        if (-not [string]::IsNullOrWhiteSpace($cfgVal)) { $rp.Default = $cfgVal }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Path Configuration Settings"
    $form.Size = New-Object System.Drawing.Size(800, 760)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Configure Application Paths"
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(770, 20)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)

    $pathControls       = @{}
    $remotePathControls = @{}
    $yPos = 45

    $ValidatePathStatus = {
        foreach ($key in $pathControls.Keys) {
            $ctrl   = $pathControls[$key]
            $result = Test-PathReadWrite -Path $ctrl.TextBox.Text
            if ($result.Exists -and $result.Readable -and $result.Writable) {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::LightGreen
            } elseif ($result.Exists -and $result.Readable) {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::Yellow
            } else {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::LightCoral
            }
        }
    }

    # ---- Local Paths ----
    foreach ($pathItem in $requiredPaths) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = "$($pathItem.Label):"
        $label.Location = New-Object System.Drawing.Point(12, $yPos)
        $label.Size = New-Object System.Drawing.Size(770, 18)
        $label.Font = New-Object System.Drawing.Font("Arial", 9)
        $form.Controls.Add($label)
        $yPos += 20

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Text = $pathItem.Default
        $textBox.Location = New-Object System.Drawing.Point(12, $yPos)
        $textBox.Size = New-Object System.Drawing.Size(700, 22)
        $textBox.Font = New-Object System.Drawing.Font("Courier New", 9)
        $form.Controls.Add($textBox)

        $browseBtn = New-Object System.Windows.Forms.Button
        $browseBtn.Text = "Browse..."
        $browseBtn.Location = New-Object System.Drawing.Point(720, $yPos)
        $browseBtn.Size = New-Object System.Drawing.Size(60, 22)
        $browseBtn.Add_Click({
            param($btnSender, $e)
            $folder = New-Object System.Windows.Forms.FolderBrowserDialog
            $folder.Description = "Select path for $($btnSender.Tag)"
            $folder.SelectedPath = $textBox.Text
            if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $textBox.Text = $folder.SelectedPath
                & $ValidatePathStatus
            }
            $folder.Dispose()
        }.GetNewClosure())
        $browseBtn.Tag = $pathItem.Label
        $form.Controls.Add($browseBtn)

        $pathControls[$pathItem.Key] = @{ TextBox = $textBox; Label = $label; BrowseBtn = $browseBtn }
        $yPos += 35
    }

    # ---- Remote Paths Section ----
    $yPos += 8
    $remoteSectionLabel = New-Object System.Windows.Forms.Label
    $remoteSectionLabel.Text = "Remote Paths"
    $remoteSectionLabel.Location = New-Object System.Drawing.Point(12, $yPos)
    $remoteSectionLabel.Size = New-Object System.Drawing.Size(770, 20)
    $remoteSectionLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    $remoteSectionLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    $form.Controls.Add($remoteSectionLabel)
    $yPos += 24

    foreach ($rItem in $remotePaths) {
        $rLabel = New-Object System.Windows.Forms.Label
        $rLabel.Text = "$($rItem.Label):"
        $rLabel.Location = New-Object System.Drawing.Point(12, $yPos)
        $rLabel.Size = New-Object System.Drawing.Size(770, 18)
        $rLabel.Font = New-Object System.Drawing.Font("Arial", 9)
        $form.Controls.Add($rLabel)
        $yPos += 20

        $rTextBox = New-Object System.Windows.Forms.TextBox
        $rTextBox.Text = $rItem.Default
        $rTextBox.Location = New-Object System.Drawing.Point(12, $yPos)
        $rTextBox.Size = New-Object System.Drawing.Size(700, 22)
        $rTextBox.Font = New-Object System.Drawing.Font("Courier New", 9)
        $form.Controls.Add($rTextBox)

        $rBrowseBtn = New-Object System.Windows.Forms.Button
        $rBrowseBtn.Text = "Browse..."
        $rBrowseBtn.Location = New-Object System.Drawing.Point(720, $yPos)
        $rBrowseBtn.Size = New-Object System.Drawing.Size(60, 22)
        $rItemCopy    = $rItem
        $rTextBoxCopy = $rTextBox
        $rBrowseBtn.Add_Click({
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = "Select path for $($rItemCopy.Label)"
            $fb.SelectedPath = if ([string]::IsNullOrWhiteSpace($rTextBoxCopy.Text)) { $scriptDir } else { $rTextBoxCopy.Text }
            if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $rTextBoxCopy.Text = $fb.SelectedPath
            }
            $fb.Dispose()
        }.GetNewClosure())
        $rBrowseBtn.Tag = $rItem.Label
        $form.Controls.Add($rBrowseBtn)

        $remotePathControls[$rItem.Key] = @{ TextBox = $rTextBox; Label = $rLabel; BrowseBtn = $rBrowseBtn; XPath = $rItem.XPath }
        $yPos += 35
    }

    $yPos += 8

    # Validate button
    $validateBtn = New-Object System.Windows.Forms.Button
    $validateBtn.Text = "Validate All"
    $validateBtn.Location = New-Object System.Drawing.Point(12, $yPos)
    $validateBtn.Size = New-Object System.Drawing.Size(100, 25)
    $validateBtn.Add_Click({ & $ValidatePathStatus })
    $form.Controls.Add($validateBtn)

    # OK Button
    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(620, $yPos)
    $okBtn.Size = New-Object System.Drawing.Size(75, 25)
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.Add_Click({
        # Save local paths to script variables
        $script:ConfigPath    = $pathControls["ConfigPath"].TextBox.Text
        $script:DefaultFolder = $pathControls["DefaultFolder"].TextBox.Text
        $script:TempFolder    = $pathControls["TempFolder"].TextBox.Text
        $script:ReportFolder  = $pathControls["ReportFolder"].TextBox.Text
        $script:DownloadFolder = $pathControls["DownloadFolder"].TextBox.Text

        # Create local directories if missing
        @($script:ConfigPath, $script:DefaultFolder, $script:TempFolder, $script:ReportFolder, $script:DownloadFolder) | ForEach-Object {
            if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
        }

        # Save remote paths to script variables and config
        foreach ($key in $remotePathControls.Keys) {
            $val = $remotePathControls[$key].TextBox.Text.Trim()
            $xp  = $remotePathControls[$key].XPath
            Set-Variable -Name $key -Value $val -Scope Script -ErrorAction SilentlyContinue
            try { Set-ConfigSubValue -XPath $xp -Value $val } catch { Write-AppLog "Remote path save failed ($xp): $_" "Warning" }
        }

        $form.Close()
    })
    $form.Controls.Add($okBtn)

    # Cancel Button
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(700, $yPos)
    $cancelBtn.Size = New-Object System.Drawing.Size(75, 25)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)

    & $ValidatePathStatus
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Get-AllScriptFolders {
    $baseFolders = @($scriptsDir)
    $customFolders = @()
    
    $config = Get-ScriptFoldersConfig
    if ($config -and $config.customScriptFolders) {
        $customFolders = @($config.customScriptFolders | Where-Object { $_.enabled -eq $true } | ForEach-Object { $_.path })
    }
    
    return @($baseFolders + $customFolders)
}

function Show-ScriptFolderSettingsGUI {
    $config = Get-ScriptFoldersConfig
    if (-not $config) {
        $config = @{ customScriptFolders = @() }
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Manage Script Folders"
    $form.Size = New-Object System.Drawing.Size(700, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Configure Custom Script Folders"
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(670, 20)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Add or remove additional script folder paths. Each path will be stored and loaded on app startup."
    $infoLabel.Location = New-Object System.Drawing.Point(12, 35)
    $infoLabel.Size = New-Object System.Drawing.Size(670, 30)
    $form.Controls.Add($infoLabel)
    
    # ListBox for folders
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(12, 70)
    $listBox.Size = New-Object System.Drawing.Size(670, 350)
    $listBox.SelectionMode = [System.Windows.Forms.SelectionMode]::One
    
    foreach ($folder in $config.customScriptFolders) {
        $displayText = "$($folder.label) - $($folder.path)"
        [void]$listBox.Items.Add($displayText)
    }
    
    $form.Controls.Add($listBox)
    
    # Add Button
    $addBtn = New-Object System.Windows.Forms.Button
    $addBtn.Text = "Add Folder..."
    $addBtn.Location = New-Object System.Drawing.Point(12, 430)
    $addBtn.Size = New-Object System.Drawing.Size(100, 25)
    $addBtn.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = "Select a script folder to add"
        
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $newFolder = @{
                path = $folderDialog.SelectedPath
                label = [System.IO.Path]::GetFileName($folderDialog.SelectedPath)
                enabled = $true
                addedDate = (Get-Date -Format "yyyy-MM-dd")
            }
            
            $config.customScriptFolders += $newFolder
            $displayText = "$($newFolder.label) - $($newFolder.path)"
            [void]$listBox.Items.Add($displayText)
        }
        $folderDialog.Dispose()
    })
    $form.Controls.Add($addBtn)
    
    # Remove Button
    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Location = New-Object System.Drawing.Point(120, 430)
    $removeBtn.Size = New-Object System.Drawing.Size(75, 25)
    $removeBtn.Add_Click({
        if ($listBox.SelectedIndex -ge 0) {
            $selected = $listBox.SelectedIndex
            $config.customScriptFolders = @($config.customScriptFolders | Where-Object { $_ -ne $config.customScriptFolders[$selected] })
            $listBox.Items.RemoveAt($selected)
        }
    })
    $form.Controls.Add($removeBtn)
    
    # OK Button
    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(490, 430)
    $okBtn.Size = New-Object System.Drawing.Size(90, 25)
    $okBtn.Add_Click({
        Save-ScriptFoldersConfig -Config $config
        Write-AppLog "Script folders configuration updated" "Info"
        $form.Close()
    })
    $form.Controls.Add($okBtn)
    
    # Cancel Button
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(590, 430)
    $cancelBtn.Size = New-Object System.Drawing.Size(90, 25)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)
    
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# ==================== HELP FUNCTIONS ====================

# ── Manifests, Registries & SINs Viewer ─────────────────────────────────
function Show-ManifestsRegistrySinsViewer {
    Write-AppLog "User opened Manifests, Registries & SINs viewer" "Audit"

    $viewerForm = New-Object System.Windows.Forms.Form
    $viewerForm.Text = "Manifests, Registries & SINs"
    $viewerForm.Size = New-Object System.Drawing.Size(960, 640)
    $viewerForm.StartPosition = "CenterScreen"
    $viewerForm.MinimumSize = New-Object System.Drawing.Size(800, 500)
    $viewerForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # ── TabControl ────────────────────────────────────────────────
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabs.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $viewerForm.Controls.Add($tabs)

    # ── Status bar ────────────────────────────────────────────────
    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = "Loading..."
    $statusBar.Items.Add($statusLabel) | Out-Null
    $viewerForm.Controls.Add($statusBar)

    # ═════════════════════════════════════════════════════════════
    #  Helper: build a split-panel tab with a ListView + detail box
    # ═════════════════════════════════════════════════════════════
    function New-DataTab {
        param(
            [string]$TabTitle,
            [string[]]$ColumnHeaders,
            [int[]]$ColumnWidths
        )
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = $TabTitle
        $page.Padding = New-Object System.Windows.Forms.Padding(4)

        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = [System.Windows.Forms.DockStyle]::Fill
        $split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
        $split.SplitterDistance = 340
        $page.Controls.Add($split)

        $lv = New-Object System.Windows.Forms.ListView
        $lv.View = [System.Windows.Forms.View]::Details
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
        $lv.Font = New-Object System.Drawing.Font("Consolas", 9)
        for ($i = 0; $i -lt $ColumnHeaders.Count; $i++) {
            $col = New-Object System.Windows.Forms.ColumnHeader
            $col.Text  = $ColumnHeaders[$i]
            $col.Width = $ColumnWidths[$i]
            $lv.Columns.Add($col) | Out-Null
        }
        $split.Panel1.Controls.Add($lv)

        $detail = New-Object System.Windows.Forms.TextBox
        $detail.Multiline  = $true
        $detail.ReadOnly   = $true
        $detail.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $detail.WordWrap   = $false
        $detail.Dock       = [System.Windows.Forms.DockStyle]::Fill
        $detail.Font       = New-Object System.Drawing.Font("Consolas", 9)
        $split.Panel2.Controls.Add($detail)

        $tabs.TabPages.Add($page) | Out-Null

        return @{ Page = $page; ListView = $lv; Detail = $detail }
    }

    # ═════════════════════════════════════════════════════════════
    #  TAB 1:  SIN Registry  (instances + patterns + SemiSins)
    # ═════════════════════════════════════════════════════════════
    $sinTab = New-DataTab -TabTitle "SIN Registry" `
        -ColumnHeaders @('SIN ID','Class','Severity','Category','Status','Title') `
        -ColumnWidths  @(260,80,80,120,90,280)

    $sinDir = Join-Path $PSScriptRoot 'sin_registry'
    $sinFiles = @(Get-ChildItem -Path $sinDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $sinTotal = 0; $sinResolved = 0; $sinCritical = 0; $sinPenance = 0
    $sinDetailMap = @{}

    foreach ($sf in $sinFiles) {
        try {
            $raw = Get-Content $sf.FullName -Raw -Encoding UTF8
            $sin = $raw | ConvertFrom-Json
            $props = $sin.PSObject.Properties.Name

            $sinId    = if ($props -contains 'sin_id')   { $sin.sin_id }   else { $sf.BaseName }
            $severity = if ($props -contains 'severity') { $sin.severity } else { '?' }
            $category = if ($props -contains 'category') { $sin.category } else { '' }
            $title    = if ($props -contains 'title')    { $sin.title }    else { '' }
            $resolved = if ($props -contains 'is_resolved') { $sin.is_resolved } else { $false }

            # Determine class
            $sinClass = 'Instance'
            if ($sinId -match '^SIN-PATTERN-')  { $sinClass = 'Pattern' }
            if ($sinId -match '^SEMI-SIN-')     { $sinClass = 'SemiSin' }

            $status = if ($resolved) { 'Resolved' } elseif ($props -contains 'status') { $sin.status } else { 'Open' }

            $item = New-Object System.Windows.Forms.ListViewItem($sinId)
            $item.SubItems.Add($sinClass)  | Out-Null
            $item.SubItems.Add($severity)  | Out-Null
            $item.SubItems.Add($category)  | Out-Null
            $item.SubItems.Add($status)    | Out-Null
            $item.SubItems.Add($title)     | Out-Null

            # Colour coding by severity
            if ($severity -eq 'CRITICAL')   { $item.ForeColor = [System.Drawing.Color]::Red }
            elseif ($severity -eq 'HIGH')   { $item.ForeColor = [System.Drawing.Color]::OrangeRed }
            elseif ($severity -eq 'MEDIUM') { $item.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            elseif ($severity -eq 'PENANCE'){ $item.ForeColor = [System.Drawing.Color]::DarkOrchid }
            if ($resolved) { $item.ForeColor = [System.Drawing.Color]::Gray }

            $sinTab.ListView.Items.Add($item) | Out-Null
            $sinDetailMap[$sinId] = $raw
            $sinTotal++
            if ($resolved)              { $sinResolved++ }
            if ($severity -eq 'CRITICAL') { $sinCritical++ }
            if ($severity -eq 'PENANCE')  { $sinPenance++ }
        }
        catch { <# skip unparseable files #> }
    }

    $sinTab.ListView.Add_SelectedIndexChanged({
        if ($sinTab.ListView.SelectedItems.Count -gt 0) {
            $selId = $sinTab.ListView.SelectedItems[0].Text
            if ($sinDetailMap.ContainsKey($selId)) {
                $sinTab.Detail.Text = $sinDetailMap[$selId]
            }
        }
    })

    # ═════════════════════════════════════════════════════════════
    #  TAB 2:  Manifests
    # ═════════════════════════════════════════════════════════════
    $mfTab = New-DataTab -TabTitle "Manifests" `
        -ColumnHeaders @('Manifest','Type','Location','Size','Key Metric') `
        -ColumnWidths  @(220,100,300,80,210)

    $manifests = @()
    $mfDetailMap = @{}

    # Files Manifest (markdown)
    $filesManifest = Join-Path $PSScriptRoot '~README.md\FILES-MANIFEST.md'
    if (Test-Path $filesManifest) {
        $fmInfo = Get-Item $filesManifest
        $manifests += @{ Name = 'FILES-MANIFEST'; Type = 'Markdown'; Path = $fmInfo.FullName; Size = "$([math]::Round($fmInfo.Length / 1KB, 1))KB"; Metric = 'Workspace file inventory' }
        $mfDetailMap['FILES-MANIFEST'] = (Get-Content $filesManifest -TotalCount 80 -Encoding UTF8) -join "`r`n"
    }

    # Agentic Manifest (JSON)
    $agManifest = Join-Path $PSScriptRoot 'config\agentic-manifest.json'
    if (Test-Path $agManifest) {
        $amInfo = Get-Item $agManifest
        $metricText = ''
        try {
            $amJson = Get-Content $agManifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $c = $amJson.meta.counts
            $metricText = "$($c.modules) modules, $($c.totalExportedFunctions) funcs, $($c.scripts) scripts"
        } catch { $metricText = 'Parse error' }
        $manifests += @{ Name = 'agentic-manifest'; Type = 'JSON'; Path = $amInfo.FullName; Size = "$([math]::Round($amInfo.Length / 1KB, 1))KB"; Metric = $metricText }
        $mfDetailMap['agentic-manifest'] = (Get-Content $agManifest -TotalCount 120 -Encoding UTF8) -join "`r`n"
    }

    # Module Load Order
    $mloFile = Join-Path $PSScriptRoot '~README.md\MODULE-LOAD-ORDER.md'
    if (Test-Path $mloFile) {
        $mloInfo = Get-Item $mloFile
        $manifests += @{ Name = 'MODULE-LOAD-ORDER'; Type = 'Markdown'; Path = $mloInfo.FullName; Size = "$([math]::Round($mloInfo.Length / 1KB, 1))KB"; Metric = 'Module import sequence' }
        $mfDetailMap['MODULE-LOAD-ORDER'] = (Get-Content $mloFile -TotalCount 80 -Encoding UTF8) -join "`r`n"
    }

    # Module Function Index
    $mfiFile = Join-Path $PSScriptRoot '~README.md\MODULE-FUNCTION-INDEX.md'
    if (Test-Path $mfiFile) {
        $mfiInfo = Get-Item $mfiFile
        $manifests += @{ Name = 'MODULE-FUNCTION-INDEX'; Type = 'Markdown'; Path = $mfiInfo.FullName; Size = "$([math]::Round($mfiInfo.Length / 1KB, 1))KB"; Metric = 'Function-to-module mapping' }
        $mfDetailMap['MODULE-FUNCTION-INDEX'] = (Get-Content $mfiFile -TotalCount 80 -Encoding UTF8) -join "`r`n"
    }

    # Installation Summary
    $isFile = Join-Path $PSScriptRoot '~README.md\INSTALLATION-SUMMARY.md'
    if (Test-Path $isFile) {
        $isInfo = Get-Item $isFile
        $manifests += @{ Name = 'INSTALLATION-SUMMARY'; Type = 'Markdown'; Path = $isInfo.FullName; Size = "$([math]::Round($isInfo.Length / 1KB, 1))KB"; Metric = 'Setup & prerequisites' }
        $mfDetailMap['INSTALLATION-SUMMARY'] = (Get-Content $isFile -TotalCount 80 -Encoding UTF8) -join "`r`n"
    }

    # Scan for any other config/*.json that looks manifest-like
    $configJsons = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'config') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($cj in $configJsons) {
        if ($cj.Name -eq 'agentic-manifest.json') { continue }  # already added
        $manifests += @{ Name = $cj.BaseName; Type = 'Config JSON'; Path = $cj.FullName; Size = "$([math]::Round($cj.Length / 1KB, 1))KB"; Metric = 'Configuration' }
        $mfDetailMap[$cj.BaseName] = (Get-Content $cj.FullName -TotalCount 60 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`r`n"
    }

    foreach ($mf in $manifests) {
        $item = New-Object System.Windows.Forms.ListViewItem($mf.Name)
        $item.SubItems.Add($mf.Type) | Out-Null
        $item.SubItems.Add($mf.Path.Replace($PSScriptRoot, '.')) | Out-Null
        $item.SubItems.Add($mf.Size) | Out-Null
        $item.SubItems.Add($mf.Metric) | Out-Null
        $mfTab.ListView.Items.Add($item) | Out-Null
    }

    $mfTab.ListView.Add_SelectedIndexChanged({
        if ($mfTab.ListView.SelectedItems.Count -gt 0) {
            $selName = $mfTab.ListView.SelectedItems[0].Text
            if ($mfDetailMap.ContainsKey($selName)) {
                $mfTab.Detail.Text = $mfDetailMap[$selName]
            }
        }
    })

    # ═════════════════════════════════════════════════════════════
    #  TAB 3:  Registries
    # ═════════════════════════════════════════════════════════════
    $regTab = New-DataTab -TabTitle "Registries" `
        -ColumnHeaders @('Registry','Type','Location','Entries','Purpose') `
        -ColumnWidths  @(220,100,300,70,220)

    $registries = @()
    $regDetailMap = @{}

    # Agent Registry (JSON)
    $arFile = Join-Path $PSScriptRoot 'agents\focalpoint-null\config\agent_registry.json'
    if (Test-Path $arFile) {
        $arInfo = Get-Item $arFile
        $agentCount = 0
        $preview = ''
        try {
            $arRaw = Get-Content $arFile -Raw -Encoding UTF8
            $arJson = $arRaw | ConvertFrom-Json
            if ($arJson.PSObject.Properties.Name -contains 'agents') { $agentCount = @($arJson.agents).Count }
            $preview = $arRaw.Substring(0, [Math]::Min($arRaw.Length, 4000))
        } catch { $preview = 'Parse error' }
        $registries += @{ Name = 'agent_registry'; Type = 'JSON'; Path = $arInfo.FullName; Entries = "$agentCount"; Purpose = 'FocalPoint agent definitions' }
        $regDetailMap['agent_registry'] = $preview
    }

    # Pipeline Registry (JSON)
    $plFile = Join-Path $PSScriptRoot 'config\cron-aiathon-pipeline.json'
    if (Test-Path $plFile) {
        $plInfo = Get-Item $plFile
        $plCount = 0
        $preview = ''
        try {
            $plRaw = Get-Content $plFile -Raw -Encoding UTF8
            $plJson = $plRaw | ConvertFrom-Json
            foreach ($cat in @('bugs','featureRequests','items2ADD','bugs2FIX','todos')) {
                if ($plJson.PSObject.Properties.Name -contains $cat) {
                    $plCount += @($plJson.$cat).Count
                }
            }
            $preview = $plRaw.Substring(0, [Math]::Min($plRaw.Length, 4000))
        } catch { $preview = 'Parse error' }
        $registries += @{ Name = 'cron-aiathon-pipeline'; Type = 'JSON'; Path = $plInfo.FullName; Entries = "$plCount"; Purpose = 'Pipeline backlog items' }
        $regDetailMap['cron-aiathon-pipeline'] = $preview
    }

    # SIN Registry folder summary (already in Tab 1, but link here)
    if (Test-Path $sinDir) {
        $registries += @{ Name = 'sin_registry'; Type = 'Folder'; Path = $sinDir; Entries = "$sinTotal"; Purpose = "SIN tracking ($sinCritical CRIT, $sinPenance PENANCE)" }
        $regDetailMap['sin_registry'] = "SIN Registry Folder: $sinDir`r`n`r`nTotal entries: $sinTotal`r`nResolved: $sinResolved`r`nCritical: $sinCritical`r`nPenance (SemiSin): $sinPenance`r`n`r`nSee the SIN Registry tab for full details."
    }

    # Checkpoint Index
    $cpIndex = Join-Path $PSScriptRoot 'checkpoints\_index.json'
    if (Test-Path $cpIndex) {
        $cpInfo = Get-Item $cpIndex
        $cpCount = 0
        $preview = ''
        try {
            $cpRaw = Get-Content $cpIndex -Raw -Encoding UTF8
            $cpJson = $cpRaw | ConvertFrom-Json
            $cpCount = @($cpJson.PSObject.Properties).Count
            $preview = $cpRaw.Substring(0, [Math]::Min($cpRaw.Length, 4000))
        } catch { $preview = 'Parse error' }
        $registries += @{ Name = 'checkpoints/_index'; Type = 'JSON'; Path = $cpInfo.FullName; Entries = "$cpCount"; Purpose = 'Epoch checkpoint index' }
        $regDetailMap['checkpoints/_index'] = $preview
    }

    # AgentRegistry.psm1 module
    $agRegMod = Join-Path $PSScriptRoot 'sovereign-kernel\core\AgentRegistry.psm1'
    if (Test-Path $agRegMod) {
        $agModInfo = Get-Item $agRegMod
        $registries += @{ Name = 'AgentRegistry.psm1'; Type = 'Module'; Path = $agModInfo.FullName; Entries = '-'; Purpose = 'Sovereign kernel agent registry' }
        $regDetailMap['AgentRegistry.psm1'] = (Get-Content $agRegMod -TotalCount 80 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`r`n"
    }

    foreach ($rg in $registries) {
        $item = New-Object System.Windows.Forms.ListViewItem($rg.Name)
        $item.SubItems.Add($rg.Type) | Out-Null
        $item.SubItems.Add($rg.Path.Replace($PSScriptRoot, '.')) | Out-Null
        $item.SubItems.Add($rg.Entries) | Out-Null
        $item.SubItems.Add($rg.Purpose) | Out-Null
        $regTab.ListView.Items.Add($item) | Out-Null
    }

    $regTab.ListView.Add_SelectedIndexChanged({
        if ($regTab.ListView.SelectedItems.Count -gt 0) {
            $selName = $regTab.ListView.SelectedItems[0].Text
            if ($regDetailMap.ContainsKey($selName)) {
                $regTab.Detail.Text = $regDetailMap[$selName]
            }
        }
    })

    # ═════════════════════════════════════════════════════════════
    #  TAB 4:  Summary Dashboard
    # ═════════════════════════════════════════════════════════════
    $summaryPage = New-Object System.Windows.Forms.TabPage
    $summaryPage.Text = "Dashboard"
    $summaryPage.Padding = New-Object System.Windows.Forms.Padding(10)

    $summaryBox = New-Object System.Windows.Forms.TextBox
    $summaryBox.Multiline  = $true
    $summaryBox.ReadOnly   = $true
    $summaryBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $summaryBox.Dock       = [System.Windows.Forms.DockStyle]::Fill
    $summaryBox.Font       = New-Object System.Drawing.Font("Consolas", 10)
    $summaryBox.WordWrap   = $true

    $sinPatterns  = @($sinFiles | Where-Object { $_.Name -match '^SIN-PATTERN-' }).Count
    $sinInstances = @($sinFiles | Where-Object { $_.Name -match '^SIN-\d{8}' }).Count
    $sinSemiSins  = @($sinFiles | Where-Object { $_.Name -match '^SEMI-SIN-' }).Count

    $dashLines = @(
        "==================================================="
        "  MANIFESTS, REGISTRIES & SINS  -  DASHBOARD"
        "==================================================="
        ""
        "  SIN REGISTRY"
        "  -----------------------------------------------"
        "    Total entries ........... $sinTotal"
        "    SIN Instances ........... $sinInstances"
        "    SIN Patterns ............ $sinPatterns"
        "    SemiSin Definitions ..... $sinSemiSins"
        "    Resolved ................ $sinResolved"
        "    Open CRITICAL ........... $sinCritical"
        "    Open PENANCE ............ $sinPenance"
        ""
        "  MANIFESTS"
        "  -----------------------------------------------"
        "    Files tracked ........... $($manifests.Count)"
        "    Main manifests:"
    )
    foreach ($mf in $manifests) {
        if ($mf.Type -eq 'Config JSON') { continue }
        $dashLines += "      $($mf.Name)  ($($mf.Size))"
    }
    $dashLines += @(
        "    Config files ............ $($configJsons.Count)"
        ""
        "  REGISTRIES"
        "  -----------------------------------------------"
    )
    foreach ($rg in $registries) {
        $dashLines += "    $($rg.Name) : $($rg.Entries) entries - $($rg.Purpose)"
    }
    $dashLines += @(
        ""
        "  SCAN RESULTS"
        "  -----------------------------------------------"
    )
    $sinScanResults = Join-Path $PSScriptRoot 'temp\sin-scan-results.json'
    if (Test-Path $sinScanResults) {
        try {
            $sr = Get-Content $sinScanResults -Raw -Encoding UTF8 | ConvertFrom-Json
            $dashLines += "    Last SIN scan: $($sr.scanId)"
            $dashLines += "    Findings: $($sr.totalFindings) (C:$($sr.critical) H:$($sr.high) M:$($sr.medium))"
        } catch { $dashLines += "    SIN scan results: parse error" }
    } else { $dashLines += "    No SIN scan results yet" }

    $penanceResults = Join-Path $PSScriptRoot 'temp\semisin-penance-results.json'
    if (Test-Path $penanceResults) {
        try {
            $pr = Get-Content $penanceResults -Raw -Encoding UTF8 | ConvertFrom-Json
            $dashLines += "    Last Penance scan: $($pr.scanId)"
            $dashLines += "    Penance warnings: $($pr.penanceWarnings) ($($pr.baselineFiles) files tracked)"
        } catch { $dashLines += "    Penance results: parse error" }
    } else { $dashLines += "    No Penance scan results yet" }

    $dashLines += @(
        ""
        "==================================================="
    )
    $summaryBox.Text = $dashLines -join "`r`n"
    $summaryPage.Controls.Add($summaryBox)
    $tabs.TabPages.Insert(0, $summaryPage) | Out-Null
    $tabs.SelectedIndex = 0

    # ── Final status ──────────────────────────────────────────────
    $statusLabel.Text = "SINs: $sinTotal  |  Manifests: $($manifests.Count)  |  Registries: $($registries.Count)"

    $viewerForm.ShowDialog() | Out-Null
    $viewerForm.Dispose()
}

function Show-UpdateHelp {
    Write-AppLog "User initiated Update-Help" "Audit"
    [System.Windows.Forms.MessageBox]::Show("Updating PowerShell Help...", "Please Wait", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    
    try {
        Update-Help -Force -ErrorAction SilentlyContinue
        Write-AppLog "Help updated successfully" "Info"
        [System.Windows.Forms.MessageBox]::Show("PowerShell Help has been updated successfully.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    catch {
        Write-AppLog "Help update failed: $_" "Error"
        [System.Windows.Forms.MessageBox]::Show("Error updating help: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Show-NetworkDiagnosticsDialog {
    Write-AppLog "User opened Network Diagnostics" "Audit"
    
    $results = Get-NetworkDiagnostic
    $resultText = $results -join "`r`n"
    
    [System.Windows.Forms.MessageBox]::Show(
        $resultText,
        "Network Diagnostics",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    
    Write-AppLog "Network Diagnostics results displayed" "Debug"
}

# ==================== TESTING ROUTINES ====================
function Test-AppTesting {
    $root = (Get-Location).Path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $report = @()

    # Folders to exclude from scanning
    $scanExclude = @('.git', '.history', '~REPORTS\archive')
    $filterScan = { param($f) foreach ($ex in $scanExclude) { if ($f.FullName -like "$root\$ex\*") { return $false } }; return $true }

    $mdFiles = Get-ChildItem -Path $root -Recurse -File -Include *.md -ErrorAction SilentlyContinue | Where-Object { & $filterScan $_ }
    $scriptFiles = @(Get-CachedScriptFiles)

    $contradictionPairs = @(
        @("supported","not supported"),
        @("enabled","disabled"),
        @("required","not required"),
        @("recommended","not recommended"),
        @("deprecated","recommended")
    )

    foreach ($md in $mdFiles) {
        $content = Get-Content $md.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="empty file"; Detail="No content" }
            continue
        }

        $headingMatches = [regex]::Matches($content, "(?m)^\s*#{1,6}\s+(.+)$")
        if ($headingMatches.Count -eq 0) {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="missing headings"; Detail="No markdown headings found" }
        } else {
            $headingCounts = @{}
            foreach ($m in $headingMatches) {
                $key = $m.Groups[1].Value.Trim().ToLowerInvariant()
                if (-not $headingCounts.ContainsKey($key)) { $headingCounts[$key] = 0 }
                $headingCounts[$key]++
            }
            foreach ($k in $headingCounts.Keys) {
                if ($headingCounts[$k] -gt 1) {
                    $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="duplicate heading"; Detail=$k }
                }
            }
        }

        $paragraphs = ($content -split "\r?\n\s*\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 20 }
        $paraCounts = @{}
        foreach ($p in $paragraphs) {
            $key = $p.ToLowerInvariant()
            if (-not $paraCounts.ContainsKey($key)) { $paraCounts[$key] = 0 }
            $paraCounts[$key]++
        }
        foreach ($k in $paraCounts.Keys) {
            if ($paraCounts[$k] -gt 1) {
                $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="duplicate paragraph"; Detail="Repeated paragraph detected" }
                break
            }
        }

        foreach ($pair in $contradictionPairs) {
            if ($content -match [regex]::Escape($pair[0]) -and $content -match [regex]::Escape($pair[1])) {
                $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="possible contradiction"; Detail="Contains '$($pair[0])' and '$($pair[1])'" }
            }
        }

        if ($content -match "\bTODO\b|\bTBD\b") {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="incomplete content"; Detail="TODO/TBD marker found" }
        }
    }

    foreach ($script in $scriptFiles) {
        $content = Get-Content $script.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $commentLines = @()
        $lines = $content -split "\r?\n"
        $inBlock = $false

        foreach ($line in $lines) {
            if ($line -match "<#(.*)#>") {
                $commentLines += $Matches[1].Trim()
                continue
            }
            if ($line -match "^\s*<#") { $inBlock = $true; continue }
            if ($line -match "#>") { $inBlock = $false; continue }

            if ($inBlock) {
                $commentLines += $line.Trim()
                continue
            }

            if ($line -match "^\s*#(.*)") {
                $commentLines += $Matches[1].Trim()
            }
        }

        $commentLines = $commentLines | Where-Object { $_ -and $_.Length -gt 0 }
        if ($commentLines.Count -eq 0) { continue }

        $commentCounts = @{}
        foreach ($c in $commentLines) {
            $key = $c.ToLowerInvariant()
            if (-not $commentCounts.ContainsKey($key)) { $commentCounts[$key] = 0 }
            $commentCounts[$key]++
        }
        foreach ($k in $commentCounts.Keys) {
            if ($commentCounts[$k] -gt 2) {
                $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="duplicate comment"; Detail=$k }
            }
        }

        foreach ($pair in $contradictionPairs) {
            if ($commentLines -match [regex]::Escape($pair[0]) -and $commentLines -match [regex]::Escape($pair[1])) {
                $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="possible contradiction"; Detail="Contains '$($pair[0])' and '$($pair[1])'" }
            }
        }

        foreach ($line in $commentLines) {
            if ($line -match "[A-Z]:\\[^\s]+") {
                $path = $Matches[0]
                if (-not (Test-Path $path)) {
                    $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="path not found"; Detail=$path }
                }
            }
        }
    }

    # Regression tests: PowerShell parsing and known parser pitfalls
    $parseTargets = @(
        @{ Name = "Windows PowerShell 5.1"; Command = "powershell.exe" },
        @{ Name = "PowerShell 7"; Command = "pwsh" }
    )

    $parseScript = @'
$tokens=$null
$errors=$null
$text=[System.IO.File]::ReadAllText('<PATH>',[System.Text.Encoding]::UTF8)
[System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors) { $errors | ForEach-Object { Write-Output $_.Message }; exit 1 } else { Write-Output "Parse OK" }
'@
    $parseScript = $parseScript -replace '<PATH>', $MyInvocation.MyCommand.Path

    foreach ($target in $parseTargets) {
        if (Get-Command $target.Command -ErrorAction SilentlyContinue) {
            $output = & $target.Command -NoProfile -Command $parseScript 2>&1
            if ($LASTEXITCODE -ne 0) {
                $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="$($target.Name) parse failed"; Detail=($output -join " ") }
            }
        } else {
            $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="$($target.Name) not found"; Detail="Command '$($target.Command)' is unavailable" }
        }
    }

    $selfContent = Get-Content $MyInvocation.MyCommand.Path -Raw -ErrorAction SilentlyContinue
    if ($selfContent -and ($selfContent -match '\$\w+:\$')) {
        $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="Potential parser risk"; Detail='Found $var:$ pattern in string interpolation' }
    }

    $logDir = Join-Path $root "logs"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $logDir "testing-app-testing-$timestamp.txt"
    $report | Format-Table -AutoSize | Out-String | Set-Content -Path $logPath -Encoding UTF8

    Write-AppLog "Test-AppTesting completed with $($report.Count) findings. Report: $logPath" "Info"
    return [pscustomobject]@{
        ReportPath = $logPath
        Findings   = $report
        Count      = $report.Count
    }
}

function Get-ScriptSafetyScore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $patterns = @(
        @{ Name = "Invoke-Expression"; Regex = "\bInvoke-Expression\b|\biex\b"; Penalty = 12 },
        @{ Name = "Download and Execute"; Regex = "(Invoke-WebRequest|iwr|New-Object\s+Net.WebClient).*?(DownloadString|DownloadFile)"; Penalty = 18 },
        @{ Name = "Execution Policy Change"; Regex = "\bSet-ExecutionPolicy\b"; Penalty = 8 },
        @{ Name = "Recursive Force Delete"; Regex = "\bRemove-Item\b.*-Recurse.*-Force"; Penalty = 10 },
        @{ Name = "RunAs Elevation"; Regex = "\bStart-Process\b.*-Verb\s+RunAs"; Penalty = 8 },
        @{ Name = "Scheduled Task"; Regex = "\bRegister-ScheduledTask\b|\bschtasks\b"; Penalty = 10 },
        @{ Name = "Security Settings"; Regex = "\b(Add|Set)-MpPreference\b"; Penalty = 8 },
        @{ Name = "Service Control"; Regex = "\bStop-Service\b|\bDisable-Service\b"; Penalty = 8 },
        @{ Name = "System Power"; Regex = "\bRestart-Computer\b|\bStop-Computer\b"; Penalty = 10 },
        @{ Name = "Registry Edit"; Regex = "\breg\s+(add|delete)\b|\bNew-ItemProperty\b|\bSet-ItemProperty\b"; Penalty = 10 }
    )

    $secretPatterns = @(
        @{ Name = "password"; Regex = "(?i)password\s*[:=]"; Penalty = 20 },
        @{ Name = "apikey"; Regex = "(?i)apikey\s*[:=]"; Penalty = 20 },
        @{ Name = "api_key"; Regex = "(?i)api_key\s*[:=]"; Penalty = 20 },
        @{ Name = "secret"; Regex = "(?i)secret\s*[:=]"; Penalty = 20 },
        @{ Name = "token"; Regex = "(?i)token\s*[:=]"; Penalty = 20 },
        @{ Name = "bw_unlock_raw"; Regex = "(?i)bw\s+unlock\s+.*--raw"; Penalty = 25 },
        @{ Name = "bw_session_var"; Regex = "(?i)BW_SESSION\s*[:=]"; Penalty = 25 },
        @{ Name = "securestring_plain"; Regex = "(?i)ConvertFrom-SecureString.*-AsPlainText"; Penalty = 20 },
        @{ Name = "vault_master_pwd"; Regex = "(?i)(master|vault).*(password|pwd)\s*[:=]"; Penalty = 30 },
        @{ Name = "hardcoded_key"; Regex = "(?i)(encryption|aes|crypto).*(key|iv)\s*[:=]\s*\S\S\S\S\S\S\S\S\S\S\S\S\S\S\S\S"; Penalty = 30 }
    )

    $findings = @()
    $penalty = 0

    foreach ($p in $patterns) {
        if ($Content -match $p.Regex) {
            $findings += $p.Name
            $penalty += $p.Penalty
        }
    }

    foreach ($sp in $secretPatterns) {
        if ($Content -match $sp.Regex) {
            $findings += "Possible secret: $($sp.Name)"
            $penalty += $sp.Penalty
        }
    }

    $score = 100 - $penalty
    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    return [pscustomobject]@{
        Score    = $score
        Findings = $findings
    }
}

function Test-ScriptSafetySecOp {
    $root = (Get-Location).Path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $report = @()

    # Folders to exclude from scanning
    $scanExclude = @('.git', '.history', '~REPORTS\archive')
    $filterScan = { param($f) foreach ($ex in $scanExclude) { if ($f.FullName -like "$root\$ex\*") { return $false } }; return $true }

    $scriptFiles = @(Get-CachedScriptFiles)
    foreach ($script in $scriptFiles) {
        $content = Get-Content $script.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $scoreInfo = Get-ScriptSafetyScore -Content $content
        $score = $scoreInfo.Score
        $findings = $scoreInfo.Findings
        $report += [pscustomobject]@{ Type="Safety"; File=$script.FullName; Issue="Safety Score"; Detail=$score }
        Write-AppLog "Script safety score: $score | $($script.FullName)" "Info"

        foreach ($finding in $findings) {
            $report += [pscustomobject]@{ Type="Safety"; File=$script.FullName; Issue=$finding; Detail="Pattern matched" }
        }
    }

    $logDir = Join-Path $root "logs"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $logDir "scrutiny-safety-secops-$timestamp.txt"
    $report | Format-Table -AutoSize | Out-String | Set-Content -Path $logPath -Encoding UTF8

    Write-AppLog "Test-ScriptSafetySecOp completed with $($report.Count) findings. Report: $logPath" "Info"
    return [pscustomobject]@{
        ReportPath = $logPath
        Findings   = $report
        Count      = $report.Count
    }
}

# ==================== STARTUP SHORTCUT HELPER ====================
function Show-StartupShortcutForm {
    param([System.Windows.Forms.Form]$Owner)

    $scForm = New-Object System.Windows.Forms.Form
    $scForm.Text = "Create Startup Shortcut"
    $scForm.Size = New-Object System.Drawing.Size(500, 280)
    $scForm.StartPosition = "CenterParent"
    $scForm.FormBorderStyle = "FixedDialog"
    $scForm.MaximizeBox = $false
    $scForm.MinimizeBox = $false
    if (Get-Command Set-ModernFormStyle -ErrorAction SilentlyContinue) { Set-ModernFormStyle -Form $scForm }

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Create a shortcut to Launch-GUI that runs at Windows startup.`nSelect whose Startup folder to place it in:"
    $lblInfo.Location = New-Object System.Drawing.Point(14, 14)
    $lblInfo.Size = New-Object System.Drawing.Size(460, 42)
    $scForm.Controls.Add($lblInfo)

    $chkUser = New-Object System.Windows.Forms.CheckBox
    $chkUser.Text = "Current User Startup  ($env:USERNAME)"
    $chkUser.Location = New-Object System.Drawing.Point(30, 68)
    $chkUser.Size = New-Object System.Drawing.Size(430, 24)
    $chkUser.Checked = $true
    $scForm.Controls.Add($chkUser)

    $chkAll = New-Object System.Windows.Forms.CheckBox
    $chkAll.Text = "All Users Startup  (requires Admin)"
    $chkAll.Location = New-Object System.Drawing.Point(30, 98)
    $chkAll.Size = New-Object System.Drawing.Size(430, 24)
    $scForm.Controls.Add($chkAll)

    $chkTray = New-Object System.Windows.Forms.CheckBox
    $chkTray.Text = "Start minimized to TaskTray (/TASKTRAY)"
    $chkTray.Location = New-Object System.Drawing.Point(30, 132)
    $chkTray.Size = New-Object System.Drawing.Size(430, 24)
    $chkTray.Checked = $true
    $scForm.Controls.Add($chkTray)

    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = "Create Shortcut"
    $btnCreate.Location = New-Object System.Drawing.Point(140, 175)
    $btnCreate.Size = New-Object System.Drawing.Size(130, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnCreate }

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(280, 175)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnCancel }

    $btnCancel.Add_Click({ $scForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $scForm.Close() })

    $btnCreate.Add_Click({
        $batPath = Join-Path $scriptDir 'Launch-GUI-quik_jnr.bat'
        if (-not (Test-Path $batPath)) { $batPath = Join-Path $scriptDir 'Launch-GUI.bat' }
        $trayArg = if ($chkTray.Checked) { '/TASKTRAY' } else { '' }
        $created = @()
        $failed  = @()

        if ($chkUser.Checked) {
            $userStartup = [Environment]::GetFolderPath('Startup')
            try {
                $ws = New-Object -ComObject WScript.Shell
                $sc = $ws.CreateShortcut((Join-Path $userStartup 'PowerShellGUI.lnk'))
                $sc.TargetPath = $batPath
                $sc.Arguments = $trayArg
                $sc.WorkingDirectory = $scriptDir
                $sc.Description = "PowerShellGUI Launcher"
                $sc.WindowStyle = 7  # minimized
                $sc.Save()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
                $created += "User Startup: $userStartup"
                Write-AppLog "Startup shortcut created in user startup: $userStartup" "Info"
            } catch {
                $failed += "User Startup: $_"
                Write-AppLog "Failed to create user startup shortcut: $_" "Error"
            }
        }

        if ($chkAll.Checked) {
            $allStartup = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
            try {
                $ws = New-Object -ComObject WScript.Shell
                $sc = $ws.CreateShortcut((Join-Path $allStartup 'PowerShellGUI.lnk'))
                $sc.TargetPath = $batPath
                $sc.Arguments = $trayArg
                $sc.WorkingDirectory = $scriptDir
                $sc.Description = "PowerShellGUI Launcher"
                $sc.WindowStyle = 7
                $sc.Save()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
                $created += "All Users Startup: $allStartup"
                Write-AppLog "Startup shortcut created in all-users startup: $allStartup" "Info"
            } catch {
                $failed += "All Users Startup: $_"
                Write-AppLog "Failed to create all-users startup shortcut: $_" "Error"
            }
        }

        $msg = ""
        if ($created.Count -gt 0) { $msg += "Created:`n" + ($created -join "`n") + "`n`n" }
        if ($failed.Count -gt 0) { $msg += "Failed:`n" + ($failed -join "`n") }
        if ($created.Count -eq 0 -and $failed.Count -eq 0) { $msg = "No startup folder selected." }

        [System.Windows.Forms.MessageBox]::Show($msg, "Startup Shortcut", "OK",
            $(if ($failed.Count -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }))
        if ($failed.Count -eq 0 -and $created.Count -gt 0) { $scForm.DialogResult = [System.Windows.Forms.DialogResult]::OK; $scForm.Close() }
    })

    $scForm.Controls.Add($btnCreate)
    $scForm.Controls.Add($btnCancel)
    $scForm.AcceptButton = $btnCreate
    $scForm.CancelButton = $btnCancel
    $scForm.ShowDialog($Owner) | Out-Null
    $scForm.Dispose()
}

# ==================== REMOTE BUILD PATH CONFIG ====================
function Show-RemoteBuildConfigForm {
    param([System.Windows.Forms.Form]$Owner)

    $rbForm = New-Object System.Windows.Forms.Form
    $rbForm.Text = "Remote Build Path Configuration"
    $rbForm.Size = New-Object System.Drawing.Size(720, 620)
    $rbForm.StartPosition = "CenterParent"
    $rbForm.FormBorderStyle = "FixedDialog"
    $rbForm.MaximizeBox = $false
    if (Get-Command Set-ModernFormStyle -ErrorAction SilentlyContinue) { Set-ModernFormStyle -Form $rbForm }

    $resultsBox = New-Object System.Windows.Forms.RichTextBox
    $resultsBox.Location = New-Object System.Drawing.Point(12, 310)
    $resultsBox.Size = New-Object System.Drawing.Size(680, 230)
    $resultsBox.ReadOnly = $true
    $resultsBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $resultsBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $resultsBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $rbForm.Controls.Add($resultsBox)

    # helper to append colored text
    $appendResult = {
        param([string]$Text, [System.Drawing.Color]$Color)
        $resultsBox.SelectionStart = $resultsBox.TextLength
        $resultsBox.SelectionLength = 0
        $resultsBox.SelectionColor = $Color
        $resultsBox.AppendText($Text + "`r`n")
        $resultsBox.ScrollToCaret()
    }

    # Remote path label + textbox
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Remote Build Path (RemoteUpdatePath):"
    $lblPath.Location = New-Object System.Drawing.Point(12, 14)
    $lblPath.Size = New-Object System.Drawing.Size(280, 20)
    $rbForm.Controls.Add($lblPath)

    $txtRemotePath = New-Object System.Windows.Forms.TextBox
    $txtRemotePath.Location = New-Object System.Drawing.Point(12, 36)
    $txtRemotePath.Size = New-Object System.Drawing.Size(600, 22)
    $cfgRemote = try { [string](Get-ConfigSubValue "RemoteUpdatePath") } catch { "" }
    $txtRemotePath.Text = if ($cfgRemote) { $cfgRemote } else { "" }
    $rbForm.Controls.Add($txtRemotePath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "..."
    $btnBrowse.Location = New-Object System.Drawing.Point(618, 34)
    $btnBrowse.Size = New-Object System.Drawing.Size(60, 26)
    $btnBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Select Remote Build Path"
        if (-not [string]::IsNullOrWhiteSpace($txtRemotePath.Text)) { $fb.SelectedPath = $txtRemotePath.Text }
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtRemotePath.Text = $fb.SelectedPath }
        $fb.Dispose()
    })
    $rbForm.Controls.Add($btnBrowse)

    # ── Check Remote Path button ──
    $btnCheck = New-Object System.Windows.Forms.Button
    $btnCheck.Text = "Check Remote Path"
    $btnCheck.Location = New-Object System.Drawing.Point(12, 70)
    $btnCheck.Size = New-Object System.Drawing.Size(160, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnCheck }
    $btnCheck.Add_Click({
        $resultsBox.Clear()
        $rp = $txtRemotePath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rp)) {
            & $appendResult "ERROR: No remote path specified." ([System.Drawing.Color]::OrangeRed)
            return
        }
        & $appendResult "=== Checking Remote Path ===" ([System.Drawing.Color]::Cyan)
        & $appendResult "Path: $rp" ([System.Drawing.Color]::White)

        # Exists?
        if (-not (Test-Path $rp)) {
            & $appendResult "[FAIL] Path does NOT exist." ([System.Drawing.Color]::OrangeRed)
            return
        }
        & $appendResult "[OK] Path exists." ([System.Drawing.Color]::LimeGreen)

        # Readable?
        try {
            $null = Get-ChildItem -Path $rp -ErrorAction Stop | Select-Object -First 1
            & $appendResult "[OK] Path is readable." ([System.Drawing.Color]::LimeGreen)
        } catch {
            & $appendResult "[FAIL] Path is NOT readable: $_" ([System.Drawing.Color]::OrangeRed)
        }

        # Writable?
        $testFile = Join-Path $rp ".pwshgui-write-test-$(Get-Random)"
        try {
            [System.IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            & $appendResult "[OK] Path is writable." ([System.Drawing.Color]::LimeGreen)
        } catch {
            & $appendResult "[FAIL] Path is NOT writable: $_" ([System.Drawing.Color]::OrangeRed)
        }

        # Build version / manifest?
        $buildDir = Join-Path $rp "~BUILD-ZIPS"
        if (Test-Path $buildDir) {
            & $appendResult "`n=== Build Directory: ~BUILD-ZIPS ===" ([System.Drawing.Color]::Cyan)
            $zips = Get-ChildItem -Path $buildDir -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($zips.Count -gt 0) {
                & $appendResult "Found $($zips.Count) zip package(s):" ([System.Drawing.Color]::White)
                foreach ($z in $zips | Select-Object -First 10) {
                    $sizeKB = [math]::Round($z.Length / 1KB, 1)
                    & $appendResult "  $($z.Name)  ($sizeKB KB)  $($z.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" ([System.Drawing.Color]::LightGray)
                }
            } else {
                & $appendResult "No zip packages found in ~BUILD-ZIPS." ([System.Drawing.Color]::Yellow)
            }

            # Check for manifest
            $manifests = Get-ChildItem -Path $buildDir -Filter "*.xml" -ErrorAction SilentlyContinue
            if ($manifests.Count -gt 0) {
                & $appendResult "Build manifest(s) found:" ([System.Drawing.Color]::White)
                foreach ($m in $manifests) { & $appendResult "  $($m.Name)" ([System.Drawing.Color]::LightGray) }
            } else {
                & $appendResult "No build manifest XML found. Zip packages may be used for expansion." ([System.Drawing.Color]::Yellow)
            }
        } else {
            & $appendResult "`n~BUILD-ZIPS directory not found at remote path." ([System.Drawing.Color]::Yellow)
            & $appendResult "Scanning for any zip packages in root of remote path..." ([System.Drawing.Color]::White)
            $rootZips = Get-ChildItem -Path $rp -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($rootZips.Count -gt 0) {
                & $appendResult "Found $($rootZips.Count) zip(s) for potential expansion:" ([System.Drawing.Color]::White)
                foreach ($z in $rootZips | Select-Object -First 10) {
                    $sizeKB = [math]::Round($z.Length / 1KB, 1)
                    $verMatch = if ($z.Name -match 'v[- ]?(\d+\.\w+\.\w+)') { $Matches[1] } else { "unknown" }
                    & $appendResult "  $($z.Name)  ($sizeKB KB)  ver: $verMatch  $($z.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" ([System.Drawing.Color]::LightGray)
                }
            } else {
                & $appendResult "No zip packages found at remote path." ([System.Drawing.Color]::Yellow)
            }
        }
        Write-AppLog "Remote build path check completed for: $rp" "Info"
    })
    $rbForm.Controls.Add($btnCheck)

    # ── Build Zip & Upload button ──
    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = "Build Zip && Upload"
    $btnBuild.Location = New-Object System.Drawing.Point(12, 110)
    $btnBuild.Size = New-Object System.Drawing.Size(160, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnBuild }
    $btnBuild.Add_Click({
        $resultsBox.Clear()
        $rp = $txtRemotePath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rp)) {
            & $appendResult "ERROR: No remote path specified." ([System.Drawing.Color]::OrangeRed)
            return
        }
        if (-not (Test-Path $rp)) {
            & $appendResult "ERROR: Remote path does not exist: $rp" ([System.Drawing.Color]::OrangeRed)
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will build a zip package from the current workspace and upload to:`n$rp\~BUILD-ZIPS`n`nProceed?",
            "Build & Upload", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        & $appendResult "=== Building Zip Package ===" ([System.Drawing.Color]::Cyan)
        try {
            $opts = @{ CopyZipToRemote = $true; RemoteUpdatePath = $rp }
            Export-WorkspacePackage -Options $opts
            & $appendResult "[OK] Zip package built and uploaded to remote path." ([System.Drawing.Color]::LimeGreen)
            # Show what was uploaded
            $buildDir = Join-Path $rp "~BUILD-ZIPS"
            if (Test-Path $buildDir) {
                $latest = Get-ChildItem -Path $buildDir -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { & $appendResult "Uploaded: $($latest.Name)  ($([math]::Round($latest.Length / 1KB, 1)) KB)" ([System.Drawing.Color]::White) }
            }
            Write-AppLog "Build zip uploaded to $rp" "Info"
        } catch {
            & $appendResult "[FAIL] Build/upload error: $_" ([System.Drawing.Color]::OrangeRed)
            Write-AppLog "Build zip upload failed: $_" "Error"
        }
    })
    $rbForm.Controls.Add($btnBuild)

    # ── TEST (WhatIf) Remote Path Build Zip ──
    $btnTestBuild = New-Object System.Windows.Forms.Button
    $btnTestBuild.Text = "TEST Build Zip (WhatIf)"
    $btnTestBuild.Location = New-Object System.Drawing.Point(185, 110)
    $btnTestBuild.Size = New-Object System.Drawing.Size(180, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnTestBuild }
    $btnTestBuild.Add_Click({
        $resultsBox.Clear()
        $rp = $txtRemotePath.Text.Trim()
        & $appendResult "=== TEST (WhatIf): Build Zip Package ===" ([System.Drawing.Color]::Yellow)
        & $appendResult "Mode: SIMULATION -- no files will be created or copied" ([System.Drawing.Color]::Yellow)
        & $appendResult "" ([System.Drawing.Color]::White)

        $versionString = Get-VersionString
        $zipName = "pwshGUI-v-$versionString.zip"
        & $appendResult "Version     : $versionString" ([System.Drawing.Color]::White)
        & $appendResult "Package name: $zipName" ([System.Drawing.Color]::White)
        & $appendResult "Source      : $scriptDir" ([System.Drawing.Color]::White)
        & $appendResult "Local dest  : $DownloadFolder\$zipName" ([System.Drawing.Color]::White)

        # Calculate what would be packaged
        $packageExcludeFolders = @(Get-ConfigList "Do-Not-VersionTag-FoldersFiles") + '.git'
        $packageItems = Get-ChildItem -Path $scriptDir -Force | Where-Object { $packageExcludeFolders -notcontains $_.Name }
        & $appendResult "`nItems to package ($($packageItems.Count)):" ([System.Drawing.Color]::Cyan)
        foreach ($item in $packageItems) {
            $sizeStr = if ($item.PSIsContainer) { "[DIR]" } else { "$([math]::Round($item.Length / 1KB, 1)) KB" }
            & $appendResult "  $($item.Name)  $sizeStr" ([System.Drawing.Color]::LightGray)
        }

        if ([string]::IsNullOrWhiteSpace($rp)) {
            & $appendResult "`n[SKIP] No remote path -- upload step would be skipped." ([System.Drawing.Color]::Yellow)
        } else {
            $remoteBuild = Join-Path $rp "~BUILD-ZIPS"
            & $appendResult "`nRemote dest : $remoteBuild\$zipName" ([System.Drawing.Color]::White)
            if (Test-Path $rp) {
                & $appendResult "[OK] Remote path exists." ([System.Drawing.Color]::LimeGreen)
            } else {
                & $appendResult "[WARN] Remote path does NOT exist -- upload would fail." ([System.Drawing.Color]::OrangeRed)
            }
        }
        & $appendResult "`n=== WhatIf complete -- no changes made ===" ([System.Drawing.Color]::Yellow)
        Write-AppLog "WhatIf build zip test completed" "Info"
    })
    $rbForm.Controls.Add($btnTestBuild)

    # ── TEST (WhatIf) Build Remote Copy From Current Version ──
    $btnTestCopy = New-Object System.Windows.Forms.Button
    $btnTestCopy.Text = "TEST Remote Copy (WhatIf)"
    $btnTestCopy.Location = New-Object System.Drawing.Point(378, 110)
    $btnTestCopy.Size = New-Object System.Drawing.Size(195, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnTestCopy }
    $btnTestCopy.Add_Click({
        $resultsBox.Clear()
        $rp = $txtRemotePath.Text.Trim()
        & $appendResult "=== TEST (WhatIf): Build Remote Copy from Current Version ===" ([System.Drawing.Color]::Yellow)
        & $appendResult "Mode: SIMULATION -- zip, upload, verify readback" ([System.Drawing.Color]::Yellow)
        & $appendResult "" ([System.Drawing.Color]::White)

        $versionString = Get-VersionString
        $zipName = "pwshGUI-v-$versionString.zip"
        $tempDir = if (-not [string]::IsNullOrWhiteSpace($TempFolder) -and (Test-Path $TempFolder)) { $TempFolder } else { "C:\temp" }

        & $appendResult "Step 1: CREATE zip package" ([System.Drawing.Color]::Cyan)
        & $appendResult "  Source     : $scriptDir" ([System.Drawing.Color]::White)
        & $appendResult "  Zip name   : $zipName" ([System.Drawing.Color]::White)
        & $appendResult "  Local path : $DownloadFolder\$zipName" ([System.Drawing.Color]::White)

        # Simulate package size
        $packageExcludeFolders = @(Get-ConfigList "Do-Not-VersionTag-FoldersFiles") + '.git'
        $packageItems = Get-ChildItem -Path $scriptDir -Force | Where-Object { $packageExcludeFolders -notcontains $_.Name }
        $totalBytes = ($packageItems | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
        & $appendResult "  Estimated size: $([math]::Round($totalBytes / 1MB, 2)) MB (uncompressed)" ([System.Drawing.Color]::LightGray)
        & $appendResult "  [SIMULATED] Zip created OK" ([System.Drawing.Color]::LimeGreen)

        & $appendResult "`nStep 2: UPLOAD to remote path" ([System.Drawing.Color]::Cyan)
        if ([string]::IsNullOrWhiteSpace($rp)) {
            & $appendResult "  [SKIP] No remote path configured." ([System.Drawing.Color]::OrangeRed)
        } else {
            $remoteBuild = Join-Path $rp "~BUILD-ZIPS"
            & $appendResult "  Destination: $remoteBuild\$zipName" ([System.Drawing.Color]::White)
            if (Test-Path $rp) {
                & $appendResult "  [OK] Remote path accessible." ([System.Drawing.Color]::LimeGreen)
                & $appendResult "  [SIMULATED] Upload OK" ([System.Drawing.Color]::LimeGreen)
            } else {
                & $appendResult "  [FAIL] Remote path not accessible." ([System.Drawing.Color]::OrangeRed)
            }
        }

        & $appendResult "`nStep 3: VERIFY readback by extracting to temp" ([System.Drawing.Color]::Cyan)
        & $appendResult "  Temp extraction dir: $tempDir" ([System.Drawing.Color]::White)
        if (Test-Path $tempDir) {
            & $appendResult "  [OK] Temp directory exists." ([System.Drawing.Color]::LimeGreen)
        } else {
            & $appendResult "  [INFO] Temp directory does not exist. Would be created." ([System.Drawing.Color]::Yellow)
        }
        $extractTarget = Join-Path $tempDir "pwshGUI-verify-$versionString"
        & $appendResult "  Extract to: $extractTarget" ([System.Drawing.Color]::White)
        & $appendResult "  [SIMULATED] Extraction OK -- $($packageItems.Count) items verified" ([System.Drawing.Color]::LimeGreen)

        & $appendResult "`n=== WhatIf complete -- no changes made ===" ([System.Drawing.Color]::Yellow)
        Write-AppLog "WhatIf remote copy test completed" "Info"
    })
    $rbForm.Controls.Add($btnTestCopy)

    # ── Temp folder label ──
    $lblTemp = New-Object System.Windows.Forms.Label
    $lblTemp.Text = "Temp folder for verify extraction:"
    $lblTemp.Location = New-Object System.Drawing.Point(12, 155)
    $lblTemp.Size = New-Object System.Drawing.Size(230, 20)
    $rbForm.Controls.Add($lblTemp)

    $txtTemp = New-Object System.Windows.Forms.TextBox
    $txtTemp.Location = New-Object System.Drawing.Point(246, 153)
    $txtTemp.Size = New-Object System.Drawing.Size(366, 22)
    $txtTemp.Text = if ($TempFolder -and (Test-Path $TempFolder)) { $TempFolder } else { "C:\temp" }
    $rbForm.Controls.Add($txtTemp)

    # ── Save Remote Path button ──
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Remote Path to Config"
    $btnSave.Location = New-Object System.Drawing.Point(12, 190)
    $btnSave.Size = New-Object System.Drawing.Size(200, 32)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnSave }
    $btnSave.Add_Click({
        $val = $txtRemotePath.Text.Trim()
        try {
            Set-ConfigSubValue -XPath "RemoteUpdatePath" -Value $val
            Set-Variable -Name 'RemoteUpdatePath' -Value $val -Scope Script -ErrorAction SilentlyContinue
            & $appendResult "Remote path saved to config: $val" ([System.Drawing.Color]::LimeGreen)
            Write-AppLog "Remote build path saved: $val" "Info"
        } catch {
            & $appendResult "Failed to save: $_" ([System.Drawing.Color]::OrangeRed)
        }
    })
    $rbForm.Controls.Add($btnSave)

    # ── Close button ──
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(600, 550)
    $btnClose.Size = New-Object System.Drawing.Size(90, 28)
    if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) { Set-ModernButtonStyle -Button $btnClose }
    $btnClose.Add_Click({ $rbForm.Close() })
    $rbForm.Controls.Add($btnClose)
    $rbForm.CancelButton = $btnClose

    # ── Results header ──
    $lblResults = New-Object System.Windows.Forms.Label
    $lblResults.Text = "Results:"
    $lblResults.Location = New-Object System.Drawing.Point(12, 290)
    $lblResults.Size = New-Object System.Drawing.Size(200, 18)
    $rbForm.Controls.Add($lblResults)

    $rbForm.ShowDialog($Owner) | Out-Null
    $rbForm.Dispose()
}

# ==================== ABOUT / SYSTEM / APP ANALYTICS FUNCTIONS ====================

function New-QrFingerprintBitmap {
    [CmdletBinding()]
    param(
        [string]$Text,
        [int]$Size = 200
    )
    # Build a deterministic visual fingerprint bitmap from the SHA256 of Text.
    # Uses a 16x16 half-symmetric block grid (like identicons) rendered into a Bitmap.
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        $sha.Dispose()

        $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb(20, 20, 30))

        $cols = 8; $rows = 8  # SIN-EXEMPT: P021 — hardcoded non-zero constants
        $cellW = [int]($Size / $cols); $cellH = [int]($Size / $rows)  # SIN-EXEMPT: P021 — $cols/$rows always=8

        # Foreground colour derived from first 3 bytes
        $fc = [System.Drawing.Color]::FromArgb(255, [int]$bytes[0], [math]::Max(80,[int]$bytes[1]), [math]::Max(80,[int]$bytes[2]))  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
        $br = New-Object System.Drawing.SolidBrush($fc)
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 20, 30))

        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt ($cols / 2); $c++) {
                $byteIdx = ($r * 4 + $c) % $bytes.Count
                $filled  = ($bytes[$byteIdx] -band (1 -shl ($c % 8))) -ne 0
                $brush   = if ($filled) { $br } else { $bg }
                $x1 = $c * $cellW
                $x2 = ($cols - 1 - $c) * $cellW
                $y  = $r * $cellH
                $g.FillRectangle($brush, $x1, $y, $cellW - 1, $cellH - 1)
                $g.FillRectangle($brush, $x2, $y, $cellW - 1, $cellH - 1)
            }
        }
        # Border
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 220, 180), 2)
        $g.DrawRectangle($pen, 1, 1, $Size - 3, $Size - 3)
        $pen.Dispose(); $br.Dispose(); $bg.Dispose(); $g.Dispose()
        return $bmp
    } catch {
        Write-AppLog "New-QrFingerprintBitmap error: $_" "Warning"
        return $null
    }
}

function Get-ManifestMismatches {
    <#.SYNOPSIS Returns files in workspace missing from manifest, and manifest entries with no matching file.#>
    [CmdletBinding()]
    param([string]$WorkspacePath = $PSScriptRoot)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $manifestPath = Join-Path $WorkspacePath 'config\agentic-manifest.json'
    if (-not (Test-Path $manifestPath)) {
        $results.Add([PSCustomObject]@{ File='(manifest not found)'; Status='Error'; Note=$manifestPath })
        return $results
    }
    try {
        $m       = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # Collect all paths referenced in manifest
        foreach ($sec in @('scripts','modules','tests','configs','xhtmlTools','styles')) {
            $items = $m.$sec
            if ($null -eq $items) { continue }
            foreach ($item in $items) {
                $p = $item.path
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                $abs = Join-Path $WorkspacePath ($p -replace '/','\\')
                $null = $tracked.Add($abs)
                if (-not (Test-Path $abs)) {
                    $results.Add([PSCustomObject]@{ File=(Split-Path $abs -Leaf); Status='Relic'; Note="In manifest, not on disk: $p" })
                }
            }
        }
        # Scan actual workspace files
        $excludeDirs = @('~DOWNLOADS','-REPORTS','temp','.git','.history','logs','~REPORTS','node_modules','vault-backups')
        $allFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $parts = $_.FullName -split '\\|/'
                $skip  = $false
                foreach ($ex in $excludeDirs) { if ($parts -contains $ex) { $skip = $true; break } }
                -not $skip -and $_.Extension -in @('.ps1','.psm1','.psd1','.bat','.json','.xml','.xhtml','.html','.css','.js')
            }
        foreach ($f in $allFiles) {
            if (-not $tracked.Contains($f.FullName)) {
                $rel = $f.FullName.Replace($WorkspacePath, '').TrimStart('\/')
                $results.Add([PSCustomObject]@{ File=$f.Name; Status='Untracked'; Note="Not in manifest: $rel" })
            }
        }
    } catch {
        $results.Add([PSCustomObject]@{ File='(error)'; Status='Error'; Note="$_" })
    }
    return $results
}

function Get-ChiefApprovals {
    [CmdletBinding()]
    param([string]$WorkspacePath = $PSScriptRoot)
    $path = Join-Path $WorkspacePath 'config\chief-approvals.json'
    if (-not (Test-Path $path)) {
        return @{ approvals = @(); bypassExpiry = $null; version = '2604.B2.V31.0' }
    }
    try { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return @{ approvals = @(); bypassExpiry = $null; version = '2604.B2.V31.0' } }
}

function Save-ChiefApprovals {
    [CmdletBinding()]
    param([object]$Data, [string]$WorkspacePath = $PSScriptRoot)
    $path = Join-Path $WorkspacePath 'config\chief-approvals.json'
    try {
        $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
        Write-AppLog "Chief approvals saved to $path" "Audit"
    } catch { Write-AppLog "Save-ChiefApprovals error: $_" "Error" }
}

function Show-ModernAboutScreen {
    <#.SYNOPSIS Full-featured tabbed About screen with Public Keys, Audit and Approvals.#>
    [CmdletBinding()]
    param([switch]$AuditMode)

    Write-AppLog "Showing Modern About Screen (AuditMode=$AuditMode)" "Audit"

    # ── Load assemblies ─────────────────────────────────────────────
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue

    $DARK_BG   = [System.Drawing.Color]::FromArgb(18, 18, 28)
    $PANEL_BG  = [System.Drawing.Color]::FromArgb(28, 28, 45)
    $ACCENT    = [System.Drawing.Color]::FromArgb(0, 220, 180)
    $ACCENT2   = [System.Drawing.Color]::FromArgb(130, 80, 255)
    $FG        = [System.Drawing.Color]::FromArgb(220, 220, 230)
    $FG_DIM    = [System.Drawing.Color]::FromArgb(140, 140, 160)
    $FG_DANGER = [System.Drawing.Color]::FromArgb(255, 80, 80)
    $FG_OK     = [System.Drawing.Color]::FromArgb(80, 255, 130)
    $FG_WARN   = [System.Drawing.Color]::FromArgb(255, 200, 50)

    $aboutForm = New-Object System.Windows.Forms.Form
    $aboutForm.Text          = "About  ·  PowerShellGUI"
    $aboutForm.Size          = New-Object System.Drawing.Size(900, 700)
    $aboutForm.StartPosition = "CenterScreen"
    $aboutForm.BackColor     = $DARK_BG
    $aboutForm.ForeColor     = $FG
    $aboutForm.Font          = New-Object System.Drawing.Font("Segoe UI", 10)
    $aboutForm.MinimumSize   = New-Object System.Drawing.Size(800, 560)

    # ── Rainbow header strip ────────────────────────────────────────
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock      = [System.Windows.Forms.DockStyle]::Top
    $header.Height    = 80
    $header.BackColor = $PANEL_BG
    $aboutForm.Controls.Add($header)

    $headerTitle = New-Object System.Windows.Forms.Label
    $headerTitle.Text      = "⚡  PowerShellGUI  ·  Scriptz Launchr"
    $headerTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $headerTitle.ForeColor = $ACCENT
    $headerTitle.Location  = New-Object System.Drawing.Point(16, 10)
    $headerTitle.Size      = New-Object System.Drawing.Size(680, 30)
    $header.Controls.Add($headerTitle)

    $vi = Get-VersionInfo
    $vStr = "2604.B2.V31.0"
    try { $vStr = "$($vi.Major).$($vi.Minor).V$($vi.Build)" } catch { <# Intentional: non-fatal, fallback version string already set above #> }
    $headerSub = New-Object System.Windows.Forms.Label
    $headerSub.Text      = "Version $vStr  ·  PS $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)  ·  $env:COMPUTERNAME  ·  $env:USERNAME"
    $headerSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $headerSub.ForeColor = $FG_DIM
    $headerSub.Location  = New-Object System.Drawing.Point(17, 44)
    $headerSub.Size      = New-Object System.Drawing.Size(750, 20)
    $header.Controls.Add($headerSub)

    # Colour band at top of header
    $band = New-Object System.Windows.Forms.Panel
    $band.Dock      = [System.Windows.Forms.DockStyle]::Top
    $band.Height    = 4
    $band.BackColor = $ACCENT
    $header.Controls.Add($band)

    # ── Tab control ─────────────────────────────────────────────────
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $tabs.BackColor = $DARK_BG
    $tabs.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $aboutForm.Controls.Add($tabs)

    function New-AboutTab {
        param([string]$Title, [string]$Symbol)
        $tp = New-Object System.Windows.Forms.TabPage
        $tp.Text      = "$Symbol  $Title"
        $tp.BackColor = $PANEL_BG
        $tp.ForeColor = $FG
        $tabs.TabPages.Add($tp) | Out-Null
        return $tp
    }

    # ════════════════════════════════════════════════════════════════
    # TAB 1 ─ App Info
    # ════════════════════════════════════════════════════════════════
    $tabInfo = New-AboutTab "App Info" "🔷"
    $tabInfo.Padding = New-Object System.Windows.Forms.Padding(10)

    $infoSplit = New-Object System.Windows.Forms.SplitContainer
    $infoSplit.Dock             = [System.Windows.Forms.DockStyle]::Fill
    $infoSplit.Orientation      = [System.Windows.Forms.Orientation]::Vertical
    $infoSplit.SplitterDistance = 420
    $tabInfo.Controls.Add($infoSplit)

    # Left: info grid
    $infoGrid = New-Object System.Windows.Forms.DataGridView
    $infoGrid.Dock                          = [System.Windows.Forms.DockStyle]::Fill
    $infoGrid.ReadOnly                      = $true
    $infoGrid.AllowUserToAddRows            = $false
    $infoGrid.RowHeadersVisible             = $false
    $infoGrid.SelectionMode                 = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $infoGrid.BackgroundColor               = $PANEL_BG
    $infoGrid.ForeColor                     = $FG
    $infoGrid.GridColor                     = [System.Drawing.Color]::FromArgb(50, 50, 70)
    $infoGrid.DefaultCellStyle.BackColor    = $PANEL_BG
    $infoGrid.DefaultCellStyle.ForeColor    = $FG
    $infoGrid.DefaultCellStyle.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $infoGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(22, 22, 38)
    $infoGrid.ColumnHeadersDefaultCellStyle.BackColor   = [System.Drawing.Color]::FromArgb(10, 10, 20)
    $infoGrid.ColumnHeadersDefaultCellStyle.ForeColor   = $ACCENT
    $infoGrid.EnableHeadersVisualStyles     = $false
    $infoGrid.Font                          = New-Object System.Drawing.Font("Consolas", 9)
    $infoGrid.Columns.Add("Field", "Field") | Out-Null
    $infoGrid.Columns.Add("Value", "Value") | Out-Null
    $infoGrid.Columns[0].Width = 180  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
    $infoGrid.Columns[1].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $infoSplit.Panel1.Controls.Add($infoGrid)

    # Populate info fields
    $cfgVersion = "unknown"
    $cfgAuthor  = "The Establishment"
    $cfgDesc    = "PowerShell GUI Application with Admin Elevation Support"
    $scriptTag  = "unknown"
    $cfgCreated = ""; $cfgModified = ""
    try {
        $bcfg        = Get-Content (Join-Path $PSScriptRoot 'config\pwsh-app-config-BASE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgVersion  = $bcfg.metadata.versionTag
        $cfgAuthor   = $bcfg.metadata.author
        $cfgDesc     = $bcfg.metadata.description
        $cfgCreated  = $bcfg.metadata.created
        $cfgModified = $bcfg.metadata.modified
    } catch { <# Intentional: non-fatal #> }
    try {
        $fl = Get-Content -LiteralPath $PSCommandPath -TotalCount 5 -ErrorAction Stop
        $tl = $fl | Where-Object { $_ -match 'VersionTag:\s*([\S]+)' } | Select-Object -First 1
        if ($tl -match 'VersionTag:\s*([\S]+)') { $scriptTag = $Matches[1] }
    } catch { <# Intentional: non-fatal #> }

    $loadedMods  = @(Get-Module | Where-Object { $_.Name -like 'PwSh*' -or $_.Name -like 'CronAi*' -or $_.Name -like 'AVPN*' -or $_.Name -like 'UserProfile*' -or $_.Name -like 'AssistedSASC*' }).Count
    $uptime      = (Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
    $uptimeStr   = "$([int]$uptime.TotalDays)d $($uptime.Hours)h $($uptime.Minutes)m"
    $ram         = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 1)

    $infoRows = @(
        @('── Version Information ──',''),
        @('Script VersionTag',     $scriptTag),
        @('Config VersionTag',     $cfgVersion),
        @('Config Version',        "$($vi.Major).$($vi.Minor).V$($vi.Build)"),
        @('PowerShell Version',    "$($PSVersionTable.PSVersion)"),
        @('PS Edition',            $PSVersionTable.PSEdition),
        @('── Environment ──',''),
        @('Computer',              $env:COMPUTERNAME),
        @('User',                  "$env:USERDOMAIN\$env:USERNAME"),
        @('OS',                    (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption),
        @('System Uptime',         $uptimeStr),
        @('RAM (Total)',           "${ram} GB"),
        @('Workspace Root',        $PSScriptRoot),
        @('── Application ──',''),
        @('App Name',              'PowerShellGUI · Scriptz Launchr'),
        @('Author',                $cfgAuthor),
        @('Description',           ($cfgDesc -replace '.{60}','$0`n')),
        @('Created',               $cfgCreated),
        @('Last Modified',         $cfgModified),
        @('Loaded Modules',        $loadedMods),
        @('── Runtime ──',''),
        @('Script Root',           $PSScriptRoot),
        @('Current Path',          (Get-Location).Path),
        @('Session ID',            $PID),
        @('Culture',               [System.Threading.Thread]::CurrentThread.CurrentUICulture.Name)
    )
    foreach ($row in $infoRows) {
        $r  = $infoGrid.Rows.Add($row[0], $row[1])  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
        $ri = $infoGrid.Rows[$r]
        if ($row[0] -match '^──') {  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
            $ri.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
            $ri.DefaultCellStyle.ForeColor = $ACCENT2
            $ri.DefaultCellStyle.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        }
    }

    # Right: modules list
    $modPanel = New-Object System.Windows.Forms.Panel
    $modPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoSplit.Panel2.Controls.Add($modPanel)

    $modLabel = New-Object System.Windows.Forms.Label
    $modLabel.Text      = "Loaded Modules"
    $modLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $modLabel.ForeColor = $ACCENT
    $modLabel.Dock      = [System.Windows.Forms.DockStyle]::Top
    $modLabel.Height    = 24
    $modPanel.Controls.Add($modLabel)

    $modList = New-Object System.Windows.Forms.ListBox
    $modList.Dock            = [System.Windows.Forms.DockStyle]::Fill
    $modList.BackColor       = $PANEL_BG
    $modList.ForeColor       = $FG
    $modList.Font            = New-Object System.Drawing.Font("Consolas", 8)
    $modList.BorderStyle     = [System.Windows.Forms.BorderStyle]::FixedSingle
    $modPanel.Controls.Add($modList)
    Get-Module | Sort-Object Name | ForEach-Object { $null = $modList.Items.Add("$($_.Name) v$($_.Version)") }

    # ════════════════════════════════════════════════════════════════
    # TAB 2 ─ Public Keys / Integrity
    # ════════════════════════════════════════════════════════════════
    $tabKeys = New-AboutTab "Public Keys" "🔑"

    $keySplit = New-Object System.Windows.Forms.SplitContainer
    $keySplit.Dock             = [System.Windows.Forms.DockStyle]::Fill
    $keySplit.Orientation      = [System.Windows.Forms.Orientation]::Vertical
    $keySplit.SplitterDistance = 240
    $tabKeys.Controls.Add($keySplit)

    # Left pane: key selector + visual fingerprint
    $keyLeft = New-Object System.Windows.Forms.Panel
    $keyLeft.Dock = [System.Windows.Forms.DockStyle]::Fill
    $keySplit.Panel1.Controls.Add($keyLeft)

    $keyDropLabel = New-Object System.Windows.Forms.Label
    $keyDropLabel.Text      = "Select PKI Key:"
    $keyDropLabel.ForeColor = $ACCENT
    $keyDropLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $keyDropLabel.Location  = New-Object System.Drawing.Point(6, 8)
    $keyDropLabel.Size      = New-Object System.Drawing.Size(200, 20)
    $keyLeft.Controls.Add($keyDropLabel)

    $keyDrop = New-Object System.Windows.Forms.ComboBox
    $keyDrop.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $keyDrop.BackColor     = $PANEL_BG
    $keyDrop.ForeColor     = $FG
    $keyDrop.Font          = New-Object System.Drawing.Font("Consolas", 9)
    $keyDrop.Location      = New-Object System.Drawing.Point(6, 30)
    $keyDrop.Size          = New-Object System.Drawing.Size(220, 24)
    $keyLeft.Controls.Add($keyDrop)

    # Load public keys
    $pkiDir  = Join-Path $PSScriptRoot 'pki'
    $pubKeys = @(Get-ChildItem $pkiDir -Filter '*.pub' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($pk in $pubKeys) { $null = $keyDrop.Items.Add($pk.BaseName) }
    if (@($keyDrop.Items).Count -gt 0) { $keyDrop.SelectedIndex = 0 }

    $fingerLabel = New-Object System.Windows.Forms.Label
    $fingerLabel.Text      = "Visual Fingerprint:"
    $fingerLabel.ForeColor = $FG_DIM
    $fingerLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $fingerLabel.Location  = New-Object System.Drawing.Point(6, 64)
    $fingerLabel.Size      = New-Object System.Drawing.Size(200, 18)
    $keyLeft.Controls.Add($fingerLabel)

    $picBox = New-Object System.Windows.Forms.PictureBox
    $picBox.Location  = New-Object System.Drawing.Point(6, 84)
    $picBox.Size      = New-Object System.Drawing.Size(200, 200)
    $picBox.BackColor = $DARK_BG
    $picBox.SizeMode  = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
    $keyLeft.Controls.Add($picBox)

    $qrNote = New-Object System.Windows.Forms.Label
    $qrNote.Text      = "Identicon fingerprint (install QRCoder for scannable QR)"
    $qrNote.ForeColor = $FG_DIM
    $qrNote.Font      = New-Object System.Drawing.Font("Segoe UI", 7)
    $qrNote.Location  = New-Object System.Drawing.Point(6, 290)
    $qrNote.Size      = New-Object System.Drawing.Size(228, 28)
    $keyLeft.Controls.Add($qrNote)

    # Right pane: fingerprint text + version table
    $keyRight = New-Object System.Windows.Forms.Panel
    $keyRight.Dock = [System.Windows.Forms.DockStyle]::Fill
    $keySplit.Panel2.Controls.Add($keyRight)

    $fpLabel = New-Object System.Windows.Forms.Label
    $fpLabel.Text      = "SHA-256 Fingerprint:"
    $fpLabel.ForeColor = $ACCENT
    $fpLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $fpLabel.Location  = New-Object System.Drawing.Point(6, 8)
    $fpLabel.Size      = New-Object System.Drawing.Size(580, 20)
    $keyRight.Controls.Add($fpLabel)

    $fpText = New-Object System.Windows.Forms.TextBox
    $fpText.ReadOnly   = $true
    $fpText.Multiline  = $true
    $fpText.BackColor  = [System.Drawing.Color]::FromArgb(10,10,20)
    $fpText.ForeColor  = $FG_OK
    $fpText.Font       = New-Object System.Drawing.Font("Consolas", 9)
    $fpText.Location   = New-Object System.Drawing.Point(6, 32)
    $fpText.Size       = New-Object System.Drawing.Size(580, 55)
    $keyRight.Controls.Add($fpText)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text      = "Copy Fingerprint"
    $copyBtn.Location  = New-Object System.Drawing.Point(6, 96)
    $copyBtn.Size      = New-Object System.Drawing.Size(150, 28)
    $copyBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $copyBtn.BackColor = $PANEL_BG
    $copyBtn.ForeColor = $ACCENT
    $copyBtn.Font      = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $keyRight.Controls.Add($copyBtn)

    $pkiGrid = New-Object System.Windows.Forms.DataGridView
    $pkiGrid.Location                         = New-Object System.Drawing.Point(6, 136)
    $pkiGrid.Size                             = New-Object System.Drawing.Size(580, 350)
    $pkiGrid.ReadOnly                         = $true
    $pkiGrid.AllowUserToAddRows               = $false
    $pkiGrid.RowHeadersVisible                = $false
    $pkiGrid.BackgroundColor                  = $PANEL_BG
    $pkiGrid.ForeColor                        = $FG
    $pkiGrid.GridColor                        = [System.Drawing.Color]::FromArgb(50,50,70)
    $pkiGrid.DefaultCellStyle.BackColor       = $PANEL_BG
    $pkiGrid.DefaultCellStyle.ForeColor       = $FG
    $pkiGrid.DefaultCellStyle.Font            = New-Object System.Drawing.Font("Consolas", 8)
    $pkiGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
    $pkiGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ACCENT
    $pkiGrid.EnableHeadersVisualStyles        = $false
    $pkiGrid.SelectionMode                    = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $pkiGrid.Columns.Add("KeyName",  "Key Name")  | Out-Null
    $pkiGrid.Columns.Add("Version",  "Version")   | Out-Null
    $pkiGrid.Columns.Add("SHA256",   "SHA256 Fingerprint")  | Out-Null
    $pkiGrid.Columns.Add("Size",     "Bytes")     | Out-Null
    $pkiGrid.Columns[0].Width = 160  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
    $pkiGrid.Columns[1].Width = 80
    $pkiGrid.Columns[2].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $pkiGrid.Columns[3].Width = 60
    $keyRight.Controls.Add($pkiGrid)

    # Anchor pkiGrid on resize
    $pkiGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $fpText.Anchor  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    # Populate all PKI files
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    foreach ($pk in $pubKeys) {
        try {
            $raw  = [System.IO.File]::ReadAllBytes($pk.FullName)
            $hash = ($sha256.ComputeHash($raw) | ForEach-Object { $_.ToString('x2') }) -join ''
            $ver  = if ($pk.BaseName -match '-(\d+)$') { $Matches[1] } else { '00' }
            $null = $pkiGrid.Rows.Add($pk.BaseName, "v$ver", $hash, $raw.Count)
        } catch { $null = $pkiGrid.Rows.Add($pk.BaseName, '?', '(error)', 0) }
    }
    $sha256.Dispose()

    # Key selection change handler
    $keyDropRef  = $keyDrop
    $picBoxRef   = $picBox
    $fpTextRef   = $fpText
    $pubKeysRef  = $pubKeys
    $pkiDirRef   = $pkiDir
    $keyDrop.Add_SelectedIndexChanged({
        $idx = $keyDropRef.SelectedIndex
        if ($idx -lt 0 -or $idx -ge @($pubKeysRef).Count) { return }
        $pk  = $pubKeysRef[$idx]
        try {
            $raw  = [System.IO.File]::ReadAllBytes($pk.FullName)
            $sha2 = [System.Security.Cryptography.SHA256]::Create()
            $hash = ($sha2.ComputeHash($raw) | ForEach-Object { $_.ToString('x2') }) -join ''
            $sha2.Dispose()
            $fpTextRef.Text = "$($pk.BaseName)`r`n$hash"
            $bmp = New-QrFingerprintBitmap -Text "$($pk.BaseName):$hash" -Size 200
            if ($null -ne $bmp) { $picBoxRef.Image = $bmp }
        } catch { $fpTextRef.Text = "(error reading key)" }
    }.GetNewClosure())

    $copyBtn.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($fpTextRef.Text)) {
            [System.Windows.Forms.Clipboard]::SetText($fpTextRef.Text)
        }
    }.GetNewClosure())

    # Trigger initial display
    if (@($keyDrop.Items).Count -gt 0) { $keyDrop.SelectedIndex = -1; $keyDrop.SelectedIndex = 0 }

    # ════════════════════════════════════════════════════════════════
    # TAB 3 ─ Audit  (Manifest Mismatch)
    # ════════════════════════════════════════════════════════════════
    $tabAudit = New-AboutTab "Audit" "🛡"
    $tabAudit.Padding = New-Object System.Windows.Forms.Padding(8)

    $auditToolStrip = New-Object System.Windows.Forms.ToolStrip
    $auditToolStrip.BackColor = [System.Drawing.Color]::FromArgb(12,12,24)
    $auditToolStrip.GripStyle = [System.Windows.Forms.ToolStripGripStyle]::Hidden
    $tabAudit.Controls.Add($auditToolStrip)

    $btnRefreshAudit = New-Object System.Windows.Forms.ToolStripButton
    $btnRefreshAudit.Text  = "⟳  Refresh"
    $btnRefreshAudit.Font  = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $auditToolStrip.Items.Add($btnRefreshAudit) | Out-Null

    $btnExportAudit = New-Object System.Windows.Forms.ToolStripButton
    $btnExportAudit.Text = "💾  Export CSV"
    $auditToolStrip.Items.Add($btnExportAudit) | Out-Null

    $auditToolStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $auditStatus = New-Object System.Windows.Forms.ToolStripLabel
    $auditStatus.Text = "Click Refresh to scan"
    $auditStatus.ForeColor = $FG_DIM
    $auditToolStrip.Items.Add($auditStatus) | Out-Null

    $auditGrid = New-Object System.Windows.Forms.DataGridView
    $auditGrid.Dock                          = [System.Windows.Forms.DockStyle]::Fill
    $auditGrid.ReadOnly                      = $true
    $auditGrid.AllowUserToAddRows            = $false
    $auditGrid.RowHeadersVisible             = $false
    $auditGrid.BackgroundColor               = $PANEL_BG
    $auditGrid.ForeColor                     = $FG
    $auditGrid.GridColor                     = [System.Drawing.Color]::FromArgb(50,50,70)
    $auditGrid.DefaultCellStyle.BackColor    = $PANEL_BG
    $auditGrid.DefaultCellStyle.ForeColor    = $FG
    $auditGrid.DefaultCellStyle.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $auditGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
    $auditGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ACCENT
    $auditGrid.EnableHeadersVisualStyles     = $false
    $auditGrid.SelectionMode                 = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $auditGrid.Columns.Add("File",   "File")   | Out-Null
    $auditGrid.Columns.Add("Status", "Status") | Out-Null
    $auditGrid.Columns.Add("Note",   "Note")   | Out-Null
    $auditGrid.Columns[0].Width = 180  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
    $auditGrid.Columns[1].Width = 90
    $auditGrid.Columns[2].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $tabAudit.Controls.Add($auditGrid)

    # Row colouring by status
    $auditGrid.Add_CellFormatting({
        $rowStatus = $this.Rows[$_.RowIndex].Cells['Status'].Value
        switch ($rowStatus) {
            'Relic'     { $_.CellStyle.ForeColor = $FG_DANGER }
            'Untracked' { $_.CellStyle.ForeColor = $FG_WARN }
            'Error'     { $_.CellStyle.ForeColor = [System.Drawing.Color]::Magenta }
        }
    })

    $auditGridRef = $auditGrid
    $auditStatusRef = $auditStatus
    $btnRefreshAudit.Add_Click({
        $auditStatusRef.Text = "Scanning..."
        $auditGridRef.Rows.Clear()
        $mismatches = Get-ManifestMismatches -WorkspacePath $PSScriptRoot
        foreach ($mm in $mismatches) { $null = $auditGridRef.Rows.Add($mm.File, $mm.Status, $mm.Note) }
        $relics    = @($mismatches | Where-Object { $_.Status -eq 'Relic' }).Count
        $untracked = @($mismatches | Where-Object { $_.Status -eq 'Untracked' }).Count
        $auditStatusRef.Text = "Relics: $relics  |  Untracked: $untracked  |  Total issues: $(@($mismatches).Count)"
        Write-AppLog "Audit scan: $relics relics, $untracked untracked" "Audit"
    }.GetNewClosure())

    $btnExportAudit.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = "CSV files (*.csv)|*.csv"
        $sfd.FileName = "audit-manifest-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
        if ($sfd.ShowDialog() -eq 'OK') {
            $rows = @()
            foreach ($row in $auditGridRef.Rows) {
                $rows += [PSCustomObject]@{ File=$row.Cells['File'].Value; Status=$row.Cells['Status'].Value; Note=$row.Cells['Note'].Value }
            }
            $rows | Export-Csv -LiteralPath $sfd.FileName -Encoding UTF8 -NoTypeInformation
        }
    }.GetNewClosure())

    # Auto-scan in audit mode
    if ($AuditMode) { $btnRefreshAudit.PerformClick() }

    # ════════════════════════════════════════════════════════════════
    # TAB 4 ─ Chief Approvals
    # ════════════════════════════════════════════════════════════════
    $tabApprovals = New-AboutTab "Approvals" "✅"
    $tabApprovals.Padding = New-Object System.Windows.Forms.Padding(8)

    # Toolbar
    $appToolStrip = New-Object System.Windows.Forms.ToolStrip
    $appToolStrip.BackColor = [System.Drawing.Color]::FromArgb(12,12,24)
    $appToolStrip.GripStyle = [System.Windows.Forms.ToolStripGripStyle]::Hidden
    $tabApprovals.Controls.Add($appToolStrip)

    $btnNewApproval = New-Object System.Windows.Forms.ToolStripButton
    $btnNewApproval.Text = "➕  Submit Item"
    $appToolStrip.Items.Add($btnNewApproval) | Out-Null

    $btnApprove = New-Object System.Windows.Forms.ToolStripButton
    $btnApprove.Text = "✔  Approve Selected"
    $appToolStrip.Items.Add($btnApprove) | Out-Null

    $btnReject = New-Object System.Windows.Forms.ToolStripButton
    $btnReject.Text = "✖  Reject Selected"
    $appToolStrip.Items.Add($btnReject) | Out-Null

    $appToolStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $btnBypass = New-Object System.Windows.Forms.ToolStripButton
    $btnBypass.Text = "⏱  Grant 28-Day Bypass"
    $btnBypass.ForeColor = $FG_WARN
    $appToolStrip.Items.Add($btnBypass) | Out-Null

    $bypassLabel = New-Object System.Windows.Forms.ToolStripLabel
    $bypassLabel.Text      = "Bypass: None"
    $bypassLabel.ForeColor = $FG_DIM
    $appToolStrip.Items.Add($bypassLabel) | Out-Null

    $appGrid = New-Object System.Windows.Forms.DataGridView
    $appGrid.Dock                          = [System.Windows.Forms.DockStyle]::Fill
    $appGrid.ReadOnly                      = $true
    $appGrid.AllowUserToAddRows            = $false
    $appGrid.RowHeadersVisible             = $false
    $appGrid.MultiSelect                   = $true
    $appGrid.BackgroundColor               = $PANEL_BG
    $appGrid.ForeColor                     = $FG
    $appGrid.GridColor                     = [System.Drawing.Color]::FromArgb(50,50,70)
    $appGrid.DefaultCellStyle.BackColor    = $PANEL_BG
    $appGrid.DefaultCellStyle.ForeColor    = $FG
    $appGrid.DefaultCellStyle.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $appGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
    $appGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ACCENT
    $appGrid.EnableHeadersVisualStyles     = $false
    $appGrid.SelectionMode                 = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $cols4 = @('ID','File','Status','Submitter','Submitted','Decision','RelatedFiles')
    $widths4 = @(60,200,90,100,100,80,200)
    for ($i = 0; $i -lt $cols4.Count; $i++) {
        $null = $appGrid.Columns.Add($cols4[$i], $cols4[$i])
        if ($i -lt $widths4.Count) { $appGrid.Columns[$i].Width = $widths4[$i] }
    }
    $appGrid.Columns[$cols4.Count-1].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $tabApprovals.Controls.Add($appGrid)

    $appGrid.Add_CellFormatting({
        $v = $this.Rows[$_.RowIndex].Cells['Status'].Value
        switch ($v) {
            'Approved'  { $_.CellStyle.ForeColor = $FG_OK }
            'Rejected'  { $_.CellStyle.ForeColor = $FG_DANGER }
            'Pending'   { $_.CellStyle.ForeColor = $FG_WARN }
            'Bypassed'  { $_.CellStyle.ForeColor = [System.Drawing.Color]::Cyan }
        }
    })

    # Load and display approvals
    $appData    = Get-ChiefApprovals -WorkspacePath $PSScriptRoot
    $appGridRef = $appGrid
    $bypassLblR = $bypassLabel

    function Refresh-ApprovalsGrid {
        $appGridRef.Rows.Clear()
        $appr = $appData.approvals
        if ($null -eq $appr) { return }
        foreach ($a in $appr) {
            $null = $appGridRef.Rows.Add(
                $a.id, $a.file, $a.status, $a.submitter,
                $a.submitted, $a.decision,
                ($a.relatedFiles -join ', ')
            )
        }
        # Bypass status
        if (-not [string]::IsNullOrWhiteSpace($appData.bypassExpiry)) {
            $exp = [datetime]::Parse($appData.bypassExpiry)
            if ($exp -gt (Get-Date)) {
                $bypassLblR.Text = "Bypass active until $($exp.ToString('yyyy-MM-dd'))"
                $bypassLblR.ForeColor = $FG_OK
            } else {
                $bypassLblR.Text = "Bypass EXPIRED ($($exp.ToString('yyyy-MM-dd')))"
                $bypassLblR.ForeColor = $FG_DANGER
            }
        } else {
            $bypassLblR.Text = "Bypass: None"
            $bypassLblR.ForeColor = $FG_DIM
        }
    }
    Refresh-ApprovalsGrid

    $btnNewApproval.Add_Click({
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Submit Item for Chief Approval"
        $dlg.Size = New-Object System.Drawing.Size(480, 320)
        $dlg.BackColor = $DARK_BG; $dlg.ForeColor = $FG
        $dlg.StartPosition = "CenterParent"
        $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        function Lbl { param([string]$t,[int]$x,[int]$y)
            $l = New-Object System.Windows.Forms.Label; $l.Text=$t; $l.ForeColor=$FG_DIM
            $l.Location = New-Object System.Drawing.Point($x,$y); $l.Size = New-Object System.Drawing.Size(420,18); $dlg.Controls.Add($l); return $l }
        function Txt { param([int]$x,[int]$y,[int]$w=420)
            $t = New-Object System.Windows.Forms.TextBox; $t.BackColor=$PANEL_BG; $t.ForeColor=$FG
            $t.Location = New-Object System.Drawing.Point($x,$y); $t.Size = New-Object System.Drawing.Size($w,22); $dlg.Controls.Add($t); return $t }

        $null = Lbl "File / Item:" 12 12;         $txtFile    = Txt 12 30
        $null = Lbl "Submitter:" 12 60;            $txtSubm    = Txt 12 78
        $null = Lbl "Related files (comma-sep):" 12 108;  $txtRel = Txt 12 126
        $null = Lbl "Notes:" 12 156;               $txtNotes   = Txt 12 174

        $okBtn = New-Object System.Windows.Forms.Button; $okBtn.Text="Submit"
        $okBtn.Location = New-Object System.Drawing.Point(12,220); $okBtn.Size = New-Object System.Drawing.Size(100,28)
        $okBtn.BackColor = $ACCENT; $okBtn.ForeColor = $DARK_BG; $okBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Controls.Add($okBtn)

        if ($dlg.ShowDialog($aboutForm) -eq 'OK') {
            $newId = "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            $newItem = [PSCustomObject]@{
                id           = $newId
                file         = $txtFile.Text
                status       = 'Pending'
                submitter    = $txtSubm.Text
                submitted    = (Get-Date -Format 'yyyy-MM-dd')
                decision     = ''
                notes        = $txtNotes.Text
                relatedFiles = ($txtRel.Text -split '\s*,\s*' | Where-Object { $_ })
            }
            if ($null -eq $appData.approvals) {
                $appData | Add-Member -MemberType NoteProperty -Name 'approvals' -Value @($newItem) -Force
            } else {
                $appData.approvals = @($appData.approvals) + $newItem
            }
            Save-ChiefApprovals -Data $appData -WorkspacePath $PSScriptRoot
            Refresh-ApprovalsGrid
        }
    }.GetNewClosure())

    $btnApprove.Add_Click({
        $rows = @($appGridRef.SelectedRows)
        if (@($rows).Count -eq 0) { return }
        foreach ($row in $rows) {
            $id = $row.Cells['ID'].Value
            foreach ($a in $appData.approvals) {
                if ($a.id -eq $id) { $a.status = 'Approved'; $a.decision = (Get-Date -Format 'yyyy-MM-dd') }
            }
        }
        Save-ChiefApprovals -Data $appData -WorkspacePath $PSScriptRoot
        Refresh-ApprovalsGrid
        Write-AppLog "Chief approved $(@($rows).Count) item(s)" "Audit"
    }.GetNewClosure())

    $btnReject.Add_Click({
        $rows = @($appGridRef.SelectedRows)
        if (@($rows).Count -eq 0) { return }
        foreach ($row in $rows) {
            $id = $row.Cells['ID'].Value
            foreach ($a in $appData.approvals) {
                if ($a.id -eq $id) { $a.status = 'Rejected'; $a.decision = (Get-Date -Format 'yyyy-MM-dd') }
            }
        }
        Save-ChiefApprovals -Data $appData -WorkspacePath $PSScriptRoot
        Refresh-ApprovalsGrid
    }.GetNewClosure())

    $btnBypass.Add_Click({
        $exp = (Get-Date).AddDays(28).ToString('yyyy-MM-dd')
        if ($null -eq ($appData.PSObject.Properties['bypassExpiry'])) {
            $appData | Add-Member -MemberType NoteProperty -Name 'bypassExpiry' -Value $exp -Force
        } else { $appData.bypassExpiry = $exp }
        Save-ChiefApprovals -Data $appData -WorkspacePath $PSScriptRoot
        Refresh-ApprovalsGrid
        Write-AppLog "Chief granted 28-day review bypass until $exp" "Audit"
    }.GetNewClosure())

    # ── Status bar ──────────────────────────────────────────────────
    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusBar.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
    $statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLbl.Text      = "PowerShellGUI  ·  $env:COMPUTERNAME  ·  Session PID $PID"
    $statusLbl.ForeColor = $FG_DIM
    $statusBar.Items.Add($statusLbl) | Out-Null
    $aboutForm.Controls.Add($statusBar)

    $aboutForm.ShowDialog() | Out-Null
    $aboutForm.Dispose()
}

function Show-AboutSystemDialog {
    <#.SYNOPSIS Full system metrics dashboard.#>
    [CmdletBinding()]
    param()

    Write-AppLog "Showing About-System dialog" "Audit"

    $DARK_BG  = [System.Drawing.Color]::FromArgb(14, 14, 24)
    $PANEL_BG = [System.Drawing.Color]::FromArgb(24, 24, 40)
    $ACCENT   = [System.Drawing.Color]::FromArgb(0, 200, 255)
    $FG       = [System.Drawing.Color]::FromArgb(220, 220, 235)
    $FG_DIM   = [System.Drawing.Color]::FromArgb(130, 130, 155)
    $FG_OK    = [System.Drawing.Color]::FromArgb(80, 255, 130)
    $FG_WARN  = [System.Drawing.Color]::FromArgb(255, 200, 50)

    $sForm = New-Object System.Windows.Forms.Form
    $sForm.Text = "About  ─  System Metrics"
    $sForm.Size = New-Object System.Drawing.Size(920, 680)
    $sForm.StartPosition = "CenterScreen"
    $sForm.BackColor = $DARK_BG; $sForm.ForeColor = $FG
    $sForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabs.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $sForm.Controls.Add($tabs)

    # ── Helper: add tab ──
    function New-SysTab { param([string]$t)
        $tp = New-Object System.Windows.Forms.TabPage; $tp.Text=$t; $tp.BackColor=$PANEL_BG; $tp.ForeColor=$FG
        $tabs.TabPages.Add($tp) | Out-Null; return $tp }

    # ── Helper: metric grid ──
    function New-MetricGrid { param([System.Windows.Forms.Control]$Parent)
        $dg = New-Object System.Windows.Forms.DataGridView
        $dg.Dock = [System.Windows.Forms.DockStyle]::Fill
        $dg.ReadOnly=$true; $dg.AllowUserToAddRows=$false; $dg.RowHeadersVisible=$false
        $dg.BackgroundColor=$PANEL_BG; $dg.ForeColor=$FG
        $dg.GridColor=[System.Drawing.Color]::FromArgb(45,45,65)
        $dg.DefaultCellStyle.BackColor=$PANEL_BG; $dg.DefaultCellStyle.ForeColor=$FG
        $dg.DefaultCellStyle.Font=New-Object System.Drawing.Font("Consolas",9)
        $dg.AlternatingRowsDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(18,18,32)
        $dg.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(8,8,18)
        $dg.ColumnHeadersDefaultCellStyle.ForeColor=$ACCENT
        $dg.EnableHeadersVisualStyles=$false
        $dg.SelectionMode=[System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $dg.Columns.Add("Metric","Metric") | Out-Null
        $dg.Columns.Add("Value","Value")   | Out-Null
        $dg.Columns[0].Width = 240  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
        $dg.Columns[1].AutoSizeMode=[System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        $Parent.Controls.Add($dg)
        return $dg }

    # ─── TAB: CPU ────────────────────────────────────────────────────
    $tCpu = New-SysTab "🖥 CPU"
    $gCpu = New-MetricGrid $tCpu
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        foreach ($cpu in $cpus) {
            $null = $gCpu.Rows.Add("Name",         $cpu.Name.Trim())
            $null = $gCpu.Rows.Add("Manufacturer", $cpu.Manufacturer)
            $null = $gCpu.Rows.Add("Cores",        $cpu.NumberOfCores)
            $null = $gCpu.Rows.Add("Logical CPUs", $cpu.NumberOfLogicalProcessors)
            $null = $gCpu.Rows.Add("Max Clock MHz",$cpu.MaxClockSpeed)
            $null = $gCpu.Rows.Add("L2 Cache KB",  $cpu.L2CacheSize)
            $null = $gCpu.Rows.Add("L3 Cache KB",  $cpu.L3CacheSize)
            $null = $gCpu.Rows.Add("Description",  $cpu.Caption)
            $cpuArch = switch ($cpu.Architecture) { 0 { 'x86' } 9 { 'x64' } 12 { 'Arm64' } default { "$($cpu.Architecture)" } }
            $null = $gCpu.Rows.Add("Architecture", $cpuArch)
            $cpuVirt = if ($cpu.VirtualizationFirmwareEnabled) { 'Enabled' } else { 'Disabled/Unknown' }
            $null = $gCpu.Rows.Add("Virtualization", $cpuVirt)
            $null = $gCpu.Rows.Add("Processor ID", $cpu.ProcessorId)
        }
        $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $null = $gCpu.Rows.Add("Current Load %", $load)
    } catch { $null = $gCpu.Rows.Add("(error)", "$_") }

    # ─── TAB: Memory ─────────────────────────────────────────────────
    $tMem = New-SysTab "💾 Memory"
    $gMem = New-MetricGrid $tMem
    try {
        $cs  = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        $freeGB   = [math]::Round($os.FreePhysicalMemory  / 1MB, 2)
        $usedGB   = [math]::Round($totalGB - $freeGB, 2)
        $pageGB   = [math]::Round($os.TotalVirtualMemorySize / 1MB, 2)
        $pageFree = [math]::Round($os.FreeVirtualMemory / 1MB, 2)
        $null = $gMem.Rows.Add("Total RAM (GB)",       $totalGB)
        $null = $gMem.Rows.Add("Used RAM (GB)",        $usedGB)
        $null = $gMem.Rows.Add("Free RAM (GB)",        $freeGB)
        $null = $gMem.Rows.Add("Usage %",              "$([math]::Round($usedGB/$totalGB*100,1))%")
        $null = $gMem.Rows.Add("── Virtual Memory ──", "")
        $null = $gMem.Rows.Add("Total VM (GB)",        $pageGB)
        $null = $gMem.Rows.Add("Free VM (GB)",         $pageFree)
        # DIMM slots
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $null = $gMem.Rows.Add("── Physical DIMMs ──", "$(@($dimms).Count) module(s)")
        foreach ($d in $dimms) {
            $gb = [math]::Round($d.Capacity / 1GB, 1)
            $null = $gMem.Rows.Add("  $($d.DeviceLocator)", "${gb}GB  $($d.Speed)MHz  $($d.Manufacturer)")
        }
    } catch { $null = $gMem.Rows.Add("(error)", "$_") }

    # ─── TAB: Disk ───────────────────────────────────────────────────
    $tDisk = New-SysTab "💿 Disk"
    $gDisk = New-MetricGrid $tDisk
    try {
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
        foreach ($d in $disks) {
            $totalGB = [math]::Round($d.Size / 1GB, 2)
            $freeGB  = [math]::Round($d.FreeSpace / 1GB, 2)
            $usedPct = if ($d.Size -gt 0) { [math]::Round(($d.Size - $d.FreeSpace) / $d.Size * 100, 1) } else { 0 }
            $null = $gDisk.Rows.Add("── Drive $($d.DeviceID) $($d.VolumeName) ──", "")
            $null = $gDisk.Rows.Add("  Total (GB)",   $totalGB)
            $null = $gDisk.Rows.Add("  Free (GB)",    $freeGB)
            $null = $gDisk.Rows.Add("  Used %",       "$usedPct%")
            $null = $gDisk.Rows.Add("  FS",           $d.FileSystem)
        }
        $physDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)
        $null = $gDisk.Rows.Add("── Physical Drives ──", "$(@($physDisks).Count)")
        foreach ($pd in $physDisks) {
            $gb = [math]::Round($pd.Size / 1GB, 2)
            $null = $gDisk.Rows.Add("  $($pd.Caption)", "${gb}GB  $($pd.MediaType)  $($pd.InterfaceType)")
        }
    } catch { $null = $gDisk.Rows.Add("(error)", "$_") }

    # ─── TAB: GPU / Display ─────────────────────────────────────────
    $tGPU = New-SysTab "🎮 GPU"
    $gGPU = New-MetricGrid $tGPU
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        foreach ($gpu in $gpus) {
            $vramMB = [math]::Round($gpu.AdapterRAM / 1MB, 0)
            $null = $gGPU.Rows.Add("── $($gpu.Caption) ──", "")
            $null = $gGPU.Rows.Add("  Driver",   $gpu.DriverVersion)
            $null = $gGPU.Rows.Add("  VRAM (MB)",$vramMB)
            $null = $gGPU.Rows.Add("  Res",      "$($gpu.CurrentHorizontalResolution) x $($gpu.CurrentVerticalResolution) @ $($gpu.CurrentRefreshRate)Hz")
            $null = $gGPU.Rows.Add("  Status",   $gpu.Status)
        }
        $monitors = @(Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue)
        $null = $gGPU.Rows.Add("── Monitors ──", "$(@($monitors).Count) detected")
        foreach ($m in $monitors) { $null = $gGPU.Rows.Add("  $($m.Name)", $m.ScreenHeight) }
    } catch { $null = $gGPU.Rows.Add("(error)", "$_") }

    # ─── TAB: Network ────────────────────────────────────────────────
    $tNet = New-SysTab "🌐 Network"
    $gNet = New-MetricGrid $tNet
    try {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disconnected' })
        foreach ($a in $adapters) {
            $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
            $null = $gNet.Rows.Add("── $($a.Name) ──", $a.Status)
            $null = $gNet.Rows.Add("  Description",    $a.InterfaceDescription)
            $null = $gNet.Rows.Add("  MAC",            $a.MacAddress)
            $null = $gNet.Rows.Add("  IPv4",           $ip)
            $null = $gNet.Rows.Add("  Speed (Mbps)",   [math]::Round($a.LinkSpeed / 1MB, 0))
        }
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
        $null = $gNet.Rows.Add("── DNS Servers ──", ($dns | Select-Object -Unique) -join ', ')
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        $null = $gNet.Rows.Add("Default Gateway", $gw)
    } catch { $null = $gNet.Rows.Add("(error)", "$_") }

    # ─── TAB: OS / Platform ──────────────────────────────────────────
    $tOS = New-SysTab "🪟 OS"
    $gOS = New-MetricGrid $tOS
    try {
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs  = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
        $bios= Get-CimInstance Win32_BIOS            -ErrorAction SilentlyContinue
        $up  = [datetime]::Now - $os.LastBootUpTime
        $null = $gOS.Rows.Add("OS Caption",         $os.Caption)
        $null = $gOS.Rows.Add("Build",              $os.BuildNumber)
        $null = $gOS.Rows.Add("Version",            $os.Version)
        $null = $gOS.Rows.Add("Architecture",       $os.OSArchitecture)
        $null = $gOS.Rows.Add("Install Date",       $os.InstallDate)
        $null = $gOS.Rows.Add("Last Boot",          $os.LastBootUpTime)
        $null = $gOS.Rows.Add("Uptime",             "$([int]$up.TotalDays)d $($up.Hours)h $($up.Minutes)m $($up.Seconds)s")
        $null = $gOS.Rows.Add("System Root",        $os.SystemDirectory)
        $null = $gOS.Rows.Add("── Computer ──",     "")
        $null = $gOS.Rows.Add("Name",               $cs.Name)
        $null = $gOS.Rows.Add("Domain/Workgroup",   $(if ($cs.PartOfDomain) { $cs.Domain } else { "(Workgroup) $($cs.Workgroup)" }))
        $null = $gOS.Rows.Add("Manufacturer",       $cs.Manufacturer)
        $null = $gOS.Rows.Add("Model",              $cs.Model)
        $null = $gOS.Rows.Add("── BIOS ──",         "")
        $null = $gOS.Rows.Add("BIOS Version",       $bios.SMBIOSBIOSVersion)
        $null = $gOS.Rows.Add("BIOS Manufacturer",  $bios.Manufacturer)
        $null = $gOS.Rows.Add("── PowerShell ──",   "")
        $null = $gOS.Rows.Add("PS Version",         "$($PSVersionTable.PSVersion)")
        $null = $gOS.Rows.Add("PS Edition",         $PSVersionTable.PSEdition)
        $null = $gOS.Rows.Add("CLR Version",        "$($PSVersionTable.CLRVersion)")
        $null = $gOS.Rows.Add("Culture",            [System.Threading.Thread]::CurrentThread.CurrentUICulture.Name)
        $null = $gOS.Rows.Add("Execution Policy",   (Get-ExecutionPolicy))
        $null = $gOS.Rows.Add("TimeZone",           (Get-TimeZone).DisplayName)
        $null = $gOS.Rows.Add("Current User",       "$env:USERDOMAIN\$env:USERNAME")
        $null = $gOS.Rows.Add("Session PID",        $PID)
    } catch { $null = $gOS.Rows.Add("(error)", "$_") }

    # ─── TAB: Processes ──────────────────────────────────────────────
    $tProc = New-SysTab "⚙ Processes"
    $gProc = New-Object System.Windows.Forms.DataGridView
    $gProc.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gProc.ReadOnly=$true; $gProc.AllowUserToAddRows=$false; $gProc.RowHeadersVisible=$false
    $gProc.BackgroundColor=$PANEL_BG; $gProc.ForeColor=$FG
    $gProc.GridColor=[System.Drawing.Color]::FromArgb(45,45,65)
    $gProc.DefaultCellStyle.BackColor=$PANEL_BG; $gProc.DefaultCellStyle.ForeColor=$FG
    $gProc.DefaultCellStyle.Font=New-Object System.Drawing.Font("Consolas",8)
    $gProc.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(8,8,18)
    $gProc.ColumnHeadersDefaultCellStyle.ForeColor=$ACCENT
    $gProc.EnableHeadersVisualStyles=$false
    $gProc.SelectionMode=[System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $tProc.Controls.Add($gProc)
    $procCols = @('Name','PID','CPU(s)','WS(MB)','Handles','Threads')
    foreach ($pc in $procCols) { $null = $gProc.Columns.Add($pc,$pc) }
    $gProc.Columns[0].Width=200; $gProc.Columns[1].Width=60
    $gProc.Columns[2].Width=70;  $gProc.Columns[3].Width=80
    try {
        Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 60 | ForEach-Object {
            $null = $gProc.Rows.Add(
                $_.ProcessName, $_.Id,
                [math]::Round($_.TotalProcessorTime.TotalSeconds,1),
                [math]::Round($_.WorkingSet64/1MB,1),
                $_.HandleCount, $_.Threads.Count
            )
        }
    } catch { <# Intentional: non-fatal #> }

    # ─── TAB: Environment Variables ──────────────────────────────────
    $tEnv = New-SysTab "📋 Env Vars"
    $gEnv = New-MetricGrid $tEnv
    $gEnv.Columns[0].Width = 200
    try {
        [System.Environment]::GetEnvironmentVariables() | ForEach-Object { $_.GetEnumerator() } |
            Sort-Object Name | ForEach-Object { $null = $gEnv.Rows.Add($_.Name, $_.Value) }
    } catch { <# Intentional: non-fatal #> }

    # ─── Status bar ──────────────────────────────────────────────────
    $sb = New-Object System.Windows.Forms.StatusStrip
    $sb.BackColor = [System.Drawing.Color]::FromArgb(8,8,18)
    $slbl = New-Object System.Windows.Forms.ToolStripStatusLabel
    $slbl.Text = "System Metrics  ·  $env:COMPUTERNAME  ·  Refreshed $(Get-Date -Format 'HH:mm:ss')"; $slbl.ForeColor = $FG_DIM
    $sb.Items.Add($slbl) | Out-Null; $sForm.Controls.Add($sb)

    $sForm.ShowDialog() | Out-Null
    $sForm.Dispose()
}

function Show-AboutAppDialog {
    <#.SYNOPSIS Analytics dashboard linking to all built-in app analytics.#>
    [CmdletBinding()]
    param()

    Write-AppLog "Showing About-App analytics dialog" "Audit"

    $DARK_BG  = [System.Drawing.Color]::FromArgb(14, 14, 24)
    $PANEL_BG = [System.Drawing.Color]::FromArgb(24, 24, 40)
    $ACCENT   = [System.Drawing.Color]::FromArgb(130, 80, 255)
    $ACCENT2  = [System.Drawing.Color]::FromArgb(0, 220, 180)
    $FG       = [System.Drawing.Color]::FromArgb(220, 220, 235)
    $FG_DIM   = [System.Drawing.Color]::FromArgb(130, 130, 155)
    $FG_OK    = [System.Drawing.Color]::FromArgb(80, 255, 130)
    $FG_WARN  = [System.Drawing.Color]::FromArgb(255, 200, 50)

    $appForm = New-Object System.Windows.Forms.Form
    $appForm.Text = "About  ─  App Analytics"
    $appForm.Size = New-Object System.Drawing.Size(880, 660)
    $appForm.StartPosition = "CenterScreen"
    $appForm.BackColor = $DARK_BG; $appForm.ForeColor = $FG
    $appForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $appForm.Controls.Add($tabs)

    function New-AppTab { param([string]$t)
        $tp = New-Object System.Windows.Forms.TabPage; $tp.Text=$t; $tp.BackColor=$PANEL_BG; $tp.ForeColor=$FG
        $tabs.TabPages.Add($tp) | Out-Null; return $tp }

    # ─── TAB: Launch Telemetry ───────────────────────────────────────
    $tTele = New-AppTab "📊 Launch Telemetry"
    $tTele.Padding = New-Object System.Windows.Forms.Padding(8)
    $gTele = New-Object System.Windows.Forms.DataGridView
    $gTele.Dock=$([System.Windows.Forms.DockStyle]::Fill); $gTele.ReadOnly=$true; $gTele.AllowUserToAddRows=$false; $gTele.RowHeadersVisible=$false
    $gTele.BackgroundColor=$PANEL_BG; $gTele.ForeColor=$FG; $gTele.GridColor=[System.Drawing.Color]::FromArgb(45,45,65)
    $gTele.DefaultCellStyle.BackColor=$PANEL_BG; $gTele.DefaultCellStyle.ForeColor=$FG
    $gTele.DefaultCellStyle.Font=New-Object System.Drawing.Font("Consolas",9)
    $gTele.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(8,8,18)
    $gTele.ColumnHeadersDefaultCellStyle.ForeColor=$ACCENT2
    $gTele.EnableHeadersVisualStyles=$false; $gTele.SelectionMode=[System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $tTele.Controls.Add($gTele)
    try {
        if (Get-Command Get-LaunchTelemetry -ErrorAction SilentlyContinue) {
            $tele = Get-LaunchTelemetry
            if ($null -ne $tele) {
                $tele.PSObject.Properties | Sort-Object Name | ForEach-Object {
                    if ($null -eq $gTele.Columns['Metric']) { $gTele.Columns.Add('Metric','Metric') | Out-Null; $gTele.Columns.Add('Value','Value') | Out-Null; $gTele.Columns[0].Width=220; $gTele.Columns[1].AutoSizeMode=[System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill }
                    $null = $gTele.Rows.Add($_.Name, $_.Value)
                }
            }
        }
        if ($gTele.Columns.Count -eq 0) {
            $gTele.Columns.Add('Metric','Metric') | Out-Null; $gTele.Columns.Add('Value','Value') | Out-Null
            $gTele.Columns[0].Width=220; $gTele.Columns[1].AutoSizeMode=[System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
            $logPath = Join-Path $PSScriptRoot 'logs'
            $logFiles = @(Get-ChildItem $logPath -Filter '*.log' -File -ErrorAction SilentlyContinue)
            $null = $gTele.Rows.Add("Log files",     "@($logFiles).Count)")
            $null = $gTele.Rows.Add("Total log size", "$([math]::Round(($logFiles | Measure-Object Length -Sum).Sum / 1KB, 1)) KB")
            $null = $gTele.Rows.Add("Workspace Root", $PSScriptRoot)
            $null = $gTele.Rows.Add("Session PID",    $PID)
            $null = $gTele.Rows.Add("Startup mode",   "Get-LaunchTelemetry not loaded")
        }
    } catch { <# Intentional: non-fatal #> }

    # ─── TAB: CronAiAthon Pipeline ──────────────────────────────────
    $tCron = New-AppTab "⏱ CronAiAthon"
    $tCron.Padding = New-Object System.Windows.Forms.Padding(8)
    $cronText = New-Object System.Windows.Forms.TextBox
    $cronText.Dock=$([System.Windows.Forms.DockStyle]::Fill); $cronText.Multiline=$true; $cronText.ReadOnly=$true; $cronText.ScrollBars='Both'; $cronText.WordWrap=$false
    $cronText.BackColor=[System.Drawing.Color]::FromArgb(8,8,18); $cronText.ForeColor=$FG_OK
    $cronText.Font=New-Object System.Drawing.Font("Consolas",9)
    $tCron.Controls.Add($cronText)
    try {
        $cPath = Join-Path $PSScriptRoot 'config\cron-aiathon-pipeline.json'
        if (Test-Path $cPath) {
            $cData = Get-Content $cPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sb = [System.Text.StringBuilder]::new()
            $null = $sb.AppendLine("=== CronAiAthon Pipeline ===")
            $null = $sb.AppendLine("Version : $($cData.meta.version)")
            $null = $sb.AppendLine("Updated : $($cData.meta.lastUpdated)")
            $null = $sb.AppendLine("")
            if ($null -ne $cData.items) {
                $open = @($cData.items | Where-Object { $_.status -ne 'DONE' }).Count
                $done = @($cData.items | Where-Object { $_.status -eq 'DONE' }).Count
                $null = $sb.AppendLine("Total Items : $(@($cData.items).Count)")
                $null = $sb.AppendLine("Open        : $open")
                $null = $sb.AppendLine("Done        : $done")
                $null = $sb.AppendLine(""); $null = $sb.AppendLine("── Open Items (top 20) ──")
                @($cData.items | Where-Object { $_.status -ne 'DONE' } | Select-Object -First 20) | ForEach-Object {
                    $null = $sb.AppendLine("[$($_.status)] [$($_.priority)] $($_.title)")
                }
            }
            $cronText.Text = $sb.ToString()
        } else { $cronText.Text = "cron-aiathon-pipeline.json not found at:`n$cPath" }
    } catch { $cronText.Text = "Error loading CronAiAthon: $_" }

    # ─── TAB: SIN Pattern Summary ────────────────────────────────────
    $tSin = New-AppTab "🛡 SIN Summary"
    $tSin.Padding = New-Object System.Windows.Forms.Padding(8)
    $gSin = New-Object System.Windows.Forms.DataGridView
    $gSin.Dock=$([System.Windows.Forms.DockStyle]::Fill); $gSin.ReadOnly=$true; $gSin.AllowUserToAddRows=$false; $gSin.RowHeadersVisible=$false
    $gSin.BackgroundColor=$PANEL_BG; $gSin.ForeColor=$FG; $gSin.GridColor=[System.Drawing.Color]::FromArgb(45,45,65)
    $gSin.DefaultCellStyle.BackColor=$PANEL_BG; $gSin.DefaultCellStyle.ForeColor=$FG
    $gSin.DefaultCellStyle.Font=New-Object System.Drawing.Font("Consolas",8)
    $gSin.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(8,8,18)
    $gSin.ColumnHeadersDefaultCellStyle.ForeColor=$ACCENT
    $gSin.EnableHeadersVisualStyles=$false; $gSin.SelectionMode=[System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $sinCols = @('SIN ID','Class','Severity','Status','Title')
    $sinWids  = @(220,70,80,90,300)
    for ($i=0;$i -lt $sinCols.Count;$i++) { $null=$gSin.Columns.Add($sinCols[$i],$sinCols[$i]); if($i -lt $sinWids.Count){$gSin.Columns[$i].Width=$sinWids[$i]} }
    $gSin.Columns[$sinCols.Count-1].AutoSizeMode=[System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $tSin.Controls.Add($gSin)
    try {
        $sinPath = Join-Path $PSScriptRoot 'sin_registry'
        @(Get-ChildItem $sinPath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name) | ForEach-Object {
            try {
                $s = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $id  = if ($s.PSObject.Properties.Name -contains 'sin_id')   { $s.sin_id }   else { $_.BaseName }
                $cls = if ($id -match 'PATTERN') { 'Pattern' } elseif ($id -match 'SEMI') { 'SemiSin' } else { 'Instance' }
                $sev = if ($s.PSObject.Properties.Name -contains 'severity') { $s.severity } else { '?' }
                $sta = if ($s.PSObject.Properties.Name -contains 'is_resolved' -and $s.is_resolved) { 'Resolved' } else { 'Open' }
                $ttl = if ($s.PSObject.Properties.Name -contains 'title') { $s.title } else { '' }
                $null = $gSin.Rows.Add($id, $cls, $sev, $sta, $ttl)
            } catch { <# Intentional: non-fatal #> }
        }
    } catch { <# Intentional: non-fatal #> }

    # ─── TAB: Config Coverage ────────────────────────────────────────
    $tCfg = New-AppTab "⚙ Config Coverage"
    $tCfg.Padding = New-Object System.Windows.Forms.Padding(8)
    $cfgText = New-Object System.Windows.Forms.TextBox
    $cfgText.Dock=$([System.Windows.Forms.DockStyle]::Fill); $cfgText.Multiline=$true; $cfgText.ReadOnly=$true; $cfgText.ScrollBars='Both'
    $cfgText.BackColor=[System.Drawing.Color]::FromArgb(8,8,18); $cfgText.ForeColor=$ACCENT2
    $cfgText.Font=New-Object System.Drawing.Font("Consolas",9)
    $tCfg.Controls.Add($cfgText)
    try {
        $cfgDir  = Join-Path $PSScriptRoot 'config'
        $cfgFiles = @(Get-ChildItem $cfgDir -File -Recurse -ErrorAction SilentlyContinue)
        $sb2 = [System.Text.StringBuilder]::new()
        $null = $sb2.AppendLine("=== Config Coverage Report ===")
        $null = $sb2.AppendLine("Config dir   : $cfgDir")
        $null = $sb2.AppendLine("Total files  : $(@($cfgFiles).Count)")
        $null = $sb2.AppendLine("Total size   : $([math]::Round(($cfgFiles|Measure-Object Length -Sum).Sum/1KB,1)) KB")
        $null = $sb2.AppendLine("")
        foreach ($cf in $cfgFiles | Sort-Object Name) {
            $null = $sb2.AppendLine("  $($cf.Name.PadRight(40)) $([math]::Round($cf.Length/1KB,1)) KB")
        }
        $cfgText.Text = $sb2.ToString()
    } catch { $cfgText.Text = "Error: $_" }

    # ─── TAB: Launch Tools ───────────────────────────────────────────
    $tTools = New-AppTab "🛠 Launch Analytics"
    $tTools.Padding = New-Object System.Windows.Forms.Padding(8)
    $toolsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $toolsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $toolsPanel.WrapContents = $false
    $toolsPanel.AutoScroll = $true
    $tTools.Controls.Add($toolsPanel)

    $appFormRef = $appForm
    $btnDefs = @(
        @{ T="📈  Scan Dashboard";      S='scripts\Show-ScanDashboard.ps1' },
        @{ T="📊  Config Coverage Audit";S='scripts\Invoke-ConfigCoverageAudit.ps1' },
        @{ T="🔎  Workspace Dependency Map";S='scripts\Invoke-WorkspaceDependencyMap.ps1' },
        @{ T="📋  CronAiAthon Tool";    S='scripts\Show-CronAiAthonTool.ps1' },
        @{ T="🛡  SIN Pattern Scanner"; S='tests\Invoke-SINPatternScanner.ps1' },
        @{ T="🔑  Certificate Manager"; S='scripts\Show-CertificateManager.ps1' },
        @{ T="⚙  Script Dependency Matrix"; S='scripts\Invoke-ScriptDependencyMatrix.ps1' }
    )
    foreach ($bd in $btnDefs) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $bd.T; $b.Width = 360; $b.Height = 38; $b.Margin = New-Object System.Windows.Forms.Padding(4)
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.BackColor = [System.Drawing.Color]::FromArgb(30,30,50); $b.ForeColor = $FG
        $b.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $scriptPath = Join-Path $PSScriptRoot $bd.S
        $b.Add_Click({ Invoke-LocalScriptWithProgress -ScriptPath $scriptPath -Owner $appFormRef }.GetNewClosure())
        $toolsPanel.Controls.Add($b)
    }

    # ─── Status bar ──────────────────────────────────────────────────
    $sb = New-Object System.Windows.Forms.StatusStrip
    $sb.BackColor=[System.Drawing.Color]::FromArgb(8,8,18)
    $slbl = New-Object System.Windows.Forms.ToolStripStatusLabel
    $slbl.Text="App Analytics  ·  $env:COMPUTERNAME  ·  $(Get-Date -Format 'HH:mm:ss')"; $slbl.ForeColor=$FG_DIM
    $sb.Items.Add($slbl) | Out-Null; $appForm.Controls.Add($sb)

    $appForm.ShowDialog() | Out-Null
    $appForm.Dispose()
}

function Invoke-LaunchModuleCheck {
    <#.SYNOPSIS Check workspace modules are importable; offer Y/A/N scripted install for any missing.#>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PSScriptRoot,
        [switch]$NonInteractive
    )

    $modulesDir = Join-Path $WorkspacePath 'modules'
    if (-not (Test-Path $modulesDir)) {
        Write-AppLog "Invoke-LaunchModuleCheck: modules dir not found at $modulesDir" "Warning"
        return
    }

    $psdFiles = @(Get-ChildItem $modulesDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue)
    if (@($psdFiles).Count -eq 0) {
        Write-AppLog "Invoke-LaunchModuleCheck: no .psd1 manifests found in $modulesDir" "Info"
        return
    }

    $missing = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($psd in $psdFiles) {
        $modName = $psd.BaseName
        $loaded  = Get-Module -Name $modName -ListAvailable -ErrorAction SilentlyContinue
        if ($null -eq $loaded) {
            $missing.Add([PSCustomObject]@{ Name = $modName; PSD = $psd.FullName })
        }
    }

    if (@($missing).Count -eq 0) {
        Write-AppLog "Invoke-LaunchModuleCheck: all $(@($psdFiles).Count) workspace modules are accessible" "Info"
        return
    }

    Write-AppLog "Invoke-LaunchModuleCheck: $(@($missing).Count) module(s) not accessible: $($missing.Name -join ', ')" "Warning"

    if ($NonInteractive) { return }

    # Build a WinForms dialog for Y/A/N selection
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Module Install Wizard"
    $dlg.Size = New-Object System.Drawing.Size(680, 520)
    $dlg.StartPosition = "CenterScreen"
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(14,14,24)
    $dlg.ForeColor = [System.Drawing.Color]::FromArgb(220,220,235)
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = "⚠  $(@($missing).Count) workspace module(s) not accessible to import"
    $hdr.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $hdr.ForeColor = [System.Drawing.Color]::FromArgb(255,200,50)
    $hdr.Dock = [System.Windows.Forms.DockStyle]::Top; $hdr.Height = 40; $hdr.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft; $hdr.Padding = New-Object System.Windows.Forms.Padding(8,0,0,0)
    $dlg.Controls.Add($hdr)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "For each module below select: (Y) Register module path, (N) Skip, or use (A) Register All."
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(160,160,180); $sub.Dock = [System.Windows.Forms.DockStyle]::Top; $sub.Height = 28
    $sub.Padding = New-Object System.Windows.Forms.Padding(8,0,0,0)
    $dlg.Controls.Add($sub)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.CheckBoxes = $true; $lv.BackColor = [System.Drawing.Color]::FromArgb(22,22,36); $lv.ForeColor = [System.Drawing.Color]::FromArgb(200,200,220)
    $lv.Font = New-Object System.Drawing.Font("Consolas",9); $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lv.Columns.Add("Module",    200) | Out-Null
    $lv.Columns.Add("PSD Path",  380) | Out-Null
    $lv.Columns.Add("Action",    70)  | Out-Null
    $dlg.Controls.Add($lv)
    foreach ($m in $missing) {
        $li = New-Object System.Windows.Forms.ListViewItem($m.Name)
        $null = $li.SubItems.Add($m.PSD)
        $null = $li.SubItems.Add("(Y) Register")
        $li.Checked = $true
        $lv.Items.Add($li) | Out-Null
    }

    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom; $btnPanel.Height = 50
    $btnPanel.BackColor = [System.Drawing.Color]::FromArgb(10,10,20)
    $dlg.Controls.Add($btnPanel)

    $btnAll = New-Object System.Windows.Forms.Button; $btnAll.Text = "A  ·  Register All"
    $btnAll.Location = New-Object System.Drawing.Point(8,8); $btnAll.Size = New-Object System.Drawing.Size(150,34)
    $btnAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $btnAll.BackColor = [System.Drawing.Color]::FromArgb(0,180,130); $btnAll.ForeColor = [System.Drawing.Color]::Black
    $btnAll.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $btnPanel.Controls.Add($btnAll)

    $btnSel = New-Object System.Windows.Forms.Button; $btnSel.Text = "Y  ·  Register Checked"
    $btnSel.Location = New-Object System.Drawing.Point(168,8); $btnSel.Size = New-Object System.Drawing.Size(150,34)
    $btnSel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $btnSel.BackColor = [System.Drawing.Color]::FromArgb(0,120,220); $btnSel.ForeColor = [System.Drawing.Color]::White
    $btnPanel.Controls.Add($btnSel)

    $btnNo = New-Object System.Windows.Forms.Button; $btnNo.Text = "N  ·  Skip All"
    $btnNo.Location = New-Object System.Drawing.Point(328,8); $btnNo.Size = New-Object System.Drawing.Size(120,34)
    $btnNo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $btnNo.BackColor = [System.Drawing.Color]::FromArgb(60,30,30); $btnNo.ForeColor = [System.Drawing.Color]::FromArgb(220,80,80)
    $btnPanel.Controls.Add($btnNo)

    $resultText = New-Object System.Windows.Forms.Label
    $resultText.Location = New-Object System.Drawing.Point(460,14); $resultText.Size = New-Object System.Drawing.Size(200,28)
    $resultText.ForeColor = [System.Drawing.Color]::FromArgb(80,255,130); $resultText.Font = New-Object System.Drawing.Font("Consolas",8)
    $btnPanel.Controls.Add($resultText)

    $lvRef = $lv; $modsDirRef = $modulesDir; $resRef = $resultText
    $registerModPath = {
        param([string]$psdPath, [string]$modsDir)
        # Add the modules directory to PSModulePath for this process and persistently for User scope
        $procCurrent = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
        if ($procCurrent.Split(';') -notcontains $modsDir) {
            [System.Environment]::SetEnvironmentVariable('PSModulePath', "$modsDir;$procCurrent", 'Process')
        }
        $userCurrent = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'User')
        if ([string]::IsNullOrEmpty($userCurrent)) { $userCurrent = '' }
        if ($userCurrent.Split(';') -notcontains $modsDir) {
            [System.Environment]::SetEnvironmentVariable('PSModulePath', ($modsDir + ';' + $userCurrent).TrimEnd(';'), 'User')
        }
        try {
            Import-Module $psdPath -Force -ErrorAction Stop
            return "OK"
        } catch { return "ERR: $_" }
    }

    $btnAll.Add_Click({
        $count = 0
        foreach ($m in $missing) {
            $r = & $registerModPath $m.PSD $modsDirRef
            Write-AppLog "Module install wizard: register $($m.Name) -> $r" "Audit"
            $count++
        }
        $resRef.Text = "Registered $count module(s)"
        Write-AppLog "Module path registered: $modsDirRef" "Info"
    }.GetNewClosure())

    $btnSel.Add_Click({
        $count = 0
        foreach ($li in $lvRef.CheckedItems) {
            $psd = $li.SubItems[1].Text
            $r   = & $registerModPath $psd $modsDirRef
            Write-AppLog "Module install wizard: register $($li.Text) -> $r" "Audit"
            $count++
        }
        $resRef.Text = "Registered $count module(s)"
    }.GetNewClosure())

    $btnNo.Add_Click({ $dlg.Close() })

    $dlg.ShowDialog() | Out-Null
    $dlg.Dispose()
}

function Invoke-RepositorySourceCheck {
    <#.SYNOPSIS Check PSGallery and NuGet are registered; offer to add them if missing.#>
    [CmdletBinding()]
    param([switch]$Silent)

    $repos  = @(Get-PSRepository -ErrorAction SilentlyContinue)
    $hasPSG = ($repos | Where-Object { $_.Name -eq 'PSGallery' } | Measure-Object).Count -gt 0
    $pkgSources = @(Get-PackageSource -ErrorAction SilentlyContinue)
    $hasNuG = ($pkgSources | Where-Object { $_.Name -like '*NuGet*' -or $_.Location -like '*nuget.org*' } | Measure-Object).Count -gt 0

    if ($hasPSG -and $hasNuG) {
        Write-AppLog "RepositorySourceCheck: PSGallery and NuGet already registered" "Info"
        return
    }

    if ($Silent) { return }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $missing = @()
    if (-not $hasPSG) { $missing += "PSGallery (PowerShell module repository)" }
    if (-not $hasNuG) { $missing += "NuGet (package source for Install-Package)" }

    $msg = "The following package repositories are not registered on this system:`n`n"
    $msg += ($missing | ForEach-Object { "  • $_" }) -join "`n"
    $msg += "`n`nWould you like to register them now?`n(This enables Install-Module and Install-Package to work correctly)"

    $result = [System.Windows.Forms.MessageBox]::Show(
        $msg, "Package Repository Setup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -ne 'Yes') { return }

    if (-not $hasPSG) {
        try {
            Register-PSRepository -Default -ErrorAction Stop
            Write-AppLog "Registered PSGallery repository" "Info"
        } catch {
            try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction Stop; Write-AppLog "PSGallery trust set" "Info" } catch { Write-AppLog "PSGallery setup failed: $_" "Warning" }
        }
    }
    if (-not $hasNuG) {
        try {
            Register-PackageSource -Name 'NuGet' -Location 'https://www.nuget.org/api/v2' -ProviderName 'NuGet' -Trusted -ErrorAction Stop
            Write-AppLog "Registered NuGet package source" "Info"
        } catch { Write-AppLog "NuGet setup failed: $_" "Warning" }
    }
    Write-AppLog "RepositorySourceCheck complete" "Audit"
}

# ==================== GUI FUNCTIONS ====================
function New-GUI {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch]$StartMinimized
    )
    if (-not $PSCmdlet.ShouldProcess("Main GUI", "Create and show")) { return }
    # Assemblies already loaded at script scope
    
    # Create main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PowerShellGUI - Scriptz Launchr"
    $form.Size = New-Object System.Drawing.Size([int]700, [int]680)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.KeyPreview = $true
    # DoubleBuffered is a protected property - must use reflection to set it
    $form.GetType().GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
    # Apply modern dark theme
    if (Get-Command Set-ModernFormStyle -ErrorAction SilentlyContinue) {
        Set-ModernFormStyle -Form $form
    } else {
        $form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    }

    # ── Single-instance tool guard: tracks running tool labels for this form ──
    $script:_RunningTools = @{}      # Key = MenuLabel, Value = $true or Process object

    function Resolve-MenuScriptPath {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$RelativeCandidates
        )

        foreach ($candidate in $RelativeCandidates) {
            $fullPath = Join-Path $PSScriptRoot $candidate
            if (Test-Path $fullPath) {
                return $fullPath
            }
        }
        return $null
    }

    function Invoke-MenuScriptSafely {
        param(
            [Parameter(Mandatory = $true)]
            [string]$MenuLabel,

            [Parameter(Mandatory = $true)]
            [string[]]$RelativeCandidates,

            [hashtable]$ScriptArguments = @{},

            [switch]$UseNewProcess
        )

        # ── Single-instance guard: prevent duplicate launches per form ──
        if ($script:_RunningTools.ContainsKey($MenuLabel)) {
            $existing = $script:_RunningTools[$MenuLabel]
            # For external processes, check if still alive
            if ($existing -is [System.Diagnostics.Process] -and -not $existing.HasExited) {
                Write-AppLog "$MenuLabel is already running (PID $($existing.Id))" 'Warning'
                [System.Windows.Forms.MessageBox]::Show(
                    "$MenuLabel is already running.`nOnly one instance per session is allowed.",
                    $MenuLabel,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
                return $false
            }
            # For inline runs, check if flag is still $true (cleared on completion)
            if ($existing -eq $true) {
                Write-AppLog "$MenuLabel is already running (inline)" 'Warning'
                [System.Windows.Forms.MessageBox]::Show(
                    "$MenuLabel is already running.`nOnly one instance per session is allowed.",
                    $MenuLabel,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
                return $false
            }
            # Stale entry -- remove it
            $script:_RunningTools.Remove($MenuLabel)
        }

        $resolvedPath = Resolve-MenuScriptPath -RelativeCandidates $RelativeCandidates
        if (-not $resolvedPath) {
            $attempted = ($RelativeCandidates | ForEach-Object { Join-Path $PSScriptRoot $_ }) -join "`n"
            Write-AppLog "$MenuLabel script not found. Tried: $attempted" 'Error'
            [System.Windows.Forms.MessageBox]::Show(
                "$MenuLabel script not found.`n`nTried:`n$attempted",
                $MenuLabel,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return $false
        }

        try {
            if ($UseNewProcess) {
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$resolvedPath`"")
                foreach ($key in $ScriptArguments.Keys) {
                    $argList += "-$key"
                    $value = $ScriptArguments[$key]
                    if ($null -ne $value -and $value -ne '') {
                        $argList += [string]$value
                    }
                }
                $proc = Start-Process powershell.exe -ArgumentList ($argList -join ' ') -WindowStyle Normal -PassThru
                $script:_RunningTools[$MenuLabel] = $proc
            } else {
                $script:_RunningTools[$MenuLabel] = $true
                try {
                    & $resolvedPath @ScriptArguments
                } finally {
                    $script:_RunningTools.Remove($MenuLabel)
                }
            }

            Write-AppLog "$MenuLabel launched: $resolvedPath" 'Info'
            return $true
        } catch {
            $script:_RunningTools.Remove($MenuLabel)
            Write-AppLog "$MenuLabel launch failed: $($_.Exception.Message) | Path: $resolvedPath" 'Error'
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to launch ${MenuLabel}:`n$($_.Exception.Message)`n`nPath: $resolvedPath",
                $MenuLabel,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return $false
        }
    }

    function Open-MenuPathSafely {
        param(
            [Parameter(Mandatory = $true)]
            [string]$MenuLabel,

            [Parameter(Mandatory = $true)]
            [string]$PathToOpen
        )

        if (-not (Test-Path $PathToOpen)) {
            Write-AppLog "$MenuLabel target missing: $PathToOpen" 'Warning'
            [System.Windows.Forms.MessageBox]::Show(
                "$MenuLabel target not found:`n$PathToOpen",
                $MenuLabel,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return $false
        }

        try {
            Start-Process $PathToOpen
            Write-AppLog "$MenuLabel opened: $PathToOpen" 'Info'
            return $true
        } catch {
            Write-AppLog "$MenuLabel failed to open: $($_.Exception.Message) | Path: $PathToOpen" 'Error'
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to open ${MenuLabel}:`n$($_.Exception.Message)`n`nPath: $PathToOpen",
                $MenuLabel,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return $false
        }
    }
    
    # ==================== MENU STRIP ====================
    $menuStrip = New-Object System.Windows.Forms.MenuStrip
    $form.Controls.Add($menuStrip)
    
    # File Menu
    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $fileMenu.Text = "&File"
    
    # Settings submenu
    $settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $settingsMenu.Text = "&Settings"
    
    $pathSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $pathSettingsItem.Text = "&Configure Paths..."
    $pathSettingsItem.Add_Click({
        Write-AppLog "User selected File > Settings > Configure Paths" "Audit"
        Show-PathSettingsGUI
        # ── Cycle 3: Refresh status bar and service lights after path save ──
        try {
            $newRemote = try { [string](Get-ConfigSubValue 'RemoteUpdatePath') } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($newRemote)) { $script:RemoteUpdatePath = $newRemote }
            $rd = if ([string]::IsNullOrWhiteSpace($newRemote)) { '(not set)' } else { $newRemote }
            if ($statusRightRow2) { $statusRightRow2.Text = "Remote: $rd | Scripts: $scriptsDir" }
            if ($script:_ServiceTimer) { $script:_ServiceTimer.Stop(); $script:_ServiceTimer.Interval = 100; $script:_ServiceTimer.Start() }
        } catch { Write-AppLog "[Settings] Path settings reload error: $_" 'Warning' }
    })
    $settingsMenu.DropDownItems.Add($pathSettingsItem) | Out-Null
    
    $scriptFoldersItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $scriptFoldersItem.Text = "&Script Folders..."
    $scriptFoldersItem.Add_Click({
        Write-AppLog "User selected File > Settings > Script Folders" "Audit"
        Show-ScriptFolderSettingsGUI
    })
    $settingsMenu.DropDownItems.Add($scriptFoldersItem) | Out-Null
    
    $fileMenu.DropDownItems.Add($settingsMenu) | Out-Null
    
    # Separator
    $fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ══════════════════════════════════════════════════════════════
    # SYSTEM TRAY (always-on) -- X closes to tray, Ctrl+Q exits
    # ══════════════════════════════════════════════════════════════
    $script:_ForceClose = $false
    $script:_TrayIcon   = New-Object System.Windows.Forms.NotifyIcon
    $script:_TrayIcon.Text = "PowerShellGUI"
    try {
        if (Get-Command New-SmileyTrayIcon -ErrorAction SilentlyContinue) {
            $script:_TrayIcon.Icon = New-SmileyTrayIcon
            Write-AppLog "[TrayHost] Custom smiley tray icon applied (yellow face / crimson oval)" "Debug"
        } else {
            $script:_TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
        }
    } catch {
        $script:_TrayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon(
            [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
    $script:_TrayIcon.Visible = $true

    # -- helper: restore window from tray --
    $script:_RestoreFromTray = {
        Write-AppLog "[TrayHost] Restoring GUI from system tray" "Debug"
        $form.Show()
        $form.ShowInTaskbar = $true
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Activate()
        Write-AppLog "[TrayHost] GUI restored and activated" "Debug"
        Write-Information '' -InformationAction Continue
        Write-Information '***GUI-is-RESTORED-from-TASKTRAY***' -InformationAction Continue
        Write-Information '' -InformationAction Continue
    }

    # -- helper: real exit (with confirmation) --
    $script:_ForceExit = {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Do you want to CLOSE and EXIT the application?`n`nYes = Close and Exit`nNo  = Minimize to Taskbar",
            "Exit PowerShellGUI",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-AppLog "User confirmed EXIT from tray -- closing application" "Audit"
            $script:_ForceClose = $true
            $form.Close()
        } else {
            Write-AppLog "User chose MINIMIZE from tray exit prompt" "Audit"
        }
    }

    # Double-click tray icon => restore
    $script:_TrayIcon.Add_DoubleClick($script:_RestoreFromTray)

    # Minimize to tray when window is minimized
    $form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and $script:_TrayIcon) {
            Write-AppLog "[TrayHost] Form minimized -- hiding to system tray (form stays alive)" "Debug"
            $form.Hide()
            $form.ShowInTaskbar = $false
            $script:_TrayIcon.ShowBalloonTip(1000, "PowerShellGUI",
                "Running in system tray. Double-click icon or press SPACEBAR in shell to restore.",
                [System.Windows.Forms.ToolTipIcon]::Info)
            Write-AppLog "[TrayHost] Form hidden -- tray balloon shown" "Debug"
            Write-Information '' -InformationAction Continue
            Write-Information '***GUI-is-MINI-on-TASKTRAY***' -InformationAction Continue
            Write-Information '##PRESS SPACEBAR IN SHELL or DOUBLE-CLICK TRAY ICON##' -InformationAction Continue
            Write-Information '' -InformationAction Continue
        }
    })

    # ── Build tray context menu ──────────────────────────────────
    $trayCtx = New-Object System.Windows.Forms.ContextMenuStrip

    # --- Restore / Show ---
    $trayRestore = New-Object System.Windows.Forms.ToolStripMenuItem
    $trayRestore.Text = "&Restore PowerShellGUI"
    $trayRestore.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $trayRestore.Add_Click($script:_RestoreFromTray)
    $trayCtx.Items.Add($trayRestore) | Out-Null
    $trayCtx.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── System Folders flyout ────────────────────────────────────
    $foldersMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $foldersMenu.Text = "System &Folders"

    $knownFolders = @(
        @{ Name = "Desktop";    Path = [Environment]::GetFolderPath('Desktop') },
        @{ Name = "Downloads";  Path = (Join-Path $env:USERPROFILE 'Downloads') },
        @{ Name = "Documents";  Path = [Environment]::GetFolderPath('MyDocuments') },
        @{ Name = "Pictures";   Path = [Environment]::GetFolderPath('MyPictures') },
        @{ Name = "Videos";     Path = [Environment]::GetFolderPath('MyVideos') },
        @{ Name = "Music";      Path = [Environment]::GetFolderPath('MyMusic') }
    )
    foreach ($kf in $knownFolders) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = $kf.Name
        $mi.Tag  = $kf.Path
        $mi.Add_Click({ Start-Process explorer.exe $this.Tag })
        $foldersMenu.DropDownItems.Add($mi) | Out-Null
    }
    $foldersMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # My Computer (This PC)
    $miPC = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPC.Text = "My Computer"
    $miPC.Add_Click({ Start-Process explorer.exe "shell:MyComputerFolder" })
    $foldersMenu.DropDownItems.Add($miPC) | Out-Null

    # Control Panel
    $miCP = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCP.Text = "Control Panel"
    $miCP.Add_Click({ Start-Process control.exe })
    $foldersMenu.DropDownItems.Add($miCP) | Out-Null

    # God Mode
    $miGod = New-Object System.Windows.Forms.ToolStripMenuItem
    $miGod.Text = "God Mode (All Settings)"
    $miGod.Add_Click({ Start-Process explorer.exe "shell:::{ED7BA470-8E54-465E-825C-99712043E01C}" })
    $foldersMenu.DropDownItems.Add($miGod) | Out-Null

    # Network Browser
    $miNet = New-Object System.Windows.Forms.ToolStripMenuItem
    $miNet.Text = "Network Browser"
    $miNet.Add_Click({ Start-Process explorer.exe "shell:NetworkPlacesFolder" })
    $foldersMenu.DropDownItems.Add($miNet) | Out-Null

    $foldersMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # All local volumes and media cards
    try {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
        foreach ($drv in $drives) {
            $label = if ($drv.VolumeLabel) { "$($drv.Name.TrimEnd('\'))  [$($drv.VolumeLabel)]" } else { "$($drv.Name.TrimEnd('\'))  [$($drv.DriveType)]" }
            $dmi = New-Object System.Windows.Forms.ToolStripMenuItem
            $dmi.Text = $label
            $dmi.Tag  = $drv.Name
            $dmi.Add_Click({ Start-Process explorer.exe $this.Tag })
            $foldersMenu.DropDownItems.Add($dmi) | Out-Null
        }
    } catch { Write-AppLog "[TrayHost] Drive folders menu error: $_" 'Warning' }

    $trayCtx.Items.Add($foldersMenu) | Out-Null

    # ── Utilities flyout ─────────────────────────────────────────
    $utilsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $utilsMenu.Text = "&Utilities"

    # Terminal / PowerShell / CMD / nslookup
    $utilEntries = @(
        @{ Name = "Windows Terminal"; Cmd = "wt.exe" },
        @{ Name = "PowerShell 7 (pwsh)"; Cmd = "pwsh.exe" },
        @{ Name = "PowerShell 5.1"; Cmd = "powershell.exe" },
        @{ Name = "Command Prompt (cmd)"; Cmd = "cmd.exe" },
        @{ Name = "nslookup"; Cmd = "cmd.exe"; Args = "/k nslookup" }
    )
    foreach ($ue in $utilEntries) {
        $exePath = Get-Command $ue.Cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if ($exePath) {
            $ui = New-Object System.Windows.Forms.ToolStripMenuItem
            $ui.Text = $ue.Name
            $ui.Tag  = if ($ue.Args) { "$exePath|$($ue.Args)" } else { "$exePath|" }
            $ui.Add_Click({
                $parts = $this.Tag -split '\|', 2
                if ($parts[1]) { Start-Process $parts[0] $parts[1] } else { Start-Process $parts[0] }  # SIN-EXEMPT: P027 - split result guarded by if/truthy check on same line
            })
            $utilsMenu.DropDownItems.Add($ui) | Out-Null
        }
    }

    $utilsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Administration tools available on this machine
    $adminTools = @(
        @{ Name = "Computer Management";   Cmd = "compmgmt.msc" },
        @{ Name = "Device Manager";        Cmd = "devmgmt.msc" },
        @{ Name = "Disk Management";       Cmd = "diskmgmt.msc" },
        @{ Name = "Event Viewer";          Cmd = "eventvwr.msc" },
        @{ Name = "Services";              Cmd = "services.msc" },
        @{ Name = "Task Scheduler";        Cmd = "taskschd.msc" },
        @{ Name = "Performance Monitor";   Cmd = "perfmon.msc" },
        @{ Name = "Local Group Policy";    Cmd = "gpedit.msc" },
        @{ Name = "Local Users & Groups";  Cmd = "lusrmgr.msc" },
        @{ Name = "Windows Firewall";      Cmd = "wf.msc" },
        @{ Name = "Registry Editor";       Cmd = "regedit.exe" },
        @{ Name = "System Configuration";  Cmd = "msconfig.exe" },
        @{ Name = "Resource Monitor";      Cmd = "resmon.exe" },
        @{ Name = "Task Manager";          Cmd = "taskmgr.exe" }
    )
    foreach ($at in $adminTools) {
        $atPath = Get-Command $at.Cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if (-not $atPath) {
            $atPath = Join-Path "$env:SystemRoot\System32" $at.Cmd
            if (-not (Test-Path $atPath)) { continue }
        }
        $ai = New-Object System.Windows.Forms.ToolStripMenuItem
        $ai.Text = $at.Name
        $ai.Tag  = $atPath
        $ai.Add_Click({ Start-Process $this.Tag })
        $utilsMenu.DropDownItems.Add($ai) | Out-Null
    }

    $trayCtx.Items.Add($utilsMenu) | Out-Null
    $trayCtx.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── Mirror main-menu top-level items into tray context ───────
    # We clone the text and re-fire by programmatically performing click on the real menu item.
    # This runs AFTER the full menuStrip is built (deferred via form.Shown).
    $form.Add_Shown({
        foreach ($topItem in $menuStrip.Items) {
            if ($topItem -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
            $clone = New-Object System.Windows.Forms.ToolStripMenuItem
            $clone.Text = $topItem.Text
            # Clone sub-items one level deep
            foreach ($child in $topItem.DropDownItems) {
                if ($child -is [System.Windows.Forms.ToolStripSeparator]) {
                    $clone.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
                    continue
                }
                if ($child -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
                $cc = New-Object System.Windows.Forms.ToolStripMenuItem
                $cc.Text = $child.Text
                $cc.Tag  = $child                # reference to real item
                $cc.Add_Click({
                    $realItem = $this.Tag
                    if ($realItem) {
                        # Restore form so menu handlers can interact with it
                        $form.Show()
                        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                        $form.Activate()
                        $realItem.PerformClick()
                    }
                })
                # Clone sub-sub-items (one more level for submenus like XHTML Reports)
                if ($child.HasDropDown) {
                    foreach ($grandchild in $child.DropDownItems) {
                        if ($grandchild -is [System.Windows.Forms.ToolStripSeparator]) {
                            $cc.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
                            continue
                        }
                        if ($grandchild -isnot [System.Windows.Forms.ToolStripMenuItem]) { continue }
                        $gc = New-Object System.Windows.Forms.ToolStripMenuItem
                        $gc.Text = $grandchild.Text
                        $gc.Tag  = $grandchild
                        $gc.Add_Click({
                            $realItem = $this.Tag
                            if ($realItem) {
                                $form.Show()
                                $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                                $form.Activate()
                                $realItem.PerformClick()
                            }
                        })
                        $cc.DropDownItems.Add($gc) | Out-Null
                    }
                }
                $clone.DropDownItems.Add($cc) | Out-Null
            }
            # Insert before the last separator+Exit in tray context
            $trayCtx.Items.Add($clone) | Out-Null
        }

        # Final separator + Exit at the very bottom
        $trayCtx.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
        $trayExitFinal = New-Object System.Windows.Forms.ToolStripMenuItem
        $trayExitFinal.Text = "E&xit PowerShellGUI"
        $trayExitFinal.Add_Click($script:_ForceExit)
        $trayCtx.Items.Add($trayExitFinal) | Out-Null
    })

    $script:_TrayIcon.ContextMenuStrip = $trayCtx
    Write-AppLog "System tray icon initialised with context menu" "Info"

    # Separator
    $fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "E&xit"
    $exitItem.ShortcutKeys = "Control+Q"
    $exitItem.Add_Click({
        Write-AppLog "User selected File > Exit" "Audit"
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Do you want to CLOSE and EXIT the application?`n`nYes = Close and Exit`nNo  = Minimize to Taskbar",
            "Exit PowerShellGUI",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-AppLog "User confirmed EXIT -- closing application" "Audit"
            $script:_ForceClose = $true
            $form.Close()
        } else {
            Write-AppLog "User chose MINIMIZE instead of exit" "Audit"
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        }
    })
    $fileMenu.DropDownItems.Add($exitItem) | Out-Null
    
    $menuStrip.Items.Add($fileMenu) | Out-Null

    # Tests Menu
    $testsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $testsMenu.Text = "&Tests"

    $versionCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $versionCheckItem.Text = "&Version Check"
    $versionCheckItem.Add_Click({
        Write-AppLog "User selected Tests > Version Check" "Audit"
        Test-VersionTag
        [System.Windows.Forms.MessageBox]::Show("Version check completed. See diff XML file if any differences.", "Version Check")
    })
    $testsMenu.DropDownItems.Add($versionCheckItem) | Out-Null

    $networkDiagItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $networkDiagItem.Text = "&Network Diagnostics"
    $networkDiagItem.Add_Click({
        Show-NetworkDiagnosticsDialog
    })
    $testsMenu.DropDownItems.Add($networkDiagItem) | Out-Null

    $testsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $diskCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $diskCheckItem.Text = "&Disk Check"
    $diskCheckItem.Add_Click({
        Show-DiskCheckDialog
    })
    $testsMenu.DropDownItems.Add($diskCheckItem) | Out-Null

    $privacyCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $privacyCheckItem.Text = "&Privacy Check"
    $privacyCheckItem.Add_Click({
        Show-PrivacyCheck
    })
    $testsMenu.DropDownItems.Add($privacyCheckItem) | Out-Null

    $systemCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $systemCheckItem.Text = "&System Check"
    $systemCheckItem.Add_Click({
        Show-SystemCheck
    })
    $testsMenu.DropDownItems.Add($systemCheckItem) | Out-Null

    $testsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $appTestingItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $appTestingItem.Text = "App Testing (Docs && Comments)"
    $appTestingItem.Add_Click({
        Write-AppLog "User selected Tests > App Testing" "Audit"
        $results = Test-AppTesting
        $count = if ($results) { $results.Count } else { 0 }
        if ($results -and $null -ne $results.Count) { $count = $results.Count }
        [System.Windows.Forms.MessageBox]::Show("App Testing completed. Findings: $count. Opening latest report...", "App Testing") | Out-Null
        if ($results.ReportPath -and (Test-Path $results.ReportPath)) { Invoke-Item $results.ReportPath }
    })
    $testsMenu.DropDownItems.Add($appTestingItem) | Out-Null

    $scrutinyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $scrutinyItem.Text = "Scrutiny Safety && SecOps"
    $scrutinyItem.Add_Click({
        Write-AppLog "User selected Tests > Scrutiny Safety and SecOps" "Audit"
        $results = Test-ScriptSafetySecOp
        $count = if ($results) { $results.Count } else { 0 }
        if ($results -and $null -ne $results.Count) { $count = $results.Count }
        [System.Windows.Forms.MessageBox]::Show("Scrutiny scan completed. Findings: $count. Opening latest report...", "Scrutiny Safety and SecOps") | Out-Null
        if ($results.ReportPath -and (Test-Path $results.ReportPath)) { Invoke-Item $results.ReportPath }
    })
    $testsMenu.DropDownItems.Add($scrutinyItem) | Out-Null

    $menuStrip.Items.Add($testsMenu) | Out-Null

    # Links Menu
    $linksMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $linksMenu.Text = "&Links"
    Initialize-LinksConfigFile
    Build-LinksMenu -LinksMenu $linksMenu
    $menuStrip.Items.Add($linksMenu) | Out-Null

    # WinGets Menu
    $wingetsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetsMenu.Text = "&WinGets"

    $wingetAppsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetAppsItem.Text = "Installed Apps (&Grid View)"
    $wingetAppsItem.Add_Click({
        Show-WingetInstalledApp
    })
    $wingetsMenu.DropDownItems.Add($wingetAppsItem) | Out-Null

    $wingetCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetCheckItem.Text = "Detect Updates (&Check-Only)"
    $wingetCheckItem.Add_Click({
        Show-WingetUpgradeCheck
    })
    $wingetsMenu.DropDownItems.Add($wingetCheckItem) | Out-Null

    $wingetUpdateAllItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetUpdateAllItem.Text = "Update All (Admin Options)"
    $wingetUpdateAllItem.Add_Click({
        Show-WingetUpdateAllDialog
    })
    $wingetsMenu.DropDownItems.Add($wingetUpdateAllItem) | Out-Null

    # Separator before SASC items
    $wingetsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $bwLiteInstallItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $bwLiteInstallItem.Text = "Install-BitWarden-&LITE"
    $bwLiteInstallItem.Add_Click({
        try {
            $installerPath = Join-Path $scriptsDir 'Install-BitwardenLite.ps1'
            if (Test-Path $installerPath) {
                Write-AppLog "Launching Bitwarden LITE installer (elevated) from WinGets menu" "Info"
                $confirm = [System.Windows.Forms.MessageBox]::Show(
                    "This will install Bitwarden CLI via winget, ensure required module dependencies, and validate core vault functions.`nAdministrator elevation may be required.`n`nProceed?",
                    "Install Bitwarden LITE",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($confirm -eq 'Yes') {
                    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
                    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$installerPath`""
                    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait -PassThru

                    if ($proc.ExitCode -ne 0) {
                        throw "Bitwarden installer exited with code $($proc.ExitCode)."
                    }

                    # Post-install readiness checks in current host
                    $readyMsgs = [System.Collections.Generic.List[string]]::new()
                    $warnMsgs = [System.Collections.Generic.List[string]]::new()

                    $sascModulePath = Get-ProjectPath SascModule
                    if (Test-Path $sascModulePath) {
                        try {
                            Import-Module $sascModulePath -Force -ErrorAction Stop
                            if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
                                Initialize-SASCModule -ScriptDir $scriptDir | Out-Null
                            }
                            $requiredFunctions = @('Test-VaultStatus','Lock-Vault','Show-VaultStatusDialog','Show-VaultUnlockDialog')
                            $missingFns = @($requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
                            if ($missingFns.Count -eq 0) {
                                $readyMsgs.Add('SASC functions loaded successfully.') | Out-Null
                            } else {
                                $warnMsgs.Add("Missing SASC functions: $($missingFns -join ', ')") | Out-Null
                            }
                        } catch {
                            $warnMsgs.Add("Failed to load AssistedSASC module: $($_.Exception.Message)") | Out-Null
                        }
                    } else {
                        $warnMsgs.Add('AssistedSASC.psm1 not found in modules folder.') | Out-Null
                    }

                    $bwCmd = Get-Command bw -ErrorAction SilentlyContinue
                    if ($bwCmd) {
                        try {
                            $raw = & $bwCmd.Source status 2>&1 | Out-String
                            $statusObj = $null
                            try { $statusObj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { <# Intentional: non-fatal #> }
                            if ($statusObj -and $statusObj.status) {
                                $readyMsgs.Add("BW status: $($statusObj.status)") | Out-Null
                            } elseif ($raw -match '(?i)service.*not.*running|service.*not.*installed|connection.*refused|unable to connect|daemon') {
                                $warnMsgs.Add('Bitwarden service is not installed or not running yet.') | Out-Null
                            } else {
                                $warnMsgs.Add('Unable to determine BW status from CLI output.') | Out-Null
                            }
                        } catch {
                            $warnMsgs.Add("BW status check failed: $($_.Exception.Message)") | Out-Null
                        }
                    } else {
                        $warnMsgs.Add('bw CLI command not found after install.') | Out-Null
                    }

                    $msg = "Bitwarden CLI installation completed."
                    if ($readyMsgs.Count -gt 0) {
                        $msg += "`n`nReady:`n - " + ($readyMsgs -join "`n - ")
                    }
                    if ($warnMsgs.Count -gt 0) {
                        $msg += "`n`nWarnings:`n - " + ($warnMsgs -join "`n - ")
                    }
                    [System.Windows.Forms.MessageBox]::Show(
                        $msg,
                        'Installation Finished',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        $(if ($warnMsgs.Count -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })
                    ) | Out-Null
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Install-BitwardenLite.ps1 not found in scripts folder.`nExpected: $installerPath",
                    "Installer Not Found",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
        } catch {
            if ($_.Exception.Message -match 'canceled by the user') {
                Write-AppLog "BW Lite install: User declined UAC elevation" "Warning"
            } else {
                Write-AppLog "BW Lite install error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Installation failed: $($_.Exception.Message)",
                    "Install Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
    })
    $wingetsMenu.DropDownItems.Add($bwLiteInstallItem) | Out-Null

    $wingetsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $appTemplateItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $appTemplateItem.Text = "App &Template Manager..."
    $appTemplateItem.Add_Click({
        Write-AppLog "User selected WinGets > App Template Manager" "Audit"
        $templateScript = Join-Path $scriptsDir 'Show-AppTemplateManager.ps1'
        if (Test-Path $templateScript) {
            try {
                . $templateScript
                Show-AppTemplateManager
            } catch {
                Write-AppLog "App Template Manager error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch App Template Manager:`n$($_.Exception.Message)",
                    "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Show-AppTemplateManager.ps1 not found in scripts.", "Missing Script",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $wingetsMenu.DropDownItems.Add($appTemplateItem) | Out-Null

    $menuStrip.Items.Add($wingetsMenu) | Out-Null
    
    # Tools Menu
    $toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $toolsMenu.Text = "&Tools"
    
    $viewConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewConfigItem.Text = "View &Config"
    $viewConfigItem.Add_Click({
        Write-AppLog "User selected Tools > View Config" "Audit"
        if (Test-Path $configFile) {
            Write-AppLog "Opening config file: $configFile" "Debug"
            Invoke-Item $configFile
        }
        else {
            Write-AppLog "Config file not found at: $configFile" "Warning"
            [System.Windows.Forms.MessageBox]::Show("Config file not found. Run a script first.", "Info")
        }
    })
    $toolsMenu.DropDownItems.Add($viewConfigItem) | Out-Null
    
    $configMaintenanceItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $configMaintenanceItem.Text = "&Config Maintenance..."
    $configMaintenanceItem.Add_Click({
        Write-AppLog "User selected Tools > Config Maintenance" "Audit"
        $currentConfigPaths = @{
            ConfigPath = $ConfigPath
            DefaultFolder = $DefaultFolder
            TempFolder = $TempFolder
            ReportFolder = $ReportFolder
            DownloadFolder = $DownloadFolder
        }
        Show-ConfigMaintenanceForm -CurrentPaths $currentConfigPaths
    })
    $toolsMenu.DropDownItems.Add($configMaintenanceItem) | Out-Null
    
    $openLogsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openLogsItem.Text = "Open &Logs Directory"
    $openLogsItem.Add_Click({
        Write-AppLog "User selected Tools > Open Logs Directory" "Audit"
        Write-AppLog "Opening logs directory: $logsDir" "Debug"
        Invoke-Item $logsDir
    })
    $toolsMenu.DropDownItems.Add($openLogsItem) | Out-Null
    
    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    
    $layoutItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $layoutItem.Text = "Scriptz n Portz N PowerShellD (Layout)"
    $layoutItem.Add_Click({
        Write-AppLog "User selected Tools > Display Layout" "Audit"
        Show-GUILayout
    })
    $toolsMenu.DropDownItems.Add($layoutItem) | Out-Null
    
    $buttonMainItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $buttonMainItem.Text = "&Button Maintenance"
    $buttonMainItem.Add_Click({
        Write-AppLog "User selected Tools > Button Maintenance" "Audit"
        [System.Windows.Forms.MessageBox]::Show(
            "Button Maintenance Tool`n`nFeature coming soon: Add/Edit/Delete custom buttons for scripts and applications.`n`nThis will allow you to manage your script launcher buttons from the GUI.",
            "Button Maintenance",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $toolsMenu.DropDownItems.Add($buttonMainItem) | Out-Null
    
    $networkDetailsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $networkDetailsItem.Text = "&Network Details"
    $networkDetailsItem.Add_Click({
        Write-AppLog "User selected Tools > Network Details (-> WinRemote PS Tool)" "Audit"
        Invoke-MenuScriptSafely -MenuLabel 'WinRemote PS Tool' `
            -RelativeCandidates @('scripts\WinRemote-PSTool.ps1') -UseNewProcess
    })
    $toolsMenu.DropDownItems.Add($networkDetailsItem) | Out-Null
    
    $avpnItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $avpnItem.Text = "A&VPN Connection Tracker"
    $avpnItem.Add_Click({
        Write-AppLog "User selected Tools > AVPN Connection Tracker" "Audit"
        Show-AVPNConnectionTracker -ConfigPath $avpnConfigFile -LogCallback { param($m, $l) Write-AppLog $m $l } -Owner $form
    })
    $toolsMenu.DropDownItems.Add($avpnItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── Script Services submenu ─────────────────────────────────────────────────
    $servicesMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $servicesMenu.Text = "Script &Services"

    $startEngineItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $startEngineItem.Text = "&#x25B6; Start Local Web Engine"
    $startEngineItem.Text = "Start Local Web Engine"
    $startEngineItem.Add_Click({
        Write-AppLog "User selected Tools > Script Services > Start Local Web Engine" "Audit"
        $svcScript = Join-Path $PSScriptRoot 'scripts\Start-LocalWebEngineService.ps1'
        if (-not (Test-Path -LiteralPath $svcScript)) {
            [System.Windows.Forms.MessageBox]::Show("Service launcher not found:`n$svcScript","Script Services",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        try {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$svcScript`"",'Start') `
                -WindowStyle Hidden
            Write-AppLog "LocalWebEngine start requested via $svcScript" "Info"
            # Trigger a quick status check after 2s
            $kickTimer = New-Object System.Windows.Forms.Timer
            $kickTimer.Interval = 2000
            $kickTimer.Add_Tick({
                $kickTimer.Stop()
                try {
                    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8042/api/engine/status')
                    $req.Timeout = 2000
                    $resp = $req.GetResponse()
                    $resp.Close()
                    if ($null -ne $script:_EngineStatusLabel) { $script:_EngineStatusLabel.Text = 'Engine: running' ; $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen }
                } catch {
                    if ($null -ne $script:_EngineStatusLabel) { $script:_EngineStatusLabel.Text = 'Engine: starting…' ; $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::Goldenrod }
                }
                $kickTimer.Dispose()
            }.GetNewClosure())
            $kickTimer.Start()
        } catch {
            Write-AppLog "Failed to start LocalWebEngine: $_" "Error"
            [System.Windows.Forms.MessageBox]::Show("Failed to start engine:`n$_","Script Services",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $servicesMenu.DropDownItems.Add($startEngineItem) | Out-Null

    $stopEngineItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $stopEngineItem.Text = "Stop Local Web Engine"
    $stopEngineItem.Add_Click({
        Write-AppLog "User selected Tools > Script Services > Stop Local Web Engine" "Audit"
        $svcScript = Join-Path $PSScriptRoot 'scripts\Start-LocalWebEngineService.ps1'
        if (Test-Path -LiteralPath $svcScript) {
            try {
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$svcScript`"",'Stop') `
                    -WindowStyle Hidden
                Write-AppLog "LocalWebEngine stop requested" "Info"
                if ($null -ne $script:_EngineStatusLabel) { $script:_EngineStatusLabel.Text = 'Engine: stopped' ; $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::Gray }
            } catch { Write-AppLog "Failed to stop engine: $_" "Error" }
        }
    })
    $servicesMenu.DropDownItems.Add($stopEngineItem) | Out-Null

    $servicesMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $openHubItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openHubItem.Text = "Open &Workspace Hub"
    $openHubItem.Add_Click({
        Write-AppLog "User selected Tools > Script Services > Open Workspace Hub" "Audit"
        try {
            Start-Process 'http://127.0.0.1:8042/'
        } catch {
            Write-AppLog "Failed to open hub browser: $_" "Warning"
        }
    })
    $servicesMenu.DropDownItems.Add($openHubItem) | Out-Null

    $openMcpConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openMcpConfigItem.Text = "MCP Service &Config"
    $openMcpConfigItem.Add_Click({
        Write-AppLog "User selected Tools > Script Services > MCP Service Config" "Audit"
        $mcpHref = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\XHTML-MCPServiceConfig.xhtml'
        if (Test-Path -LiteralPath $mcpHref) { Start-Process $mcpHref } else {
            [System.Windows.Forms.MessageBox]::Show("MCP config page not found:`n$mcpHref","Script Services",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $servicesMenu.DropDownItems.Add($openMcpConfigItem) | Out-Null

    $toolsMenu.DropDownItems.Add($servicesMenu) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $depMatrixItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $depMatrixItem.Text = "Script &Dependency Matrix"
    $depMatrixItem.Add_Click({
        Write-AppLog "User selected Tools > Script Dependency Matrix" "Audit"

        $matrixScript = Join-Path $PSScriptRoot 'scripts\Invoke-ScriptDependencyMatrix.ps1'
        if (-not (Test-Path $matrixScript)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Matrix generator not found:`n$matrixScript",
                "Dependency Matrix",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Script Dependency Matrix'
        $dlg.Size = New-Object System.Drawing.Size(780, 600)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'Sizable'
        $dlg.MinimumSize = New-Object System.Drawing.Size(520, 380)

        $statusLabel = New-Object System.Windows.Forms.Label
        $statusLabel.Dock = 'Top'
        $statusLabel.Height = 24
        $statusLabel.Text = 'Ready -- click Generate to scan workspace dependencies.'
        $statusLabel.Padding = New-Object System.Windows.Forms.Padding(4,4,4,0)
        $dlg.Controls.Add($statusLabel)

        $progressPanel = New-Object System.Windows.Forms.Panel
        $progressPanel.Dock = 'Top'
        $progressPanel.Height = 28
        $dlg.Controls.Add($progressPanel)

        $progressBar = New-Object System.Windows.Forms.ProgressBar
        $progressBar.Location = New-Object System.Drawing.Point(6, 4)
        $progressBar.Size = New-Object System.Drawing.Size(560, 18)
        $progressBar.Minimum = 0
        $progressBar.Maximum = 100
        $progressPanel.Controls.Add($progressBar)

        $progressLabel = New-Object System.Windows.Forms.Label
        $progressLabel.Location = New-Object System.Drawing.Point(575, 5)
        $progressLabel.Size = New-Object System.Drawing.Size(180, 18)
        $progressLabel.Text = '0%'
        $progressPanel.Controls.Add($progressLabel)

        $setProgressUi = {
            param([int]$p)
            $p2 = [Math]::Max(0, [Math]::Min(100, $p))
            $progressBar.Value = $p2
            $progressLabel.Text = "$p2%"
            if ($p2 -lt 35) {
                $progressLabel.ForeColor = [System.Drawing.Color]::OrangeRed
            } elseif ($p2 -lt 70) {
                $progressLabel.ForeColor = [System.Drawing.Color]::Goldenrod
            } else {
                $progressLabel.ForeColor = [System.Drawing.Color]::LimeGreen
            }
        }

        $resultsBox = New-Object System.Windows.Forms.RichTextBox
        $resultsBox.Dock = 'Fill'
        $resultsBox.ReadOnly = $true
        $resultsBox.Font = New-Object System.Drawing.Font('Consolas', 9)
        $resultsBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $resultsBox.ForeColor = [System.Drawing.Color]::White
        $resultsBox.WordWrap = $false
        $dlg.Controls.Add($resultsBox)

        $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.Dock = 'Bottom'
        $btnPanel.Height = 42
        $btnPanel.FlowDirection = 'RightToLeft'
        $btnPanel.Padding = New-Object System.Windows.Forms.Padding(4)

        $closeBtn2 = New-Object System.Windows.Forms.Button
        $closeBtn2.Text = 'Close'
        $closeBtn2.Width = 90
        $closeBtn2.Add_Click({ $dlg.Close() })
        $btnPanel.Controls.Add($closeBtn2)

        $openVizBtn = New-Object System.Windows.Forms.Button
        $openVizBtn.Text = 'Open Visualisation'
        $openVizBtn.Width = 130
        $openVizBtn.Enabled = $false
        $btnPanel.Controls.Add($openVizBtn)

        $openReportBtn = New-Object System.Windows.Forms.Button
        $openReportBtn.Text = 'Open Report'
        $openReportBtn.Width = 110
        $openReportBtn.Enabled = $false
        $btnPanel.Controls.Add($openReportBtn)

        $generateBtn = New-Object System.Windows.Forms.Button
        $generateBtn.Text = 'Generate'
        $generateBtn.Width = 90
        $btnPanel.Controls.Add($generateBtn)

        $dlg.Controls.Add($btnPanel)

        $generateBtn.Add_Click({
            $resultsBox.Clear()
            $statusLabel.Text = 'Scanning workspace -- this may take a moment...'
            & $setProgressUi 10
            $dlg.Refresh()
            $openVizBtn.Enabled = $false
            $openReportBtn.Enabled = $false

            try {
                Write-AppLog "Running dependency matrix generator" "Info"
                $output = & $matrixScript -WorkspacePath $PSScriptRoot -ReportPath (Join-Path $PSScriptRoot '~REPORTS') 2>&1 | Out-String
                & $setProgressUi 80
                $resultsBox.Text = $output

                $vizMatch = [regex]::Match($output, 'Visualisation (?:HTML|XHTML):\s*(.+\.(?:html|xhtml))')
                if (-not $vizMatch.Success) {
                    $vizMatch = [regex]::Match($output, 'Visualisation Canonical XHTML:\s*(.+\.xhtml)')
                }
                $mdMatch = [regex]::Match($output, 'Matrix Markdown:\s*(.+\.md)')

                if ($vizMatch.Success -and (Test-Path $vizMatch.Groups[1].Value.Trim())) {
                    $openVizBtn.Tag = $vizMatch.Groups[1].Value.Trim()
                    $openVizBtn.Enabled = $true
                }
                if ($mdMatch.Success -and (Test-Path $mdMatch.Groups[1].Value.Trim())) {
                    $openReportBtn.Tag = $mdMatch.Groups[1].Value.Trim()
                    $openReportBtn.Enabled = $true
                }

                $edgeMatch = [regex]::Match($output, 'Edges:\s*(\d+)')
                $moduleMatch = [regex]::Match($output, 'Distinct modules:\s*(\d+)')
                $statusLabel.Text = ('Scan complete -- Edges: {0}  |  Modules: {1}' -f $(if($edgeMatch.Success){$edgeMatch.Groups[1].Value}else{'?'}), $(if($moduleMatch.Success){$moduleMatch.Groups[1].Value}else{'?'}))
                & $setProgressUi 100

                Write-AppLog "Dependency matrix generation complete" "Info"
            } catch {
                $resultsBox.Text = "Error: $($_.Exception.Message)"
                $statusLabel.Text = 'Generation failed'
                & $setProgressUi 0
                Write-AppLog "Dependency matrix error: $($_.Exception.Message)" "Error"
            }
        })

        $openVizBtn.Add_Click({
            if ($openVizBtn.Tag -and (Test-Path $openVizBtn.Tag)) {
                Write-AppLog "Opening dependency visualisation: $($openVizBtn.Tag)" "Audit"
                Start-Process $openVizBtn.Tag
            }
        })

        $openReportBtn.Add_Click({
            if ($openReportBtn.Tag -and (Test-Path $openReportBtn.Tag)) {
                Write-AppLog "Opening dependency report: $($openReportBtn.Tag)" "Audit"
                Invoke-Item $openReportBtn.Tag
            }
        })

        # ── Cross-launch: open Module Dependency Check from Script Matrix ──
        $modCheckBtn = New-Object System.Windows.Forms.Button
        $modCheckBtn.Text = 'Module Check \u21E8'
        $modCheckBtn.Width = 120
        $modCheckBtn.Add_Click({
            Write-AppLog "Cross-launch: Script Matrix -> Module Dependency Check" "Audit"
            $dlg.Close()
            $moduleCheckItem.PerformClick()
        })
        $btnPanel.Controls.Add($modCheckBtn)

        $dlg.ShowDialog($form) | Out-Null
        $dlg.Dispose()
    })
    $toolsMenu.DropDownItems.Add($depMatrixItem) | Out-Null

    $moduleCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $moduleCheckItem.Text = "Module &Management"
    $moduleCheckItem.Add_Click({
        Write-AppLog "User selected Tools > Module Management" "Audit"

        $moduleScript = Join-Path $PSScriptRoot 'scripts\Invoke-ModuleManagement.ps1'
        if (-not (Test-Path $moduleScript)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Module management script not found:`n$moduleScript",
                "Module Management",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # --- build results dialog ---
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Module Management'
        $dlg.Size = New-Object System.Drawing.Size(820, 620)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'Sizable'
        $dlg.MinimumSize = New-Object System.Drawing.Size(560, 400)

        $statusLabel = New-Object System.Windows.Forms.Label
        $statusLabel.Dock = 'Top'
        $statusLabel.Height = 24
        $statusLabel.Text = 'Scanning modules...'
        $statusLabel.Padding = New-Object System.Windows.Forms.Padding(4,4,4,0)
        $dlg.Controls.Add($statusLabel)

        $progressPanel = New-Object System.Windows.Forms.Panel
        $progressPanel.Dock = 'Top'
        $progressPanel.Height = 28
        $dlg.Controls.Add($progressPanel)

        $progressBar = New-Object System.Windows.Forms.ProgressBar
        $progressBar.Location = New-Object System.Drawing.Point(6, 4)
        $progressBar.Size = New-Object System.Drawing.Size(560, 18)
        $progressBar.Minimum = 0
        $progressBar.Maximum = 100
        $progressPanel.Controls.Add($progressBar)

        $progressLabel = New-Object System.Windows.Forms.Label
        $progressLabel.Location = New-Object System.Drawing.Point(575, 5)
        $progressLabel.Size = New-Object System.Drawing.Size(180, 18)
        $progressLabel.Text = '0%'
        $progressPanel.Controls.Add($progressLabel)

        $setProgressUi = {
            param([int]$p)
            $p2 = [Math]::Max(0, [Math]::Min(100, $p))
            $progressBar.Value = $p2
            $progressLabel.Text = "$p2%"
            if ($p2 -lt 35) {
                $progressLabel.ForeColor = [System.Drawing.Color]::OrangeRed
            } elseif ($p2 -lt 70) {
                $progressLabel.ForeColor = [System.Drawing.Color]::Goldenrod
            } else {
                $progressLabel.ForeColor = [System.Drawing.Color]::LimeGreen
            }
        }

        $resultsBox = New-Object System.Windows.Forms.RichTextBox
        $resultsBox.Dock = 'Fill'
        $resultsBox.ReadOnly = $true
        $resultsBox.Font = New-Object System.Drawing.Font('Consolas', 9)
        $resultsBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $resultsBox.ForeColor = [System.Drawing.Color]::White
        $resultsBox.WordWrap = $false
        $dlg.Controls.Add($resultsBox)

        $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttonPanel.Dock = 'Bottom'
        $buttonPanel.Height = 42
        $buttonPanel.FlowDirection = 'RightToLeft'
        $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(4)

        $closeBtn = New-Object System.Windows.Forms.Button
        $closeBtn.Text = 'Close'
        $closeBtn.Width = 90
        $closeBtn.Add_Click({ $dlg.Close() })
        $buttonPanel.Controls.Add($closeBtn)

        $installBtn = New-Object System.Windows.Forms.Button
        $installBtn.Text = 'Install Missing'
        $installBtn.Width = 120
        $installBtn.Enabled = $false
        $buttonPanel.Controls.Add($installBtn)

        $workspaceBtn = New-Object System.Windows.Forms.Button
        $workspaceBtn.Text = 'Use Workspace'
        $workspaceBtn.Width = 120
        $workspaceBtn.Enabled = $false
        $buttonPanel.Controls.Add($workspaceBtn)

        $refreshBtn = New-Object System.Windows.Forms.Button
        $refreshBtn.Text = 'Refresh'
        $refreshBtn.Width = 90
        $buttonPanel.Controls.Add($refreshBtn)

        $exportInstallerBtn = New-Object System.Windows.Forms.Button
        $exportInstallerBtn.Text = 'Export Installer'
        $exportInstallerBtn.Width = 120
        $exportInstallerBtn.Enabled = $false
        $buttonPanel.Controls.Add($exportInstallerBtn)

        $exportInventoryBtn = New-Object System.Windows.Forms.Button
        $exportInventoryBtn.Text = 'Export Inventory'
        $exportInventoryBtn.Width = 120
        $buttonPanel.Controls.Add($exportInventoryBtn)

        $dlg.Controls.Add($buttonPanel)

        # helper: run module management and populate results box
        $runModMgmt = {
            param([hashtable]$Params)
            $resultsBox.Clear()
            $statusLabel.Text = 'Scanning modules...'
            & $setProgressUi 10
            $dlg.Refresh()

            try {
                $splatParams = @{
                    WorkspacePath = $PSScriptRoot
                    ReportPath    = (Join-Path $PSScriptRoot '~REPORTS')
                }
                if ($Params) {
                    foreach ($k in $Params.Keys) { $splatParams[$k] = $Params[$k] }
                }
                $output = & $moduleScript @splatParams *>&1 | Out-String
                $resultsBox.Text = $output
                & $setProgressUi 80

                $instMatch = [regex]::Match($output, 'Installed:\s*(\d+)')
                $missMatch = [regex]::Match($output, 'Missing:\s*(\d+)')
                $errMatch  = [regex]::Match($output, 'Errors:\s*(\d+)')
                $inst = if ($instMatch.Success) { $instMatch.Groups[1].Value } else { '?' }
                $miss = if ($missMatch.Success) { $missMatch.Groups[1].Value } else { '?' }
                $errs = if ($errMatch.Success)  { $errMatch.Groups[1].Value }  else { '?' }
                $statusLabel.Text = "Installed: $inst  |  Missing: $miss  |  Errors: $errs"
                & $setProgressUi 100

                $installBtn.Enabled    = ($miss -ne '0' -and $miss -ne '?')
                $workspaceBtn.Enabled  = ($miss -ne '0' -and $miss -ne '?')
                $exportInstallerBtn.Enabled = ($miss -ne '0' -and $miss -ne '?')

                Write-AppLog "Module scan: Installed=$inst, Missing=$miss, Errors=$errs" "Info"
            } catch {
                $resultsBox.Text = "Error: $($_.Exception.Message)"
                $statusLabel.Text = 'Scan failed'
                & $setProgressUi 0
                Write-AppLog "Module management error: $($_.Exception.Message)" "Error"
            }
        }

        $refreshBtn.Add_Click({ & $runModMgmt @{} })

        $installBtn.Add_Click({
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Install missing public modules (CurrentUser scope)?`n`nThis will try LOCAL first, then PSGallery as a fallback.",
                "Confirm Install",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($confirm -eq 'Yes') {
                Write-AppLog "User confirmed auto-install missing modules" "Audit"
                & $runModMgmt @{ AutoInstallMissing = $true }
            }
        })

        $workspaceBtn.Add_Click({
            Write-AppLog "User selected Use Workspace Modules" "Audit"
            & $runModMgmt @{ AutoInstallMissing = $true; UseWorkspaceModules = $true }
        })

        $exportInstallerBtn.Add_Click({
            Write-AppLog "User selected Export Installer" "Audit"
            $statusLabel.Text = 'Generating installer script...'
            $dlg.Refresh()
            & $runModMgmt @{ ExportInstaller = $true }
        })

        $exportInventoryBtn.Add_Click({
            Write-AppLog "User selected Export Inventory" "Audit"
            $statusLabel.Text = 'Exporting module inventory...'
            $dlg.Refresh()
            & $runModMgmt @{ ExportInventory = $true }
        })

        # initial scan on dialog open
        $dlg.Add_Shown({ & $runModMgmt @{} })

        $dlg.ShowDialog($form) | Out-Null
        $dlg.Dispose()
    })
    $toolsMenu.DropDownItems.Add($moduleCheckItem) | Out-Null

    $envScannerItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $envScannerItem.Text = "PS &Environment Scanner"
    $envScannerItem.Add_Click({
        Write-AppLog "User selected Tools > PS Environment Scanner" "Audit"
        [void](Invoke-MenuScriptSafely -MenuLabel 'Environment Scanner' -RelativeCandidates @(
            'scripts\Invoke-PSEnvironmentScanner.ps1'
        ) -ScriptArguments @{ AutoScan = $true })
    })
    $toolsMenu.DropDownItems.Add($envScannerItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $upmItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $upmItem.Text = "&User Profile Manager"
    $upmItem.Add_Click({
        Write-AppLog "User selected Tools > User Profile Manager" "Audit"
        [void](Invoke-MenuScriptSafely -MenuLabel 'User Profile Manager' -RelativeCandidates @(
            'UPM\UserProfile-Manager.ps1',
            'scripts\UserProfile-Manager.ps1'
        ) -UseNewProcess)
    })
    $toolsMenu.DropDownItems.Add($upmItem) | Out-Null

    $eventLogItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $eventLogItem.Text = "Event Log &Viewer"
    $eventLogItem.Add_Click({
        Write-AppLog "User selected Tools > Event Log Viewer" "Audit"
        Invoke-MenuScriptSafely -MenuLabel 'Event Log Viewer' -RelativeCandidates @(
            'scripts\Show-EventLogViewer.ps1'
        )
    })
    $toolsMenu.DropDownItems.Add($eventLogItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── Scan Dashboard ─────────────────────────────────────────────────────
    $scanDashItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $scanDashItem.Text = "Scan &Dashboard..."
    $scanDashItem.Add_Click({
        Write-AppLog "User selected Tools > Scan Dashboard" "Audit"
        $dashScript = Join-Path $scriptsDir 'Show-ScanDashboard.ps1'
        if (Test-Path $dashScript) {
            try {
                . $dashScript
                Show-ScanDashboard
            } catch {
                Write-AppLog "Scan Dashboard error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch Scan Dashboard:`n$($_.Exception.Message)",
                    "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Show-ScanDashboard.ps1 not found in scripts.", "Missing Script",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $toolsMenu.DropDownItems.Add($scanDashItem) | Out-Null

    # ── WinRemote PS Tool ──────────────────────────────────────────────────
    $winRemoteItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $winRemoteItem.Text = "Win&Remote PS Tool"
    $winRemoteItem.Add_Click({
        Write-AppLog "User selected Tools > WinRemote PS Tool" "Audit"
        Invoke-MenuScriptSafely -MenuLabel 'WinRemote PS Tool' `
            -RelativeCandidates @('scripts\WinRemote-PSTool.ps1') -UseNewProcess
    })
    $toolsMenu.DropDownItems.Add($winRemoteItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── Cron-Ai-Athon Tool ─────────────────────────────────────────────────
    $cronAiAthonItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $cronAiAthonItem.Text = "Cron-Ai-Athon &Tool"
    $cronAiAthonItem.Add_Click({
        Write-AppLog "User selected Tools > Cron-Ai-Athon Tool" "Audit"
        $cronScript = Join-Path $PSScriptRoot 'scripts\Show-CronAiAthonTool.ps1'
        if (Test-Path $cronScript) {
            try {
                . $cronScript
                Show-CronAiAthonTool -WorkspacePath $PSScriptRoot
            } catch {
                Write-AppLog "Cron-Ai-Athon Tool error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch Cron-Ai-Athon Tool:`n$($_.Exception.Message)",
                    "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Show-CronAiAthonTool.ps1 not found in scripts.", "Missing Script",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $toolsMenu.DropDownItems.Add($cronAiAthonItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── MCP Service Config ─────────────────────────────────────────────────
    $mcpConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $mcpConfigItem.Text = "&MCP Service Config"
    $mcpConfigItem.Add_Click({
        Write-AppLog "User selected Tools > MCP Service Config" "Audit"
        $mcpScript = Join-Path $PSScriptRoot 'scripts\Show-MCPServiceConfig.ps1'
        if (Test-Path $mcpScript) {
            try {
                . $mcpScript
                Show-MCPServiceConfig
            } catch {
                Write-AppLog "MCP Service Config error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch MCP Service Config:`n$($_.Exception.Message)",
                    "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Show-MCPServiceConfig.ps1 not found in scripts.", "Missing Script",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $toolsMenu.DropDownItems.Add($mcpConfigItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── Interactive Sandbox Test Tool ──────────────────────────────────────
    $sandboxTestItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $sandboxTestItem.Text = "Interactive &Sandbox Test"
    $sandboxTestItem.Add_Click({
        Write-AppLog "User selected Tools > Interactive Sandbox Test" "Audit"
        $sandboxScript = Join-Path $PSScriptRoot 'scripts\Show-SandboxTestTool.ps1'
        if (Test-Path $sandboxScript) {
            try {
                . $sandboxScript
                Show-SandboxTestTool -WorkspacePath $PSScriptRoot
            } catch {
                Write-AppLog "Sandbox Test Tool error: $($_.Exception.Message)" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to launch Interactive Sandbox Test Tool:`n$($_.Exception.Message)",
                    "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Show-SandboxTestTool.ps1 not found in scripts.", "Missing Script",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $toolsMenu.DropDownItems.Add($sandboxTestItem) | Out-Null

    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # ── XHTML Reports submenu ──────────────────────────────────────────────
    $xhtmlSubMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $xhtmlSubMenu.Text = "X&HTML Reports"

    $xhtmlCodeAnalysisItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $xhtmlCodeAnalysisItem.Text = "Code &Analysis"
    $xhtmlCodeAnalysisItem.Add_Click({
        Write-AppLog "User selected Tools > XHTML Reports > Code Analysis" "Audit"
        $xhtmlPath = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\XHTML-code-analysis.xhtml'
        [void](Open-MenuPathSafely -MenuLabel 'XHTML Code Analysis' -PathToOpen $xhtmlPath)
    })
    $xhtmlSubMenu.DropDownItems.Add($xhtmlCodeAnalysisItem) | Out-Null

    $xhtmlFeatureReqItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $xhtmlFeatureReqItem.Text = "&Feature Requests"
    $xhtmlFeatureReqItem.Add_Click({
        Write-AppLog "User selected Tools > XHTML Reports > Feature Requests" "Audit"
        $xhtmlPath = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml'
        [void](Open-MenuPathSafely -MenuLabel 'XHTML Feature Requests' -PathToOpen $xhtmlPath)
    })
    $xhtmlSubMenu.DropDownItems.Add($xhtmlFeatureReqItem) | Out-Null

    $xhtmlMCPConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $xhtmlMCPConfigItem.Text = "MCP Service &Config"
    $xhtmlMCPConfigItem.Add_Click({
        Write-AppLog "User selected Tools > XHTML Reports > MCP Service Config" "Audit"
        $xhtmlPath = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\XHTML-MCPServiceConfig.xhtml'
        [void](Open-MenuPathSafely -MenuLabel 'XHTML MCP Service Config' -PathToOpen $xhtmlPath)
    })
    $xhtmlSubMenu.DropDownItems.Add($xhtmlMCPConfigItem) | Out-Null

    $xhtmlMasterToDoItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $xhtmlMasterToDoItem.Text = "Central Master &To-Do"
    $xhtmlMasterToDoItem.Add_Click({
        Write-AppLog "User selected Tools > XHTML Reports > Central Master To-Do" "Audit"
        $xhtmlPath = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\XHTML-MasterToDo.xhtml'
        [void](Open-MenuPathSafely -MenuLabel 'Central Master To-Do' -PathToOpen $xhtmlPath)
    })
    $xhtmlSubMenu.DropDownItems.Add($xhtmlMasterToDoItem) | Out-Null

    $toolsMenu.DropDownItems.Add($xhtmlSubMenu) | Out-Null

    # ── Startup Shortcut ──
    $startupShortcutItem = New-Object System.Windows.Forms.ToolStripMenuItem("Create Startup Shortcut...")
    $startupShortcutItem.Add_Click({
        Write-AppLog "User selected Tools > Create Startup Shortcut" "Audit"
        Show-StartupShortcutForm -Owner $form
    })
    $toolsMenu.DropDownItems.Add($startupShortcutItem) | Out-Null

    # ── Remote Build Config ──
    $remoteBuildItem = New-Object System.Windows.Forms.ToolStripMenuItem("Remote Build Path Config...")
    $remoteBuildItem.Add_Click({
        Write-AppLog "User selected Tools > Remote Build Path Config" "Audit"
        Show-RemoteBuildConfigForm -Owner $form
    })
    $toolsMenu.DropDownItems.Add($remoteBuildItem) | Out-Null

    $menuStrip.Items.Add($toolsMenu) | Out-Null
    
    # ==================== SECURITY MENU ====================
    # Helper: Check if running as admin
    function Test-IsElevated {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Helper: Prompt for elevation confirmation -- returns $true to proceed
    function Request-ElevationConfirmation {
        param([string]$OperationName = 'This operation')
        if (Test-IsElevated) { return $true }  # Already elevated
        $msg = "$OperationName may require Administrator privileges.`n`nThe application is not currently running elevated.`nSome operations may fail without admin rights.`n`nContinue anyway?"
        $result = [System.Windows.Forms.MessageBox]::Show($msg, "Elevation Advisory",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Shield)
        return ($result -eq 'Yes')
    }

    function Write-SecurityErrorAdvice {
        param(
            [string]$Operation,
            [System.Exception]$ExceptionObject
        )
        $msg = if ($ExceptionObject) { $ExceptionObject.Message } else { 'Unknown error' }
        $isAdvisory = $msg -match '(?i)integrity|not initialised|not initialized|vault is not unlocked|integritywarning'
        if ($isAdvisory) {
            Write-AppLog "Security issue noted [$Operation]: $msg" "Warning"
        } else {
            Write-AppLog "Security action failed [$Operation]: $msg" "Error"
        }
        if ($script:ExtendedSecurityLogging -and $ExceptionObject -and $ExceptionObject.StackTrace) {
            Write-AppLog "Security extended stack [$Operation]: $($ExceptionObject.StackTrace)" "Debug"
        }
        $title = if ($isAdvisory) { 'Security Advisory' } else { 'Security Operation Error' }
        $bodyPrefix = if ($isAdvisory) { "$Operation reported an issue." } else { "$Operation failed." }
        [System.Windows.Forms.MessageBox]::Show(
            "$bodyPrefix`n`nDetail: $msg`n`nGuidance:`n1. Verify Bitwarden CLI and SASC modules are available.`n2. Re-open Security > Security Checklist and fix items marked ! or ?.`n3. If this follows a crash, review logs for extended diagnostics.",
            $title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }

    function Get-SecurityChecklistRows {
        $rows = New-Object System.Collections.Generic.List[object]

        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentUser = if ($currentIdentity -and $currentIdentity.Name) { $currentIdentity.Name } else { "$env:USERDOMAIN\\$env:USERNAME" }
        $elevated = Test-IsElevated
        $runAsProfile = "$currentUser | Elevated=$elevated | Profile=$env:USERPROFILE"

        $assistedSascModulePath = Get-ProjectPath SascModule
        $sascAdaptersModulePath = Get-ProjectPath SascAdapters
        $invokeSecretsPagePath = Join-Path $scriptDir 'XHTML-invoke-secrets.xhtml'
        $configPath = Get-ProjectPath SascConfig
        $cfg = $null

        $moduleStatus = [ordered]@{
            AssistedSASC = if (-not [string]::IsNullOrWhiteSpace($assistedSascModulePath) -and (Test-Path $assistedSascModulePath)) {
                if (Get-Command Show-AssistedSASCDialog -ErrorAction SilentlyContinue) { 'loaded' } else { 'file present (not loaded)' }
            } else { if ([string]::IsNullOrWhiteSpace($assistedSascModulePath)) { 'path unavailable' } else { 'missing' } }
            'SASC-Adapters' = if (-not [string]::IsNullOrWhiteSpace($sascAdaptersModulePath) -and (Test-Path $sascAdaptersModulePath)) {
                if (Get-Module SASC-Adapters -ErrorAction SilentlyContinue) { 'loaded' } else { 'file present (not loaded)' }
            } else { if ([string]::IsNullOrWhiteSpace($sascAdaptersModulePath)) { 'path unavailable' } else { 'missing' } }
        }

        foreach ($entry in $moduleStatus.GetEnumerator()) {
            $modulePath = if ($entry.Key -eq 'AssistedSASC') { $assistedSascModulePath } else { $sascAdaptersModulePath }
            $moduleState = if ($entry.Value -eq 'loaded') { '✓' } elseif ($entry.Value -like 'file present*') { '!' } else { '✗' }
            $rows.Add([pscustomobject]@{
                Option = "Module Status: $($entry.Key)"
                State = $moduleState
                Action = 'Provide Security menu command implementations'
                CheckedPath = $modulePath
                RunAsProfile = $runAsProfile
                ModuleStatus = $entry.Value
                Detail = "Module=$($entry.Key); Status=$($entry.Value)"
                Guidance = 'Ensure security modules exist and import successfully before using Security menu actions.'
            }) | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path $configPath)) {
            try {
                $cfg = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
            } catch {
                $rows.Add([pscustomobject]@{
                    Option = 'Security Checklist'
                    State = '!'
                    Action = 'Parse security config'
                    CheckedPath = $configPath
                    RunAsProfile = $runAsProfile
                    ModuleStatus = $moduleStatus.AssistedSASC
                    Detail = 'sasc-vault-config.json exists but is invalid JSON'
                    Guidance = 'Fix JSON syntax in config\sasc-vault-config.json.'
                }) | Out-Null
            }
        } else {
            $rows.Add([pscustomobject]@{
                Option = 'Security Checklist'
                State = '?'
                Action = 'Load security config'
                CheckedPath = $configPath
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = 'sasc-vault-config.json is missing'
                Guidance = 'Create config\sasc-vault-config.json to initialize security settings.'
            }) | Out-Null
        }

        $integrityPath = $null
        $backupPath = $null
        if ($cfg) {
            if ($cfg.IntegrityManifestPath) {
                $integrityPath = Join-Path $scriptDir ([string]$cfg.IntegrityManifestPath -replace '/', '\\')
            }
            if ($cfg.VaultBackupPath) {
                $backupPath = Join-Path $scriptDir ([string]$cfg.VaultBackupPath -replace '/', '\\')
            }
        }

        $securityActionRows = @(
            [pscustomobject]@{
                Option='Assisted SASC Wizard';
                Action='Launch setup and hardening wizard';
                Command='Show-AssistedSASCDialog';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='Vault Status';
                Action='Show vault state, lockout, and LAN status';
                Command='Show-VaultStatusDialog';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='Unlock Vault';
                Action='Prompt user and unlock vault session';
                Command='Show-VaultUnlockDialog';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='Lock Vault';
                Action='Clear session and lock vault';
                Command='Lock-Vault';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='Import Secrets';
                Action='Import secret data into vault';
                Command='Import-VaultSecrets';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='Prompted'
            },
            [pscustomobject]@{
                Option='Import Certificates';
                Action='Import certificate material for protected workflows';
                Command='Import-Certificates';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='Prompted'
            },
            [pscustomobject]@{
                Option='Vault Security Audit';
                Action='Run security checks and score';
                Command='Test-VaultSecurity';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='Prompted'
            },
            [pscustomobject]@{
                Option='Integrity Verification';
                Action='Validate integrity manifest and signatures';
                Command='Test-IntegrityManifest';
                CheckedPath=$(if ($integrityPath) { $integrityPath } else { $configPath });
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='LAN Vault Sharing';
                Action='View/toggle LAN vault sharing service';
                Command='Get-VaultLANStatus, Set-VaultLANSharing';
                CheckedPath=$assistedSascModulePath;
                Module='AssistedSASC';
                RequiresAdmin='For enable'
            },
            [pscustomobject]@{
                Option='Windows Hello Setup';
                Action='Configure Windows Hello for unlock';
                Command='Enable-WindowsHello';
                CheckedPath=$configPath;
                Module='AssistedSASC';
                RequiresAdmin='Prompted'
            },
            [pscustomobject]@{
                Option='Invoke Secrets Page';
                Action='Open embedded/fallback secrets page';
                Command='Show-SecretsInvokerForm';
                CheckedPath=$invokeSecretsPagePath;
                Module='AssistedSASC';
                RequiresAdmin='No'
            },
            [pscustomobject]@{
                Option='Export Vault Backup';
                Action='Export encrypted vault backup file';
                Command='Export-VaultBackup';
                CheckedPath=$(if ($backupPath) { $backupPath } else { Join-Path $pkiDir 'vault-backups' });
                Module='AssistedSASC';
                RequiresAdmin='Prompted'
            }
        )

        foreach ($opt in $securityActionRows) {
            $cmdAvailable = if ($opt.Command -match ',') {
                $parts = $opt.Command -split '\s*,\s*'
                @($parts | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }).Count -eq $parts.Count
            } else {
                [bool](Get-Command $opt.Command -ErrorAction SilentlyContinue)
            }
            $pathOk = if ($opt.CheckedPath) { Test-Path -LiteralPath $opt.CheckedPath } else { $false }
            $moduleState = if ($moduleStatus.Contains($opt.Module)) { $moduleStatus[$opt.Module] } else { 'unknown' }
            $state = if ($cmdAvailable -and $pathOk) { '✓' } elseif ($cmdAvailable -or $pathOk) { '!' } else { '✗' }

            $rows.Add([pscustomobject]@{
                Option = $opt.Option
                State = $state
                Action = $opt.Action
                CheckedPath = [string]$opt.CheckedPath
                RunAsProfile = "$runAsProfile | ElevationRequirement=$($opt.RequiresAdmin)"
                ModuleStatus = "$($opt.Module): $moduleState"
                Detail = "Command=$($opt.Command); PathExists=$pathOk; CommandAvailable=$cmdAvailable"
                Guidance = 'If command/path is missing, reinstall dependencies and reload security modules from this session.'
            }) | Out-Null
        }

        if ($cfg) {
            $rows.Add([pscustomobject]@{
                Option = 'Config: Windows Hello'
                State = if ($cfg.WindowsHelloEnabled -eq $true) { '✓' } else { '!' }
                Action = 'Read Windows Hello setting'
                CheckedPath = $configPath
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = "WindowsHelloEnabled=$($cfg.WindowsHelloEnabled)"
                Guidance = 'Enable Windows Hello and configure key protection for local unlock.'
            }) | Out-Null

            $rows.Add([pscustomobject]@{
                Option = 'Config: Integrity manifest'
                State = if ($cfg.IntegrityManifestPath -and (Test-Path $integrityPath)) { '✓' } else { '!' }
                Action = 'Read integrity manifest setting'
                CheckedPath = if ($integrityPath) { $integrityPath } else { $configPath }
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = "IntegrityManifestPath=$($cfg.IntegrityManifestPath)"
                Guidance = 'Generate/update integrity manifest and keep path valid.'
            }) | Out-Null

            $rows.Add([pscustomobject]@{
                Option = 'Config: Vault backup path'
                State = if ($cfg.VaultBackupEnabled -and $cfg.VaultBackupPath -and (Test-Path $backupPath)) { '✓' } elseif ($cfg.VaultBackupEnabled) { '!' } else { '?' }
                Action = 'Read backup config setting'
                CheckedPath = if ($backupPath) { $backupPath } else { $configPath }
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = "VaultBackupEnabled=$($cfg.VaultBackupEnabled), Path=$($cfg.VaultBackupPath)"
                Guidance = 'Create backup directory and schedule encrypted backup checks.'
            }) | Out-Null

            $rows.Add([pscustomobject]@{
                Option = 'Config: Audit logging'
                State = if ($cfg.AuditLogEnabled -eq $true) { '✓' } else { '!' }
                Action = 'Read audit logging setting'
                CheckedPath = $configPath
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = "AuditLogEnabled=$($cfg.AuditLogEnabled)"
                Guidance = 'Enable audit logging to support incident review and accountability.'
            }) | Out-Null

            $rows.Add([pscustomobject]@{
                Option = 'Config: LAN sharing'
                State = if ($cfg.LANSharePort -ge 1 -and $cfg.LANSharePort -le 65535) { '✓' } else { '!' }
                Action = 'Read LAN sharing setting'
                CheckedPath = $configPath
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = "LANShareEnabled=$($cfg.LANShareEnabled), Port=$($cfg.LANSharePort)"
                Guidance = 'Use an approved port and keep LAN share disabled unless required.'
            }) | Out-Null
        }

        if ($script:LastCrashDetected) {
            $rows.Add([pscustomobject]@{
                Option = 'Runtime: Last boot crash cleanup'
                State = '✗'
                Action = 'Report crash-recovery condition'
                CheckedPath = Join-Path $logsDir 'app-' + (Get-Date -Format 'yyyy-MM-dd') + '.log'
                RunAsProfile = $runAsProfile
                ModuleStatus = $moduleStatus.AssistedSASC
                Detail = 'Crash recovery executed on this startup'
                Guidance = 'Review logs and resolve root cause before relying on security automation.'
            }) | Out-Null
        }

        return $rows.ToArray()
    }

    function Show-SecurityChecklistForm {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Security Checklist'
        $dlg.Size = New-Object System.Drawing.Size(920, 520)
        $dlg.StartPosition = 'CenterParent'

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.AutoSizeColumnsMode = 'AllCells'
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = 'FullRowSelect'

        $rows = Get-SecurityChecklistRows
        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add('Option', [string])
        [void]$dt.Columns.Add('State', [string])
        [void]$dt.Columns.Add('Action', [string])
        [void]$dt.Columns.Add('CheckedPath', [string])
        [void]$dt.Columns.Add('RunAsProfile', [string])
        [void]$dt.Columns.Add('ModuleStatus', [string])
        [void]$dt.Columns.Add('Detail', [string])
        [void]$dt.Columns.Add('Guidance', [string])
        foreach ($r in $rows) {
            $dr = $dt.NewRow()
            $dr['Option'] = $r.Option
            $dr['State'] = $r.State
            $dr['Action'] = $r.Action
            $dr['CheckedPath'] = $r.CheckedPath
            $dr['RunAsProfile'] = $r.RunAsProfile
            $dr['ModuleStatus'] = $r.ModuleStatus
            $dr['Detail'] = $r.Detail
            $dr['Guidance'] = $r.Guidance
            [void]$dt.Rows.Add($dr)
        }
        $grid.DataSource = $dt

        if ($grid.Columns['Guidance']) { $grid.Columns['Guidance'].Visible = $false }
        if ($grid.Columns['CheckedPath']) { $grid.Columns['CheckedPath'].AutoSizeMode = 'Fill' }
        if ($grid.Columns['Detail']) { $grid.Columns['Detail'].AutoSizeMode = 'Fill' }
        if ($grid.Columns['RunAsProfile']) { $grid.Columns['RunAsProfile'].AutoSizeMode = 'Fill' }

        $grid.Add_CellFormatting({
            param($gridSender, $e)
            if ($e.RowIndex -lt 0) { return }
            $row = $gridSender.Rows[$e.RowIndex]
            $state = [string]$row.Cells['State'].Value
            switch ($state) {
                '✓' { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::LimeGreen }
                '!' { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gold }
                '?' { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::LightSkyBlue }
                '✗' { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
            }
            $row.Cells['State'].ToolTipText = [string]$row.Cells['Guidance'].Value
        })

        $dlg.Controls.Add($grid)
        $dlg.ShowDialog($form) | Out-Null
        $dlg.Dispose()
    }

    $securityMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $securityMenu.Text = "&Security"

    $securityChecklistItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $securityChecklistItem.Text = "Security &Checklist..."
    $securityChecklistItem.Add_Click({
        try {
            Show-SecurityChecklistForm
        } catch {
            Write-SecurityErrorAdvice -Operation 'Security Checklist' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($securityChecklistItem) | Out-Null

    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Assisted SASC Wizard
    $sascWizardItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $sascWizardItem.Text = "Assisted SASC &Wizard..."
    $sascWizardItem.Add_Click({
        try {
            if ($script:_SASCAvailable -and (Get-Command Show-AssistedSASCDialog -ErrorAction SilentlyContinue)) {
                Show-AssistedSASCDialog
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "SASC module is not available.`nEnsure AssistedSASC.psm1 is in the modules folder and Bitwarden CLI is installed.",
                    "SASC Not Available", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        } catch {
            Write-SecurityErrorAdvice -Operation 'Assisted SASC Wizard' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($sascWizardItem) | Out-Null

    # Vault Status
    $vaultStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $vaultStatusItem.Text = "Vault &Status..."
    $vaultStatusItem.Add_Click({
        try {
            if (Get-Command Show-VaultStatusDialog -ErrorAction SilentlyContinue) {
                Show-VaultStatusDialog
            } else {
                [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        } catch {
            Write-SecurityErrorAdvice -Operation 'Vault Status' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($vaultStatusItem) | Out-Null

    # Separator
    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Unlock Vault
    $unlockVaultItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $unlockVaultItem.Text = "&Unlock Vault..."
    $unlockVaultItem.Add_Click({
        try {
            if (Get-Command Show-VaultUnlockDialog -ErrorAction SilentlyContinue) {
                $result = Show-VaultUnlockDialog
                if ($result) {
                    Write-AppLog "Vault unlocked via Security menu" "Info"
                    # Immediately refresh vault status indicators
                    $vaultStatusLabel.Text = "Vault: UNLOCKED"
                    $vaultStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
                    $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Green
                    $vaultDetailLabel.Text = "Unlocked via Security menu"
                    $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Green
                }
            }
        } catch {
            Write-SecurityErrorAdvice -Operation 'Unlock Vault' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($unlockVaultItem) | Out-Null

    # Lock Vault
    $lockVaultItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $lockVaultItem.Text = "&Lock Vault"
    $lockVaultItem.Add_Click({
        try {
            if (Get-Command Lock-Vault -ErrorAction SilentlyContinue) {
                Lock-Vault
                Write-AppLog "Vault locked via Security menu" "Info"
                [System.Windows.Forms.MessageBox]::Show("Vault has been locked.", "Vault Locked",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        } catch {
            Write-SecurityErrorAdvice -Operation 'Lock Vault' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($lockVaultItem) | Out-Null

    # ── Vault Operations flyout (enabled only when vault is Unlocked) ──
    $vaultOpsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $vaultOpsItem.Text = "Vault &Operations"

    # Helper: check vault unlocked before each operation
    $testVaultUnlocked = {
        if (Get-Command Test-VaultStatus -ErrorAction SilentlyContinue) {
            $vs = Test-VaultStatus
            return ($vs.State -eq 'Unlocked')
        }
        return $false
    }

    # Enable/disable flyout items dynamically when the menu opens
    $securityMenu.Add_DropDownOpening({
        $isUnlocked = & $testVaultUnlocked
        $vaultOpsItem.Enabled = $isUnlocked
        if ($isUnlocked) {
            $vaultOpsItem.Text = "Vault &Operations  [Unlocked]"
        } else {
            $vaultOpsItem.Text = "Vault &Operations  [Locked]"
        }
    })

    # --- Save Secret ---
    $saveSecretItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $saveSecretItem.Text = "&Save Secret..."
    $saveSecretItem.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.Form
            $dlg.Text = 'Save Secret to Vault'
            $dlg.Size = New-Object System.Drawing.Size(420, 300)
            $dlg.StartPosition = 'CenterParent'
            $dlg.FormBorderStyle = 'FixedDialog'
            $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

            $y = 12
            foreach ($pair in @(@('Name:','txtName'),@('Username:','txtUser'),@('Password:','txtPass'),@('URI:','txtUri'))) {
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.Text = $pair[0]; $lbl.Location = New-Object System.Drawing.Point(12, $y); $lbl.AutoSize = $true  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                $dlg.Controls.Add($lbl)
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Name = $pair[1]; $tb.Location = New-Object System.Drawing.Point(100, ($y - 2)); $tb.Size = New-Object System.Drawing.Size(290, 22)  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                if ($pair[1] -eq 'txtPass') { $tb.UseSystemPasswordChar = $true }  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                $dlg.Controls.Add($tb)
                $y += 32
            }
            $noteBox = New-Object System.Windows.Forms.TextBox
            $noteBox.Name = 'txtNotes'; $noteBox.Multiline = $true
            $noteBox.Location = New-Object System.Drawing.Point(100, $y); $noteBox.Size = New-Object System.Drawing.Size(290, 50)
            $nlbl = New-Object System.Windows.Forms.Label
            $nlbl.Text = 'Notes:'; $nlbl.Location = New-Object System.Drawing.Point(12, $y); $nlbl.AutoSize = $true
            $dlg.Controls.Add($nlbl); $dlg.Controls.Add($noteBox)

            $btnOk = New-Object System.Windows.Forms.Button
            $btnOk.Text = 'Save'; $btnOk.DialogResult = 'OK'
            $btnOk.Location = New-Object System.Drawing.Point(210, 220); $btnOk.Size = New-Object System.Drawing.Size(80, 28)
            $btnCn = New-Object System.Windows.Forms.Button
            $btnCn.Text = 'Cancel'; $btnCn.DialogResult = 'Cancel'
            $btnCn.Location = New-Object System.Drawing.Point(300, 220); $btnCn.Size = New-Object System.Drawing.Size(80, 28)
            $dlg.Controls.AddRange(@($btnOk, $btnCn))
            $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCn

            if ($dlg.ShowDialog() -eq 'OK') {
                $secName = $dlg.Controls['txtName'].Text
                if (-not $secName) { throw 'Secret name is required.' }
                $secPass = $null
                $rawPass = $dlg.Controls['txtPass'].Text
                if ($rawPass) {
                    $secPass = ConvertTo-SecureString -String $rawPass -AsPlainText -Force
                }
                Set-VaultItem -Name $secName -UserName $dlg.Controls['txtUser'].Text `
                    -Password $secPass -Uri @($dlg.Controls['txtUri'].Text) `
                    -Notes $dlg.Controls['txtNotes'].Text -Confirm:$false
                [System.Windows.Forms.MessageBox]::Show("Secret '$secName' saved.", 'Secret Saved',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            $dlg.Dispose()
        } catch {
            Write-SecurityErrorAdvice -Operation 'Save Secret' -ExceptionObject $_.Exception
        }
    })
    $vaultOpsItem.DropDownItems.Add($saveSecretItem) | Out-Null

    # --- Retrieve Secret ---
    $retrieveSecretItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $retrieveSecretItem.Text = "&Retrieve Secret..."
    $retrieveSecretItem.Add_Click({
        try {
            $inputDlg = New-Object System.Windows.Forms.Form
            $inputDlg.Text = 'Retrieve Secret'
            $inputDlg.Size = New-Object System.Drawing.Size(380, 150)
            $inputDlg.StartPosition = 'CenterParent'
            $inputDlg.FormBorderStyle = 'FixedDialog'
            $inputDlg.MaximizeBox = $false; $inputDlg.MinimizeBox = $false
            $inputLbl = New-Object System.Windows.Forms.Label
            $inputLbl.Text = 'Enter secret name or search term:'
            $inputLbl.Location = New-Object System.Drawing.Point(12, 14); $inputLbl.AutoSize = $true
            $inputDlg.Controls.Add($inputLbl)
            $inputTb = New-Object System.Windows.Forms.TextBox
            $inputTb.Location = New-Object System.Drawing.Point(12, 38); $inputTb.Size = New-Object System.Drawing.Size(340, 22)
            $inputDlg.Controls.Add($inputTb)
            $inputOk = New-Object System.Windows.Forms.Button
            $inputOk.Text = 'OK'; $inputOk.DialogResult = 'OK'
            $inputOk.Location = New-Object System.Drawing.Point(190, 74); $inputOk.Size = New-Object System.Drawing.Size(75, 28)
            $inputCn = New-Object System.Windows.Forms.Button
            $inputCn.Text = 'Cancel'; $inputCn.DialogResult = 'Cancel'
            $inputCn.Location = New-Object System.Drawing.Point(275, 74); $inputCn.Size = New-Object System.Drawing.Size(75, 28)
            $inputDlg.Controls.AddRange(@($inputOk, $inputCn))
            $inputDlg.AcceptButton = $inputOk; $inputDlg.CancelButton = $inputCn
            if ($inputDlg.ShowDialog() -ne 'OK') { $inputDlg.Dispose(); return }
            $searchName = $inputTb.Text
            $inputDlg.Dispose()
            if (-not $searchName) { return }
            $item = Get-VaultItem -Name $searchName
            if (-not $item) {
                [System.Windows.Forms.MessageBox]::Show("Secret '$searchName' not found.", 'Not Found',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $msg  = "Name:     $($item.Name)`n"
            $msg += "Username: $($item.UserName)`n"
            $msg += "URI:      $(($item.Uri -join ', '))`n"
            $msg += "Notes:    $($item.Notes)`n`n"
            $msg += "(Password is on the clipboard for 30 seconds.)"
            # Copy password to clipboard securely for 30s
            if ($item.Password) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($item.Password)
                try {
                    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    [System.Windows.Forms.Clipboard]::SetText($plain)
                } finally {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                # Clear clipboard after 30 seconds
                $clipTimer = New-Object System.Windows.Forms.Timer
                $clipTimer.Interval = 30000
                $clipTimer.Add_Tick({
                    [System.Windows.Forms.Clipboard]::Clear()
                    $this.Stop(); $this.Dispose()
                })
                $clipTimer.Start()
            }
            [System.Windows.Forms.MessageBox]::Show($msg, "Secret: $($item.Name)",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            Write-SecurityErrorAdvice -Operation 'Retrieve Secret' -ExceptionObject $_.Exception
        }
    })
    $vaultOpsItem.DropDownItems.Add($retrieveSecretItem) | Out-Null

    # --- Create New Secret ---
    $createSecretItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $createSecretItem.Text = "&Create New Secret..."
    $createSecretItem.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.Form
            $dlg.Text = 'Create New Vault Secret'
            $dlg.Size = New-Object System.Drawing.Size(420, 340)
            $dlg.StartPosition = 'CenterParent'
            $dlg.FormBorderStyle = 'FixedDialog'
            $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

            $y = 12
            foreach ($pair in @(@('Name:','txtName'),@('Username:','txtUser'),@('Password:','txtPass'),@('URI:','txtUri'))) {
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.Text = $pair[0]; $lbl.Location = New-Object System.Drawing.Point(12, $y); $lbl.AutoSize = $true  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                $dlg.Controls.Add($lbl)
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Name = $pair[1]; $tb.Location = New-Object System.Drawing.Point(100, ($y - 2)); $tb.Size = New-Object System.Drawing.Size(290, 22)  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                if ($pair[1] -eq 'txtPass') { $tb.UseSystemPasswordChar = $true }  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                $dlg.Controls.Add($tb)
                $y += 32
            }

            # Generate random password button
            $btnRand = New-Object System.Windows.Forms.Button
            $btnRand.Text = 'Generate Random (15 char)'
            $btnRand.Location = New-Object System.Drawing.Point(100, $y); $btnRand.Size = New-Object System.Drawing.Size(200, 26)
            $btnRand.Add_Click({
                $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789!@#$%^&*_-+='
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                $bytes = [byte[]]::new(15)
                $rng.GetBytes($bytes)
                $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
                $rng.Dispose()
                $dlg.Controls['txtPass'].UseSystemPasswordChar = $false
                $dlg.Controls['txtPass'].Text = $pw
            })
            $dlg.Controls.Add($btnRand)
            $y += 34

            $noteBox = New-Object System.Windows.Forms.TextBox
            $noteBox.Name = 'txtNotes'; $noteBox.Multiline = $true
            $noteBox.Location = New-Object System.Drawing.Point(100, $y); $noteBox.Size = New-Object System.Drawing.Size(290, 50)
            $nlbl = New-Object System.Windows.Forms.Label
            $nlbl.Text = 'Notes:'; $nlbl.Location = New-Object System.Drawing.Point(12, $y); $nlbl.AutoSize = $true
            $dlg.Controls.Add($nlbl); $dlg.Controls.Add($noteBox)

            $btnOk = New-Object System.Windows.Forms.Button
            $btnOk.Text = 'Create'; $btnOk.DialogResult = 'OK'
            $btnOk.Location = New-Object System.Drawing.Point(210, 260); $btnOk.Size = New-Object System.Drawing.Size(80, 28)
            $btnCn = New-Object System.Windows.Forms.Button
            $btnCn.Text = 'Cancel'; $btnCn.DialogResult = 'Cancel'
            $btnCn.Location = New-Object System.Drawing.Point(300, 260); $btnCn.Size = New-Object System.Drawing.Size(80, 28)
            $dlg.Controls.AddRange(@($btnOk, $btnCn))
            $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCn

            if ($dlg.ShowDialog() -eq 'OK') {
                $secName = $dlg.Controls['txtName'].Text
                if (-not $secName) { throw 'Secret name is required.' }
                $secPass = $null
                $rawPass = $dlg.Controls['txtPass'].Text
                if ($rawPass) {
                    $secPass = ConvertTo-SecureString -String $rawPass -AsPlainText -Force
                }
                Set-VaultItem -Name $secName -UserName $dlg.Controls['txtUser'].Text `
                    -Password $secPass -Uri @($dlg.Controls['txtUri'].Text) `
                    -Notes $dlg.Controls['txtNotes'].Text -Confirm:$false
                [System.Windows.Forms.MessageBox]::Show("Secret '$secName' created.", 'Secret Created',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            $dlg.Dispose()
        } catch {
            Write-SecurityErrorAdvice -Operation 'Create New Secret' -ExceptionObject $_.Exception
        }
    })
    $vaultOpsItem.DropDownItems.Add($createSecretItem) | Out-Null

    # --- Propose Secure Random 15-char Password ---
    $randomPwItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $randomPwItem.Text = "&Propose Random Password (15 char)"
    $randomPwItem.Add_Click({
        try {
            $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789!@#$%^&*_-+='
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $bytes = [byte[]]::new(15)
            $rng.GetBytes($bytes)
            $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
            $rng.Dispose()
            [System.Windows.Forms.Clipboard]::SetText($pw)
            # Auto-clear clipboard after 30 seconds
            $clipTimer = New-Object System.Windows.Forms.Timer
            $clipTimer.Interval = 30000
            $clipTimer.Add_Tick({ [System.Windows.Forms.Clipboard]::Clear(); $this.Stop(); $this.Dispose() })
            $clipTimer.Start()
            [System.Windows.Forms.MessageBox]::Show(
                "Generated password:`n`n$pw`n`nCopied to clipboard (auto-clears in 30 seconds).",
                'Secure Random Password',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            Write-SecurityErrorAdvice -Operation 'Generate Random Password' -ExceptionObject $_.Exception
        }
    })
    $vaultOpsItem.DropDownItems.Add($randomPwItem) | Out-Null

    # --- BW-CLI Server (launch bw serve in independent shell) ---
    $vaultOpsItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $bwServeItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $bwServeItem.Text = "BW-CLI &Server..."
    $bwServeItem.ToolTipText = "Launch Bitwarden CLI HTTP API service in an independent shell"
    $bwServeItem.Add_Click({
        try {
            [void](Invoke-MenuScriptSafely -MenuLabel 'BW-CLI Server' `
                -RelativeCandidates @('scripts\Start-BWServe.ps1') `
                -UseNewProcess)
        } catch {
            Write-SecurityErrorAdvice -Operation 'BW-CLI Server' -ExceptionObject $_.Exception
        }
    })
    $vaultOpsItem.DropDownItems.Add($bwServeItem) | Out-Null

    $securityMenu.DropDownItems.Add($vaultOpsItem) | Out-Null

    # Separator
    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Import Secrets
    $importSecretsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $importSecretsItem.Text = "Import &Secrets..."
    $importSecretsItem.Add_Click({
        if (-not (Request-ElevationConfirmation 'Import Secrets')) { return }
        if (Get-Command Import-VaultSecrets -ErrorAction SilentlyContinue) {
            # --- Format picker dialog ---
            $fmtForm = New-Object System.Windows.Forms.Form
            $fmtForm.Text = 'Select Import Format'
            $fmtForm.Size = New-Object System.Drawing.Size(340, 200)
            $fmtForm.StartPosition = 'CenterParent'
            $fmtForm.FormBorderStyle = 'FixedDialog'
            $fmtForm.MaximizeBox = $false
            $fmtForm.MinimizeBox = $false
            $fmtLbl = New-Object System.Windows.Forms.Label
            $fmtLbl.Text = 'Source format:'
            $fmtLbl.Location = New-Object System.Drawing.Point(12, 16)
            $fmtLbl.AutoSize = $true
            $fmtForm.Controls.Add($fmtLbl)
            $fmtCombo = New-Object System.Windows.Forms.ComboBox
            $fmtCombo.DropDownStyle = 'DropDownList'
            $fmtCombo.Location = New-Object System.Drawing.Point(12, 40)
            $fmtCombo.Size = New-Object System.Drawing.Size(300, 24)
            @('bitwardencsv','bitwardenjson','lastpasscsv','1passwordcsv','keepass2xml','chromecsv','firefoxcsv') | ForEach-Object { $fmtCombo.Items.Add($_) | Out-Null }
            $fmtCombo.SelectedIndex = 0
            $fmtForm.Controls.Add($fmtCombo)
            $fmtOk = New-Object System.Windows.Forms.Button
            $fmtOk.Text = 'OK'; $fmtOk.DialogResult = 'OK'
            $fmtOk.Location = New-Object System.Drawing.Point(130, 120)
            $fmtOk.Size = New-Object System.Drawing.Size(80, 28)
            $fmtForm.Controls.Add($fmtOk)
            $fmtCancel = New-Object System.Windows.Forms.Button
            $fmtCancel.Text = 'Cancel'; $fmtCancel.DialogResult = 'Cancel'
            $fmtCancel.Location = New-Object System.Drawing.Point(220, 120)
            $fmtCancel.Size = New-Object System.Drawing.Size(80, 28)
            $fmtForm.Controls.Add($fmtCancel)
            $fmtForm.AcceptButton = $fmtOk
            $fmtForm.CancelButton = $fmtCancel
            if ($fmtForm.ShowDialog() -ne 'OK') { $fmtForm.Dispose(); return }
            $selectedFormat = $fmtCombo.SelectedItem.ToString()
            $fmtForm.Dispose()

            # --- File picker with format-aware filter ---
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Title = "Select Secrets File to Import ($selectedFormat)"
            switch -Wildcard ($selectedFormat) {
                '*json' { $ofd.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*" }
                '*csv'  { $ofd.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*" }
                '*xml'  { $ofd.Filter = "XML files (*.xml)|*.xml|All files (*.*)|*.*" }
                default { $ofd.Filter = "All files (*.*)|*.*" }
            }
            if ($ofd.ShowDialog() -eq 'OK') {
                try {
                    Import-VaultSecrets -FilePath $ofd.FileName -Format $selectedFormat
                    [System.Windows.Forms.MessageBox]::Show("Secrets imported successfully from $selectedFormat.", "Import Complete",
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                } catch {
                    Write-SecurityErrorAdvice -Operation 'Import Secrets' -ExceptionObject $_.Exception
                }
            }
        } else {
            Write-AppLog "Import Secrets requested but SASC module is unavailable" "Warning"
            [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $securityMenu.DropDownItems.Add($importSecretsItem) | Out-Null

    # Import Certificates
    $importCertsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $importCertsItem.Text = "Import &Certificates..."
    $importCertsItem.Add_Click({
        if (-not (Request-ElevationConfirmation 'Import Certificates')) { return }
        if (Get-Command Import-Certificates -ErrorAction SilentlyContinue) {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Certificate files (*.pfx;*.cer;*.crt)|*.pfx;*.cer;*.crt|All files (*.*)|*.*"
            $ofd.Title = "Select Certificate to Import"
            if ($ofd.ShowDialog() -eq 'OK') {
                try {
                    Import-Certificates -CertPath $ofd.FileName
                    [System.Windows.Forms.MessageBox]::Show("Certificate imported.", "Import Complete",
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                } catch {
                    Write-SecurityErrorAdvice -Operation 'Import Certificates' -ExceptionObject $_.Exception
                }
            }
        } else {
            Write-AppLog "Import Certificates requested but SASC module is unavailable" "Warning"
            [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $securityMenu.DropDownItems.Add($importCertsItem) | Out-Null

    # Separator
    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Vault Security Audit
    $secAuditItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $secAuditItem.Text = "Vault Security &Audit..."
    $secAuditItem.Add_Click({
        if (-not (Request-ElevationConfirmation 'Vault Security Audit')) { return }
        if (Get-Command Test-VaultSecurity -ErrorAction SilentlyContinue) {
            try {
                $auditResult = Test-VaultSecurity
                $msg = "Security Score: $($auditResult.Score)/100`n`nFindings:`n"
                foreach ($f in $auditResult.Findings) { $msg += "  - $f`n" }
                foreach ($r in $auditResult.Recommendations) { $msg += "  [!] $r`n" }
                $icon = if ($auditResult.Score -ge 80) { 'Information' } elseif ($auditResult.Score -ge 50) { 'Warning' } else { 'Error' }
                [System.Windows.Forms.MessageBox]::Show($msg, "Vault Security Audit",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$icon)
            } catch {
                Write-SecurityErrorAdvice -Operation 'Vault Security Audit' -ExceptionObject $_.Exception
            }
        } else {
            Write-AppLog "Vault Security Audit requested but SASC module is unavailable" "Warning"
            [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $securityMenu.DropDownItems.Add($secAuditItem) | Out-Null

    # Integrity Verification
    $integrityItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $integrityItem.Text = "&Integrity Verification..."
    $integrityItem.Add_Click({
        if (Get-Command Test-IntegrityManifest -ErrorAction SilentlyContinue) {
            try {
                $intResult = Test-IntegrityManifest
                if ($intResult.AllPassed -and $intResult.SignatureValid) {
                    $passCount = ($intResult.Results | Where-Object { $_.Passed }).Count
                    [System.Windows.Forms.MessageBox]::Show(
                        "All $passCount files passed integrity verification.`nSignature: Valid",
                        "Integrity OK", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                } else {
                    $failMsg = "INTEGRITY VERIFICATION:`n"
                    $failMsg += "Signature Valid: $($intResult.SignatureValid)`n`n"
                    $failed = $intResult.Results | Where-Object { -not $_.Passed }
                    if ($failed) {
                        $failMsg += "Failed Files:`n"
                        foreach ($f in $failed) { $failMsg += "  - $($f.File): $($f.Status)`n" }
                    }
                    if ($intResult.Errors) {
                        foreach ($e in $intResult.Errors) { $failMsg += "  [!] $e`n" }
                    }
                    [System.Windows.Forms.MessageBox]::Show($failMsg, "Integrity Issues",
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                }
            } catch {
                Write-AppLog "Integrity check error: $($_.Exception.Message)" "Error"
            }
        }
    })
    $securityMenu.DropDownItems.Add($integrityItem) | Out-Null

    # Separator
    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # LAN Sharing Settings
    $lanSharingItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $lanSharingItem.Text = "LA&N Vault Sharing..."
    $lanSharingItem.Add_Click({
        if (Get-Command Get-VaultLANStatus -ErrorAction SilentlyContinue) {
            try {
                $lanStatus = Get-VaultLANStatus
                $currentState = if ($lanStatus.Enabled) { "ENABLED" } else { "DISABLED" }
                $newState = if ($lanStatus.Enabled) { "DISABLE" } else { "ENABLE" }
                $toggleMsg = "LAN Vault Sharing is currently: $currentState`n`n$newState sharing?`n`nNote: Enabling requires Administrator elevation (UAC prompt)."
                $dlgResult = [System.Windows.Forms.MessageBox]::Show($toggleMsg, "LAN Vault Sharing",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($dlgResult -eq 'Yes') {
                    Set-VaultLANSharing -Enable (-not $lanStatus.Enabled)
                    $resultState = if (-not $lanStatus.Enabled) { "enabled" } else { "disabled" }
                    Write-AppLog "LAN sharing $resultState" "Info"
                    [System.Windows.Forms.MessageBox]::Show(
                        "LAN Vault Sharing has been $resultState.",
                        "LAN Sharing",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            } catch {
                Write-SecurityErrorAdvice -Operation 'LAN Vault Sharing' -ExceptionObject $_.Exception
            }
        }
    })
    $securityMenu.DropDownItems.Add($lanSharingItem) | Out-Null

    # Windows Hello Integration
    $helloItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $helloItem.Text = "Windows &Hello Setup..."
    $helloItem.Add_Click({
        if (-not (Request-ElevationConfirmation 'Windows Hello Setup')) { return }
        if (Get-Command Enable-WindowsHello -ErrorAction SilentlyContinue) {
            try {
                Enable-WindowsHello
                [System.Windows.Forms.MessageBox]::Show("Windows Hello integration configured.", "Windows Hello",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            } catch {
                Write-SecurityErrorAdvice -Operation 'Windows Hello Setup' -ExceptionObject $_.Exception
            }
        } else {
            Write-AppLog "Windows Hello setup requested but SASC module is unavailable" "Warning"
            [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $securityMenu.DropDownItems.Add($helloItem) | Out-Null

    # Separator
    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Invoke Secrets (XHTML page)
    $invokeSecretsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $invokeSecretsItem.Text = "Invoke Secrets &Page..."
    $invokeSecretsItem.Add_Click({
        try {
            if (Get-Command Show-SecretsInvokerForm -ErrorAction SilentlyContinue) {
                Show-SecretsInvokerForm
            } else {
                $xhtmlPath = Join-Path $scriptDir 'XHTML-invoke-secrets.xhtml'
                if (Test-Path $xhtmlPath) {
                    Start-Process $xhtmlPath
                } else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Secrets invoker page not found.`nExpected: $xhtmlPath",
                        "Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                }
            }
        } catch {
            Write-SecurityErrorAdvice -Operation 'Invoke Secrets Page' -ExceptionObject $_.Exception
        }
    })
    $securityMenu.DropDownItems.Add($invokeSecretsItem) | Out-Null

    # Export Vault Backup
    $exportBackupItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exportBackupItem.Text = "Export Vault &Backup..."
    $exportBackupItem.Add_Click({
        if (-not (Request-ElevationConfirmation 'Export Vault Backup')) { return }
        if (Get-Command Export-VaultBackup -ErrorAction SilentlyContinue) {
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = "Encrypted Backup (*.vaultbak)|*.vaultbak|All files (*.*)|*.*"
            $sfd.Title = "Export Vault Backup"
            $sfd.FileName = "vault-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').vaultbak"
            if ($sfd.ShowDialog() -eq 'OK') {
                try {
                    Export-VaultBackup -OutputPath $sfd.FileName
                    [System.Windows.Forms.MessageBox]::Show("Backup exported to:`n$($sfd.FileName)", "Backup Complete",
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                } catch {
                    Write-SecurityErrorAdvice -Operation 'Export Vault Backup' -ExceptionObject $_.Exception
                }
            }
        } else {
            Write-AppLog "Export Vault Backup requested but SASC module is unavailable" "Warning"
            [System.Windows.Forms.MessageBox]::Show("SASC module not loaded.", "Unavailable",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $securityMenu.DropDownItems.Add($exportBackupItem) | Out-Null

    $menuStrip.Items.Add($securityMenu) | Out-Null
    
    # Help Menu
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpMenu.Text = "&Help"
    
    $updateHelpItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $updateHelpItem.Text = "Update-&Help"
    $updateHelpItem.Add_Click({
        Show-UpdateHelp
    })
    $helpMenu.DropDownItems.Add($updateHelpItem) | Out-Null
    
    $helpIndexItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpIndexItem.Text = "PwShGUI App &Help (Webpage Index)"
    $helpIndexItem.Add_Click({
        Write-AppLog "User selected Help > PwShGUI App Help" "Audit"
        $helpFile = Get-ProjectPath HelpIndex
        [void](Open-MenuPathSafely -MenuLabel 'PwShGUI Help Index' -PathToOpen $helpFile)
    })
    $helpMenu.DropDownItems.Add($helpIndexItem) | Out-Null
    
    $packageItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $packageItem.Text = "&Package Workspace"
    $packageItem.Add_Click({
        Write-AppLog "User selected Help > Package Workspace" "Audit"
        Export-WorkspacePackage
        [System.Windows.Forms.MessageBox]::Show("Workspace packaged.","Package","OK",[System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $helpMenu.DropDownItems.Add($packageItem) | Out-Null
    
    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $depVizHelpItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $depVizHelpItem.Text = "Dependency &Visualisation"
    $depVizHelpItem.Add_Click({
        Write-AppLog "User selected Help > Dependency Visualisation" "Audit"
        # Prefer canonical README location, then latest history snapshot,
        # then legacy checker path for backward compatibility.
        $canonicalPath = Join-Path $PSScriptRoot '~README.md\Dependency-Visualisation.html'
        if (Test-Path $canonicalPath) {
            [void](Open-MenuPathSafely -MenuLabel 'Dependency Visualisation' -PathToOpen $canonicalPath)
        } else {
            $historyDir = Join-Path $PSScriptRoot '.history\~README.md'
            $vizFiles = @(Get-ChildItem -Path $historyDir -Filter 'Dependency-Visualisation_*.html' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            if ($vizFiles.Count -gt 0) {
                [void](Open-MenuPathSafely -MenuLabel 'Dependency Visualisation Snapshot' -PathToOpen $vizFiles[0].FullName)
            } else {
                $legacyPath = Join-Path $PSScriptRoot 'scripts\XHTML-Checker\Dependency-Visualisation.xhtml'
                if (Test-Path $legacyPath) {
                    [void](Open-MenuPathSafely -MenuLabel 'Dependency Visualisation (Legacy)' -PathToOpen $legacyPath)
                } else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "No visualisation found. Run Tools > Script Dependency Matrix first to generate data.",
                        "Dependency Visualisation",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                }
            }
        }
    })
    $helpMenu.DropDownItems.Add($depVizHelpItem) | Out-Null

    $cheatSheetItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $cheatSheetItem.Text = "PS-&Cheatsheet V2"
    $cheatSheetItem.Add_Click({
        Write-AppLog "User selected Help > PS-Cheatsheet V2" "Audit"
        $cheatFile = Join-Path $PSScriptRoot 'scripts\PS-CheatSheet-EXAMPLES-V2.ps1'
        if (Test-Path $cheatFile) {
            # V2 requires PowerShell 7+ (#Requires -Version 7.0) and uses
            # interactive prompts (Out-GridView / Read-Host), so launch it
            # in a new pwsh console window.  Fall back to powershell.exe if
            # pwsh is not available.
            $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
            try {
                Start-Process $shell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$cheatFile`"" -WindowStyle Normal
                Write-AppLog "Launched PS-Cheatsheet V2 via $shell" "Info"
            } catch {
                Write-AppLog "Failed to launch PS-Cheatsheet V2: $_" "Error"
                [System.Windows.Forms.MessageBox]::Show(
                    "Could not launch cheatsheet:`n$_",
                    "PS-Cheatsheet V2",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Cheatsheet not found:`n$cheatFile",
                "PS-Cheatsheet V2",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    })
    $helpMenu.DropDownItems.Add($cheatSheetItem) | Out-Null

    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $mrsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $mrsItem.Text = "&Manifests, Registries && SINs"
    $mrsItem.Add_Click({
        Write-AppLog "User selected Help > Manifests, Registries & SINs" "Audit"
        Show-ManifestsRegistrySinsViewer
    })
    $helpMenu.DropDownItems.Add($mrsItem) | Out-Null

    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutItem.Text = "🔷  &About"
    $aboutItem.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $aboutItem.Add_Click({
        Write-AppLog "User selected Help > About" "Audit"
        Show-ModernAboutScreen
    })
    $helpMenu.DropDownItems.Add($aboutItem) | Out-Null

    $aboutSysItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutSysItem.Text = "🖥  About - System"
    $aboutSysItem.Add_Click({
        Write-AppLog "User selected Help > About - System" "Audit"
        Show-AboutSystemDialog
    })
    $helpMenu.DropDownItems.Add($aboutSysItem) | Out-Null

    $aboutAppItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutAppItem.Text = "📊  About - App"
    $aboutAppItem.Add_Click({
        Write-AppLog "User selected Help > About - App" "Audit"
        Show-AboutAppDialog
    })
    $helpMenu.DropDownItems.Add($aboutAppItem) | Out-Null
    
    $menuStrip.Items.Add($helpMenu) | Out-Null

    # ── Apply modern dark theme to menu strip ──
    if (Get-Command Set-ModernMenuStyle -ErrorAction SilentlyContinue) {
        Set-ModernMenuStyle -MenuStrip $menuStrip
    }
    
    # ==================== TITLE LABEL ====================
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "PowerShellGUI - Scriptz Launchr - Setupz-Settingz &-Scanrz."
    $titleLabel.Location = New-Object System.Drawing.Point([int]20, [int]40)
    $titleLabel.Size = New-Object System.Drawing.Size([int]660, [int]30)
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    if (Get-Command Get-ThemeValue -ErrorAction SilentlyContinue) {
        $titleLabel.ForeColor = Get-ThemeValue 'HeadingFore'
    }
    $form.Controls.Add($titleLabel)
    
    # ==================== RAINBOW PROGRESS BAR & SPINNER ====================
    $script:_ProgressBar = $null
    $script:_Spinner = $null
    if (Get-Command New-RainbowProgressBar -ErrorAction SilentlyContinue) {
        $script:_ProgressBar = New-RainbowProgressBar -Width 640 -Height 6
        $script:_ProgressBar.Panel.Location = New-Object System.Drawing.Point([int]30, [int]74)
        $form.Controls.Add($script:_ProgressBar.Panel)
    }
    if (Get-Command New-SpinnerLabel -ErrorAction SilentlyContinue) {
        $script:_Spinner = New-SpinnerLabel -Prefix "Processing"
        $script:_Spinner.Label.Location = New-Object System.Drawing.Point([int]570, [int]42)
        $script:_Spinner.Label.Size = New-Object System.Drawing.Size([int]120, [int]18)
        $form.Controls.Add($script:_Spinner.Label)
    }

    # ==================== BUTTONS ====================
    # Load button configuration from config file
    $buttonConfig = Get-ButtonConfiguration
    $buttonNames = $buttonConfig.Left
    $rightButtonNames = $buttonConfig.Right
    
    $buttonHeight = 50
    $buttonWidth = 260
    $spacing = 10
    $column1X = 30
    $column2X = 310
    $startY = 90
    
    # Add left column buttons (6 buttons, 3 per column)
    for ($i = 0; $i -lt $buttonNames.Count; $i++) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $buttonNames[$i].DisplayName
        $button.Size = New-Object System.Drawing.Size([int]$buttonWidth, [int]$buttonHeight)
        $button.Tag = $buttonNames[$i].ScriptName
        
        # Calculate position (left column - 3 buttons)
        $yPos = [int]($startY + ($i * ($buttonHeight + $spacing)))
        $button.Location = New-Object System.Drawing.Point([int]$column1X, $yPos)
        
        if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) {
            Set-ModernButtonStyle -Button $button
        } else {
            $button.Font = New-Object System.Drawing.Font("Segoe UI", 10)
            $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        
        # Create click handler
        $button.Add_Click({
            $scriptName = $this.Tag
            $displayName = $this.Text
            
            Write-AppLog "Button clicked: $displayName ($scriptName)" "Audit"
            Write-ScriptLog "Button clicked for execution" $scriptName "Audit"
            
            # Get elevation preference with safety badge
            $scriptPath = Join-Path $scriptsDir "$scriptName.ps1"
            $shouldElevate = Show-ElevationPrompt -ScriptName $scriptName -ScriptPath $scriptPath
            
            # Invoke the script
            Invoke-ScriptWithElevation -ScriptName $scriptName -RunAsAdmin $shouldElevate
        })
        
        $form.Controls.Add($button)
    }

    # ADD RIGHT COLUMN BUTTONS (6 buttons)
    for ($j = 0; $j -lt $rightButtonNames.Count; $j++) {
        $rightButton = New-Object System.Windows.Forms.Button
        $rightButton.Text = $rightButtonNames[$j].DisplayName
        $rightButton.Size = New-Object System.Drawing.Size([int]$buttonWidth, [int]$buttonHeight)
        $rightButton.Tag = $rightButtonNames[$j].ScriptName

        # Calculate position (Right column - 3 buttons)
        $yPos = [int]($startY + ($j * ($buttonHeight + $spacing)))
        $rightButton.Location = New-Object System.Drawing.Point([int]$column2X, [int]$yPos)

        if (Get-Command Set-ModernButtonStyle -ErrorAction SilentlyContinue) {
            Set-ModernButtonStyle -Button $rightButton
        } else {
            $rightButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
            $rightButton.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        
        # Create click handler for PWSH Quick App
        $rightButton.Add_Click({
            $scriptName = $this.Tag
            $displayName = $this.Text
            
            Write-AppLog "Button clicked: $displayName ($scriptName)" "Audit"
            
            # Get elevation preference with safety badge
            $scriptPath = Join-Path $scriptsDir "$scriptName.ps1"
            $shouldElevate = Show-ElevationPrompt -ScriptName $scriptName -ScriptPath $scriptPath
            
            # Invoke the script
            Invoke-ScriptWithElevation -ScriptName $scriptName -RunAsAdmin $shouldElevate
        })

        $form.Controls.Add($rightButton)
    }
    
    # ==================== SERVICE STATUS LIGHTS BAR ====================
    # Positioned above the main status bar -- coloured circles with tooltips
    $servicePanel = New-Object System.Windows.Forms.Panel
    $servicePanel.Location = New-Object System.Drawing.Point([int]0, [int]440)
    $servicePanel.Size = New-Object System.Drawing.Size([int]700, [int]22)
    $servicePanel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $form.Controls.Add($servicePanel)

    $serviceToolTip = New-Object System.Windows.Forms.ToolTip
    $serviceToolTip.InitialDelay = 300
    $serviceToolTip.AutoPopDelay = 8000

    # Service definitions: Name, initial state
    $script:_ServiceDefs = @(
        @{ Name = 'Vault';        State = 'Off';    Tip = 'Bitwarden Vault: Not checked' },
        @{ Name = 'Config';       State = 'Off';    Tip = 'Configuration: Not loaded' },
        @{ Name = 'Logging';      State = 'Off';    Tip = 'Logging: Not started' },
        @{ Name = 'Scripts';      State = 'Off';    Tip = 'Scripts folder: Not verified' },
        @{ Name = 'Remote';       State = 'Off';    Tip = 'Remote paths: Not configured' },
        @{ Name = 'Modules';      State = 'Off';    Tip = 'Modules: Not loaded' },
        @{ Name = 'Session';      State = 'Off';    Tip = 'Session lock: Unknown' },
        @{ Name = 'SFC';          State = 'Off';    Tip = 'SFC: Not scanned' },
        @{ Name = 'DISM';         State = 'Off';    Tip = 'DISM Health: Not checked' },
        @{ Name = 'Versions';     State = 'Off';    Tip = 'Version status: Not assessed' },
        @{ Name = 'Reboot';       State = 'Off';    Tip = 'Pending reboot: Unknown' }
    )
    $script:_ServiceLabels = @{}

    $svcX = 4
    foreach ($svc in $script:_ServiceDefs) {
        $svcLabel = New-Object System.Windows.Forms.Label
        $svcLabel.Text = [char]0x25CF  # filled circle
        $svcLabel.Location = New-Object System.Drawing.Point($svcX, 2)
        $svcLabel.Size = New-Object System.Drawing.Size(14, 18)
        $svcLabel.ForeColor = [System.Drawing.Color]::Gray
        $svcLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $svcLabel.TextAlign = "MiddleCenter"
        $serviceToolTip.SetToolTip($svcLabel, $svc.Tip)
        $servicePanel.Controls.Add($svcLabel)
        $script:_ServiceLabels[$svc.Name] = $svcLabel

        $svcNameLabel = New-Object System.Windows.Forms.Label
        $svcNameLabel.Text = $svc.Name
        $svcNameLabel.Location = New-Object System.Drawing.Point(($svcX + 13), 3)
        $svcNameLabel.Size = New-Object System.Drawing.Size(48, 16)
        $svcNameLabel.ForeColor = [System.Drawing.Color]::Silver
        $svcNameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 6.5)
        $svcNameLabel.TextAlign = "MiddleLeft"
        $servicePanel.Controls.Add($svcNameLabel)

        $svcX += 62
    }

    # Helper function to update a service light
    function Set-ServiceLight {
        param([string]$ServiceName, [string]$State, [string]$TooltipText)
        if (-not $script:_ServiceLabels.ContainsKey($ServiceName)) { return }
        $lbl = $script:_ServiceLabels[$ServiceName]
        $color = switch ($State) {
            'Running'    { [System.Drawing.Color]::Lime }
            'Error'      { [System.Drawing.Color]::Red }
            'Warning'    { [System.Drawing.Color]::Yellow }
            'Idle'       { [System.Drawing.Color]::DodgerBlue }
            'Paused'     { [System.Drawing.Color]::MediumPurple }
            'Off'        { [System.Drawing.Color]::Gray }
            default      { [System.Drawing.Color]::Gray }
        }
        $lbl.ForeColor = $color
        if ($TooltipText) { $serviceToolTip.SetToolTip($lbl, $TooltipText) }
    }

    # ── Initial service state assessment ──
    # Config
    if (Test-Path $configFile) {
        Set-ServiceLight 'Config' 'Running' "Configuration: Loaded from $configFile"
    } else {
        Set-ServiceLight 'Config' 'Error' 'Configuration: File not found'
    }
    # Logging
    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
        Set-ServiceLight 'Logging' 'Running' "Logging: Active - $logsDir"
    }
    # Scripts
    if (Test-Path $scriptsDir) {
        $scriptCount = @(Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -ErrorAction SilentlyContinue).Count
        Set-ServiceLight 'Scripts' 'Running' "Scripts folder: $scriptCount scripts found"
    } else {
        Set-ServiceLight 'Scripts' 'Error' 'Scripts folder: Not found'
    }
    # Modules
    $modCount = @(Get-Module | Where-Object { $_.Path -like "$scriptDir*" }).Count
    if ($modCount -gt 0) {
        Set-ServiceLight 'Modules' 'Running' "Modules: $modCount project modules loaded"
    } else {
        Set-ServiceLight 'Modules' 'Warning' 'Modules: No project modules loaded'
    }
    # Session
    Set-ServiceLight 'Session' 'Running' "Session: Active since $(Get-Date -Format 'HH:mm:ss')"

    # SFC -- check cached last result if available
    $sfcTip = 'SFC: Not scanned (run sfc /scannow as admin)'
    $sfcState = 'Off'
    try {
        $sfcLog = "$env:windir\Logs\CBS\CBS.log"
        if (Test-Path $sfcLog) {
            $sfcTail = Get-Content $sfcLog -Tail 200 -ErrorAction SilentlyContinue | Select-String 'No integrity violations' -Quiet
            if ($sfcTail) { $sfcState = 'Running'; $sfcTip = 'SFC: No integrity violations found' }
            else { $sfcState = 'Warning'; $sfcTip = 'SFC: Check CBS.log for details' }
        }
    } catch { <# Intentional: non-fatal #> }
    Set-ServiceLight 'SFC' $sfcState $sfcTip

    # DISM health -- check component store
    $dismState = 'Off'; $dismTip = 'DISM: Not checked'
    try {
        $dismKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        if (Test-Path $dismKey) { $dismState = 'Warning'; $dismTip = 'DISM: Component store repair pending' }
        else { $dismState = 'Running'; $dismTip = 'DISM: Component store healthy' }
    } catch { <# Intentional: non-fatal #> }
    Set-ServiceLight 'DISM' $dismState $dismTip

    # Versions -- compare PS and OS currency
    $verState = 'Off'; $verTip = 'Version status: Unknown'
    try {
        $psVer = $PSVersionTable.PSVersion
        if ($psVer.Major -ge 7) { $verState = 'Running'; $verTip = "Versions: PS $psVer (current)" }
        elseif ($psVer.Major -eq 5) { $verState = 'Warning'; $verTip = "Versions: PS $psVer (5.1 - consider pwsh 7)" }
        else { $verState = 'Error'; $verTip = "Versions: PS $psVer (outdated)" }
    } catch { <# Intentional: non-fatal #> }
    Set-ServiceLight 'Versions' $verState $verTip

    # Pending reboot -- check registry keys
    $rebootState = 'Off'; $rebootTip = 'Reboot: None pending'
    try {
        $rebootPending = $false
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rebootPending = $true }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rebootPending = $true }
        if ($rebootPending) { $rebootState = 'Idle'; $rebootTip = 'Reboot: PENDING - restart recommended' }
        else { Set-ServiceLight 'Reboot' 'Running' 'Reboot: None pending'; $rebootState = $null }
    } catch { <# Intentional: non-fatal #> }
    if ($rebootState) { Set-ServiceLight 'Reboot' $rebootState $rebootTip }

    # ── Service status refresh timer (every 10s) ──
    $script:_ServiceTimer = New-Object System.Windows.Forms.Timer
    $script:_ServiceTimer.Interval = 10000
    $script:_ServiceTimer.Add_Tick({
        try {
            # Null-guard: child-script StrictMode can make $script: vars inaccessible (P022)
            $timer = $script:_ServiceTimer
            if ($null -eq $timer) { return }
            # Restore normal interval if triggered manually (F5 / path save)
            if ($timer.Interval -ne 10000) { $timer.Interval = 10000 }
            # Skip when minimized (Cycle 6 optimization)
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }

            # Vault status
            if ($script:_SASCAvailable -and (Get-Command Test-VaultStatus -ErrorAction SilentlyContinue)) {
                $vs = Test-VaultStatus
                switch ($vs.State) {
                    'Unlocked'        { Set-ServiceLight 'Vault' 'Running' "Vault: Unlocked" }
                    'Locked'          { Set-ServiceLight 'Vault' 'Idle' "Vault: Locked - ready to unlock" }
                    'LockedOut'       { Set-ServiceLight 'Vault' 'Error' "Vault: Locked out" }
                    'Unauthenticated' { Set-ServiceLight 'Vault' 'Warning' "Vault: Not logged in" }
                    'NotInitialized'  { Set-ServiceLight 'Vault' 'Off' "Vault: Not initialized" }
                    default           { Set-ServiceLight 'Vault' 'Off' "Vault: $($vs.State)" }
                }
            } else {
                Set-ServiceLight 'Vault' 'Off' 'Vault: Module not loaded'
            }

            # Remote
            $remoteCfg = try { [string](Get-ConfigSubValue 'RemoteUpdatePath') } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($remoteCfg)) {
                if (Test-Path $remoteCfg) {
                    Set-ServiceLight 'Remote' 'Running' "Remote: Connected - $remoteCfg"
                } else {
                    Set-ServiceLight 'Remote' 'Warning' "Remote: Path not reachable - $remoteCfg"
                }
            } else {
                Set-ServiceLight 'Remote' 'Off' 'Remote: Not configured'
            }
        } catch { Write-AppLog "[ServiceTimer] Remote check error: $_" 'Warning' }
    })
    $script:_ServiceTimer.Start()

    # ==================== STATUS BAR ====================
    # ── Gather system info for status bar ──
    $script:_StatusWanIP = '...'; $script:_StatusWanCacheTime = [datetime]::MinValue
    $script:_StatusLanIP = '...'
    try {
        $lanAddr = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet*','Wi-Fi*' -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1).IPAddress
        if ($lanAddr) { $script:_StatusLanIP = $lanAddr } else { $script:_StatusLanIP = 'N/A' }
    } catch { $script:_StatusLanIP = 'N/A' }

    # DHCP / DNS info
    $dhcpEnabled = $false; $dhcpServer = ''; $dnsServers = @(); $dnssecOK = $false
    try {
        $activeIf = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($activeIf) {
            $dhcpCfg = Get-NetIPAddress -InterfaceIndex $activeIf.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -eq 'Dhcp' }
            $dhcpEnabled = ($null -ne $dhcpCfg)
            if ($dhcpEnabled) {
                $dhcpServer = try { (Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceIndex -eq $activeIf.InterfaceIndex -and $_.DHCPEnabled } |
                    Select-Object -First 1).DHCPServer } catch { '' }
            }
            $dnsServers = @($activeIf.DNSServer | ForEach-Object { $_.ServerAddresses } | Select-Object -First 2)
        }
    } catch { <# Intentional: non-fatal #> }
    $dhcpText = if ($dhcpEnabled) { "DHCP: Yes$(if($dhcpServer){" ($dhcpServer)"})" } else { 'DHCP: Static' }
    $dnsText = if ($dnsServers.Count -gt 0) { "DNS: $($dnsServers -join ', ')" } else { 'DNS: N/A' }

    # DNSSEC -- quick check via registry
    try {
        $dnssecReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableDnsSec -ErrorAction SilentlyContinue
        $dnssecOK = ($dnssecReg -and $dnssecReg.EnableDnsSec -eq 1)
    } catch { <# Intentional: non-fatal #> }
    $dnssecText = if ($dnssecOK) { 'DNSSEC: On' } else { 'DNSSEC: Off' }

    # Windows version build
    $winBuild = ''
    try {
        $ntReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $curBuild = $ntReg.CurrentBuild
        $ubr = $ntReg.UBR
        $dispVer = $ntReg.DisplayVersion
        $winBuild = "Win $(if($dispVer){$dispVer + ' '}else{''})$curBuild$(if($ubr){'.' + $ubr}else{''})"
    } catch { $winBuild = 'Win ?' }

    # App version
    $appVerStr = ''
    try { $appVerStr = "App $(Get-VersionString)" } catch { $appVerStr = 'App ?' }

    # System volume free space
    $diskText = ''
    try {
        $sysDrive = $env:SystemDrive.TrimEnd(':')
        $psd = Get-PSDrive -Name $sysDrive -ErrorAction SilentlyContinue
        if ($psd) {
            $freeGB = [math]::Round($psd.Free / 1GB, 1)
            $diskText = "$($env:SystemDrive) $($freeGB) GB free"
        }
    } catch { $diskText = "$($env:SystemDrive) ?" }

    # ── Row layout (Y positions) ──
    #   Y=462: Row 1 - Left: Computer/User (blue)     Right: Paths (Default + Remote)
    #   Y=482: Row 2 - Left: WAN/LAN IP               Right: Scripts path
    #   Y=502: Row 3 - Left: DHCP/DNS/DNSSEC           Right: Win build + App ver + Disk
    #   Y=522: Row 4 - Vault status (full width)

    # ROW 1 Left - Computer + User
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "$env:COMPUTERNAME | $env:USERNAME"
    $statusLabel.Location = New-Object System.Drawing.Point([int]0, [int]462)
    $statusLabel.Size = New-Object System.Drawing.Size([int]250, [int]20)
    $statusLabel.BackColor = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $statusLabel.ForeColor = [System.Drawing.Color]::White
    $statusLabel.TextAlign = "MiddleLeft"
    $statusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $statusLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $form.Controls.Add($statusLabel)

    # ROW 1 Right - Default path + Remote path (2 columns)
    $statusRightRow1 = New-Object System.Windows.Forms.Label
    $statusRightRow1.Text = "Default: $DefaultFolder"
    $statusRightRow1.Location = New-Object System.Drawing.Point([int]250, [int]462)
    $statusRightRow1.Size = New-Object System.Drawing.Size([int]450, [int]20)
    $statusRightRow1.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $statusRightRow1.TextAlign = "MiddleLeft"
    $statusRightRow1.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $statusRightRow1.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $statusRightRow1.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $statusRightRow1.ForeColor = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $form.Controls.Add($statusRightRow1)

    # ROW 2 Left - WAN / LAN IP
    $script:_NetInfoLabel = New-Object System.Windows.Forms.Label
    $script:_NetInfoLabel.Text = "WAN: $($script:_StatusWanIP) | LAN: $($script:_StatusLanIP)"
    $script:_NetInfoLabel.Location = New-Object System.Drawing.Point([int]0, [int]482)
    $script:_NetInfoLabel.Size = New-Object System.Drawing.Size([int]250, [int]20)
    $script:_NetInfoLabel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $script:_NetInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(206, 145, 64)
    $script:_NetInfoLabel.TextAlign = "MiddleLeft"
    $script:_NetInfoLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:_NetInfoLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $script:_NetInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $form.Controls.Add($script:_NetInfoLabel)

    # ROW 2 Right - Remote path + Scripts path
    $remotePathLive = $RemoteUpdatePath
    if ([string]::IsNullOrWhiteSpace($remotePathLive)) {
        $remotePathLive = try { [string](Get-ConfigSubValue 'RemoteUpdatePath') } catch { '' }
    }
    $remotePathDisplay = if ([string]::IsNullOrWhiteSpace($remotePathLive)) { "(not set)" } else { $remotePathLive }
    $statusRightRow2 = New-Object System.Windows.Forms.Label
    $statusRightRow2.Text = "Remote: $remotePathDisplay | Scripts: $scriptsDir"
    $statusRightRow2.Location = New-Object System.Drawing.Point([int]250, [int]482)
    $statusRightRow2.Size = New-Object System.Drawing.Size([int]450, [int]20)
    $statusRightRow2.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $statusRightRow2.TextAlign = "MiddleLeft"
    $statusRightRow2.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $statusRightRow2.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $statusRightRow2.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $statusRightRow2.ForeColor = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $form.Controls.Add($statusRightRow2)

    # ROW 3 Left - DHCP / DNS / DNSSEC
    $script:_DhcpDnsLabel = New-Object System.Windows.Forms.Label
    $script:_DhcpDnsLabel.Text = "$dhcpText | $dnsText | $dnssecText"
    $script:_DhcpDnsLabel.Location = New-Object System.Drawing.Point([int]0, [int]502)
    $script:_DhcpDnsLabel.Size = New-Object System.Drawing.Size([int]400, [int]20)
    $script:_DhcpDnsLabel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $script:_DhcpDnsLabel.ForeColor = [System.Drawing.Color]::Silver
    $script:_DhcpDnsLabel.TextAlign = "MiddleLeft"
    $script:_DhcpDnsLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:_DhcpDnsLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $script:_DhcpDnsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $form.Controls.Add($script:_DhcpDnsLabel)

    # ROW 3 Right - Windows build + App version + Disk
    $script:_SysInfoLabel = New-Object System.Windows.Forms.Label
    $script:_SysInfoLabel.Text = "$winBuild | $appVerStr | $diskText"
    $script:_SysInfoLabel.Location = New-Object System.Drawing.Point([int]400, [int]502)
    $script:_SysInfoLabel.Size = New-Object System.Drawing.Size([int]300, [int]20)
    $script:_SysInfoLabel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $script:_SysInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $script:_SysInfoLabel.TextAlign = "MiddleLeft"
    $script:_SysInfoLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:_SysInfoLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $script:_SysInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $form.Controls.Add($script:_SysInfoLabel)

    # ==================== VAULT STATUS INDICATORS ====================
    # Vault Status Label (left side, below system info)
    $vaultStatusLabel = New-Object System.Windows.Forms.Label
    $vaultStatusLabel.Text = "Vault: Checking..."
    $vaultStatusLabel.Location = New-Object System.Drawing.Point([int]0, [int]522)
    $vaultStatusLabel.Size = New-Object System.Drawing.Size([int]350, [int]20)
    $vaultStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $vaultStatusLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $vaultStatusLabel.TextAlign = "MiddleLeft"
    $vaultStatusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $vaultStatusLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $vaultStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($vaultStatusLabel)

    # Vault Detail Label (right side)
    $vaultDetailLabel = New-Object System.Windows.Forms.Label
    $vaultDetailLabel.Text = ""
    $vaultDetailLabel.Location = New-Object System.Drawing.Point([int]350, [int]522)
    $vaultDetailLabel.Size = New-Object System.Drawing.Size([int]350, [int]20)
    $vaultDetailLabel.BackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $vaultDetailLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $vaultDetailLabel.TextAlign = "MiddleLeft"
    $vaultDetailLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $vaultDetailLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $vaultDetailLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $form.Controls.Add($vaultDetailLabel)

    # ROW 5 — Local Web Engine status indicator (Y=542)
    $script:_EngineStatusLabel = New-Object System.Windows.Forms.Label
    $script:_EngineStatusLabel.Text = "Engine: checking…"
    $script:_EngineStatusLabel.Location = New-Object System.Drawing.Point([int]0, [int]542)
    $script:_EngineStatusLabel.Size = New-Object System.Drawing.Size([int]350, [int]20)
    $script:_EngineStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
    $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:_EngineStatusLabel.TextAlign = "MiddleLeft"
    $script:_EngineStatusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_EngineStatusLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $script:_EngineStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $script:_EngineStatusLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:_EngineStatusLabel.Add_Click({
        try { Start-Process 'http://127.0.0.1:8042/' } catch { <# non-fatal #> }
    })
    $form.Controls.Add($script:_EngineStatusLabel)

    $script:_EngineUpTimeLabel = New-Object System.Windows.Forms.Label
    $script:_EngineUpTimeLabel.Text = ""
    $script:_EngineUpTimeLabel.Location = New-Object System.Drawing.Point([int]350, [int]542)
    $script:_EngineUpTimeLabel.Size = New-Object System.Drawing.Size([int]350, [int]20)
    $script:_EngineUpTimeLabel.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
    $script:_EngineUpTimeLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 201, 176)
    $script:_EngineUpTimeLabel.TextAlign = "MiddleLeft"
    $script:_EngineUpTimeLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_EngineUpTimeLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $script:_EngineUpTimeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $form.Controls.Add($script:_EngineUpTimeLabel)

    # Expand form height to accommodate the extra row
    $form.Size = New-Object System.Drawing.Size([int]700, [int]700)

    # ==================== FOOTER TOOLTIP & CLICK-TO-OPEN WIRING ====================
    # Reuse existing $serviceToolTip; increase AutoPopDelay for richer footer tooltips
    $serviceToolTip.AutoPopDelay = 15000

    # Capture paths into a shared hashtable for closures (avoids $script: scope bleed with .GetNewClosure)
    $footerPaths = @{
        DefaultFolder    = $DefaultFolder
        RemoteUpdatePath = $remotePathLive
        ScriptsDir       = $scriptsDir
        ConfigFile       = $configFile
        MainScript       = $PSCommandPath
        LogsDir          = $logsDir
    }

    # ── Row 1 Left: Computer/User — show config file metadata ──
    $statusLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $cfgPath = $footerPaths.ConfigFile
    $statusLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $cfgPath -ItemLabel 'Configuration File'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $statusLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $cfgPath) {
                Start-Process explorer.exe "/select,`"$cfgPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 1 Right: Default folder path ──
    $statusRightRow1.Cursor = [System.Windows.Forms.Cursors]::Hand
    $defPath = $footerPaths.DefaultFolder
    $statusRightRow1.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $defPath -ItemLabel 'Default Folder'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $statusRightRow1.Add_Click({
        try {
            if (Test-Path -LiteralPath $defPath) {
                Start-Process explorer.exe "`"$defPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 2 Left: Network info — show Main-GUI.ps1 metadata ──
    $script:_NetInfoLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $mainPath = $footerPaths.MainScript
    $script:_NetInfoLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $mainPath -ItemLabel 'Main GUI Script'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $script:_NetInfoLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $mainPath) {
                Start-Process explorer.exe "/select,`"$mainPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 2 Right: Remote + Scripts paths ──
    $statusRightRow2.Cursor = [System.Windows.Forms.Cursors]::Hand
    $sDir = $footerPaths.ScriptsDir
    $rDir = $footerPaths.RemoteUpdatePath
    $statusRightRow2.Add_MouseEnter({
        try {
            $tipParts = @()
            $tipParts += (Get-FooterItemTooltip -ItemPath $rDir -ItemLabel '--- Remote Path ---')
            $tipParts += ''
            $tipParts += (Get-FooterItemTooltip -ItemPath $sDir -ItemLabel '--- Scripts Directory ---')
            $serviceToolTip.SetToolTip($this, ($tipParts -join "`n"))
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $statusRightRow2.Add_Click({
        try {
            if (Test-Path -LiteralPath $sDir) {
                Start-Process explorer.exe "`"$sDir`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 3 Left: DHCP/DNS — show logs directory metadata ──
    $script:_DhcpDnsLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $logDir = $footerPaths.LogsDir
    $script:_DhcpDnsLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $logDir -ItemLabel 'Logs Directory'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $script:_DhcpDnsLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $logDir) {
                Start-Process explorer.exe "`"$logDir`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 3 Right: SysInfo — show main script file metadata (version source) ──
    $script:_SysInfoLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:_SysInfoLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $mainPath -ItemLabel 'Application Script (Version Source)'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $script:_SysInfoLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $mainPath) {
                Start-Process explorer.exe "/select,`"$mainPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── Row 4: Vault status — show config file metadata ──
    $vaultStatusLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $vaultStatusLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $cfgPath -ItemLabel 'Vault Configuration Source'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $vaultStatusLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $cfgPath) {
                Start-Process explorer.exe "/select,`"$cfgPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    $vaultDetailLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $vaultDetailLabel.Add_MouseEnter({
        try {
            $tip = Get-FooterItemTooltip -ItemPath $cfgPath -ItemLabel 'Vault Detail — Config File'
            $serviceToolTip.SetToolTip($this, $tip)
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())
    $vaultDetailLabel.Add_Click({
        try {
            if (Test-Path -LiteralPath $cfgPath) {
                Start-Process explorer.exe "/select,`"$cfgPath`""
            }
        } catch { <# Intentional: non-fatal #> }
    }.GetNewClosure())

    # ── WAN IP background refresh timer (every 5 minutes) ──
    $script:_WanRefreshTimer = New-Object System.Windows.Forms.Timer
    $script:_WanRefreshTimer.Interval = 500  # first tick fast, then switch to 5min
    $script:_WanRefreshTimer.Add_Tick({
        try {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
            $script:_WanRefreshTimer.Interval = 300000  # 5 minutes after first tick
            try {
                $wanResp = (New-Object System.Net.WebClient).DownloadString('https://api.ipify.org').Trim()
                if ($wanResp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $script:_StatusWanIP = $wanResp
                }
            } catch { $script:_StatusWanIP = 'unavailable' }
            # Also refresh LAN
            try {
                $lanAddr = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet*','Wi-Fi*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
                    Select-Object -First 1).IPAddress
                if ($lanAddr) { $script:_StatusLanIP = $lanAddr }
            } catch { <# Intentional: non-fatal #> }
            $script:_NetInfoLabel.Text = "WAN: $($script:_StatusWanIP) | LAN: $($script:_StatusLanIP)"
        } catch { <# Intentional: non-fatal #> }
    })
    $script:_WanRefreshTimer.Start()

    # Vault status refresh timer (every 5 seconds) -- monitors BW CLI service health
    $script:_BWStatusCache = $null
    $script:_BWStatusCacheTime = [datetime]::MinValue
    $vaultTimer = New-Object System.Windows.Forms.Timer
    $vaultTimer.Interval = 5000
    $vaultTimer.Add_Tick({
        try {
            # Skip expensive checks when form is minimized (Cycle 6 optimization)
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }

            if ($script:_SASCAvailable -and (Get-Command Test-VaultStatus -ErrorAction SilentlyContinue)) {
                $vs = Test-VaultStatus

                # Periodically query bw status for live service health (every 30s to reduce overhead)
                $bwLive = $null
                if ($vs.BWCliAvailable -and ((Get-Date) - $script:_BWStatusCacheTime).TotalSeconds -ge 30) {
                    try {
                        $bwJson = & $vs.BWCliPath status 2>$null
                        if ($bwJson) {
                            $bwLive = $bwJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                            $script:_BWStatusCache = $bwLive
                            $script:_BWStatusCacheTime = Get-Date
                        }
                    } catch { $bwLive = $null }
                } else {
                    $bwLive = $script:_BWStatusCache
                }

                $serverUrl = if ($bwLive -and $bwLive.serverUrl) { $bwLive.serverUrl } else { 'local' }
                $bwUserId  = if ($bwLive -and $bwLive.userId) { $bwLive.userId.Substring(0, 8) + '...' } else { '' }
                $bwState   = if ($bwLive -and $bwLive.status) { $bwLive.status } else { $vs.State }

                switch ($vs.State) {
                    'Unlocked' {
                        $lockInfo = if ($vs.AutoLockRemaining) { " | Auto-lock: $($vs.AutoLockRemaining)" } else { '' }
                        $vaultStatusLabel.Text = "Vault: UNLOCKED$lockInfo"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Green
                        $vaultDetailLabel.Text = "BW: $serverUrl | User: $bwUserId | State: $bwState"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Green
                    }
                    'Locked' {
                        $vaultStatusLabel.Text = "Vault: LOCKED"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::LightYellow
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::DarkGoldenrod
                        $vaultDetailLabel.Text = "Security > Unlock Vault | BW: $bwState"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::DarkGoldenrod
                    }
                    'LockedOut' {
                        $remaining = if ($vs.LockoutUntil) {
                            $r = ($vs.LockoutUntil - (Get-Date)).TotalMinutes
                            [math]::Ceiling([math]::Max($r, 0)).ToString() + ' min'
                        } else { 'unknown' }
                        $vaultStatusLabel.Text = "Vault: LOCKED OUT ($remaining)"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::Black
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::White
                        $vaultDetailLabel.Text = "Failed: $($vs.FailedAttempts)/$($vs.MaxAttempts) attempts"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Black
                    }
                    'Unauthenticated' {
                        $vaultStatusLabel.Text = "Vault: NOT LOGGED IN"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::MistyRose
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Red
                        $vaultDetailLabel.Text = "Run: bw login | BW CLI: $(if($vs.BWCliAvailable){'found'}else{'missing'})"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Red
                    }
                    'NotInitialized' {
                        $vaultStatusLabel.Text = "Vault: Not Initialized"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::MistyRose
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Red
                        $vaultDetailLabel.Text = "Install BW CLI via WinGets > Install-BitWarden-LITE"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Red
                    }
                    default {
                        $vaultStatusLabel.Text = "Vault: $($vs.State)"
                        $vaultStatusLabel.BackColor = [System.Drawing.Color]::MistyRose
                        $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Red
                        $vaultDetailLabel.Text = "BW CLI: $(if($vs.BWCliAvailable){'available'}else{'not found'})"
                        $vaultDetailLabel.ForeColor = [System.Drawing.Color]::Red
                    }
                }
            } else {
                $vaultStatusLabel.Text = "Vault: Module Not Loaded"
                $vaultStatusLabel.BackColor = [System.Drawing.Color]::MistyRose
                $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Red
                $vaultDetailLabel.Text = "Load AssistedSASC module to enable"
            }
        } catch {
            $vaultStatusLabel.Text = "Vault: Error"
            $vaultStatusLabel.ForeColor = [System.Drawing.Color]::Red
            $vaultDetailLabel.Text = "$($_.Exception.Message)".Substring(0, [math]::Min(60, "$($_.Exception.Message)".Length))
        }
    })
    $vaultTimer.Start()

    # ── Engine status poll timer (every 10 seconds) ────────────────────────────
    $script:_EngineTimer = New-Object System.Windows.Forms.Timer
    $script:_EngineTimer.Interval = 10000  # first tick after 10s; quick-kick on demand via menu
    $script:_EngineTimer.Add_Tick({
        try {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
            $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8042/api/engine/status')
            $req.Timeout = 2000
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $json = $reader.ReadToEnd()
            $reader.Close()
            $resp.Close()
            $obj = $json | ConvertFrom-Json
            $upSec = if ($null -ne $obj -and $null -ne $obj.uptime) { [int]$obj.uptime } else { 0 }
            $upTxt = if ($upSec -lt 60) { "${upSec}s" } else { "$([math]::Floor($upSec/60))m" }
            if ($null -ne $script:_EngineStatusLabel) {
                $script:_EngineStatusLabel.Text  = "Engine: running (port $($obj.port))"
                $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen
                $script:_EngineStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(20, 50, 20)
            }
            if ($null -ne $script:_EngineUpTimeLabel) {
                $script:_EngineUpTimeLabel.Text = "Uptime $upTxt | PID $($obj.pid) | hub: http://127.0.0.1:$($obj.port)/"
            }
        } catch {
            if ($null -ne $script:_EngineStatusLabel) {
                $script:_EngineStatusLabel.Text  = "Engine: offline"
                $script:_EngineStatusLabel.ForeColor = [System.Drawing.Color]::Gray
                $script:_EngineStatusLabel.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
            }
            if ($null -ne $script:_EngineUpTimeLabel) {
                $script:_EngineUpTimeLabel.Text = "Tools > Script Services > Start Local Web Engine"
            }
        }
    })
    $script:_EngineTimer.Start()
    
    # ==================== KEYBOARD ACCELERATORS ====================
    $form.Add_KeyDown({
        param($sender, $e)
        # Ctrl+Q -- Quit
        if ($e.Control -and $e.KeyCode -eq 'Q') { $e.SuppressKeyPress = $true; $sender.Close() }
        # F5 -- Refresh all service lights immediately
        if ($e.KeyCode -eq 'F5') {
            $e.SuppressKeyPress = $true
            try {
                # Re-check local services
                if (Test-Path $configFile) { Set-ServiceLight 'Config' 'Running' "Configuration: Loaded from $configFile" }
                else { Set-ServiceLight 'Config' 'Error' 'Configuration: File not found' }
                if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) { Set-ServiceLight 'Logging' 'Running' "Logging: Active - $logsDir" }
                if (Test-Path $scriptsDir) {
                    $sc = @(Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -ErrorAction SilentlyContinue).Count
                    Set-ServiceLight 'Scripts' 'Running' "Scripts folder: $sc scripts found"
                } else { Set-ServiceLight 'Scripts' 'Error' 'Scripts folder: Not found' }
                $mc = @(Get-Module | Where-Object { $_.Path -like "$scriptDir*" }).Count
                if ($mc -gt 0) { Set-ServiceLight 'Modules' 'Running' "Modules: $mc project modules loaded" }
                else { Set-ServiceLight 'Modules' 'Warning' 'Modules: No project modules loaded' }
                Set-ServiceLight 'Session' 'Running' "Session: Refreshed $(Get-Date -Format 'HH:mm:ss')"
                # Trigger Vault + Remote check via timer
                if ($script:_ServiceTimer) { $script:_ServiceTimer.Stop(); $script:_ServiceTimer.Interval = 100; $script:_ServiceTimer.Start() }
            } catch { Write-AppLog "[Refresh] Module refresh error: $_" 'Warning' }
        }
    })

    # ==================== GRACEFUL EXIT HANDLER ====================
    $form.Add_FormClosing({
        param($s, $e)
        # If user clicked X (or Alt+F4) and we are NOT force-closing, minimize to tray instead
        # Null-guard _ForceClose: child-script StrictMode can make $script: vars inaccessible (P022)
        $forceClose = try { $script:_ForceClose } catch { $false }
        $trayIcon   = try { $script:_TrayIcon }   catch { $null }
        if (-not $forceClose -and $trayIcon) {
            Write-AppLog "[TrayHost] FormClosing intercepted -- cancelling close, minimizing to tray instead" "Debug"
            $e.Cancel = $true
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            # The Resize handler will Hide and show the balloon
            return
        }
        Write-AppLog "[TrayHost] FormClosing with _ForceClose=true -- performing full shutdown" "Debug"
        try {
            # Cleanup running tool processes
            if ($script:_RunningTools) {
                foreach ($entry in @($script:_RunningTools.GetEnumerator())) {
                    if ($entry.Value -is [System.Diagnostics.Process] -and -not $entry.Value.HasExited) {
                        try { $entry.Value.CloseMainWindow() | Out-Null } catch { <# Intentional: non-fatal #> }
                    }
                }
                $script:_RunningTools.Clear()
            }
            if ($script:_ServiceTimer) { $script:_ServiceTimer.Stop(); $script:_ServiceTimer.Dispose() }
            if ($script:_WanRefreshTimer) { $script:_WanRefreshTimer.Stop(); $script:_WanRefreshTimer.Dispose() }
            if ($vaultTimer) { $vaultTimer.Stop(); $vaultTimer.Dispose() }
            # Dispose system tray icon
            if ($script:_TrayIcon) { $script:_TrayIcon.Visible = $false; $script:_TrayIcon.Dispose(); $script:_TrayIcon = $null }
            if ($script:_SASCAvailable -and (Get-Command Lock-Vault -ErrorAction SilentlyContinue)) {
                Lock-Vault
                Write-AppLog "Vault locked on application exit" "Info"
            }
            # Stop TrayHost (keyboard monitor + background pool + ExitThread)
            if (Get-Command Stop-TrayHost -ErrorAction SilentlyContinue) {
                Write-AppLog "[TrayHost] Stopping TrayHost services" "Debug"
                Stop-TrayHost
            }
            Write-AppLog "Application closing gracefully" "Info"
            Export-LogBuffer
            Remove-SessionLock
        } catch {
            # Best-effort cleanup -- do not block close
        }
    })

    # ── Start minimized to tray if requested ──
    $script:_StartMinimized = $StartMinimized

    # ── Initialize TrayHost ApplicationContext (PShellCore) ──
    $trayHostAvailable = Get-Command Initialize-TrayAppContext -ErrorAction SilentlyContinue
    if ($trayHostAvailable) {
        Write-AppLog "[TrayHost] Initializing ApplicationContext lifecycle (form decoupled from message loop)" "Debug"
        $null = Initialize-TrayAppContext -Form $form -RestoreAction $script:_RestoreFromTray

        # Initialize background runspace pool
        if (Get-Command Initialize-BackgroundPool -ErrorAction SilentlyContinue) {
            Initialize-BackgroundPool -MinThreads 1 -MaxThreads 4
        }

        # Start keyboard monitor for spacebar rehydration
        if (Get-Command Start-KeyboardMonitor -ErrorAction SilentlyContinue) {
            Start-KeyboardMonitor -IntervalMs 300
        }

        # Show form via ApplicationContext (non-modal, message loop stays alive when hidden)
        Write-AppLog "Displaying GUI form window via ApplicationContext" "Audit"
        _SwMark 'first-paint-trayhost'
        Start-TrayApplicationLoop -StartMinimized:$StartMinimized

        # Message loop has ended (Stop-TrayHost or ExitThread was called)
        Write-AppLog "[TrayHost] ApplicationContext loop returned -- performing final cleanup" "Debug"
        if ($form -and -not $form.IsDisposed) {
            $form.Dispose()
            Write-AppLog "GUI form disposed after ApplicationContext exit" "Audit"
        }
    } else {
        # Fallback: original ShowDialog behaviour when TrayHost module not available
        if ($StartMinimized) {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            $form.ShowInTaskbar = $false
            Write-AppLog "TaskTray mode: starting minimized to system tray" "Audit"
        }
        Write-AppLog "Displaying GUI form window (ShowDialog fallback)" "Audit"
        _SwMark 'first-paint-showdialog'
        $form.ShowDialog() | Out-Null
        $form.Dispose()
        Write-AppLog "GUI form disposed -- application exiting" "Audit"
    }
}

# ==================== MAIN EXECUTION ====================
Write-AppLog "=====================================================================" "Audit"
Write-AppLog "PowerShell GUI Application starting..." "Info"
Write-AppLog "Computer: $env:COMPUTERNAME | User: $env:USERNAME | PowerShell: $($PSVersionTable.PSVersion)" "Info"
Write-AppLog "=====================================================================" "Audit"

# IMPL-20260405-007: Emit startup timing milestones collected so far
_SwMark 'main-execution-start'
if ($script:_StartupMilestones.Count -gt 0) {
    $timingParts = $script:_StartupMilestones | ForEach-Object { "$($_.label)=$([math]::Round($_.elapsed,1))ms" }
    Write-AppLog "Startup timing: $($timingParts -join ' | ')" "Info"
}

# ==================== CRASH RECOVERY & SESSION LOCK ====================
$crashDetected = Invoke-CrashRecovery -TempDir (Join-Path $scriptDir 'temp')
$script:LastCrashDetected = [bool]$crashDetected
$script:ExtendedSecurityLogging = [bool]$crashDetected
if ($crashDetected) {
    Write-AppLog "Previous crash detected -- recovery cleanup completed" "Warning"
    Write-AppLog "Extended security logging enabled for this session due to crash recovery" "Warning"
}
Invoke-LogRotation -LogsDir $logsDir
Write-SessionLock
Write-AppLog "Session lock written, log rotation checked" "Info"

# ==================== LAUNCH CHECK: Module Accessibility & Package Repos ====================
Write-AppLog "Launch Check: Verifying workspace modules and package repositories..." "Audit"
try {
    # Check package repositories (PSGallery / NuGet) — silently first, prompt once
    Invoke-RepositorySourceCheck -Silent
} catch { Write-AppLog "Launch Check repo check error: $_" "Warning" }
try {
    # Check workspace modules — shows Y/A/N dialog only if modules are missing
    Invoke-LaunchModuleCheck -WorkspacePath $PSScriptRoot
} catch { Write-AppLog "Launch Check module check error: $_" "Warning" }
Write-AppLog "Launch Check complete" "Info"

# Phase 0: Validate and configure paths
Write-AppLog "Phase 0: Validating application paths..." "Audit"
$pathsNeedValidation = $false

# Check if any required path is inaccessible
$requiredPaths = @($ConfigPath, $DefaultFolder, $TempFolder, $ReportFolder, $DownloadFolder)
foreach ($path in $requiredPaths) {
    if ($path) {
        $result = Test-PathReadWrite -Path $path
        if (-not $result.Readable -or -not $result.Writable) {
            $pathsNeedValidation = $true
            break
        }
    }
}

# If paths need validation or are not initialized, show the settings GUI
if ($pathsNeedValidation -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    Write-AppLog "Path validation required - showing configuration GUI" "Warning"
    Show-PathSettingsGUI
} else {
    Write-AppLog "All application paths are accessible and configured correctly" "Info"
}

# Initialize script folders config if it doesn't exist
$scriptFoldersConfigPath = Get-ProjectPath ScriptFolders
if (-not [string]::IsNullOrWhiteSpace($scriptFoldersConfigPath) -and -not (Test-Path $scriptFoldersConfigPath)) {
    $defaultConfig = @{
        metadata = @{
            version = "1.0.0"
            description = "Script folder paths configuration for PowerShell GUI Application"
            lastModified = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            format = "JSON"
        }
        customScriptFolders = @(
            @{
                path = (Join-Path $scriptsDir "QUICK-APP")
                label = "QUICK-APP Scripts"
                enabled = $true
                addedDate = (Get-Date -Format "yyyy-MM-dd")
            }
        )
    }
    Save-ScriptFoldersConfig -Config $defaultConfig
    Write-AppLog "Script folders config initialized" "Info"
}

# ensure config exists
if (-not (Test-Path $configFile)) { Initialize-ConfigFile -ConfigFile $configFile -LogsDir $logsDir -ConfigDir $configDir -ScriptsDir $scriptsDir }

Write-AppLog "Startup mode selected: $StartupMode" "Audit"

# Parse version values once for display and downstream phases
$versionInfo = Get-VersionInfo
$major = $versionInfo.Major
$minor = $versionInfo.Minor
$build = $versionInfo.Build
$hasIssues = $false
$issueDetails = @()

if ($StartupMode -eq 'slow_snr') {
    # Phase 1: Check version tags BEFORE any auto-increment
    Write-AppLog "Phase 1: Checking version tag consistency..." "Audit"
    $diffFile = Test-VersionTag

    if ($diffFile -and (Test-Path $diffFile)) {
        [xml]$diffXml = Get-Content $diffFile
        $folders = $diffXml.SelectNodes('//Folder')
        if ($folders.Count -gt 0) {
            $hasIssues = $true
            foreach($folder in $folders) {
                $files = $folder.SelectNodes('File')
                foreach($file in $files) {
                    $issue = "$($file.GetAttribute('name')) - $($file.GetAttribute('issue'))"
                    if ($file.HasAttribute('found')) {
                        $issue += " (found: $($file.GetAttribute('found')), expected: $($file.GetAttribute('expected')))"
                    }
                    $issueDetails += $issue
                }
            }
        }
    }

    # Phase 2: Display results and prompt for auto-increment
    Write-Information "" -InformationAction Continue
    Write-Information "=====================================================================" -InformationAction Continue

    if (-not $hasIssues) {
        Write-Information "ALL FILES MATCH VERSION-TAGS" -InformationAction Continue
        Write-Information "Current Version: $(Get-VersionString)" -InformationAction Continue
        Write-Information "All files are tagged properly - no auto-increment needed." -InformationAction Continue
        Write-Information "=====================================================================" -InformationAction Continue
        Write-Information "" -InformationAction Continue
    } else {
        Write-Information "VERSION-TAGS FOUND THAT DO NOT MATCH" -InformationAction Continue
        Write-Information "Current Version: $(Get-VersionString)" -InformationAction Continue
        Write-Information "" -InformationAction Continue
        Write-Information "Mismatches detected:" -InformationAction Continue
        foreach($detail in $issueDetails) {
            Write-Information "  - $detail" -InformationAction Continue
        }
        Write-Information "" -InformationAction Continue
        Write-Information "=====================================================================" -InformationAction Continue
        Write-Information "" -InformationAction Continue
        Write-Information "Type 'AA' and press ENTER to allow Auto-Increment of build number (or just press ENTER to skip):" -InformationAction Continue
        Write-Information "Response: " -InformationAction Continue

        $userInput = Read-Host

        if ($userInput -eq "AA") {
            Write-Information "" -InformationAction Continue
            Write-Information "Auto-Increment AUTHORIZED by user" -InformationAction Continue
            Write-AppLog "User authorized auto-increment" "Audit"
            Update-VersionBuild -Auto
            Write-Information "Build number incremented to: $(Get-VersionString)" -InformationAction Continue
            Write-AppLog "Updating version tags after increment..." "Audit"
            Update-VersionTag
        } else {
            Write-Information "" -InformationAction Continue
            Write-Information "BYPASSING Build mismatch as no Auto-Increment Allow Action from user" -InformationAction Continue
            Write-AppLog "User skipped auto-increment" "Audit"
        }
        Write-Information "" -InformationAction Continue
    }
} else {
    Write-AppLog "Fast startup mode: skipping Phase 1 version consistency scan and auto-increment prompt" "Info"
}

# Phase 3: Generate manifest for slow startup mode
Write-AppLog "Phase 3: Build manifest generation starting..." "Audit"
Write-AppLog "DEBUG: StartupMode detected as: $StartupMode" "Debug"
try {
    if ($StartupMode -eq 'slow_snr') {
        Write-AppLog "Generating build manifest..." "Audit"
        Write-AppLog "DEBUG: Calling New-BuildManifest for slow startup mode" "Debug"
        New-BuildManifest
        Write-AppLog "DEBUG: New-BuildManifest completed successfully" "Debug"
    } else {
        Write-AppLog "Fast startup mode: skipping build manifest generation" "Info"
        Write-AppLog "DEBUG: Manifest generation skipped due to startup mode: $StartupMode" "Debug"
    }
    Write-AppLog "Phase 3: Build manifest generation completed successfully" "Info"
} catch {
    Write-AppLog "Phase 3 ERROR: Failed to generate build manifest: $_" "Error"
    Write-AppLog "DEBUG: Full exception details:`n$($_.ScriptStackTrace)" "Debug"
    Write-AppLog "Phase 3: Continuing to Phase 4 despite manifest generation failure" "Warning"
}

# Phase 4: Display system information
Write-AppLog "Phase 4: System information display starting..." "Audit"
$rootPath = "unknown"
$scriptsPath = "unknown"
$configVersion = "unknown"
$timezone = "unknown"
$currentDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try {
    $rootPath = (Get-Location).Path
    $scriptsPath = Join-Path $rootPath "scripts"
    $versionInfo = Get-VersionInfo
    $configVersion = Get-VersionString
    $timezone = (Get-TimeZone).DisplayName
    Write-AppLog "Phase 4: System information resolved successfully" "Info"
} catch {
    Write-AppLog "Phase 4 ERROR: System information collection failed: $_" "Error"
    Write-AppLog "Phase 4: Using fallback values for system information" "Warning"
}

Write-Information "" -InformationAction Continue
Write-Information "=== END SYSTEM INFORMATION ===" -InformationAction Continue
Write-Information "Root Path:              $rootPath" -InformationAction Continue
Write-Information "Scripts:                $scriptsPath" -InformationAction Continue
Write-Information "Build from Config:      $configVersion" -InformationAction Continue
Write-Information "Current Date/Time:      $currentDateTime" -InformationAction Continue
Write-Information "Time Zone:              $timezone" -InformationAction Continue
Write-Information "=====================================================================" -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-AppLog "Phase 4: System information display completed" "Info"

# ==================== Phase 5: STARTUP INTEGRITY CHECK ====================
Write-AppLog "Phase 5: Running startup integrity check..." "Audit"
if (Get-Command Invoke-StartupIntegrityCheck -ErrorAction SilentlyContinue) {
    $integrityResult = Invoke-StartupIntegrityCheck -WorkspacePath $scriptDir -ConfigFile $configFile
    if (-not $integrityResult.Passed) {
        Write-AppLog "Phase 5: $($integrityResult.IssueCount) integrity issue(s) detected" "Warning"
        # Offer emergency unlock if vault is available
        if (Get-Command Invoke-EmergencyUnlock -ErrorAction SilentlyContinue) {
            $vaultStatus = $null
            try { $vaultStatus = Test-VaultStatus } catch { <# Intentional: non-fatal, vault may not be ready #> }
            if ($vaultStatus -and $vaultStatus.State -in @('Unlocked','Open')) {
                $emergency = Invoke-EmergencyUnlock -WorkspacePath $scriptDir
                if ($emergency.Granted) {
                    Write-AppLog "Phase 5: Emergency unlock GRANTED — continuing in degraded mode" "Critical"
                }
            }
        }
    } else {
        Write-AppLog "Phase 5: All integrity checks passed" "Info"
    }
} else {
    # Fallback: inline checks when IntegrityCore module is unavailable
    $integrityIssues = @()
    foreach ($modName in @('PwShGUICore')) {
        if (-not (Get-Module -Name $modName)) { $integrityIssues += "Module '$modName' is not loaded" }
    }
    foreach ($dirEntry in @(
        @{ Name = 'scripts';  Path = $scriptsDir },
        @{ Name = 'config';   Path = $configDir  },
        @{ Name = 'modules';  Path = (Join-Path $scriptDir 'modules') },
        @{ Name = 'logs';     Path = $logsDir    }
    )) {
        if (-not (Test-Path $dirEntry.Path)) { $integrityIssues += "Required directory '$($dirEntry.Name)' missing at $($dirEntry.Path)" }
    }
    if ($configFile -and (Test-Path $configFile)) {
        try { [xml]$null = Get-Content $configFile -ErrorAction Stop } catch { $integrityIssues += "Config file is not valid XML: $configFile" }
    } else { $integrityIssues += "Config file not found: $configFile" }
    if (@($integrityIssues).Count -gt 0) {
        foreach ($issue in $integrityIssues) { Write-AppLog "Integrity issue (fallback): $issue" "Warning" }
        Write-AppLog "Phase 5 (fallback): Completed with $(@($integrityIssues).Count) issue(s)" "Warning"
    } else {
        Write-AppLog "Phase 5 (fallback): All integrity checks passed" "Info"
    }
}

Write-AppLog "Creating and displaying GUI..." "Audit"
if ($TaskTray) {
    Write-AppLog "TaskTray switch active -- GUI will start minimized to system tray" "Audit"
}
try {
    # Create the GUI
    if ($TaskTray) {
        New-GUI -StartMinimized
    } else {
        New-GUI
    }
    Write-AppLog "GUI closed successfully" "Info"
}
catch {
    Write-AppLog "Error in GUI creation: $_" "Error"
    Write-AppLog "Stack Trace: $($_.ScriptStackTrace)" "Error"
}

Write-AppLog "=====================================================================" "Audit"
Write-AppLog "PowerShell GUI Application closed" "Info"
Write-AppLog "=====================================================================" "Audit"

# Clean up session lock and flush remaining log entries
Remove-SessionLock
Export-LogBuffer







