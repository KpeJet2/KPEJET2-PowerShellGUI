# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$lines = [IO.File]::ReadAllLines($path)
# Count quotes in each line up to find the unbalanced one
$totalDQ = 0
for ($i=0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    # naive count, skip backtick-escaped
    $c = ($line.ToCharArray() | Where-Object { $_ -eq '"' }).Count
    if ($c -gt 0) { $totalDQ += $c }
    if ($i -ge 130 -and $i -le 175) {
        Write-Host ("L{0,3} dq={1,2} : {2}" -f ($i+1), $c, $line)
    }
}
Write-Host "Total DQ count: $totalDQ"

