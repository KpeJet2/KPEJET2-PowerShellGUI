# VersionTag: 2605.B5.V46.0
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-SinHeatmap.psm1 -Force -DisableNameChecking

$out = 'C:\PowerShellGUI\reports\iter9'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# Convert PSSA -> heatmap-shape findings
$pssa = Get-Content 'C:\PowerShellGUI\reports\iter6\pssa-modules.json' -Raw | ConvertFrom-Json
$findings = $pssa.Findings | ForEach-Object {
    [PSCustomObject]@{ File = $_.File; Line = $_.Line; Pattern = $_.RuleName }
}
$fJson = Join-Path $out 'pssa-findings.json'
$findings | ConvertTo-Json -Depth 4 | Set-Content -Path $fJson -Encoding UTF8

$svg = Join-Path $out 'heatmap.svg'
$heat = Get-SinHeatmap -FindingsPath $fJson -SvgPath $svg -Top 20
"Top files by SIN density (per 1k LoC):"
$heat | Format-Table -AutoSize
$heat | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $out 'heatmap-top20.json') -Encoding UTF8
"SVG written: $svg ($([System.IO.File]::ReadAllBytes($svg).Length) bytes)"

