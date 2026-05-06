# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    Auto-approval writer for PENDING_APPROVAL items older than the configured
    cool-off (default 7 days) that no human has approved.

.DESCRIPTION
    Implements user policy decision: "Auto writer for implementing 7 day old
    items not approved by a human."

    For each todo/*.json in PENDING_APPROVAL with age >= AgeDays:
      - Append status_history entry { status: 'AUTO_APPROVED', by: 'auto-approval-writer', timestamp, reason }
      - Set status to 'AUTO_APPROVED' (a new terminal-pending lifecycle state
        consumable downstream by Invoke-PipelineProcess20 to flip to IN-PROGRESS)
      - Add field autoApprovedAt = ISO timestamp
      - Idempotent: items already AUTO_APPROVED are skipped

    Then rebuilds todo/_bundle.js so the GUI/dashboard sees the change.

.PARAMETER WorkspacePath
    Workspace root.
.PARAMETER AgeDays
    Cool-off threshold in days. Default 7.
.PARAMETER DryRun
    Report what would change without writing.
.PARAMETER MaxPerRun
    Safety cap; default 100.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [int]$AgeDays = 7,
    [switch]$DryRun,
    [int]$MaxPerRun = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$todoDir = Join-Path $WorkspacePath 'todo'
$logDir  = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("auto-approval-writer-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")

function Write-AaLog {
    param([string]$Msg, [string]$Level = 'Info')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Optional adapter for normalized event emission.
$adapter = Join-Path $WorkspacePath 'modules\PwShGUI-EventLogAdapter.psm1'
$adapterLoaded = $false
if (Test-Path $adapter) { try { Import-Module $adapter -Force -DisableNameChecking; $adapterLoaded = $true } catch { <# Intentional: non-fatal -- adapter optional #> } }

$script:AaEventSeq = 0
$script:AaActionId = 'auto-approval-' + ([guid]::NewGuid().ToString().Substring(0,8))
$script:AaAgentId = 'auto-approval-writer'
$script:AaEditor = [string]$env:USERNAME

function New-AaEventId {
    $script:AaEventSeq++
    return [int64]('{0}{1:D3}' -f (Get-Date -Format 'yyMMddHHmmss'), $script:AaEventSeq)
}

function Emit-Event {
    param(
        [string]$Sev,
        [string]$Msg,
        [string]$Corr = '',
        [string]$ItemId = '',
        [string]$ItemType = 'ToDo'
    )
    if ($adapterLoaded) {
        try {
            Write-EventLogNormalized -Scope pipeline -Component 'AutoApprovalWriter' -Message $Msg -Severity $Sev -CorrId $Corr -WorkspacePath $WorkspacePath -EventId (New-AaEventId) -ItemId $ItemId -ItemType $ItemType -ActionId $script:AaActionId -AgentId $script:AaAgentId -Editor $script:AaEditor
        } catch { <# Intentional: non-fatal -- emit best-effort #> }
    }
}

if (-not (Test-Path $todoDir)) { Write-AaLog "Todo dir missing: $todoDir" 'Error'; exit 1 }
$now = (Get-Date).ToUniversalTime()
$nowIso = $now.ToString('o')
$cutoff = $now.AddDays(-$AgeDays)

Write-AaLog "Auto-approval writer starting (AgeDays=$AgeDays cutoff=$($cutoff.ToString('o')) DryRun=$($DryRun.IsPresent) MaxPerRun=$MaxPerRun)"
Emit-Event -Sev 'Info' -Msg ("Auto-approval writer starting (AgeDays={0}, DryRun={1}, MaxPerRun={2})" -f $AgeDays, $DryRun.IsPresent, $MaxPerRun)

$files = @(Get-ChildItem -LiteralPath $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
$promoted = 0
$skipped  = 0
$processed = @()

foreach ($f in $files) {
    if ($promoted -ge $MaxPerRun) { break }
    try {
        $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { Write-AaLog "Parse failed: $($f.Name) -- $($_.Exception.Message)" 'Warning'; continue }

    $status = if ($obj.PSObject.Properties.Name -contains 'status') { [string]$obj.status } else { '' }
    if ($status -ne 'PENDING_APPROVAL') { continue }

    # Determine anchor timestamp.
    $anchor = $null
    foreach ($p in @('plannedAt','modified','created','createdAt')) {
        if ($obj.PSObject.Properties.Name -contains $p -and $null -ne $obj.$p -and [string]$obj.$p) { $anchor = $obj.$p; break }
    }
    if ($null -eq $anchor) { Write-AaLog "Skip (no timestamp): $($f.Name)" 'Warning'; $skipped++; continue }
    $anchorDt = $null
    try {
        if ($anchor -is [DateTime]) {
            $anchorDt = $anchor.ToUniversalTime()
        } else {
            $anchorText = [string]$anchor
            try {
                $anchorDt = [DateTime]::Parse($anchorText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } catch {
                $anchorDt = [DateTime]::Parse($anchorText).ToUniversalTime()
            }
        }
    } catch {
        Write-AaLog "Skip (invalid timestamp '$anchor' in $($f.Name)): $($_.Exception.Message)" 'Warning'
        $skipped++
        continue
    }
    if ($anchorDt -gt $cutoff) { continue }

    # Promote.
    $oldStatus = $status
    $obj.status = 'AUTO_APPROVED'
    if ($obj.PSObject.Properties.Name -contains 'modified') { $obj.modified = $nowIso } else { Add-Member -InputObject $obj -NotePropertyName modified -NotePropertyValue $nowIso -Force }
    if ($obj.PSObject.Properties.Name -contains 'autoApprovedAt') { $obj.autoApprovedAt = $nowIso } else { Add-Member -InputObject $obj -NotePropertyName autoApprovedAt -NotePropertyValue $nowIso -Force }

    $hist = @()
    if ($obj.PSObject.Properties.Name -contains 'status_history' -and $obj.status_history) { $hist = @($obj.status_history) }
    $hist += [ordered]@{ status = 'AUTO_APPROVED'; by = 'auto-approval-writer'; timestamp = $nowIso; reason = "No human approval after $AgeDays day(s) since $anchor"; previousStatus = $oldStatus }
    if ($obj.PSObject.Properties.Name -contains 'status_history') { $obj.status_history = $hist } else { Add-Member -InputObject $obj -NotePropertyName status_history -NotePropertyValue $hist -Force }

    $title = if ($obj.PSObject.Properties.Name -contains 'title') { [string]$obj.title } else { $f.BaseName }
    $id    = if ($obj.PSObject.Properties.Name -contains 'id')    { [string]$obj.id }    else { $f.BaseName }

    if (-not $DryRun) {
        $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
    }
    $promoted++
    $processed += [ordered]@{ id = $id; title = $title; ageDays = [Math]::Round(($now - $anchorDt).TotalDays, 1); file = $f.Name }
    Write-AaLog ("AUTO_APPROVED: {0} ({1}, {2:N1}d old)" -f $id, $title, ($now - $anchorDt).TotalDays)
    Emit-Event -Sev 'Audit' -Msg ("Auto-approved {0}: {1} ({2:N1}d)" -f $id, $title, ($now - $anchorDt).TotalDays) -Corr $id -ItemId $id -ItemType 'ToDo'
}

Write-AaLog "Summary: promoted=$promoted skipped=$skipped totalScanned=$(@($files).Count)"
Emit-Event -Sev 'Info' -Msg "AutoApproval cycle complete: promoted=$promoted skipped=$skipped"

# Rebuild bundle (best-effort).
if (-not $DryRun -and $promoted -gt 0) {
    $rebuild = Join-Path $WorkspacePath 'scripts\Invoke-TodoBundleRebuild.ps1'
    if (Test-Path $rebuild) {
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $rebuild | Out-Null
            Write-AaLog 'Bundle rebuilt'
        } catch { Write-AaLog "Bundle rebuild failed: $($_.Exception.Message)" 'Warning' }
    }
}

# Write report.
$reportDir = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$reportFile = Join-Path $reportDir ("AutoApproval-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".json")
[ordered]@{
    generatedAt = $nowIso
    ageDaysThreshold = $AgeDays
    dryRun = [bool]$DryRun.IsPresent
    promoted = $promoted
    skipped  = $skipped
    items    = $processed
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding UTF8
Write-AaLog "Report: $reportFile"
exit 0

