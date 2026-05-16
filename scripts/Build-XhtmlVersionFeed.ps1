# VersionTag: 2605.B5.V46.0
# FileRole: Pipeline
# SupportPS5.1: YES
# SupportsPS7.6: YES
<#
.SYNOPSIS
    Build a JSON feed of every XHTML file's VersionTag for use by
    styles/pwshgui-version-link.js (renders live version badges on every page).

.DESCRIPTION
    Walks the workspace, parses the `<!-- VersionTag: ... -->` comment from
    each *.xhtml file, and emits ~REPORTS/xhtml-version-feed.json (schema
    "XhtmlVersionFeed/1.0"). Determines `currentRelease` as the highest
    canonical tag observed across the set.
.NOTES
    Idempotent. Safe to run from cron / pre-commit / Build-VER pipelines.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $WorkspacePath '~REPORTS/xhtml-version-feed.json'
}
$reportsDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

$tagRegex = [regex]'(?im)^\s*<!--\s*VersionTag:\s*(?<tag>[\w.\-]+)\s*-->'
$canonical = [regex]'^(?<prefix>\d{4})\.B(?<build>\d+)\.V(?<major>\d+)\.(?<minor>\d+)$'

# Excluded folders: build artefacts, vendor, archives, downloads
$excludePatterns = @('\\node_modules\\', '\\.venv\\', '\\.git\\', '\\.history\\', '\\~DOWNLOADS\\', '\\~REPORTS\\', '\\checkpoints\\', '\\logs\\')

$files = Get-ChildItem -LiteralPath $WorkspacePath -Recurse -Filter '*.xhtml' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $p = $_.FullName
        -not ($excludePatterns | Where-Object { $p -match $_ })
    }

$entries = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $tag = $null
    try {
        $head = Get-Content -LiteralPath $f.FullName -TotalCount 30 -ErrorAction Stop -Encoding UTF8 | Out-String
        $m = $tagRegex.Match($head)
        if ($m.Success) { $tag = $m.Groups['tag'].Value }
    } catch { <# Intentional: skip unreadable file #> }

    $rel = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\','/').Replace('\','/')
    $cm  = $canonical.Match([string]$tag)
    $entries.Add([pscustomobject]@{
        path         = $rel
        versionTag   = $tag
        canonical    = $cm.Success
        prefix       = if ($cm.Success) { $cm.Groups['prefix'].Value } else { '' }
        build        = if ($cm.Success) { [int]$cm.Groups['build'].Value } else { -1 }
        major        = if ($cm.Success) { [int]$cm.Groups['major'].Value } else { -1 }
        minor        = if ($cm.Success) { [int]$cm.Groups['minor'].Value } else { -1 }
        sizeBytes    = $f.Length
        lastWriteUtc = $f.LastWriteTimeUtc.ToString('o')
    }) | Out-Null
}

# currentRelease = lexically highest canonical tag by (prefix, build, major, minor)
$currentRelease = $null
$canon = @($entries | Where-Object { $_.canonical })
if ($canon.Count -gt 0) {
    $sorted = $canon | Sort-Object prefix, build, major, minor -Descending
    $currentRelease = $sorted[0].versionTag
}

# Distribution summary
$dist = @($entries | Where-Object { $_.versionTag } | Group-Object versionTag |
    Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject]@{ versionTag = $_.Name; fileCount = $_.Count } })

$payload = [ordered]@{
    schema           = 'XhtmlVersionFeed/1.0'
    generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath    = $WorkspacePath
    currentRelease   = $currentRelease
    fileCount        = $entries.Count
    canonicalCount   = @($entries | Where-Object { $_.canonical }).Count
    untaggedCount    = @($entries | Where-Object { -not $_.versionTag }).Count
    distribution     = $dist
    files            = $entries
}

$json = $payload | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host ("XHTML version feed written: {0}" -f $OutputPath)
Write-Host ("  files={0}  canonical={1}  untagged={2}  currentRelease={3}" -f `
    $entries.Count, $payload.canonicalCount, $payload.untaggedCount, ($currentRelease -replace '^$','--'))
