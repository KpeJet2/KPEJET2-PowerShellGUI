# VersionTag: 2605.B2.V31.7
Import-Module C:\PowerShellGUI\modules\PwShGUI-LegacyEncoding.psm1 -Force -DisableNameChecking
$tgts = @('C:\PowerShellGUI\scripts','C:\PowerShellGUI\sovereign-kernel','C:\PowerShellGUI\agents','C:\PowerShellGUI\UPM')
$all = foreach ($t in $tgts) {
    if (-not (Test-Path $t)) { continue }
    Get-ChildItem -Path $t -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue |
        ForEach-Object { Test-FileEncoding -Path $_.FullName }
}
$bad = @($all | Where-Object { $_.NeedsFix })
$dbl = @($bad | Where-Object { $_.DoubleEncoded })
"Total candidates: $($bad.Count)"
"Of which double-encoded (P023, urgent): $($dbl.Count)"
"Plain P006 (just need BOM): $($bad.Count - $dbl.Count)"
$dbl | Select-Object -First 10 Path

