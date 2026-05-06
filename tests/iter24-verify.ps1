# VersionTag: 2605.B2.V31.7
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSUseToExportFieldsInManifest
Write-Host ("Remaining: " + @($f).Count)
$f | Format-Table ScriptName, Line, Message -AutoSize
# Test imports
$mods = Get-ChildItem 'C:\PowerShellGUI\modules' -Filter '*.psd1' -File | Where-Object { $_.Name -notlike '_TEMPLATE*' }
$ok=0; $fail=0
foreach ($m in $mods) {
    try { Import-Module $m.FullName -Force -DisableNameChecking -ErrorAction Stop; $ok++ } catch { $fail++; Write-Host ("FAIL " + $m.Name + " :: " + $_.Exception.Message.Split("`n")[0]) }
}
Write-Host ("Manifest imports OK=$ok FAIL=$fail")

