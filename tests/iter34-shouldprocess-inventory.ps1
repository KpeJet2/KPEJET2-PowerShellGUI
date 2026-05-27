# VersionTag: 2605.B5.V46.0
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseShouldProcessForStateChangingFunctions
Write-Host ("Total: " + @($f).Count)
$f | Group-Object ScriptName | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize
$f | Select-Object ScriptName, Line, @{n='Func';e={$_.Message -replace '.*''([^'']+)''.*','$1'}} | Format-Table -AutoSize

