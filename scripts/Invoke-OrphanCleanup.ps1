# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Removes or archives orphaned files identified by Invoke-OrphanAudit.
.PARAMETER ReportPath
    Path containing orphan audit reports.
.PARAMETER Apply
    When set, actually deletes/archives orphans instead of dry-run.
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

$latestAudit = Get-ChildItem -Path $ReportPath -Filter 'orphan-audit-*.json' -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latestAudit) {
    throw "No orphan audit JSON files found in $ReportPath"
}

$audit = Get-Content -Path $latestAudit.FullName -Raw | ConvertFrom-Json
$candidates = @($audit.candidates)

$dedupMap = @{}
foreach ($candidate in $candidates) {
    if (-not $dedupMap.ContainsKey($candidate.relativePath)) {
        $dedupMap[$candidate.relativePath] = $candidate
    }
}

$deduped = @($dedupMap.Values)

$safeTempNames = @(
    'run-orphan-audit-core.ps1',
    'server_stderr.txt',
    'server_stdout.txt',
    '_gui_test.ps1',
    '_gui_wrap.ps1'
)

$actions = foreach ($candidate in $deduped) {
    $folder = [string]$candidate.folder
    $name = [string]$candidate.fileName
    $fullPath = [string]$candidate.fullPath

    $decision = 'keep'
    $reason = 'outside safe auto-clean scope'

    if ($folder -ieq 'temp' -and $safeTempNames -contains $name) {
        $decision = 'delete'
        $reason = 'known generated temp artifact'
    }

    [pscustomobject]@{
        relativePath = [string]$candidate.relativePath
        fullPath = $fullPath
        folder = $folder
        fileName = $name
        decision = $decision
        reason = $reason
        exists = (Test-Path $fullPath)
        applied = $false
    }
}

if ($Apply) {
    foreach ($action in ($actions | Where-Object { $_.decision -eq 'delete' -and $_.exists })) {
        try {
            Remove-Item -LiteralPath $action.fullPath -Force -ErrorAction Stop
            $action.applied = $true
            $action.exists = $false
        } catch {
            $action.reason = "delete failed: $_"
        }
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outJson = Join-Path $ReportPath "orphan-cleanup-$stamp.json"
$outMd = Join-Path $ReportPath "orphan-cleanup-$stamp.md"

$summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    sourceAudit = $latestAudit.FullName
    applyMode = [bool]$Apply
    totalCandidates = $candidates.Count
    dedupedCandidates = $deduped.Count
    deletePlanned = @($actions | Where-Object { $_.decision -eq 'delete' }).Count
    deleteApplied = @($actions | Where-Object { $_.applied -eq $true }).Count
}

$result = [pscustomobject]@{
    summary = $summary
    actions = $actions
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outJson -Encoding UTF8

$lines = @(
    '# Orphan Cleanup Run',
    '',
    "Generated: $($summary.generatedAt)",
    "Source Audit: $($summary.sourceAudit)",
    "Apply Mode: $($summary.applyMode)",
    "Total Candidates: $($summary.totalCandidates)",
    "Deduped Candidates: $($summary.dedupedCandidates)",
    "Delete Planned: $($summary.deletePlanned)",
    "Delete Applied: $($summary.deleteApplied)",
    '',
    '## Actions',
    '',
    '| RelativePath | Decision | Applied | Reason |',
    '|---|---|---|---|'
)

foreach ($action in $actions) {
    $lines += "| $($action.relativePath) | $($action.decision) | $($action.applied) | $($action.reason) |"
}

Set-Content -Path $outMd -Value $lines -Encoding UTF8

Write-Output "Cleanup JSON: $outJson"
Write-Output "Cleanup Markdown: $outMd"
Write-Output "Delete planned: $($summary.deletePlanned)"
Write-Output "Delete applied: $($summary.deleteApplied)"







<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





