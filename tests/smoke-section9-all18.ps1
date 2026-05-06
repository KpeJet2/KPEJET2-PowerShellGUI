# VersionTag: 2605.B2.V31.7
$ms = @(
    'PwShGUI-DependencyMap','PwShGUI-CoverageReport','PwShGUI-AutoRemediate',
    'PwShGUI-SinFromScan','PwShGUI-BreakingChange','PwShGUI-PSScriptAnalyzerScan',
    'PwShGUI-SinDriftScan','PwShGUI-SinHeatmap','PwShGUI-XhtmlReportTester',
    'PwShGUI-SecretScan','PwShGUI-LegacyEncoding','PwShGUI-EventLogReplay',
    'PwShGUI-AgentScorecard','PwShGUI-PesterParallel','PwShGUI-ManifestDiff',
    'PwShGUI-CheckpointPrune','PwShGUI-LaunchTimingProfile','PwShGUI-SinFixBranch'
)
$ok = 0; $fail = 0
foreach ($m in $ms) {
    try {
        Import-Module (Join-Path 'C:\PowerShellGUI\modules' "$m.psm1") -Force -ErrorAction Stop
        $cmds = (Get-Command -Module $m | Select-Object -ExpandProperty Name) -join ','
        "OK   $m -> $cmds"
        $ok++
    } catch {
        "FAIL $m -> $($_.Exception.Message)"
        $fail++
    }
}
"---"
"Total OK:$ok FAIL:$fail"

