# VersionTag: 2606.B5.V51.4
$path = 'C:\PowerShellGUI\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
$lines = [IO.File]::ReadAllLines($path)
foreach ($n in @(171, 174)) {
    $l = $lines[$n-1]
    Write-Host ("--- L${n} (len=$($l.Length)) ---")
    for ($i=0; $i -lt $l.Length; $i++) {
        $c = $l[$i]; $code = [int]$c  # SIN-EXEMPT:P027 -- index access, context-verified safe
        if ($code -gt 127 -or $c -eq '"') { Write-Host ("  [$i] '$c' U+{0:X4}" -f $code) }
    }
}



