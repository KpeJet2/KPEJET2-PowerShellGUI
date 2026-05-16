# VersionTag: 2605.B5.V46.0
$j = Get-Content 'C:\PowerShellGUI\reports\iter6\pssa-modules.json' -Raw | ConvertFrom-Json
$j.Findings | Group-Object RuleName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize

