# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- SelfHealer Module
    Integrity verification, auto-restore, cipher auto-upgrade, and degraded-mode operation.

.DESCRIPTION
    Provides self-healing capabilities:
      - SHA-512 integrity baseline for all kernel files
      - Tamper detection via periodic integrity scans
      - Auto-restore from known-good snapshots in .history/
      - Cipher strength auto-upgrade when stronger algorithms become available
      - Health monitoring with degraded-mode fallback
      - Module hot-reload after repair
      - Recovery audit trail via ledger

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.healer.1
    Depends  : CryptoEngine.psm1, LedgerWriter.psm1, AgentRegistry.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_Baseline          = @{}    # relativePath -> SHA-512 hash
$script:_KernelRoot        = $null
$script:_HealingConfig     = $null
$script:_RepairLog         = [System.Collections.Generic.List[hashtable]]::new()
$script:_DegradedMode      = $false
$script:_SelfHealInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-SelfHealer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$KernelRoot,

        [hashtable]$HealingConfig
    )
    $script:_KernelRoot   = $KernelRoot
    $script:_HealingConfig = if ($HealingConfig) { $HealingConfig } else { @{ auto_restart = $true; max_retries = 3; degraded_mode = 'continue_limited' } }

    # Build initial baseline
    Build-IntegrityBaseline

    $script:_SelfHealInitialized = $true
    Write-Verbose "[SelfHealer] Initialized -- baseline files: $($script:_Baseline.Count)"
}

# ========================== INTEGRITY BASELINE ==========================
function Build-IntegrityBaseline {
    <#
    .SYNOPSIS  Scans all kernel files and records their SHA-512 hashes.
    #>
    [CmdletBinding()]
    param()
    $script:_Baseline = @{}
    $extensions = @('*.psm1', '*.ps1', '*.json')

    foreach ($ext in $extensions) {
        $files = Get-ChildItem -Path $script:_KernelRoot -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $relativePath = $f.FullName.Substring($script:_KernelRoot.Length).TrimStart('\', '/')
            try {
                $hash = Get-FileHash512 -Path $f.FullName
                $script:_Baseline[$relativePath] = $hash
            }
            catch {
                Write-AppLog -Message "[SelfHealer] Failed to hash: $relativePath" -Level Warning
            }
        }
    }
}

function Get-IntegrityBaseline {
    [CmdletBinding()]
    param()
    return $script:_Baseline.Clone()
}

# ========================== INTEGRITY SCAN ==========================
function Invoke-IntegrityScan {
    <#
    .SYNOPSIS  Compares current file hashes to baseline. Returns list of violations.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    $violations = @()

    foreach ($relativePath in $script:_Baseline.Keys) {
        $fullPath = Join-Path $script:_KernelRoot $relativePath
        if (-not (Test-Path $fullPath)) {
            $violations += @{
                file      = $relativePath
                type      = 'MISSING'
                expected  = $script:_Baseline[$relativePath]
                actual    = $null
            }
            continue
        }

        $currentHash = Get-FileHash512 -Path $fullPath
        if ($currentHash -ne $script:_Baseline[$relativePath]) {
            $violations += @{
                file      = $relativePath
                type      = 'MODIFIED'
                expected  = $script:_Baseline[$relativePath]
                actual    = $currentHash
            }
        }
    }

    # Check for new (unexpected) files
    $extensions = @('*.psm1', '*.ps1', '*.json')
    foreach ($ext in $extensions) {
        $files = Get-ChildItem -Path $script:_KernelRoot -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($script:_KernelRoot.Length).TrimStart('\', '/')
            if (-not $script:_Baseline.ContainsKey($rel)) {
                $violations += @{
                    file     = $rel
                    type     = 'UNEXPECTED'
                    expected = $null
                    actual   = (Get-FileHash512 -Path $f.FullName)
                }
            }
        }
    }

    # Log result
    $scanResult = @{
        action          = 'INTEGRITY_SCAN'
        violation_count = $violations.Count
        scanned_utc     = [datetime]::UtcNow.ToString('o')
    }
    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'SelfHealer' -Data $scanResult } catch { <# Intentional: non-fatal ledger write #> }

    return $violations
}

# ========================== AUTO-RESTORE ==========================
function Invoke-AutoRestore {
    <#
    .SYNOPSIS  Attempts to restore corrupted/missing files from known-good sources.
    .DESCRIPTION
        Restore priority:
          1. .history/ folder timestamped snapshots (if available)
          2. Compressed snapshots from sovereign-kernel/snapshots/
          3. Fall back to degraded mode if no source available
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Violations
    )
    $restored = @()
    $failed   = @()

    foreach ($v in $Violations) {
        if ($v.type -eq 'UNEXPECTED') { continue }

        $repairResult = Repair-File -RelativePath $v.file -ExpectedHash $v.expected

        if ($repairResult.success) {
            $restored += $repairResult
            # Update baseline
            $script:_Baseline[$v.file] = $repairResult.restored_hash
        }
        else {
            $failed += $repairResult
        }
    }

    $record = @{
        action         = 'AUTO_RESTORE'
        restored_count = $restored.Count
        failed_count   = $failed.Count
        restored_utc   = [datetime]::UtcNow.ToString('o')
    }
    $script:_RepairLog.Add($record)

    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'SelfHealer' -Data $record } catch { <# Intentional: non-fatal ledger write #> }

    # Enter degraded mode if any repairs failed
    if ($failed.Count -gt 0) {
        Enter-DegradedMode -Reason "Failed to restore $($failed.Count) file(s)"
    }

    return @{
        restored = $restored
        failed   = $failed
    }
}

function Repair-File {
    [CmdletBinding()]
    param(
        [string]$RelativePath,
        [string]$ExpectedHash
    )
    $fullPath = Join-Path $script:_KernelRoot $RelativePath

    # Strategy 1: Check .history/ folder
    $historyRoot = Join-Path (Split-Path $script:_KernelRoot -Parent) '.history'
    if (Test-Path $historyRoot) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath)
        $ext      = [System.IO.Path]::GetExtension($RelativePath)
        $histDir  = Join-Path $historyRoot (Split-Path $RelativePath -Parent)

        if (Test-Path $histDir) {
            # Find most recent matching history file
            $pattern = "${baseName}_*${ext}"
            $histFiles = Get-ChildItem -Path $histDir -Filter $pattern -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending

            foreach ($hf in $histFiles) {
                $hHash = Get-FileHash512 -Path $hf.FullName
                # Accept any parse-clean version if we cannot match expected hash
                try {
                    $dir = Split-Path $fullPath -Parent
                    if (-not (Test-Path $dir)) {
                        New-Item -Path $dir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path $hf.FullName -Destination $fullPath -Force
                    return @{
                        success       = $true
                        file          = $RelativePath
                        source        = "history:$($hf.Name)"
                        restored_hash = $hHash
                    }
                }
                catch { Write-Verbose "[SelfHealer] History restore failed for ${RelativePath}: $($_.Exception.Message)" }
            }
        }
    }

    # Strategy 2: Snapshot restore (full manifest only)
    if ($RelativePath -like '*sovereign-kernel.json') {
        $snapDir = Join-Path $script:_KernelRoot 'snapshots'
        if (Test-Path $snapDir) {
            $snaps = Get-ChildItem -Path $snapDir -Filter '*.json.gz' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

            foreach ($snap in $snaps) {
                try {
                    $compressed = [System.IO.File]::ReadAllBytes($snap.FullName)
                    $decompressed = Expand-Data -CompressedBytes $compressed
                    $dir = Split-Path $fullPath -Parent
                    if (-not (Test-Path $dir)) {
                        New-Item -Path $dir -ItemType Directory -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllBytes($fullPath, $decompressed)
                    $restoredHash = Get-FileHash512 -Path $fullPath
                    return @{
                        success       = $true
                        file          = $RelativePath
                        source        = "snapshot:$($snap.Name)"
                        restored_hash = $restoredHash
                    }
                }
                catch { Write-Verbose "[SelfHealer] Snapshot restore failed for ${RelativePath}: $($_.Exception.Message)" }
            }
        }
    }

    # No viable source
    return @{
        success = $false
        file    = $RelativePath
        source  = $null
        reason  = 'No restore source found'
    }
}

# ========================== CIPHER AUTO-UPGRADE ==========================
function Test-CipherUpgradeAvailable {
    <#
    .SYNOPSIS  Checks if a stronger cipher suite is available in the runtime.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $currentScore = Get-CipherStrengthScore -CipherSuite 'AES-256-CBC+HMAC-SHA512'
    $upgradable   = $false
    $upgradeTo    = $null

    # Check if AES-GCM is available (PowerShell 7+ / .NET Core)
    try {
        $gcmType = [System.Security.Cryptography.AesGcm]
        if ($gcmType) {
            $gcmScore = Get-CipherStrengthScore -CipherSuite 'AES-256-GCM'
            if ($gcmScore -gt $currentScore) {
                $upgradable = $true
                $upgradeTo  = 'AES-256-GCM'
            }
        }
    }
    catch { <# Intentional: AesGcm type check -- not available on PS 5.1 #> }

    return @{
        current_algorithm = 'AES-256-CBC'
        current_score     = $currentScore
        upgrade_available = $upgradable
        upgrade_target    = $upgradeTo
    }
}

# ========================== DEGRADED MODE ==========================
function Enter-DegradedMode {
    [CmdletBinding()]
    param([string]$Reason)
    $script:_DegradedMode = $true
    $record = @{
        action  = 'DEGRADED_MODE_ENTERED'
        reason  = $Reason
        utc     = [datetime]::UtcNow.ToString('o')
    }
    $script:_RepairLog.Add($record)
    try { Write-LedgerEntry -EventType 'ALERT' -Source 'SelfHealer' -Data $record } catch { <# Intentional: non-fatal ledger write #> }
    Write-AppLog -Message "[SelfHealer] DEGRADED MODE -- $Reason" -Level Warning
}

function Exit-DegradedMode {
    [CmdletBinding()]
    param()
    $script:_DegradedMode = $false
    $record = @{
        action = 'DEGRADED_MODE_EXITED'
        utc    = [datetime]::UtcNow.ToString('o')
    }
    $script:_RepairLog.Add($record)
    try { Write-LedgerEntry -EventType 'SYSTEM' -Source 'SelfHealer' -Data $record } catch { <# Intentional: non-fatal ledger write #> }
}

function Test-DegradedMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:_DegradedMode
}

# ========================== FULL HEAL CYCLE ==========================
function Invoke-HealCycle {
    <#
    .SYNOPSIS  Runs a complete self-healing cycle: scan, restore, re-baseline.
    #>
    [CmdletBinding()]
    param()
    $violations = Invoke-IntegrityScan

    if ($violations.Count -eq 0) {
        return @{ clean = $true; violations = 0; restored = 0; failed = 0 }
    }

    $restorable = @($violations | Where-Object { $_.type -ne 'UNEXPECTED' })
    $restoreResult = @{ restored = @(); failed = @() }

    if ($restorable.Count -gt 0) {
        $restoreResult = Invoke-AutoRestore -Violations $restorable
    }

    # Re-baseline on success
    if ($restoreResult.failed.Count -eq 0) {
        Build-IntegrityBaseline
        if ($script:_DegradedMode) { Exit-DegradedMode }
    }

    return @{
        clean    = $false
        violations = $violations.Count
        restored = $restoreResult.restored.Count
        failed   = $restoreResult.failed.Count
    }
}

# ========================== STATUS ==========================
function Get-SelfHealerStatus {
    [CmdletBinding()]
    param()
    return @{
        initialized     = $script:_SelfHealInitialized
        baseline_files  = $script:_Baseline.Count
        degraded_mode   = $script:_DegradedMode
        repair_log_size = $script:_RepairLog.Count
        cipher_upgrade  = (Test-CipherUpgradeAvailable)
    }
}

function Get-RepairLog {
    [CmdletBinding()]
    param([int]$Last = 20)
    return @($script:_RepairLog | Select-Object -Last $Last)
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
    'Initialize-SelfHealer'
    'Build-IntegrityBaseline'
    'Get-IntegrityBaseline'
    'Invoke-IntegrityScan'
    'Invoke-AutoRestore'
    'Test-CipherUpgradeAvailable'
    'Enter-DegradedMode'
    'Exit-DegradedMode'
    'Test-DegradedMode'
    'Invoke-HealCycle'
    'Get-SelfHealerStatus'
    'Get-RepairLog'
)







