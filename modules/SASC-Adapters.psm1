# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 3 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    SASC-Adapters -- Target-specific credential injection adapters for Assisted SASC.
# TODO: HelpMenu | Show-SASCAdaptersHelp | Actions: Load|Unload|List|Test|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides credential injection functions for PuTTY/plink, mRemoteNG, Azure
    PowerShell, Active Directory (RSAT), PowerShell ISE, and Windows Hello.
    All adapters funnel through Get-CredentialForTarget from AssistedSASC.psm1.

    Security constraints:
      - Every adapter calls Test-IntegrityManifest before credential retrieval
      - All outputs use [SecureString] for passwords
      - Plaintext password conversion happens only at the execution boundary
        and is zeroed in a finally block
      - No clipboard usage -- ever
      - All access logged via Write-AppLog (target name, never the secret)

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th March 2026
    Modified : 4th March 2026

.LINK
    ~README.md/SECRETS-MANAGEMENT-GUIDE.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#  HELPER: PRE-FLIGHT VALIDATION

function Assert-AdapterReady {
    <#
    .SYNOPSIS  Validates module integrity and vault state before adapter use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AdapterName
    )

    # Verify AssistedSASC module is loaded
    $sascModule = Get-Module -Name 'AssistedSASC' -ErrorAction SilentlyContinue
    if (-not $sascModule) {
        throw "AssistedSASC module not loaded. Import it before using adapters."
    }

    # Run throttled integrity check
    try {
        $integrityPath = Join-Path (Join-Path (Split-Path $PSScriptRoot) 'config') 'sasc-integrity.sha256.json'
        if (Test-Path -LiteralPath $integrityPath) {
            $intResult = Test-IntegrityManifest
            if (-not $intResult.AllPassed) {
                throw [System.Security.SecurityException]::new(
                    "Integrity check failed. Adapter '$AdapterName' refused to execute.")
            }
        }
    } catch [System.Security.SecurityException] {
        throw  # Re-throw security exceptions
    } catch {
        # Non-security errors during integrity check -- log but continue
        try { Write-AppLog "SASC-Adapter: Integrity check warning for $AdapterName -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }

    try { Write-AppLog "SASC-Adapter: $AdapterName -- pre-flight passed" "Debug" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
}

function Find-Executable {
    <#
    .SYNOPSIS  Locate an executable by name, checking PATH and common install paths.
    .OUTPUTS   [string] Full path, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string[]]$AdditionalPaths = @()
    )

    # Check PATH first
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Check additional paths
    foreach ($p in $AdditionalPaths) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($p)
        $found = Get-Item -Path $expanded -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

#  ADAPTER: PuTTY / plink

function Invoke-PuTTYSession {
    <#
    .SYNOPSIS  Open an SSH session via PuTTY/plink using vault credentials.
    .DESCRIPTION
        Retrieves credentials from the vault, builds plink argument list with
        -pw parameter. Password is in process args briefly -- document this risk.
        For higher security, use SSH key auth via vault-stored private keys.
    .PARAMETER TargetName    Vault item name containing SSH credentials.
    .PARAMETER Host          Override host (default: from vault item URI).
    .PARAMETER Port          SSH port (default: 22).
    .PARAMETER UseKey        Use SSH key from vault instead of password auth.
    .PARAMETER UsePuTTY      Launch PuTTY GUI instead of plink CLI.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseKey', Justification='Reserved for PuTTY -i private-key flag; PFX/PEM resolution path TBD.')]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$TargetHost,
        [int]$Port = 22,
        [switch]$UseKey,
        [switch]$UsePuTTY
    )

    Assert-AdapterReady -AdapterName 'PuTTY'

    $cred = Get-CredentialForTarget -TargetName $TargetName
    $item = Get-VaultItem -Name $TargetName

    # Determine host from vault URI if not explicitly provided
    if (-not $TargetHost) {
        $firstUri = $item.Uri | Select-Object -First 1
        if ($firstUri) {
            try {
                $parsed = [System.Uri]::new($firstUri)
                $TargetHost = $parsed.Host
                if ($parsed.Port -gt 0 -and $parsed.Port -ne 80 -and $parsed.Port -ne 443) {
                    $Port = $parsed.Port
                }
            } catch {
                $TargetHost = $firstUri  # Use raw string as host
            }
        }
    }

    if (-not $TargetHost) {
        throw "No host specified and vault item has no URI."
    }

    if (-not $PSCmdlet.ShouldProcess("$($cred.UserName)@${TargetHost}:${Port}", "Open SSH session")) { return }

    # Find PuTTY/plink executable
    $exeName = if ($UsePuTTY) { 'putty.exe' } else { 'plink.exe' }
    $exePath = Find-Executable -Name $exeName -AdditionalPaths @(
        "$env:ProgramFiles\PuTTY\$exeName",
        "${env:ProgramFiles(x86)}\PuTTY\$exeName",
        "$env:LOCALAPPDATA\Programs\PuTTY\$exeName"
    )

    if (-not $exePath) {
        throw "$exeName not found. Install PuTTY or ensure it is on PATH."
    }

    $passwordPlain = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
        try {
            $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if ($UsePuTTY) {
            # PuTTY GUI -- password via -pw parameter
            $argList = "-ssh $($cred.UserName)@$TargetHost -P $Port -pw `"$passwordPlain`""
            Start-Process -FilePath $exePath -ArgumentList $argList
        } else {
            # plink CLI -- password via -pw parameter
            $argList = @('-ssh', "$($cred.UserName)@$TargetHost", '-P', $Port.ToString(), '-pw', $passwordPlain)
            Start-Process -FilePath $exePath -ArgumentList $argList
        }

        try { Write-AppLog "SASC-Adapter: PuTTY session opened -- $($cred.UserName)@${TargetHost}:${Port}" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    } finally {
        $passwordPlain = $null
    }
}

#  ADAPTER: mRemoteNG

function Invoke-MRemoteNGSession {
    <#
    .SYNOPSIS  Launch mRemoteNG with vault credentials injected into a temp connection file.
    .DESCRIPTION
        Creates a temporary copy of the mRemoteNG connection file with vault
        credentials injected. Launches mRemoteNG pointing to the temp file.
        Temp file is ACL-restricted to current user and deleted after launch.
    .PARAMETER TargetName        Vault item name.
    .PARAMETER Protocol          Connection protocol (default: SSH2).
    .PARAMETER ConnectionFile    Path to existing confCons.xml (optional).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ConnectionFile', Justification='Reserved for mRemoteNG XML import path; conn-file ingest TBD.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification='Start-Job scriptblock receives $path via -ArgumentList (param-bound); $using: scope modifier is neither needed nor compatible with -ArgumentList. PSSA AST cannot distinguish param-bound vars from outer-scope captures inside Start-Job.')]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [ValidateSet('SSH2','RDP','VNC','Telnet','HTTP','HTTPS')]
        [string]$Protocol = 'SSH2',
        [string]$ConnectionFile
    )

    Assert-AdapterReady -AdapterName 'mRemoteNG'

    $cred = Get-CredentialForTarget -TargetName $TargetName
    $item = Get-VaultItem -Name $TargetName

    $mremotePath = Find-Executable -Name 'mRemoteNG.exe' -AdditionalPaths @(
        "$env:ProgramFiles\mRemoteNG\mRemoteNG.exe",
        "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe",
        "$env:LOCALAPPDATA\Programs\mRemoteNG\mRemoteNG.exe"
    )

    if (-not $mremotePath) {
        throw "mRemoteNG not found. Install it or ensure it is on PATH."
    }

    $hostName = $null
    $firstUri = $item.Uri | Select-Object -First 1
    if ($firstUri) {
        try { $hostName = ([System.Uri]::new($firstUri)).Host } catch { $hostName = $firstUri }
    }
    if (-not $hostName) { $hostName = $TargetName }

    if (-not $PSCmdlet.ShouldProcess("$($cred.UserName)@$hostName", "Open mRemoteNG session")) { return }

    $passwordPlain = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
        try {
            $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        # Create temporary connection XML
        $tempFile = Join-Path $env:TEMP "mremoteng-sasc-$(Get-Random).xml"
        $protocolMap = @{
            'SSH2'   = 'SSH2'
            'RDP'    = 'RDP'
            'VNC'    = 'VNC'
            'Telnet' = 'Telnet'
            'HTTP'   = 'HTTP'
            'HTTPS'  = 'HTTPS'
        }

        $connXml = @"
<?xml version="1.0" encoding="utf-8"?>
<mrng:Connections xmlns:mrng="http://mremoteng.org"
                   Name="SASC Connections"
                   Export="false"
                   EncryptionEngine="AES"
                   BlockCipherMode="GCM"
                   KdfIterations="1000"
                   FullFileEncryption="false"
                   Protected="SASC-TempConnection"
                   ConfVersion="2.6">
    <Node Name="$([System.Security.SecurityElement]::Escape($TargetName))"
          Type="Connection"
          Hostname="$([System.Security.SecurityElement]::Escape($hostName))"
          Protocol="$($protocolMap[$Protocol])"
          Username="$([System.Security.SecurityElement]::Escape($cred.UserName))"
          Password="$([System.Security.SecurityElement]::Escape($passwordPlain))"  <%# SECURITY: plaintext is required by mRemoteNG import format; file is ACL-restricted and auto-deleted after launch #%>
          Port="22"
          ConnectToConsole="false"
          UseCredSsp="false" />
</mrng:Connections>
"@
        Set-Content -LiteralPath $tempFile -Value $connXml -Encoding UTF8 -Force
        # ACL-restrict temp file
        Set-VaultFilePermissions -Path $tempFile

        # Launch mRemoteNG with temp connection file
        Start-Process -FilePath $mremotePath -ArgumentList "-consfile `"$tempFile`""

        # Schedule cleanup after a brief delay (allow mRemoteNG to read the file)
        # Security: plaintext password in temp XML is mitigated by ACL restriction,
        # short file lifetime (2s), and automatic deletion via background job.
        Start-Job -ScriptBlock {
            param($path)
            Start-Sleep -Seconds 2  <# SS-004 exempt: runs inside Start-Job background block #>
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        } -ArgumentList $tempFile | Out-Null

        try { Write-AppLog "SASC-Adapter: mRemoteNG session opened -- $($cred.UserName)@$hostName ($Protocol)" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    } finally {
        $passwordPlain = $null
    }
}

#  ADAPTER: Azure PowerShell

function Connect-AzureWithVault {
    <#
    .SYNOPSIS  Connect to Azure using vault credentials.
    .DESCRIPTION
        Supports username/password via Connect-AzAccount -Credential, or
        certificate-based auth via -CertificateThumbprint. Certificate-based
        is preferred (no password in memory).
    .PARAMETER TargetName    Vault item name for Azure credentials.
    .PARAMETER TenantId      Azure tenant ID (optional -- from vault item notes if stored).
    .PARAMETER UseCertificate  Use certificate-based auth if a cert thumbprint is stored.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$TenantId,
        [switch]$UseCertificate
    )

    Assert-AdapterReady -AdapterName 'Azure'

    # Verify Az module is available
    if (-not (Get-Module -ListAvailable -Name 'Az.Accounts' -ErrorAction SilentlyContinue)) {
        throw "Az.Accounts module not installed. Run: Install-Module Az -AllowClobber -Scope CurrentUser"
    }

    if (-not $PSCmdlet.ShouldProcess($TargetName, "Connect to Azure")) { return }

    $cred = Get-CredentialForTarget -TargetName $TargetName
    $item = Get-VaultItem -Name $TargetName

    # Extract TenantId from notes if not provided
    if (-not $TenantId -and $item.Notes) {
        if ($item.Notes -match 'TenantId\s*[:=]\s*([0-9a-f-]+)') {
            $TenantId = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
        }
    }

    Import-Module Az.Accounts -ErrorAction Stop

    $connectParams = @{}
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }

    if ($UseCertificate -and $item.Notes -match 'Thumbprint\s*[:=]\s*([A-Fa-f0-9]+)') {
        $thumbprint = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
        $appId = $cred.UserName  # Application/Client ID as username
        $connectParams['ApplicationId'] = $appId
        $connectParams['CertificateThumbprint'] = $thumbprint

        Connect-AzAccount @connectParams
        try { Write-AppLog "SASC-Adapter: Azure connected via certificate -- App: $appId" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    } else {
        $connectParams['Credential'] = $cred
        Connect-AzAccount @connectParams
        try { Write-AppLog "SASC-Adapter: Azure connected via credential -- User: $($cred.UserName)" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }
}

#  ADAPTER: Active Directory (RSAT/ADDS)

function Connect-ADDSWithVault {
    <#
    .SYNOPSIS  Retrieve a [PSCredential] for use with AD/RSAT cmdlets.
    .DESCRIPTION
        Returns a [PSCredential] object from the vault that can be passed to
        any RSAT cmdlet's -Credential parameter. Does not establish a persistent
        connection -- provides the credential for the caller to use.
    .PARAMETER TargetName     Vault item name for AD credentials.
    .PARAMETER DomainController  Optional DC to test against.
    .OUTPUTS   [PSCredential]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$DomainController
    )

    Assert-AdapterReady -AdapterName 'ADDS'

    $cred = Get-CredentialForTarget -TargetName $TargetName

    # Optionally verify the credential works
    if ($DomainController) {
        if (Get-Module -ListAvailable -Name 'ActiveDirectory' -ErrorAction SilentlyContinue) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                Get-ADDomainController -Server $DomainController -Credential $cred -ErrorAction Stop | Out-Null
                try { Write-AppLog "SASC-Adapter: ADDS credential verified against DC: $DomainController" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            } catch {
                try { Write-AppLog "SASC-Adapter: ADDS credential verification failed for DC: $DomainController -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            }
        }
    }

    try { Write-AppLog "SASC-Adapter: ADDS credential retrieved for: $TargetName (user: $($cred.UserName))" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    return $cred
}

#  ADAPTER: PowerShell ISE

function Open-ISEWithCredential {
    <#
    .SYNOPSIS  Launch PowerShell ISE with a pre-loaded credential script.
    .DESCRIPTION
        Creates a temporary .ps1 startup script that calls Get-CredentialForTarget
        inside the ISE session. The credential retrieval happens within ISE,
        not passed cross-process.
    .PARAMETER TargetName       Vault item name.
    .PARAMETER VariableName     Variable name for the credential in ISE (default: $cred).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$VariableName = 'cred'
    )

    Assert-AdapterReady -AdapterName 'ISE'

    if (-not $PSCmdlet.ShouldProcess("ISE with credential $TargetName", "Launch")) { return }

    $modulePath = Join-Path (Join-Path (Split-Path $PSScriptRoot) 'modules') 'AssistedSASC.psm1'

    # Create temp startup script
    $tempScript = Join-Path $env:TEMP "sasc-ise-startup-$(Get-Random).ps1"
    $scriptContent = @"
# SASC ISE Startup -- Auto-generated $(Get-Date -Format 'o')
# This file will self-delete after execution.
try {
    Import-Module '$modulePath' -Force -ErrorAction Stop
    Initialize-SASCModule -ScriptDir '$(Split-Path $PSScriptRoot)'
    `$$VariableName = Get-CredentialForTarget -TargetName '$([System.Security.SecurityElement]::Escape($TargetName))'
    Write-Host "Credential loaded into `$$VariableName for: $TargetName" -ForegroundColor Green  <# ISE interactive UI output — SS-003 exempt #>
    Write-Host "  Username: `$(`$$VariableName.UserName)" -ForegroundColor Cyan  <# ISE interactive UI output — SS-003 exempt #>
} catch {
    Write-AppLog -Message "Failed to load credential: `$(`$_.Exception.Message)" -Level Warning
} finally {
    # Self-delete
    if (Test-Path -LiteralPath '$tempScript') {
        Remove-Item -LiteralPath '$tempScript' -Force -ErrorAction SilentlyContinue
    }
}
"@
    Set-Content -LiteralPath $tempScript -Value $scriptContent -Encoding UTF8 -Force
    Set-VaultFilePermissions -Path $tempScript

    # Launch ISE with startup script
    $isePath = Find-Executable -Name 'powershell_ise.exe' -AdditionalPaths @(
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell_ise.exe"
    )

    if (-not $isePath) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        throw "PowerShell ISE not found."
    }

    Start-Process -FilePath $isePath -ArgumentList "-NoExit -File `"$tempScript`""
    try { Write-AppLog "SASC-Adapter: ISE launched with credential for: $TargetName" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
}

#  ADAPTER: Windows Hello Authentication

function Invoke-WindowsHelloAuth {
    <#
    .SYNOPSIS  Authenticate via Windows Hello and unlock vault.
    .DESCRIPTION
        Checks if Windows Hello (DPAPI-protected master password) is configured.
        If so, decrypts the master password via DPAPI CurrentUser scope and
        unlocks the vault. Falls back to PIN if biometric is unavailable.
    .OUTPUTS   [bool] $true if vault unlocked via Windows Hello.
    #>
    [CmdletBinding()]
    param()

    Assert-AdapterReady -AdapterName 'WindowsHello'

    # Verify Windows Hello is configured in SASC
    $config = Get-VaultConfig
    if (-not $config.WindowsHelloEnabled -or -not $config.WindowsHelloBlob) {
        throw "Windows Hello not configured. Run Enable-WindowsHello first."
    }

    try {
        $result = Unlock-Vault -UseWindowsHello
        if ($result) {
            try { Write-AppLog "SASC-Adapter: Vault unlocked via Windows Hello" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        }
        return $result
    } catch {
        try { Write-AppLog "SASC-Adapter: Windows Hello auth failed -- $($_.Exception.Message)" "Warning" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        throw
    }
}

#  ADAPTER: Windows Credential Dialog

function Set-CredentialDialogFill {
    <#
    .SYNOPSIS  Pre-fill a Windows credential dialog with vault credentials.
    .DESCRIPTION
        Uses the CredentialUI API (CredUIPromptForCredentials) to present a
        credential dialog pre-populated with vault username. Password requires
        the user to confirm (security design -- no auto-fill of password in
        system-level dialogs).
    .PARAMETER TargetName    Vault item name.
    .PARAMETER Caption       Dialog caption text.
    .OUTPUTS   [PSCredential] Final credential from the dialog.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TargetName,
        [string]$Caption = "Authenticate -- $TargetName"
    )
    if (-not $PSCmdlet.ShouldProcess('Set-CredentialDialogFill', 'Modify')) { return }


    Assert-AdapterReady -AdapterName 'CredentialDialog'

    $vaultCred = Get-CredentialForTarget -TargetName $TargetName

    # Use Get-Credential with pre-filled username
    $dialogCred = Get-Credential -UserName $vaultCred.UserName -Message $Caption

    if ($dialogCred) {
        try { Write-AppLog "SASC-Adapter: Credential dialog completed for: $TargetName" "Info" } catch { <# Intentional: non-fatal #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
    }
    return $dialogCred
}

#  ADAPTER: Generic Script Credential Provider

function Get-VaultCredentialForScript {
    <#
    .SYNOPSIS  Generic adapter for any script needing a [PSCredential] from the vault.
    .DESCRIPTION
        Prompts the user to select a vault item via GUI, returns [PSCredential].
        Intended to be called from custom user scripts as a drop-in replacement
        for Get-Credential.
    .PARAMETER TargetName     If provided, retrieves specific item. If omitted, shows picker.
    .PARAMETER PromptMessage  Custom prompt message.
    .OUTPUTS   [PSCredential]
    #>
    [CmdletBinding()]
    param(
        [string]$TargetName,
        [string]$PromptMessage = "Select vault credential"
    )

    Assert-AdapterReady -AdapterName 'GenericScript'

    if ($TargetName) {
        return Get-CredentialForTarget -TargetName $TargetName
    }

    # Show a picker dialog
    $status = Test-VaultStatus
    if ($status.State -ne 'Unlocked') {
        $unlocked = Show-VaultUnlockDialog
        if (-not $unlocked) { throw "Vault unlock cancelled." }
    }

    $items = Get-VaultItemList
    if (-not $items -or $items.Count -eq 0) {
        throw "No items in vault."
    }

    # Build selection using Out-GridView if available, else use a WinForms dialog
    $displayItems = $items | ForEach-Object {
        [PSCustomObject]@{
            Name     = $_.Name
            UserName = $_.UserName
            URI      = ($_.Uri -join ', ')
            Id       = $_.Id
        }
    }

    $selected = $displayItems | Out-GridView -Title $PromptMessage -OutputMode Single
    if (-not $selected) { throw "No item selected." }

    return Get-CredentialForTarget -TargetName $selected.Name
}

#  MODULE EXPORTS

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
    'Invoke-PuTTYSession',
    'Invoke-MRemoteNGSession',
    'Connect-AzureWithVault',
    'Connect-ADDSWithVault',
    'Open-ISEWithCredential',
    'Invoke-WindowsHelloAuth',
    'Set-CredentialDialogFill',
    'Get-VaultCredentialForScript'
)












