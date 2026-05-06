# VersionTag: 2605.B2.V31.7
Import-Module C:\PowerShellGUI\modules\PwShGUI-LegacyEncoding.psm1 -Force -DisableNameChecking
$bad = @(Get-ChildItem C:\PowerShellGUI\modules -Filter *.psm1 | ForEach-Object { Test-FileEncoding -Path $_.FullName } | Where-Object { $_.NeedsFix })
"P006 violations remaining: $($bad.Count)"

