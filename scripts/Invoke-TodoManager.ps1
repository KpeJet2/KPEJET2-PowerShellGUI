#Requires -Version 5.1
# Author: The Establishment
# Date: 2603
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# FileRole: Script
<#
.SYNOPSIS
    Manages the PwShGUI todo/ directory: reindexes, validates, reports, and adds items.
.DESCRIPTION
    Systematic routines for todo JSON management:
      -Reindex     Rebuild _index.json from all todo-*.json files (includes type summary)
      -Validate    Check all todo JSONs for required fields and schema
      -Report      Print summary by category/priority/status/type
      -AddItem     Interactive prompt to create a new todo JSON
      -AddBug      Convenience: create a bug item (sets type=bug)
      -AddFeature  Convenience: create a feature item (sets type=feature)
      -ListByFile  List all items whose file_refs contain the given path
.EXAMPLE
    .\Invoke-TodoManager.ps1 -Reindex
    .\Invoke-TodoManager.ps1 -Validate
    .\Invoke-TodoManager.ps1 -Report
    .\Invoke-TodoManager.ps1 -AddItem -Category regression -Priority HIGH -Title "New regression item"
    .\Invoke-TodoManager.ps1 -AddBug -Title "Parse error in module" -Priority HIGH -FileRefs "modules/Foo.psm1"
    .\Invoke-TodoManager.ps1 -AddFeature -Title "Dark mode toggle" -Priority MEDIUM
    .\Invoke-TodoManager.ps1 -ListByFile -FilePath "modules/PwShGUICore.psm1"
#>
param(
    [switch]$Reindex,
    [switch]$Validate,
    [switch]$Report,
    [switch]$AddItem,
    [switch]$AddBug,
    [switch]$AddFeature,
    [switch]$ListByFile,
    [string]$FilePath,
    [string]$Category,
    [string]$Priority,
    [string]$Title,
    [string]$Description,
    [string[]]$Affects,
    [string[]]$FileRefs,
    [string]$Severity,
    [string]$Notes,
    [string[]]$BugReferrals,
    [ValidateSet('todo','bug','feature')]
    [string]$Type
)

$ErrorActionPreference = 'Stop'
$todoDir = Join-Path $PSScriptRoot '..\todo'
if (-not (Test-Path $todoDir)) {
    Write-Error "Todo directory not found: $todoDir"
    return
}
$todoDir = (Resolve-Path $todoDir).Path
$pipelineModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\CronAiAthon-Pipeline.psm1'
if (Test-Path $pipelineModulePath) {
    try {
        Import-Module $pipelineModulePath -Force -ErrorAction Stop
    } catch {
        Write-Warning "[TodoManager] Failed to import CronAiAthon-Pipeline.psm1: $_"
    }
}

$validCategories = @('security','maintenance','testing','ux','optimization','regression','smoke-test','review','iteration','new_agents','feature','bug')
$validPriorities = @('CRITICAL','HIGH','MEDIUM','LOW')
$validStatuses   = @('OPEN','PLANNED','IN_PROGRESS','TESTING','DONE','CLOSED','BLOCKED','FAILED')
$validTypes      = @('todo','bug','feature')
$validSeverities = @('CRITICAL','HIGH','MEDIUM','LOW')
$requiredFields  = @('todo_id','category','title','description','priority','status','created_at')

# ── Reindex ──────────────────────────────────────────────────
if ($Reindex) {
    Write-Host "`n=== Reindexing todo/ directory ===" -ForegroundColor Cyan
    $useFallbackReindex = $true
    if (Get-Command -Name Invoke-PipelineArtifactRefresh -ErrorAction SilentlyContinue) {
        try {
            $workspacePath = Split-Path -Parent $todoDir
            $refresh = Invoke-PipelineArtifactRefresh -WorkspacePath $workspacePath
            $index = Get-Content (Join-Path $todoDir '_index.json') -Raw | ConvertFrom-Json
            Write-Host "Indexed $($index.count) master items and $($index.fileCount) active files -> _index.json" -ForegroundColor Green
            Write-Host "  Types: $($index.types.todos) todos, $($index.types.bugs) bugs, $($index.types.features) features" -ForegroundColor Gray
            Write-Host "  Generated: $($index.generated)" -ForegroundColor Gray
            Write-Host "  Refreshed: $($refresh.master), $($refresh.bundle), $($refresh.index)" -ForegroundColor Gray
            $useFallbackReindex = $false
        } catch {
            Write-Warning "[TodoManager] Pipeline artifact refresh failed, using fallback reindex: $($_.Exception.Message)"
        }
    }

    if ($useFallbackReindex) {
        $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
        $files = @(
            Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" } |
            Sort-Object Name
        )
        # Build type summary counts
        $typeCounts = @{ todos = 0; bugs = 0; features = 0 }
        foreach ($f in $files) {
            try {
                $item = Get-Content $f.FullName -Raw | ConvertFrom-Json
                switch (($item.type -as [string]).ToLower()) {
                    'bug'     { $typeCounts.bugs++ }
                    'feature' { $typeCounts.features++ }
                    default   { $typeCounts.todos++ }
                }
            } catch { $typeCounts.todos++ }
        }
        $index = [ordered]@{
            generated = (Get-Date).ToUniversalTime().ToString('o')
            count     = @($files).Count
            types     = [ordered]@{
                todos    = $typeCounts.todos
                bugs     = $typeCounts.bugs
                features = $typeCounts.features
            }
            files     = @($files.Name)
        }
        $indexPath = Join-Path $todoDir '_index.json'
        $index | ConvertTo-Json -Depth 3 | Set-Content -Path $indexPath -Encoding UTF8
        Write-Host "Indexed $(@($files).Count) todo files -> _index.json" -ForegroundColor Green
        Write-Host "  Types: $($typeCounts.todos) todos, $($typeCounts.bugs) bugs, $($typeCounts.features) features" -ForegroundColor Gray
        Write-Host "  Generated: $($index.generated)" -ForegroundColor Gray

        if (Get-Command -Name Export-CentralMasterToDo -ErrorAction SilentlyContinue) {
            try {
                $workspacePath = Split-Path -Parent $todoDir
                $masterPath = Export-CentralMasterToDo -WorkspacePath $workspacePath
                Write-Host "  Refreshed: $masterPath" -ForegroundColor Gray
            } catch {
                Write-Warning "[TodoManager] Fallback reindex could not refresh _master-aggregated.json: $($_.Exception.Message)"
            }
        }
    }
}

# ── Validate ─────────────────────────────────────────────────
if ($Validate) {
    Write-Host "`n=== Validating todo JSON files ===" -ForegroundColor Cyan
    $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
    $files = @(
        Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" }
    )
    $errors = 0
    $warnings = 0
    foreach ($f in $files) {
        try {
            $t = Get-Content $f.FullName -Raw | ConvertFrom-Json
        } catch {
            Write-Host "  [FAIL] $($f.Name): Invalid JSON - $_" -ForegroundColor Red
            $errors++
            continue
        }
        $missing = @()
        foreach ($field in $requiredFields) {
            $val = $t.PSObject.Properties[$field]
            if (-not $val -or [string]::IsNullOrWhiteSpace($val.Value)) {
                $missing += $field
            }
        }
        if (@($missing).Count -gt 0) {
            Write-Host "  [WARN] $($f.Name): Missing fields: $($missing -join ', ')" -ForegroundColor Yellow
            $warnings++
        }
        if ($t.category -and $validCategories -notcontains $t.category.ToLower()) {
            Write-Host "  [WARN] $($f.Name): Unknown category '$($t.category)'" -ForegroundColor Yellow
            $warnings++
        }
        if ($t.priority -and $validPriorities -notcontains $t.priority.ToUpper()) {
            Write-Host "  [WARN] $($f.Name): Unknown priority '$($t.priority)'" -ForegroundColor Yellow
            $warnings++
        }
        if ($t.status -and $validStatuses -notcontains $t.status.ToUpper()) {
            if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
                $normalizedStatus = ConvertTo-PipelineStatus -Status $t.status
                if ($validStatuses -notcontains $normalizedStatus) {
                    Write-Host "  [WARN] $($f.Name): Unknown status '$($t.status)'" -ForegroundColor Yellow
                    $warnings++
                }
            } else {
                Write-Host "  [WARN] $($f.Name): Unknown status '$($t.status)'" -ForegroundColor Yellow
                $warnings++
            }
        }
        if ($t.type -and $validTypes -notcontains $t.type.ToLower()) {
            Write-Host "  [WARN] $($f.Name): Unknown type '$($t.type)'" -ForegroundColor Yellow
            $warnings++
        }
        if ($t.severity -and $validSeverities -notcontains $t.severity.ToUpper()) {
            Write-Host "  [WARN] $($f.Name): Unknown severity '$($t.severity)'" -ForegroundColor Yellow
            $warnings++
        }
    }
    $total = @($files).Count
    Write-Host "`nValidation: $total files, $errors errors, $warnings warnings" -ForegroundColor $(if ($errors -gt 0) { 'Red' } elseif ($warnings -gt 0) { 'Yellow' } else { 'Green' })
}

# ── Report ───────────────────────────────────────────────────
if ($Report) {
    Write-Host "`n=== ToDo Summary Report ===" -ForegroundColor Cyan
    $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
    $files = @(
        Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" }
    )
    $todos = @()
    foreach ($f in $files) {
        try { $todos += (Get-Content $f.FullName -Raw | ConvertFrom-Json) } catch { Write-Warning "[TodoManager] Parse error in $($f.Name): $_" }
    }
    if (@($todos).Count -eq 0) {
        Write-Host "No todo items found." -ForegroundColor Yellow
        return
    }
    if (Get-Command -Name ConvertTo-PipelineStatus -ErrorAction SilentlyContinue) {
        foreach ($todo in @($todos)) {
            if ($todo.PSObject.Properties['status']) {
                $todo.status = ConvertTo-PipelineStatus -Status $todo.status
            }
        }
    }

    # By status
    Write-Host "`n--- By Status ---" -ForegroundColor White
    $todos | Group-Object status | Sort-Object Name | ForEach-Object {
        $color = switch ($_.Name.ToUpper()) { 'OPEN' { 'Red' } 'IN_PROGRESS' { 'Yellow' } 'DONE' { 'Green' } 'CLOSED' { 'DarkGray' } default { 'Gray' } }
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor $color
    }

    # By category
    Write-Host "`n--- By Category ---" -ForegroundColor White
    $todos | Group-Object category | Sort-Object Count -Descending | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor Cyan
    }

    # By priority
    Write-Host "`n--- By Priority ---" -ForegroundColor White
    $prioOrder = @{ 'CRITICAL' = 0; 'HIGH' = 1; 'MEDIUM' = 2; 'LOW' = 3 }
    $todos | Group-Object priority | Sort-Object { $prioOrder[$_.Name.ToUpper()] } | ForEach-Object {
        $color = switch ($_.Name.ToUpper()) { 'CRITICAL' { 'Red' } 'HIGH' { 'Yellow' } 'MEDIUM' { 'Cyan' } default { 'Gray' } }
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor $color
    }

    # Open items contiguous list
    Write-Host "`n--- Open Items (contiguous) ---" -ForegroundColor White
    $open = $todos | Where-Object { $_.status -in @('OPEN','PLANNED','IN_PROGRESS') } | Sort-Object {
        $prioOrder[$_.priority.ToUpper()]
    }, category, title
    $n = 1
    foreach ($t in $open) {
        $priTag = "[$($t.priority)]"
        Write-Host "  $n. $priTag [$($t.category)] $($t.title)" -ForegroundColor $(
            switch ($t.priority.ToUpper()) { 'CRITICAL' { 'Red' } 'HIGH' { 'Yellow' } 'MEDIUM' { 'Cyan' } default { 'Gray' } }
        )
        $n++
    }
    Write-Host "`nTotal: $($todos.Count) | Active: $(($todos | Where-Object { $_.status -in @('OPEN','PLANNED','IN_PROGRESS','TESTING','BLOCKED') }).Count) | Done: $(($todos | Where-Object { $_.status -eq 'DONE' }).Count)" -ForegroundColor Green

    # By type
    Write-Host "`n--- By Type ---" -ForegroundColor White
    $todos | Group-Object { if ($_.type) { $_.type } else { 'todo' } } | Sort-Object Name | ForEach-Object {
        $color = switch ($_.Name.ToLower()) { 'bug' { 'Red' } 'feature' { 'Cyan' } default { 'Green' } }
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor $color
    }
}

# ── Add Item / Add Bug / Add Feature ─────────────────────────
if ($AddBug)     { $AddItem = $true; if (-not $Type) { $Type = 'bug' };     if (-not $Category) { $Category = 'bug' } }
if ($AddFeature) { $AddItem = $true; if (-not $Type) { $Type = 'feature' }; if (-not $Category) { $Category = 'feature' } }
if ($AddItem) {
    if (-not $Type) { $Type = 'todo' }
    if (-not $Title) { $Title = Read-Host "Title" }
    if (-not $Category) {
        Write-Host "Categories: $($validCategories -join ', ')"
        $Category = Read-Host "Category"
    }
    if (-not $Priority) {
        Write-Host "Priorities: $($validPriorities -join ', ')"
        $Priority = Read-Host "Priority"
    }
    if (-not $Description) { $Description = Read-Host "Description" }
    if (-not $Notes) { $Notes = Read-Host "Notes (optional)" }
    if (-not $Affects) {
        $affStr = Read-Host "Affected files (comma-separated, optional)"
        if ($affStr) { $Affects = $affStr -split ',\s*' }
    }
    if (-not $FileRefs -and $Type -ne 'todo') {
        $frStr = Read-Host "File references (comma-separated workspace-relative paths, optional)"
        if ($frStr) { $FileRefs = $frStr -split ',\s*' }
    }
    if (-not $Severity -and $Type -eq 'bug') {
        Write-Host "Severities: $($validSeverities -join ', ')"
        $Severity = Read-Host "Bug severity"
    }
    if (-not $BugReferrals -and $Type -eq 'bug') {
        $brStr = Read-Host "Bug referrals (comma-separated pipeline IDs, e.g. bug-001,bug-003) (optional)"
        if ($brStr) { $BugReferrals = $brStr -split ',\s*' }
    }

    $catSlug = $Category.ToLower() -replace '[^a-z0-9]', '-'
    $existing = Get-ChildItem -Path $todoDir -Filter "todo-*-$catSlug-*.json" | Sort-Object Name -Descending | Select-Object -First 1
    $seq = 1
    if ($existing -and $existing.Name -match "$catSlug-(\d+)\.json$") {
        $seq = [int]$Matches[1] + 1  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
    }
    $todoId = "$catSlug-$('{0:D3}' -f $seq)"
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
    $fileName = "todo-${stamp}-${todoId}.json"

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $todo = [ordered]@{
        todo_id        = $todoId
        type           = $Type.ToLower()
        category       = $Category.ToLower()
        title          = $Title
        description    = $Description
        suggested_by   = "$env:USERNAME"
        priority       = $Priority.ToUpper()
        status         = 'OPEN'
        created_at     = $now
        acknowledged_at = $null
        affects        = @($Affects | Where-Object { $_ })
        file_refs      = @($FileRefs | Where-Object { $_ })
        notes          = $Notes
        status_history = @(
            [ordered]@{ status = 'OPEN'; timestamp = $now; by = "$env:USERNAME" }
        )
    }
    if ($Type -eq 'bug' -and $Severity) {
        $todo['severity'] = $Severity.ToUpper()
    }
    if ($Type -eq 'bug' -and @($BugReferrals | Where-Object { $_ }).Count -gt 0) {
        $todo['bugReferrals'] = @($BugReferrals | Where-Object { $_ })
    }

    $outPath = Join-Path $todoDir $fileName
    $todo | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath -Encoding UTF8
    Write-Host "`nCreated: $fileName" -ForegroundColor Green
    Write-Host "ID: $todoId | Type: $Type | Category: $Category | Priority: $Priority" -ForegroundColor Cyan

    # Auto-reindex
    Write-Host "Auto-reindexing..." -ForegroundColor Gray
    & $PSCommandPath -Reindex
}

# ── List By File ─────────────────────────────────────────────
if ($ListByFile) {
    if (-not $FilePath) { $FilePath = Read-Host "File path (workspace-relative)" }
    $normPath = $FilePath.Replace('\', '/').TrimStart('./')
    Write-Host "`n=== Items referencing: $normPath ===" -ForegroundColor Cyan
    $files = Get-ChildItem -Path $todoDir -Filter 'todo-*.json'
    $linkedItems = @()
    foreach ($f in $files) {
        try {
            $t = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $refs = @()
            if ($t.file_refs) { $refs += @($t.file_refs) }
            if ($t.affects)   { $refs += @($t.affects) }
            foreach ($ref in $refs) {
                $normRef = ($ref -as [string]).Replace('\', '/').TrimStart('./')
                if ($normRef -like "*$normPath*") {
                    $linkedItems += $t
                    break
                }
            }
        } catch { Write-Warning "[TodoManager] File-ref search error: $_" }
    }
    if (@($linkedItems).Count -eq 0) {
        Write-Host "  No items reference this file." -ForegroundColor Yellow
    } else {
        foreach ($m in $linkedItems) {
            $typeTag = if ($m.type) { "[$($m.type)]" } else { '[todo]' }
            Write-Host "  $typeTag [$($m.priority)] $($m.status) - $($m.title) (ID: $($m.todo_id))" -ForegroundColor $(
                switch (($m.priority -as [string]).ToUpper()) { 'CRITICAL' { 'Red' } 'HIGH' { 'Yellow' } 'MEDIUM' { 'Cyan' } default { 'Gray' } }
            )
        }
        Write-Host "`nTotal: $(@($linkedItems).Count) items reference this file" -ForegroundColor Green
    }
}

# Default: if no switch specified, show usage
if (-not ($Reindex -or $Validate -or $Report -or $AddItem -or $AddBug -or $AddFeature -or $ListByFile)) {
    Write-Host @"

Invoke-TodoManager.ps1 - PwShGUI ToDo Management Routines

Usage:
    -Reindex     Refresh _master-aggregated.json, _bundle.js, and _index.json
  -Validate    Check all todo JSONs for required fields and schema
  -Report      Print summary grouped by status, category, priority, type
  -AddItem     Create a new todo item (interactive or with parameters)
  -AddBug      Create a new bug item (sets type=bug, category=bug)
  -AddFeature  Create a new feature item (sets type=feature, category=feature)
  -ListByFile  List all items referencing a given file path

Parameters for -AddItem / -AddBug / -AddFeature:
  -Category <string>     One of: $($validCategories -join ', ')
  -Priority <string>     One of: $($validPriorities -join ', ')
  -Title <string>        Short title
  -Description <string>  Full description
  -Notes <string>        Optional regression/review notes
  -Affects <string[]>    Affected files (legacy)
  -FileRefs <string[]>   Workspace-relative file references for cross-referencing
  -Severity <string>     Bug severity: CRITICAL, HIGH, MEDIUM, LOW
  -BugReferrals <string[]>  Pipeline bug IDs this item references (bug items only)
  -Type <string>         Item type: todo, bug, feature

Parameters for -ListByFile:
  -FilePath <string>     Workspace-relative file path to search

Examples:
  .\Invoke-TodoManager.ps1 -Reindex
  .\Invoke-TodoManager.ps1 -Report
  .\Invoke-TodoManager.ps1 -AddItem -Category regression -Priority HIGH -Title "New bug pattern"
  .\Invoke-TodoManager.ps1 -AddBug -Title "Parse failure" -Priority HIGH -FileRefs "modules/Foo.psm1"
  .\Invoke-TodoManager.ps1 -AddFeature -Title "Dark mode" -Priority MEDIUM
  .\Invoke-TodoManager.ps1 -ListByFile -FilePath "modules/PwShGUICore.psm1"

"@ -ForegroundColor White
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





