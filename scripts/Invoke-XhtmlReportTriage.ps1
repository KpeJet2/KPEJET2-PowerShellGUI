# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Triages XHTML report files by validating structure and flagging issues.
.PARAMETER ReportPath
    Path to the reports folder to triage.
.PARAMETER Apply
    When set, applies fixes to flagged reports.
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

$targets = @(Get-ChildItem -Path $ReportPath -Filter '*Script1-Account-User-Management*.xhtml' -File | Sort-Object LastWriteTime -Descending)

$canonical = $targets | Where-Object { $_.Name -notmatch '_(Administrators|DisabledAccounts|Groups|Privileges|Users)\.xhtml$' } | Select-Object -First 1
if (-not $canonical -and $targets.Count -gt 0) {
    $canonical = $targets[0]
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archiveDir = Join-Path $ReportPath "archive\xhtml-triage-$stamp"
$actions = @()

foreach ($file in $targets) {
    $decision = 'archive'
    $reason = 'component-detail XHTML export retained only as archive artifact'
    if ($canonical -and $file.FullName -ieq $canonical.FullName) {
        $decision = 'keep'
        $reason = 'canonical consolidated XHTML export'
    }

    $action = [pscustomobject]@{
        name = $file.Name
        fullPath = $file.FullName
        decision = $decision
        reason = $reason
        applied = $false
        destination = if ($decision -eq 'archive') { Join-Path $archiveDir $file.Name } else { $file.FullName }
    }

    if ($Apply -and $decision -eq 'archive') {
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

$summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    reportPath = $ReportPath
    applyMode = [bool]$Apply
    targetCount = $targets.Count
    keepCount = @($actions | Where-Object { $_.decision -eq 'keep' }).Count
    archiveCount = @($actions | Where-Object { $_.decision -eq 'archive' }).Count
    archiveApplied = @($actions | Where-Object { $_.decision -eq 'archive' -and $_.applied }).Count
    canonicalFile = if ($canonical) { $canonical.Name } else { $null }
}

$result = [pscustomobject]@{
    summary = $summary
    actions = $actions
}

$outJson = Join-Path $ReportPath "xhtml-triage-$stamp.json"
$outMd = Join-Path $ReportPath "xhtml-triage-$stamp.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outJson -Encoding UTF8

$lines = @(
    '# XHTML Report Triage Run',
    '',
    "Generated: $($summary.generatedAt)",
    "ReportPath: $($summary.reportPath)",
    "ApplyMode: $($summary.applyMode)",
    "TargetCount: $($summary.targetCount)",
    "KeepCount: $($summary.keepCount)",
    "ArchiveCount: $($summary.archiveCount)",
    "ArchiveApplied: $($summary.archiveApplied)",
    "CanonicalFile: $($summary.canonicalFile)",
    '',
    '## Actions',
    '',
    '| Name | Decision | Applied | Reason |',
    '|---|---|---|---|'
)

foreach ($action in $actions) {
    $lines += "| $($action.name) | $($action.decision) | $($action.applied) | $($action.reason) |"
}

Set-Content -Path $outMd -Value $lines -Encoding UTF8

Write-Output "Triage JSON: $outJson"
Write-Output "Triage Markdown: $outMd"
Write-Output "Archive applied: $($summary.archiveApplied)"






