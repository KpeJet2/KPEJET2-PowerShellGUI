# VersionTag: 2605.B5.V46.0
# iter16 verify
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-VersionManager.psm1 -Force -DisableNameChecking
Import-Module C:\PowerShellGUI\modules\PwShGUICore.psm1 -Force -DisableNameChecking
Import-Module C:\PowerShellGUI\modules\CronAiAthon-Scheduler.psm1 -Force -DisableNameChecking
Write-Host 'IMPORTS OK'
# Confirm alias works
$r1 = Parse-VersionTag -Tag '2604.B3.V37.0'
Write-Host ("Parse-VersionTag (alias) -> full=" + $r1.full)
$r2 = ConvertFrom-VersionTag -Tag '2604.B3.V37.0'
Write-Host ("ConvertFrom-VersionTag -> full=" + $r2.full)
# Confirm renamed function
if (Get-Command Test-ConfigPaths -ErrorAction SilentlyContinue) { Write-Host 'Test-ConfigPaths function exists' }
# Confirm BOMs
foreach ($f in 'C:\PowerShellGUI\modules\CronAiAthon-Scheduler.psm1','C:\PowerShellGUI\modules\UserProfileManager.psd1') {
    $b = [System.IO.File]::ReadAllBytes($f)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    Write-Host "$f BOM=$bom"
}
# Re-run targeted PSSA
$rules = @('PSPossibleIncorrectComparisonWithNull','PSUseApprovedVerbs','PSUseBOMForUnicodeEncodedFile')
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule $rules
Write-Host ("Remaining (filtered rules): " + @($findings).Count)
$findings | Format-Table RuleName,@{N='File';E={Split-Path $_.ScriptPath -Leaf}},Line -AutoSize

