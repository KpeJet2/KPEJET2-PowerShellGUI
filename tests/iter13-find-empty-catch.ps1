# VersionTag: 2605.B2.V31.7
# iter13: find empty/whitespace/comment-only catch blocks in source
$ErrorActionPreference = 'Stop'
$root = 'C:\PowerShellGUI'
$widened = 'catch\s*\{(?:[\s]|#[^\r\n]*[\r\n])*\}'
$files = Get-ChildItem -Path (Join-Path $root 'modules'),(Join-Path $root 'scripts') -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\ActionPacks-master\\' -and $_.FullName -notmatch '\\QUICK-APP\\' -and $_.FullName -notmatch '\\\.venv\\' }
$hits = New-Object System.Collections.Generic.List[object]
$rx = [regex]::new($widened, 'IgnoreCase')
foreach ($f in $files) {
    try { $c = Get-Content -Raw -Encoding UTF8 -Path $f.FullName } catch { continue }
    if (-not $c) { continue }
    foreach ($m in $rx.Matches($c)) {
        $line = ([regex]::Matches($c.Substring(0, $m.Index), "`n")).Count + 1
        $body = $m.Value
        $exempt = $body -match 'SIN-EXEMPT' -or $body -match 'Intentional:' -or $body -match 'non-fatal'
        if ($exempt) { continue }
        $bodyFlat = ($body -replace '\s+', ' ')
        $snip = if ($bodyFlat.Length -gt 80) { $bodyFlat.Substring(0, 80) } else { $bodyFlat }
        $hits.Add([PSCustomObject]@{
            File = $f.FullName.Substring($root.Length + 1)
            Line = $line
            Snippet = $snip
        }) | Out-Null
    }
}
$outDir = Join-Path $root 'reports\iter13'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$hits | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'empty-catch-findings.json') -Encoding UTF8
Write-Host ("Empty/whitespace/comment-only catches (non-exempt): " + $hits.Count)
$hits | Select-Object -First 30 | Format-Table -AutoSize

