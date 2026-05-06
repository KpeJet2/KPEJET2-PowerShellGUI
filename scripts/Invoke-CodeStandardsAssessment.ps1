# VersionTag: 2605.B2.V31.7
# SupportPS5.1: YES(As of: 2026-04-27)
# SupportsPS7.6: YES(As of: 2026-04-27)
# SupportPS5.1TestedDate: 2026-04-27
# SupportsPS7.6TestedDate: 2026-04-27
# FileRole: AssessmentScript
# SchemaVersion: StandardsAssessment/1.0
# Author: The Establishment
# Date: 2026-04-27
#Requires -Version 5.1
<#!
.SYNOPSIS
    Assesss standards coverage for modules, scripts, configs, and XHTML including .psd1 manifests.
.DESCRIPTION
    Generates a machine-readable assessment report with key standards gaps and summary metrics.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $reportsDir = Join-Path $WorkspacePath 'reports'
    if (-not (Test-Path $reportsDir)) {
        $null = New-Item -Path $reportsDir -ItemType Directory -Force
    }
    $OutputPath = Join-Path $reportsDir 'standards-assessment.json'
}

function Test-HeaderFields {
    param(
        [Parameter(Mandatory)][string]$Content,
        [switch]$CheckSchema
    )

    return [ordered]@{
        hasVersionTag = [bool]($Content -match '#\s*VersionTag:')
        hasFileRole = [bool]($Content -match '#\s*FileRole:')
        hasSchemaVersion = if ($CheckSchema) { [bool]($Content -match '#\s*SchemaVersion:') } else { $true }
    }
}

$assessment = [ordered]@{
    '$schema' = 'PwShGUI-StandardsAssessment/1.0'
    generated = (Get-Date).ToUniversalTime().ToString('o')
    workspace = $WorkspacePath
    summary = [ordered]@{}
    gaps = [ordered]@{
        psm1MissingVersionTag = @()
        psm1MissingFileRole = @()
        psm1MissingSchemaVersion = @()
        psd1MissingVersionTag = @()
        psd1MissingFileRole = @()
        psd1MissingSchemaVersion = @()
        ps1MissingVersionTag = @()
        ps1MissingFileRole = @()
        xhtmlMissingVersionTag = @()
        xhtmlMissingFileRole = @()
        configJsonMissingSchemaField = @()
    }
}

$moduleFiles = @(Get-ChildItem (Join-Path $WorkspacePath 'modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue)
$manifestFiles = @(Get-ChildItem (Join-Path $WorkspacePath 'modules') -Filter '*.psd1' -File -ErrorAction SilentlyContinue)
$scriptFiles = @(Get-ChildItem (Join-Path $WorkspacePath 'scripts') -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)
$xhtmlFiles = @(Get-ChildItem $WorkspacePath -Filter '*.xhtml' -File -ErrorAction SilentlyContinue)
$configJsonFiles = @(Get-ChildItem (Join-Path $WorkspacePath 'config') -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)

foreach ($file in $moduleFiles) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch {
        continue
    }
    $check = Test-HeaderFields -Content $content -CheckSchema
    if (-not $check.hasVersionTag) { $assessment.gaps.psm1MissingVersionTag += $file.Name }
    if (-not $check.hasFileRole) { $assessment.gaps.psm1MissingFileRole += $file.Name }
    if (-not $check.hasSchemaVersion) { $assessment.gaps.psm1MissingSchemaVersion += $file.Name }
}

foreach ($file in $manifestFiles) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch {
        continue
    }
    $check = Test-HeaderFields -Content $content -CheckSchema
    if (-not $check.hasVersionTag) { $assessment.gaps.psd1MissingVersionTag += $file.Name }
    if (-not $check.hasFileRole) { $assessment.gaps.psd1MissingFileRole += $file.Name }
    if (-not $check.hasSchemaVersion) { $assessment.gaps.psd1MissingSchemaVersion += $file.Name }
}

foreach ($file in $scriptFiles) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch {
        continue
    }
    $check = Test-HeaderFields -Content $content
    if (-not $check.hasVersionTag) { $assessment.gaps.ps1MissingVersionTag += $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/') }
    if (-not $check.hasFileRole) { $assessment.gaps.ps1MissingFileRole += $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/') }
}

foreach ($file in $xhtmlFiles) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch {
        continue
    }
    if ($content -notmatch '<!--\s*VersionTag:') { $assessment.gaps.xhtmlMissingVersionTag += $file.Name }
    if ($content -notmatch '<!--\s*FileRole:') { $assessment.gaps.xhtmlMissingFileRole += $file.Name }
}

foreach ($file in $configJsonFiles) {
    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $json.PSObject.Properties.Name.Contains('$schema') -and -not ($json.meta -and $json.meta.PSObject.Properties.Name.Contains('$schema'))) {
            $assessment.gaps.configJsonMissingSchemaField += $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
        }
    } catch {
        $assessment.gaps.configJsonMissingSchemaField += $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
    }
}

$assessment.summary = [ordered]@{
    moduleCount = $moduleFiles.Count
    moduleManifestCount = $manifestFiles.Count
    scriptCount = $scriptFiles.Count
    xhtmlCount = $xhtmlFiles.Count
    configJsonCount = $configJsonFiles.Count
    psm1Compliant = ($assessment.gaps.psm1MissingVersionTag.Count -eq 0 -and $assessment.gaps.psm1MissingFileRole.Count -eq 0 -and $assessment.gaps.psm1MissingSchemaVersion.Count -eq 0)
    psd1Compliant = ($assessment.gaps.psd1MissingVersionTag.Count -eq 0 -and $assessment.gaps.psd1MissingFileRole.Count -eq 0 -and $assessment.gaps.psd1MissingSchemaVersion.Count -eq 0)
}

$assessment | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Standards assessment written: $OutputPath" -ForegroundColor Green

