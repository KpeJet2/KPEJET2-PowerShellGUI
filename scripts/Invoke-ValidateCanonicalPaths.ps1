# VersionTag: 2607.B1.V52.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-23
# SupportsPS7.6TestedDate: 2026-07-23
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that required canonical pipeline paths exist.
.PARAMETER WorkspacePath
    Workspace root path.
.PARAMETER RegistryPath
    JSON registry containing requiredPaths array.
.PARAMETER OutputJson
    Optional JSON output path.
.PARAMETER FailOnMissing
    Exit with code 1 when required paths are missing.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$RegistryPath = '',
    [string]$OutputJson = '',
    [switch]$FailOnMissing,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path (Join-Path $root 'config') 'pipeline-canonical-paths.json'
}
if (-not (Test-Path -LiteralPath $RegistryPath)) {
    throw ('Canonical registry missing: ' + $RegistryPath)
}

$registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$requiredPaths = @()
if ($registry -and $registry.PSObject.Properties.Name -contains 'requiredPaths') {
    $requiredPaths = @($registry.requiredPaths)
}

$missing = @()
$existing = @()
foreach ($rel in $requiredPaths) {
    $norm = [string]$rel
    if ([string]::IsNullOrWhiteSpace($norm)) { continue }
    $abs = Join-Path $root ($norm -replace '/', '\\')
    if (Test-Path -LiteralPath $abs) {
        $existing += $norm
    } else {
        $missing += $norm
    }
}

$result = [ordered]@{
    scanId = 'PATHREG-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    workspace = $root
    registryPath = $RegistryPath
    requiredCount = @($requiredPaths).Count
    existingCount = @($existing).Count
    missingCount = @($missing).Count
    missingPaths = @($missing)
    existingPaths = @($existing)
}

if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
    $outDir = Split-Path -Parent $OutputJson
    if (-not (Test-Path -LiteralPath $outDir)) {
        $null = New-Item -ItemType Directory -Path $outDir -Force
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

if (-not $Quiet) {
    if (@($missing).Count -eq 0) {
        Write-Host '[CanonicalPaths] All required paths exist.' -ForegroundColor Green
    } else {
        Write-Host ('[CanonicalPaths] Missing required paths: ' + @($missing).Count) -ForegroundColor Yellow
        foreach ($m in $missing) {
            Write-Host (' - ' + $m) -ForegroundColor Yellow
        }
    }
}

$result

if ($FailOnMissing -and @($missing).Count -gt 0) {
    exit 1
}

exit 0
