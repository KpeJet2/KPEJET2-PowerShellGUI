# VersionTag: 2605.B5.V46.0
# Deep version-tag detection + raise-to-canonical pass.
# Scans every file (no extension filter, full content) excluding historical/vendor zones.
# Groups by detected version, optionally rewrites every non-canonical match to TargetVersion.

[CmdletBinding()]
param(
    [string]$Workspace     = 'C:\PowerShellGUI',
    [string]$TargetVersion = '2605.B5.V46.0',
    [string]$DetectCsv     = 'C:\PowerShellGUI\temp\version-detections.csv',
    [string]$BumpLog       = 'C:\PowerShellGUI\temp\raise-bump-log.csv',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

# Folders considered historical / vendor / runtime — never touched.
# (Strict prefix match against forward-slash relative path.)
$excludeFolders = @(
    '.git/','.history/','.venv/','.venv-pygame312/','node_modules/',
    '~DOWNLOADS/','~HISTORY/','~REPORTS/',
    'reports/','Report/','gallery/','logs/','checkpoints/',
    'sin_registry/',                 # SIN records pin to historical versions
    'agents/focalpoint-null/checkpoints/',
    'config/agentic-manifest-history/',  # immutable timestamped manifest snapshots
    'sovereign-kernel/snapshot'
)
# Always skip binaries / archives / images / fonts / media etc.
$skipExtRx = '\.(exe|dll|pdb|zip|7z|tar|gz|tgz|bz2|rar|jar|msi|wim|iso|png|jpg|jpeg|gif|ico|svg|bmp|tif|tiff|webp|woff2?|ttf|otf|eot|wav|mp3|mp4|mov|avi|webm|pdf|db|sqlite|sqlite3|class|pyc|pyo|so|dylib|bin|nupkg|lockb)$'

$rxAny     = [regex]'VersionTag:\s*([0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?)'
$rxRewrite = [regex]'(VersionTag:\s*)([0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?)'

function Get-FileEncodingInfo {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4
        $n = $fs.Read($buf, 0, 4)
    } finally { $fs.Dispose() }
    if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) {
        return @{ Name='utf8-bom';  Encoding=[System.Text.UTF8Encoding]::new($true) }
    }
    if ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) {
        return @{ Name='utf16-le';  Encoding=[System.Text.UnicodeEncoding]::new($false,$true) }
    }
    if ($n -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) {
        return @{ Name='utf16-be';  Encoding=[System.Text.UnicodeEncoding]::new($true,$true) }
    }
    return @{ Name='utf8-nobom'; Encoding=[System.Text.UTF8Encoding]::new($false) }
}

$detections   = New-Object System.Collections.Generic.List[object]
$bumpResults  = New-Object System.Collections.Generic.List[object]
$filesScanned = 0
$filesRewrit  = 0
$matchesRewrit= 0

Get-ChildItem -LiteralPath $Workspace -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($Workspace.Length).TrimStart('\').Replace('\','/')
    foreach ($x in $excludeFolders) { if ($rel -like ($x + '*')) { return } }
    if ($_.Extension -and ($_.Extension.ToLower() -match $skipExtRx)) { return }
    if ($_.Length -gt 5MB) { return }

    $filesScanned++
    try {
        $enc  = Get-FileEncodingInfo -Path $_.FullName
        $text = [System.IO.File]::ReadAllText($_.FullName, $enc.Encoding)
        $hits = $rxAny.Matches($text)
        if ($hits.Count -eq 0) { return }

        foreach ($m in $hits) {
            $detections.Add([pscustomobject]@{
                Path    = $rel
                Version = $m.Groups[1].Value
            }) | Out-Null
        }

        if ($Apply) {
            $newText = $rxRewrite.Replace($text, { param($mm)
                if ($mm.Groups[2].Value -eq $TargetVersion) { return $mm.Value }
                $script:matchesRewrit++
                return $mm.Groups[1].Value + $TargetVersion
            })
            if ($newText -ne $text) {
                [System.IO.File]::WriteAllText($_.FullName, $newText, $enc.Encoding)
                $filesRewrit++
                $bumpResults.Add([pscustomobject]@{
                    Path     = $rel
                    Encoding = $enc.Name
                    Status   = 'updated'
                }) | Out-Null
            }
        }
    }
    catch {
        $bumpResults.Add([pscustomobject]@{
            Path     = $rel
            Encoding = ''
            Status   = ('error: ' + $_.Exception.Message)
        }) | Out-Null
    }
}

$detections | Export-Csv -LiteralPath $DetectCsv -NoTypeInformation -Encoding UTF8
if ($Apply) { $bumpResults | Export-Csv -LiteralPath $BumpLog -NoTypeInformation -Encoding UTF8 }

Write-Host ""
Write-Host "================ Deep VersionTag Scan ================"
Write-Host ("Files scanned : {0}" -f $filesScanned)
Write-Host ("Detections    : {0}" -f $detections.Count)
Write-Host ("Detect CSV    : {0}" -f $DetectCsv)
Write-Host ""
Write-Host "Top detections by version (rank, version, occurrences, distinct files):"
$detections | Group-Object Version | ForEach-Object {
    [pscustomobject]@{
        Version  = $_.Name
        Hits     = $_.Count
        Files    = ($_.Group | Select-Object -ExpandProperty Path -Unique).Count
    }
} | Sort-Object Hits -Descending |
ForEach-Object -Begin { $script:rank=0 } -Process {
    $script:rank++
    '{0,2}. {1,-22} hits={2,5}  files={3,5}' -f $script:rank, $_.Version, $_.Hits, $_.Files
} | Out-Host

if ($Apply) {
    Write-Host ""
    Write-Host "================ Raise Pass ================"
    Write-Host ("Files rewritten : {0}" -f $filesRewrit)
    Write-Host ("Matches updated : {0}" -f $matchesRewrit)
    Write-Host ("Bump log        : {0}" -f $BumpLog)
}
