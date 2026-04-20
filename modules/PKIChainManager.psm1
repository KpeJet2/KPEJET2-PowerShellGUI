# VersionTag: 2604.B2.V31.0
# FileRole: Module
<#
.SYNOPSIS  PKIChainManager - PKI certificate chain management.
.DESCRIPTION
    Manages a 3-tier PKI chain: Root CA > Subordinate CA > Code Signing cert.
    Uses .NET X509 certificate APIs with PowerShell 5.1 compatibility.
    Private keys can be stored in Bitwarden vault via AssistedSASC.
    All operations are logged to the sovereign kernel ledger.
# TODO: HelpMenu | Show-PKIHelp | Actions: Validate|Import|Export|Audit|Help | Spec: config/help-menu-registry.json

    Chain hierarchy:
    - Root CA:       Self-signed, 4096-bit RSA, 10yr, CA:TRUE
    - Subordinate CA: Signed by Root, 4096-bit RSA, 5yr, CA:TRUE pathLen:0
    - Code Sign:     Signed by SubCA, 2048-bit RSA, 2yr, Code Signing EKU
#>
#Requires -Version 5.1

$script:_PKIBasePath = $null
$script:_PKIInitialized = $false

function Initialize-PKIChainManager {
    <#
    .SYNOPSIS  Set up PKI paths and ensure folder structure.
    .PARAMETER BasePath  Root of the pki/ folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BasePath
    )
    $script:_PKIBasePath = $BasePath
    foreach ($sub in @('ca', 'subca', 'codesign', 'crl')) {
        $p = Join-Path $BasePath $sub
        if (-not (Test-Path $p)) { New-Item $p -ItemType Directory -Force | Out-Null }
    }
    $script:_PKIInitialized = $true
    Write-Verbose "[PKIChainManager] Initialized at $BasePath"
}

function New-RootCACertificate {
    <#
    .SYNOPSIS  Generate a self-signed Root CA certificate.
    .PARAMETER Subject         CN for the Root CA.
    .PARAMETER ValidityYears   Certificate lifetime (default 10).
    .PARAMETER KeyLength       RSA key size (default 4096).
    .PARAMETER PfxPassword     SecureString password for the PFX export.
    #>
    [CmdletBinding()]
    param(
        [string]$Subject = 'CN=PwShGUI Root CA, O=SovereignKernel, OU=PKI',
        [int]$ValidityYears = 10,
        [int]$KeyLength = 4096,
        [Parameter(Mandatory)]
        [System.Security.SecureString]$PfxPassword
    )
    if (-not $script:_PKIInitialized) { throw '[PKIChainManager] Not initialized.' }

    $certPath = Join-Path $script:_PKIBasePath 'ca'
    $notBefore = [datetime]::UtcNow
    $notAfter  = $notBefore.AddYears($ValidityYears)

    # Use New-SelfSignedCertificate (available in Windows 10+/Server 2016+)
    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -KeyAlgorithm RSA `
        -KeyLength $KeyLength `
        -HashAlgorithm SHA256 `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotBefore $notBefore `
        -NotAfter $notAfter `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -KeyUsageProperty All `
        -TextExtension @(
            '2.5.29.19={critical}{text}ca=TRUE'
            '2.5.29.14={text}'
        ) `
        -FriendlyName 'PwShGUI Root CA'

    # Export PFX (private key)
    $pfxPath = Join-Path $certPath 'RootCA.pfx'
    $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPassword)
    [System.IO.File]::WriteAllBytes($pfxPath, $bytes)

    # Export public cert
    $cerPath = Join-Path $certPath 'RootCA.cer'
    $pubBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($cerPath, $pubBytes)

    # Log to ledger
    if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
        Write-LedgerEntry -EventType 'AUDIT' -Source 'PKIChainManager' -Data @{
            action      = 'RootCA-Created'
            subject     = $Subject
            thumbprint  = $cert.Thumbprint
            notAfter    = $notAfter.ToString('o')
            keyLength   = $KeyLength
        }
    }

    Write-Verbose "[PKI] Root CA created: $($cert.Thumbprint)"
    [PSCustomObject]@{
        Type        = 'RootCA'
        Subject     = $Subject
        Thumbprint  = $cert.Thumbprint
        NotAfter    = $notAfter
        PfxPath     = $pfxPath
        CerPath     = $cerPath
        Certificate = $cert
    }
}

function New-SubordinateCACertificate {
    <#
    .SYNOPSIS  Generate a Subordinate CA certificate signed by the Root CA.
    .PARAMETER Subject         CN for the SubCA.
    .PARAMETER SignerThumbprint Thumbprint of the Root CA cert (must be in CurrentUser\My).
    .PARAMETER ValidityYears   Certificate lifetime (default 5).
    .PARAMETER KeyLength       RSA key size (default 4096).
    .PARAMETER PfxPassword     SecureString password for the PFX export.
    #>
    [CmdletBinding()]
    param(
        [string]$Subject = 'CN=PwShGUI Subordinate CA, O=SovereignKernel, OU=PKI',
        [Parameter(Mandatory)]
        [string]$SignerThumbprint,
        [int]$ValidityYears = 5,
        [int]$KeyLength = 4096,
        [Parameter(Mandatory)]
        [System.Security.SecureString]$PfxPassword
    )
    if (-not $script:_PKIInitialized) { throw '[PKIChainManager] Not initialized.' }

    $signer = Get-ChildItem Cert:\CurrentUser\My\$SignerThumbprint -ErrorAction Stop
    $certPath = Join-Path $script:_PKIBasePath 'subca'
    $notBefore = [datetime]::UtcNow
    $notAfter  = $notBefore.AddYears($ValidityYears)

    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Signer $signer `
        -KeyAlgorithm RSA `
        -KeyLength $KeyLength `
        -HashAlgorithm SHA256 `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotBefore $notBefore `
        -NotAfter $notAfter `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -KeyUsageProperty All `
        -TextExtension @(
            '2.5.29.19={critical}{text}ca=TRUE&pathlength=0'
        ) `
        -FriendlyName 'PwShGUI Subordinate CA'

    $pfxPath = Join-Path $certPath 'SubCA.pfx'
    $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPassword)
    [System.IO.File]::WriteAllBytes($pfxPath, $bytes)

    $cerPath = Join-Path $certPath 'SubCA.cer'
    $pubBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($cerPath, $pubBytes)

    if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
        Write-LedgerEntry -EventType 'AUDIT' -Source 'PKIChainManager' -Data @{
            action         = 'SubCA-Created'
            subject        = $Subject
            thumbprint     = $cert.Thumbprint
            signerThumb    = $SignerThumbprint
            notAfter       = $notAfter.ToString('o')
        }
    }

    Write-Verbose "[PKI] SubCA created: $($cert.Thumbprint)"
    [PSCustomObject]@{
        Type        = 'SubordinateCA'
        Subject     = $Subject
        Thumbprint  = $cert.Thumbprint
        SignedBy    = $SignerThumbprint
        NotAfter    = $notAfter
        PfxPath     = $pfxPath
        CerPath     = $cerPath
        Certificate = $cert
    }
}

function New-CodeSignCertificate {
    <#
    .SYNOPSIS  Generate a Code Signing certificate signed by the SubCA.
    .PARAMETER Subject         CN for the code signing cert.
    .PARAMETER SignerThumbprint Thumbprint of the SubCA cert.
    .PARAMETER ValidityYears   Certificate lifetime (default 2).
    .PARAMETER KeyLength       RSA key size (default 2048).
    .PARAMETER PfxPassword     SecureString password for the PFX export.
    #>
    [CmdletBinding()]
    param(
        [string]$Subject = 'CN=PwShGUI Code Signing, O=SovereignKernel, OU=Security',
        [Parameter(Mandatory)]
        [string]$SignerThumbprint,
        [int]$ValidityYears = 2,
        [int]$KeyLength = 2048,
        [Parameter(Mandatory)]
        [System.Security.SecureString]$PfxPassword
    )
    if (-not $script:_PKIInitialized) { throw '[PKIChainManager] Not initialized.' }

    $signer = Get-ChildItem Cert:\CurrentUser\My\$SignerThumbprint -ErrorAction Stop
    $certPath = Join-Path $script:_PKIBasePath 'codesign'
    $notBefore = [datetime]::UtcNow
    $notAfter  = $notBefore.AddYears($ValidityYears)

    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Signer $signer `
        -KeyAlgorithm RSA `
        -KeyLength $KeyLength `
        -HashAlgorithm SHA256 `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotBefore $notBefore `
        -NotAfter $notAfter `
        -Type CodeSigningCert `
        -FriendlyName 'PwShGUI Code Signing'

    $pfxPath = Join-Path $certPath 'CodeSign.pfx'
    $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPassword)
    [System.IO.File]::WriteAllBytes($pfxPath, $bytes)

    $cerPath = Join-Path $certPath 'CodeSign.cer'
    $pubBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($cerPath, $pubBytes)

    if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
        Write-LedgerEntry -EventType 'AUDIT' -Source 'PKIChainManager' -Data @{
            action      = 'CodeSign-Created'
            subject     = $Subject
            thumbprint  = $cert.Thumbprint
            signerThumb = $SignerThumbprint
            notAfter    = $notAfter.ToString('o')
        }
    }

    Write-Verbose "[PKI] Code Signing cert created: $($cert.Thumbprint)"
    [PSCustomObject]@{
        Type        = 'CodeSigning'
        Subject     = $Subject
        Thumbprint  = $cert.Thumbprint
        SignedBy    = $SignerThumbprint
        NotAfter    = $notAfter
        PfxPath     = $pfxPath
        CerPath     = $cerPath
        Certificate = $cert
    }
}

function Get-PKIChainStatus {
    <#
    .SYNOPSIS  Show the current PKI chain status from the local cert store.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:_PKIInitialized) { throw '[PKIChainManager] Not initialized.' }

    $caPath = Join-Path $script:_PKIBasePath 'ca'
    $subPath = Join-Path $script:_PKIBasePath 'subca'
    $csPath = Join-Path $script:_PKIBasePath 'codesign'

    $status = @()
    foreach ($item in @(
        @{ Type = 'RootCA';       Path = (Join-Path $caPath 'RootCA.cer') },
        @{ Type = 'SubordinateCA'; Path = (Join-Path $subPath 'SubCA.cer') },
        @{ Type = 'CodeSigning';  Path = (Join-Path $csPath 'CodeSign.cer') }
    )) {
        if (Test-Path $item.Path) {
            $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($item.Path)
            $daysLeft = ($c.NotAfter - [datetime]::UtcNow).Days
            $status += [PSCustomObject]@{
                Type       = $item.Type
                Subject    = $c.Subject
                Thumbprint = $c.Thumbprint
                NotAfter   = $c.NotAfter
                DaysLeft   = $daysLeft
                Status     = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -lt 90) { 'EXPIRING' } else { 'Valid' }
            }
        } else {
            $status += [PSCustomObject]@{
                Type       = $item.Type
                Subject    = '(not created)'
                Thumbprint = ''
                NotAfter   = $null
                DaysLeft   = -1
                Status     = 'Missing'
            }
        }
    }
    $status
}

function Export-CertToVault {
    <#
    .SYNOPSIS  Export a PFX to Bitwarden vault via AssistedSASC.
    .PARAMETER PfxPath        Path to the PFX file.
    .PARAMETER VaultItemName  Name for the Bitwarden secure note.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PfxPath,

        [Parameter(Mandatory)]
        [string]$VaultItemName
    )
    if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }

    $base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PfxPath))

    if (Get-Command Set-VaultSecret -ErrorAction SilentlyContinue) {
        Set-VaultSecret -Name $VaultItemName -Value $base64
        Write-Verbose "[PKI] Exported to vault: $VaultItemName"
    } else {
        Write-Warning "[PKI] AssistedSASC not loaded. Cannot export to vault. Base64 saved to clipboard."
        Set-Clipboard $base64
    }

    if (Get-Command Write-LedgerEntry -ErrorAction SilentlyContinue) {
        Write-LedgerEntry -EventType 'AUDIT' -Source 'PKIChainManager' -Data @{
            action    = 'Cert-ExportToVault'
            pfxPath   = $PfxPath
            vaultItem = $VaultItemName
        }
    }
}

function New-FullPKIChain {
    <#
    .SYNOPSIS  Create the complete 3-tier PKI chain in one operation.
    .PARAMETER PfxPassword  SecureString password for all PFX exports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString]$PfxPassword
    )
    if (-not $script:_PKIInitialized) { throw '[PKIChainManager] Not initialized.' }

    Write-Verbose "`n=== Creating Full PKI Chain ==="

    Write-Verbose "`n[1/3] Root CA..."
    $root = New-RootCACertificate -PfxPassword $PfxPassword

    Write-Verbose "`n[2/3] Subordinate CA..."
    $sub = New-SubordinateCACertificate -SignerThumbprint $root.Thumbprint -PfxPassword $PfxPassword

    Write-Verbose "`n[3/3] Code Signing Certificate..."
    $cs = New-CodeSignCertificate -SignerThumbprint $sub.Thumbprint -PfxPassword $PfxPassword

    Write-Verbose "`n=== PKI Chain Complete ==="
    Write-Verbose "Root CA:   $($root.Thumbprint)"
    Write-Verbose "SubCA:     $($sub.Thumbprint)"
    Write-Verbose "CodeSign:  $($cs.Thumbprint)"

    [PSCustomObject]@{
        RootCA       = $root
        SubCA        = $sub
        CodeSigning  = $cs
    }
}

# ── Exports ──────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Initialize-PKIChainManager'
    'New-RootCACertificate'
    'New-SubordinateCACertificate'
    'New-CodeSignCertificate'
    'Get-PKIChainStatus'
    'Export-CertToVault'
    'New-FullPKIChain'
)

