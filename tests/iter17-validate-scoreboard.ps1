# VersionTag: 2606.B5.V51.4
[xml]$x = Get-Content 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml' -Raw
$tables = $x.SelectNodes('//*[local-name()="table"]')
Write-Host ("XML OK; tables=" + @($tables).Count)



