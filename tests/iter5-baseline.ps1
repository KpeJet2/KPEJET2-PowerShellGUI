# VersionTag: 2605.B5.V46.0
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-DependencyMap.psm1 -Force -DisableNameChecking
Import-Module C:\PowerShellGUI\modules\PwShGUI-BreakingChange.psm1 -Force -DisableNameChecking

$out = 'C:\PowerShellGUI\reports\iter5'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$map = Get-DependencyMap -WorkspacePath 'C:\PowerShellGUI'
$map | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $out 'dependency-map.json') -Encoding UTF8
"Dependency: $($map.Nodes.Count) nodes / $($map.Edges.Count) edges"

$surface = Get-ModuleSurface -Path 'C:\PowerShellGUI\modules'
$surface | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $out 'modules-surface-baseline.json') -Encoding UTF8
"Surface entries (function-level): $($surface.Keys.Count)"

$sec9 = @('SinDriftScan','XhtmlReportTester','SecretScan','LegacyEncoding','ManifestDiff','CheckpointPrune','SinHeatmap','AgentScorecard','PesterParallel','EventLogReplay','LaunchTimingProfile','SinFixBranch','DependencyMap','CoverageReport','AutoRemediate','SinFromScan','BreakingChange','PSScriptAnalyzerScan')
$found = foreach ($s in $sec9) {
    $name = "PwShGUI-$s"
    $hits = @($surface.Keys | Where-Object { $_ -like "$name::*" })
    [PSCustomObject]@{ Module = $name; FunctionCount = $hits.Count }
}
$found | Format-Table -AutoSize

