# VersionTag: 2605.B2.V31.7
$ms = 'PwShGUI-DependencyMap','PwShGUI-CoverageReport','PwShGUI-AutoRemediate','PwShGUI-SinFromScan','PwShGUI-BreakingChange','PwShGUI-PSScriptAnalyzerScan'
foreach ($m in $ms) {
    try {
        Import-Module (Join-Path 'C:\PowerShellGUI\modules' "$m.psm1") -Force -ErrorAction Stop
        "OK   $m -> $((Get-Command -Module $m).Name -join ',')"
    } catch {
        "FAIL $m -> $_"
    }
}

