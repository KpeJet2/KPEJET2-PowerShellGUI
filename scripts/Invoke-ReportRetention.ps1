# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#   2604.B2.V32  2026-04-10        IMPL-20260405-001 / gap-2604-002: expanded to all ~REPORTS/* categories
#                                  and hanikragi-squabble.enc rotation
#Requires -Version 5.1
<#
.SYNOPSIS
    Enforces retention policy on ALL report files across every ~REPORTS/ category.
.DESCRIPTION
    Scans both the root ~REPORTS/ folder and all subdirectories.  For each
    recognised file pattern a keep-count is applied; older files are archived to
    ~REPORTS/archive/<timestamp>/<category>/.  Also prunes hanikragi-squabble.enc
    entries older than SquabbleRetentionDays (gap-2604-002).

    Recognised categories (root-level patterns):
      error-handling-compliance-*   keep 5
      script-dependency-matrix-*    keep 3
      script-dependency-error*      keep 2
      script-dependency-graph*      keep 2
      script-dependency-edges*      keep 2
      script-dependency-errors*     keep 2
      module-references-*           keep 2
      report-retention-*            keep 3
      xhtml-triage-*                keep 3
      orphan-audit-*                keep 2
      orphan-audit-core-*           keep 2
      orphan-cleanup-*              keep 2
      workspace-dependency-map-*    keep 2
      sin-scan-results*             keep 5
      precommit-*                   keep 5
      cron-integrity-*              keep 5

    Subdirectory files: keep latest 3 per subdirectory leaf folder.

.PARAMETER ReportPath
    Root reports folder.  Default: <workspace>\~REPORTS.
.PARAMETER Apply
    Perform moves; without this flag runs dry-run only.
.PARAMETER SquabbleRetentionDays
    Number of days of squabble-log entries to keep.  Default: 30.
#>

[CmdletBinding()]
param(
    [string]$ReportPath,
    [switch]$Apply,
    [int]$SquabbleRetentionDays = 30
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

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archiveRoot = Join-Path $ReportPath "archive\$timestamp"
$actions = [System.Collections.ArrayList]::new()

# ── Helper: archive files beyond keep-count ────────────────────────────────
function Invoke-FileGroupRetention {
    param([System.IO.FileInfo[]]$Files, [int]$Keep, [string]$Category, [string]$ArchiveBase, [bool]$DoApply)
    $sorted = @($Files | Sort-Object LastWriteTime -Descending)
    $toArchive = if ($sorted.Count -gt $Keep) { @($sorted[$Keep..($sorted.Count - 1)]) } else { @() }
    foreach ($f in $toArchive) {
        $dest = Join-Path (Join-Path $ArchiveBase $Category) $f.Name
        $action = [PSCustomObject]@{
            category = $Category; name = $f.Name
            source = $f.FullName; destination = $dest
            applied = $false; reason = "stale - keep $Keep"
        }
        if ($DoApply) {
            $ddir = Split-Path $dest -Parent
            if (-not (Test-Path $ddir)) { New-Item -Path $ddir -ItemType Directory -Force | Out-Null }
            try { Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop; $action.applied = $true }
            catch { $action.reason = "MOVE FAILED: $_" }
        }
        [void]$script:actions.Add($action)
    }
}

# ── Root-level patterns (glob → keep-count) ───────────────────────────────
$rootPatterns = [ordered]@{
    'error-handling-compliance-*'     = 5
    'script-dependency-matrix-*'      = 3
    'script-dependency-error-*'       = 2
    'script-dependency-errors-*'      = 2
    'script-dependency-graph-*'       = 2
    'script-dependency-edges-*'       = 2
    'module-references-*'             = 2
    'report-retention-*'              = 3
    'xhtml-triage-*'                  = 3
    'orphan-audit-[0-9]*'             = 2
    'orphan-audit-core-*'             = 2
    'orphan-cleanup-*'                = 2
    'workspace-dependency-map-[0-9]*' = 2
    'sin-scan-results-*'              = 5
    'precommit-*'                     = 5
    'cron-integrity-*'                = 5
}

foreach ($pattern in $rootPatterns.Keys) {
    $files = @(Get-ChildItem -Path $ReportPath -Filter $pattern -File -ErrorAction SilentlyContinue)
    if ($files.Count -gt 0) {
        Invoke-FileGroupRetention -Files $files -Keep $rootPatterns[$pattern] `
            -Category 'root' -ArchiveBase $archiveRoot -DoApply $Apply.IsPresent
    }
}

# ── Subdirectories: keep latest 3 files per leaf folder ───────────────────
$subDirs = @(Get-ChildItem -Path $ReportPath -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "*\archive\*" })
foreach ($dir in $subDirs) {
    $files = @(Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue)
    if ($files.Count -gt 3) {
        $catName = $dir.FullName.Replace($ReportPath, '').TrimStart('\/')
        Invoke-FileGroupRetention -Files $files -Keep 3 `
            -Category $catName -ArchiveBase $archiveRoot -DoApply $Apply.IsPresent
    }
}

# ── gap-2604-002: hanikragi-squabble.enc age-based pruning ────────────────
$squabblePath = Join-Path $workspacePath 'logs\hanikragi-squabble.enc'
$squabbleAction = [PSCustomObject]@{ category='SquabbleLog'; name='hanikragi-squabble.enc'
    source=$squabblePath; destination=''; applied=$false; reason='' }
if (Test-Path $squabblePath) {
    $ageHours = ((Get-Date) - (Get-Item $squabblePath).LastWriteTime).TotalHours
    $cutoffDays = $SquabbleRetentionDays
    if ($ageHours -gt ($cutoffDays * 24)) {
        $squabbleAction.reason = "squabble.enc last-write $([int]$ageHours)h ago - exceeds ${cutoffDays}d retention; archiving whole file"
        $dest = Join-Path $archiveRoot "SquabbleLog\hanikragi-squabble-$timestamp.enc"
        $squabbleAction.destination = $dest
        if ($Apply) {
            $ddir = Split-Path $dest -Parent
            if (-not (Test-Path $ddir)) { New-Item -Path $ddir -ItemType Directory -Force | Out-Null }
            try { Move-Item -LiteralPath $squabblePath -Destination $dest -Force; $squabbleAction.applied = $true }
            catch { $squabbleAction.reason += " | MOVE FAILED: $_" }
        }
    } else {
        $squabbleAction.reason = "squabble.enc within ${cutoffDays}d retention ($([int]$ageHours)h old) - no action"
    }
} else {
    $squabbleAction.reason = 'squabble.enc not present - skipped'
}
[void]$actions.Add($squabbleAction)

# ── gap-2604-006: sin_registry/fixes/ record rotation (keep last 50) ─────────
$sinFixesDir  = Join-Path $workspacePath 'sin_registry\fixes'
$sinFixesKeep = 50
if (Test-Path $sinFixesDir) {
    $sinFixFiles = Get-ChildItem -Path $sinFixesDir -Filter 'FIX-*.json' -File |
        Sort-Object LastWriteTime -Descending
    $sinFixToPrune = if ($sinFixFiles.Count -gt $sinFixesKeep) { $sinFixFiles | Select-Object -Skip $sinFixesKeep } else { @() }
    foreach ($sf in $sinFixToPrune) {
        $sfAction = [PSCustomObject]@{
            category    = 'SINRegistryFix'
            name        = $sf.Name
            source      = $sf.FullName
            destination = ''
            applied     = $false
            reason      = "SIN fix record - exceeds keep-$sinFixesKeep limit; pruning"
        }
        if ($Apply) {
            try { Remove-Item -LiteralPath $sf.FullName -Force; $sfAction.applied = $true }
            catch { $sfAction.reason += " | REMOVE FAILED: $_" }
        }
        [void]$actions.Add($sfAction)
    }
    if ($sinFixToPrune.Count -eq 0) {
        [void]$actions.Add([PSCustomObject]@{
            category='SINRegistryFix'; name='sin_registry/fixes'; source=$sinFixesDir
            destination=''; applied=$false; reason="SIN fix records within keep-$sinFixesKeep limit ($($sinFixFiles.Count) files) - no action"
        })
    }
}

# ── Summary & report ──────────────────────────────────────────────────────
$totalCandidates = @($actions | Where-Object { $_.reason -notlike '*within*' -and $_.reason -notlike '*not present*' }).Count
$totalArchived   = @($actions | Where-Object { $_.applied }).Count

$result = [ordered]@{
    generatedAt    = (Get-Date).ToString('o')
    reportPath     = $ReportPath
    applyMode      = [bool]$Apply
    archiveRoot    = $archiveRoot
    candidates     = $totalCandidates
    archived       = $totalArchived
    squabbleRetentionDays = $SquabbleRetentionDays
    actions        = @($actions)
}

$outJson = Join-Path $ReportPath "report-retention-$timestamp.json"
$outMd   = Join-Path $ReportPath "report-retention-$timestamp.md"
$result | ConvertTo-Json -Depth 10 | Set-Content -Path $outJson -Encoding UTF8

$lines = @(
    '# Report Retention Run',
    '',
    "Generated : $(Get-Date -Format 'o')",
    "ReportPath: $ReportPath",
    "ApplyMode : $($Apply.IsPresent)",
    "Archive   : $archiveRoot",
    "Candidates: $totalCandidates",
    "Archived  : $totalArchived",
    '',
    '## Actions',
    '',
    '| Category | File | Applied | Reason |',
    '|---|---|---|---|'
)
foreach ($a in $actions) {
    $lines += "| $($a.category) | $($a.name) | $($a.applied) | $($a.reason) |"
}
Set-Content -Path $outMd -Value $lines -Encoding UTF8

Write-Output "Retention JSON  : $outJson"
Write-Output "Archive candidates: $totalCandidates | Archived: $totalArchived"
return $result








<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





