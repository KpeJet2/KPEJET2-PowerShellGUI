# VersionTag: 2605.B5.V46.0
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseOutputTypeCorrectly
Write-Host "Total: $(@($f).Count)"
$f | Select-Object -First 10 | Format-Table ScriptName, Line, Message -AutoSize -Wrap
$f | Group-Object ScriptName | Sort-Object Count -Descending | Select-Object -First 10 | Format-Table -AutoSize

