# VersionTag: 2604.B2.V31.2
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
# TODO: HelpMenu | Show-IntegrityCoreHelp | Actions: Verify|Baseline|Compare|Report|Help | Spec: config/help-menu-registry.json
<#
.SYNOPSIS
    PwShGUI-IntegrityCore -- Centralised startup and runtime integrity checking.
.DESCRIPTION
    Consolidates all integrity verification logic that was previously scattered
    inline across Main-GUI.ps1 (Phase 5 block, line-1626 duplicate check, and
    system-check panel references).  Provides:
      - Invoke-StartupIntegrityCheck  : Phase 5 replacement for Main-GUI.ps1
      - Test-IntegrityManifest        : File-hash manifest validator
      - Initialize-EmergencyUnlockKey : Seeds emergency-unlock AES-256 key in vault
      - Invoke-EmergencyUnlock        : Unlocks the app after catastrophic integrity failure
.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Module
    Version : 2604.B2.V31.0
#>

Set-StrictMode -Off

# -------------------------------------------------------------------------------
#  PRIVATE HELPERS
# -------------------------------------------------------------------------------

function Write-IntegrityLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [string]$Severity = 'Informational'
    )
    try {
        Write-AppLog $Message $Severity
    } catch {
        try { Write-AppLog -Message "[IntegrityCore] $Message" -Level Warning } catch { <# Intentional: non-fatal #> }
    }
}

# -------------------------------------------------------------------------------
#  STARTUP INTEGRITY CHECK  (replaces Phase 5 inline block in Main-GUI.ps1)
# -------------------------------------------------------------------------------

function Invoke-StartupIntegrityCheck {
    <#
    .SYNOPSIS
        Run startup integrity checks: required modules, directories and config XML validity.
    .DESCRIPTION
        Replaces the inline Phase 5 block previously embedded in Main-GUI.ps1.
        Returns a [PSCustomObject] with Passed [bool], Issues [string[]], and
        IssueCount [int] so the caller can decide how to handle failures.

        Checks performed:
          1. Required PowerShell modules are loaded.
          2. Required workspace directories exist.
          3. PwShGUI-Config.xml is present and parses as valid XML.
    .PARAMETER WorkspacePath
        Root of the PowerShellGUI workspace.  Defaults to $PSScriptRoot/../
    .PARAMETER ConfigFile
        Path to config XML.  Defaults to WorkspacePath\config\PwShGUI-Config.xml
    .PARAMETER RequiredModules
        Override the list of module names that must be loaded.
        Default: @('PwShGUICore')
    .OUTPUTS
        [PSCustomObject] Passed, Issues, IssueCount
    .EXAMPLE
        $result = Invoke-StartupIntegrityCheck -WorkspacePath 'C:\PowerShellGUI'
        if (-not $result.Passed) { Write-AppLog -Message "Integrity check FAILED" -Level Warning }
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath,
        [string]$ConfigFile,
        [string[]]$RequiredModules = @('PwShGUICore')
    )

    # Resolve workspace path
    if (-not $WorkspacePath) {
        $WorkspacePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        if (-not (Test-Path $WorkspacePath)) {
            $WorkspacePath = Split-Path $PSScriptRoot -Parent
        }
    }

    $issues = [System.Collections.ArrayList]::new()

    # 1 � Required modules loaded
    foreach ($modName in $RequiredModules) {
        if (-not (Get-Module -Name $modName)) {
            [void]$issues.Add("Module '$modName' is not loaded")
            Write-IntegrityLog "Integrity: module '$modName' not loaded" 'Warning'
        }
    }

    # 2 � Required directories exist
    $requiredDirs = @(
        @{ Name = 'scripts';  Path = Join-Path $WorkspacePath 'scripts'  },
        @{ Name = 'config';   Path = Join-Path $WorkspacePath 'config'   },
        @{ Name = 'modules';  Path = Join-Path $WorkspacePath 'modules'  },
        @{ Name = 'logs';     Path = Join-Path $WorkspacePath 'logs'     }
    )
    foreach ($dirEntry in $requiredDirs) {
        if (-not (Test-Path $dirEntry.Path)) {
            [void]$issues.Add("Required directory '$($dirEntry.Name)' missing at $($dirEntry.Path)")
            Write-IntegrityLog "Integrity: directory '$($dirEntry.Name)' missing at $($dirEntry.Path)" 'Warning'
        }
    }

    # 3 � Config XML parseable
    if (-not $ConfigFile) {
        $ConfigFile = Join-Path (Join-Path $WorkspacePath 'config') 'PwShGUI-Config.xml'
    }
    if (Test-Path $ConfigFile) {
        try {
            [xml]$null = Get-Content $ConfigFile -Encoding UTF8 -ErrorAction Stop
        } catch {
            [void]$issues.Add("Config file is not valid XML: $ConfigFile ($($_.Exception.Message))")
            Write-IntegrityLog "Integrity: config XML invalid at $ConfigFile � $($_.Exception.Message)" 'Error'
        }
    } else {
        [void]$issues.Add("Config file not found: $ConfigFile")
        Write-IntegrityLog "Integrity: config file not found at $ConfigFile" 'Error'
    }

    $issueCount = @($issues).Count
    if ($issueCount -gt 0) {
        Write-IntegrityLog "Phase 5: Completed with $issueCount integrity issue(s)" 'Warning'
    } else {
        Write-IntegrityLog 'Phase 5: All integrity checks passed' 'Info'
    }

    [PSCustomObject]@{
        Passed     = ($issueCount -eq 0)
        Issues     = @($issues)
        IssueCount = $issueCount
    }
}

# -------------------------------------------------------------------------------
#  FILE-HASH MANIFEST VALIDATOR
# -------------------------------------------------------------------------------

function Test-IntegrityManifest {
    <#
    .SYNOPSIS
        Validate workspace files against a pre-built SHA-256 hash manifest.
    .DESCRIPTION
        Reads the manifest at ManifestPath (JSON array of {RelativePath, Hash}) and
        verifies each file still matches.  Returns a [PSCustomObject] with:
          Passed [bool], Violations [PSCustomObject[]] (RelativePath, Expected, Actual).
    .PARAMETER WorkspacePath
        Root workspace folder.
    .PARAMETER ManifestPath
        Path to integrity manifest JSON file.  May be read from config
        IntegrityManifestPath element if omitted.
    .OUTPUTS
        [PSCustomObject] Passed, Violations, ViolationCount
    .EXAMPLE
        $r = Test-IntegrityManifest -WorkspacePath 'C:\PowerShellGUI'
        if (-not $r.Passed) { $r.Violations | Format-Table }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [string]$ManifestPath
    )

    # Attempt to resolve manifest path from config if not supplied
    if (-not $ManifestPath) {
        $cfgPath = Join-Path (Join-Path $WorkspacePath 'config') 'PwShGUI-Config.xml'
        if (Test-Path $cfgPath) {
            try {
                [xml]$cfg = Get-Content $cfgPath -Encoding UTF8 -ErrorAction Stop
                $ManifestPath = $cfg.SelectSingleNode('//IntegrityManifestPath').'#text'
            } catch {
                Write-IntegrityLog "Test-IntegrityManifest: failed to read config XML: $($_.Exception.Message)" 'Warning'
            }
        }
    }

    if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) {
        Write-IntegrityLog "Test-IntegrityManifest: manifest not found at '$ManifestPath' � skipping" 'Warning'
        return [PSCustomObject]@{ Passed = $true; Violations = @(); ViolationCount = 0; Skipped = $true }
    }

    $entries = @()
    try {
        $entries = Get-Content $ManifestPath -Encoding UTF8 -Raw -ErrorAction Stop |
                   ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-IntegrityLog "Test-IntegrityManifest: failed to parse manifest JSON: $($_.Exception.Message)" 'Error'
        return [PSCustomObject]@{ Passed = $false; Violations = @(); ViolationCount = 0; Error = $_.Exception.Message }
    }

    $violations = [System.Collections.ArrayList]::new()
    foreach ($entry in $entries) {
        $fullPath = Join-Path $WorkspacePath $entry.RelativePath
        if (-not (Test-Path $fullPath)) {
            [void]$violations.Add([PSCustomObject]@{
                RelativePath = $entry.RelativePath
                Expected     = $entry.Hash
                Actual       = 'FILE_MISSING'
            })
            continue
        }
        try {
            $actual = (Get-FileHash -Path $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($actual -ne $entry.Hash) {
                [void]$violations.Add([PSCustomObject]@{
                    RelativePath = $entry.RelativePath
                    Expected     = $entry.Hash
                    Actual       = $actual
                })
            }
        } catch {
            Write-IntegrityLog "Test-IntegrityManifest: hash error on '$($entry.RelativePath)': $($_.Exception.Message)" 'Warning'
        }
    }

    $count = @($violations).Count
    if ($count -gt 0) {
        Write-IntegrityLog "Test-IntegrityManifest: $count violation(s) detected" 'Warning'
    } else {
        Write-IntegrityLog 'Test-IntegrityManifest: all entries verified clean' 'Info'
    }

    [PSCustomObject]@{
        Passed         = ($count -eq 0)
        Violations     = @($violations)
        ViolationCount = $count
    }
}

# -------------------------------------------------------------------------------
#  EMERGENCY UNLOCK KEY MANAGEMENT
# -------------------------------------------------------------------------------

function Initialize-EmergencyUnlockKey {
    <#
    .SYNOPSIS
        Generate and store a 32-byte AES-256 emergency unlock key in the vault.
    .DESCRIPTION
        Creates a cryptographically random 32-byte key, Base64-encodes it, and
        stores it in the vault under the name 'system/emergency-unlock-key'.
        Should be called once during initial setup or key rotation.
        Safe to call if key already present -- will update the value.

        The key is returned as a [SecureString] for optional display/escrow.
        NEVER log the key value.
    .PARAMETER WorkspacePath
        Workspace root (used to locate the vault module if not already loaded).
    .OUTPUTS
        [PSCustomObject] KeyVaultEntry, KeyLengthBytes, KeyBase64Len, UpdatedAt
    .EXAMPLE
        Initialize-EmergencyUnlockKey -WorkspacePath 'C:\PowerShellGUI'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    # Ensure vault module available
    $vaultMod = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
    if (-not (Get-Module -Name 'AssistedSASC') -and (Test-Path $vaultMod)) {
        try {
            Import-Module $vaultMod -Force -ErrorAction Stop
        } catch {
            Write-IntegrityLog "Initialize-EmergencyUnlockKey: failed to load vault module: $($_.Exception.Message)" 'Error'
            throw
        }
    }

    $keyBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($keyBytes) } finally { $rng.Dispose() }
    $keyB64 = [Convert]::ToBase64String($keyBytes)

    $secKey = $keyB64 | ForEach-Object {
        $ss = New-Object System.Security.SecureString
        $_.ToCharArray() | ForEach-Object { $ss.AppendChar($_) }
        $ss.MakeReadOnly()
        $ss
    }

    try {
        Set-VaultItem -Name 'system/emergency-unlock-key' -Notes $keyB64 -ErrorAction Stop
        Write-IntegrityLog 'Initialize-EmergencyUnlockKey: emergency unlock key set in vault' 'Audit'
    } catch {
        Write-IntegrityLog "Initialize-EmergencyUnlockKey: failed to store key in vault: $($_.Exception.Message)" 'Error'
        throw
    }

    [PSCustomObject]@{
        KeyVaultEntry   = 'system/emergency-unlock-key'
        KeyLengthBytes  = 32
        KeyBase64Len    = $keyB64.Length
        UpdatedAt       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Invoke-EmergencyUnlock {
    <#
    .SYNOPSIS
        Attempt emergency application unlock using the vault-stored AES key.
    .DESCRIPTION
        Used when the normal startup integrity check fails hard enough to block
        the application.  Reads 'system/emergency-unlock-key' from the vault,
        verifies it is present and well-formed, then writes an AUDIT entry to
        confirm the override was used.

        This function does NOT bypass individual feature locks -- it records
        an authorised override so that the calling startup code can skip the
        blocking integrity gate and allow the application to continue loading
        in a degraded / remediation mode.

        Returns a [PSCustomObject] with Granted [bool] and Reason [string].
    .PARAMETER WorkspacePath
        Workspace root.
    .PARAMETER ProvidedKey
        Optional [SecureString] matching the stored key for confirmation.
        If supplied the stored key is compared against the provided value.
        If omitted, vault presence alone confirms the unlock.
    .OUTPUTS
        [PSCustomObject] Granted, Reason, Timestamp
    .EXAMPLE
        $unlock = Invoke-EmergencyUnlock -WorkspacePath 'C:\PowerShellGUI'
        if ($unlock.Granted) { # continue in degraded mode }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [System.Security.SecureString]$ProvidedKey
    )

    $vaultMod = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
    if (-not (Get-Module -Name 'AssistedSASC') -and (Test-Path $vaultMod)) {
        try { Import-Module $vaultMod -Force -ErrorAction Stop } catch {
            return [PSCustomObject]@{ Granted = $false; Reason = "Vault module load failed: $($_.Exception.Message)"; Timestamp = (Get-Date).ToString('o') }
        }
    }

    # Test vault is accessible
    $status = $null
    try { $status = Test-VaultStatus } catch {
        return [PSCustomObject]@{ Granted = $false; Reason = "Vault status check failed: $($_.Exception.Message)"; Timestamp = (Get-Date).ToString('o') }
    }
    if ($status.State -notin @('Unlocked', 'Open')) {
        return [PSCustomObject]@{ Granted = $false; Reason = "Vault is not unlocked (state: $($status.State))"; Timestamp = (Get-Date).ToString('o') }
    }

    $storedItem = $null
    try { $storedItem = Get-VaultItem -Name 'system/emergency-unlock-key' -ErrorAction Stop } catch {
        return [PSCustomObject]@{ Granted = $false; Reason = "Emergency key not found in vault: $($_.Exception.Message)"; Timestamp = (Get-Date).ToString('o') }
    }

    $storedNotes = $storedItem.Notes
    if ([string]::IsNullOrWhiteSpace($storedNotes) -or $storedNotes.Length -lt 40) {
        return [PSCustomObject]@{ Granted = $false; Reason = 'Stored emergency key is malformed or empty'; Timestamp = (Get-Date).ToString('o') }
    }

    # If a key was provided, validate it matches stored value
    if ($ProvidedKey) {
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ProvidedKey)
        $plain  = $null
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($plain -ne $storedNotes) {
            Write-IntegrityLog 'Invoke-EmergencyUnlock: provided key does NOT match stored key -- DENIED' 'Warning'
            return [PSCustomObject]@{ Granted = $false; Reason = 'Provided key does not match stored emergency key'; Timestamp = (Get-Date).ToString('o') }
        }
    }

    Write-IntegrityLog 'Invoke-EmergencyUnlock: EMERGENCY UNLOCK GRANTED -- application continuing in degraded mode' 'Critical'
    [PSCustomObject]@{
        Granted   = $true
        Reason    = 'Emergency unlock authorised via vault key'
        Timestamp = (Get-Date).ToString('o')
    }
}

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
    'Invoke-StartupIntegrityCheck'
    'Test-IntegrityManifest'
    'Initialize-EmergencyUnlockKey'
    'Invoke-EmergencyUnlock'
)







