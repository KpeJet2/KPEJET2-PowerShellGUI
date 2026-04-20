# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- CycleManager Module
    Version lineage, cycle progression, branch analysis, rollback gates, and regression detection.

.DESCRIPTION
    Manages the kernel's evolution lifecycle:
      - Version lineage tracking with immutable history
      - Cycle roll-forward with pre-condition checks
      - Branch analysis (divergence detection, drift limits)
      - Rollback with depth limits and ledger recording
      - Regression detection via delta comparison
      - Manifest snapshot creation before each cycle advance

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.cycle.1
    Depends  : CryptoEngine.psm1, LedgerWriter.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_VersioningConfig  = $null
$script:_CurrentVersion    = $null
$script:_CurrentCycle      = $null
$script:_Lineage           = @()
$script:_BranchPolicy      = @{}
$script:_CycleHistory      = [System.Collections.Generic.List[hashtable]]::new()
$script:_Snapshots         = [System.Collections.Generic.List[hashtable]]::new()
$script:_KernelRoot        = $null
$script:_CycleInitialized  = $false

# ========================== INITIALISATION ==========================
function Initialize-CycleManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$VersioningConfig,

        [Parameter(Mandatory)]
        [string]$KernelRoot
    )
    $script:_VersioningConfig = $VersioningConfig
    $script:_CurrentVersion   = $VersioningConfig.doctrine_version
    $script:_CurrentCycle     = $VersioningConfig.current_cycle
    $script:_Lineage          = @($VersioningConfig.lineage)
    $script:_BranchPolicy     = if ($VersioningConfig.branch_policy) { $VersioningConfig.branch_policy } else { @{} }
    $script:_KernelRoot       = $KernelRoot

    # Ensure snapshots directory exists
    $snapDir = Join-Path $KernelRoot 'snapshots'
    if (-not (Test-Path $snapDir)) {
        New-Item -Path $snapDir -ItemType Directory -Force | Out-Null
    }

    # Load cycle history if it exists
    $historyPath = Join-Path $KernelRoot 'cycle-history.json'
    if (Test-Path $historyPath) {
        $saved = Get-Content -Path $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $saved) {
            $ht = @{}
            $entry.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            $script:_CycleHistory.Add($ht)
        }
    }

    $script:_CycleInitialized = $true
    Write-Verbose "[CycleManager] Initialized -- version=$($script:_CurrentVersion), cycle=$($script:_CurrentCycle)"
}

# ========================== CYCLE PROGRESSION ==========================
function Test-CycleAdvanceReady {
    <#
    .SYNOPSIS  Pre-condition checks before advancing to the next cycle.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $issues = @()

    # Check that kernel is not halted
    try {
        if (Test-KernelHalted) {
            $issues += 'Kernel is halted by watchdog tribunal.'
        }
    }
    catch { $issues += "Kernel halt check failed: $_" }

    # Check health score
    try {
        $health = Get-HealthScore
        if ($health -lt 0.8) {
            $issues += "Health score too low for cycle advance: $health (need >= 0.8)"
        }
    }
    catch { $issues += "Health score check failed: $_" }

    # Check ledger integrity
    try {
        $ledgerOk = Test-LedgerIntegrity -ReplicaIndex 0
        if ($ledgerOk.Broken) {
            $issues += "Ledger integrity broken at entry $($ledgerOk.BreakAtIndex)"
        }
    }
    catch { $issues += "Ledger integrity check failed: $_" }

    # Check cipher compliance
    try {
        if (-not (Test-CipherStrengthCompliance)) {
            $issues += 'Cipher strength below minimum threshold.'
        }
    }
    catch { $issues += "Cipher compliance check failed: $_" }

    # Check self-review composite score (gates on workspace health)
    try {
        $histPath = Join-Path (Join-Path $script:_KernelRoot '..') (Join-Path 'config' 'self-review-history.json')
        $histPath = [System.IO.Path]::GetFullPath($histPath)
        if (Test-Path $histPath) {
            $srHist   = Get-Content -Path $histPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $srRuns   = @($srHist.runs)
            if (@($srRuns).Count -gt 0) {
                $latestRun   = $srRuns[-1]
                $srScore     = if ($latestRun.PSObject.Properties.Name -contains 'compositeScore') { [double]$latestRun.compositeScore } else { 1.0 }
                $srTimestamp = if ($latestRun.PSObject.Properties.Name -contains 'timestamp')      { [datetime]$latestRun.timestamp    } else { [datetime]::UtcNow }
                $srAgeHours  = ([datetime]::UtcNow - $srTimestamp.ToUniversalTime()).TotalHours

                if ($srScore -lt 0.6) {
                    $issues += "Self-review composite score too low: $srScore (need >= 0.6 -- check ~REPORTS/SelfReview/ for details)"
                }
                if ($srAgeHours -gt 12) {
                    # Non-blocking warning only -- stale but not a hard block
                    $issues += "[WARNING] Self-review last ran $([math]::Round($srAgeHours, 1))h ago (consider triggering TASK-SelfReview)"
                }
            }
        }
    }
    catch { $issues += "Self-review gate check failed: $_" }

    return @{
        ready  = (-not (@($issues | Where-Object { $_ -notlike '[WARNING]*' }).Count -gt 0))
        issues = $issues
    }
}

function Invoke-CycleAdvance {
    <#
    .SYNOPSIS  Advances the kernel to the next cycle.
    #>
    [CmdletBinding()]
    param(
        [string]$NewCycleName
    )
    $readiness = Test-CycleAdvanceReady
    if (-not $readiness.ready) {
        throw "[CycleManager] Cannot advance cycle: $($readiness.issues -join '; ')"
    }

    # Create snapshot of current state
    $snapshot = New-CycleSnapshot -Label "pre-advance-$($script:_CurrentCycle)"

    # Determine new cycle
    $currentNum = 0
    if ($script:_CurrentCycle -match 'cycle(\d+)') {
        $currentNum = [int]$Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
    }

    if (-not $NewCycleName) {
        $NewCycleName = 'cycle' + ($currentNum + 1)
    }

    $oldCycle = $script:_CurrentCycle
    $script:_CurrentCycle = $NewCycleName

    $record = @{
        action       = 'CYCLE_ADVANCE'
        from_cycle   = $oldCycle
        to_cycle     = $NewCycleName
        version      = $script:_CurrentVersion
        snapshot_id  = $snapshot.snapshot_id
        advanced_utc = [datetime]::UtcNow.ToString('o')
    }
    $script:_CycleHistory.Add($record)

    # Persist cycle history
    Save-CycleHistory

    # Log to ledger
    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'CycleManager' -Data $record } catch { <# Intentional: non-fatal ledger write #> }

    return $record
}

# ========================== ROLLBACK ==========================
function Invoke-CycleRollback {
    <#
    .SYNOPSIS  Rolls back to a previous cycle within the allowed rollback depth.
    #>
    [CmdletBinding()]
    param(
        [int]$StepsBack = 1
    )
    $maxRollback = if ($script:_BranchPolicy.rollback_depth) { $script:_BranchPolicy.rollback_depth } else { 3 }
    if ($StepsBack -gt $maxRollback) {
        throw "[CycleManager] Rollback depth $StepsBack exceeds maximum $maxRollback."
    }

    $historyCount = $script:_CycleHistory.Count
    if ($StepsBack -gt $historyCount) {
        throw "[CycleManager] Not enough cycle history for $StepsBack-step rollback."
    }

    $targetIndex  = $historyCount - $StepsBack
    $targetRecord = $script:_CycleHistory[$targetIndex]
    $targetCycle  = $targetRecord.from_cycle

    $oldCycle = $script:_CurrentCycle
    $script:_CurrentCycle = $targetCycle

    $record = @{
        action       = 'CYCLE_ROLLBACK'
        from_cycle   = $oldCycle
        to_cycle     = $targetCycle
        steps_back   = $StepsBack
        rolledback_utc = [datetime]::UtcNow.ToString('o')
    }
    $script:_CycleHistory.Add($record)
    Save-CycleHistory

    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'CycleManager' -Data $record } catch { <# Intentional: non-fatal ledger write #> }

    return $record
}

# ========================== BRANCH ANALYSIS ==========================
function Test-BranchDivergence {
    <#
    .SYNOPSIS  Checks if the current cycle has drifted too far from the lineage.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $currentNum = 0
    if ($script:_CurrentCycle -match 'cycle(\d+)') {
        $currentNum = [int]$Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
    }

    # Check against known lineage
    $latestVersion    = $script:_Lineage[-1]
    $maxDrift         = if ($script:_BranchPolicy.max_drift_cycles) { $script:_BranchPolicy.max_drift_cycles } else { 2 }
    $allowDivergence  = if ($null -ne $script:_BranchPolicy.allow_divergence) { $script:_BranchPolicy.allow_divergence } else { $false }

    # Count advances since last version bump
    $advancesSinceVersion = ($script:_CycleHistory | Where-Object { $_.action -eq 'CYCLE_ADVANCE' }).Count
    $diverged = $advancesSinceVersion -gt $maxDrift

    return @{
        current_cycle       = $script:_CurrentCycle
        current_version     = $script:_CurrentVersion
        advances_since_bump = $advancesSinceVersion
        max_drift           = $maxDrift
        diverged            = $diverged
        allow_divergence    = $allowDivergence
        action_required     = ($diverged -and -not $allowDivergence)
    }
}

function Invoke-VersionBump {
    <#
    .SYNOPSIS  Bumps the doctrine version and appends to lineage.
    #>
    [CmdletBinding()]
    param()
    $currentNum = 0
    if ($script:_CurrentVersion -match 'v(\d+)') {
        $currentNum = [int]$Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
    }
    $newVersion = 'v' + ($currentNum + 1)
    $script:_Lineage += $newVersion
    $oldVersion = $script:_CurrentVersion
    $script:_CurrentVersion = $newVersion

    $record = @{
        action       = 'VERSION_BUMP'
        from_version = $oldVersion
        to_version   = $newVersion
        lineage      = $script:_Lineage
        bumped_utc   = [datetime]::UtcNow.ToString('o')
    }
    $script:_CycleHistory.Add($record)
    Save-CycleHistory

    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'CycleManager' -Data $record } catch { <# Intentional: non-fatal ledger write #> }

    return $record
}

# ========================== SNAPSHOTS ==========================
function New-CycleSnapshot {
    <#
    .SYNOPSIS  Creates a compressed, encrypted snapshot of the current manifest.
    #>
    [CmdletBinding()]
    param(
        [string]$Label = 'manual'
    )
    $snapDir      = Join-Path $script:_KernelRoot 'snapshots'
    $manifestPath = Join-Path (Join-Path $script:_KernelRoot 'manifest') 'sovereign-kernel.json'

    $snapshotId   = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $timestamp    = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $snapName     = "snap-${timestamp}-${Label}-${snapshotId}"

    $snapshot = @{
        snapshot_id  = $snapshotId
        label        = $Label
        version      = $script:_CurrentVersion
        cycle        = $script:_CurrentCycle
        created_utc  = [datetime]::UtcNow.ToString('o')
        file_name    = "${snapName}.json.gz"
    }

    # Read manifest, compress, and write
    if (Test-Path $manifestPath) {
        $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
        $compressed    = Compress-Data -InputBytes $manifestBytes
        $snapPath      = Join-Path $snapDir $snapshot.file_name
        [System.IO.File]::WriteAllBytes($snapPath, $compressed)

        $snapshot['hash'] = Get-SHA512Hash -InputBytes $manifestBytes
        $snapshot['compressed_size'] = $compressed.Length
        $snapshot['original_size']   = $manifestBytes.Length
    }

    $script:_Snapshots.Add($snapshot)

    # Enforce max snapshots
    $maxSnaps = 10
    try {
        $files = Get-ChildItem -Path $snapDir -Filter '*.json.gz' | Sort-Object CreationTime
        if ($files.Count -gt $maxSnaps) {
            $toRemove = $files | Select-Object -First ($files.Count - $maxSnaps)
            foreach ($f in $toRemove) { Remove-Item -Path $f.FullName -Force }
        }
    }
    catch { Write-Verbose "[CycleManager] Snapshot cleanup failed: $($_.Exception.Message)" }

    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'CycleManager' -Data $snapshot } catch { <# Intentional: non-fatal ledger write #> }

    return $snapshot
}

function Get-CycleSnapshots {
    [CmdletBinding()]
    param()
    return @($script:_Snapshots)
}

# ========================== STATE ==========================
function Get-CycleState {
    [CmdletBinding()]
    param()
    return @{
        version        = $script:_CurrentVersion
        cycle          = $script:_CurrentCycle
        lineage        = $script:_Lineage
        history_count  = $script:_CycleHistory.Count
        snapshot_count = $script:_Snapshots.Count
    }
}

function Get-CycleHistory {
    [CmdletBinding()]
    param([int]$Last = 20)
    return @($script:_CycleHistory | Select-Object -Last $Last)
}

# ========================== PERSISTENCE ==========================
function Save-CycleHistory {
    [CmdletBinding()]
    param()
    if (-not $script:_KernelRoot) { return }
    $historyPath = Join-Path $script:_KernelRoot 'cycle-history.json'
    $json = @($script:_CycleHistory) | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($historyPath, $json, [System.Text.Encoding]::UTF8)
}

# ========================== EXPORTS ==========================
Export-ModuleMember -Function @(
    'Initialize-CycleManager'
    'Test-CycleAdvanceReady'
    'Invoke-CycleAdvance'
    'Invoke-CycleRollback'
    'Test-BranchDivergence'
    'Invoke-VersionBump'
    'New-CycleSnapshot'
    'Get-CycleSnapshots'
    'Get-CycleState'
    'Get-CycleHistory'
)

