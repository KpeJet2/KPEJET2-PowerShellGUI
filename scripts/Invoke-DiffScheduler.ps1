# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    Background diff routine using DiffPlex. Reads config/diff-scheduler.json.

.DESCRIPTION
    Engine choice (per user decision #5): DiffPlex.
    DiffPlex is loaded on first use; if missing, a console-side Compare-Object
    fallback is used so the pipeline never breaks when DiffPlex isn't present.

    Outputs to ~REPORTS/diffs/<label>-<ts>.{patch,json} and emits one normalized
    event row per pair via PwShGUI-EventLogAdapter (scope=pipeline).

.PARAMETER WorkspacePath
    Workspace root.
.PARAMETER ConfigPath
    Path to diff-scheduler.json. Defaults to <ws>/config/diff-scheduler.json.
.PARAMETER Once
    Run all configured pairs once and exit (default).
.PARAMETER Continuous
    Loop with -IntervalSec sleep between cycles.
.PARAMETER IntervalSec
    Sleep seconds when -Continuous. Default 3600 (1 hour).
.PARAMETER DryRun
    Do not write output files, only log.
.PARAMETER PairLabel
    Run only the named pair (filter).
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$Continuous,
    [int]   $IntervalSec = 3600,
    [switch]$DryRun,
    [string]$PairLabel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDir = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("diffscheduler-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")

function Write-DsLog {
    param([string]$Msg, [string]$Level = 'Info')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Try to import the EventLog adapter (optional).
$adapter = Join-Path $WorkspacePath 'modules\PwShGUI-EventLogAdapter.psm1'
$adapterLoaded = $false
if (Test-Path $adapter) {
    try { Import-Module $adapter -Force -DisableNameChecking; $adapterLoaded = $true } catch { Write-DsLog "Adapter import failed: $($_.Exception.Message)" 'Warning' }
}

function Emit-Event {
    param([string]$Sev, [string]$Component, [string]$Msg, [string]$Corr = '')
    if ($adapterLoaded) {
        try { Write-EventLogNormalized -Scope pipeline -Component $Component -Message $Msg -Severity $Sev -CorrId $Corr -WorkspacePath $WorkspacePath } catch { <# Intentional: non-fatal -- emit best-effort #> }
    }
}

if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $WorkspacePath 'config') 'diff-scheduler.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-DsLog "Config not found: $ConfigPath" 'Error'
    Emit-Event 'Error' 'DiffScheduler' "Config not found: $ConfigPath"
    exit 1
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$outDirRel = if ($cfg.PSObject.Properties.Name -contains 'outputDir' -and $cfg.outputDir) { [string]$cfg.outputDir } else { '~REPORTS/diffs' }
$outDir = Join-Path $WorkspacePath ($outDirRel -replace '/', '\')
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# DiffPlex loader -- search common locations.
$script:_DiffPlex = $null
function Initialize-DiffPlex {
    if ($script:_DiffPlex) { return $script:_DiffPlex }
    $candidates = @(
        (Join-Path $WorkspacePath 'tools\DiffPlex\DiffPlex.dll'),
        (Join-Path $WorkspacePath 'tools\DiffPlex.dll'),
        (Join-Path $WorkspacePath 'modules\DiffPlex\DiffPlex.dll')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            try {
                Add-Type -Path $c -ErrorAction Stop
                $script:_DiffPlex = [DiffPlex.DiffBuilder.InlineDiffBuilder]::Instance
                Write-DsLog "DiffPlex loaded: $c"
                return $script:_DiffPlex
            } catch {
                Write-DsLog "DiffPlex load failed at ${c}: $($_.Exception.Message)" 'Warning'
            }
        }
    }
    Write-DsLog 'DiffPlex assembly not found; falling back to Compare-Object line mode.' 'Warning'
    return $null
}

function Invoke-DiffPair {
    param([Parameter(Mandatory)] $Pair)
    $label = [string]$Pair.label
    $left  = $Pair.left;  if ($left  -and -not [System.IO.Path]::IsPathRooted([string]$left))  { $left  = Join-Path $WorkspacePath ([string]$left  -replace '/', '\') }
    $right = $Pair.right; if ($right -and -not [System.IO.Path]::IsPathRooted([string]$right)) { $right = Join-Path $WorkspacePath ([string]$right -replace '/', '\') }
    if (-not (Test-Path -LiteralPath $left))  { Write-DsLog "$label : left missing $left" 'Error'; Emit-Event 'Error' 'DiffScheduler' "Pair $label left missing: $left"; return }
    if (-not (Test-Path -LiteralPath $right)) { Write-DsLog "$label : right missing $right" 'Error'; Emit-Event 'Error' 'DiffScheduler' "Pair $label right missing: $right"; return }

    $leftText  = Get-Content -LiteralPath $left  -Raw -Encoding UTF8
    $rightText = Get-Content -LiteralPath $right -Raw -Encoding UTF8

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $patchOut = Join-Path $outDir "${label}-${ts}.patch"
    $jsonOut  = Join-Path $outDir "${label}-${ts}.json"

    $rows = @()
    $stats = [ordered]@{ added = 0; deleted = 0; unchanged = 0; modified = 0 }

    $dp = Initialize-DiffPlex
    if ($dp) {
        try {
            $model = $dp.BuildDiffModel($leftText, $rightText)
            foreach ($ln in $model.Lines) {
                $type = [string]$ln.Type
                $row  = [ordered]@{ type = $type; pos = [int]$ln.Position; text = [string]$ln.Text }
                $rows += $row
                switch ($type) { 'Inserted' { $stats.added++ } 'Deleted' { $stats.deleted++ } 'Modified' { $stats.modified++ } default { $stats.unchanged++ } }
            }
        } catch {
            Write-DsLog "DiffPlex BuildDiffModel failed for ${label}: $($_.Exception.Message); falling back" 'Warning'
            $dp = $null
        }
    }
    if (-not $dp) {
        # Compare-Object fallback line-mode.
        $L = $leftText  -split "`r?`n"
        $R = $rightText -split "`r?`n"
        $cmp = Compare-Object -ReferenceObject $L -DifferenceObject $R -IncludeEqual
        $i = 0
        foreach ($c in $cmp) {
            $i++
            $type = switch ($c.SideIndicator) { '<=' { 'Deleted' } '=>' { 'Inserted' } default { 'Unchanged' } }
            $rows += [ordered]@{ type = $type; pos = $i; text = [string]$c.InputObject }
            switch ($type) { 'Inserted' { $stats.added++ } 'Deleted' { $stats.deleted++ } default { $stats.unchanged++ } }
        }
    }

    $envelope = [ordered]@{
        label     = $label
        generated = (Get-Date).ToUniversalTime().ToString('o')
        engine    = if ($dp) { 'DiffPlex' } else { 'Compare-Object' }
        left      = $left
        right     = $right
        stats     = $stats
        rows      = $rows
    }

    if (-not $DryRun) {
        $envelope | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonOut -Encoding UTF8
        # Unified-style patch output.
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("--- $left")
        [void]$sb.AppendLine("+++ $right")
        foreach ($r in $rows) {
            $prefix = switch ($r.type) { 'Inserted' { '+' } 'Deleted' { '-' } 'Modified' { '~' } default { ' ' } }
            [void]$sb.AppendLine($prefix + $r.text)
        }
        Set-Content -LiteralPath $patchOut -Value $sb.ToString() -Encoding UTF8
        Write-DsLog "$label -> $patchOut (added=$($stats.added) deleted=$($stats.deleted) modified=$($stats.modified))"
        Emit-Event 'Info' 'DiffScheduler' ("Pair {0}: +{1}/-{2}/~{3} -> {4}" -f $label, $stats.added, $stats.deleted, $stats.modified, (Split-Path $patchOut -Leaf)) $label
    } else {
        Write-DsLog "$label DRYRUN -- would write $patchOut and $jsonOut"
    }
}

function Invoke-DiffCycle {
    $pairs = @($cfg.pairs)
    if ($PairLabel) { $pairs = @($pairs | Where-Object { $_.label -eq $PairLabel }) }
    if (-not @($pairs).Count) { Write-DsLog 'No pairs to process'; return }
    foreach ($p in $pairs) {
        try { Invoke-DiffPair -Pair $p } catch { Write-DsLog "Pair failed: $($_.Exception.Message)" 'Error' }
    }
}

Write-DsLog "DiffScheduler starting (Once=$($Once.IsPresent) Continuous=$($Continuous.IsPresent) DryRun=$($DryRun.IsPresent))"
if ($Continuous) {
    while ($true) {
        Invoke-DiffCycle
        Write-DsLog "Sleeping $IntervalSec sec..."
        Start-Sleep -Seconds $IntervalSec
    }
} else {
    Invoke-DiffCycle
}
Write-DsLog 'DiffScheduler complete'
exit 0

