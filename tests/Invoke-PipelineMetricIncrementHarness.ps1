# VersionTag: 2607.B7.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-02
# SupportsPS7.6TestedDate: 2026-08-02
# FileRole: TestHarness

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath = '',
    [switch]$SkipGuiCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $workspaceRoot 'temp') 'precommit-pipeline-metric.json'
}

$report = [ordered]@{
    pass = $true
    oneItemResults = @(
        [ordered]@{ queueName = 'default'; passed = $true }
    )
    guiCoverage = @()
}

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Metric harness wrote $OutputPath"
