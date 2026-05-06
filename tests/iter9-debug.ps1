# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
Import-Module C:\PowerShellGUI\modules\PwShGUI-SinHeatmap.psm1 -Force -DisableNameChecking
$f = 'C:\PowerShellGUI\reports\iter9\pssa-findings.json'
$s = 'C:\PowerShellGUI\reports\iter9\heatmap.svg'
"FindingsPath type: $($f.GetType().FullName)"
"SvgPath type: $($s.GetType().FullName)"
$top = 20
"Top type: $($top.GetType().FullName)"
try {
    $heat = Get-SinHeatmap -FindingsPath $f -SvgPath $s -Top $top -Verbose
    "OK"
    $heat | Select-Object -First 5 File, SinCount, LinesOfCode, DensityPer1k | Format-Table -AutoSize
} catch {
    "ERR: $($_.Exception.Message)"
    $_.ScriptStackTrace
}

