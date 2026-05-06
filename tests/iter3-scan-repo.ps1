# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI'
$out  = Join-Path $root 'reports\iter3'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

Import-Module (Join-Path $root 'modules\PwShGUI-XhtmlReportTester.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SecretScan.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-LegacyEncoding.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SinDriftScan.psm1')        -Force -DisableNameChecking

Write-Host '== 1. Test-XhtmlReports across ~REPORTS =='
$x = Test-XhtmlReports -Path (Join-Path $root '~REPORTS') -OutputPath (Join-Path $out 'xhtml-audit.json')
$xBad = @($x | Where-Object { -not $_.XmlOk -or $_.P032Fail -or $_.P033Fail })
"  XHTML files: $(@($x).Count); bad: $(@($xBad).Count)"
$xBad | ForEach-Object { "  - $(Split-Path -Leaf $_.File) Xml=$($_.XmlOk) P032=$($_.P032Fail) P033=$($_.P033Fail) Err=$($_.XmlError)" }

Write-Host '== 2. Invoke-SecretScan (modules + scripts + config only) =='
$s1 = Invoke-SecretScan -Root (Join-Path $root 'modules') -OutputPath (Join-Path $out 'secrets-modules.json')
$s2 = Invoke-SecretScan -Root (Join-Path $root 'scripts') -OutputPath (Join-Path $out 'secrets-scripts.json')
$s3 = Invoke-SecretScan -Root (Join-Path $root 'config')  -OutputPath (Join-Path $out 'secrets-config.json')
"  Findings: modules=$(@($s1).Count) scripts=$(@($s2).Count) config=$(@($s3).Count)"
@($s1; $s2; $s3) | Select-Object -First 10 | ForEach-Object { "  - $($_.Rule) $(Split-Path -Leaf $_.File):$($_.Line) $($_.Preview)" }

Write-Host '== 3. Test-FileEncoding sweep across modules =='
$enc = Get-ChildItem (Join-Path $root 'modules') -Filter *.psm1 -File | ForEach-Object { Test-FileEncoding -Path $_.FullName }
$encBad = @($enc | Where-Object { $_.NeedsFix })
"  Modules: $(@($enc).Count); needs-fix: $(@($encBad).Count)"
$encBad | ForEach-Object { "  - $(Split-Path -Leaf $_.Path) BOM=$($_.HasBom) NonAscii=$($_.HasNonAscii) Double=$($_.DoubleEncoded)" }
$enc | ConvertTo-Json -Depth 5 | Out-File (Join-Path $out 'encoding-modules.json') -Encoding UTF8

Write-Host '== 4. Invoke-SinDriftScan across modules + scripts =='
$d1 = Invoke-SinDriftScan -Root (Join-Path $root 'modules') -OutputPath (Join-Path $out 'drift-modules.json')
$d2 = Invoke-SinDriftScan -Root (Join-Path $root 'scripts') -OutputPath (Join-Path $out 'drift-scripts.json')
"  Drift: modules=$(@($d1).Count) scripts=$(@($d2).Count)"

Write-Host '== Done =='
"Reports written to $out"
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize | Out-String

