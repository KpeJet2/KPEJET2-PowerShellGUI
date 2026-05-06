# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: UIForm
#Requires -Version 5.1
<#
.SYNOPSIS
    Show-WorkspaceIntentReview -- WinForms GUI for development intent management,
    indexed change logging, and intent sealing.
.DESCRIPTION
    Provides a multi-tabbed dark-themed WinForms interface for:
      Tab 1: Intent Overview -- all intents with status, priority, sealed state
      Tab 2: Change Log     -- indexed incremental change history with filters
      Tab 3: Intent Detail  -- full audit trail for selected intent
      Tab 4: New Intent     -- create/seal/unseal intents
      Tab 5: Pipeline       -- RE-memorAiZ session results and handback status

    Intent sealing pins development direction. Sealed intents display a lock icon
    and cannot be modified without explicit unseal with documented reason.

.NOTES
    Author   : The Establishment
    Date     : 2026-04-08
    FileRole : GUI-Tool
    Version  : 2604.B2.V31.1
    Category : Workspace Governance
.EXAMPLE
    .\scripts\Show-WorkspaceIntentReview.ps1
    .\scripts\Show-WorkspaceIntentReview.ps1 -WorkspacePath C:\PowerShellGUI
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = ''
)

Set-StrictMode -Off   # P024: StrictMode scope bleed via ShowDialog

$ErrorActionPreference = 'Continue'

# ── Resolve workspace ─────────────────────────────────────────────────────────
if ($WorkspacePath -eq '') {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}

# ── Module imports ────────────────────────────────────────────────────────────
$coreModule = Join-Path $WorkspacePath 'modules\PwShGUICore.psm1'
if (Test-Path $coreModule) {
    try { Import-Module $coreModule -Force -ErrorAction Stop } catch { Write-Warning "PwShGUICore import failed: $_" }
}

$intentModule = Join-Path $WorkspacePath 'modules\WorkspaceIntentReview.psm1'
if (Test-Path $intentModule) {
    try { Import-Module $intentModule -Force -ErrorAction Stop } catch { Write-Warning "WorkspaceIntentReview import failed: $_" }
}

$memoraizModule = Join-Path $WorkspacePath 'modules\RE-memorAiZ.psm1'
if (Test-Path $memoraizModule) {
    try { Import-Module $memoraizModule -Force -ErrorAction Stop } catch { Write-Warning "RE-memorAiZ import failed: $_" }
}

# ── Initialize intent store ──────────────────────────────────────────────────
Initialize-IntentStore -WorkspacePath $WorkspacePath

# ── Assemblies ────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ═══════════════════════════════════════════════════════════════════════════════
#  THEME & FONTS
# ═══════════════════════════════════════════════════════════════════════════════

$script:bgDark   = [System.Drawing.Color]::FromArgb(30, 30, 30)
$script:bgMed    = [System.Drawing.Color]::FromArgb(45, 45, 48)
$script:bgLight  = [System.Drawing.Color]::FromArgb(62, 62, 66)
$script:fgWhite  = [System.Drawing.Color]::White
$script:fgGray   = [System.Drawing.Color]::FromArgb(180, 180, 180)
$script:accBlue  = [System.Drawing.Color]::FromArgb(0, 122, 204)
$script:accGreen = [System.Drawing.Color]::FromArgb(78, 201, 176)
$script:accRed   = [System.Drawing.Color]::FromArgb(244, 71, 71)
$script:accAmber = [System.Drawing.Color]::FromArgb(255, 193, 7)

$script:fontNorm = New-Object System.Drawing.Font('Segoe UI', 9.5)
$script:fontBold = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$script:fontHead = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$script:fontMono = New-Object System.Drawing.Font('Consolas', 9.5)

# ═══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function New-StyledLabel {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 200, [int]$H = 20, [System.Drawing.Font]$Font = $script:fontNorm)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($W, $H)
    $lbl.Font = $Font
    $lbl.ForeColor = $script:fgWhite
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    return $lbl
}

function New-StyledButton {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 30, [System.Drawing.Color]$BgColor = $script:accBlue)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.Font = $script:fontBold
    $btn.ForeColor = $script:fgWhite
    $btn.BackColor = $BgColor
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function New-StyledDGV {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Location = New-Object System.Drawing.Point($X, $Y)
    $dgv.Size = New-Object System.Drawing.Size($W, $H)
    $dgv.BackgroundColor = $script:bgMed
    $dgv.ForeColor = $script:fgWhite
    $dgv.GridColor = $script:bgLight
    $dgv.Font = $script:fontNorm
    $dgv.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $dgv.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $dgv.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
    $dgv.EnableHeadersVisualStyles = $false
    $dgv.ColumnHeadersDefaultCellStyle.BackColor = $script:bgDark
    $dgv.ColumnHeadersDefaultCellStyle.ForeColor = $script:fgWhite
    $dgv.ColumnHeadersDefaultCellStyle.Font = $script:fontBold
    $dgv.DefaultCellStyle.BackColor = $script:bgMed
    $dgv.DefaultCellStyle.ForeColor = $script:fgWhite
    $dgv.DefaultCellStyle.SelectionBackColor = $script:accBlue
    $dgv.DefaultCellStyle.SelectionForeColor = $script:fgWhite
    $dgv.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 42)
    $dgv.RowHeadersVisible = $false
    $dgv.AllowUserToAddRows = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.ReadOnly = $true
    $dgv.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $dgv.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    return $dgv
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'DRAFT'    { return $script:fgGray }
        'ACTIVE'   { return $script:accGreen }
        'SEALED'   { return $script:accAmber }
        'ARCHIVED' { return $script:accRed }
        default    { return $script:fgWhite }
    }
}

function Refresh-IntentGrid {
    param([System.Windows.Forms.DataGridView]$Grid)
    $Grid.Rows.Clear()
    $intents = Get-DevelopmentIntent -Status 'ALL'
    foreach ($intent in $intents) {
        $sealIcon = if ($intent.status -eq 'SEALED') { '[LOCKED]' } else { '' }
        $rowIdx = $Grid.Rows.Add(
            $intent.intentId,
            $intent.title,
            "$($intent.status) $sealIcon",
            $intent.priority,
            $intent.author,
            $intent.createdAt,
            $intent.updatedAt
        )
        $row = $Grid.Rows[$rowIdx]
        $statusColor = Get-StatusColor -Status $intent.status
        if ($null -ne $row.Cells[2]) {
            $row.Cells[2].Style.ForeColor = $statusColor
        }
    }
}

function Refresh-ChangeLogGrid {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [int]$Last = 100
    )
    $Grid.Rows.Clear()
    $entries = Get-ChangeLogEntries -Last $Last
    foreach ($entry in $entries) {
        $filesStr = if (@($entry.affectedFiles).Count -gt 0) { ($entry.affectedFiles -join ', ') } else { '' }
        $Grid.Rows.Add(
            $entry.index,
            $entry.timestamp,
            $entry.changeType,
            $entry.description,
            $entry.agent,
            $entry.governingIntentId,
            $filesStr
        ) | Out-Null
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  BUILD FORM
# ═══════════════════════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text = "Workspace Intent Review -- PowerShellGUI"
$form.Size = New-Object System.Drawing.Size(1100, 750)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:bgDark
$form.ForeColor = $script:fgWhite
$form.Font = $script:fontNorm

# ── Tab Control ───────────────────────────────────────────────────────────────
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 10)
$tabControl.Size = New-Object System.Drawing.Size(1065, 690)
$tabControl.Font = $script:fontBold
$tabControl.BackColor = $script:bgMed

# ═══════════════════════════════════════════════════════════════════════════════
#  TAB 1: INTENT OVERVIEW
# ═══════════════════════════════════════════════════════════════════════════════

$tabIntents = New-Object System.Windows.Forms.TabPage
$tabIntents.Text = 'Intent Overview'
$tabIntents.BackColor = $script:bgDark

$lblIntentsTitle = New-StyledLabel -Text 'Development Intents' -X 10 -Y 10 -W 400 -H 30 -Font $script:fontHead
$tabIntents.Controls.Add($lblIntentsTitle)

# Intent grid
$dgvIntents = New-StyledDGV -X 10 -Y 50 -W 1035 -H 450
$dgvIntents.Columns.Add('ID', 'ID') | Out-Null
$dgvIntents.Columns.Add('Title', 'Title') | Out-Null
$dgvIntents.Columns.Add('Status', 'Status') | Out-Null
$dgvIntents.Columns.Add('Priority', 'Priority') | Out-Null
$dgvIntents.Columns.Add('Author', 'Author') | Out-Null
$dgvIntents.Columns.Add('Created', 'Created') | Out-Null
$dgvIntents.Columns.Add('Updated', 'Updated') | Out-Null
$dgvIntents.Columns['ID'].Width = 50
$dgvIntents.Columns['Title'].Width = 300
$dgvIntents.Columns['Status'].Width = 120
$tabIntents.Controls.Add($dgvIntents)

# Action buttons
$btnRefreshIntents = New-StyledButton -Text 'Refresh' -X 10 -Y 510 -W 100 -BgColor $script:accBlue
$btnRefreshIntents.Add_Click({ Refresh-IntentGrid -Grid $dgvIntents })
$tabIntents.Controls.Add($btnRefreshIntents)

$btnSealIntent = New-StyledButton -Text 'Seal Intent' -X 120 -Y 510 -W 120 -BgColor $script:accAmber
$btnSealIntent.Add_Click({
    if (@($dgvIntents.SelectedRows).Count -gt 0) {
        $selectedId = [int]$dgvIntents.SelectedRows[0].Cells['ID'].Value
        $result = Invoke-IntentSeal -IntentId $selectedId
        if ($null -ne $result) {
            [System.Windows.Forms.MessageBox]::Show(
                "Intent #$selectedId sealed successfully.",
                'Intent Sealed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            Add-ChangeLogEntry -Description "Intent #$selectedId sealed" -ChangeType 'Sealed' -Agent $env:USERNAME -GoverningIntentId $selectedId
            Refresh-IntentGrid -Grid $dgvIntents
        }
    }
})
$tabIntents.Controls.Add($btnSealIntent)

$btnUnsealIntent = New-StyledButton -Text 'Unseal' -X 250 -Y 510 -W 100 -BgColor $script:accRed
$btnUnsealIntent.Add_Click({
    if (@($dgvIntents.SelectedRows).Count -gt 0) {
        $selectedId = [int]$dgvIntents.SelectedRows[0].Cells['ID'].Value
        $reason = [Microsoft.VisualBasic.Interaction]::InputBox(
            'Provide reason for unsealing this intent:',
            'Unseal Intent',
            ''
        )
        if ($reason -ne '') {
            $result = Invoke-IntentUnseal -IntentId $selectedId -Reason $reason
            if ($null -ne $result) {
                Add-ChangeLogEntry -Description "Intent #$selectedId unsealed: $reason" -ChangeType 'Unsealed' -Agent $env:USERNAME -GoverningIntentId $selectedId
                Refresh-IntentGrid -Grid $dgvIntents
            }
        }
    }
})
$tabIntents.Controls.Add($btnUnsealIntent)

$btnActivateIntent = New-StyledButton -Text 'Activate' -X 360 -Y 510 -W 100 -BgColor $script:accGreen
$btnActivateIntent.Add_Click({
    if (@($dgvIntents.SelectedRows).Count -gt 0) {
        $selectedId = [int]$dgvIntents.SelectedRows[0].Cells['ID'].Value
        $result = Set-IntentStatus -IntentId $selectedId -NewStatus 'ACTIVE'
        if ($null -ne $result) {
            Refresh-IntentGrid -Grid $dgvIntents
        }
    }
})
$tabIntents.Controls.Add($btnActivateIntent)

$btnArchiveIntent = New-StyledButton -Text 'Archive' -X 470 -Y 510 -W 100 -BgColor $script:bgLight
$btnArchiveIntent.Add_Click({
    if (@($dgvIntents.SelectedRows).Count -gt 0) {
        $selectedId = [int]$dgvIntents.SelectedRows[0].Cells['ID'].Value
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Archive intent #$selectedId? This is a soft-delete.",
            'Confirm Archive',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Set-IntentStatus -IntentId $selectedId -NewStatus 'ARCHIVED' -Reason 'Archived via GUI'
            Refresh-IntentGrid -Grid $dgvIntents
        }
    }
})
$tabIntents.Controls.Add($btnArchiveIntent)

$tabControl.TabPages.Add($tabIntents)

# ═══════════════════════════════════════════════════════════════════════════════
#  TAB 2: CHANGE LOG
# ═══════════════════════════════════════════════════════════════════════════════

$tabChangeLog = New-Object System.Windows.Forms.TabPage
$tabChangeLog.Text = 'Change Log'
$tabChangeLog.BackColor = $script:bgDark

$lblChangeTitle = New-StyledLabel -Text 'Indexed Change Log' -X 10 -Y 10 -W 400 -H 30 -Font $script:fontHead
$tabChangeLog.Controls.Add($lblChangeTitle)

$dgvChanges = New-StyledDGV -X 10 -Y 50 -W 1035 -H 500
$dgvChanges.Columns.Add('Idx', '#') | Out-Null
$dgvChanges.Columns.Add('Timestamp', 'Timestamp') | Out-Null
$dgvChanges.Columns.Add('Type', 'Type') | Out-Null
$dgvChanges.Columns.Add('Description', 'Description') | Out-Null
$dgvChanges.Columns.Add('Agent', 'Agent') | Out-Null
$dgvChanges.Columns.Add('Intent', 'Intent#') | Out-Null
$dgvChanges.Columns.Add('Files', 'Affected Files') | Out-Null
$dgvChanges.Columns['Idx'].Width = 50
$dgvChanges.Columns['Description'].Width = 300
$tabChangeLog.Controls.Add($dgvChanges)

$btnRefreshLog = New-StyledButton -Text 'Refresh' -X 10 -Y 560 -W 100 -BgColor $script:accBlue
$btnRefreshLog.Add_Click({ Refresh-ChangeLogGrid -Grid $dgvChanges -Last 100 })
$tabChangeLog.Controls.Add($btnRefreshLog)

$tabControl.TabPages.Add($tabChangeLog)

# ═══════════════════════════════════════════════════════════════════════════════
#  TAB 3: INTENT DETAIL / HISTORY
# ═══════════════════════════════════════════════════════════════════════════════

$tabDetail = New-Object System.Windows.Forms.TabPage
$tabDetail.Text = 'Intent Detail'
$tabDetail.BackColor = $script:bgDark

$lblDetailTitle = New-StyledLabel -Text 'Intent Audit Trail' -X 10 -Y 10 -W 400 -H 30 -Font $script:fontHead
$tabDetail.Controls.Add($lblDetailTitle)

$lblSelectIntent = New-StyledLabel -Text 'Intent ID:' -X 10 -Y 50 -W 80 -H 25
$tabDetail.Controls.Add($lblSelectIntent)

$txtIntentId = New-Object System.Windows.Forms.TextBox
$txtIntentId.Location = New-Object System.Drawing.Point(90, 48)
$txtIntentId.Size = New-Object System.Drawing.Size(60, 25)
$txtIntentId.Font = $script:fontMono
$txtIntentId.BackColor = $script:bgLight
$txtIntentId.ForeColor = $script:fgWhite
$tabDetail.Controls.Add($txtIntentId)

$btnLoadDetail = New-StyledButton -Text 'Load' -X 160 -Y 47 -W 80 -H 27
$tabDetail.Controls.Add($btnLoadDetail)

$txtDetailOutput = New-Object System.Windows.Forms.RichTextBox
$txtDetailOutput.Location = New-Object System.Drawing.Point(10, 85)
$txtDetailOutput.Size = New-Object System.Drawing.Size(1035, 540)
$txtDetailOutput.Font = $script:fontMono
$txtDetailOutput.BackColor = $script:bgMed
$txtDetailOutput.ForeColor = $script:fgWhite
$txtDetailOutput.ReadOnly = $true
$txtDetailOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tabDetail.Controls.Add($txtDetailOutput)

$btnLoadDetail.Add_Click({
    $idText = $txtIntentId.Text.Trim()
    if ($idText -match '^\d+$') {
        $history = Get-IntentHistory -IntentId ([int]$idText)
        if ($null -ne $history) {
            $sb = [System.Text.StringBuilder]::new()
            $i = $history.intent
            [void]$sb.AppendLine("=== Intent #$($i.intentId): $($i.title) ===")
            [void]$sb.AppendLine("Status     : $($i.status)")
            [void]$sb.AppendLine("Priority   : $($i.priority)")
            [void]$sb.AppendLine("Author     : $($i.author)")
            [void]$sb.AppendLine("Created    : $($i.createdAt)")
            [void]$sb.AppendLine("Updated    : $($i.updatedAt)")
            if ($null -ne $i.sealedAt -and $i.sealedAt -ne '') {
                [void]$sb.AppendLine("Sealed At  : $($i.sealedAt)")
                [void]$sb.AppendLine("Sealed By  : $($i.sealedBy)")
            }
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("--- Description ---")
            [void]$sb.AppendLine($i.description)
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("--- Intent History ---")
            foreach ($h in @($history.intentHistory)) {
                [void]$sb.AppendLine("  [$($h.timestamp)] $($h.action) by $($h.by)")
                [void]$sb.AppendLine("    $($h.detail)")
            }
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("--- Related Changes ($(@($history.relatedChanges).Count) entries) ---")
            foreach ($c in @($history.relatedChanges)) {
                [void]$sb.AppendLine("  #$($c.index) [$($c.timestamp)] $($c.changeType): $($c.description)")
            }
            $txtDetailOutput.Text = $sb.ToString()
        } else {
            $txtDetailOutput.Text = "Intent #$idText not found."
        }
    }
})

$tabControl.TabPages.Add($tabDetail)

# ═══════════════════════════════════════════════════════════════════════════════
#  TAB 4: NEW INTENT
# ═══════════════════════════════════════════════════════════════════════════════

$tabNewIntent = New-Object System.Windows.Forms.TabPage
$tabNewIntent.Text = 'New Intent'
$tabNewIntent.BackColor = $script:bgDark

$lblNewTitle = New-StyledLabel -Text 'Create Development Intent' -X 10 -Y 10 -W 400 -H 30 -Font $script:fontHead
$tabNewIntent.Controls.Add($lblNewTitle)

$lblTitle = New-StyledLabel -Text 'Title:' -X 10 -Y 55 -W 80
$tabNewIntent.Controls.Add($lblTitle)
$txtTitle = New-Object System.Windows.Forms.TextBox
$txtTitle.Location = New-Object System.Drawing.Point(90, 53)
$txtTitle.Size = New-Object System.Drawing.Size(500, 25)
$txtTitle.Font = $script:fontNorm
$txtTitle.BackColor = $script:bgLight
$txtTitle.ForeColor = $script:fgWhite
$tabNewIntent.Controls.Add($txtTitle)

$lblDesc = New-StyledLabel -Text 'Description:' -X 10 -Y 90 -W 80
$tabNewIntent.Controls.Add($lblDesc)
$txtDesc = New-Object System.Windows.Forms.TextBox
$txtDesc.Location = New-Object System.Drawing.Point(90, 88)
$txtDesc.Size = New-Object System.Drawing.Size(500, 120)
$txtDesc.Multiline = $true
$txtDesc.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtDesc.Font = $script:fontNorm
$txtDesc.BackColor = $script:bgLight
$txtDesc.ForeColor = $script:fgWhite
$tabNewIntent.Controls.Add($txtDesc)

$lblPri = New-StyledLabel -Text 'Priority:' -X 10 -Y 220 -W 80
$tabNewIntent.Controls.Add($lblPri)
$cmbPriority = New-Object System.Windows.Forms.ComboBox
$cmbPriority.Location = New-Object System.Drawing.Point(90, 218)
$cmbPriority.Size = New-Object System.Drawing.Size(120, 25)
$cmbPriority.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbPriority.Items.AddRange(@('HIGH','MEDIUM','LOW'))
$cmbPriority.SelectedIndex = 1
$cmbPriority.Font = $script:fontNorm
$cmbPriority.BackColor = $script:bgLight
$cmbPriority.ForeColor = $script:fgWhite
$tabNewIntent.Controls.Add($cmbPriority)

$lblTags = New-StyledLabel -Text 'Tags (comma-sep):' -X 10 -Y 255 -W 130
$tabNewIntent.Controls.Add($lblTags)
$txtTags = New-Object System.Windows.Forms.TextBox
$txtTags.Location = New-Object System.Drawing.Point(140, 253)
$txtTags.Size = New-Object System.Drawing.Size(450, 25)
$txtTags.Font = $script:fontNorm
$txtTags.BackColor = $script:bgLight
$txtTags.ForeColor = $script:fgWhite
$tabNewIntent.Controls.Add($txtTags)

$lblModules = New-StyledLabel -Text 'Modules (comma-sep):' -X 10 -Y 290 -W 130
$tabNewIntent.Controls.Add($lblModules)
$txtModules = New-Object System.Windows.Forms.TextBox
$txtModules.Location = New-Object System.Drawing.Point(140, 288)
$txtModules.Size = New-Object System.Drawing.Size(450, 25)
$txtModules.Font = $script:fontNorm
$txtModules.BackColor = $script:bgLight
$txtModules.ForeColor = $script:fgWhite
$tabNewIntent.Controls.Add($txtModules)

$chkSealImmediate = New-Object System.Windows.Forms.CheckBox
$chkSealImmediate.Text = 'Seal immediately after creation'
$chkSealImmediate.Location = New-Object System.Drawing.Point(90, 325)
$chkSealImmediate.Size = New-Object System.Drawing.Size(250, 25)
$chkSealImmediate.Font = $script:fontNorm
$chkSealImmediate.ForeColor = $script:accAmber
$tabNewIntent.Controls.Add($chkSealImmediate)

$btnCreateIntent = New-StyledButton -Text 'Create Intent' -X 90 -Y 360 -W 150 -H 35 -BgColor $script:accGreen
$btnCreateIntent.Add_Click({
    $title = $txtTitle.Text.Trim()
    $desc = $txtDesc.Text.Trim()
    if ($title -eq '' -or $desc -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Title and Description are required.', 'Validation', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $tags = @($txtTags.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $modules = @($txtModules.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $priority = $cmbPriority.SelectedItem.ToString()

    $intent = New-DevelopmentIntent -Title $title -Description $desc -Priority $priority -Tags $tags -AffectedModules $modules
    if ($null -ne $intent) {
        Add-ChangeLogEntry -Description "Created intent: $title" -ChangeType 'Created' -Agent $env:USERNAME -GoverningIntentId $intent.intentId

        if ($chkSealImmediate.Checked) {
            Invoke-IntentSeal -IntentId $intent.intentId
            Add-ChangeLogEntry -Description "Intent #$($intent.intentId) sealed on creation" -ChangeType 'Sealed' -Agent $env:USERNAME -GoverningIntentId $intent.intentId
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Intent #$($intent.intentId) created$(if ($chkSealImmediate.Checked) { ' and sealed' }).",
            'Intent Created',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Clear form
        $txtTitle.Text = ''
        $txtDesc.Text = ''
        $txtTags.Text = ''
        $txtModules.Text = ''
        $chkSealImmediate.Checked = $false

        # Refresh overview
        Refresh-IntentGrid -Grid $dgvIntents
    }
})
$tabNewIntent.Controls.Add($btnCreateIntent)

$tabControl.TabPages.Add($tabNewIntent)

# ═══════════════════════════════════════════════════════════════════════════════
#  TAB 5: PIPELINE STATUS
# ═══════════════════════════════════════════════════════════════════════════════

$tabPipeline = New-Object System.Windows.Forms.TabPage
$tabPipeline.Text = 'Pipeline'
$tabPipeline.BackColor = $script:bgDark

$lblPipeTitle = New-StyledLabel -Text 'RE-memorAiZ Pipeline Status' -X 10 -Y 10 -W 400 -H 30 -Font $script:fontHead
$tabPipeline.Controls.Add($lblPipeTitle)

$txtPipeOutput = New-Object System.Windows.Forms.RichTextBox
$txtPipeOutput.Location = New-Object System.Drawing.Point(10, 50)
$txtPipeOutput.Size = New-Object System.Drawing.Size(1035, 500)
$txtPipeOutput.Font = $script:fontMono
$txtPipeOutput.BackColor = $script:bgMed
$txtPipeOutput.ForeColor = $script:fgWhite
$txtPipeOutput.ReadOnly = $true
$txtPipeOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tabPipeline.Controls.Add($txtPipeOutput)

$btnLoadMemory = New-StyledButton -Text 'Load Memory' -X 10 -Y 560 -W 120 -BgColor $script:accBlue
$btnLoadMemory.Add_Click({
    $memPath = Join-Path $WorkspacePath 'config\workspace-memory-summary.json'
    if (Test-Path $memPath) {
        $memData = Get-Content $memPath -Raw | ConvertFrom-Json
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("=== Workspace Memory Summary ===")
        [void]$sb.AppendLine("Last Updated  : $($memData.lastUpdated)")
        [void]$sb.AppendLine("Updated By    : $($memData.lastUpdatedBy)")
        [void]$sb.AppendLine("Session ID    : $($memData.sessionId)")
        [void]$sb.AppendLine("Version Tag   : $($memData.currentVersionTag)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--- Inventory ---")
        if ($null -ne $memData.inventory) {
            [void]$sb.AppendLine("  Modules     : $($memData.inventory.modules)")
            [void]$sb.AppendLine("  Scripts     : $($memData.inventory.scripts)")
            [void]$sb.AppendLine("  Tests       : $($memData.inventory.tests)")
            [void]$sb.AppendLine("  SIN Patterns: $($memData.inventory.sinPatterns)")
            [void]$sb.AppendLine("  Agents      : $($memData.inventory.agents)")
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--- Handback Registry ---")
        if ($null -ne $memData.handbackRegistry) {
            $hbProps = @($memData.handbackRegistry.PSObject.Properties)
            if (@($hbProps).Count -eq 0) {
                [void]$sb.AppendLine("  No pending handbacks")
            } else {
                foreach ($p in $hbProps) {
                    [void]$sb.AppendLine("  $($p.Name): $(@($p.Value).Count) items")
                }
            }
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--- Development Intent ---")
        if ($null -ne $memData.developmentIntent) {
            [void]$sb.AppendLine("  Chief Directive: $($memData.developmentIntent.chiefDirective)")
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--- Continuity ---")
        if ($null -ne $memData.continuityNotes) {
            [void]$sb.AppendLine("  $($memData.continuityNotes.resumeInstructions)")
        }
        $txtPipeOutput.Text = $sb.ToString()
    } else {
        $txtPipeOutput.Text = "Memory file not found. Run Invoke-REmemorAiZ to generate."
    }
})
$tabPipeline.Controls.Add($btnLoadMemory)

$btnRunPipeline = New-StyledButton -Text 'Run Pipeline (DryRun)' -X 140 -Y 560 -W 180 -BgColor $script:accAmber
$btnRunPipeline.Add_Click({
    $txtPipeOutput.Text = "Running RE-memorAiZ in DryRun mode...`r`nThis may take a moment."
    $txtPipeOutput.Refresh()
    try {
        $result = Invoke-REmemorAiZ -WorkspacePath $WorkspacePath -DryRun -SkipManifest -SkipDependency
        if ($null -ne $result) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("=== RE-memorAiZ DryRun Results ===")
            [void]$sb.AppendLine("Session    : $($result.sessionId)")
            [void]$sb.AppendLine("Elapsed    : $([math]::Round($result.elapsed, 1))s")
            [void]$sb.AppendLine('')
            foreach ($k in $result.phases.Keys) {
                $p = $result.phases[$k]
                [void]$sb.AppendLine("Phase: $k -> $($p.status) ($([math]::Round($p.duration, 2))s)")
            }
            $txtPipeOutput.Text = $sb.ToString()
        }
    } catch {
        $txtPipeOutput.Text = "Pipeline error: $($_.Exception.Message)"
    }
})
$tabPipeline.Controls.Add($btnRunPipeline)

$tabControl.TabPages.Add($tabPipeline)

# ── Add TabControl to Form ───────────────────────────────────────────────────
$form.Controls.Add($tabControl)

# ── Status bar ────────────────────────────────────────────────────────────────
$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusBar.BackColor = $script:bgDark
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.ForeColor = $script:fgGray
$statusLabel.Text = "Workspace: $WorkspacePath | v2604.B2.V31.1 | Session: $(Get-Date -Format 'HH:mm:ss')"
$statusBar.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusBar)

# ── Initial data load ────────────────────────────────────────────────────────
$form.Add_Shown({
    Refresh-IntentGrid -Grid $dgvIntents
    Refresh-ChangeLogGrid -Grid $dgvChanges -Last 100
})

# ── Show Form ─────────────────────────────────────────────────────────────────
[void]$form.ShowDialog()

# ── Cleanup ───────────────────────────────────────────────────────────────────
$form.Dispose()

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





