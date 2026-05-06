# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-AutoRemediate.psm1 -Force -DisableNameChecking
$ConfirmPreference = 'None'
try {
    $res = Invoke-AutoRemediate -Path 'C:\PowerShellGUI\modules\PwShGUI-AutoRemediate.psm1' -Patterns @('P002') -Verbose
    "OK single file"
    $res | ConvertTo-Json -Depth 4
} catch {
    "ERR: $($_.Exception.GetType().FullName)"
    "Msg: $($_.Exception.Message)"
    $_.ScriptStackTrace
    if ($_.Exception.InnerException) { "Inner: " + $_.Exception.InnerException.Message }
}

