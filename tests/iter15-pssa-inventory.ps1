# VersionTag: 2605.B2.V31.7
# Iter15: PSSA inventory by rule
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -ExcludeRule PSAvoidUsingWriteHost
$grouped = $findings | Group-Object RuleName | Sort-Object Count -Descending
$grouped | Select-Object Count, Name | Format-Table -AutoSize
Write-Host ("Total: " + $findings.Count)

