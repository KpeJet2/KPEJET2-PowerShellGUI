# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
$pssa = Get-Content 'C:\PowerShellGUI\reports\iter6\pssa-modules.json' -Raw | ConvertFrom-Json
$autoVar = @($pssa.Findings | Where-Object { $_.RuleName -eq 'PSAvoidAssignmentToAutomaticVariable' })
"P034 candidates: $($autoVar.Count)"
$autoVar | ForEach-Object { "  $($_.File | Split-Path -Leaf):$($_.Line)  $($_.Message)" }

$out = 'C:\PowerShellGUI\sin_registry'
$ts = (Get-Date).ToString('yyyyMMddHHmmss')
$count = 0
foreach ($f in $autoVar) {
    $count++
    $fileShort = Split-Path -Leaf $f.File
    $hash = [Convert]::ToString(($f.File + ':' + $f.Line).GetHashCode(), 16).TrimStart('-').PadLeft(8,'0').Substring(0,8)
    $name = "SIN-$ts-P034-$hash.json"
    $path = Join-Path $out $name
    if (Test-Path $path) { continue }
    $obj = [ordered]@{
        sin_id      = "SIN-$ts-P034-$hash"
        pattern_id  = 'P034'
        title       = 'PSAvoidAssignmentToAutomaticVariables'
        file        = $f.File
        line        = $f.Line
        column      = $f.Column
        severity    = 'MEDIUM'
        category    = 'STRICTMODE'
        status      = 'OPEN'
        registered  = (Get-Date).ToString('yyyy-MM-dd')
        message     = $f.Message
        source_tool = 'PSScriptAnalyzer (iter6)'
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    "  + $name"
}
"Created $count instance records"

