# VersionTag: 2606.B5.V51.4
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseSingularNouns
Write-Host "Total: $(@($f).Count)"
$f | Select-Object ScriptName, Line, Message | Format-Table -AutoSize -Wrap



