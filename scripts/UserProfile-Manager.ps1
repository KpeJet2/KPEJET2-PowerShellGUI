# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    User Profile Manager -- GUI for capturing, saving, comparing, and restoring
    complete Windows user-profile snapshots.

.DESCRIPTION
    Tab 1 -- VIEW    : Live-capture and browse every profile component.
    Tab 2 -- SAVE    : Name the snapshot, choose location, optional AES-256 encryption.
    Tab 3 -- COMPARE : Load a saved profile and diff it against the live environment.
    Tab 4 -- RESTORE : Select items to restore; always saves an auto-encrypted rollback first.

.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 2026-02-28
    Module  : modules\UserProfileManager.psm1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Assemblies ───────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Module ───────────────────────────────────────────────────────────────────
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path (Split-Path -Parent $scriptDir) 'modules\UserProfileManager.psm1'
if (-not (Test-Path $modulePath)) {
    $modulePath = Join-Path (Split-Path -Parent $scriptDir) 'UPM\modules\UserProfileManager.psm1'
}
if (-not (Test-Path $modulePath)) { throw "Module not found: $modulePath" }
Import-Module $modulePath -Force

# ── Colours / Fonts ──────────────────────────────────────────────────────────
$clrBg         = [System.Drawing.Color]::FromArgb(30, 30, 30)
$clrPanel      = [System.Drawing.Color]::FromArgb(40, 40, 40)
$clrCard       = [System.Drawing.Color]::FromArgb(50, 50, 55)
$clrBorder     = [System.Drawing.Color]::FromArgb(70, 70, 75)
$clrText       = [System.Drawing.Color]::FromArgb(220, 220, 220)
$clrAccent     = [System.Drawing.Color]::FromArgb(0, 122, 204)
$clrGreen      = [System.Drawing.Color]::FromArgb(100, 200, 100)
$clrRed        = [System.Drawing.Color]::FromArgb(220, 80, 80)
$clrAmber      = [System.Drawing.Color]::FromArgb(240, 180, 40)
$clrSubtle     = [System.Drawing.Color]::FromArgb(130, 130, 140)
$fontMain      = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontMono      = New-Object System.Drawing.Font('Consolas', 8.5)
$fontTitle     = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$fontSub       = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)

# ── Shared state ─────────────────────────────────────────────────────────────
$script:LiveSnapshot     = $null
$script:LoadedProfile    = $null    # for Compare / Restore tabs
$script:ProfileStorePath = Join-Path $env:APPDATA 'PowerShellGUI\UserProfiles'
if (-not (Test-Path $script:ProfileStorePath)) {
    New-Item -ItemType Directory -Path $script:ProfileStorePath -Force | Out-Null
}

# ── Session log ──────────────────────────────────────────────────────────────
$script:ScriptBaseName  = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$script:LogProfileName  = $env:USERNAME
$script:LogStamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogDir          = Join-Path $env:TEMP "UPM-Backups\$($script:LogProfileName)"
$script:LogFile         = Join-Path $script:LogDir "$($script:ScriptBaseName)-$($env:COMPUTERNAME)-$($env:USERNAME)-$($script:LogStamp).log"

function Write-UPMLog {
    param(
        [string]$Message,
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        if (-not (Test-Path $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { <# Intentional: non-fatal #> }
}

function Write-DiagnosticDump {
    param(
        [string]$Reason,
        [object]$ErrorRecord = $null,
        [hashtable]$Context = $null
    )
    Write-UPMLog "===== DIAGNOSTIC DUMP BEGIN: $Reason =====" 'ERROR'
    try {
        if ($Context) {
            foreach ($k in ($Context.Keys | Sort-Object)) {
                Write-UPMLog "CTX.$k = $($Context[$k])" 'ERROR'
            }
        }
        if ($ErrorRecord) {
            $ex = if ($ErrorRecord.Exception) { $ErrorRecord.Exception } else { $null }
            if ($ex) {
                Write-UPMLog "ERR.Type = $($ex.GetType().FullName)" 'ERROR'
                Write-UPMLog "ERR.Message = $($ex.Message)" 'ERROR'
                if ($ex.StackTrace) { Write-UPMLog "ERR.Stack = $($ex.StackTrace)" 'ERROR' }
            } else {
                Write-UPMLog "ERR.Raw = $ErrorRecord" 'ERROR'
            }
            if ($ErrorRecord.ScriptStackTrace) {
                Write-UPMLog "ERR.ScriptStack = $($ErrorRecord.ScriptStackTrace)" 'ERROR'
            }
        }
    } catch { <# Intentional: non-fatal #> }
    Write-UPMLog "===== DIAGNOSTIC DUMP END: $Reason =====" 'ERROR'
}

function Show-UPMError {
    param(
        [string]$Title,
        [string]$FriendlyMessage,
        [object]$ErrorRecord = $null,
        [hashtable]$Context = $null
    )
    $detail = if ($ErrorRecord -and $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } elseif ($ErrorRecord) { [string]$ErrorRecord } else { 'Unknown error' }
    Write-UPMLog "$Title failed: $detail" 'ERROR'
    Write-DiagnosticDump -Reason $Title -ErrorRecord $ErrorRecord -Context $Context
    [System.Windows.Forms.MessageBox]::Show(
        "$FriendlyMessage`n`nTechnical detail: $detail`nLog: $($script:LogFile)",
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Get-CapturedDateDisplay {
    param([object]$CapturedOn)
    $raw = [string]$CapturedOn
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'unknown-date' }
    if ($raw.Length -ge 10) { return $raw.Substring(0, 10) }
    return $raw
}

function Get-ProfileDisplayText {
    param(
        [object]$Profile,
        [bool]$IncludeRollbackTag = $false
    )
    $name = if ([string]::IsNullOrWhiteSpace([string]$Profile.ProfileName)) { '(unnamed)' } else { [string]$Profile.ProfileName }
    $date = Get-CapturedDateDisplay $Profile.CapturedOn
    $tags = @()
    if ($Profile.Encrypted) { $tags += '[ENC]' }
    if ($IncludeRollbackTag -and $Profile.IsRollback) { $tags += '[ROLLBACK]' }
    $tagText = if ($tags.Count -gt 0) { "$($tags -join '') " } else { '' }
    return "$name | $date | $tagText$($Profile.FileName)"
}

# ── Helper: styled button ────────────────────────────────────────────────────
function New-StyledButton {
    param(
        [string] $Text,
        [int]    $X,
        [int]    $Y,
        [int]    $W = 140,
        [int]    $H = 30,
        [System.Drawing.Color] $BackColor
    )
    if (-not $BackColor) { $BackColor = $clrAccent }
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Location  = New-Object System.Drawing.Point($X, $Y)
    $btn.Size      = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize  = 0
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(30, 144, 255)
    $btn.BackColor = $BackColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font      = $fontBold
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

# ── Helper: labelled text box ────────────────────────────────────────────────
function New-LabelledTextBox {
    param([string]$LabelText, [int]$X, [int]$Y, [int]$W = 340, [bool]$IsPassword = $false)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $LabelText
    $lbl.Location  = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size      = New-Object System.Drawing.Size($W, 16)
    $lbl.ForeColor = $clrSubtle
    $lbl.Font      = $fontMain
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location   = New-Object System.Drawing.Point($X, ($Y + 18))
    $tb.Size       = New-Object System.Drawing.Size($W, 22)
    $tb.BackColor  = $clrCard
    $tb.ForeColor  = $clrText
    $tb.Font       = $fontMain
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if ($IsPassword) { $tb.UseSystemPasswordChar = $true }
    return @{ Label = $lbl; TextBox = $tb }
}

# ── Helper: show password dialog (returns SecureString or $null) ─────────────
function Show-PasswordDialog {
    param([string]$Title = 'Enter Profile Password', [bool]$Confirm = $false)
    $dlgHeight = if ($Confirm) { 210 } else { 160 }
    $btnY      = if ($Confirm) { 128 } else { 100 }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = $Title
    $dlg.Size            = New-Object System.Drawing.Size(380, $dlgHeight)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $clrBg
    $dlg.ForeColor       = $clrText
    $dlg.Font            = $fontMain

    $pw1 = New-LabelledTextBox 'Password' 16 14 330 $true
    $dlg.Controls.AddRange(@($pw1.Label, $pw1.TextBox))

    if ($Confirm) {
        $pw2 = New-LabelledTextBox 'Confirm Password' 16 62 330 $true
        $dlg.Controls.AddRange(@($pw2.Label, $pw2.TextBox))
    }

    $btnOk  = New-StyledButton 'OK'     16  $btnY 80 28
    $btnCxl = New-StyledButton 'Cancel' 108 $btnY 80 28 ([System.Drawing.Color]::FromArgb(90,40,40))
    $btnOk.DialogResult  = [System.Windows.Forms.DialogResult]::OK
    $btnCxl.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($btnOk, $btnCxl))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCxl

    $result = $dlg.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $pwd = $pw1.TextBox.Text
    if ($Confirm) {
        if ($pw2.TextBox.Text -ne $pwd) {
            [System.Windows.Forms.MessageBox]::Show('Passwords do not match.','Mismatch',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return $null
        }
    }
    if ([string]::IsNullOrEmpty($pwd)) { return $null }
    $ss = New-Object System.Security.SecureString
    foreach ($c in $pwd.ToCharArray()) { $ss.AppendChar($c) }
    $ss.MakeReadOnly()
    return $ss
}

# ── Helper: async job runner with progress ───────────────────────────────────
function Invoke-WithProgress {
    param(
        [System.Windows.Forms.ProgressBar] $ProgressBar,
        [System.Windows.Forms.Label]       $StatusLabel,
        [scriptblock] $Work
    )
    $ProgressBar.Value = 0
    $ProgressBar.Visible = $true
    $StatusLabel.Text = 'Working...'
    [System.Windows.Forms.Application]::DoEvents()

    $callback = {
        param([int]$Pct, [string]$Msg)
        $ProgressBar.Value = [Math]::Min($Pct, 100)
        $StatusLabel.Text  = $Msg
        [System.Windows.Forms.Application]::DoEvents()
    }
    try {
        & $Work $callback
    } finally {
        $ProgressBar.Value   = 100
        $ProgressBar.Visible = $false
    }
}

# ════════════════════════════════════════════════════════════════════════════
#  MAIN FORM
# ════════════════════════════════════════════════════════════════════════════
$form = New-Object System.Windows.Forms.Form
$form.Text            = "User Profile Manager  --  $($env:USERNAME) @ $($env:COMPUTERNAME)"
$form.Size            = New-Object System.Drawing.Size(1120, 820)
$form.MinimumSize     = New-Object System.Drawing.Size(900, 700)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $clrBg
$form.ForeColor       = $clrText
$form.Font            = $fontMain
$form.FormBorderStyle = 'Sizable'

# Status bar
$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusBar.BackColor = $clrPanel
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text      = 'Ready.'
$statusLabel.ForeColor = $clrText
$statusLabel.Font      = $fontMain
$statusBar.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusBar)

# Tab Control
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock         = 'Fill'
$tabs.DrawMode     = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.ItemSize     = New-Object System.Drawing.Size(200, 32)
$tabs.Font         = $fontBold
$tabs.Padding      = New-Object System.Drawing.Point(12, 6)
$tabs.BackColor    = $clrBg
$tabs.Add_DrawItem({
    param($sender, $e)
    $tab   = $sender.TabPages[$e.Index]
    $rect  = $e.Bounds
    $bg    = if ($e.Index -eq $sender.SelectedIndex) { $clrAccent } else { $clrPanel }
    $brush = New-Object System.Drawing.SolidBrush($bg)
    $e.Graphics.FillRectangle($brush, $rect)
    $tf   = [System.Drawing.StringFormat]::GenericDefault
    $tf.Alignment = [System.Drawing.StringAlignment]::Center
    $tf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $e.Graphics.DrawString($tab.Text, $fontBold, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]$rect, $tf)
    $brush.Dispose()
})
$form.Controls.Add($tabs)

# ════════════════════════════════════════════════════════════════════════════
#  TAB 1 -- VIEW (Capture & Browse)
# ════════════════════════════════════════════════════════════════════════════
$tabView = New-Object System.Windows.Forms.TabPage
$tabView.Text      = '  VIEW  '
$tabView.BackColor = $clrBg
$tabView.Padding   = New-Object System.Windows.Forms.Padding(8)
$tabs.TabPages.Add($tabView)

# Toolbar
$viewToolbar = New-Object System.Windows.Forms.Panel
$viewToolbar.Size     = New-Object System.Drawing.Size(1100, 50)
$viewToolbar.Location = New-Object System.Drawing.Point(4, 4)
$viewToolbar.BackColor = $clrPanel
$tabView.Controls.Add($viewToolbar)

$btnCapture = New-StyledButton 'Capture Current Profile' 10 10 200 30
$viewToolbar.Controls.Add($btnCapture)

$viewProgress = New-Object System.Windows.Forms.ProgressBar
$viewProgress.Location = New-Object System.Drawing.Point(220, 16)
$viewProgress.Size     = New-Object System.Drawing.Size(400, 18)
$viewProgress.Style    = 'Continuous'
$viewProgress.Visible  = $false
$viewProgress.BackColor = $clrCard
$viewProgress.ForeColor = $clrAccent
$viewToolbar.Controls.Add($viewProgress)

$viewStatusLbl = New-Object System.Windows.Forms.Label
$viewStatusLbl.Location  = New-Object System.Drawing.Point(630, 15)
$viewStatusLbl.Size      = New-Object System.Drawing.Size(220, 20)
$viewStatusLbl.ForeColor = $clrSubtle
$viewStatusLbl.Font      = $fontSub
$viewStatusLbl.BackColor = [System.Drawing.Color]::Transparent
$viewToolbar.Controls.Add($viewStatusLbl)

$chkViewLocalCerts = New-Object System.Windows.Forms.CheckBox
$chkViewLocalCerts.Text      = 'Include Local Machine cert stores'
$chkViewLocalCerts.Location  = New-Object System.Drawing.Point(862, 14)
$chkViewLocalCerts.Size      = New-Object System.Drawing.Size(220, 20)
$chkViewLocalCerts.ForeColor = $clrSubtle
$chkViewLocalCerts.Font      = $fontSub
$chkViewLocalCerts.BackColor = [System.Drawing.Color]::Transparent
$viewToolbar.Controls.Add($chkViewLocalCerts)

# Splitter + tree + detail
$viewSplit = New-Object System.Windows.Forms.SplitContainer
$viewSplit.Location    = New-Object System.Drawing.Point(4, 60)
$viewSplit.Size        = New-Object System.Drawing.Size(1094, 680)
$viewSplit.SplitterDistance = 300
$viewSplit.Panel1.BackColor = $clrPanel
$viewSplit.Panel2.BackColor = $clrCard
$viewSplit.BackColor   = $clrBg
$tabView.Controls.Add($viewSplit)

$viewTree = New-Object System.Windows.Forms.TreeView
$viewTree.Dock             = 'Fill'
$viewTree.BackColor        = $clrPanel
$viewTree.ForeColor        = $clrText
$viewTree.Font             = $fontMain
$viewTree.BorderStyle      = 'FixedSingle'
$viewTree.LineColor        = $clrBorder
$viewTree.ShowRootLines    = $true
$viewSplit.Panel1.Controls.Add($viewTree)

$viewDetail = New-Object System.Windows.Forms.DataGridView
$viewDetail.Dock                 = 'Fill'
$viewDetail.BackgroundColor      = $clrCard
$viewDetail.GridColor            = $clrBorder
$viewDetail.ForeColor            = $clrText
$viewDetail.Font                 = $fontMono
$viewDetail.RowHeadersVisible    = $false
$viewDetail.AllowUserToAddRows   = $false
$viewDetail.AllowUserToDeleteRows = $false
$viewDetail.ReadOnly             = $true
$viewDetail.AutoSizeColumnsMode  = 'Fill'
$viewDetail.SelectionMode        = 'FullRowSelect'
$viewDetail.MultiSelect          = $false
$viewDetail.BorderStyle          = 'FixedSingle'
$viewDetail.ColumnHeadersDefaultCellStyle.BackColor = $clrBg
$viewDetail.ColumnHeadersDefaultCellStyle.ForeColor = $clrText
$viewDetail.ColumnHeadersDefaultCellStyle.Font      = $fontBold
$viewDetail.DefaultCellStyle.BackColor  = $clrCard
$viewDetail.DefaultCellStyle.ForeColor  = $clrText
$viewDetail.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45,45,50)
$viewDetail.EnableHeadersVisualStyles   = $false
$viewSplit.Panel2.Controls.Add($viewDetail)

# Populate tree from snapshot
function Populate-ViewTree {
    $viewTree.Nodes.Clear()
    $viewDetail.Columns.Clear()
    $viewDetail.Rows.Clear()
    if ($null -eq $script:LiveSnapshot) { return }
    $snap = $script:LiveSnapshot

    function Add-Node { param([System.Windows.Forms.TreeNode]$Parent, [string]$Text, [object]$Tag)
        $n = if ($Parent) { $Parent.Nodes.Add($Text) } else { $viewTree.Nodes.Add($Text) }
        $n.Tag = $Tag ; return $n
    }

    $root = Add-Node $null "Profile: $($snap.Meta.ProfileName)" $snap
    $root.NodeFont = $fontBold

    # Winget
    $wn = Add-Node $root "Winget Applications ($($snap.Data.WingetApplications.Count))" 'winget'
    $wn.ForeColor = $clrGreen

    # PS Environment
    $psn = Add-Node $root "PowerShell Environment" 'psenv'
    $psn.ForeColor = $clrAccent
    Add-Node $psn "Version: $($snap.Data.PSEnvironment.PSVersion)" 'psver' | Out-Null
    Add-Node $psn "Modules ($($snap.Data.PSEnvironment.InstalledModules.Count))" 'psmod' | Out-Null
    Add-Node $psn "Scripts on PATH ($($snap.Data.PSEnvironment.ScriptPaths.Count))" 'psscripts' | Out-Null
    if ($snap.Data.PSEnvironment.ProfilePaths) {
        Add-Node $psn "Profile Paths ($(@($snap.Data.PSEnvironment.ProfilePaths.Keys).Count))" 'psprofiles' | Out-Null
    }

    # User App Configs
    $cfgn = Add-Node $root "User App Configs" 'userconfig'
    $cfgn.ForeColor = $clrAmber
    Add-Node $cfgn "Registry Keys ($($snap.Data.UserAppConfigs.RegistryKeys.Count))" 'regleys' | Out-Null
    Add-Node $cfgn "Config Files ($($snap.Data.UserAppConfigs.ConfigFiles.Count))" 'cfgfiles' | Out-Null

    # Taskbar
    $tbn = Add-Node $root "Taskbar Layout (Pins: $($snap.Data.TaskbarLayout.PinnedItems.Count))" 'taskbar'
    $tbn.ForeColor = $clrAccent

    # Print Drivers
    $prn = Add-Node $root "Print Drivers ($($snap.Data.PrintDrivers.Count))" 'printdrivers'
    $prn.ForeColor = $clrSubtle

    # MIME Types
    $mn = Add-Node $root "MIME Types ($($snap.Data.MimeTypes.Count))" 'mimetypes'
    $mn.ForeColor = $clrSubtle

    # WiFi Profiles
    $wfn = Add-Node $root "WiFi Profiles ($(@($snap.Data.WiFiProfiles).Count))" 'wifi'
    $wfn.ForeColor = $clrAccent

    # MRU Locations
    $mrun = Add-Node $root "Recent Locations (MRU)" 'mru'
    $mrun.ForeColor = $clrSubtle
    if ($snap.Data.MRULocations) {
        Add-Node $mrun "Typed Paths ($(@($snap.Data.MRULocations.TypedPaths).Count))"       'mru_typed'    | Out-Null
        Add-Node $mrun "Run MRU ($(@($snap.Data.MRULocations.RunMRU).Count))"               'mru_run'      | Out-Null
        Add-Node $mrun "Open/Save Paths ($(@($snap.Data.MRULocations.OpenSavePaths).Count))" 'mru_opensave' | Out-Null
        Add-Node $mrun "Recent Extensions ($(@($snap.Data.MRULocations.RecentExts).Count))"  'mru_exts'     | Out-Null
    }

    # Certificates
    $certs = $snap.Data.Certificates
    $certCount = if ($certs) { (@($certs.UserStore).Count + @($certs.LocalMachineStore).Count) } else { 0 }
    $certn = Add-Node $root "Certificates ($certCount)" 'certs'
    $certn.ForeColor = $clrAmber
    if ($certs) {
        Add-Node $certn "User Store ($(@($certs.UserStore).Count))"           'certs_user' | Out-Null
        Add-Node $certn "Local Machine ($(@($certs.LocalMachineStore).Count))" 'certs_lm'   | Out-Null
    }

    # ISE
    $isen = Add-Node $root "ISE Configuration" 'ise'
    $isen.ForeColor = $clrSubtle
    if ($snap.Data.ISEConfiguration) {
        $ise = $snap.Data.ISEConfiguration
        Add-Node $isen "Profile Script"                                                   'ise_profile' | Out-Null
        Add-Node $isen "Snippets ($(@($ise.SnippetFiles).Count))"                         'ise_snip'    | Out-Null
        Add-Node $isen "Registry Settings ($(@($ise.RegistrySettings).Count))"           'ise_reg'     | Out-Null
        Add-Node $isen "ISE Options ($(@($ise.ISEOptionsEntries).Count))"                'ise_opts'    | Out-Null
        Add-Node $isen "Add-Ons ($(@($ise.AddOns).Count))"                               'ise_addons'  | Out-Null
        Add-Node $isen "Recent Files ($(@($ise.RecentFiles).Count))"                     'ise_recent'  | Out-Null
    }

    # Terminal
    $termn = Add-Node $root "Terminal Configuration" 'terminal'
    $termn.ForeColor = $clrAccent
    if ($snap.Data.TerminalConfiguration) {
        $tc = $snap.Data.TerminalConfiguration
        Add-Node $termn "Console Host Settings ($(@($tc.ConhostSettings).Count))" 'terminal_con' | Out-Null
        if ($tc.SettingsPath) {
            Add-Node $termn 'Windows Terminal settings.json' 'terminal_wt' | Out-Null
        }
        if ($tc.PSProfileHashes) {
            Add-Node $termn "PS Profile Hashes ($(@($tc.PSProfileHashes.Keys).Count))" 'terminal_profiles' | Out-Null
        }
    }

    # PS Help Repos
    $pshn = Add-Node $root "PS Repositories ($(@($snap.Data.PSHelpRepositories.Repositories).Count))" 'pshelp'
    $pshn.ForeColor = $clrSubtle

    # Screensaver
    $ssn = Add-Node $root 'Screensaver Settings' 'screensaver'
    $ssn.ForeColor = $clrSubtle

    # Power
    $pwrn = Add-Node $root "Power Plans ($(@($snap.Data.PowerConfiguration.Plans).Count))" 'power'
    $pwrn.ForeColor = $clrSubtle

    # Display
    $dispn = Add-Node $root "Display Layout ($(@($snap.Data.DisplayLayout.Monitors).Count) monitor(s))" 'display'
    $dispn.ForeColor = $clrAccent
    if ($snap.Data.DisplayLayout) {
        $dl = $snap.Data.DisplayLayout
        if ($dl.DpiRegistry -and $dl.DpiRegistry.Count -gt 0) {
            Add-Node $dispn "DPI Registry ($($dl.DpiRegistry.Count) value(s))" 'display_dpi' | Out-Null
        }
        if (@($dl.PerMonitorDpi).Count -gt 0) {
            Add-Node $dispn "Per-Monitor DPI ($(@($dl.PerMonitorDpi).Count))" 'display_pm' | Out-Null
        }
    }

    # Regional
    $regn = Add-Node $root 'Regional & Language Settings' 'regional'
    $regn.ForeColor = $clrSubtle

    # Environment Variables
    $envn = Add-Node $root 'Environment Variables' 'envvars'
    $envn.ForeColor = $clrAmber
    if ($snap.Data.EnvironmentVariables) {
        $ev = $snap.Data.EnvironmentVariables
        Add-Node $envn "User ($(@($ev.User).Count))"    'envvars_user'    | Out-Null
        Add-Node $envn "Machine ($(@($ev.Machine).Count))" 'envvars_machine' | Out-Null
        Add-Node $envn "Process ($(@($ev.Process).Count))" 'envvars_process' | Out-Null
    }

    # Mapped Drives
    $mapn = Add-Node $root "Mapped Drives ($(@($snap.Data.MappedDrives).Count))" 'mappeddrives'
    $mapn.ForeColor = $clrAccent

    # Installed Fonts
    $fontn = Add-Node $root "Installed Fonts ($(@($snap.Data.InstalledFonts).Count))" 'fonts'
    $fontn.ForeColor = $clrSubtle

    # Language & Speech
    $langn = Add-Node $root 'Language & Speech' 'lang'
    $langn.ForeColor = $clrAccent
    if ($snap.Data.LanguageAndSpeech) {
        $ls = $snap.Data.LanguageAndSpeech
        Add-Node $langn "Language Packs ($(@($ls.InstalledLanguages).Count))"   'lang_packs' | Out-Null
        Add-Node $langn "Speech Recognition ($(@($ls.SpeechRecognition).Count))" 'lang_sr'   | Out-Null
        Add-Node $langn "Text-to-Speech ($(@($ls.TextToSpeech).Count))"          'lang_tts'  | Out-Null
        Add-Node $langn "Dictionary Files ($(@($ls.DictionaryFiles).Count))"     'lang_dict' | Out-Null
        Add-Node $langn "Custom Dictionaries ($(@($ls.CustomDictionaries).Count))" 'lang_custom' | Out-Null
    }

    # Quick Access
    $qan = Add-Node $root 'Quick Access Links' 'quickaccess'
    $qan.ForeColor = $clrAmber
    if ($snap.Data.QuickAccessLinks) {
        $qa = $snap.Data.QuickAccessLinks
        Add-Node $qan "Frequent Folders ($(@($qa.FrequentFolders).Count))" 'qa_folders' | Out-Null
        Add-Node $qan "Recent Files ($(@($qa.RecentFiles).Count))"          'qa_files'   | Out-Null
        Add-Node $qan "Pinned Items ($(@($qa.PinnedFolders).Count))"        'qa_pinned'  | Out-Null
    }

    # Explorer Folder View
    $expn = Add-Node $root 'Explorer Folder View' 'explorer'
    $expn.ForeColor = $clrSubtle
    if ($snap.Data.ExplorerFolderView) {
        $xp = $snap.Data.ExplorerFolderView
        Add-Node $expn "Advanced Options ($(@($xp.AdvancedOptions).Count))" 'exp_adv'  | Out-Null
        Add-Node $expn 'General Options'                                      'exp_gen'  | Out-Null
        Add-Node $expn 'View State'                                           'exp_view' | Out-Null
        if (@($xp.BagMRU).Count -gt 0) {
            Add-Node $expn "Bag MRU ($(@($xp.BagMRU).Count))" 'exp_bag' | Out-Null
        }
    }

    # Search Providers
    $srchn = Add-Node $root 'Search Providers' 'search'
    $srchn.ForeColor = $clrAccent
    if ($snap.Data.SearchProviders) {
        $sp = $snap.Data.SearchProviders
        Add-Node $srchn "IE / Edge Search Scopes ($(@($sp.InternetExplorer).Count))" 'search_ie'  | Out-Null
        Add-Node $srchn 'Windows Search Settings'                                     'search_ws'  | Out-Null
        Add-Node $srchn 'Cortana / Search Prefs'                                      'search_cor' | Out-Null
    }

    $root.Expand()
    $psn.Expand()
    $cfgn.Expand()
    $mrun.Expand()
    $certn.Expand()
    $isen.Expand()
    $termn.Expand()
    $envn.Expand()
    $langn.Expand()
    $qan.Expand()
    $expn.Expand()
}

$viewTree.Add_AfterSelect({
    $viewDetail.Columns.Clear()
    $viewDetail.Rows.Clear()
    if ($null -eq $script:LiveSnapshot -or $null -eq $this.SelectedNode) { return }
    $snap = $script:LiveSnapshot
    $key  = $this.SelectedNode.Tag

    function Add-Col { param([string]$H, [int]$FW = 100)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.HeaderText = $H ; $c.FillWeight = $FW
        $viewDetail.Columns.Add($c) | Out-Null
    }

    switch ($key) {
        'winget' {
            Add-Col 'Name' 160 ; Add-Col 'Id' 140 ; Add-Col 'Version' 60 ; Add-Col 'Source' 60
            foreach ($app in $snap.Data.WingetApplications) {
                $viewDetail.Rows.Add($app.Name, $app.Id, $app.Version, $app.Source) | Out-Null
            }
        }
        'psver' {
            Add-Col 'Property' 200 ; Add-Col 'Value' 400
            $pse = $snap.Data.PSEnvironment
            if ($pse) {
                $viewDetail.Rows.Add('PS Version',  $pse.PSVersion)  | Out-Null
                $viewDetail.Rows.Add('PS Edition',  $pse.PSEdition)  | Out-Null
                $viewDetail.Rows.Add('PS Home',     $pse.PSHOME)     | Out-Null
            }
        }
        'psmod' {
            Add-Col 'Name' 160 ; Add-Col 'Version' 60 ; Add-Col 'Repository' 80 ; Add-Col 'Path' 200
            foreach ($m in $snap.Data.PSEnvironment.InstalledModules) {
                $viewDetail.Rows.Add($m.Name, $m.Version, $m.Repository, $m.ModuleBase) | Out-Null
            }
        }
        'psscripts' {
            Add-Col 'Name' 120 ; Add-Col 'Path' 260 ; Add-Col 'Size' 50 ; Add-Col 'Modified' 100
            foreach ($s in $snap.Data.PSEnvironment.ScriptPaths) {
                $viewDetail.Rows.Add($s.Name, $s.FullPath, $s.Size, $s.Modified) | Out-Null
            }
        }
        'psprofiles' {
            Add-Col 'Profile Key' 160 ; Add-Col 'Path' 340 ; Add-Col 'Exists' 50 ; Add-Col 'Hash' 220
            foreach ($kv in $snap.Data.PSEnvironment.ProfilePaths.GetEnumerator()) {
                $viewDetail.Rows.Add($kv.Key, $kv.Value.Path, $kv.Value.Exists, $kv.Value.Hash) | Out-Null
            }
        }
        'regleys' {
            Add-Col 'Key Name' 180 ; Add-Col 'Sub Keys' 60 ; Add-Col 'Values Count' 60 ; Add-Col 'Key Path' 260
            foreach ($k in $snap.Data.UserAppConfigs.RegistryKeys) {
                $viewDetail.Rows.Add($k.Name, $k.SubKeys, $k.Values.Count, $k.KeyPath) | Out-Null
            }
        }
        'cfgfiles' {
            Add-Col 'Name' 120 ; Add-Col 'Path' 260 ; Add-Col 'Size' 50 ; Add-Col 'Modified' 100 ; Add-Col 'SHA-256' 160
            foreach ($f in $snap.Data.UserAppConfigs.ConfigFiles) {
                $viewDetail.Rows.Add($f.Name, $f.Path, $f.Size, $f.Modified, $f.Hash) | Out-Null
            }
        }
        'taskbar' {
            Add-Col 'Pin Name' 220 ; Add-Col 'Modified' 120
            foreach ($p in $snap.Data.TaskbarLayout.PinnedItems) {
                $viewDetail.Rows.Add($p.Name, $p.Modified) | Out-Null
            }
            if ($snap.Data.TaskbarLayout.LayoutXmlPath) {
                $viewDetail.Rows.Add("LayoutModification.xml", $snap.Data.TaskbarLayout.LayoutXmlPath) | Out-Null
            }
        }
        'printdrivers' {
            Add-Col 'Name' 200 ; Add-Col 'Provider' 120 ; Add-Col 'Version' 80 ; Add-Col 'Environment' 80 ; Add-Col 'Inf Path' 160
            foreach ($d in $snap.Data.PrintDrivers) {
                $viewDetail.Rows.Add($d.Name, $d.Provider, $d.DriverVersion, $d.PrinterEnvironment, $d.InfPath) | Out-Null
            }
        }
        'mimetypes' {
            Add-Col 'Extension' 100 ; Add-Col 'MIME Type' 260
            foreach ($m in $snap.Data.MimeTypes) {
                $viewDetail.Rows.Add($m.Extension, $m.MimeType) | Out-Null
            }
        }
        'wifi' {
            Add-Col 'Name' 160 ; Add-Col 'Auth' 80 ; Add-Col 'Cipher' 70 ; Add-Col 'Mode' 90 ; Add-Col 'Auto' 50 ; Add-Col 'Network Type' 80
            foreach ($w in $snap.Data.WiFiProfiles) {
                $viewDetail.Rows.Add($w.Name, $w.AuthType, $w.Cipher, $w.ConnectionMode, $w.AutoConnect, $w.NetworkType) | Out-Null
            }
        }
        'mru_typed' {
            Add-Col 'Path' 500
            foreach ($p in $snap.Data.MRULocations.TypedPaths) { $viewDetail.Rows.Add($p) | Out-Null }
        }
        'mru_run' {
            Add-Col 'Command' 500
            foreach ($r in $snap.Data.MRULocations.RunMRU) { $viewDetail.Rows.Add($r) | Out-Null }
        }
        'mru_opensave' {
            Add-Col 'Key' 80 ; Add-Col 'Value' 520
            foreach ($entry in $snap.Data.MRULocations.OpenSavePaths) { $viewDetail.Rows.Add($entry.Key, $entry.Value) | Out-Null }
        }
        'mru_exts' {
            Add-Col 'Extension' 200
            foreach ($e in $snap.Data.MRULocations.RecentExts) { $viewDetail.Rows.Add($e) | Out-Null }
        }
        'certs_user' {
            Add-Col 'Store' 80 ; Add-Col 'Subject' 200 ; Add-Col 'Issuer' 160 ; Add-Col 'Expires' 100 ; Add-Col 'Thumbprint' 220 ; Add-Col 'Has Key' 50
            foreach ($c in $snap.Data.Certificates.UserStore) {
                $viewDetail.Rows.Add($c.StoreName, $c.Subject, $c.Issuer, $c.NotAfter, $c.Thumbprint, $c.HasPrivateKey) | Out-Null
            }
        }
        'certs_lm' {
            Add-Col 'Store' 80 ; Add-Col 'Subject' 200 ; Add-Col 'Issuer' 160 ; Add-Col 'Expires' 100 ; Add-Col 'Thumbprint' 220 ; Add-Col 'Has Key' 50
            foreach ($c in $snap.Data.Certificates.LocalMachineStore) {
                $viewDetail.Rows.Add($c.StoreName, $c.Subject, $c.Issuer, $c.NotAfter, $c.Thumbprint, $c.HasPrivateKey) | Out-Null
            }
        }
        'ise_snip' {
            Add-Col 'File Name' 200 ; Add-Col 'Modified' 120
            foreach ($s in $snap.Data.ISEConfiguration.SnippetFiles) { $viewDetail.Rows.Add($s.Name, $s.Modified) | Out-Null }
        }
        'ise_reg' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($r in $snap.Data.ISEConfiguration.RegistrySettings) { $viewDetail.Rows.Add($r.Name, $r.Value) | Out-Null }
        }
        'ise_profile' {
            Add-Col 'Property' 180 ; Add-Col 'Value' 420
            $ise = $snap.Data.ISEConfiguration
            if ($ise) {
                $profileExists = if ([string]::IsNullOrEmpty($ise.ProfilePath)) { $false } else { Test-Path $ise.ProfilePath }
                $viewDetail.Rows.Add('Profile Path',    $ise.ProfilePath)    | Out-Null
                $viewDetail.Rows.Add('Profile Exists',  $profileExists)      | Out-Null
                $viewDetail.Rows.Add('Profile Content', $ise.ProfileContent) | Out-Null
            }
        }
        'ise_opts' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($r in $snap.Data.ISEConfiguration.ISEOptionsEntries) { $viewDetail.Rows.Add($r.Name, $r.Value) | Out-Null }
        }
        'ise_addons' {
            Add-Col 'Name' 200 ; Add-Col 'DLL Path' 300 ; Add-Col 'Author' 100
            foreach ($a in $snap.Data.ISEConfiguration.AddOns) { $viewDetail.Rows.Add($a.Name, $a.DllPath, $a.Author) | Out-Null }
        }
        'ise_recent' {
            Add-Col 'Recent File Path' 560
            foreach ($f in $snap.Data.ISEConfiguration.RecentFiles) { $viewDetail.Rows.Add($f) | Out-Null }
        }
        'envvars_user' {
            Add-Col 'Name' 200 ; Add-Col 'Value' 400
            foreach ($v in $snap.Data.EnvironmentVariables.User) { $viewDetail.Rows.Add($v.Name, $v.Value) | Out-Null }
        }
        'envvars_machine' {
            Add-Col 'Name' 200 ; Add-Col 'Value' 400
            foreach ($v in $snap.Data.EnvironmentVariables.Machine) { $viewDetail.Rows.Add($v.Name, $v.Value) | Out-Null }
        }
        'envvars_process' {
            Add-Col 'Name' 200 ; Add-Col 'Value' 400
            foreach ($v in $snap.Data.EnvironmentVariables.Process) { $viewDetail.Rows.Add($v.Name, $v.Value) | Out-Null }
        }
        'mappeddrives' {
            Add-Col 'Drive' 60 ; Add-Col 'Network Path' 340 ; Add-Col 'Description' 160 ; Add-Col 'Root' 80
            foreach ($d in $snap.Data.MappedDrives) { $viewDetail.Rows.Add($d.Drive, $d.NetworkPath, $d.Description, $d.Root) | Out-Null }
        }
        'fonts' {
            Add-Col 'Font Name' 260 ; Add-Col 'File Name' 180 ; Add-Col 'Exists' 50 ; Add-Col 'Full Path' 200
            foreach ($f in $snap.Data.InstalledFonts) { $viewDetail.Rows.Add($f.Name, $f.FileName, $f.Exists, $f.FullPath) | Out-Null }
        }
        'lang_packs' {
            Add-Col 'Language Tag' 120 ; Add-Col 'Type' 120 ; Add-Col 'Installed' 60
            foreach ($l in $snap.Data.LanguageAndSpeech.InstalledLanguages) { $viewDetail.Rows.Add($l.Tag, $l.Type, $l.Installed) | Out-Null }
        }
        'lang_sr' {
            Add-Col 'Name' 220 ; Add-Col 'Language' 100 ; Add-Col 'CLSID' 260
            foreach ($r in $snap.Data.LanguageAndSpeech.SpeechRecognition) { $viewDetail.Rows.Add($r.Name, $r.Language, $r.CLSID) | Out-Null }
        }
        'lang_tts' {
            Add-Col 'Name' 220 ; Add-Col 'Language' 100 ; Add-Col 'Gender' 80
            foreach ($v in $snap.Data.LanguageAndSpeech.TextToSpeech) { $viewDetail.Rows.Add($v.Name, $v.Language, $v.Gender) | Out-Null }
        }
        'lang_dict' {
            Add-Col 'File Name' 160 ; Add-Col 'Size' 60 ; Add-Col 'Modified' 120 ; Add-Col 'Full Path' 280
            foreach ($d in $snap.Data.LanguageAndSpeech.DictionaryFiles) { $viewDetail.Rows.Add($d.Name, $d.Size, $d.Modified, $d.FullPath) | Out-Null }
        }
        'lang_custom' {
            Add-Col 'File Name' 200 ; Add-Col 'Path' 400
            foreach ($d in $snap.Data.LanguageAndSpeech.CustomDictionaries) { $viewDetail.Rows.Add($d.Name, $d.Path) | Out-Null }
        }
        'qa_folders' {
            Add-Col 'Name' 220 ; Add-Col 'Path' 400
            foreach ($f in $snap.Data.QuickAccessLinks.FrequentFolders) { $viewDetail.Rows.Add($f.Name, $f.Path) | Out-Null }
        }
        'qa_files' {
            Add-Col 'Name' 220 ; Add-Col 'Path' 400
            foreach ($f in $snap.Data.QuickAccessLinks.RecentFiles) { $viewDetail.Rows.Add($f.Name, $f.Path) | Out-Null }
        }
        'qa_pinned' {
            Add-Col 'File' 260 ; Add-Col 'Size' 60 ; Add-Col 'Modified' 120
            foreach ($p in $snap.Data.QuickAccessLinks.PinnedFolders) { $viewDetail.Rows.Add($p.File, $p.Size, $p.Modified) | Out-Null }
        }
        'exp_adv' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($r in $snap.Data.ExplorerFolderView.AdvancedOptions) { $viewDetail.Rows.Add($r.Name, $r.Value) | Out-Null }
        }
        'exp_gen' {
            Add-Col 'Key' 220 ; Add-Col 'Value' 380
            foreach ($kv in $snap.Data.ExplorerFolderView.GeneralOptions.GetEnumerator()) { $viewDetail.Rows.Add($kv.Key, $kv.Value) | Out-Null }
        }
        'exp_view' {
            Add-Col 'Key' 220 ; Add-Col 'Value' 380
            foreach ($kv in $snap.Data.ExplorerFolderView.ViewOptions.GetEnumerator()) { $viewDetail.Rows.Add($kv.Key, $kv.Value) | Out-Null }
        }
        'exp_bag' {
            Add-Col 'Name' 220 ; Add-Col 'Value' 380
            foreach ($b in $snap.Data.ExplorerFolderView.BagMRU) { $viewDetail.Rows.Add($b.Name, $b.Value) | Out-Null }
        }
        'search_ie' {
            Add-Col 'Display Name' 180; Add-Col 'URL' 280; Add-Col 'Default' 50; Add-Col 'GUID' 160
            foreach ($s in $snap.Data.SearchProviders.InternetExplorer) { $viewDetail.Rows.Add($s.DisplayName, $s.URL, $s.Default, $s.GUID) | Out-Null }
        }
        'search_ws' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($kv in $snap.Data.SearchProviders.WindowsSearch.GetEnumerator()) { $viewDetail.Rows.Add($kv.Key, $kv.Value) | Out-Null }
        }
        'search_cor' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($kv in $snap.Data.SearchProviders.CortanaSearch.GetEnumerator()) { $viewDetail.Rows.Add($kv.Key, $kv.Value) | Out-Null }
        }
        'terminal_con' {
            Add-Col 'Setting' 220 ; Add-Col 'Value' 380
            foreach ($r in $snap.Data.TerminalConfiguration.ConhostSettings) { $viewDetail.Rows.Add($r.Name, $r.Value) | Out-Null }
        }
        'terminal_wt' {
            Add-Col 'Property' 180 ; Add-Col 'Value' 420
            $tc = $snap.Data.TerminalConfiguration
            if ($tc) {
                $viewDetail.Rows.Add('Settings Path',    $tc.SettingsPath)    | Out-Null
                $viewDetail.Rows.Add('Settings Content', $tc.SettingsContent) | Out-Null
            }
        }
        'terminal_profiles' {
            Add-Col 'Profile Key' 160 ; Add-Col 'Path' 280 ; Add-Col 'Exists' 50 ; Add-Col 'Hash' 180 ; Add-Col 'Modified' 120
            $tc = $snap.Data.TerminalConfiguration
            if ($tc -and $tc.PSProfileHashes) {
                foreach ($kv in $tc.PSProfileHashes.GetEnumerator()) {
                    $viewDetail.Rows.Add($kv.Key, $kv.Value.Path, $kv.Value.Exists, $kv.Value.Hash, $kv.Value.Modified) | Out-Null
                }
            }
        }
        'pshelp' {
            Add-Col 'Repository Name' 160 ; Add-Col 'Source Location' 260 ; Add-Col 'Policy' 80 ; Add-Col 'Trusted' 50
            foreach ($r in $snap.Data.PSHelpRepositories.Repositories) {
                $viewDetail.Rows.Add($r.Name, $r.SourceLocation, $r.InstallationPolicy, $r.Trusted) | Out-Null
            }
            foreach ($p in $snap.Data.PSHelpRepositories.ModulePath) { $viewDetail.Rows.Add($p) | Out-Null }
        }
        'screensaver' {
            Add-Col 'Setting' 200 ; Add-Col 'Value' 400
            $ss = $snap.Data.ScreensaverSettings
            if ($ss) {
                $viewDetail.Rows.Add('Screen Saver Exe',  $ss.ScreenSaver)  | Out-Null
                $viewDetail.Rows.Add('Enabled',           $ss.Enabled)      | Out-Null
                $viewDetail.Rows.Add('Secure (password)', $ss.Secure)       | Out-Null
                $viewDetail.Rows.Add('Timeout (secs)',    $ss.TimeoutSecs)  | Out-Null
            }
        }
        'power' {
            Add-Col 'GUID' 180 ; Add-Col 'Plan Name' 200 ; Add-Col 'Active' 60
            foreach ($pl in $snap.Data.PowerConfiguration.Plans) {
                $viewDetail.Rows.Add($pl.Guid, $pl.Name, $pl.Active) | Out-Null
            }
        }
        'display' {
            Add-Col 'Monitor' 200 ; Add-Col 'Resolution' 120 ; Add-Col 'Refresh Hz' 80 ; Add-Col 'Bits/Pixel' 60 ; Add-Col 'Driver Ver' 100
            foreach ($m in $snap.Data.DisplayLayout.Monitors) {
                $viewDetail.Rows.Add($m.Name, "$($m.CurrentHorizontalResolution)x$($m.CurrentVerticalResolution)", $m.CurrentRefreshRate, $m.CurrentBitsPerPixel, $m.DriverVersion) | Out-Null
            }
        }
        'display_dpi' {
            Add-Col 'Key' 220 ; Add-Col 'Value' 380
            foreach ($kv in $snap.Data.DisplayLayout.DpiRegistry.GetEnumerator()) { $viewDetail.Rows.Add($kv.Key, $kv.Value) | Out-Null }
        }
        'display_pm' {
            Add-Col 'Monitor' 300 ; Add-Col 'DPI Value' 300
            foreach ($m in $snap.Data.DisplayLayout.PerMonitorDpi) { $viewDetail.Rows.Add($m.Monitor, $m.DpiValue) | Out-Null }
        }
        'regional' {
            Add-Col 'Setting' 200 ; Add-Col 'Value' 400
            $rl = $snap.Data.RegionalSettings
            if ($rl) {
                $viewDetail.Rows.Add('Culture',        $rl.CultureDisplayName) | Out-Null
                $viewDetail.Rows.Add('Culture Name',   $rl.CultureName)        | Out-Null
                $viewDetail.Rows.Add('System Locale',  $rl.SystemLocale)       | Out-Null
                $viewDetail.Rows.Add('Home Location',  $rl.HomeLocation)       | Out-Null
                foreach ($lang in $rl.Languages) {
                    $viewDetail.Rows.Add("Language: $($lang.EnglishName)", $lang.LanguageTag) | Out-Null
                }
                foreach ($kv in $rl.RegistryInternational.GetEnumerator()) {
                    $viewDetail.Rows.Add("Intl: $($kv.Key)", $kv.Value) | Out-Null
                }
            }
        }
    }
})

$btnCapture.Add_Click({
    $btnCapture.Enabled = $false
    $viewStatusLbl.Text = 'Capturing...'
    Write-UPMLog 'Capture initiated by user'
    try {
        $inclLocalCerts = $chkViewLocalCerts.Checked
        Invoke-WithProgress $viewProgress $viewStatusLbl {
            param($cb)
            $script:LiveSnapshot = Get-ProfileSnapshot -ProfileName "$($env:USERNAME)-live" -ProgressCallback $cb -IncludeLocalMachineCerts $inclLocalCerts
        }
        Populate-ViewTree
        $viewStatusLbl.Text = "Snapshot captured at $(Get-Date -Format 'HH:mm:ss')"
        if ($null -ne $script:LiveSnapshot) {
            $appCount = @($script:LiveSnapshot.Data.WingetApplications).Count
            $modCount = @($script:LiveSnapshot.Data.PSEnvironment.InstalledModules).Count
            $statusLabel.Text = "Live snapshot ready -- $appCount apps, $modCount modules"
        }
    } catch {
        $viewStatusLbl.Text = 'Capture failed. See log for details.'
        Show-UPMError -Title 'Capture' -FriendlyMessage 'Live profile capture failed. One or more config sources may be unavailable. Retry after closing locked apps.' -ErrorRecord $_ -Context @{
            Operation = 'Get-ProfileSnapshot'
            IncludeLocalMachineCerts = $chkViewLocalCerts.Checked
        }
    } finally {
        $btnCapture.Enabled = $true
    }
})

# ════════════════════════════════════════════════════════════════════════════
#  TAB 2 -- SAVE
# ════════════════════════════════════════════════════════════════════════════
$tabSave = New-Object System.Windows.Forms.TabPage
$tabSave.Text      = '  SAVE  '
$tabSave.BackColor = $clrBg
$tabs.TabPages.Add($tabSave)

$savePanel = New-Object System.Windows.Forms.Panel
$savePanel.Location  = New-Object System.Drawing.Point(20, 20)
$savePanel.Size      = New-Object System.Drawing.Size(640, 590)
$savePanel.BackColor = $clrPanel
$tabSave.Controls.Add($savePanel)

$saveTitleLbl = New-Object System.Windows.Forms.Label
$saveTitleLbl.Text      = 'Save Profile Snapshot'
$saveTitleLbl.Location  = New-Object System.Drawing.Point(16, 16)
$saveTitleLbl.Size      = New-Object System.Drawing.Size(600, 28)
$saveTitleLbl.Font      = $fontTitle
$saveTitleLbl.ForeColor = $clrText
$saveTitleLbl.BackColor = [System.Drawing.Color]::Transparent
$savePanel.Controls.Add($saveTitleLbl)

$saveNameCtl = New-LabelledTextBox 'Profile Name' 16 58 450
$saveNameCtl.TextBox.Text = "$($env:USERNAME)-$(Get-Date -Format 'yyyyMMdd')"
$savePanel.Controls.AddRange(@($saveNameCtl.Label, $saveNameCtl.TextBox))

$savePathCtl = New-LabelledTextBox 'Save Location' 16 110 370
$savePathCtl.TextBox.Text = $script:ProfileStorePath
$savePanel.Controls.AddRange(@($savePathCtl.Label, $savePathCtl.TextBox))

$btnBrowseSave = New-StyledButton '...' 392 128 60 24
$btnBrowseSave.Font = $fontMain
$savePanel.Controls.Add($btnBrowseSave)
$btnBrowseSave.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $savePathCtl.TextBox.Text
    $dlg.Description  = 'Select folder for profile snapshots'
    if ($dlg.ShowDialog() -eq 'OK') { $savePathCtl.TextBox.Text = $dlg.SelectedPath }
})

# Encryption section
$encBox = New-Object System.Windows.Forms.GroupBox
$encBox.Text      = '  Encryption'
$encBox.Location  = New-Object System.Drawing.Point(16, 170)
$encBox.Size      = New-Object System.Drawing.Size(600, 140)
$encBox.ForeColor = $clrAmber
$encBox.Font      = $fontBold
$encBox.BackColor = $clrCard
$savePanel.Controls.Add($encBox)

$chkEncrypt = New-Object System.Windows.Forms.CheckBox
$chkEncrypt.Text      = 'Enable strong encryption (AES-256-PBKDF2) -- recommended for sensitive environments'
$chkEncrypt.Location  = New-Object System.Drawing.Point(12, 24)
$chkEncrypt.Size      = New-Object System.Drawing.Size(572, 20)
$chkEncrypt.ForeColor = $clrText
$chkEncrypt.Font      = $fontMain
$chkEncrypt.BackColor = [System.Drawing.Color]::Transparent
$encBox.Controls.Add($chkEncrypt)

$encPw1Ctl = New-LabelledTextBox 'Password' 12 50 270 $true
$encPw2Ctl = New-LabelledTextBox 'Confirm Password' 300 50 270 $true
$encBox.Controls.AddRange(@($encPw1Ctl.Label, $encPw1Ctl.TextBox, $encPw2Ctl.Label, $encPw2Ctl.TextBox))

$encPw1Ctl.TextBox.Enabled = $false
$encPw2Ctl.TextBox.Enabled = $false
$chkEncrypt.Add_CheckedChanged({
    $encPw1Ctl.TextBox.Enabled = $chkEncrypt.Checked
    $encPw2Ctl.TextBox.Enabled = $chkEncrypt.Checked
    if (-not $chkEncrypt.Checked) { $encPw1Ctl.TextBox.Clear(); $encPw2Ctl.TextBox.Clear() }
})

# Capture Options groupbox
$captureOptBox = New-Object System.Windows.Forms.GroupBox
$captureOptBox.Text      = '  Capture Options'
$captureOptBox.Location  = New-Object System.Drawing.Point(16, 320)
$captureOptBox.Size      = New-Object System.Drawing.Size(600, 60)
$captureOptBox.ForeColor = $clrAccent
$captureOptBox.Font      = $fontBold
$captureOptBox.BackColor = $clrCard
$savePanel.Controls.Add($captureOptBox)

$chkSaveLocalMachineCerts = New-Object System.Windows.Forms.CheckBox
$chkSaveLocalMachineCerts.Text      = 'Include Local Machine certificate stores (requires elevated rights)'
$chkSaveLocalMachineCerts.Location  = New-Object System.Drawing.Point(12, 24)
$chkSaveLocalMachineCerts.Size      = New-Object System.Drawing.Size(572, 20)
$chkSaveLocalMachineCerts.ForeColor = $clrText
$chkSaveLocalMachineCerts.Font      = $fontMain
$chkSaveLocalMachineCerts.BackColor = [System.Drawing.Color]::Transparent
$captureOptBox.Controls.Add($chkSaveLocalMachineCerts)

# Capture + Save buttons
$saveInfoLbl = New-Object System.Windows.Forms.Label
$saveInfoLbl.Location  = New-Object System.Drawing.Point(16, 390)
$saveInfoLbl.Size      = New-Object System.Drawing.Size(600, 40)
$saveInfoLbl.ForeColor = $clrSubtle
$saveInfoLbl.Font      = $fontSub
$saveInfoLbl.BackColor = [System.Drawing.Color]::Transparent
$saveInfoLbl.Text      = "Saving will capture a fresh snapshot of the current user profile if one is not already in memory (View tab)."
$savePanel.Controls.Add($saveInfoLbl)

$saveProgress = New-Object System.Windows.Forms.ProgressBar
$saveProgress.Location = New-Object System.Drawing.Point(16, 434)
$saveProgress.Size     = New-Object System.Drawing.Size(600, 16)
$saveProgress.Visible  = $false
$savePanel.Controls.Add($saveProgress)

$savePrgLbl = New-Object System.Windows.Forms.Label
$savePrgLbl.Location  = New-Object System.Drawing.Point(16, 454)
$savePrgLbl.Size      = New-Object System.Drawing.Size(600, 18)
$savePrgLbl.ForeColor = $clrSubtle
$savePrgLbl.Font      = $fontSub
$savePrgLbl.BackColor = [System.Drawing.Color]::Transparent
$savePanel.Controls.Add($savePrgLbl)

$btnSaveProfile = New-StyledButton 'Capture & Save Profile' 16 480 200 34
$savePanel.Controls.Add($btnSaveProfile)

$btnSaveProfile.Add_Click({
    $profileName = $saveNameCtl.TextBox.Text.Trim()
    $savePath    = $savePathCtl.TextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($profileName)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a profile name.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($savePath)) {
        [System.Windows.Forms.MessageBox]::Show('Please specify a save location.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $encrypt = $chkEncrypt.Checked
    $secPwd  = $null
    if ($encrypt) {
        $pwd  = $encPw1Ctl.TextBox.Text
        $pwd2 = $encPw2Ctl.TextBox.Text
        if ([string]::IsNullOrEmpty($pwd)) {
            [System.Windows.Forms.MessageBox]::Show('Please enter a password for encryption.','Encryption',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($pwd -ne $pwd2) {
            [System.Windows.Forms.MessageBox]::Show('Passwords do not match.','Mismatch',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $secPwd = New-Object System.Security.SecureString
        foreach ($c in $pwd.ToCharArray()) { $secPwd.AppendChar($c) }
        $secPwd.MakeReadOnly()
    }

    $btnSaveProfile.Enabled = $false
    try {
        Write-UPMLog "Save initiated: profile='$profileName' path='$savePath' encrypted=$encrypt"
        Invoke-WithProgress $saveProgress $savePrgLbl {
            param($cb)
            $inclLocalCertsSave = $chkSaveLocalMachineCerts.Checked
            if ($null -eq $script:LiveSnapshot) {
                $script:LiveSnapshot = Get-ProfileSnapshot -ProfileName $profileName -ProgressCallback $cb -IncludeLocalMachineCerts $inclLocalCertsSave
            } else {
                $script:LiveSnapshot.Meta.ProfileName = $profileName
                & $cb 50 'Using in-memory snapshot...'
            }
        }
        $outFile = Join-Path $savePath "$profileName.upjson"
        Save-ProfileSnapshot -Snapshot $script:LiveSnapshot -OutputPath $outFile -Encrypt $encrypt -Password $secPwd
        $savePrgLbl.Text = "Saved: $outFile"
        $statusLabel.Text = "Profile saved: $outFile"
        [System.Windows.Forms.MessageBox]::Show(
            "Profile saved successfully.`n`n$outFile`n`nEncryption: $(if ($encrypt) { 'AES-256-PBKDF2' } else { 'None' })",
            'Saved', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        Show-UPMError -Title 'Save Profile' -FriendlyMessage 'Save failed. Snapshot capture or write operation did not complete. Check path permissions and retry.' -ErrorRecord $_ -Context @{
            Operation = 'Save-ProfileSnapshot'
            ProfileName = $profileName
            SavePath = $savePath
            Encrypted = $encrypt
        }
    } finally {
        $btnSaveProfile.Enabled = $true
    }
})

# ════════════════════════════════════════════════════════════════════════════
#  TAB 3 -- COMPARE
# ════════════════════════════════════════════════════════════════════════════
$tabCompare = New-Object System.Windows.Forms.TabPage
$tabCompare.Text      = '  COMPARE  '
$tabCompare.BackColor = $clrBg
$tabs.TabPages.Add($tabCompare)

# Top load bar
$cmpTopPanel = New-Object System.Windows.Forms.Panel
$cmpTopPanel.Location  = New-Object System.Drawing.Point(8, 8)
$cmpTopPanel.Size      = New-Object System.Drawing.Size(1090, 68)
$cmpTopPanel.BackColor = $clrPanel
$tabCompare.Controls.Add($cmpTopPanel)

$cmpProfileLbl = New-Object System.Windows.Forms.Label
$cmpProfileLbl.Text      = 'Saved Profile:'
$cmpProfileLbl.Location  = New-Object System.Drawing.Point(10, 23)
$cmpProfileLbl.Size      = New-Object System.Drawing.Size(90, 20)
$cmpProfileLbl.ForeColor = $clrSubtle
$cmpProfileLbl.Font      = $fontMain
$cmpProfileLbl.BackColor = [System.Drawing.Color]::Transparent
$cmpTopPanel.Controls.Add($cmpProfileLbl)

$cmpCombo = New-Object System.Windows.Forms.ComboBox
$cmpCombo.Location      = New-Object System.Drawing.Point(104, 18)
$cmpCombo.Size          = New-Object System.Drawing.Size(500, 26)
$cmpCombo.DropDownStyle = 'DropDownList'
$cmpCombo.IntegralHeight = $false
$cmpCombo.DropDownHeight = 280
$cmpCombo.BackColor     = $clrCard
$cmpCombo.ForeColor     = $clrText
$cmpCombo.Font          = $fontMain
$cmpTopPanel.Controls.Add($cmpCombo)

$btnCmpRefresh = New-StyledButton 'Refresh List' 614 18 110 28 ([System.Drawing.Color]::FromArgb(60,60,60))
$cmpTopPanel.Controls.Add($btnCmpRefresh)

$btnCmpLoad = New-StyledButton 'Compare' 734 18 110 28
$cmpTopPanel.Controls.Add($btnCmpLoad)

$cmpStatusLbl = New-Object System.Windows.Forms.Label
$cmpStatusLbl.Location  = New-Object System.Drawing.Point(855, 23)
$cmpStatusLbl.Size      = New-Object System.Drawing.Size(220, 20)
$cmpStatusLbl.ForeColor = $clrSubtle
$cmpStatusLbl.Font      = $fontSub
$cmpStatusLbl.BackColor = [System.Drawing.Color]::Transparent
$cmpTopPanel.Controls.Add($cmpStatusLbl)

# Legend
$legendPanel = New-Object System.Windows.Forms.Panel
$legendPanel.Location  = New-Object System.Drawing.Point(8, 82)
$legendPanel.Size      = New-Object System.Drawing.Size(1090, 26)
$legendPanel.BackColor = $clrBg
$tabCompare.Controls.Add($legendPanel)

function Add-LegendItem { param([string]$Text, [System.Drawing.Color]$Color, [int]$X)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "  $Text  "
    $lbl.Location  = New-Object System.Drawing.Point($X, 3)
    $lbl.Size      = New-Object System.Drawing.Size(110, 20)
    $lbl.BackColor = $Color
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font      = $fontMain
    $legendPanel.Controls.Add($lbl)
}
Add-LegendItem 'ADDED'   $clrGreen  10
Add-LegendItem 'REMOVED' $clrRed    130
Add-LegendItem 'CHANGED' $clrAmber  250
Add-LegendItem 'MATCH'   $clrSubtle 370

# Category tabs inside Compare
$cmpCatTabs = New-Object System.Windows.Forms.TabControl
$cmpCatTabs.Location  = New-Object System.Drawing.Point(8, 112)
$cmpCatTabs.Size      = New-Object System.Drawing.Size(1090, 610)
$cmpCatTabs.Font      = $fontMain
$cmpCatTabs.BackColor = $clrBg
$tabCompare.Controls.Add($cmpCatTabs)

function New-CmpGrid {
    param([string]$TabName, [string[]]$Columns)
    $tp = New-Object System.Windows.Forms.TabPage
    $tp.Text      = $TabName
    $tp.BackColor = $clrBg
    $cmpCatTabs.TabPages.Add($tp)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock                       = 'Fill'
    $grid.BackgroundColor            = $clrCard
    $grid.GridColor                  = $clrBorder
    $grid.ForeColor                  = $clrText
    $grid.Font                       = $fontMono
    $grid.RowHeadersVisible          = $false
    $grid.AllowUserToAddRows         = $false
    $grid.AllowUserToDeleteRows      = $false
    $grid.ReadOnly                   = $true
    $grid.AutoSizeColumnsMode        = 'Fill'
    $grid.SelectionMode              = 'FullRowSelect'
    $grid.MultiSelect                = $false
    $grid.BorderStyle                = 'None'
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $clrBg
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $clrText
    $grid.ColumnHeadersDefaultCellStyle.Font      = $fontBold
    $grid.DefaultCellStyle.BackColor  = $clrCard
    $grid.DefaultCellStyle.ForeColor  = $clrText
    $grid.EnableHeadersVisualStyles   = $false

    foreach ($col in $Columns) {
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.HeaderText = $col
        $grid.Columns.Add($c) | Out-Null
    }
    $tp.Controls.Add($grid)
    return $grid
}

$cmpGridWinget  = New-CmpGrid 'Winget Apps'    @('Status','Id','Name','Ref Version','Cur Version','Source')
$cmpGridModules = New-CmpGrid 'PS Modules'     @('Status','Name','Ref Version','Cur Version')
$cmpGridDrivers = New-CmpGrid 'Print Drivers'  @('Status','Name','Provider','Environment')
$cmpGridMime    = New-CmpGrid 'MIME Types'     @('Status','Extension','Ref MIME','Cur MIME')
$cmpGridTaskbar = New-CmpGrid 'Taskbar Pins'   @('Status','Name')
$cmpGridConfigs = New-CmpGrid 'Config Files'   @('Status','Path','Ref Modified','Cur Modified','Hash Match')
$cmpGridPS      = New-CmpGrid 'PS Version'     @('Item','Reference','Current','Changed')
$cmpGridWifi    = New-CmpGrid 'WiFi Profiles'  @('Status','Name','Auth','Cipher','Mode')
$cmpGridCerts   = New-CmpGrid 'Certificates'   @('Status','Store','Thumbprint','Subject','Issuer','Expires')
$cmpGridSettings= New-CmpGrid 'Settings'       @('Status','Category','Key','Ref Value','Cur Value')

function Add-CmpRow {
    param($Grid, [string]$Status, [object[]]$Values)
    $rowIdx = $Grid.Rows.Add(@(,$Status + $Values))
    $row = $Grid.Rows[$rowIdx]
    $row.DefaultCellStyle.BackColor = switch ($Status) {
        'ADDED'   { [System.Drawing.Color]::FromArgb(30, 80, 30) }
        'REMOVED' { [System.Drawing.Color]::FromArgb(80, 20, 20) }
        'CHANGED' { [System.Drawing.Color]::FromArgb(70, 55, 10) }
        default   { $clrCard }
    }
    $row.DefaultCellStyle.ForeColor = switch ($Status) {
        'ADDED'   { $clrGreen }
        'REMOVED' { $clrRed }
        'CHANGED' { $clrAmber }
        default   { $clrText }
    }
}

function Load-ProfileList {
    try {
        $cmpCombo.Items.Clear()
        $profiles = Get-ProfileList -ProfileStorePath $script:ProfileStorePath
        foreach ($p in $profiles) {
            $cmpCombo.Items.Add((Get-ProfileDisplayText -Profile $p -IncludeRollbackTag $false)) | Out-Null
        }
        $cmpCombo.Tag = $profiles
        if ($cmpCombo.Items.Count -gt 0) { $cmpCombo.SelectedIndex = 0 }
    } catch {
        $cmpCombo.Tag = @()
        Show-UPMError -Title 'Load Profile List' -FriendlyMessage 'Unable to read saved profiles for Compare. Check profile files and permissions, then refresh.' -ErrorRecord $_ -Context @{
            Operation = 'Load-ProfileList'
            StorePath = $script:ProfileStorePath
        }
    }
}

$btnCmpRefresh.Add_Click({ Load-ProfileList })

$cmpProgress = New-Object System.Windows.Forms.ProgressBar
$cmpProgress.Location = New-Object System.Drawing.Point(8, 730)
$cmpProgress.Size     = New-Object System.Drawing.Size(600, 10)
$cmpProgress.Visible  = $false
$tabCompare.Controls.Add($cmpProgress)

$btnCmpLoad.Add_Click({
    if ($cmpCombo.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Please select a profile.','Select Profile',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $profiles = $cmpCombo.Tag
    if (-not $profiles -or $cmpCombo.SelectedIndex -ge $profiles.Count) { return }
    $profileMeta = $profiles[$cmpCombo.SelectedIndex]

    $secPwd = $null
    if ($profileMeta.Encrypted -and -not $profileMeta.IsRollback) {
        $secPwd = Show-PasswordDialog "Enter password for: $($profileMeta.ProfileName)"
        if ($null -eq $secPwd) { return }
    }

    $btnCmpLoad.Enabled = $false
    $cmpStatusLbl.Text  = 'Comparing...'
    Write-UPMLog "Compare initiated against: $($profileMeta.ProfileName) | $($profileMeta.FilePath)"
    try {
        # Clear grids
        foreach ($g in @($cmpGridWinget,$cmpGridModules,$cmpGridDrivers,$cmpGridMime,$cmpGridTaskbar,$cmpGridConfigs,$cmpGridPS,$cmpGridWifi,$cmpGridCerts,$cmpGridSettings)) {
            $g.Rows.Clear()
        }

        $refSnap = Import-ProfileSnapshot -FilePath $profileMeta.FilePath -Password $secPwd

        # Capture current if needed
        if ($null -eq $script:LiveSnapshot) {
            $cmpStatusLbl.Text = 'Capturing live snapshot...'
            [System.Windows.Forms.Application]::DoEvents()
            $script:LiveSnapshot = Get-ProfileSnapshot -ProfileName "$($env:USERNAME)-live"
        }

        $diff = Compare-ProfileSnapshot -ReferenceSnapshot $refSnap -CurrentSnapshot $script:LiveSnapshot

        # ── Winget ──────────────────────────────────────────────────────────
        foreach ($app in $diff.WingetApps.Added)   { Add-CmpRow $cmpGridWinget 'ADDED'   @($app.Id, $app.Name, '', $app.Version, $app.Source) }
        foreach ($app in $diff.WingetApps.Removed) { Add-CmpRow $cmpGridWinget 'REMOVED' @($app.Id, $app.Name, $app.Version, '', $app.Source) }
        foreach ($app in $diff.WingetApps.Changed) { Add-CmpRow $cmpGridWinget 'CHANGED' @($app.Id, '', $app.RefVersion, $app.CurVersion, '') }

        # ── PS Modules ───────────────────────────────────────────────────────
        foreach ($m in $diff.PSModules.Added)   { Add-CmpRow $cmpGridModules 'ADDED'   @($m.Name, '', $m.Version) }
        foreach ($m in $diff.PSModules.Removed) { Add-CmpRow $cmpGridModules 'REMOVED' @($m.Name, $m.Version, '') }
        foreach ($m in $diff.PSModules.Changed) { Add-CmpRow $cmpGridModules 'CHANGED' @($m.Name, $m.RefVersion, $m.CurVersion) }

        # ── Print Drivers ────────────────────────────────────────────────────
        foreach ($d in $diff.PrintDrivers.Added)   { Add-CmpRow $cmpGridDrivers 'ADDED'   @($d.Name, $d.Provider, $d.PrinterEnvironment) }
        foreach ($d in $diff.PrintDrivers.Removed) { Add-CmpRow $cmpGridDrivers 'REMOVED' @($d.Name, $d.Provider, $d.PrinterEnvironment) }

        # ── MIME ──────────────────────────────────────────────────────────────
        foreach ($m in $diff.MimeTypes.Added)   { Add-CmpRow $cmpGridMime 'ADDED'   @($m.Extension, '', $m.MimeType) }
        foreach ($m in $diff.MimeTypes.Removed) { Add-CmpRow $cmpGridMime 'REMOVED' @($m.Extension, $m.MimeType, '') }
        foreach ($m in $diff.MimeTypes.Changed) { Add-CmpRow $cmpGridMime 'CHANGED' @($m.Extension, $m.RefMime, $m.CurMime) }

        # ── Taskbar ───────────────────────────────────────────────────────────
        foreach ($p in $diff.TaskbarPins.Added)   { Add-CmpRow $cmpGridTaskbar 'ADDED'   @($p.Name) }
        foreach ($p in $diff.TaskbarPins.Removed) { Add-CmpRow $cmpGridTaskbar 'REMOVED' @($p.Name) }

        # ── Config Files ─────────────────────────────────────────────────────
        foreach ($f in $diff.ConfigFiles.Added)    { Add-CmpRow $cmpGridConfigs 'ADDED'   @($f.Path, '', $f.Modified, 'N/A') }
        foreach ($f in $diff.ConfigFiles.Removed)  { Add-CmpRow $cmpGridConfigs 'REMOVED' @($f.Path, $f.Modified, '', 'N/A') }
        foreach ($f in $diff.ConfigFiles.Modified) { Add-CmpRow $cmpGridConfigs 'CHANGED' @($f.Path, $f.RefModified, $f.CurModified, 'NO') }

        # ── PS Version ────────────────────────────────────────────────────────
        $cmpGridPS.Rows.Add(@('PS Version', $diff.PSVersion.Reference, $diff.PSVersion.Current, $diff.PSVersion.Changed.ToString())) | Out-Null
        if ($diff.PSVersion.Changed) {
            $cmpGridPS.Rows[0].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(70,55,10)
            $cmpGridPS.Rows[0].DefaultCellStyle.ForeColor = $clrAmber
        }

        # ── WiFi ─────────────────────────────────────────────────────────────
        foreach ($w in $diff.WiFiProfiles.Added)   { Add-CmpRow $cmpGridWifi 'ADDED'   @($w.Name, '', '', '') }
        foreach ($w in $diff.WiFiProfiles.Removed) { Add-CmpRow $cmpGridWifi 'REMOVED' @($w.Name, '', '', '') }

        # ── Certificates ─────────────────────────────────────────────────────
        foreach ($c in $diff.Certificates.Added)   { Add-CmpRow $cmpGridCerts 'ADDED'   @('User', $c.Thumbprint, $c.Subject, $c.Issuer, $c.NotAfter) }
        foreach ($c in $diff.Certificates.Removed) { Add-CmpRow $cmpGridCerts 'REMOVED' @('User', $c.Thumbprint, $c.Subject, $c.Issuer, $c.NotAfter) }

        # ── Settings changed (Regional / Screensaver / Display / Power / Terminal) ─
        foreach ($ch in $diff.RegionalChanged.Changed)    { Add-CmpRow $cmpGridSettings 'CHANGED' @('Regional',    $ch.Key, $ch.RefValue, $ch.CurValue) }
        foreach ($ch in $diff.ScreensaverChanged.Changed) { Add-CmpRow $cmpGridSettings 'CHANGED' @('Screensaver',  $ch.Key, $ch.RefValue, $ch.CurValue) }
        foreach ($ch in $diff.DisplayChanged.Changed)     { Add-CmpRow $cmpGridSettings 'CHANGED' @('Display',      $ch.Key, $ch.RefValue, $ch.CurValue) }
        foreach ($ch in $diff.PowerChanged.Changed)       { Add-CmpRow $cmpGridSettings 'CHANGED' @('Power',        $ch.Key, $ch.RefValue, $ch.CurValue) }
        foreach ($ch in $diff.TerminalChanged.Changed)    { Add-CmpRow $cmpGridSettings 'CHANGED' @('Terminal',     $ch.Key, $ch.RefValue, $ch.CurValue) }
        foreach ($r in $diff.PSHelpRepos.Added)           { Add-CmpRow $cmpGridSettings 'ADDED'   @('PSRepository', $r.Name, '', $r.SourceLocation) }
        foreach ($r in $diff.PSHelpRepos.Removed)         { Add-CmpRow $cmpGridSettings 'REMOVED' @('PSRepository', $r.Name, $r.SourceLocation, '') }
        foreach ($s in $diff.ISESettings.Added)           { Add-CmpRow $cmpGridSettings 'ADDED'   @('ISE Registry', $s.Name, '', $s.Value) }
        foreach ($s in $diff.ISESettings.Removed)         { Add-CmpRow $cmpGridSettings 'REMOVED' @('ISE Registry', $s.Name, $s.Value, '') }

        # Guard against $null arrays (e.g. ConvertFrom-Json produces $null not @())
        function Count-Safe { param($v); if ($null -eq $v) { 0 } else { @($v).Count } }
        $total = (Count-Safe $diff.WingetApps.Added)   + (Count-Safe $diff.WingetApps.Removed)  + (Count-Safe $diff.WingetApps.Changed) +
                 (Count-Safe $diff.PSModules.Added)    + (Count-Safe $diff.PSModules.Removed)   + (Count-Safe $diff.PSModules.Changed)  +
                 (Count-Safe $diff.WiFiProfiles.Added) + (Count-Safe $diff.WiFiProfiles.Removed) +
                 (Count-Safe $diff.Certificates.Added) + (Count-Safe $diff.Certificates.Removed) +
                 (Count-Safe $diff.RegionalChanged.Changed) + (Count-Safe $diff.ScreensaverChanged.Changed)
        $cmpStatusLbl.Text = "Done -- $total change(s) detected"
        $statusLabel.Text  = "Compare complete: $($profileMeta.ProfileName) vs live"
    } catch {
        $cmpStatusLbl.Text = 'Compare failed. See log for details.'
        Show-UPMError -Title 'Compare' -FriendlyMessage 'Compare failed. This usually means one or more config captures are unreadable or inaccessible. Re-capture and retry.' -ErrorRecord $_ -Context @{
            Operation = 'Compare-ProfileSnapshot'
            ProfileName = $profileMeta.ProfileName
            ProfilePath = $profileMeta.FilePath
        }
    } finally {
        $btnCmpLoad.Enabled = $true
    }
})

# ════════════════════════════════════════════════════════════════════════════
#  TAB 4 -- RESTORE
# ════════════════════════════════════════════════════════════════════════════
$tabRestore = New-Object System.Windows.Forms.TabPage
$tabRestore.Text      = '  RESTORE  '
$tabRestore.BackColor = $clrBg
$tabs.TabPages.Add($tabRestore)

# Top load bar (shared helper: reuse same pattern)
$restTopPanel = New-Object System.Windows.Forms.Panel
$restTopPanel.Location  = New-Object System.Drawing.Point(8, 8)
$restTopPanel.Size      = New-Object System.Drawing.Size(1090, 68)
$restTopPanel.BackColor = $clrPanel
$tabRestore.Controls.Add($restTopPanel)

$restProfileLbl = New-Object System.Windows.Forms.Label
$restProfileLbl.Text      = 'Source Profile:'
$restProfileLbl.Location  = New-Object System.Drawing.Point(10, 23)
$restProfileLbl.Size      = New-Object System.Drawing.Size(95, 20)
$restProfileLbl.ForeColor = $clrSubtle
$restProfileLbl.Font      = $fontMain
$restProfileLbl.BackColor = [System.Drawing.Color]::Transparent
$restTopPanel.Controls.Add($restProfileLbl)

$restCombo = New-Object System.Windows.Forms.ComboBox
$restCombo.Location      = New-Object System.Drawing.Point(108, 18)
$restCombo.Size          = New-Object System.Drawing.Size(500, 26)
$restCombo.DropDownStyle = 'DropDownList'
$restCombo.IntegralHeight = $false
$restCombo.DropDownHeight = 280
$restCombo.BackColor     = $clrCard
$restCombo.ForeColor     = $clrText
$restCombo.Font          = $fontMain
$restTopPanel.Controls.Add($restCombo)

$btnRestRefresh = New-StyledButton 'Refresh List' 618 18 110 28 ([System.Drawing.Color]::FromArgb(60,60,60))
$restTopPanel.Controls.Add($btnRestRefresh)

$btnLoadRest = New-StyledButton 'Load Profile' 738 18 120 28 ([System.Drawing.Color]::FromArgb(50,90,50))
$restTopPanel.Controls.Add($btnLoadRest)

$restLoadLbl = New-Object System.Windows.Forms.Label
$restLoadLbl.Location  = New-Object System.Drawing.Point(868, 23)
$restLoadLbl.Size      = New-Object System.Drawing.Size(210, 20)
$restLoadLbl.ForeColor = $clrSubtle
$restLoadLbl.Font      = $fontSub
$restLoadLbl.BackColor = [System.Drawing.Color]::Transparent
$restTopPanel.Controls.Add($restLoadLbl)

# Options panel
$restOptPanel = New-Object System.Windows.Forms.GroupBox
$restOptPanel.Text      = '  Restore Options'
$restOptPanel.Location  = New-Object System.Drawing.Point(8, 90)
$restOptPanel.Size      = New-Object System.Drawing.Size(520, 220)
$restOptPanel.ForeColor = $clrText
$restOptPanel.Font      = $fontBold
$restOptPanel.BackColor = $clrPanel
$tabRestore.Controls.Add($restOptPanel)

function New-RestoreCheckbox { param([string]$Label, [int]$Y, [bool]$Default = $true)
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text      = $Label
    $chk.Location  = New-Object System.Drawing.Point(16, $Y)
    $chk.Size      = New-Object System.Drawing.Size(480, 24)
    $chk.Checked   = $Default
    $chk.ForeColor = $clrText
    $chk.Font      = $fontMain
    $chk.BackColor = [System.Drawing.Color]::Transparent
    $restOptPanel.Controls.Add($chk)
    return $chk
}

$chkRstWinget  = New-RestoreCheckbox 'Install missing Winget applications'            26  $true
$chkRstModules = New-RestoreCheckbox 'Install missing PowerShell modules'              56  $true
$chkRstTaskbar = New-RestoreCheckbox 'Restore taskbar pins and LayoutModification.xml' 86  $true
$chkRstMime    = New-RestoreCheckbox 'Restore MIME type associations (registry)'       116 $true
$chkRstCfg     = New-RestoreCheckbox 'Restore config files (METADATA NOTE -- no binary backups in snapshot)' 146 $false
$chkRstCfg.ForeColor = $clrSubtle

# Rollback notice
$rollbackNotice = New-Object System.Windows.Forms.Label
$rollbackNotice.Location  = New-Object System.Drawing.Point(8, 320)
$rollbackNotice.Size      = New-Object System.Drawing.Size(1080, 50)
$rollbackNotice.ForeColor = $clrAmber
$rollbackNotice.Font      = $fontBold
$rollbackNotice.BackColor = [System.Drawing.Color]::FromArgb(40, 32, 0)
$rollbackNotice.TextAlign = 'MiddleLeft'
$rollbackNotice.Text      = "  ⚠  A rollback snapshot will be AUTOMATICALLY captured and AES-encrypted before any changes are made.  Encryption key is derived from the profile name, machine name, and username -- no password required."
$tabRestore.Controls.Add($rollbackNotice)

$btnStartRestore = New-StyledButton 'Start Restore' 8 378 180 36 ([System.Drawing.Color]::FromArgb(160,40,40))
$btnStartRestore.Enabled = $false
$tabRestore.Controls.Add($btnStartRestore)

$restProgress = New-Object System.Windows.Forms.ProgressBar
$restProgress.Location = New-Object System.Drawing.Point(200, 384)
$restProgress.Size     = New-Object System.Drawing.Size(600, 24)
$restProgress.Visible  = $false
$tabRestore.Controls.Add($restProgress)

$restStatusLbl = New-Object System.Windows.Forms.Label
$restStatusLbl.Location  = New-Object System.Drawing.Point(8, 422)
$restStatusLbl.Size      = New-Object System.Drawing.Size(1080, 20)
$restStatusLbl.ForeColor = $clrSubtle
$restStatusLbl.Font      = $fontSub
$restStatusLbl.BackColor = [System.Drawing.Color]::Transparent
$tabRestore.Controls.Add($restStatusLbl)

# Restore log
$restLog = New-Object System.Windows.Forms.RichTextBox
$restLog.Location   = New-Object System.Drawing.Point(8, 450)
$restLog.Size       = New-Object System.Drawing.Size(1080, 264)
$restLog.BackColor  = $clrCard
$restLog.ForeColor  = $clrText
$restLog.Font       = $fontMono
$restLog.ReadOnly   = $true
$restLog.BorderStyle = 'None'
$restLog.ScrollBars = 'Vertical'
$tabRestore.Controls.Add($restLog)

function Append-RestLog { param([string]$Text, [System.Drawing.Color]$Color)
    if (-not $Color) { $Color = $clrText }
    $restLog.SelectionStart  = $restLog.TextLength
    $restLog.SelectionLength = 0
    $restLog.SelectionColor  = $Color
    $restLog.AppendText("$Text`n")
    $restLog.ScrollToCaret()
}

function Load-RestoreList {
    try {
        $restCombo.Items.Clear()
        $profiles = Get-ProfileList -ProfileStorePath $script:ProfileStorePath
        foreach ($p in $profiles) {
            $restCombo.Items.Add((Get-ProfileDisplayText -Profile $p -IncludeRollbackTag $true)) | Out-Null
        }
        $restCombo.Tag = $profiles
        if ($restCombo.Items.Count -gt 0) { $restCombo.SelectedIndex = 0 }
        $btnStartRestore.Enabled = $false
        $restLoadLbl.Text = ''
    } catch {
        $restCombo.Tag = @()
        $btnStartRestore.Enabled = $false
        Show-UPMError -Title 'Load Restore List' -FriendlyMessage 'Unable to read saved profiles for Restore. Check profile files and permissions, then refresh.' -ErrorRecord $_ -Context @{
            Operation = 'Load-RestoreList'
            StorePath = $script:ProfileStorePath
        }
    }
}

$btnRestRefresh.Add_Click({ Load-RestoreList })

$btnLoadRest.Add_Click({
    if ($restCombo.SelectedIndex -lt 0) { return }
    $profiles = $restCombo.Tag
    if (-not $profiles -or $restCombo.SelectedIndex -ge $profiles.Count) { return }
    $meta     = $profiles[$restCombo.SelectedIndex]

    $secPwd = $null
    if ($meta.Encrypted -and -not $meta.IsRollback) {
        $secPwd = Show-PasswordDialog "Enter password for: $($meta.ProfileName)"
        if ($null -eq $secPwd) { return }
    }

    try {
        $script:LoadedProfile = Import-ProfileSnapshot -FilePath $meta.FilePath -Password $secPwd
        $restLoadLbl.Text     = "Loaded: $($meta.ProfileName)"
        $btnStartRestore.Enabled = $true
        $restLog.Clear()
        Append-RestLog "Profile loaded: $($meta.ProfileName)" $clrGreen
        Append-RestLog "Captured: $($script:LoadedProfile.Meta.CapturedOn)" $clrSubtle
        Append-RestLog "Machine:  $($script:LoadedProfile.Meta.MachineName)" $clrSubtle
        Append-RestLog "Winget apps : $($script:LoadedProfile.Data.WingetApplications.Count)" $clrText
        Append-RestLog "PS Modules  : $($script:LoadedProfile.Data.PSEnvironment.InstalledModules.Count)" $clrText
        Append-RestLog "Print drivers: $($script:LoadedProfile.Data.PrintDrivers.Count)" $clrText
        Append-RestLog "── Ready. Click 'Start Restore' to proceed. ──" $clrAmber
        $statusLabel.Text = "Profile loaded for restore: $($meta.ProfileName)"
    } catch {
        if ($_ -match 'ENCRYPTED:') {
            [System.Windows.Forms.MessageBox]::Show('A password is required to open this profile.','Encrypted',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } else {
            Show-UPMError -Title 'Load Profile' -FriendlyMessage 'Unable to load the selected profile. The snapshot may be corrupted or inaccessible.' -ErrorRecord $_ -Context @{
                Operation = 'Import-ProfileSnapshot'
                ProfileName = $meta.ProfileName
                ProfilePath = $meta.FilePath
            }
        }
    }
})

$btnStartRestore.Add_Click({
    if ($null -eq $script:LoadedProfile) { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will:`n`n• [AUTO] Capture and encrypt a rollback snapshot`n• Install missing apps/modules`n• Restore taskbar, MIME types, and other settings`n`nA rollback snapshot is always saved first -- you can undo at any time.`n`nProceed?",
        'Confirm Restore',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $options = @{
        RestoreWinget      = $chkRstWinget.Checked
        RestorePSModules   = $chkRstModules.Checked
        RestoreTaskbar     = $chkRstTaskbar.Checked
        RestoreMimeTypes   = $chkRstMime.Checked
        RestoreConfigFiles = $chkRstCfg.Checked
    }

    $btnStartRestore.Enabled = $false
    $restLog.Clear()

    try {
        Invoke-WithProgress $restProgress $restStatusLbl {
            param($cb)
            $restResult = Restore-ProfileSnapshot `
                -ReferenceSnapshot $script:LoadedProfile `
                -ProfileStorePath  $script:ProfileStorePath `
                -Options           $options `
                -ProgressCallback  $cb

            Append-RestLog "ROLLBACK saved: $($restResult.RollbackPath)" $clrGreen
            Append-RestLog '' $clrText
            foreach ($log in $restResult.Restored) { Append-RestLog "  ✔ $log" $clrGreen }
            foreach ($log in $restResult.Skipped)  { Append-RestLog "  – $log" $clrSubtle }
            foreach ($log in $restResult.Errors)   { Append-RestLog "  ✘ $log" $clrRed }
            Append-RestLog '' $clrText
            Append-RestLog "Restore complete." $clrAmber
            $statusLabel.Text = "Restore complete. Rollback: $($restResult.RollbackPath)"
        }
    } catch {
        Append-RestLog "FATAL: $_" $clrRed
        Show-UPMError -Title 'Restore' -FriendlyMessage 'Restore encountered an unrecoverable error. Review the log and rollback snapshot details before retrying.' -ErrorRecord $_ -Context @{
            Operation = 'Restore-ProfileSnapshot'
            ProfileName = if ($script:LoadedProfile -and $script:LoadedProfile.Meta) { $script:LoadedProfile.Meta.ProfileName } else { 'unknown' }
        }
    } finally {
        $btnStartRestore.Enabled = $true
    }
})

# ════════════════════════════════════════════════════════════════════════════
#  STARTUP & SHOW
# ════════════════════════════════════════════════════════════════════════════
$form.Add_Load({
    Write-UPMLog "UPM started. User=$($env:USERNAME) Computer=$($env:COMPUTERNAME) Store=$($script:ProfileStorePath)"
    $statusLabel.Text = "Loading profile list from: $($script:ProfileStorePath)"
    try {
        Load-ProfileList
        Load-RestoreList
        $statusLabel.Text = "Ready -- profile store: $($script:ProfileStorePath)"
    } catch {
        $statusLabel.Text = 'Started with profile list errors. Check log.'
        Show-UPMError -Title 'Startup' -FriendlyMessage 'UPM started, but profile lists could not be fully loaded. You can continue and retry from Refresh List.' -ErrorRecord $_ -Context @{
            Operation = 'FormLoad'
            StorePath = $script:ProfileStorePath
        }
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    $activeTab = if ($tabs -and $tabs.SelectedTab) { $tabs.SelectedTab.Text } else { '(none)' }
    Write-UPMLog "UPM closing. Reason=$($e.CloseReason) ActiveTab=$activeTab Status='$($statusLabel.Text)'"
    Write-DiagnosticDump -Reason 'SessionClose' -Context @{
        CloseReason = [string]$e.CloseReason
        ActiveTab   = $activeTab
        Status      = $statusLabel.Text
        StorePath   = $script:ProfileStorePath
    }
})

# Auto-size grid columns when tabs switch
$tabs.Add_SelectedIndexChanged({
    [System.Windows.Forms.Application]::DoEvents()
})

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    Show-UPMError -Title 'Application Run' -FriendlyMessage 'UPM terminated unexpectedly while running. A diagnostic dump was written to the log.' -ErrorRecord $_ -Context @{
        Operation = 'Application.Run'
        StorePath = $script:ProfileStorePath
    }
}







