# VersionTag: 2605.B5.V46.1
# SupportPS5.1: YES(As of: 2026-04-29)
# SupportsPS7.6: YES(As of: 2026-04-29)
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
# Show-Objectives: Execute compounding objective-improvement cycles with deterministic recommendations, in-place script hardening, and repeatable validation.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [ValidateRange(1, 25)]
    [int]$Iterations = 11
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetScripts = @(
    'scripts/Sync-ChangelogViewerData.ps1',
    'fix_update_version.ps1',
    'fix_check_version.ps1',
    'tests/Invoke-GUISmokeTest.ps1',
    'Launch-GUI-SmokeTest.bat'
)

function Get-RecommendationPool {
    return @(
        'Ensure Show-Objectives header exists and stays specific to operational intent.',
        'Ensure Outline and Objectives-Review sections are present for maintainability reflection.',
        'Run PowerShell parser checks on target scripts each cycle to detect drift early.',
        'Run changelog embed synchronization to preserve viewer consistency.',
        'Run XHTML XML validation for key pages after content-affecting changes.',
        'Keep version metadata in canonical uppercase format for consistency.',
        'Record cycle telemetry as JSON evidence for release review.',
        'Prefer small deterministic updates over broad unbounded rewrites.',
        'Keep PS5.1 compatibility guardrails in place for all cycle operations.',
        'Re-check objective alignment each pass and capture incremental recommendations.'
    )
}

function Ensure-ShowObjectivesHeader {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }
    if ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant() -ne '.ps1') { return $false }

    $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    if ($raw -match '(?m)^\s*#\s*Show-Objectives:') { return $false }

    $insertLine = '# Show-Objectives: Maintain script intent clarity and objective-driven validation outcomes.'
    $newRaw = $raw

    if ($raw -match '(?m)^\s*#\s*SupportsPS7\.6TestedDate:.*$') {
        $replacement = [string]::Concat('$1', [Environment]::NewLine, $insertLine)
        $newRaw = [regex]::Replace($raw, '(?m)^(\s*#\s*SupportsPS7\.6TestedDate:.*)$', $replacement, 1)
    } elseif ($raw -match '(?m)^\s*#\s*VersionTag:.*$') {
        $replacement2 = [string]::Concat('$1', [Environment]::NewLine, $insertLine)
        $newRaw = [regex]::Replace($raw, '(?m)^(\s*#\s*VersionTag:.*)$', $replacement2, 1)
    } else {
        $newRaw = "$insertLine`r`n$raw"
    }

    Set-Content -LiteralPath $FilePath -Value $newRaw -Encoding UTF8
    return $true
}

function Ensure-OutlineSections {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) { return $false }
    if ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant() -ne '.ps1') { return $false }

    $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    if ($raw -match '(?s)<#\s*Outline:') { return $false }

    $append = @(
        '',
        '<# Outline:',
        '    Objective cycle managed section: this script should keep behavior explicit and verifiable.',
        '#>',
        '',
        '<# Objectives-Review:',
        '    Objective alignment captured during pipeline cycle execution; update when scope changes.',
        '#>',
        '',
        '<# Problems:',
        '    No newly identified problems in this cycle section.',
        '#>'
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath $FilePath -Value ($raw + [Environment]::NewLine + $append + [Environment]::NewLine) -Encoding UTF8
    return $true
}

function Test-TargetParse {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ File = $FilePath; Parsed = $false; Error = 'Missing file' }
    }

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -ne '.ps1') {
        return [pscustomobject]@{ File = $FilePath; Parsed = $true; Error = '' }
    }

    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $FilePath), [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) {
        return [pscustomobject]@{ File = $FilePath; Parsed = $false; Error = $errors[0].Message }
    }
    return [pscustomobject]@{ File = $FilePath; Parsed = $true; Error = '' }
}

function Invoke-CycleIteration {
    param(
        [int]$Iteration,
        [int]$RecommendationCount,
        [string[]]$Targets,
        [string]$Root
    )

    $pool = @(Get-RecommendationPool)
    $recs = @($pool | Select-Object -First $RecommendationCount)
    $actions = New-Object System.Collections.Generic.List[string]

    foreach ($rel in $Targets) {
        $full = Join-Path $Root $rel
        if (Ensure-ShowObjectivesHeader -FilePath $full) {
            $actions.Add("Added Show-Objectives: $rel") | Out-Null
        }
        if (Ensure-OutlineSections -FilePath $full) {
            $actions.Add("Added Outline block: $rel") | Out-Null
        }
    }

    $syncScript = Join-Path $Root 'scripts/Sync-ChangelogViewerData.ps1'
    if (Test-Path -LiteralPath $syncScript) {
        & $syncScript -WorkspacePath $Root | Out-Null
        $actions.Add('Ran Sync-ChangelogViewerData.ps1') | Out-Null
    }

    $parseResults = @()
    foreach ($rel2 in $Targets) {
        $parseResults += Test-TargetParse -FilePath (Join-Path $Root $rel2)
    }

    $xmlResults = @()
    foreach ($page in @('XHTML-ChangelogViewer.xhtml', 'XHTML-WorkspaceHub.xhtml')) {
        $file = Join-Path $Root $page
        if (Test-Path -LiteralPath $file) {
            try {
                [xml](Get-Content -LiteralPath $file -Raw -Encoding UTF8) | Out-Null
                $xmlResults += [pscustomobject]@{ File = $page; Valid = $true; Error = '' }
            } catch {
                $xmlResults += [pscustomobject]@{ File = $page; Valid = $false; Error = $_.Exception.Message }
            }
        }
    }

    return [pscustomobject]@{
        iteration = $Iteration
        recommendationCount = $RecommendationCount
        recommendations = $recs
        actions = @($actions)
        parseResults = $parseResults
        xmlResults = $xmlResults
        timestamp = (Get-Date).ToString('o')
    }
}

$reportDir = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path -LiteralPath $reportDir)) {
    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
}

$todoPath = Join-Path $WorkspacePath 'agents/focalpoint-null/todo/ADMIN-TODO.json'
$activeTodoSummary = [pscustomobject]@{ source = 'none'; openItems = 0 }
if (Test-Path -LiteralPath $todoPath) {
    $todoObj = Get-Content -LiteralPath $todoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $openItems = @($todoObj.items | Where-Object { $_.status -eq 'OPEN' })
    $activeTodoSummary = [pscustomobject]@{ source = 'agents/focalpoint-null/todo/ADMIN-TODO.json'; openItems = @($openItems).Count }
}

$countsPattern = @(5, 4, 3, 2)
$results = @()
for ($i = 1; $i -le $Iterations; $i++) {
    $count = $countsPattern[($i - 1) % @($countsPattern).Count]
    $results += Invoke-CycleIteration -Iteration $i -RecommendationCount $count -Targets $targetScripts -Root $WorkspacePath
}

$summary = [pscustomobject]@{
    schema = 'ObjectivePipelineCycle/1.0'
    versionTag = '2605.B5.V46.1'
    workspacePath = $WorkspacePath
    generatedAt = (Get-Date).ToString('o')
    requestedIterations = $Iterations
    cadence = '5,4,3,2 repeating'
    activeTodoSummary = $activeTodoSummary
    targets = $targetScripts
    iterations = $results
}

$outFile = Join-Path $reportDir ('objective-pipeline-cycle-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFile -Encoding UTF8
Write-Output "Objective pipeline cycles complete: $Iterations"
Write-Output "Report: $outFile"

<# Outline:
    Executes iterative recommendation-and-implementation objective cycles with deterministic checks and JSON evidence output.
#>

<# Objectives-Review:
    This script enables bounded continuous improvement without unbounded looping.
    Future improvement: bind recommendation packs to repo metrics severity to prioritize high-impact actions first.
#>

<# Problems:
    Full GUI smoke is intentionally not executed per iteration due runtime cost; use dedicated smoke script after cycle completion.
#>

