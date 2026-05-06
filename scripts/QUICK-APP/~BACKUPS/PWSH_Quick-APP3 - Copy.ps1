# VersionTag: 2602.a.11
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.10
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.9
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.8
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionTag: 2602.a.7
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# PowerShell Quick App Script Launcher
# This script lists and executes PowerShell scripts from user-selected folders

#region Configuration
$ConfigPath = "$PSScriptRoot\config.json"
$DefaultFolder = "C:\Temp\QUICK-APP\FOLDER-ROOT"

# Initialize or load configuration file
function Initialize-Config {
    if (-not (Test-Path $ConfigPath)) {
        # Create default configuration if not exists
        $config = @{
            SelectedFolders = @($DefaultFolder)
            LogPath = "$PSScriptRoot\logs"
            ExecutionMode = "Sequential"
        }
        $config | ConvertTo-Json | Set-Content $ConfigPath -ErrorAction Stop
        Write-Host "Config file created at: $ConfigPath"
    }
    
    # Load and return configuration
    return Get-Content $ConfigPath | ConvertFrom-Json
}

# Save configuration to file
function Save-Config {
    param([PSCustomObject]$Config)
    try {
        $Config | ConvertTo-Json | Set-Content $ConfigPath -ErrorAction Stop
        Write-Host "Configuration saved successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "Error saving config: $_" -ForegroundColor Red
    }
}

# Display configuration in grid format
function Show-ConfigGrid {
    param([PSCustomObject]$Config)
    $ConfigData = @()
    $Config.PSObject.Properties | ForEach-Object {
        $ConfigData += [PSCustomObject]@{
            Setting = $_.Name
            Value = if ($_.Value -is [array]) { $_.Value -join "; " } else { $_.Value }
        }
    }
    $ConfigData | Out-GridView -Title "Current Configuration"
}

#endregion

#region Logging
# Create or get log file path based on hostname and date
function Get-LogFilePath {
    param([string]$LogPath)
    
    # Ensure log path exists
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    
    # Create log filename: HOSTNAME_yyyymmdd.log
    $hostname = [System.Net.Dns]::GetHostName()
    $date = Get-Date -Format "yyyyMMdd"
    $logFileName = "{0}_{1}.log" -f $hostname, $date
    
    return Join-Path $LogPath $logFileName
}

# Write message to log file and console
function Write-Log {
    param(
        [string]$Message,
        [string]$LogPath,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    try {
        $logFilePath = Get-LogFilePath $LogPath
        Add-Content -Path $logFilePath -Value $logMessage -ErrorAction Stop
    }
    catch {
        Write-Host "Error writing to log: $_" -ForegroundColor Red
    }
}

#endregion

#region Configuration
# Prompt user to select additional folders
function Get-FolderSelection {
    param([string[]]$CurrentFolders)
    
    $folders = $CurrentFolders | Sort-Object -Unique
    
    do {
        Write-Host "`n=== Folder Selection ===" -ForegroundColor Cyan
        Write-Host "Current folders:" -ForegroundColor Yellow
        $folders | ForEach-Object { Write-Host "  - $_" }
        Write-Host "`nOptions: (A)dd folder, (R)emove folder, (Q)uit [default: Q]"
        
        $choice = Read-Host "Enter choice"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = 'Q'
        }
        
        switch ($choice.ToUpper()) {
            'A' {
                $newFolder = Read-Host "Enter folder path"
                if ([string]::IsNullOrWhiteSpace($newFolder)) {
                    Write-Host "Invalid path" -ForegroundColor Red
                }
                elseif (Test-Path $newFolder) {
                    $folders += $newFolder
                    Write-Host "Folder added" -ForegroundColor Green
                }
                else {
                    Write-Host "Folder does not exist" -ForegroundColor Red
                }
            }
            'R' {
                $folders | ForEach-Object { Write-Host "$($folders.IndexOf($_) + 1). $_" }
                $index = Read-Host "Enter number to remove" | ForEach-Object { [int]$_ - 1 }
                if ($index -ge 0 -and $index -lt $folders.Count) {
                    $folders = $folders | Where-Object { $_ -ne $folders[$index] }
                    Write-Host "Folder removed" -ForegroundColor Green
                }
            }
            'Q' {
                break
            }
            default {
                Write-Host "Invalid choice" -ForegroundColor Red
            }
        }
    }until (
        $choice.ToUpper() -eq 'Q')
    return $folders
}

#endregion

#region Script Discovery
# Get all PowerShell scripts from selected folders
function Get-ScriptsFromFolders {
    param([string[]]$Folders)
    
    $scripts = @()
    
    foreach ($folder in $Folders) {
        try {
            if (-not (Test-Path $folder)) {
                Write-Host "Path not found: $folder" -ForegroundColor Yellow
                continue
            }
            
            # Retrieve all .ps1 files from folder
            $folderScripts = Get-ChildItem -Path $folder -Filter "*.ps1" -ErrorAction Stop
            $folderScripts | ForEach-Object {
                $scripts += [PSCustomObject]@{
                    Name = $_.Name
                    FullPath = $_.FullName
                    Folder = $folder
                    Selected = $false
                }
            }
        }
        catch {
            Write-Host "Error reading folder '$folder': $_" -ForegroundColor Red
        }
    }
    
    return $scripts
}

#endregion

#region Script Selection & Execution
# Display scripts in grid and allow user selection
function Select-Scripts {
    param([PSCustomObject[]]$Scripts)
    
    if ($Scripts.Count -eq 0) {
        Write-Host "No scripts found in selected folders" -ForegroundColor Yellow
        return @()
    }
    
    # Display grid for selection
    $selected = $Scripts | Out-GridView -Title "Select scripts to execute (Ctrl+Click for multiple)" -OutputMode Multiple
    
    return $selected
}

# Execute selected scripts in sequence
function Invoke-SelectedScripts {
    param(
        [PSCustomObject[]]$SelectedScripts,
        [string]$LogPath
    )
    
    if ($SelectedScripts.Count -eq 0) {
        Write-Host "No scripts selected" -ForegroundColor Yellow
        Write-Log "No scripts selected" -LogPath $LogPath -Level "WARNING"
        return
    }
    
    Write-Host "`n=== Executing Scripts ===" -ForegroundColor Cyan
    Write-Log "=== Script Execution Started ===" -LogPath $LogPath
    
    foreach ($script in $SelectedScripts) {
        try {
            Write-Host "`nExecuting: $($script.Name)" -ForegroundColor Yellow
            Write-Log "Executing script: $($script.FullPath)" -LogPath $LogPath
            
            # Execute script with command logging
            $output = & $script.FullPath 2>&1
            
            Write-Host "✓ Completed: $($script.Name)" -ForegroundColor Green
            Write-Log "✓ Completed: $($script.Name)" -LogPath $LogPath
            
            # Log script output
            if ($output) {
                $output | ForEach-Object {
                    Write-Log "  OUTPUT: $_" -LogPath $LogPath
                }
            }
        }
        catch {
            Write-Host "✗ Error executing $($script.Name): $_" -ForegroundColor Red
            Write-Log "✗ Error executing $($script.Name): $_" -LogPath $LogPath -Level "ERROR"
        }
    }
    
    Write-Host "`n=== Execution Complete ===" -ForegroundColor Cyan
    Write-Log "=== Script Execution Completed ===" -LogPath $LogPath
}

#endregion

#region Main
# Main script logic
function Main {
    try {
        # Initialize configuration
        $config = Initialize-Config
        
        # Log session start
        Write-Log "=== PowerShell Quick App Session Started ===" -LogPath $config.LogPath
        
        # Display current settings
        Write-Host "Displaying current configuration..." -ForegroundColor Cyan
        Write-Log "Displaying configuration and folders" -LogPath $config.LogPath
        Show-ConfigGrid $config
        
        # Allow folder selection
        $folders = Get-FolderSelection $config.SelectedFolders
        Write-Log "Folders selected: $($folders -join '; ')" -LogPath $config.LogPath
        
        # Convert config to hashtable, update, and save
        $configHash = @{
            SelectedFolders = $folders
            LogPath = $config.LogPath
            ExecutionMode = $config.ExecutionMode
        }
        $configHash | ConvertTo-Json | Set-Content $ConfigPath -ErrorAction Stop
        Write-Host "Folder configuration saved successfully" -ForegroundColor Green
        Write-Log "Folder configuration saved successfully" -LogPath $config.LogPath
        
        # Discover scripts
        $scripts = Get-ScriptsFromFolders $folders
        Write-Log "Discovered $($scripts.Count) scripts" -LogPath $config.LogPath
        
        # Select and execute scripts
        $selected = Select-Scripts $scripts
        Write-Log "User selected $($selected.Count) scripts for execution" -LogPath $config.LogPath
        Invoke-SelectedScripts $selected -LogPath $config.LogPath
    }
    catch {
        Write-Host "Fatal error: $_" -ForegroundColor Red
        Write-Log "Fatal error: $_" -LogPath $config.LogPath -Level "ERROR"
    }
}

#endregion

# Script loop for running main logic multiple times
$config = Initialize-Config
Write-Log "=== PowerShell Quick App Started ===" -LogPath $config.LogPath

$continue = $true
while ($continue) {
    Main
    
    Write-Host "`n=== Main Script Complete ===" -ForegroundColor Cyan
    Write-Host "Options: (R)un again, (Q)uit [default: Q]"
    $userChoice = Read-Host "Enter choice"
    if ([string]::IsNullOrWhiteSpace($userChoice)) {
        $userChoice = 'Q'
    }
    
    switch ($userChoice.ToUpper()) {
        'R' {
            Write-Host "`nRestarting main script logic...`n" -ForegroundColor Yellow
            Write-Log "User chose to run again" -LogPath $config.LogPath
        }
        'Q' {
            Write-Host "Exiting script..." -ForegroundColor Yellow
            Write-Log "=== PowerShell Quick App Ended ===" -LogPath $config.LogPath
            $continue = $false
        }
        default {
            Write-Host "Invalid choice. Exiting..." -ForegroundColor Red
            Write-Log "Invalid choice selected. Exiting..." -LogPath $config.LogPath -Level "WARNING"
            $continue = $false
        }
    }
}

Read-Host "Press Enter to exit"













<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>



