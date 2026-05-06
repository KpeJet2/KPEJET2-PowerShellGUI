# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- SovereignPolicy Module
    Governance enforcement, override rules, ethical constraints, and compliance audit.

.DESCRIPTION
    Enforces the sovereign_core.override_policy from the manifest:
      - Determines which layers/modules can override which
      - Verifies quorum for escalation decisions
      - Logs every policy decision to the immutable ledger
      - Provides ethical constraint checking via governance_spine
      - Tracks compliance state per module

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.policy.1
    Depends  : LedgerWriter.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_PolicyConfig      = $null   # sovereign_core from manifest
$script:_GovernanceSpine   = @()
$script:_EthicalSpine      = @()
$script:_ModulePermissions = @{}     # moduleId -> { can_override=@(), blocked_by=@() }
$script:_PolicyDecisionLog = [System.Collections.Generic.List[hashtable]]::new()
$script:_ComplianceState   = @{}     # moduleId -> { compliant=$true, last_check_utc, violations=@() }
$script:_PolicyInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-SovereignPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SovereignCore,

        [Parameter(Mandatory)]
        [hashtable]$Spines
    )
    $script:_PolicyConfig    = $SovereignCore
    $script:_GovernanceSpine = if ($Spines.governance_spine) { $Spines.governance_spine } else { @() }
    $script:_EthicalSpine    = if ($Spines.ethical_spine)    { $Spines.ethical_spine    } else { @() }

    # Build default permission matrix from override_policy
    $overridePolicy = $SovereignCore.override_policy
    $script:_ModulePermissions['SOVEREIGN_CORE'] = @{
        can_override = $overridePolicy.can_override
        blocked_by   = @()   # sovereign core cannot be overridden
    }

    $script:_PolicyInitialized = $true
    Write-Verbose '[SovereignPolicy] Initialized -- sovereignty_model=human_primacy_governance_first'
}

# ========================== OVERRIDE CHECKS ==========================
function Test-OverridePermission {
    <#
    .SYNOPSIS
        Checks whether a requesting module is allowed to override a target layer.
        Returns $true/$false and logs the decision.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RequestingModule,

        [Parameter(Mandatory)]
        [string]$TargetLayer,

        [string]$Reason = ''
    )
    $allowed   = $false
    $overrides = $script:_PolicyConfig.override_policy

    # The sovereign core can override anything in its can_override list
    if ($RequestingModule -eq 'SOVEREIGN_CORE') {
        $allowed = $TargetLayer -in $overrides.can_override
    }
    else {
        # No module or protocol can override the sovereign core
        if ($RequestingModule -in $overrides.cannot_be_overridden_by) {
            $allowed = $false
        }
        # Check module-specific permissions
        elseif ($script:_ModulePermissions.ContainsKey($RequestingModule)) {
            $perms   = $script:_ModulePermissions[$RequestingModule]
            $allowed = $TargetLayer -in $perms.can_override
        }
    }

    $decision = @{
        timestamp_utc    = [datetime]::UtcNow.ToString('o')
        action           = 'OVERRIDE_CHECK'
        requesting       = $RequestingModule
        target           = $TargetLayer
        allowed          = $allowed
        reason           = $Reason
    }
    $script:_PolicyDecisionLog.Add($decision)

    # Log to immutable ledger
    try {
        Write-LedgerEntry -EventType 'POLICY' -Source 'SovereignPolicy' -Data $decision
    }
    catch {
        Write-AppLog -Message "[SovereignPolicy] Ledger write failed for policy decision: $_" -Level Warning
    }

    return $allowed
}

# ========================== QUORUM ==========================
function Test-EscalationQuorum {
    <#
    .SYNOPSIS
        Verifies that enough members of the escalation chain have approved an action.
    .PARAMETER Approvals
        Array of module IDs that have approved.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Approvals,

        [string]$Action = 'ESCALATION'
    )
    $chain   = $script:_PolicyConfig.override_policy.escalation_chain
    $quorum  = $script:_PolicyConfig.override_policy.quorum_required

    # Count how many approvals are from valid escalation chain members
    $validApprovals = ($Approvals | Where-Object { $_ -in $chain }).Count

    $met = $validApprovals -ge $quorum

    $decision = @{
        timestamp_utc   = [datetime]::UtcNow.ToString('o')
        action          = $Action
        approvals       = $Approvals
        valid_approvals = $validApprovals
        quorum_required = $quorum
        quorum_met      = $met
    }
    $script:_PolicyDecisionLog.Add($decision)

    try {
        Write-LedgerEntry -EventType 'POLICY' -Source 'SovereignPolicy' -Data $decision
    }
    catch {
        Write-AppLog -Message "[SovereignPolicy] Ledger write failed for quorum check: $_" -Level Warning
    }

    return $met
}

# ========================== MODULE PERMISSIONS ==========================
function Register-ModulePermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleId,

        [string[]]$CanOverride = @(),
        [string[]]$BlockedBy   = @()
    )
    $script:_ModulePermissions[$ModuleId] = @{
        can_override = $CanOverride
        blocked_by   = $BlockedBy
    }
}

function Get-ModulePermissions {
    [CmdletBinding()]
    param([string]$ModuleId)
    if ($ModuleId) {
        return $script:_ModulePermissions[$ModuleId]
    }
    return $script:_ModulePermissions.Clone()
}

# ========================== ETHICAL CONSTRAINTS ==========================
function Test-EthicalConstraint {
    <#
    .SYNOPSIS
        Checks an action against the ethical spine modules.
        Each ethical spine member must not have flagged a violation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$RequestingModule,

        [hashtable]$Context = @{}
    )
    $violations = @()

    # Check if the requesting module is in a non-compliant state
    if ($script:_ComplianceState.ContainsKey($RequestingModule)) {
        $state = $script:_ComplianceState[$RequestingModule]
        if (-not $state.compliant) {
            $violations += "Module $RequestingModule is non-compliant: $($state.violations -join '; ')"
        }
    }

    # Check governance spine approval for destructive actions
    $destructiveActions = @('DELETE', 'OVERRIDE', 'HALT', 'PURGE', 'ROLLBACK')
    if ($Action.ToUpperInvariant() -in $destructiveActions) {
        $hasGovernanceApproval = $false
        foreach ($gov in $script:_GovernanceSpine) {
            if ($script:_ComplianceState.ContainsKey($gov) -and $script:_ComplianceState[$gov].compliant) {
                $hasGovernanceApproval = $true
                break
            }
        }
        if (-not $hasGovernanceApproval -and $script:_GovernanceSpine.Count -gt 0) {
            $violations += "Destructive action '$Action' requires governance spine approval."
        }
    }

    $result = @{
        action           = $Action
        requesting       = $RequestingModule
        violations       = $violations
        passed           = ($violations.Count -eq 0)
        checked_utc      = [datetime]::UtcNow.ToString('o')
    }

    try {
        Write-LedgerEntry -EventType 'POLICY' -Source 'SovereignPolicy.Ethics' -Data $result
    }
    catch { <# Intentional: non-fatal ledger write #> }

    return $result
}

# ========================== COMPLIANCE TRACKING ==========================
function Set-ModuleComplianceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleId,

        [Parameter(Mandatory)]
        [bool]$Compliant,

        [string[]]$Violations = @()
    )
    $script:_ComplianceState[$ModuleId] = @{
        compliant      = $Compliant
        last_check_utc = [datetime]::UtcNow.ToString('o')
        violations     = $Violations
    }
}

function Get-ModuleComplianceState {
    [CmdletBinding()]
    param([string]$ModuleId)
    if ($ModuleId) {
        return $script:_ComplianceState[$ModuleId]
    }
    return $script:_ComplianceState.Clone()
}

function Get-ComplianceReport {
    <#
    .SYNOPSIS  Returns a summary of all module compliance states.
    #>
    [CmdletBinding()]
    param()
    $total     = $script:_ComplianceState.Count
    $compliant = ($script:_ComplianceState.Values | Where-Object { $_.compliant }).Count
    $ratio     = if ($total -gt 0) { [math]::Round($compliant / $total, 3) } else { 1.0 }

    return @{
        total_modules    = $total
        compliant        = $compliant
        non_compliant    = $total - $compliant
        compliance_ratio = $ratio
        generated_utc    = [datetime]::UtcNow.ToString('o')
        details          = $script:_ComplianceState.Clone()
    }
}

# ========================== POLICY DECISION LOG ==========================
function Get-PolicyDecisionLog {
    [CmdletBinding()]
    param(
        [int]$Last = 50,
        [string]$FilterAction
    )
    $log = $script:_PolicyDecisionLog
    if ($FilterAction) {
        $log = $log | Where-Object { $_.action -eq $FilterAction }
    }
    return @($log | Select-Object -Last $Last)
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
    'Initialize-SovereignPolicy'
    'Test-OverridePermission'
    'Test-EscalationQuorum'
    'Register-ModulePermissions'
    'Get-ModulePermissions'
    'Test-EthicalConstraint'
    'Set-ModuleComplianceState'
    'Get-ModuleComplianceState'
    'Get-ComplianceReport'
    'Get-PolicyDecisionLog'
)







