# VersionTag: 2605.B5.V51.1
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: TestHarness
#Requires -Version 5.1
<#!
.SYNOPSIS
    One-item incremental pipeline metric validation harness.

.DESCRIPTION
    Creates an isolated test workspace, discovers all queue arrays, performs
    +1 item injection per queue, and verifies metric parity across:
      - queue-level counts
      - total queue counts
      - pipeline artifact readback (_index.json / _master-aggregated.json)
      - PipelineManager XHTML queue-counter source coverage

    The harness is intentionally queue-agnostic for future extensibility.
    If a future queue is discovered but not yet wired into known artifacts/UI,
    the harness records actionable failures.
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$OutputPath = '',
    [switch]$SkipGuiCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Result {
    [CmdletBinding()]
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [string]$Severity = 'Info'
    )

    return [ordered]@{
        name     = $Name
        passed   = $Passed
        severity = $Severity
        detail   = $Detail
        at       = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-QueueNamesFromRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Registry)

    $exclude = @('meta', 'statistics', 'autopilotSuggestions')
    $names = @()

    if ($null -eq $Registry -or $null -eq $Registry.PSObject) {
        return @('featureRequests', 'bugs', 'items2ADD', 'bugs2FIX', 'todos')
    }

    foreach ($prop in @($Registry.PSObject.Properties)) {
        if ($exclude -contains $prop.Name) { continue }
        if ($prop.Value -is [System.Array]) {
            $names += [string]$prop.Name
        }
    }

    foreach ($fallback in @('featureRequests', 'bugs', 'items2ADD', 'bugs2FIX', 'todos')) {
        if ($names -notcontains $fallback) {
            $names += $fallback
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-KnownQueueNameSet {
    [CmdletBinding()]
    param()

    return @('featureRequests', 'bugs', 'items2ADD', 'bugs2FIX', 'todos')
}

function Convert-QueueToPipelineType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QueueName)

    switch ($QueueName) {
        'featureRequests' { return 'FeatureRequest' }
        'bugs' { return 'Bug' }
        'items2ADD' { return 'Items2ADD' }
        'bugs2FIX' { return 'Bugs2FIX' }
        'todos' { return 'ToDo' }
        default { return '' }
    }
}

function Get-Snapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HarnessWorkspace,
        [Parameter(Mandatory)][string[]]$QueueNames
    )

    $regPath = Join-Path (Join-Path $HarnessWorkspace 'config') 'cron-aiathon-pipeline.json'
    $registry = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $queueCounts = [ordered]@{}
    $totalAllQueues = 0

    foreach ($q in @($QueueNames)) {
        $val = $null
        if ($registry.PSObject.Properties.Name -contains $q) {
            $val = $registry.PSObject.Properties[$q].Value
        }
        $count = @($val).Count
        $queueCounts[$q] = $count
        $totalAllQueues += $count
    }

    $todoDir = Join-Path $HarnessWorkspace 'todo'
    $indexPath = Join-Path $todoDir '_index.json'
    $masterPath = Join-Path $todoDir '_master-aggregated.json'

    $indexCount = -1
    if (Test-Path $indexPath) {
        try {
            $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $indexCount = [int]$index.count
        } catch {
            $indexCount = -1
        }
    }

    $masterCount = -1
    if (Test-Path $masterPath) {
        try {
            $master = Get-Content -LiteralPath $masterPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $masterCount = [int]$master.meta.totalItems
        } catch {
            $masterCount = -1
        }
    }

    $created = 0
    if ($null -ne $registry.statistics -and $registry.statistics.PSObject.Properties.Name -contains 'totalItemsCreated') {
        $created = [int]$registry.statistics.totalItemsCreated
    }

    return [ordered]@{
        queueCounts      = $queueCounts
        totalAllQueues   = $totalAllQueues
        indexCount       = $indexCount
        masterCount      = $masterCount
        totalItemsCreated = $created
    }
}

function Add-OneItemToQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HarnessWorkspace,
        [Parameter(Mandatory)][string]$QueueName
    )

    $knownType = Convert-QueueToPipelineType -QueueName $QueueName
    if (-not [string]::IsNullOrWhiteSpace($knownType)) {
        $item = New-PipelineItem -Type $knownType -Title ("Harness +1 " + $QueueName) -Description 'Increment validation item' -Priority 'LOW' -Source 'Manual' -Category 'testing'
        $null = Add-PipelineItem -WorkspacePath $HarnessWorkspace -Item $item
        return
    }

    # Fallback path for future queue arrays not yet mapped by Add-PipelineItem.
    $regPath = Join-Path (Join-Path $HarnessWorkspace 'config') 'cron-aiathon-pipeline.json'
    $registry = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($registry.PSObject.Properties.Name -notcontains $QueueName) {
        $registry | Add-Member -MemberType NoteProperty -Name $QueueName -Value @() -Force
    }

    $synthetic = [ordered]@{
        id              = ("FutureQueue-" + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString().Substring(0, 8)))
        type            = 'ToDo'
        title           = ("Harness future +1 " + $QueueName)
        description     = 'Synthetic future-queue increment item'
        priority        = 'LOW'
        status          = 'OPEN'
        source          = 'Manual'
        category        = 'testing'
        created         = (Get-Date).ToUniversalTime().ToString('o')
        modified        = (Get-Date).ToUniversalTime().ToString('o')
        sessionModCount = 1
    }

    $arr = @($registry.PSObject.Properties[$QueueName].Value)
    $arr += $synthetic
    $registry.PSObject.Properties[$QueueName].Value = $arr

    if ($null -eq $registry.statistics) {
        $registry | Add-Member -MemberType NoteProperty -Name 'statistics' -Value ([ordered]@{ totalItemsCreated = 0 }) -Force
    }
    if ($registry.statistics.PSObject.Properties.Name -notcontains 'totalItemsCreated') {
        $registry.statistics | Add-Member -MemberType NoteProperty -Name 'totalItemsCreated' -Value 0 -Force
    }
    $registry.statistics.totalItemsCreated = [int]$registry.statistics.totalItemsCreated + 1
    if ($null -ne $registry.meta -and $registry.meta.PSObject.Properties.Name -contains 'lastModified') {
        $registry.meta.lastModified = (Get-Date).ToUniversalTime().ToString('o')
    }

    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $regPath -Encoding UTF8

    # Rebuild known artifacts; unknown queues may not appear in those artifacts yet.
    $null = Invoke-PipelineArtifactRefresh -WorkspacePath $HarnessWorkspace
}

function Test-GuiQueueCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$XhtmlPath,
        [Parameter(Mandatory)][string[]]$QueueNames
    )

    $raw = Get-Content -LiteralPath $XhtmlPath -Raw -Encoding UTF8
    $results = @()

    foreach ($q in @($QueueNames)) {
        $prefix = 'pipelineData'
        $token = "$prefix.$q"
        $hasToken = ($raw -match [regex]::Escape($token))
        $results += New-Result -Name ("GUI counter token " + $q) -Passed:$hasToken -Detail ("Expected token: " + $token) -Severity 'Error'
    }

    return $results
}

function New-IsolatedHarnessWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceWorkspace)

    $tempRoot = Join-Path $env:TEMP ("PwShGUI-MetricHarness-" + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString().Substring(0, 8)))
    $null = New-Item -ItemType Directory -Path $tempRoot -Force

    foreach ($dirName in @('config', 'todo')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $tempRoot $dirName) -Force
    }

    # Seed from source config if available, otherwise initialize fresh.
    $sourceReg = Join-Path (Join-Path $SourceWorkspace 'config') 'cron-aiathon-pipeline.json'
    $destReg = Join-Path (Join-Path $tempRoot 'config') 'cron-aiathon-pipeline.json'

    if (Test-Path $sourceReg) {
        $raw = Get-Content -LiteralPath $sourceReg -Raw -Encoding UTF8
        Set-Content -LiteralPath $destReg -Value $raw -Encoding UTF8
    }

    if (-not (Test-Path $destReg)) {
        $null = Initialize-PipelineRegistry -WorkspacePath $tempRoot
    }

    # Normalize derived artifacts from current registry seed.
    $null = Invoke-PipelineArtifactRefresh -WorkspacePath $tempRoot

    return $tempRoot
}

$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

$harnessWorkspace = New-IsolatedHarnessWorkspace -SourceWorkspace $WorkspacePath
$regPath = Join-Path (Join-Path $harnessWorkspace 'config') 'cron-aiathon-pipeline.json'
$registry = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
$queueNames = Get-QueueNamesFromRegistry -Registry $registry
$knownQueueNames = Get-KnownQueueNameSet

$report = [ordered]@{
    generatedAt       = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath     = $WorkspacePath
    harnessWorkspace  = $harnessWorkspace
    queueNames        = $queueNames
    knownQueueNames   = $knownQueueNames
    oneItemResults    = @()
    guiCoverage       = @()
    pass              = $true
}

foreach ($q in @($queueNames)) {
    $before = Get-Snapshot -HarnessWorkspace $harnessWorkspace -QueueNames $queueNames
    Add-OneItemToQueue -HarnessWorkspace $harnessWorkspace -QueueName $q
    $after = Get-Snapshot -HarnessWorkspace $harnessWorkspace -QueueNames $queueNames

    $queueDelta = ([int]$after.queueCounts[$q]) - ([int]$before.queueCounts[$q])
    $totalDelta = ([int]$after.totalAllQueues) - ([int]$before.totalAllQueues)

    $queueOk = ($queueDelta -eq 1)
    $totalOk = ($totalDelta -eq 1)

    $artifactExpectation = ($knownQueueNames -contains $q)
    $indexDelta = ([int]$after.indexCount) - ([int]$before.indexCount)
    $masterDelta = ([int]$after.masterCount) - ([int]$before.masterCount)
    $artifactOk = $true

    if ($artifactExpectation) {
        $artifactOk = ($indexDelta -eq 1 -and $masterDelta -eq 1)
    }

    $createdDelta = ([int]$after.totalItemsCreated) - ([int]$before.totalItemsCreated)
    $createdOk = ($createdDelta -eq 1)

    $queuePass = ($queueOk -and $totalOk -and $artifactOk -and $createdOk)
    if (-not $queuePass) {
        $report.pass = $false
    }

    $report.oneItemResults += [ordered]@{
        queueName            = $q
        queueDelta           = $queueDelta
        totalDelta           = $totalDelta
        indexDelta           = $indexDelta
        masterDelta          = $masterDelta
        totalItemsCreatedDelta = $createdDelta
        knownQueueArtifactsExpected = $artifactExpectation
        passed               = $queuePass
        notes                = if ($artifactExpectation) { '' } else { 'Future queue fallback path used. Artifact parity is advisory until queue map integration is added.' }
    }
}

if (-not $SkipGuiCoverage) {
    $pipelineManagerPath = Join-Path $WorkspacePath 'XHTML-PipelineManager.xhtml'
    if (Test-Path $pipelineManagerPath) {
        $coverage = Test-GuiQueueCoverage -XhtmlPath $pipelineManagerPath -QueueNames $queueNames
        $report.guiCoverage = $coverage
        foreach ($c in @($coverage)) {
            if (-not $c.passed) {
                $report.pass = $false
            }
        }
    } else {
        $report.guiCoverage = @(
            New-Result -Name 'GUI file exists' -Passed:$false -Detail ('Missing: ' + $pipelineManagerPath) -Severity 'Error'
        )
        $report.pass = $false
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $logsDir = Join-Path $WorkspacePath 'logs'
    if (-not (Test-Path $logsDir)) {
        $null = New-Item -ItemType Directory -Path $logsDir -Force
    }
    $OutputPath = Join-Path $logsDir ('pipeline-metric-increment-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Output ($report | ConvertTo-Json -Depth 6)
if (-not $report.pass) {
    exit 1
}

