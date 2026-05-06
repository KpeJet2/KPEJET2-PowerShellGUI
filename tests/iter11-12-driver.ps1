# Iter11: Surface diff vs iter5 JSON baseline + Iter12: SIN drift scan
# VersionTag: 2605.B2.V31.7
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI'
$outDir = Join-Path $root 'reports\iter11'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Import-Module (Join-Path $root 'modules\PwShGUI-BreakingChange.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PwShGUI-SinDriftScan.psm1') -Force -DisableNameChecking

# --- Iter11: load baseline JSON, compute current, diff keys + parameter sets ---
$baselinePath = Join-Path $root 'reports\iter5\modules-surface-baseline.json'
$baseRaw = Get-Content -Raw -Encoding UTF8 -Path $baselinePath | ConvertFrom-Json
$baseKeys = @($baseRaw.PSObject.Properties.Name)
Write-Host "Baseline functions: $($baseKeys.Count)"

$current = Get-ModuleSurface -Path (Join-Path $root 'modules')
$currKeys = @($current.Keys)
Write-Host "Current functions: $($currKeys.Count)"

$removed = New-Object System.Collections.Generic.List[string]
foreach ($k in $baseKeys) { if (-not $current.ContainsKey($k)) { $removed.Add($k) | Out-Null } }
$added = New-Object System.Collections.Generic.List[string]
foreach ($k in $currKeys) { if ($baseKeys -notcontains $k) { $added.Add($k) | Out-Null } }
$changed = New-Object System.Collections.Generic.List[object]
foreach ($k in @($baseKeys | Where-Object { $current.ContainsKey($_) })) {
    $b = $baseRaw.$k
    $c = $current[$k]
    $bSig = @(@($b.Parameters) | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Name):$($_.Type):$($_.Mandatory)" } | Sort-Object)
    $cSig = @(@($c.Parameters) | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Name):$($_.Type):$($_.Mandatory)" } | Sort-Object)
    if ($bSig.Count -eq 0 -and $cSig.Count -eq 0) { continue }
    $diff = @(Compare-Object -ReferenceObject ($bSig + @('__SENTINEL__')) -DifferenceObject ($cSig + @('__SENTINEL__')) -ErrorAction SilentlyContinue |
              Where-Object { $_.InputObject -ne '__SENTINEL__' })
    if ($diff.Count -gt 0) {
        $changed.Add([PSCustomObject]@{
            Function = $k
            Removed  = @($diff | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
            Added    = @($diff | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })
        }) | Out-Null
    }
}
$rmCount = $removed.Count
$addCount = $added.Count
$chCount = $changed.Count
$verdict = if ($rmCount -gt 0 -or $chCount -gt 0) { 'BREAKING' }
           elseif ($addCount -gt 0) { 'ADDITIVE' } else { 'NONE' }

$report = [ordered]@{
    generated     = (Get-Date).ToUniversalTime().ToString('o')
    baseline      = $baselinePath
    verdict       = $verdict
    removed_count = $rmCount
    added_count   = $addCount
    changed_count = $chCount
    removed       = @($removed.ToArray())
    added         = @($added.ToArray())
    changed       = @($changed.ToArray())
}
$diffPath = Join-Path $outDir 'surface-diff.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $diffPath -Encoding UTF8
Write-Host ("[ITER11] verdict={0} removed={1} added={2} changed={3} -> {4}" -f $verdict, $rmCount, $addCount, $chCount, $diffPath)

# --- Iter12: SIN drift scan against current modules tree ---
$driftDir = Join-Path $root 'reports\iter12'
if (-not (Test-Path $driftDir)) { New-Item -ItemType Directory -Path $driftDir -Force | Out-Null }
$driftPath = Join-Path $driftDir 'drift.json'
$resolved = @(Get-ResolvedSinPatterns -RegistryPath (Join-Path $root 'sin_registry'))
Write-Host "RESOLVED patterns to drift-scan: $($resolved.Count)"
$drift = @(Invoke-SinDriftScan -Root (Join-Path $root 'modules') -OutputPath $driftPath)
Write-Host ("[ITER12] drift findings: {0} -> {1}" -f @($drift).Count, $driftPath)

