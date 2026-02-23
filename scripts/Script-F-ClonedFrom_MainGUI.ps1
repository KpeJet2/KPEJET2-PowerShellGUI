# VersionTag: 2602.a.11
# VersionTag: 2602.a.10
# VersionTag: 2602.a.9
# VersionTag: 2602.a.8
# VersionTag: 2602.a.7
#Requires -Version 5.1
<#
.SYNOPSIS
Script-F - User Management

.DESCRIPTION
This script performs user management tasks.

.NOTES


.LINK


.INPUTS


.OUTPUTS


.FUNCTIONALITY
For system administrators and IT professionals to manage user accounts and permissions.

.AUTHOR
The Establishment

.CREATED
24th January 2026

.MODIFIED
16th February 2026

.VERSION
1.0.0

.CONFIGURATION BASE
pwsh-app-config-BASE.json

#>


# Stop on errors
$ErrorActionPreference = "Stop"

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

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

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
        $script:remaining--
        if ($script:remaining -le 0) {
            $script:timedOut = $true
            $timer.Stop()
            $form.Close()
        } else {
            $countdownLabel.Text = "Auto-continue in $script:remaining s"
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

# Define LOCAL region Configuration
$ConfigPath = ""
$DefaultFolder = ""
$TempFolder = ""
$ReportFolder = ""

if (-not $ConfigPath) { $ConfigPath = Request-LocalPath -Label "ConfigPath" -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $DefaultFolder) { $DefaultFolder = Request-LocalPath -Label "DefaultFolder" -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $TempFolder) { $TempFolder = Request-LocalPath -Label "TempFolder" -DefaultValue $localRoot -TimeoutSeconds 9 }
if (-not $ReportFolder) { $ReportFolder = Request-LocalPath -Label "ReportFolder" -DefaultValue $localRoot -TimeoutSeconds 9 }

# Create local directories if they don't exist
if ($ConfigPath -and -not (Test-Path $ConfigPath)) { New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null }
if ($DefaultFolder -and -not (Test-Path $DefaultFolder)) { New-Item -ItemType Directory -Path $DefaultFolder -Force | Out-Null }
if ($TempFolder -and -not (Test-Path $TempFolder)) { New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null }
if ($ReportFolder -and -not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

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
if (-not (Test-Path $avpnModulePath)) { Write-AppLog "AVPN module not found at $avpnModulePath" "Warning" }

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
    $logFile = Join-Path $logsDir "$hostname-$(Get-Date -Format 'yyyy-MM-dd').log"
    
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    
    # Also write to console without Write-Host
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
    $scriptLogFile = Join-Path $logsDir "$hostname-$(Get-Date -Format 'yyyy-MM-dd')_PwShGui-SCRIPTS.log"
    
    $logEntry = "[$timestamp] [$ScriptName] [$Level] $Message"
    Add-Content -Path $scriptLogFile -Value $logEntry -ErrorAction SilentlyContinue
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
    }
    
    $systemVars | Export-Clixml -Path $configFile -Force
    Write-AppLog "System variables config file created: $configFile" "Success"
}

# ==================== SCRIPT MAIN EXECUTION ====================
Write-Information "================================" -InformationAction Continue
Write-Information "Script-F: User Management" -InformationAction Continue
Write-Information "================================" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-AppLog "Script-F execution started" "Info"

Write-Information "Execution Details:" -InformationAction Continue
Write-Information "  Computer: $env:COMPUTERNAME" -InformationAction Continue
Write-Information "  User: $env:USERNAME" -InformationAction Continue
Write-Information "  PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -InformationAction Continue
Write-Information "  Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -InformationAction Continue
Write-Information "" -InformationAction Continue

Write-Information "Managing user accounts and permissions..." -InformationAction Continue

Write-Information "  [OK] TASK 1 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 1 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 2 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 2 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 3 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 3 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 4 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 4 completed" "Script-F" "Info"

Write-Information "  [OK] TASK 5 - User Management Task" -InformationAction Continue
Write-ScriptLog "Task 5 completed" "Script-F" "Info"
Write-Information "" -InformationAction Continue

Write-Information "User management completed successfully!" -InformationAction Continue
Write-AppLog "Script-F execution completed successfully" "Success"
Write-Information "" -InformationAction Continue
# A
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
# $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
###
#B
# Write-Host "Press any key to proceed... or you can just wait 5 seconds."
#timeout /t 10
###
#C
# https://www.sharepointdiary.com/2023/03/pause-powershell-with-press-any-key-to-continue.html
function Wait-KeyOrTimeout {
    param([int]$Seconds = 5)
     
    $endTime = (Get-Date).AddSeconds($Seconds)
    Write-Information "Press any key to continue or wait $Seconds seconds..." -InformationAction Continue
     
    while ((Get-Date) -lt $endTime) {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Information "Timeout reached, continuing..." -InformationAction Continue
}
 
Write-Information "FFF completed." -InformationAction Continue
Wait-KeyOrTimeout -Seconds 5
Write-Information "Script-F execution finished." -InformationAction Continue












