# VersionTag: 2605.B2.V31.7
[xml]$x = Get-Content 'C:\PowerShellGUI\~REPORTS\SIN-Scoreboard.xhtml' -Raw -Encoding UTF8
"XML parses OK. Root: $($x.DocumentElement.LocalName)"
$tables = $x.SelectNodes('//*[local-name()="table"]')
"Tables: $($tables.Count)"

