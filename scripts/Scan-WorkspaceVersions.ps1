# VersionTag: 2605.B5.V46.0
$ws = 'C:\PowerShellGUI'
$exts = @('.ps1','.psm1','.psd1','.bat','.cmd','.json','.yaml','.yml','.md','.xhtml','.html','.js','.ts','.css','.py','.txt','.xml','.csv')
# Permanent exclusions: vendored deps, VCS internals, virtualenvs, runtime artefacts,
# auto-snapshots (.history), checkpoint blobs, generated reports, downloads, gallery assets.
$exclude = @('node_modules','.git','.venv','.history','logs','checkpoints','temp','~DOWNLOADS','reports','Report','~REPORTS','gallery')
$rx = [regex]'VersionTag:\s*([0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?)'
$out = New-Object System.Collections.Generic.List[object]
Get-ChildItem -LiteralPath $ws -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($ws.Length).TrimStart('\').Replace('\','/')
    foreach ($x in $exclude) { if ($rel.StartsWith("$x/") -or $rel -eq $x) { return } }
    if ($exts -notcontains $_.Extension.ToLower()) { return }
    $tag = $null
    try {
        $head = Get-Content -LiteralPath $_.FullName -TotalCount 6 -ErrorAction Stop
        foreach ($line in $head) {
            $m = $rx.Match($line)
            if ($m.Success) { $tag = $m.Groups[1].Value; break }
        }
    } catch {}
    $out.Add([pscustomobject]@{ Path=$rel; Version=$tag; SizeKB=[math]::Round($_.Length/1KB,1) })
}
$out | Sort-Object Path | Export-Csv -LiteralPath 'C:\PowerShellGUI\temp\workspace-versions.csv' -NoTypeInformation -Encoding UTF8
$total = $out.Count
$tagged = ($out | Where-Object Version).Count
$grp = $out | Where-Object Version | Group-Object Version | Sort-Object Count -Descending
Write-Output ("TOTAL=$total TAGGED=$tagged UNTAGGED=$($total-$tagged)")
$grp | ForEach-Object { "  {0,-25} {1,5} files" -f $_.Name, $_.Count }
