# VersionTag: 2605.B5.V46.0
# iter14 verify
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\AVPN-Tracker.psm1 -Force -DisableNameChecking
Import-Module C:\PowerShellGUI\modules\PwShGUI-Theme.psm1 -Force -DisableNameChecking
Import-Module C:\PowerShellGUI\modules\PwShGUICore.psm1 -Force -DisableNameChecking
Write-Host 'IMPORTS OK'
$findings = Invoke-ScriptAnalyzer -Path C:\PowerShellGUI\modules -Recurse -IncludeRule PSAvoidAssignmentToAutomaticVariable
Write-Host ("P034 hits in modules/: " + @($findings).Count)
$findings | Format-Table ScriptName,Line,Message -AutoSize

