# VersionTag: 2607.B6.V53.0
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ws = Split-Path -Parent $scriptDir
$exts = @('.ps1','.psm1','.psd1','.bat','.cmd','.json','.yaml','.yml','.md','.xhtml','.html','.js','.ts','.css','.py','.txt','.xml','.csv')
# Permanent exclusions: vendored deps, VCS internals, virtualenvs, runtime artefacts,
# auto-snapshots (.history), checkpoint blobs, generated reports, downloads, gallery assets.
$exclude = @('node_modules','.git','.venv','.history','logs','checkpoints','temp','~DOWNLOADS','reports','Report','~REPORTS','gallery')
$rx = [regex]'VersionTag:\s*([0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?)'

$out = New-Object System.Collections.Generic.List[object]
$scanStarted = Get-Date
Get-ChildItem -LiteralPath $ws -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($ws.Length).TrimStart('\').Replace('\','/')
    foreach ($x in $exclude) {
        if ($rel.StartsWith("$x/") -or $rel -eq $x) { return }
    }
    if ($rel -match '^todo/(Bug|Bugs2FIX)-.*\.json$') { return }
    $ext = $_.Extension.ToLowerInvariant()
    if ($exts -notcontains $ext) { return }

    $tag = $null
    try {
        $head = Get-Content -LiteralPath $_.FullName -TotalCount 6 -Encoding UTF8 -ErrorAction Stop
        foreach ($line in $head) {
            $m = $rx.Match($line)
            if ($m.Success) { $tag = $m.Groups[1].Value.ToUpperInvariant(); break }
        }
    } catch { <# Intentional: non-fatal — unreadable files silently skipped during version scan #> }

    $out.Add([pscustomobject]@{
        Path = $rel
        Version = $tag
        Extension = $ext
        SizeKB = [math]::Round($_.Length / 1KB, 1)
        LastWriteTime = $_.LastWriteTime
        LastWriteTimeUtc = $_.LastWriteTimeUtc
        AgeDays = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays, 1)
    })
}
$scanFinished = Get-Date

$tempDir = Join-Path $ws 'temp'
if (-not (Test-Path -LiteralPath $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

$csvPath = Join-Path $tempDir 'workspace-versions.csv'
$summaryPath = Join-Path $tempDir 'workspace-versions-summary.csv'
$out | Sort-Object Path | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$total = @($out).Count
$tagged = @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Version) }).Count
$untagged = $total - $tagged
$totalSizeMb = [math]::Round((@($out | Measure-Object -Property SizeKB -Sum).Sum) / 1024, 2)

$scanWindowSec = [math]::Round(($scanFinished - $scanStarted).TotalSeconds, 2)
$oldest = $null
$newest = $null
if ($total -gt 0) {
    $oldest = ($out | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
    $newest = ($out | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
}

Write-Output 'EXCLUDED_PATHS:'
foreach ($x in $exclude) {
    Write-Output ("  - {0}" -f $x)
}
Write-Output '  - todo/(Bug|Bugs2FIX)-*.json'
Write-Output ''

Write-Output 'VERSION_SCAN_SUMMARY:'
Write-Output ("  Workspace        : {0}" -f $ws)
Write-Output ("  ScanStarted      : {0}" -f ($scanStarted.ToString('yyyy-MM-dd HH:mm:ss')))
Write-Output ("  ScanFinished     : {0}" -f ($scanFinished.ToString('yyyy-MM-dd HH:mm:ss')))
Write-Output ("  DurationSec      : {0}" -f $scanWindowSec)
Write-Output ("  TotalFiles       : {0}" -f $total)
Write-Output ("  TaggedFiles      : {0}" -f $tagged)
Write-Output ("  UntaggedFiles    : {0}" -f $untagged)
Write-Output ("  TotalSizeMB      : {0}" -f $totalSizeMb)
if ($null -ne $oldest -and $null -ne $newest) {
    Write-Output ("  ModifiedRange    : {0} -> {1}" -f ($oldest.ToString('yyyy-MM-dd HH:mm:ss')), ($newest.ToString('yyyy-MM-dd HH:mm:ss')))
}
Write-Output ("  CsvPath          : {0}" -f $csvPath)
Write-Output ''

$groupSummary = @(
    $out |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Version) } |
    Group-Object Version |
    Sort-Object Count -Descending |
    ForEach-Object {
        $items = @($_.Group)
        $minWrite = ($items | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
        $maxWrite = ($items | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        $sumKb = [double](@($items | Measure-Object -Property SizeKB -Sum).Sum)
        $avgKb = if (@($items).Count -gt 0) { [math]::Round($sumKb / @($items).Count, 2) } else { 0 }
        $coverageDays = [math]::Round(($maxWrite - $minWrite).TotalDays, 1)
        [pscustomobject]@{
            Version = $_.Name
            FileCount = @($items).Count
            TotalSizeKB = [math]::Round($sumKb, 2)
            AvgSizeKB = $avgKb
            MinModified = $minWrite.ToString('yyyy-MM-dd HH:mm:ss')
            MaxModified = $maxWrite.ToString('yyyy-MM-dd HH:mm:ss')
            ModifiedRangeDays = $coverageDays
        }
    }
)

if (@($groupSummary).Count -gt 0) {
    $groupSummary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    Write-Output 'VERSION_SETS:'
    foreach ($g in $groupSummary) {
        Write-Output ("  {0,-20} files={1,5} sizeKB={2,10} avgKB={3,8} modified={4} -> {5} spanDays={6}" -f $g.Version, $g.FileCount, $g.TotalSizeKB, $g.AvgSizeKB, $g.MinModified, $g.MaxModified, $g.ModifiedRangeDays)
    }
    Write-Output ''
    Write-Output ("VERSION_SET_SUMMARY_CSV={0}" -f $summaryPath)
}

$topExt = @(
    $out |
    Group-Object Extension |
    Sort-Object Count -Descending |
    Select-Object -First 10 |
    ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }
)
if (@($topExt).Count -gt 0) {
    Write-Output ''
    Write-Output 'TOP_EXTENSIONS:'
    foreach ($line in $topExt) { Write-Output ("  {0}" -f $line) }
}


