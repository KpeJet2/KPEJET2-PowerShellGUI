# VersionTag: 2605.B5.V46.0
# Apply canonical VersionTag bulk rewrite preserving original encoding.
# Reads workspace-versions.csv, replaces all existing VersionTag values with $TargetVersion.
# Encoding-safe: detects BOM (UTF-8/UTF-16LE/UTF-16BE) and preserves; defaults to UTF-8 no-BOM.

[CmdletBinding()]
param(
    [string]$CsvPath       = 'C:\PowerShellGUI\temp\workspace-versions.csv',
    [string]$TargetVersion = '2605.B5.V46.0',
    [string]$LogPath       = 'C:\PowerShellGUI\temp\retag-log.csv',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$rows = Import-Csv -LiteralPath $CsvPath
Write-Host ("Rows in CSV: {0}" -f @($rows).Count)

# Pattern: replace existing VersionTag value (preserves any prefix like '#', '<!--', '//', ';')
$pattern = [regex]'(VersionTag:\s*)([0-9]{4}\.B\d+\.[Vv]\d+(?:\.\d+)?)'
$replace = '${1}' + $TargetVersion

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

$results  = New-Object System.Collections.Generic.List[object]
$updated  = 0
$skipped  = 0
$failed   = 0
$noChange = 0

foreach ($r in $rows) {
    $relPath = $r.Path
    if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
    if ([string]::IsNullOrWhiteSpace($r.Version)) { continue }  # only re-tag known-listed items
    $abs = Join-Path 'C:\PowerShellGUI' ($relPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs)) {
        $skipped++
        $results.Add([pscustomobject]@{ Path=$relPath; OldVersion=$r.Version; NewVersion=''; Encoding=''; Status='missing' }) | Out-Null
        continue
    }
    try {
        $enc  = Get-FileEncodingInfo -Path $abs
        $text = [System.IO.File]::ReadAllText($abs, $enc.Encoding)
        if (-not $pattern.IsMatch($text)) {
            $noChange++
            $results.Add([pscustomobject]@{ Path=$relPath; OldVersion=$r.Version; NewVersion=''; Encoding=$enc.Name; Status='no-match' }) | Out-Null
            continue
        }
        $newText = $pattern.Replace($text, $replace, 1)  # only first match (canonical header)
        if ($newText -eq $text) {
            $noChange++
            $results.Add([pscustomobject]@{ Path=$relPath; OldVersion=$r.Version; NewVersion=$TargetVersion; Encoding=$enc.Name; Status='already-current' }) | Out-Null
            continue
        }
        if (-not $DryRun) {
            [System.IO.File]::WriteAllText($abs, $newText, $enc.Encoding)
        }
        $updated++
        $results.Add([pscustomobject]@{ Path=$relPath; OldVersion=$r.Version; NewVersion=$TargetVersion; Encoding=$enc.Name; Status=($(if($DryRun){'would-update'}else{'updated'})) }) | Out-Null
    }
    catch {
        $failed++
        $results.Add([pscustomobject]@{ Path=$relPath; OldVersion=$r.Version; NewVersion=''; Encoding=''; Status=('error: ' + $_.Exception.Message) }) | Out-Null
    }
}

$results | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "================ Re-tag Summary ================"
Write-Host ("TargetVersion : {0}" -f $TargetVersion)
Write-Host ("Total rows    : {0}" -f @($rows).Count)
Write-Host ("Updated       : {0}" -f $updated)
Write-Host ("No-change     : {0}" -f $noChange)
Write-Host ("Skipped       : {0}" -f $skipped)
Write-Host ("Failed        : {0}" -f $failed)
Write-Host ("Log           : {0}" -f $LogPath)
