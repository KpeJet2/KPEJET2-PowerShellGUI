# VersionTag: 2605.B2.V31.7
$f = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSReviewUnusedParameter
Write-Host ("Remaining PSReviewUnusedParameter: " + @($f).Count)
$f | Format-Table ScriptName, Line, Message -AutoSize
# Smoke
$mods = Get-ChildItem 'C:\PowerShellGUI\modules' -Filter '*.psm1' -File
$ok=0; $fail=0
foreach ($m in $mods) {
    try { Import-Module $m.FullName -Force -DisableNameChecking -ErrorAction Stop; $ok++ } catch { $fail++; Write-Host ("FAIL " + $m.Name + " :: " + $_.Exception.Message) }
}
Write-Host ("Imports OK=" + $ok + " FAIL=" + $fail)

