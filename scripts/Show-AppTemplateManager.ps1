# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
#Requires -Version 5.1
<#
.SYNOPSIS  App Install Template Manager -- 3-pane GUI for JSON template-based
           application inventory, gap analysis, and winget install orchestration.
.DESCRIPTION
    Pane 1 (top):   Load / Save / Browse JSON templates. Loaded apps shown with checkboxes.
    Pane 2 (middle): Apps from selection that are missing or outdated on the system.
    Pane 3 (bottom): Currently installed apps (winget list). Save selection as template,
                     search for updates, view update candidates in Pane 2.
#>

# ── Module import ─────────────────────────────────────────────────────────────
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUICore.psm1'
if (Test-Path $modulePath) { try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-WingetInstalledApps {
    <# Returns [hashtable] keyed by approximate winget Id with value = version string #>
    $result = @{}
    try {
        $raw = & winget list --accept-source-agreements 2>&1 | Out-String
        $lines = $raw -split "`n" | Where-Object { $_.Trim() -ne '' }
        # Find header line to determine column offsets
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Name\s+Id\s+Version') { $headerIdx = $i; break }
        }
        if ($headerIdx -lt 0) { return $result }
        $header = $lines[$headerIdx]
        $idStart  = $header.IndexOf('Id')
        $verStart = $header.IndexOf('Version')
        $srcStart = $header.IndexOf('Source')
        if ($srcStart -lt 0) { $srcStart = $header.Length }

        for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.Length -lt $verStart + 1) { continue }
            $appId   = $line.Substring($idStart, [Math]::Min($verStart - $idStart, $line.Length - $idStart)).Trim()
            $appVer  = $line.Substring($verStart, [Math]::Min($srcStart - $verStart, $line.Length - $verStart)).Trim()
            if ($appId -and $appId -ne '---') { $result[$appId] = $appVer }
        }
    } catch { <# Intentional: non-fatal -- winget may not be available #> }
    return $result
}

function Get-WingetUpgradeList {
    <# Returns [hashtable] of upgradable apps: Id -> available version #>
    $result = @{}
    try {
        $raw = & winget upgrade --accept-source-agreements 2>&1 | Out-String
        $lines = $raw -split "`n" | Where-Object { $_.Trim() -ne '' }
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Name\s+Id\s+Version\s+Available') { $headerIdx = $i; break }
        }
        if ($headerIdx -lt 0) { return $result }
        $header   = $lines[$headerIdx]
        $idStart  = $header.IndexOf('Id')
        $verStart = $header.IndexOf('Version')
        $avlStart = $header.IndexOf('Available')
        $srcStart = $header.IndexOf('Source')
        if ($srcStart -lt 0) { $srcStart = $header.Length }

        for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.Length -lt $avlStart + 1) { continue }
            $appId  = $line.Substring($idStart, [Math]::Min($verStart - $idStart, $line.Length - $idStart)).Trim()
            $newVer = $line.Substring($avlStart, [Math]::Min($srcStart - $avlStart, $line.Length - $avlStart)).Trim()
            if ($appId -and $newVer -and $appId -ne '---') { $result[$appId] = $newVer }
        }
    } catch { <# Intentional: non-fatal -- winget may not be available #> }
    return $result
}

function Compare-VersionStrings {
    param([string]$Current, [string]$Minimum)
    if (-not $Minimum -or $Minimum -eq '') { return $true }
    try {
        $c = [version]($Current -replace '[^0-9.]','')
        $m = [version]($Minimum -replace '[^0-9.]','')
        return $c -ge $m
    } catch { return $true }
}

# ── Main form builder ─────────────────────────────────────────────────────────

function Show-AppTemplateManager {
    [CmdletBinding()]
    param()

    $templateDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\APP-INSTALL-TEMPLATES'
    if (-not (Test-Path $templateDir)) { New-Item -ItemType Directory -Path $templateDir -Force | Out-Null }

    # ── State ──
    $script:loadedApps    = @()   # array of PSCustomObject from JSON
    $script:installedApps = @{}   # Id -> version (winget list cache)
    $script:upgradeList   = @{}   # Id -> available version

    # ══════════════════════════════════════════════════════════════════════════
    #  FORM
    # ══════════════════════════════════════════════════════════════════════════
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'App Install Template Manager'
    $form.Size            = New-Object System.Drawing.Size(920, 780)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimumSize     = New-Object System.Drawing.Size(800, 600)
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready'
    $statusBar.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusBar)

    # ══════════════════════════════════════════════════════════════════════════
    #  PANE 1 -- Template Loader (top ~240px)
    # ══════════════════════════════════════════════════════════════════════════
    $groupPane1 = New-Object System.Windows.Forms.GroupBox
    $groupPane1.Text     = 'Pane 1 -- App Templates'
    $groupPane1.Dock     = 'Top'
    $groupPane1.Height   = 240
    $groupPane1.Padding  = New-Object System.Windows.Forms.Padding(6)

    # Top toolbar row
    $pnlToolbar = New-Object System.Windows.Forms.Panel
    $pnlToolbar.Dock   = 'Top'
    $pnlToolbar.Height = 36

    $btnLoad = New-Object System.Windows.Forms.Button
    $btnLoad.Text = 'Load Template'
    $btnLoad.Location = New-Object System.Drawing.Point(4, 4)
    $btnLoad.Size = New-Object System.Drawing.Size(110, 28)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(120, 4)
    $btnBrowse.Size = New-Object System.Drawing.Size(90, 28)

    $btnSaveTemplate = New-Object System.Windows.Forms.Button
    $btnSaveTemplate.Text = 'Save Template'
    $btnSaveTemplate.Location = New-Object System.Drawing.Point(216, 4)
    $btnSaveTemplate.Size = New-Object System.Drawing.Size(110, 28)

    $cboTemplates = New-Object System.Windows.Forms.ComboBox
    $cboTemplates.Location = New-Object System.Drawing.Point(332, 6)
    $cboTemplates.Size = New-Object System.Drawing.Size(280, 24)
    $cboTemplates.DropDownStyle = 'DropDownList'

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = 'Select All'
    $btnSelectAll.Location = New-Object System.Drawing.Point(620, 4)
    $btnSelectAll.Size = New-Object System.Drawing.Size(80, 28)

    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = 'Select None'
    $btnSelectNone.Location = New-Object System.Drawing.Point(705, 4)
    $btnSelectNone.Size = New-Object System.Drawing.Size(90, 28)

    $pnlToolbar.Controls.AddRange(@($btnLoad, $btnBrowse, $btnSaveTemplate, $cboTemplates, $btnSelectAll, $btnSelectNone))
    $groupPane1.Controls.Add($pnlToolbar)

    # Template app checklist
    $clbApps = New-Object System.Windows.Forms.CheckedListBox
    $clbApps.Dock = 'Fill'
    $clbApps.CheckOnClick = $true
    $clbApps.Font = New-Object System.Drawing.Font('Consolas', 9)
    $groupPane1.Controls.Add($clbApps)

    $form.Controls.Add($groupPane1)

    # ══════════════════════════════════════════════════════════════════════════
    #  PANE 2 -- Missing / Outdated (middle ~200px)
    # ══════════════════════════════════════════════════════════════════════════
    $groupPane2 = New-Object System.Windows.Forms.GroupBox
    $groupPane2.Text   = 'Pane 2 -- Missing or Outdated'
    $groupPane2.Dock   = 'Top'
    $groupPane2.Height = 200

    $dgvMissing = New-Object System.Windows.Forms.DataGridView
    $dgvMissing.Dock = 'Fill'
    $dgvMissing.ReadOnly = $true
    $dgvMissing.AllowUserToAddRows = $false
    $dgvMissing.AutoSizeColumnsMode = 'Fill'
    $dgvMissing.SelectionMode = 'FullRowSelect'
    $dgvMissing.RowHeadersVisible = $false
    @('App Name','Winget ID','Required Version','Installed Version','Status') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_
        $col.Name = $_ -replace ' ',''
        $dgvMissing.Columns.Add($col) | Out-Null
    }
    # Add Install Selected button bar
    $pnlPane2Buttons = New-Object System.Windows.Forms.Panel
    $pnlPane2Buttons.Dock   = 'Bottom'
    $pnlPane2Buttons.Height = 34

    $btnInstallSelected = New-Object System.Windows.Forms.Button
    $btnInstallSelected.Text = 'Install / Update Selected'
    $btnInstallSelected.Location = New-Object System.Drawing.Point(4, 3)
    $btnInstallSelected.Size = New-Object System.Drawing.Size(170, 28)

    $btnRefreshGap = New-Object System.Windows.Forms.Button
    $btnRefreshGap.Text = 'Refresh Gap Analysis'
    $btnRefreshGap.Location = New-Object System.Drawing.Point(180, 3)
    $btnRefreshGap.Size = New-Object System.Drawing.Size(155, 28)

    $pnlPane2Buttons.Controls.AddRange(@($btnInstallSelected, $btnRefreshGap))
    $groupPane2.Controls.Add($dgvMissing)
    $groupPane2.Controls.Add($pnlPane2Buttons)

    $form.Controls.Add($groupPane2)

    # ══════════════════════════════════════════════════════════════════════════
    #  PANE 3 -- Installed Apps (bottom, fills remaining)
    # ══════════════════════════════════════════════════════════════════════════
    $groupPane3 = New-Object System.Windows.Forms.GroupBox
    $groupPane3.Text = 'Pane 3 -- Installed Applications'
    $groupPane3.Dock = 'Fill'

    $dgvInstalled = New-Object System.Windows.Forms.DataGridView
    $dgvInstalled.Dock = 'Fill'
    $dgvInstalled.ReadOnly = $true
    $dgvInstalled.AllowUserToAddRows = $false
    $dgvInstalled.AutoSizeColumnsMode = 'Fill'
    $dgvInstalled.SelectionMode = 'FullRowSelect'
    $dgvInstalled.RowHeadersVisible = $false
    @('App ID','Installed Version') | ForEach-Object {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $_
        $col.Name = $_ -replace ' ',''
        $dgvInstalled.Columns.Add($col) | Out-Null
    }

    $pnlPane3Buttons = New-Object System.Windows.Forms.Panel
    $pnlPane3Buttons.Dock   = 'Bottom'
    $pnlPane3Buttons.Height = 34

    $btnSaveInstalled = New-Object System.Windows.Forms.Button
    $btnSaveInstalled.Text = 'Save Installed as Template'
    $btnSaveInstalled.Location = New-Object System.Drawing.Point(4, 3)
    $btnSaveInstalled.Size = New-Object System.Drawing.Size(170, 28)

    $btnCheckUpdates = New-Object System.Windows.Forms.Button
    $btnCheckUpdates.Text = 'Check for Updates'
    $btnCheckUpdates.Location = New-Object System.Drawing.Point(180, 3)
    $btnCheckUpdates.Size = New-Object System.Drawing.Size(140, 28)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(330, 5)
    $txtSearch.Size = New-Object System.Drawing.Size(220, 24)
    $txtSearch.PlaceholderText = 'Search installed apps...'

    $pnlPane3Buttons.Controls.AddRange(@($btnSaveInstalled, $btnCheckUpdates, $txtSearch))
    $groupPane3.Controls.Add($dgvInstalled)
    $groupPane3.Controls.Add($pnlPane3Buttons)

    $form.Controls.Add($groupPane3)

    # ══════════════════════════════════════════════════════════════════════════
    #  HELPER FUNCTIONS (closures over form controls)
    # ══════════════════════════════════════════════════════════════════════════

    function Refresh-TemplateDropdown {
        $cboTemplates.Items.Clear()
        $jsonFiles = Get-ChildItem -Path $templateDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($f in $jsonFiles) {
            $cboTemplates.Items.Add($f.Name) | Out-Null
        }
        if ($cboTemplates.Items.Count -gt 0) { $cboTemplates.SelectedIndex = 0 }
    }

    function Load-TemplateFile {
        param([string]$FilePath)
        $clbApps.Items.Clear()
        $script:loadedApps = @()
        try {
            $json = Get-Content $FilePath -Raw | ConvertFrom-Json
            foreach ($app in $json.applications) {
                $display = '{0,-32} [{1}]  min:{2}' -f $app.name, $app.wingetId, $(if ($app.minVersion) { $app.minVersion } else { 'any' })
                $idx = $clbApps.Items.Add($display)
                $clbApps.SetItemChecked($idx, $true)
                $script:loadedApps += [PSCustomObject]@{
                    Name       = $app.name
                    WingetId   = $app.wingetId
                    Publisher  = $app.publisher
                    MinVersion = $app.minVersion
                    Category   = $app.category
                    Required   = [bool]$app.required
                }
            }
            $statusLabel.Text = "Loaded $($json.applications.Count) apps from $(Split-Path $FilePath -Leaf)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to load template:`n$($_.Exception.Message)", 'Load Error',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }

    function Refresh-InstalledGrid {
        param([string]$Filter = '')
        $dgvInstalled.Rows.Clear()
        foreach ($kv in $script:installedApps.GetEnumerator() | Sort-Object Key) {
            if ($Filter -and $kv.Key -notlike "*$Filter*") { continue }
            $dgvInstalled.Rows.Add($kv.Key, $kv.Value) | Out-Null
        }
        $statusLabel.Text = "Installed apps: $($dgvInstalled.Rows.Count)"
    }

    function Refresh-GapAnalysis {
        $dgvMissing.Rows.Clear()
        $checkedIndices = @()
        for ($i = 0; $i -lt $clbApps.Items.Count; $i++) {
            if ($clbApps.GetItemChecked($i)) { $checkedIndices += $i }
        }
        foreach ($idx in $checkedIndices) {
            if ($idx -ge $script:loadedApps.Count) { continue }
            $app = $script:loadedApps[$idx]
            $installedVer = $null
            # Try exact match first, then partial match
            if ($script:installedApps.ContainsKey($app.WingetId)) {
                $installedVer = $script:installedApps[$app.WingetId]
            } else {
                $match = $script:installedApps.Keys | Where-Object { $_ -like "*$($app.WingetId)*" } | Select-Object -First 1
                if ($match) { $installedVer = $script:installedApps[$match] }
            }

            $status = 'OK'
            if (-not $installedVer) {
                $status = 'NOT INSTALLED'
            } elseif ($app.MinVersion -and -not (Compare-VersionStrings -Current $installedVer -Minimum $app.MinVersion)) {
                $status = 'OUTDATED'
            } elseif ($script:upgradeList.ContainsKey($app.WingetId)) {
                $status = "UPDATE AVAILABLE ($($script:upgradeList[$app.WingetId]))"
            }

            if ($status -ne 'OK') {
                $rowIdx = $dgvMissing.Rows.Add($app.Name, $app.WingetId, $app.MinVersion, $installedVer, $status)
                if ($status -eq 'NOT INSTALLED') {
                    $dgvMissing.Rows[$rowIdx].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
                } elseif ($status -eq 'OUTDATED') {
                    $dgvMissing.Rows[$rowIdx].DefaultCellStyle.BackColor = [System.Drawing.Color]::LemonChiffon
                } else {
                    $dgvMissing.Rows[$rowIdx].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCyan
                }
            }
        }
        $statusLabel.Text = "Gap analysis: $($dgvMissing.Rows.Count) apps need attention"
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  EVENT HANDLERS
    # ══════════════════════════════════════════════════════════════════════════

    $btnLoad.Add_Click({
        $selected = $cboTemplates.SelectedItem
        if (-not $selected) {
            [System.Windows.Forms.MessageBox]::Show('Select a template from the dropdown first.', 'No Template')
            return
        }
        $filePath = Join-Path $templateDir $selected
        Load-TemplateFile -FilePath $filePath
    })

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'JSON Templates (*.json)|*.json|All Files (*.*)|*.*'
        $ofd.InitialDirectory = $templateDir
        $ofd.Title = 'Select App Template'
        if ($ofd.ShowDialog() -eq 'OK') {
            Load-TemplateFile -FilePath $ofd.FileName
        }
        $ofd.Dispose()
    })

    $btnSaveTemplate.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = 'JSON Templates (*.json)|*.json'
        $sfd.InitialDirectory = $templateDir
        $sfd.Title = 'Save App Template'
        if ($sfd.ShowDialog() -eq 'OK') {
            $checkedApps = @()
            for ($i = 0; $i -lt $clbApps.Items.Count; $i++) {
                if ($clbApps.GetItemChecked($i) -and $i -lt $script:loadedApps.Count) {
                    $a = $script:loadedApps[$i]
                    $checkedApps += @{
                        name       = $a.Name
                        wingetId   = $a.WingetId
                        publisher  = $a.Publisher
                        minVersion = $a.MinVersion
                        category   = $a.Category
                        required   = $a.Required
                    }
                }
            }
            $template = @{
                templateName = [System.IO.Path]::GetFileNameWithoutExtension($sfd.FileName)
                description  = 'Custom template'
                version      = '1.0'
                created      = (Get-Date -Format 'yyyy-MM-dd')
                scope        = 'allUsers'
                applications = $checkedApps
            }
            $template | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sfd.FileName -Encoding UTF8
            $statusLabel.Text = "Template saved: $(Split-Path $sfd.FileName -Leaf)"
            Refresh-TemplateDropdown
        }
        $sfd.Dispose()
    })

    $btnSelectAll.Add_Click({
        for ($i = 0; $i -lt $clbApps.Items.Count; $i++) { $clbApps.SetItemChecked($i, $true) }
    })

    $btnSelectNone.Add_Click({
        for ($i = 0; $i -lt $clbApps.Items.Count; $i++) { $clbApps.SetItemChecked($i, $false) }
    })

    $btnRefreshGap.Add_Click({
        $statusLabel.Text = 'Scanning installed applications...'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $script:installedApps = Get-WingetInstalledApps
            Refresh-InstalledGrid
            Refresh-GapAnalysis
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $btnInstallSelected.Add_Click({
        $selectedRows = @($dgvMissing.SelectedRows)
        if ($selectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select one or more rows in the Missing/Outdated grid.', 'No Selection')
            return
        }
        $appIds = @($selectedRows | ForEach-Object { $_.Cells['WingetID'].Value })
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Install/update $($appIds.Count) app(s) for all users?`n`n$($appIds -join "`n")",
            'Confirm Install', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = 'Installing...'
        foreach ($id in $appIds) {
            $statusLabel.Text = "Installing: $id"
            $form.Refresh()
            try {
                $proc = Start-Process -FilePath 'winget' -ArgumentList "install --id `"$id`" --scope machine --accept-source-agreements --accept-package-agreements --silent" -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -eq 0) {
                    try { Write-AppLog "Installed $id via App Template Manager" "Info" } catch { <# Intentional: non-fatal #> }
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Failed to install ${id}:`n$($_.Exception.Message)", 'Install Error',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $statusLabel.Text = 'Installation batch complete. Refreshing...'
        $script:installedApps = Get-WingetInstalledApps
        Refresh-InstalledGrid
        Refresh-GapAnalysis
    })

    $btnSaveInstalled.Add_Click({
        if ($script:installedApps.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No installed apps loaded. Click "Check for Updates" first.', 'No Data')
            return
        }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = 'JSON Templates (*.json)|*.json'
        $sfd.InitialDirectory = $templateDir
        $sfd.FileName = "installed-snapshot-$(Get-Date -Format 'yyyyMMdd').json"
        $sfd.Title = 'Save Installed Apps as Template'
        if ($sfd.ShowDialog() -eq 'OK') {
            $apps = @()
            foreach ($row in $dgvInstalled.SelectedRows) {
                $apps += @{
                    name       = $row.Cells['AppID'].Value
                    wingetId   = $row.Cells['AppID'].Value
                    publisher  = ''
                    minVersion = $row.Cells['InstalledVersion'].Value
                    category   = ''
                    required   = $false
                }
            }
            if ($apps.Count -eq 0) {
                # If nothing selected, export all
                foreach ($kv in $script:installedApps.GetEnumerator()) {
                    $apps += @{
                        name       = $kv.Key
                        wingetId   = $kv.Key
                        publisher  = ''
                        minVersion = $kv.Value
                        category   = ''
                        required   = $false
                    }
                }
            }
            $template = @{
                templateName = [System.IO.Path]::GetFileNameWithoutExtension($sfd.FileName)
                description  = 'Snapshot of installed applications'
                version      = '1.0'
                created      = (Get-Date -Format 'yyyy-MM-dd')
                scope        = 'allUsers'
                applications = $apps
            }
            $template | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sfd.FileName -Encoding UTF8
            $statusLabel.Text = "Saved $($apps.Count) apps to $(Split-Path $sfd.FileName -Leaf)"
            Refresh-TemplateDropdown
        }
        $sfd.Dispose()
    })

    $btnCheckUpdates.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $statusLabel.Text = 'Querying winget for installed apps and available updates...'
        $form.Refresh()
        try {
            $script:installedApps = Get-WingetInstalledApps
            $script:upgradeList   = Get-WingetUpgradeList
            Refresh-InstalledGrid
            # Push upgradable items into Pane 2 if not already listed
            foreach ($kv in $script:upgradeList.GetEnumerator()) {
                $alreadyListed = $false
                foreach ($row in $dgvMissing.Rows) {
                    if ($row.Cells['WingetID'].Value -eq $kv.Key) { $alreadyListed = $true; break }
                }
                if (-not $alreadyListed) {
                    $curVer = if ($script:installedApps.ContainsKey($kv.Key)) { $script:installedApps[$kv.Key] } else { '?' }
                    $rowIdx = $dgvMissing.Rows.Add($kv.Key, $kv.Key, '', $curVer, "UPDATE AVAILABLE ($($kv.Value))")
                    $dgvMissing.Rows[$rowIdx].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCyan
                }
            }
            $statusLabel.Text = "Found $($script:installedApps.Count) installed, $($script:upgradeList.Count) upgradable"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $txtSearch.Add_TextChanged({
        Refresh-InstalledGrid -Filter $txtSearch.Text
    })

    # ── Initialization ────────────────────────────────────────────────────────
    Refresh-TemplateDropdown

    # ── Show form ─────────────────────────────────────────────────────────────
    [void]$form.ShowDialog()
    $form.Dispose()
}

# If run directly, launch the form
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.InvocationName -ne '') {
    Show-AppTemplateManager
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





