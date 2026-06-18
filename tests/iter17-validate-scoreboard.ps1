# VersionTag: 2605.B5.V51.1
[xml]$x = Get-Content 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml' -Raw
$tables = $x.SelectNodes('//*[local-name()="table"]')
Write-Host ("XML OK; tables=" + @($tables).Count)


