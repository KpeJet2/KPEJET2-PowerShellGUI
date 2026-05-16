# VersionTag: 2605.B5.V46.0
# FileRole: Pipeline
# SupportPS5.1: YES
# SupportsPS7.6: YES
<#
.SYNOPSIS
    Wire every workspace .xhtml file to styles/pwshgui-version-link.js so that
    static version strings (in title, header, body, footer) get rendered as a
    live link to the canonical version feed.

.DESCRIPTION
    Idempotent. For each candidate XHTML file:
      1. Extract the page's <!-- VersionTag: ... --> (skip if missing).
      2. Compute relative path to styles/pwshgui-version-link.js and to the
         feed JSON.
      3. If the file does not yet contain `pwshgui-version-tag`, inject:
            <meta name="pwshgui-version-tag"  content="VVV"/>
            <meta name="pwshgui-version-feed" content="../~REPORTS/xhtml-version-feed.json"/>
            <script type="text/javascript" src="../styles/pwshgui-version-link.js"></script>
         immediately before </head>.
      4. If the body has no element with class matching ver/version/ft-version
         (i.e. nothing for the JS to upgrade), append a small floating badge
         element  <div class="pwshgui-version" data-pwshgui-version>v...</div>
         immediately before </body> so the page still gets a visible link.

    Files preserve their original encoding (BOM detected via byte-prefix).
    Skips templates, copies, and excluded paths.

.PARAMETER DryRun
    Report planned edits without writing.

.PARAMETER Path
    Restrict to a single file (still applied idempotently).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$Path,
    [switch]$DryRun
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$jsRelRoot   = 'styles/pwshgui-version-link.js'
$feedRelRoot = '~REPORTS/xhtml-version-feed.json'

$tagRegex = [regex]'(?im)<!--\s*VersionTag:\s*(?<tag>[\w.\-]+)\s*-->'
$markerCheck = 'pwshgui-version-tag'

# Patterns that mean the page already has a version-display element the JS will pick up.
$displayHints = @(
    'class="pwshgui-version"', 'data-pwshgui-version',
    'class="ver-badge"', 'class="ft-version"', 'class="hdr-ver"',
    'class="ver "', "class='ver '", 'class="ver"', "class='ver'",
    'class="version"', "class='version'",
    'id="hdrVer"', 'id="headerVersion"'
)

$excludePatterns = @('\\node_modules\\', '\\.venv\\', '\\.git\\', '\\.history\\', '\\~DOWNLOADS\\', '\\~REPORTS\\', '\\checkpoints\\', '\\logs\\', '\\_TEMPLATE-', '\\_BASE-template', '_COPY_')

if ($Path) {
    $files = @(Get-Item -LiteralPath $Path -ErrorAction Stop)
} else {
    $files = Get-ChildItem -LiteralPath $WorkspacePath -Recurse -Filter '*.xhtml' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $_.FullName
            -not ($excludePatterns | Where-Object { $p -match $_ })
        }
}

function Get-RelativePath {
    param([string]$From, [string]$To)
    $fromUri = [uri]("file:///" + ($From -replace '\\','/').TrimEnd('/') + "/")
    $toUri   = [uri]("file:///" + ($To   -replace '\\','/'))
    return [uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString())
}

function Read-FileWithEncoding {
    param([string]$FullName)
    $bytes = [System.IO.File]::ReadAllBytes($FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)  # SIN-EXEMPT:P027 -- guarded by Length -ge 3 check
    $enc = [System.Text.UTF8Encoding]::new($hasBom)
    $text = $enc.GetString($bytes, ($(if ($hasBom) { 3 } else { 0 })), $bytes.Length - $(if ($hasBom) { 3 } else { 0 }))
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom }
}

function Write-FileWithEncoding {
    param([string]$FullName, [string]$Text, [bool]$HasBom)
    $enc = [System.Text.UTF8Encoding]::new($HasBom)
    [System.IO.File]::WriteAllBytes($FullName, $enc.GetPreamble() + $enc.GetBytes($Text))
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
    $entry = [ordered]@{
        path        = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\','/').Replace('\','/')
        versionTag  = $null
        action      = 'skipped'
        reason      = ''
        addedMeta   = $false
        addedBadge  = $false
    }

    try {
        $info = Read-FileWithEncoding -FullName $f.FullName
        $text = $info.Text
        $m = $tagRegex.Match($text)
        if (-not $m.Success) {
            $entry.reason = 'no-VersionTag'
            $results.Add([pscustomobject]$entry) | Out-Null
            continue
        }
        $entry.versionTag = $m.Groups['tag'].Value

        if ($text.Contains($markerCheck)) {
            $entry.action = 'already-wired'
            $results.Add([pscustomobject]$entry) | Out-Null
            continue
        }

        # Resolve relative paths from this file to assets at workspace root.
        $fileDir   = Split-Path -Parent $f.FullName
        $jsAbs     = Join-Path $WorkspacePath $jsRelRoot
        $feedAbs   = Join-Path $WorkspacePath $feedRelRoot
        $jsHref    = (Get-RelativePath -From $fileDir -To $jsAbs).Replace('\','/')
        $feedHref  = (Get-RelativePath -From $fileDir -To $feedAbs).Replace('\','/')

        $injection = @"
  <meta name="pwshgui-version-tag" content="$($entry.versionTag)" />
  <meta name="pwshgui-version-feed" content="$feedHref" />
  <script type="text/javascript" src="$jsHref"></script>
"@

        # Insert immediately before </head> (case-insensitive, single occurrence)
        $headClose = [regex]::new('(?i)</head>')
        $hcMatch = $headClose.Match($text)
        if (-not $hcMatch.Success) {
            $entry.reason = 'no-</head>'
            $results.Add([pscustomobject]$entry) | Out-Null
            continue
        }
        $newText = $headClose.Replace($text, ($injection + "`r`n</head>"), 1)
        $entry.addedMeta = $true

        # If page has no version-display element, add a small badge before </body>
        $hasDisplay = $false
        foreach ($hint in $displayHints) { if ($text.IndexOf($hint, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hasDisplay = $true; break } }
        if (-not $hasDisplay) {
            $badge = "  <div class=`"pwshgui-version`" data-pwshgui-version=`"$($entry.versionTag)`" style=`"position:fixed;bottom:6px;right:8px;font-size:11px;background:rgba(13,17,23,0.8);color:#58a6ff;padding:2px 8px;border:1px solid #30363d;border-radius:4px;z-index:9999;`">v$($entry.versionTag)</div>`r`n"
            $bodyClose = [regex]::new('(?i)</body>')
            if ($bodyClose.IsMatch($newText)) {
                $newText = $bodyClose.Replace($newText, ($badge + '</body>'), 1)
                $entry.addedBadge = $true
            }
        }

        $entry.action = 'wired'

        if (-not $DryRun) {
            Write-FileWithEncoding -FullName $f.FullName -Text $newText -HasBom $info.HasBom

            # Quick well-formedness check
            try {
                $null = [xml](Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop)
            } catch {
                # Roll back
                Write-FileWithEncoding -FullName $f.FullName -Text $text -HasBom $info.HasBom
                $entry.action = 'rolled-back'
                $entry.reason = 'xml-parse-failure: ' + $_.Exception.Message
            }
        }

    } catch {
        $entry.action = 'error'
        $entry.reason = $_.Exception.Message
    }
    $results.Add([pscustomobject]$entry) | Out-Null
}

# Summary
$wired       = @($results | Where-Object { $_.action -eq 'wired' }).Count
$alreadyDone = @($results | Where-Object { $_.action -eq 'already-wired' }).Count
$skipped     = @($results | Where-Object { $_.action -eq 'skipped' }).Count
$rolled      = @($results | Where-Object { $_.action -eq 'rolled-back' }).Count
$errors      = @($results | Where-Object { $_.action -eq 'error' }).Count

Write-Host ''
Write-Host '=== Add-XhtmlVersionLink ==='
Write-Host ("  Wired (newly):     {0}" -f $wired)
Write-Host ("  Already-wired:     {0}" -f $alreadyDone)
Write-Host ("  Skipped (no tag):  {0}" -f $skipped)
Write-Host ("  Rolled back:       {0}" -f $rolled)
Write-Host ("  Errors:            {0}" -f $errors)

if ($DryRun) { Write-Host '  (DryRun - no files modified)' }

# Emit results so callers can pipe / capture
$results
