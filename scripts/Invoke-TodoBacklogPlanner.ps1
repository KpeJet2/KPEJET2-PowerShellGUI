#Requires -Version 5.1
# VersionTag: 2605.B5.V46.0
# Purpose: Normalize backlog data from todo JSON files and inline TODO/FIXME/HACK markers.

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [switch]$IncludeMarkerOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath $WorkspacePath)) {
    throw "WorkspacePath not found: $WorkspacePath"
}

$todoDir = Join-Path $WorkspacePath 'todo'
if (-not (Test-Path -LiteralPath $todoDir)) {
    throw "todo directory not found: $todoDir"
}

$reportRoot = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path -LiteralPath $reportRoot)) {
    New-Item -Path $reportRoot -ItemType Directory -Force | Out-Null
}

$outDir = Join-Path $reportRoot 'TodoPlanning'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
$todoFiles = @(
    Get-ChildItem -LiteralPath $todoDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $excludeNames -notcontains $_.Name }
)

$normalizedItems = [System.Collections.Generic.List[object]]::new()

foreach ($todoFile in $todoFiles) {
    $obj = $null
    try {
        $obj = Get-Content -LiteralPath $todoFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $normalizedItems.Add([PSCustomObject]@{
            id = "PARSE-$($todoFile.BaseName)"
            source = 'todo-json'
            file = $todoFile.FullName
            title = "Invalid JSON in $($todoFile.Name)"
            category = 'parsing'
            priority = 'HIGH'
            status = 'OPEN'
            actionable = $true
            markerType = ''
            notes = $_.Exception.Message
        }) | Out-Null
        continue
    }

    $id = if ($obj.PSObject.Properties.Name -contains 'todo_id' -and -not [string]::IsNullOrWhiteSpace($obj.todo_id)) {
        [string]$obj.todo_id
    } else {
        "NOID-$($todoFile.BaseName)"
    }

    $statusRaw = if ($obj.PSObject.Properties.Name -contains 'status') { [string]$obj.status } else { 'OPEN' }
    $status = $statusRaw.ToUpper()

    $title = if ($obj.PSObject.Properties.Name -contains 'title') { [string]$obj.title } else { $todoFile.BaseName }
    $desc = if ($obj.PSObject.Properties.Name -contains 'description') { [string]$obj.description } else { '' }

    $isActionable = $true
    if ($status -eq 'PENDING_APPROVAL') {
        $isActionable = $false
    }

    $normalizedItems.Add([PSCustomObject]@{
        id = $id
        source = 'todo-json'
        file = $todoFile.FullName
        title = $title
        description = $desc
        category = if ($obj.PSObject.Properties.Name -contains 'category') { [string]$obj.category } else { 'uncategorized' }
        priority = if ($obj.PSObject.Properties.Name -contains 'priority') { ([string]$obj.priority).ToUpper() } else { 'MEDIUM' }
        status = $status
        actionable = $isActionable
        markerType = ''
        file_refs = if ($obj.PSObject.Properties.Name -contains 'file_refs') { @($obj.file_refs) } else { @() }
    }) | Out-Null
}

# Scan inline markers across scripts and markdown
$scanRoots = @(
    (Join-Path $WorkspacePath 'scripts'),
    (Join-Path $WorkspacePath 'modules'),
    (Join-Path $WorkspacePath 'tests'),
    (Join-Path $WorkspacePath 'docs'),
    (Join-Path $WorkspacePath '~README.md')
)

$inlineFiles = [System.Collections.Generic.List[object]]::new()
foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $rootFiles = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1,*.psd1,*.md -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike '*\\.history\\*' -and
                $_.FullName -notlike '*\\.venv\\*' -and
                $_.FullName -notlike '*\\node_modules\\*' -and
                $_.FullName -notlike '*\\~REPORTS\\*' -and
                $_.FullName -notlike '*\\reports\\*' -and
                $_.FullName -notlike '*\\logs\\*' -and
                $_.FullName -notlike '*\\temp\\*'
            }
    )
    foreach ($rf in $rootFiles) {
        $inlineFiles.Add($rf) | Out-Null
    }
}

$mainGuiPath = Join-Path $WorkspacePath 'Main-GUI.ps1'
if (Test-Path -LiteralPath $mainGuiPath) {
    try {
        $inlineFiles.Add((Get-Item -LiteralPath $mainGuiPath -ErrorAction Stop)) | Out-Null
    } catch { <# Intentional: non-fatal #> }
}

$inlineFiles = @($inlineFiles | Sort-Object FullName -Unique)

$markerRegex = '(TODO|FIXME|HACK)'

foreach ($f in $inlineFiles) {
    $matches = @()
    try {
        $matches = @(Select-String -LiteralPath $f.FullName -Pattern $markerRegex -CaseSensitive:$false -ErrorAction SilentlyContinue)
    } catch {
        $matches = @()
    }

    foreach ($m in $matches) {
        $text = [string]$m.Line
        $upper = $text.ToUpperInvariant()
        $ext = $f.Extension.ToLowerInvariant()

        $markerType = 'inline-marker'
        $actionable = $true

        # Markdown markers are planning references by default unless explicitly promoted.
        if ($ext -eq '.md') {
            $actionable = $false
            $markerType = 'markdown-marker'
        }

        # Marker-only scaffold patterns should not pollute execution queue.
        if ($upper -match 'STUB:\s*LIST PENDING WORK HERE' -or $upper -match 'HELP MENU INTEGRATION TODO') {
            $markerType = 'template-marker'
            $actionable = $false
        }

        # Explicit code-level action markers remain actionable.
        if ($ext -ne '.md' -and ($upper -match 'TODO:\s*IMPLEMENT' -or $upper -match 'FIXME' -or $upper -match 'HACK')) {
            $actionable = $true
        }

        if ($actionable -or $IncludeMarkerOnly) {
            $normalizedItems.Add([PSCustomObject]@{
                id = "INLINE-$($f.BaseName)-L$($m.LineNumber)"
                source = 'inline-scan'
                file = $f.FullName
                line = $m.LineNumber
                title = $text.Trim()
                description = ''
                category = 'inline-marker'
                priority = 'LOW'
                status = if ($actionable) { 'OPEN' } else { 'MARKER_ONLY' }
                actionable = $actionable
                markerType = $markerType
                file_refs = @($f.FullName)
            }) | Out-Null
        }
    }
}

$allItems = @($normalizedItems)
$actionableItems = @($allItems | Where-Object { $_.actionable })
$activeStatuses = @('OPEN', 'PLANNED', 'IN_PROGRESS', 'IN-PROGRESS', 'TESTING', 'BLOCKED', 'FAILED')
$executionQueue = @($actionableItems | Where-Object { $activeStatuses -contains ([string]$_.status).ToUpperInvariant() })

$byArea = [ordered]@{
    GUI = @($actionableItems | Where-Object { $_.file -match 'Main-GUI\.ps1|XHTML-|Theme|WinForms' }).Count
    Tray = @($actionableItems | Where-Object { $_.file -match 'TrayHost|TASKTRAY|tray' }).Count
    Pipeline = @($actionableItems | Where-Object { $_.file -match 'CronAiAthon|Pipeline|Invoke-CronProcessor|Start-LocalWebEngine' }).Count
    Docs = @($actionableItems | Where-Object { $_.file -match '\\.md$|~README\\.md' }).Count
    Security = @($actionableItems | Where-Object { $_.file -match 'AssistedSASC|vault|security|secdump|integrity' }).Count
    Tests = @($actionableItems | Where-Object { $_.file -match '\\tests\\|\.Tests\.ps1$' }).Count
}

$result = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    totalItems = @($allItems).Count
    actionableItems = @($actionableItems).Count
    executionQueueItems = @($executionQueue).Count
    markerOnlyItems = (@($allItems).Count - @($actionableItems).Count)
    areaCounts = $byArea
    items = $allItems
}

$jsonPath = Join-Path $outDir ("todo-normalized-$timestamp.json")
$mdPath = Join-Path $outDir ("todo-actionable-$timestamp.md")
$pointerPath = Join-Path $outDir 'todo-planning-pointer.json'

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Todo Planning Snapshot") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Generated: $($result.generatedAt)") | Out-Null
$lines.Add("Workspace: $WorkspacePath") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Summary") | Out-Null
$lines.Add("- Total: $($result.totalItems)") | Out-Null
$lines.Add("- Actionable: $($result.actionableItems)") | Out-Null
$lines.Add("- Execution queue: $($result.executionQueueItems)") | Out-Null
$lines.Add("- Marker-only: $($result.markerOnlyItems)") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Area Counts") | Out-Null
+($result.areaCounts.GetEnumerator() | ForEach-Object { $lines.Add("- $($_.Key): $($_.Value)") | Out-Null })
$lines.Add("") | Out-Null
$lines.Add("## Top Actionable Items") | Out-Null

$topActionable = @($executionQueue | Sort-Object priority, status, title | Select-Object -First 50)
foreach ($it in $topActionable) {
    $line = "- [$($it.priority)] [$($it.status)] $($it.id) :: $($it.title)"
    $lines.Add($line) | Out-Null
}

$lines | Set-Content -LiteralPath $mdPath -Encoding UTF8

([ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    latestJson = $jsonPath
    latestMarkdown = $mdPath
    actionableItems = @($actionableItems).Count
    executionQueueItems = @($executionQueue).Count
    totalItems = @($allItems).Count
}) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pointerPath -Encoding UTF8

Write-Host "[TodoPlanner] JSON: $jsonPath" -ForegroundColor Green
Write-Host "[TodoPlanner] Markdown: $mdPath" -ForegroundColor Green
Write-Host "[TodoPlanner] Pointer: $pointerPath" -ForegroundColor Cyan
Write-Host "[TodoPlanner] Actionable: $(@($actionableItems).Count) | Queue: $(@($executionQueue).Count) / Total: $(@($allItems).Count)" -ForegroundColor Yellow

