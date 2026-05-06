# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Read config file
$configPath = "$PSScriptRoot\config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found at $configPath"
    exit
}

try {
    $config = Get-Content $configPath | ConvertFrom-Json 
    if ($null -eq $config -or $null -eq $config.folderPath) {
        Write-Error "Config file is invalid or missing 'folderPath' property"
        exit
    }
    $folderPath = $config.folderPath | Out-GridView -OutputMode Single
    if ($null -eq $folderPath) {
        Write-Error "No folder selected"
        exit
    }
} catch {
    Write-Error "Failed to read or parse config file: $_"
    exit
} 

# Create a hidden form to keep the application running
$form = New-Object System.Windows.Forms.Form
$form.Text = "Quick App"
$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$form.ShowInTaskbar = $false

# Create NotifyIcon
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Visible = $true
$notifyIcon.Text = "Quick App"

# Create context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Build tree from folder
function Add-FolderItems ($path, $parentItem) {
    try {
        $items = @(Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($null -eq $items -or $items.Count -eq 0) {
            return
        }
        
        $fileTypes = $items | Where-Object { $null -ne $_ -and $_.PSIsContainer -eq $false } | Group-Object Extension | Sort-Object Name
        
        foreach ($group in $fileTypes) {
            if ($null -eq $group) { continue }
            
            $typeItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $typeItem.Text = "$($group.Name) ($($group.Count))"
            
            foreach ($file in ($group.Group | Sort-Object Name)) {
                if ($null -eq $file) { continue }
                
                $fileItem = New-Object System.Windows.Forms.ToolStripMenuItem
                $fileItem.Text = $file.Name
                $fileItem.Tag = $file.FullName
                
                if ($file.Extension -eq ".ps1") {
                    $file_FullName = $file.FullName
                    $fileItem.Add_Click({
                        try {
                            & pwsh -File $file_FullName
                        } catch {
                            [System.Windows.Forms.MessageBox]::Show("Error running script: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                        }
                    })
                }
                $typeItem.DropDownItems.Add($fileItem) | Out-Null
            }
            $parentItem.DropDownItems.Add($typeItem) | Out-Null
        }
    
        $folders = $items | Where-Object { $null -ne $_ -and $_.PSIsContainer -eq $true } | Sort-Object Name
        foreach ($folder in $folders) {
            if ($null -eq $folder) { continue }
            
            $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $folderItem.Text = $folder.Name
            Add-FolderItems $folder.FullName $folderItem
            $parentItem.DropDownItems.Add($folderItem) | Out-Null
        }
    } catch {
        Write-Warning "Error processing folder '$path': $_"
    }
}

Add-FolderItems $folderPath $contextMenu

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({ $notifyIcon.Visible = $false; $form.Close(); [System.Windows.Forms.Application]::Exit() })
$contextMenu.Items.Add($exitItem) | Out-Null

$notifyIcon.ContextMenuStrip = $contextMenu

# Add click handler to show menu
$notifyIcon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $contextMenu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

$form.Add_Load({ $form.Hide() })
[System.Windows.Forms.Application]::Run($form)













<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




