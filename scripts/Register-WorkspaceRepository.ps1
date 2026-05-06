# VersionTag: 2605.B2.V31.7
# Registers a local PowerShell repository in the workspace
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repoPath = Join-Path $workspaceRoot 'gallery'
if (-not (Test-Path $repoPath)) { New-Item -ItemType Directory -Path $repoPath | Out-Null }

# Ensure PowerShellGet is available before using Get-PSRepository
if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
    Write-Host "[WARN] PowerShellGet module not found. Skipping repository registration."
    return
}
$canUsePsRepository = $false
try {
    Import-Module PowerShellGet -ErrorAction Stop
    $canUsePsRepository = $true
} catch {
    # Some environments expose Register-PSRepository without a clean Import-Module path.
    if (Get-Command Register-PSRepository -ErrorAction SilentlyContinue) {
        $canUsePsRepository = $true
        Write-Host "[WARN] PowerShellGet import failed: $($_.Exception.Message). Continuing with existing repository commands."
    } else {
        Write-Host "[WARN] Failed to import PowerShellGet and no repository commands are available. Skipping repository registration."
        return
    }
}
if (-not $canUsePsRepository) {
    Write-Host "[WARN] PowerShell repository commands are unavailable. Skipping repository registration."
    return
}
# Ensure NuGet provider is available without prompting interactively
try {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction Stop
    if ($nuget.Version -lt [Version]'2.8.5.201') { throw "NuGet provider version too old" }
} catch {
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "[WARN] NuGet provider unavailable: $_. Skipping repository registration."
        return
    }
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


