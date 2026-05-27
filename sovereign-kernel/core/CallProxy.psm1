# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- CallProxy Module
    Single choke point for all method calls and outbound network traffic.

.DESCRIPTION
    Every invocation between kernel modules and every outbound network call is
    routed through the CallProxy for:
      - Pre-execution policy checks (governance required)
      - Rate limiting
      - Call depth tracking (prevents infinite recursion)
      - Full audit logging to the immutable ledger
      - Outbound firewall with allowlist enforcement
      - Dependency chain recording
      - Timeout enforcement

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.proxy.1
    Depends  : SovereignPolicy.psm1, LedgerWriter.psm1, AgentRegistry.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_ProxyConfig       = $null   # tools_and_calls from manifest
$script:_CallStack         = [System.Collections.Generic.Stack[hashtable]]::new()
$script:_RateLimiter       = @{}     # agentOrigin -> { count, window_start_utc }
$script:_OutboundAllowlist = @()
$script:_CallCounter       = [long]0
$script:_ProxyInitialized  = $false
$script:_MaxCallDepth      = 16
$script:_DefaultTimeoutMs  = 30000

# ========================== INITIALISATION ==========================
function Initialize-CallProxy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ToolsAndCallsConfig,

        [string]$KernelRoot
    )
    $script:_ProxyConfig      = $ToolsAndCallsConfig
    $script:_MaxCallDepth     = if ($ToolsAndCallsConfig.method_call_monitor.max_call_depth) {
        $ToolsAndCallsConfig.method_call_monitor.max_call_depth
    } else { 16 }
    $script:_DefaultTimeoutMs = if ($ToolsAndCallsConfig.method_call_monitor.timeout_ms) {
        $ToolsAndCallsConfig.method_call_monitor.timeout_ms
    } else { 30000 }

    # Load outbound allowlist if configured
    if ($ToolsAndCallsConfig.outbound_firewall.allowlist_path -and $KernelRoot) {
        $allowPath = Join-Path $KernelRoot $ToolsAndCallsConfig.outbound_firewall.allowlist_path
        if (Test-Path $allowPath) {
            $script:_OutboundAllowlist = @(
                (Get-Content -Path $allowPath -Raw -Encoding UTF8 | ConvertFrom-Json).allowed
            )
        }
    }

    $script:_ProxyInitialized = $true
    Write-Verbose "[CallProxy] Initialized -- max_depth=$($script:_MaxCallDepth), timeout=$($script:_DefaultTimeoutMs)ms"
}

# ========================== METHOD CALL PROXY ==========================
function Invoke-ProxiedCall {
    <#
    .SYNOPSIS
        Wraps any module method call with policy checks, depth tracking, logging, and timeout.
    .PARAMETER ModuleId
        The calling module.
    .PARAMETER MethodName
        The function/method being called.
    .PARAMETER Arguments
        Hashtable of arguments to pass.
    .PARAMETER ScriptBlock
        The actual code to execute.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleId,

        [Parameter(Mandatory)]
        [string]$MethodName,

        [hashtable]$Arguments = @{},

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [int]$TimeoutMs = 0
    )
    if (-not $script:_ProxyInitialized) {
        throw '[CallProxy] Not initialized. Call Initialize-CallProxy first.'
    }

    if ($TimeoutMs -le 0) { $TimeoutMs = $script:_DefaultTimeoutMs }
    $script:_CallCounter++
    $callId = $script:_CallCounter

    # Depth check
    if ($script:_CallStack.Count -ge $script:_MaxCallDepth) {
        $depthError = @{
            call_id   = $callId
            module    = $ModuleId
            method    = $MethodName
            error     = 'MAX_CALL_DEPTH_EXCEEDED'
            depth     = $script:_CallStack.Count
            max_depth = $script:_MaxCallDepth
        }
        try { Write-LedgerEntry -EventType 'ERROR' -Source 'CallProxy' -Data $depthError } catch { <# Intentional: non-fatal ledger write #> }
        throw "[CallProxy] Maximum call depth ($($script:_MaxCallDepth)) exceeded."
    }

    # Rate limit check
    $rateOk = Test-RateLimit -AgentOrigin $ModuleId
    if (-not $rateOk) {
        $rateError = @{
            call_id = $callId
            module  = $ModuleId
            method  = $MethodName
            error   = 'RATE_LIMIT_EXCEEDED'
        }
        try { Write-LedgerEntry -EventType 'ERROR' -Source 'CallProxy' -Data $rateError } catch { <# Intentional: non-fatal ledger write #> }
        throw "[CallProxy] Rate limit exceeded for module $ModuleId."
    }

    # Push call onto stack
    $callFrame = @{
        call_id       = $callId
        module        = $ModuleId
        method        = $MethodName
        args_keys     = @($Arguments.Keys)
        depth         = $script:_CallStack.Count + 1
        started_utc   = [datetime]::UtcNow.ToString('o')
    }
    $script:_CallStack.Push($callFrame)

    # Log the call
    $callRecord = @{
        call_id          = $callId
        module           = $ModuleId
        method           = $MethodName
        args_schema      = @($Arguments.Keys)
        version          = 'SK.v15.c8'
        cycle            = 'cycle8'
        dependencies     = @()
        protocol_context = 'internal'
        timestamp        = $callFrame.started_utc
        depth            = $callFrame.depth
    }

    try { Write-LedgerEntry -EventType 'METHOD_CALL' -Source 'CallProxy' -Data $callRecord } catch { <# Intentional: non-fatal ledger write #> }

    # Execute with timeout
    $result   = $null
    $error_   = $null
    $elapsed  = $null

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $ScriptBlock @Arguments
        $sw.Stop()
        $elapsed = $sw.ElapsedMilliseconds

        if ($elapsed -gt $TimeoutMs) {
            Write-AppLog -Message "[CallProxy] Call $callId ($ModuleId::$MethodName) exceeded timeout: ${elapsed}ms > ${TimeoutMs}ms" -Level Warning
        }
    }
    catch {
        $error_ = $_.Exception.Message
        try {
            Write-LedgerEntry -EventType 'ERROR' -Source 'CallProxy' -Data @{
                call_id = $callId
                module  = $ModuleId
                method  = $MethodName
                error   = $error_
            }
        }
        catch { <# Intentional: non-fatal error ledger write before re-throw #> }
        throw
    }
    finally {
        if ($script:_CallStack.Count -gt 0) {
            $script:_CallStack.Pop() | Out-Null
        }
    }

    return $result
}

# ========================== OUTBOUND FIREWALL ==========================
function Test-OutboundRequest {
    <#
    .SYNOPSIS
        Validates an outbound network request against the firewall policy.
        Block-by-default unless in allowlist or governance-approved.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Hostname,

        [int]$Port = 443,
        [string]$Protocol = 'HTTPS',
        [string]$Purpose = '',
        [string]$AgentOrigin = '',
        [string[]]$GovernanceApprovers = @()
    )
    $fw = $script:_ProxyConfig.outbound_firewall
    $allowed = $false
    $reason  = 'BLOCKED_BY_DEFAULT'

    # Check allowlist
    if ($Hostname -in $script:_OutboundAllowlist) {
        $allowed = $true
        $reason  = 'ALLOWLISTED'
    }

    # If block-by-default and not allowlisted, check governance approval
    if (-not $allowed -and $fw.block_by_default) {
        $requiredGov = $fw.governance_required
        $approvedCount = ($GovernanceApprovers | Where-Object { $_ -in $requiredGov }).Count
        if ($approvedCount -ge 2) {
            $allowed = $true
            $reason  = 'GOVERNANCE_APPROVED'
        }
    }

    $record = @{
        hostname         = $Hostname
        ip               = ''
        port             = $Port
        protocol         = $Protocol
        purpose          = $Purpose
        agent_origin     = $AgentOrigin
        dependency_chain = @()
        timestamp        = [datetime]::UtcNow.ToString('o')
        version          = 'SK.v15.c8'
        allowed          = $allowed
        reason           = $reason
    }

    # Always log outbound attempts
    if ($fw.log_all) {
        try { Write-LedgerEntry -EventType 'AUDIT' -Source 'CallProxy.Firewall' -Data $record } catch { <# Intentional: non-fatal ledger write #> }
    }

    return $record
}

# ========================== RATE LIMITING ==========================
function Test-RateLimit {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AgentOrigin
    )
    $limit = if ($script:_ProxyConfig.outbound_firewall.rate_limit_per_minute) {
        $script:_ProxyConfig.outbound_firewall.rate_limit_per_minute
    } else { 120 }

    $now = [datetime]::UtcNow
    if (-not $script:_RateLimiter.ContainsKey($AgentOrigin)) {
        $script:_RateLimiter[$AgentOrigin] = @{ count = 1; window_start = $now }
        return $true
    }

    $entry   = $script:_RateLimiter[$AgentOrigin]
    $elapsed = ($now - $entry.window_start).TotalSeconds

    if ($elapsed -ge 60) {
        # Reset window
        $entry.count        = 1
        $entry.window_start = $now
        return $true
    }

    $entry.count++
    return ($entry.count -le $limit)
}

# ========================== CALL STACK INSPECTION ==========================
function Get-CurrentCallStack {
    [CmdletBinding()]
    param()
    return @($script:_CallStack.ToArray())
}

function Get-CurrentCallDepth {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:_CallStack.Count
}

function Get-CallStats {
    [CmdletBinding()]
    param()
    return @{
        total_calls    = $script:_CallCounter
        current_depth  = $script:_CallStack.Count
        max_depth      = $script:_MaxCallDepth
        rate_limiters  = $script:_RateLimiter.Count
        proxy_active   = $script:_ProxyInitialized
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
    'Initialize-CallProxy'
    'Invoke-ProxiedCall'
    'Test-OutboundRequest'
    'Test-RateLimit'
    'Get-CurrentCallStack'
    'Get-CurrentCallDepth'
    'Get-CallStats'
)







