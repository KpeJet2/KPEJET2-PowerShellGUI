# VersionTag: 2605.B5.V46.0
$mods = 'PwShGUI-DependencyMap','PwShGUI-CoverageReport','PwShGUI-AutoRemediate','PwShGUI-SinFromScan','PwShGUI-BreakingChange','PwShGUI-PSScriptAnalyzerScan'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
foreach ($m in $mods) {
    $p = Join-Path 'C:\PowerShellGUI\modules' "$m.psm1"
    $c = [System.IO.File]::ReadAllText($p)
    $c = $c -replace [char]0x2014, '--'
    $c = $c -replace [char]0x2013, '-'
    $c = $c -replace [char]0x2026, '...'
    $c = $c -replace [char]0x2018, "'"
    $c = $c -replace [char]0x2019, "'"
    $c = $c -replace [char]0x201C, '"'
    $c = $c -replace [char]0x201D, '"'
    [System.IO.File]::WriteAllText($p, $c, $utf8Bom)
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $bom = if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 'BOM-OK' } else { 'NO-BOM' }
    "$m  $bom"
}

