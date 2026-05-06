# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-AutoRemediate.psm1 -Force -DisableNameChecking
$out = 'C:\PowerShellGUI\reports\iter7'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# Direct run with backup
$res = Invoke-AutoRemediate -Path 'C:\PowerShellGUI\modules' -Patterns @('P002') -BackupOriginal -Confirm:$false
$res | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $out 'p002-modules.json') -Encoding UTF8
"FilesScanned=$($res.FilesScanned)  FilesChanged=$($res.FilesChanged)  TotalFixes=$($res.TotalFixes)"
$res.Details | Select-Object -First 10 File, Total | Format-Table -AutoSize

