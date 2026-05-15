# VersionTag: 2605.B5.V46.0
<#
.SYNOPSIS
  Reconciles stale bug records in todo/ against current file parse state.
.DESCRIPTION
  Marks bug-parse-* and parse-error NOID-Bug*/NOID-Bugs2FIX-* records as RESOLVED when
  the referenced source file currently parses with 0 errors (or no longer exists).
  Writes audit trail to ~REPORTS/TodoPlanning/reconcile-<timestamp>.json.
.NOTES
  PS 5.1-strict-safe, PS 7.6-first. Idempotent. Dry-run by default.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = 'C:\PowerShellGUI',
    [switch]$Apply,
    [string]$ResolvedBy = 'BacklogReconcile-AutoParse'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$todoDir   = Join-Path $WorkspacePath 'todo'
$reportDir = Join-Path $WorkspacePath '~REPORTS\TodoPlanning'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$auditPath = Join-Path $reportDir ("reconcile-{0}.json" -f $timestamp)

function Resolve-FileRef {
    param([string]$Ref, [string]$Workspace)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    $clean = $Ref -replace '^[\\/]+',''
    $leaf  = Split-Path $clean -Leaf
    # Backup-snapshot refs are stale by definition; resolve via leaf in live workspace.
    $isBackup = $clean -match 'remediation-backups|~REPORTS\\|backup_|\.bak\b|checkpoints\\'
    if (-not $isBackup) {
        $direct = Join-Path $Workspace $clean
        if (Test-Path $direct) { return (Resolve-Path $direct).Path }
    }
    foreach ($root in @('modules','scripts','tests','sovereign-kernel','tools','UPM','agents')) {
        $cand = Join-Path (Join-Path $Workspace $root) $leaf
        if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    }
    $rootCand = Join-Path $Workspace $leaf
    if (Test-Path $rootCand) { return (Resolve-Path $rootCand).Path }
    return $null
}

function Test-FileParses {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }  # missing => no longer relevant
    if ($Path -notmatch '\.(ps1|psm1|psd1)$') { return $true }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    return (@($errs).Count -eq 0)
}

function Get-FileLeafFromTitle {
    param([string]$Title)
    if (-not $Title) { return $null }
    if ($Title -match '([A-Za-z0-9._-]+\.(?:ps1|psm1|psd1))') { return $Matches[1] }
    return $null
}

$results = [System.Collections.Generic.List[object]]::new()
$excludeNames = @('_index.json','_bundle.js','_master-aggregated.json','action-log.json')
$candidates = Get-ChildItem $todoDir -File -Filter '*.json' | Where-Object { $excludeNames -notcontains $_.Name }

Write-Host "Scanning $($candidates.Count) candidate backlog records..." -ForegroundColor Cyan

foreach ($file in $candidates) {
    try {
        $j = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        continue
    }
    $status = if ($j.PSObject.Properties.Name -contains 'status') { $j.status } else { '' }
    if ($status -in @('DONE','CLOSED','RESOLVED','VALIDATED')) { continue }

    $title = if ($j.PSObject.Properties.Name -contains 'title') { $j.title } else { '' }
    $desc  = if ($j.PSObject.Properties.Name -contains 'description') { $j.description } else { '' }
    $isParseRecord = ($title -match 'parse error|Missing ''=''|Unexpected token') -or ($desc -match 'parse|Unexpected token|Missing ''=''')
    if (-not $isParseRecord) { continue }

    # Resolve target file
    $refs = @()
    if ($j.PSObject.Properties.Name -contains 'file_refs' -and $j.file_refs) { $refs += @($j.file_refs) }
    if ($j.PSObject.Properties.Name -contains 'affectedFiles' -and $j.affectedFiles) { $refs += @($j.affectedFiles) }
    $leafFromTitle = Get-FileLeafFromTitle $title
    if ($leafFromTitle) { $refs += $leafFromTitle }
    $leafFromDesc = Get-FileLeafFromTitle $desc
    if ($leafFromDesc) { $refs += $leafFromDesc }

    $resolvedPath = $null
    foreach ($r in $refs) {
        $rp = Resolve-FileRef -Ref $r -Workspace $WorkspacePath
        if ($rp) { $resolvedPath = $rp; break }
    }

    # Require evidence: a clearly identified PS file that currently parses cleanly,
    # OR a clearly named file that no longer exists in workspace.
    $hasFileEvidence = ($refs.Count -gt 0) -and ($leafFromTitle -or $leafFromDesc -or ($refs | Where-Object { $_ -match '\.(ps1|psm1|psd1|xhtml|html)$' }))
    if (-not $hasFileEvidence) { continue }

    $clean = if ($resolvedPath) { Test-FileParses -Path $resolvedPath } else { $true }

    if ($clean) {
        $results.Add([pscustomobject]@{
            File         = $file.Name
            ResolvedPath = $resolvedPath
            OldStatus    = $status
            Action       = 'WILL_RESOLVE'
        }) | Out-Null
        if ($Apply) {
            $j.status = 'DONE'
            if ($j.PSObject.Properties.Name -contains 'resolved_by') { $j.resolved_by = $ResolvedBy } else { $j | Add-Member -NotePropertyName resolved_by -NotePropertyValue $ResolvedBy }
            $resolvedAt = (Get-Date).ToString('o')
            if ($j.PSObject.Properties.Name -contains 'resolved_at') { $j.resolved_at = $resolvedAt } else { $j | Add-Member -NotePropertyName resolved_at -NotePropertyValue $resolvedAt }
            $reconcileNote = "Auto-reconciled: target file currently parses cleanly (or absent). Path=$resolvedPath"
            if ($j.PSObject.Properties.Name -contains 'notes') {
                $j.notes = ($j.notes + "`n" + $reconcileNote).Trim()
            } else {
                $j | Add-Member -NotePropertyName notes -NotePropertyValue $reconcileNote
            }
            $json = $j | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($file.FullName, $json, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

$audit = [pscustomobject]@{
    timestamp     = (Get-Date).ToString('o')
    workspace     = $WorkspacePath
    apply         = [bool]$Apply
    candidates    = $candidates.Count
    resolved      = $results.Count
    items         = $results
}
$audit | ConvertTo-Json -Depth 6 | Set-Content -Path $auditPath -Encoding UTF8

Write-Host ("Reconcile complete. Candidates={0} Resolved={1} Apply={2}" -f $candidates.Count, $results.Count, [bool]$Apply) -ForegroundColor Green
Write-Host ("Audit: {0}" -f $auditPath) -ForegroundColor Gray

