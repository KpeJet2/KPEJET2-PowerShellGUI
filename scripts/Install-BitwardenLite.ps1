# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Setup
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Install-BitwardenLite -- Guided Bitwarden CLI installer for Assisted SASC.

.DESCRIPTION
    Installs the Bitwarden CLI (bw) via winget with least-privilege enforcement.
    Attempts user-scope install first; only requests elevation if required.
    Post-install: validates binary, records hash in integrity manifest, runs
    guided vault setup via WinForms dialogs.

    Follows existing installer patterns from ~DOWNLOADS/INSTALLER-Scripts/.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th March 2026
    Modified : 4th March 2026
    Security : Least-privilege, ShouldProcess, hash verification

.LINK
    ~README.md/SECRETS-MANAGEMENT-GUIDE.md
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipVaultSetup,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
#  ASSEMBLY LOADING
# ═══════════════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════════
#  PATHS & LOGGING
# ═══════════════════════════════════════════════════════════════════════════════
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logTag    = "Install-BW"

# Try to import core module for logging
$coreModulePath = Join-Path (Join-Path $scriptDir 'modules') 'PwShGUICore.psm1'
if (Test-Path $coreModulePath) {
    try { Import-Module $coreModulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" }
    Initialize-CorePaths -ScriptDir $scriptDir -ErrorAction SilentlyContinue
}

function Write-Log {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param(
        [string]$Message,
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$timestamp] [$Level] $Message"
    if (-not $Silent) { Write-Verbose $formatted }
    try { Write-AppLog "$logTag`: $Message" $Level } catch {
        # Fallback if Write-AppLog not available
        Write-Host $formatted
    }
}

function Ensure-PackageStack {
    param([switch]$AutoInstall)

    $requiredModules = @(
        @{ Name = 'PackageManagement'; Min = '1.4.8.1' },
        @{ Name = 'PowerShellGet'; Min = '2.2.5' },
        @{ Name = 'Microsoft.PowerShell.PSResourceGet'; Min = '1.0.0' }
    )

    foreach ($req in $requiredModules) {
        $name = [string]$req.Name
        $minVersion = [string]$req.Min
        $installed = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1

        $needsInstall = $false
        if (-not $installed) {
            $needsInstall = $true
        } else {
            try {
                if ([version]$installed.Version -lt [version]$minVersion) { $needsInstall = $true }
            } catch {
                $needsInstall = $true
            }
        }

        if ($needsInstall) {
            if ($AutoInstall) {
                try {
                    Write-Log "Installing required module '$name' (min $minVersion)" 'Info'
                    Install-Module -Name $name -Scope CurrentUser -MinimumVersion $minVersion -Force -AllowClobber -ErrorAction Stop
                } catch {
                    Write-Log "Module install failed for '$name': $($_.Exception.Message)" 'Warning'
                }
            } else {
                Write-Log "Required module '$name' not installed or below min version ($minVersion)" 'Warning'
            }
        }

        try {
            if (Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue) {
                Import-Module $name -Force -ErrorAction Stop
                Write-Log "Module loaded: $name" 'Debug'
            }
        } catch {
            Write-Log "Module import warning for '$name': $($_.Exception.Message)" 'Warning'
        }
    }
}

function Ensure-LocalSecurityModule {
    $requiredFunctions = @(
        'Initialize-SASCModule',
        'Test-VaultStatus',
        'Lock-Vault',
        'Show-VaultStatusDialog',
        'Show-VaultUnlockDialog'
    )

    $sascModulePath = Get-ProjectPath SascModule
    if (-not (Test-Path $sascModulePath)) {
        Write-Log "Local security module missing: $sascModulePath" 'Warning'
        return $false
    }

    try {
        Import-Module $sascModulePath -Force -ErrorAction Stop
        if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
            Initialize-SASCModule -ScriptDir $scriptDir | Out-Null
        }

        $missing = @()
        foreach ($fn in $requiredFunctions) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                $missing += $fn
            }
        }

        if ($missing.Count -gt 0) {
            Write-Log ("AssistedSASC missing functions: {0}" -f ($missing -join ', ')) 'Warning'
            return $false
        }

        # Invocation smoke-check for one key function.
        try {
            $null = Test-VaultStatus
            Write-Log "AssistedSASC function invocation check passed" 'Debug'
        } catch {
            Write-Log "AssistedSASC invocation warning: $($_.Exception.Message)" 'Warning'
        }

        return $true
    } catch {
        Write-Log "Failed to load AssistedSASC module: $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Get-BWStatusSafe {
    param([string]$BWPath)

    try {
        $statusRaw = & $BWPath status 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($statusRaw)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'No output returned by bw status'; Status = $null }
        }

        try {
            $statusObj = $statusRaw | ConvertFrom-Json -ErrorAction Stop
            return [pscustomobject]@{ Ok = $true; Reason = ''; Status = $statusObj; Raw = $statusRaw }
        } catch {
            $statusText = $statusRaw.Trim()
            if ($statusText -match '(?i)service.*not.*running|service.*not.*installed|connection.*refused|unable to connect|daemon') {
                return [pscustomobject]@{ Ok = $false; Reason = 'Bitwarden service is not installed or not running.'; Status = $null; Raw = $statusRaw }
            }
            return [pscustomobject]@{ Ok = $false; Reason = "bw status returned non-JSON output: $statusText"; Status = $null; Raw = $statusRaw }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '(?i)service.*not.*running|service.*not.*installed|connection.*refused|unable to connect|daemon') {
            return [pscustomobject]@{ Ok = $false; Reason = 'Bitwarden service is not installed or not running.'; Status = $null }
        }
        return [pscustomobject]@{ Ok = $false; Reason = "bw status failed: $msg"; Status = $null }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

Write-Log "Starting Bitwarden CLI installation pre-flight checks"

# Ensure package management dependencies are loaded (or installed when confirmed)
$autoInstallDeps = $false
if (-not $Silent) {
    $depChoice = [System.Windows.Forms.MessageBox]::Show(
        "Before installing Bitwarden CLI, install/import required PowerShell package modules if missing?`n`nThis includes PowerShellGet, PackageManagement, and PSResourceGet.",
        "Module Dependency Check",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($depChoice -eq 'Yes') { $autoInstallDeps = $true }
}
Ensure-PackageStack -AutoInstall:$autoInstallDeps

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or later is required. Current: $($PSVersionTable.PSVersion)"
}
Write-Log "PowerShell version: $($PSVersionTable.PSVersion)" "Debug"

# Check winget availability
$wingetCmd = Get-Command 'winget' -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    $msg = "WinGet (Windows Package Manager) is not available.`nInstall 'App Installer' from the Microsoft Store, then try again."
    if (-not $Silent) {
        [System.Windows.Forms.MessageBox]::Show($msg, "Pre-flight Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    throw "winget not found. Install App Installer from Microsoft Store."
}
Write-Log "winget found: $($wingetCmd.Source)"

# Check if bw is already installed
$existingBW = Get-Command 'bw' -ErrorAction SilentlyContinue
if ($existingBW) {
    $bwVersion = & $existingBW.Source --version 2>&1
    Write-Log "Bitwarden CLI already installed: v$bwVersion at $($existingBW.Source)"

    if (-not $Silent) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Bitwarden CLI is already installed:`n`nVersion: $bwVersion`nPath: $($existingBW.Source)`n`nWould you like to reinstall/upgrade?",
            "Already Installed",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($result -ne 'Yes') {
            Write-Log "User declined reinstall"
            return @{
                Success = $true
                Path    = $existingBW.Source
                Version = $bwVersion
                Action  = 'AlreadyInstalled'
            }
        }
    }
}

# Check admin status
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "Running as admin: $isAdmin"

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $PSCmdlet.ShouldProcess("Bitwarden CLI", "Install via winget")) { return }

Write-Log "Starting winget install -- attempting user scope first"

$installResult = $null
$installSuccess = $false

# Try user-scope install first (least privilege)
try {
    Write-Log "Attempting: winget install Bitwarden.CLI --scope user"
    $output = winget install Bitwarden.CLI --accept-package-agreements --accept-source-agreements --scope user 2>&1
    $installResult = $output | Out-String
    Write-Log "winget output: $installResult" "Debug"

    if ($LASTEXITCODE -eq 0 -or $installResult -match 'Successfully installed|already installed|No applicable update') {
        $installSuccess = $true
        Write-Log "User-scope install succeeded"
    }
} catch {
    Write-Log "User-scope install failed: $($_.Exception.Message)" "Warning"
}

# If user-scope failed, try machine-scope with elevation
if (-not $installSuccess) {
    Write-Log "User-scope install failed, attempting machine-scope" "Warning"

    if (-not $isAdmin) {
        Write-Log "Requesting elevation for machine-scope install"
        if (-not $Silent) {
            $elevResult = [System.Windows.Forms.MessageBox]::Show(
                "User-scope installation was unsuccessful.`n`nElevated (admin) installation is required. Grant admin permissions?",
                "Elevation Required",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($elevResult -ne 'Yes') {
                throw "Installation cancelled by user -- elevation denied."
            }
        }

        # Re-launch this script elevated
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
        $scriptPath = $MyInvocation.MyCommand.Path
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Silent"
        if ($SkipVaultSetup) { $arguments += " -SkipVaultSetup" }

        try {
            $proc = Start-Process -FilePath $psExe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            if ($proc.ExitCode -eq 0) {
                $installSuccess = $true
                Write-Log "Elevated install completed successfully"
            } else {
                throw "Elevated install exited with code $($proc.ExitCode)"
            }
        } catch {
            throw "Failed to install Bitwarden CLI: $($_.Exception.Message)"
        }
    } else {
        # Already admin -- try machine scope
        try {
            Write-Log "Attempting: winget install Bitwarden.CLI --scope machine"
            $output = winget install Bitwarden.CLI --accept-package-agreements --accept-source-agreements 2>&1
            $installResult = $output | Out-String
            Write-Log "winget output: $installResult" "Debug"

            if ($LASTEXITCODE -eq 0 -or $installResult -match 'Successfully installed|already installed') {
                $installSuccess = $true
                Write-Log "Machine-scope install succeeded"
            } else {
                throw "winget install failed with exit code $LASTEXITCODE"
            }
        } catch {
            throw "Machine-scope install failed: $($_.Exception.Message)"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  POST-INSTALL VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Log "Verifying installation..."

# Refresh PATH for the current session
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# Locate bw.exe
$bwPath = $null
$bwCmd = Get-Command 'bw' -ErrorAction SilentlyContinue
if ($bwCmd) {
    $bwPath = $bwCmd.Source
} else {
    # Search common winget install locations
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Bitwarden CLI\bw.exe",
        "$env:ProgramFiles\Bitwarden CLI\bw.exe",
        "${env:ProgramFiles(x86)}\Bitwarden CLI\bw.exe"
    )
    # Wildcard search in winget packages
    $wingetPkgs = Get-Item -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Bitwarden.CLI_*\bw.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wingetPkgs) { $candidates += $wingetPkgs.FullName }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $bwPath = $c
            break
        }
    }
}

if (-not $bwPath) {
    throw "Bitwarden CLI installed but bw.exe not found. You may need to restart your terminal."
}

Write-Log "bw.exe located at: $bwPath"

# Verify binary
$bwVersion = & $bwPath --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "bw.exe found but version check failed: $bwVersion"
}
Write-Log "Bitwarden CLI version: v$bwVersion"

# Compute SHA-256 hash for integrity manifest
$bwHash = (Get-FileHash -LiteralPath $bwPath -Algorithm SHA256).Hash
Write-Log "bw.exe SHA-256: $bwHash"

# ═══════════════════════════════════════════════════════════════════════════════
#  SECURITY CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

Write-Log "Running post-install security checks..."

# Verify bw status command works
try {
    $statusResult = Get-BWStatusSafe -BWPath $bwPath
    if ($statusResult.Ok -and $statusResult.Status) {
        Write-Log "Vault status: $($statusResult.Status.status)"
    } else {
        Write-Log "Vault status check warning: $($statusResult.Reason)" 'Warning'
        if (-not $Silent -and $statusResult.Reason -match 'not installed or not running') {
            [System.Windows.Forms.MessageBox]::Show(
                "Bitwarden service appears unavailable.`n`nReason: $($statusResult.Reason)`n`nYou can continue setup and verify again after service initialization.",
                "Bitwarden Service Warning",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
} catch {
    Write-Log "Could not query vault status: $($_.Exception.Message)" "Warning"
}

# Ensure local security module is loaded and functions are invokable post-install.
$sascReady = Ensure-LocalSecurityModule
if (-not $sascReady) {
    Write-Log "AssistedSASC module is not fully ready after install" 'Warning'
}

# Check no BW_SESSION in environment
if ($env:BW_SESSION) {
    Write-Log "WARNING: BW_SESSION found in environment -- clearing" "Warning"
    $env:BW_SESSION = $null
}

# Create vault backup directory
$backupDir = Join-Path (Join-Path $scriptDir 'pki') 'vault-backups'
if (-not (Test-Path -LiteralPath $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Write-Log "Created vault backup directory: $backupDir"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  INTEGRITY MANIFEST UPDATE
# ═══════════════════════════════════════════════════════════════════════════════

# Try to update the integrity manifest with the new BW CLI path
try {
    $sascModule = Get-ProjectPath SascModule
    if (Test-Path $sascModule) {
        Import-Module $sascModule -Force
        Initialize-SASCModule -ScriptDir $scriptDir | Out-Null
        New-IntegrityManifest | Out-Null
        Write-Log "Integrity manifest updated with bw.exe hash"
    }
} catch {
    Write-Log "Could not update integrity manifest: $($_.Exception.Message)" "Warning"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  GUIDED VAULT SETUP (optional)
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $SkipVaultSetup -and -not $Silent) {
    Write-Log "Starting guided vault setup"

    $setupResult = [System.Windows.Forms.MessageBox]::Show(
        "Bitwarden CLI installed successfully!`n`n" +
        "Version: $bwVersion`n" +
        "Path: $bwPath`n" +
        "SHA-256: $bwHash`n`n" +
        "Would you like to configure your vault now?`n`n" +
        "This will guide you through:`n" +
        "  1. Login / Account creation`n" +
        "  2. Initial vault unlock`n" +
        "  3. Security configuration",
        "Bitwarden CLI -- Setup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($setupResult -eq 'Yes') {
        # Check if already logged in
        $statusResult2 = Get-BWStatusSafe -BWPath $bwPath
        $statusObj2 = $statusResult2.Status

        if (-not $statusResult2.Ok -and $statusResult2.Reason -match 'not installed or not running') {
            [System.Windows.Forms.MessageBox]::Show(
                "Bitwarden service is not currently reachable.`n`n$($statusResult2.Reason)`n`nPlease start Bitwarden service/application and run setup again.",
                "Service Not Running",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            Write-Log "Guided setup deferred due to unavailable BW service" 'Warning'
            $statusObj2 = $null
        }

        if ($statusObj2 -and $statusObj2.status -eq 'unauthenticated') {
            # Need to login
            $loginChoice = [System.Windows.Forms.MessageBox]::Show(
                "You are not logged in to Bitwarden.`n`n" +
                "Choose how to proceed:`n" +
                "  YES -- Login with existing account`n" +
                "  NO  -- Open Bitwarden website to create account`n",
                "Bitwarden Login",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question)

            if ($loginChoice -eq 'Yes') {
                # Interactive login via new terminal
                Write-Log "Opening interactive BW login terminal"
                $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
                Start-Process -FilePath $psExe -ArgumentList "-NoExit -Command `"& '$bwPath' login; Write-Host 'Login complete. You can close this window.' -ForegroundColor Green; pause`""
            } elseif ($loginChoice -eq 'No') {
                Start-Process 'https://vault.bitwarden.com/#/register'
                [System.Windows.Forms.MessageBox]::Show(
                    "After creating your account, run this installer again to complete setup.",
                    "Account Registration",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        } elseif ($statusObj2 -and $statusObj2.status -eq 'locked') {
            Write-Log "Vault is locked -- user can unlock via GUI"
            [System.Windows.Forms.MessageBox]::Show(
                "Your vault is set up and locked.`nUse Security > Unlock Vault in the main GUI to unlock it.",
                "Vault Ready",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } elseif ($statusObj2 -and $statusObj2.status -eq 'unlocked') {
            Write-Log "Vault already unlocked"
            [System.Windows.Forms.MessageBox]::Show(
                "Your vault is already unlocked and ready to use!",
                "Vault Ready",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } elseif (-not $statusObj2) {
            Write-Log "Vault setup skipped because status could not be determined" 'Warning'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  RESULT
# ═══════════════════════════════════════════════════════════════════════════════

$result = @{
    Success  = $true
    Path     = $bwPath
    Version  = $bwVersion
    SHA256   = $bwHash
    Action   = 'Installed'
}

Write-Log "Installation complete: $($result | ConvertTo-Json -Depth 5 -Compress)"
return $result







<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




