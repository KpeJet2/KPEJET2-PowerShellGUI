# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Publisher
# Publishes all modules in ./modules to the local WorkspaceRepo
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string]$RepositoryName = 'WorkspaceRepo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = $WorkspacePath
if (-not (Test-Path $workspaceRoot)) {
    throw "Workspace path does not exist: $workspaceRoot"
}

$modulesPath = Join-Path $workspaceRoot 'modules'
if (-not (Test-Path $modulesPath)) {
    throw "Modules path not found: $modulesPath"
}

$repo = Get-PSRepository -Name $RepositoryName -ErrorAction SilentlyContinue
if (-not $repo) {
    Write-Warning "Repository '$RepositoryName' is not registered. Run scripts/Setup-ModuleEnvironment.ps1 -Action Register first."
}

$moduleFiles = @(Get-ChildItem -Path $modulesPath -Filter *.psm1 -File | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
$stageRoot = Join-Path $workspaceRoot 'temp\module-publish-stage'
if (-not (Test-Path $stageRoot)) {
    $null = New-Item -Path $stageRoot -ItemType Directory -Force
}

foreach ($moduleFile in $moduleFiles) {
    $moduleName = $moduleFile.BaseName
    $moduleManifest = Join-Path $modulesPath ($moduleName + '.psd1')
    if (Test-Path $moduleManifest) {
        try {
            $stagePath = Join-Path $stageRoot $moduleName
            if (Test-Path $stagePath) {
                Remove-Item -Path $stagePath -Recurse -Force
            }
            $null = New-Item -Path $stagePath -ItemType Directory -Force
            Copy-Item -Path $moduleFile.FullName -Destination $stagePath -Force
            Copy-Item -Path $moduleManifest -Destination $stagePath -Force

            Publish-Module -Path $stagePath -Repository $RepositoryName -Force -ErrorAction Stop
            Write-Output "[INFO] Published $moduleName via $RepositoryName"
        } catch {
            Write-Warning "Publish failed for ${moduleName}: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "No module manifest found for $moduleName"
    }
}

<# Outline:
    Publishes every .psm1/.psd1 pair under <workspace>/modules to a registered local
    PSRepository (default 'WorkspaceRepo'). Each module is staged into
    temp/module-publish-stage/<ModuleName> first to give Publish-Module a clean container.
    Skips _TEMPLATE-Module.psm1 and modules without a .psd1.
#>

<# Problems:
    Get-PSRepository -ErrorAction SilentlyContinue is intentional (existence probe, not module
    import) and therefore exempt from SIN-PATTERN-P003. Publish failures are reported per-module
    via Write-Warning so a single bad manifest does not abort the rest of the batch.
#>

<# ToDo:
    Optional: add -WhatIf support and a JSON publish report consumable by the pipeline.
#>



