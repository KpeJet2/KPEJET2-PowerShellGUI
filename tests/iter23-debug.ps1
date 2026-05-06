# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$b = [IO.File]::ReadAllBytes($path)
$hasBom = ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
Write-Host ("Bytes 0-2: 0x" + ('{0:X2}' -f $b[0]) + ' 0x' + ('{0:X2}' -f $b[1]) + ' 0x' + ('{0:X2}' -f $b[2]) + " BOM=$hasBom Size=$($b.Length)")
# Show line 446
$lines = [IO.File]::ReadAllLines($path)
Write-Host "Line 446: $($lines[445])"
Write-Host "Line 447: $($lines[446])"

