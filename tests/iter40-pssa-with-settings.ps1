# VersionTag: 2605.B5.V46.0
$settings = 'C:\PowerShellGUI\config\PSScriptAnalyzerSettings.psd1'
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -Settings $settings
Write-Host "Total: $(@($f).Count)"
$f | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 12 | Format-Table -AutoSize

