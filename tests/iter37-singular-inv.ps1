# VersionTag: 2605.B5.V46.0
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseSingularNouns
Write-Host "Total: $(@($f).Count)"
$f | Select-Object ScriptName, Line, Message | Format-Table -AutoSize -Wrap

