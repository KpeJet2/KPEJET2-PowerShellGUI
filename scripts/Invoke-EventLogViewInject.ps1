# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Pipeline
<#
.SYNOPSIS
    Idempotently inject the shared EventLogView mount partial into target XHTML pages.

.DESCRIPTION
    Wildcard-style insertion. Each target gets injected just before </body>:
      <!-- EvLV-AUTOMOUNT V31.0 -->
      <link rel="stylesheet" href="<rel>/styles/eventlog-view.css"/>
      <script src="<rel>/scripts/XHTML-Checker/_assets/eventlog-view.js"></script>
      <div class="evlv-mount" data-scope="<scope>" data-title="<title>"></div>
      <script>document.addEventListener('DOMContentLoaded',function(){if(window.EvLV)EvLV.mountAll();});</script>

    The marker "<!-- EvLV-AUTOMOUNT" makes the operation idempotent.
    Per-page scope hints are picked from the route table below.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Per-page injection table -- scope follows EVENT-LOG-STANDARD.md scopes.
# 'extra' allows multiple mount divs on a single page (Checklists_V1-ROOT needs 3).
$routes = @(
    @{ rel='scripts\XHTML-Checker\XHTML-ServiceClusterController.xhtml'; scope='service';  title='Cluster Events' },
    @{ rel='XHTML-PipelineManager.xhtml';                                 scope='pipeline'; title='Pipeline Events' },
    @{ rel='scripts\XHTML-Checker\XHTML-MCPServiceConfig.xhtml';          scope='mcp';      title='MCP Events' },
    @{ rel='XHTML-WorkspaceHub.xhtml';                                    scope='root';     title='Workspace Aggregate Events' },
    @{ rel='~REPORTS\SIN-Scoreboard.xhtml';                               scope='sin';      title='SIN Events' },
    @{ rel='~README.md\PwShGUI-Checklists-TEST.xhtml';                    scope='pipeline'; title='Auto-UpAi Pipeline Events' },
    @{ rel='PwShGUI-Checklists_V1-ROOT.xhtml';                            scope='root';     title='V1-ROOT Events';
       extra=@(
           @{ scope='cron'; title='CronAiAthon Events' },
           @{ scope='gui';  title='GUI Events' }
       )
    }
)

function Get-RelativeAssetPath {
    param([string]$XhtmlRelPath)
    # Compute "../" prefix count needed from the xhtml file back to workspace root.
    $depth = ($XhtmlRelPath -split '[\\/]').Count - 1
    if ($depth -le 0) { return '.' }
    return (('..\' * $depth).TrimEnd('\'))
}

function Build-Snippet {
    param([string]$AssetBase, [array]$Mounts)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!-- EvLV-AUTOMOUNT V31.0 (PwShGUI-EventLogAdapter contract: docs/EVENT-LOG-STANDARD.md) -->')
    [void]$sb.AppendLine(('<link rel="stylesheet" href="{0}/styles/eventlog-view.css"/>' -f $AssetBase))
    [void]$sb.AppendLine(('<script src="{0}/scripts/XHTML-Checker/_assets/eventlog-view.js"></script>' -f $AssetBase))
    foreach ($m in $Mounts) {
        [void]$sb.AppendLine(('<div class="evlv-mount" data-scope="{0}" data-title="{1}" data-tail="500"></div>' -f $m.scope, $m.title))
    }
    [void]$sb.AppendLine('<script>document.addEventListener(''DOMContentLoaded'',function(){if(window.EvLV){EvLV.mountAll();}});</script>')
    return $sb.ToString()
}

$marker = '<!-- EvLV-AUTOMOUNT'
$summary = @()

foreach ($r in $routes) {
    $rel = [string]$r.rel
    $full = Join-Path $WorkspacePath $rel
    if (-not (Test-Path -LiteralPath $full)) {
        $summary += [ordered]@{ file=$rel; result='MISSING' }
        continue
    }
    $content = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    if ($content -match [regex]::Escape($marker)) {
        $summary += [ordered]@{ file=$rel; result='ALREADY-INJECTED' }
        continue
    }
    $closeIdx = $content.LastIndexOf('</body>')
    if ($closeIdx -lt 0) {
        $summary += [ordered]@{ file=$rel; result='NO-BODY-CLOSE' }
        continue
    }
    $assetBase = Get-RelativeAssetPath -XhtmlRelPath $rel
    $mounts = @( @{ scope=$r.scope; title=$r.title } )
    if ($r.ContainsKey('extra') -and $r.extra) { foreach ($x in $r.extra) { $mounts += $x } }
    $snippet = Build-Snippet -AssetBase $assetBase -Mounts $mounts
    $newContent = $content.Substring(0, $closeIdx) + $snippet + $content.Substring($closeIdx)

    if (-not $DryRun) {
        # Preserve original encoding (UTF-8 with or without BOM).
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $enc = New-Object System.Text.UTF8Encoding($hasBom)
        [System.IO.File]::WriteAllText($full, $newContent, $enc)
    }
    $summary += [ordered]@{ file=$rel; result=if($DryRun){'WOULD-INJECT'}else{'INJECTED'}; mounts=$mounts.Count; assetBase=$assetBase }
}

$summary | ForEach-Object {
    $m = if ($_.PSObject.Properties.Name -contains 'mounts') { $_.mounts } else { 0 }
    Write-Host ('{0,-18} {1,2} {2}' -f $_.result, $m, $_.file)
}
$summary | ConvertTo-Json -Depth 5
exit 0

