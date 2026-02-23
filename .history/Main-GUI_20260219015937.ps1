# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
# VersionTag: 2602.a.7
#Requires -Version 5.1
<#
.SYNOPSIS
PowerShell GUI Application with Admin Elevation Support

.DESCRIPTION
A Windows Forms GUI application that provides a menu-driven interface to launch
various PowerShell scripts with optional admin elevation, config file management,
and comprehensive logging.


.NOTES


.LINK


.INPUTS


.OUTPUTS


.FUNCTIONALITY
For system administrators and IT professionals to easily access and run common maintenance scripts,

.AUTHOR
The Establishment

.VERSION
1.0.0

.CREATED
24th January 2026

.MODIFIED
16th February 2026

.VERSION HISTORY
1.0.0 - Initial version

.CONFIGURATION BASE
pwsh-app-config-BASE.json

#>

param(
    [ValidateSet('quik_jnr', 'slow_snr')]
    [string]$StartupMode = 'slow_snr'
)

# Stop on errors
$ErrorActionPreference = "Stop"

# ==================== PERFORMANCE OPTIMIZATION: ASSEMBLY LOADING ====================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web

# ==================== PERFORMANCE OPTIMIZATION: CACHING ====================
# XML Document Cache
$script:_XmlCache = @{
    ConfigFile = $null
    LinksConfig = $null
    LastConfigLoad = $null
    LastLinksLoad = $null
}

# Log Stream for buffered writes
$script:_LogBuffer = @()
$script:_LogBufferSize = 10  # Flush every N entries
$script:_LogFilePath = $null

# Define LOCAL script directory and paths
$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Request-LocalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue,

        [int]$TimeoutSeconds = 9
    )

    $result = $DefaultValue
    $timedOut = $false
    $remaining = $TimeoutSeconds

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Local config: $Label"
    $form.Size = New-Object System.Drawing.Size(520, 180)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Topmost = $true

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.Text = "Enter value for $Label (blank uses default):"
    $promptLabel.Location = New-Object System.Drawing.Point(12, 12)
    $promptLabel.Size = New-Object System.Drawing.Size(490, 18)
    $form.Controls.Add($promptLabel)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $DefaultValue
    $textBox.Location = New-Object System.Drawing.Point(12, 36)
    $textBox.Size = New-Object System.Drawing.Size(490, 20)
    $form.Controls.Add($textBox)

    $countdownLabel = New-Object System.Windows.Forms.Label
    $countdownLabel.Text = "Auto-continue in $remaining s"
    $countdownLabel.Location = New-Object System.Drawing.Point(12, 64)
    $countdownLabel.Size = New-Object System.Drawing.Size(490, 18)
    $form.Controls.Add($countdownLabel)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(346, 100)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Use Default"
    $cancelButton.Location = New-Object System.Drawing.Point(426, 100)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $remaining--
        if ($remaining -le 0) {
            $timedOut = $true
            $timer.Stop()
            $form.Close()
        } else {
            $countdownLabel.Text = "Auto-continue in $remaining s"
        }
    })

    $form.Add_Shown({ $timer.Start() })
    $dialogResult = $form.ShowDialog()
    $timer.Stop()

    if (-not $timedOut -and $dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $result = if ([string]::IsNullOrWhiteSpace($textBox.Text)) { $DefaultValue } else { $textBox.Text }
    }

    return $result
}

function Request-LocalPathsUnified {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Defaults,

        [int]$TimeoutSeconds = 15
    )

    $result = @{}
    $timedOut = $false
    $remaining = $TimeoutSeconds

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Local configuration paths"
    $form.Size = New-Object System.Drawing.Size(860, 340)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Topmost = $true

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Set local folders (blank keeps default)."
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(820, 20)
    $form.Controls.Add($titleLabel) | Out-Null

    $fieldOrder = @('ConfigPath', 'DefaultFolder', 'TempFolder', 'ReportFolder', 'DownloadFolder')
    $textBoxes = @{}
    $y = 44

    foreach ($fieldName in $fieldOrder) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $fieldName
        $label.Location = New-Object System.Drawing.Point(12, $y)
        $label.Size = New-Object System.Drawing.Size(120, 22)
        $form.Controls.Add($label) | Out-Null

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Text = [string]$Defaults[$fieldName]
        $textBox.Location = New-Object System.Drawing.Point(138, $y)
        $textBox.Size = New-Object System.Drawing.Size(610, 22)
        $form.Controls.Add($textBox) | Out-Null
        $textBoxes[$fieldName] = $textBox

        $browseButton = New-Object System.Windows.Forms.Button
        $browseButton.Text = "Browse..."
        $browseButton.Location = New-Object System.Drawing.Point(756, $y - 1)
        $browseButton.Size = New-Object System.Drawing.Size(84, 24)
        $fieldNameCopy = $fieldName
        $textBoxCopy = $textBox
        $defaultValueCopy = [string]$Defaults[$fieldName]
        $browseButton.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Select folder for $fieldNameCopy"
            $dialog.SelectedPath = if ([string]::IsNullOrWhiteSpace($textBoxCopy.Text)) { $defaultValueCopy } else { $textBoxCopy.Text }
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $textBoxCopy.Text = $dialog.SelectedPath
            }
        }.GetNewClosure())
        $form.Controls.Add($browseButton) | Out-Null

        $y += 42
    }

    $countdownLabel = New-Object System.Windows.Forms.Label
    $countdownLabel.Text = "Auto-continue in $remaining s"
    $countdownLabel.Location = New-Object System.Drawing.Point(12, 262)
    $countdownLabel.Size = New-Object System.Drawing.Size(380, 18)
    $form.Controls.Add($countdownLabel) | Out-Null

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(666, 256)
    $okButton.Size = New-Object System.Drawing.Size(84, 28)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $defaultsButton = New-Object System.Windows.Forms.Button
    $defaultsButton.Text = "Use Defaults"
    $defaultsButton.Location = New-Object System.Drawing.Point(756, 256)
    $defaultsButton.Size = New-Object System.Drawing.Size(84, 28)
    $defaultsButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($defaultsButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $defaultsButton

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timerRemaining = $remaining
    $timer.Add_Tick({
        $timerRemaining--
        if ($timerRemaining -le 0) {
            $timer.Stop()
            $form.Close()
        } else {
            $countdownLabel.Text = "Auto-continue in $timerRemaining s"
        }
    }.GetNewClosure())

    $form.Add_Shown({ $timer.Start() })
    $dialogResult = $form.ShowDialog()
    $timer.Stop()

    foreach ($fieldName in $fieldOrder) {
        $defaultValue = [string]$Defaults[$fieldName]
        $entered = [string]$textBoxes[$fieldName].Text
        if (-not [string]::IsNullOrWhiteSpace($entered)) {
            $result[$fieldName] = $entered
        } else {
            $result[$fieldName] = $defaultValue
        }
    }

    return $result
}

# Define LOCAL region Configuration
$ConfigPath = ""
$DefaultFolder = ""
$TempFolder = ""
$ReportFolder = ""
$DownloadFolder = ""

$localPathDefaults = @{
    ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $localRoot } else { $ConfigPath }
    DefaultFolder = if ([string]::IsNullOrWhiteSpace($DefaultFolder)) { $localRoot } else { $DefaultFolder }
    TempFolder = if ([string]::IsNullOrWhiteSpace($TempFolder)) { $localRoot } else { $TempFolder }
    ReportFolder = if ([string]::IsNullOrWhiteSpace($ReportFolder)) { $localRoot } else { $ReportFolder }
    DownloadFolder = if ([string]::IsNullOrWhiteSpace($DownloadFolder)) { (Join-Path $localRoot "~DOWNLOADS") } else { $DownloadFolder }
}

$localPathSelection = Request-LocalPathsUnified -Defaults $localPathDefaults -TimeoutSeconds 15
$ConfigPath = $localPathSelection.ConfigPath
$DefaultFolder = $localPathSelection.DefaultFolder
$TempFolder = $localPathSelection.TempFolder
$ReportFolder = $localPathSelection.ReportFolder
$DownloadFolder = $localPathSelection.DownloadFolder

# Create local directories if they don't exist
if ($ConfigPath -and -not (Test-Path $ConfigPath)) { New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null }
if ($DefaultFolder -and -not (Test-Path $DefaultFolder)) { New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null }
if ($TempFolder -and -not (Test-Path $TempFolder)) { New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null }
if ($ReportFolder -and -not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
if ($DownloadFolder -and -not (Test-Path $DownloadFolder)) { New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null }

# Define GLOBAL script directory and Files
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $scriptDir "config"
$modulesDir = Join-Path $scriptDir "modules"
$logsDir = Join-Path $scriptDir "logs"
$scriptsDir = Join-Path $scriptDir "scripts"
$configFile = Join-Path $configDir "system-variables.xml"
$linksConfigFile = Join-Path $configDir "links.xml"
$avpnConfigFile = Join-Path $configDir "AVPN-devices.json"
$avpnModulePath = Join-Path $modulesDir "AVPN-Tracker.psm1"

# Create GLOBAL directories if they don't exist
if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null }
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
if (-not (Test-Path $modulesDir)) { New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
if (-not (Test-Path $configFile)) { New-Item -ItemType File -Path $configFile -Force | Out-Null }
if (-not (Test-Path $linksConfigFile)) { New-Item -ItemType File -Path $linksConfigFile -Force | Out-Null }
if (-not (Test-Path $avpnConfigFile)) { New-Item -ItemType File -Path $avpnConfigFile -Force | Out-Null }
if (-not (Test-Path $avpnModulePath)) { Write-Warning "AVPN module not found at $avpnModulePath" }

# ==================== LOGGING FUNCTIONS ====================
function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet("Info", "Warning", "Error", "Success", "Debug", "Event")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $hostname = $env:COMPUTERNAME
    $timestamp_date = Get-Date -Format 'yyyy-MM-dd'
    $logFile = Join-Path $logsDir "$hostname-$timestamp_date.log"
    
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Buffered write instead of Add-Content for performance
    $script:_LogBuffer += @{
        File = $logFile
        Content = $logEntry
    }
    
    if ($script:_LogBuffer.Count -ge $script:_LogBufferSize) {
        Flush-LogBuffer
    }
    
    # Also write to console
    switch ($Level) {
        "Warning" { Write-Warning $logEntry }
        "Error" { Write-Error $logEntry -ErrorAction Continue }
        default { Write-Information $logEntry -InformationAction Continue }
    }
}

function Write-ScriptLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        
        [ValidateSet("Info", "Warning", "Error", "Success", "Debug", "Event")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $hostname = $env:COMPUTERNAME
    $timestamp_date = Get-Date -Format 'yyyy-MM-dd'
    $scriptLogFile = Join-Path $logsDir "$hostname-$timestamp_date`_PwShGui-SCRIPTS.log"
    
    $logEntry = "[$timestamp] [$ScriptName] [$Level] $Message"
    
    # Buffered write instead of Add-Content for performance
    $script:_LogBuffer += @{
        File = $scriptLogFile
        Content = $logEntry
    }
    
    if ($script:_LogBuffer.Count -ge $script:_LogBufferSize) {
        Flush-LogBuffer
    }
}

function Flush-LogBuffer {
    if ($script:_LogBuffer.Count -eq 0) { return }
    
    $groupedByFile = $script:_LogBuffer | Group-Object -Property File
    
    foreach ($group in $groupedByFile) {
        $logFile = $group.Name
        $entries = $group.Group | ForEach-Object { $_.Content }
        
        try {
            $entries | Add-Content -Path $logFile -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "Failed to write log to $logFile : $_"
        }
    }
    
    $script:_LogBuffer.Clear()
}

# Import AVPN module if available
if (Test-Path $avpnModulePath) {
    Import-Module $avpnModulePath -Force
} else {
    Write-AppLog "AVPN module not found at $avpnModulePath" "Warning"
}

# ==================== CONFIG FUNCTIONS ====================
function Initialize-ConfigFile {
    Write-AppLog "Creating system variables config file..." "Info"
    
    $systemVars = @{
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        UserDomain = $env:USERDOMAIN
        OSVersion = [System.Environment]::OSVersion.VersionString
        ProcessorCount = $env:PROCESSOR_COUNT
        SystemRoot = $env:SystemRoot
        Windows = $env:Windows
        ProgramFiles = $env:ProgramFiles
        ProgramFiles_x86 = ${env:ProgramFiles(x86)}
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        Temp = $env:TEMP
        PSVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellVersion = $PSVersionTable.PSVersion.Major
        ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LogDirectory = $logsDir
        ConfigDirectory = $configDir
        ScriptsDirectory = $scriptsDir
        InitialExecutionHost = $host.Name
    }
    
    # Convert to XML and save
    $xmlDoc = New-Object System.Xml.XmlDocument
    $root = $xmlDoc.CreateElement("SystemVariables")
    
    foreach ($key in $systemVars.Keys) {
        $element = $xmlDoc.CreateElement($key)
        $element.InnerText = $systemVars[$key]
        $root.AppendChild($element) | Out-Null
    }
    
    # version and tagging configuration
    $versionElement = $xmlDoc.CreateElement("Version")
    $majorElem = $xmlDoc.CreateElement("Major")
    $majorElem.InnerText = (Get-Date).ToString('yyMM')
    $versionElement.AppendChild($majorElem) | Out-Null
    $minorElem = $xmlDoc.CreateElement("Minor")
    $minorElem.InnerText = 'a'
    $versionElement.AppendChild($minorElem) | Out-Null
    $buildElem = $xmlDoc.CreateElement("Build")
    $buildElem.InnerText = '0'
    $versionElement.AppendChild($buildElem) | Out-Null
    $root.AppendChild($versionElement) | Out-Null
    
    $excludeElement = $xmlDoc.CreateElement("Do-Not-VersionTag-FoldersFiles")
    foreach ($folder in @('~BACKUPS','FOLDER-ROOT','logs','~REPORTS','~DOWNLOADS','temp','.logs','AutoIssueFinder-Logs')) {
        $f = $xmlDoc.CreateElement("Folder")
        $f.InnerText = $folder
        $excludeElement.AppendChild($f) | Out-Null
    }
    $root.AppendChild($excludeElement) | Out-Null
    
    # Add Buttons section
    $buttonsElement = $xmlDoc.CreateElement("Buttons")
    
    # Left column buttons
    $leftButtonsElement = $xmlDoc.CreateElement("LeftColumn")
    $leftButtons = @(
        @{ ScriptName = "Script5"; DisplayName = "Backup Operations" },
        @{ ScriptName = "Script6"; DisplayName = "Configuration Sync" },
        @{ ScriptName = "Script1"; DisplayName = "Database Maintenance" },
        @{ ScriptName = "Script3"; DisplayName = "Network Diagnostics" },
        @{ ScriptName = "Script2"; DisplayName = "System Cleanup" },
        @{ ScriptName = "Script4"; DisplayName = "Access - User and Group Management" }
    )
    
    foreach ($btn in $leftButtons) {
        $btnElement = $xmlDoc.CreateElement("Button")
        
        $scriptNameElem = $xmlDoc.CreateElement("ScriptName")
        $scriptNameElem.InnerText = $btn.ScriptName
        $btnElement.AppendChild($scriptNameElem) | Out-Null
        
        $displayNameElem = $xmlDoc.CreateElement("DisplayName")
        $displayNameElem.InnerText = $btn.DisplayName
        $btnElement.AppendChild($displayNameElem) | Out-Null
        
        $leftButtonsElement.AppendChild($btnElement) | Out-Null
    }
    
    $buttonsElement.AppendChild($leftButtonsElement) | Out-Null
    
    # Right column buttons
    $rightButtonsElement = $xmlDoc.CreateElement("RightColumn")
    $rightButtons = @(
        @{ ScriptName = "PWShQuickApp"; DisplayName = "PWSH-Quick-App (PWSH7 Prompt - Script Runner)"; ScriptPath = "~PWSH_Quick-APP3.ps1" }
    )
    
    foreach ($btn in $rightButtons) {
        $btnElement = $xmlDoc.CreateElement("Button")
        
        $scriptNameElem = $xmlDoc.CreateElement("ScriptName")
        $scriptNameElem.InnerText = $btn.ScriptName
        $btnElement.AppendChild($scriptNameElem) | Out-Null
        
        $displayNameElem = $xmlDoc.CreateElement("DisplayName")
        $displayNameElem.InnerText = $btn.DisplayName
        $btnElement.AppendChild($displayNameElem) | Out-Null
        
        if ($btn.ScriptPath) {
            $pathElem = $xmlDoc.CreateElement("ScriptPath")
            $pathElem.InnerText = $btn.ScriptPath
            $btnElement.AppendChild($pathElem) | Out-Null
        }
        
        $rightButtonsElement.AppendChild($btnElement) | Out-Null
    }
    
    $buttonsElement.AppendChild($rightButtonsElement) | Out-Null
    $root.AppendChild($buttonsElement) | Out-Null
    
    $xmlDoc.AppendChild($root) | Out-Null
    $xmlDoc.Save($configFile)
    
    Write-AppLog "System variables config created successfully" "Success"
}

function Get-ConfigVariable {
    param([string]$VariableName)
    
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return $null
    }
    
    [xml]$xml = Get-Content $configFile
    return $xml.SystemVariables.$VariableName.InnerText
}

function Get-ButtonConfiguration {
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return @{ Left = @(); Right = @() }
    }
    
    [xml]$xml = Get-Content $configFile
    $buttonConfig = @{ Left = @(); Right = @() }
    
    # Load left column buttons
    if ($xml.SystemVariables.Buttons.LeftColumn) {
        foreach ($btn in $xml.SystemVariables.Buttons.LeftColumn.Button) {
            $buttonConfig.Left += @{
                ScriptName = $btn.ScriptName
                DisplayName = $btn.DisplayName
            }
        }
    }
    
    # Load right column buttons
    if ($xml.SystemVariables.Buttons.RightColumn) {
        foreach ($btn in $xml.SystemVariables.Buttons.RightColumn.Button) {
            $buttonConfig.Right += @{
                ScriptName = $btn.ScriptName
                DisplayName = $btn.DisplayName
                ScriptPath = $btn.ScriptPath
            }
        }
    }
    
    return $buttonConfig
}

# ------------------ configuration helpers ------------------
function Get-ConfigSubValue {
    param([string]$XPath)
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return $null
    }
    
    # Load config once and cache it
    if (-not $script:_XmlCache.ConfigFile -or (Test-Path $configFile -NewerThan $script:_XmlCache.LastConfigLoad)) {
        $script:_XmlCache.ConfigFile = [xml](Get-Content $configFile)
        $script:_XmlCache.LastConfigLoad = Get-Item $configFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    $node = $script:_XmlCache.ConfigFile.SelectSingleNode("/SystemVariables/$XPath")
    if ($node) { return $node.InnerText } else { return $null }
}

function Get-ConfigList {
    param([string]$ListName)
    if (-not (Test-Path $configFile)) {
        Write-AppLog "Config file not found: $configFile" "Warning"
        return @()
    }
    
    # Load config once and cache it
    if (-not $script:_XmlCache.ConfigFile -or (Test-Path $configFile -NewerThan $script:_XmlCache.LastConfigLoad)) {
        $script:_XmlCache.ConfigFile = [xml](Get-Content $configFile)
        $script:_XmlCache.LastConfigLoad = Get-Item $configFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    $nodes = $script:_XmlCache.ConfigFile.SelectNodes("/SystemVariables/$ListName/Folder")
    return $nodes | ForEach-Object { $_.InnerText }
}

function Initialize-LinksConfigFile {
    if (Test-Path $linksConfigFile) { return }
    $xmlDoc = New-Object System.Xml.XmlDocument
    $root = $xmlDoc.CreateElement("Links")
    $xmlDoc.AppendChild($root) | Out-Null

    $categories = @(
        @{ Name = "CORPORATE"; Links = @(@{ Name = "Intranet"; Url = "https://intranet.example.com" }, @{ Name = "HR Portal"; Url = "https://hr.example.com" }) },
        @{ Name = "PUBLIC-INFO"; Links = @(@{ Name = "Company Site"; Url = "https://example.com" }) },
        @{ Name = "LOCAL"; Links = @(@{ Name = "Local Dashboard"; Url = "http://localhost" }) },
        @{ Name = "M365"; Links = @(@{ Name = "Outlook"; Url = "https://outlook.office.com" }, @{ Name = "OneDrive"; Url = "https://onedrive.live.com" }) },
        @{ Name = "SEARCH"; Links = @(@{ Name = "Bing"; Url = "https://www.bing.com" }, @{ Name = "Google"; Url = "https://www.google.com" }) },
        @{ Name = "USERS-URLS"; Links = @(@{ Name = "User Link 1"; Url = "https://example.com" }) }
    )

    foreach ($cat in $categories) {
        $catElem = $xmlDoc.CreateElement("Category")
        $catElem.SetAttribute("name", $cat.Name)
        foreach ($link in $cat.Links) {
            $linkElem = $xmlDoc.CreateElement("Link")
            $linkElem.SetAttribute("name", $link.Name)
            $linkElem.SetAttribute("url", $link.Url)
            $catElem.AppendChild($linkElem) | Out-Null
        }
        $root.AppendChild($catElem) | Out-Null
    }

    $xmlDoc.Save($linksConfigFile)
}

function Get-LinksConfig {
    if (-not (Test-Path $linksConfigFile)) { Initialize-LinksConfigFile }
    
    # Load and cache links config
    if (-not $script:_XmlCache.LinksConfig -or (Test-Path $linksConfigFile -NewerThan $script:_XmlCache.LastLinksLoad)) {
        $script:_XmlCache.LinksConfig = [xml](Get-Content $linksConfigFile)
        $script:_XmlCache.LastLinksLoad = Get-Item $linksConfigFile | Select-Object -ExpandProperty LastWriteTime
    }
    
    return $script:_XmlCache.LinksConfig
}

function Get-VersionInfo {
    # Consolidated version info retrieval (single cache load instead of 3)
    try {
        return @{
            Major = Get-ConfigSubValue "Version/Major"
            Minor = Get-ConfigSubValue "Version/Minor"
            Build = Get-ConfigSubValue "Version/Build"
        }
    } catch {
        Write-AppLog "Error retrieving version info: $_" "Error"
        return @{ Major = "26"; Minor = "02"; Build = "0" }
    }
}

function Build-LinksMenu {
    param([System.Windows.Forms.ToolStripMenuItem]$LinksMenu)
    $LinksMenu.DropDownItems.Clear() | Out-Null
    $xml = Get-LinksConfig
    foreach ($cat in $xml.Links.Category) {
        $catItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $catItem.Text = $cat.name
        foreach ($link in $cat.Link) {
            $linkItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $linkItem.Text = $link.name
            $urlCopy = $link.url
            $linkItem.Add_Click({ Start-Process $urlCopy })
            $catItem.DropDownItems.Add($linkItem) | Out-Null
        }
        $LinksMenu.DropDownItems.Add($catItem) | Out-Null
    }
}
function Show-DiskCheckDialog {
    Write-AppLog "User initiated Disk Check" "Event"
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -ExpandProperty DeviceID
    if (-not $drives) {
        [System.Windows.Forms.MessageBox]::Show("No local fixed drives found.", "Disk Check") | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Disk Check"
    $form.Size = New-Object System.Drawing.Size(360, 320)
    $form.StartPosition = "CenterParent"

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Location = New-Object System.Drawing.Point(12, 12)
    $list.Size = New-Object System.Drawing.Size(320, 220)
    $list.CheckOnClick = $true
    foreach ($drive in $drives) { [void]$list.Items.Add($drive) }
    $form.Controls.Add($list)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Run"
    $okBtn.Location = New-Object System.Drawing.Point(176, 245)
    $okBtn.Add_Click({
        $selected = @($list.CheckedItems)
        if (-not $selected) {
            [System.Windows.Forms.MessageBox]::Show("Select at least one drive.", "Disk Check") | Out-Null
            return
        }
        foreach ($drive in $selected) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c chkdsk $drive /f" -Verb RunAs
        }
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(256, 245)
    $cancelBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($cancelBtn)

    $form.ShowDialog() | Out-Null
}

function Show-PrivacyCheck {
    Write-AppLog "User initiated Privacy Check" "Event"
    Start-Process "ms-settings:privacy"
}

function Show-SystemCheck {
    Write-AppLog "User initiated System Check" "Event"
    $tempFile = Join-Path $env:TEMP ("sfc-detectonly-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c sfc /detectonly > `"$tempFile`" 2>&1" -Wait -WindowStyle Hidden
    $output = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
    $issuesFound = $false
    if ($output -match "found corrupt files" -or $output -match "integrity violations") { $issuesFound = $true }

    if ($issuesFound) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "System file issues detected. Run elevated 'sfc /scannow' now?",
            "System Check",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c sfc /scannow" -Verb RunAs
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("No integrity violations detected.", "System Check") | Out-Null
    }
}

function Show-WingetInstalledApp {
    Write-AppLog "User initiated WinGet Installed Apps view" "Event"
    $apps = @()
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_.DisplayName) { return }
            $installDate = ''
            if ($_.InstallDate -match '^\d{8}$') {
                $installDate = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
            }
            $sizeMB = ''
            if ($_.EstimatedSize) { $sizeMB = [math]::Round($_.EstimatedSize / 1024, 2) }
            $lastUpdated = ''
            try { $lastUpdated = (Get-Item $_.PSPath).LastWriteTime.ToString('yyyy-MM-dd') } catch { $lastUpdated = '' }
            $apps += [pscustomobject]@{
                Name = $_.DisplayName
                Publisher = $_.Publisher
                Version = $_.DisplayVersion
                InstallDate = $installDate
                LastUpdated = $lastUpdated
                LastExecuted = ''
                SizeMB = $sizeMB
            }
        }
    }

    $apps | Sort-Object Name | Out-GridView -Title "Installed Apps (Registry/WinGet)"
}

function Show-WingetUpgradeCheck {
    Write-AppLog "User initiated WinGet update check" "Event"
    $logFile = Join-Path $logsDir ("winget-upgrades-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c winget upgrade > `"$logFile`" 2>&1" -Wait -WindowStyle Hidden
    Invoke-Item $logFile
}

function Show-WingetUpdateAllDialog {
    Write-AppLog "User initiated WinGet update-all" "Event"
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WinGet Update All"
    $form.Size = New-Object System.Drawing.Size(520, 220)
    $form.StartPosition = "CenterParent"

    $autoRadio = New-Object System.Windows.Forms.RadioButton
    $autoRadio.Text = "AUTO - winget upgrade --all --accept-source-agreements --accept-package-agreements"
    $autoRadio.Location = New-Object System.Drawing.Point(12, 12)
    $autoRadio.Size = New-Object System.Drawing.Size(480, 24)
    $autoRadio.Checked = $true
    $form.Controls.Add($autoRadio)

    $bugRadio = New-Object System.Windows.Forms.RadioButton
    $bugRadio.Text = "BUG - winget upgrade --all (prompt per package)"
    $bugRadio.Location = New-Object System.Drawing.Point(12, 44)
    $bugRadio.Size = New-Object System.Drawing.Size(480, 24)
    $form.Controls.Add($bugRadio)

    $adminCheck = New-Object System.Windows.Forms.CheckBox
    $adminCheck.Text = "Run as admin"
    $adminCheck.Location = New-Object System.Drawing.Point(12, 78)
    $adminCheck.Checked = $true
    $form.Controls.Add($adminCheck)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "Run"
    $okBtn.Location = New-Object System.Drawing.Point(336, 120)
    $okBtn.Add_Click({
        $wingetArgs = "upgrade --all"
        if ($autoRadio.Checked) {
            $wingetArgs = "upgrade --all --accept-source-agreements --accept-package-agreements"
        } else {
            [System.Windows.Forms.MessageBox]::Show("You will be prompted to confirm updates.", "WinGet") | Out-Null
        }
        if ($adminCheck.Checked) {
            Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Verb RunAs
        } else {
            Start-Process -FilePath "winget" -ArgumentList $wingetArgs
        }
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(416, 120)
    $cancelBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($cancelBtn)

    $form.ShowDialog() | Out-Null
}

# version helpers and tagging
function Update-VersionBuild {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Auto)
    if (-not (Test-Path $configFile)) { Initialize-ConfigFile }
    if (-not $PSCmdlet.ShouldProcess($configFile, "Update build number")) { return }
    [xml]$xml = Get-Content $configFile
    $buildNode = $xml.SelectSingleNode('/SystemVariables/Version/Build')
    if (-not $buildNode) {
        $versionNode = $xml.SelectSingleNode('/SystemVariables/Version')
        if (-not $versionNode) {
            $versionNode = $xml.CreateElement('Version')
            $xml.SystemVariables.AppendChild($versionNode) | Out-Null
        }
        $buildNode = $xml.CreateElement('Build')
        $versionNode.AppendChild($buildNode) | Out-Null
        $buildNode.InnerText = '0'
    }
    $current = [int]$buildNode.InnerText
    $buildNode.InnerText = ($current + 1).ToString()
    $xml.Save($configFile)
    if ($Auto) { Write-AppLog "Auto-incremented build to $($buildNode.InnerText)" "Info" }
}

function Export-WorkspacePackage {
    $versionInfo = Get-VersionInfo
    $major = $versionInfo.Major
    $minor = $versionInfo.Minor
    $build = $versionInfo.Build
    $zipName = "pwshGUI-v-$major$minor-build$build.zip"
    $workspace = Get-Location
    $packageExcludeFolders = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"
    $packageItems = Get-ChildItem -Path $workspace.Path -Force | Where-Object {
        $packageExcludeFolders -notcontains $_.Name
    } | Select-Object -ExpandProperty FullName
    $destinationPath = Join-Path $DownloadFolder $zipName
    Write-AppLog "Packaging workspace to $destinationPath" "Info"
    Compress-Archive -Path $packageItems -DestinationPath $destinationPath -Force
    Write-AppLog "Package created" "Success"
}

# update files in workspace with a version comment tag
function Update-VersionTag {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    # Auto-increment removed - now controlled by startup logic
    $versionInfo = Get-VersionInfo
    $major = $versionInfo.Major
    $minor = $versionInfo.Minor
    $build = $versionInfo.Build
    $versionString = "$major.$minor.$build"
    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"

    Write-AppLog "Updating version tags to $versionString" "Info"
    $workspace = Get-Location
    Get-ChildItem -File -Recurse | Where-Object {
        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")
        $skip = $false
        foreach($ex in $exclude) {
            if ($rel -like "${ex}*") { $skip = $true; break }
        }
        -not $skip
    } | ForEach-Object {
        $file = $_
        # skip modifying the main launcher script and build manifests
        if ($file.FullName -ieq $MyInvocation.MyCommand.Path) { return }
        if ($file.Name -like 'pwshGUI-v-*versionbuild*') { return }
        if ($file.Extension -ieq ".json") {
            $txt = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt) {
                $clean = $txt -replace '(?m)^\s*#\s*VersionTag:.*$\r?\n?', ''
                if ($clean -ne $txt) {
                    if ($PSCmdlet.ShouldProcess($file.FullName, "Remove version tag")) {
                        Set-Content -Path $file.FullName -Value $clean -ErrorAction SilentlyContinue
                    }
                }
            }
            return
        }
        if ($file.Extension -ieq ".exe" -or $file.Extension -ieq ".dll") { return }
        $text = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { return }
        $commentPrefix = "#"
        $commentSuffix = ""
        switch -Regex ($file.Extension) {
            "\.xml$|\.html$|\.htm$" { $commentPrefix = "<!--"; $commentSuffix=" -->" }
            "\.ps1$|\.psm1$|\.psd1$|\.txt$|\.md$" { $commentPrefix="#"; $commentSuffix="" }
            default { $commentPrefix="#"; $commentSuffix="" }
        }
        $tagLine = "$commentPrefix VersionTag: $versionString$commentSuffix"
        $newText = $text
        if ($text -match '^(.*)VersionTag:\s*([\d\.a-z]+)(.*)$') {
            $existingVer = $Matches[2]
            if ($existingVer -ne $versionString) {
                $newText = $text -replace '(?m)^\s*(#|<!--)\s*VersionTag:.*?(-->)?\s*$', $tagLine
            }
        } else {
            $newText = $tagLine + [Environment]::NewLine + $text
        }
        if ($newText -ne $text) {
            if ($PSCmdlet.ShouldProcess($file.FullName, "Update version tag")) {
                Set-Content -Path $file.FullName -Value $newText -ErrorAction SilentlyContinue
            }
        }
    }
}
function New-BuildManifest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $versionInfo = Get-VersionInfo
    $major = $versionInfo.Major
    $minor = $versionInfo.Minor
    $build = $versionInfo.Build
    $versionString = "$major.$minor.$build"
    $fileName = "pwshGUI-v-$major$minor-versionbuild.txt"
    $workspace = Get-Location
    $manifestPath = Join-Path $workspace.Path $fileName
    $manifestCachePath = Join-Path $configDir "manifest-cache.json"
    if (-not $PSCmdlet.ShouldProcess($manifestPath, "Create build manifest")) { return }
    Write-AppLog "Generating build manifest $fileName" "Info"

    $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"

    $cacheIndex = @{}
    if (Test-Path $manifestCachePath) {
        try {
            $cachedManifest = Get-Content $manifestCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($entry in @($cachedManifest.entries)) {
                if ($entry.RelPath) {
                    $cacheIndex[$entry.RelPath] = $entry
                }
            }
        }
        catch {
            Write-AppLog "Manifest cache unreadable, rebuilding incrementally from scratch: $_" "Warning"
            $cacheIndex = @{}
        }
    }

    $manifestLines = @()
    $manifestLines += "Version: $versionString"
    $manifestLines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    # header row
    $manifestLines += "Path,\tCreated,\tModified,\tSize,\tOwner,\tSHA256,\tMarkOfWeb,\tCert,\tCompressed,\tReadOnly,\tEncrypted"

    $newCacheEntries = New-Object System.Collections.Generic.List[object]
    $reusedCount = 0
    $refreshedCount = 0

    Get-ChildItem -File -Recurse | Where-Object {
        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart('\\')
        foreach($ex in $exclude) { if ($rel -like "$ex*") { return $false } }
        return $true
    } | ForEach-Object {
        $f = $_
        $rel = $f.FullName.Substring($workspace.Path.Length).TrimStart('\\')
        $signature = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        $cachedEntry = $cacheIndex[$rel]

        if ($cachedEntry -and $cachedEntry.Signature -eq $signature) {
            $entry = [PSCustomObject]@{
                RelPath = $rel
                Signature = $signature
                Created = [string]$cachedEntry.Created
                Modified = [string]$cachedEntry.Modified
                Size = [string]$cachedEntry.Size
                Owner = [string]$cachedEntry.Owner
                SHA256 = [string]$cachedEntry.SHA256
                MarkOfWeb = [string]$cachedEntry.MarkOfWeb
                Cert = [string]$cachedEntry.Cert
                Compressed = [string]$cachedEntry.Compressed
                ReadOnly = [string]$cachedEntry.ReadOnly
                Encrypted = [string]$cachedEntry.Encrypted
            }
            $reusedCount++
        }
        else {
            $attrs = Get-Item $f.FullName
            $owner = (Get-Acl $f.FullName).Owner
            $sha256 = (Get-FileHash -Algorithm SHA256 $f.FullName).Hash
            $motw = if (Test-Path "$($f.FullName):Zone.Identifier") { 'Yes' } else {'No'}
            $auth = Get-AuthenticodeSignature $f.FullName
            $cert = if ($auth.SignerCertificate) { $auth.SignerCertificate.Subject } else {''}
            $compressed = if ($attrs.Attributes -band [IO.FileAttributes]::Compressed) {'Yes'} else {'No'}
            $readonly = if ($attrs.IsReadOnly) {'Yes'} else {'No'}
            $encrypted = if ($attrs.Attributes -band [IO.FileAttributes]::Encrypted) {'Yes'} else {'No'}

            $entry = [PSCustomObject]@{
                RelPath = $rel
                Signature = $signature
                Created = $f.CreationTime.ToString('s')
                Modified = $f.LastWriteTime.ToString('s')
                Size = [string]$f.Length
                Owner = [string]$owner
                SHA256 = [string]$sha256
                MarkOfWeb = [string]$motw
                Cert = [string]$cert
                Compressed = [string]$compressed
                ReadOnly = [string]$readonly
                Encrypted = [string]$encrypted
            }
            $refreshedCount++
        }

        $newCacheEntries.Add($entry) | Out-Null
        # separate fields with comma followed by tab
        $manifestLines += "$($entry.RelPath),`t$($entry.Created),`t$($entry.Modified),`t$($entry.Size),`t$($entry.Owner),`t$($entry.SHA256),`t$($entry.MarkOfWeb),`t$($entry.Cert),`t$($entry.Compressed),`t$($entry.ReadOnly),`t$($entry.Encrypted)"
    }

    $manifestLines | Out-File -FilePath $manifestPath -Encoding UTF8

    $cachePayload = @{
        Version = $versionString
        Generated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        Entries = @($newCacheEntries)
    }
    $cachePayload | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestCachePath -Encoding UTF8

    Write-AppLog "Manifest cache summary: reused=$reusedCount refreshed=$refreshedCount total=$($reusedCount + $refreshedCount)" "Info"
}

function Test-VersionTag {
    $versionInfo = Get-VersionInfo
    $major = $versionInfo.Major
    $minor = $versionInfo.Minor
    $build = $versionInfo.Build
    $expected = "$major.$minor.$build"
    $workspace = Get-Location
    Write-AppLog "Checking version tags against expected $expected" "Info"

    # build xml document
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('Diffs')
    $root.SetAttribute('version',$expected)
    $xml.AppendChild($root) | Out-Null

    Get-ChildItem -File -Recurse | Where-Object {
        $rel = $_.FullName.Substring($workspace.Path.Length).TrimStart("\\")
        # skip manifest itself
        if ($rel -like 'pwshGUI-v-*versionbuild*') { return $false }
        $exclude = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"
        foreach($ex in $exclude) { if ($rel -like "${ex}*") { return $false } }
        return $true
    } | ForEach-Object {
        $file = $_
        if (
            $file.Extension -ieq '.json' -or
            $file.Extension -ieq '.exe' -or
            $file.Extension -ieq '.dll' -or
            $file.Extension -ieq '.html' -or
            $file.Extension -ieq '.htm' -or
            $file.Extension -ieq '.xhtml' -or
            $file.Extension -ieq '.log'
        ) { return }
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { return }
        $rel = $file.FullName.Substring($workspace.Path.Length).TrimStart("\\")
        $folder = Split-Path $rel -Parent
        if (-not $folder) { $folder = '.' }
        if ($content -match 'VersionTag:\s*([\d\.a-z]+)') {
            $tag = $Matches[1]
            if ($tag -ne $expected) {
                $folderNode = $root.SelectSingleNode("Folder[@path='$folder']")
                if (-not $folderNode) {
                    $folderNode = $xml.CreateElement('Folder')
                    $folderNode.SetAttribute('path',$folder)
                    $root.AppendChild($folderNode) | Out-Null
                }
                $fileNode = $xml.CreateElement('File')
                $fileNode.SetAttribute('name',$rel)
                $fileNode.SetAttribute('issue','tag mismatch')
                $fileNode.SetAttribute('found',$tag)
                $fileNode.SetAttribute('expected',$expected)
                $folderNode.AppendChild($fileNode) | Out-Null
                Write-AppLog "[$file] version tag mismatch: $tag vs $expected" "Error"
            }
        } else {
            $folderNode = $root.SelectSingleNode("Folder[@path='$folder']")
            if (-not $folderNode) {
                $folderNode = $xml.CreateElement('Folder')
                $folderNode.SetAttribute('path',$folder)
                $root.AppendChild($folderNode) | Out-Null
            }
            $fileNode = $xml.CreateElement('File')
            $fileNode.SetAttribute('name',$rel)
            $fileNode.SetAttribute('issue','missing tag')
            $folderNode.AppendChild($fileNode) | Out-Null
            Write-AppLog "[$file] missing version tag" "Warning"
        }
    }

    Compare-ExcludedFolder -workspace $workspace -xmlDoc $xml

    $diffFile = Join-Path $workspace.Path ("pwshGUI-v-$major$minor-versionbuild~DIFFS.xml")
    $xml.Save($diffFile)
}

function Compare-ExcludedFolder {
    param(
        $workspace,
        [ref]$diffs,
        [xml]$xmlDoc
    )
    $excludes = Get-ConfigList "Do-Not-VersionTag-FoldersFiles"
    $reportedIssues = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($ex in $excludes) {
        if ($ex -ieq 'logs') { continue }
        $folderPath = Join-Path $workspace.Path $ex
        if (-not (Test-Path $folderPath)) { continue }
        Get-ChildItem -Path $folderPath -Filter *.txt -File | ForEach-Object {
            $manifest = $_
            $lines = Get-Content $manifest.FullName
            $listed = @{}
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                if ($line -match '^(Path,\s*\t|Version:|Generated:)') { continue }

                $relativePath = $null
                if ($line -match '^(?<path>[^,\t]+),\s*\t') {
                    $relativePath = $Matches['path']
                } elseif ($line -match '^(?<path>[^\t]+)\t') {
                    $relativePath = $Matches['path']
                }

                if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
                    $listed[$relativePath] = $true
                    $listed[(Split-Path $relativePath -Leaf)] = $true
                }
            }
            Get-ChildItem -Path $folderPath -File | ForEach-Object {
                $relname = $_.Name
                if ($relname -like 'pwshGUI-v-*versionbuild*') { return }
                if ($manifest.FullName -eq $_.FullName) { return }

                $relativeFromExcludedFolder = Join-Path $ex $relname
                $relativeFromExcludedFolder = $relativeFromExcludedFolder -replace '/', '\\'

                if ($listed.ContainsKey($relname) -or $listed.ContainsKey($relativeFromExcludedFolder)) {
                    return
                }

                $issueKey = "$ex|$relname"
                if (-not $reportedIssues.Add($issueKey)) { return }

                Write-AppLog "$relname exists but not in manifest" "Error"
                if ($diffs) { $diffs.Value += "$folderPath\$relname - not in manifest" }
                if ($xmlDoc) {
                    $root = $xmlDoc.DocumentElement
                    $folderNode = $root.SelectSingleNode("Folder[@path='$ex']")
                    if (-not $folderNode) {
                        $folderNode = $xmlDoc.CreateElement('Folder')
                        $folderNode.SetAttribute('path',$ex)
                        $root.AppendChild($folderNode) | Out-Null
                    }
                    $fileNode = $xmlDoc.CreateElement('File')
                    $fileNode.SetAttribute('name',$relname)
                    $fileNode.SetAttribute('issue','not in manifest')
                    $folderNode.AppendChild($fileNode) | Out-Null
                }
            }
        }
    }
}

# ==================== SCRIPT EXECUTION FUNCTIONS ====================

function Get-RainbowColor {
    param([int]$Step)

    $colors = @(
        @{R=255; G=0;   B=0},
        @{R=255; G=127; B=0},
        @{R=255; G=255; B=0},
        @{R=0;   G=255; B=0},
        @{R=0;   G=0;   B=255},
        @{R=75;  G=0;   B=130},
        @{R=148; G=0;   B=211}
    )

    $index = $Step % $colors.Count
    return $colors[$index]
}

function Write-RainbowProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [Parameter(Mandatory = $true)]
        [int]$PercentComplete,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [int]$Step = 0
    )

    $color = Get-RainbowColor -Step $Step
    $barLength = 50
    $completed = [Math]::Floor(($PercentComplete / 100) * $barLength)
    $remaining = $barLength - $completed
    $bar = ("[" + ("█" * $completed) + ("░" * $remaining) + "]")
    $colorCode = "`e[38;2;$($color.R);$($color.G);$($color.B)m"
    $resetCode = "`e[0m"
    Write-Host "`r$colorCode$bar $PercentComplete% $resetCode- $Status" -NoNewline

    if ($PercentComplete -ge 100) {
        Write-Host ""
    }
}

function Invoke-LocalScriptWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [bool]$UseWhatIf = $false,

        [int]$EstimatedSeconds = 10
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "▶ STEP 1 of 1: Executing $ScriptName" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $job = Start-Job -ScriptBlock {
        param($path, $useWhatIf)
        if ($useWhatIf) {
            & $path -WhatIf *>&1
        } else {
            & $path *>&1
        }
    } -ArgumentList $ScriptPath, $UseWhatIf

    $startTime = Get-Date
    $lastOutputCount = 0
    $elapsedBlocks = 0
    $percentComplete = 0

    while ($job.State -eq 'Running') {
        $elapsed = (Get-Date) - $startTime
        $elapsedSeconds = [Math]::Floor($elapsed.TotalSeconds)

        if ($elapsedSeconds -lt $EstimatedSeconds) {
            $percentComplete = [Math]::Floor(($elapsedSeconds / $EstimatedSeconds) * 100)
        } else {
            $percentComplete = 95 + ($elapsedSeconds - $EstimatedSeconds)
            if ($percentComplete -gt 99) { $percentComplete = 99 }
        }

        $currentBlock = [Math]::Floor($elapsedSeconds / 5)
        if ($currentBlock -gt $elapsedBlocks) {
            $elapsedBlocks = $currentBlock
            Write-Host "`n⏱  Elapsed: $($elapsedBlocks * 5) seconds" -ForegroundColor Magenta
        }

        $status = "Processing... Elapsed: $elapsedSeconds s"
        Write-RainbowProgress -Activity $ScriptName -PercentComplete $percentComplete -Status $status -Step $elapsedSeconds

        $output = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
        $outputArray = @($output)
        if ($outputArray.Count -gt $lastOutputCount) {
            $outputArray[$lastOutputCount..($outputArray.Count - 1)] | ForEach-Object { Write-Host $_ }
            $lastOutputCount = $outputArray.Count
        }

        Start-Sleep -Milliseconds 500
    }

    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    $finalElapsed = ((Get-Date) - $startTime).TotalSeconds
    Write-RainbowProgress -Activity $ScriptName -PercentComplete 101 -Status "COMPLETED!" -Step 10

    Write-Host "`n✓ COMPLETED: $ScriptName" -ForegroundColor Green
    Write-Host "  Duration: $([Math]::Round($finalElapsed, 2)) seconds" -ForegroundColor Gray
    Write-Host "  Items processed: $lastOutputCount" -ForegroundColor Gray

    return $result
}

function Wait-ProcessWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [int]$EstimatedSeconds = 10
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "▶ STEP 1 of 1: Executing $ScriptName (elevated)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $startTime = Get-Date
    $elapsedBlocks = 0
    $percentComplete = 0

    while (-not $Process.HasExited) {
        $elapsed = (Get-Date) - $startTime
        $elapsedSeconds = [Math]::Floor($elapsed.TotalSeconds)

        if ($elapsedSeconds -lt $EstimatedSeconds) {
            $percentComplete = [Math]::Floor(($elapsedSeconds / $EstimatedSeconds) * 100)
        } else {
            $percentComplete = 95 + ($elapsedSeconds - $EstimatedSeconds)
            if ($percentComplete -gt 99) { $percentComplete = 99 }
        }

        $currentBlock = [Math]::Floor($elapsedSeconds / 5)
        if ($currentBlock -gt $elapsedBlocks) {
            $elapsedBlocks = $currentBlock
            Write-Host "`n⏱  Elapsed: $($elapsedBlocks * 5) seconds" -ForegroundColor Magenta
        }

        $status = "Processing... Elapsed: $elapsedSeconds s"
        Write-RainbowProgress -Activity $ScriptName -PercentComplete $percentComplete -Status $status -Step $elapsedSeconds
        Start-Sleep -Milliseconds 500
    }

    $finalElapsed = ((Get-Date) - $startTime).TotalSeconds
    Write-RainbowProgress -Activity $ScriptName -PercentComplete 101 -Status "COMPLETED!" -Step 10

    Write-Host "`n✓ COMPLETED: $ScriptName" -ForegroundColor Green
    Write-Host "  Duration: $([Math]::Round($finalElapsed, 2)) seconds" -ForegroundColor Gray
    Write-Host "  Items processed: Output not captured (elevated process)" -ForegroundColor Gray
}

# ==================== SCRIPT EXECUTION FUNCTIONS ====================
function Invoke-ScriptWithElevation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        
        [bool]$RunAsAdmin = $false
    )
    
    $scriptPath = Join-Path $scriptsDir "$ScriptName.ps1"
    
    if (-not (Test-Path $scriptPath)) {
        Write-AppLog "Script not found: $scriptPath" "Error"
        Write-ScriptLog "Script not found: $scriptPath" $ScriptName "Error"
        [System.Windows.Forms.MessageBox]::Show("Script not found: $ScriptName.ps1", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
    
    $scriptContent = Get-Content $scriptPath -Raw -ErrorAction SilentlyContinue
    $scoreInfo = if ($scriptContent) { Get-ScriptSafetyScore -Content $scriptContent } else { $null }
    $safetyScore = if ($scoreInfo) { $scoreInfo.Score } else { 0 }
    $requiresInteractive = $false
    if ($scriptContent) {
        $requiresInteractive = $scriptContent -match '\bRead-Host\b|\bPromptForChoice\b|Out-GridView\s+.*-OutputMode|\.ShowDialog\(|MessageBox\]::Show\('
    } else {
        $requiresInteractive = $ScriptName -match 'QUICK-APP' -or $scriptPath -match '\\QUICK-APP\\'
    }
    if (-not $requiresInteractive) {
        if ($ScriptName -match 'QUICK-APP' -or $scriptPath -match '\\QUICK-APP\\') {
            $requiresInteractive = $true
        }
    }
    Write-AppLog "Launching script: $ScriptName (RunAsAdmin: $RunAsAdmin)" "Info"
    Write-AppLog "Script safety score: $safetyScore | $scriptPath" "Info"
    Write-ScriptLog "Script launch initiated (RunAsAdmin: $RunAsAdmin)" $ScriptName "Event"

    $supportsWhatIf = $false
    try {
        $cmd = Get-Command $scriptPath -ErrorAction Stop
        $supportsWhatIf = $cmd.Parameters.ContainsKey('WhatIf')
    } catch { $supportsWhatIf = $false }

    $useWhatIf = $false
    if ($safetyScore -gt 50 -and $supportsWhatIf) {
        $useWhatIf = $true
        Write-AppLog "Auto-enabling -WhatIf due to safety score > 50" "Info"
    }
    
    try {
        if ($RunAsAdmin) {
            # Check if already running as admin
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
            $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            
            if ($isAdmin) {
                Write-AppLog "Already running as admin, executing script directly" "Info"
                Write-ScriptLog "Executing as admin (current session elevated)" $ScriptName "Info"
                if ($requiresInteractive) {
                    Write-AppLog "Interactive input detected (Read-Host). Running without progress monitor." "Info"
                    Write-ScriptLog "Interactive input detected. Running without progress monitor." $ScriptName "Info"
                    if ($useWhatIf) {
                        & $scriptPath -WhatIf
                    } else {
                        & $scriptPath
                    }
                } else {
                    $null = Invoke-LocalScriptWithProgress -ScriptPath $scriptPath -ScriptName $ScriptName -UseWhatIf $useWhatIf -EstimatedSeconds 10
                }
            }
            else {
                Write-AppLog "Attempting to elevate script execution" "Info"
                Write-ScriptLog "Executing with elevation prompt" $ScriptName "Info"
                $whatIfArg = if ($useWhatIf) { " -WhatIf" } else { "" }
                $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"$whatIfArg" -Verb RunAs -PassThru
                if ($requiresInteractive) {
                    Write-AppLog "Interactive input detected (Read-Host). Skipping progress monitor for elevated run." "Info"
                    Write-ScriptLog "Interactive input detected. Skipping progress monitor for elevated run." $ScriptName "Info"
                    $proc.WaitForExit()
                } else {
                    Wait-ProcessWithProgress -Process $proc -ScriptName $ScriptName -EstimatedSeconds 10
                }
            }
        }
        else {
            Write-AppLog "Executing script without elevation" "Info"
            Write-ScriptLog "Executing without admin elevation" $ScriptName "Info"
            if ($requiresInteractive) {
                Write-AppLog "Interactive input detected (Read-Host). Running without progress monitor." "Info"
                Write-ScriptLog "Interactive input detected. Running without progress monitor." $ScriptName "Info"
                if ($useWhatIf) {
                    & $scriptPath -WhatIf
                } else {
                    & $scriptPath
                }
            } else {
                $null = Invoke-LocalScriptWithProgress -ScriptPath $scriptPath -ScriptName $ScriptName -UseWhatIf $useWhatIf -EstimatedSeconds 10
            }
        }
        
        Write-AppLog "Script execution completed: $ScriptName" "Success"
        Write-ScriptLog "Script execution completed successfully" $ScriptName "Success"
        return $true
    }
    catch {
        Write-AppLog "Error executing script: $_" "Error"
        Write-ScriptLog "Script execution failed: $_" $ScriptName "Error"
        [System.Windows.Forms.MessageBox]::Show("Error executing script: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

function Show-ElevationPrompt {
    param(
        [string]$ScriptName,
        [string]$ScriptPath
    )
    
    Write-AppLog "Displaying admin elevation prompt for script: $ScriptName" "Event"
    
    # Calculate safety score
    $safetyScore = 0
    $scoreEmoji = "[ ]"
    $scoreColor = "Unknown"
    $scriptContent = ""
    
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        $scriptContent = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
        if ($scriptContent) {
            $scoreInfo = Get-ScriptSafetyScore -Content $scriptContent
            $safetyScore = $scoreInfo.Score
            
            # Determine color and emoji
            if ($safetyScore -ge 80) {
                $scoreEmoji = "[+]"
                $scoreColor = "Safe"
            } elseif ($safetyScore -ge 50) {
                $scoreEmoji = "[~]"
                $scoreColor = "Moderate"
            } else {
                $scoreEmoji = "[!]"
                $scoreColor = "Risky"
            }
        }
    }
    
    # Build message with safety badge
    $message = "=======================================`n"
    $message += "  Script: $ScriptName`n"
    $message += "  Safety Score: $safetyScore/100 $scoreEmoji`n"
    $message += "  Status: $scoreColor`n"
    $message += "=======================================`n`n"
    $message += "Run with administrator privileges?"
    
    if ($safetyScore -gt 50 -and $safetyScore -lt 100) {
        $message += "`n`nNOTE: Script will run with -WhatIf (preview mode)"
    }
    
    Write-AppLog "Script safety score displayed: $safetyScore ($scoreColor)" "Info"
    
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Admin Elevation Request",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    
    $shouldElevate = $result -eq [System.Windows.Forms.DialogResult]::Yes
    Write-AppLog "Admin elevation response: $(if ($shouldElevate) { 'YES' } else { 'NO' })" "Event"
    
    return $shouldElevate
}

# ==================== NETWORK DIAGNOSTICS ====================
function Get-NetworkDiagnostic {
    $results = @()
    
    # Get local IP
    try {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        if (-not $localIP) {
            $localIP = ([System.Net.Dns]::GetHostByName([System.Net.Dns]::GetHostName()).AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0].IPAddress
        }
        $results += "Local IP: $localIP"
    }
    catch {
        $results += "Local IP: Unable to determine"
    }
    
    # Get gateway IP
    try {
        $gateway = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Select-Object -First 1).NextHop
        $results += "Gateway IP: $gateway"
    }
    catch {
        $results += "Gateway IP: Unable to determine"
    }
    
    # Get public WAN IP
    try {
        $wanIP = Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 5 | Select-Object -ExpandProperty ip
        $results += "Public WAN IP: $wanIP"
    }
    catch {
        $results += "Public WAN IP: Unable to determine"
    }
    
    # DNS servers
    $results += "`nDNS Configuration:"
    $dnsServers = @("1.1.1.1", "9.9.9.9", "8.8.8.8")
    
    foreach ($dns in $dnsServers) {
        $pingTest = $false
        $dnsTest = $false
        
        try {
            $ping = Test-Connection -ComputerName $dns -Count 1 -ErrorAction SilentlyContinue
            $pingTest = $null -ne $ping
        }
        catch { $pingTest = $false }
        
        try {
            $dnsResolve = Resolve-DnsName -Name "google.com" -Server $dns -ErrorAction SilentlyContinue
            $dnsTest = $null -ne $dnsResolve
        }
        catch { $dnsTest = $false }
        
        $pingStatus = if ($pingTest) { "OK Reachable" } else { "FAIL Unreachable" }
        $dnsStatus = if ($dnsTest) { "OK Working" } else { "FAIL Failed" }
        
        $results += "DNS $dns - Ping: $pingStatus | Lookup: $dnsStatus"
    }
    
    return $results
}

# ==================== GUI LAYOUT DISPLAY ====================
function Show-GUILayout {
    [System.Windows.Forms.MessageBox]::Show(
        @"
Scriptz n Portz N PowerShellD - Layout Information:

MAIN WINDOW (600x500)
+ Menu Bar
|  + File
|  |  - Exit (Ctrl+Q)
|  + Tests
|  |  - Version Check
|  |  - Network Diagnostics
|  |  - Disk Check
|  |  - Privacy Check
|  |  - System Check
|  + Links
|  |  - CORPORATE
|  |  - PUBLIC-INFO
|  |  - LOCAL
|  |  - M365
|  |  - SEARCH
|  |  - USERS-URLS
|  + WinGets
|  |  - Installed Apps (Grid View)
|  |  - Detect Updates (Check-Only)
|  |  - Update All (Admin Options)
|  + Tools
|  |  - View Config
|  |  - Open Logs Directory
|  |  - Scriptz n Portz N PowerShellD (Layout)
|  |  - Button Maintenance
|  |  - Network Details
|  |  - AVPN Connection Tracker
|  + Help
|     - Update-Help
|     - Package Workspace
|     - About
+ Title Label (560x30) - "Scriptz n Portz N PowerShellD"
+ Buttons Grid (2 columns x 3 rows)
|  - Script1 - Database Maintenance
|  - Script2 - System Cleanup
|  - Script3 - Network Diagnostics
|  - Script4 - User Management
|  - Script5 - Backup Operations
|  - Script6 - Configuration Sync
`- Status Bar (600x20)

CONFIGURATION
- Config File: C:\PowerShellGUI\config\system-variables.xml
- AVPN Devices: C:\PowerShellGUI\config\AVPN-devices.json
`- Logs Directory: C:\PowerShellGUI\logs\

For more information, see the documentation files.
"@,
        "Scriptz n Portz N PowerShellD - Layout",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

# ==================== PATH MANAGEMENT FUNCTIONS ====================
function Test-PathReadWrite {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return @{ Readable = $false; Writable = $false; Exists = $false }
    }
    
    $canRead = $true
    $canWrite = $true
    
    try {
        $items = Get-ChildItem -Path $Path -ErrorAction Stop
    } catch {
        $canRead = $false
    }
    
    try {
        $testFile = Join-Path $Path ".access-test-$([guid]::NewGuid().ToString()).tmp"
        New-Item -ItemType File -Path $testFile -Force | Out-Null
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
    } catch {
        $canWrite = $false
    }
    
    return @{ Readable = $canRead; Writable = $canWrite; Exists = $true }
}

function Get-ScriptFoldersConfig {
    $scriptFoldersConfigPath = Join-Path $configDir "pwsh-scriptfolders-config.json"
    
    if (Test-Path $scriptFoldersConfigPath) {
        try {
            $config = Get-Content -Path $scriptFoldersConfigPath -Raw | ConvertFrom-Json
            return $config
        } catch {
            Write-AppLog "Error reading script folders config: $_" "Warning"
            return $null
        }
    }
    return $null
}

function Save-ScriptFoldersConfig {
    param([object]$Config)
    
    $scriptFoldersConfigPath = Join-Path $configDir "pwsh-scriptfolders-config.json"
    
    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $scriptFoldersConfigPath -Force
        Write-AppLog "Script folders config saved successfully" "Success"
        return $true
    } catch {
        Write-AppLog "Error saving script folders config: $_" "Error"
        return $false
    }
}

function Show-PathSettingsGUI {
    $requiredPaths = @(
        @{ Key = "ConfigPath"; Label = "Configuration Folder"; Default = $ConfigPath },
        @{ Key = "DefaultFolder"; Label = "Default Working Folder"; Default = $DefaultFolder },
        @{ Key = "TempFolder"; Label = "Temporary Folder"; Default = $TempFolder },
        @{ Key = "ReportFolder"; Label = "Report Output Folder"; Default = $ReportFolder },
        @{ Key = "DownloadFolder"; Label = "Download Folder"; Default = $DownloadFolder }
    )
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Path Configuration Settings"
    $form.Size = New-Object System.Drawing.Size(800, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Configure Application Paths"
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(770, 20)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $pathControls = @{}
    $yPos = 45
    
    foreach ($pathItem in $requiredPaths) {
        # Label
        $label = New-Object System.Windows.Forms.Label
        $label.Text = "$($pathItem.Label):"
        $label.Location = New-Object System.Drawing.Point(12, $yPos)
        $label.Size = New-Object System.Drawing.Size(770, 18)
        $label.Font = New-Object System.Drawing.Font("Arial", 9)
        $form.Controls.Add($label)
        
        $yPos += 20
        
        # TextBox
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Text = $pathItem.Default
        $textBox.Location = New-Object System.Drawing.Point(12, $yPos)
        $textBox.Size = New-Object System.Drawing.Size(700, 22)
        $textBox.Font = New-Object System.Drawing.Font("Courier New", 9)
        $form.Controls.Add($textBox)
        
        # Browse Button
        $browseBtn = New-Object System.Windows.Forms.Button
        $browseBtn.Text = "Browse..."
        $browseBtn.Location = New-Object System.Drawing.Point(720, $yPos)
        $browseBtn.Size = New-Object System.Drawing.Size(60, 22)
        $browseBtn.Add_Click({
            param($sender, $e)
            $folder = New-Object System.Windows.Forms.FolderBrowserDialog
            $folder.Description = "Select path for $($sender.Tag)"
            $folder.SelectedPath = $textBox.Text
            if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $textBox.Text = $folder.SelectedPath
                Validate-PathStatus
            }
        }.GetNewClosure())
        $browseBtn.Tag = $pathItem.Label
        $form.Controls.Add($browseBtn)
        
        $pathControls[$pathItem.Key] = @{ TextBox = $textBox; Label = $label; BrowseBtn = $browseBtn }
        
        $yPos += 35
    }
    
    # Validate button
    $validateBtn = New-Object System.Windows.Forms.Button
    $validateBtn.Text = "Validate All"
    $validateBtn.Location = New-Object System.Drawing.Point(12, $yPos)
    $validateBtn.Size = New-Object System.Drawing.Size(100, 25)
    $validateBtn.Add_Click({ Validate-PathStatus })
    $form.Controls.Add($validateBtn)
    
    # OK Button
    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(620, $yPos)
    $okBtn.Size = New-Object System.Drawing.Size(75, 25)
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.Add_Click({
        # Save paths to global variables
        $script:ConfigPath = $pathControls["ConfigPath"].TextBox.Text
        $script:DefaultFolder = $pathControls["DefaultFolder"].TextBox.Text
        $script:TempFolder = $pathControls["TempFolder"].TextBox.Text
        $script:ReportFolder = $pathControls["ReportFolder"].TextBox.Text
        $script:DownloadFolder = $pathControls["DownloadFolder"].TextBox.Text
        
        # Create directories
        @($script:ConfigPath, $script:DefaultFolder, $script:TempFolder, $script:ReportFolder, $script:DownloadFolder) | ForEach-Object {
            if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
        }
        
        $form.Close()
    })
    $form.Controls.Add($okBtn)
    
    # Cancel Button
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(700, $yPos)
    $cancelBtn.Size = New-Object System.Drawing.Size(75, 25)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)
    
    function Validate-PathStatus {
        foreach ($key in $pathControls.Keys) {
            $ctrl = $pathControls[$key]
            $result = Test-PathReadWrite -Path $ctrl.TextBox.Text
            
            if ($result.Exists -and $result.Readable -and $result.Writable) {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::LightGreen
            } elseif ($result.Exists -and $result.Readable) {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::Yellow
            } else {
                $ctrl.TextBox.BackColor = [System.Drawing.Color]::LightCoral
            }
        }
    }
    
    Validate-PathStatus
    $form.ShowDialog() | Out-Null
}

function Get-AllScriptFolders {
    $baseFolders = @($scriptsDir)
    $customFolders = @()
    
    $config = Get-ScriptFoldersConfig
    if ($config -and $config.customScriptFolders) {
        $customFolders = @($config.customScriptFolders | Where-Object { $_.enabled -eq $true } | ForEach-Object { $_.path })
    }
    
    return @($baseFolders + $customFolders)
}

function Show-ScriptFolderSettingsGUI {
    $config = Get-ScriptFoldersConfig
    if (-not $config) {
        $config = @{ customScriptFolders = @() }
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Manage Script Folders"
    $form.Size = New-Object System.Drawing.Size(700, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Configure Custom Script Folders"
    $titleLabel.Location = New-Object System.Drawing.Point(12, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(670, 20)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Add or remove additional script folder paths. Each path will be stored and loaded on app startup."
    $infoLabel.Location = New-Object System.Drawing.Point(12, 35)
    $infoLabel.Size = New-Object System.Drawing.Size(670, 30)
    $form.Controls.Add($infoLabel)
    
    # ListBox for folders
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(12, 70)
    $listBox.Size = New-Object System.Drawing.Size(670, 350)
    $listBox.SelectionMode = [System.Windows.Forms.SelectionMode]::One
    
    foreach ($folder in $config.customScriptFolders) {
        $displayText = "$($folder.label) - $($folder.path)"
        [void]$listBox.Items.Add($displayText)
    }
    
    $form.Controls.Add($listBox)
    
    # Add Button
    $addBtn = New-Object System.Windows.Forms.Button
    $addBtn.Text = "Add Folder..."
    $addBtn.Location = New-Object System.Drawing.Point(12, 430)
    $addBtn.Size = New-Object System.Drawing.Size(100, 25)
    $addBtn.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = "Select a script folder to add"
        
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $newFolder = @{
                path = $folderDialog.SelectedPath
                label = [System.IO.Path]::GetFileName($folderDialog.SelectedPath)
                enabled = $true
                addedDate = (Get-Date -Format "yyyy-MM-dd")
            }
            
            $config.customScriptFolders += $newFolder
            $displayText = "$($newFolder.label) - $($newFolder.path)"
            [void]$listBox.Items.Add($displayText)
        }
    })
    $form.Controls.Add($addBtn)
    
    # Remove Button
    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Location = New-Object System.Drawing.Point(120, 430)
    $removeBtn.Size = New-Object System.Drawing.Size(75, 25)
    $removeBtn.Add_Click({
        if ($listBox.SelectedIndex -ge 0) {
            $selected = $listBox.SelectedIndex
            $config.customScriptFolders = @($config.customScriptFolders | Where-Object { $_ -ne $config.customScriptFolders[$selected] })
            $listBox.Items.RemoveAt($selected)
        }
    })
    $form.Controls.Add($removeBtn)
    
    # OK Button
    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(570, 430)
    $okBtn.Size = New-Object System.Drawing.Size(100, 25)
    $okBtn.Add_Click({
        Save-ScriptFoldersConfig -Config $config
        Write-AppLog "Script folders configuration updated" "Success"
        $form.Close()
    })
    $form.Controls.Add($okBtn)
    
    # Cancel Button
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(600, 430)
    $cancelBtn.Size = New-Object System.Drawing.Size(75, 25)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)
    
    $form.ShowDialog() | Out-Null
}

# ==================== HELP FUNCTIONS ====================
function Show-UpdateHelp {
    Write-AppLog "User initiated Update-Help" "Event"
    [System.Windows.Forms.MessageBox]::Show("Updating PowerShell Help...", "Please Wait", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    
    try {
        Update-Help -Force -ErrorAction SilentlyContinue
        Write-AppLog "Help updated successfully" "Success"
        [System.Windows.Forms.MessageBox]::Show("PowerShell Help has been updated successfully.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    catch {
        Write-AppLog "Help update failed: $_" "Error"
        [System.Windows.Forms.MessageBox]::Show("Error updating help: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Show-NetworkDiagnosticsDialog {
    Write-AppLog "User opened Network Diagnostics" "Event"
    
    $results = Get-NetworkDiagnostic
    $resultText = $results -join "`r`n"
    
    [System.Windows.Forms.MessageBox]::Show(
        $resultText,
        "Network Diagnostics",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    
    Write-AppLog "Network Diagnostics results displayed" "Debug"
}

# ==================== TESTING ROUTINES ====================
function Test-AppTesting {
    $root = (Get-Location).Path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $report = @()

    $mdFiles = Get-ChildItem -Path $root -Recurse -File -Include *.md -ErrorAction SilentlyContinue
    $scriptFiles = Get-ChildItem -Path $root -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue

    $contradictionPairs = @(
        @("supported","not supported"),
        @("enabled","disabled"),
        @("required","not required"),
        @("recommended","not recommended"),
        @("deprecated","recommended")
    )

    foreach ($md in $mdFiles) {
        $content = Get-Content $md.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="empty file"; Detail="No content" }
            continue
        }

        $headingMatches = [regex]::Matches($content, "(?m)^\s*#{1,6}\s+(.+)$")
        if ($headingMatches.Count -eq 0) {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="missing headings"; Detail="No markdown headings found" }
        } else {
            $headingCounts = @{}
            foreach ($m in $headingMatches) {
                $key = $m.Groups[1].Value.Trim().ToLowerInvariant()
                if (-not $headingCounts.ContainsKey($key)) { $headingCounts[$key] = 0 }
                $headingCounts[$key]++
            }
            foreach ($k in $headingCounts.Keys) {
                if ($headingCounts[$k] -gt 1) {
                    $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="duplicate heading"; Detail=$k }
                }
            }
        }

        $paragraphs = ($content -split "\r?\n\s*\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 20 }
        $paraCounts = @{}
        foreach ($p in $paragraphs) {
            $key = $p.ToLowerInvariant()
            if (-not $paraCounts.ContainsKey($key)) { $paraCounts[$key] = 0 }
            $paraCounts[$key]++
        }
        foreach ($k in $paraCounts.Keys) {
            if ($paraCounts[$k] -gt 1) {
                $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="duplicate paragraph"; Detail="Repeated paragraph detected" }
                break
            }
        }

        foreach ($pair in $contradictionPairs) {
            if ($content -match [regex]::Escape($pair[0]) -and $content -match [regex]::Escape($pair[1])) {
                $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="possible contradiction"; Detail="Contains '$($pair[0])' and '$($pair[1])'" }
            }
        }

        if ($content -match "\bTODO\b|\bTBD\b") {
            $report += [pscustomobject]@{ Type="Markdown"; File=$md.FullName; Issue="incomplete content"; Detail="TODO/TBD marker found" }
        }
    }

    foreach ($script in $scriptFiles) {
        $content = Get-Content $script.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $commentLines = @()
        $lines = $content -split "\r?\n"
        $inBlock = $false

        foreach ($line in $lines) {
            if ($line -match "<#(.*)#>") {
                $commentLines += $Matches[1].Trim()
                continue
            }
            if ($line -match "^\s*<#") { $inBlock = $true; continue }
            if ($line -match "#>") { $inBlock = $false; continue }

            if ($inBlock) {
                $commentLines += $line.Trim()
                continue
            }

            if ($line -match "^\s*#(.*)") {
                $commentLines += $Matches[1].Trim()
            }
        }

        $commentLines = $commentLines | Where-Object { $_ -and $_.Length -gt 0 }
        if ($commentLines.Count -eq 0) { continue }

        $commentCounts = @{}
        foreach ($c in $commentLines) {
            $key = $c.ToLowerInvariant()
            if (-not $commentCounts.ContainsKey($key)) { $commentCounts[$key] = 0 }
            $commentCounts[$key]++
        }
        foreach ($k in $commentCounts.Keys) {
            if ($commentCounts[$k] -gt 2) {
                $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="duplicate comment"; Detail=$k }
            }
        }

        foreach ($pair in $contradictionPairs) {
            if ($commentLines -match [regex]::Escape($pair[0]) -and $commentLines -match [regex]::Escape($pair[1])) {
                $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="possible contradiction"; Detail="Contains '$($pair[0])' and '$($pair[1])'" }
            }
        }

        foreach ($line in $commentLines) {
            if ($line -match "[A-Z]:\\[^\s]+") {
                $path = $Matches[0]
                if (-not (Test-Path $path)) {
                    $report += [pscustomobject]@{ Type="Comment"; File=$script.FullName; Issue="path not found"; Detail=$path }
                }
            }
        }
    }

    # Regression tests: PowerShell parsing and known parser pitfalls
    $parseTargets = @(
        @{ Name = "Windows PowerShell 5.1"; Command = "powershell.exe" },
        @{ Name = "PowerShell 7"; Command = "pwsh" }
    )

    $parseScript = @'
$tokens=$null
$errors=$null
$text=[System.IO.File]::ReadAllText('<PATH>',[System.Text.Encoding]::UTF8)
[System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors) { $errors | ForEach-Object { Write-Output $_.Message }; exit 1 } else { Write-Output "Parse OK" }
'@
    $parseScript = $parseScript -replace '<PATH>', $MyInvocation.MyCommand.Path

    foreach ($target in $parseTargets) {
        if (Get-Command $target.Command -ErrorAction SilentlyContinue) {
            $output = & $target.Command -NoProfile -Command $parseScript 2>&1
            if ($LASTEXITCODE -ne 0) {
                $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="$($target.Name) parse failed"; Detail=($output -join " ") }
            }
        } else {
            $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="$($target.Name) not found"; Detail="Command '$($target.Command)' is unavailable" }
        }
    }

    $selfContent = Get-Content $MyInvocation.MyCommand.Path -Raw -ErrorAction SilentlyContinue
    if ($selfContent -and ($selfContent -match '\$\w+:\$')) {
        $report += [pscustomobject]@{ Type="Regression"; File=$MyInvocation.MyCommand.Path; Issue="Potential parser risk"; Detail='Found $var:$ pattern in string interpolation' }
    }

    $logDir = Join-Path $root "logs"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $logDir "testing-app-testing-$timestamp.txt"
    $report | Format-Table -AutoSize | Out-String | Set-Content -Path $logPath

    Write-AppLog "Test-AppTesting completed with $($report.Count) findings. Report: $logPath" "Info"
    return [pscustomobject]@{
        ReportPath = $logPath
        Findings   = $report
        Count      = $report.Count
    }
}

function Get-ScriptSafetyScore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $patterns = @(
        @{ Name = "Invoke-Expression"; Regex = "\bInvoke-Expression\b|\biex\b"; Penalty = 12 },
        @{ Name = "Download and Execute"; Regex = "(Invoke-WebRequest|iwr|New-Object\s+Net.WebClient).*?(DownloadString|DownloadFile)"; Penalty = 18 },
        @{ Name = "Execution Policy Change"; Regex = "\bSet-ExecutionPolicy\b"; Penalty = 8 },
        @{ Name = "Recursive Force Delete"; Regex = "\bRemove-Item\b.*-Recurse.*-Force"; Penalty = 10 },
        @{ Name = "RunAs Elevation"; Regex = "\bStart-Process\b.*-Verb\s+RunAs"; Penalty = 8 },
        @{ Name = "Scheduled Task"; Regex = "\bRegister-ScheduledTask\b|\bschtasks\b"; Penalty = 10 },
        @{ Name = "Security Settings"; Regex = "\b(Add|Set)-MpPreference\b"; Penalty = 8 },
        @{ Name = "Service Control"; Regex = "\bStop-Service\b|\bDisable-Service\b"; Penalty = 8 },
        @{ Name = "System Power"; Regex = "\bRestart-Computer\b|\bStop-Computer\b"; Penalty = 10 },
        @{ Name = "Registry Edit"; Regex = "\breg\s+(add|delete)\b|\bNew-ItemProperty\b|\bSet-ItemProperty\b"; Penalty = 10 }
    )

    $secretPatterns = @(
        @{ Name = "password"; Regex = "(?i)password\s*[:=]"; Penalty = 20 },
        @{ Name = "apikey"; Regex = "(?i)apikey\s*[:=]"; Penalty = 20 },
        @{ Name = "api_key"; Regex = "(?i)api_key\s*[:=]"; Penalty = 20 },
        @{ Name = "secret"; Regex = "(?i)secret\s*[:=]"; Penalty = 20 },
        @{ Name = "token"; Regex = "(?i)token\s*[:=]"; Penalty = 20 }
    )

    $findings = @()
    $penalty = 0

    foreach ($p in $patterns) {
        if ($Content -match $p.Regex) {
            $findings += $p.Name
            $penalty += $p.Penalty
        }
    }

    foreach ($sp in $secretPatterns) {
        if ($Content -match $sp.Regex) {
            $findings += "Possible secret: $($sp.Name)"
            $penalty += $sp.Penalty
        }
    }

    $score = 100 - $penalty
    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    return [pscustomobject]@{
        Score    = $score
        Findings = $findings
    }
}

function Test-ScriptSafetySecOp {
    $root = (Get-Location).Path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $report = @()

    $scriptFiles = Get-ChildItem -Path $root -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue
    foreach ($script in $scriptFiles) {
        $content = Get-Content $script.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $scoreInfo = Get-ScriptSafetyScore -Content $content
        $score = $scoreInfo.Score
        $findings = $scoreInfo.Findings
        $report += [pscustomobject]@{ Type="Safety"; File=$script.FullName; Issue="Safety Score"; Detail=$score }
        Write-AppLog "Script safety score: $score | $($script.FullName)" "Info"

        foreach ($finding in $findings) {
            $report += [pscustomobject]@{ Type="Safety"; File=$script.FullName; Issue=$finding; Detail="Pattern matched" }
        }
    }

    $logDir = Join-Path $root "logs"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $logDir "scrutiny-safety-secops-$timestamp.txt"
    $report | Format-Table -AutoSize | Out-String | Set-Content -Path $logPath

    Write-AppLog "Test-ScriptSafetySecOp completed with $($report.Count) findings. Report: $logPath" "Info"
    return [pscustomobject]@{
        ReportPath = $logPath
        Findings   = $report
        Count      = $report.Count
    }
}

# ==================== GUI FUNCTIONS ====================
function New-GUI {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not $PSCmdlet.ShouldProcess("Main GUI", "Create and show")) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    # Create main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PowerShell Script Launcher"
    $form.Size = New-Object System.Drawing.Size([int]600, [int]500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    
    # ==================== MENU STRIP ====================
    $menuStrip = New-Object System.Windows.Forms.MenuStrip
    $form.Controls.Add($menuStrip)
    
    # File Menu
    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $fileMenu.Text = "&File"
    
    # Settings submenu
    $settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $settingsMenu.Text = "&Settings"
    
    $pathSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $pathSettingsItem.Text = "&Configure Paths..."
    $pathSettingsItem.Add_Click({
        Write-AppLog "User selected File > Settings > Configure Paths" "Event"
        Show-PathSettingsGUI
    })
    $settingsMenu.DropDownItems.Add($pathSettingsItem) | Out-Null
    
    $scriptFoldersItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $scriptFoldersItem.Text = "&Script Folders..."
    $scriptFoldersItem.Add_Click({
        Write-AppLog "User selected File > Settings > Script Folders" "Event"
        Show-ScriptFolderSettingsGUI
    })
    $settingsMenu.DropDownItems.Add($scriptFoldersItem) | Out-Null
    
    $fileMenu.DropDownItems.Add($settingsMenu) | Out-Null
    
    # Separator
    $fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "E&xit"
    $exitItem.ShortcutKeys = "Control+Q"
    $exitItem.Add_Click({
        Write-AppLog "User selected File > Exit" "Event"
        $form.Close()
    })
    $fileMenu.DropDownItems.Add($exitItem) | Out-Null
    
    $menuStrip.Items.Add($fileMenu) | Out-Null

    # Tests Menu
    $testsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $testsMenu.Text = "&Tests"

    $versionCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $versionCheckItem.Text = "&Version Check"
    $versionCheckItem.Add_Click({
        Write-AppLog "User selected Tests > Version Check" "Event"
        Test-VersionTag
        [System.Windows.Forms.MessageBox]::Show("Version check completed. See diff XML file if any differences.", "Version Check")
    })
    $testsMenu.DropDownItems.Add($versionCheckItem) | Out-Null

    $networkDiagItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $networkDiagItem.Text = "&Network Diagnostics"
    $networkDiagItem.Add_Click({
        Show-NetworkDiagnosticsDialog
    })
    $testsMenu.DropDownItems.Add($networkDiagItem) | Out-Null

    $testsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $diskCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $diskCheckItem.Text = "&Disk Check"
    $diskCheckItem.Add_Click({
        Show-DiskCheckDialog
    })
    $testsMenu.DropDownItems.Add($diskCheckItem) | Out-Null

    $privacyCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $privacyCheckItem.Text = "&Privacy Check"
    $privacyCheckItem.Add_Click({
        Show-PrivacyCheck
    })
    $testsMenu.DropDownItems.Add($privacyCheckItem) | Out-Null

    $systemCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $systemCheckItem.Text = "&System Check"
    $systemCheckItem.Add_Click({
        Show-SystemCheck
    })
    $testsMenu.DropDownItems.Add($systemCheckItem) | Out-Null

    $testsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $appTestingItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $appTestingItem.Text = "App Testing (Docs && Comments)"
    $appTestingItem.Add_Click({
        Write-AppLog "User selected Tests > App Testing" "Event"
        $results = Test-AppTesting
        $count = if ($results) { $results.Count } else { 0 }
        if ($results -and $null -ne $results.Count) { $count = $results.Count }
        [System.Windows.Forms.MessageBox]::Show("App Testing completed. Findings: $count. Opening latest report...", "App Testing") | Out-Null
        if ($results.ReportPath -and (Test-Path $results.ReportPath)) { Invoke-Item $results.ReportPath }
    })
    $testsMenu.DropDownItems.Add($appTestingItem) | Out-Null

    $scrutinyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $scrutinyItem.Text = "Scrutiny Safety && SecOps"
    $scrutinyItem.Add_Click({
        Write-AppLog "User selected Tests > Scrutiny Safety and SecOps" "Event"
        $results = Test-ScriptSafetySecOp
        $count = if ($results) { $results.Count } else { 0 }
        if ($results -and $null -ne $results.Count) { $count = $results.Count }
        [System.Windows.Forms.MessageBox]::Show("Scrutiny scan completed. Findings: $count. Opening latest report...", "Scrutiny Safety and SecOps") | Out-Null
        if ($results.ReportPath -and (Test-Path $results.ReportPath)) { Invoke-Item $results.ReportPath }
    })
    $testsMenu.DropDownItems.Add($scrutinyItem) | Out-Null

    $menuStrip.Items.Add($testsMenu) | Out-Null

    # Links Menu
    $linksMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $linksMenu.Text = "&Links"
    Initialize-LinksConfigFile
    Build-LinksMenu -LinksMenu $linksMenu
    $menuStrip.Items.Add($linksMenu) | Out-Null

    # WinGets Menu
    $wingetsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetsMenu.Text = "&WinGets"

    $wingetAppsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetAppsItem.Text = "Installed Apps (&Grid View)"
    $wingetAppsItem.Add_Click({
        Show-WingetInstalledApp
    })
    $wingetsMenu.DropDownItems.Add($wingetAppsItem) | Out-Null

    $wingetCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetCheckItem.Text = "Detect Updates (&Check-Only)"
    $wingetCheckItem.Add_Click({
        Show-WingetUpgradeCheck
    })
    $wingetsMenu.DropDownItems.Add($wingetCheckItem) | Out-Null

    $wingetUpdateAllItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $wingetUpdateAllItem.Text = "Update All (Admin Options)"
    $wingetUpdateAllItem.Add_Click({
        Show-WingetUpdateAllDialog
    })
    $wingetsMenu.DropDownItems.Add($wingetUpdateAllItem) | Out-Null

    $menuStrip.Items.Add($wingetsMenu) | Out-Null
    
    # Tools Menu
    $toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $toolsMenu.Text = "&Tools"
    
    $viewConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewConfigItem.Text = "View &Config"
    $viewConfigItem.Add_Click({
        Write-AppLog "User selected Tools > View Config" "Event"
        if (Test-Path $configFile) {
            Write-AppLog "Opening config file: $configFile" "Debug"
            Invoke-Item $configFile
        }
        else {
            Write-AppLog "Config file not found at: $configFile" "Warning"
            [System.Windows.Forms.MessageBox]::Show("Config file not found. Run a script first.", "Info")
        }
    })
    $toolsMenu.DropDownItems.Add($viewConfigItem) | Out-Null
    
    $openLogsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openLogsItem.Text = "Open &Logs Directory"
    $openLogsItem.Add_Click({
        Write-AppLog "User selected Tools > Open Logs Directory" "Event"
        Write-AppLog "Opening logs directory: $logsDir" "Debug"
        Invoke-Item $logsDir
    })
    $toolsMenu.DropDownItems.Add($openLogsItem) | Out-Null
    
    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    
    $layoutItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $layoutItem.Text = "Scriptz n Portz N PowerShellD (Layout)"
    $layoutItem.Add_Click({
        Write-AppLog "User selected Tools > Display Layout" "Event"
        Show-GUILayout
    })
    $toolsMenu.DropDownItems.Add($layoutItem) | Out-Null
    
    $buttonMainItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $buttonMainItem.Text = "&Button Maintenance"
    $buttonMainItem.Add_Click({
        Write-AppLog "User selected Tools > Button Maintenance" "Event"
        [System.Windows.Forms.MessageBox]::Show(
            "Button Maintenance Tool`n`nFeature coming soon: Add/Edit/Delete custom buttons for scripts and applications.`n`nThis will allow you to manage your script launcher buttons from the GUI.",
            "Button Maintenance",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $toolsMenu.DropDownItems.Add($buttonMainItem) | Out-Null
    
    $networkDetailsItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $networkDetailsItem.Text = "&Network Details"
    $networkDetailsItem.Add_Click({
        Write-AppLog "User selected Tools > Network Details" "Event"
        [System.Windows.Forms.MessageBox]::Show(
            "Network Details Tool`n`nFeature coming soon: Display detailed network information including:`n- IPConfig details for LAN and WiFi`n- ARP tables`n- Tracert to 1.1.1.1`n- Ping times to DNS servers",
            "Network Details",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $toolsMenu.DropDownItems.Add($networkDetailsItem) | Out-Null
    
    $avpnItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $avpnItem.Text = "A&VPN Connection Tracker"
    $avpnItem.Add_Click({
        Write-AppLog "User selected Tools > AVPN Connection Tracker" "Event"
        Show-AVPNConnectionTracker -ConfigPath $avpnConfigFile -LogCallback { param($m, $l) Write-AppLog $m $l } -Owner $form
    })
    $toolsMenu.DropDownItems.Add($avpnItem) | Out-Null
    
    $menuStrip.Items.Add($toolsMenu) | Out-Null
    
    # Help Menu
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpMenu.Text = "&Help"
    
    $updateHelpItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $updateHelpItem.Text = "Update-&Help"
    $updateHelpItem.Add_Click({
        Show-UpdateHelp
    })
    $helpMenu.DropDownItems.Add($updateHelpItem) | Out-Null
    
    $helpIndexItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpIndexItem.Text = "PwShGUI App &Help (Webpage Index)"
    $helpIndexItem.Add_Click({
        Write-AppLog "User selected Help > PwShGUI App Help" "Event"
        $helpFile = Join-Path $PSScriptRoot "~README.md\PwShGUI-Help-Index.html"
        if (Test-Path $helpFile) {
            Start-Process $helpFile
        } else {
            [System.Windows.Forms.MessageBox]::Show("Help file not found: $helpFile","Error","OK",[System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $helpMenu.DropDownItems.Add($helpIndexItem) | Out-Null
    
    $packageItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $packageItem.Text = "&Package Workspace"
    $packageItem.Add_Click({
        Write-AppLog "User selected Help > Package Workspace" "Event"
        Export-WorkspacePackage
        [System.Windows.Forms.MessageBox]::Show("Workspace packaged.","Package","OK",[System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $helpMenu.DropDownItems.Add($packageItem) | Out-Null
    
    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    
    $aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutItem.Text = "&About"
    $aboutItem.Add_Click({
        Write-AppLog "User selected Help > About" "Event"
        [System.Windows.Forms.MessageBox]::Show(
            "Scriptz n Portz N PowerShellD v1.1.0`n`nA powerful GUI application for launching scripts with admin elevation support.`n`nComputer: $env:COMPUTERNAME`nUser: $env:USERNAME`nPowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)",
            "About",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $helpMenu.DropDownItems.Add($aboutItem) | Out-Null
    
    $menuStrip.Items.Add($helpMenu) | Out-Null
    
    # ==================== TITLE LABEL ====================
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Scriptz n Portz N PowerShellD"
    $titleLabel.Location = New-Object System.Drawing.Point([int]20, [int]40)
    $titleLabel.Size = New-Object System.Drawing.Size([int]560, [int]30)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)
    
    # ==================== BUTTONS ====================
    # Load button configuration from config file
    $buttonConfig = Get-ButtonConfiguration
    $buttonNames = $buttonConfig.Left
    $rightButtonNames = $buttonConfig.Right
    
    $buttonHeight = 50
    $buttonWidth = 260
    $spacing = 10
    $column1X = 30
    $column2X = 310
    $startY = 90
    
    # Add left column buttons (6 buttons, 3 per column)
    for ($i = 0; $i -lt $buttonNames.Count; $i++) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $buttonNames[$i].DisplayName
        $button.Size = New-Object System.Drawing.Size([int]$buttonWidth, [int]$buttonHeight)
        $button.Tag = $buttonNames[$i].ScriptName
        
        # Calculate position (left column - 3 buttons)
        $yPos = [int]($startY + ($i * ($buttonHeight + $spacing)))
        $button.Location = New-Object System.Drawing.Point([int]$column1X, $yPos)
        
        $button.Font = New-Object System.Drawing.Font("Arial", 10)
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        
        # Create click handler
        $button.Add_Click({
            $scriptName = $this.Tag
            $displayName = $this.Text
            
            Write-AppLog "Button clicked: $displayName ($scriptName)" "Event"
            Write-ScriptLog "Button clicked for execution" $scriptName "Event"
            
            # Get elevation preference with safety badge
            $scriptPath = Join-Path $scriptsDir "$scriptName.ps1"
            $shouldElevate = Show-ElevationPrompt -ScriptName $scriptName -ScriptPath $scriptPath
            
            # Invoke the script
            Invoke-ScriptWithElevation -ScriptName $scriptName -RunAsAdmin $shouldElevate
        })
        
        $form.Controls.Add($button)
    }
        # Add right column button (PWSH Quick App)
<#    if ($rightButtonNames.Count -gt 0) {
        $rightButton = New-Object System.Windows.Forms.Button
        $rightButton.Text = $rightButtonNames[0].DisplayName
        $rightButton.Size = New-Object System.Drawing.Size([int]$buttonWidth, [int]$buttonHeight)
        $rightButton.Tag = $rightButtonNames[0].ScriptPath
#>
# ADD RIGHT COLUMN BUTTONS (6 buttons)
    for ($j = 0; $j -lt $rightButtonNames.Count; $j++) {
        $rightButton = New-Object System.Windows.Forms.Button
        $rightButton.Text = $rightButtonNames[$j].DisplayName
        $rightButton.Size = New-Object System.Drawing.Size([int]$buttonWidth, [int]$buttonHeight)
        $rightButton.Tag = $rightButtonNames[$j].ScriptName

        # Calculate position (Right column - 3 buttons)
        $yPos = [int]($startY + ($j * ($buttonHeight + $spacing)))
        $rightButton.Location = New-Object System.Drawing.Point([int]$column2X, [int]$yPos)

        $rightButton.Font = New-Object System.Drawing.Font("Arial", 10)
        $rightButton.Cursor = [System.Windows.Forms.Cursors]::Hand
        
        # Create click handler for PWSH Quick App
        $rightButton.Add_Click({
            $scriptName = $this.Tag
            $displayName = $this.Text
            
            Write-AppLog "Button clicked: $displayName ($scriptName)" "Event"
            
            # Get elevation preference with safety badge
            $scriptPath = Join-Path $scriptsDir "$scriptName.ps1"
            $shouldElevate = Show-ElevationPrompt -ScriptName $scriptName -ScriptPath $scriptPath
            
            # Invoke the script
            Invoke-ScriptWithElevation -ScriptName $scriptName -RunAsAdmin $shouldElevate
        
        <#

        Write-AppLog "PWSH Quick App button clicked: $scriptPath" "Event"
        
        # Resolve the script path (handle ~ for home directory)
        $expandedPath = if ($scriptPath -like "~*") {
            Join-Path $env:USERPROFILE $scriptPath.Substring(1)
        }
        else {
            $scriptPath
        }
        
        # Check if file exists
        if (-not (Test-Path $expandedPath)) {
            Write-AppLog "PWSH Quick App script not found: $expandedPath" "Error"
            [System.Windows.Forms.MessageBox]::Show("Script not found: $expandedPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        
        Write-AppLog "Launching PWSH7 prompt with script: $expandedPath" "Info"
        
        try {
            # Launch pwsh in a new window with the script
            Start-Process -FilePath "pwsh" -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$expandedPath`"" -Wait:$false
            Write-AppLog "PWSH7 prompt launched successfully" "Success"
        }
        catch {
            Write-AppLog "Error launching PWSH7 prompt: $_" "Error"
            [System.Windows.Forms.MessageBox]::Show("Error launching PWSH7 prompt: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
             #>            
    })
   

    $form.Controls.Add($rightButton)
    }
    
    # ==================== STATUS BAR ====================
    # Left Status Label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Ready - Computer: $env:COMPUTERNAME | User: $env:USERNAME"
    $statusLabel.Location = New-Object System.Drawing.Point([int]0, [int]440)
    $statusLabel.Size = New-Object System.Drawing.Size([int]400, [int]20)
    $statusLabel.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $statusLabel.TextAlign = "MiddleLeft"
    $statusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $statusLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $statusLabel.Font = New-Object System.Drawing.Font("Arial", 8)
    $form.Controls.Add($statusLabel)
    
    # Right Status Label - Script Path
    $scriptPathLabel = New-Object System.Windows.Forms.Label
    $scriptPathLabel.Text = "Scripts: $scriptsDir"
    $scriptPathLabel.Location = New-Object System.Drawing.Point([int]400, [int]440)
    $scriptPathLabel.Size = New-Object System.Drawing.Size([int]200, [int]20)
    $scriptPathLabel.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $scriptPathLabel.TextAlign = "MiddleRight"
    $scriptPathLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $scriptPathLabel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
    $scriptPathLabel.Font = New-Object System.Drawing.Font("Arial", 8)
    $scriptPathLabel.ForeColor = [System.Drawing.Color]::DarkBlue
    $form.Controls.Add($scriptPathLabel)
    
    # Show the form
    Write-AppLog "Displaying GUI form window" "Event"
    $form.ShowDialog() | Out-Null
    Write-AppLog "GUI form closed by user" "Event"
}

# ==================== MAIN EXECUTION ====================
Write-AppLog "=====================================================================" "Event"
Write-AppLog "PowerShell GUI Application starting..." "Info"
Write-AppLog "Computer: $env:COMPUTERNAME | User: $env:USERNAME | PowerShell: $($PSVersionTable.PSVersion)" "Info"
Write-AppLog "=====================================================================" "Event"

# Phase 0: Validate and configure paths
Write-AppLog "Phase 0: Validating application paths..." "Event"
$pathsNeedValidation = $false

# Check if any required path is inaccessible
$requiredPaths = @($ConfigPath, $DefaultFolder, $TempFolder, $ReportFolder, $DownloadFolder)
foreach ($path in $requiredPaths) {
    if ($path) {
        $result = Test-PathReadWrite -Path $path
        if (-not $result.Readable -or -not $result.Writable) {
            $pathsNeedValidation = $true
            break
        }
    }
}

# If paths need validation or are not initialized, show the settings GUI
if ($pathsNeedValidation -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    Write-AppLog "Path validation required - showing configuration GUI" "Warning"
    Show-PathSettingsGUI
} else {
    Write-AppLog "All application paths are accessible and configured correctly" "Success"
}

# Initialize script folders config if it doesn't exist
$scriptFoldersConfigPath = Join-Path $configDir "pwsh-scriptfolders-config.json"
if (-not (Test-Path $scriptFoldersConfigPath)) {
    $defaultConfig = @{
        metadata = @{
            version = "1.0.0"
            description = "Script folder paths configuration for PowerShell GUI Application"
            lastModified = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            format = "JSON"
        }
        customScriptFolders = @(
            @{
                path = (Join-Path $scriptsDir "QUICK-APP")
                label = "QUICK-APP Scripts"
                enabled = $true
                addedDate = (Get-Date -Format "yyyy-MM-dd")
            }
        )
    }
    Save-ScriptFoldersConfig -Config $defaultConfig
    Write-AppLog "Script folders config initialized" "Success"
}

# ensure config exists
if (-not (Test-Path $configFile)) { Initialize-ConfigFile }

Write-AppLog "Startup mode selected: $StartupMode" "Event"

# Parse version values once for display and downstream phases
$versionInfo = Get-VersionInfo
$major = $versionInfo.Major
$minor = $versionInfo.Minor
$build = $versionInfo.Build
$diffFile = Join-Path (Get-Location).Path "pwshGUI-v-$major$minor-versionbuild~DIFFS.xml"

$hasIssues = $false
$issueDetails = @()

if ($StartupMode -eq 'slow_snr') {
    # Phase 1: Check version tags BEFORE any auto-increment
    Write-AppLog "Phase 1: Checking version tag consistency..." "Event"
    Test-VersionTag

    if (Test-Path $diffFile) {
        [xml]$diffXml = Get-Content $diffFile
        $folders = $diffXml.SelectNodes('//Folder')
        if ($folders.Count -gt 0) {
            $hasIssues = $true
            foreach($folder in $folders) {
                $files = $folder.SelectNodes('File')
                foreach($file in $files) {
                    $issue = "$($file.GetAttribute('name')) - $($file.GetAttribute('issue'))"
                    if ($file.HasAttribute('found')) {
                        $issue += " (found: $($file.GetAttribute('found')), expected: $($file.GetAttribute('expected')))"
                    }
                    $issueDetails += $issue
                }
            }
        }
    }

    # Phase 2: Display results and prompt for auto-increment
    Write-Information "" -InformationAction Continue
    Write-Information "=====================================================================" -InformationAction Continue

    if (-not $hasIssues) {
        Write-Information "ALL FILES MATCH VERSION-TAGS" -InformationAction Continue
        Write-Information "Current Version: $major.$minor.$build" -InformationAction Continue
        Write-Information "All files are tagged properly - no auto-increment needed." -InformationAction Continue
        Write-Information "=====================================================================" -InformationAction Continue
        Write-Information "" -InformationAction Continue
    } else {
        Write-Information "VERSION-TAGS FOUND THAT DO NOT MATCH" -InformationAction Continue
        Write-Information "Current Version: $major.$minor.$build" -InformationAction Continue
        Write-Information "" -InformationAction Continue
        Write-Information "Mismatches detected:" -InformationAction Continue
        foreach($detail in $issueDetails) {
            Write-Information "  - $detail" -InformationAction Continue
        }
        Write-Information "" -InformationAction Continue
        Write-Information "=====================================================================" -InformationAction Continue
        Write-Information "" -InformationAction Continue
        Write-Information "Type 'AA' and press ENTER to allow Auto-Increment of build number (or just press ENTER to skip):" -InformationAction Continue
        Write-Information "Response: " -InformationAction Continue

        $userInput = Read-Host

        if ($userInput -eq "AA") {
            Write-Information "" -InformationAction Continue
            Write-Information "Auto-Increment AUTHORIZED by user" -InformationAction Continue
            Write-AppLog "User authorized auto-increment" "Event"
            Update-VersionBuild -Auto
            Write-Information "Build number incremented to: $(Get-ConfigSubValue 'Version/Build')" -InformationAction Continue
            Write-AppLog "Updating version tags after increment..." "Event"
            Update-VersionTag
        } else {
            Write-Information "" -InformationAction Continue
            Write-Information "BYPASSING Build mismatch as no Auto-Increment Allow Action from user" -InformationAction Continue
            Write-AppLog "User skipped auto-increment" "Event"
        }
        Write-Information "" -InformationAction Continue
    }
} else {
    Write-AppLog "Fast startup mode: skipping Phase 1 version consistency scan and auto-increment prompt" "Info"
}

# Phase 3: Generate manifest regardless of version check results
Write-AppLog "Generating build manifest..." "Event"
New-BuildManifest

# Phase 4: Display system information
$rootPath = (Get-Location).Path
$scriptsPath = Join-Path $rootPath "scripts"
$versionInfo = Get-VersionInfo
$configVersion = "$($versionInfo.Major).$($versionInfo.Minor).$($versionInfo.Build)"
$timezone = (Get-TimeZone).DisplayName
$currentDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Information "" -InformationAction Continue
Write-Information "=== END SYSTEM INFORMATION ===" -InformationAction Continue
Write-Information "Root Path:              $rootPath" -InformationAction Continue
Write-Information "Scripts:                $scriptsPath" -InformationAction Continue
Write-Information "Build from Config:      $configVersion" -InformationAction Continue
Write-Information "Current Date/Time:      $currentDateTime" -InformationAction Continue
Write-Information "Time Zone:              $timezone" -InformationAction Continue
Write-Information "=====================================================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-AppLog "Creating and displaying GUI..." "Event"
try {
    # Create the GUI
    New-GUI
    Write-AppLog "GUI closed successfully" "Success"
}
catch {
    Write-AppLog "Error in GUI creation: $_" "Error"
    Write-AppLog "Stack Trace: $($_.ScriptStackTrace)" "Error"
}

Write-AppLog "=====================================================================" "Event"
Write-AppLog "PowerShell GUI Application closed" "Info"
Write-AppLog "=====================================================================" "Event"

# Flush any remaining log entries
Flush-LogBuffer















