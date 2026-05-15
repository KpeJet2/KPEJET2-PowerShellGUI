# VersionTag: 2605.B5.V46.0
Import-Module C:\PowerShellGUI\modules\PwShGUI-LegacyEncoding.psm1 -Force -DisableNameChecking
$tgts = @('C:\PowerShellGUI\scripts','C:\PowerShellGUI\sovereign-kernel','C:\PowerShellGUI\agents','C:\PowerShellGUI\UPM')
$start = Get-Date
$results = foreach ($t in $tgts) {
    if (-not (Test-Path $t)) { continue }
    Get-ChildItem -Path $t -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName |
        Convert-LegacyEncoding -Confirm:$false
}
$elapsed = (Get-Date) - $start
$dbl = @($results | Where-Object { $_.FixedDoubleEncoded })
"Repaired total: $($results.Count) in $([math]::Round($elapsed.TotalSeconds,1))s"
"P023 (double-encoded) repaired: $($dbl.Count)"
$dbl | Select-Object Path

