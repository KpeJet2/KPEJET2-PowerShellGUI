# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v23  2026-03-28 09:15  Fix Join-Path 3-arg calls for PS 5.1 compatibility
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 3 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI Core Utility Module -- shared logging, lifecycle, and helper functions.

.DESCRIPTION
    Centralises functions previously duplicated across Main-GUI.ps1 and payload
    scripts (Write-AppLog, Write-ScriptLog, Export-LogBuffer, Wait-KeyOrTimeout,
    Request-LocalPath).  Also provides new lifecycle helpers: session-lock
    management, crash recovery, and log rotation.

    Import this module early in every script:
        Import-Module (Join-Path $modulesDir 'PwShGUICore.psm1') -Force

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th March 2026
    Modified : 4th March 2026
    Config   : config\system-variables.xml

.CONFIGURATION BASE
    config\pwsh-app-config-BASE.json

.LINK
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
#>

# ========================== MODULE-SCOPED STATE ==========================
# Log buffer shared across all callers in this session.
# When Main-GUI.ps1 imports this module, it inherits these variables.
$script:_LogBuffer     = [System.Collections.Generic.List[hashtable]]::new()
$script:_LogBufferSize = 10          # flush every N entries

# Resolved once per session -- callers may override via Set-CoreLogPath.
$script:_CoreLogsDir   = $null       # set by Initialize-CorePaths or caller

# Session lock
$script:_LockFilePath  = $null       # set by Initialize-CorePaths or caller

# Log level filtering -- only messages at or above _MinLogLevel are written.
# Levels: Debug(0) < Info(1) < Warning(2) < Error(3) < Critical(4) < Audit(5)
$script:_LogLevelOrder = @{ Debug=0; Info=1; Warning=2; Error=3; Critical=4; Audit=5 }
$script:_MinLogLevel   = 'Info'   # suppress Debug-level entries by default

# ========================== CENTRALISED PATH REGISTRY ==========================
# Single lookup table for all project directories and key files.
# Populated by Initialize-CorePaths; read via Get-ProjectPath.
$script:_PathRegistry = @{}

# ========================== PATH INITIALISATION ==========================
function Initialize-CorePaths {
    <#
    .SYNOPSIS  Set the module-wide paths used by logging, lock files, and rotation.
    .DESCRIPTION
        Must be called once after importing the module so that Write-AppLog,
        Write-SessionLock, Invoke-LogRotation, etc. know where to operate.
        Also populates the centralised path registry for Get-ProjectPath.
    .PARAMETER ScriptDir  Root of the PowerShellGUI workspace.
    .PARAMETER LogsDir    Override logs directory (defaults to $ScriptDir\logs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptDir,

        [string]$LogsDir
    )

    if (-not $LogsDir) { $LogsDir = Join-Path $ScriptDir 'logs' }

    $script:_CoreLogsDir  = $LogsDir
    $script:_LockFilePath = Join-Path $ScriptDir '.pwshgui-session.lock'

    # Build centralised path registry
    # Resolve config and modules directories first for nested joins (PS 5.1 compat)
    $cfgDir = Join-Path $ScriptDir 'config'
    $modDir = Join-Path $ScriptDir 'modules'
    $rdmDir = Join-Path $ScriptDir '~README.md'

    $script:_PathRegistry = @{
        # Directories
        Root          = $ScriptDir
        Config        = $cfgDir
        Modules       = $modDir
        Scripts       = Join-Path $ScriptDir 'scripts'
        Logs          = $LogsDir
        LogsArchive   = Join-Path $LogsDir   'archive'
        Reports       = Join-Path $ScriptDir '~REPORTS'
        Temp          = Join-Path $ScriptDir 'temp'
        Downloads     = Join-Path $ScriptDir '~DOWNLOADS'
        Todo          = Join-Path $ScriptDir 'todo'
        Checkpoints   = Join-Path $ScriptDir 'checkpoints'
        Tests         = Join-Path $ScriptDir 'tests'
        Pki           = Join-Path $ScriptDir 'pki'
        SinRegistry   = Join-Path $ScriptDir 'sin_registry'
        Readme        = $rdmDir
        UPM           = Join-Path $ScriptDir 'UPM'
        Agents        = Join-Path $ScriptDir 'agents'
        History       = Join-Path $ScriptDir '.history'
        # Key config files (nested Join-Path for PS 5.1 compatibility)
        SystemVarsXml = Join-Path $cfgDir 'system-variables.xml'
        LinksXml      = Join-Path $cfgDir 'links.xml'
        AppConfigJson = Join-Path $cfgDir 'pwsh-app-config-BASE.json'
        PrereqJson    = Join-Path $cfgDir 'prerequisites-baseline.json'
        SascConfig    = Join-Path $cfgDir 'sasc-vault-config.json'
        AvpnDevices   = Join-Path $cfgDir 'AVPN-devices.json'
        ScriptFolders = Join-Path $cfgDir 'pwsh-scriptfolders-config.json'
        # Key module files
        CoreModule    = Join-Path $modDir 'PwShGUICore.psm1'
        TrayHostModule = Join-Path $modDir 'PwShGUI-TrayHost.psm1'
        SascModule    = Join-Path $modDir 'AssistedSASC.psm1'
        SascAdapters  = Join-Path $modDir 'SASC-Adapters.psm1'
        AvpnModule    = Join-Path $modDir 'AVPN-Tracker.psm1'
        UpmModule     = Join-Path $modDir 'UserProfileManager.psm1'
        IssueModule   = Join-Path $modDir 'PwShGUI_AutoIssueFinder.psm1'
        HelpModule    = Join-Path $modDir 'PwSh-HelpFilesUpdateSource-ReR.psm1'
        # Templates / standards
        Manifest      = Join-Path $rdmDir 'FILES-MANIFEST.md'
        HelpIndex     = Join-Path $rdmDir 'PwShGUI-Help-Index.html'
        LockFile      = Join-Path $ScriptDir '.pwshgui-session.lock'
    }

    # Ensure archive sub-directory exists for log rotation
    $archiveDir = $script:_PathRegistry['LogsArchive']
    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }
}

function Get-ProjectPath {
    <#
    .SYNOPSIS  Return a path from the centralised registry.
    .PARAMETER Key  Registry key (e.g. 'Config', 'Logs', 'SascModule').
    .OUTPUTS   [string] Absolute path, or $null if key not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    if ($script:_PathRegistry.Count -eq 0) {
        Write-AppLog -Message '' -Level Warning
        return $null
    }
    if ($script:_PathRegistry.ContainsKey($Key)) {
        return $script:_PathRegistry[$Key]
    }
    Write-AppLog -Message "PwShGUICore: Unknown path key '$Key'. Valid keys: $($script:_PathRegistry.Keys -join ', ')" -Level Warning
    return $null
}

function Get-AllProjectPaths {
    <#
    .SYNOPSIS  Return the full path registry hashtable (read-only copy).
    #>
    [CmdletBinding()]
    param()
    return $script:_PathRegistry.Clone()
}

# ========================== LOGGING FUNCTIONS ==========================
function Write-AppLog {
    <#
    .SYNOPSIS  Buffered application-level log writer.
    .PARAMETER Message   The log message text.
    .PARAMETER Level     Severity -- Debug, Info, Warning, Error, Critical, Audit.
    .PARAMETER LogPath   Optional override for the log file path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info',

        [string]$LogPath
    )

    # Filter by minimum log level -- skip entries below threshold (e.g. Debug when min is Info)
    if ($script:_LogLevelOrder[$Level] -lt $script:_LogLevelOrder[$script:_MinLogLevel]) { return }

    $timestamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $timestampDate = Get-Date -Format 'yyyy-MM-dd'
    $hostname      = $env:COMPUTERNAME

    if (-not $LogPath) {
        if ($script:_CoreLogsDir) {
            $LogPath = Join-Path $script:_CoreLogsDir "$hostname-$timestampDate.log"
        } else {
            # Fallback -- write next to calling script
            $LogPath = Join-Path (Get-Location).Path "$hostname-$timestampDate.log"
        }
    }

    $logEntry = "[$timestamp] [$Level] $Message"

    # Buffer the entry
    $script:_LogBuffer.Add(@{ File = $LogPath; Content = $logEntry })

    if ($script:_LogBuffer.Count -ge $script:_LogBufferSize) {
        Export-LogBuffer
    }

    # Console echo
    switch ($Level) {
        'Warning'  { Write-Warning $logEntry }
        'Error'    { Write-Error $logEntry -ErrorAction Continue }
        'Critical' { Write-Error $logEntry -ErrorAction Continue }
        default    { Write-Information $logEntry -InformationAction Continue }
    }
}

function Set-LogMinLevel {
    <#
    .SYNOPSIS  Set the minimum log severity level for Write-AppLog filtering.
    .DESCRIPTION
        Any Write-AppLog call with a Level below this threshold is silently
        discarded. Useful to suppress Debug noise in production while keeping
        it available during troubleshooting.
    .PARAMETER Level  Minimum severity: Debug, Info, Warning, Error, Critical, or Audit.
    .EXAMPLE
        Set-LogMinLevel -Level 'Info'   # default; suppress Debug entries
        Set-LogMinLevel -Level 'Debug'  # emit all entries (troubleshooting mode)
        Set-LogMinLevel -Level 'Warning' # suppress Info + Debug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level
    )
    $script:_MinLogLevel = $Level
}

function Get-LogMinLevel {
    <#
    .SYNOPSIS  Return the current minimum log level filter setting.
    #>
    [CmdletBinding()]
    param()
    return $script:_MinLogLevel
}

function Write-ErrorReport {
    <#
    .SYNOPSIS  Centralised error reporter -- logs, formats, and optionally rethrows.
    .DESCRIPTION
        Captures full exception detail (message, type, script position) into
        a structured log entry via Write-AppLog, then optionally rethrows.
        Reduces boilerplate in catch blocks across the project.
    .PARAMETER ErrorRecord  The $_ ErrorRecord from a catch block.
    .PARAMETER Context      Short label for where the error occurred (e.g. 'WAN-IP-Lookup').
    .PARAMETER Rethrow      If set, rethrows the original exception after logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [string]$Context = 'Unspecified',

        [switch]$Rethrow
    )

    $ex  = $ErrorRecord.Exception
    $pos = $ErrorRecord.InvocationInfo.PositionMessage
    $msg = "[$Context] $($ex.GetType().Name): $($ex.Message)"
    if ($pos) { $msg += " -- $pos" }

    Write-AppLog $msg 'Error'

    if ($Rethrow) { throw $ErrorRecord }
}

function Write-ScriptLog {
    <#
    .SYNOPSIS  Buffered script-level log writer (prefixes with script name).
    .PARAMETER Message     The log message text.
    .PARAMETER ScriptName  Name of the calling script.
    .PARAMETER Level       Severity -- Debug, Info, Warning, Error, Critical, Audit.
    .PARAMETER LogPath     Optional override for the log file path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$ScriptName,

        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info',

        [string]$LogPath
    )

    $timestamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $timestampDate = Get-Date -Format 'yyyy-MM-dd'
    $hostname      = $env:COMPUTERNAME

    if (-not $LogPath) {
        if ($script:_CoreLogsDir) {
            $LogPath = Join-Path $script:_CoreLogsDir "${hostname}-${timestampDate}_PwShGui-SCRIPTS.log"
        } else {
            $LogPath = Join-Path (Get-Location).Path "${hostname}-${timestampDate}_PwShGui-SCRIPTS.log"
        }
    }

    $logEntry = "[$timestamp] [$ScriptName] [$Level] $Message"

    $script:_LogBuffer.Add(@{ File = $LogPath; Content = $logEntry })

    if ($script:_LogBuffer.Count -ge $script:_LogBufferSize) {
        Export-LogBuffer
    }
}

function Export-LogBuffer {
    <#
    .SYNOPSIS  Flush all buffered log entries to their respective files.
    #>
    [CmdletBinding()]
    param()

    if ($script:_LogBuffer.Count -eq 0) { return }

    $grouped = $script:_LogBuffer | Group-Object -Property File

    foreach ($group in $grouped) {
        $entries = $group.Group | ForEach-Object { $_.Content }
        try {
            $entries | Add-Content -Path $group.Name -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            Write-AppLog -Message "PwShGUICore: Failed to write log to $($group.Name): $_" -Level Warning
        }
    }

    $script:_LogBuffer = [System.Collections.Generic.List[hashtable]]::new()
}

# ========================== TIMEOUT / PATH HELPERS ==========================
function Wait-KeyOrTimeout {
    <#
    .SYNOPSIS  Wait for a keypress or timeout.
    .PARAMETER Seconds   Number of seconds to wait.
    .PARAMETER Message   Prompt displayed to the user.
    #>
    [CmdletBinding()]
    param(
        [int]$Seconds = 10,
        [string]$Message = 'Press any key to continue or wait for timeout...'
    )

    Write-AppLog $Message "Info"
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 200  <# SS-004 exempt: console Wait-KeyOrTimeout loop, not UI thread #>
    }
}

function Request-LocalPath {
    <#
    .SYNOPSIS  GUI dialog with countdown for path entry.
    .PARAMETER Label           Display label for the path.
    .PARAMETER DefaultValue    Default value returned on timeout or blank input.
    .PARAMETER TimeoutSeconds  Seconds before auto-continue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$DefaultValue,

        [int]$TimeoutSeconds = 9
    )

    # Ensure WinForms is loaded (idempotent)
    Add-Type -AssemblyName System.Windows.Forms  -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing        -ErrorAction SilentlyContinue

    $result    = $DefaultValue
    $remaining = $TimeoutSeconds

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Local config: $Label"
    $form.Size            = New-Object System.Drawing.Size(520, 180)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.Topmost         = $true

    $promptLabel       = New-Object System.Windows.Forms.Label
    $promptLabel.Text  = "Enter value for $Label (blank uses default):"
    $promptLabel.Location = New-Object System.Drawing.Point(12, 12)
    $promptLabel.Size  = New-Object System.Drawing.Size(490, 18)
    $form.Controls.Add($promptLabel)

    $textBox          = New-Object System.Windows.Forms.TextBox
    $textBox.Text     = $DefaultValue
    $textBox.Location = New-Object System.Drawing.Point(12, 36)
    $textBox.Size     = New-Object System.Drawing.Size(490, 20)
    $form.Controls.Add($textBox)

    $countdownLabel          = New-Object System.Windows.Forms.Label
    $countdownLabel.Text     = "Auto-continue in $remaining s"
    $countdownLabel.Location = New-Object System.Drawing.Point(12, 64)
    $countdownLabel.Size     = New-Object System.Drawing.Size(490, 18)
    $form.Controls.Add($countdownLabel)

    $okButton              = New-Object System.Windows.Forms.Button
    $okButton.Text         = 'OK'
    $okButton.Location     = New-Object System.Drawing.Point(346, 100)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton              = New-Object System.Windows.Forms.Button
    $cancelButton.Text         = 'Use Default'
    $cancelButton.Location     = New-Object System.Drawing.Point(426, 100)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $script:_rlpTimedOut  = $false
    $script:_rlpRemaining = $TimeoutSeconds

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:_rlpRemaining--
        if ($script:_rlpRemaining -le 0) {
            $script:_rlpTimedOut = $true
            $timer.Stop()
            $form.Close()
        } else {
            $countdownLabel.Text = "Auto-continue in $script:_rlpRemaining s"
        }
    }.GetNewClosure())

    $form.Add_Shown({ $timer.Start() })
    $dialogResult = $form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()

    if (-not $script:_rlpTimedOut -and $dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $result = if ([string]::IsNullOrWhiteSpace($textBox.Text)) { $DefaultValue } else { $textBox.Text }
    }

    return $result
}

# ========================== SESSION LOCK ==========================
function Write-SessionLock {
    <#
    .SYNOPSIS  Create a session lock file indicating the app is running.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:_LockFilePath) {
        Write-AppLog -Message '' -Level Warning
        return
    }

    $lockData = @{
        PID       = $PID
        Started   = (Get-Date -Format 'o')
        Hostname  = $env:COMPUTERNAME
        User      = $env:USERNAME
    }

    $lockData | ConvertTo-Json -Depth 5 | Set-Content -Path $script:_LockFilePath -Encoding UTF8 -Force
}

function Remove-SessionLock {
    <#
    .SYNOPSIS  Remove the session lock file on graceful exit.
    #>
    [CmdletBinding()]
    param()

    if ($script:_LockFilePath -and (Test-Path $script:_LockFilePath)) {
        Remove-Item -Path $script:_LockFilePath -Force -ErrorAction SilentlyContinue
    }
}

# ========================== CRASH RECOVERY ==========================
function Invoke-CrashRecovery {
    <#
    .SYNOPSIS  Detect stale session lock and perform post-crash cleanup.
    .DESCRIPTION
        Checks for an existing .pwshgui-session.lock file.  If the PID recorded
        in the file is no longer running, the previous session crashed.
        Cleanup actions: flush residual log buffer, purge temp/ files, remove
        the stale lock, and log the event.
    .PARAMETER TempDir  Path to the temp directory to purge on crash.
    .OUTPUTS   [bool] $true if a crash was detected and cleaned up.
    #>
    [CmdletBinding()]
    param(
        [string]$TempDir
    )

    if (-not $script:_LockFilePath) {
        Write-AppLog -Message '' -Level Warning
        return $false
    }

    if (-not (Test-Path $script:_LockFilePath)) { return $false }

    # Read existing lock
    try {
        $lockJson = Get-Content $script:_LockFilePath -Raw -ErrorAction Stop
        $lock     = $lockJson | ConvertFrom-Json
    } catch {
        # Unreadable lock -- treat as stale
        Remove-Item -Path $script:_LockFilePath -Force -ErrorAction SilentlyContinue
        return $true
    }

    # Check whether the recorded PID is still alive
    $stale = $true
    if ($lock.PID) {
        $proc = Get-Process -Id $lock.PID -ErrorAction SilentlyContinue
        if ($proc) { $stale = $false }
    }

    if (-not $stale) { return $false }

    # --- Crash detected ---
    $crashTime = if ($lock.Started) { $lock.Started } else { 'unknown' }
    Write-AppLog "CRASH RECOVERY: Stale session detected (PID $($lock.PID), started $crashTime). Performing cleanup." 'Warning'

    # 1. Flush any residual log buffer entries
    Export-LogBuffer

    # 2. Purge temp files
    if ($TempDir -and (Test-Path $TempDir)) {
        $purged = 0
        Get-ChildItem -Path $TempDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item $_.FullName -Force -ErrorAction Stop; $purged++ } catch { <# Intentional: non-fatal #> }
        }
        Write-AppLog "CRASH RECOVERY: Purged $purged file(s) from temp/" 'Info'
    }

    # 3. Remove stale lock
    Remove-Item -Path $script:_LockFilePath -Force -ErrorAction SilentlyContinue

    Write-AppLog 'CRASH RECOVERY: Cleanup complete.' 'Info'
    return $true
}

# ========================== LOG ROTATION ==========================
function Invoke-LogRotation {
    <#
    .SYNOPSIS  Archive old log files and keep the last N days.
    .DESCRIPTION
        Scans $LogsDir for .log files older than $RetainDays.  Groups them by
        month and compresses each group into logs/archive/YYYY-MM.zip.  Originals
        are deleted after successful archival.
    .PARAMETER LogsDir     Path to the logs directory.
    .PARAMETER RetainDays  Number of days to keep (default 30).
    #>
    [CmdletBinding()]
    param(
        [string]$LogsDir,
        [int]$RetainDays = 30
    )

    if (-not $LogsDir) { $LogsDir = $script:_CoreLogsDir }
    if (-not $LogsDir -or -not (Test-Path $LogsDir)) { return }

    $cutoff     = (Get-Date).AddDays(-$RetainDays)
    $archiveDir = Join-Path $LogsDir 'archive'
    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    $oldLogs = Get-ChildItem -Path $LogsDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -lt $cutoff }

    if (-not $oldLogs -or $oldLogs.Count -eq 0) { return }

    # Group by year-month
    $groups = $oldLogs | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') }

    foreach ($g in $groups) {
        $zipName = Join-Path $archiveDir "$($g.Name).zip"
        try {
            # If archive already exists for that month, add to it
            if (Test-Path $zipName) {
                # Compress-Archive -Update adds files
                Compress-Archive -Path ($g.Group | ForEach-Object { $_.FullName }) -DestinationPath $zipName -Update -ErrorAction Stop
            } else {
                Compress-Archive -Path ($g.Group | ForEach-Object { $_.FullName }) -DestinationPath $zipName -ErrorAction Stop
            }
            # Remove originals after successful archive
            foreach ($f in $g.Group) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-AppLog "LOG ROTATION: Archived $($g.Group.Count) log(s) to archive/$($g.Name).zip" 'Info'
        } catch {
            Write-AppLog "LOG ROTATION: Failed to archive $($g.Name): $_" 'Warning'
        }
    }
}

# ========================== CONFIG INITIALISATION ==========================
function Initialize-ConfigFile {
    <#
    .SYNOPSIS  Create the system-variables.xml config file with environment info, version tags, and button definitions.
    .PARAMETER ConfigFile   Full path to the XML config file to create.
    .PARAMETER LogsDir      Logs directory path (written into the XML).
    .PARAMETER ConfigDir    Config directory path (written into the XML).
    .PARAMETER ScriptsDir   Scripts directory path (written into the XML).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigFile,
        [Parameter(Mandatory)] [string]$LogsDir,
        [Parameter(Mandatory)] [string]$ConfigDir,
        [Parameter(Mandatory)] [string]$ScriptsDir
    )

    Write-AppLog "Creating system variables config file..." "Info"

    $systemVars = @{
        ComputerName          = $env:COMPUTERNAME
        UserName              = $env:USERNAME
        UserDomain            = $env:USERDOMAIN
        OSVersion             = [System.Environment]::OSVersion.VersionString
        ProcessorCount        = $env:PROCESSOR_COUNT
        SystemRoot            = $env:SystemRoot
        Windows               = $env:Windows
        ProgramFiles          = $env:ProgramFiles
        ProgramFiles_x86      = ${env:ProgramFiles(x86)}
        AppData               = $env:APPDATA
        LocalAppData          = $env:LOCALAPPDATA
        Temp                  = $env:TEMP
        PSVersion             = $PSVersionTable.PSVersion.ToString()
        PowerShellVersion     = $PSVersionTable.PSVersion.Major
        ExecutionDate         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LogDirectory          = $LogsDir
        ConfigDirectory       = $ConfigDir
        ScriptsDirectory      = $ScriptsDir
        InitialExecutionHost  = $host.Name
    }

    $xmlDoc = New-Object System.Xml.XmlDocument
    $root   = $xmlDoc.CreateElement("SystemVariables")

    foreach ($key in $systemVars.Keys) {
        $element = $xmlDoc.CreateElement($key)
        $element.InnerText = $systemVars[$key]
        $root.AppendChild($element) | Out-Null
    }

    # Version and tagging configuration
    $versionElement = $xmlDoc.CreateElement("Version")
    $majorElem = $xmlDoc.CreateElement("Major")
    $majorElem.InnerText = (Get-Date).ToString('yyMM')
    $versionElement.AppendChild($majorElem) | Out-Null
    $minorElem = $xmlDoc.CreateElement("Minor")
    $minorElem.InnerText = 'B0'
    $versionElement.AppendChild($minorElem) | Out-Null
    $buildElem = $xmlDoc.CreateElement("Build")
    $buildElem.InnerText = '0'
    $versionElement.AppendChild($buildElem) | Out-Null
    $root.AppendChild($versionElement) | Out-Null

    $excludeElement = $xmlDoc.CreateElement("Do-Not-VersionTag-FoldersFiles")
    foreach ($folder in @('~BACKUPS','FOLDER-ROOT','logs','~REPORTS','~DOWNLOADS','temp','.logs','AutoIssueFinder-Logs','.history','.vscode')) {
        $f = $xmlDoc.CreateElement("Folder")
        $f.InnerText = $folder
        $excludeElement.AppendChild($f) | Out-Null
    }
    $root.AppendChild($excludeElement) | Out-Null

    # Button definitions
    $buttonsElement = $xmlDoc.CreateElement("Buttons")

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
        $btnElement      = $xmlDoc.CreateElement("Button")
        $scriptNameElem  = $xmlDoc.CreateElement("ScriptName")
        $scriptNameElem.InnerText = $btn.ScriptName
        $btnElement.AppendChild($scriptNameElem) | Out-Null
        $displayNameElem = $xmlDoc.CreateElement("DisplayName")
        $displayNameElem.InnerText = $btn.DisplayName
        $btnElement.AppendChild($displayNameElem) | Out-Null
        $leftButtonsElement.AppendChild($btnElement) | Out-Null
    }
    $buttonsElement.AppendChild($leftButtonsElement) | Out-Null

    $rightButtonsElement = $xmlDoc.CreateElement("RightColumn")
    $rightButtons = @(
        @{ ScriptName = "PWShQuickApp"; DisplayName = "PWSH-Quick-App (PWSH7 Prompt - Script Runner)"; ScriptPath = "~PWSH_Quick-APP3.ps1" }
    )

    foreach ($btn in $rightButtons) {
        $btnElement      = $xmlDoc.CreateElement("Button")
        $scriptNameElem  = $xmlDoc.CreateElement("ScriptName")
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
    $xmlDoc.Save($ConfigFile)

    Write-AppLog "System variables config created successfully" "Info"
}

# ========================== PROGRESS & VISUAL HELPERS ==========================
function Get-RainbowColor {
    <#
    .SYNOPSIS  Return an RGB hashtable for the given step index (cycles through 7 rainbow colours).
    #>
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
    <#
    .SYNOPSIS  Display a coloured ANSI progress bar in the console.
    #>
    param(
        [Parameter(Mandatory)] [string]$Activity,
        [Parameter(Mandatory)] [int]$PercentComplete,
        [Parameter(Mandatory)] [string]$Status,
        [int]$Step = 0
    )

    $color = Get-RainbowColor -Step $Step
    $barLength = 50
    $completed = [Math]::Floor(($PercentComplete / 100) * $barLength)
    $remaining = $barLength - $completed
    $bar = ("[" + ([string][char]9608) * $completed + ([string][char]9617) * $remaining + "]")
    $colorCode = "`e[38;2;$($color.R);$($color.G);$($color.B)m"
    $resetCode = "`e[0m"
    Write-Host "`r$colorCode$bar $PercentComplete% $resetCode- $Status" -NoNewline

    if ($PercentComplete -ge 100) {
        Write-Host ""
    }
}

function Assert-DirectoryExists {
    <#
    .SYNOPSIS  Creates directories if they don't exist. Accepts one or more paths. Logs creation.
    #>
    param([Parameter(Mandatory, ValueFromPipeline)][string[]]$Path)
    process {
        foreach ($p in $Path) {
            if ($p -and -not (Test-Path $p)) {
                New-Item -ItemType Directory -Path $p -Force | Out-Null
                if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
                    Write-AppLog "Created missing directory: $p" "Warning"
                }
            }
        }
    }
}

# ========================== CLI PROCESS BANNER ==========================
function Write-ProcessBanner {
    <#
    .SYNOPSIS  Prints a neat ASCII completion banner with process name and elapsed time.
    .PARAMETER ProcessName  The name of the process/script/scan that completed.
    .PARAMETER Stopwatch    Optional [System.Diagnostics.Stopwatch] for elapsed time.
    .PARAMETER StartTime    Optional [datetime] — used when no stopwatch is available.
    .PARAMETER Success      Whether the process succeeded (default $true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [datetime]$StartTime,
        [bool]$Success = $true
    )
    $elapsed = ''
    if ($Stopwatch) {
        $ts = $Stopwatch.Elapsed
        $elapsed = if ($ts.TotalMinutes -ge 1) { '{0:0}m {1:0.0}s' -f [math]::Floor($ts.TotalMinutes), ($ts.TotalSeconds % 60) }
                   elseif ($ts.TotalSeconds -ge 1) { '{0:N1}s' -f $ts.TotalSeconds }
                   else { '{0}ms' -f $ts.TotalMilliseconds }
    } elseif ($StartTime -ne [datetime]::MinValue -and $StartTime -ne $null) {
        $span = (Get-Date) - $StartTime
        $elapsed = if ($span.TotalMinutes -ge 1) { '{0:0}m {1:0.0}s' -f [math]::Floor($span.TotalMinutes), ($span.TotalSeconds % 60) }
                   elseif ($span.TotalSeconds -ge 1) { '{0:N1}s' -f $span.TotalSeconds }
                   else { '{0:N0}ms' -f $span.TotalMilliseconds }
    }
    $icon = if ($Success) { '[OK]' } else { '[!!]' }
    $color = if ($Success) { 'Cyan' } else { 'Red' }
    $timeStr = if ($elapsed) { " | Elapsed: $elapsed" } else { '' }
    $label = "$icon $ProcessName$timeStr"
    $lineLen = [math]::Max($label.Length + 4, 60)
    $border = [string]::new([char]0x2550, $lineLen)
    $pad = $lineLen - $label.Length - 2
    $padLeft = [int]($pad / 2)
    $padRight = $pad - $padLeft
    Write-Host ([char]0x2554 + $border + [char]0x2557) -ForegroundColor $color
    Write-Host ([char]0x2551 + (' ' * $padLeft) + $label + (' ' * $padRight) + [char]0x2551) -ForegroundColor $color
    Write-Host ([char]0x255A + $border + [char]0x255D) -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────
# Write-CrashDump
#   Persists a structured crash report to logs/crash-dumps/.
#   Detects repeating errors by signature (phase + first 80 chars of message).
#   Increments occurrence count and sets isRepeating on existing signature matches.
# ─────────────────────────────────────────────────────────────
function Write-CrashDump {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [string]$StackTrace    = '',
        [int]$RetryCount       = 0,
        [string]$CrashDumpDir  = '',
        [hashtable]$ExtraContext = @{}
    )

    # ── Resolve dump directory (P015: no hardcoded paths) ──────────────
    if ([string]::IsNullOrEmpty($CrashDumpDir)) {
        if (-not [string]::IsNullOrEmpty($script:_CoreCrashDumpDir)) {
            $CrashDumpDir = $script:_CoreCrashDumpDir
        } else {
            $CrashDumpDir = Join-Path $PSScriptRoot '..\logs'
            $CrashDumpDir = Join-Path $CrashDumpDir 'crash-dumps'
        }
    }

    # ── Ensure directory exists ─────────────────────────────────────────
    if (-not (Test-Path $CrashDumpDir)) {
        try {
            $null = New-Item -Path $CrashDumpDir -ItemType Directory -Force
        } catch {
            Write-Warning "Write-CrashDump: could not create crash-dump dir '$CrashDumpDir'. $_"
            return
        }
    }

    # ── Build error signature for deduplication (P022: null guard) ─────
    $sigPhase = if ($null -ne $Phase) { $Phase.ToLower().Trim() } else { 'unknown' }
    $msgPart  = if ($null -ne $ErrorMessage) { $ErrorMessage.Trim() } else { '' }
    if ($msgPart.Length -gt 80) { $msgPart = $msgPart.Substring(0, 80) }
    $signature = "$sigPhase`:$msgPart".ToLower()

    # ── Scan existing dumps for same signature ──────────────────────────
    $occurrences    = 1
    $firstSeen      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $isRepeating    = $false
    $existingDumps  = @()

    try {
        $dumpFiles = @(Get-ChildItem -Path $CrashDumpDir -Filter 'crash-*.json' -File -ErrorAction SilentlyContinue)
        foreach ($dumpFile in $dumpFiles) {
            try {
                $raw  = Get-Content -LiteralPath $dumpFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                # P022: null guard before ConvertFrom-Json result usage
                if (-not [string]::IsNullOrEmpty($raw)) {
                    $obj = $raw | ConvertFrom-Json
                    if ($null -ne $obj -and $null -ne $obj.signature -and $obj.signature -eq $signature) {
                        $existingDumps += $obj
                    }
                }
            } catch {
                <# Intentional: non-fatal — unreadable crash dump files are skipped #>
            }
        }
    } catch {
        <# Intentional: non-fatal — if dir scan fails, continue with occurrences=1 #>
    }

    if (@($existingDumps).Count -gt 0) {
        $isRepeating = $true
        $occurrences = @($existingDumps).Count + 1
        # Preserve firstSeen from oldest existing dump (P022: null guard)
        $oldest = $existingDumps | Sort-Object { if ($null -ne $_.timestamp) { $_.timestamp } else { '9999' } } | Select-Object -First 1
        if ($null -ne $oldest -and $null -ne $oldest.timestamp) {
            $firstSeen = $oldest.timestamp
        }
    }

    # ── Build crash record ──────────────────────────────────────────────
    $crashRecord = [ordered]@{
        timestamp      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        firstSeen      = $firstSeen
        phase          = $Phase
        errorMessage   = $ErrorMessage
        stackTrace     = $StackTrace
        retryCount     = $RetryCount
        occurrences    = $occurrences
        isRepeating    = $isRepeating
        signature      = $signature
        hostname       = $env:COMPUTERNAME
        psVersion      = "$($PSVersionTable.PSVersion)"
        extraContext   = $ExtraContext
    }

    # ── Write dump file (P012: -Encoding, P014: -Depth, P018: nested Join-Path) ─
    $ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safePhase = $Phase -replace '[^a-zA-Z0-9_-]', '_'
    $fileName  = "crash-$ts-$safePhase.json"
    $filePath  = Join-Path $CrashDumpDir $fileName

    try {
        $json = $crashRecord | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $filePath -Value $json -Encoding UTF8 -Force
    } catch {
        Write-Warning "Write-CrashDump: failed to write '$filePath'. $_"
        return
    }

    # ── Mirror to Write-AppLog if available ────────────────────────────
    $repStr    = if ($isRepeating) { " [REPEATING x$occurrences]" } else { '' }
    $logMsg    = "CRASH[$Phase]$repStr $ErrorMessage"
    try {
        Write-AppLog -Level 'Critical' -Message $logMsg
    } catch {
        <# Intentional: non-fatal — Write-AppLog may not be initialized yet #>
    }
}

# ========================== EXPORTS ==========================
Export-ModuleMember -Function @(
    'Initialize-CorePaths'
    'Initialize-ConfigFile'
    'Get-ProjectPath'
    'Get-AllProjectPaths'
    'Write-AppLog'
    'Set-LogMinLevel'
    'Get-LogMinLevel'
    'Write-ErrorReport'
    'Write-ScriptLog'
    'Export-LogBuffer'
    'Wait-KeyOrTimeout'
    'Request-LocalPath'
    'Write-SessionLock'
    'Remove-SessionLock'
    'Invoke-CrashRecovery'
    'Invoke-LogRotation'
    'Get-RainbowColor'
    'Write-RainbowProgress'
    'Assert-DirectoryExists'
    'Write-ProcessBanner'
    'Write-CrashDump'
)






