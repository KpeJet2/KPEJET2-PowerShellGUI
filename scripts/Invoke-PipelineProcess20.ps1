# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    One-shot pipeline processor: 20 Bugs2FIX -> IN-PROGRESS,
    1 Feature2ADD -> series of PENDING_APPROVAL Items2Do,
    promotes resurfacing bug titles to SIN candidates.
.NOTES
    Status lifecycle:
        OPEN -> PENDING_APPROVAL -> IN-PROGRESS -> IMPLEMENTED -> CLOSED (after 13 day cool-off)
    Closure rule: Status=IMPLEMENTED, plus no recurrence of same title for 13 consecutive days,
    then Convert-ImplementedToClosed.ps1 (separate cron job) flips to CLOSED.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [int]   $BugCount      = 20,
    [string]$Agent         = 'CronAiAthon-Pipeline',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$todoDir = Join-Path $WorkspacePath 'todo'
$sinDir  = Join-Path $WorkspacePath 'sin_registry'
$logDir  = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("pipeline-process20-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")

function Write-PipeLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Optional adapter for normalized event emission.
$adapter = Join-Path $WorkspacePath 'modules\PwShGUI-EventLogAdapter.psm1'
$adapterLoaded = $false
if (Test-Path $adapter) {
    try {
        Import-Module $adapter -Force -DisableNameChecking
        $adapterLoaded = $true
    } catch { <# Intentional: non-fatal -- adapter optional #> }
}

$script:PipeEventSeq = 0
$script:PipeActionId = 'pipe20-' + ([guid]::NewGuid().ToString().Substring(0,8))
$script:PipeEditor = [string]$env:USERNAME

function New-PipeEventId {
    $script:PipeEventSeq++
    return [int64]('{0}{1:D3}' -f (Get-Date -Format 'yyMMddHHmmss'), $script:PipeEventSeq)
}

function Emit-PipeEvent {
    param(
        [string]$Severity = 'Info',
        [string]$Message,
        [string]$Corr = '',
        [string]$ItemId = '',
        [string]$ItemType = ''
    )
    if (-not $adapterLoaded) { return }
    try {
        Write-EventLogNormalized -Scope pipeline -Component 'Invoke-PipelineProcess20' -Message $Message -Severity $Severity -CorrId $Corr -WorkspacePath $WorkspacePath -EventId (New-PipeEventId) -ItemId $ItemId -ItemType $ItemType -ActionId $script:PipeActionId -AgentId $Agent -Editor $script:PipeEditor
    } catch { <# Intentional: non-fatal -- event emission is best-effort #> }
}

Write-PipeLog "Pipeline-Process20 starting (BugCount=$BugCount, DryRun=$($DryRun.IsPresent))"
Emit-PipeEvent -Severity 'Info' -Message ("Pipeline-Process20 starting (BugCount={0}, DryRun={1})" -f $BugCount, $DryRun.IsPresent)

# 1) Load all BUG-*.json
$bugFiles = @(Get-ChildItem -Path $todoDir -Filter 'BUG-*.json' -File -ErrorAction SilentlyContinue)
Write-PipeLog "Loaded $($bugFiles.Count) bug files"

$bugs = @()
foreach ($bf in $bugFiles) {
    try {
        $b = Get-Content $bf.FullName -Raw | ConvertFrom-Json
        $bugs += [PSCustomObject]@{ File = $bf.FullName; Data = $b }
    } catch {
        Write-PipeLog "Failed to parse $($bf.Name): $($_.Exception.Message)" 'WARN'
    }
}

# 2) Detect resurfacing titles (>= 2 occurrences across distinct bug files)
$titleGroups = $bugs | Group-Object { $_.Data.title } | Where-Object { @($_.Group).Count -ge 2 }
Write-PipeLog "Detected $(@($titleGroups).Count) resurfacing bug title groups (>=2 occurrences)"

# 3) Pick 20 OPEN bugs to move IN-PROGRESS, prioritising HIGH then MEDIUM then LOW
$openBugs = $bugs | Where-Object { $_.Data.status -eq 'OPEN' }
$prioRank = @{ 'CRITICAL' = 0; 'HIGH' = 1; 'MEDIUM' = 2; 'LOW' = 3 }
$selected = @($openBugs | Sort-Object @{ Expression = {
    $p = if ($_.Data.PSObject.Properties.Name -contains 'priority') { [string]$_.Data.priority } else { '' }
    if ($prioRank.ContainsKey($p)) { $prioRank[$p] } else { 9 }
} }, @{ Expression = {
    if ($_.Data.PSObject.Properties.Name -contains 'created') { [string]$_.Data.created } else { '' }
} } | Select-Object -First $BugCount)
Write-PipeLog "Selected $($selected.Count) bugs for IN-PROGRESS transition"
Emit-PipeEvent -Severity 'Info' -Message ("Selected {0} bug(s) for IN-PROGRESS transition" -f $selected.Count)

$nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
$movedCount = 0
foreach ($item in $selected) {
    $b = $item.Data
    $b.status = 'IN-PROGRESS'
    if ($b.PSObject.Properties.Name -contains 'modified') { $b.modified = $nowIso } else { Add-Member -InputObject $b -NotePropertyName modified -NotePropertyValue $nowIso -Force }
    if ($b.PSObject.Properties.Name -contains 'executionAgent') { $b.executionAgent = $Agent } else { Add-Member -InputObject $b -NotePropertyName executionAgent -NotePropertyValue $Agent -Force }
    if ($b.PSObject.Properties.Name -contains 'plannedAt') { $b.plannedAt = $nowIso } else { Add-Member -InputObject $b -NotePropertyName plannedAt -NotePropertyValue $nowIso -Force }
    $note = "Auto-transitioned to IN-PROGRESS by Invoke-PipelineProcess20 at $nowIso"
    if ($b.PSObject.Properties.Name -contains 'notes' -and $b.notes) { $b.notes = "$($b.notes) | $note" } else { Add-Member -InputObject $b -NotePropertyName notes -NotePropertyValue $note -Force }
    if (-not $DryRun) {
        ($b | ConvertTo-Json -Depth 10) | Set-Content -Path $item.File -Encoding UTF8
    }
    $eventBugId = if ($b.PSObject.Properties.Name -contains 'id') { [string]$b.id } else { (Split-Path $item.File -Leaf) }
    Emit-PipeEvent -Severity 'Audit' -Message ("Bug {0} moved to IN-PROGRESS" -f $eventBugId) -Corr $eventBugId -ItemId $eventBugId -ItemType 'Bug'
    $movedCount++
}
Write-PipeLog "$movedCount bugs flipped to IN-PROGRESS"
Emit-PipeEvent -Severity 'Info' -Message ("{0} bug(s) flipped to IN-PROGRESS" -f $movedCount)

# 4) Promote resurfacing bug titles to SIN candidates (recorded as JSON entries; do not overwrite registry numbers >= 031)
$sinFixesDir = Join-Path $sinDir 'candidates'
if (-not (Test-Path $sinFixesDir)) { New-Item -ItemType Directory -Path $sinFixesDir | Out-Null }
$promotedCount = 0
foreach ($g in $titleGroups) {
    $candidate = [PSCustomObject]@{
        id            = "SIN-CANDIDATE-" + ((Get-Date).ToString('yyyyMMddHHmmss')) + "-" + ([guid]::NewGuid().ToString().Substring(0,8))
        title         = "Resurfacing bug pattern: $($g.Name)"
        occurrences   = @($g.Group).Count
        sample_bug_ids = @($g.Group | Select-Object -First 5 | ForEach-Object {
            if ($_.Data.PSObject.Properties.Name -contains 'id') { [string]$_.Data.id } else { (Split-Path $_.File -Leaf) }
        })
        affected_files = @($g.Group | ForEach-Object {
            if ($_.Data.PSObject.Properties.Name -contains 'affectedFiles') { $_.Data.affectedFiles } else { @() }
        } | Where-Object { $_ } | Select-Object -Unique)
        severity      = if (@($g.Group).Count -ge 5) { 'Blocking' } else { 'Advisory' }
        category      = 'Resurfacing/Recurrence'
        date_added    = (Get-Date -Format 'yyyy-MM-dd')
        promotion_rule = '>=2 distinct bug files share an identical title within active OPEN/IN-PROGRESS pool'
        next_step     = 'Manual review: assign SIN-PATTERN-NNN once root cause confirmed; current registry head=030'
    }
    $candFile = Join-Path $sinFixesDir ("$($candidate.id).json")
    if (-not $DryRun) {
        ($candidate | ConvertTo-Json -Depth 10) | Set-Content -Path $candFile -Encoding UTF8
    }
    $promotedCount++
}
Write-PipeLog "$promotedCount SIN candidates written to sin_registry/candidates/"
Emit-PipeEvent -Severity 'Info' -Message ("{0} SIN candidate(s) promoted from resurfacing bugs" -f $promotedCount)

# 5) Convert FEATURE-F001 -> series of Items2Do under PENDING_APPROVAL
$featureFile = Get-ChildItem -Path $todoDir -Filter 'FEATURE-*.json' -File | Select-Object -First 1
if ($featureFile) {
    $feature = Get-Content $featureFile.FullName -Raw | ConvertFrom-Json
    Write-PipeLog "Processing feature: $($feature.title) ($($feature.id))"
    $featureId = if ($feature.PSObject.Properties.Name -contains 'id') { [string]$feature.id } else { $featureFile.BaseName }
    Emit-PipeEvent -Severity 'Info' -Message ("Processing feature decomposition for {0}" -f $featureId) -Corr $featureId -ItemId $featureId -ItemType 'FeatureRequest'

    # Decompose into Items2Do (specific to Secrets Management feature)
    $subItems = @(
        @{ slug = 'a-vault-init';      title = 'Initialise BW vault DPAPI key store'; priority = 'HIGH' }
        @{ slug = 'b-windows-hello';   title = 'Wire Windows Hello unlock to vault entry point'; priority = 'HIGH' }
        @{ slug = 'c-secdump-rotate';  title = 'Implement secdump-yyyyMMdd-HHmm.log rotation policy (logs/secdump/)'; priority = 'MEDIUM' }
        @{ slug = 'd-checklist-tile';  title = 'Add Secrets-Vault tile to BW-Vault-Checklist.xhtml + Checklists-TEST'; priority = 'MEDIUM' }
        @{ slug = 'e-cli-helpers';     title = 'Expose Get-VaultSecret / Set-VaultSecret cmdlets in PwShGUICore'; priority = 'HIGH' }
        @{ slug = 'f-tests';           title = 'Pester suite for vault unlock + read + rotate paths'; priority = 'HIGH' }
        @{ slug = 'g-docs';            title = 'Update SECRETS-MANAGEMENT-GUIDE.md and SECURITY-SETUP-GUIDE.xhtml cross-refs'; priority = 'LOW' }
    )
    $createdItems = 0
    foreach ($si in $subItems) {
        $tid = "TODO-PA-{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), $si.slug
        $newItem = [PSCustomObject]@{
            id              = $tid
            todo_id         = $tid
            type            = 'TodoItem'
            category        = 'feature-decomposition'
            title           = $si.title
            description     = "Sub-item of $($feature.id) ($($feature.title))"
            priority        = $si.priority
            status          = 'PENDING_APPROVAL'
            source_id       = $feature.id
            source_status   = $feature.status
            parentId        = $feature.id
            created         = $nowIso
            createdAt       = $nowIso
            modified        = $nowIso
            suggested_by    = $Agent
            file_refs       = @()
            notes           = "Auto-decomposed from $($feature.id) by Invoke-PipelineProcess20; awaiting approval before IN-PROGRESS"
            status_history  = @(
                @{ status = 'PENDING_APPROVAL'; timestamp = $nowIso; by = $Agent }
            )
        }
        $outFile = Join-Path $todoDir ("$tid.json")
        if (-not $DryRun) {
            ($newItem | ConvertTo-Json -Depth 10) | Set-Content -Path $outFile -Encoding UTF8
        }
        Emit-PipeEvent -Severity 'Audit' -Message ("Created pending approval todo {0} from feature {1}" -f $tid, $featureId) -Corr $featureId -ItemId $tid -ItemType 'ToDo'
        $createdItems++
    }
    Write-PipeLog "$createdItems Items2Do written under PENDING_APPROVAL (feature decomposition of $($feature.id))"
    Emit-PipeEvent -Severity 'Info' -Message ("Created {0} pending approval todo item(s) from feature {1}" -f $createdItems, $featureId) -Corr $featureId -ItemId $featureId -ItemType 'FeatureRequest'

    # Mark feature as IN-PROGRESS (decomposed)
    if ($feature.PSObject.Properties.Name -contains 'status') { $feature.status = 'IN-PROGRESS' }
    if ($feature.PSObject.Properties.Name -contains 'modified') { $feature.modified = $nowIso }
    $featNote = "Decomposed into $createdItems PENDING_APPROVAL items at $nowIso"
    if ($feature.PSObject.Properties.Name -contains 'notes' -and $feature.notes) { $feature.notes = "$($feature.notes) | $featNote" } else { Add-Member -InputObject $feature -NotePropertyName notes -NotePropertyValue $featNote -Force }
    if (-not $DryRun) {
        ($feature | ConvertTo-Json -Depth 10) | Set-Content -Path $featureFile.FullName -Encoding UTF8
    }
    Emit-PipeEvent -Severity 'Audit' -Message ("Feature {0} moved to IN-PROGRESS after decomposition" -f $featureId) -Corr $featureId -ItemId $featureId -ItemType 'FeatureRequest'
} else {
    Write-PipeLog "No FEATURE-*.json found to decompose" 'WARN'
    Emit-PipeEvent -Severity 'Warning' -Message 'No FEATURE-*.json found to decompose'
}

Write-PipeLog "Pipeline-Process20 complete. Log: $logFile"
Emit-PipeEvent -Severity 'Info' -Message ("Pipeline-Process20 complete: bugsMoved={0}, sinCandidates={1}, featureItems={2}, dryRun={3}" -f $movedCount, $promotedCount, $(if ($featureFile) { $createdItems } else { 0 }), $DryRun.IsPresent)

[PSCustomObject]@{
    bugsMovedToInProgress    = $movedCount
    sinCandidatesPromoted    = $promotedCount
    featureItemsCreated      = if ($featureFile) { $createdItems } else { 0 }
    log                      = $logFile
    dryRun                   = $DryRun.IsPresent
} | ConvertTo-Json -Depth 5

