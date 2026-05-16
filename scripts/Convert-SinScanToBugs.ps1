# VersionTag: 2605.B5.V46.1
<#
.SYNOPSIS
    Convert SIN scanner findings into pipeline Bug-*.json items.

.DESCRIPTION
    Reads temp/sin-scan-results.json (produced by tests/Invoke-SINPatternScanner.ps1)
    and creates one pipeline Bug per (sinId,file) pair via New-PipelineItem +
    Add-PipelineItem. Each Bug is stamped with sinPattern = canonical SIN-PATTERN-NNN
    so SIN-PATTERN-048 (linkage propagation) is satisfied at creation time.

    Default mode is dry-run. Pass -Apply to actually create Bug items. Pass
    -SeverityFilter CRITICAL,Blocking,HIGH to throttle the queue (default: critical+blocking).

    Closes residual gap G15 from the 2026-05-17 SIN governance audit.

.PARAMETER WorkspacePath
    Workspace root. Defaults to parent of script directory.

.PARAMETER ScanResultsPath
    JSON produced by Invoke-SINPatternScanner.ps1.

.PARAMETER SeverityFilter
    Severities to ingest. Default: CRITICAL, Blocking, HIGH.

.PARAMETER Apply
    Required to actually persist Bug items. Without -Apply, the script reports
    what WOULD be created.

.PARAMETER MaxItems
    Cap on number of bugs created in a single run (safety throttle). Default 50.

.EXAMPLE
    pwsh -File scripts\Convert-SinScanToBugs.ps1
    # Dry-run, shows what would be created.

.EXAMPLE
    pwsh -File scripts\Convert-SinScanToBugs.ps1 -Apply -MaxItems 25
    # Creates up to 25 Bug-*.json items from current scan results.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [string]$ScanResultsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'temp\sin-scan-results.json'),
    [string[]]$SeverityFilter = @('CRITICAL','Blocking','HIGH'),
    [switch]$Apply,
    [int]$MaxItems = 50
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScanResultsPath)) {
    throw "Scan results not found: $ScanResultsPath. Run tests/Invoke-SINPatternScanner.ps1 first."
}

$pipelineMod = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path -LiteralPath $pipelineMod)) {
    throw "Pipeline module not found: $pipelineMod"
}
Import-Module $pipelineMod -Force -DisableNameChecking

$scan = Get-Content -LiteralPath $ScanResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = @($scan.findings)
Write-Host ("Loaded {0} raw findings from scanner output ({1})." -f $findings.Count, $scan.generatedAt) -ForegroundColor Cyan

# Severity filter (case-insensitive). Accept canonical aliases.
$sevSet = @{}
foreach ($s in $SeverityFilter) { $sevSet[$s.ToUpperInvariant()] = $true }
$keep = @($findings | Where-Object { $sevSet.ContainsKey(([string]$_.severity).ToUpperInvariant()) })
Write-Host ("After severity filter [{0}]: {1} findings." -f ($SeverityFilter -join ','), $keep.Count) -ForegroundColor Gray

# Group by (sinId, file) so each Bug represents one violation hotspot, not one line.
$grouped = $keep | Group-Object -Property { '{0}|{1}' -f $_.sinId, $_.file }
Write-Host ("Distinct (sinId,file) hotspots: {0}." -f $grouped.Count) -ForegroundColor Gray

# Throttle.
$toCreate = @($grouped | Select-Object -First $MaxItems)
if ($toCreate.Count -lt $grouped.Count) {
    Write-Warning ("MaxItems={0} caps creation; {1} additional hotspots NOT ingested this run." -f $MaxItems, ($grouped.Count - $toCreate.Count))
}

# Skip duplicates: hotspots that already have an OPEN/IN-PROGRESS Bug-*.json with same sinPattern+file.
$todoDir = Join-Path $WorkspacePath 'todo'
$existing = @{}
if (Test-Path -LiteralPath $todoDir) {
    foreach ($bf in Get-ChildItem -Path $todoDir -Filter 'Bug-*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $bj = Get-Content -LiteralPath $bf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $st = if ($bj.PSObject.Properties.Name -contains 'status') { [string]$bj.status } else { '' }
            if ($st -in 'OPEN','IN-PROGRESS','IN_PROGRESS','PLANNED') {
                $sp = if ($bj.PSObject.Properties.Name -contains 'sinPattern') { [string]$bj.sinPattern } else { '' }
                $af = if ($bj.PSObject.Properties.Name -contains 'affectedFiles' -and @($bj.affectedFiles).Count -gt 0) { @($bj.affectedFiles)[0] } else { '' }
                if ($sp -and $af) { $existing["$sp|$af"] = $true }
            }
        } catch { <# Intentional: non-fatal -- malformed bug JSON silently skipped during dedup scan #> }
    }
}

$created = 0
$skippedDup = 0
$results = New-Object System.Collections.Generic.List[object]

foreach ($g in $toCreate) {
    $first = $g.Group | Select-Object -First 1
    $sinId = [string]$first.sinId   # e.g. SIN-PATTERN-027-NULL-ARRAY-INDEX
    $file  = [string]$first.file
    $sev   = [string]$first.severity
    $title = [string]$first.title
    $key = "$sinId|$file"
    if ($existing.ContainsKey($key)) {
        $skippedDup++
        $results.Add([pscustomobject]@{ action='skip-dup'; sinPattern=$sinId; file=$file; lines=$g.Count }) | Out-Null
        continue
    }

    # Map scanner severity -> pipeline priority enum (CRITICAL|HIGH|MEDIUM|LOW).
    $priority = switch -Regex ($sev) {
        '^(CRITICAL|CRIT|BLOCKING)$' { 'CRITICAL'; break }
        '^(HIGH|ERROR)$'             { 'HIGH';     break }
        '^(MEDIUM|WARN(ING)?)$'      { 'MEDIUM';   break }
        default                      { 'LOW' }
    }

    $bugTitle = '[SIN-SCAN] {0} :: {1}' -f $sinId, $title
    $sample = $g.Group | Select-Object -First 5 | ForEach-Object { 'line {0}: {1}' -f $_.line, $_.content }
    $desc = (@(
        "Scanner-detected violations of $sinId in $file ($($g.Count) hits).",
        "Title: $title",
        "Severity: $sev",
        "",
        "Sample matches:"
    ) + @($sample)) -join "`n"

    if ($PSCmdlet.ShouldProcess($key, 'Create Bug from SIN scan finding')) {
        if ($Apply) {
            $bug = New-PipelineItem -Type 'Bug' -Title $bugTitle -Description $desc `
                -Priority $priority -Source 'BugTracker' -Category 'sin-scan' `
                -AffectedFiles @($file) -SuggestedBy 'SIN-Scanner' `
                -SinPattern $sinId
            $bug.notes = "Created by Convert-SinScanToBugs from $sinId hotspot ($($g.Count) line hits)."
            Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bug | Out-Null
            $created++
            $results.Add([pscustomobject]@{ action='created'; id=$bug.id; sinPattern=$sinId; file=$file; lines=$g.Count; priority=$priority }) | Out-Null
        } else {
            $results.Add([pscustomobject]@{ action='dry-run'; sinPattern=$sinId; file=$file; lines=$g.Count; priority=$priority }) | Out-Null
        }
    }
}

# Audit report.
$reportDir = Join-Path $WorkspacePath '~REPORTS\sin-scan-bridge'
if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$tag = (Get-Date -Format 'yyyyMMdd-HHmmss')
$reportPath = Join-Path $reportDir ("sin-scan-bridge-$tag.json")
$audit = [ordered]@{}
try { $audit.Add('generated',      (Get-Date).ToUniversalTime().ToString('o')) } catch { Write-Host "ERR generated: $_"; throw }
try { $audit.Add('apply',          [bool]$Apply) } catch { Write-Host "ERR apply: $_"; throw }
try { $audit.Add('severityFilter', $SeverityFilter) } catch { Write-Host "ERR severityFilter: $_"; throw }
try { $audit.Add('maxItems',       $MaxItems) } catch { Write-Host "ERR maxItems: $_"; throw }
try { $audit.Add('rawFindings',    $findings.Count) } catch { Write-Host "ERR rawFindings: $_"; throw }
try { $audit.Add('afterFilter',    $keep.Count) } catch { Write-Host "ERR afterFilter: $_"; throw }
try { $audit.Add('hotspots',       $grouped.Count) } catch { Write-Host "ERR hotspots: $_"; throw }
try { $audit.Add('considered',     $toCreate.Count) } catch { Write-Host "ERR considered: $_"; throw }
try { $audit.Add('skippedDup',     $skippedDup) } catch { Write-Host "ERR skippedDup: $_"; throw }
try { $audit.Add('created',        $created) } catch { Write-Host "ERR created: $_"; throw }
try { $audit.Add('results',        ([object[]](@() + $results))) } catch { Write-Host "ERR results: $_"; throw }
$json = $audit | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($reportPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host ("Audit: {0}" -f $reportPath) -ForegroundColor Gray
Write-Host ('  raw={0} filtered={1} hotspots={2} considered={3} skippedDup={4} created={5}' -f $findings.Count, $keep.Count, $grouped.Count, $toCreate.Count, $skippedDup, $created) -ForegroundColor Cyan
if (-not $Apply) { Write-Host 'DRY-RUN: pass -Apply to actually create Bug items.' -ForegroundColor Yellow }
