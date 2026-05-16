#Requires -Version 5.1
# VersionTag: 2605.B5.V46.0
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

function Test-DataMigrationRecordProperty {
    param(
        [object]$Record,
        [string]$Name
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return ($Record.PSObject.Properties.Name -contains $Name)
}

function Get-DataMigrationRecordValue {
    param(
        [object]$Record,
        [string[]]$Names,
        $DefaultValue = $null
    )

    if ($null -eq $Record -or @($Names).Count -eq 0) {
        return $DefaultValue
    }

    foreach ($name in $Names) {
        if (-not (Test-DataMigrationRecordProperty -Record $Record -Name $name)) {
            continue
        }

        $prop = $Record.PSObject.Properties[$name]
        if ($null -eq $prop) {
            continue
        }

        $value = $prop.Value
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        return $value
    }

    return $DefaultValue
}

function Get-DataMigrationRecordStringValue {
    param(
        [object]$Record,
        [string[]]$Names,
        [string]$DefaultValue = ''
    )

    $value = Get-DataMigrationRecordValue -Record $Record -Names $Names -DefaultValue $null
    if ($null -eq $value) {
        return $DefaultValue
    }

    return [string]$value
}

# ── Load existing todo IDs to avoid duplicates ──
$existingSourceIds = @{}
if (-not $Force) {
    Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json') -and $_.FullName -notlike "*\~*\*" } |
    ForEach-Object {
        try {
            $item = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $sourceId = Get-DataMigrationRecordStringValue -Record $item -Names @('source_id','sourceId') -DefaultValue ''
            if (-not [string]::IsNullOrWhiteSpace($sourceId)) { $existingSourceIds[$sourceId] = $_.Name }  # SIN-EXEMPT:P027 -- index access, context-verified safe
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
            $nodeId = Get-DataMigrationRecordStringValue -Record $node -Names @('id') -DefaultValue ''
            $nodeTitle = Get-DataMigrationRecordStringValue -Record $node -Names @('title') -DefaultValue $nodeId
            $nodeStatus = Get-DataMigrationRecordStringValue -Record $node -Names @('status') -DefaultValue 'Proposed'
            $nodeDescription = Get-DataMigrationRecordStringValue -Record $node -Names @('description') -DefaultValue ''
            $nodeCreated = Get-DataMigrationRecordStringValue -Record $node -Names @('created','created_at','createdAt') -DefaultValue ''
            $nodeChildren = @(Get-DataMigrationRecordValue -Record $node -Names @('children') -DefaultValue @())
            $sourceId = "feature-$nodeId"
            if (-not $Force -and $existingSourceIds.ContainsKey($sourceId)) {
                Write-Host "  SKIP: $nodeId - $nodeTitle (already migrated as $($existingSourceIds[$sourceId]))" -ForegroundColor DarkGray  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $script:skipped++
                # Still recurse children
                if (@($nodeChildren).Count -gt 0) {
                    Convert-FeatureNode -Nodes $nodeChildren -ParentId $nodeId -Depth ($Depth + 1)
                }
                continue
            }

            $mappedStatus = 'OPEN'
            if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $featureStatusMap.ContainsKey($nodeStatus)) {
                $mappedStatus = $featureStatusMap[$nodeStatus]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
            if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
                $mappedStatus = ConvertTo-PipelineStatus -Status $mappedStatus
            }

            $mappedPriority = switch ($nodeStatus) {
                'ALPHA Testing' { 'HIGH' }
                'ALPHA'         { 'HIGH' }
                'BETA Testing'  { 'HIGH' }
                'BETA'          { 'HIGH' }
                'Proposed'      { 'MEDIUM' }
                default         { 'MEDIUM' }
            }

            $now = (Get-Date).ToUniversalTime().ToString('o')
            $safeId = ($nodeId -replace '[^A-Za-z0-9\.\-]', '').ToLower()
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
            $fileName = "todo-${stamp}-feature-${safeId}.json"

            $todo = [ordered]@{
                todo_id        = "feature-$safeId"
                type           = 'feature'
                category       = 'feature'
                title          = $nodeTitle
                description    = $nodeDescription
                suggested_by   = 'Invoke-DataMigration'
                priority       = $mappedPriority
                status         = $mappedStatus
                created_at     = if (-not [string]::IsNullOrWhiteSpace($nodeCreated)) { $nodeCreated } else { $now }
                acknowledged_at = $null
                affects        = @()
                file_refs      = @()
                notes          = "Migrated from PsGUI-FeatureRequests.json (original status: $nodeStatus)"
                source_id      = $sourceId
                parent_id      = if ($ParentId) { "feature-$($ParentId.ToLower() -replace '[^a-z0-9\.\-]','')" } else { $null }
                status_history = @(
                    [ordered]@{ status = $mappedStatus; timestamp = $now; by = 'Invoke-DataMigration' }
                )
            }

            if ($WhatIf) {
                Write-Host "  WOULD CREATE: $fileName - ${nodeId}: $nodeTitle [$mappedStatus]" -ForegroundColor Yellow
            } else {
                $outPath = Join-Path $todoDir $fileName
                $todo | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath -Encoding UTF8
                Write-Host "  + $fileName - ${nodeId}: $nodeTitle [$mappedStatus]" -ForegroundColor Green
            }
            $script:created++

            if (@($nodeChildren).Count -gt 0) {
                Convert-FeatureNode -Nodes $nodeChildren -ParentId $nodeId -Depth ($Depth + 1)
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
        $bugId = Get-DataMigrationRecordStringValue -Record $bug -Names @('id') -DefaultValue ''
        $bugTitle = Get-DataMigrationRecordStringValue -Record $bug -Names @('title') -DefaultValue $bugId
        $bugStatus = Get-DataMigrationRecordStringValue -Record $bug -Names @('status') -DefaultValue 'OPEN'
        $bugSeverity = Get-DataMigrationRecordStringValue -Record $bug -Names @('severity','priority') -DefaultValue 'MEDIUM'
        $bugDescription = Get-DataMigrationRecordStringValue -Record $bug -Names @('description') -DefaultValue ''
        $bugReported = Get-DataMigrationRecordStringValue -Record $bug -Names @('reported','created_at','createdAt','created','firstSeenAt') -DefaultValue ''
        $sourceId = "bug-$bugId"
        if (-not $Force -and $existingSourceIds.ContainsKey($sourceId)) {
            Write-Host "  SKIP: $bugId - $bugTitle (already migrated)" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        $mappedStatus = 'OPEN'
        if (-not [string]::IsNullOrWhiteSpace($bugStatus) -and $bugStatusMap.ContainsKey($bugStatus.ToUpper())) {
            $mappedStatus = $bugStatusMap[$bugStatus.ToUpper()]
        }
        if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
            $mappedStatus = ConvertTo-PipelineStatus -Status $mappedStatus
        }

        $mappedPriority = switch ($bugSeverity.ToUpper()) {
            'CRITICAL' { 'CRITICAL' }
            'HIGH'     { 'HIGH' }
            'MEDIUM'   { 'MEDIUM' }
            'LOW'      { 'LOW' }
            default    { 'MEDIUM' }
        }

        $fileRefs = @()
        $bugFile = Get-DataMigrationRecordStringValue -Record $bug -Names @('file') -DefaultValue ''
        if (-not [string]::IsNullOrWhiteSpace($bugFile)) { $fileRefs = @($bugFile) }

        $now = (Get-Date).ToUniversalTime().ToString('o')
        $safeId = ($bugId -replace '[^A-Za-z0-9\-]', '').ToLower()
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
        $fileName = "todo-${stamp}-bug-${safeId}.json"

        $todo = [ordered]@{
            todo_id        = "bug-$safeId"
            type           = 'bug'
            category       = 'bug'
            title          = $bugTitle
            description    = $bugDescription
            suggested_by   = 'Invoke-DataMigration'
            priority       = $mappedPriority
            severity       = $mappedPriority
            status         = $mappedStatus
            created_at     = if (-not [string]::IsNullOrWhiteSpace($bugReported)) { $bugReported } else { $now }
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
        $bugRootCause = Get-DataMigrationRecordStringValue -Record $bug -Names @('rootCause') -DefaultValue ''
        $bugFix = Get-DataMigrationRecordStringValue -Record $bug -Names @('fix') -DefaultValue ''
        $bugVersion = Get-DataMigrationRecordStringValue -Record $bug -Names @('version') -DefaultValue ''
        $bugTags = @(Get-DataMigrationRecordValue -Record $bug -Names @('tags') -DefaultValue @())
        if (-not [string]::IsNullOrWhiteSpace($bugRootCause)) { $notesParts += "Root Cause: $bugRootCause" }
        if (-not [string]::IsNullOrWhiteSpace($bugFix))       { $notesParts += "Fix: $bugFix" }
        if (-not [string]::IsNullOrWhiteSpace($bugVersion))   { $notesParts += "Version: $bugVersion" }
        if (@($bugTags).Count -gt 0)      { $notesParts += "Tags: $(($bugTags -join ', '))" }
        if ($notesParts.Count -gt 0) { $todo['notes'] = $notesParts -join ' | ' }

        if ($WhatIf) {
            Write-Host "  WOULD CREATE: $fileName - ${bugId}: $bugTitle [$mappedStatus]" -ForegroundColor Yellow
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





