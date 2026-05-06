# VersionTag: 2605.B2.V31.7
$j = Get-Content 'C:\PowerShellGUI\reports\iter6\pssa-modules.json' -Raw | ConvertFrom-Json
$j.Findings | Group-Object RuleName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize

