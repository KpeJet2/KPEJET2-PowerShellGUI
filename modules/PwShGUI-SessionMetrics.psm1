# VersionTag: 2605.B5.V46.0
# Module: PwShGUI-SessionMetrics
# Purpose: Boot/exit metrics, session object caching, crash detection
# ================================================================

using namespace System.Collections.Generic

# ── Session metrics state ──
$script:_SessionMetrics = @{
    BootTime            = $null
    ExitTime            = $null
    SessionObjects      = [Queue[PSCustomObject]]::new()
    MaxCachedObjects    = 50
    CrashIndicators     = @()
    InstanceEventLog    = @()
}

function Start-SessionMetrics {
    <#
    .SYNOPSIS  Initialize session metrics at boot.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId = (New-Guid).Guid,
        [int]$MaxCachedObjects = 50
    )

    $script:_SessionMetrics.BootTime = Get-Date
    $script:_SessionMetrics.SessionId = $SessionId
    $script:_SessionMetrics.MaxCachedObjects = $MaxCachedObjects
    $script:_SessionMetrics.SessionObjects.Clear()
    $script:_SessionMetrics.CrashIndicators = @()
    $script:_SessionMetrics.InstanceEventLog = @()

    Write-SessionEvent -ObjectType 'SessionStart' -Data @{
        SessionId = $SessionId
        BootTime = $script:_SessionMetrics.BootTime
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
    }

    return $script:_SessionMetrics.BootTime
}

function Stop-SessionMetrics {
    <#
    .SYNOPSIS  Finalize session metrics at exit.
    .OUTPUTS   [PSCustomObject] with BootTime, ExitTime, Uptime, CrashIndicators, ObjectsCached
    #>
    [CmdletBinding()]
    param()

    $script:_SessionMetrics.ExitTime = Get-Date
    $uptime = $script:_SessionMetrics.ExitTime - $script:_SessionMetrics.BootTime

    Write-SessionEvent -ObjectType 'SessionEnd' -Data @{
        SessionId = $script:_SessionMetrics.SessionId
        BootTime = $script:_SessionMetrics.BootTime
        ExitTime = $script:_SessionMetrics.ExitTime
        UptimeSeconds = [math]::Round($uptime.TotalSeconds, 2)
        CrashIndicators = $script:_SessionMetrics.CrashIndicators
        ObjectsCached = $script:_SessionMetrics.SessionObjects.Count
    }

    return [PSCustomObject]@{
        BootTime = $script:_SessionMetrics.BootTime
        ExitTime = $script:_SessionMetrics.ExitTime
        Uptime = $uptime
        UptimeSeconds = [math]::Round($uptime.TotalSeconds, 2)
        CrashIndicators = $script:_SessionMetrics.CrashIndicators
        ObjectsCached = $script:_SessionMetrics.SessionObjects.Count
        InstanceEventLog = $script:_SessionMetrics.InstanceEventLog | Select-Object -Last 10
    }
}

function Write-SessionEvent {
    <#
    .SYNOPSIS  Log an instance event (function call, tray action, etc.) with timestamp.
    .PARAMETER ObjectType  Type of object (FunctionCall, TrayEvent, FormShow, FormHide, etc.)
    .PARAMETER Data  Hashtable of event data
    #>
    [CmdletBinding()]
    param(
        [string]$ObjectType,
        [hashtable]$Data = @{}
    )

    $evt = [PSCustomObject]@{
        Timestamp = Get-Date
        ObjectType = $ObjectType
        Data = $Data
    }

    $script:_SessionMetrics.InstanceEventLog += $evt

    # Keep only last 100 events
    if ($script:_SessionMetrics.InstanceEventLog.Count -gt 100) {
        $script:_SessionMetrics.InstanceEventLog = @($script:_SessionMetrics.InstanceEventLog | Select-Object -Last 100)
    }

    return $evt
}

function Add-SessionObject {
    <#
    .SYNOPSIS  Cache a function call or object reference for crash detection.
    .PARAMETER ObjectType  Type identifier (function name, module name, etc.)
    .PARAMETER ObjectName  Instance name or call identifier
    .PARAMETER Context  Additional context data (parameters, state, etc.)
    #>
    [CmdletBinding()]
    param(
        [string]$ObjectType,
        [string]$ObjectName,
        [hashtable]$Context = @{}
    )

    $obj = [PSCustomObject]@{
        Timestamp = Get-Date
        ObjectType = $ObjectType
        ObjectName = $ObjectName
        Context = $Context
        StackTrace = $null
    }

    # Capture call stack for debugging
    try {
        $stack = Get-PSCallStack
        $obj.StackTrace = @($stack | Select-Object -ExpandProperty Command) -join ' -> '
    } catch { <# Intentional: non-fatal — call stack capture is best-effort #> }

    # Add to queue and maintain max size
    $script:_SessionMetrics.SessionObjects.Enqueue($obj)
    while ($script:_SessionMetrics.SessionObjects.Count -gt $script:_SessionMetrics.MaxCachedObjects) {
        $script:_SessionMetrics.SessionObjects.Dequeue()
    }

    Write-SessionEvent -ObjectType 'ObjectCached' -Data @{
        Type = $ObjectType
        Name = $ObjectName
        QueueSize = $script:_SessionMetrics.SessionObjects.Count
    }

    return $obj
}

function Get-SessionObjectCache {
    <#
    .SYNOPSIS  Retrieve cached session objects (for crash analysis).
    .OUTPUTS   [PSCustomObject[]] Array of cached objects
    #>
    [CmdletBinding()]
    param()

    return @($script:_SessionMetrics.SessionObjects | ForEach-Object { $_ })
}

function Add-CrashIndicator {
    <#
    .SYNOPSIS  Log a potential crash indicator (exception, timeout, state mismatch, etc.).
    .PARAMETER Indicator  Description of the indicator
    .PARAMETER Severity  Severity level (Low, Medium, High, Critical)
    #>
    [CmdletBinding()]
    param(
        [string]$Indicator,
        [ValidateSet('Low', 'Medium', 'High', 'Critical')]
        [string]$Severity = 'Medium'
    )

    $indicator_obj = [PSCustomObject]@{
        Timestamp = Get-Date
        Indicator = $Indicator
        Severity = $Severity
        SessionObjects = @($script:_SessionMetrics.SessionObjects)
    }

    $script:_SessionMetrics.CrashIndicators += $indicator_obj

    Write-SessionEvent -ObjectType 'CrashIndicator' -Data @{
        Indicator = $Indicator
        Severity = $Severity
        CachedObjectsAtTime = $script:_SessionMetrics.SessionObjects.Count
    }

    return $indicator_obj
}

function Get-CrashAnalysis {
    <#
    .SYNOPSIS  Analyze crash indicators and cached objects to suggest root cause.
    .OUTPUTS   [PSCustomObject] with CrashLikelihood, SuggestedRootCause, RecommendedActions
    #>
    [CmdletBinding()]
    param()

    $indicators = $script:_SessionMetrics.CrashIndicators
    $cached = @($script:_SessionMetrics.SessionObjects)

    $likelihood = if ($indicators.Count -eq 0) { 'Low' }
        elseif ($indicators.Count -le 2) { 'Medium' }
        else { 'High' }

    $criticalCount = @($indicators | Where-Object Severity -eq 'Critical').Count
    if ($criticalCount -gt 0) { $likelihood = 'Critical' }

    $lastIndicator = $indicators[-1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $suggestedCause = if ($lastIndicator) { $lastIndicator.Indicator } else { 'No indicators recorded' }

    $actions = @()
    if ($cached) {
        $lastObj = $cached[-1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $actions += "Last cached object was $($lastObj.ObjectType): $($lastObj.ObjectName) at $($lastObj.Timestamp)"
        $actions += "Call stack: $($lastObj.StackTrace)"
    }

    if ($indicators -match 'disposed|not yet created') {
        $actions += "Form initialization race condition detected -- ensure TrayHost fully loads before GUI"
    }

    if ($indicators -match 'timeout|freeze|hang') {
        $actions += "UI thread blocking detected -- check for long-running operations in event handlers"
    }

    return [PSCustomObject]@{
        CrashLikelihood = $likelihood
        IndicatorCount = $indicators.Count
        CriticalIndicators = $criticalCount
        SuggestedRootCause = $suggestedCause
        RecommendedActions = $actions
        LastCachedObjects = $cached | Select-Object -Last 5
        InstanceEventLog = $script:_SessionMetrics.InstanceEventLog | Select-Object -Last 20
    }
}

function Export-SessionMetrics {
    <#
    .SYNOPSIS  Export session metrics to file for post-mortem analysis.
    .PARAMETER FilePath  Output file path (JSON or PS1XML)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $analysis = Get-CrashAnalysis
    $export = @{
        BootTime = $script:_SessionMetrics.BootTime
        ExitTime = $script:_SessionMetrics.ExitTime
        Uptime = if ($script:_SessionMetrics.ExitTime) { ($script:_SessionMetrics.ExitTime - $script:_SessionMetrics.BootTime).TotalSeconds } else { $null }
        CrashAnalysis = $analysis
        SessionObjects = @($script:_SessionMetrics.SessionObjects)
        InstanceEventLog = $script:_SessionMetrics.InstanceEventLog
    }

    if ($FilePath -match '\.json$') {
        $export | ConvertTo-Json -Depth 6 | Set-Content -Path $FilePath -Encoding UTF8
    } else {
        $export | Export-Clixml -Path $FilePath
    }

    Write-Verbose "Session metrics exported to $FilePath"
    return $FilePath
}

# ── Exports ──
Export-ModuleMember -Function @(
    'Start-SessionMetrics',
    'Stop-SessionMetrics',
    'Write-SessionEvent',
    'Add-SessionObject',
    'Get-SessionObjectCache',
    'Add-CrashIndicator',
    'Get-CrashAnalysis',
    'Export-SessionMetrics'
)

# Legacy compatibility shim: keep old call sites working without exporting an unapproved verb.
try {
    if (-not (Get-Command Log-InstanceEvent -ErrorAction SilentlyContinue)) {
        Set-Alias -Name Log-InstanceEvent -Value Write-SessionEvent -Scope Global -Force
    }
} catch {
    <# Intentional: alias setup is non-fatal #>
}

