# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-AgentScorecard
# Purpose: Aggregate per-agent activity from agents/ + reports/ into a scorecard.

function Get-AgentScorecard {
    <#
    .SYNOPSIS
    Build a per-agent activity scorecard.
    .DESCRIPTION
    Inspects agents/ for declared agents and counts touches in
    ~REPORTS/, sin_registry/, and CHANGELOG. Returns rows suitable
    for Section 1 of the SIN scoreboard.
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
        [string]$OutputPath
    )
    $agentsDir = Join-Path $Root 'agents'
    $agents = @()
    if (Test-Path $agentsDir) {
        $agents = @(Get-ChildItem -Path $agentsDir -File -Recurse -Include *.json, *.md, *.psm1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty BaseName -Unique)
    }
    if (-not $agents -or @($agents).Count -eq 0) {
        # Fallback: derive from common agent name patterns
        $agents = @('Plan4Me', 'kpe-AiGent_Code-INspectre', 'Explore', 'Shop-ListedItemsBot')
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $reportFiles = @(Get-ChildItem -Path (Join-Path $Root '~REPORTS') -Recurse -File -ErrorAction SilentlyContinue)
    $sinFiles    = @(Get-ChildItem -Path (Join-Path $Root 'sin_registry') -File -Filter *.json -ErrorAction SilentlyContinue)
    $changelog   = Join-Path $Root '~README.md\CHANGELOG.md'
    $clText = if (Test-Path $changelog) { Get-Content -Raw -Encoding UTF8 -Path $changelog } else { '' }
    foreach ($a in $agents) {
        $reportTouches = @($reportFiles | Where-Object { $_.Name -match [regex]::Escape($a) }).Count
        $sinTouches    = @($sinFiles | Where-Object {
            try { (Get-Content -Raw -Path $_.FullName -Encoding UTF8) -match [regex]::Escape($a) } catch { $false }
        }).Count
        $clTouches = ([regex]::Matches($clText, [regex]::Escape($a))).Count
        $rows.Add([PSCustomObject]@{
            Agent         = $a
            ReportTouches = $reportTouches
            SinTouches    = $sinTouches
            ChangelogTouches = $clTouches
            Score         = ($reportTouches * 1) + ($sinTouches * 3) + ($clTouches * 2)
        })
    }
    $arr = @($rows.ToArray() | Sort-Object Score -Descending)
    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding UTF8
    }
    $arr
}

Export-ModuleMember -Function Get-AgentScorecard

