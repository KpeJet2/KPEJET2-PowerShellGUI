# VersionTag: 2606.B5.V51.4
# FileRole: Script
#Requires -Version 5.1
<#
.SYNOPSIS
    Remove repeated generated TODO-PA and SIN-CANDIDATE artifacts from a pipeline repeat run.
.DESCRIPTION
    Reads the most recent pipeline repeat summary by default and deletes generated
    todo\TODO-PA-*.json and sin_registry\candidates\SIN-CANDIDATE-*.json files whose
    write times fall inside the recorded run window. Dry-run by default.
.PARAMETER WorkspacePath
    Workspace root.
.PARAMETER SummaryJsonPath
    Path to a repeat summary JSON file. Defaults to the latest temp\pipeline-sin-repeat11-*.json.
.PARAMETER Apply
    Actually delete the matched files.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$SummaryJsonPath = '',
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CleanupLog {
    param([string]$Message)
    Write-Output "[Invoke-GeneratedCandidateCleanup] $Message"
}

$workspaceRoot = [System.IO.Path]::GetFullPath($WorkspacePath)
if ([string]::IsNullOrWhiteSpace($SummaryJsonPath)) {
    $tempDir = Join-Path $workspaceRoot 'temp'
    $latestSummary = @(Get-ChildItem -LiteralPath $tempDir -Filter 'pipeline-sin-repeat11-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if (@($latestSummary).Count -eq 0) {
        throw 'No repeat-11 summary JSON found in temp\.'
    }
    $SummaryJsonPath = $latestSummary[0].FullName
}

if (-not (Test-Path -LiteralPath $SummaryJsonPath)) {
    throw "Summary JSON not found: $SummaryJsonPath"
}

$summary = Get-Content -LiteralPath $SummaryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$iterations = @($summary.iterations)
if (@($iterations).Count -eq 0) {
    throw "Summary JSON does not contain any iterations: $SummaryJsonPath"
}

$started = [datetime]::Parse([string]$iterations[0].startedAt)
$finished = [datetime]::Parse([string]$iterations[-1].finishedAt)
$windowStart = $started.AddMinutes(-10)
$windowEnd = $finished.AddMinutes(10)

$todoDir = Join-Path $workspaceRoot 'todo'
$candidateDir = Join-Path (Join-Path $workspaceRoot 'sin_registry') 'candidates'

$todoFiles = @(Get-ChildItem -LiteralPath $todoDir -Filter 'TODO-PA-*.json' -File -ErrorAction SilentlyContinue)
$sinFiles = @(Get-ChildItem -LiteralPath $candidateDir -Filter 'SIN-CANDIDATE-*.json' -File -ErrorAction SilentlyContinue)

$actions = New-Object System.Collections.Generic.List[object]
foreach ($file in @($todoFiles | Where-Object { $_.LastWriteTime -ge $windowStart -and $_.LastWriteTime -le $windowEnd })) {
    $actions.Add([ordered]@{ path = $file.FullName; relativePath = $file.FullName.Substring($workspaceRoot.Length).TrimStart('\\'); lastWriteTime = $file.LastWriteTime.ToString('o'); exists = $true; deleted = $false }) | Out-Null
}
foreach ($file in @($sinFiles | Where-Object { $_.LastWriteTime -ge $windowStart -and $_.LastWriteTime -le $windowEnd })) {
    $actions.Add([ordered]@{ path = $file.FullName; relativePath = $file.FullName.Substring($workspaceRoot.Length).TrimStart('\\'); lastWriteTime = $file.LastWriteTime.ToString('o'); exists = $true; deleted = $false }) | Out-Null
}

if ($Apply) {
    foreach ($action in $actions) {
        try {
            Remove-Item -LiteralPath $action.path -Force -ErrorAction Stop
            $action.deleted = $true
            $action.exists = $false
        } catch {
            Write-CleanupLog "Failed to delete $($action.relativePath): $($_.Exception.Message)"
        }
    }
}

$reportRoot = Join-Path $workspaceRoot '~REPORTS'
$reportDir = Join-Path $reportRoot 'generated-candidate-cleanup'
if (-not (Test-Path -LiteralPath $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $reportDir ("generated-candidate-cleanup-$stamp.json")
$mdPath = Join-Path $reportDir ("generated-candidate-cleanup-$stamp.md")

$summaryOut = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    sourceSummary = $SummaryJsonPath
    applyMode = [bool]$Apply
    windowStart = $windowStart.ToString('o')
    windowEnd = $windowEnd.ToString('o')
    todoCandidates = @($todoFiles | Where-Object { $_.LastWriteTime -ge $windowStart -and $_.LastWriteTime -le $windowEnd }).Count
    sinCandidates = @($sinFiles | Where-Object { $_.LastWriteTime -ge $windowStart -and $_.LastWriteTime -le $windowEnd }).Count
    deletePlanned = $actions.Count
    deleteApplied = @($actions | Where-Object { $_.deleted -eq $true }).Count
}

[pscustomobject]@{ summary = $summaryOut; actions = @($actions) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$mdLines = @(
    '# Generated Candidate Cleanup',
    '',
    "Generated: $($summaryOut.generatedAt)",
    "Source Summary: $($summaryOut.sourceSummary)",
    "Apply Mode: $($summaryOut.applyMode)",
    "Window Start: $($summaryOut.windowStart)",
    "Window End: $($summaryOut.windowEnd)",
    "Todo Candidates: $($summaryOut.todoCandidates)",
    "SIN Candidates: $($summaryOut.sinCandidates)",
    "Delete Planned: $($summaryOut.deletePlanned)",
    "Delete Applied: $($summaryOut.deleteApplied)",
    '',
    '## Actions',
    '',
    '| RelativePath | Deleted | LastWriteTime |',
    '|---|---|---|'
)

foreach ($action in $actions) {
    $mdLines += "| $($action.relativePath) | $($action.deleted) | $($action.lastWriteTime) |"
}

Set-Content -LiteralPath $mdPath -Value $mdLines -Encoding UTF8

Write-CleanupLog "Cleanup JSON: $jsonPath"
Write-CleanupLog "Cleanup Markdown: $mdPath"
Write-CleanupLog "Delete planned: $($summaryOut.deletePlanned)"
Write-CleanupLog "Delete applied: $($summaryOut.deleteApplied)"

