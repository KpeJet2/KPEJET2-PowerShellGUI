# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
# PipelineStage: pre-new-work
# PipelineOrder: 0
<#
.SYNOPSIS
    Cod-Rhi-Pear -- Pre-new-work governance gate.

.DESCRIPTION
    Objective (verbatim, per user mandate):
        "aim to complete any incomplete todo items before adding or altering any
         code scope further"

    Detect-and-assess pipeline that runs BEFORE any new work-processing pipeline
    stage. Scans todo/*.json for non-terminal statuses, reassesses each against
    the current workspace state to determine whether the underlying code has
    moved on since the todo was created (which would risk regression if the
    item were resumed blindly), then classifies each into:

        AUTO_CLOSE     - Referenced files are gone or work is clearly done.
        STILL_PENDING  - Referenced files unchanged since todo created; safe to resume.
        STALE_REVIEW   - Referenced files modified after the todo was created;
                         needs human reassessment before resuming.
        ORPHAN         - No file references and no scope hints; classify by age only.

    Exit codes:
        0  All clear (no STILL_PENDING items, or -ReportOnly).
        2  STILL_PENDING items exist and -Block was supplied (gate fails).
        1  Hard error.

.PARAMETER WorkspacePath
    Workspace root. Defaults to parent of this script.

.PARAMETER ReportOnly
    Generate report; never fail the gate.

.PARAMETER Block
    Exit code 2 when STILL_PENDING items exist. Used in CI / pre-work guard.

.PARAMETER MaxAgeDays
    Items older than this in OPEN are flagged regardless. Default 14.

.PARAMETER Statuses
    Non-terminal statuses to scan. Default covers OPEN/PLANNED/IN_PROGRESS/
    IN-PROGRESS/PENDING_APPROVAL/BLOCKED/NEW.

.EXAMPLE
    pwsh -File scripts/Invoke-CodRhiPear.ps1 -ReportOnly

.EXAMPLE
    pwsh -File scripts/Invoke-CodRhiPear.ps1 -Block
#>
[CmdletBinding()]
param(
    [string]   $WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]   $ReportOnly,
    [switch]   $Block,
    [int]      $MaxAgeDays    = 14,
    [string[]] $Statuses      = @('OPEN','PLANNED','IN_PROGRESS','IN-PROGRESS','PENDING_APPROVAL','BLOCKED','NEW')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths ---------------------------------------------------------------
$todoDir   = Join-Path $WorkspacePath 'todo'
$logDir    = Join-Path $WorkspacePath 'logs'
$reportDir = Join-Path $WorkspacePath '~REPORTS'
foreach ($d in @($logDir, $reportDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile   = Join-Path $logDir   ("codrhipear-$ts.log")
$jsonFile  = Join-Path $reportDir ("CodRhiPear-$ts.json")
$mdFile    = Join-Path $reportDir ("CodRhiPear-$ts.md")

# --- Logging -------------------------------------------------------------
function Write-CrpLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

Write-CrpLog "Cod-Rhi-Pear starting (ReportOnly=$($ReportOnly.IsPresent), Block=$($Block.IsPresent))"
Write-CrpLog "Objective: aim to complete any incomplete todo items before adding or altering any code scope further"

if (-not (Test-Path $todoDir)) {
    Write-CrpLog "Todo dir not found: $todoDir" 'ERROR'
    exit 1
}

# --- Helpers -------------------------------------------------------------
function Get-PropOrDefault {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Test-StatusIsNonTerminal {
    param([string]$Status, [string[]]$Allow)
    if ([string]::IsNullOrWhiteSpace($Status)) { return $false }
    $norm = $Status.Trim().ToUpperInvariant()
    foreach ($a in $Allow) { if ($norm -eq $a.ToUpperInvariant()) { return $true } }
    return $false
}

function Get-TodoFileRefs {
    param($Item)
    $refs = @()
    foreach ($candidate in @('file_refs','fileRefs','files','file','path','target','source')) {
        $v = Get-PropOrDefault -Object $Item -Name $candidate
        if ($null -eq $v) { continue }
        if ($v -is [string]) { if ($v) { $refs += $v } }
        elseif ($v -is [System.Collections.IEnumerable]) {
            foreach ($x in $v) { if ($x -is [string] -and $x) { $refs += $x } }
        }
    }
    return @($refs | Select-Object -Unique)
}

function Resolve-RefAbsolute {
    param([string]$Ref)
    if ([System.IO.Path]::IsPathRooted($Ref)) { return $Ref }
    return (Join-Path $WorkspacePath $Ref)
}

# --- Scan ----------------------------------------------------------------
$todoFiles = @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
Write-CrpLog "Loaded $(@($todoFiles).Count) todo files from $todoDir"

$now      = [DateTime]::UtcNow
$findings = @()
$parseFail = 0

foreach ($tf in $todoFiles) {
    try {
        $item = Get-Content $tf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $parseFail++
        Write-CrpLog "Parse failed: $($tf.Name) -- $($_.Exception.Message)" 'WARN'
        continue
    }

    $status = [string](Get-PropOrDefault -Object $item -Name 'status' -Default '')
    if (-not (Test-StatusIsNonTerminal -Status $status -Allow $Statuses)) { continue }

    $created  = [string](Get-PropOrDefault -Object $item -Name 'created'  -Default '')
    $modified = [string](Get-PropOrDefault -Object $item -Name 'modified' -Default $created)
    $ageDays  = $null
    $createdDt = $null
    if ($created) {
        try { $createdDt = [DateTime]::Parse($created); $ageDays = [Math]::Round(($now - $createdDt).TotalDays, 1) } catch { <# Intentional: non-fatal -- malformed date leaves ageDays null #> }
    }

    $refs        = Get-TodoFileRefs -Item $item
    $refDetails  = @()
    $missing     = 0
    $modifiedAft = 0
    $present     = 0

    foreach ($r in $refs) {
        $abs = Resolve-RefAbsolute -Ref $r
        if (-not (Test-Path -LiteralPath $abs)) {
            $missing++
            $refDetails += [ordered]@{ ref = $r; state = 'missing' }
            continue
        }
        $present++
        $fi = Get-Item -LiteralPath $abs -ErrorAction SilentlyContinue
        $fmod = $null
        if ($fi) {
            $fmod = $fi.LastWriteTimeUtc
            if ($createdDt -and $fmod -gt $createdDt) { $modifiedAft++ }
        }
        $refDetails += [ordered]@{
            ref           = $r
            state         = 'present'
            lastWriteUtc  = if ($fmod) { $fmod.ToString('o') } else { '' }
            modifiedAfter = ($createdDt -and $fmod -and $fmod -gt $createdDt)
        }
    }

    # Classify
    $classification = 'STILL_PENDING'
    $reason         = 'Default: non-terminal status with refs unchanged or no refs.'

    if (@($refs).Count -eq 0) {
        $classification = 'ORPHAN'
        $reason = 'No file references; cannot reassess scope automatically.'
        if ($null -ne $ageDays -and $ageDays -gt $MaxAgeDays) {
            $reason += " Age $ageDays d > $MaxAgeDays d threshold."
        }
    }
    elseif ($missing -eq @($refs).Count -and @($refs).Count -gt 0) {
        $classification = 'AUTO_CLOSE'
        $reason = 'All referenced files are missing -- work likely completed or scope removed.'
    }
    elseif ($modifiedAft -gt 0) {
        $classification = 'STALE_REVIEW'
        $reason = "$modifiedAft of $present referenced file(s) modified after todo created -- regression risk if resumed without review."
    }

    $findings += [ordered]@{
        id             = [string](Get-PropOrDefault -Object $item -Name 'id' -Default $tf.BaseName)
        file           = $tf.Name
        title          = [string](Get-PropOrDefault -Object $item -Name 'title' -Default '')
        status         = $status
        priority       = [string](Get-PropOrDefault -Object $item -Name 'priority' -Default '')
        category       = [string](Get-PropOrDefault -Object $item -Name 'category' -Default '')
        created        = $created
        modified       = $modified
        ageDays        = $ageDays
        refCount       = @($refs).Count
        refsMissing    = $missing
        refsPresent    = $present
        refsModifiedAfter = $modifiedAft
        classification = $classification
        reason         = $reason
        refs           = $refDetails
    }
}

# --- Summary -------------------------------------------------------------
$byClass = $findings | Group-Object classification | ForEach-Object {
    [ordered]@{ classification = $_.Name; count = @($_.Group).Count }
}
$stillPending = @($findings | Where-Object { $_.classification -eq 'STILL_PENDING' })
$staleReview  = @($findings | Where-Object { $_.classification -eq 'STALE_REVIEW' })
$autoClose    = @($findings | Where-Object { $_.classification -eq 'AUTO_CLOSE' })
$orphans      = @($findings | Where-Object { $_.classification -eq 'ORPHAN' })

$report = [ordered]@{
    generatedAt   = $now.ToString('o')
    pipeline      = 'Cod-Rhi-Pear'
    pipelineStage = 'pre-new-work'
    pipelineOrder = 0
    objective     = 'aim to complete any incomplete todo items before adding or altering any code scope further'
    workspace     = $WorkspacePath
    scannedFiles  = @($todoFiles).Count
    parseFailures = $parseFail
    statusesScanned = $Statuses
    maxAgeDays    = $MaxAgeDays
    summary       = [ordered]@{
        total         = @($findings).Count
        stillPending  = @($stillPending).Count
        staleReview   = @($staleReview).Count
        autoClose     = @($autoClose).Count
        orphan        = @($orphans).Count
        byClass       = @($byClass)
    }
    findings      = @($findings)
}

# --- Write report --------------------------------------------------------
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonFile -Encoding UTF8
Write-CrpLog "JSON report: $jsonFile"

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Cod-Rhi-Pear Report')
[void]$md.AppendLine('')
[void]$md.AppendLine("Generated: $($report.generatedAt)")
[void]$md.AppendLine("Stage: pre-new-work | Order: 0")
[void]$md.AppendLine('')
[void]$md.AppendLine('> Objective: aim to complete any incomplete todo items before adding or altering any code scope further')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Summary')
[void]$md.AppendLine('')
[void]$md.AppendLine("| Metric | Count |")
[void]$md.AppendLine("|---|---|")
[void]$md.AppendLine("| Scanned todo files | $($report.scannedFiles) |")
[void]$md.AppendLine("| Parse failures | $($report.parseFailures) |")
[void]$md.AppendLine("| Total non-terminal | $($report.summary.total) |")
[void]$md.AppendLine("| STILL_PENDING (gate-blocking) | $($report.summary.stillPending) |")
[void]$md.AppendLine("| STALE_REVIEW (needs human review) | $($report.summary.staleReview) |")
[void]$md.AppendLine("| AUTO_CLOSE candidates | $($report.summary.autoClose) |")
[void]$md.AppendLine("| ORPHAN (no refs) | $($report.summary.orphan) |")
[void]$md.AppendLine('')
foreach ($cls in @('STILL_PENDING','STALE_REVIEW','AUTO_CLOSE','ORPHAN')) {
    $rows = @($findings | Where-Object { $_.classification -eq $cls })
    if (-not @($rows).Count) { continue }
    [void]$md.AppendLine("## $cls ($(@($rows).Count))")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| ID | Status | Age (d) | Refs | Reason |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    foreach ($r in $rows) {
        $age = if ($null -ne $r.ageDays) { $r.ageDays } else { '?' }
        $refStr = "P:$($r.refsPresent) M:$($r.refsMissing) +Mod:$($r.refsModifiedAfter)"
        [void]$md.AppendLine("| $($r.id) | $($r.status) | $age | $refStr | $($r.reason) |")
    }
    [void]$md.AppendLine('')
}
$md.ToString() | Set-Content -Path $mdFile -Encoding UTF8
Write-CrpLog "Markdown report: $mdFile"

Write-CrpLog ("Summary: total={0} stillPending={1} staleReview={2} autoClose={3} orphan={4}" -f `
    $report.summary.total, $report.summary.stillPending, $report.summary.staleReview, `
    $report.summary.autoClose, $report.summary.orphan)

# --- Gate ----------------------------------------------------------------
if ($Block -and -not $ReportOnly -and $report.summary.stillPending -gt 0) {
    Write-CrpLog "GATE FAIL: $($report.summary.stillPending) STILL_PENDING item(s) must be completed before new code scope is altered." 'ERROR'
    exit 2
}

Write-CrpLog "GATE PASS"
exit 0

