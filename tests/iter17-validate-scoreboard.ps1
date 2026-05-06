# VersionTag: 2605.B2.V31.7
[xml]$x = Get-Content 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml' -Raw
$tables = $x.SelectNodes('//*[local-name()="table"]')
Write-Host ("XML OK; tables=" + @($tables).Count)

