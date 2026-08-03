# VersionTag: 2607.B7.V53.0
# FileRole: Script
# Registers a local PowerShell repository in the workspace
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repoPath = Join-Path $workspaceRoot 'gallery'
if (-not (Test-Path -LiteralPath $repoPath)) { New-Item -ItemType Directory -Path $repoPath -Force | Out-Null }

# Resolve the PowerShellGet repository commands via auto-loading (Get-Command) instead of an
# explicit Import-Module. A partially-broken PackageManagement install (common under PowerShell 7)
# makes 'Import-Module PowerShellGet -ErrorAction Stop' surface an alarming module-load error during
# launch bootstrap even though Register-PSRepository remains usable. Probing quietly avoids the noise.
if (-not (Get-Command -Name Register-PSRepository -ErrorAction SilentlyContinue) -or
    -not (Get-Command -Name Get-PSRepository -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] PowerShell repository commands are unavailable in this host. Skipping repository registration."
    return
}

# Ensure the NuGet package provider is available (Register-PSRepository depends on it). The legacy
# PackageManagement provider is frequently missing or broken under PowerShell 7; only attempt a
# non-interactive bootstrap when its cmdlets actually exist, and skip quietly otherwise so launch
# output stays clean instead of emitting "term not recognized" warnings.
$nugetReady = $false
if (Get-Command -Name Get-PackageProvider -ErrorAction SilentlyContinue) {
    try {
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction Stop
        if ($null -ne $nuget -and $nuget.Version -ge [Version]'2.8.5.201') { $nugetReady = $true }
    } catch {
        if (Get-Command -Name Install-PackageProvider -ErrorAction SilentlyContinue) {
            try {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false -ErrorAction Stop | Out-Null
                $nugetReady = $true
            } catch {
                $nugetReady = $false  # bootstrap unavailable in this host; handled below
            }
        }
    }
}
if (-not $nugetReady) {
    Write-Host "[INFO] NuGet package provider unavailable in this host. Skipping WorkspaceRepo registration (local module gallery features remain optional)."
    return
}
if (-not (Get-PSRepository -Name WorkspaceRepo -ErrorAction SilentlyContinue)) {
    try {
        Register-PSRepository -Name WorkspaceRepo -SourceLocation $repoPath -InstallationPolicy Trusted -ErrorAction Stop
        Write-Host "[INFO] Registered WorkspaceRepo at $repoPath"
    } catch {
        Write-Host "[WARN] Could not register WorkspaceRepo: $_"
    }
} else {
    Write-Host "[INFO] WorkspaceRepo already registered."
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




