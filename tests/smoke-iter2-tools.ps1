# VersionTag: 2605.B5.V46.0
$mods = @(
    @{ M = 'PwShGUI-SinDriftScan';        F = @('Get-ResolvedSinPatterns', 'Invoke-SinDriftScan') },
    @{ M = 'PwShGUI-XhtmlReportTester';   F = @('Test-XhtmlReports') },
    @{ M = 'PwShGUI-SecretScan';          F = @('Invoke-SecretScan') },
    @{ M = 'PwShGUI-LegacyEncoding';      F = @('Test-FileEncoding', 'Convert-LegacyEncoding') },
    @{ M = 'PwShGUI-ManifestDiff';        F = @('Get-ManifestSnapshot', 'Compare-ModuleManifest') },
    @{ M = 'PwShGUI-CheckpointPrune';     F = @('Invoke-CheckpointPrune') },
    @{ M = 'PwShGUI-SinHeatmap';          F = @('Get-SinHeatmap') },
    @{ M = 'PwShGUI-AgentScorecard';      F = @('Get-AgentScorecard') },
    @{ M = 'PwShGUI-PesterParallel';      F = @('Invoke-PesterParallel') },
    @{ M = 'PwShGUI-EventLogReplay';      F = @('Invoke-EventLogReplay') },
    @{ M = 'PwShGUI-LaunchTimingProfile'; F = @('Get-LaunchTimingProfile') },
    @{ M = 'PwShGUI-SinFixBranch';        F = @('New-SinFixBranch') }
)
$root = 'C:\PowerShellGUI\modules'
$fail = 0
foreach ($m in $mods) {
    $p = Join-Path $root ($m.M + '.psm1')
    try {
        Import-Module $p -Force -ErrorAction Stop -DisableNameChecking
        $missing = @($m.F | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
        if (@($missing).Count -gt 0) { Write-Host "FAIL $($m.M) missing: $($missing -join ',')"; $fail++ }
        else { Write-Host "OK   $($m.M) -> $($m.F -join ',')" }
    } catch {
        Write-Host "FAIL $($m.M) import: $_"
        $fail++
    }
}
if ($fail -gt 0) { exit 1 } else { Write-Host "ALL OK" }

