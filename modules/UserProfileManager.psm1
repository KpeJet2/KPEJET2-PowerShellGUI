# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 3 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    UserProfileManager -- capture, save, compare, and restore a full Windows user profile snapshot.
# TODO: HelpMenu | Show-UserProfileHelp | Actions: Load|Save|Reset|Export|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Captures: winget applications, PowerShell version/modules/scripts, user application registry
    configs, taskbar layout (Win10/11), print drivers, and file-extension MIME types.
    Profiles are serialized to JSON and may be AES-256-PBKDF2 encrypted at the user's request.
    Rollback snapshots are always created before any restore and are auto-encrypted using a key
    derived from the profile name, machine name, and username -- no user prompt required.

.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 2026-02-28
    Module  : UserProfileManager.psm1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#  CONSTANTS
$script:ProfileSchemaVersion = '1.0'
$script:PBKDF2_Iterations     = 600000
$script:AES_KeySize            = 256
$script:AES_BlockSize          = 128
$script:SaltSize               = 32   # bytes
$script:ProfileFileExt         = '.upjson'
$script:RollbackSubDir         = 'Rollbacks'

#  ENCRYPTION HELPERS

function New-AesKey {
    <#
    .SYNOPSIS  Derives a 256-bit AES key + 128-bit IV from a password using PBKDF2 (SHA-256).
    .OUTPUTS   [hashtable] Keys: Key (byte[32]), IV (byte[16]), Salt (byte[32])
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification='Internal helper invoked only by Protect/Unprotect-ProfileData with plaintext briefly unwrapped from caller-supplied SecureString; promoting to SecureString here would simply move the unwrap one frame down without security gain.')]
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Password,
        [byte[]] $Salt = $null
    )
    if (-not $PSCmdlet.ShouldProcess('New-AesKey', 'Create')) { return }

    if ($null -eq $Salt -or $Salt.Length -eq 0) {
        $Salt = New-Object byte[] $script:SaltSize
        [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Salt)
    }
    $rfc = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Password,
        $Salt,
        $script:PBKDF2_Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    @{
        Key  = $rfc.GetBytes(32)
        IV   = $rfc.GetBytes(16)
        Salt = $Salt
    }
}

function Protect-ProfileData {
    <#
    .SYNOPSIS  AES-256-CBC encrypts a plain-text string. Returns Base64 cipher text.
    .PARAMETER PlainText   The JSON string to encrypt.
    .PARAMETER Password    User-supplied password or auto-derived key string.
    .OUTPUTS   [hashtable] Keys: CipherText (Base64), Salt (Base64)
        .DESCRIPTION
      Detailed behaviour: Protect profile data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification='Receives plaintext password already unwrapped from caller-supplied SecureString (see Save-ProfileSnapshot SecureStringToBSTR pattern). API is internal-use; maintains symmetry with Unprotect-ProfileData.')]
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PlainText,
        [Parameter(Mandatory)] [string] $Password
    )
    $keyMaterial = New-AesKey -Password $Password
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize   = $script:AES_KeySize
    $aes.BlockSize = $script:AES_BlockSize
    $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keyMaterial.Key
    $aes.IV  = $keyMaterial.IV

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encryptor  = $aes.CreateEncryptor()
    $mem        = New-Object System.IO.MemoryStream
    $cs         = New-Object System.Security.Cryptography.CryptoStream($mem, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
    $cs.Write($plainBytes, 0, $plainBytes.Length)
    $cs.FlushFinalBlock()
    $cs.Close()

    @{
        CipherText = [Convert]::ToBase64String($mem.ToArray())
        Salt       = [Convert]::ToBase64String($keyMaterial.Salt)
    }
}

function Unprotect-ProfileData {
    <#
    .SYNOPSIS  Decrypts a Base64 AES-256-CBC cipher text back to a plain-text string.
    .PARAMETER CipherText  Base64 encrypted data.
    .PARAMETER Salt        Base64 salt used during encryption.
    .PARAMETER Password    Password matching the one used during encryption.
    .OUTPUTS   [string] Decrypted plain text.
        .DESCRIPTION
      Detailed behaviour: Unprotect profile data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification='Receives plaintext password already unwrapped from caller-supplied SecureString (see Restore-ProfileSnapshot SecureStringToBSTR pattern). API is internal-use; maintains symmetry with Protect-ProfileData.')]
    [OutputType([System.String])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CipherText,
        [Parameter(Mandatory)] [string] $Salt,
        [Parameter(Mandatory)] [string] $Password
    )
    $saltBytes = [Convert]::FromBase64String($Salt)
    $keyMaterial = New-AesKey -Password $Password -Salt $saltBytes

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize   = $script:AES_KeySize
    $aes.BlockSize = $script:AES_BlockSize
    $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keyMaterial.Key
    $aes.IV  = $keyMaterial.IV

    $cipherBytes = [Convert]::FromBase64String($CipherText)
    $decryptor   = $aes.CreateDecryptor()
    $mem         = New-Object System.IO.MemoryStream($cipherBytes)
    $cs          = New-Object System.Security.Cryptography.CryptoStream($mem, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read)
    $reader      = New-Object System.IO.StreamReader($cs, [System.Text.Encoding]::UTF8)
    $plainText   = $reader.ReadToEnd()
    $reader.Close()
    $plainText
}

function Get-AutoRollbackPassword {
    <#
    .SYNOPSIS  Derives the auto-password used to encrypt rollback files (no user prompt).
               Key material: profileName + machineName + username (deterministic per machine/user).
    #>
    param([Parameter(Mandatory)] [string] $ProfileName)
    # Use SHA-256 hash of combined material so it is printable but unique
    $combined  = "$ProfileName|$($env:COMPUTERNAME)|$($env:USERNAME)"
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined))
    [Convert]::ToBase64String($hashBytes)
}

#  DATA CAPTURE FUNCTIONS

function Get-WingetApplications {
    <#
    .SYNOPSIS  Returns a list of all winget-managed applications with Id, Name, Version, Source.
        .DESCRIPTION
      Detailed behaviour: Get winget applications.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    try {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-AppLog -Message '' -Level Warning
            return $result
        }
        # Use --accept-source-agreements to avoid interactive prompts
        # 2>&1 mixes ErrorRecord objects into the array -- keep only plain strings
        $raw = & winget list --accept-source-agreements 2>&1 | Where-Object { $_ -is [string] }
        $inTable = $false
        foreach ($line in $raw) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^-{3,}') { $inTable = $true; continue }
            if (-not $inTable) { continue }
            # Split on 2+ spaces to handle names containing single spaces
            $cols = @($line -split '\s{2,}' | Where-Object { $_ -ne '' })
            if ($cols.Count -ge 2) {
                $entry = @{
                    Name    = $cols[0].Trim()  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    Id      = $cols[1].Trim()  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    Version = if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    Source  = if ($cols.Count -ge 4) { $cols[3].Trim() } else { 'unknown' }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }
                $result.Add($entry)
            }
        }
    } catch {
        Write-AppLog -Message "[UserProfileManager] WingetApplications capture error: $_" -Level Warning
    }
    return $result
}

function Get-PSEnvironment {
    <#
    .SYNOPSIS  Captures PowerShell version, installed modules (all scopes), and script paths.
        .DESCRIPTION
      Detailed behaviour: Get p s environment.
    #>
    param()
    $data = @{
        PSVersion         = $PSVersionTable.PSVersion.ToString()
        PSEdition         = $PSVersionTable.PSEdition
        PSHOME            = $PSHOME
        InstalledModules  = [System.Collections.Generic.List[hashtable]]::new()
        ScriptPaths       = [System.Collections.Generic.List[hashtable]]::new()
        ProfilePaths      = @{}
    }

    # Modules
    try {
        Get-Module -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Name, Version -Unique |
        ForEach-Object {
            $data.InstalledModules.Add(@{
                Name        = $_.Name
                Version     = $_.Version.ToString()
                ModuleBase  = $_.ModuleBase
                Repository  = if ($_.RepositorySourceLocation) { $_.RepositorySourceLocation.ToString() } else { 'local' }
            })
        }
    } catch { Write-AppLog -Message "[UserProfileManager] PSEnvironment modules error: $_" -Level Warning }

    # Scripts on PATH
    try {
        $env:PATH -split ';' | Where-Object { $_ } | ForEach-Object {
            if (Test-Path $_) {
                Get-ChildItem -Path $_ -Filter '*.ps1' -File -ErrorAction Stop |
                ForEach-Object {
                    $data.ScriptPaths.Add(@{
                        Name     = $_.Name
                        FullPath = $_.FullName
                        Size     = $_.Length
                        Modified = $_.LastWriteTime.ToString('o')
                    })
                }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] PSEnvironment scripts error: $_" -Level Warning }

    # Profile paths (existence + hash when present)
    $profileKeys = @('AllUsersAllHosts','AllUsersCurrentHost','CurrentUserAllHosts','CurrentUserCurrentHost')
    foreach ($key in $profileKeys) {
        $path = $PROFILE.$key
        $exists = $false
        $hash = $null
        try {
            $null = Get-Item -Path $path -ErrorAction Stop
            $exists = $true
            $hash = (Get-FileHash -Path $path -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch { <# Intentional: profile path may not exist #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        $data.ProfilePaths[$key] = @{
            Path   = $path
            Exists = $exists
            Hash   = $hash
        }
    }

    return $data
}

function Get-UserAppConfigs {
    <#
    .SYNOPSIS  Captures user-scope application configuration: HKCU registry keys + common config file paths.
    .NOTES     Registry subtree is limited to Software\ to avoid excessive data.
               Config files captured: %APPDATA%, %LOCALAPPDATA% *.ini, *.cfg, *.json, *.xml (top 2 levels).
        .DESCRIPTION
      Detailed behaviour: Get user app configs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        RegistryKeys = [System.Collections.Generic.List[hashtable]]::new()
        ConfigFiles  = [System.Collections.Generic.List[hashtable]]::new()
    }

    # HKCU\SOFTWARE -- enumerate top-level app keys (name + default value only, not deep recursion)
    try {
        $softwareKey = 'HKCU:\SOFTWARE'
        Get-ChildItem -Path $softwareKey -ErrorAction Stop | ForEach-Object {
            $keyInfo = @{
                KeyPath  = $_.PSPath -replace 'Microsoft.PowerShell.Core\\Registry::', 'Registry::'
                Name     = $_.PSChildName
                SubKeys  = ($_.SubKeyCount)
                Values   = [System.Collections.Generic.List[hashtable]]::new()
            }
            try {
                $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                if ($props) {
                    $props.PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' } |
                    ForEach-Object {
                        $keyInfo.Values.Add(@{ Name = $_.Name; Value = [string]$_.Value })
                    }
                }
            } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            $data.RegistryKeys.Add($keyInfo)
        }
    } catch { Write-AppLog -Message "[UserProfileManager] UserAppConfigs registry error: $_" -Level Warning }

    # Config files in APPDATA / LOCALAPPDATA (2 levels deep, common extensions)
    $configDirs = @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ }
    $extensions = @('*.ini','*.cfg','*.json','*.xml','*.config','*.toml','*.yaml','*.yml')
    foreach ($dir in $configDirs) {
        try {
            $null = Get-Item -Path $dir -ErrorAction Stop
            foreach ($ext in $extensions) {
                Get-ChildItem -Path $dir -Filter $ext -File -Depth 2 -ErrorAction Stop |
                ForEach-Object {
                    $data.ConfigFiles.Add(@{
                        Path     = $_.FullName
                        Name     = $_.Name
                        Size     = $_.Length
                        Modified = $_.LastWriteTime.ToString('o')
                        Hash     = try { (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } catch { $null }
                    })
                }
            }
        } catch { Write-AppLog -Message "[UserProfileManager] Config file scan error in $dir`: $_" -Level Warning }
    }

    return $data
}

function Get-TaskbarLayout {
    <#
    .SYNOPSIS  Captures taskbar pinned items + layout XML for Windows 10 and Windows 11.
        .DESCRIPTION
      Detailed behaviour: Get taskbar layout.
    #>
    param()
    $data = @{
        OSBuild          = [System.Environment]::OSVersion.Version.Build
        PinnedItems      = [System.Collections.Generic.List[hashtable]]::new()
        LayoutXmlPath    = $null
        LayoutXmlContent = $null
        TaskbandData     = $null
    }

    # Pinned shortcuts (lnk files in taskbar folder -- works on both Win10 and Win11)
    $taskbarPinDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    try {
        if (Test-Path $taskbarPinDir) {
            Get-ChildItem -Path $taskbarPinDir -Filter '*.lnk' -File -ErrorAction Stop |
            ForEach-Object {
                $data.PinnedItems.Add(@{
                    Name    = $_.Name
                    Path    = $_.FullName
                    Size    = $_.Length
                    Modified = $_.LastWriteTime.ToString('o')
                    # Store binary as Base64 so it survives JSON round-trip and can be written back
                    LnkBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($_.FullName))
                })
            }
        }
    } catch {
        Write-AppLog -Message "[UserProfileManager] Taskbar pin scan error: $_" -Level Warning
    }

    # Windows 10: LayoutModification.xml
    try {
        $layoutXml = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell\LayoutModification.xml'
        try {
            $null = Get-Item -Path $layoutXml -ErrorAction Stop
        } catch {
            $layoutXml = Join-Path $env:APPDATA 'Microsoft\Windows\Shell\LayoutModification.xml'
            $null = Get-Item -Path $layoutXml -ErrorAction Stop
        }
        $data.LayoutXmlPath    = $layoutXml
        $data.LayoutXmlContent = [System.IO.File]::ReadAllText($layoutXml)
    } catch { <# Intentional: layout XML not present on all systems #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

    # Taskband registry blob (binary pin data -- Windows 10/11)
    try {
        $tbKey  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        $tbProp = Get-ItemProperty -Path $tbKey -ErrorAction SilentlyContinue
        if ($tbProp -and $tbProp.Favorites) {
            $data.TaskbandData = [Convert]::ToBase64String([byte[]]$tbProp.Favorites)
        }
    } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

    return $data
}

function Get-PrintDrivers {
    <#
    .SYNOPSIS  Returns all installed print drivers with Name, DriverVersion, PrinterEnvironment, InfPath.
        .DESCRIPTION
      Detailed behaviour: Get print drivers.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    try {
        Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object {
            $result.Add(@{
                Name               = $_.Name
                DriverVersion      = $_.DriverVersion
                PrinterEnvironment = $_.PrinterEnvironment
                InfPath            = $_.InfPath
                Provider           = $_.Provider
                MajorVersion       = $_.MajorVersion
            })
        }
    } catch { Write-AppLog -Message "[UserProfileManager] PrintDrivers capture error: $_" -Level Warning }
    return $result
}

function Get-MimeTypes {
    <#
    .SYNOPSIS  Returns file-extension → MIME-type mappings from the Windows registry.
               Sources: HKLM\SOFTWARE\Classes\<ext> and HKCU\SOFTWARE\Classes\<ext>.
               User overrides (HKCU) take precedence.
        .DESCRIPTION
      Detailed behaviour: Get mime types.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    $seen   = @{}   # local to this call -- no $script: scope leak

    foreach ($hivePath in @('HKLM:\SOFTWARE\Classes', 'HKCU:\SOFTWARE\Classes')) {
        try {
            Get-ChildItem -Path $hivePath -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^\.' } |
            ForEach-Object {
                $ext  = $_.PSChildName
                $mime = (Get-ItemProperty -Path $_.PSPath -Name 'Content Type' -ErrorAction SilentlyContinue).'Content Type'
                if ($mime) { $seen[$ext] = $mime }   # HKCU runs second → overrides HKLM  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    foreach ($kv in $seen.GetEnumerator()) {
        $result.Add(@{ Extension = $kv.Key; MimeType = $kv.Value })
    }
    return ($result | Sort-Object { $_['Extension'] })
}

#  EXTENDED CAPTURE FUNCTIONS

<#
.SYNOPSIS
  Get wi fi profiles.
#>
function Get-WiFiProfiles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $raw = @(& netsh wlan show profiles 2>&1 | Where-Object { $_ -is [string] })
        foreach ($line in $raw) {
            if ($line -match 'All User Profile\s*:\s*(.+)') {
                $name   = $Matches[1].Trim()  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $detail = @(& netsh wlan show profile name="$name" key=clear 2>&1 | Where-Object { $_ -is [string] })
                # Helper: extract value after first colon from matching line (avoids Object[] from MatchInfo)
                $gf = { param($lines, $pat)
                    $mi = $lines | Select-String $pat | Select-Object -First 1
                    if ($mi) { (($mi.Line -split ':', 2)[-1]).Trim() } else { '' }
                }
                $xmlB64 = $null
                try {
                    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "upman_wlan_$([System.IO.Path]::GetRandomFileName())"
                    New-Item $tmp -ItemType Directory -Force | Out-Null
                    & netsh wlan export profile name="$name" folder=$tmp 2>&1 | Out-Null
                    $xf = Get-ChildItem $tmp -Filter '*.xml' -EA SilentlyContinue | Select-Object -First 1
                    if ($xf) { $xmlB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($xf.FullName)) }
                    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
                } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
                $result.Add(@{
                    Name             = $name
                    AuthType         = & $gf $detail 'Authentication\s*:'
                    Cipher           = & $gf $detail 'Cipher\s*:'
                    ConnectionMode   = & $gf $detail 'Connection mode\s*:'
                    AutoConnect      = & $gf $detail 'Connect auto\w*\s*:'
                    NetworkType      = & $gf $detail 'Network type\s*:'
                    ProfileXmlBase64 = $xmlB64
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] WiFiProfiles capture error: $_" -Level Warning }
    return $result
}

<#
.SYNOPSIS
  Get m r u locations.
#>
function Get-MRULocations {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        TypedPaths    = [System.Collections.Generic.List[string]]::new()
        RunMRU        = [System.Collections.Generic.List[string]]::new()
        OpenSavePaths = [System.Collections.Generic.List[hashtable]]::new()
        RecentExts    = [System.Collections.Generic.List[string]]::new()
    }
    try {
        $tp = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths'
        try {
            $null = Get-Item -Path $tp -ErrorAction Stop
            $props = Get-ItemProperty -Path $tp -ErrorAction Stop
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -match '^url\d+' } |
                Sort-Object Name | ForEach-Object { $data.TypedPaths.Add([string]$_.Value) }
            }
        } catch { <# Intentional: TypedPaths can be absent #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

        $run = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
        try {
            $null = Get-Item -Path $run -ErrorAction Stop
            $props = Get-ItemProperty -Path $run -ErrorAction Stop
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -match '^[a-z]$' } |
                Sort-Object Name | ForEach-Object { $data.RunMRU.Add(([string]$_.Value) -replace '\\1$','') }
            }
        } catch { <# Intentional: RunMRU can be absent #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

        $cs = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU'
        try {
            $null = Get-Item -Path $cs -ErrorAction Stop
        } catch {
            $cs = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedMRU'
        }
        try {
            $null = Get-Item -Path $cs -ErrorAction Stop
            $props = Get-ItemProperty -Path $cs -ErrorAction Stop
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS|^MRUList' } |
                ForEach-Object {
                    # Binary (PIDL) values produce byte[]; convert safely to avoid List.Add(2-arg) ambiguity
                    $rawVal = $_.Value
                    $strVal = if ($rawVal -is [byte[]]) { [System.BitConverter]::ToString($rawVal) } else { ([string]$rawVal).Trim("`0") }
                    $entry  = @{ Key = [string]$_.Name; Value = $strVal }
                    $data.OpenSavePaths.Add($entry)
                }
            }
        } catch { <# Intentional: ComDlg32 key may be absent #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }

        $re = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs'
        try {
            $null = Get-Item -Path $re -ErrorAction Stop
            Get-ChildItem -Path $re -ErrorAction Stop | ForEach-Object {
                if ($_.PSChildName -match '^\.\w+') { $data.RecentExts.Add($_.PSChildName) }
            }
        } catch { <# Intentional: RecentDocs can be absent #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    } catch { Write-AppLog -Message "[UserProfileManager] MRULocations capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get certificate stores.
#>
function Get-CertificateStores {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param([bool]$IncludeLocalMachine = $false)
    $data = @{
        UserStore         = [System.Collections.Generic.List[hashtable]]::new()
        LocalMachineStore = [System.Collections.Generic.List[hashtable]]::new()
    }
    $hives = @('Cert:\CurrentUser')
    if ($IncludeLocalMachine) { $hives += 'Cert:\LocalMachine' }
    foreach ($hive in $hives) {
        $list = if ($hive -eq 'Cert:\CurrentUser') { $data.UserStore } else { $data.LocalMachineStore }
        try {
            Get-ChildItem $hive -EA SilentlyContinue | ForEach-Object {
                $storeName = $_.PSChildName
                try {
                    Get-ChildItem "$hive\$storeName" -EA SilentlyContinue | ForEach-Object {
                        $list.Add(@{
                            StoreName     = $storeName
                            Thumbprint    = $_.Thumbprint
                            Subject       = $_.Subject
                            Issuer        = $_.Issuer
                            NotBefore     = $_.NotBefore.ToString('o')
                            NotAfter      = $_.NotAfter.ToString('o')
                            FriendlyName  = $_.FriendlyName
                            HasPrivateKey = $_.HasPrivateKey
                            SerialNumber  = $_.SerialNumber
                        })
                    }
                } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            }
        } catch { Write-AppLog -Message "[UserProfileManager] CertStore $hive error: $_" -Level Warning }
    }
    return $data
}

<#
.SYNOPSIS
  Get i s e configuration.
#>
function Get-ISEConfiguration {
    param()
    $data = @{
        ProfilePath       = $null
        ProfileContent    = $null
        SnippetFiles      = [System.Collections.Generic.List[hashtable]]::new()
        RegistrySettings  = [System.Collections.Generic.List[hashtable]]::new()
        AddOns            = [System.Collections.Generic.List[hashtable]]::new()
        RecentFiles       = [System.Collections.Generic.List[string]]::new()
        ISEOptionsEntries = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # Profile script
        $iseProf = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShellISE_profile.ps1'
        if (Test-Path $iseProf) {
            $data.ProfilePath    = $iseProf
            $data.ProfileContent = Get-Content $iseProf -Raw -EA SilentlyContinue
        }
        # Snippets
        $snippetDir = Join-Path $env:APPDATA 'Microsoft\Windows PowerShell\ISE\Snippets'
        if (Test-Path $snippetDir) {
            Get-ChildItem $snippetDir -Filter '*.snippets.ps1xml' -EA SilentlyContinue | ForEach-Object {
                $data.SnippetFiles.Add(@{
                    Name     = $_.Name
                    Content  = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($_.FullName))
                    Modified = $_.LastWriteTime.ToString('o')
                })
            }
        }
        # Root registry key and direct values
        $iseKey = 'HKCU:\SOFTWARE\Microsoft\PowerShell\3\PowerShellISE'
        if (Test-Path $iseKey) {
            $props = Get-ItemProperty $iseKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.RegistrySettings.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
            }
            # ISE Options sub-key (Recent Files etc.)
            $optKey = "$iseKey\Options"
            if (Test-Path $optKey) {
                $opts = Get-ItemProperty $optKey -EA SilentlyContinue
                if ($opts) {
                    $opts.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                    ForEach-Object { $data.ISEOptionsEntries.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
                }
            }
            # Recent files list stored under ISE root MRU-style values
            $rfKey = "$iseKey\RecentFiles"
            if (Test-Path $rfKey) {
                $rfProps = Get-ItemProperty $rfKey -EA SilentlyContinue
                if ($rfProps) {
                    $rfProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                    Sort-Object Name | ForEach-Object { $data.RecentFiles.Add([string]$_.Value) }
                }
            }
            # Add-On Modules registered with ISE
            $addOnKey = "$iseKey\AddOns"
            if (Test-Path $addOnKey) {
                Get-ChildItem $addOnKey -EA SilentlyContinue | ForEach-Object {
                    $ap = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                    if ($ap) {
                        $data.AddOns.Add(@{
                            Name    = $_.PSChildName
                            DllPath = [string]$ap.DllPath
                            Author  = [string]$ap.Author
                        })
                    }
                }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] ISEConfiguration capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get terminal configuration.
#>
function Get-TerminalConfiguration {
    param()
    $data = @{
        SettingsPath     = $null
        SettingsContent  = $null
        PSProfileHashes  = @{}
        ConhostSettings  = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # Windows Terminal (packaged store)
        $wtPkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Filter 'Microsoft.WindowsTerminal_*' -Directory -EA SilentlyContinue | Select-Object -First 1
        if ($wtPkg) {
            $wtSet = Join-Path $wtPkg.FullName 'LocalState\settings.json'
            if (Test-Path $wtSet) { $data.SettingsPath = $wtSet; $data.SettingsContent = Get-Content $wtSet -Raw -EA SilentlyContinue }
        }
        # Non-packaged / older installs
        if (-not $data.SettingsPath) {
            $wtAlt = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
            if (Test-Path $wtAlt) { $data.SettingsPath = $wtAlt; $data.SettingsContent = Get-Content $wtAlt -Raw -EA SilentlyContinue }
        }
        # PowerShell $PROFILE hashes
        foreach ($key in @('CurrentUserCurrentHost','CurrentUserAllHosts','AllUsersCurrentHost','AllUsersAllHosts')) {
            $path = $PROFILE.$key
            $data.PSProfileHashes[$key] = @{
                Path     = $path
                Exists   = (Test-Path $path)
                Hash     = if (Test-Path $path) { (Get-FileHash $path -Algorithm SHA256 -EA SilentlyContinue).Hash } else { $null }
                Modified = if (Test-Path $path) { (Get-Item $path).LastWriteTime.ToString('o') } else { $null }
            }
        }
        # Console host registry (colours / font)
        $ck = 'HKCU:\Console'
        if (Test-Path $ck) {
            $props = Get-ItemProperty $ck -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.ConhostSettings.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] TerminalConfiguration capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get p s help repositories.
#>
function Get-PSHelpRepositories {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        ModulePath   = @($env:PSModulePath -split ';' | Where-Object { $_ })
        Repositories = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        Get-PSRepository -EA SilentlyContinue | ForEach-Object {
            $data.Repositories.Add(@{
                Name               = $_.Name
                SourceLocation     = $_.SourceLocation
                PublishLocation    = $_.PublishLocation
                InstallationPolicy = $_.InstallationPolicy
                Trusted            = [bool]($_.InstallationPolicy -eq 'Trusted')
            })
        }
    } catch { Write-AppLog -Message "[UserProfileManager] PSHelpRepositories error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get screensaver settings.
#>
function Get-ScreensaverSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{ Enabled = $null; Secure = $null; TimeoutSecs = $null; ScreenSaver = $null }
    try {
        $key = 'HKCU:\Control Panel\Desktop'
        if (Test-Path $key) {
            $props = Get-ItemProperty $key -EA SilentlyContinue
            if ($props) {
                $data.ScreenSaver  = $props.'SCRNSAVE.EXE'
                $data.Enabled      = $props.ScreenSaveActive
                $data.Secure       = $props.ScreenSaverIsSecure
                $data.TimeoutSecs  = $props.ScreenSaveTimeOut
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] ScreensaverSettings capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get power configuration.
#>
function Get-PowerConfiguration {
    param()
    $data = @{
        ActivePlanGuid = $null
        ActivePlanName = $null
        Plans          = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        $listOut = @(& powercfg /list 2>&1 | Where-Object { $_ -is [string] })
        foreach ($line in $listOut) {
            if ($line -match 'Power Scheme GUID:\s*([\w-]+)\s*\((.+?)\)\s*(\*?)') {
                $data.Plans.Add(@{ Guid = $Matches[1].Trim(); Name = $Matches[2].Trim(); Active = ($Matches[3].Trim() -eq '*') })  # SIN-EXEMPT:P027 -- index access, context-verified safe
                if ($Matches[3].Trim() -eq '*') { $data.ActivePlanGuid = $Matches[1].Trim(); $data.ActivePlanName = $Matches[2].Trim() }  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] PowerConfiguration capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get display layout.
#>
function Get-DisplayLayout {
    param()
    $data = @{
        Monitors      = [System.Collections.Generic.List[hashtable]]::new()
        DpiRegistry   = @{}
        PerMonitorDpi = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        Get-CimInstance -ClassName Win32_VideoController -EA SilentlyContinue | ForEach-Object {
            $data.Monitors.Add(@{
                Name                        = $_.Name
                CurrentHorizontalResolution = $_.CurrentHorizontalResolution
                CurrentVerticalResolution   = $_.CurrentVerticalResolution
                CurrentRefreshRate          = $_.CurrentRefreshRate
                CurrentBitsPerPixel         = $_.CurrentBitsPerPixel
                DriverVersion               = $_.DriverVersion
            })
        }
    } catch { Write-AppLog -Message "[UserProfileManager] DisplayLayout VideoController error: $_" -Level Warning }
    try {
        $dk = 'HKCU:\Control Panel\Desktop'
        if (Test-Path $dk) {
            $p = Get-ItemProperty $dk -EA SilentlyContinue
            if ($p) {
                # These keys are absent on some Windows builds -- guard each one
                $dpiReg = @{}
                foreach ($pname in @('LogPixels','Win8DpiScaling','DpiScalingVer')) {
                    if ($null -ne $p.PSObject.Properties[$pname]) { $dpiReg[$pname] = $p.$pname }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }
                $data.DpiRegistry = $dpiReg
            }
        }
        $pmk = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
        if (Test-Path $pmk) {
            Get-ChildItem $pmk -EA SilentlyContinue | ForEach-Object {
                $mp = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                if ($mp) { $data.PerMonitorDpi.Add(@{ Monitor = $_.PSChildName; DpiValue = $mp.DpiValue }) }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] DisplayLayout DPI error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get regional settings.
#>
function Get-RegionalSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        CultureName          = $null
        CultureDisplayName   = $null
        SystemLocale         = $null
        HomeLocation         = $null
        Languages            = [System.Collections.Generic.List[hashtable]]::new()
        RegistryInternational = @{}
    }
    try { $c = Get-Culture -EA SilentlyContinue; if ($c) { $data.CultureName = $c.Name; $data.CultureDisplayName = $c.DisplayName } } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    try { $sl = Get-WinSystemLocale -EA SilentlyContinue; if ($sl) { $data.SystemLocale = $sl.Name } } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    try { $hl = Get-WinHomeLocation -EA SilentlyContinue; if ($hl) { $data.HomeLocation = "$($hl.GeoId) -- $($hl.HomeLocation)" } } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    try {
        Get-WinUserLanguageList -EA SilentlyContinue | ForEach-Object {
            $data.Languages.Add(@{ LanguageTag = $_.LanguageTag; Autonym = $_.Autonym; EnglishName = $_.EnglishName })
        }
    } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    try {
        $ik = 'HKCU:\Control Panel\International'
        if (Test-Path $ik) {
            $props = Get-ItemProperty $ik -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.RegistryInternational[$_.Name] = [string]$_.Value }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] RegionalSettings registry error: $_" -Level Warning }
    return $data
}

#  ADDITIONAL CAPTURE FUNCTIONS

<#
.SYNOPSIS
  Get environment variables.
#>
function Get-EnvironmentVariables {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        User    = [System.Collections.Generic.List[hashtable]]::new()
        Machine = [System.Collections.Generic.List[hashtable]]::new()
        Process = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        [System.Environment]::GetEnvironmentVariables('User').GetEnumerator() | Sort-Object Name |
            ForEach-Object { $data.User.Add(@{ Name = $_.Key; Value = $_.Value }) }
    } catch { Write-AppLog -Message "[UserProfileManager] EnvVars User error: $_" -Level Warning }
    try {
        [System.Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name |
            ForEach-Object { $data.Machine.Add(@{ Name = $_.Key; Value = $_.Value }) }
    } catch { Write-AppLog -Message "[UserProfileManager] EnvVars Machine error: $_" -Level Warning }
    try {
        [System.Environment]::GetEnvironmentVariables('Process').GetEnumerator() | Sort-Object Name |
            ForEach-Object { $data.Process.Add(@{ Name = $_.Key; Value = $_.Value }) }
    } catch { Write-AppLog -Message "[UserProfileManager] EnvVars Process error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get mapped drives.
#>
function Get-MappedDrives {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    try {
        Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue | Where-Object { $_.DisplayRoot -match '^\\\\' } | ForEach-Object {
            $result.Add(@{
                Drive       = "$($_.Name):"
                NetworkPath = $_.DisplayRoot
                Description = $_.Description
                Root        = $_.Root
            })
        }
        # Also check WMI for drives that may be connected/disconnected
        Get-CimInstance Win32_MappedLogicalDisk -EA SilentlyContinue | ForEach-Object {
            $disk   = $_   # capture outer $_ before Where-Object changes it
            $exists = $result | Where-Object { $_.Drive -eq $disk.DeviceID }
            if (-not $exists) {
                $result.Add(@{
                    Drive       = $disk.DeviceID
                    NetworkPath = $disk.ProviderName
                    Description = $disk.Description
                    Root        = $disk.DeviceID
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] MappedDrives capture error: $_" -Level Warning }
    return $result
}

<#
.SYNOPSIS
  Get installed fonts.
#>
function Get-InstalledFonts {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $result = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $fontKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (Test-Path $fontKey) {
            $props = Get-ItemProperty $fontKey -EA SilentlyContinue
            if ($props) {
                $fontDir = Join-Path $env:WINDIR 'Fonts'
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Sort-Object Name |
                ForEach-Object {
                    $fileName = [string]$_.Value
                    $fullPath = if ($fileName -match '^[A-Za-z]:\\') { $fileName } else { Join-Path $fontDir $fileName }
                    $result.Add(@{
                        Name     = $_.Name
                        FileName = $fileName
                        FullPath = $fullPath
                        Exists   = (Test-Path $fullPath)
                    })
                }
            }
        }
        # Per-user fonts (Windows 10 1809+)
        $userFontKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (Test-Path $userFontKey) {
            $props = Get-ItemProperty $userFontKey -EA SilentlyContinue
            if ($props) {
                $userFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Sort-Object Name |
                ForEach-Object {
                    $fileName = [string]$_.Value
                    $fullPath = if ($fileName -match '^[A-Za-z]:\\') { $fileName } else { Join-Path $userFontDir $fileName }
                    $result.Add(@{
                        Name     = "[User] $($_.Name)"
                        FileName = $fileName
                        FullPath = $fullPath
                        Exists   = (Test-Path $fullPath)
                    })
                }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] InstalledFonts capture error: $_" -Level Warning }
    return $result
}

<#
.SYNOPSIS
  Get language and speech.
#>
function Get-LanguageAndSpeech {
    param()
    $data = @{
        InstalledLanguages = [System.Collections.Generic.List[hashtable]]::new()
        SpeechRecognition  = [System.Collections.Generic.List[hashtable]]::new()
        TextToSpeech       = [System.Collections.Generic.List[hashtable]]::new()
        DictionaryFiles    = [System.Collections.Generic.List[hashtable]]::new()
        CustomDictionaries = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # Installed language packs
        $lpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages'
        if (Test-Path $lpKey) {
            Get-ChildItem $lpKey -EA SilentlyContinue | ForEach-Object {
                $lp = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                $data.InstalledLanguages.Add(@{
                    Tag       = $_.PSChildName
                    Type      = if ($lp) { [string]$lp.Type } else { '' }
                    Installed = $true
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] LanguagePacks error: $_" -Level Warning }
    try {
        # Speech recognition engines -- Language/attributes live in the Attributes sub-key
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Speech\Recognizers\Tokens'
        if (Test-Path $srKey) {
            Get-ChildItem $srKey -EA SilentlyContinue | ForEach-Object {
                $sp   = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                $attr = Get-ItemProperty (Join-Path $_.PSPath 'Attributes') -EA SilentlyContinue
                $lang = if ($attr -and $null -ne $attr.PSObject.Properties['Language']) { [string]$attr.Language }
                        elseif ($sp -and $null -ne $sp.PSObject.Properties['Language']) { [string]$sp.Language }
                        else { '' }
                $data.SpeechRecognition.Add(@{
                    Name     = if ($sp -and $null -ne $sp.PSObject.Properties['(default)']) { [string]$sp.'(default)' } else { $_.PSChildName }
                    Language = $lang
                    CLSID    = $_.PSChildName
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] SpeechRecognition error: $_" -Level Warning }
    try {
        # Text-to-speech voices -- Language/Gender are in the Attributes sub-key
        $ttsKey = 'HKLM:\SOFTWARE\Microsoft\Speech\Voices\Tokens'
        if (-not (Test-Path $ttsKey)) { $ttsKey = 'HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens' }
        if (Test-Path $ttsKey) {
            Get-ChildItem $ttsKey -EA SilentlyContinue | ForEach-Object {
                $vp   = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                $attr = Get-ItemProperty (Join-Path $_.PSPath 'Attributes') -EA SilentlyContinue
                $lang = if ($attr -and $null -ne $attr.PSObject.Properties['Language']) { [string]$attr.Language }
                        elseif ($vp -and $null -ne $vp.PSObject.Properties['Language'])  { [string]$vp.Language }
                        else { '' }
                $gend = if ($attr -and $null -ne $attr.PSObject.Properties['Gender'])   { [string]$attr.Gender }
                        elseif ($vp -and $null -ne $vp.PSObject.Properties['Gender'])    { [string]$vp.Gender }
                        else { '' }
                $data.TextToSpeech.Add(@{
                    Name     = if ($vp -and $null -ne $vp.PSObject.Properties['(default)']) { [string]$vp.'(default)' } else { $_.PSChildName }
                    Language = $lang
                    Gender   = $gend
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] TextToSpeech error: $_" -Level Warning }
    try {
        # Built-in spell-check dictionary files (Office + Windows)
        $dictDirs = @(
            (Join-Path $env:APPDATA 'Microsoft\Spelling'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Spelling'),
            (Join-Path $env:WINDIR 'System32\Speech')
        )
        foreach ($dir in $dictDirs) {
            if (Test-Path $dir) {
                Get-ChildItem $dir -Recurse -Include '*.dic','*.aff','*.lex','*.srul' -EA SilentlyContinue | ForEach-Object {
                    $data.DictionaryFiles.Add(@{
                        Name     = $_.Name
                        FullPath = $_.FullName
                        Size     = $_.Length
                        Modified = $_.LastWriteTime.ToString('o')
                    })
                }
            }
        }
        # User-added custom dictionary (Office)
        $customDictDir = Join-Path $env:APPDATA 'Microsoft\UProof'
        if (Test-Path $customDictDir) {
            Get-ChildItem $customDictDir -Include '*.dic' -Recurse -EA SilentlyContinue | ForEach-Object {
                $data.CustomDictionaries.Add(@{
                    Name    = $_.Name
                    Path    = $_.FullName
                    Content = (Get-Content $_.FullName -Raw -EA SilentlyContinue)
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] DictionaryFiles error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get quick access links.
#>
function Get-QuickAccessLinks {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        FrequentFolders = [System.Collections.Generic.List[hashtable]]::new()
        RecentFiles     = [System.Collections.Generic.List[hashtable]]::new()
        PinnedFolders   = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # Frequent folders / recent files via shell.application
        $shell = New-Object -ComObject Shell.Application -EA SilentlyContinue
        if ($shell) {
            try {
                $qa = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
                if ($qa) {
                    foreach ($item in $qa.Items()) {
                        $entry = @{ Name = $item.Name; Path = $item.Path; IsFolder = $item.IsFolder }
                        if ($item.IsFolder) { $data.FrequentFolders.Add($entry) } else { $data.RecentFiles.Add($entry) }
                    }
                }
            } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
        # Pinned Quick Access folders via lnk files in AutomaticDestinations
        $pinDir = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'
        $manDir = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations'
        foreach ($dir in @($pinDir, $manDir)) {
            if (Test-Path $dir) {
                # -Filter only accepts a single string; use Where-Object to match both extensions
                Get-ChildItem $dir -EA SilentlyContinue |
                    Where-Object { $_.Name -match '\.automaticDestinations-ms$|\.customDestinations-ms$' } |
                    ForEach-Object {
                        $data.PinnedFolders.Add(@{ File = $_.Name; Size = $_.Length; Modified = $_.LastWriteTime.ToString('o') })
                    }
            }
        }
        # HomeFolder pinned items in registry
        $qaKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HomeFolder\NameSpace'
        if (Test-Path $qaKey) {
            Get-ChildItem $qaKey -EA SilentlyContinue | ForEach-Object {
                $data.PinnedFolders.Add(@{ File = $_.PSChildName; Size = 0; Modified = '' })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] QuickAccessLinks capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get explorer folder view.
#>
function Get-ExplorerFolderView {
    param()
    $data = @{
        GeneralOptions   = @{}
        ViewOptions      = @{}
        AdvancedOptions  = [System.Collections.Generic.List[hashtable]]::new()
        BagMRU           = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # General view behaviour (show/hide hidden files, extensions, etc.)
        $advKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        if (Test-Path $advKey) {
            $props = Get-ItemProperty $advKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.AdvancedOptions.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
            }
        }
        # Folder-general options
        $goKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
        if (Test-Path $goKey) {
            $props = Get-ItemProperty $goKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.GeneralOptions[$_.Name] = [string]$_.Value }
            }
        }
        # View state stream options
        $vsKey = 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
        if (Test-Path $vsKey) {
            $props = Get-ItemProperty $vsKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.ViewOptions[$_.Name] = [string]$_.Value }
            }
        }
        # BagMRU -- per-folder remembered views (top-level names only, not binary blobs)
        $bagKey = 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\BagMRU'
        if (Test-Path $bagKey) {
            $props = Get-ItemProperty $bagKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.BagMRU.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] ExplorerFolderView capture error: $_" -Level Warning }
    return $data
}

<#
.SYNOPSIS
  Get search providers.
#>
function Get-SearchProviders {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param()
    $data = @{
        InternetExplorer  = [System.Collections.Generic.List[hashtable]]::new()
        WindowsSearch     = @{}
        CortanaSearch     = @{}
        SearchConfig      = [System.Collections.Generic.List[hashtable]]::new()
    }
    try {
        # IE/Edge legacy search scopes
        $ieScopeKey = 'HKCU:\SOFTWARE\Microsoft\Internet Explorer\SearchScopes'
        if (Test-Path $ieScopeKey) {
            $defScope = (Get-ItemProperty $ieScopeKey -EA SilentlyContinue).DefaultScope
            Get-ChildItem $ieScopeKey -EA SilentlyContinue | ForEach-Object {
                $sp = Get-ItemProperty $_.PSPath -EA SilentlyContinue
                $data.InternetExplorer.Add(@{
                    GUID        = $_.PSChildName
                    DisplayName = if ($sp) { [string]$sp.DisplayName } else { '' }
                    URL         = if ($sp) { [string]$sp.URL }         else { '' }
                    Default     = ($_.PSChildName -eq $defScope)
                    FaviconURL  = if ($sp) { [string]$sp.FaviconURL }  else { '' }
                })
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] SearchProviders IE error: $_" -Level Warning }
    try {
        # Windows Search indexing settings
        $wsKey = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
        if (Test-Path $wsKey) {
            $props = Get-ItemProperty $wsKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.WindowsSearch[$_.Name] = [string]$_.Value }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] SearchProviders WindowsSearch error: $_" -Level Warning }
    try {
        # Cortana / Windows Search user preferences
        $cKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
        if (Test-Path $cKey) {
            $props = Get-ItemProperty $cKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.CortanaSearch[$_.Name] = [string]$_.Value }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] SearchProviders Cortana error: $_" -Level Warning }
    try {
        # Additional search config under Explorer
        $ecKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Search\PrimaryProperties'
        if (Test-Path $ecKey) {
            $props = Get-ItemProperty $ecKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { $data.SearchConfig.Add(@{ Name = $_.Name; Value = [string]$_.Value }) }
            }
        }
    } catch { Write-AppLog -Message "[UserProfileManager] SearchProviders Explorer config error: $_" -Level Warning }
    return $data
}

#  PROFILE SNAPSHOT ORCHESTRATION

function Get-ProfileSnapshot {
    <#
    .SYNOPSIS  Captures all profile components and returns a structured snapshot.
    .PARAMETER ProfileName             Friendly name stored in the profile metadata.
    .PARAMETER ProgressCallback        Optional [scriptblock] called with (int $Percent, string $Status).
    .PARAMETER IncludeLocalMachineCerts When $true, also captures the LocalMachine certificate store.
        .DESCRIPTION
      Detailed behaviour: Get profile snapshot.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProgressCallback', Justification='Captured by closure inside nested Invoke-Progress function; PSSA does not trace closure capture.')]
    param(
        [string]      $ProfileName             = 'Profile',
        [scriptblock] $ProgressCallback        = $null,
        [bool]        $IncludeLocalMachineCerts = $false
    )

    function Invoke-Progress {
        param([int]$Pct, [string]$Msg)
        Write-Verbose "[Snapshot $Pct%] $Msg"
        if ($ProgressCallback) { & $ProgressCallback $Pct $Msg }
    }

    Invoke-Progress 0 'Starting snapshot...'

    $snapshot = [ordered]@{
        Meta = [ordered]@{
            SchemaVersion             = $script:ProfileSchemaVersion
            ProfileName               = $ProfileName
            CapturedBy                = $env:USERNAME
            CapturedOn                = (Get-Date).ToString('o')
            MachineName               = $env:COMPUTERNAME
            Encrypted                 = $false
            EncryptionSalt            = $null
            IncludesLocalMachineCerts = $IncludeLocalMachineCerts
        }
        Data = [ordered]@{
            WingetApplications    = $null
            PSEnvironment         = $null
            UserAppConfigs        = $null
            TaskbarLayout         = $null
            PrintDrivers          = $null
            MimeTypes             = $null
            WiFiProfiles          = $null
            MRULocations          = $null
            Certificates          = $null
            ISEConfiguration      = $null
            TerminalConfiguration = $null
            PSHelpRepositories    = $null
            ScreensaverSettings   = $null
            PowerConfiguration    = $null
            DisplayLayout         = $null
            RegionalSettings      = $null
            EnvironmentVariables  = $null
            MappedDrives          = $null
            InstalledFonts        = $null
            LanguageAndSpeech     = $null
            QuickAccessLinks      = $null
            ExplorerFolderView    = $null
            SearchProviders       = $null
        }
    }

    Invoke-Progress  4 'Capturing winget applications...'
    $snapshot.Data.WingetApplications = Get-WingetApplications

    Invoke-Progress 12 'Capturing PowerShell environment...'
    $snapshot.Data.PSEnvironment = Get-PSEnvironment

    Invoke-Progress 19 'Capturing user app configs...'
    $snapshot.Data.UserAppConfigs = Get-UserAppConfigs

    Invoke-Progress 24 'Capturing taskbar layout...'
    $snapshot.Data.TaskbarLayout = Get-TaskbarLayout

    Invoke-Progress 29 'Capturing print drivers...'
    $snapshot.Data.PrintDrivers = Get-PrintDrivers

    Invoke-Progress 33 'Capturing MIME types...'
    $snapshot.Data.MimeTypes = Get-MimeTypes

    Invoke-Progress 38 'Capturing WiFi profiles...'
    $snapshot.Data.WiFiProfiles = Get-WiFiProfiles

    Invoke-Progress 43 'Capturing MRU / recent file locations...'
    $snapshot.Data.MRULocations = Get-MRULocations

    Invoke-Progress 49 'Capturing certificate stores...'
    $snapshot.Data.Certificates = Get-CertificateStores -IncludeLocalMachine $IncludeLocalMachineCerts

    Invoke-Progress 54 'Capturing ISE configuration...'
    $snapshot.Data.ISEConfiguration = Get-ISEConfiguration

    Invoke-Progress 60 'Capturing terminal configuration...'
    $snapshot.Data.TerminalConfiguration = Get-TerminalConfiguration

    Invoke-Progress 65 'Capturing PS help repositories...'
    $snapshot.Data.PSHelpRepositories = Get-PSHelpRepositories

    Invoke-Progress 70 'Capturing screensaver settings...'
    $snapshot.Data.ScreensaverSettings = Get-ScreensaverSettings

    Invoke-Progress 75 'Capturing power configuration...'
    $snapshot.Data.PowerConfiguration = Get-PowerConfiguration

    Invoke-Progress 82 'Capturing display layout...'
    $snapshot.Data.DisplayLayout = Get-DisplayLayout

    Invoke-Progress 90 'Capturing regional & language settings...'
    $snapshot.Data.RegionalSettings = Get-RegionalSettings

    Invoke-Progress 92 'Capturing environment variables...'
    $snapshot.Data.EnvironmentVariables = Get-EnvironmentVariables

    Invoke-Progress 94 'Capturing mapped drives...'
    $snapshot.Data.MappedDrives = Get-MappedDrives

    Invoke-Progress 95 'Capturing installed fonts...'
    $snapshot.Data.InstalledFonts = Get-InstalledFonts

    Invoke-Progress 96 'Capturing language & speech configuration...'
    $snapshot.Data.LanguageAndSpeech = Get-LanguageAndSpeech

    Invoke-Progress 97 'Capturing Quick Access links...'
    $snapshot.Data.QuickAccessLinks = Get-QuickAccessLinks

    Invoke-Progress 98 'Capturing Explorer folder view settings...'
    $snapshot.Data.ExplorerFolderView = Get-ExplorerFolderView

    Invoke-Progress 99 'Capturing search providers...'
    $snapshot.Data.SearchProviders = Get-SearchProviders

    Invoke-Progress 100 'Snapshot complete.'
    return $snapshot
}

#  SAVE / LOAD

function Save-ProfileSnapshot {
    <#
    .SYNOPSIS  Serializes a snapshot to disk. Optionally encrypts the Data block.
    .PARAMETER Snapshot    The hashtable returned by Get-ProfileSnapshot.
    .PARAMETER OutputPath  File system path for the output .upjson file.
    .PARAMETER Encrypt     If $true, the Data block is AES-256-PBKDF2 encrypted.
    .PARAMETER Password    Required when Encrypt = $true.  Pass as [SecureString].
    .PARAMETER IsRollback  When $true, uses AutoRollback self-contained encryption (no password prompt).
        .DESCRIPTION
      Detailed behaviour: Save profile snapshot.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]  $Snapshot,
        [Parameter(Mandatory)] [string]     $OutputPath,
        [bool]          $Encrypt    = $false,
        [securestring]  $Password   = $null,
        [bool]          $IsRollback = $false
    )

    $snapshotCopy = $Snapshot.Clone()   # shallow -- Data refs intact

    if ($Encrypt -or $IsRollback) {
        if ($IsRollback) {
            $plainPwd = Get-AutoRollbackPassword -ProfileName $snapshotCopy.Meta.ProfileName
        } else {
            if ($null -eq $Password) { throw 'Password is required when Encrypt=$true.' }
            $bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        $dataJson  = $snapshotCopy.Data | ConvertTo-Json -Depth 20 -Compress
        $encResult = Protect-ProfileData -PlainText $dataJson -Password $plainPwd
        $snapshotCopy.Meta.Encrypted      = $true
        $snapshotCopy.Meta.EncryptionSalt = $encResult.Salt
        if ($IsRollback) {
            $snapshotCopy.Meta.RollbackAutoKey = $true
        }
        $snapshotCopy.Data = $encResult.CipherText   # replace Data hashtable with cipher string
    }

    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $snapshotCopy | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "[UserProfileManager] Profile saved: $OutputPath"
}

function Import-ProfileSnapshot {
    <#
    .SYNOPSIS  Loads a .upjson file and optionally decrypts the Data block.
    .PARAMETER FilePath   Path to the .upjson file.
    .PARAMETER Password   SecureString if the file is user-encrypted. Not needed for rollbacks.
    .OUTPUTS   [hashtable] Snapshot with decrypted Data (as hashtable, not raw JSON string).
        .DESCRIPTION
      Detailed behaviour: Import profile snapshot.
    #>
    param(
        [Parameter(Mandatory)] [string]    $FilePath,
        [securestring]                     $Password = $null
    )

    if (-not (Test-Path $FilePath)) { throw "Profile file not found: $FilePath" }

    $raw      = Get-Content -Path $FilePath -Raw -Encoding UTF8
    $snapshot = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop

    if ($snapshot.Meta.Encrypted) {
        if ($snapshot.Meta.RollbackAutoKey) {
            $plainPwd = Get-AutoRollbackPassword -ProfileName $snapshot.Meta.ProfileName
        } else {
            if ($null -eq $Password) {
                throw 'ENCRYPTED:This profile is encrypted. A password is required to open it.'
            }
            $bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $decrypted     = Unprotect-ProfileData -CipherText $snapshot.Data -Salt $snapshot.Meta.EncryptionSalt -Password $plainPwd
        $snapshot.Data = $decrypted | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    return $snapshot
}

#  COMPARISON

function Compare-ProfileSnapshot {
    <#
    .SYNOPSIS  Compares a saved (reference) snapshot against a live current snapshot.
    .PARAMETER ReferenceSnapshot  Loaded snapshot hashtable (from Import-ProfileSnapshot).
    .PARAMETER CurrentSnapshot   Snapshot hashtable (from Get-ProfileSnapshot).
    .OUTPUTS   [hashtable] Diff report with Added, Removed, Changed lists per category.
        .DESCRIPTION
      Detailed behaviour: Compare profile snapshot.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $ReferenceSnapshot,
        [Parameter(Mandatory)] [hashtable] $CurrentSnapshot
    )

    $report = [ordered]@{
        GeneratedOn       = (Get-Date).ToString('o')
        ReferenceProfile  = $ReferenceSnapshot.Meta.ProfileName
        ReferenceCaptured = $ReferenceSnapshot.Meta.CapturedOn
        CurrentUser       = $env:USERNAME
        CurrentMachine    = $env:COMPUTERNAME
        WingetApps        = Compare-WingetLists    $ReferenceSnapshot.Data.WingetApplications $CurrentSnapshot.Data.WingetApplications
        PSModules         = Compare-PSModuleLists  $ReferenceSnapshot.Data.PSEnvironment.InstalledModules $CurrentSnapshot.Data.PSEnvironment.InstalledModules
        PSVersion         = @{
            Reference = $ReferenceSnapshot.Data.PSEnvironment.PSVersion
            Current   = $CurrentSnapshot.Data.PSEnvironment.PSVersion
            Changed   = $ReferenceSnapshot.Data.PSEnvironment.PSVersion -ne $CurrentSnapshot.Data.PSEnvironment.PSVersion
        }
        PrintDrivers      = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.PrintDrivers -Cur $CurrentSnapshot.Data.PrintDrivers -Key 'Name'
        MimeTypes         = Compare-MimeLists      $ReferenceSnapshot.Data.MimeTypes $CurrentSnapshot.Data.MimeTypes
        TaskbarPins       = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.TaskbarLayout.PinnedItems -Cur $CurrentSnapshot.Data.TaskbarLayout.PinnedItems -Key 'Name'
        ConfigFiles       = Compare-ConfigFileLists $ReferenceSnapshot.Data.UserAppConfigs.ConfigFiles $CurrentSnapshot.Data.UserAppConfigs.ConfigFiles
        WiFiProfiles      = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.WiFiProfiles -Cur $CurrentSnapshot.Data.WiFiProfiles -Key 'Name'
        Certificates      = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.Certificates.UserStore -Cur $CurrentSnapshot.Data.Certificates.UserStore -Key 'Thumbprint'
        PSHelpRepos       = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.PSHelpRepositories.Repositories -Cur $CurrentSnapshot.Data.PSHelpRepositories.Repositories -Key 'Name'
        ISESettings       = Compare-SimpleLists -Ref $ReferenceSnapshot.Data.ISEConfiguration.RegistrySettings -Cur $CurrentSnapshot.Data.ISEConfiguration.RegistrySettings -Key 'Name'
        RegionalChanged   = Compare-FlatMap        $ReferenceSnapshot.Data.RegionalSettings.RegistryInternational $CurrentSnapshot.Data.RegionalSettings.RegistryInternational
        DisplayChanged    = Compare-FlatMap        $ReferenceSnapshot.Data.DisplayLayout.DpiRegistry $CurrentSnapshot.Data.DisplayLayout.DpiRegistry
        ScreensaverChanged= Compare-FlatMap        $ReferenceSnapshot.Data.ScreensaverSettings $CurrentSnapshot.Data.ScreensaverSettings
        PowerChanged      = Compare-FlatMap        $ReferenceSnapshot.Data.PowerConfiguration $CurrentSnapshot.Data.PowerConfiguration
        TerminalChanged   = @{
            Changed = @(if ($ReferenceSnapshot.Data.TerminalConfiguration.SettingsContent -ne $CurrentSnapshot.Data.TerminalConfiguration.SettingsContent) {
                @{ Key = 'settings.json content'; RefValue = $ReferenceSnapshot.Data.TerminalConfiguration.SettingsPath; CurValue = $CurrentSnapshot.Data.TerminalConfiguration.SettingsPath }
            })
        }
    }
    return $report
}

# -- Comparison helpers -------------------------------------------------------

function Compare-FlatMap {
    <#  Compares two flat hashtables and returns which scalar keys changed.  #>
    param($Ref, $Cur)
    $result = @{ Changed = @() }
    if (-not $Ref -or -not $Cur) { return $result }
    $refHt = if ($Ref -is [hashtable]) { $Ref } else { @{} }
    $curHt = if ($Cur -is [hashtable]) { $Cur } else { @{} }
    $allKeys = @(@($refHt.Keys) + @($curHt.Keys)) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        $rv = $refHt[$k]; $cv = $curHt[$k]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        # Skip arrays and nested hashtables -- only compare scalars
        if ($rv -is [System.Collections.ICollection] -or $rv -is [hashtable]) { continue }
        if ($cv -is [System.Collections.ICollection] -or $cv -is [hashtable]) { continue }
        $rvs = if ($null -eq $rv) { '' } else { [string]$rv }
        $cvs = if ($null -eq $cv) { '' } else { [string]$cv }
        if ($rvs -ne $cvs) { $result.Changed += @{ Key = $k; RefValue = $rvs; CurValue = $cvs } }
    }
    return $result
}

function Compare-WingetLists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param($Ref, $Cur)
    $result = @{ Added = @(); Removed = @(); Changed = @() }
    $refMap = @{}; foreach ($app in $Ref)  { $refMap[$app.Id] = $app }
    $curMap = @{}; foreach ($app in $Cur)  { $curMap[$app.Id] = $app }

    foreach ($id in $refMap.Keys) {
        if (-not $curMap.ContainsKey($id)) { $result.Removed += $refMap[$id] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        elseif ($refMap[$id].Version -ne $curMap[$id].Version) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $result.Changed += @{ Id = $id; RefVersion = $refMap[$id].Version; CurVersion = $curMap[$id].Version }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
    }
    foreach ($id in $curMap.Keys) {
        if (-not $refMap.ContainsKey($id)) { $result.Added += $curMap[$id] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return $result
}

function Compare-PSModuleLists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param($Ref, $Cur)
    $result = @{ Added = @(); Removed = @(); Changed = @() }
    if (-not $Ref) { $Ref = @() }
    if (-not $Cur) { $Cur = @() }
    $refMap = @{}; foreach ($m in $Ref) { $refMap["$($m.Name)::$($m.Version)"] = $m }
    $curMap = @{}; foreach ($m in $Cur) { $curMap["$($m.Name)::$($m.Version)"] = $m }

    $refNames = @{}; foreach ($m in $Ref) { $refNames[$m.Name] = $m.Version }
    $curNames = @{}; foreach ($m in $Cur) { $curNames[$m.Name] = $m.Version }

    foreach ($name in $refNames.Keys) {
        if (-not $curNames.ContainsKey($name)) { $result.Removed += @{ Name = $name; Version = $refNames[$name] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        elseif ($refNames[$name] -ne $curNames[$name]) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $result.Changed += @{ Name = $name; RefVersion = $refNames[$name]; CurVersion = $curNames[$name] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
    }
    foreach ($name in $curNames.Keys) {
        if (-not $refNames.ContainsKey($name)) { $result.Added += @{ Name = $name; Version = $curNames[$name] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return $result
}

function Compare-SimpleLists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param($Ref, $Cur, [string]$Key)
    $result = @{ Added = @(); Removed = @() }
    if (-not $Ref) { $Ref = @() }
    if (-not $Cur) { $Cur = @() }
    $refSet = @{}; foreach ($item in $Ref) { $refSet[$item[$Key]] = $item }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $curSet = @{}; foreach ($item in $Cur) { $curSet[$item[$Key]] = $item }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    foreach ($k in $refSet.Keys) { if (-not $curSet.ContainsKey($k)) { $result.Removed += $refSet[$k] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    foreach ($k in $curSet.Keys) { if (-not $refSet.ContainsKey($k)) { $result.Added   += $curSet[$k]  } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    return $result
}

function Compare-MimeLists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param($Ref, $Cur)
    $result = @{ Added = @(); Removed = @(); Changed = @() }
    if (-not $Ref) { $Ref = @() }
    if (-not $Cur) { $Cur = @() }
    $refMap = @{}; foreach ($m in $Ref) { $refMap[$m.Extension] = $m.MimeType }
    $curMap = @{}; foreach ($m in $Cur) { $curMap[$m.Extension] = $m.MimeType }
    foreach ($ext in $refMap.Keys) {
        if (-not $curMap.ContainsKey($ext)) { $result.Removed += @{ Extension = $ext; MimeType = $refMap[$ext] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        elseif ($refMap[$ext] -ne $curMap[$ext]) { $result.Changed += @{ Extension = $ext; RefMime = $refMap[$ext]; CurMime = $curMap[$ext] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    foreach ($ext in $curMap.Keys) {
        if (-not $refMap.ContainsKey($ext)) { $result.Added += @{ Extension = $ext; MimeType = $curMap[$ext] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return $result
}

function Compare-ConfigFileLists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns a collection or aggregate; plural noun is semantically clearer than singular for these collection/list/settings/metrics APIs. Renaming would require alias bridges across many call sites.')]
    param($Ref, $Cur)
    $result = @{ Added = @(); Removed = @(); Modified = @() }
    if (-not $Ref) { $Ref = @() }
    if (-not $Cur) { $Cur = @() }
    $refMap = @{}; foreach ($f in $Ref) { $refMap[$f.Path] = $f }
    $curMap = @{}; foreach ($f in $Cur) { $curMap[$f.Path] = $f }
    foreach ($path in $refMap.Keys) {
        if (-not $curMap.ContainsKey($path)) { $result.Removed += $refMap[$path] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        elseif ($refMap[$path].Hash -ne $curMap[$path].Hash) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $result.Modified += @{ Path = $path; RefHash = $refMap[$path].Hash; CurHash = $curMap[$path].Hash; RefModified = $refMap[$path].Modified; CurModified = $curMap[$path].Modified }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
    }
    foreach ($path in $curMap.Keys) {
        if (-not $refMap.ContainsKey($path)) { $result.Added += $curMap[$path] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return $result
}

#  RESTORE

function Restore-ProfileSnapshot {
    <#
    .SYNOPSIS  Restores items from a reference snapshot onto the current machine.
               ALWAYS captures and auto-encrypts a rollback snapshot first.
    .PARAMETER ReferenceSnapshot  Loaded snapshot.
    .PARAMETER ProfileStorePath   Root folder where profiles and rollbacks are stored.
    .PARAMETER Options            [hashtable] Keys: RestoreWinget, RestorePSModules,
                                  RestoreTaskbar, RestoreMimeTypes, RestoreConfigFiles.
                                  Default: all $true except RestoreConfigFiles ($false).
    .PARAMETER ProgressCallback   Optional scriptblock(int pct, string msg).
    .OUTPUTS   [hashtable] Result: RollbackPath, Restored (list of actions), Skipped, Errors.
        .DESCRIPTION
      Detailed behaviour: Restore profile snapshot.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProgressCallback', Justification='Captured by closure inside nested Invoke-Progress function; PSSA does not trace closure capture.')]
    param(
        [Parameter(Mandatory)] [hashtable]  $ReferenceSnapshot,
        [Parameter(Mandatory)] [string]     $ProfileStorePath,
        [hashtable]    $Options = @{},
        [scriptblock]  $ProgressCallback = $null
    )

    $defaultOptions = @{
        RestoreWinget      = $true
        RestorePSModules   = $true
        RestoreTaskbar     = $true
        RestoreMimeTypes   = $true
        RestoreConfigFiles = $false   # off by default: destructive
    }
    foreach ($k in $defaultOptions.Keys) { if (-not $Options.ContainsKey($k)) { $Options[$k] = $defaultOptions[$k] } }  # SIN-EXEMPT:P027 -- index access, context-verified safe

    function Invoke-Progress {
        param([int]$Pct, [string]$Msg)
        Write-Verbose "[Restore $Pct%] $Msg"
        if ($ProgressCallback) { & $ProgressCallback $Pct $Msg }
    }

    $result = @{
        RollbackPath = $null
        Restored     = [System.Collections.Generic.List[string]]::new()
        Skipped      = [System.Collections.Generic.List[string]]::new()
        Errors       = [System.Collections.Generic.List[string]]::new()
    }

    # ── STEP 1: Capture rollback BEFORE making any changes ──────────────────
    Invoke-Progress 2 'Capturing rollback snapshot (auto-encrypted)...'
    try {
        $rollbackName = "$($ReferenceSnapshot.Meta.ProfileName)-ROLLBACK-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $rollbackDir  = Join-Path $ProfileStorePath $script:RollbackSubDir
        if (-not (Test-Path $rollbackDir)) { New-Item -ItemType Directory -Path $rollbackDir -Force | Out-Null }
        $rollbackFile = Join-Path $rollbackDir "$rollbackName$script:ProfileFileExt"

        $rollbackSnap = Get-ProfileSnapshot -ProfileName $rollbackName -ProgressCallback {
            param($p, $m)
            # Map 0-100 to roughly 2-20 in the outer progress
            Invoke-Progress ([Math]::Round(2 + $p * 0.18)) "Rollback capture: $m"
        }
        Save-ProfileSnapshot -Snapshot $rollbackSnap -OutputPath $rollbackFile -IsRollback $true
        $result.RollbackPath = $rollbackFile
        Invoke-Progress 22 "Rollback saved: $rollbackFile"
    } catch {
        # Rollback failure is critical -- abort restore
        throw "ROLLBACK_FAILED: Cannot proceed -- rollback capture failed: $_"
    }

    # ── STEP 2: Restore winget applications ─────────────────────────────────
    if ($Options.RestoreWinget) {
        Invoke-Progress 25 'Restoring winget applications...'
        try {
            $currentApps = (Get-WingetApplications) | ForEach-Object { $_['Id'] }
            foreach ($app in $ReferenceSnapshot.Data.WingetApplications) {
                if ($app.Id -notin $currentApps -and $app.Source -eq 'winget') {
                    try {
                        & winget install --id $app.Id --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                        $result.Restored.Add("winget: installed $($app.Id) v$($app.Version)")
                    } catch {
                        $result.Errors.Add("winget: failed to install $($app.Id): $_")
                    }
                }
            }
        } catch { $result.Errors.Add("WingetRestore: $_") }
    } else { $result.Skipped.Add('WingetApplications') }

    # ── STEP 3: Restore PS modules ───────────────────────────────────────────
    Invoke-Progress 45 'Restoring PowerShell modules...'
    if ($Options.RestorePSModules) {
        try {
            $currentMods = (Get-Module -ListAvailable -ErrorAction SilentlyContinue) |
                           Select-Object -ExpandProperty Name -Unique
            foreach ($mod in $ReferenceSnapshot.Data.PSEnvironment.InstalledModules) {
                if ($mod.Name -notin $currentMods) {
                    try {
                        Install-Module -Name $mod.Name -RequiredVersion $mod.Version `
                            -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop 2>&1 | Out-Null
                        $result.Restored.Add("PSModule: installed $($mod.Name) v$($mod.Version)")
                    } catch {
                        $result.Errors.Add("PSModule: failed to install $($mod.Name): $_")
                    }
                }
            }
        } catch { $result.Errors.Add("PSModuleRestore: $_") }
    } else { $result.Skipped.Add('PSModules') }

    # ── STEP 4: Restore taskbar layout ──────────────────────────────────────
    Invoke-Progress 65 'Restoring taskbar layout...'
    if ($Options.RestoreTaskbar) {
        try {
            $tb = $ReferenceSnapshot.Data.TaskbarLayout
            # Restore .lnk pin files
            $taskbarPinDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
            if (-not (Test-Path $taskbarPinDir)) { New-Item -ItemType Directory -Path $taskbarPinDir -Force | Out-Null }
            foreach ($pin in $tb.PinnedItems) {
                $dest = Join-Path $taskbarPinDir $pin.Name
                if (-not (Test-Path $dest)) {
                    [System.IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String($pin.LnkBase64))
                    $result.Restored.Add("Taskbar pin: $($pin.Name)")
                }
            }
            # Restore LayoutModification.xml if captured
            if ($tb.LayoutXmlContent -and $tb.LayoutXmlPath) {
                [System.IO.File]::WriteAllText($tb.LayoutXmlPath, $tb.LayoutXmlContent)
                $result.Restored.Add("Taskbar LayoutModification.xml restored")
            }
            # Restore Taskband registry blob
            if ($tb.TaskbandData) {
                $tbKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
                if (-not (Test-Path $tbKey)) { New-Item -Path $tbKey -Force | Out-Null }
                Set-ItemProperty -Path $tbKey -Name 'Favorites' -Value ([Convert]::FromBase64String($tb.TaskbandData)) -Type Binary
                $result.Restored.Add("Taskband registry blob restored")
            }
        } catch { $result.Errors.Add("TaskbarRestore: $_") }
    } else { $result.Skipped.Add('TaskbarLayout') }

    # ── STEP 5: Restore MIME types ───────────────────────────────────────────
    Invoke-Progress 80 'Restoring MIME type associations...'
    if ($Options.RestoreMimeTypes) {
        try {
            foreach ($mime in $ReferenceSnapshot.Data.MimeTypes) {
                $regPath = "HKCU:\SOFTWARE\Classes\$($mime.Extension)"
                if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                Set-ItemProperty -Path $regPath -Name 'Content Type' -Value $mime.MimeType -Force
                $result.Restored.Add("MIME: $($mime.Extension) → $($mime.MimeType)")
            }
        } catch { $result.Errors.Add("MimeTypeRestore: $_") }
    } else { $result.Skipped.Add('MimeTypes') }

    # ── STEP 6: Restore config files ─────────────────────────────────────────
    Invoke-Progress 92 'Restoring config files...'
    if ($Options.RestoreConfigFiles) {
        # NOTE: This requires the original file data to be embedded in the snapshot.
        # Current snapshot only stores metadata/hash, not file content.
        # Restoration logs the paths that differ but cannot copy bytes without full backup.
        $result.Skipped.Add('ConfigFiles -- content not embedded in snapshot; manual restore required.')
    } else { $result.Skipped.Add('ConfigFiles (disabled)') }

    Invoke-Progress 100 'Restore complete.'
    return $result
}

#  PROFILE STORE HELPERS

function Get-ProfileList {
    <#
    .SYNOPSIS  Returns a list of profile .upjson files found in the given store folder.
               Includes basic metadata from each file's Meta block (no decryption needed).
        .DESCRIPTION
      Detailed behaviour: Get profile list.
    #>
    param([Parameter(Mandatory)] [string] $ProfileStorePath)
    $files = @()
    if (-not (Test-Path $ProfileStorePath)) { return $files }
    Get-ChildItem -Path $ProfileStorePath -Filter "*$script:ProfileFileExt" -File -Recurse:$false |
    ForEach-Object {
        try {
            $raw  = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $files += [PSCustomObject]@{
                FileName    = $_.Name
                FilePath    = $_.FullName
                ProfileName = $raw.Meta.ProfileName
                CapturedBy  = $raw.Meta.CapturedBy
                CapturedOn  = $raw.Meta.CapturedOn
                MachineName = $raw.Meta.MachineName
                Encrypted   = $raw.Meta.Encrypted
                IsRollback  = [bool]($raw.Meta.RollbackAutoKey)
                FileSize    = $_.Length
            }
        } catch {
            $files += [PSCustomObject]@{
                FileName    = $_.Name
                FilePath    = $_.FullName
                ProfileName = '(unreadable)'
                CapturedBy  = ''
                CapturedOn  = ''
                MachineName = ''
                Encrypted   = $false
                IsRollback  = $false
                FileSize    = $_.Length
            }
        }
    }
    return $files
}

#  EXPORTS

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
    'Get-WingetApplications',
    'Get-PSEnvironment',
    'Get-UserAppConfigs',
    'Get-TaskbarLayout',
    'Get-PrintDrivers',
    'Get-MimeTypes',
    'Get-WiFiProfiles',
    'Get-MRULocations',
    'Get-CertificateStores',
    'Get-ISEConfiguration',
    'Get-TerminalConfiguration',
    'Get-PSHelpRepositories',
    'Get-ScreensaverSettings',
    'Get-PowerConfiguration',
    'Get-DisplayLayout',
    'Get-RegionalSettings',
    'Get-EnvironmentVariables',
    'Get-MappedDrives',
    'Get-InstalledFonts',
    'Get-LanguageAndSpeech',
    'Get-QuickAccessLinks',
    'Get-ExplorerFolderView',
    'Get-SearchProviders',
    'Get-ProfileSnapshot',
    'Protect-ProfileData',
    'Unprotect-ProfileData',
    'Save-ProfileSnapshot',
    'Import-ProfileSnapshot',
    'Compare-ProfileSnapshot',
    'Restore-ProfileSnapshot',
    'Get-ProfileList'
)













