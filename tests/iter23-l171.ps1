# VersionTag: 2605.B2.V31.7
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$lines = [IO.File]::ReadAllLines($path)
foreach ($n in @(171, 174)) {
    $l = $lines[$n-1]
    Write-Host ("--- L${n} (len=$($l.Length)) ---")
    for ($i=0; $i -lt $l.Length; $i++) {
        $c = $l[$i]; $code = [int]$c
        if ($code -gt 127 -or $c -eq '"') { Write-Host ("  [$i] '$c' U+{0:X4}" -f $code) }
    }
}

