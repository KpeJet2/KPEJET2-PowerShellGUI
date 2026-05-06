# VersionTag: 2605.B2.V31.7
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingEmptyCatchBlock
Write-Host ("Total: " + @($f).Count)
$f | Format-Table ScriptName, Line -AutoSize

