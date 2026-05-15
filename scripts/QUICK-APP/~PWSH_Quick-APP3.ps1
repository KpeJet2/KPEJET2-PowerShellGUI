# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# PowerShell Quick App Script Launcher
# This script lists and executes PowerShell scripts from user-selected folders

# Define LOCAL region Configuration
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
        Write-Information "Config file created at: $ConfigPath" -InformationAction Continue
    }
    
    # Load and return configuration
    return Get-Content $ConfigPath | ConvertFrom-Json
}

# Save configuration to file
function Save-Config {
    param([PSCustomObject]$Config)
    try {
        $Config | ConvertTo-Json | Set-Content $ConfigPath -ErrorAction Stop
        Write-Information "Configuration saved successfully" -InformationAction Continue
    }
    catch {
        Write-Warning "Error saving config: $_"
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
#    $ConfigData | Out-GridView -Title "Current Configuration"
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
function Write-QuickLog {
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
        Write-Warning "Error writing to log: $_"
    }
}

# Log system information at startup
function Write-SystemInfo {
    param([string]$LogPath)
    
    try {
        # Get FQDN
        $fqdn = [System.Net.Dns]::GetHostByName("").HostName
        
        # Get IP Address
        $ipAddress = @([System.Net.Dns]::GetHostByName($env:COMPUTERNAME).AddressList.IPAddressToString) -join ", "
        
        # Get MAC Address
        $macAddresses = @()
        try {
            $networkAdapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
            foreach ($adapter in $networkAdapters) {
                if ($adapter.MACAddress) {
                    $macAddresses += $adapter.MACAddress
                }
            }
        }
        catch {
            $macAddresses = @("Unable to retrieve MAC addresses")
        }
        $macAddressList = $macAddresses -join ", "
        
        # Get current user
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        
        # Get OS version
        $osVersion = [System.Environment]::OSVersion.VersionString
        
        # Get DNS servers
        $dnsServers = @()
        try {
            $networkAdapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
            foreach ($adapter in $networkAdapters) {
                if ($adapter.DNSServerSearchOrder) {
                    $dnsServers += $adapter.DNSServerSearchOrder
                }
            }
        }
        catch {
            $dnsServers = @("Unable to retrieve DNS servers")
        }
        $dnsServerList = $dnsServers -join ", "
        
        # Get Windows Installation Date
        $installDate = "Unknown"
        try {
            # Try using registry first (more reliable)
            $installDateReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "InstallDate" -ErrorAction Stop
            $installDate = ([DateTime]::FromFileTime([Int64]::Parse($installDateReg.InstallDate) * 10000000)).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            try {
                # Fallback to WMI
                $wmiOS = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                if ($wmiOS.InstallDate) {
                    $installDate = $wmiOS.InstallDate.ToString("yyyy-MM-dd HH:mm:ss")
                }
            }
            catch {
                $installDate = "Unable to retrieve installation date"
            }
        }
        
        # Get Last Reboot Time and calculate uptime
        $lastReboot = "Unknown"
        $uptime = "Unknown"
        try {
            # Use Get-CimInstance which handles datetime better than Get-WmiObject
            $wmiOS = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $lastRebootTime = $wmiOS.LastBootUpTime
            
            if ($lastRebootTime) {
                $lastReboot = $lastRebootTime.ToString("yyyy-MM-dd HH:mm:ss")
                
                $uptimeSpan = (Get-Date) - $lastRebootTime
                $uptime = "{0} days, {1} hours, {2} minutes, {3} seconds" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes, $uptimeSpan.Seconds
            }
        }
        catch {
            try {
                # Fallback to registry method for uptime using boot time
                $lastBootTime = Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -ErrorAction Stop
                $uptime = "Unable to retrieve from registry"
            }
            catch {
                $uptime = "Unable to retrieve uptime"
            }
        }
        
        # Write system info to log
        Write-QuickLog "=== SYSTEM INFORMATION ===" -LogPath $LogPath
        Write-QuickLog "FQDN: $fqdn" -LogPath $LogPath
        Write-QuickLog "IP Address: $ipAddress" -LogPath $LogPath
        Write-QuickLog "MAC Address: $macAddressList" -LogPath $LogPath
        Write-QuickLog "Username: $currentUser" -LogPath $LogPath
        Write-QuickLog "OS Version: $osVersion" -LogPath $LogPath
        Write-QuickLog "Installation Date: $installDate" -LogPath $LogPath
        Write-QuickLog "Last Reboot: $lastReboot" -LogPath $LogPath
        Write-QuickLog "Uptime: $uptime" -LogPath $LogPath
        Write-QuickLog "DNS Servers: $dnsServerList" -LogPath $LogPath
        Write-QuickLog "=== END SYSTEM INFORMATION ===" -LogPath $LogPath
        
        # Display to console as well
        Write-Information "=== SYSTEM INFORMATION ===" -InformationAction Continue
        Write-Information "FQDN: $fqdn" -InformationAction Continue
        Write-Information "IP Address: $ipAddress" -InformationAction Continue
        Write-Information "MAC Address: $macAddressList" -InformationAction Continue
        Write-Information "Username: $currentUser" -InformationAction Continue
        Write-Information "OS Version: $osVersion" -InformationAction Continue
        Write-Information "Installation Date: $installDate" -InformationAction Continue
        Write-Information "Last Reboot: $lastReboot" -InformationAction Continue
        Write-Information "Uptime: $uptime" -InformationAction Continue
        Write-Information "DNS Servers: $dnsServerList" -InformationAction Continue
        Write-Information "=== END SYSTEM INFORMATION ===" -InformationAction Continue
    }
    catch {
        Write-QuickLog "Error gathering system information: $_" -LogPath $LogPath -Level "ERROR"
    }
}

#endregion

#region Main Menu
# Display main menu and get user choice
function Show-MainMenu {
    Write-Information "" -InformationAction Continue
    Write-Information "========================================" -InformationAction Continue
    Write-Information "  PowerShell Quick App Launcher" -InformationAction Continue
    Write-Information "========================================" -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information "Select an option:" -InformationAction Continue
    Write-Information "  1) TEST         - Run TEST.ps1" -InformationAction Continue
    Write-Information "  2) REPAIR       - Run REPAIR.ps1" -InformationAction Continue
    Write-Information "  3) PWSH-SETUP   - Run PWSH-SETUP.ps1" -InformationAction Continue
    Write-Information "  4) INSTALLS     - Run INSTALLS.ps1" -InformationAction Continue
    Write-Information "  5) SCRIPTS      - Run Script Selection Tool [default]" -InformationAction Continue
    Write-Information "  Q) QUIT         - Exit application" -InformationAction Continue
    Write-Information "" -InformationAction Continue
    
    $choice = Read-Host "Enter choice (1-5 or Q)"
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = '5'
    }
    
    return $choice.ToUpper()
}

# Execute a specific script file
function Invoke-ScriptFile {
    param(
        [string]$ScriptPath,
        [string]$ScriptName,
        [string]$LogPath
    )
    
    if (-not (Test-Path $ScriptPath)) {
        Write-Warning "Error: Script file not found: $ScriptPath"
        Write-QuickLog "Error: Script file not found: $ScriptPath" -LogPath $LogPath -Level "ERROR"
        return
    }
    
    try {
        Write-Information "Executing: $ScriptName" -InformationAction Continue
        Write-QuickLog "Executing: $ScriptName ($ScriptPath)" -LogPath $LogPath
        
        # Execute script with command logging
        $output = & $ScriptPath 2>&1
        
        Write-Information "OK Completed: $ScriptName" -InformationAction Continue
        Write-QuickLog "OK Completed: $ScriptName" -LogPath $LogPath
        
        # Log script output
        if ($output) {
            $output | ForEach-Object {
                Write-QuickLog "  OUTPUT: $_" -LogPath $LogPath
            }
        }
    }
    catch {
        Write-Warning "FAIL Error executing $ScriptName`: $_"
        Write-QuickLog "FAIL Error executing $ScriptName`: $_" -LogPath $LogPath -Level "ERROR"
    }
}

# Handle menu option selection
function Invoke-MenuOption {
    param(
        [string]$Choice,
        [string]$LogPath,
        [PSCustomObject]$Config
    )
    
    switch ($Choice) {
        '1' {
            Write-QuickLog "User selected: TEST" -LogPath $LogPath
            $scriptPath = Join-Path $PSScriptRoot "TEST.ps1"
            Invoke-ScriptFile $scriptPath "TEST" $LogPath
        }
        '2' {
            Write-QuickLog "User selected: REPAIR" -LogPath $LogPath
            $scriptPath = Join-Path $PSScriptRoot "REPAIR.ps1"
            Invoke-ScriptFile $scriptPath "REPAIR" $LogPath
        }
        '3' {
            Write-QuickLog "User selected: PWSH-SETUP" -LogPath $LogPath
            $scriptPath = Join-Path $PSScriptRoot "PWSH-SETUP.ps1"
            Invoke-ScriptFile $scriptPath "PWSH-SETUP" $LogPath
        }
        '4' {
            Write-QuickLog "User selected: INSTALLS" -LogPath $LogPath
            $scriptPath = Join-Path $PSScriptRoot "INSTALLS.ps1"
            Invoke-ScriptFile $scriptPath "INSTALLS" $LogPath
        }
        '5' {
            Write-QuickLog "User selected: SCRIPTS (Script Selection Tool)" -LogPath $LogPath
            Invoke-ScriptsMenu $Config
        }
        'Q' {
            Write-QuickLog "User selected: QUIT" -LogPath $LogPath
            return $false
        }
        default {
            Write-Warning "Invalid choice"
            Write-QuickLog "Invalid menu choice: $Choice" -LogPath $LogPath -Level "WARNING"
        }
    }
    
    return $true
}

#endregion

#region Configuration
# Prompt user to select additional folders
function Get-FolderSelection {
    param([string[]]$CurrentFolders)
    
    $folders = $CurrentFolders | Sort-Object -Unique
    
    do {
        Write-Information "=== Folder Selection ===" -InformationAction Continue
        Write-Information "Current folders:" -InformationAction Continue
        $folders | ForEach-Object { Write-Information "  - $_" -InformationAction Continue }
        Write-Information "Options: (A)dd folder, (R)emove folder, (Q)uit [default: Q]" -InformationAction Continue
        
        $choice = Read-Host "Enter choice"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = 'Q'
        }
        
        switch ($choice.ToUpper()) {
            'A' {
                $newFolder = Read-Host "Enter folder path"
                if ([string]::IsNullOrWhiteSpace($newFolder)) {
                    Write-Warning "Invalid path"
                }
                elseif (Test-Path $newFolder) {
                    $folders += $newFolder
                    Write-Information "Folder added" -InformationAction Continue
                }
                else {
                    Write-Warning "Folder does not exist"
                }
            }
            'R' {
                $folders | ForEach-Object { Write-Information "$($folders.IndexOf($_) + 1). $_" -InformationAction Continue }
                $index = Read-Host "Enter number to remove" | ForEach-Object { [int]$_ - 1 }
                if ($index -ge 0 -and $index -lt $folders.Count) {
                    $folders = $folders | Where-Object { $_ -ne $folders[$index] }
                    Write-Information "Folder removed" -InformationAction Continue
                }
            }
            'Q' {
                break
            }
            default {
                Write-Warning "Invalid choice"
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
                Write-Warning "Path not found: $folder"
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
            Write-Warning "Error reading folder '$folder': $_"
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
        Write-Warning "No scripts found in selected folders"
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
        Write-Warning "No scripts selected"
        Write-QuickLog "No scripts selected" -LogPath $LogPath -Level "WARNING"
        return
    }
    
    Write-Information "=== Executing Scripts ===" -InformationAction Continue
    Write-QuickLog "=== Script Execution Started ===" -LogPath $LogPath
    
    foreach ($script in $SelectedScripts) {
        try {
            Write-Information "Executing: $($script.Name)" -InformationAction Continue
            Write-QuickLog "Executing script: $($script.FullPath)" -LogPath $LogPath
            
            # Execute script with command logging
            $output = & $script.FullPath 2>&1
            
            Write-Information "OK Completed: $($script.Name)" -InformationAction Continue
            Write-QuickLog "OK Completed: $($script.Name)" -LogPath $LogPath
            
            # Log script output
            if ($output) {
                $output | ForEach-Object {
                    Write-QuickLog "  OUTPUT: $_" -LogPath $LogPath
                }
            }
        }
        catch {
            Write-Warning "FAIL Error executing $($script.Name): $_"
            Write-QuickLog "FAIL Error executing $($script.Name): $_" -LogPath $LogPath -Level "ERROR"
        }
    }
    
    Write-Information "=== Execution Complete ===" -InformationAction Continue
    Write-QuickLog "=== Script Execution Completed ===" -LogPath $LogPath
}

#endregion

#region Main
# Scripts menu - the original main logic wrapped
function Invoke-ScriptsMenu {
    param([PSCustomObject]$Config)
    
    try {
        # Log session start
        Write-QuickLog "=== Script Selection Tool Started ===" -LogPath $Config.LogPath
        
        # Display current settings
        Write-Information "Displaying current configuration..." -InformationAction Continue
        Write-QuickLog "Displaying configuration and folders" -LogPath $Config.LogPath
        Show-ConfigGrid $Config
        
        # Allow folder selection
        $folders = Get-FolderSelection $Config.SelectedFolders
        Write-QuickLog "Folders selected: $($folders -join '; ')" -LogPath $Config.LogPath
        
        # Convert config to hashtable, update, and save
        $configHash = @{
            SelectedFolders = $folders
            LogPath = $Config.LogPath
            ExecutionMode = $Config.ExecutionMode
        }
        $configHash | ConvertTo-Json | Set-Content $ConfigPath -ErrorAction Stop
        Write-Information "Folder configuration saved successfully" -InformationAction Continue
        Write-QuickLog "Folder configuration saved successfully" -LogPath $Config.LogPath
        
        # Discover scripts
        $scripts = Get-ScriptsFromFolders $folders
        Write-QuickLog "Discovered $($scripts.Count) scripts" -LogPath $Config.LogPath
        
        # Select and execute scripts
        $selected = Select-Scripts $scripts
        Write-QuickLog "User selected $($selected.Count) scripts for execution" -LogPath $Config.LogPath
        Invoke-SelectedScripts $selected -LogPath $Config.LogPath
    }
    catch {
        Write-Warning "Fatal error: $_"
        Write-QuickLog "Fatal error: $_" -LogPath $Config.LogPath -Level "ERROR"
    }
}

#endregion

# Script loop - main application entry point
$config = Initialize-Config
Write-QuickLog "=== PowerShell Quick App Started ===" -LogPath $config.LogPath

# Write system information at startup
Write-SystemInfo $config.LogPath

$continue = $true
while ($continue) {
    $menuChoice = Show-MainMenu
    $continue = Invoke-MenuOption $menuChoice $config.LogPath $config
    
    # Reload config in case it was modified
    $config = Initialize-Config
}

Write-Information "Thank you for using PowerShell Quick App Launcher!" -InformationAction Continue
Write-QuickLog "=== PowerShell Quick App Ended ===" -LogPath $config.LogPath
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



