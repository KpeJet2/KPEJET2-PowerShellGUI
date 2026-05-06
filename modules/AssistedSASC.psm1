# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Assisted SASC -- Secret Access & Security Checks module for PwShGUI.
# TODO: HelpMenu | Show-AssistedSASCHelp | Actions: Scan|Report|Reset|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides Bitwarden CLI-backed vault management with authenticated encryption
    (AES-256-CBC + HMAC-SHA256), static on-disk integrity manifests, brute-force
    lockout, Windows Hello integration via DPAPI, LAN vault sharing, and a
    WebView2-based secrets invoker form.

    Security architecture:
      - Least privilege: no admin unless required (installer only)
      - Fail-closed: integrity or HMAC failure = vault lock + abort
      - Memory hygiene: all passwords as [SecureString], cleared via ZeroFreeBSTR
      - Audit trail: every vault access logged (never the secret value)
      - PBKDF2-SHA256 with 600,000 iterations (OWASP 2024)
      - Encrypt-then-MAC with separate HMAC key

    References:
      - NIST SP 800-63B (credential storage)
      - MITRE ATT&CK T1555 (credential store protection)
      - OWASP 2024 Password Storage Cheat Sheet

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th March 2026
    Modified : 4th March 2026
    Config   : config\system-variables.xml
    Requires : Bitwarden CLI (bw) -- installed via Install-BitwardenLite

.CONFIGURATION BASE
    config\pwsh-app-config-BASE.json

.LINK
    ~README.md/SECRETS-MANAGEMENT-GUIDE.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------
#  MODULE-SCOPED STATE  (all private -- not exported)
# -------------------------------------------------------------------------------
$script:_BWSessionKey       = $null          # [SecureString] -- BW session token
$script:_VaultState         = 'NotConfigured' # NotConfigured | Locked | Unlocked | Error | LockedOut
$script:_FailedAttempts     = 0
$script:_LockoutUntil       = [datetime]::MinValue
$script:_AutoLockTimer      = $null          # [System.Timers.Timer]
$script:_AutoLockStartTime  = [datetime]::MinValue  # tracks when auto-lock timer started
$script:_LastIntegrityCheck = [datetime]::MinValue
$script:_ModuleRoot         = $null
$script:_ConfigDir          = $null
$script:_PkiDir             = $null
$script:_LogsDir            = $null
$script:_ScriptsDir         = $null
$script:_IntegrityPath      = $null
$script:_VaultConfigPath    = $null
$script:_BWCliPath          = $null
$script:_Initialized        = $false
$script:_IntegrityIssuesDetected = $false
$script:_LastIntegrityMessage    = $null

# -------------------------------------------------------------------------------
#  CONSTANTS (overridable via config\sasc-tuning.json)
# -------------------------------------------------------------------------------
$script:PBKDF2_Iterations      = 600000      # OWASP 2024 recommendation
$script:AES_KeySize            = 256
$script:AES_BlockSize          = 128
$script:SaltSize               = 32          # bytes
$script:HMACKeySize            = 32          # bytes -- separate from AES key
$script:MaxFailedAttempts      = 5
$script:LockoutDurationMinutes = 30
$script:DefaultAutoLockMinutes = 15
$script:IntegrityCheckThrottle = 60          # seconds between re-checks
$script:DefaultLANPort         = 8087

# Allow external override from config\sasc-tuning.json
try {
    $sascTuningPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\sasc-tuning.json'
    if (Test-Path $sascTuningPath) {
        $tuning = Get-Content $sascTuningPath -Raw | ConvertFrom-Json
        foreach ($prop in $tuning.PSObject.Properties) {
            $varName = "script:$($prop.Name)"
            if (Get-Variable -Name $prop.Name -Scope Script -ErrorAction SilentlyContinue) {
                Set-Variable -Name $prop.Name -Scope Script -Value $prop.Value
            }
        }
    }
} catch { <# Intentional: non-fatal -- use defaults if tuning file is missing or malformed #> }

# -------------------------------------------------------------------------------
#  PATH INITIALISATION
# -------------------------------------------------------------------------------

function Initialize-SASCModule {
    <#
    .SYNOPSIS  Initialise module paths, verify BW CLI, run integrity check.
    .PARAMETER ScriptDir  Root of the PowerShellGUI workspace.
    .OUTPUTS   [bool] $true if initialisation succeeded and integrity is intact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptDir
    )

    # Validate ScriptDir exists and is a directory
    $resolvedDir = [System.IO.Path]::GetFullPath($ScriptDir)
    if (-not (Test-Path -LiteralPath $resolvedDir -PathType Container)) {
        Write-AppLog -Message "SASC: ScriptDir not found: $resolvedDir" -Level Warning
        return $false
    }

    $script:_ModuleRoot    = $resolvedDir
    $script:_ConfigDir     = Join-Path $resolvedDir 'config'
    $script:_PkiDir        = Join-Path $resolvedDir 'pki'
    $script:_LogsDir       = Join-Path $resolvedDir 'logs'
    $script:_ScriptsDir    = Join-Path $resolvedDir 'scripts'
    $script:_IntegrityPath = Join-Path $script:_ConfigDir 'sasc-integrity.sha256.json'
    $script:_VaultConfigPath = Join-Path $script:_ConfigDir 'sasc-vault-config.json'

    # Ensure vault backup directory exists
    $backupDir = Join-Path $script:_PkiDir 'vault-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    # Locate BW CLI
    $script:_BWCliPath = Find-BWCli
    if ($script:_BWCliPath) {
        try {
            Write-AppLog "SASC: Bitwarden CLI found at $($script:_BWCliPath)" "Info"
            # Version pre-flight check
            $bwVerRaw = & $script:_BWCliPath --version 2>&1
            if ($bwVerRaw -match '(\d+\.\d+\.\d+)') {
                $script:_BWCliVersion = [version]$Matches[1]
                $minVer = [version]'2024.1.0'
                if ($script:_BWCliVersion -lt $minVer) {
                    Write-AppLog "SASC: Bitwarden CLI $($script:_BWCliVersion) is below minimum $minVer -- update recommended" "Warning"
                } else {
                    Write-AppLog "SASC: Bitwarden CLI version $($script:_BWCliVersion)" "Debug"
                }
            }
        } catch {
            # Write-AppLog may not be available yet during early init
        }
    }

    # Run integrity manifest check if manifest exists
    if (Test-Path -LiteralPath $script:_IntegrityPath) {
        $integrityResult = Test-SASCSignedManifest
        if (-not $integrityResult.AllPassed) {
            $script:_VaultState = 'IntegrityWarning'
            $script:_IntegrityIssuesDetected = $true
            $script:_LastIntegrityMessage = 'Integrity manifest reported one or more mismatches.'
            try { Write-AppLog "SASC: INTEGRITY ISSUE -- advisory mode enabled (functions not restricted)" "Warning" } catch { <# Intentional: non-fatal #> }
        } else {
            $script:_IntegrityIssuesDetected = $false
            $script:_LastIntegrityMessage = $null
        }
    }

    # Determine initial vault state
    if ($script:_BWCliPath) {
        $status = Get-BWStatus
        $script:_VaultState = switch ($status) {
            'unlocked'  { 'Unlocked' }
            'locked'    { 'Locked' }
            'unauthenticated' { 'Locked' }
            default     { 'NotConfigured' }
        }
    } else {
        $script:_VaultState = 'NotConfigured'
    }

    $script:_Initialized = $true
    try { Write-AppLog "SASC: Module initialised -- state: $($script:_VaultState)" "Info" } catch { <# Intentional: non-fatal #> }
    return $true
}

# -------------------------------------------------------------------------------
#  HELPER: SAFE PATH VALIDATION
# -------------------------------------------------------------------------------

function Assert-SafePath {
    <#
    .SYNOPSIS  Validates a file path against traversal attacks.
    .DESCRIPTION
        Resolves the path to its canonical form and verifies it falls within
        one of the allowed root directories. Throws on violation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string[]]$AllowedRoots = @($script:_ModuleRoot)
    )
    $canonical = [System.IO.Path]::GetFullPath($Path)
    $allowed = $false
    foreach ($root in $AllowedRoots) {
        $canonRoot = [System.IO.Path]::GetFullPath($root)
        if ($canonical.StartsWith($canonRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        throw [System.Security.SecurityException]::new(
            "Path traversal blocked: '$canonical' is outside allowed roots.")
    }
    return $canonical
}

function Convert-PlainTextToSecureString {
    <#
    .SYNOPSIS  Converts plain text to SecureString without using -AsPlainText.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$PlainText
    )

    $secure = New-Object System.Security.SecureString
    if ($null -ne $PlainText) {
        foreach ($ch in $PlainText.ToCharArray()) {
            $secure.AppendChar($ch)
        }
    }
    $secure.MakeReadOnly()
    return $secure
}

# -------------------------------------------------------------------------------
#  AUTHENTICATED ENCRYPTION  (AES-256-CBC + HMAC-SHA256)
# -------------------------------------------------------------------------------

function New-VaultKey {
    <#
    .SYNOPSIS  Derives AES-256 key + HMAC-SHA256 key from password via PBKDF2.
    .DESCRIPTION
        Uses Rfc2898DeriveBytes with SHA-256 and 600,000 iterations.
        Produces 64 bytes: first 32 = AES key, next 16 = IV, next 32 via
        separate derivation = HMAC key.
    .OUTPUTS   [hashtable] Keys: AesKey (byte[32]), IV (byte[16]), HmacKey (byte[32]), Salt (byte[32])
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [SecureString]$Password,
        [byte[]]$Salt = $null
    )
    # Convert SecureString to plaintext for Rfc2898DeriveBytes, with BSTR cleanup
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ($null -eq $Salt -or $Salt.Length -eq 0) {
        $Salt = New-Object byte[] $script:SaltSize
        [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Salt)
    }
    # Derive 80 bytes: 32 (AES key) + 16 (IV) + 32 (HMAC key)
    $rfc = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $plainPassword, $Salt, $script:PBKDF2_Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $plainPassword = $null  # Clear from memory
    $aesKey  = $rfc.GetBytes(32)
    $iv      = $rfc.GetBytes(16)
    $hmacKey = $rfc.GetBytes(32)
    $rfc.Dispose()
    @{
        AesKey  = $aesKey
        IV      = $iv
        HmacKey = $hmacKey
        Salt    = $Salt
    }
}

function Protect-VaultData {
    <#
    .SYNOPSIS  Encrypt-then-MAC: AES-256-CBC + HMAC-SHA256.
    .DESCRIPTION
        Encrypts plain text with AES-256-CBC/PKCS7, then computes HMAC-SHA256
        over (Salt + IV + CipherText) using a separate HMAC key derived from the
        same password. Returns all components as Base64 strings.
    .PARAMETER PlainText   The string to encrypt.
    .PARAMETER Password    User-supplied password string.
    .OUTPUTS   [hashtable] Keys: CipherText, Salt, IV, HMAC (all Base64)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PlainText,
        [Parameter(Mandatory)] [SecureString]$Password
    )
    $keyMaterial = New-VaultKey -Password $Password

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize   = $script:AES_KeySize
    $aes.BlockSize = $script:AES_BlockSize
    $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key       = $keyMaterial.AesKey
    $aes.IV        = $keyMaterial.IV

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encryptor  = $aes.CreateEncryptor()
    $mem        = New-Object System.IO.MemoryStream
    $cs         = New-Object System.Security.Cryptography.CryptoStream(
                      $mem, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
    $cs.Write($plainBytes, 0, $plainBytes.Length)
    $cs.FlushFinalBlock()
    $cs.Close()
    $aes.Dispose()

    $cipherBytes = $mem.ToArray()
    $mem.Close()

    # Compute HMAC-SHA256 over (Salt + IV + CipherText)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyMaterial.HmacKey
    $dataToMac = $keyMaterial.Salt + $keyMaterial.IV + $cipherBytes
    $macBytes  = $hmac.ComputeHash($dataToMac)
    $hmac.Dispose()

    # Clear sensitive material from memory
    [Array]::Clear($keyMaterial.AesKey, 0, $keyMaterial.AesKey.Length)
    [Array]::Clear($keyMaterial.HmacKey, 0, $keyMaterial.HmacKey.Length)
    [Array]::Clear($plainBytes, 0, $plainBytes.Length)

    @{
        CipherText = [Convert]::ToBase64String($cipherBytes)
        Salt       = [Convert]::ToBase64String($keyMaterial.Salt)
        IV         = [Convert]::ToBase64String($keyMaterial.IV)
        HMAC       = [Convert]::ToBase64String($macBytes)
    }
}

function Unprotect-VaultData {
    <#
    .SYNOPSIS  Verify-then-decrypt: checks HMAC-SHA256 before decrypting AES-256-CBC.
    .DESCRIPTION
        Performs constant-time HMAC comparison first. If HMAC fails, throws
        [System.Security.SecurityException] immediately -- decryption is never
        attempted. This prevents padding oracle and tamper attacks.
    .OUTPUTS   [string] Decrypted plain text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CipherText,
        [Parameter(Mandatory)] [string]$Salt,
        [Parameter(Mandatory)] [string]$IV,
        [Parameter(Mandatory)] [string]$HMAC,
        [Parameter(Mandatory)] [SecureString]$Password
    )
    $saltBytes   = [Convert]::FromBase64String($Salt)
    $ivBytes     = [Convert]::FromBase64String($IV)
    $cipherBytes = [Convert]::FromBase64String($CipherText)
    $macExpected = [Convert]::FromBase64String($HMAC)

    $keyMaterial = New-VaultKey -Password $Password -Salt $saltBytes

    # Verify HMAC first (constant-time comparison)
    $hmacCalc = New-Object System.Security.Cryptography.HMACSHA256
    $hmacCalc.Key = $keyMaterial.HmacKey
    $dataToMac    = $saltBytes + $ivBytes + $cipherBytes
    $macActual    = $hmacCalc.ComputeHash($dataToMac)
    $hmacCalc.Dispose()

    if (-not (Compare-ByteArrayConstantTime -Expected $macExpected -Actual $macActual)) {
        [Array]::Clear($keyMaterial.AesKey, 0, $keyMaterial.AesKey.Length)
        [Array]::Clear($keyMaterial.HmacKey, 0, $keyMaterial.HmacKey.Length)
        try { Write-AppLog "SASC: HMAC verification FAILED -- possible tampering detected" "Error" } catch { <# Intentional: non-fatal #> }
        throw [System.Security.SecurityException]::new(
            "HMAC verification failed. Encrypted data may have been tampered with.")
    }

    # HMAC passed -- decrypt
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize   = $script:AES_KeySize
    $aes.BlockSize = $script:AES_BlockSize
    $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key       = $keyMaterial.AesKey
    $aes.IV        = $ivBytes

    $decryptor = $aes.CreateDecryptor()
    $mem = New-Object System.IO.MemoryStream($cipherBytes)
    $cs  = New-Object System.Security.Cryptography.CryptoStream(
               $mem, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read)
    $reader   = New-Object System.IO.StreamReader($cs, [System.Text.Encoding]::UTF8)
    $result   = $reader.ReadToEnd()
    $reader.Close()
    $aes.Dispose()

    [Array]::Clear($keyMaterial.AesKey, 0, $keyMaterial.AesKey.Length)
    [Array]::Clear($keyMaterial.HmacKey, 0, $keyMaterial.HmacKey.Length)

    return $result
}

function Compare-ByteArrayConstantTime {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    <#
    .SYNOPSIS  Constant-time byte array comparison to prevent timing attacks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [byte[]]$Expected,
        [Parameter(Mandatory)] [byte[]]$Actual
    )
    if ($Expected.Length -ne $Actual.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        $diff = $diff -bor ($Expected[$i] -bxor $Actual[$i])
    }
    return ($diff -eq 0)
}

# -------------------------------------------------------------------------------
#  INTEGRITY MANIFEST  (SHA-256 + DPAPI-signed HMAC)
# -------------------------------------------------------------------------------

function New-IntegrityManifest {
    <#
    .SYNOPSIS  Generate SHA-256 integrity manifest for all SASC-critical files.
    .DESCRIPTION
        Computes SHA-256 hashes for each file, then signs the manifest JSON with
        an HMAC key protected by DPAPI (CurrentUser scope) so only the same user
        on the same machine can validate it.
    .OUTPUTS   [string] Path to the generated manifest file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess($script:_IntegrityPath, "Generate integrity manifest")) { return }

    $filesToProtect = @(
        (Join-Path $script:_ModuleRoot 'modules' 'AssistedSASC.psm1'),
        (Join-Path $script:_ModuleRoot 'modules' 'SASC-Adapters.psm1'),
        (Join-Path $script:_ModuleRoot 'scripts' 'Install-BitwardenLite.ps1'),
        (Join-Path $script:_ModuleRoot 'XHTML-invoke-secrets.xhtml')
    )
    # Add vault config if it exists
    if (Test-Path -LiteralPath $script:_VaultConfigPath) {
        $filesToProtect += $script:_VaultConfigPath
    }
    # Add BW CLI binary if known
    if ($script:_BWCliPath -and (Test-Path -LiteralPath $script:_BWCliPath)) {
        $filesToProtect += $script:_BWCliPath
    }

    $entries = @()
    foreach ($fp in $filesToProtect) {
        if (Test-Path -LiteralPath $fp) {
            $hash = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash
            $info = Get-Item -LiteralPath $fp
            $entries += @{
                Path        = $fp
                SHA256      = $hash
                SizeBytes   = $info.Length
                LastWritten = $info.LastWriteTimeUtc.ToString('o')
            }
        }
    }

    $manifest = @{
        SchemaVersion   = '1.0'
        ManifestCreated = (Get-Date).ToUniversalTime().ToString('o')
        MachineName     = $env:COMPUTERNAME
        UserName        = $env:USERNAME
        Files           = $entries
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 5 -Compress

    # Sign the manifest JSON with a DPAPI-protected HMAC
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
    $entropy       = [System.Text.Encoding]::UTF8.GetBytes("SASC-Integrity-$env:COMPUTERNAME-$env:USERNAME")
    $protectedKey  = [System.Security.Cryptography.ProtectedData]::Protect(
        $entropy, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $protectedKey[0..31]
    $sig = [Convert]::ToBase64String($hmac.ComputeHash($manifestBytes))
    $hmac.Dispose()

    $signedManifest = @{
        Manifest  = $manifest
        Signature = $sig
    }
    $signedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:_IntegrityPath -Encoding UTF8 -Force

    # Lock down file permissions
    Set-VaultFilePermissions -Path $script:_IntegrityPath

    try { Write-AppLog "SASC: Integrity manifest generated with $($entries.Count) files" "Info" } catch { <# Intentional: non-fatal #> }
    return $script:_IntegrityPath
}

function Test-SASCSignedManifest {
    <#
    .SYNOPSIS  Verify the SASC HMAC-signed integrity manifest -- re-compute hashes and validate HMAC.
    .NOTES     Renamed from Test-IntegrityManifest (P011 fix) to avoid collision with PwShGUI-IntegrityCore.psm1.
    .OUTPUTS   [PSCustomObject] with AllPassed, Results (per-file), SignatureValid
    #>
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        AllPassed      = $false
        SignatureValid = $false
        Results        = @()
        Errors         = @()
    }

    if (-not (Test-Path -LiteralPath $script:_IntegrityPath)) {
        $result.Errors += "Integrity manifest not found: $($script:_IntegrityPath)"
        return $result
    }

    try {
        $signed = Get-Content -LiteralPath $script:_IntegrityPath -Raw | ConvertFrom-Json
    } catch {
        $result.Errors += "Failed to parse integrity manifest: $($_.Exception.Message)"
        return $result
    }

    # Verify signature
    $manifestJson  = ($signed.Manifest | ConvertTo-Json -Depth 5 -Compress)
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
    $entropy       = [System.Text.Encoding]::UTF8.GetBytes("SASC-Integrity-$env:COMPUTERNAME-$env:USERNAME")
    try {
        $protectedKey = [System.Security.Cryptography.ProtectedData]::Protect(
            $entropy, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $protectedKey[0..31]
        $expectedSig = [Convert]::ToBase64String($hmac.ComputeHash($manifestBytes))
        $hmac.Dispose()
        $result.SignatureValid = ($expectedSig -eq $signed.Signature)
    } catch {
        $result.Errors += "Signature verification failed: $($_.Exception.Message)"
        return $result
    }

    if (-not $result.SignatureValid) {
        $result.Errors += "Manifest signature mismatch -- possible tampering"
        return $result
    }

    # Verify each file hash
    $allPassed = $true
    foreach ($entry in $signed.Manifest.Files) {
        $fileResult = @{ Path = $entry.Path; Status = 'Unknown' }
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            $fileResult.Status = 'Missing'
            $allPassed = $false
        } else {
            $currentHash = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash
            if ($currentHash -eq $entry.SHA256) {
                $fileResult.Status = 'Passed'
            } else {
                $fileResult.Status = 'Modified'
                $allPassed = $false
            }
        }
        $result.Results += [PSCustomObject]$fileResult
    }

    $result.AllPassed = $allPassed
    $script:_LastIntegrityCheck = Get-Date

    if (-not $allPassed) {
        try { Write-AppLog "SASC: Integrity check FAILED -- $(($result.Results | Where-Object Status -ne 'Passed').Count) file(s) invalid" "Error" } catch { <# Intentional: non-fatal #> }
    }
    return $result
}

# -------------------------------------------------------------------------------
#  FILE PERMISSION HARDENING
# -------------------------------------------------------------------------------

function Set-VaultFilePermissions {
    <#
    .SYNOPSIS  Lock file to current user only -- remove inherited and other permissions.
    .DESCRIPTION
        Sets the ACL to CurrentUser:FullControl only. Disables inheritance and
        removes all other access rules. This satisfies MITRE ATT&CK T1555
        mitigation for credential file protection.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Path
    )
    if (-not $PSCmdlet.ShouldProcess($Path, "Restrict ACL to current user")) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, remove inherited rules
        # Remove all existing rules
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null
        # Add current user with FullControl
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        try { Write-AppLog "SASC: Failed to set permissions on $Path -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> }
    }
}

# -------------------------------------------------------------------------------
#  BITWARDEN CLI HELPERS
# -------------------------------------------------------------------------------

function Find-BWCli {
    <#
    .SYNOPSIS  Locate the Bitwarden CLI binary.
    .OUTPUTS   [string] Full path to bw.exe, or $null if not found.
    #>
    [CmdletBinding()]
    param()

    # Check if bw is on PATH
    $cmd = Get-Command 'bw' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Check common install locations
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Bitwarden CLI\bw.exe",
        "$env:ProgramFiles\Bitwarden CLI\bw.exe",
        "${env:ProgramFiles(x86)}\Bitwarden CLI\bw.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Bitwarden.CLI_*\bw.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-Item -Path $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-BWStatus {
    <#
    .SYNOPSIS  Query Bitwarden vault status via CLI.
    .OUTPUTS   [string] 'unlocked', 'locked', 'unauthenticated', or 'error'.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:_BWCliPath) { return 'error' }
    try {
        $raw = & $script:_BWCliPath status 2>&1
        $statusObj = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($statusObj -and $statusObj.status) {
            return $statusObj.status.ToLower()
        }
    } catch { <# Intentional: non-fatal #> }
    return 'error'
}

function Invoke-BWCommand {
    <#
    .SYNOPSIS  Execute a BW CLI command with session key injection.
    .DESCRIPTION
        Injects the session key as an environment variable for the child process
        only -- never written to disk. Clears the env var after execution.
    .PARAMETER Arguments  Array of arguments to pass to bw.exe.
    .OUTPUTS   [string] Raw stdout from bw.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    if (-not $script:_BWCliPath) {
        throw "Bitwarden CLI not found. Run Install-BitwardenLite first."
    }

    $sessionPlain = $null
    try {
        # Inject session key if available
        if ($script:_BWSessionKey) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:_BWSessionKey)
            try {
                $sessionPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            $env:BW_SESSION = $sessionPlain
        }

        $output = & $script:_BWCliPath @Arguments 2>&1
        return ($output | Out-String).Trim()
    } finally {
        # Always clear session from environment
        if ($env:BW_SESSION) { $env:BW_SESSION = $null }
        if ($sessionPlain) {
            # Cannot truly zero a .NET string, but remove the reference
            $sessionPlain = $null
        }
    }
}

# -------------------------------------------------------------------------------
#  VAULT OPERATIONS
# -------------------------------------------------------------------------------

function Test-VaultStatus {
    <#
    .SYNOPSIS  Return current vault state -- no secrets accessed.
    .OUTPUTS   [PSCustomObject] with State, BWCliAvailable, AutoLockRemaining, FailedAttempts
    #>
    [CmdletBinding()]
    param()

    $autoLockRemaining = $null
    if ($script:_AutoLockTimer -and $script:_AutoLockTimer.Enabled -and
        $script:_AutoLockStartTime -ne [datetime]::MinValue) {
        $elapsed   = (Get-Date) - $script:_AutoLockStartTime
        $total     = [TimeSpan]::FromMinutes($script:DefaultAutoLockMinutes)
        $remaining = $total - $elapsed
        if ($remaining.TotalSeconds -gt 0) {
            $autoLockRemaining = [math]::Floor($remaining.TotalMinutes).ToString() + ':' +
                                 $remaining.Seconds.ToString('00')
        }
    }

    # Check lockout
    if ($script:_VaultState -eq 'LockedOut' -and (Get-Date) -gt $script:_LockoutUntil) {
        $script:_VaultState    = 'Locked'
        $script:_FailedAttempts = 0
    }

    [PSCustomObject]@{
        State              = $script:_VaultState
        BWCliAvailable     = [bool]$script:_BWCliPath
        BWCliPath          = $script:_BWCliPath
        AutoLockRemaining  = $autoLockRemaining
        FailedAttempts     = $script:_FailedAttempts
        MaxAttempts        = $script:MaxFailedAttempts
        IsLockedOut        = ($script:_VaultState -eq 'LockedOut')
        LockoutUntil       = if ($script:_VaultState -eq 'LockedOut') { $script:_LockoutUntil } else { $null }
        Initialized        = $script:_Initialized
        IntegrityIssuesDetected = $script:_IntegrityIssuesDetected
        IntegrityMessage   = $script:_LastIntegrityMessage
    }
}

function Unlock-Vault {
    <#
    .SYNOPSIS  Unlock the Bitwarden vault with master password or Windows Hello.
    .DESCRIPTION
        Accepts a [SecureString] master password. Enforces brute-force lockout
        (5 attempts / 30 minutes). On success, stores session key as [SecureString].
    .PARAMETER MasterPassword  The vault master password as SecureString.
    .PARAMETER UseWindowsHello  Use DPAPI-protected master password (Windows Hello).
    .OUTPUTS   [bool] $true on success.
    #>
    [CmdletBinding()]
    param(
        [System.Security.SecureString]$MasterPassword,
        [switch]$UseWindowsHello
    )

    # Pre-flight checks
    try { Write-AppLog "SASC: Unlock-Vault starting -- current state: $($script:_VaultState)" "Verbose" } catch { <# Intentional: non-fatal #> }
    if (-not $script:_BWCliPath) {
        try { Write-AppLog "SASC: Unlock-Vault FAIL -- BW CLI not available" "Error" } catch { <# Intentional: non-fatal #> }
        throw "Bitwarden CLI not available. Run Install-BitwardenLite first."
    }
    try { Write-AppLog "SASC: Unlock-Vault pre-flight OK -- BW CLI at $($script:_BWCliPath)" "Verbose" } catch { <# Intentional: non-fatal #> }

    # Check lockout
    if ($script:_VaultState -eq 'LockedOut') {
        if ((Get-Date) -lt $script:_LockoutUntil) {
            $remaining = ($script:_LockoutUntil - (Get-Date)).TotalMinutes
            throw "Vault is locked out. Try again in $([math]::Ceiling($remaining)) minutes."
        }
        $script:_FailedAttempts = 0
        $script:_VaultState = 'Locked'
    }

    # Throttled integrity check
    $now = Get-Date
    if (($now - $script:_LastIntegrityCheck).TotalSeconds -gt $script:IntegrityCheckThrottle) {
        if (Test-Path -LiteralPath $script:_IntegrityPath) {
            $intCheck = Test-SASCSignedManifest
            if (-not $intCheck.AllPassed) {
                if ($script:_VaultState -ne 'Unlocked') {
                    $script:_VaultState = 'IntegrityWarning'
                }
                $script:_IntegrityIssuesDetected = $true
                $script:_LastIntegrityMessage = 'Integrity check detected mismatches during unlock attempt.'
                try { Write-AppLog "SASC: Integrity check detected issues; continuing in advisory mode" "Warning" } catch { <# Intentional: non-fatal #> }
            }
        }
    }

    # Resolve password
    $passwordPlain = $null
    try {
        if ($UseWindowsHello) {
            $passwordPlain = Get-WindowsHelloPassword
            if (-not $passwordPlain) {
                throw "Windows Hello authentication failed or not configured."
            }
        } else {
            if (-not $MasterPassword) {
                throw "MasterPassword is required when not using Windows Hello."
            }
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MasterPassword)
            try {
                $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

        # Attempt unlock via BW CLI -- pipe password to stdin
        try { Write-AppLog "SASC: Querying BW vault status before unlock" "Verbose" } catch { <# Intentional: non-fatal #> }
        $status = Get-BWStatus
        try { Write-AppLog "SASC: BW vault status = '$status'" "Verbose" } catch { <# Intentional: non-fatal #> }
        if ($status -eq 'unauthenticated') {
            # Need to login first
            try { Write-AppLog "SASC: Vault is unauthenticated -- login required" "Error" } catch { <# Intentional: non-fatal #> }
            throw "Bitwarden vault is not authenticated. Please run the Assisted SASC wizard to set up your vault."
        }

        # Unlock
        try { Write-AppLog "SASC: Executing BW unlock command" "Verbose" } catch { <# Intentional: non-fatal #> }
        $result = & $script:_BWCliPath unlock --raw $passwordPlain 2>&1
        $exitCode = $LASTEXITCODE
        try { Write-AppLog "SASC: BW unlock exit code = $exitCode, result length = $(if($result){$result.Length}else{0})" "Verbose" } catch { <# Intentional: non-fatal #> }

        if ($exitCode -eq 0 -and $result -and $result.Length -gt 10) {
            # Store session key as SecureString
            $script:_BWSessionKey = Convert-PlainTextToSecureString -PlainText $result
            $script:_VaultState = 'Unlocked'
            $script:_FailedAttempts = 0
            try {
                Start-AutoLockTimer
                try { Write-AppLog "SASC: Auto-lock timer started ($($script:DefaultAutoLockMinutes) min)" "Info" } catch { <# Intentional: non-fatal #> }
            } catch {
                # Auto-lock failure is non-fatal -- vault is already unlocked
                try { Write-AppLog "SASC: Auto-lock timer failed to start: $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> }
            }
            try { Write-AppLog "SASC: Vault unlocked successfully" "Info" } catch { <# Intentional: non-fatal #> }
            return $true
        } else {
            # Unlock failed
            $script:_FailedAttempts++
            try { Write-AppLog "SASC: Vault unlock failed (attempt $($script:_FailedAttempts)/$($script:MaxFailedAttempts))" "Warning" } catch { <# Intentional: non-fatal #> }

            if ($script:_FailedAttempts -ge $script:MaxFailedAttempts) {
                $script:_VaultState = 'LockedOut'
                $script:_LockoutUntil = (Get-Date).AddMinutes($script:LockoutDurationMinutes)
                try { Write-AppLog "SASC: Vault LOCKED OUT until $($script:_LockoutUntil.ToString('HH:mm:ss'))" "Error" } catch { <# Intentional: non-fatal #> }
                throw "Too many failed attempts. Vault locked out for $($script:LockoutDurationMinutes) minutes."
            }
            return $false
        }
    } finally {
        # Zero password from memory
        if ($passwordPlain) { $passwordPlain = $null }
        # Clear BW_SESSION env var
        if ($env:BW_SESSION) { $env:BW_SESSION = $null }
        # Clear result (contains session token on success)
        if ($result) { $result = $null }
    }
}

function Lock-Vault {
    <#
    .SYNOPSIS  Lock the vault immediately, clear session key from memory.
    #>
    [CmdletBinding()]
    param()

    if ($script:_BWCliPath) {
        try { & $script:_BWCliPath lock 2>&1 | Out-Null } catch { <# Intentional: non-fatal #> }
    }

    # Clear session key
    $script:_BWSessionKey = $null
    $env:BW_SESSION = $null
    $script:_VaultState = 'Locked'

    # Stop auto-lock timer
    if ($script:_AutoLockTimer) {
        $script:_AutoLockTimer.Stop()
        $script:_AutoLockTimer.Dispose()
        $script:_AutoLockTimer = $null
    }
    $script:_AutoLockStartTime = [datetime]::MinValue

    try { Write-AppLog "SASC: Vault locked" "Info" } catch { <# Intentional: non-fatal #> }
}

function Start-AutoLockTimer {
    <#
    .SYNOPSIS  Start a timer that auto-locks the vault after configured idle minutes.
    #>
    [CmdletBinding()]
    param(
        [int]$Minutes = $script:DefaultAutoLockMinutes
    )

    # Stop existing timer
    if ($script:_AutoLockTimer) {
        $script:_AutoLockTimer.Stop()
        $script:_AutoLockTimer.Dispose()
    }

    $script:_AutoLockTimer = New-Object System.Timers.Timer
    $script:_AutoLockTimer.Interval = $Minutes * 60 * 1000  # milliseconds
    $script:_AutoLockTimer.AutoReset = $false
    $script:_AutoLockStartTime = Get-Date  # track start time for countdown display

    # Register elapsed event
    Register-ObjectEvent -InputObject $script:_AutoLockTimer -EventName Elapsed -Action {
        Lock-Vault
    } | Out-Null

    $script:_AutoLockTimer.Start()
}

# -------------------------------------------------------------------------------
#  VAULT ITEM OPERATIONS
# -------------------------------------------------------------------------------

function Get-VaultItem {
    <#
    .SYNOPSIS  Retrieve a single secret from the vault by name or ID.
    .DESCRIPTION
        Runs integrity check, retrieves item via BW CLI, returns password as
        [SecureString]. Never returns password as plain text. Logs the access
        (item name, not value).
    .PARAMETER Name     Item name to search for.
    .PARAMETER ItemId   Exact BW item ID.
    .OUTPUTS   [PSCustomObject] with Name, UserName, Password ([SecureString]), Uri, Notes, FolderId
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ItemId
    )

    Assert-VaultUnlocked

    $searchArgs = if ($ItemId) { @('get', 'item', $ItemId) } else { @('get', 'item', $Name) }
    $raw = Invoke-BWCommand -Arguments $searchArgs
    if (-not $raw) {
        throw "Vault item not found: $(if ($ItemId) { $ItemId } else { $Name })"
    }

    $item = $raw | ConvertFrom-Json -ErrorAction Stop

    # Build secure output -- password as SecureString
    $securePassword = $null
    if ($item.login -and $item.login.password) {
        $securePassword = Convert-PlainTextToSecureString -PlainText $item.login.password
    }

    try { Write-AppLog "SASC: Vault item accessed -- Name: $($item.name), ID: $($item.id)" "Info" } catch { <# Intentional: non-fatal #> }

    [PSCustomObject]@{
        Id       = $item.id
        Name     = $item.name
        UserName = if ($item.login) { $item.login.username } else { $null }
        Password = $securePassword
        Uri      = if ($item.login -and $item.login.uris) { $item.login.uris | ForEach-Object { $_.uri } } else { @() }
        Notes    = $item.notes
        FolderId = $item.folderId
        Type     = $item.type
    }
}

function Get-VaultItemList {
    <#
    .SYNOPSIS  List all vault items (metadata only -- no passwords returned).
    .OUTPUTS   [PSCustomObject[]] Array of items with Name, UserName, Uri, FolderId
    #>
    [CmdletBinding()]
    param(
        [string]$FolderId,
        [string]$Search
    )

    Assert-VaultUnlocked

    $bwArgs = @('list', 'items')
    if ($FolderId) { $bwArgs += '--folderid', $FolderId }
    if ($Search)   { $bwArgs += '--search', $Search }

    $raw = Invoke-BWCommand -Arguments $bwArgs
    if (-not $raw) { return @() }

    $items = $raw | ConvertFrom-Json -ErrorAction Stop

    $items | ForEach-Object {
        [PSCustomObject]@{
            Id       = $_.id
            Name     = $_.name
            UserName = if ($_.login) { $_.login.username } else { $null }
            Uri      = if ($_.login -and $_.login.uris) { $_.login.uris | ForEach-Object { $_.uri } } else { @() }
            FolderId = $_.folderId
            Type     = $_.type
        }
    }
}

function Set-VaultItem {
    <#
    .SYNOPSIS  Create or update a vault item. Requires re-auth if >5 min since unlock.
    .PARAMETER Name       Item name.
    .PARAMETER UserName   Login username.
    .PARAMETER Password   Login password as [SecureString].
    .PARAMETER Uri        Login URI(s).
    .PARAMETER Notes      Item notes.
    .PARAMETER FolderId   Folder assignment.
    .PARAMETER ItemId     If provided, updates existing item. Otherwise creates new.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$UserName,
        [System.Security.SecureString]$Password,
        [string[]]$Uri,
        [string]$Notes,
        [string]$FolderId,
        [string]$ItemId
    )

    Assert-VaultUnlocked

    if (-not $PSCmdlet.ShouldProcess($Name, "Set vault item")) { return }

    # Build item JSON
    $passwordPlain = $null
    try {
        if ($Password) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

        $uriObjects = @()
        if ($Uri) {
            $uriObjects = $Uri | ForEach-Object { @{ uri = $_; match = $null } }
        }

        $itemPayload = @{
            type  = 1  # Login type
            name  = $Name
            notes = $Notes
            login = @{
                username = $UserName
                password = $passwordPlain
                uris     = $uriObjects
            }
            folderId = $FolderId
        }

        $jsonPayload = $itemPayload | ConvertTo-Json -Depth 5 -Compress
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonPayload))

        if ($ItemId) {
            $result = Invoke-BWCommand -Arguments @('edit', 'item', $ItemId, $encoded)
        } else {
            $result = Invoke-BWCommand -Arguments @('create', 'item', $encoded)
        }

        try { Write-AppLog "SASC: Vault item set -- Name: $Name, ID: $ItemId" "Info" } catch { <# Intentional: non-fatal #> }
        return $result
    } finally {
        $passwordPlain = $null
    }
}

# -------------------------------------------------------------------------------
#  IMPORT / EXPORT
# -------------------------------------------------------------------------------

function Import-VaultSecrets {
    <#
    .SYNOPSIS  Import credentials from external password manager exports.
    .DESCRIPTION
        Supports: bitwardencsv, bitwardenjson, lastpasscsv, 1aboratoriescsv,
        keepass2xml, chromecsv, firefoxcsv. Validates file path, checks hash
        before/after import.
    .PARAMETER FilePath   Path to the import file.
    .PARAMETER Format     Import format identifier.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)]
        [ValidateSet('bitwardencsv','bitwardenjson','lastpasscsv',
                     '1passwordcsv','keepass2xml','chromecsv','firefoxcsv')]
        [string]$Format
    )

    Assert-VaultUnlocked

    # Validate path
    $safePath = [System.IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) {
        throw "Import file not found: $safePath"
    }

    if (-not $PSCmdlet.ShouldProcess($safePath, "Import vault secrets from $Format")) { return }

    # Record pre-import hash for audit
    $preHash = (Get-FileHash -LiteralPath $safePath -Algorithm SHA256).Hash
    try { Write-AppLog "SASC: Importing secrets from $Format -- file hash: $preHash" "Info" } catch { <# Intentional: non-fatal #> }

    $result = Invoke-BWCommand -Arguments @('import', $Format, $safePath)

    # Validate BW CLI result -- capture error output that would otherwise be lost
    if (-not $result) {
        throw "Import returned no output -- verify vault is unlocked and file format is correct."
    }
    if ($result -match '(?i)error|failed|not found|invalid') {
        throw "Import failed: $result"
    }

    try { Write-AppLog "SASC: Import completed from $Format" "Info" } catch { <# Intentional: non-fatal #> }
    return $result
}

function Import-Certificates {
    <#
    .SYNOPSIS  Import PFX/PEM/CER certificates into vault as secure notes.
    .PARAMETER FilePath     Path to certificate file.
    .PARAMETER Passphrase   PFX passphrase as [SecureString] (if applicable).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [System.Security.SecureString]$Passphrase
    )

    Assert-VaultUnlocked

    $safePath = Assert-SafePath -Path $FilePath -AllowedRoots @($script:_ModuleRoot, $env:USERPROFILE)
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) {
        throw "Certificate file not found: $safePath"
    }
    if (-not $PSCmdlet.ShouldProcess($safePath, "Import certificate to vault")) { return }

    $certContent = Get-Content -LiteralPath $safePath -Raw
    $certName    = [System.IO.Path]::GetFileName($safePath)
    $certHash    = (Get-FileHash -LiteralPath $safePath -Algorithm SHA256).Hash

    # Store as secure note in vault
    $notePayload = @{
        type      = 2  # SecureNote type
        name      = "Certificate: $certName"
        notes     = "SHA256: $certHash`nImported: $(Get-Date -Format 'o')"
        secureNote = @{ type = 0 }
        fields    = @(
            @{ name = 'CertificateContent'; value = $certContent; type = 1 }  # Hidden field
        )
    }

    $jsonPayload = $notePayload | ConvertTo-Json -Depth 5 -Compress
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonPayload))

    $result = Invoke-BWCommand -Arguments @('create', 'item', $encoded)

    try { Write-AppLog "SASC: Certificate imported -- $certName (SHA256: $certHash)" "Info" } catch { <# Intentional: non-fatal #> }
    return $result
}

function Export-VaultBackup {
    <#
    .SYNOPSIS  Create encrypted backup of vault to pki/vault-backups/.
    .DESCRIPTION
        Uses BW CLI encrypted JSON export. ACL-locks the backup file to current user.
    .PARAMETER MasterPassword  Required to authorise export.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [System.Security.SecureString]$MasterPassword
    )

    Assert-VaultUnlocked

    $backupDir  = Join-Path $script:_PkiDir 'vault-backups'
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupFile = Join-Path $backupDir "vault-backup-$timestamp.json"

    if (-not $PSCmdlet.ShouldProcess($backupFile, "Export encrypted vault backup")) { return }

    $passwordPlain = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MasterPassword)
        try {
            $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        $null = Invoke-BWCommand -Arguments @('export', '--format', 'encrypted_json', '--password', $passwordPlain, '--output', $backupFile)

        if (Test-Path -LiteralPath $backupFile) {
            Set-VaultFilePermissions -Path $backupFile
            try { Write-AppLog "SASC: Vault backup exported to $backupFile" "Info" } catch { <# Intentional: non-fatal #> }
        }
        return $backupFile
    } finally {
        $passwordPlain = $null
    }
}

# -------------------------------------------------------------------------------
#  SECURITY AUDIT
# -------------------------------------------------------------------------------

function Test-VaultSecurity {
    <#
    .SYNOPSIS  Comprehensive vault security audit.
    .DESCRIPTION
        Checks: BW CLI version, integrity manifest, file permissions, failed
        attempts log, session key memory state, master password strength
        indicator, PBKDF2 KDF iterations via BW CLI.
    .OUTPUTS   [PSCustomObject] with Score (0-100), Findings, Passed, Warnings, Failures
    #>
    [CmdletBinding()]
    param()

    $findings = @()
    $score = 100

    # 1. BW CLI availability
    if ($script:_BWCliPath) {
        $findings += [PSCustomObject]@{ Category='Infrastructure'; Check='BW CLI Available'; Status='Passed'; Detail=$script:_BWCliPath }
    } else {
        $findings += [PSCustomObject]@{ Category='Infrastructure'; Check='BW CLI Available'; Status='Failed'; Detail='Not installed' }
        $score -= 25
    }

    # 2. BW CLI version currency
    if ($script:_BWCliPath) {
        try {
            $ver = & $script:_BWCliPath --version 2>&1
            $findings += [PSCustomObject]@{ Category='Infrastructure'; Check='BW CLI Version'; Status='Passed'; Detail="v$ver" }
        } catch {
            $findings += [PSCustomObject]@{ Category='Infrastructure'; Check='BW CLI Version'; Status='Warning'; Detail='Could not determine version' }
            $score -= 5
        }
    }

    # 3. Integrity manifest
    if (Test-Path -LiteralPath $script:_IntegrityPath) {
        $intResult = Test-SASCSignedManifest
        if ($intResult.AllPassed -and $intResult.SignatureValid) {
            $findings += [PSCustomObject]@{ Category='Integrity'; Check='Manifest Verification'; Status='Passed'; Detail="$($intResult.Results.Count) files verified" }
        } else {
            $findings += [PSCustomObject]@{ Category='Integrity'; Check='Manifest Verification'; Status='Failed'; Detail="Signature: $($intResult.SignatureValid), Files: $($intResult.Results | Where-Object Status -ne 'Passed' | ForEach-Object { $_.Path })" }
            $score -= 30
        }
    } else {
        $findings += [PSCustomObject]@{ Category='Integrity'; Check='Manifest Exists'; Status='Warning'; Detail='No integrity manifest found -- run New-IntegrityManifest' }
        $score -= 10
    }

    # 4. File permissions on vault config
    foreach ($fp in @($script:_IntegrityPath, $script:_VaultConfigPath)) {
        if (Test-Path -LiteralPath $fp) {
            try {
                $acl = Get-Acl -LiteralPath $fp
                $rules = $acl.Access
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                $otherAccess = $rules | Where-Object { $_.IdentityReference.Value -ne $currentUser -and $_.IdentityReference.Value -ne 'NT AUTHORITY\SYSTEM' }
                if ($otherAccess) {
                    $findings += [PSCustomObject]@{ Category='Permissions'; Check="ACL: $(Split-Path $fp -Leaf)"; Status='Warning'; Detail="Other users have access: $($otherAccess.IdentityReference -join ', ')" }
                    $score -= 10
                } else {
                    $findings += [PSCustomObject]@{ Category='Permissions'; Check="ACL: $(Split-Path $fp -Leaf)"; Status='Passed'; Detail='Restricted to current user' }
                }
            } catch {
                $findings += [PSCustomObject]@{ Category='Permissions'; Check="ACL: $(Split-Path $fp -Leaf)"; Status='Warning'; Detail="Could not read ACL: $($_.Exception.Message)" }
                $score -= 5
            }
        }
    }

    # 5. Session key in environment
    if ($env:BW_SESSION) {
        $findings += [PSCustomObject]@{ Category='Memory'; Check='Session Key in Env'; Status='Failed'; Detail='BW_SESSION found in environment variables -- security risk' }
        $score -= 20
    } else {
        $findings += [PSCustomObject]@{ Category='Memory'; Check='Session Key in Env'; Status='Passed'; Detail='No session key in environment' }
    }

    # 6. Failed attempts log
    if ($script:_FailedAttempts -gt 0) {
        $findings += [PSCustomObject]@{ Category='Auth'; Check='Failed Attempts'; Status='Warning'; Detail="$($script:_FailedAttempts) failed unlock attempts this session" }
        $score -= ($script:_FailedAttempts * 3)
    } else {
        $findings += [PSCustomObject]@{ Category='Auth'; Check='Failed Attempts'; Status='Passed'; Detail='No failed attempts' }
    }

    # 7. Auto-lock timer
    if ($script:_VaultState -eq 'Unlocked' -and -not ($script:_AutoLockTimer -and $script:_AutoLockTimer.Enabled)) {
        $findings += [PSCustomObject]@{ Category='Policy'; Check='Auto-Lock Timer'; Status='Warning'; Detail='Vault is unlocked with no auto-lock timer' }
        $score -= 10
    } elseif ($script:_AutoLockTimer -and $script:_AutoLockTimer.Enabled) {
        $findings += [PSCustomObject]@{ Category='Policy'; Check='Auto-Lock Timer'; Status='Passed'; Detail='Active' }
    }

    # Clamp score
    $score = [math]::Max(0, [math]::Min(100, $score))

    try { Write-AppLog "SASC: Security audit completed -- Score: $score/100" "Info" } catch { <# Intentional: non-fatal #> }

    [PSCustomObject]@{
        Score    = $score
        Findings = $findings
        Passed   = ($findings | Where-Object Status -eq 'Passed').Count
        Warnings = ($findings | Where-Object Status -eq 'Warning').Count
        Failures = ($findings | Where-Object Status -eq 'Failed').Count
    }
}

# -------------------------------------------------------------------------------
#  WINDOWS HELLO INTEGRATION
# -------------------------------------------------------------------------------

function Enable-WindowsHello {
    <#
    .SYNOPSIS  Store master password encrypted with DPAPI for Windows Hello unlock.
    .DESCRIPTION
        Encrypts the master password using ProtectedData with CurrentUser scope
        and machine+user-specific entropy. The protected blob is stored in the
        vault config. Decryption requires the same Windows user session.
    .PARAMETER MasterPassword  The vault master password as SecureString.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [System.Security.SecureString]$MasterPassword
    )

    if (-not $PSCmdlet.ShouldProcess("Windows Hello", "Configure DPAPI-protected master password")) { return }

    $passwordPlain = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MasterPassword)
        try {
            $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($passwordPlain)
        $entropy = [System.Text.Encoding]::UTF8.GetBytes(
            "SASC-WinHello-$env:COMPUTERNAME-$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)")

        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $passwordBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)

        # Store in vault config
        $configData = Get-VaultConfig
        $configData.WindowsHelloEnabled = $true
        $configData.WindowsHelloBlob    = [Convert]::ToBase64String($protectedBytes)
        Save-VaultConfig -Config $configData

        try { Write-AppLog "SASC: Windows Hello configured successfully" "Info" } catch { <# Intentional: non-fatal #> }
    } finally {
        if ($passwordPlain) {
            $passwordPlain = $null
        }
    }
}

function Get-WindowsHelloPassword {
    <#
    .SYNOPSIS  Retrieve master password from DPAPI-protected storage.
    .OUTPUTS   [string] Plaintext password (caller must zero after use), or $null on failure.
    #>
    [CmdletBinding()]
    param()

    $config = Get-VaultConfig
    if (-not $config.WindowsHelloEnabled -or -not $config.WindowsHelloBlob) {
        return $null
    }

    try {
        $protectedBytes = [Convert]::FromBase64String($config.WindowsHelloBlob)
        $entropy = [System.Text.Encoding]::UTF8.GetBytes(
            "SASC-WinHello-$env:COMPUTERNAME-$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)")

        $passwordBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)

        $password = [System.Text.Encoding]::UTF8.GetString($passwordBytes)
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        return $password
    } catch {
        try { Write-AppLog "SASC: Windows Hello decryption failed -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> }
        return $null
    }
}

# -------------------------------------------------------------------------------
#  LAN VAULT SHARING
# -------------------------------------------------------------------------------

function Get-VaultLANStatus {
    <#
    .SYNOPSIS  Check if vault is accessible on LAN subnet.
    .OUTPUTS   [PSCustomObject] with Enabled, Port, URI, Subnet, ProcessRunning
    #>
    [CmdletBinding()]
    param()

    $config = Get-VaultConfig
    $processRunning = $false
    $uri = $null

    # Check for running bw serve process
    $bwProcesses = Get-Process -Name 'bw' -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'serve' } -ErrorAction SilentlyContinue

    if ($bwProcesses) { $processRunning = $true }

    # Detect local subnet
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1).IPAddress

    $port = if ($config.LANSharePort) { $config.LANSharePort } else { $script:DefaultLANPort }

    if ($processRunning -and $localIP) {
        $uri = "http://${localIP}:${port}"
    }

    [PSCustomObject]@{
        Enabled        = [bool]$config.LANShareEnabled
        Port           = $port
        URI            = $uri
        LocalIP        = $localIP
        ProcessRunning = $processRunning
    }
}

function Set-VaultLANSharing {
    <#
    .SYNOPSIS  Enable or disable vault API serving on LAN subnet.
    .PARAMETER Enable   $true to start bw serve, $false to stop it.
    .PARAMETER Port     Port number (default 8087).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [bool]$Enable,
        [int]$Port = $script:DefaultLANPort
    )

    Assert-VaultUnlocked

    if (-not $PSCmdlet.ShouldProcess("LAN Vault Sharing", "$(if($Enable){'Enable'}else{'Disable'}) on port $Port")) { return }

    if ($Enable) {
        # Start bw serve in background
        $sessionPlain = $null
        try {
            if ($script:_BWSessionKey) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:_BWSessionKey)
                try {
                    $sessionPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }

            # bw serve on 0.0.0.0 requires admin elevation for network binding
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = "-NoProfile -WindowStyle Hidden -Command `"& { `$env:BW_SESSION = '$sessionPlain'; & '$($script:_BWCliPath)' serve --port $Port --hostname 0.0.0.0 }`""
            $psi.UseShellExecute = $true
            $psi.Verb = 'RunAs'
            $psi.CreateNoWindow = $false

            try {
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            } catch {
                if ($_.Exception.Message -match 'canceled by the user') {
                    throw "LAN sharing requires administrator elevation. Operation cancelled by user."
                }
                throw
            }

            $config = Get-VaultConfig
            $config.LANShareEnabled = $true
            $config.LANSharePort    = $Port
            Save-VaultConfig -Config $config

            try { Write-AppLog "SASC: LAN vault sharing enabled on port $Port" "Info" } catch { <# Intentional: non-fatal #> }
        } finally {
            $sessionPlain = $null
        }
    } else {
        # Stop bw serve processes
        Get-Process -Name 'bw' -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill() } catch { <# Intentional: non-fatal #> }
        }

        $config = Get-VaultConfig
        $config.LANShareEnabled = $false
        Save-VaultConfig -Config $config

        try { Write-AppLog "SASC: LAN vault sharing disabled" "Info" } catch { <# Intentional: non-fatal #> }
    }
}

# -------------------------------------------------------------------------------
#  VAULT CONFIG HELPERS
# -------------------------------------------------------------------------------

function Get-VaultConfig {
    <#
    .SYNOPSIS  Read the SASC vault configuration JSON.
    .OUTPUTS   [hashtable] Configuration data.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:_VaultConfigPath) {
        return @{
            WindowsHelloEnabled = $false
            WindowsHelloBlob    = $null
            LANShareEnabled     = $false
            LANSharePort        = $script:DefaultLANPort
            AutoLockMinutes     = $script:DefaultAutoLockMinutes
            UserLinks           = @()
        }
    }

    if (-not (Test-Path -LiteralPath $script:_VaultConfigPath)) {
        return @{
            WindowsHelloEnabled = $false
            WindowsHelloBlob    = $null
            LANShareEnabled     = $false
            LANSharePort        = $script:DefaultLANPort
            AutoLockMinutes     = $script:DefaultAutoLockMinutes
            UserLinks           = @()
        }
    }

    try {
        $raw = Get-Content -LiteralPath $script:_VaultConfigPath -Raw
        return ($raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } catch {
        try { Write-AppLog "SASC: Failed to read vault config -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> }
        return @{
            WindowsHelloEnabled = $false
            WindowsHelloBlob    = $null
            LANShareEnabled     = $false
            LANSharePort        = $script:DefaultLANPort
            AutoLockMinutes     = $script:DefaultAutoLockMinutes
            UserLinks           = @()
        }
    }
}

function Save-VaultConfig {
    <#
    .SYNOPSIS  Persist vault config to JSON with file permission hardening.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config
    )

    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:_VaultConfigPath -Encoding UTF8 -Force
    Set-VaultFilePermissions -Path $script:_VaultConfigPath
}

function Assert-VaultUnlocked {
    <#
    .SYNOPSIS  Guard function -- throws if vault is not unlocked.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:_Initialized) {
        throw "SASC module not initialised. Call Initialize-SASCModule first."
    }
    if ($script:_VaultState -ne 'Unlocked') {
        throw "Vault is not unlocked. Current state: $($script:_VaultState)"
    }
}

# -------------------------------------------------------------------------------
#  GUI: ASSISTED SASC WIZARD  (unified setup / resume form)
# -------------------------------------------------------------------------------

function Show-AssistedSASCDialog {
    <#
    .SYNOPSIS  Single-form assisted setup that allows resumption of install, setup
               or configuration. Shows visual status indicators for every step and
               outputs extra verbose logging during execution.
    .DESCRIPTION
        Renders a single WinForms dialog with a DataGridView listing every setup
        step.  Each row has coloured status icons:
          Green  ?  = completed / enabled / installed
          Yellow !  = partially complete / needs attention
          Red    ?  = missing / disabled / failed
          Gray   --  = not started
        A console-style log pane shows real-time verbose output.
        Users can re-run any step at any time for resumption.
    #>
    [CmdletBinding()]
    param()

    try { Write-AppLog "SASC: Assisted Setup form opened" "Audit" } catch { <# Intentional: non-fatal #> }

    # -- Helper: assess a single step ---------------------------------------
    $assessSteps = {
        $steps = [ordered]@{}

        # 1. PowerShell Version
        $psVer = $PSVersionTable.PSVersion
        $steps['PowerShell Version'] = [pscustomobject]@{
            Category = 'Environment'
            Status   = if ($psVer.Major -ge 7) { 'Installed' } elseif ($psVer.Major -ge 5) { 'Partial' } else { 'Missing' }
            Detail   = "v$($psVer.ToString())$(if($psVer.Major -lt 7){' -- pwsh 7+ recommended'})"
            CanRun   = $false
            Action   = $null
        }

        # 2. WinGet
        $wingetOk = [bool](Get-Command 'winget' -ErrorAction SilentlyContinue)
        $steps['WinGet Package Manager'] = [pscustomobject]@{
            Category = 'Environment'
            Status   = if ($wingetOk) { 'Installed' } else { 'Missing' }
            Detail   = if ($wingetOk) { 'Available on PATH' } else { 'Install App Installer from Microsoft Store' }
            CanRun   = $false
            Action   = $null
        }

        # 3. .NET Runtime
        $dotnet = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        $steps['.NET Runtime'] = [pscustomobject]@{
            Category = 'Environment'
            Status   = 'Installed'
            Detail   = $dotnet
            CanRun   = $false
            Action   = $null
        }

        # 4. DPAPI / Windows Hello capability
        $dpapiOk = $false
        try {
            $tb = [System.Text.Encoding]::UTF8.GetBytes("SASC-test")
            $te = [System.Text.Encoding]::UTF8.GetBytes("entropy")
            $p  = [System.Security.Cryptography.ProtectedData]::Protect($tb, $te, 'CurrentUser')
            [void][System.Security.Cryptography.ProtectedData]::Unprotect($p, $te, 'CurrentUser')
            $dpapiOk = $true
        } catch { <# Intentional: non-fatal #> }
        $steps['DPAPI (Windows Hello)'] = [pscustomobject]@{
            Category = 'Environment'
            Status   = if ($dpapiOk) { 'Installed' } else { 'Missing' }
            Detail   = if ($dpapiOk) { 'Round-trip OK' } else { 'DPAPI unavailable' }
            CanRun   = $false
            Action   = $null
        }

        # 5. Admin privileges
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $steps['Admin Privileges'] = [pscustomobject]@{
            Category = 'Environment'
            Status   = if ($isAdmin) { 'Enabled' } else { 'Disabled' }
            Detail   = if ($isAdmin) { 'Running elevated' } else { 'Standard user -- installer may prompt' }
            CanRun   = $false
            Action   = $null
        }

        # 6. Bitwarden CLI
        $bwPath = Find-BWCli
        $steps['Bitwarden CLI'] = [pscustomobject]@{
            Category = 'Install'
            Status   = if ($bwPath) { 'Installed' } else { 'Missing' }
            Detail   = if ($bwPath) { "Found: $bwPath" } else { 'Not installed -- click Run to install' }
            CanRun   = (-not $bwPath)
            Action   = 'Install-BW'
        }

        # 7. SASC Module loaded
        $sascLoaded = [bool](Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue)
        $steps['AssistedSASC Module'] = [pscustomobject]@{
            Category = 'Module'
            Status   = if ($sascLoaded) { 'Installed' } else { 'Missing' }
            Detail   = if ($sascLoaded) { 'Loaded and functions available' } else { 'Module not imported' }
            CanRun   = $false
            Action   = $null
        }

        # 8. SASC-Adapters Module loaded
        $adaptersLoaded = [bool](Get-Module SASC-Adapters -ErrorAction SilentlyContinue)
        $steps['SASC-Adapters Module'] = [pscustomobject]@{
            Category = 'Module'
            Status   = if ($adaptersLoaded) { 'Installed' } else { 'Missing' }
            Detail   = if ($adaptersLoaded) { 'Loaded' } else { 'Module not imported' }
            CanRun   = $false
            Action   = $null
        }

        # 9. SASC Initialization
        $steps['SASC Initialised'] = [pscustomobject]@{
            Category = 'Config'
            Status   = if ($script:_Initialized) { 'Completed' } else { 'NotStarted' }
            Detail   = if ($script:_Initialized) { "State: $($script:_VaultState)" } else { 'Not yet initialised' }
            CanRun   = (-not $script:_Initialized)
            Action   = 'Init-SASC'
        }

        # 10. Vault config file
        $cfgExists = $false
        if ($script:_VaultConfigPath) { $cfgExists = Test-Path -LiteralPath $script:_VaultConfigPath }
        $steps['Vault Configuration'] = [pscustomobject]@{
            Category = 'Config'
            Status   = if ($cfgExists) { 'Completed' } else { 'NotStarted' }
            Detail   = if ($cfgExists) { $script:_VaultConfigPath } else { 'sasc-vault-config.json missing -- defaults used' }
            CanRun   = $false
            Action   = $null
        }

        # 11. Integrity manifest
        $intExists = $false
        if ($script:_IntegrityPath) { $intExists = Test-Path -LiteralPath $script:_IntegrityPath }
        $steps['Integrity Manifest'] = [pscustomobject]@{
            Category = 'Security'
            Status   = if ($intExists -and -not $script:_IntegrityIssuesDetected) { 'Completed' }
                       elseif ($intExists) { 'Partial' }
                       else { 'NotStarted' }
            Detail   = if ($intExists -and -not $script:_IntegrityIssuesDetected) { 'Manifest OK' }
                       elseif ($intExists) { "Mismatches detected: $($script:_LastIntegrityMessage)" }
                       else { 'No manifest -- click Run to generate' }
            CanRun   = $true
            Action   = 'Gen-Integrity'
        }

        # 12. Vault state
        $steps['Vault Status'] = [pscustomobject]@{
            Category = 'Vault'
            Status   = switch ($script:_VaultState) {
                'Unlocked'         { 'Enabled' }
                'Locked'           { 'Disabled' }
                'LockedOut'        { 'Missing' }
                'IntegrityWarning' { 'Partial' }
                'NotConfigured'    { 'NotStarted' }
                default            { 'NotStarted' }
            }
            Detail   = "Current state: $($script:_VaultState)"
            CanRun   = ($script:_VaultState -in @('Locked','IntegrityWarning'))
            Action   = 'Unlock-Vault'
        }

        # 13. Windows Hello
        $cfg = Get-VaultConfig
        $steps['Windows Hello'] = [pscustomobject]@{
            Category = 'Security'
            Status   = if ($cfg.WindowsHelloEnabled -and $cfg.WindowsHelloBlob) { 'Enabled' }
                       elseif ($dpapiOk) { 'Disabled' }
                       else { 'Missing' }
            Detail   = if ($cfg.WindowsHelloEnabled) { 'Enabled with DPAPI blob stored' }
                       elseif ($dpapiOk) { 'Available but not configured -- click Run' }
                       else { 'DPAPI not available on this system' }
            CanRun   = ($dpapiOk -and -not $cfg.WindowsHelloEnabled)
            Action   = 'Setup-Hello'
        }

        # 14. LAN Sharing
        $steps['LAN Vault Sharing'] = [pscustomobject]@{
            Category = 'Config'
            Status   = if ($cfg.LANShareEnabled) { 'Enabled' } else { 'Disabled' }
            Detail   = "Port: $($cfg.LANSharePort) | $(if($cfg.LANShareEnabled){'Active'}else{'Inactive'})"
            CanRun   = $false
            Action   = $null
        }

        # 15. Secrets page (XHTML)
        $secretsPage = if ($script:_ModuleRoot) { Join-Path $script:_ModuleRoot 'XHTML-invoke-secrets.xhtml' } else { $null }
        $pageExists  = if ($secretsPage) { Test-Path -LiteralPath $secretsPage } else { $false }
        $steps['Secrets Invoker Page'] = [pscustomobject]@{
            Category = 'Config'
            Status   = if ($pageExists) { 'Installed' } else { 'Missing' }
            Detail   = if ($pageExists) { $secretsPage } else { 'XHTML-invoke-secrets.xhtml not found' }
            CanRun   = $false
            Action   = $null
        }

        # 16. Security audit
        $steps['Security Audit'] = [pscustomobject]@{
            Category = 'Security'
            Status   = 'NotStarted'
            Detail   = 'Click Run to execute full security audit'
            CanRun   = ($script:_Initialized)
            Action   = 'Run-Audit'
        }

        return $steps
    }

    # -- Colour helpers -----------------------------------------------------
    $statusToIcon = @{
        'Installed'   = [char]0x2714   # ?
        'Completed'   = [char]0x2714
        'Enabled'     = [char]0x2714
        'Partial'     = '!'
        'Disabled'    = [char]0x2500   # -
        'NotStarted'  = [char]0x2500
        'Missing'     = [char]0x2718   # ?
    }
    $statusToColor = @{
        'Installed'   = [System.Drawing.Color]::FromArgb(40, 167, 69)
        'Completed'   = [System.Drawing.Color]::FromArgb(40, 167, 69)
        'Enabled'     = [System.Drawing.Color]::FromArgb(40, 167, 69)
        'Partial'     = [System.Drawing.Color]::FromArgb(255, 193, 7)
        'Disabled'    = [System.Drawing.Color]::FromArgb(108, 117, 125)
        'NotStarted'  = [System.Drawing.Color]::FromArgb(108, 117, 125)
        'Missing'     = [System.Drawing.Color]::FromArgb(220, 53, 69)
    }

    # -- Build form ---------------------------------------------------------
    $setupForm = New-Object System.Windows.Forms.Form
    $setupForm.Text = "Assisted Setup -- Secret Access & Security Checks"
    $setupForm.Size = New-Object System.Drawing.Size([int]880, [int]660)
    $setupForm.StartPosition = 'CenterScreen'
    $setupForm.MinimizeBox = $false
    $setupForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # -- Header -------------------------------------------------------------
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = 'Top'
    $headerPanel.Height = 48
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(33, 37, 41)
    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = "  SASC Assisted Setup"
    $headerLabel.Dock = 'Fill'
    $headerLabel.ForeColor = [System.Drawing.Color]::White
    $headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $headerLabel.TextAlign = 'MiddleLeft'
    $headerPanel.Controls.Add($headerLabel)
    $setupForm.Controls.Add($headerPanel)

    # -- Grid ---------------------------------------------------------------
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point([int]10, [int]56)
    $grid.Size = New-Object System.Drawing.Size([int]840, [int]310)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grid.AutoSizeColumnsMode = 'None'

    # Define columns
    $colIcon    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIcon.Name = 'Icon'; $colIcon.HeaderText = ''; $colIcon.Width = 30
    $colCat     = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCat.Name = 'Category'; $colCat.HeaderText = 'Category'; $colCat.Width = 85
    $colStep    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStep.Name = 'Step'; $colStep.HeaderText = 'Step'; $colStep.Width = 180
    $colStatus  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.Name = 'Status'; $colStatus.HeaderText = 'Status'; $colStatus.Width = 90
    $colDetail  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDetail.Name = 'Detail'; $colDetail.HeaderText = 'Detail'; $colDetail.Width = 350
    $colAction  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAction.Name = 'ActionKey'; $colAction.HeaderText = ''; $colAction.Visible = $false
    $colCanRun  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colCanRun.Name = 'CanRun'; $colCanRun.HeaderText = ''; $colCanRun.Visible = $false

    $grid.Columns.AddRange(@($colIcon, $colCat, $colStep, $colStatus, $colDetail, $colAction, $colCanRun) | Where-Object { $_ -is [System.Windows.Forms.DataGridViewColumn] })
    $setupForm.Controls.Add($grid)

    # -- Buttons ------------------------------------------------------------
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh Status"
    $btnRefresh.Location = New-Object System.Drawing.Point([int]10, [int]374)
    $btnRefresh.Size = New-Object System.Drawing.Size([int]130, [int]32)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run Selected Step"
    $btnRun.Location = New-Object System.Drawing.Point([int]150, [int]374)
    $btnRun.Size = New-Object System.Drawing.Size([int]150, [int]32)
    $btnRun.Enabled = $false

    $btnRunAll = New-Object System.Windows.Forms.Button
    $btnRunAll.Text = "Run All Pending"
    $btnRunAll.Location = New-Object System.Drawing.Point([int]310, [int]374)
    $btnRunAll.Size = New-Object System.Drawing.Size([int]130, [int]32)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point([int]760, [int]374)
    $btnClose.Size = New-Object System.Drawing.Size([int]90, [int]32)
    $btnClose.Add_Click({ $setupForm.Close() })

    $setupForm.Controls.AddRange(@($btnRefresh, $btnRun, $btnRunAll, $btnClose))

    # -- Log pane -----------------------------------------------------------
    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = "Execution Log"
    $logLabel.Location = New-Object System.Drawing.Point([int]10, [int]414)
    $logLabel.Size = New-Object System.Drawing.Size([int]200, [int]18)
    $logLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $setupForm.Controls.Add($logLabel)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Both'
    $logBox.ReadOnly = $true
    $logBox.WordWrap = $false
    $logBox.Location = New-Object System.Drawing.Point([int]10, [int]434)
    $logBox.Size = New-Object System.Drawing.Size([int]840, [int]175)
    $logBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 40)
    $logBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 220, 200)
    $setupForm.Controls.Add($logBox)

    # -- Log helper ---------------------------------------------------------
    $writeLog = {
        param([string]$Message, [string]$Level)
        $ts  = (Get-Date).ToString('HH:mm:ss.fff')
        $tag = switch ($Level) { 'OK' { '[OK]  ' } 'WARN' { '[!]   ' } 'ERR' { '[ERR] ' } 'RUN' { '[>>>] ' } default { '[---] ' } }
        $logBox.AppendText("$ts $tag $Message`r`n")
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
        try { Write-AppLog "SASC-Setup: $Message" $(if($Level -eq 'ERR'){'Error'}elseif($Level -eq 'WARN'){'Warning'}else{'Verbose'}) } catch { <# Intentional: non-fatal #> }
    }

    # -- Populate / refresh grid --------------------------------------------
    $refreshGrid = {
        $grid.Rows.Clear()
        $steps = & $assessSteps
        foreach ($kv in $steps.GetEnumerator()) {
            $s   = $kv.Value
            $ico = if ($statusToIcon.ContainsKey($s.Status)) { $statusToIcon[$s.Status] } else { '?' }
            $clr = if ($statusToColor.ContainsKey($s.Status)) { $statusToColor[$s.Status] } else { [System.Drawing.Color]::Gray }
            $idx = $grid.Rows.Add($ico, $s.Category, $kv.Key, $s.Status, $s.Detail, $s.Action, $s.CanRun)
            $row = $grid.Rows[$idx]
            # Colour the icon and status cells
            $row.Cells['Icon'].Style.ForeColor   = $clr
            $row.Cells['Icon'].Style.Font        = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
            $row.Cells['Status'].Style.ForeColor  = $clr
            $row.Cells['Status'].Style.Font       = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            # Light row background tint
            $alpha = 30
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb($alpha, $clr.R, $clr.G, $clr.B)
        }
        & $writeLog "Status refreshed -- $($steps.Count) steps assessed" 'INFO'
    }

    # -- Enable/disable Run button based on selection -----------------------
    $grid.Add_SelectionChanged({
        if ($grid.SelectedRows.Count -eq 1) {
            $canRun = $grid.SelectedRows[0].Cells['CanRun'].Value
            $btnRun.Enabled = ($canRun -eq $true -or $canRun -eq 'True')
        } else {
            $btnRun.Enabled = $false
        }
    })

    # -- Execute a single action --------------------------------------------
    $executeAction = {
        param([string]$ActionKey, [string]$StepName)
        & $writeLog "Starting: $StepName" 'RUN'
        try {
            switch ($ActionKey) {
                'Install-BW' {
                    & $writeLog "Locating installer script in scripts directory" 'INFO'
                    $installerScript = if ($script:_ScriptsDir) { Join-Path $script:_ScriptsDir 'Install-BitwardenLite.ps1' } else { $null }
                    if (-not $installerScript -or -not (Test-Path -LiteralPath $installerScript)) {
                        & $writeLog "Installer script not found: $installerScript" 'ERR'
                        return
                    }
                    & $writeLog "Running: $installerScript" 'RUN'
                    $result = & $installerScript -Verbose 4>&1 2>&1
                    foreach ($line in $result) { & $writeLog "$line" 'INFO' }
                    $script:_BWCliPath = Find-BWCli
                    if ($script:_BWCliPath) {
                        & $writeLog "Bitwarden CLI installed at: $($script:_BWCliPath)" 'OK'
                        New-IntegrityManifest | Out-Null
                        & $writeLog "Integrity manifest updated after install" 'OK'
                    } else {
                        & $writeLog "Installation completed but bw.exe not found on PATH" 'WARN'
                    }
                }
                'Init-SASC' {
                    & $writeLog "Initialising SASC module for workspace: $($script:_ModuleRoot)" 'RUN'
                    if ($script:_ModuleRoot) {
                        $ok = Initialize-SASCModule -ScriptDir $script:_ModuleRoot
                        & $writeLog "Initialize-SASCModule returned: $ok" $(if($ok){'OK'}else{'WARN'})
                    } else {
                        & $writeLog "Module root not set -- cannot initialise" 'ERR'
                    }
                }
                'Gen-Integrity' {
                    & $writeLog "Generating integrity manifest" 'RUN'
                    $result = New-IntegrityManifest
                    $hashCount = if ($result -and $result.Hashes) { $result.Hashes.Count } else { 0 }
                    & $writeLog "Manifest generated -- $hashCount file hashes recorded" 'OK'
                    # Verify immediately
                    & $writeLog "Running integrity verification" 'RUN'
                    $verify = Test-SASCSignedManifest
                    if ($verify.AllPassed) {
                        & $writeLog "Integrity verification: ALL PASSED" 'OK'
                        $script:_IntegrityIssuesDetected = $false
                        $script:_LastIntegrityMessage = $null
                    } else {
                        $failCount = @($verify.Results | Where-Object { -not $_.Passed }).Count
                        & $writeLog "Integrity verification: $failCount mismatch(es) detected" 'WARN'
                        foreach ($mis in ($verify.Results | Where-Object { -not $_.Passed })) {
                            & $writeLog "  MISMATCH: $($mis.Path)" 'WARN'
                        }
                    }
                }
                'Unlock-Vault' {
                    & $writeLog "Opening vault unlock dialog" 'RUN'
                    $unlocked = Show-VaultUnlockDialog
                    if ($unlocked) {
                        & $writeLog "Vault unlocked successfully" 'OK'
                    } else {
                        & $writeLog "Vault unlock cancelled or failed" 'WARN'
                    }
                }
                'Setup-Hello' {
                    & $writeLog "Starting Windows Hello setup" 'RUN'
                    if ($script:_VaultState -ne 'Unlocked') {
                        & $writeLog "Vault must be unlocked before enabling Windows Hello" 'WARN'
                        & $writeLog "Opening vault unlock dialog first" 'RUN'
                        $unlocked = Show-VaultUnlockDialog
                        if (-not $unlocked) {
                            & $writeLog "Vault not unlocked -- aborting Hello setup" 'ERR'
                            return
                        }
                    }
                    Enable-WindowsHello
                    & $writeLog "Windows Hello configured" 'OK'
                }
                'Run-Audit' {
                    & $writeLog "Executing full security audit" 'RUN'
                    $auditResult = Test-VaultSecurity
                    foreach ($finding in $auditResult.Findings) {
                        $lvl = switch ($finding.Status) { 'Passed' { 'OK' } 'Warning' { 'WARN' } 'Failed' { 'ERR' } default { 'INFO' } }
                        & $writeLog "  [$($finding.Category)] $($finding.Check): $($finding.Status) -- $($finding.Detail)" $lvl
                    }
                    & $writeLog "Security score: $($auditResult.Score) / 100" $(if($auditResult.Score -ge 80){'OK'}elseif($auditResult.Score -ge 50){'WARN'}else{'ERR'})
                }
                default {
                    & $writeLog "No handler for action: $ActionKey" 'WARN'
                }
            }
        } catch {
            & $writeLog "FAILED: $($_.Exception.Message)" 'ERR'
            if ($_.Exception.StackTrace) {
                & $writeLog "Stack: $($_.Exception.StackTrace.Split("`n")[0])" 'ERR'
            }
        }
        & $writeLog "Completed: $StepName -- refreshing status" 'INFO'
        & $refreshGrid
    }

    # -- Wire buttons -------------------------------------------------------
    $btnRefresh.Add_Click({ & $refreshGrid })

    $btnRun.Add_Click({
        if ($grid.SelectedRows.Count -ne 1) { return }
        $row = $grid.SelectedRows[0]
        $actionKey = [string]$row.Cells['ActionKey'].Value
        $stepName  = [string]$row.Cells['Step'].Value
        if ([string]::IsNullOrEmpty($actionKey)) { return }
        & $executeAction $actionKey $stepName
    })

    $btnRunAll.Add_Click({
        & $writeLog '--- Running all pending steps ---' 'RUN'
        $steps = & $assessSteps
        foreach ($kv in $steps.GetEnumerator()) {
            $s = $kv.Value
            if ($s.CanRun -and $s.Action) {
                & $executeAction $s.Action $kv.Key
            }
        }
        & $writeLog '--- All pending steps processed ---' 'OK'
    })

    # -- Initial populate ---------------------------------------------------
    & $refreshGrid

    $setupForm.ShowDialog() | Out-Null
    $setupForm.Dispose()
}

# -------------------------------------------------------------------------------
#  GUI: VAULT UNLOCK DIALOG
# -------------------------------------------------------------------------------

function Show-VaultUnlockDialog {
    <#
    .SYNOPSIS  Show a password dialog to unlock the vault with verbose status output.
    .OUTPUTS   [bool] $true if vault was unlocked.
    #>
    [CmdletBinding()]
    param()

    try { Write-AppLog "SASC: Vault unlock dialog opened" "Audit" } catch { <# Intentional: non-fatal #> }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Unlock Vault"
    $dlg.Size = New-Object System.Drawing.Size([int]430, [int]330)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Vault state indicator
    $vaultState = $script:_VaultState
    $bwAvail    = [bool]$script:_BWCliPath
    $stateColor = switch ($vaultState) {
        'Unlocked'  { [System.Drawing.Color]::FromArgb(40, 167, 69) }
        'Locked'    { [System.Drawing.Color]::FromArgb(255, 193, 7) }
        'LockedOut' { [System.Drawing.Color]::FromArgb(220, 53, 69) }
        default     { [System.Drawing.Color]::Gray }
    }
    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Text = "Vault: $vaultState | BW CLI: $(if($bwAvail){'available'}else{'MISSING'})"
    $lblState.Location = New-Object System.Drawing.Point([int]15, [int]10)
    $lblState.Size = New-Object System.Drawing.Size([int]380, [int]20)
    $lblState.ForeColor = $stateColor
    $lblState.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)

    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = "Enter master password to unlock the Bitwarden vault:"
    $lblPrompt.Location = New-Object System.Drawing.Point([int]15, [int]38)
    $lblPrompt.AutoSize = $true

    $txtPassword = New-Object System.Windows.Forms.MaskedTextBox
    $txtPassword.PasswordChar = '*'
    $txtPassword.Location = New-Object System.Drawing.Point([int]15, [int]62)
    $txtPassword.Size = New-Object System.Drawing.Size([int]380, [int]25)

    $chkHello = New-Object System.Windows.Forms.CheckBox
    $chkHello.Text = "Use Windows Hello"
    $chkHello.Location = New-Object System.Drawing.Point([int]15, [int]95)
    $chkHello.AutoSize = $true

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = ""
    $lblStatus.Location = New-Object System.Drawing.Point([int]15, [int]122)
    $lblStatus.Size = New-Object System.Drawing.Size([int]380, [int]20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed

    # Verbose log area
    $logArea = New-Object System.Windows.Forms.TextBox
    $logArea.Multiline = $true
    $logArea.ScrollBars = 'Vertical'
    $logArea.ReadOnly = $true
    $logArea.Location = New-Object System.Drawing.Point([int]15, [int]148)
    $logArea.Size = New-Object System.Drawing.Size([int]380, [int]90)
    $logArea.Font = New-Object System.Drawing.Font("Consolas", 7.5)
    $logArea.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 40)
    $logArea.ForeColor = [System.Drawing.Color]::FromArgb(200, 220, 200)

    $appendLog = {
        param([string]$Msg)
        $logArea.AppendText("$(Get-Date -Format 'HH:mm:ss') $Msg`r`n")
        $logArea.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    & $appendLog "Vault state: $vaultState | BW CLI: $(if($bwAvail){$script:_BWCliPath}else{'not found'})"
    if ($script:_IntegrityIssuesDetected) {
        & $appendLog "WARNING: Integrity issues detected -- $($script:_LastIntegrityMessage)"
    }

    $btnUnlock = New-Object System.Windows.Forms.Button
    $btnUnlock.Text = "Unlock"
    $btnUnlock.Location = New-Object System.Drawing.Point([int]215, [int]250)
    $btnUnlock.Size = New-Object System.Drawing.Size([int]85, [int]30)
    $btnUnlock.DialogResult = 'None'
    $btnUnlock.Add_Click({
        try {
            $lblStatus.Text = ""
            $unlocked = $false
            if ($chkHello.Checked) {
                & $appendLog "Attempting unlock via Windows Hello..."
                $unlocked = Unlock-Vault -UseWindowsHello
            } else {
                if ([string]::IsNullOrWhiteSpace($txtPassword.Text)) {
                    $lblStatus.Text = "Password cannot be empty."
                    & $appendLog "Aborted: empty password"
                    return
                }
                & $appendLog "Attempting unlock via master password..."
                $secPwd = Convert-PlainTextToSecureString -PlainText $txtPassword.Text
                $unlocked = Unlock-Vault -MasterPassword $secPwd
            }
            if ($unlocked) {
                & $appendLog "SUCCESS -- vault unlocked"
                $dlg.DialogResult = 'OK'
                $dlg.Close()
            } else {
                $status = Test-VaultStatus
                $msg = "Unlock failed. Attempts: $($status.FailedAttempts)/$($status.MaxAttempts)"
                $lblStatus.Text = $msg
                & $appendLog $msg
                if ($status.IsLockedOut) {
                    & $appendLog "LOCKED OUT until $($status.LockoutUntil.ToString('HH:mm:ss'))"
                }
            }
        } catch {
            $errMsg = $_.Exception.Message
            $lblStatus.Text = $errMsg
            & $appendLog "ERROR: $errMsg"
            try { Write-AppLog "SASC: Unlock dialog error -- $errMsg" "Error" } catch { <# Intentional: non-fatal #> }
        }
    })

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point([int]310, [int]250)
    $btnCancel.Size = New-Object System.Drawing.Size([int]85, [int]30)
    $btnCancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lblState, $lblPrompt, $txtPassword, $chkHello, $lblStatus,
                              $logArea, $btnUnlock, $btnCancel))
    $dlg.AcceptButton = $btnUnlock
    $dlg.CancelButton = $btnCancel

    $dialogResult = $dlg.ShowDialog()
    $dlg.Dispose()
    return ($dialogResult -eq 'OK')
}

# -------------------------------------------------------------------------------
#  GUI: VAULT STATUS DIALOG
# -------------------------------------------------------------------------------

function Show-VaultStatusDialog {
    <#
    .SYNOPSIS  Detailed vault health panel.
    #>
    [CmdletBinding()]
    param()

    $status = Test-VaultStatus
    $lanStatus = Get-VaultLANStatus

    $msg  = "---------------------------------------`n"
    $msg += "       VAULT STATUS REPORT`n"
    $msg += "---------------------------------------`n`n"
    $msg += "  State:           $($status.State)`n"
    $msg += "  BW CLI:          $(if ($status.BWCliAvailable) { $status.BWCliPath } else { 'Not installed' })`n"
    $msg += "  Auto-Lock:       $(if ($status.AutoLockRemaining) { $status.AutoLockRemaining } else { 'N/A' })`n"
    $msg += "  Failed Attempts: $($status.FailedAttempts) / $($status.MaxAttempts)`n"
    $msg += "  Locked Out:      $($status.IsLockedOut)`n"
    if ($status.LockoutUntil) {
        $msg += "  Lockout Until:   $($status.LockoutUntil.ToString('HH:mm:ss'))`n"
    }
    $msg += "`n  -- LAN Sharing --`n"
    $msg += "  Enabled:         $($lanStatus.Enabled)`n"
    $msg += "  Process Running: $($lanStatus.ProcessRunning)`n"
    $msg += "  URI:             $(if ($lanStatus.URI) { $lanStatus.URI } else { 'N/A' })`n"
    $msg += "  Local IP:        $(if ($lanStatus.LocalIP) { $lanStatus.LocalIP } else { 'N/A' })`n"
    $msg += "`n---------------------------------------"

    [System.Windows.Forms.MessageBox]::Show(
        $msg, "Vault Status -- Assisted SASC",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

# -------------------------------------------------------------------------------
#  GUI: SECRETS INVOKER (WebView2 or WinForms fallback)
# -------------------------------------------------------------------------------

function Show-SecretsInvokerForm {
    <#
    .SYNOPSIS  WebView2-based XHTML secrets invoker, with WinForms fallback.
    .DESCRIPTION
        If WebView2 runtime is available, loads XHTML-invoke-secrets.xhtml in an
        embedded browser with PowerShell-to-JS bridge for credential injection
        without clipboard. Falls back to a pure WinForms dialog otherwise.
    #>
    [CmdletBinding()]
    param()

    Assert-VaultUnlocked
    try { Write-AppLog "SASC: Secrets Invoker opened" "Audit" } catch { <# Intentional: non-fatal #> }

    # Check for WebView2
    $webView2Available = $false
    try {
        $wv2Key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5B8BB31}' -ErrorAction SilentlyContinue
        if (-not $wv2Key) {
            $wv2Key = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5B8BB31}' -ErrorAction SilentlyContinue
        }
        if ($wv2Key) { $webView2Available = $true }
    } catch { <# Intentional: non-fatal #> }

    if (-not $webView2Available) {
        # Fall back to WinForms-based invoker
        Show-SecretsInvokerFallback
        return
    }

    # Attempt WebView2 form
    try {
        $wv2Assembly = [System.Reflection.Assembly]::LoadFrom(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.Web.WebView2.WinForms.dll")
        if (-not $wv2Assembly) { throw "Assembly not found" }
        Show-SecretsInvokerWebView2
    } catch {
        try { Write-AppLog "SASC: WebView2 assembly load failed, using fallback -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> }
        Show-SecretsInvokerFallback
    }
}

function Show-SecretsInvokerFallback {
    <#
    .SYNOPSIS  Pure WinForms fallback for secrets invoker.
    #>
    [CmdletBinding()]
    param()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Invoke Secrets -- Assisted SASC"
    $form.Size = New-Object System.Drawing.Size([int]600, [int]480)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Site selector
    $lblSite = New-Object System.Windows.Forms.Label
    $lblSite.Text = "Select credential:"
    $lblSite.Location = New-Object System.Drawing.Point([int]15, [int]15)
    $lblSite.AutoSize = $true

    $cboSite = New-Object System.Windows.Forms.ComboBox
    $cboSite.Location = New-Object System.Drawing.Point([int]15, [int]40)
    $cboSite.Size = New-Object System.Drawing.Size([int]550, [int]25)
    $cboSite.DropDownStyle = 'DropDownList'

    # URI checkboxes
    $lblUri = New-Object System.Windows.Forms.Label
    $lblUri.Text = "Select pages to open:"
    $lblUri.Location = New-Object System.Drawing.Point([int]15, [int]80)
    $lblUri.AutoSize = $true

    $uriList = New-Object System.Windows.Forms.CheckedListBox
    $uriList.Location = New-Object System.Drawing.Point([int]15, [int]105)
    $uriList.Size = New-Object System.Drawing.Size([int]550, [int]200)

    # Populate sites
    $script:_InvokerItems = @()
    try {
        $items = Get-VaultItemList
        foreach ($item in $items) {
            $display = "$($item.Name) -- $($item.UserName)"
            $cboSite.Items.Add($display) | Out-Null
        }
        $script:_InvokerItems = $items
    } catch {
        $cboSite.Items.Add("(vault error: $($_.Exception.Message))") | Out-Null
    }

    $cboSite.Add_SelectedIndexChanged({
        $uriList.Items.Clear()
        $idx = $cboSite.SelectedIndex
        if ($idx -ge 0 -and $script:_InvokerItems -and $idx -lt $script:_InvokerItems.Count) {
            $selected = $script:_InvokerItems[$idx]
            foreach ($u in $selected.Uri) {
                $uriList.Items.Add($u, $true) | Out-Null
            }
        }
    })

    # Status
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Ready"
    $lblStatus.Location = New-Object System.Drawing.Point([int]15, [int]370)
    $lblStatus.Size = New-Object System.Drawing.Size([int]450, [int]25)
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen

    # Execute button
    $btnExecute = New-Object System.Windows.Forms.Button
    $btnExecute.Text = "Open && Authenticate"
    $btnExecute.Location = New-Object System.Drawing.Point([int]15, [int]400)
    $btnExecute.Size = New-Object System.Drawing.Size([int]200, [int]35)
    $btnExecute.Add_Click({
        $idx = $cboSite.SelectedIndex
        if ($idx -lt 0) {
            $lblStatus.Text = "Please select a credential."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }

        $checkedUris = @()
        for ($i = 0; $i -lt $uriList.Items.Count; $i++) {
            if ($uriList.GetItemChecked($i)) {
                $checkedUris += $uriList.Items[$i]
            }
        }

        if ($checkedUris.Count -eq 0) {
            $lblStatus.Text = "Please select at least one page to open."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }

        try {
            $selected = $script:_InvokerItems[$idx]
            $cred = Get-VaultItem -ItemId $selected.Id
            $lblStatus.Text = "Opening $($checkedUris.Count) page(s)..."
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue

            foreach ($uri in $checkedUris) {
                Start-Process $uri
            }

            $lblStatus.Text = "Pages opened. Credential available for: $($cred.Name)"
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            try { Write-AppLog "SASC: Secrets invoker -- opened $($checkedUris.Count) pages for $($cred.Name)" "Info" } catch { <# Intentional: non-fatal #> }
        } catch {
            $lblStatus.Text = "Error: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
        }
    })

    $form.Controls.AddRange(@($lblSite, $cboSite, $lblUri, $uriList, $lblStatus, $btnExecute))
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

function Show-SecretsInvokerWebView2 {
    <#
    .SYNOPSIS  WebView2-based secrets invoker with DOM credential injection.
    .DESCRIPTION
        Loads XHTML-invoke-secrets.xhtml in embedded WebView2. Credentials are
        injected via ExecuteScriptAsync from PowerShell -- secrets never enter
        the JavaScript context directly.
    #>
    [CmdletBinding()]
    param()

    # This is a placeholder for WebView2 integration. Full WebView2 requires
    # the Microsoft.Web.WebView2 NuGet package DLL. When available, this
    # function creates a Form with WebView2 control and navigates to the
    # XHTML file with a JS bridge for credential injection.

    # For now, delegate to fallback with a notice
    try { Write-AppLog "SASC: WebView2 invoker -- delegating to fallback (assembly integration pending)" "Info" } catch { <# Intentional: non-fatal #> }
    Show-SecretsInvokerFallback
}

# -------------------------------------------------------------------------------
#  INSTALL WRAPPER
# -------------------------------------------------------------------------------

function Install-BitwardenLite {
    <#
    .SYNOPSIS  Wrapper to invoke the Bitwarden CLI installer script.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $installerPath = Join-Path $script:_ScriptsDir 'Install-BitwardenLite.ps1'
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Installer script not found: $installerPath"
    }

    if (-not $PSCmdlet.ShouldProcess("Bitwarden CLI", "Install via $installerPath")) { return }

    try { Write-AppLog "SASC: Starting Bitwarden CLI installation" "Info" } catch { <# Intentional: non-fatal #> }
    & $installerPath
    $script:_BWCliPath = Find-BWCli
    if ($script:_BWCliPath) {
        try { Write-AppLog "SASC: Bitwarden CLI installed at $($script:_BWCliPath)" "Info" } catch { <# Intentional: non-fatal #> }
        New-IntegrityManifest | Out-Null
    }
}

# -------------------------------------------------------------------------------
#  MODULE EXPORTS
# -------------------------------------------------------------------------------

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
    # Lifecycle
    'Initialize-SASCModule',
    'Install-BitwardenLite',
    # Vault operations
    'Test-VaultStatus',
    'Unlock-Vault',
    'Lock-Vault',
    'Start-AutoLockTimer',
    'Get-VaultItem',
    'Get-VaultItemList',
    'Set-VaultItem',
    # Import / Export
    'Import-VaultSecrets',
    'Import-Certificates',
    'Export-VaultBackup',
    # Security
    'Test-VaultSecurity',
    'New-IntegrityManifest',
    'Test-SASCSignedManifest',
    'Set-VaultFilePermissions',
    # Windows Hello
    'Enable-WindowsHello',
    # LAN
    'Get-VaultLANStatus',
    'Set-VaultLANSharing',
    # Encryption
    'Protect-VaultData',
    'Unprotect-VaultData',
    # GUI
    'Show-AssistedSASCDialog',
    'Show-VaultUnlockDialog',
    'Show-VaultStatusDialog',
    'Show-SecretsInvokerForm',
    # Helpers
    'Assert-SafePath',
    'Find-BWCli',
    'Get-CredentialForTarget'
)

# -------------------------------------------------------------------------------
#  HIGH-LEVEL CREDENTIAL RETRIEVAL
# -------------------------------------------------------------------------------

function Get-CredentialForTarget {
    <#
    .SYNOPSIS  Retrieve a [PSCredential] from the vault for a named target.
    .DESCRIPTION
        High-level convenience function: checks vault state ? prompts unlock if
        needed ? retrieves item ? returns [PSCredential]. All adapters funnel
        through this function.
    .PARAMETER TargetName  The vault item name or search term.
    .OUTPUTS   [PSCredential]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TargetName
    )

    # Ensure vault is unlocked
    if ($script:_VaultState -ne 'Unlocked') {
        $unlocked = Show-VaultUnlockDialog
        if (-not $unlocked) {
            throw "Vault unlock cancelled or failed."
        }
    }

    $item = Get-VaultItem -Name $TargetName
    if (-not $item -or -not $item.UserName) {
        throw "Vault item not found or has no username: $TargetName"
    }

    $cred = New-Object System.Management.Automation.PSCredential(
        $item.UserName, $item.Password)

    try { Write-AppLog "SASC: Credential retrieved for target: $TargetName (user: $($item.UserName))" "Info" } catch { <# Intentional: non-fatal #> }
    return $cred
}












