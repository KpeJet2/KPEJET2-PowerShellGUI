# VersionTag: 2605.B2.V31.7
$c = Get-Content C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml -Raw -Encoding UTF8
$rx = '(?is)<script[^>]*>(.*?)</script>'
$ms = [regex]::Matches($c, $rx)
$p32fail = $false
foreach ($m in $ms) {
    $body = $m.Groups[1].Value
    if ($body -match '(?i)</(script|style)') { Write-Host "FAIL P032 in script body"; $p32fail = $true }
}
if (-not $p32fail) { Write-Host 'P032-OK' }
$varRx = '(?m)^\s*var\s+(\w+)\s*='
$names = [regex]::Matches($c, $varRx) | ForEach-Object { $_.Groups[1].Value }
$dup = $names | Group-Object | Where-Object Count -gt 1
if ($dup) { Write-Host "P033 DUP: $($dup.Name -join ',')" } else { Write-Host 'P033-OK' }
Write-Host "Lines: $((Get-Content C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml).Count)"

