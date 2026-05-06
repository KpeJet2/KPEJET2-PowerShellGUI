# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
#Requires -Version 5.1
<#
.SYNOPSIS  MCP Service Configuration -- manage MCP servers from the GUI.
.DESCRIPTION
    Reads .vscode/mcp.json to list all configured MCP servers.
    Main tab shows server overview with status (Installed/Missing/Running/Stopped).
    Per-server tabs expose config editing, start/stop/restart, backup, and test.
    Status bar shows live service state.
#>

# ── Module import ─────────────────────────────────────────────────────────────
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUICore.psm1'
if (Test-Path $modulePath) { try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-MCPConfigPath {
    param([string]$ProjectRoot)
    return (Join-Path $ProjectRoot '.vscode\mcp.json')
}

function Read-MCPConfig {
    <#
    .SYNOPSIS  Read and parse .vscode/mcp.json safely.
    #>
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) { return $null }
    try {
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-MCPConfig {
    <#
    .SYNOPSIS  Write mcp.json back with formatting.
    #>
    param([string]$ConfigPath, [object]$Config)
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigPath, $json, [System.Text.Encoding]::UTF8)
}

function Backup-MCPConfig {
    param([string]$ConfigPath, [string]$BackupDir)
    if (-not (Test-Path $ConfigPath)) { return $null }
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "mcp_backup_$ts.json"
    Copy-Item -Path $ConfigPath -Destination $dest -Force
    return $dest
}

function Test-MCPServerReachable {
    <#
    .SYNOPSIS  Lightweight connectivity test for an MCP server definition.
    #>
    param([string]$ServerName, [PSCustomObject]$ServerDef)
    $result = @{ Name = $ServerName; Status = 'Unknown'; Detail = '' }

    $serverType = if ($ServerDef.PSObject.Properties['type']) { $ServerDef.type } else { 'stdio' }

    if ($serverType -eq 'http') {
        $url = if ($ServerDef.PSObject.Properties['url']) { $ServerDef.url } else { '' }
        if (-not $url) {
            $result.Status = 'No URL'
            $result.Detail = 'HTTP server has no url defined'
            return $result
        }
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Timeout = 3000
            $req.Method  = 'HEAD'
            $resp = $req.GetResponse()
            $resp.Close()
            $result.Status = 'Reachable'
            $result.Detail = "HTTP $($resp.StatusCode)"
        } catch {
            $result.Status = 'Unreachable'
            $result.Detail = $_.Exception.InnerException.Message
            if (-not $result.Detail) { $result.Detail = $_.Exception.Message }
        }
    } elseif ($serverType -eq 'stdio') {
        $cmd = if ($ServerDef.PSObject.Properties['command']) { $ServerDef.command } else { '' }
        if (-not $cmd) {
            $result.Status = 'No Command'
            $result.Detail = 'stdio server has no command defined'
            return $result
        }
        $found = $null
        try { $found = Get-Command $cmd -ErrorAction SilentlyContinue } catch { Write-Warning "[MCPConfig] Command check error for '$cmd': $_" }
        if ($found) {
            $result.Status = 'Installed'
            $result.Detail = "Command '$cmd' found at $($found.Source)"
        } else {
            $result.Status = 'Missing'
            $result.Detail = "Command '$cmd' not found in PATH"
        }
    } else {
        $result.Status = 'Unknown Type'
        $result.Detail = "Server type '$serverType' not recognised"
    }
    return $result
}

function Get-MCPServerSummary {
    <#
    .SYNOPSIS  Build a summary array of all MCP servers from config.
    #>
    param([PSCustomObject]$Config)
    $rows = @()
    if (-not $Config -or -not $Config.PSObject.Properties['servers']) { return $rows }
    $servers = $Config.servers
    foreach ($prop in $servers.PSObject.Properties) {
        $name = $prop.Name
        $def  = $prop.Value
        $serverType = if ($def.PSObject.Properties['type']) { $def.type } else { 'stdio' }
        $cmd  = ''
        if ($serverType -eq 'stdio') {
            $cmd = if ($def.PSObject.Properties['command']) { $def.command } else { '-' }
        } elseif ($serverType -eq 'http') {
            $cmd = if ($def.PSObject.Properties['url']) { $def.url } else { '-' }
        }
        $rows += [PSCustomObject]@{
            Name    = $name
            Type    = $serverType
            Command = $cmd
            Status  = '...'
        }
    }
    return $rows
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN FUNCTION
# ══════════════════════════════════════════════════════════════════════════════

function Show-MCPServiceConfig {
    [CmdletBinding()]
    param()

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $configPath  = Get-MCPConfigPath -ProjectRoot $projectRoot
    $backupDir   = Join-Path $projectRoot 'config\mcp-backups'

    # ── Read config ───────────────────────────────────────────────────────────
    $script:mcpConfig = Read-MCPConfig -ConfigPath $configPath
    if (-not $script:mcpConfig) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read .vscode/mcp.json.`nPath: $configPath",
            'MCP Config Missing', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  FORM
    # ══════════════════════════════════════════════════════════════════════════
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'MCP Service Configuration'
    $form.Size            = New-Object System.Drawing.Size(1060, 720)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimumSize     = New-Object System.Drawing.Size(800, 520)
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    # Apply PwShGUI-Theme if available
    try {
        $themeMod = Join-Path $projectRoot 'modules\PwShGUI-Theme.psm1'
        if (Test-Path $themeMod) {
            try { Import-Module $themeMod -Force -ErrorAction Stop } catch { Write-Warning "Failed to import theme module: $_" }
            if (Get-Command Set-PwShGUITheme -ErrorAction SilentlyContinue) {
                Set-PwShGUITheme -Form $form
            }
        }
    } catch { Write-Warning "[MCPConfig] Theme load error: $_" }

    # ── Status bar ────────────────────────────────────────────────────────────
    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'MCP Service Config -- Ready'
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = 'MiddleLeft'
    $statusBar.Items.Add($statusLabel) | Out-Null

    $statusCountLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusCountLabel.Text = ''
    $statusCountLabel.TextAlign = 'MiddleRight'
    $statusBar.Items.Add($statusCountLabel) | Out-Null
    $form.Controls.Add($statusBar)

    # ── Tab control ───────────────────────────────────────────────────────────
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = 'Fill'

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB 1: SERVER OVERVIEW
    # ══════════════════════════════════════════════════════════════════════════
    $tabOverview = New-Object System.Windows.Forms.TabPage
    $tabOverview.Text = 'All MCP Servers'

    # Toolbar panel
    $pnlToolbar = New-Object System.Windows.Forms.Panel
    $pnlToolbar.Dock   = 'Top'
    $pnlToolbar.Height = 40

    $btnRefreshAll = New-Object System.Windows.Forms.Button
    $btnRefreshAll.Text     = 'Refresh Status'
    $btnRefreshAll.Location = New-Object System.Drawing.Point(4, 6)
    $btnRefreshAll.Size     = New-Object System.Drawing.Size(120, 28)

    $btnBackup = New-Object System.Windows.Forms.Button
    $btnBackup.Text     = 'Backup Config'
    $btnBackup.Location = New-Object System.Drawing.Point(130, 6)
    $btnBackup.Size     = New-Object System.Drawing.Size(110, 28)

    $btnOpenJson = New-Object System.Windows.Forms.Button
    $btnOpenJson.Text     = 'Open mcp.json'
    $btnOpenJson.Location = New-Object System.Drawing.Point(246, 6)
    $btnOpenJson.Size     = New-Object System.Drawing.Size(110, 28)

    $btnTestAll = New-Object System.Windows.Forms.Button
    $btnTestAll.Text     = 'Test All'
    $btnTestAll.Location = New-Object System.Drawing.Point(362, 6)
    $btnTestAll.Size     = New-Object System.Drawing.Size(80, 28)

    $pnlToolbar.Controls.AddRange(@($btnRefreshAll, $btnBackup, $btnOpenJson, $btnTestAll))
    $tabOverview.Controls.Add($pnlToolbar)

    # DataGridView for server list
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Dock              = 'Fill'
    $dgv.AllowUserToAddRows    = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.ReadOnly          = $true
    $dgv.SelectionMode     = 'FullRowSelect'
    $dgv.AutoSizeColumnsMode = 'Fill'
    $dgv.RowHeadersVisible = $false
    $dgv.BackgroundColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $dgv.ForeColor         = [System.Drawing.Color]::White
    $dgv.GridColor         = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $dgv.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
    $dgv.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $dgv.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $dgv.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $dgv.EnableHeadersVisualStyles = $false

    $colName    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = 'Server Name'
    $colName.Name       = 'Name'
    $colName.FillWeight = 30

    $colType    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colType.HeaderText = 'Type'
    $colType.Name       = 'Type'
    $colType.FillWeight = 12

    $colCommand = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCommand.HeaderText = 'Command / URL'
    $colCommand.Name       = 'Command'
    $colCommand.FillWeight = 40

    $colStatus  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = 'Status'
    $colStatus.Name       = 'Status'
    $colStatus.FillWeight = 18

    $dgv.Columns.AddRange(@($colName, $colType, $colCommand, $colStatus))

    # ── Populate grid ─────────────────────────────────────────────────────────
    $script:serverRows = Get-MCPServerSummary -Config $script:mcpConfig

    function Populate-OverviewGrid {
        $dgv.Rows.Clear()
        foreach ($r in $script:serverRows) {
            [void]$dgv.Rows.Add($r.Name, $r.Type, $r.Command, $r.Status)
        }
        $statusCountLabel.Text = "$($script:serverRows.Count) server(s)"
    }

    function Update-AllStatuses {
        $statusLabel.Text = 'Testing servers...'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()

        $servers = $script:mcpConfig.servers
        $idx = 0
        foreach ($prop in $servers.PSObject.Properties) {
            $test = Test-MCPServerReachable -ServerName $prop.Name -ServerDef $prop.Value
            if ($idx -lt $script:serverRows.Count) {
                $script:serverRows[$idx].Status = $test.Status
            }
            if ($idx -lt $dgv.Rows.Count) {
                $dgv.Rows[$idx].Cells['Status'].Value = $test.Status
                $dgv.Rows[$idx].Cells['Status'].ToolTipText = $test.Detail
                # Colour-code status cells
                switch ($test.Status) {
                    'Reachable'  { $dgv.Rows[$idx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::LimeGreen }
                    'Installed'  { $dgv.Rows[$idx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 120) }
                    'Missing'    { $dgv.Rows[$idx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::OrangeRed }
                    'Unreachable'{ $dgv.Rows[$idx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::OrangeRed }
                    default      { $dgv.Rows[$idx].Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Gold }
                }
            }
            $idx++
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $statusLabel.Text = "Status check complete -- $(Get-Date -Format 'HH:mm:ss')"
    }

    Populate-OverviewGrid

    # ── Status colouring guard ────────────────────────────────────────────────
    $script:_OverviewFormatted = $false
    if (-not $script:_OverviewFormatted) {
        $script:_OverviewFormatted = $true
        $dgv.Add_CellFormatting({
            param($s, $e)
            if ($e.ColumnIndex -eq 3 -and $e.RowIndex -ge 0) {
                $val = "$($e.Value)"
                switch ($val) {
                    'Reachable'  { $e.CellStyle.ForeColor = [System.Drawing.Color]::LimeGreen }
                    'Installed'  { $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 120) }
                    'Missing'    { $e.CellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                    'Unreachable'{ $e.CellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                }
            }
        })
    }

    $tabOverview.Controls.Add($dgv)
    $tabControl.TabPages.Add($tabOverview)

    # ══════════════════════════════════════════════════════════════════════════
    #  PER-SERVER TABS
    # ══════════════════════════════════════════════════════════════════════════
    $script:serverTextBoxes = @{}

    foreach ($prop in $script:mcpConfig.servers.PSObject.Properties) {
        $srvName = $prop.Name
        $srvDef  = $prop.Value

        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $srvName
        $tab.Tag  = $srvName

        # ── Button panel ──────────────────────────────────────────────────────
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.Dock   = 'Top'
        $pnl.Height = 40

        $btnTest = New-Object System.Windows.Forms.Button
        $btnTest.Text     = 'Test'
        $btnTest.Location = New-Object System.Drawing.Point(4, 6)
        $btnTest.Size     = New-Object System.Drawing.Size(70, 28)
        $btnTest.Tag      = $srvName

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text     = 'Save'
        $btnSave.Location = New-Object System.Drawing.Point(80, 6)
        $btnSave.Size     = New-Object System.Drawing.Size(70, 28)
        $btnSave.Tag      = $srvName

        $btnBackupSrv = New-Object System.Windows.Forms.Button
        $btnBackupSrv.Text     = 'Backup'
        $btnBackupSrv.Location = New-Object System.Drawing.Point(156, 6)
        $btnBackupSrv.Size     = New-Object System.Drawing.Size(80, 28)
        $btnBackupSrv.Tag      = $srvName

        $btnReload = New-Object System.Windows.Forms.Button
        $btnReload.Text     = 'Reload'
        $btnReload.Location = New-Object System.Drawing.Point(242, 6)
        $btnReload.Size     = New-Object System.Drawing.Size(80, 28)
        $btnReload.Tag      = $srvName

        $pnl.Controls.AddRange(@($btnTest, $btnSave, $btnBackupSrv, $btnReload))
        $tab.Controls.Add($pnl)

        # ── Config editor (JSON text) ─────────────────────────────────────────
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Dock      = 'Fill'
        $txt.Multiline = $true
        $txt.ScrollBars = 'Both'
        $txt.WordWrap  = $false
        $txt.Font      = New-Object System.Drawing.Font('Consolas', 10)
        $txt.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $txt.ForeColor = [System.Drawing.Color]::FromArgb(212, 212, 212)

        $srvJson = $srvDef | ConvertTo-Json -Depth 10
        $txt.Text = $srvJson
        $txt.Tag  = $srvName

        $script:serverTextBoxes[$srvName] = $txt

        $tab.Controls.Add($txt)

        # ── Button click handlers ─────────────────────────────────────────────
        $btnTest.Add_Click({
            $name = $this.Tag
            $def  = $script:mcpConfig.servers.$name
            $test = Test-MCPServerReachable -ServerName $name -ServerDef $def
            $statusLabel.Text = "$name -- $($test.Status): $($test.Detail)"
            [System.Windows.Forms.MessageBox]::Show(
                "Server: $name`nStatus: $($test.Status)`n$($test.Detail)",
                'MCP Test Result', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        })

        $btnSave.Add_Click({
            $name = $this.Tag
            $tb   = $script:serverTextBoxes[$name]
            try {
                $parsed = $tb.Text | ConvertFrom-Json
                $script:mcpConfig.servers.$name = $parsed
                Write-MCPConfig -ConfigPath $configPath -Config $script:mcpConfig
                $statusLabel.Text = "Saved config for '$name' -- $(Get-Date -Format 'HH:mm:ss')"
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Invalid JSON for '$name':`n$($_.Exception.Message)",
                    'Save Error', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        })

        $btnBackupSrv.Add_Click({
            $dest = Backup-MCPConfig -ConfigPath $configPath -BackupDir $backupDir
            if ($dest) {
                $statusLabel.Text = "Backup created: $dest"
            } else {
                $statusLabel.Text = 'Backup failed -- config file not found'
            }
        })

        $btnReload.Add_Click({
            $name = $this.Tag
            $script:mcpConfig = Read-MCPConfig -ConfigPath $configPath
            if ($script:mcpConfig -and $script:mcpConfig.servers.PSObject.Properties[$name]) {
                $tb = $script:serverTextBoxes[$name]
                $tb.Text = ($script:mcpConfig.servers.$name | ConvertTo-Json -Depth 10)
                $statusLabel.Text = "Reloaded config for '$name'"
            }
        })

        $tabControl.TabPages.Add($tab)
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  TAB: ADD NEW SERVER
    # ══════════════════════════════════════════════════════════════════════════
    $tabAdd = New-Object System.Windows.Forms.TabPage
    $tabAdd.Text = '+ Add Server'

    $addPanel = New-Object System.Windows.Forms.Panel
    $addPanel.Dock = 'Fill'
    $addPanel.Padding = New-Object System.Windows.Forms.Padding(16)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text     = 'Server Name:'
    $lblName.Location = New-Object System.Drawing.Point(16, 20)
    $lblName.AutoSize = $true

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(130, 17)
    $txtName.Size     = New-Object System.Drawing.Size(300, 24)

    $lblType = New-Object System.Windows.Forms.Label
    $lblType.Text     = 'Type:'
    $lblType.Location = New-Object System.Drawing.Point(16, 54)
    $lblType.AutoSize = $true

    $cmbType = New-Object System.Windows.Forms.ComboBox
    $cmbType.Location = New-Object System.Drawing.Point(130, 51)
    $cmbType.Size     = New-Object System.Drawing.Size(150, 24)
    $cmbType.DropDownStyle = 'DropDownList'
    [void]$cmbType.Items.Add('stdio')
    [void]$cmbType.Items.Add('http')
    $cmbType.SelectedIndex = 0

    $lblDef = New-Object System.Windows.Forms.Label
    $lblDef.Text     = 'Server definition (JSON):'
    $lblDef.Location = New-Object System.Drawing.Point(16, 90)
    $lblDef.AutoSize = $true

    $txtDef = New-Object System.Windows.Forms.TextBox
    $txtDef.Location  = New-Object System.Drawing.Point(16, 112)
    $txtDef.Size      = New-Object System.Drawing.Size(580, 300)
    $txtDef.Multiline = $true
    $txtDef.ScrollBars = 'Both'
    $txtDef.WordWrap  = $false
    $txtDef.Font      = New-Object System.Drawing.Font('Consolas', 10)
    $txtDef.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtDef.ForeColor = [System.Drawing.Color]::FromArgb(212, 212, 212)
    $txtDef.Text      = @'
{
  "type": "stdio",
  "command": "",
  "args": []
}
'@

    $btnAddServer = New-Object System.Windows.Forms.Button
    $btnAddServer.Text     = 'Add Server to Config'
    $btnAddServer.Location = New-Object System.Drawing.Point(16, 422)
    $btnAddServer.Size     = New-Object System.Drawing.Size(200, 32)

    $btnAddServer.Add_Click({
        $newName = $txtName.Text.Trim()
        if (-not $newName) {
            [System.Windows.Forms.MessageBox]::Show('Enter a server name.', 'Validation',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($script:mcpConfig.servers.PSObject.Properties[$newName]) {
            [System.Windows.Forms.MessageBox]::Show("Server '$newName' already exists.", 'Duplicate',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        try {
            $parsed = $txtDef.Text | ConvertFrom-Json
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Invalid JSON:`n$($_.Exception.Message)", 'Parse Error',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        # Backup before modification
        Backup-MCPConfig -ConfigPath $configPath -BackupDir $backupDir | Out-Null
        $script:mcpConfig.servers | Add-Member -NotePropertyName $newName -NotePropertyValue $parsed -Force
        Write-MCPConfig -ConfigPath $configPath -Config $script:mcpConfig
        $statusLabel.Text = "Added server '$newName' -- $(Get-Date -Format 'HH:mm:ss')"
        [System.Windows.Forms.MessageBox]::Show(
            "Server '$newName' added to mcp.json.`nRestart the MCP Config tool to see its tab.",
            'Server Added', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    })

    $addPanel.Controls.AddRange(@($lblName, $txtName, $lblType, $cmbType, $lblDef, $txtDef, $btnAddServer))
    $tabAdd.Controls.Add($addPanel)
    $tabControl.TabPages.Add($tabAdd)

    # ══════════════════════════════════════════════════════════════════════════
    #  OVERVIEW BUTTON HANDLERS
    # ══════════════════════════════════════════════════════════════════════════
    $btnRefreshAll.Add_Click({
        $script:mcpConfig = Read-MCPConfig -ConfigPath $configPath
        $script:serverRows = Get-MCPServerSummary -Config $script:mcpConfig
        Populate-OverviewGrid
        Update-AllStatuses
    })

    $btnBackup.Add_Click({
        $dest = Backup-MCPConfig -ConfigPath $configPath -BackupDir $backupDir
        if ($dest) {
            $statusLabel.Text = "Backup saved: $dest"
            [System.Windows.Forms.MessageBox]::Show("Backup created:`n$dest", 'Backup',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

    $btnOpenJson.Add_Click({
        if (Test-Path $configPath) {
            Start-Process $configPath
        } else {
            [System.Windows.Forms.MessageBox]::Show('mcp.json not found.', 'Missing',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })

    $btnTestAll.Add_Click({
        Update-AllStatuses
    })

    # ══════════════════════════════════════════════════════════════════════════
    #  ASSEMBLE & SHOW
    # ══════════════════════════════════════════════════════════════════════════
    $form.Controls.Add($tabControl)
    $form.Add_Shown({ Update-AllStatuses })
    [void]$form.ShowDialog()
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




