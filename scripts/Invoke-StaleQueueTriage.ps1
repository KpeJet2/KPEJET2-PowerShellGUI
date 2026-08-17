# VersionTag: 2608.B1.V54.7
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: QueueTriage
#Requires -Version 5.1
<#!
.SYNOPSIS
    Finds stale JSON queue items in the workspace todo queue tree.
.DESCRIPTION
    Scans the queue directory for backlog files that have not been touched within
    the configured threshold. The default mode is report-only and does not mutate
    queue state.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$QueuePath = '',
    [int]$ThresholdDays = 14,
    [switch]$IncludeNonJson,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QueueRoot {
    param(
        [string]$Root,
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $candidate = $Override
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $Root $candidate
        }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $defaultRoot = Join-Path $Root 'todo\QUEUES-ToDo'
    if (Test-Path -LiteralPath $defaultRoot) {
        return (Resolve-Path -LiteralPath $defaultRoot).Path
    }

    return $defaultRoot
}

$workspace = $null
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $workspace = (Get-Location).Path
} else {
    $workspace = (Resolve-Path -LiteralPath $WorkspacePath).Path
}

$queueRoot = Get-QueueRoot -Root $workspace -Override $QueuePath
$thresholdMinutes = [double]($ThresholdDays * 24 * 60)
$executionTime = (Get-Date).ToUniversalTime().ToString('o')
$stale = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path -LiteralPath $queueRoot)) {
    $summary = [ordered]@{
        workspacePath = $workspace
        queuePath     = $queueRoot
        thresholdDays = [int]$ThresholdDays
        generatedAtUtc = $executionTime
        staleCount    = 0
        staleFiles    = @()
        note          = 'Queue root not found; no stale queue items scanned.'
    }
    if ($AsJson) { $summary | ConvertTo-Json -Depth 8; return }
    return [pscustomobject]$summary
}

$files = @(Get-ChildItem -LiteralPath $queueRoot -File -Recurse -ErrorAction SilentlyContinue)
foreach ($file in $files) {
    $ext = [System.IO.Path]::GetExtension($file.Name)
    if (-not $AsJson -and -not $IncludeNonJson -and $ext -ne '.json') {
        continue
    }

    $ageMinutes = ((Get-Date) - $file.LastWriteTime).TotalMinutes
    if ($ageMinutes -le $thresholdMinutes) { continue }

    $meta = [ordered]@{
        path = $file.FullName
        relativePath = [string]($file.FullName.Substring($workspace.Length + 1) -replace '\\', '/')
        name = $file.Name
        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        ageMinutes = [double]$ageMinutes
        ageDays = [double]($ageMinutes / 1440)
    }

    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $json = $content | ConvertFrom-Json -ErrorAction Stop
            if ($json -and $json.PSObject.Properties.Name -contains 'status') {
                $meta['status'] = [string]$json.status
            }
            if ($json -and $json.PSObject.Properties.Name -contains 'title') {
                $meta['title'] = [string]$json.title
            }
        }
    } catch {
        $meta['status'] = 'unreadable-json'
    }

    $null = $stale.Add([pscustomobject]$meta)
}

$summary = [ordered]@{
    workspacePath = $workspace
    queuePath     = $queueRoot
    thresholdDays = [int]$ThresholdDays
    generatedAtUtc = $executionTime
    staleCount    = @($stale).Count
    staleFiles    = @($stale | ForEach-Object { $_.relativePath })
    staleEntries  = @($stale)
}

Write-Host ('[QueueTriage] queuePath=' + $queueRoot + ' thresholdDays=' + $ThresholdDays + ' staleCount=' + @($stale).Count) -ForegroundColor Cyan
foreach ($entry in @($stale)) {
    Write-Host ('  - ' + $entry.relativePath + ' ageDays=' + ([math]::Round([double]$entry.ageDays, 2))) -ForegroundColor Yellow
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 12
    return
}

return [pscustomobject]$summary
