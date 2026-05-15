# VersionTag: 2605.B5.V46.0
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$lines = [IO.File]::ReadAllLines($path)
foreach ($n in @(131,132,133,134,135)) {
    $l = $lines[$n-1]
    Write-Host ("--- L${n} (len=$($l.Length)) ---")
    for ($i=0; $i -lt $l.Length; $i++) {
        $c = $l[$i]; $code = [int]$c
        if ($code -gt 127) { Write-Host ("  [$i] '$c' U+{0:X4}" -f $code) }
    }
}

