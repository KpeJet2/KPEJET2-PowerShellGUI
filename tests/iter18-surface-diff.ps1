# VersionTag: 2605.B5.V46.0
# iter18: surface-diff vs baseline (re-run after cycle 1)
$baseline = Get-Content 'C:\PowerShellGUI\reports\iter5\modules-surface-baseline.json' -Raw | ConvertFrom-Json
$current = @()
$root = 'C:\PowerShellGUI\modules'
try { Import-Module -Name (Join-Path $root 'PwShGUICore.psm1') -Force -DisableNameChecking -ErrorAction Stop } catch { Write-Warning "iter18: PwShGUICore import failed: $_" }
foreach ($psm in Get-ChildItem -Path $root -Filter '*.psm1' -File) {
    $name = [IO.Path]::GetFileNameWithoutExtension($psm.Name)
    try { Import-Module $psm.FullName -Force -DisableNameChecking -ErrorAction Stop } catch { continue }
    $cmds = Get-Command -Module $name -ErrorAction SilentlyContinue
    foreach ($c in $cmds) {
        $params = @($c.Parameters.Keys | Where-Object { $_ -notmatch '^(Verbose|Debug|ErrorAction|WarningAction|InformationAction|ErrorVariable|WarningVariable|InformationVariable|OutVariable|OutBuffer|PipelineVariable|WhatIf|Confirm|ProgressAction)$' } | Sort-Object)
        $current += [PSCustomObject]@{
            Module = $name; Function = $c.Name; CommandType = "$($c.CommandType)"; Parameters = $params
        }
    }
}
$baseKeys = @{}; foreach ($b in $baseline) { $baseKeys["$($b.Module)::$($b.Function)"] = $b }
$curKeys  = @{}; foreach ($c in $current)  { $curKeys["$($c.Module)::$($c.Function)"]  = $c }

$added = @($curKeys.Keys | Where-Object { -not $baseKeys.ContainsKey($_) })
$removed = @($baseKeys.Keys | Where-Object { -not $curKeys.ContainsKey($_) })
$changed = @()
foreach ($k in $curKeys.Keys) {
    if ($baseKeys.ContainsKey($k)) {
        $b = @($baseKeys[$k].Parameters); $c = @($curKeys[$k].Parameters)
        if (($b -join ',') -ne ($c -join ',')) { $changed += "$k :: was=[$($b -join ',')] now=[$($c -join ',')]" }
    }
}
Write-Host ("Added: " + $added.Count + " | Removed: " + $removed.Count + " | Changed: " + $changed.Count)
$added | ForEach-Object { Write-Host ("  +" + $_) }
$removed | ForEach-Object { Write-Host ("  -" + $_) }
$changed | ForEach-Object { Write-Host ("  ~" + $_) }

