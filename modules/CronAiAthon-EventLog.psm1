# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    Cron-Ai-Athon EventLog & SYSLOG module -- Windows Event Log integration
    with SYSLOG severity levels and optional forwarding.
# TODO: HelpMenu | Show-EventLogHelp | Actions: Write|Query|Export|Rotate|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides:
      - Windows Event Log source registration (PowerShellGUI-CRON, PowerShellGUI-CORE)
      - Writing events with SYSLOG severity levels (RFC 5424)
      - SYSLOG UDP/161 forwarding with TCP/161 fallback
      - Local .SYSLOG file output to the logs/ folder
      - Log level filtering and severity standard enforcement

    SYSLOG Severity Levels (RFC 5424):
      0 = Emergency   -- System is unusable
      1 = Alert       -- Immediate action needed
      2 = Critical    -- Critical conditions
      3 = Error       -- Error conditions
      4 = Warning     -- Warning conditions
      5 = Notice      -- Normal but significant
      6 = Informational -- Informational messages
      7 = Debug       -- Debug-level messages

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 28th March 2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ========================== SYSLOG SEVERITY MAP ==========================

$script:SyslogSeverity = @{
    'Emergency'     = 0
    'Alert'         = 1
    'Critical'      = 2
    'Error'         = 3
    'Warning'       = 4
    'Notice'        = 5
    'Informational' = 6
    'Debug'         = 7
}

$script:SeverityToEventLogType = @{
    0 = 'Error'       # Emergency
    1 = 'Error'       # Alert
    2 = 'Error'       # Critical
    3 = 'Error'       # Error
    4 = 'Warning'     # Warning
    5 = 'Information' # Notice
    6 = 'Information' # Informational
    7 = 'Information' # Debug
}

$script:EventLogSources = @('PowerShellGUI-CRON', 'PowerShellGUI-CORE')
$script:DefaultSyslogPort = 514
$script:SyslogFileSuffix = '.SYSLOG'

# ========================== SOURCE REGISTRATION ==========================

function Register-EventLogSources {
    <#
    .SYNOPSIS  Register Windows Event Log sources for PowerShellGUI.
    .DESCRIPTION
        Registers PowerShellGUI-CRON and PowerShellGUI-CORE sources under
        the Application log. Requires elevated privileges on first registration.
    .PARAMETER Sources  Array of source names to register.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [CmdletBinding()]
    param(
        [string[]]$Sources = $script:EventLogSources
    )

    $results = @()
    foreach ($src in $Sources) {
        try {
            $exists = [System.Diagnostics.EventLog]::SourceExists($src)
            if (-not $exists) {
                [System.Diagnostics.EventLog]::CreateEventSource($src, 'Application')
                $results += [ordered]@{
                    source  = $src
                    status  = 'REGISTERED'
                    detail  = 'Created in Application log'
                }
            } else {
                $results += [ordered]@{
                    source  = $src
                    status  = 'EXISTS'
                    detail  = 'Already registered'
                }
            }
        } catch {
            Write-AppLog -Message "Register-EventLogSource failed for ${src}: $($_.Exception.Message)" -Level Error
            $results += [ordered]@{
                source  = $src
                status  = 'FAILED'
                detail  = $_.Exception.Message
            }
        }
    }
    return $results
}

function Test-EventLogSourceReady {
    <#
    .SYNOPSIS  Check if an event log source is registered and accessible.
        .DESCRIPTION
      Detailed behaviour: Test event log source ready.
    #>
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param([string]$Source = 'PowerShellGUI-CRON')

    try {
        return [System.Diagnostics.EventLog]::SourceExists($Source)
    } catch {
        Write-AppLog -Message "Test-EventLogSourceReady failed for ${Source}: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# ========================== EVENT WRITING ==========================

function Write-CronEventLog {
    <#
    .SYNOPSIS  Write an event to Windows Event Log with SYSLOG severity.
    .PARAMETER Source     Event log source (PowerShellGUI-CRON or PowerShellGUI-CORE).
    .PARAMETER Message    Event message text.
    .PARAMETER Severity   SYSLOG severity name (Emergency..Debug).
    .PARAMETER EventId    Optional event ID number (default 1000).
    .PARAMETER Category   Optional event category (default 0).
        .DESCRIPTION
      Detailed behaviour: Write cron event log.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [string]$Source = 'PowerShellGUI-CRON',
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Emergency','Alert','Critical','Error','Warning','Notice','Informational','Debug')]
        [string]$Severity = 'Informational',
        [int]$EventId = 1000,
        [int16]$Category = 0
    )

    $sevLevel = $script:SyslogSeverity[$Severity]
    $entryType = $script:SeverityToEventLogType[$sevLevel]

    # Prefix message with SYSLOG severity tag
    $taggedMessage = "[SYSLOG-$sevLevel/$Severity] $Message"

    try {
        if (Test-EventLogSourceReady -Source $Source) {
            Write-EventLog -LogName 'Application' -Source $Source -EventId $EventId `
                           -EntryType $entryType -Message $taggedMessage -Category $Category
            return [ordered]@{ success = $true; target = 'EventLog'; source = $Source; severity = $Severity }
        } else {
            return [ordered]@{ success = $false; target = 'EventLog'; error = "Source '$Source' not registered. Run Register-EventLogSources with elevated privileges." }
        }
    } catch {
        return [ordered]@{ success = $false; target = 'EventLog'; error = $_.Exception.Message }
    }
}

# ========================== SYSLOG FORWARDING ==========================

function Send-SyslogMessage {
    <#
    .SYNOPSIS  Forward a SYSLOG message via UDP (primary) or TCP (fallback).
    .PARAMETER Server     Target SYSLOG server hostname or IP.
    .PARAMETER Port       Target port (default 514).
    .PARAMETER Facility   SYSLOG facility code (default 1 = user-level).
    .PARAMETER Severity   SYSLOG severity name.
    .PARAMETER Message    Log message.
    .PARAMETER Hostname   Originating hostname (default: local).
    .PARAMETER AppName    Application name tag.
    .PARAMETER UseTcpFallback  If UDP fails, try TCP.
        .DESCRIPTION
      Detailed behaviour: Send syslog message.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Server,
        [int]$Port = $script:DefaultSyslogPort,
        [int]$Facility = 1,
        [ValidateSet('Emergency','Alert','Critical','Error','Warning','Notice','Informational','Debug')]
        [string]$Severity = 'Informational',
        [Parameter(Mandatory)] [string]$Message,
        [string]$Hostname = $env:COMPUTERNAME,
        [string]$AppName = 'PowerShellGUI',
        [switch]$UseTcpFallback
    )

    $sevLevel = $script:SyslogSeverity[$Severity]
    $pri = ($Facility * 8) + $sevLevel
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $syslogMsg = "<$pri>1 $timestamp $Hostname $AppName - - - $Message"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($syslogMsg)

    # Attempt UDP first
    $udpResult = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Send($bytes, $bytes.Length, $Server, $Port) | Out-Null
        $udp.Close()
        $udpResult = [ordered]@{ success = $true; protocol = 'UDP'; server = $Server; port = $Port }
    } catch {
        $udpError = $_.Exception.Message
        $udpResult = [ordered]@{ success = $false; protocol = 'UDP'; error = $udpError }
    }

    if ($udpResult.success) { return $udpResult }

    # TCP Fallback
    if ($UseTcpFallback) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect($Server, $Port)
            $stream = $tcp.GetStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $stream.Close()
            $tcp.Close()
            return [ordered]@{ success = $true; protocol = 'TCP'; server = $Server; port = $Port }
        } catch {
            return [ordered]@{ success = $false; protocol = 'TCP'; error = $_.Exception.Message; udpError = $udpError }
        }
    }

    return $udpResult
}

# ========================== .SYSLOG FILE OUTPUT ==========================

function Write-SyslogFile {
    <#
    .SYNOPSIS  Append a SYSLOG-formatted entry to the local .SYSLOG file.
    .PARAMETER WorkspacePath  Root workspace path (logs/ subdirectory used).
    .PARAMETER Message         Log message.
    .PARAMETER Severity        SYSLOG severity name.
    .PARAMETER Source          Source identifier.
        .DESCRIPTION
      Detailed behaviour: Write syslog file.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Emergency','Alert','Critical','Error','Warning','Notice','Informational','Debug')]
        [string]$Severity = 'Informational',
        [string]$Source = 'PowerShellGUI-CRON'
    )

    $logsDir = Join-Path $WorkspacePath 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

    $syslogFile = Join-Path $logsDir ('PowerShellGUI' + $script:SyslogFileSuffix)
    $sevLevel = $script:SyslogSeverity[$Severity]
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $entry = "$timestamp [$sevLevel/$Severity] [$Source] $Message"

    Add-Content -Path $syslogFile -Value $entry -Encoding UTF8
    return [ordered]@{ success = $true; file = $syslogFile; severity = $Severity }
}

# ========================== UNIFIED LOG FUNCTION ==========================

function Write-CronLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    <#
    .SYNOPSIS  Unified logger -- writes to EventLog, .SYSLOG file, and optionally forwards.
    .DESCRIPTION
        Single entry point for all Cron-Ai-Athon logging. Writes to:
          1. Windows Event Log (if source is registered)
          2. Local .SYSLOG file (always)
          3. SYSLOG server via UDP/TCP (if Server is specified)
    .PARAMETER WorkspacePath  Root workspace path.
    .PARAMETER Source          Event source (PowerShellGUI-CRON or PowerShellGUI-CORE).
    .PARAMETER Message         Text to log.
    .PARAMETER Severity        SYSLOG severity level name.
    .PARAMETER SyslogServer    Optional SYSLOG server for forwarding.
    .PARAMETER SyslogPort      SYSLOG port (default 514).
    .PARAMETER EventId         Windows Event Log event ID.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = '',
        [string]$Source = 'PowerShellGUI-CRON',
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Emergency','Alert','Critical','Error','Warning','Notice','Informational','Debug')]
        [string]$Severity = 'Informational',
        [string]$SyslogServer,
        [int]$SyslogPort = 161,
        [int]$EventId = 1000
    )

    $results = [ordered]@{
        eventLog = $null
        syslogFile = $null
        syslogForward = $null
    }

    # 1. Windows Event Log
    $results.eventLog = Write-CronEventLog -Source $Source -Message $Message -Severity $Severity -EventId $EventId

    # 2. Local .SYSLOG file (always, when WorkspacePath is provided)
    if ($WorkspacePath) {
        $results.syslogFile = Write-SyslogFile -WorkspacePath $WorkspacePath -Message $Message -Severity $Severity -Source $Source
    }

    # 3. Remote SYSLOG forwarding (optional)
    if ($SyslogServer) {
        $results.syslogForward = Send-SyslogMessage -Server $SyslogServer -Port $SyslogPort `
            -Severity $Severity -Message $Message -UseTcpFallback
    }

    return $results
}

# ========================== LOG CONFIG ==========================

function Get-EventLogConfig {
    <#
    .SYNOPSIS  Return current EventLog/SYSLOG configuration summary.
        .DESCRIPTION
      Detailed behaviour: Get event log config.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $syslogFile = Join-Path (Join-Path $WorkspacePath 'logs') ('PowerShellGUI' + $script:SyslogFileSuffix)
    $syslogExists = Test-Path $syslogFile
    $syslogSize = 0
    $syslogLines = 0
    if ($syslogExists) {
        $syslogSize = (Get-Item $syslogFile).Length
        $syslogLines = @(Get-Content $syslogFile -ErrorAction SilentlyContinue).Count
    }

    $sourceStates = @()
    foreach ($src in $script:EventLogSources) {
        $sourceStates += [ordered]@{
            source     = $src
            registered = (Test-EventLogSourceReady -Source $src)
        }
    }

    return [ordered]@{
        sources    = $sourceStates
        syslogFile = [ordered]@{
            path   = $syslogFile
            exists = $syslogExists
            sizeBytes = $syslogSize
            lineCount = $syslogLines
        }
        severity   = $script:SyslogSeverity
        defaultPort = $script:DefaultSyslogPort
    }
}

function Get-SyslogEntries {
    <#
    .SYNOPSIS  Read recent entries from the local .SYSLOG file.
        .DESCRIPTION
      Detailed behaviour: Get syslog entries.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [int]$Last = 100
    )

    $syslogFile = Join-Path (Join-Path $WorkspacePath 'logs') ('PowerShellGUI' + $script:SyslogFileSuffix)
    if (-not (Test-Path $syslogFile)) { return @() }

    $lines = Get-Content $syslogFile -Tail $Last -ErrorAction SilentlyContinue
    return $lines
}

# ========================== APP-TO-SYSLOG BRIDGE ==========================

function ConvertTo-SyslogSeverity {
    <#
    .SYNOPSIS  Map canonical application log levels to RFC 5424 SYSLOG severity names.
    .DESCRIPTION
        Bridges the 6-level canonical logging model (Debug, Info, Warning, Error,
        Critical, Audit) to the 8-level SYSLOG severity names used by
        Write-CronLog, Write-CronEventLog, and Send-SyslogMessage.

        This allows any module or script to translate an application-level
        severity before forwarding to the SYSLOG infrastructure.
    .PARAMETER AppLevel  One of the canonical levels: Debug, Info, Warning, Error, Critical, Audit.
    .OUTPUTS   [string] The corresponding SYSLOG severity name.
    .EXAMPLE
        ConvertTo-SyslogSeverity -AppLevel 'Error'   # returns 'Error'
        ConvertTo-SyslogSeverity -AppLevel 'Audit'   # returns 'Notice'
        ConvertTo-SyslogSeverity -AppLevel 'Critical' # returns 'Critical'
    #>
    [OutputType([System.String])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$AppLevel
    )

    switch ($AppLevel) {
        'Debug'    { return 'Debug' }
        'Info'     { return 'Informational' }
        'Warning'  { return 'Warning' }
        'Error'    { return 'Error' }
        'Critical' { return 'Critical' }
        'Audit'    { return 'Notice' }
    }
}

# ========================== HELP MENU ==========================

function Show-EventLogHelp {
    <#
    .SYNOPSIS  Display quick usage help for CronAiAthon EventLog operations.
        .DESCRIPTION
      Detailed behaviour: Show event log help.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Write','Query','Export','Rotate','Help')]
        [string]$Action = 'Help',

        [ValidateSet('Debug','Info','Warning','Error','Critical')]
        [string]$EventLevel = 'Info',

        [string]$LogToFile = 'auto',
        [switch]$ShowRainbow
    )

    if ($ShowRainbow) {
        Write-Host '=== CronAiAthon EventLog Help ===' -ForegroundColor Cyan
    }

    $lines = @(
        'Actions: Write | Query | Export | Rotate | Help',
        "Selected Action: $Action",
        "EventLevel: $EventLevel",
        'Examples:',
        '  Show-EventLogHelp -Action Write',
        '  Show-EventLogHelp -Action Query -EventLevel Warning',
        '  Show-EventLogHelp -Action Export -LogToFile auto',
        '  Show-EventLogHelp -Action Help -ShowRainbow'
    )
    foreach ($line in $lines) {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($LogToFile)) {
        $logPath = if ($LogToFile -eq 'auto') {
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs') 'eventlog-events-help.log'
        } else {
            $LogToFile
        }
        try {
            $logDir = Split-Path -Path $logPath -Parent
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $logPath -Value ("[{0}] Help viewed: Action={1}; EventLevel={2}" -f (Get-Date -Format o), $Action, $EventLevel) -Encoding UTF8
        } catch {
            Write-Verbose "Show-EventLogHelp log write failed: $($_.Exception.Message)"
        }
    }
}

# ========================== EXPORTS ==========================

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
    'Register-EventLogSources',
    'Test-EventLogSourceReady',
    'Write-CronEventLog',
    'Send-SyslogMessage',
    'Write-SyslogFile',
    'Write-CronLog',
    'Get-EventLogConfig',
    'Get-SyslogEntries',
    'ConvertTo-SyslogSeverity',
    'Show-EventLogHelp'
)







