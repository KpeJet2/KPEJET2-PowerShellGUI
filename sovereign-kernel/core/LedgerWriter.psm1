# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- LedgerWriter Module
    Append-only, hash-chained, compressed, encrypted immutable ledger.

.DESCRIPTION
    Every kernel event, method call, policy decision, and watchdog vote is recorded
    in an immutable ledger with the following guarantees:
      - Append-only: no entry can be modified or deleted
      - Hash-chained: each entry contains SHA-512(previous_hash + current_data)
      - Compressed: GZIP before write (mandatory)
      - Encrypted: AES-256-CBC + HMAC-SHA512 (mandatory)
      - Redundant: writes to N replica paths with quorum confirmation
      - Verifiable: full chain integrity audit at any time
      - Tamper-evident: broken chain detected on read

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.ledger.1
    Depends  : CryptoEngine.psm1
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_LedgerConfig    = $null
$script:_LedgerPaths     = @()
$script:_LedgerQuorum    = 2
$script:_LastHash        = '0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
$script:_EntryIndex      = 0
$script:_LedgerLock      = [System.Threading.Mutex]::new($false, 'SovereignKernelLedgerMutex')
$script:_EncryptionKeySet = $null
$script:_LedgerInitialized = $false

# ========================== INITIALISATION ==========================
function Initialize-LedgerWriter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$RedundancyConfig,

        [Parameter(Mandatory)]
        [hashtable]$LoggingConfig,

        [Parameter(Mandatory)]
        [string]$KernelRoot,

        [Parameter(Mandatory)]
        [hashtable]$EncryptionKeySet
    )
    $script:_LedgerConfig    = $LoggingConfig
    $script:_LedgerQuorum    = $RedundancyConfig.quorum_for_write
    $script:_EncryptionKeySet = $EncryptionKeySet

    # Resolve replica paths relative to kernel root
    $script:_LedgerPaths = foreach ($relPath in $RedundancyConfig.ledger_paths) {
        $fullPath = Join-Path $KernelRoot $relPath
        if (-not (Test-Path $fullPath)) {
            New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
        }
        $fullPath
    }

    # Load existing chain state from primary ledger
    $primaryIndex = Join-Path $script:_LedgerPaths[0] 'chain-index.json'
    if (Test-Path $primaryIndex) {
        $indexData = Get-Content -Path $primaryIndex -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:_LastHash   = $indexData.last_hash
        $script:_EntryIndex = [int]$indexData.entry_count
    }

    $script:_LedgerInitialized = $true
    Write-Verbose "[LedgerWriter] Initialized with $($script:_LedgerPaths.Count) replica(s), quorum=$($script:_LedgerQuorum), entries=$($script:_EntryIndex)"
}

# ========================== WRITE ==========================
function Write-LedgerEntry {
    <#
    .SYNOPSIS
        Appends a new entry to all ledger replicas with hash-chain, compression, and encryption.
    .PARAMETER EventType
        Classification: AUDIT, METHOD_CALL, POLICY, WATCHDOG, SYSTEM, ERROR, SEAL
    .PARAMETER Source
        Module or component that generated the event.
    .PARAMETER Data
        Hashtable of event-specific data fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AUDIT','METHOD_CALL','POLICY','WATCHDOG','SYSTEM','ERROR','SEAL','INTEGRITY','HEALTH')]
        [string]$EventType,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Data
    )
    if (-not $script:_LedgerInitialized) {
        throw '[LedgerWriter] Not initialized. Call Initialize-LedgerWriter first.'
    }

    $acquired = $false
    try {
        $acquired = $script:_LedgerLock.WaitOne(5000)
        if (-not $acquired) {
            throw '[LedgerWriter] Could not acquire ledger lock within timeout.'
        }

        $script:_EntryIndex++
        $timestamp = [datetime]::UtcNow.ToString('o')

        # Build the entry payload
        $entry = @{
            index         = $script:_EntryIndex
            timestamp_utc = $timestamp
            event_type    = $EventType
            source        = $Source
            data          = $Data
            previous_hash = $script:_LastHash
        }

        # Serialize for hashing
        $entryJson = $entry | ConvertTo-Json -Depth 10 -Compress
        $entryHash = Get-StringHash512 -InputString $entryJson
        $entry['hash'] = $entryHash

        # Update chain
        $chainHash = New-HashChainEntry -PreviousHash $script:_LastHash -CurrentData $entryJson
        $entry['chain_hash'] = $chainHash

        # Serialize final
        $finalJson  = $entry | ConvertTo-Json -Depth 10 -Compress
        $finalBytes = [System.Text.Encoding]::UTF8.GetBytes($finalJson)

        # Encrypt (compress + encrypt is handled by Protect-Data)
        $protected = Protect-Data `
            -Plaintext     $finalBytes `
            -EncryptionKey $script:_EncryptionKeySet.EncryptionKey `
            -HmacKey       $script:_EncryptionKeySet.HmacKey

        $protectedJson = $protected | ConvertTo-Json -Depth 5 -Compress

        # Write to all replicas, track success count
        $successCount = 0
        $fileName = '{0:D8}.entry' -f $script:_EntryIndex

        foreach ($replicaPath in $script:_LedgerPaths) {
            try {
                $entryPath = Join-Path $replicaPath $fileName
                [System.IO.File]::WriteAllText($entryPath, $protectedJson, [System.Text.Encoding]::UTF8)
                $successCount++
            }
            catch {
                Write-AppLog -Message "[LedgerWriter] Failed to write replica at $replicaPath : $_" -Level Warning
            }
        }

        # Check quorum
        if ($successCount -lt $script:_LedgerQuorum) {
            throw "[LedgerWriter] Write quorum not met: $successCount/$($script:_LedgerQuorum) replicas succeeded."
        }

        # Quorum met -- update chain state
        $script:_LastHash = $chainHash
        $chainIndex = @{
            last_hash   = $script:_LastHash
            entry_count = $script:_EntryIndex
            updated_utc = $timestamp
        } | ConvertTo-Json -Depth 5 -Compress

        foreach ($replicaPath in $script:_LedgerPaths) {
            try {
                $idxPath = Join-Path $replicaPath 'chain-index.json'
                [System.IO.File]::WriteAllText($idxPath, $chainIndex, [System.Text.Encoding]::UTF8)
            }
            catch {
                Write-AppLog -Message "[LedgerWriter] Failed to update chain-index at $replicaPath : $_" -Level Warning
            }
        }

        # Entry written successfully (no return -- write operations must not pollute pipelines)
    }
    finally {
        if ($acquired) { $script:_LedgerLock.ReleaseMutex() }
    }
}

# ========================== READ / VERIFY ==========================
function Read-LedgerEntry {
    <#
    .SYNOPSIS  Reads and decrypts a single ledger entry by index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Index,

        [int]$ReplicaIndex = 0
    )
    if ($ReplicaIndex -ge $script:_LedgerPaths.Count) {
        throw "[LedgerWriter] Replica index $ReplicaIndex out of range."
    }
    $fileName  = '{0:D8}.entry' -f $Index
    $entryPath = Join-Path $script:_LedgerPaths[$ReplicaIndex] $fileName

    if (-not (Test-Path $entryPath)) {
        throw "[LedgerWriter] Entry $Index not found at replica $ReplicaIndex."
    }

    $protectedJson = [System.IO.File]::ReadAllText($entryPath, [System.Text.Encoding]::UTF8)
    $protected     = $protectedJson | ConvertFrom-Json

    # Convert PSCustomObject to hashtable for Unprotect-Data
    $protectedHt = @{
        IV         = $protected.IV
        Ciphertext = $protected.Ciphertext
        HMAC       = $protected.HMAC
        Compressed = $protected.Compressed
        Algorithm  = $protected.Algorithm
    }

    $plainBytes = Unprotect-Data `
        -ProtectedPayload $protectedHt `
        -EncryptionKey    $script:_EncryptionKeySet.EncryptionKey `
        -HmacKey          $script:_EncryptionKeySet.HmacKey

    $plainJson = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    return ($plainJson | ConvertFrom-Json)
}

function Test-LedgerIntegrity {
    <#
    .SYNOPSIS
        Verifies the entire hash chain of a ledger replica.
        Returns a result object with pass/fail and break point.
    #>
    [CmdletBinding()]
    param(
        [int]$ReplicaIndex = 0
    )
    $result = @{
        ReplicaIndex   = $ReplicaIndex
        TotalEntries   = $script:_EntryIndex
        Verified       = 0
        Broken         = $false
        BreakAtIndex   = -1
        StartedUtc     = [datetime]::UtcNow.ToString('o')
        CompletedUtc   = $null
    }

    $previousHash = '0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'

    for ($i = 1; $i -le $script:_EntryIndex; $i++) {
        try {
            $entry = Read-LedgerEntry -Index $i -ReplicaIndex $ReplicaIndex

            # Verify the entry records the correct previous hash
            if ($entry.previous_hash -ne $previousHash) {
                $result.Broken      = $true
                $result.BreakAtIndex = $i
                break
            }

            # Reconstruct and verify chain hash
            $entryForHash = @{
                index         = $entry.index
                timestamp_utc = $entry.timestamp_utc
                event_type    = $entry.event_type
                source        = $entry.source
                data          = $entry.data
                previous_hash = $entry.previous_hash
            }
            $reconstructedJson = $entryForHash | ConvertTo-Json -Depth 10 -Compress
            $expectedChain = New-HashChainEntry -PreviousHash $previousHash -CurrentData $reconstructedJson

            if ($expectedChain -ne $entry.chain_hash) {
                $result.Broken      = $true
                $result.BreakAtIndex = $i
                break
            }

            $previousHash = $entry.chain_hash
            $result.Verified++
        }
        catch {
            $result.Broken      = $true
            $result.BreakAtIndex = $i
            Write-AppLog -Message "[LedgerWriter] Integrity check error at entry $i : $_" -Level Warning
            break
        }
    }

    $result.CompletedUtc = [datetime]::UtcNow.ToString('o')
    return $result
}

function Get-LedgerStats {
    [CmdletBinding()]
    param()
    return @{
        Initialized  = $script:_LedgerInitialized
        EntryCount   = $script:_EntryIndex
        ReplicaCount = $script:_LedgerPaths.Count
        Quorum       = $script:_LedgerQuorum
        LastHash     = $script:_LastHash
        ReplicaPaths = $script:_LedgerPaths
    }
}

function Sync-LedgerReplicas {
    <#
    .SYNOPSIS  Synchronizes entries across all replicas from the primary (index 0).
    #>
    [CmdletBinding()]
    param()
    $primary = $script:_LedgerPaths[0]
    $missing = @{}

    for ($r = 1; $r -lt $script:_LedgerPaths.Count; $r++) {
        $replicaPath = $script:_LedgerPaths[$r]
        $repairCount = 0
        for ($i = 1; $i -le $script:_EntryIndex; $i++) {
            $fileName   = '{0:D8}.entry' -f $i
            $targetFile = Join-Path $replicaPath $fileName
            if (-not (Test-Path $targetFile)) {
                $sourceFile = Join-Path $primary $fileName
                if (Test-Path $sourceFile) {
                    Copy-Item -Path $sourceFile -Destination $targetFile -Force
                    $repairCount++
                }
            }
        }
        $missing["Replica$r"] = $repairCount
    }
    return $missing
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
    'Initialize-LedgerWriter'
    'Write-LedgerEntry'
    'Read-LedgerEntry'
    'Test-LedgerIntegrity'
    'Get-LedgerStats'
    'Sync-LedgerReplicas'
)







