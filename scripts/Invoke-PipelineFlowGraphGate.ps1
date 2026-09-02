# VersionTag: 2608.B1.V54.2
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-14
# SupportsPS7.6TestedDate: 2026-08-14
# FileRole: Pipeline
#Requires -Version 5.1
<#!
.SYNOPSIS
    Builds and validates the pipeline flow graph artifact.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$SourcesConfigPath = '',
    [string]$GraphPath = '',
    [string]$BaselinePath = '',
    [string]$OutputJson = '',
    [switch]$AsObject,
    [switch]$FailOnDrift,
    [switch]$UpdateBaseline,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($SourcesConfigPath)) {
    $SourcesConfigPath = Join-Path (Join-Path $root 'config') 'pipeline-flow-sources.json'
}
if ([string]::IsNullOrWhiteSpace($GraphPath)) {
    $GraphPath = Join-Path (Join-Path $root 'config') 'pipeline-flow-graph.json'
}
if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    $BaselinePath = Join-Path (Join-Path $root 'config') 'pipeline-flow-baseline.json'
}
if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path (Join-Path $root 'reports') 'pipeline-flow-gate') 'latest.json'
}

$modulePath = Join-Path (Join-Path $root 'modules') 'PwShGUI-PipelineFlowGraph.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw ('Flow graph module missing: ' + $modulePath)
}
Import-Module -Name $modulePath -Force

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail)
    $checks.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }) | Out-Null
}

$exitCode = 0
$graph = $null
$drift = $null
$baseline = $null

try {
    if (Test-Path -LiteralPath $SourcesConfigPath) {
        Add-Check -Name 'SourcesConfigPresent' -Status 'PASS' -Detail $SourcesConfigPath
    } else {
        Add-Check -Name 'SourcesConfigPresent' -Status 'FAIL' -Detail $SourcesConfigPath
        throw ('Flow sources config missing: ' + $SourcesConfigPath)
    }

    $graph = Get-PipelineFlowGraph -WorkspacePath $root -SourcesConfigPath $SourcesConfigPath
    Add-Check -Name 'GraphBuilt' -Status 'PASS' -Detail ('nodes=' + [string]$graph.stats.nodeCount + '; edges=' + [string]$graph.stats.edgeCount)

    if (Test-Path -LiteralPath $BaselinePath) {
        $baseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Check -Name 'BaselinePresent' -Status 'PASS' -Detail $BaselinePath
    } else {
        $baseline = [PSCustomObject]@{ graphHash = ''; counts = @{ nodes = 0 } }
        Add-Check -Name 'BaselinePresent' -Status 'WARN' -Detail ('Baseline not found: ' + $BaselinePath)
    }

    $drift = Compare-PipelineFlowGraph -Graph $graph -Baseline $baseline
    if ($drift.driftDetected) {
        $status = if ($FailOnDrift) { 'FAIL' } else { 'WARN' }
        Add-Check -Name 'BaselineDrift' -Status $status -Detail ('expected=' + $drift.expectedHash + '; actual=' + $drift.actualHash)
        if ($FailOnDrift) { $exitCode = 1 }
    } else {
        Add-Check -Name 'BaselineDrift' -Status 'PASS' -Detail 'No drift detected'
    }

    if ($UpdateBaseline) {
        $baselineOut = [ordered]@{
            VersionTag = [string]$graph.VersionTag
            SchemaVersion = [string]$graph.SchemaVersion
            baselineGeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            graphHash = [string]$graph.graphHash
            counts = [ordered]@{
                nodes = [int]$graph.stats.nodeCount
                edges = [int]$graph.stats.edgeCount
                gates = [int]$graph.stats.gateCount
                orphanNodes = [int]$graph.stats.orphanNodeCount
            }
            bladeCounts = @()
        }

        $baselineDir = Split-Path -Parent $BaselinePath
        if (-not (Test-Path -LiteralPath $baselineDir)) {
            $null = New-Item -ItemType Directory -Path $baselineDir -Force
        }
        $baselineOut | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $BaselinePath -Encoding UTF8
        Add-Check -Name 'BaselineUpdated' -Status 'PASS' -Detail $BaselinePath
        $drift = Compare-PipelineFlowGraph -Graph $graph -Baseline $baselineOut
    }

    if (-not $VerifyOnly) {
        Export-PipelineFlowGraph -Graph $graph -OutputPath $GraphPath | Out-Null
        Add-Check -Name 'GraphArtifactWritten' -Status 'PASS' -Detail $GraphPath
    } else {
        Add-Check -Name 'GraphArtifactWritten' -Status 'SKIP' -Detail 'VerifyOnly enabled'
    }
}
catch {
    Add-Check -Name 'GateRuntime' -Status 'FAIL' -Detail $_.Exception.Message
    $exitCode = 1
}

$graphSummary = $null
if ($null -ne $graph) {
    $graphSummary = [ordered]@{
        SchemaVersion = [string]$graph.SchemaVersion
        VersionTag = [string]$graph.VersionTag
        graphHash = [string]$graph.graphHash
        stats = $graph.stats
    }
}

$result = @{}
$result['generatedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
$result['workspacePath'] = $root
$result['sourcesConfigPath'] = $SourcesConfigPath
$result['graphPath'] = $GraphPath
$result['baselinePath'] = $BaselinePath
$result['checks'] = @($checks | ForEach-Object { $_ })
$result['drift'] = $drift
$result['graph'] = $graphSummary
$result['failOnDrift'] = [bool]$FailOnDrift
$result['verifyOnly'] = [bool]$VerifyOnly
$result['updateBaseline'] = [bool]$UpdateBaseline
$result['exitCode'] = $exitCode
$resultObject = [PSCustomObject]@{
    generatedAtUtc = $result['generatedAtUtc']
    workspacePath = $result['workspacePath']
    sourcesConfigPath = $result['sourcesConfigPath']
    graphPath = $result['graphPath']
    baselinePath = $result['baselinePath']
    checks = @($result['checks'])
    drift = $result['drift']
    graph = $result['graph']
    failOnDrift = $result['failOnDrift']
    verifyOnly = $result['verifyOnly']
    updateBaseline = $result['updateBaseline']
    exitCode = $result['exitCode']
}

$outDir = Split-Path -Parent $OutputJson
if (-not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputJson -Encoding UTF8

if ($AsObject) {
    return $resultObject
}

$resultObject
if ($exitCode -ne 0) {
    exit 1
}

exit 0
