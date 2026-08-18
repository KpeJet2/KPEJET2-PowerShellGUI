# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: Exporter

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$WorkspacePath,
    [string]$OutputPath,
    [ValidateSet('user', 'workspace', 'combined')]
    [string]$Scope = 'combined',
    [ValidateSet('all', 'feature', 'menu', 'nature', 'security hardening', 'feature development', 'newly added configs/parameters')]
    [string]$FilterCategory = 'all',
    [string]$Filter
)

$modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'VsCodeConfigCoverage.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
$snapshot = Get-VsCodeConfigSnapshot -WorkspacePath $WorkspacePath
$report = New-VsCodeConfigCoverageReport -Snapshot $snapshot -InstallBaseline $snapshot -Scope $Scope -FilterCategory $FilterCategory -Filter $Filter
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'ConfigCoverage'
    if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $OutputPath = Join-Path $reportDir 'vscode-config-report.json'
}
$outputParent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output $OutputPath
