# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
  Sync pipeline registry item statuses from on-disk todo/<id>.json files.
.DESCRIPTION
  config/cron-aiathon-pipeline.json drifts from todo/<id>.json files because
  Invoke-BacklogReconcile.ps1 only writes to disk. This script walks every
  bucket in the registry (featureRequests, bugs, items2ADD, bugs2FIX, todos)
  and copies status (and resolved_at/resolved_by/notes when present) from the
  matching todo/<id>.json. Items whose source file is missing are marked
  CLOSED with an auto-close note. Backs up the registry before writing.
.NOTES
  PS5.1-strict-safe. Idempotent. Dry-run unless -Apply is passed.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = 'C:\PowerShellGUI',
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$regPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
$todoDir = Join-Path $WorkspacePath 'todo'
if (-not (Test-Path -LiteralPath $regPath)) { throw "Registry not found: $regPath" }
if (-not (Test-Path -LiteralPath $todoDir)) { throw "Todo dir not found: $todoDir" }

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$raw       = [System.IO.File]::ReadAllText($regPath, [System.Text.UTF8Encoding]::new($false))
$reg       = $raw | ConvertFrom-Json
$buckets   = @('featureRequests','bugs','items2ADD','bugs2FIX','todos')

$nowIso    = (Get-Date).ToUniversalTime().ToString('o')
$closedSet = @('DONE','CLOSED','RESOLVED','VALIDATED')

$summary = [ordered]@{
    bucketsTouched     = 0
    itemsExamined      = 0
    statusFromDisk     = 0
    closedAsMissing    = 0
    unchanged          = 0
    skipped_NoIdField  = 0
}
$changes = [System.Collections.Generic.List[object]]::new()

foreach ($bucket in $buckets) {
    if (-not ($reg.PSObject.Properties.Name -contains $bucket)) { continue }
    $list = @($reg.$bucket)
    if ($list.Count -eq 0) { continue }
    $summary.bucketsTouched++

    foreach ($item in $list) {
        $summary.itemsExamined++
        if ($null -eq $item) { continue }
        $itemProps = $item.PSObject.Properties.Name
        if ($itemProps -notcontains 'id' -or [string]::IsNullOrWhiteSpace([string]$item.id)) {
            $summary.skipped_NoIdField++
            continue
        }
        $regStatus = if ($itemProps -contains 'status') { [string]$item.status } else { 'OPEN' }
        $diskFile  = Join-Path $todoDir ($item.id + '.json')

        if (-not (Test-Path -LiteralPath $diskFile)) {
            if ($regStatus -in $closedSet) { $summary.unchanged++; continue }
            $changes.Add([pscustomobject]@{
                Bucket = $bucket; Id = $item.id; OldStatus = $regStatus;
                NewStatus = 'CLOSED'; Reason = 'source-file-missing'
            }) | Out-Null
            if ($Apply) {
                $item.status = 'CLOSED'
                $note = "Auto-closed by Sync-PipelineRegistryFromDisk: todo/<id>.json no longer exists"
                if ($itemProps -contains 'notes' -and $item.notes) {
                    $item.notes = ($item.notes + "`n" + $note).Trim()
                } elseif ($itemProps -contains 'notes') {
                    $item.notes = $note
                } else {
                    $item | Add-Member -NotePropertyName notes -NotePropertyValue $note -Force
                }
                if ($itemProps -contains 'modified') { $item.modified = $nowIso } else { $item | Add-Member -NotePropertyName modified -NotePropertyValue $nowIso -Force }
            }
            $summary.closedAsMissing++
            continue
        }

        try {
            $diskRaw  = [System.IO.File]::ReadAllText($diskFile, [System.Text.UTF8Encoding]::new($false))
            $diskJson = $diskRaw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $summary.unchanged++
            continue
        }

        $diskProps  = $diskJson.PSObject.Properties.Name
        $diskStatus = if ($diskProps -contains 'status') { [string]$diskJson.status } else { '' }
        if ([string]::IsNullOrWhiteSpace($diskStatus) -or $diskStatus -eq $regStatus) {
            $summary.unchanged++
            continue
        }

        $changes.Add([pscustomobject]@{
            Bucket = $bucket; Id = $item.id; OldStatus = $regStatus;
            NewStatus = $diskStatus; Reason = 'sync-from-disk'
        }) | Out-Null

        if ($Apply) {
            if ($itemProps -contains 'status') { $item.status = $diskStatus } else { $item | Add-Member -NotePropertyName status -NotePropertyValue $diskStatus -Force }
            foreach ($f in @('resolved_at','resolved_by','modified','executedAt','completedAt')) {
                if ($diskProps -contains $f -and $diskJson.$f) {
                    if ($itemProps -contains $f) { $item.$f = $diskJson.$f } else { $item | Add-Member -NotePropertyName $f -NotePropertyValue $diskJson.$f -Force }
                }
            }
        }
        $summary.statusFromDisk++
    }
}

# Update meta.byStatus counters across all buckets
if ($Apply -and ($reg.PSObject.Properties.Name -contains 'meta')) {
    $allItems = @()
    foreach ($b in $buckets) { if ($reg.PSObject.Properties.Name -contains $b) { $allItems += @($reg.$b) } }
    $byStatus = [ordered]@{
        OPEN        = @($allItems | Where-Object { $_.status -eq 'OPEN' }).Count
        PLANNED     = @($allItems | Where-Object { $_.status -eq 'PLANNED' }).Count
        IN_PROGRESS = @($allItems | Where-Object { $_.status -eq 'IN_PROGRESS' }).Count
        TESTING     = @($allItems | Where-Object { $_.status -eq 'TESTING' }).Count
        BLOCKED     = @($allItems | Where-Object { $_.status -eq 'BLOCKED' }).Count
        DONE        = @($allItems | Where-Object { $_.status -eq 'DONE' }).Count
        CLOSED      = @($allItems | Where-Object { $_.status -eq 'CLOSED' }).Count
        RESOLVED    = @($allItems | Where-Object { $_.status -eq 'RESOLVED' }).Count
        VALIDATED   = @($allItems | Where-Object { $_.status -eq 'VALIDATED' }).Count
    }
    if ($reg.meta.PSObject.Properties.Name -contains 'byStatus') {
        $reg.meta.byStatus = $byStatus
    } else {
        $reg.meta | Add-Member -NotePropertyName byStatus -NotePropertyValue $byStatus -Force
    }
    if ($reg.meta.PSObject.Properties.Name -contains 'lastSync') {
        $reg.meta.lastSync = $nowIso
    } else {
        $reg.meta | Add-Member -NotePropertyName lastSync -NotePropertyValue $nowIso -Force
    }
}

# Write audit
$reportDir = Join-Path $WorkspacePath '~REPORTS\TodoPlanning'
if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$tag       = (Get-Date).ToString('yyyyMMdd-HHmmss')
$auditPath = Join-Path $reportDir ("registry-sync-{0}.json" -f $tag)
$audit = [pscustomobject]@{
    timestamp     = $nowIso
    workspace     = $WorkspacePath
    apply         = [bool]$Apply
    summary       = $summary
    changeCount   = $changes.Count
    sample        = @($changes | Select-Object -First 30)
    changes       = @($changes)
}
$audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $auditPath -Encoding UTF8

if ($Apply) {
    $backup = $regPath + '.bak-syncfromdisk-' + $tag
    Copy-Item -LiteralPath $regPath -Destination $backup -Force
    $json = $reg | ConvertTo-Json -Depth 25
    [System.IO.File]::WriteAllText($regPath, $json, $utf8NoBom)
    Write-Host ("Registry updated. Backup: {0}" -f $backup) -ForegroundColor Green
} else {
    Write-Host "DRY-RUN: registry not modified. Pass -Apply to commit." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
$summary.GetEnumerator() | ForEach-Object { '  {0,-22} {1}' -f $_.Key, $_.Value } | Out-Host
Write-Host ("  changes               {0}" -f $changes.Count)
Write-Host ("Audit: {0}" -f $auditPath) -ForegroundColor Gray

# SIN-PATTERN-050 closure: regenerate scoreboard manifests after every Apply so the dashboard
# never drifts >24h from registry truth. Best-effort -- failure here does not invalidate the sync.
if ($Apply) {
    $scoreGen = Join-Path $PSScriptRoot '..\tests\iter41-scoreboard-data-gen.ps1'
    if (Test-Path -LiteralPath $scoreGen) {
        try {
            Write-Host "Refreshing SIN-Scoreboard manifests..." -ForegroundColor Cyan
            & $scoreGen | Out-Host
        } catch {
            Write-Warning ("Scoreboard refresh failed (non-fatal): {0}" -f $_.Exception.Message)
        }
    }
}
