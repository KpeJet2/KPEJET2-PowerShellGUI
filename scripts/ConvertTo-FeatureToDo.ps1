#Requires -Version 5.1
# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
    Converts Feature Requests from XHTML backup JSON into ToDo items in the todo/ folder.

.DESCRIPTION
    Reads a PsGUI-FeatureRequests JSON backup file (exported from the XHTML Feature
    Requests tab) and converts each Proposed/ALPHA feature into a standardised ToDo
    JSON file in the todo/ directory. Also supports listing features and filtering by
    status. Integrates with the PsGUI-BugTracker.json for cross-referencing.

.PARAMETER FeatureJsonPath
    Path to the PsGUI-FeatureRequests backup JSON file.
    If omitted, scans config/feature-requests-latest.json then the newest backup
    in scripts/XHTML-Checker/.

.PARAMETER StatusFilter
    Comma-separated list of statuses to convert. Default: Proposed,ALPHA

.PARAMETER ListOnly
    List features without converting to todos.

.PARAMETER OutputJson
    Write a summary report JSON to ~REPORTS/.

.NOTES
    Author   : Code-INspectre Agent
    Version  : 2604.B2.V31.0
    Created  : March 11, 2026
#>
param(
    [string]$FeatureJsonPath,
    [string[]]$StatusFilter = @('Proposed', 'ALPHA'),
    [switch]$ListOnly,
    [switch]$OutputJson
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$todoDir   = Join-Path $scriptDir 'todo'
$reportDir = Join-Path $scriptDir '~REPORTS'

# ── Locate feature JSON ──
if (-not $FeatureJsonPath) {
    $latestConfig = Join-Path (Join-Path $scriptDir 'config') 'feature-requests-latest.json'
    if (Test-Path $latestConfig) {
        $FeatureJsonPath = $latestConfig
    } else {
        $xhtmlDir = Join-Path (Join-Path $scriptDir 'scripts') 'XHTML-Checker'
        $backups = Get-ChildItem -Path $xhtmlDir -Filter 'PsGUI-FeatureRequests_BACKUP_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if ($backups) {
            $FeatureJsonPath = $backups[0].FullName
        }
    }
}

if (-not $FeatureJsonPath -or -not (Test-Path $FeatureJsonPath)) {
    Write-Warning @"
No feature requests JSON found. Export one from the XHTML Feature Requests tab:
  1. Open scripts/XHTML-Checker/XHTML-FeatureRequests.xhtml
  2. Click 'Download Backup' in the toolbar
  3. Save to config/feature-requests-latest.json or re-run with -FeatureJsonPath
"@
    return
}

Write-Host "Reading features from: $FeatureJsonPath" -ForegroundColor Cyan
$featureData = Get-Content -Path $FeatureJsonPath -Raw | ConvertFrom-Json

# ── Flatten hierarchical features ──
function Flatten-Features {
    param([object[]]$Nodes, [int]$Depth = 0, [string]$ParentId = '')
    $results = @()
    foreach ($node in $Nodes) {
        $results += [PSCustomObject]@{
            Id          = $node.id
            Title       = $node.title
            Status      = $node.status
            Description = $node.description
            Created     = $node.created
            ReviewedBy  = $node.reviewedBy
            Depth       = $Depth
            ParentId    = $ParentId
        }
        if ($node.children) {
            $results += Flatten-Features -Nodes $node.children -Depth ($Depth + 1) -ParentId $node.id
        }
    }
    return $results
}

$allFeatures = @(Flatten-Features -Nodes $featureData.features)
Write-Host "Total features found: $($allFeatures.Count)" -ForegroundColor White

$filtered = @($allFeatures | Where-Object { $StatusFilter -contains $_.Status })
Write-Host "Features matching status filter ($($StatusFilter -join ', ')): $($filtered.Count)" -ForegroundColor Yellow

# ── List mode ──
if ($ListOnly) {
    Write-Host ""
    Write-Host ("  {0,-12} {1,-12} {2,-50} {3}" -f 'ID', 'Status', 'Title', 'Description') -ForegroundColor Gray
    Write-Host ("  {0,-12} {1,-12} {2,-50} {3}" -f '---', '------', '-----', '-----------') -ForegroundColor DarkGray
    foreach ($f in $allFeatures) {
        $indent = '  ' + ('  ' * $f.Depth)
        $color = switch ($f.Status) {
            'Proposed'  { 'White' }
            'ALPHA'     { 'Yellow' }
            'BETA'      { 'Cyan' }
            'Released'  { 'Green' }
            'Deferred'  { 'DarkGray' }
            default     { 'White' }
        }
        Write-Host ("{0}{1,-12} {2,-12} {3,-50} {4}" -f $indent, $f.Id, $f.Status, ($f.Title | Select-Object -First 1), ($f.Description | Select-Object -First 1)) -ForegroundColor $color
    }
    return
}

# ── Load existing todos to avoid duplicates ──
if (-not (Test-Path $todoDir)) { New-Item -Path $todoDir -ItemType Directory -Force | Out-Null }
$existingTodos = Get-ChildItem -Path $todoDir -Filter '*.json' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    Where-Object { $_.source_feature_id }

$existingFeatureIds = @($existingTodos | ForEach-Object { $_.source_feature_id })

# ── Convert features to todos ──
$created = 0
$skipped = 0
$summary = @()

foreach ($feat in $filtered) {
    if ($existingFeatureIds -contains $feat.Id) {
        $skipped++
        $summary += [PSCustomObject]@{ Action = 'SKIPPED'; FeatureId = $feat.Id; Title = $feat.Title; Reason = 'Already exists' }
        continue
    }

    $todoId = [guid]::NewGuid().ToString()
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $safeTitle = ($feat.Title -replace '[^\w\s\-]', '' -replace '\s+', '-').Substring(0, [Math]::Min(60, $feat.Title.Length))
    $fileName = "todo-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMddTHHmmss'), $todoId.Substring(0, 8)

    $todo = @{
        todo_id            = $todoId
        category           = 'feature_request'
        title              = $feat.Title
        description        = $feat.Description
        source_feature_id  = $feat.Id
        source_status      = $feat.Status
        suggested_by       = 'ConvertTo-FeatureToDo'
        priority           = if ($feat.Status -eq 'ALPHA') { 'HIGH' } else { 'MEDIUM' }
        status             = 'OPEN'
        created_at         = $now
        acknowledged_at    = $null
        notes              = "Auto-converted from Feature Request $($feat.Id) (status: $($feat.Status))"
    }

    $todoPath = Join-Path $todoDir $fileName
    $todo | ConvertTo-Json -Depth 4 | Set-Content -Path $todoPath -Encoding UTF8
    $created++
    $summary += [PSCustomObject]@{ Action = 'CREATED'; FeatureId = $feat.Id; Title = $feat.Title; TodoFile = $fileName }

    Write-Host "  + $($feat.Id): $($feat.Title) -> $fileName" -ForegroundColor Green
}

Write-Host ""
Write-Host "Summary: $created created, $skipped skipped (duplicates)" -ForegroundColor Cyan

# ── Optional JSON report ──
if ($OutputJson) {
    if (-not (Test-Path $reportDir)) { New-Item -Path $reportDir -ItemType Directory -Force | Out-Null }
    $reportPath = Join-Path $reportDir "feature-to-todo-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    @{
        generated   = (Get-Date).ToUniversalTime().ToString('o')
        source      = $FeatureJsonPath
        totalFeatures = $allFeatures.Count
        filtered    = $filtered.Count
        created     = $created
        skipped     = $skipped
        items       = @($summary)
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "Report saved to: $reportPath" -ForegroundColor Cyan
}

return [PSCustomObject]@{
    Created  = $created
    Skipped  = $skipped
    Total    = $allFeatures.Count
    Filtered = $filtered.Count
}


