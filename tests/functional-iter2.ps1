# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI'
Import-Module (Join-Path $root 'modules\PwShGUI-XhtmlReportTester.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SecretScan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-LegacyEncoding.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-ManifestDiff.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-AgentScorecard.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-LaunchTimingProfile.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SinDriftScan.psm1') -Force -DisableNameChecking

Write-Host '== Test-XhtmlReports =='
$x = Test-XhtmlReports -Path (Join-Path $root '~REPORTS')
"  Files scanned: $(@($x).Count)"
$bad = @($x | Where-Object { -not $_.XmlOk -or $_.P032Fail -or $_.P033Fail })
"  Bad: $(@($bad).Count)"
$bad | Select-Object -First 5 | ForEach-Object { "    - $($_.File) Xml=$($_.XmlOk) P032=$($_.P032Fail) P033=$($_.P033Fail)" }

Write-Host '== Invoke-SecretScan (root, top 5) =='
$s = Invoke-SecretScan -Root $root
"  Findings: $(@($s).Count)"
$s | Select-Object -First 5 | ForEach-Object { "    - $($_.Rule) :: $($_.File):$($_.Line) $($_.Preview)" }

Write-Host '== Test-FileEncoding (5 modules) =='
Get-ChildItem (Join-Path $root 'modules\PwShGUI-Sin*.psm1') | Select-Object -First 5 | ForEach-Object {
    $r = Test-FileEncoding -Path $_.FullName
    "  $($r.Path | Split-Path -Leaf) BOM=$($r.HasBom) NonAscii=$($r.HasNonAscii) Double=$($r.DoubleEncoded) NeedsFix=$($r.NeedsFix)"
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
"  Timing rows: $(@($lt).Count) (0 expected if logs lack STARTUP_MS markers)"

Write-Host '== Invoke-SinDriftScan (limited) =='
$d = Invoke-SinDriftScan -Root (Join-Path $root 'modules')
"  Drift findings: $(@($d).Count)"

Write-Host 'FUNCTIONAL-OK'

