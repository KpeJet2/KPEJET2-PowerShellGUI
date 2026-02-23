# VersionTag: 2602.a.12
# Stable alias launcher for module dependency checking.
# Automatically locates the latest module-dependency-check-*.ps1 generated
# by Invoke-ScriptDependencyMatrix.ps1 and forwards all parameters to it.
#Requires -Version 5.1

<#
.SYNOPSIS
    Tests workspace module dependencies against installed modules, with
    options to auto-install missing public modules from PSGallery and/or
    load available workspace modules.

.DESCRIPTION
    This is a stable entry-point so you never need to remember timestamped
    report filenames. It finds the newest module-dependency-check-*.ps1
    helper in ~REPORTS and runs it with your chosen switches.

    If no helper exists yet, it offers to generate one by running
    Invoke-ScriptDependencyMatrix.ps1 first.

.PARAMETER AutoInstallPublic
    Install missing modules from the PSGallery (CurrentUser scope).

.PARAMETER UseWorkspaceModules
    Prefer workspace-local modules under the modules/ directory when a
    matching module is found there.

.PARAMETER WhatIfOnly
    Show what would happen without making any changes.

.PARAMETER Regenerate
    Force a fresh dependency scan before running the check, even if a
    recent helper already exists.

.EXAMPLE
    .\scripts\Test-ModuleDependencies.ps1 -WhatIfOnly
    # Dry-run: shows status of every referenced module.

.EXAMPLE
    .\scripts\Test-ModuleDependencies.ps1 -AutoInstallPublic -UseWorkspaceModules
    # Install missing public modules and load workspace modules where available.
#>

[CmdletBinding()]
param(
    [switch]$AutoInstallPublic,
    [switch]$UseWorkspaceModules,
    [switch]$WhatIfOnly,
    [switch]$Regenerate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspacePath = Split-Path -Parent $scriptRoot
$reportPath = Join-Path $workspacePath '~REPORTS'
$matrixScript = Join-Path $scriptRoot 'Invoke-ScriptDependencyMatrix.ps1'

function Find-LatestModuleChecker {
    if (-not (Test-Path $reportPath)) { return $null }

    $candidates = @(Get-ChildItem -Path $reportPath -Filter 'module-dependency-check-*.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)

    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Invoke-MatrixGeneration {
    Write-Host 'Generating fresh dependency matrix and module data...' -ForegroundColor Cyan
    if (-not (Test-Path $matrixScript)) {
        throw "Matrix generator not found: $matrixScript"
    }

    & $matrixScript -WorkspacePath $workspacePath -ReportPath $reportPath
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw 'Matrix generation failed. Check output above for details.'
    }
}

# --- Main ---

if ($Regenerate) {
    Invoke-MatrixGeneration
}

$checkerPath = Find-LatestModuleChecker

if (-not $checkerPath) {
    Write-Host 'No module dependency data found. Generating now...' -ForegroundColor Yellow
    Invoke-MatrixGeneration
    $checkerPath = Find-LatestModuleChecker

    if (-not $checkerPath) {
        throw 'Failed to locate module checker after generation. Check ~REPORTS for errors.'
    }
}

Write-Host ("Using module checker: {0}" -f (Split-Path -Leaf $checkerPath)) -ForegroundColor DarkGray

$params = @{}
if ($AutoInstallPublic) { $params['AutoInstallPublic'] = $true }
if ($UseWorkspaceModules) { $params['UseWorkspaceModules'] = $true }
if ($WhatIfOnly) { $params['WhatIfOnly'] = $true }

& $checkerPath @params
