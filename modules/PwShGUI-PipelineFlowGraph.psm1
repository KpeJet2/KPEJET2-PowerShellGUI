# VersionTag: 2608.B1.V54.2
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-14
# SupportsPS7.6TestedDate: 2026-08-14
# FileRole: Module
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    return ($InputObject | ConvertTo-Json -Depth 32 -Compress)
}

function Get-HashHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($b in $hash) {
        [void]$builder.AppendFormat('{0:x2}', $b)
    }
    return $builder.ToString()
}

function Get-PipelineFlowGraphHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Graph
    )

    $blades = @($Graph.blades | Sort-Object order, id)
    $nodes = @($Graph.nodes | Sort-Object id)
    $edges = @($Graph.edges | Sort-Object from, to, kind)
    $glossary = @($Graph.glossary | Sort-Object term)

    $canonical = [ordered]@{
        SchemaVersion = [string]$Graph.SchemaVersion
        VersionTag = [string]$Graph.VersionTag
        generatedBy = [string]$Graph.generatedBy
        sourceHashes = $Graph.sourceHashes
        blades = @($blades)
        nodes = @($nodes)
        edges = @($edges)
        glossary = @($glossary)
        crossRefs = $Graph.crossRefs
        stats = $Graph.stats
    }

    return (Get-HashHex -Text (ConvertTo-CanonicalJson -InputObject $canonical))
}

function Get-PipelineFlowGraph {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
        [string]$SourcesConfigPath = ''
    )

    $root = (Resolve-Path -LiteralPath $WorkspacePath).Path
    if ([string]::IsNullOrWhiteSpace($SourcesConfigPath)) {
        $SourcesConfigPath = Join-Path (Join-Path $root 'config') 'pipeline-flow-sources.json'
    }

    if (-not (Test-Path -LiteralPath $SourcesConfigPath)) {
        throw ('Flow sources config missing: ' + $SourcesConfigPath)
    }

    $cfg = Get-Content -LiteralPath $SourcesConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $sourceFiles = @()
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'sourceFiles') {
        $sourceFiles = @($cfg.sourceFiles)
    }

    $sourceGlobs = @()
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'sourceGlobs') {
        $sourceGlobs = @($cfg.sourceGlobs)
    }

    $allSources = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $sourceFiles) {
        if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
        [void]$allSources.Add(([string]$rel).Replace('\\', '/'))
    }

    foreach ($glob in $sourceGlobs) {
        if ([string]::IsNullOrWhiteSpace([string]$glob)) { continue }
        $globHitList = @(Get-ChildItem -Path $root -Filter ([System.IO.Path]::GetFileName([string]$glob)) -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($m in $globHitList) {
            $relPath = [string]$m.FullName.Substring($root.Length).TrimStart('\\')
            $relPath = $relPath.Replace('\\', '/')
            if (-not $allSources.Contains($relPath)) {
                [void]$allSources.Add($relPath)
            }
        }
    }

    $bladeDefs = @()
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'bladeDefinitions') {
        $bladeDefs = @($cfg.bladeDefinitions)
    }

    $nodes = New-Object System.Collections.Generic.List[object]
    $sourceHashes = [ordered]@{}

    foreach ($src in @($allSources | Sort-Object)) {
        $abs = Join-Path $root ($src -replace '/', '\\')
        if (-not (Test-Path -LiteralPath $abs)) { continue }

        $slug = (($src -replace '[^a-zA-Z0-9]+', '-') -replace '-+', '-').Trim('-').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'unknown' }

        $bladeId = 'blade.pipeline'
        if ($src -like 'tests/*') { $bladeId = 'blade.gates' }
        elseif ($src -like 'config/*' -or $src -like 'sin_registry/*') { $bladeId = 'blade.artifacts' }
        elseif ($src -like 'scripts/Invoke-CronProcessor.ps1') { $bladeId = 'blade.cron' }

        $node = [ordered]@{
            id = ('node.source.' + $slug)
            label = $src
            kind = 'script'
            blade = $bladeId
            parent = $null
            order = 0
            sourceFile = $src
            sourceLine = 1
            functionName = ''
            blocking = $false
            status = 'UNKNOWN'
            terms = @('pipeline', 'flow')
            links = @(
                [ordered]@{ rel = 'readme'; href = 'README.md'; title = 'Workspace README' }
            )
        }
        [void]$nodes.Add($node)

        $raw = Get-Content -LiteralPath $abs -Raw -Encoding UTF8
        $sourceHashes[$src] = Get-HashHex -Text $raw
    }

    $edges = @()
    $sortedNodes = @($nodes | Sort-Object id)
    for ($i = 0; $i -lt (@($sortedNodes).Count - 1); $i++) {
        $edges += [ordered]@{
            from = [string]$sortedNodes[$i].id
            to = [string]$sortedNodes[$i + 1].id
            kind = 'sequence'
            condition = 'scaffold-order'
            blocking = $false
        }
    }

    $graph = [ordered]@{
        SchemaVersion = 'CronPipeFlow/1.0'
        VersionTag = '2608.B1.V54.2'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        generatedBy = 'modules/PwShGUI-PipelineFlowGraph.psm1'
        graphHash = ''
        sourceHashes = $sourceHashes
        blades = @($bladeDefs | Sort-Object order, id)
        nodes = @($sortedNodes)
        edges = @($edges)
        glossary = @()
        crossRefs = [ordered]@{
            canonicalPaths = 'config/pipeline-canonical-paths.json'
            tasks = '.vscode/tasks.json'
        }
        stats = [ordered]@{
            nodeCount = @($sortedNodes).Count
            edgeCount = @($edges).Count
            gateCount = @($sortedNodes | Where-Object { $_.kind -eq 'gate' }).Count
            orphanNodeCount = @($sortedNodes | Where-Object { @($_.links).Count -eq 0 }).Count
        }
    }

    $graph.graphHash = Get-PipelineFlowGraphHash -Graph $graph
    return [PSCustomObject]$graph
}

function Compare-PipelineFlowGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Graph,
        [Parameter(Mandatory = $true)]
        $Baseline
    )

    $expectedHash = ''
    if ($Baseline -and $Baseline.PSObject.Properties.Name -contains 'graphHash') {
        $expectedHash = [string]$Baseline.graphHash
    }

    $actualHash = [string]$Graph.graphHash
    $drift = -not ([string]::Equals($expectedHash, $actualHash, [System.StringComparison]::OrdinalIgnoreCase))

    return [PSCustomObject]@{
        driftDetected = $drift
        expectedHash = $expectedHash
        actualHash = $actualHash
        expectedNodeCount = [int]$(if ($Baseline.counts) { $Baseline.counts.nodes } else { 0 })
        actualNodeCount = [int]$Graph.stats.nodeCount
    }
}

function Export-PipelineFlowGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Graph,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        $null = New-Item -ItemType Directory -Path $outDir -Force
    }

    $Graph | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return $OutputPath
}

Export-ModuleMember -Function @(
    'Get-PipelineFlowGraph',
    'Get-PipelineFlowGraphHash',
    'Compare-PipelineFlowGraph',
    'Export-PipelineFlowGraph'
)
