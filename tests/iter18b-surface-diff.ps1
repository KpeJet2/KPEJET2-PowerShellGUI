# VersionTag: 2605.B5.V46.0
# iter18b: surface-diff against hash-shaped baseline
$baseRaw = Get-Content 'C:\PowerShellGUI\reports\iter5\modules-surface-baseline.json' -Raw | ConvertFrom-Json
$baseKeys = @{}
foreach ($p in $baseRaw.PSObject.Properties) { $baseKeys[$p.Name] = $p.Value }

$root = 'C:\PowerShellGUI\modules'
foreach ($psm in Get-ChildItem -Path $root -Filter '*.psm1' -File) {
    try { Import-Module $psm.FullName -Force -DisableNameChecking -ErrorAction Stop } catch { continue }
}
$curKeys = @{}
foreach ($psm in Get-ChildItem -Path $root -Filter '*.psm1' -File) {
    $name = [IO.Path]::GetFileNameWithoutExtension($psm.Name)
    $cmds = Get-Command -Module $name -ErrorAction SilentlyContinue
    foreach ($c in $cmds) {
        $params = @($c.Parameters.Keys | Where-Object { $_ -notmatch '^(Verbose|Debug|ErrorAction|WarningAction|InformationAction|ErrorVariable|WarningVariable|InformationVariable|OutVariable|OutBuffer|PipelineVariable|WhatIf|Confirm|ProgressAction)$' } | Sort-Object)
        $curKeys["$name`::$($c.Name)"] = [PSCustomObject]@{ Module=$name; Function=$c.Name; Parameters=$params }
    }
}
$added = @($curKeys.Keys | Where-Object { -not $baseKeys.ContainsKey($_) })
$removed = @($baseKeys.Keys | Where-Object { -not $curKeys.ContainsKey($_) })
$changed = @()
foreach ($k in $curKeys.Keys) {
    if ($baseKeys.ContainsKey($k)) {
        $b = @($baseKeys[$k].Parameters | ForEach-Object { "$_" }); $c = @($curKeys[$k].Parameters)
        if (($b -join ',') -ne ($c -join ',')) { $changed += "$k :: was=[$($b -join ',')] now=[$($c -join ',')]" }
    }
}
Write-Host ("Baseline: " + $baseKeys.Count + " | Current: " + $curKeys.Count)
Write-Host ("Added: " + $added.Count + " | Removed: " + $removed.Count + " | Changed: " + $changed.Count)
if ($added.Count -le 25) { $added | ForEach-Object { Write-Host ("  +" + $_) } }
$removed | ForEach-Object { Write-Host ("  -" + $_) }
$changed | ForEach-Object { Write-Host ("  ~" + $_) }

