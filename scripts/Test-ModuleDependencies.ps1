# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Test
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries)
# Stable alias launcher for Module Management.
# Forwards parameters to Invoke-ModuleManagement.ps1.
#Requires -Version 5.1

<#
.SYNOPSIS
    Module Management launcher -- reports on installed, missing and errored
    modules with optional install/export capabilities.

.DESCRIPTION
    Thin wrapper around Invoke-ModuleManagement.ps1 that resolves paths
    automatically. Call this script from the command line or batch files;
    the GUI uses Invoke-ModuleManagement.ps1 directly.

    If -Regenerate is specified the Script Dependency Matrix is re-run
    first so that Invoke-ModuleManagement.ps1 has fresh cross-reference
    data available.

.PARAMETER AutoInstallMissing
    Install missing modules from PSGallery (CurrentUser scope).

.PARAMETER UseWorkspaceModules
    Load workspace-local modules where available.

.PARAMETER WhatIfOnly
    Show what would happen without making any changes.

.PARAMETER ExportInstaller
    Generate an installer script for all missing modules.

.PARAMETER ExportInventory
    Export full module inventory as JSON and CSV.

.PARAMETER Regenerate
    Re-run the Script Dependency Matrix before module management so
    cross-reference data is current.

.EXAMPLE
    .\scripts\Test-ModuleDependencies.ps1 -WhatIfOnly
    # Dry-run: list all module statuses.

.EXAMPLE
    .\scripts\Test-ModuleDependencies.ps1 -AutoInstallMissing
    # Install missing public modules from PSGallery.
#>

[CmdletBinding()]
param(
    [switch]$AutoInstallMissing,
    [switch]$UseWorkspaceModules,
    [switch]$WhatIfOnly,
    [switch]$ExportInstaller,
    [switch]$ExportInventory,
    [switch]$Regenerate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspacePath = Split-Path -Parent $scriptRoot
$reportPath    = Join-Path $workspacePath '~REPORTS'
$moduleScript  = Join-Path $scriptRoot 'Invoke-ModuleManagement.ps1'

if (-not (Test-Path $moduleScript)) {
    throw "Module management script not found: $moduleScript"
}

# Optional: regenerate the dependency matrix first for fresh cross-reference data
if ($Regenerate) {
    $matrixScript = Join-Path $scriptRoot 'Invoke-ScriptDependencyMatrix.ps1'
    if (Test-Path $matrixScript) {
        Write-Host 'Regenerating dependency matrix for fresh cross-reference data...' -ForegroundColor Cyan
        & $matrixScript -WorkspacePath $workspacePath -ReportPath $reportPath
    } else {
        Write-Warning "Matrix script not found: $matrixScript -- skipping regeneration."
    }
}

# Forward to Invoke-ModuleManagement.ps1
$params = @{
    WorkspacePath = $workspacePath
    ReportPath    = $reportPath
}
if ($AutoInstallMissing)  { $params['AutoInstallMissing']  = $true }
if ($UseWorkspaceModules) { $params['UseWorkspaceModules'] = $true }
if ($WhatIfOnly)          { $params['WhatIfOnly']          = $true }
if ($ExportInstaller)     { $params['ExportInstaller']     = $true }
if ($ExportInventory)     { $params['ExportInventory']     = $true }

& $moduleScript @params







<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





