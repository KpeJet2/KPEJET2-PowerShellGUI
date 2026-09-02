# VersionTag: 2606.B5.V51.4
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidUsingEmptyCatchBlock
Write-Host ("Total: " + @($f).Count)
$f | Format-Table ScriptName, Line -AutoSize



