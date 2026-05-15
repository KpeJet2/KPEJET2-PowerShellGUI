# VersionTag: 2605.B5.V46.0
$b = Get-Content 'C:\PowerShellGUI\reports\iter5\modules-surface-baseline.json' -Raw | ConvertFrom-Json
Write-Host ("Baseline count: " + @($b).Count)
$b[0] | Format-List

