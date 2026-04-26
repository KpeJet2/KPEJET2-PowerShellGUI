# VersionTag: 2604.B2.V31.3
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI-ConvoVault -- Encrypted conversation registry for Rumi/Sumi (koe-RumA and H-Ai-Nikr-Agi) exchanges.
.DESCRIPTION
    Records cross-agent conversations between koe-RumA (poetic insight) and H-Ai-Nikr-Agi (disdainful critic).
    All entries are AES-256-CBC encrypted + GZip compressed on disk using a vault-backed key.
    Exports an encrypted JSON web bundle for the PwShGUI-Checklists Rumi/Sumi tab.
    Browseable in-browser via SubtleCrypto with the vault key provided by the user.
.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Module
#>
# TODO: HelpMenu | Show-ConvoVaultHelp | Actions: Store|Retrieve|Search|Purge|Help | Spec: config/help-menu-registry.json

<# Outline:
    Key management (vault-backed AES-256)
    Entry creation: Invoke-ConvoExchange (Rumi verse + Nikr response)
    Persistence: Add-ConvoEntry reads/decrypts/appends/encrypts
    Web export: Export-ConvoBundle writes per-entry encrypted Base64 JSON for browser delivery
    Read path: Get-ConvoEntries decrypts and returns all entries
#>
<# Problems:
    Vault may be locked -- all functions must degrade gracefully (no exception propagation)
    Browser crypto uses SubtleCrypto (PBKDF2 + AES-CBC) -- different from PS internal AES
    Export bundle uses same AES-256-CBC but wraps ciphertext as Base64 for JS consumption
#>
<# Roadmap:
    Add conversation search/filter by topic or date range
    Add MaxEntries cap + auto-rotation (compress oldest 50% to side-car zip)
    Wire Invoke-ConvoExchange into koe-RumA milestone event handler
#>

Set-StrictMode -Off

$script:ConvoVaultKeyEntry = 'agents/convo-vault-key'
$script:ConvoVaultLogName  = 'convo-vault.enc'
$script:ConvoBundleName    = 'convo-bundle.json'
$script:MaxConvoEntries    = 200   # rolling cap; oldest are dropped when exceeded

#   CRYPTO (PS 5.1 compatible AES-256-CBC + GZip, mirrors H-Ai-Nikr-Agi pattern)

function Protect-ConvoData {
    [CmdletBinding()]
    param([string]$PlainText, [byte[]]$Key)
    try {
        $raw = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $ms  = New-Object System.IO.MemoryStream
        $gz  = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($raw, 0, $raw.Length)
        $gz.Close()
        $compressed = $ms.ToArray()
        $ms.Dispose()

        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256; $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $Key
        $aes.GenerateIV()
        $iv            = $aes.IV
        $enc           = $aes.CreateEncryptor()
        $cipher        = $enc.TransformFinalBlock($compressed, 0, $compressed.Length)
        $aes.Dispose()

        $result = New-Object byte[] ($iv.Length + $cipher.Length)
        [Array]::Copy($iv,     0, $result, 0,          $iv.Length)
        [Array]::Copy($cipher, 0, $result, $iv.Length, $cipher.Length)
        return $result
    } catch {
        Write-AppLog -Message "Protect-ConvoData: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Unprotect-ConvoData {
    [CmdletBinding()]
    param([byte[]]$EncData, [byte[]]$Key)
    try {
        if (@($EncData).Count -lt 17) { return $null }
        $iv     = $EncData[0..15]
        $cipher = $EncData[16..($EncData.Length - 1)]

        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256; $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $Key
        $aes.IV        = $iv
        $dec           = $aes.CreateDecryptor()
        $compressed    = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $aes.Dispose()

        $inMs  = New-Object System.IO.MemoryStream(@(,$compressed))
        $gz    = New-Object System.IO.Compression.GZipStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
        $outMs = New-Object System.IO.MemoryStream
        $buf   = New-Object byte[] 4096
        do { $read = $gz.Read($buf, 0, $buf.Length); if ($read -gt 0) { $outMs.Write($buf, 0, $read) } } while ($read -gt 0)
        $gz.Close()
        $plain = [System.Text.Encoding]::UTF8.GetString($outMs.ToArray())
        $outMs.Dispose(); $inMs.Dispose()
        return $plain
    } catch {
        Write-AppLog -Message "Unprotect-ConvoData: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# ─── Per-entry encryption for web bundle (no GZip -- small entries, raw AES-CBC Base64) ───
function Protect-ConvoEntry {
    [CmdletBinding()]
    param([string]$PlainText, [byte[]]$Key)
    try {
        $raw           = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256; $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $Key
        $aes.GenerateIV()
        $iv            = $aes.IV
        $enc           = $aes.CreateEncryptor()
        $cipher        = $enc.TransformFinalBlock($raw, 0, $raw.Length)
        $aes.Dispose()
        $combined      = New-Object byte[] ($iv.Length + $cipher.Length)
        [Array]::Copy($iv,     0, $combined, 0,          $iv.Length)
        [Array]::Copy($cipher, 0, $combined, $iv.Length, $cipher.Length)
        return [Convert]::ToBase64String($combined)
    } catch {
        Write-AppLog -Message "Protect-ConvoEntry: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

#   KEY MANAGEMENT

function Initialize-ConvoVaultKey {
    <#
    .SYNOPSIS Returns the 32-byte AES key from vault, creating one if absent.
    #>
    [CmdletBinding()]
    param([string]$WorkspacePath)
    try {
        $vaultMod = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
        if (Test-Path $vaultMod) { Import-Module $vaultMod -Force -ErrorAction Stop }

        if (Get-Command Get-VaultItem -ErrorAction SilentlyContinue) {
            try {
                $b64 = Get-VaultItem -Key $script:ConvoVaultKeyEntry -ErrorAction SilentlyContinue
                if ($b64) { return [Convert]::FromBase64String($b64) }
            } catch { <# Intentional: vault locked -- generate ephemeral key #> }
        }

        # Generate + store new key
        $newKey = New-Object byte[] 32
        [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($newKey)
        $newB64 = [Convert]::ToBase64String($newKey)
        if (Get-Command Set-VaultItem -ErrorAction SilentlyContinue) {
            try { Set-VaultItem -Key $script:ConvoVaultKeyEntry -Value $newB64 -ErrorAction SilentlyContinue } catch { <# vault locked -- non-fatal #> }
        }
        return $newKey
    } catch {
        Write-AppLog -Message "Initialize-ConvoVaultKey: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

#   READ / WRITE

function Get-ConvoEntries {
    <#
    .SYNOPSIS Decrypts and returns all conversation entries. Returns empty array if vault unavailable.
    .OUTPUTS PSCustomObject[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [byte[]]$KeyOverride = $null
    )
    try {
        $key = if ($KeyOverride) { $KeyOverride } else { Initialize-ConvoVaultKey -WorkspacePath $WorkspacePath }
        if (-not $key) { return @() }

        $logPath = Join-Path (Join-Path $WorkspacePath 'logs') $script:ConvoVaultLogName
        if (-not (Test-Path $logPath)) { return @() }

        $raw  = [System.IO.File]::ReadAllBytes($logPath)
        $json = Unprotect-ConvoData -EncData $raw -Key $key
        if (-not $json) { return @() }
        return @($json | ConvertFrom-Json)
    } catch {
        Write-AppLog -Message "Get-ConvoEntries: $($_.Exception.Message)" -Level Warning
        return @()
    }
}

function Add-ConvoEntry {
    <#
    .SYNOPSIS Appends a single conversation exchange to the encrypted vault log.
    .PARAMETER WorkspacePath  Workspace root.
    .PARAMETER Entry  Ordered hashtable with: id, timestamp, sessionTag, topic, rumiVerse, rumiContext, nikrResponse, nikrCutoff, retort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [hashtable]$Entry,
        [byte[]]$KeyOverride = $null
    )
    try {
        $key = if ($KeyOverride) { $KeyOverride } else { Initialize-ConvoVaultKey -WorkspacePath $WorkspacePath }
        if (-not $key) {
            Write-AppLog -Message "Add-ConvoEntry: vault key unavailable -- entry not persisted" -Level Warning
            return $false
        }

        $logDir  = Join-Path $WorkspacePath 'logs'
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $logPath = Join-Path $logDir $script:ConvoVaultLogName

        # Load existing
        $entries = [System.Collections.ArrayList]::new()
        if (Test-Path $logPath) {
            try {
                $raw  = [System.IO.File]::ReadAllBytes($logPath)
                $json = Unprotect-ConvoData -EncData $raw -Key $key
                if ($json) { foreach ($e in @($json | ConvertFrom-Json)) { [void]$entries.Add($e) } }
            } catch { <# Intentional: corrupt/unreadable -- start fresh #> }
        }

        [void]$entries.Add($Entry)

        # Rolling cap: drop oldest when exceeded
        while ($entries.Count -gt $script:MaxConvoEntries) { $entries.RemoveAt(0) }

        $json    = @($entries) | ConvertTo-Json -Depth 8 -Compress
        $encData = Protect-ConvoData -PlainText $json -Key $key
        if ($encData) {
            [System.IO.File]::WriteAllBytes($logPath, $encData)
            return $true
        }
        return $false
    } catch {
        Write-AppLog -Message "Add-ConvoEntry: $($_.Exception.Message)" -Level Warning
        return $false
    }
}

#   CROSS-AGENT EXCHANGE (koe-RumA verse + H-Ai-Nikr-Agi response)

function Invoke-ConvoExchange {
    <#
    .SYNOPSIS Generates and persists one Rumi/Sumi cross-agent conversation exchange.
    .DESCRIPTION
        koe-RumA provides a Rumi verse and poetic context (Imagination/Dreams/Manifestation).
        H-Ai-Nikr-Agi responds with characteristic criticism and a retort.
        The exchange is saved to the encrypted ConvoVault and optionally returned.
    .PARAMETER WorkspacePath  Workspace root.
    .PARAMETER Topic          Conversation topic context.
    .PARAMETER SessionTag     Label for the pipeline session (e.g. 'BugScan-20260403').
    .PARAMETER Save           If set, persists to vault (default: true).
    .OUTPUTS PSCustomObject with .rumiVerse, .nikrResponse, .display, .id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string]$Topic      = 'General',
        [string]$SessionTag = '',
        [switch]$NoSave
    )
    try {
        # ── Load koe-RumA ──────────────────────────────────────────────────────
        $rumaMod = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'koe-RumA') (Join-Path 'core' 'koe-RumA.psm1')
        $rumaVerse    = 'The wound is the place where the Light enters you.'
        $rumaContext  = "An unfolding of $Topic"
        if (Test-Path $rumaMod) {
            try {
                Import-Module $rumaMod -Force -ErrorAction Stop
                if (Get-Command Get-RumiVerse -ErrorAction SilentlyContinue) {
                    $rumaVerse   = Get-RumiVerse
                    $rumaContext = "koe-RumA reflects on: $Topic"
                }
            } catch { <# Intentional: non-fatal, use defaults above #> }
        }

        # ── Load H-Ai-Nikr-Agi ────────────────────────────────────────────────
        $nikrMod = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'H-Ai-Nikr-Agi') (Join-Path 'core' 'H-Ai-Nikr-Agi.psm1')
        $nikrResponse = "I've heard livelier things from a cable modem handshake."
        $nikrCutoff   = "I'll be in the garden."
        $retort       = [ordered]@{ agent1 = 'koe-RumA'; line1 = "The garden of the codebase has no limits."; agent2 = $null; line2 = $null }
        if (Test-Path $nikrMod) {
            try {
                Import-Module $nikrMod -Force -ErrorAction Stop
                if (Get-Command Get-NikrAgiComment -ErrorAction SilentlyContinue) {
                    $nikrResponse = Get-NikrAgiComment -Topic $Topic
                    $nikrCutoff   = Get-NikrAgiCutoff
                    $retort       = Get-NikrAgiRetort -AgentCount 2
                }
            } catch { <# Intentional: non-fatal, use defaults above #> }
        }

        $entryId = "CONVO-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$(([System.Guid]::NewGuid().ToString('N')).Substring(0,6))"
        $entry   = [ordered]@{
            id           = $entryId
            timestamp    = [datetime]::UtcNow.ToString('o')
            sessionTag   = $SessionTag
            topic        = $Topic
            rumiVerse    = $rumaVerse
            rumiContext  = $rumaContext
            nikrResponse = $nikrResponse
            nikrCutoff   = $nikrCutoff
            retort       = [ordered]@{
                agent1   = $retort.agent1
                line1    = $retort.line1
                agent2   = $retort.agent2
                line2    = $retort.line2
            }
        }

        if (-not $NoSave) {
            Add-ConvoEntry -WorkspacePath $WorkspacePath -Entry $entry | Out-Null
        }

        $display = "[koe-RumA] `"$rumaVerse`"  |  [H-Ai-Nikr-Agi] $nikrResponse $nikrCutoff"
        if ($retort.agent1) { $display += "  |  [$($retort.agent1)]: $($retort.line1)" }
        if ($retort.agent2) { $display += "  |  [$($retort.agent2)]: $($retort.line2)" }

        return [PSCustomObject]@{
            id           = $entryId
            topic        = $Topic
            rumiVerse    = $rumaVerse
            rumiContext  = $rumaContext
            nikrResponse = $nikrResponse
            nikrCutoff   = $nikrCutoff
            retort       = $retort
            display      = $display
        }
    } catch {
        Write-AppLog -Message "Invoke-ConvoExchange: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

#   WEB BUNDLE EXPORT (encrypted per-entry for SubtleCrypto browser decryption)

function Export-ConvoBundle {
    <#
    .SYNOPSIS Exports per-entry AES-256-CBC encrypted Base64 bundle for browser delivery.
    .DESCRIPTION
        Writes convo-bundle.json to ~REPORTS/ConvoVault/.
        Each entry is individually encrypted (IV prepended, Base64 encoded).
        The browser page (Rumi/Sumi tab) decrypts each entry using SubtleCrypto when the user
        provides the vault key (Base64) in the passphrase field.
        Bundle schema: { exported, keyHint, entries: [ { id, timestamp, sessionTag, topic, cipher } ] }
    .PARAMETER WorkspacePath  Workspace root.
    .OUTPUTS [PSCustomObject] with .BundlePath, .EntryCount
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [byte[]]$KeyOverride = $null
    )
    try {
        $key = if ($KeyOverride) { $KeyOverride } else { Initialize-ConvoVaultKey -WorkspacePath $WorkspacePath }
        if (-not $key) {
            Write-AppLog -Message "Export-ConvoBundle: vault key unavailable" -Level Warning
            return $null
        }

        $entries = @(Get-ConvoEntries -WorkspacePath $WorkspacePath -KeyOverride $key)
        if (@($entries).Count -eq 0) {
            Write-AppLog -Message "Export-ConvoBundle: no entries to export" -Level Warning
        }

        $bundleEntries = [System.Collections.ArrayList]::new()
        foreach ($e in $entries) {
            $plainJson = $e | ConvertTo-Json -Depth 6 -Compress
            $cipher    = Protect-ConvoEntry -PlainText $plainJson -Key $key
            if ($cipher) {
                [void]$bundleEntries.Add([ordered]@{
                    id         = $e.id
                    timestamp  = $e.timestamp
                    sessionTag = $e.sessionTag
                    topic      = $e.topic
                    cipher     = $cipher
                })
            }
        }

        $bundle = [ordered]@{
            schema      = 'ConvoVault-Bundle/1.0'
            exported    = (Get-Date).ToUniversalTime().ToString('o')
            keyHint     = 'Vault key: vault item agents/convo-vault-key (Base64)'
            algorithm   = 'AES-256-CBC; first 16 bytes = IV; remainder = ciphertext; no GZip'
            entryCount  = $bundleEntries.Count
            entries     = @($bundleEntries)
        }

        $outDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'ConvoVault'
        if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
        $bundlePath = Join-Path $outDir $script:ConvoBundleName
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -Path $bundlePath -Encoding UTF8

        Write-Verbose "Export-ConvoBundle: $($bundleEntries.Count) entries -> $bundlePath"
        return [PSCustomObject]@{ BundlePath = $bundlePath; EntryCount = $bundleEntries.Count }
    } catch {
        Write-AppLog -Message "Export-ConvoBundle: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

#   EXPORTS


<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Initialize-ConvoVaultKey',
    'Get-ConvoEntries',
    'Add-ConvoEntry',
    'Invoke-ConvoExchange',
    'Export-ConvoBundle'
)







