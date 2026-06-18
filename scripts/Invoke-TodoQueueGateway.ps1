#Requires -Version 5.1
# VersionTag: 2605.B5.V51.1
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-23
# SupportsPS7.6TestedDate: 2026-05-23
# FileRole: Pipeline
<#
.SYNOPSIS
    Queue gateway entrypoint for todo queue synchronization and artifact refresh.
.DESCRIPTION
    Provides one pipeline gateway with queue routing support.
    Queue folders are expected under: todo/QUEUES-ToDo/<prefix>/
.PARAMETER WorkspacePath
    Workspace root path.
.PARAMETER Action
    Sync     -> move root todo items into queue folders.
    Bundle   -> sync + rebuild _bundle.js and _index.json.
    Reindex  -> sync + refresh master aggregate, bundle, and index.
    Status   -> report current queue distribution.
.PARAMETER Queue
    Queue key filter (for reporting), for example: Bug-, TODO-PA-, Crash-, FEATURE-, FIX-, All.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = '',
    [ValidateSet('Sync','Bundle','Reindex','Status')]
    [string]$Action = 'Sync',
    [string]$Queue = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $WorkspacePath = Split-Path -Path $PSScriptRoot -Parent
    } else {
        $WorkspacePath = (Get-Location).Path
    }
}

$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path
$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Get-QueueGatewayItems {
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Ws)

    $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
    return @(
        Get-PipelineTodoJsonFiles -WorkspacePath $Ws -Filter '*.json' |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike '*\~*\*' }
    )
}

function Get-QueueGatewaySummary {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Ws,
        [string]$QueueFilter = 'All'
    )

    $allFiles = @(Get-QueueGatewayItems -Ws $Ws)
    $queueMap = @{}
    foreach ($file in @($allFiles)) {
        $queueKey = Get-PipelineTodoQueueKeyFromFileName -FileName $file.Name
        if (-not $queueMap.ContainsKey($queueKey)) {
            $queueMap[$queueKey] = 0
        }
        $queueMap[$queueKey]++
    }

    $filteredCount = 0
    if ([string]::IsNullOrWhiteSpace($QueueFilter) -or $QueueFilter -eq 'All') {
        $filteredCount = @($allFiles).Count
    } else {
        $norm = $QueueFilter.Trim()
        $filteredCount = @($allFiles | Where-Object { (Get-PipelineTodoQueueKeyFromFileName -FileName $_.Name) -eq $norm }).Count
    }

    $orderedQueues = [ordered]@{}
    foreach ($k in @($queueMap.Keys | Sort-Object)) {
        $orderedQueues[$k] = $queueMap[$k]
    }

    return [ordered]@{
        action        = $Action
        queueFilter   = $QueueFilter
        workspacePath = $Ws
        totalItems    = @($allFiles).Count
        filteredItems = $filteredCount
        queues        = $orderedQueues
    }
}

$result = [ordered]@{
    action = $Action
    queue  = $Queue
}

switch ($Action) {
    'Sync' {
        $result.sync = Move-PipelineTodoFilesToQueues -WorkspacePath $WorkspacePath
    }
    'Bundle' {
        $result.sync = Move-PipelineTodoFilesToQueues -WorkspacePath $WorkspacePath
        $result.bundle = Update-TodoBundle -WorkspacePath $WorkspacePath
        $result.index = Update-PipelineIndex -WorkspacePath $WorkspacePath
    }
    'Reindex' {
        $result.refresh = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
    }
    'Status' {
        # no state-changing operation
    }
}

$result.summary = Get-QueueGatewaySummary -Ws $WorkspacePath -QueueFilter $Queue

Write-Host "[TodoQueueGateway] Action=$Action Queue=$Queue Total=$($result.summary.totalItems)" -ForegroundColor Cyan
if ($result.summary.queues.Count -gt 0) {
    foreach ($q in @($result.summary.queues.Keys)) {
        Write-Host ("  {0} -> {1}" -f $q, $result.summary.queues[$q]) -ForegroundColor Gray
    }
}

$result | ConvertTo-Json -Depth 8

