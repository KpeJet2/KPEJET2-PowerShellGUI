# VersionTag: 2605.B5.V46.0
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$lines = [IO.File]::ReadAllLines($path)
$line = $lines[445]   # 0-indexed for line 446  # SIN-EXEMPT:P027 -- index access, context-verified safe
Write-Host "Length: $($line.Length)"
Write-Host "Last 10 chars (codes):"
$start = [Math]::Max(0, $line.Length - 12)
for ($i = $start; $i -lt $line.Length; $i++) {
    $c = $line[$i]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    Write-Host ("  [{0}] '{1}' U+{2:X4}" -f $i, $c, [int]$c)
}

