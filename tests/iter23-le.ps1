# VersionTag: 2605.B5.V46.0
$b = [IO.File]::ReadAllBytes('C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1')
$crlf=0; $lfonly=0
for ($i=0; $i -lt $b.Length-1; $i++) {
    if ($b[$i] -eq 0x0D -and $b[$i+1] -eq 0x0A) { $crlf++; $i++ }
    elseif ($b[$i] -eq 0x0A) { $lfonly++ }
}
Write-Host ("CRLF=$crlf LF-only=$lfonly Size=$($b.Length)")

