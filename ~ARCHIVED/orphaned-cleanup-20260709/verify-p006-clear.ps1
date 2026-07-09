# VersionTag: 2606.B5.V51.4
Import-Module C:\PowerShellGUI\modules\PwShGUI-LegacyEncoding.psm1 -Force -DisableNameChecking
$bad = @(Get-ChildItem C:\PowerShellGUI\modules -Filter *.psm1 | ForEach-Object { Test-FileEncoding -Path $_.FullName } | Where-Object { $_.NeedsFix })
"P006 violations remaining: $($bad.Count)"



