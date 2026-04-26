# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Packages sandbox browser test results into an encrypted 7zip archive.
.DESCRIPTION
    Installs 7-Zip if missing (winget with manual fallback), collects all test
    results, generates an unencrypted SandboxEnvironment-HelpAbout.txt, and
    creates a password-protected .7z archive. Encryption uses either a cert
    from CurrentUser\My (RSA public key encrypts AES key) or falls back to
    YYYYMMDD date-based password. The archive is saved to the sandbox desktop
    and the shared output folder for host download.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$SessionId = "browsertest-$(Get-Date -Format 'yyyyMMddHHmmss')",

    [string]$CertThumbprint,

    [string]$HostTesterName = 'HOST-of-CHIEF-to-TEST'
)

$ErrorActionPreference = 'Continue'

function Write-ArchLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    $color = switch ($Level) {
        'ERROR' { 'Red' }; 'WARN' { 'Yellow' }; 'OK' { 'Green' }; default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

# ========================== INSTALL 7-ZIP ==========================
function Install-7Zip {
    $exePaths = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )

    foreach ($p in $exePaths) {
        if (Test-Path $p) {
            Write-ArchLog "7-Zip found: $p" -Level 'OK'
            return $p
        }
    }

    # Try winget
    $wingetAvail = $false
    try {
        $null = & winget --version 2>&1
        if ($LASTEXITCODE -eq 0) { $wingetAvail = $true }
    } catch { } <# Intentional: non-fatal winget availability probe #>

    if ($wingetAvail) {
        Write-ArchLog 'Installing 7-Zip via winget...'
        try {
            & winget install 7zip.7zip --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
            foreach ($p in $exePaths) {
                if (Test-Path $p) {
                    Write-ArchLog "7-Zip installed: $p" -Level 'OK'
                    return $p
                }
            }
        } catch {
            Write-ArchLog "Winget install failed: $_" -Level 'WARN'
        }
    }

    # Manual download fallback
    Write-ArchLog 'Downloading 7-Zip installer...' -Level 'WARN'
    try {
        $installerUrl = 'https://7-zip.org/a/7z2409-x64.exe'
        $installerPath = Join-Path $OutputPath '7z-setup.exe'
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        $null = Start-Process $installerPath -ArgumentList '/S' -Wait -PassThru
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        foreach ($p in $exePaths) {
            if (Test-Path $p) {
                Write-ArchLog "7-Zip installed via manual download: $p" -Level 'OK'
                return $p
            }
        }
    } catch {
        Write-ArchLog "Manual 7-Zip install failed: $_" -Level 'ERROR'
        Write-ArchLog 'Download manually from: https://7-zip.org/' -Level 'WARN'
    }

    return $null
}

# ========================== HELP ABOUT ==========================
function New-HelpAboutFile {
    param([string]$OutDir)
    $helpPath = Join-Path $OutDir 'SandboxEnvironment-HelpAbout.txt'

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('================================================================')
    $lines.Add('  Sandbox Environment Help About')
    $lines.Add("  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("  Session: $SessionId")
    $lines.Add("  HOST-of-CHIEF-to-TEST: $HostTesterName")
    $lines.Add('================================================================')
    $lines.Add('')

    # PowerShell version
    $lines.Add('--- PowerShell Version ---')
    foreach ($key in $PSVersionTable.Keys) {
        $lines.Add("  $key : $($PSVersionTable[$key])")
    }
    $lines.Add('')

    # OS info
    $lines.Add('--- Operating System ---')
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $lines.Add("  Caption      : $($os.Caption)")
        $lines.Add("  Version      : $($os.Version)")
        $lines.Add("  BuildNumber  : $($os.BuildNumber)")
        $lines.Add("  Architecture : $($os.OSArchitecture)")
        $lines.Add("  TotalMemoryMB: $([Math]::Round($os.TotalVisibleMemorySize / 1024))")
    } catch {
        $lines.Add("  (CIM query failed: $_)")
    }
    $lines.Add('')

    # Computer info
    $lines.Add('--- Computer ---')
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $lines.Add("  Name   : $($cs.Name)")
        $lines.Add("  Domain : $($cs.Domain)")
        $lines.Add("  Model  : $($cs.Model)")
    } catch {
        $lines.Add("  (CIM query failed: $_)")
    }
    $lines.Add('')

    # Browser versions
    $lines.Add('--- Browser Versions ---')
    $browserPaths = @{
        'Edge'    = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe')
        'Chrome'  = @('C:\Program Files\Google\Chrome\Application\chrome.exe', 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe')
        'Firefox' = @('C:\Program Files\Mozilla Firefox\firefox.exe', 'C:\Program Files (x86)\Mozilla Firefox\firefox.exe')
    }
    foreach ($browser in $browserPaths.Keys) {
        $found = $false
        foreach ($bp in $browserPaths[$browser]) {
            if (Test-Path $bp) {
                $ver = (Get-Item $bp).VersionInfo.ProductVersion
                $lines.Add("  $browser : $ver ($bp)")
                $found = $true
                break
            }
        }
        if (-not $found) { $lines.Add("  $browser : Not installed") }
    }
    $lines.Add('')

    # .NET version
    $lines.Add('--- .NET Runtime ---')
    $lines.Add("  CLRVersion: $($PSVersionTable.CLRVersion)")
    $lines.Add('')

    # Disk space
    $lines.Add('--- Disk Space ---')
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | Where-Object { $_.Used -gt 0 }
        foreach ($d in $drives) {
            $usedGB = [Math]::Round($d.Used / 1GB, 1)
            $freeGB = [Math]::Round($d.Free / 1GB, 1)
            $lines.Add("  $($d.Root) Used:${usedGB}GB Free:${freeGB}GB")
        }
    } catch {
        $lines.Add("  (Drive query failed: $_)")
    }

    $content = $lines -join "`r`n"
    Set-Content -LiteralPath $helpPath -Value $content -Encoding UTF8
    Write-ArchLog "HelpAbout generated: $helpPath" -Level 'OK'
    return @{ Path = $helpPath; Content = $content }
}

# ========================== ENCRYPTION ==========================
function Get-ArchivePassword {
    param([string]$Thumbprint)

    # Try cert-based encryption
    if ($Thumbprint) {
        try {
            $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction Stop
            if ($cert.HasPrivateKey -or $cert.PublicKey) {
                # Generate random AES password
                $aesBytes = New-Object byte[] 32
                $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
                $rng.GetBytes($aesBytes)
                $rng.Dispose()
                $aesPassword = [Convert]::ToBase64String($aesBytes)

                # Encrypt the AES password with the cert's public key
                $pubKey = $cert.PublicKey.Key
                $encryptedKey = $pubKey.Encrypt([System.Text.Encoding]::UTF8.GetBytes($aesPassword), $true)
                $encryptedKeyB64 = [Convert]::ToBase64String($encryptedKey)

                Write-ArchLog "Cert-based encryption using thumbprint: $Thumbprint" -Level 'OK'
                return @{
                    Password      = $aesPassword
                    Method        = 'Certificate'
                    Thumbprint    = $Thumbprint
                    EncryptedKey  = $encryptedKeyB64
                    Subject       = $cert.Subject
                }
            }
        } catch {
            Write-ArchLog "Cert lookup failed for $Thumbprint -- $_" -Level 'WARN'
        }
    }

    # Search cert store for any valid RSA cert
    try {
        $certs = Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction Stop |
                 Where-Object { $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey -and $_.PublicKey.Key.KeySize -ge 2048 }
        if ($certs -and @($certs).Count -gt 0) {
            $cert = @($certs)[0]
            $aesBytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $rng.GetBytes($aesBytes)
            $rng.Dispose()
            $aesPassword = [Convert]::ToBase64String($aesBytes)

            $pubKey = $cert.PublicKey.Key
            $encryptedKey = $pubKey.Encrypt([System.Text.Encoding]::UTF8.GetBytes($aesPassword), $true)
            $encryptedKeyB64 = [Convert]::ToBase64String($encryptedKey)

            Write-ArchLog "Auto-selected cert: $($cert.Thumbprint) ($($cert.Subject))" -Level 'OK'
            return @{
                Password     = $aesPassword
                Method       = 'Certificate'
                Thumbprint   = $cert.Thumbprint
                EncryptedKey = $encryptedKeyB64
                Subject      = $cert.Subject
            }
        }
    } catch {
        Write-ArchLog "Cert store search failed: $_" -Level 'WARN'
    }

    # Fallback: date-based password
    $datePassword = Get-Date -Format 'yyyyMMdd'
    Write-ArchLog "No certs found. Using date-based password (YYYYMMDD)" -Level 'WARN'
    return @{
        Password = $datePassword
        Method   = 'DateFallback'
    }
}

# ========================== MAIN ==========================
$7zExe = Install-7Zip
if (-not $7zExe) {
    Write-ArchLog 'Cannot proceed without 7-Zip' -Level 'ERROR'
    exit 1
}

# Generate HelpAbout
$stagingDir = Join-Path $OutputPath 'archive-staging'
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
$helpAbout = New-HelpAboutFile -OutDir $stagingDir

# Collect files to archive
$filesToArchive = New-Object System.Collections.Generic.List[string]
$resultFiles = @(
    'sandbox-browser-test-results.json',
    'sandbox-browser-test-bugs.json',
    'browser-manifest.json',
    'browser-test-suite.log',
    'browser-test-install.log',
    'browser-test-complete.json'
)
foreach ($rf in $resultFiles) {
    $rfPath = Join-Path $OutputPath $rf
    if (Test-Path $rfPath) {
        $destPath = Join-Path $stagingDir $rf
        Copy-Item $rfPath $destPath -Force
        $filesToArchive.Add($destPath)
    }
}

# Get password
$pwInfo = Get-ArchivePassword -Thumbprint $CertThumbprint

# Create archive -- HelpAbout is added WITHOUT password, rest WITH password
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$archiveName = "SandboxTestResults-$timestamp.7z"
$desktopPath = 'C:\Users\WDAGUtilityAccount\Desktop'
$archivePath = Join-Path $desktopPath $archiveName

# 7z cannot do mixed encryption in one archive, so we create:
# 1. The encrypted .7z with all results
# 2. The unencrypted HelpAbout.txt alongside it
Write-ArchLog 'Creating encrypted archive...'

# Build argument list properly
$addArgs = @('a', '-t7z', '-mhe=on', "-p$($pwInfo.Password)", $archivePath)
$addArgs += $filesToArchive.ToArray()

$proc = Start-Process $7zExe -ArgumentList $addArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $stagingDir '7z-stdout.txt')
if ($proc.ExitCode -eq 0) {
    Write-ArchLog "Archive created: $archivePath" -Level 'OK'
} else {
    Write-ArchLog "7z exited with code $($proc.ExitCode)" -Level 'ERROR'
}

# Copy HelpAbout alongside the archive (unencrypted)
$helpAboutDest = Join-Path $desktopPath "SandboxTestResults-$timestamp-HelpAbout.txt"
Copy-Item $helpAbout.Path $helpAboutDest -Force

# Save encrypted key blob if cert-based
if ($pwInfo.Method -eq 'Certificate') {
    $keyBlobPath = Join-Path $desktopPath "SandboxTestResults-$timestamp.keyblob"
    $keyBlobContent = [ordered]@{
        method       = 'RSA-AES'
        thumbprint   = $pwInfo.Thumbprint
        subject      = $pwInfo.Subject
        encryptedKey = $pwInfo.EncryptedKey
        archiveFile  = $archiveName
        created      = (Get-Date -Format 'o')
        note         = 'Decrypt the encryptedKey with the matching private key to get the 7z password'
    }
    ConvertTo-Json $keyBlobContent -Depth 5 | Set-Content -LiteralPath $keyBlobPath -Encoding UTF8
    Write-ArchLog "Key blob saved: $keyBlobPath" -Level 'OK'
}

# Also copy to output folder for host access
Copy-Item $archivePath (Join-Path $OutputPath $archiveName) -Force -ErrorAction SilentlyContinue
Copy-Item $helpAboutDest (Join-Path $OutputPath "SandboxTestResults-$timestamp-HelpAbout.txt") -Force -ErrorAction SilentlyContinue
if ($pwInfo.Method -eq 'Certificate') {
    Copy-Item $keyBlobPath (Join-Path $OutputPath "SandboxTestResults-$timestamp.keyblob") -Force -ErrorAction SilentlyContinue
}

# Write archive metadata as 7z comment-substitute (7z doesn't support metadata well)
$metaPath = Join-Path $desktopPath "SandboxTestResults-$timestamp-META.json"
$metaContent = [ordered]@{
    archiveFile         = $archiveName
    'HOST-of-CHIEF-to-TEST' = $HostTesterName
    sessionId           = $SessionId
    encryptionMethod    = $pwInfo.Method
    certThumbprint      = if ($pwInfo.Thumbprint) { $pwInfo.Thumbprint } else { 'N/A' }
    helpAboutSummary    = ($helpAbout.Content -split "`r?`n" | Select-Object -First 20) -join ' | '
    created             = (Get-Date -Format 'o')
}
ConvertTo-Json $metaContent -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding UTF8
Copy-Item $metaPath (Join-Path $OutputPath "SandboxTestResults-$timestamp-META.json") -Force -ErrorAction SilentlyContinue

Write-ArchLog '=================================================================='
Write-ArchLog '  Archive Summary'
Write-ArchLog '=================================================================='
Write-ArchLog "  Archive    : $archivePath"
Write-ArchLog "  HelpAbout  : $helpAboutDest (unencrypted)"
Write-ArchLog "  Encryption : $($pwInfo.Method)"
if ($pwInfo.Method -eq 'Certificate') {
    Write-ArchLog "  Cert       : $($pwInfo.Thumbprint)"
    Write-ArchLog "  Key Blob   : $keyBlobPath"
} else {
    Write-ArchLog "  Password   : YYYYMMDD format of sandbox clock date"
}
Write-ArchLog "  HOST-of-CHIEF-to-TEST: $HostTesterName"
Write-ArchLog '=================================================================='

# Cleanup staging
Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




