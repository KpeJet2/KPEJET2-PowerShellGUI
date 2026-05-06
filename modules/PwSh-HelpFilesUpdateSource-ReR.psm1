# VersionTag: 2604.B2.V31.2
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
PowerShell Help Files Update Source - ReR (Remote Resource Retrieval)
# TODO: HelpMenu | Show-HelpFilesHelp | Actions: Update|Check|Download|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
A GUI-based module for managing PowerShell help file sources. Allows users to specify
a location to save and update PowerShell Help files with support for UICultures En-US
and En-AU. Provides Save-Help and Update-Help operations with visual feedback.

.NOTES

.LINK

.INPUTS

.OUTPUTS

.FUNCTIONALITY
Simplifies PowerShell help file management for offline environments and local repositories.

.AUTHOR
The Establishment

.CREATED
16th February 2026

.MODIFIED
16th February 2026

.VERSION
1.0.0

.CONFIG-BASE
pwsh-app-config-BASE.json

#>

# Stop on errors
$ErrorActionPreference = "Stop"

# Define LOCAL script directory and paths
$script:localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Define LOCAL region Configuration
$script:ConfigPath = $script:localRoot
$script:DefaultFolder = $script:localRoot
$script:TempFolder = Join-Path $script:localRoot "temp"
$script:ReportFolder = Join-Path $script:localRoot "~REPORTS"
$script:DownloadFolder = Join-Path $script:localRoot "~DOWNLOADS"

# Create local directories if they don't exist
@($script:ConfigPath, $script:DefaultFolder, $script:TempFolder, $script:ReportFolder, $script:DownloadFolder) | ForEach-Object {
    if ($_ -and -not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# Define GLOBAL script directory and Files
$script:scriptDir = Split-Path -Parent $script:localRoot
$script:configDir = Join-Path $script:scriptDir "config"
$script:modulesDir = Join-Path $script:scriptDir "modules"
$script:logsDir = Join-Path $script:scriptDir "logs"
$script:scriptsDir = Join-Path $script:scriptDir "scripts"
$script:configFile = Join-Path $script:configDir "system-variables.xml"
$script:linksConfigFile = Join-Path $script:configDir "links.xml"
$script:avpnConfigFile = Join-Path $script:configDir "AVPN-devices.json"

# Create GLOBAL directories if they don't exist
@($script:scriptDir, $script:configDir, $script:modulesDir, $script:logsDir, $script:scriptsDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ==================== LOGGING FUNCTIONS ====================
# Write-AppLog, Write-ScriptLog -- now provided by PwShGUICore module
$script:coreModulePath = Join-Path $script:modulesDir 'PwShGUICore.psm1'
if (Test-Path $script:coreModulePath) {
    Import-Module $script:coreModulePath -Force
    Initialize-CorePaths -ScriptDir $script:scriptDir
} else {
    Write-AppLog -Message "PwShGUICore module not found at $($script:coreModulePath)" -Level Warning
}

# ==================== HELP FILE FUNCTIONS ====================
function Test-HelpFilesExist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HelpPath
    )

    if (-not (Test-Path $HelpPath)) {
        return $false
    }

    $helpFiles = @()
    $helpFiles += Get-ChildItem -Path $HelpPath -Filter "*help.xml" -ErrorAction SilentlyContinue
    $helpFiles += Get-ChildItem -Path $HelpPath -Filter "*help.zip" -ErrorAction SilentlyContinue
    $helpFiles += Get-ChildItem -Recurse -Path $HelpPath -Filter "*help.xml" -ErrorAction SilentlyContinue -Depth 2

    return ($helpFiles.Count -gt 0)
}

function Invoke-SavePowerShellHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [string[]]$UICultures = @("en-US", "en-AU")
    )

    try {
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }

        Write-AppLog "Starting Save-Help for cultures: $($UICultures -join ', ')" "Info"

        foreach ($culture in $UICultures) {
            Write-Verbose "Saving help files for culture: $culture"
            
            try {
                Save-Help -DestinationPath $DestinationPath -UICulture $culture -Force -ErrorAction Stop
                Write-AppLog "Successfully saved help files for culture: $culture" "Info"
                Write-Verbose "âœ“ Saved help for $culture"
            } catch {
                Write-AppLog "Error saving help for culture $($culture): $_" "Warning"
                Write-Verbose "âœ— Error saving help for $culture : $_"
            }
        }

        Write-AppLog "Save-Help operation completed" "Info"
        return $true
    } catch {
        Write-AppLog "Save-Help failed: $_" "Error"
        Write-Verbose "Error: $_"
        return $false
    }
}

function Invoke-UpdatePowerShellHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [string[]]$UICultures = @("en-US", "en-AU")
    )

    try {
        if (-not (Test-Path $SourcePath)) {
            Write-Verbose "Source path does not exist: $SourcePath"
            Write-AppLog "Update-Help failed: source path does not exist: $SourcePath" "Error"
            return $false
        }

        Write-AppLog "Starting Update-Help from source: $SourcePath for cultures: $($UICultures -join ', ')" "Info"

        foreach ($culture in $UICultures) {
            Write-Verbose "Updating help files for culture: $culture"
            
            try {
                Update-Help -SourcePath $SourcePath -UICulture $culture -Force -ErrorAction Stop
                Write-AppLog "Successfully updated help files for culture: $culture" "Info"
                Write-Verbose "âœ“ Updated help for $culture"
            } catch {
                Write-AppLog "Error updating help for culture $($culture): $_" "Warning"
                Write-Verbose "âœ— Error updating help for $culture : $_"
            }
        }

        Write-AppLog "Update-Help operation completed" "Info"
        return $true
    } catch {
        Write-AppLog "Update-Help failed: $_" "Error"
        Write-Verbose "Error: $_"
        return $false
    }
}

function Get-HelpFileInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HelpPath
    )

    $info = @{
        Path = $HelpPath
        FileCount = 0
        TotalSize = 0
        Cultures = @()
        LastModified = $null
    }

    if (Test-Path $HelpPath) {
        $files = Get-ChildItem -Path $HelpPath -Recurse -File -ErrorAction SilentlyContinue
        $info.FileCount = $files.Count
        $info.TotalSize = ($files | Measure-Object -Property Length -Sum).Sum

        if ($files.Count -gt 0) {
            $info.LastModified = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            
            # Detect cultures from directory structure
            $cultureDirs = Get-ChildItem -Path $HelpPath -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^[a-z]{2}-[A-Z]{2}$'
            $info.Cultures = @($cultureDirs | ForEach-Object { $_.Name })
        }
    }

    return $info
}

# ==================== GUI FUNCTIONS ====================
function Show-HelpFilesGUI {
    param(
        [string]$InitialPath = $script:DownloadFolder
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PowerShell Help Files Update Source (ReR)"
    $form.Size = New-Object System.Drawing.Size(700, 650)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "PowerShell Help Files Manager"
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(670, 24)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)

    # Help Path Section
    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = "Help Files Location:"
    $pathLabel.Location = New-Object System.Drawing.Point(12, 45)
    $pathLabel.Size = New-Object System.Drawing.Size(670, 18)
    $pathLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($pathLabel)

    $pathTextBox = New-Object System.Windows.Forms.TextBox
    $pathTextBox.Text = $InitialPath
    $pathTextBox.Location = New-Object System.Drawing.Point(12, 66)
    $pathTextBox.Size = New-Object System.Drawing.Size(590, 22)
    $form.Controls.Add($pathTextBox)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse..."
    $browseButton.Location = New-Object System.Drawing.Point(609, 66)
    $browseButton.Size = New-Object System.Drawing.Size(70, 22)
    $browseButton.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = "Select a folder for PowerShell help files"
        $folderDialog.SelectedPath = $pathTextBox.Text
        
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $pathTextBox.Text = $folderDialog.SelectedPath
            Update-HelpStatus
        }
    })
    $form.Controls.Add($browseButton)

    # Status Section
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Status:"
    $statusLabel.Location = New-Object System.Drawing.Point(12, 100)
    $statusLabel.Size = New-Object System.Drawing.Size(670, 18)
    $statusLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($statusLabel)

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Location = New-Object System.Drawing.Point(12, 121)
    $statusPanel.Size = New-Object System.Drawing.Size(670, 210)
    $statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $statusPanel.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($statusPanel)

    $statusTextBox = New-Object System.Windows.Forms.TextBox
    $statusTextBox.Multiline = $true
    $statusTextBox.ReadOnly = $true
    $statusTextBox.Location = New-Object System.Drawing.Point(0, 0)
    $statusTextBox.Size = New-Object System.Drawing.Size(668, 208)
    $statusTextBox.Font = New-Object System.Drawing.Font("Courier New", 9)
    $statusTextBox.BackColor = [System.Drawing.Color]::WhiteSmoke
    $statusPanel.Controls.Add($statusTextBox)

    # Culture Selection
    $culturesLabel = New-Object System.Windows.Forms.Label
    $culturesLabel.Text = "Help Cultures:"
    $culturesLabel.Location = New-Object System.Drawing.Point(12, 345)
    $culturesLabel.Size = New-Object System.Drawing.Size(670, 18)
    $culturesLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($culturesLabel)

    $enUsCheckbox = New-Object System.Windows.Forms.CheckBox
    $enUsCheckbox.Text = "English (United States) - en-US"
    $enUsCheckbox.Location = New-Object System.Drawing.Point(12, 366)
    $enUsCheckbox.Size = New-Object System.Drawing.Size(320, 20)
    $enUsCheckbox.Checked = $true
    $form.Controls.Add($enUsCheckbox)

    $enAuCheckbox = New-Object System.Windows.Forms.CheckBox
    $enAuCheckbox.Text = "English (Australia) - en-AU"
    $enAuCheckbox.Location = New-Object System.Drawing.Point(350, 366)
    $enAuCheckbox.Size = New-Object System.Drawing.Size(320, 20)
    $enAuCheckbox.Checked = $true
    $form.Controls.Add($enAuCheckbox)

    # Action Buttons
    $actionLabel = New-Object System.Windows.Forms.Label
    $actionLabel.Text = "Actions:"
    $actionLabel.Location = New-Object System.Drawing.Point(12, 400)
    $actionLabel.Size = New-Object System.Drawing.Size(670, 18)
    $actionLabel.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($actionLabel)

    $saveHelpButton = New-Object System.Windows.Forms.Button
    $saveHelpButton.Text = "Save-Help (Download)"
    $saveHelpButton.Location = New-Object System.Drawing.Point(12, 425)
    $saveHelpButton.Size = New-Object System.Drawing.Size(200, 35)
    $saveHelpButton.Font = New-Object System.Drawing.Font("Arial", 10)
    $saveHelpButton.BackColor = [System.Drawing.Color]::Orange
    $saveHelpButton.Add_Click({
        $cultures = @()
        if ($enUsCheckbox.Checked) { $cultures += "en-US" }
        if ($enAuCheckbox.Checked) { $cultures += "en-AU" }

        if ($cultures.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one culture.", "No Culture Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $statusTextBox.Text = "Saving help files...`r`nThis may take several minutes.`r`n`r`n"
        $form.Refresh()

        $result = Invoke-SavePowerShellHelp -DestinationPath $pathTextBox.Text -UICultures $cultures
        
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("Help files saved successfully!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [System.Windows.Forms.MessageBox]::Show("Error saving help files. Check the status above for details.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        
        Update-HelpStatus
    })
    $form.Controls.Add($saveHelpButton)

    $updateHelpButton = New-Object System.Windows.Forms.Button
    $updateHelpButton.Text = "Update-Help (Apply)"
    $updateHelpButton.Location = New-Object System.Drawing.Point(220, 425)
    $updateHelpButton.Size = New-Object System.Drawing.Size(200, 35)
    $updateHelpButton.Font = New-Object System.Drawing.Font("Arial", 10)
    $updateHelpButton.BackColor = [System.Drawing.Color]::LimeGreen
    $updateHelpButton.Enabled = $false
    $updateHelpButton.Add_Click({
        $cultures = @()
        if ($enUsCheckbox.Checked) { $cultures += "en-US" }
        if ($enAuCheckbox.Checked) { $cultures += "en-AU" }

        if ($cultures.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one culture.", "No Culture Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $statusTextBox.Text = "Updating help files...`r`nThis may take several minutes.`r`n`r`n"
        $form.Refresh()

        $result = Invoke-UpdatePowerShellHelp -SourcePath $pathTextBox.Text -UICultures $cultures
        
        if ($result) {
            [System.Windows.Forms.MessageBox]::Show("Help files updated successfully!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [System.Windows.Forms.MessageBox]::Show("Error updating help files. Check the status above for details.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        
        Update-HelpStatus
    })
    $form.Controls.Add($updateHelpButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(428, 425)
    $closeButton.Size = New-Object System.Drawing.Size(200, 35)
    $closeButton.Font = New-Object System.Drawing.Font("Arial", 10)
    $closeButton.Add_Click({ $form.Close() })
    $form.Controls.Add($closeButton)

    # Progress Bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(12, 475)
    $progressBar.Size = New-Object System.Drawing.Size(670, 25)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.Visible = $false
    $form.Controls.Add($progressBar)

    # Info Label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Select a location to save/update PowerShell help files. Help files are required for offline environments."
    $infoLabel.Location = New-Object System.Drawing.Point(12, 515)
    $infoLabel.Size = New-Object System.Drawing.Size(670, 40)
    $infoLabel.AutoSize = $true
    $infoLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $form.Controls.Add($infoLabel)

    # Update help status function
    function Update-HelpStatus {
        $path = $pathTextBox.Text
        $helpExists = Test-HelpFilesExist -HelpPath $path

        $statusTextBox.Clear()

        if ($helpExists) {
            $info = Get-HelpFileInfo -HelpPath $path
            $statusTextBox.Text = "[OK] Help files detected in this folder`r`n`r`n"
            $statusTextBox.AppendText("Files Found: $($info.FileCount)`r`n")
            $statusTextBox.AppendText("Total Size: $(if ($info.TotalSize -gt 1MB) { "$([Math]::Round($info.TotalSize / 1MB, 2)) MB" } else { "$([Math]::Round($info.TotalSize / 1KB, 2)) KB" })`r`n")
            
            if ($info.LastModified) {
                $statusTextBox.AppendText("Last Modified: $($info.LastModified.ToString('yyyy-MM-dd HH:mm:ss'))`r`n")
            }

            if ($info.Cultures.Count -gt 0) {
                $statusTextBox.AppendText("Detected Cultures: $($info.Cultures -join ', ')`r`n")
            }

            $statusTextBox.AppendText("`r`nRecommendation:`r`nClick 'Update-Help (Apply)' to apply these help files to your local system.")
            $updateHelpButton.Enabled = $true
            $saveHelpButton.Enabled = $true
        } else {
            $statusTextBox.Text = "[!] No help files detected in this folder`r`n`r`n"
            $statusTextBox.AppendText("Recommendation:`r`nClick 'Save-Help (Download)' to download the latest PowerShell help files to this location.`r`n`r`n")
            $statusTextBox.AppendText("This process:`r`n")
            $statusTextBox.AppendText("1. Requires an internet connection`r`n")
            $statusTextBox.AppendText("2. May take several minutes`r`n")
            $statusTextBox.AppendText("3. Downloads help for the selected cultures (en-US and/or en-AU)`r`n")
            $statusTextBox.AppendText("4. Stores files in the specified location`r`n")
            $updateHelpButton.Enabled = $false
            $saveHelpButton.Enabled = $true
        }
    }

    # Initial status update
    Update-HelpStatus

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# ==================== EXPORTED FUNCTIONS ====================

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Show-HelpFilesGUI',
    'Invoke-SavePowerShellHelp',
    'Invoke-UpdatePowerShellHelp',
    'Test-HelpFilesExist',
    'Get-HelpFileInfo',
    'Write-AppLog',
    'Write-ScriptLog'
)

















