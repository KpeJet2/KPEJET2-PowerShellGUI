# VersionTag: 2605.B2.V31.7
# Module: PwShGUI-SinHeatmap
# Purpose: Build a per-file SIN density heatmap (returns data + optional inline SVG).

function Get-SinHeatmap {
    <#
    .SYNOPSIS
    Build a per-file SIN density table from a sin-scan findings JSON.
    .DESCRIPTION
    Reads a findings array (file/line/pattern), groups by file, computes
    density per 1000 lines, and optionally writes a small SVG bar chart.
    .EXAMPLE
    Get-SinHeatmap -FindingsPath .\reports\sin-scan.json -SvgPath .\reports\heatmap.svg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [string]$SvgPath,
        [int]$Top = 25
    )
    if (-not (Test-Path $FindingsPath)) { throw "Findings file not found: $FindingsPath" }
    $findings = @(Get-Content -Raw -Encoding UTF8 -Path $FindingsPath | ConvertFrom-Json)
    $rows = $findings | Group-Object File | ForEach-Object {
        $file = $_.Name
        $count = @($_.Group).Count
        $loc = 0
        if (Test-Path $file) {
            try { $loc = (Get-Content -Path $file -ErrorAction Stop | Measure-Object -Line).Lines } catch { $loc = 0 }
        }
        $density = if ($loc -gt 0) { [Math]::Round(($count * 1000.0) / $loc, 2) } else { 0 }
        [PSCustomObject]@{ File = $file; SinCount = $count; LinesOfCode = $loc; DensityPer1k = $density }
    } | Sort-Object DensityPer1k -Descending | Select-Object -First $Top

    if ($SvgPath) {
        $h = 18
        $w = 400
        $rowsArr = @($rows)
        $svgH = ($h * $rowsArr.Count) + 20
        $maxD = ([double]($rowsArr | Measure-Object DensityPer1k -Maximum).Maximum)
        if ($maxD -le 0) { $maxD = 1 }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("<?xml version='1.0' encoding='UTF-8'?>")
        [void]$sb.AppendLine("<svg xmlns='http://www.w3.org/2000/svg' width='$($w + 220)' height='$svgH' font-family='Consolas,monospace' font-size='11'>")
        $y = 10
        foreach ($r in $rowsArr) {
            $bar = [int](($r.DensityPer1k / $maxD) * $w)
            $name = (Split-Path -Leaf $r.File)
            $color = if ($r.DensityPer1k -gt 10) { '#c0392b' } elseif ($r.DensityPer1k -gt 3) { '#e67e22' } else { '#27ae60' }
            [void]$sb.AppendLine("<rect x='200' y='$y' width='$bar' height='14' fill='$color'/>")
            [void]$sb.AppendLine("<text x='195' y='$($y + 11)' text-anchor='end' fill='#333'>$([System.Security.SecurityElement]::Escape($name))</text>")
            [void]$sb.AppendLine("<text x='$($bar + 205)' y='$($y + 11)' fill='#333'>$($r.DensityPer1k)</text>")
            $y += $h
        }
        [void]$sb.AppendLine('</svg>')
        $dir = Split-Path -Parent $SvgPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($SvgPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    }
    $rows
}

Export-ModuleMember -Function Get-SinHeatmap

