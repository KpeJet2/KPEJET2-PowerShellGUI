# VersionTag: 2606.B5.V51.4
$ErrorActionPreference = 'Stop'
$out  = Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

Import-Module (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules\PwShGUI-XhtmlReportTester.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules\PwShGUI-SecretScan.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules\PwShGUI-LegacyEncoding.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules\PwShGUI-SinDriftScan.psm1')        -Force -DisableNameChecking

Write-Host '== 1. Test-XhtmlReports across ~REPORTS =='
$x = Test-XhtmlReports -Path (Join-Path -Path 'C:\PowerShellGUI' -ChildPath '~REPORTS') -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\xhtml-audit.json')
$xBad = @($x | Where-Object { -not $_.XmlOk -or $_.P032Fail -or $_.P033Fail })
"  XHTML files: $(@($x).Count); bad: $(@($xBad).Count)"
$xBad | ForEach-Object { "  - $(Split-Path -Leaf $_.File) Xml=$($_.XmlOk) P032=$($_.P032Fail) P033=$($_.P033Fail) Err=$($_.XmlError)" }

Write-Host '== 2. Invoke-SecretScan (modules + scripts + config only) =='
$s1 = Invoke-SecretScan -Root (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules') -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\secrets-modules.json')
$s2 = Invoke-SecretScan -Root (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'scripts') -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\secrets-scripts.json')
$s3 = Invoke-SecretScan -Root (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'config')  -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\secrets-config.json')
"  Findings: modules=$(@($s1).Count) scripts=$(@($s2).Count) config=$(@($s3).Count)"
@($s1; $s2; $s3) | Select-Object -First 10 | ForEach-Object { "  - $($_.Rule) $(Split-Path -Leaf $_.File):$($_.Line) $($_.Preview)" }

Write-Host '== 3. Test-FileEncoding sweep across modules =='
$modulePath = Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules'
$enc = Get-ChildItem $modulePath -Filter *.psm1 -File | ForEach-Object { Test-FileEncoding -Path $_.FullName }
$encBad = @($enc | Where-Object { $_.NeedsFix })
"  Modules: $(@($enc).Count); needs-fix: $(@($encBad).Count)"
$encBad | ForEach-Object { "  - $(Split-Path -Leaf $_.Path) BOM=$($_.HasBom) NonAscii=$($_.HasNonAscii) Double=$($_.DoubleEncoded)" }
$enc | ConvertTo-Json -Depth 5 | Out-File (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\encoding-modules.json') -Encoding UTF8

Write-Host '== 4. Invoke-SinDriftScan across modules + scripts =='
$d1 = Invoke-SinDriftScan -Root (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'modules') -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\drift-modules.json')
$d2 = Invoke-SinDriftScan -Root (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'scripts') -OutputPath (Join-Path -Path 'C:\PowerShellGUI' -ChildPath 'reports\iter3\drift-scripts.json')
"  Drift: modules=$(@($d1).Count) scripts=$(@($d2).Count)"

Write-Host '== Done =='
"Reports written to $out"
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize | Out-String



