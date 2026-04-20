<#
.SYNOPSIS
  Windows Terminal Layout & Profile Manager with GUI, layout memory, ping grid, ARP, and config backup/restore.

.NOTES
  - Requires Windows Terminal installed.
  - Uses WinForms for GUI.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# -------------------- Paths & Globals --------------------
$ScriptPath      = $MyInvocation.MyCommand.Path
$ScriptDir       = Split-Path $ScriptPath
$ScriptBaseName  = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
$HostName        = $env:COMPUTERNAME

$LayoutMemoryFile = Join-Path $ScriptDir ("{0}_layoutmemories.json" -f $ScriptBaseName)
$ConfigZipPattern = "{0}_terminalconfig_*.zip" -f $ScriptBaseName
$HostConfigZip    = Join-Path $ScriptDir ("{0}_terminalconfig_{1}.zip" -f $ScriptBaseName, $HostName)

# Layout keys
$LayoutOptions = @(
    "OnePane",
    "TwoRows",
    "TwoColumns",
    "TwoSplits",
    "Quad"
)

# In-memory layout memory
$LayoutMemory = @{}

# -------------------- Helpers: Layout Memory --------------------
function Load-LayoutMemory {
    if (Test-Path $LayoutMemoryFile) {
        try {
            $json = Get-Content $LayoutMemoryFile -Raw
            if ($json.Trim()) {
                $global:LayoutMemory = $json | ConvertFrom-Json
            }
        } catch {
            $global:LayoutMemory = @{}
        }
    } else {
        $global:LayoutMemory = @{}
    }
}

function Save-LayoutMemory {
    $LayoutMemory | ConvertTo-Json -Depth 5 | Set-Content -Path $LayoutMemoryFile -Encoding UTF8
}

function Get-ProfileLayoutSelection {
    param(
        [string]$ProfileName
    )
    if ($LayoutMemory.ContainsKey($ProfileName)) {
        return $LayoutMemory[$ProfileName]
    } else {
        # default layout
        return "OnePane"
    }
}

function Set-ProfileLayoutSelection {
    param(
        [string]$ProfileName,
        [string]$LayoutKey
    )
    $LayoutMemory[$ProfileName] = $LayoutKey
}

# -------------------- Helpers: Windows Terminal Profiles --------------------
function Get-WTSettingsPath {
    $base = Join-Path $env:LOCALAPPDATA "Packages"
    $wtPackage = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "Microsoft.WindowsTerminal*" } |
                 Select-Object -First 1

    if (-not $wtPackage) { return $null }

    $settingsPath = Join-Path $wtPackage.FullName "LocalState\settings.json"
    if (Test-Path $settingsPath) {
        return $settingsPath
    }

    # Older style profiles.json fallback
    $profilesPath = Join-Path $wtPackage.FullName "LocalState\profiles.json"
    if (Test-Path $profilesPath) {
        return $profilesPath
    }

    return $null
}

function Get-WTProfiles {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }

    try {
        $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $profiles = @()

    if ($json.profiles.list) {
        $profiles = $json.profiles.list
    } elseif ($json.profiles) {
        $profiles = $json.profiles
    }

    # Return objects with name + commandline if present
    $profiles | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.name
            Commandline = $_.commandline
            Guid        = $_.guid
        }
    }
}

# -------------------- Helpers: Layout → wt.exe arguments --------------------
function Get-WTLayoutArgs {
    param(
        [string]$ProfileName,
        [string]$LayoutKey
    )

    # We will use profile name with -p
    $base = "new-tab -p `"$ProfileName`""

    switch ($LayoutKey) {
        "OnePane"   { return $base }
        "TwoRows"   { return "$base ; split-pane -V -p `"$ProfileName`"" }
        "TwoColumns"{ return "$base ; split-pane -H -p `"$ProfileName`"" }
        "TwoSplits" { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        "Quad"      { return "$base ; split-pane -H -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`" ; split-pane -V -p `"$ProfileName`"" }
        default     { return $base }
    }
}

# -------------------- Helpers: Ping & ARP --------------------
function Start-PingLayout {
    param(
        [System.Windows.Forms.DataGridView]$PingGrid
    )

    $targets = @()
    foreach ($row in $PingGrid.Rows) {
        if (-not $row.IsNewRow) {
            $val = $row.Cells[0].Value
            if ($val -and $val.ToString().Trim()) {
                $targets += $val.ToString().Trim()
            }
        }
    }

    if (-not $targets) {
        [System.Windows.Forms.MessageBox]::Show("No ping targets specified.")
        return
    }

    # Build a single tab with multiple panes, each running ping -t target
    $cmd = "wt.exe"
    $first = $true
    $cmdArgs = ""

    foreach ($t in $targets) {
        if ($first) {
            $cmdArgs += " new-tab powershell -NoLogo -NoExit -Command `"ping -t $t`""
            $first = $false
        } else {
            $cmdArgs += " ; split-pane -H powershell -NoLogo -NoExit -Command `"ping -t $t`""
        }
    }

    Start-Process $cmd -ArgumentList $cmdArgs
}

function Run-ArpScan {
    param(
        [System.Windows.Forms.DataGridView]$OutputGrid
    )

    $OutputGrid.Rows.Clear()

    $arp = arp -a 2>$null
    if (-not $arp) { return }

    foreach ($line in $arp) {
        if ($line -match "^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-]+)\s+(\w+)") {
            $ip  = $matches[1]
            $mac = $matches[2]
            $typ = $matches[3]
            [void]$OutputGrid.Rows.Add($ip, $mac, $typ)
        }
    }
}

function Export-ArpToHtml {
    param(
        [System.Windows.Forms.DataGridView]$OutputGrid
    )

    $rows = @()
    foreach ($row in $OutputGrid.Rows) {
        if (-not $row.IsNewRow) {
            $rows += [PSCustomObject]@{
                IPAddress = $row.Cells[0].Value  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
                MAC       = $row.Cells[1].Value
                Type      = $row.Cells[2].Value
            }
        }
    }

    if (-not $rows) {
        [System.Windows.Forms.MessageBox]::Show("No ARP data to export.")
        return
    }

    $html = $rows | ConvertTo-Html -Title "ARP Table" -PreContent "<h1>ARP Table</h1>"
    $htmlPath = Join-Path $ScriptDir "ARPTable.html"
    $html | Set-Content -Path $htmlPath -Encoding UTF8
    Start-Process $htmlPath
}

# -------------------- Helpers: Config Backup / Restore --------------------
function Get-WTConfigFiles {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) { return @() }

    $dir = Split-Path $settingsPath
    Get-ChildItem $dir -File
}

function Save-TerminalConfig {
    [System.Windows.Forms.MessageBox]::Show("Saving terminal config to `n$HostConfigZip")

    if (Test-Path $HostConfigZip) {
        Remove-Item $HostConfigZip -Force
    }

    $tempDir = Join-Path $env:TEMP ("WTConfig_{0}_{1}" -f $HostName, (Get-Random))
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        # Copy WT config files
        $cfgFiles = Get-WTConfigFiles
        foreach ($f in $cfgFiles) {
            Copy-Item $f.FullName -Destination (Join-Path $tempDir $f.Name)
        }

        # Copy this script
        Copy-Item $ScriptPath -Destination (Join-Path $tempDir (Split-Path $ScriptPath -Leaf))

        # Copy all layout memories
        $layoutFiles = Get-ChildItem $ScriptDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue
        foreach ($lf in $layoutFiles) {
            Copy-Item $lf.FullName -Destination (Join-Path $tempDir $lf.Name)
        }

        [IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $HostConfigZip)
        [System.Windows.Forms.MessageBox]::Show("Saved terminal config to `n$HostConfigZip")
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-TerminalConfig {
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.InitialDirectory = $ScriptDir
    $openFileDialog.Filter = "Zip files (*.zip)|*.zip|All files (*.*)|*.*"
    $openFileDialog.Title  = "Select Terminal Config Zip"

    if ($openFileDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    $zipPath = $openFileDialog.FileName

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Restore terminal config from:`n$zipPath`n`nThis will overwrite existing settings files. Continue?",
        "Confirm Restore",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $tempDir = Join-Path $env:TEMP ("WTConfigRestore_{0}_{1}" -f $HostName, (Get-Random))
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempDir)

        # Copy back WT config files
        $settingsPath = Get-WTSettingsPath
        if ($settingsPath) {
            $cfgDir = Split-Path $settingsPath
            $extractedCfg = Get-ChildItem $tempDir -File | Where-Object {
                $_.Name -like "settings.json" -or $_.Name -like "profiles.json" -or $_.Extension -eq ".json"
            }

            foreach ($f in $extractedCfg) {
                Copy-Item $f.FullName -Destination (Join-Path $cfgDir $f.Name) -Force
            }
        }

        # Copy layout memories back
        $extractedLayouts = Get-ChildItem $tempDir -Filter "*_layoutmemories*" -File -ErrorAction SilentlyContinue
        foreach ($lf in $extractedLayouts) {
            Copy-Item $lf.FullName -Destination (Join-Path $ScriptDir $lf.Name) -Force
        }

        [System.Windows.Forms.MessageBox]::Show("Restore complete. You may need to restart Windows Terminal.")
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-TerminalConfigInfo {
    $settingsPath = Get-WTSettingsPath
    if (-not $settingsPath) {
        [System.Windows.Forms.MessageBox]::Show("Windows Terminal settings not found.")
        return
    }

    $cfgDir = Split-Path $settingsPath
    $files  = Get-ChildItem $cfgDir -File

    $msg = "Settings path: $settingsPath`n`nFiles:`n"
    foreach ($f in $files) {
        $msg += " - {0} ({1} bytes)`n" -f $f.Name, $f.Length
    }

    [System.Windows.Forms.MessageBox]::Show($msg, "Terminal Config Info")
}

function Ensure-HostBaselineConfig {
    if (Test-Path $HostConfigZip) {
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "No terminal config zip found for host '$HostName'.`n`nCreate a baseline now?",
        "Baseline Config",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Save-TerminalConfig
    }
}

# -------------------- GUI --------------------
Load-LayoutMemory
$profiles = Get-WTProfiles

$form = New-Object System.Windows.Forms.Form
$form.Text = "Terminal Layout & Profile Manager"
$form.Size = New-Object System.Drawing.Size(1100, 700)
$form.StartPosition = "CenterScreen"

# Menu
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$terminalMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Terminal Profiles Management")

$miShow    = New-Object System.Windows.Forms.ToolStripMenuItem("Check & Show")
$miSave    = New-Object System.Windows.Forms.ToolStripMenuItem("Save Config")
$miRestore = New-Object System.Windows.Forms.ToolStripMenuItem("Restore Config")

$miShow.Add_Click({ Show-TerminalConfigInfo })
$miSave.Add_Click({ Save-TerminalConfig })
$miRestore.Add_Click({ Restore-TerminalConfig })

$terminalMenu.DropDownItems.AddRange(@($miShow, $miSave, $miRestore))
$menuStrip.Items.Add($terminalMenu)
$form.MainMenuStrip = $menuStrip
$form.Controls.Add($menuStrip)

# Profiles vs Layout grid
$profilesGrid = New-Object System.Windows.Forms.DataGridView
$profilesGrid.Location = New-Object System.Drawing.Point(10, 40)
$profilesGrid.Size     = New-Object System.Drawing.Size(650, 300)
$profilesGrid.AllowUserToAddRows = $false
$profilesGrid.AutoSizeColumnsMode = "Fill"

$colProfile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProfile.HeaderText = "Profile Name"
$colProfile.ReadOnly   = $true

$colLayout = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colLayout.HeaderText = "Layout"
$colLayout.Items.AddRange($LayoutOptions)

$profilesGrid.Columns.AddRange(@($colProfile, $colLayout))

foreach ($p in $profiles) {
    $layoutKey = Get-ProfileLayoutSelection -ProfileName $p.Name
    $idx = $profilesGrid.Rows.Add()
    $profilesGrid.Rows[$idx].Cells[0].Value = $p.Name
    $profilesGrid.Rows[$idx].Cells[1].Value = $layoutKey
}

$form.Controls.Add($profilesGrid)

# Button: Open Selected Layouts
$btnOpenLayouts = New-Object System.Windows.Forms.Button
$btnOpenLayouts.Text = "Open Selected Layouts"
$btnOpenLayouts.Location = New-Object System.Drawing.Point(10, 350)
$btnOpenLayouts.Size = New-Object System.Drawing.Size(200, 30)
$form.Controls.Add($btnOpenLayouts)

$btnOpenLayouts.Add_Click({
    # Save current selections to memory
    foreach ($row in $profilesGrid.Rows) {
        $profileName = $row.Cells[0].Value  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
        $layoutKey   = $row.Cells[1].Value
        if ($profileName -and $layoutKey) {
            Set-ProfileLayoutSelection -ProfileName $profileName -LayoutKey $layoutKey
        }
    }
    Save-LayoutMemory

    # Build wt.exe command
    $cmd = "wt.exe"
    $args = ""
    $first = $true

    foreach ($row in $profilesGrid.Rows) {
        $profileName = $row.Cells[0].Value  # SIN-EXEMPT: P022 - false positive: DataGridView column/cell index on populated grid
        $layoutKey   = $row.Cells[1].Value
        if (-not $profileName -or -not $layoutKey) { continue }

        $layoutArgs = Get-WTLayoutArgs -ProfileName $profileName -LayoutKey $layoutKey
        if ($first) {
            $args += " $layoutArgs"
            $first = $false
        } else {
            $args += " ; $layoutArgs"
        }
    }

    if (-not $args.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("No profiles/layouts selected.")
        return
    }

    Start-Process $cmd -ArgumentList $args
})

# Ping targets grid
$lblPing = New-Object System.Windows.Forms.Label
$lblPing.Text = "Ping Targets (one per line):"
$lblPing.Location = New-Object System.Drawing.Point(680, 40)
$lblPing.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($lblPing)

$pingGrid = New-Object System.Windows.Forms.DataGridView
$pingGrid.Location = New-Object System.Drawing.Point(680, 60)
$pingGrid.Size     = New-Object System.Drawing.Size(380, 200)
$pingGrid.AllowUserToAddRows = $true
$pingGrid.AutoSizeColumnsMode = "Fill"

$colPing = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPing.HeaderText = "Host/IP"
$pingGrid.Columns.Add($colPing)

$form.Controls.Add($pingGrid)

$btnPing = New-Object System.Windows.Forms.Button
$btnPing.Text = "Open Ping Layout"
$btnPing.Location = New-Object System.Drawing.Point(680, 270)
$btnPing.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($btnPing)

$btnPing.Add_Click({
    Start-PingLayout -PingGrid $pingGrid
})

# ARP checkbox and grid
$chkArp = New-Object System.Windows.Forms.CheckBox
$chkArp.Text = "ARP local subnet"
$chkArp.Location = New-Object System.Drawing.Point(680, 320)
$chkArp.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($chkArp)

$btnRunArp = New-Object System.Windows.Forms.Button
$btnRunArp.Text = "Run ARP"
$btnRunArp.Location = New-Object System.Drawing.Point(680, 350)
$btnRunArp.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($btnRunArp)

$arpGrid = New-Object System.Windows.Forms.DataGridView
$arpGrid.Location = New-Object System.Drawing.Point(10, 400)
$arpGrid.Size     = New-Object System.Drawing.Size(650, 230)
$arpGrid.AllowUserToAddRows = $false
$arpGrid.AutoSizeColumnsMode = "Fill"

$colIP  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colIP.HeaderText = "IP Address"
$colMAC = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMAC.HeaderText = "MAC Address"
$colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colType.HeaderText = "Type"

$arpGrid.Columns.AddRange(@($colIP, $colMAC, $colType))
$form.Controls.Add($arpGrid)

$btnArpHtml = New-Object System.Windows.Forms.Button
$btnArpHtml.Text = "Export ARP to HTML Grid"
$btnArpHtml.Location = New-Object System.Drawing.Point(180, 350)
$btnArpHtml.Size = New-Object System.Drawing.Size(200, 30)
$form.Controls.Add($btnArpHtml)

$btnRunArp.Add_Click({
    if ($chkArp.Checked) {
        Run-ArpScan -OutputGrid $arpGrid
    } else {
        [System.Windows.Forms.MessageBox]::Show("ARP checkbox is not ticked.")
    }
})

$btnArpHtml.Add_Click({
    if ($chkArp.Checked) {
        Export-ArpToHtml -OutputGrid $arpGrid
    } else {
        [System.Windows.Forms.MessageBox]::Show("Enable ARP local subnet first.")
    }
})

# On form closing, ensure baseline config exists
$form.Add_FormClosing({
    Ensure-HostBaselineConfig
})

[void]$form.ShowDialog()
