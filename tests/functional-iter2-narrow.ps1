# VersionTag: 2605.B5.V46.0
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI'
Import-Module (Join-Path $root 'modules\PwShGUI-SecretScan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-LegacyEncoding.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-ManifestDiff.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-AgentScorecard.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-LaunchTimingProfile.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SinDriftScan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SinHeatmap.psm1') -Force -DisableNameChecking

Write-Host '== Invoke-SecretScan (modules folder only) =='
$s = Invoke-SecretScan -Root (Join-Path $root 'modules')
"  Findings: $(@($s).Count) (expected 0 in modules)"

Write-Host '== Test-FileEncoding (5 modules) =='
Get-ChildItem (Join-Path $root 'modules\PwShGUI-Sin*.psm1') | Select-Object -First 5 | ForEach-Object {
    $r = Test-FileEncoding -Path $_.FullName
    "  $(Split-Path -Leaf $r.Path) BOM=$($r.HasBom) NonAscii=$($r.HasNonAscii) NeedsFix=$($r.NeedsFix)"
}

Write-Host '== Get-ManifestSnapshot =='
$snap = Get-ManifestSnapshot -ModulesPath (Join-Path $root 'modules')
"  Manifests captured: $(@($snap.Modules.PSObject.Properties).Count)"

Write-Host '== Get-AgentScorecard =='
$a = Get-AgentScorecard -Root $root
"  Agents: $(@($a).Count)"
$a | Select-Object -First 3 | ForEach-Object { "    - $($_.Agent) score=$($_.Score)" }

Write-Host '== Get-LaunchTimingProfile =='
$lt = Get-LaunchTimingProfile -LogsPath (Join-Path $root 'logs')
"  Timing rows: $(@($lt).Count)"

Write-Host '== Invoke-SinDriftScan (modules only) =='
$d = Invoke-SinDriftScan -Root (Join-Path $root 'modules')
"  Drift findings: $(@($d).Count)"

Write-Host '== Get-SinHeatmap (synthetic findings) =='
$tmp = Join-Path $env:TEMP 'sinscan-test.json'
@(
    [PSCustomObject]@{ File = (Join-Path $root 'modules\PwShGUI-DependencyMap.psm1'); Line = 1; Pattern = 'P004' },
    [PSCustomObject]@{ File = (Join-Path $root 'modules\PwShGUI-DependencyMap.psm1'); Line = 5; Pattern = 'P017' },
    [PSCustomObject]@{ File = (Join-Path $root 'modules\PwShGUI-AutoRemediate.psm1'); Line = 2; Pattern = 'P002' }
) | ConvertTo-Json -Depth 3 | Out-File $tmp -Encoding UTF8
$h = Get-SinHeatmap -FindingsPath $tmp -Top 10
"  Heatmap rows: $(@($h).Count)"
Remove-Item $tmp -Force

Write-Host 'FUNCTIONAL-OK'

