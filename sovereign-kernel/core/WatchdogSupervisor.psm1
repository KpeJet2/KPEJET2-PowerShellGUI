# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- WatchdogSupervisor Module
    Implements CASPAR / MELCHIOR / BALTHAZAR 2-of-3 voting tribunal.

.DESCRIPTION
    Three independent watchdog modules monitor kernel integrity, ethical compliance,
    and predictive anomalies. Any two can halt the kernel:
      - CASPAR:    integrity breach detection (hash mismatch, tamper, corruption)
      - MELCHIOR:  ethical breach detection (policy violation, governance bypass)
      - BALTHAZAR: predictive anomaly detection (drift, regression, behavioral shift)

    Voting model: 2-of-3 required to trigger a kernel action (halt, quarantine, rollback).
    All votes are recorded immutably in the ledger.

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.watchdog.1
    Depends  : LedgerWriter.psm1, SovereignPolicy.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_WatchdogConfig    = @{}    # watchdog definitions from manifest
$script:_ActiveAlerts      = [System.Collections.Generic.List[hashtable]]::new()
$script:_VoteHistory       = [System.Collections.Generic.List[hashtable]]::new()
$script:_WatchdogState     = @{
    CASPAR    = @{ active = $true;  last_triggered_utc = $null; trigger_count = 0 }
    MELCHIOR  = @{ active = $true;  last_triggered_utc = $null; trigger_count = 0 }
    BALTHAZAR = @{ active = $true;  last_triggered_utc = $null; trigger_count = 0 }
}
$script:_KernelHalted      = $false
$script:_WatchdogInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-WatchdogSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$WatchdogConfig
    )
    $script:_WatchdogConfig = $WatchdogConfig
    foreach ($key in $WatchdogConfig.Keys) {
        if (-not $script:_WatchdogState.ContainsKey($key)) {
            $script:_WatchdogState[$key] = @{
                active             = $true
                last_triggered_utc = $null
                trigger_count      = 0
            }
        }
    }
    $script:_WatchdogInitialized = $true
    Write-Verbose '[WatchdogSupervisor] Initialized -- CASPAR, MELCHIOR, BALTHAZAR online.'
}

# ========================== ALERT SUBMISSION ==========================
function Submit-WatchdogAlert {
    <#
    .SYNOPSIS
        A watchdog submits an alert for tribunal review.
    .PARAMETER WatchdogId
        CASPAR, MELCHIOR, or BALTHAZAR.
    .PARAMETER TriggerType
        The type of breach detected.
    .PARAMETER Evidence
        Hashtable of evidence data.
    .PARAMETER RequestHalt
        Whether this watchdog requests a kernel halt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CASPAR','MELCHIOR','BALTHAZAR')]
        [string]$WatchdogId,

        [Parameter(Mandatory)]
        [string]$TriggerType,

        [hashtable]$Evidence = @{},

        [bool]$RequestHalt = $false
    )
    if (-not $script:_WatchdogInitialized) {
        throw '[WatchdogSupervisor] Not initialized.'
    }

    $alert = @{
        alert_id      = [guid]::NewGuid().ToString('N')
        watchdog      = $WatchdogId
        trigger_type  = $TriggerType
        evidence      = $Evidence
        request_halt  = $RequestHalt
        submitted_utc = [datetime]::UtcNow.ToString('o')
        resolved      = $false
    }

    $script:_ActiveAlerts.Add($alert)
    $script:_WatchdogState[$WatchdogId].last_triggered_utc = $alert.submitted_utc
    $script:_WatchdogState[$WatchdogId].trigger_count++

    # Log to ledger
    try {
        Write-LedgerEntry -EventType 'WATCHDOG' -Source "WatchdogSupervisor.$WatchdogId" -Data $alert
    }
    catch { <# Intentional: non-fatal ledger write #> }

    Write-AppLog -Message "[WatchdogSupervisor] ALERT from $WatchdogId : $TriggerType" -Level Warning

    return $alert
}

# ========================== VOTING ==========================
function Invoke-TribunalVote {
    <#
    .SYNOPSIS
        Initiates a 2-of-3 vote among watchdogs on a proposed action.
    .PARAMETER ProposedAction
        HALT, QUARANTINE, ROLLBACK, WARN
    .PARAMETER Votes
        Hashtable: @{ CASPAR=$true; MELCHIOR=$false; BALTHAZAR=$true }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('HALT','QUARANTINE','ROLLBACK','WARN','RESUME')]
        [string]$ProposedAction,

        [Parameter(Mandatory)]
        [hashtable]$Votes,

        [string]$Reason = ''
    )
    $yesCount = ($Votes.Values | Where-Object { $_ -eq $true }).Count
    $required = 2   # 2-of-3

    $passed = $yesCount -ge $required

    $voteRecord = @{
        vote_id         = [guid]::NewGuid().ToString('N')
        proposed_action = $ProposedAction
        votes           = $Votes
        yes_count       = $yesCount
        required        = $required
        passed          = $passed
        reason          = $Reason
        voted_utc       = [datetime]::UtcNow.ToString('o')
    }

    $script:_VoteHistory.Add($voteRecord)

    # Log to ledger
    try {
        Write-LedgerEntry -EventType 'WATCHDOG' -Source 'WatchdogSupervisor.Tribunal' -Data $voteRecord
    }
    catch { <# Intentional: non-fatal ledger write #> }

    # Execute if passed
    if ($passed) {
        switch ($ProposedAction) {
            'HALT' {
                $script:_KernelHalted = $true
                Write-AppLog -Message '' -Level Warning
            }
            'QUARANTINE' {
                Write-AppLog -Message '' -Level Warning
            }
            'ROLLBACK' {
                Write-AppLog -Message '' -Level Warning
            }
            'RESUME' {
                $script:_KernelHalted = $false
                Write-Verbose '[WatchdogSupervisor] TRIBUNAL VOTE PASSED: RESUME'
            }
            'WARN' {
                Write-AppLog -Message '' -Level Warning
            }
        }
    }

    return $voteRecord
}

# ========================== INTEGRITY CHECKS (CASPAR) ==========================
function Invoke-CasparIntegrityCheck {
    <#
    .SYNOPSIS  CASPAR checks manifest and ledger integrity.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$ExpectedHash
    )
    $breaches = @()

    if ($ManifestPath -and (Test-Path $ManifestPath)) {
        $currentHash = Get-FileHash512 -Path $ManifestPath
        if ($ExpectedHash -and $currentHash -ne $ExpectedHash) {
            $breaches += @{
                type     = 'MANIFEST_TAMPER'
                expected = $ExpectedHash
                actual   = $currentHash
            }
        }
    }

    # Check ledger integrity
    try {
        $ledgerResult = Test-LedgerIntegrity -ReplicaIndex 0
        if ($ledgerResult.Broken) {
            $breaches += @{
                type           = 'LEDGER_CHAIN_BROKEN'
                break_at_index = $ledgerResult.BreakAtIndex
            }
        }
    }
    catch {
        $breaches += @{
            type  = 'LEDGER_CHECK_ERROR'
            error = $_.Exception.Message
        }
    }

    if ($breaches.Count -gt 0) {
        Submit-WatchdogAlert -WatchdogId 'CASPAR' -TriggerType 'integrity_breach' -Evidence @{
            breaches = $breaches
        } -RequestHalt $true
    }

    return @{
        watchdog = 'CASPAR'
        breaches = $breaches
        clean    = ($breaches.Count -eq 0)
    }
}

# ========================== ETHICAL CHECKS (MELCHIOR) ==========================
function Invoke-MelchiorEthicsCheck {
    <#
    .SYNOPSIS  MELCHIOR checks compliance state across all modules.
    #>
    [CmdletBinding()]
    param()
    $report = Get-ComplianceReport
    $breaches = @()

    if ($report.non_compliant -gt 0) {
        foreach ($key in $report.details.Keys) {
            $detail = $report.details[$key]
            if (-not $detail.compliant) {
                $breaches += @{
                    module     = $key
                    violations = $detail.violations
                }
            }
        }
    }

    if ($breaches.Count -gt 0) {
        Submit-WatchdogAlert -WatchdogId 'MELCHIOR' -TriggerType 'ethical_breach' -Evidence @{
            compliance_ratio = $report.compliance_ratio
            breaches         = $breaches
        } -RequestHalt ($report.compliance_ratio -lt 0.5)
    }

    return @{
        watchdog         = 'MELCHIOR'
        compliance_ratio = $report.compliance_ratio
        breaches         = $breaches
        clean            = ($breaches.Count -eq 0)
    }
}

# ========================== PREDICTIVE CHECKS (BALTHAZAR) ==========================
function Invoke-BalthazarAnomalyCheck {
    <#
    .SYNOPSIS  BALTHAZAR checks health score trends for anomalous degradation.
    #>
    [CmdletBinding()]
    param(
        [double]$DegradedThreshold = 0.6,
        [double]$CriticalThreshold = 0.3
    )
    $healthScore = Get-HealthScore
    $anomalies   = @()

    if ($healthScore -lt $CriticalThreshold) {
        $anomalies += @{
            type      = 'CRITICAL_DEGRADATION'
            score     = $healthScore
            threshold = $CriticalThreshold
        }
    }
    elseif ($healthScore -lt $DegradedThreshold) {
        $anomalies += @{
            type      = 'DEGRADATION_WARNING'
            score     = $healthScore
            threshold = $DegradedThreshold
        }
    }

    # Check for modules with high failure counts
    $allHealth = Get-ModuleHealth
    foreach ($key in $allHealth.Keys) {
        $h = $allHealth[$key]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        if ($h.failures -ge 3) {
            $anomalies += @{
                type     = 'REPEATED_FAILURE'
                module   = $key
                failures = $h.failures
            }
        }
    }

    if (@($anomalies).Count -gt 0) {
        $isHaltWorthy = @($anomalies | Where-Object { $_.type -eq 'CRITICAL_DEGRADATION' }).Count -gt 0
        Submit-WatchdogAlert -WatchdogId 'BALTHAZAR' -TriggerType 'predictive_anomaly' -Evidence @{
            health_score = $healthScore
            anomalies    = $anomalies
        } -RequestHalt $isHaltWorthy
    }

    # Check for consecutive self-review score drops
    try {
        $workspaceRoot  = Split-Path (Split-Path $PSScriptRoot)
        $srHistPath     = Join-Path (Join-Path $workspaceRoot 'config') 'self-review-history.json'
        if (Test-Path $srHistPath) {
            $srHist      = Get-Content -Path $srHistPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $srRuns      = @($srHist.runs)
            $srCfgPath   = Join-Path (Join-Path $workspaceRoot 'config') 'self-review-config.json'
            $consecutiveDropsRequired = 3
            if (Test-Path $srCfgPath) {
                try {
                    $srCfg = Get-Content -Path $srCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($null -ne $srCfg.thresholds -and $null -ne $srCfg.thresholds.balthazarConsecutiveDrops) {
                        $consecutiveDropsRequired = [int]$srCfg.thresholds.balthazarConsecutiveDrops
                    }
                } catch { <# Intentional: non-fatal config read #> }
            }

            if (@($srRuns).Count -ge ($consecutiveDropsRequired + 1)) {
                $checkSet = @($srRuns[-(($consecutiveDropsRequired + 1))..-1])
                $allDrops = $true
                $dropCount = 0
                for ($i = 1; $i -lt @($checkSet).Count; $i++) {
                    $prev = if ($checkSet[$i - 1].PSObject.Properties.Name -contains 'compositeScore') { [double]$checkSet[$i - 1].compositeScore } else { 1.0 }
                    $curr = if ($checkSet[$i].PSObject.Properties.Name -contains 'compositeScore')     { [double]$checkSet[$i].compositeScore     } else { 1.0 }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    if ($curr -ge $prev) { $allDrops = $false; break }
                    $dropCount++
                }

                if ($allDrops -and $dropCount -ge $consecutiveDropsRequired) {
                    $latestScore = if ($srRuns[-1].PSObject.Properties.Name -contains 'compositeScore') { [double]$srRuns[-1].compositeScore } else { 0 }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    $anomalies += @{
                        type          = 'SELF_REVIEW_CONSECUTIVE_DROP'
                        drops         = $dropCount
                        latestScore   = $latestScore
                        threshold     = $consecutiveDropsRequired
                    }
                    Submit-WatchdogAlert -WatchdogId 'BALTHAZAR' -TriggerType 'self_review_trend_anomaly' -Evidence @{
                        consecutive_drops = $dropCount
                        latest_score      = $latestScore
                        required_drops    = $consecutiveDropsRequired
                    } -RequestHalt $false
                }
            }
        }
    } catch {
        Write-Verbose "[BALTHAZAR] Self-review trend check error: $_"
    }

    return @{
        watchdog     = 'BALTHAZAR'
        health_score = $healthScore
        anomalies    = $anomalies
        clean        = (@($anomalies).Count -eq 0)
    }
}

# ========================== FULL TRIBUNAL SWEEP ==========================
function Invoke-FullTribunalSweep {
    <#
    .SYNOPSIS  Runs all three watchdog checks and auto-votes on halt if needed.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$ExpectedHash
    )
    $caspar    = Invoke-CasparIntegrityCheck -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash
    $melchior  = Invoke-MelchiorEthicsCheck
    $balthazar = Invoke-BalthazarAnomalyCheck

    # If any alert requests halt, trigger tribunal vote
    $haltRequests = @($script:_ActiveAlerts | Where-Object { $_.request_halt -and -not $_.resolved })
    if ($haltRequests.Count -gt 0) {
        $votes = @{
            CASPAR    = (-not $caspar.clean)
            MELCHIOR  = (-not $melchior.clean)
            BALTHAZAR = (-not $balthazar.clean)
        }
        $voteResult = Invoke-TribunalVote -ProposedAction 'HALT' -Votes $votes -Reason 'Automated tribunal sweep'

        # Mark alerts as resolved
        foreach ($alert in $haltRequests) {
            $alert.resolved = $true
        }

        return @{
            caspar    = $caspar
            melchior  = $melchior
            balthazar = $balthazar
            vote      = $voteResult
            halted    = $script:_KernelHalted
        }
    }

    return @{
        caspar    = $caspar
        melchior  = $melchior
        balthazar = $balthazar
        vote      = $null
        halted    = $script:_KernelHalted
    }
}

# ========================== STATUS ==========================
function Get-WatchdogStatus {
    [CmdletBinding()]
    param()
    return @{
        kernel_halted  = $script:_KernelHalted
        watchdogs      = $script:_WatchdogState.Clone()
        active_alerts  = $script:_ActiveAlerts.Count
        total_votes    = $script:_VoteHistory.Count
    }
}

function Get-VoteHistory {
    [CmdletBinding()]
    param([int]$Last = 20)
    return @($script:_VoteHistory | Select-Object -Last $Last)
}

function Test-KernelHalted {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:_KernelHalted
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
    'Initialize-WatchdogSupervisor'
    'Submit-WatchdogAlert'
    'Invoke-TribunalVote'
    'Invoke-CasparIntegrityCheck'
    'Invoke-MelchiorEthicsCheck'
    'Invoke-BalthazarAnomalyCheck'
    'Invoke-FullTribunalSweep'
    'Get-WatchdogStatus'
    'Get-VoteHistory'
    'Test-KernelHalted'
)







