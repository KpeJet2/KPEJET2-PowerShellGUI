# VersionTag: 2605.B5.V46.0
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingEmptyCatchBlock
Write-Host ("Total: " + @($f).Count)
$f | Format-Table ScriptName, Line -AutoSize

