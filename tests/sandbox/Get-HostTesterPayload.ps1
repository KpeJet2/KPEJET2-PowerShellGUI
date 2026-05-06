# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Handles certificate key exchange between host and sandbox for encrypted archive access.
.DESCRIPTION
    On the HOST side: exports the public cert for the sandbox to use.
    Provides decryption utility to recover the AES password from a .keyblob file
    using the matching private key in CurrentUser\My cert store.
.NOTES
    Author  : The Establishment
    Runs on : HOST machine (not sandbox)
#>
param(
    [Parameter(Mandatory, ParameterSetName = 'Export')]
    [switch]$ExportPublicKey,

    [Parameter(Mandatory, ParameterSetName = 'Decrypt')]
    [switch]$DecryptKeyBlob,

    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Decrypt')]
    [string]$Thumbprint,

    [Parameter(ParameterSetName = 'Decrypt')]
    [string]$KeyBlobPath,

    [Parameter(ParameterSetName = 'Export')]
    [string]$OutputDir = '.'
)

$ErrorActionPreference = 'Stop'

if ($ExportPublicKey) {
    # ========================== EXPORT PUBLIC KEY ==========================
    $certs = Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction Stop |
             Where-Object { $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey -and $_.PublicKey.Key.KeySize -ge 2048 }

    if (-not $certs -or @($certs).Count -eq 0) {
        Write-Host '[ERROR] No valid RSA certificates found in CurrentUser\My' -ForegroundColor Red
        Write-Host 'To create a self-signed cert for testing:' -ForegroundColor Yellow
        Write-Host '  New-SelfSignedCertificate -Subject "CN=PwShGUI-TestHost" -KeyAlgorithm RSA -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(2)' -ForegroundColor Cyan
        exit 1
    }

    if ($Thumbprint) {
        $cert = $certs | Where-Object { $_.Thumbprint -eq $Thumbprint }
        if (-not $cert) {
            Write-Host "[ERROR] Cert with thumbprint $Thumbprint not found" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host 'Available certificates:' -ForegroundColor Cyan
        $i = 0
        foreach ($c in $certs) {
            $i++
            Write-Host "  [$i] $($c.Thumbprint) | $($c.Subject) | Expires: $($c.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
        }
        $cert = @($certs)[0]
        Write-Host "Using first cert: $($cert.Thumbprint)" -ForegroundColor Green
    }

    # Export public key as .cer (DER encoded)
    $exportPath = Join-Path $OutputDir "PwShGUI-TestHost-$($cert.Thumbprint.Substring(0,8)).cer"
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($exportPath, $certBytes)

    # Also export thumbprint to a payload file for sandbox
    $payloadPath = Join-Path $OutputDir 'host-cert-payload.json'
    $payload = [ordered]@{
        thumbprint = $cert.Thumbprint
        subject    = $cert.Subject
        publicKey  = [Convert]::ToBase64String($certBytes)
        exportedAt = (Get-Date -Format 'o')
    }
    ConvertTo-Json $payload -Depth 5 | Set-Content -LiteralPath $payloadPath -Encoding UTF8

    Write-Host '================================================================' -ForegroundColor Green
    Write-Host '  Public Key Export Complete' -ForegroundColor Green
    Write-Host "  Certificate : $exportPath" -ForegroundColor Gray
    Write-Host "  Payload     : $payloadPath" -ForegroundColor Gray
    Write-Host "  Thumbprint  : $($cert.Thumbprint)" -ForegroundColor Gray
    Write-Host '================================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Place these files in the sandbox shared folder before running browser tests.' -ForegroundColor Yellow
}

if ($DecryptKeyBlob) {
    # ========================== DECRYPT KEY BLOB ==========================
    if (-not $KeyBlobPath -or -not (Test-Path $KeyBlobPath)) {
        Write-Host '[ERROR] KeyBlobPath not found or not specified' -ForegroundColor Red
        exit 1
    }

    $keyBlob = Get-Content $KeyBlobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $blobThumbprint = $keyBlob.thumbprint

    if ($Thumbprint) { $blobThumbprint = $Thumbprint }

    $cert = Get-Item "Cert:\CurrentUser\My\$blobThumbprint" -ErrorAction Stop
    if (-not $cert.HasPrivateKey) {
        Write-Host "[ERROR] No private key for cert $blobThumbprint" -ForegroundColor Red
        exit 1
    }

    # Decrypt the AES password
    $encryptedBytes = [Convert]::FromBase64String($keyBlob.encryptedKey)
    $privKey = $cert.PrivateKey
    $decryptedBytes = $privKey.Decrypt($encryptedBytes, $true)
    $password = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)

    Write-Host '================================================================' -ForegroundColor Green
    Write-Host '  Key Blob Decrypted' -ForegroundColor Green
    Write-Host "  Archive     : $($keyBlob.archiveFile)" -ForegroundColor Gray
    Write-Host "  Cert Used   : $blobThumbprint" -ForegroundColor Gray
    Write-Host '================================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '7z password (copy this):' -ForegroundColor Yellow
    Write-Host $password -ForegroundColor Cyan
    Write-Host ''
    Write-Host "To extract: 7z x `"$($keyBlob.archiveFile)`" -p`"$password`"" -ForegroundColor Gray
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




