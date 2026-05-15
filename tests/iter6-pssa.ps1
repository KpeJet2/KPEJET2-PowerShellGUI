# VersionTag: 2605.B5.V46.0
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-PSScriptAnalyzerScan.psm1 -Force -DisableNameChecking
$out = 'C:\PowerShellGUI\reports\iter6'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$res = Invoke-PSScriptAnalyzerScan -Path 'C:\PowerShellGUI\modules' -Severity Warning -OutputDir $out -ExcludeRule @('PSAvoidUsingWriteHost','PSUseShouldProcessForStateChangingFunctions')
if ($res.Available -eq $false) {
    $res.Message
    return
}
"Findings (total): " + ($res.Findings.Count)
$res.Findings | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 15 Count, Name | Format-Table -AutoSize
$res | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $out 'pssa-modules.json') -Encoding UTF8

