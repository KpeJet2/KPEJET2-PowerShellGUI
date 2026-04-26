#Requires -Version 5.1
# Author: The Establishment
# Date: 2604
# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# FileRole: Script
<#
.SYNOPSIS
    Validate pipeline artifact coherence and detect stale interrupted items.
.DESCRIPTION
    Imports the CronAiAthon pipeline module, optionally refreshes derived artifacts,
    then validates that todo/_index.json, todo/_bundle.js, and
    todo/_master-aggregated.json are in sync with the active todo item files.
    Also reports stale OPEN, PLANNED, IN_PROGRESS, and BLOCKED items.
.EXAMPLE
    .\Invoke-PipelineIntegrityCheck.ps1
    .\Invoke-PipelineIntegrityCheck.ps1 -Refresh
#>
param(
    [string]$WorkspacePath,
    [switch]$Refresh,
    [switch]$WriteReport,
    [string]$ReportPath,
    [switch]$FailOnStale,
    [int]$OpenDays = 14,
    [int]$PlannedDays = 7,
    [int]$InProgressDays = 3,
    [int]$BlockedDays = 7
)

$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}

$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Error "Pipeline module not found: $modulePath"
    return
}

Import-Module $modulePath -Force -ErrorAction Stop

if ($Refresh) {
    Write-Host "Refreshing pipeline artifacts..." -ForegroundColor Cyan
    $refreshResult = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
    Write-Host "  Master: $($refreshResult.master)" -ForegroundColor Gray
    Write-Host "  Bundle: $($refreshResult.bundle)" -ForegroundColor Gray
    Write-Host "  Index:  $($refreshResult.index)" -ForegroundColor Gray
}

$result = Test-PipelineArtifactIntegrity -WorkspacePath $WorkspacePath -IncludeStaleCheck -OpenDays $OpenDays -PlannedDays $PlannedDays -InProgressDays $InProgressDays -BlockedDays $BlockedDays

$report = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    refreshed = [bool]$Refresh
    failOnStale = [bool]$FailOnStale
    thresholds = [ordered]@{
        openDays = $OpenDays
        plannedDays = $PlannedDays
        inProgressDays = $InProgressDays
        blockedDays = $BlockedDays
    }
    result = $result
}

$shouldWriteReport = ($WriteReport -or -not [string]::IsNullOrWhiteSpace($ReportPath))
$resolvedReportPath = $null
if ($shouldWriteReport) {
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineIntegrity'
        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        $ReportPath = Join-Path $reportDir ("integrity-{0}.json" -f (Get-Date -Format 'yyMMddHHmm'))
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -Path $ReportPath -Encoding UTF8
    $resolvedReportPath = $ReportPath
}

Write-Host "`n=== Pipeline Artifact Integrity ===" -ForegroundColor Cyan
Write-Host "Healthy: $($result.isHealthy)" -ForegroundColor $(if ($result.isHealthy) { 'Green' } else { 'Yellow' })
Write-Host "  Index count:      $($result.counts.indexCount)" -ForegroundColor White
Write-Host "  Master count:     $($result.counts.masterCount)" -ForegroundColor White
Write-Host "  Index file count: $($result.counts.indexFileCount)" -ForegroundColor White
Write-Host "  Bundle count:     $($result.counts.bundleCount)" -ForegroundColor White
Write-Host "  Active files:     $($result.counts.activeFileCount)" -ForegroundColor White

Write-Host "`nChecks:" -ForegroundColor White
$result.checks.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value) { 'Green' } else { 'Red' }
    Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor $color
}

if ($null -ne $result.interruptions) {
    Write-Host "`nStale Interruptions: $($result.interruptions.total)" -ForegroundColor $(if ($result.interruptions.total -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  OPEN:        $($result.interruptions.byStatus.OPEN)" -ForegroundColor White
    Write-Host "  PLANNED:     $($result.interruptions.byStatus.PLANNED)" -ForegroundColor White
    Write-Host "  IN_PROGRESS: $($result.interruptions.byStatus.IN_PROGRESS)" -ForegroundColor White
    Write-Host "  BLOCKED:     $($result.interruptions.byStatus.BLOCKED)" -ForegroundColor White

    foreach ($item in @($result.interruptions.items) | Sort-Object status, @{ Expression = 'ageDays'; Descending = $true }, id | Select-Object -First 15) {
        Write-Host "  [$($item.status)] $($item.id) age=$($item.ageDays)d threshold=$($item.threshold)d :: $($item.title)" -ForegroundColor DarkYellow
    }
}

if ($resolvedReportPath) {
    Write-Host "`nReport: $resolvedReportPath" -ForegroundColor Gray
}

if (-not $result.isHealthy) {
    $failedChecks = @($result.checks.GetEnumerator() | Where-Object { -not $_.Value })
    if ($FailOnStale -or @($failedChecks).Count -gt 0) {
        exit 1
    }
}

exit 0
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




