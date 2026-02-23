# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Enforces retention policy on report files, archiving or deleting old reports.
.PARAMETER ReportPath
    Path to the reports folder to manage.
.PARAMETER Apply
    When set, actually removes/archives expired reports.
#>

[CmdletBinding()]
param(
    [string]$ReportPath,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspacePath = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $workspacePath '~REPORTS'
}
if (-not (Test-Path $ReportPath)) {
    throw "Report path not found: $ReportPath"
}

$orphanAudits = @(Get-ChildItem -Path $ReportPath -Filter 'orphan-audit-*.json' -File | Sort-Object LastWriteTime -Descending)
$orphanAuditMds = @(Get-ChildItem -Path $ReportPath -Filter 'orphan-audit-core-*.md' -File | Sort-Object LastWriteTime -Descending)
$cleanupReports = @(Get-ChildItem -Path $ReportPath -Filter 'orphan-cleanup-*.*' -File | Sort-Object LastWriteTime -Descending)

$keepSet = New-Object 'System.Collections.Generic.HashSet[string]'
if ($orphanAudits.Count -gt 0) { $keepSet.Add($orphanAudits[0].FullName) | Out-Null }
if ($orphanAuditMds.Count -gt 0) { $keepSet.Add($orphanAuditMds[0].FullName) | Out-Null }
if ($cleanupReports.Count -gt 0) {
    $latestCleanupStamp = [System.IO.Path]::GetFileNameWithoutExtension($cleanupReports[0].Name) -replace '^orphan-cleanup-',''
    foreach ($f in $cleanupReports) {
        if ($f.Name -like "orphan-cleanup-$latestCleanupStamp.*") {
            $keepSet.Add($f.FullName) | Out-Null
        }
    }
}

$candidates = @($orphanAudits + $orphanAuditMds + $cleanupReports | Sort-Object FullName -Unique)
$archiveCandidates = @($candidates | Where-Object { -not $keepSet.Contains($_.FullName) })

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archiveDir = Join-Path $ReportPath "archive\$timestamp"
$actions = @()

foreach ($file in $archiveCandidates) {
    $action = [pscustomobject]@{
        name = $file.Name
        source = $file.FullName
        destination = (Join-Path $archiveDir $file.Name)
        applied = $false
        reason = 'archive stale generated report artifact'
    }

    if ($Apply) {
        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        }
        try {
            Move-Item -LiteralPath $file.FullName -Destination $action.destination -Force -ErrorAction Stop
            $action.applied = $true
        } catch {
            $action.reason = "archive failed: $_"
        }
    }

    $actions += $action
}

$result = [pscustomobject]@{
    summary = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        reportPath = $ReportPath
        applyMode = [bool]$Apply
        archiveDirectory = $archiveDir
        candidates = $archiveCandidates.Count
        archived = @($actions | Where-Object { $_.applied }).Count
    }
    actions = $actions
}

$outJson = Join-Path $ReportPath "report-retention-$timestamp.json"
$outMd = Join-Path $ReportPath "report-retention-$timestamp.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outJson -Encoding UTF8

$lines = @(
    '# Report Retention Run',
    '',
    "Generated: $($result.summary.generatedAt)",
    "ReportPath: $($result.summary.reportPath)",
    "ApplyMode: $($result.summary.applyMode)",
    "ArchiveDirectory: $($result.summary.archiveDirectory)",
    "Candidates: $($result.summary.candidates)",
    "Archived: $($result.summary.archived)",
    '',
    '## Actions',
    '',
    '| Name | Applied | Reason |',
    '|---|---|---|'
)

foreach ($a in $actions) {
    $lines += "| $($a.name) | $($a.applied) | $($a.reason) |"
}

Set-Content -Path $outMd -Value $lines -Encoding UTF8

Write-Output "Retention JSON: $outJson"
Write-Output "Retention Markdown: $outMd"
Write-Output "Archive candidates: $($result.summary.candidates)"
Write-Output "Archived: $($result.summary.archived)"






