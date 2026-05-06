# VersionTag: 2605.B2.V31.7
$f = 'C:\PowerShellGUI\sin_registry\SIN-PATTERN-036-DICTKEYS-COUNT-IN-LITERAL_20260430.json'
$nf = 'C:\PowerShellGUI\sin_registry\SIN-PATTERN-037-DICTKEYS-COUNT-IN-LITERAL_20260430.json'
$c = Get-Content $f -Raw -Encoding UTF8
$c = $c -replace 'SIN-PATTERN-036-DICTKEYS','SIN-PATTERN-037-DICTKEYS'
[System.IO.File]::WriteAllText($nf, $c, (New-Object System.Text.UTF8Encoding($true)))
Remove-Item $f
Get-ChildItem C:\PowerShellGUI\sin_registry\SIN-PATTERN-03[4-7]*.json | Select-Object Name

