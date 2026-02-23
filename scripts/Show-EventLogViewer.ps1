# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Event Log Viewer - Browse and filter Windows Event Logs in a WinForms GUI.

.DESCRIPTION
    Displays System, Application, and Security event logs with filtering by level,
    source, date range, and keyword search. Results shown in a sortable DataGridView.

.NOTES
    Author   : The Establishment
    Created  : 24th March 2026
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-EventLogViewer {
    [CmdletBinding()]
    param()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Event Log Viewer"
    $form.Size = New-Object System.Drawing.Size(960, 640)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(800, 500)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # ── Filter Panel ─────────────────────────────────────────────
    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $filterPanel.Height = 60
    $filterPanel.Padding = New-Object System.Windows.Forms.Padding(8)

    # Log Name
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "Log:"
    $lblLog.Location = New-Object System.Drawing.Point(8, 10)
    $lblLog.Size = New-Object System.Drawing.Size(30, 20)
    $filterPanel.Controls.Add($lblLog)

    $cboLog = New-Object System.Windows.Forms.ComboBox
    $cboLog.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboLog.Location = New-Object System.Drawing.Point(40, 7)
    $cboLog.Size = New-Object System.Drawing.Size(120, 22)
    $cboLog.Items.AddRange(@("Application", "System", "Security"))
    $cboLog.SelectedIndex = 0
    $filterPanel.Controls.Add($cboLog)

    # Level
    $lblLevel = New-Object System.Windows.Forms.Label
    $lblLevel.Text = "Level:"
    $lblLevel.Location = New-Object System.Drawing.Point(170, 10)
    $lblLevel.Size = New-Object System.Drawing.Size(38, 20)
    $filterPanel.Controls.Add($lblLevel)

    $cboLevel = New-Object System.Windows.Forms.ComboBox
    $cboLevel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboLevel.Location = New-Object System.Drawing.Point(210, 7)
    $cboLevel.Size = New-Object System.Drawing.Size(100, 22)
    $cboLevel.Items.AddRange(@("All", "Error", "Warning", "Information"))
    $cboLevel.SelectedIndex = 0
    $filterPanel.Controls.Add($cboLevel)

    # Max events
    $lblMax = New-Object System.Windows.Forms.Label
    $lblMax.Text = "Max:"
    $lblMax.Location = New-Object System.Drawing.Point(320, 10)
    $lblMax.Size = New-Object System.Drawing.Size(34, 20)
    $filterPanel.Controls.Add($lblMax)

    $nudMax = New-Object System.Windows.Forms.NumericUpDown
    $nudMax.Location = New-Object System.Drawing.Point(356, 7)
    $nudMax.Size = New-Object System.Drawing.Size(70, 22)
    $nudMax.Minimum = 10
    $nudMax.Maximum = 5000
    $nudMax.Value = 200
    $nudMax.Increment = 50
    $filterPanel.Controls.Add($nudMax)

    # Keyword filter
    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"
    $lblSearch.Location = New-Object System.Drawing.Point(436, 10)
    $lblSearch.Size = New-Object System.Drawing.Size(46, 20)
    $filterPanel.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(484, 7)
    $txtSearch.Size = New-Object System.Drawing.Size(180, 22)
    $filterPanel.Controls.Add($txtSearch)

    # Fetch button
    $btnFetch = New-Object System.Windows.Forms.Button
    $btnFetch.Text = "Fetch Events"
    $btnFetch.Location = New-Object System.Drawing.Point(674, 5)
    $btnFetch.Size = New-Object System.Drawing.Size(100, 26)
    $filterPanel.Controls.Add($btnFetch)

    # Status label
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Ready"
    $lblStatus.Location = New-Object System.Drawing.Point(8, 36)
    $lblStatus.Size = New-Object System.Drawing.Size(760, 18)
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $filterPanel.Controls.Add($lblStatus)

    $form.Controls.Add($filterPanel)

    # ── DataGridView ─────────────────────────────────────────────
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $dgv.AllowUserToAddRows = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.ReadOnly = $true
    $dgv.SelectionMode = "FullRowSelect"
    $dgv.AutoSizeColumnsMode = "Fill"
    $dgv.RowHeadersVisible = $false
    $dgv.BackgroundColor = [System.Drawing.Color]::White
    $dgv.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $null = $dgv.Columns.Add((New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = "Time"; HeaderText = "Time"; Width = 150 }))
    $null = $dgv.Columns.Add((New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = "Level"; HeaderText = "Level"; Width = 80 }))
    $null = $dgv.Columns.Add((New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = "Source"; HeaderText = "Source"; Width = 160 }))
    $null = $dgv.Columns.Add((New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = "EventID"; HeaderText = "ID"; Width = 60 }))
    $null = $dgv.Columns.Add((New-Object System.Windows.Forms.DataGridViewTextBoxColumn -Property @{ Name = "Message"; HeaderText = "Message"; AutoSizeMode = "Fill" }))

    $form.Controls.Add($dgv)

    # ── Detail Panel ─────────────────────────────────────────────
    $detailPanel = New-Object System.Windows.Forms.Panel
    $detailPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $detailPanel.Height = 120

    $txtDetail = New-Object System.Windows.Forms.TextBox
    $txtDetail.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtDetail.Multiline = $true
    $txtDetail.ReadOnly = $true
    $txtDetail.ScrollBars = "Vertical"
    $txtDetail.Font = New-Object System.Drawing.Font("Consolas", 9)
    $txtDetail.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $detailPanel.Controls.Add($txtDetail)
    $form.Controls.Add($detailPanel)

    # ── Row selection -> detail ──────────────────────────────────
    $dgv.Add_SelectionChanged({
        if ($dgv.SelectedRows.Count -eq 0) { return }
        $row = $dgv.SelectedRows[0]
        $txtDetail.Text = "[$($row.Cells['Time'].Value)] [$($row.Cells['Level'].Value)] $($row.Cells['Source'].Value) (ID: $($row.Cells['EventID'].Value))`r`n`r`n$($row.Cells['Message'].Value)"
    })

    # ── Colour rows by level ────────────────────────────────────
    $dgv.Add_CellFormatting({
        param($sender, $e)
        if ($e.ColumnIndex -ne 1) { return }
        $val = $sender.Rows[$e.RowIndex].Cells[1].Value
        switch ($val) {
            'Error'       { $e.CellStyle.ForeColor = [System.Drawing.Color]::Red }
            'Warning'     { $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            'Information' { $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkBlue }
        }
    })

    # ── Fetch logic ──────────────────────────────────────────────
    $FetchEvents = {
        $dgv.Rows.Clear()
        $txtDetail.Text = ""
        $logName = $cboLog.SelectedItem
        $maxEntries = [int]$nudMax.Value
        $levelFilter = $cboLevel.SelectedItem
        $keyword = $txtSearch.Text.Trim()

        $lblStatus.Text = "Fetching $logName events..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Refresh()

        try {
            $entries = Get-EventLog -LogName $logName -Newest $maxEntries -ErrorAction Stop

            if ($levelFilter -ne 'All') {
                $entries = $entries | Where-Object { $_.EntryType -eq $levelFilter }
            }
            if ($keyword) {
                $entries = $entries | Where-Object {
                    $_.Message -like "*$keyword*" -or $_.Source -like "*$keyword*"
                }
            }

            foreach ($entry in $entries) {
                $msg = if ($entry.Message) { $entry.Message.Replace("`r`n", " ").Replace("`n", " ") } else { "" }
                if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + "..." }
                $null = $dgv.Rows.Add(
                    $entry.TimeGenerated.ToString("yyyy-MM-dd HH:mm:ss"),
                    $entry.EntryType.ToString(),
                    $entry.Source,
                    $entry.InstanceId,
                    $msg
                )
            }

            $lblStatus.Text = "Loaded $($dgv.Rows.Count) entries from $logName log"
        }
        catch {
            $lblStatus.Text = "Error: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }
        finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $btnFetch.Add_Click($FetchEvents)

    # Auto-fetch on load
    $form.Add_Shown({ & $FetchEvents })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# Entry point
Show-EventLogViewer

