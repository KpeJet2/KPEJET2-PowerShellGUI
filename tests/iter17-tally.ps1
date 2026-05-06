# VersionTag: 2605.B2.V31.7
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -ExcludeRule PSAvoidUsingWriteHost
Write-Host ("PSSA total post-iter11-16: " + @($findings).Count)
$findings | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 10 Count, Name | Format-Table -AutoSize
$findings | ConvertTo-Json -Depth 5 | Out-File C:\PowerShellGUI\reports\iter17\pssa-post-cycle.json -Encoding UTF8

