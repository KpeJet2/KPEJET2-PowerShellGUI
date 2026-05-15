<#
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-30)
# SupportsPS7.6: YES(As of: 2026-04-30)
.SYNOPSIS
    PwShGUI-DependencyMap - Auto-generate module dependency graph.
.DESCRIPTION
    Scans all .psm1/.psd1/.ps1 files for Import-Module / using module
    statements and builds a Mermaid DAG plus JSON manifest.
.NOTES
    SIN posture: P004 @().Count, P006 BOM, P012/P017 -Encoding UTF8,
    P014 -Depth 6, P018 2-arg Join-Path, P027 @() forced arrays.
#>
#Requires -Version 5.1

$script:ModuleVersion = '2604.B3.V28.0'

function Get-DependencyMap {
    <#
    .SYNOPSIS  Build module dependency graph for the workspace.
    .OUTPUTS   PSCustomObject { Nodes, Edges, Mermaid }
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = (Get-Location).Path,
        [string[]]$Include = @('modules', 'scripts', 'tools'),
        [string[]]$Exclude = @('node_modules', '.venv', 'temp', '~DOWNLOADS')
    )

    $files = @()
    foreach ($sub in $Include) {
        $root = Join-Path $WorkspacePath $sub
        if (Test-Path $root) {
            $files += @(Get-ChildItem -Path $root -Recurse -File -Include *.psm1, *.psd1, *.ps1 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch ($Exclude -join '|') })
        }
    }

    $nodes = @{}
    $edges = New-Object System.Collections.Generic.List[object]
    $importPattern = '(?im)^\s*(?:Import-Module|using\s+module)\s+[''"]?([^''"\s;]+)'

    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if (-not $nodes.ContainsKey($name)) {
            $nodes[$name] = @{ name = $name; path = $f.FullName; type = $f.Extension.TrimStart('.') }
        }
        try {
            $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            continue
        }
        $importMatches = [regex]::Matches($content, $importPattern)
        foreach ($m in $importMatches) {
            $depRaw = $m.Groups[1].Value
            $dep = [System.IO.Path]::GetFileNameWithoutExtension($depRaw)
            if ($dep -and $dep -ne $name) {
                $edges.Add([PSCustomObject]@{ from = $name; to = $dep }) | Out-Null
            }
        }
    }

    # Mermaid output
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('graph LR')
    foreach ($k in ($nodes.Keys | Sort-Object)) {
        [void]$sb.AppendLine(("  {0}[""{0}""]" -f ($k -replace '[^A-Za-z0-9_]', '_')))
    }
    foreach ($e in $edges) {
        $a = $e.from -replace '[^A-Za-z0-9_]', '_'
        $b = $e.to   -replace '[^A-Za-z0-9_]', '_'
        [void]$sb.AppendLine("  $a --> $b")
    }

    $nodeArr = @()
    foreach ($k in $nodes.Keys) { $nodeArr += ,$nodes[$k] }
    $edgeArr = @()
    foreach ($e in $edges)      { $edgeArr += ,$e }

    [PSCustomObject]@{
        Generated = (Get-Date).ToUniversalTime().ToString('o')
        Workspace = $WorkspacePath
        NodeCount = $nodeArr.Count
        EdgeCount = $edgeArr.Count
        Nodes     = $nodeArr
        Edges     = $edgeArr
        Mermaid   = $sb.ToString()
    }
}

function Invoke-DependencyGraph {
    <#
    .SYNOPSIS  Generate dependency graph and persist to ~REPORTS.
        .DESCRIPTION
      Detailed behaviour: Invoke dependency graph.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$WorkspacePath = (Get-Location).Path,
        [string]$OutputDir
    )
    if (-not $OutputDir) { $OutputDir = Join-Path $WorkspacePath '~REPORTS' }
    if (-not (Test-Path $OutputDir)) {
        if ($PSCmdlet.ShouldProcess($OutputDir, 'Create directory')) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }
    }

    $map = Get-DependencyMap -WorkspacePath $WorkspacePath
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
    $jsonPath = Join-Path $OutputDir ("dependency-map-{0}.json" -f $stamp)
    $mmdPath  = Join-Path $OutputDir ("dependency-map-{0}.mmd"  -f $stamp)

    if ($PSCmdlet.ShouldProcess($jsonPath, 'Write JSON')) {
        $map | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    }
    if ($PSCmdlet.ShouldProcess($mmdPath, 'Write Mermaid')) {
        Set-Content -Path $mmdPath -Value $map.Mermaid -Encoding UTF8
    }

    [PSCustomObject]@{
        JsonPath  = $jsonPath
        MmdPath   = $mmdPath
        Nodes     = $map.NodeCount
        Edges     = $map.EdgeCount
    }
}

Export-ModuleMember -Function Get-DependencyMap, Invoke-DependencyGraph

