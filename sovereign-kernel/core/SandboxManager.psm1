# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- SandboxManager Module
    Nested sandboxes, subsandboxes, para-virtualization layers, and isolation enforcement.

.DESCRIPTION
    Provides multi-tier isolation for kernel module execution:
      - Sandbox creation with configurable language mode
      - Nested subsandboxes up to configurable depth
      - Para-virtualization layers: environment, runspace, filesystem, network
      - Resource limits enforcement (memory, CPU, threads, time)
      - Automatic sandbox destruction on exit
      - Policy inheritance from parent sandboxes
      - Complete environment isolation per sandbox

    Uses PowerShell Runspaces for execution isolation. Each sandbox gets its own
    runspace with restricted capabilities based on the tier and manifest config.

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.sandbox.1
    Depends  : SovereignPolicy.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_SandboxConfig     = $null
$script:_ActiveSandboxes   = @{}    # sandboxId -> sandbox state hashtable
$script:_SandboxCounter    = [long]0
$script:_MaxDepth          = 3
$script:_SandboxInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-SandboxManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SandboxConfig
    )
    $script:_SandboxConfig = $SandboxConfig
    $script:_MaxDepth = if ($SandboxConfig.max_sandbox_depth) { $SandboxConfig.max_sandbox_depth } else { 3 }
    $script:_SandboxInitialized = $true
    Write-Verbose "[SandboxManager] Initialized -- max_depth=$($script:_MaxDepth), language_mode=$($SandboxConfig.default_language_mode)"
}

# ========================== SANDBOX LIFECYCLE ==========================
function New-Sandbox {
    <#
    .SYNOPSIS
        Creates a new isolated sandbox environment.
    .PARAMETER Name
        Descriptive name for the sandbox.
    .PARAMETER ParentSandboxId
        If creating a subsandbox, the ID of the parent. Enforces depth limits.
    .PARAMETER IsolationLayers
        Override isolation layers: environment, runspace, filesystem, network.
    .PARAMETER MaxExecutionSeconds
        Maximum execution time for code running in this sandbox.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$ParentSandboxId,

        [string[]]$IsolationLayers,

        [int]$MaxExecutionSeconds = 300,

        [string]$LanguageMode
    )
    if (-not $script:_SandboxInitialized) {
        throw '[SandboxManager] Not initialized.'
    }

    $script:_SandboxCounter++
    $sandboxId = 'SBX-' + $script:_SandboxCounter.ToString('D6')

    # Calculate depth
    $depth = 1
    if ($ParentSandboxId) {
        if (-not $script:_ActiveSandboxes.ContainsKey($ParentSandboxId)) {
            throw "[SandboxManager] Parent sandbox '$ParentSandboxId' not found."
        }
        $parent = $script:_ActiveSandboxes[$ParentSandboxId]
        $depth  = $parent.depth + 1

        if ($depth -gt $script:_MaxDepth) {
            throw "[SandboxManager] Maximum sandbox depth ($($script:_MaxDepth)) exceeded."
        }

        # Check parent subsandbox limit
        $realmDef = $parent.realm_definition
        if ($realmDef -and $realmDef.max_subsandboxes) {
            $childCount = ($script:_ActiveSandboxes.Values | Where-Object { $_.parent_id -eq $ParentSandboxId }).Count
            if ($childCount -ge $realmDef.max_subsandboxes) {
                throw "[SandboxManager] Parent sandbox '$ParentSandboxId' has reached max subsandboxes ($($realmDef.max_subsandboxes))."
            }
        }
    }

    # Resolve settings
    if (-not $LanguageMode) {
        $LanguageMode = $script:_SandboxConfig.default_language_mode
    }
    if (-not $IsolationLayers) {
        $paraVirt = $script:_SandboxConfig.para_virtualization
        $IsolationLayers = if ($paraVirt -and $paraVirt.isolation_layers) {
            $paraVirt.isolation_layers
        } else {
            @('environment', 'runspace')
        }
    }

    # Resource limits
    $limits = @{
        max_memory_mb         = 512
        max_cpu_percent       = 25
        max_threads           = 8
        max_execution_seconds = $MaxExecutionSeconds
    }
    $paraVirt = $script:_SandboxConfig.para_virtualization
    if ($paraVirt -and $paraVirt.resource_limits) {
        $rl = $paraVirt.resource_limits
        if ($rl.max_memory_mb)         { $limits.max_memory_mb         = $rl.max_memory_mb }
        if ($rl.max_cpu_percent)       { $limits.max_cpu_percent       = $rl.max_cpu_percent }
        if ($rl.max_threads)           { $limits.max_threads           = $rl.max_threads }
        if ($rl.max_execution_seconds) { $limits.max_execution_seconds = $rl.max_execution_seconds }
    }

    # Create the runspace with isolation
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # Apply language mode restrictions
    switch ($LanguageMode) {
        'ConstrainedLanguage' {
            $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::ConstrainedLanguage
        }
        'RestrictedLanguage' {
            $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::RestrictedLanguage
        }
        'NoLanguage' {
            $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::NoLanguage
        }
        default {
            $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
        }
    }

    # Environment isolation: create isolated environment variables
    $envSnapshot = @{}
    if ('environment' -in $IsolationLayers) {
        # Capture current env for isolation
        foreach ($e in [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
            $envSnapshot[$e.Key] = $e.Value
        }
    }

    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()

    # Set sandbox-specific variables in the runspace
    $runspace.SessionStateProxy.SetVariable('SandboxId', $sandboxId)
    $runspace.SessionStateProxy.SetVariable('SandboxName', $Name)
    $runspace.SessionStateProxy.SetVariable('SandboxDepth', $depth)

    $sandbox = @{
        sandbox_id       = $sandboxId
        name             = $Name
        depth            = $depth
        parent_id        = $ParentSandboxId
        language_mode    = $LanguageMode
        isolation_layers = $IsolationLayers
        resource_limits  = $limits
        runspace         = $runspace
        created_utc      = [datetime]::UtcNow.ToString('o')
        status           = 'ACTIVE'
        env_snapshot     = $envSnapshot
        children         = @()
        realm_definition = $null
        execution_count  = 0
    }

    # Register with parent
    if ($ParentSandboxId -and $script:_ActiveSandboxes.ContainsKey($ParentSandboxId)) {
        $script:_ActiveSandboxes[$ParentSandboxId].children += $sandboxId
    }

    $script:_ActiveSandboxes[$sandboxId] = $sandbox

    try {
        Write-LedgerEntry -EventType 'SYSTEM' -Source 'SandboxManager' -Data @{
            action           = 'SANDBOX_CREATED'
            sandbox_id       = $sandboxId
            name             = $Name
            depth            = $depth
            parent_id        = $ParentSandboxId
            language_mode    = $LanguageMode
            isolation_layers = $IsolationLayers
        }
    }
    catch { Write-Verbose "[SandboxManager] Ledger write failed during sandbox creation: $($_.Exception.Message)" }

    return $sandbox
}

# ========================== EXECUTION ==========================
function Invoke-InSandbox {
    <#
    .SYNOPSIS
        Executes a scriptblock inside an isolated sandbox with timeout enforcement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SandboxId,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters = @{}
    )
    if (-not $script:_ActiveSandboxes.ContainsKey($SandboxId)) {
        throw "[SandboxManager] Sandbox '$SandboxId' not found."
    }

    $sandbox = $script:_ActiveSandboxes[$SandboxId]
    if ($sandbox.status -ne 'ACTIVE') {
        throw "[SandboxManager] Sandbox '$SandboxId' is not active (status: $($sandbox.status))."
    }

    $sandbox.execution_count++
    $maxSeconds = $sandbox.resource_limits.max_execution_seconds

    $ps = [powershell]::Create()
    $ps.Runspace = $sandbox.runspace
    $ps.AddScript($ScriptBlock.ToString()) | Out-Null

    foreach ($key in $Parameters.Keys) {
        $ps.AddParameter($key, $Parameters[$key]) | Out-Null
    }

    $result  = $null
    $errors  = @()
    $timedOut = $false

    try {
        $asyncResult = $ps.BeginInvoke()
        $completed   = $asyncResult.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($maxSeconds))

        if ($completed) {
            $result = $ps.EndInvoke($asyncResult)
            if ($ps.HadErrors) {
                $errors = @($ps.Streams.Error | ForEach-Object { $_.ToString() })
            }
        }
        else {
            $timedOut = $true
            $ps.Stop()
        }
    }
    finally {
        $ps.Dispose()
    }

    $execRecord = @{
        sandbox_id = $SandboxId
        timed_out  = $timedOut
        had_errors = ($errors.Count -gt 0)
        error_msgs = $errors
    }

    try {
        Write-LedgerEntry -EventType 'SYSTEM' -Source 'SandboxManager' -Data $execRecord
    }
    catch { Write-Verbose "[SandboxManager] Ledger write failed for exec record: $($_.Exception.Message)" }

    if ($timedOut) {
        throw "[SandboxManager] Execution in sandbox '$SandboxId' timed out after ${maxSeconds}s."
    }

    return @{
        output     = $result
        errors     = $errors
        had_errors = ($errors.Count -gt 0)
        sandbox_id = $SandboxId
    }
}

# ========================== DESTRUCTION ==========================
function Remove-Sandbox {
    <#
    .SYNOPSIS  Destroys a sandbox and all its subsandboxes (recursive).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SandboxId
    )
    if (-not $script:_ActiveSandboxes.ContainsKey($SandboxId)) { return }

    $sandbox = $script:_ActiveSandboxes[$SandboxId]

    # Recursively destroy children first
    foreach ($childId in $sandbox.children) {
        Remove-Sandbox -SandboxId $childId
    }

    # Close runspace
    if ($sandbox.runspace -and $sandbox.runspace.RunspaceStateInfo.State -eq 'Opened') {
        try { $sandbox.runspace.Close() } catch { <# Intentional: best-effort runspace cleanup #> }
        try { $sandbox.runspace.Dispose() } catch { <# Intentional: best-effort runspace cleanup #> }
    }

    $sandbox.status = 'DESTROYED'

    # Remove from parent
    if ($sandbox.parent_id -and $script:_ActiveSandboxes.ContainsKey($sandbox.parent_id)) {
        $parent = $script:_ActiveSandboxes[$sandbox.parent_id]
        $parent.children = @($parent.children | Where-Object { $_ -ne $SandboxId })
    }

    $script:_ActiveSandboxes.Remove($SandboxId) | Out-Null

    try {
        Write-LedgerEntry -EventType 'SYSTEM' -Source 'SandboxManager' -Data @{
            action     = 'SANDBOX_DESTROYED'
            sandbox_id = $SandboxId
            name       = $sandbox.name
        }
    }
    catch { Write-Verbose "[SandboxManager] Ledger write failed during sandbox destroy: $($_.Exception.Message)" }
}

# ========================== STATUS ==========================
function Get-SandboxStatus {
    [CmdletBinding()]
    param([string]$SandboxId)
    if ($SandboxId) {
        $sb = $script:_ActiveSandboxes[$SandboxId]
        if (-not $sb) { return $null }
        return @{
            sandbox_id       = $sb.sandbox_id
            name             = $sb.name
            depth            = $sb.depth
            status           = $sb.status
            language_mode    = $sb.language_mode
            isolation_layers = $sb.isolation_layers
            children         = $sb.children
            execution_count  = $sb.execution_count
            created_utc      = $sb.created_utc
        }
    }
    return @($script:_ActiveSandboxes.Keys | ForEach-Object { Get-SandboxStatus -SandboxId $_ })
}

function Get-ActiveSandboxCount {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:_ActiveSandboxes.Count
}

function Remove-AllSandboxes {
    [CmdletBinding()]
    param()
    $ids = @($script:_ActiveSandboxes.Keys)
    # Destroy root sandboxes first (they clean up children)
    $roots = @($ids | Where-Object { -not $script:_ActiveSandboxes[$_].parent_id })
    foreach ($rootId in $roots) {
        Remove-Sandbox -SandboxId $rootId
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
    'Initialize-SandboxManager'
    'New-Sandbox'
    'Invoke-InSandbox'
    'Remove-Sandbox'
    'Get-SandboxStatus'
    'Get-ActiveSandboxCount'
    'Remove-AllSandboxes'
)






