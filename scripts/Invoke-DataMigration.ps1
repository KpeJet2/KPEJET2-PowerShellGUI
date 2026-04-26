#Requires -Version 5.1
# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
<#
.SYNOPSIS
    One-time migration of Feature Requests and Bug Tracker JSON into unified todo/ items.
.DESCRIPTION
    Reads PsGUI-FeatureRequests.json (tree structure) and PsGUI-BugTracker.json,
    converts each entry into individual todo/ JSON files with the unified schema
    (type, file_refs, status_history). Preserves feature hierarchy via parent_id.
    Auto-reindexes _index.json after migration.
.PARAMETER WhatIf
    Dry-run: show what would be created without writing files.
.PARAMETER Force
    Overwrite existing migrated items (skip duplicate check).
.PARAMETER FeatureJsonPath
    Path to PsGUI-FeatureRequests.json. Auto-detected if omitted.
.PARAMETER BugJsonPath
    Path to PsGUI-BugTracker.json. Auto-detected if omitted.
.EXAMPLE
    .\Invoke-DataMigration.ps1 -WhatIf
    .\Invoke-DataMigration.ps1
    .\Invoke-DataMigration.ps1 -Force
#>
param(
    [switch]$WhatIf,
    [switch]$Force,
    [string]$FeatureJsonPath,
    [string]$BugJsonPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$todoDir    = Join-Path $scriptRoot 'todo'
$xhtmlDir   = Join-Path (Join-Path $scriptRoot 'scripts') 'XHTML-Checker'
$pipelineModulePath = Join-Path $scriptRoot 'modules\CronAiAthon-Pipeline.psm1'

if (Test-Path $pipelineModulePath) {
    try {
        Import-Module $pipelineModulePath -Force -ErrorAction Stop
    } catch {
        Write-Warning "[DataMigration] Failed to import CronAiAthon-Pipeline.psm1: $_"
    }
}

if (-not (Test-Path $todoDir)) { New-Item -Path $todoDir -ItemType Directory -Force | Out-Null }

# ── Auto-detect source files ──
if (-not $FeatureJsonPath) { $FeatureJsonPath = Join-Path $xhtmlDir 'PsGUI-FeatureRequests.json' }
if (-not $BugJsonPath)     { $BugJsonPath     = Join-Path $xhtmlDir 'PsGUI-BugTracker.json' }

# ── Status mapping ──
$featureStatusMap = @{
    'Proposed'      = 'OPEN'
    'ALPHA Testing' = 'OPEN'
    'ALPHA'         = 'OPEN'
    'BETA Testing'  = 'OPEN'
    'BETA'          = 'OPEN'
    'Released'      = 'DONE'
    'Deferred'      = 'CLOSED'
}

$bugStatusMap = @{
    'OPEN'    = 'OPEN'
    'FIXED'   = 'DONE'
    'CLOSED'  = 'CLOSED'
    'WONTFIX' = 'CLOSED'
}

# ── Load existing todo IDs to avoid duplicates ──
$existingSourceIds = @{}
if (-not $Force) {
    Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json') -and $_.FullName -notlike "*\~*\*" } |
    ForEach-Object {
        try {
            $item = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($item.source_id) { $existingSourceIds[$item.source_id] = $_.Name }
        } catch { Write-Warning "[DataMigration] Parse error in $($_.Name): $_" }
    }
}

$created = 0
$skipped = 0
# ═══════════════════════════════════════════════════════════
# MIGRATE FEATURES
# ═══════════════════════════════════════════════════════════
if (Test-Path $FeatureJsonPath) {
    Write-Host "`n=== Migrating Feature Requests ===" -ForegroundColor Cyan
    Write-Host "Source: $FeatureJsonPath" -ForegroundColor Gray
    $featureData = Get-Content -Path $FeatureJsonPath -Raw | ConvertFrom-Json

    function Convert-FeatureNode {
        param(
            [object[]]$Nodes,
            [string]$ParentId = '',
            [int]$Depth = 0
        )
        foreach ($node in $Nodes) {
            $sourceId = "feature-$($node.id)"
            if (-not $Force -and $existingSourceIds.ContainsKey($sourceId)) {
                Write-Host "  SKIP: $($node.id) - $($node.title) (already migrated as $($existingSourceIds[$sourceId]))" -ForegroundColor DarkGray
                $script:skipped++
                # Still recurse children
                if ($node.children) {
                    Convert-FeatureNode -Nodes $node.children -ParentId $node.id -Depth ($Depth + 1)
                }
                continue
            }

            $mappedStatus = 'OPEN'
            if ($node.status -and $featureStatusMap.ContainsKey($node.status)) {
                $mappedStatus = $featureStatusMap[$node.status]
            }
            if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
                $mappedStatus = ConvertTo-PipelineStatus -Status $mappedStatus
            }

            $mappedPriority = switch ($node.status) {
                'ALPHA Testing' { 'HIGH' }
                'ALPHA'         { 'HIGH' }
                'BETA Testing'  { 'HIGH' }
                'BETA'          { 'HIGH' }
                'Proposed'      { 'MEDIUM' }
                default         { 'MEDIUM' }
            }

            $now = (Get-Date).ToUniversalTime().ToString('o')
            $safeId = ($node.id -replace '[^A-Za-z0-9\.\-]', '').ToLower()
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
            $fileName = "todo-${stamp}-feature-${safeId}.json"

            $todo = [ordered]@{
                todo_id        = "feature-$safeId"
                type           = 'feature'
                category       = 'feature'
                title          = $node.title
                description    = if ($node.description) { $node.description } else { '' }
                suggested_by   = 'Invoke-DataMigration'
                priority       = $mappedPriority
                status         = $mappedStatus
                created_at     = if ($node.created) { $node.created } else { $now }
                acknowledged_at = $null
                affects        = @()
                file_refs      = @()
                notes          = "Migrated from PsGUI-FeatureRequests.json (original status: $($node.status))"
                source_id      = $sourceId
                parent_id      = if ($ParentId) { "feature-$($ParentId.ToLower() -replace '[^a-z0-9\.\-]','')" } else { $null }
                status_history = @(
                    [ordered]@{ status = $mappedStatus; timestamp = $now; by = 'Invoke-DataMigration' }
                )
            }

            if ($WhatIf) {
                Write-Host "  WOULD CREATE: $fileName - $($node.id): $($node.title) [$mappedStatus]" -ForegroundColor Yellow
            } else {
                $outPath = Join-Path $todoDir $fileName
                $todo | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath -Encoding UTF8
                Write-Host "  + $fileName - $($node.id): $($node.title) [$mappedStatus]" -ForegroundColor Green
            }
            $script:created++

            if ($node.children) {
                Convert-FeatureNode -Nodes $node.children -ParentId $node.id -Depth ($Depth + 1)
            }
        }
    }

    if ($featureData.features) {
        Convert-FeatureNode -Nodes $featureData.features
    }
    Write-Host "Features: $created created, $skipped skipped" -ForegroundColor Cyan
} else {
    Write-Host "Feature JSON not found at: $FeatureJsonPath - skipping feature migration" -ForegroundColor Yellow
}

$featureCreated = $created
$featureSkipped = $skipped

# Reset counters for bugs
$created = 0
$skipped = 0

# ═══════════════════════════════════════════════════════════
# MIGRATE BUGS
# ═══════════════════════════════════════════════════════════
if (Test-Path $BugJsonPath) {
    Write-Host "`n=== Migrating Bug Tracker ===" -ForegroundColor Cyan
    Write-Host "Source: $BugJsonPath" -ForegroundColor Gray
    $bugData = Get-Content -Path $BugJsonPath -Raw | ConvertFrom-Json

    foreach ($bug in $bugData.bugs) {
        $sourceId = "bug-$($bug.id)"
        if (-not $Force -and $existingSourceIds.ContainsKey($sourceId)) {
            Write-Host "  SKIP: $($bug.id) - $($bug.title) (already migrated)" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        $mappedStatus = 'OPEN'
        if ($bug.status -and $bugStatusMap.ContainsKey($bug.status.ToUpper())) {
            $mappedStatus = $bugStatusMap[$bug.status.ToUpper()]
        }
        if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
            $mappedStatus = ConvertTo-PipelineStatus -Status $mappedStatus
        }

        $mappedPriority = switch (($bug.severity -as [string]).ToUpper()) {
            'CRITICAL' { 'CRITICAL' }
            'HIGH'     { 'HIGH' }
            'MEDIUM'   { 'MEDIUM' }
            'LOW'      { 'LOW' }
            default    { 'MEDIUM' }
        }

        $fileRefs = @()
        if ($bug.file) { $fileRefs = @($bug.file) }

        $now = (Get-Date).ToUniversalTime().ToString('o')
        $safeId = ($bug.id -replace '[^A-Za-z0-9\-]', '').ToLower()
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
        $fileName = "todo-${stamp}-bug-${safeId}.json"

        $todo = [ordered]@{
            todo_id        = "bug-$safeId"
            type           = 'bug'
            category       = 'bug'
            title          = $bug.title
            description    = if ($bug.description) { $bug.description } else { '' }
            suggested_by   = 'Invoke-DataMigration'
            priority       = $mappedPriority
            severity       = $mappedPriority
            status         = $mappedStatus
            created_at     = if ($bug.reported) { $bug.reported } else { $now }
            acknowledged_at = $null
            affects        = @()
            file_refs      = $fileRefs
            notes          = ''
            source_id      = $sourceId
            status_history = @(
                [ordered]@{ status = $mappedStatus; timestamp = $now; by = 'Invoke-DataMigration' }
            )
        }

        # Enrich with root cause and fix info if available
        $notesParts = @()
        if ($bug.rootCause) { $notesParts += "Root Cause: $($bug.rootCause)" }
        if ($bug.fix)       { $notesParts += "Fix: $($bug.fix)" }
        if ($bug.version)   { $notesParts += "Version: $($bug.version)" }
        if ($bug.tags)      { $notesParts += "Tags: $(($bug.tags -join ', '))" }
        if ($notesParts.Count -gt 0) { $todo['notes'] = $notesParts -join ' | ' }

        if ($WhatIf) {
            Write-Host "  WOULD CREATE: $fileName - $($bug.id): $($bug.title) [$mappedStatus]" -ForegroundColor Yellow
        } else {
            $outPath = Join-Path $todoDir $fileName
            $todo | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath -Encoding UTF8
            Write-Host "  + $fileName - $($bug.id): $($bug.title) [$mappedStatus]" -ForegroundColor Green
        }
        $created++
    }
    Write-Host "Bugs: $created created, $skipped skipped" -ForegroundColor Cyan
} else {
    Write-Host "Bug JSON not found at: $BugJsonPath - skipping bug migration" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════
# SUMMARY & REINDEX
# ═══════════════════════════════════════════════════════════
$totalCreated = $featureCreated + $created
$totalSkipped = $featureSkipped + $skipped

Write-Host "`n=== Migration Summary ===" -ForegroundColor Cyan
Write-Host "  Features: $featureCreated created, $featureSkipped skipped" -ForegroundColor White
Write-Host "  Bugs:     $created created, $skipped skipped" -ForegroundColor White
Write-Host "  Total:    $totalCreated created, $totalSkipped skipped" -ForegroundColor Green

if (-not $WhatIf -and $totalCreated -gt 0) {
    Write-Host "`nReindexing todo/ directory..." -ForegroundColor Gray
    $todoMgr = Join-Path $PSScriptRoot 'Invoke-TodoManager.ps1'
    if (Test-Path $todoMgr) {
        & $todoMgr -Reindex
    } else {
        Write-Warning "Invoke-TodoManager.ps1 not found - run -Reindex manually"
    }
}

if ($WhatIf) {
    Write-Host "`n[DRY RUN] No files were written. Remove -WhatIf to execute migration." -ForegroundColor Yellow
}

return [PSCustomObject]@{
    FeaturesCreated = $featureCreated
    FeaturesSkipped = $featureSkipped
    BugsCreated     = $created
    BugsSkipped     = $skipped
    TotalCreated    = $totalCreated
    TotalSkipped    = $totalSkipped
}


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




