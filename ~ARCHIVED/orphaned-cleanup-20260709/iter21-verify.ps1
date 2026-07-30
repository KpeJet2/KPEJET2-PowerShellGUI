# VersionTag: 2606.B5.V51.4
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseDeclaredVarsMoreThanAssignments
Write-Host ("Remaining PSUseDeclaredVarsMoreThanAssignments: " + @($f).Count)
$f | Format-Table ScriptName, Line, Message -AutoSize



