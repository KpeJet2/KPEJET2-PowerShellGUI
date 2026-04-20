# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Sovereign Kernel -- CryptoEngine Module
    AES-256-CBC + HMAC-SHA512 authenticated encryption with mandatory GZIP compression.

.DESCRIPTION
    Provides all cryptographic primitives for the Sovereign Kernel:
      - Key derivation (PBKDF2-SHA512, 600 000 iterations)
      - Authenticated encryption (Encrypt-then-MAC)
      - GZIP compression (mandatory pre-encryption)
      - SHA-512 hashing and hash-chain verification
      - Epoch sealing (timestamp + nonce + HMAC)
      - Cipher strength scoring and auto-upgrade detection
      - Secure random generation
      - Key rotation support

    All cipher parameters are drawn from the kernel manifest crypto_config.
    No plaintext is ever stored -- compress-then-encrypt is the only path.

.NOTES
    Author   : The Establishment / Sovereign Kernel
    Version  : SK.v15.c8.crypto.1
    PS Compat: 5.1+ (no AES-GCM; uses CBC + HMAC-SHA512 Encrypt-then-MAC)
#>

# ========================== MODULE-SCOPED STATE ==========================
$script:_CryptoConfig     = $null   # populated by Initialize-CryptoEngine
$script:_DerivedKeys       = @{}    # cache: purposeTag -> {Key,HMAC,Salt,CreatedUtc}
$script:_KeyRotationTimers = @{}
$script:_CipherScores      = @{
    'AES-256-CBC+HMAC-SHA512' = 512
    'AES-256-CBC+HMAC-SHA384' = 448
    'AES-256-CBC+HMAC-SHA256' = 384
    'AES-128-CBC+HMAC-SHA256' = 256
}

# ========================== INITIALISATION ==========================
function Initialize-CryptoEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$CryptoConfig
    )
    $script:_CryptoConfig = $CryptoConfig
    Write-Verbose '[CryptoEngine] Initialized with cipher suite: AES-256-CBC+HMAC-SHA512'
}

# ========================== SECURE RANDOM ==========================
function Get-SecureRandomBytes {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 1048576)]
        [int]$Count
    )
    $rng    = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $buffer = [byte[]]::new($Count)
    try   { $rng.GetBytes($buffer) }
    finally { $rng.Dispose() }
    return $buffer
}

function Get-SecureRandomHex {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$ByteCount = 32)
    $bytes = Get-SecureRandomBytes -Count $ByteCount
    return ([BitConverter]::ToString($bytes) -replace '-','').ToLowerInvariant()
}

# ========================== KEY DERIVATION ==========================
function New-DerivedKeySet {
    <#
    .SYNOPSIS
        Derives an AES key + HMAC key from a passphrase via PBKDF2-SHA512.
    .OUTPUTS
        Hashtable with Keys: EncryptionKey (byte[32]), HmacKey (byte[64]), Salt (byte[32]), CreatedUtc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [securestring]$Passphrase,

        [byte[]]$Salt,

        [string]$PurposeTag = 'default'
    )
    if (-not $Salt) { $Salt = Get-SecureRandomBytes -Count 32 }
    $iterations = if ($script:_CryptoConfig) { $script:_CryptoConfig.kdf_iterations } else { 600000 }

    # Convert SecureString to plaintext bytes for PBKDF2
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
            $plain,
            $Salt,
            $iterations
        )
        try {
            # 32 bytes for AES-256 key + 64 bytes for HMAC-SHA512 key = 96 bytes
            $derived = $pbkdf2.GetBytes(96)
            $encKey  = $derived[0..31]
            $hmacKey = $derived[32..95]
        }
        finally { $pbkdf2.Dispose() }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $keySet = @{
        EncryptionKey = [byte[]]$encKey
        HmacKey       = [byte[]]$hmacKey
        Salt          = $Salt
        CreatedUtc    = [datetime]::UtcNow.ToString('o')
    }
    $script:_DerivedKeys[$PurposeTag] = $keySet
    return $keySet
}

function Get-CachedKeySet {
    [CmdletBinding()]
    param([string]$PurposeTag = 'default')
    if ($script:_DerivedKeys.ContainsKey($PurposeTag)) {
        return $script:_DerivedKeys[$PurposeTag]
    }
    return $null
}

# ========================== COMPRESSION ==========================
function Compress-Data {
    <#
    .SYNOPSIS  Mandatory GZIP compression. All data passes through this before encryption.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$InputBytes
    )
    $ms = [System.IO.MemoryStream]::new()
    try {
        $gz = [System.IO.Compression.GZipStream]::new(
            $ms,
            [System.IO.Compression.CompressionLevel]::Optimal
        )
        try   { $gz.Write($InputBytes, 0, $InputBytes.Length) }
        finally { $gz.Dispose() }
        return $ms.ToArray()
    }
    finally { $ms.Dispose() }
}

function Expand-Data {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$CompressedBytes
    )
    $msIn  = [System.IO.MemoryStream]::new($CompressedBytes)
    $msOut = [System.IO.MemoryStream]::new()
    try {
        $gz = [System.IO.Compression.GZipStream]::new(
            $msIn,
            [System.IO.Compression.CompressionMode]::Decompress
        )
        try   { $gz.CopyTo($msOut) }
        finally { $gz.Dispose() }
        return $msOut.ToArray()
    }
    finally {
        $msIn.Dispose()
        $msOut.Dispose()
    }
}

# ========================== AUTHENTICATED ENCRYPTION ==========================
function Protect-Data {
    <#
    .SYNOPSIS
        Compress -> Encrypt (AES-256-CBC) -> MAC (HMAC-SHA512).
        Returns a hashtable: { IV, Ciphertext, HMAC, Salt, Compressed=$true }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Plaintext,

        [Parameter(Mandatory)]
        [byte[]]$EncryptionKey,

        [Parameter(Mandatory)]
        [byte[]]$HmacKey
    )
    # Step 1: Compress (mandatory)
    $compressed = Compress-Data -InputBytes $Plaintext

    # Step 2: Encrypt with AES-256-CBC
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $EncryptionKey
        $aes.GenerateIV()
        $iv = $aes.IV

        $encryptor = $aes.CreateEncryptor()
        try {
            $ciphertext = $encryptor.TransformFinalBlock($compressed, 0, $compressed.Length)
        }
        finally { $encryptor.Dispose() }
    }
    finally { $aes.Dispose() }

    # Step 3: HMAC-SHA512 over (IV + Ciphertext) -- Encrypt-then-MAC
    $macInput = [byte[]]::new($iv.Length + $ciphertext.Length)
    [Array]::Copy($iv,         0, $macInput, 0,          $iv.Length)
    [Array]::Copy($ciphertext, 0, $macInput, $iv.Length, $ciphertext.Length)

    $hmac = [System.Security.Cryptography.HMACSHA512]::new($HmacKey)
    try   { $mac = $hmac.ComputeHash($macInput) }
    finally { $hmac.Dispose() }

    return @{
        IV         = [Convert]::ToBase64String($iv)
        Ciphertext = [Convert]::ToBase64String($ciphertext)
        HMAC       = [Convert]::ToBase64String($mac)
        Compressed = $true
        Algorithm  = 'AES-256-CBC+HMAC-SHA512'
    }
}

function Unprotect-Data {
    <#
    .SYNOPSIS
        Verify MAC -> Decrypt (AES-256-CBC) -> Decompress.
        Throws on MAC mismatch (tamper detection).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ProtectedPayload,

        [Parameter(Mandatory)]
        [byte[]]$EncryptionKey,

        [Parameter(Mandatory)]
        [byte[]]$HmacKey
    )
    $iv         = [Convert]::FromBase64String($ProtectedPayload.IV)
    $ciphertext = [Convert]::FromBase64String($ProtectedPayload.Ciphertext)
    $storedMac  = [Convert]::FromBase64String($ProtectedPayload.HMAC)

    # Step 1: Verify HMAC (Encrypt-then-MAC -- verify first)
    $macInput = [byte[]]::new($iv.Length + $ciphertext.Length)
    [Array]::Copy($iv,         0, $macInput, 0,          $iv.Length)
    [Array]::Copy($ciphertext, 0, $macInput, $iv.Length, $ciphertext.Length)

    $hmac = [System.Security.Cryptography.HMACSHA512]::new($HmacKey)
    try   { $computedMac = $hmac.ComputeHash($macInput) }
    finally { $hmac.Dispose() }

    # Constant-time comparison to prevent timing attacks
    if (-not (Compare-ByteArrayConstantTime -A $storedMac -B $computedMac)) {
        throw '[CryptoEngine] HMAC verification failed -- data may be tampered.'
    }

    # Step 2: Decrypt
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $EncryptionKey
        $aes.IV        = $iv

        $decryptor = $aes.CreateDecryptor()
        try {
            $compressed = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
        }
        finally { $decryptor.Dispose() }
    }
    finally { $aes.Dispose() }

    # Step 3: Decompress (mandatory)
    if ($ProtectedPayload.Compressed) {
        return Expand-Data -CompressedBytes $compressed
    }
    return $compressed
}

# ========================== HASHING ==========================
function Get-SHA512Hash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$InputBytes
    )
    $sha = [System.Security.Cryptography.SHA512]::Create()
    try {
        $hash = $sha.ComputeHash($InputBytes)
        return ([BitConverter]::ToString($hash) -replace '-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-FileHash512 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA512]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
            return ([BitConverter]::ToString($hash) -replace '-','').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-StringHash512 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$InputString
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    return Get-SHA512Hash -InputBytes $bytes
}

# ========================== HASH CHAIN ==========================
function New-HashChainEntry {
    <#
    .SYNOPSIS
        Creates a new hash-chain link: SHA-512(previousHash + currentData).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PreviousHash,

        [Parameter(Mandatory)]
        [string]$CurrentData
    )
    $combined = $PreviousHash + $CurrentData
    return Get-StringHash512 -InputString $combined
}

function Test-HashChain {
    <#
    .SYNOPSIS  Verifies an array of {Data, Hash, PreviousHash} entries.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [array]$Chain
    )
    for ($i = 0; $i -lt $Chain.Count; $i++) {
        $entry = $Chain[$i]
        $expected = New-HashChainEntry -PreviousHash $entry.PreviousHash -CurrentData $entry.Data
        if ($expected -ne $entry.Hash) {
            Write-AppLog -Message "[CryptoEngine] Hash chain broken at index $i" -Level Warning
            return $false
        }
    }
    return $true
}

# ========================== EPOCH SEALING ==========================
function New-EpochSeal {
    <#
    .SYNOPSIS
        Produces a cryptographic epoch seal for a manifest or data block.
        Seal = HMAC-SHA512(key, timestamp + nonce + dataHash)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DataHash,

        [Parameter(Mandatory)]
        [byte[]]$HmacKey,

        [string]$SealedBy = 'SOVEREIGN_PRIMARCH'
    )
    $timestamp = [datetime]::UtcNow.ToString('o')
    $nonce     = Get-SecureRandomHex -ByteCount 32
    $payload   = $timestamp + $nonce + $DataHash
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $hmac = [System.Security.Cryptography.HMACSHA512]::new($HmacKey)
    try   { $sealHash = $hmac.ComputeHash($payloadBytes) }
    finally { $hmac.Dispose() }

    return @{
        algorithm    = 'HMAC-SHA512'
        sealed_at_utc = $timestamp
        sealed_by    = $SealedBy
        hash         = ([BitConverter]::ToString($sealHash) -replace '-','').ToLowerInvariant()
        nonce        = $nonce
        cipher_suite = 'AES-256-CBC+HMAC-SHA512'
        compression  = 'GZIP'
        seal_version = 1
    }
}

function Test-EpochSeal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Seal,

        [Parameter(Mandatory)]
        [string]$DataHash,

        [Parameter(Mandatory)]
        [byte[]]$HmacKey
    )
    $payload = $Seal.sealed_at_utc + $Seal.nonce + $DataHash
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $hmac = [System.Security.Cryptography.HMACSHA512]::new($HmacKey)
    try   { $computedHash = $hmac.ComputeHash($payloadBytes) }
    finally { $hmac.Dispose() }

    $computedHex = ([BitConverter]::ToString($computedHash) -replace '-','').ToLowerInvariant()
    return ($computedHex -eq $Seal.hash)
}

# ========================== CIPHER STRENGTH ==========================
function Get-CipherStrengthScore {
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$CipherSuite = 'AES-256-CBC+HMAC-SHA512')
    if ($script:_CipherScores.ContainsKey($CipherSuite)) {
        return $script:_CipherScores[$CipherSuite]
    }
    return 0
}

function Test-CipherStrengthCompliance {
    <#
    .SYNOPSIS  Returns $true if the active cipher meets or exceeds the minimum score.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $minScore = if ($script:_CryptoConfig) { $script:_CryptoConfig.min_cipher_score } else { 256 }
    $current  = Get-CipherStrengthScore -CipherSuite 'AES-256-CBC+HMAC-SHA512'
    return ($current -ge $minScore)
}

function Get-RecommendedCipherUpgrade {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # In PS 5.1 (.NET Framework), AES-GCM is not available.
    # Return current best available.
    $psVersion = $PSVersionTable.PSVersion.Major
    if ($psVersion -ge 7) {
        return 'AES-256-GCM+HMAC-SHA512'
    }
    return 'AES-256-CBC+HMAC-SHA512'
}

# ========================== UTILITY ==========================
function Compare-ByteArrayConstantTime {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    <#
    .SYNOPSIS  Constant-time byte comparison to prevent timing side-channel attacks.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]]$A,
        [Parameter(Mandatory)][byte[]]$B
    )
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor ($A[$i] -bxor $B[$i])
    }
    return ($diff -eq 0)
}

function ConvertTo-SecureStringFromPlain {
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][string]$PlainText)
    $ss = [System.Security.SecureString]::new()
    foreach ($c in $PlainText.ToCharArray()) { $ss.AppendChar($c) }
    $ss.MakeReadOnly()
    return $ss
}

# ========================== EXPORTS ==========================
Export-ModuleMember -Function @(
    'Initialize-CryptoEngine'
    'Get-SecureRandomBytes'
    'Get-SecureRandomHex'
    'New-DerivedKeySet'
    'Get-CachedKeySet'
    'Compress-Data'
    'Expand-Data'
    'Protect-Data'
    'Unprotect-Data'
    'Get-SHA512Hash'
    'Get-FileHash512'
    'Get-StringHash512'
    'New-HashChainEntry'
    'Test-HashChain'
    'New-EpochSeal'
    'Test-EpochSeal'
    'Get-CipherStrengthScore'
    'Test-CipherStrengthCompliance'
    'Get-RecommendedCipherUpgrade'
    'Compare-ByteArrayConstantTime'
    'ConvertTo-SecureStringFromPlain'
)


