# VersionTag: 2606.B5.V51.4
$j = Get-Content 'C:\PowerShellGUI\reports\iter6\pssa-modules.json' -Raw | ConvertFrom-Json
$j.Findings | Group-Object RuleName | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize



