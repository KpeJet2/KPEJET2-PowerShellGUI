# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- AgentRegistry Module
    Maps symbolic module names to handlers, manages dependency graphs, health, and lazy loading.

.DESCRIPTION
    Central registry for all kernel modules (meta, operational, transcendent, reflexive,
    watchdogs, realm keepers). Provides:
      - Symbolic name to handler binding
      - Dependency graph resolution with topological sort
      - Lazy loading with on-demand initialization
      - Health status tracking per module
      - Capability enumeration
      - Hot-standby failover routing

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.registry.1
    Depends  : SovereignPolicy.psm1, LedgerWriter.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_Registry          = @{}     # moduleId -> registration hashtable
$script:_DependencyGraph   = @{}     # moduleId -> @(dependsOn...)
$script:_HealthStatus      = @{}     # moduleId -> { status, last_check_utc, failures }
$script:_BootOrder         = @()     # topologically sorted module IDs
$script:_RegistryInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-AgentRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Manifest
    )
    $kernel = $Manifest.sovereign_kernel

    # Register all module categories
    $categories = @(
        @{ Source = $kernel.meta_modules;        Tier = 'meta'         }
        @{ Source = $kernel.operational_modules;  Tier = 'operational'  }
        @{ Source = $kernel.transcendent_ring;    Tier = 'transcendent' }
        @{ Source = $kernel.reflexive_crown;      Tier = 'reflexive'    }
        @{ Source = $kernel.watchdogs;            Tier = 'watchdog'     }
    )

    foreach ($cat in $categories) {
        if ($cat.Source -and $cat.Source -is [hashtable]) {
            foreach ($key in $cat.Source.Keys) {
                $def = $cat.Source[$key]
                $reg = @{
                    ModuleId    = $key
                    Tier        = $cat.Tier
                    Definition  = $def
                    Handler     = $null       # bound later
                    Loaded      = $false
                    BootPriority = if ($def.priority) { $def.priority } else { 99 }
                    AutoHeal    = if ($null -ne $def.auto_heal) { $def.auto_heal } else { $false }
                    HotStandby  = if ($null -ne $def.hot_standby) { $def.hot_standby } else { $false }
                }
                $script:_Registry[$key] = $reg
                $script:_HealthStatus[$key] = @{
                    status         = 'NOT_STARTED'
                    last_check_utc = $null
                    failures       = 0
                    consecutive_ok = 0
                }
            }
        }
    }

    # Register realm keepers
    foreach ($realmKey in @('above','within','below')) {
        if ($kernel.realms -and $kernel.realms[$realmKey]) {
            $realm = $kernel.realms[$realmKey]
            $keeperId = $realm.keeper_module
            if (-not $script:_Registry.ContainsKey($keeperId)) {
                $script:_Registry[$keeperId] = @{
                    ModuleId     = $keeperId
                    Tier         = 'realm_keeper'
                    Definition   = $realm
                    Handler      = $null
                    Loaded       = $false
                    BootPriority = 50
                    AutoHeal     = $true
                    HotStandby   = $false
                }
                $script:_HealthStatus[$keeperId] = @{
                    status         = 'NOT_STARTED'
                    last_check_utc = $null
                    failures       = 0
                    consecutive_ok = 0
                }
            }
        }
    }

    # Register spine members if not already present
    if ($kernel.spines) {
        foreach ($spineKey in $kernel.spines.Keys) {
            $members = $kernel.spines[$spineKey]
            foreach ($memberId in $members) {
                if (-not $script:_Registry.ContainsKey($memberId)) {
                    $script:_Registry[$memberId] = @{
                        ModuleId     = $memberId
                        Tier         = 'spine_member'
                        Definition   = @{ spine = $spineKey }
                        Handler      = $null
                        Loaded       = $false
                        BootPriority = 75
                        AutoHeal     = $false
                        HotStandby   = $false
                    }
                    $script:_HealthStatus[$memberId] = @{
                        status         = 'NOT_STARTED'
                        last_check_utc = $null
                        failures       = 0
                        consecutive_ok = 0
                    }
                }
            }
        }
    }

    $script:_RegistryInitialized = $true
    Write-Verbose "[AgentRegistry] Registered $($script:_Registry.Count) modules across all tiers."
}

# ========================== REGISTRATION ==========================
function Register-ModuleHandler {
    <#
    .SYNOPSIS  Binds a handler (scriptblock or module info) to a registered module ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleId,

        [Parameter(Mandatory)]
        [object]$Handler,

        [string[]]$DependsOn = @()
    )
    if (-not $script:_Registry.ContainsKey($ModuleId)) {
        throw "[AgentRegistry] Module '$ModuleId' is not registered in the manifest."
    }
    $script:_Registry[$ModuleId].Handler = $Handler
    $script:_Registry[$ModuleId].Loaded  = $true
    $script:_DependencyGraph[$ModuleId]  = $DependsOn

    $script:_HealthStatus[$ModuleId].status = 'LOADED'
    $script:_HealthStatus[$ModuleId].last_check_utc = [datetime]::UtcNow.ToString('o')

    try {
        Write-LedgerEntry -EventType 'SYSTEM' -Source 'AgentRegistry' -Data @{
            action    = 'HANDLER_BOUND'
            module_id = $ModuleId
            depends   = $DependsOn
        }
    }
    catch { <# Intentional: non-fatal ledger write #> }
}

function Get-RegisteredModule {
    [CmdletBinding()]
    param([string]$ModuleId)
    if ($ModuleId) {
        return $script:_Registry[$ModuleId]
    }
    return $script:_Registry.Clone()
}

# ========================== DEPENDENCY RESOLUTION ==========================
function Resolve-BootOrder {
    <#
    .SYNOPSIS  Topological sort of modules by dependency graph + boot priority.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $visited  = @{}
    $order    = [System.Collections.Generic.List[string]]::new()

    function Visit-Node {
        param([string]$NodeId)
        if ($visited.ContainsKey($NodeId)) {
            if ($visited[$NodeId] -eq 'IN_PROGRESS') {
                Write-AppLog -Message "[AgentRegistry] Circular dependency detected at $NodeId" -Level Warning
            }
            return
        }
        $visited[$NodeId] = 'IN_PROGRESS'
        if ($script:_DependencyGraph.ContainsKey($NodeId)) {
            foreach ($dep in $script:_DependencyGraph[$NodeId]) {
                Visit-Node -NodeId $dep
            }
        }
        $visited[$NodeId] = 'DONE'
        $order.Add($NodeId)
    }

    # Sort by priority first, then resolve dependencies
    $sortedKeys = $script:_Registry.Keys | Sort-Object {
        $script:_Registry[$_].BootPriority
    }
    foreach ($moduleId in $sortedKeys) {
        Visit-Node -NodeId $moduleId
    }

    $script:_BootOrder = $order.ToArray()
    return $script:_BootOrder
}

function Get-BootOrder {
    [CmdletBinding()]
    param()
    if ($script:_BootOrder.Count -eq 0) {
        return Resolve-BootOrder
    }
    return $script:_BootOrder
}

# ========================== HEALTH ==========================
function Update-ModuleHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleId,

        [Parameter(Mandatory)]
        [ValidateSet('HEALTHY','DEGRADED','FAILED','NOT_STARTED','LOADED','HEALING')]
        [string]$Status
    )
    if (-not $script:_HealthStatus.ContainsKey($ModuleId)) {
        $script:_HealthStatus[$ModuleId] = @{ status='NOT_STARTED'; last_check_utc=$null; failures=0; consecutive_ok=0 }
    }
    $h = $script:_HealthStatus[$ModuleId]
    $h.status         = $Status
    $h.last_check_utc = [datetime]::UtcNow.ToString('o')

    if ($Status -eq 'HEALTHY') {
        $h.consecutive_ok++
        $h.failures = 0
    }
    elseif ($Status -in @('FAILED','DEGRADED')) {
        $h.failures++
        $h.consecutive_ok = 0
    }
}

function Get-ModuleHealth {
    [CmdletBinding()]
    param([string]$ModuleId)
    if ($ModuleId) {
        return $script:_HealthStatus[$ModuleId]
    }
    return $script:_HealthStatus.Clone()
}

function Get-HealthScore {
    <#
    .SYNOPSIS  Returns overall kernel health as a ratio (0.0 to 1.0).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()
    $total   = $script:_HealthStatus.Count
    if ($total -eq 0) { return 1.0 }
    $healthy = ($script:_HealthStatus.Values | Where-Object { $_.status -in @('HEALTHY','LOADED') }).Count
    return [math]::Round($healthy / $total, 3)
}

function Get-FailedModules {
    [CmdletBinding()]
    param()
    return @($script:_HealthStatus.GetEnumerator() |
        Where-Object { $_.Value.status -in @('FAILED','DEGRADED') } |
        ForEach-Object { $_.Key })
}

function Get-AutoHealCandidates {
    [CmdletBinding()]
    param()
    $failed = Get-FailedModules
    return @($failed | Where-Object {
        $script:_Registry.ContainsKey($_) -and $script:_Registry[$_].AutoHeal
    })
}

# ========================== CAPABILITY ENUMERATION ==========================
function Get-ModulesByTier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Tier
    )
    return @($script:_Registry.GetEnumerator() |
        Where-Object { $_.Value.Tier -eq $Tier } |
        ForEach-Object { $_.Key })
}

function Get-ModulesBySpine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SpineName,

        [Parameter(Mandatory)]
        [hashtable]$Spines
    )
    if ($Spines.ContainsKey($SpineName)) {
        return $Spines[$SpineName]
    }
    return @()
}

function Get-HotStandbyModules {
    [CmdletBinding()]
    param()
    return @($script:_Registry.GetEnumerator() |
        Where-Object { $_.Value.HotStandby -eq $true } |
        ForEach-Object { $_.Key })
}

function Register-ExternalAgent {
    <#
    .SYNOPSIS  Registers an external agent (e.g. koe-RumA, H-Ai-Nikr-Agi) at runtime with optional health-check hook.
    .NOTES     gap-2604-014: Allows registering agents that are not present in the sovereign manifest.
               Agents registered here are always tier='external'. Existing registrations are skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId,

        [Parameter(Mandatory)]
        [string]$Function,

        [Parameter()]
        [scriptblock]$HealthCheckHook,

        [Parameter()]
        [bool]$AutoHeal = $true,

        [Parameter()]
        [string[]]$DependsOn = @()
    )

    if ($script:_Registry.ContainsKey($AgentId)) {
        Write-Verbose "[AgentRegistry] External agent '$AgentId' already registered - skipping."
        return
    }

    $script:_Registry[$AgentId] = @{
        ModuleId        = $AgentId
        Tier            = 'external'
        Definition      = @{ function = $Function; tier = 'external'; auto_heal = $AutoHeal }
        Handler         = $null
        Loaded          = $false
        BootPriority    = 90
        AutoHeal        = $AutoHeal
        HotStandby      = $false
        HealthCheckHook = $HealthCheckHook
    }
    $script:_HealthStatus[$AgentId] = @{
        status          = 'REGISTERED'
        last_check_utc  = $null
        failures        = 0
        consecutive_ok  = 0
    }
    $script:_DependencyGraph[$AgentId] = $DependsOn

    Write-Verbose "[AgentRegistry] External agent '$AgentId' ($Function) registered."

    try {
        Write-LedgerEntry -EventType 'SYSTEM' -Source 'AgentRegistry' -Data @{
            action    = 'EXTERNAL_AGENT_REGISTERED'
            module_id = $AgentId
            function  = $Function
        }
    }
    catch { <# Intentional: non-fatal #> }
}

function Invoke-AgentHealthCheck {
    <#
    .SYNOPSIS  Runs the HealthCheckHook for an external agent (if defined) and updates health status.
    .NOTES     gap-2604-014
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId
    )

    if (-not $script:_Registry.ContainsKey($AgentId)) {
        throw "[AgentRegistry] Agent '$AgentId' is not registered."
    }

    $entry = $script:_Registry[$AgentId]
    $hook  = $entry.HealthCheckHook

    $health = $script:_HealthStatus[$AgentId]
    $health.last_check_utc = [datetime]::UtcNow.ToString('o')

    if ($null -ne $hook) {
        try {
            $result = & $hook
            $ok = ($result -is [bool] -and $result) -or ($result -is [hashtable] -and $result.ok) -or ($result -is [PSCustomObject] -and $result.ok)
            if ($ok) {
                $health.status         = 'HEALTHY'
                $health.consecutive_ok++
                $health.failures       = 0
            } else {
                $health.status    = 'DEGRADED'
                $health.failures++
                $health.consecutive_ok = 0
            }
        } catch {
            $health.status    = 'FAILED'
            $health.failures++
            $health.consecutive_ok = 0
        }
    } else {
        $health.status = 'HEALTHY'
        $health.consecutive_ok++
    }

    return [PSCustomObject]@{
        agentId        = $AgentId
        status         = $health.status
        last_check_utc = $health.last_check_utc
        failures       = $health.failures
        consecutive_ok = $health.consecutive_ok
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
    'Initialize-AgentRegistry'
    'Register-ModuleHandler'
    'Register-ExternalAgent'
    'Invoke-AgentHealthCheck'
    'Get-RegisteredModule'
    'Resolve-BootOrder'
    'Get-BootOrder'
    'Update-ModuleHealth'
    'Get-ModuleHealth'
    'Get-HealthScore'
    'Get-FailedModules'
    'Get-AutoHealCandidates'
    'Get-ModulesByTier'
    'Get-ModulesBySpine'
    'Get-HotStandbyModules'
)








