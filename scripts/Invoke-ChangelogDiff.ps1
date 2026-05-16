# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Generate .mdv (virtual markdown) differential changelog files.

.DESCRIPTION
    Parses CHANGELOG.md and/or ENHANCEMENTS-LOG.md, computes differential
    or combined views between two version points, and writes .mdv files
    to temp/changelog-mdv/.  These are built on demand and referenced
    dynamically from the temp directory by XHTML-ChangelogViewer.xhtml.

    Modes:
      - Diff       Compare two specific versions side-by-side
      - Combined   Merge all changes between two version points
      - List       List all existing .mdv files in temp/changelog-mdv/
      - Refresh    Re-parse changelog and rebuild the version index JSON

.PARAMETER WorkspacePath
    Workspace root.  Defaults to parent of this script's directory.

.PARAMETER Mode
    Operation mode: Diff, Combined, List, Refresh.

.PARAMETER FromVersion
    Starting version tag (e.g. '2604.B2.V33.1').

.PARAMETER ToVersion
    Ending version tag (e.g. '2604.B2.V33.3').

.PARAMETER ChangelogFile
    Which changelog to parse: 'CHANGELOG' or 'ENHANCEMENTS-LOG'.
    Defaults to 'CHANGELOG'.

.EXAMPLE
    .\scripts\Invoke-ChangelogDiff.ps1 -Mode Diff -FromVersion '2604.B2.V33.1' -ToVersion '2604.B2.V33.3'
    .\scripts\Invoke-ChangelogDiff.ps1 -Mode Combined -FromVersion '2604.B1.V1.0' -ToVersion '2604.B2.V33.3'
    .\scripts\Invoke-ChangelogDiff.ps1 -Mode List
    .\scripts\Invoke-ChangelogDiff.ps1 -Mode Refresh

.NOTES
    Author  : The Establishment
    Created : 2026-04-16
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = '',
    [ValidateSet('Diff','Combined','List','Refresh')]
    [string]$Mode = 'Diff',
    [string]$FromVersion = '',
    [string]$ToVersion   = '',
    [ValidateSet('CHANGELOG','ENHANCEMENTS-LOG')]
    [string]$ChangelogFile = 'CHANGELOG'
)

# ── Resolve workspace ──
if (-not $WorkspacePath) { $WorkspacePath = Split-Path $PSScriptRoot }
if (-not $WorkspacePath -or -not (Test-Path $WorkspacePath)) { $WorkspacePath = $PSScriptRoot }

# ── Ensure output directory ──
$mdvDir = Join-Path (Join-Path $WorkspacePath 'temp') 'changelog-mdv'
if (-not (Test-Path $mdvDir)) {
    New-Item -Path $mdvDir -ItemType Directory -Force | Out-Null
}

# ── Logging (use Write-AppLog if available, else Write-Host) ──
function Write-Log {
    param([string]$Message, [string]$Level = 'Info')
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix = "[$ts ChangelogDiff $Level]"
    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
        Write-AppLog "$prefix $Message" $Level
    } else {
        $color = switch ($Level) {
            'Error'   { 'Red' }
            'Warning' { 'Yellow' }
            'Info'    { 'Cyan' }
            default   { 'Gray' }
        }
        Write-Host "$prefix $Message" -ForegroundColor $color
    }
}

# ══════════════════════════════════════════════════════════════
# PARSE CHANGELOG
# ══════════════════════════════════════════════════════════════
function Parse-Changelog {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Log "Changelog not found: $FilePath" 'Error'
        return @()
    }

    $lines = Get-Content -Path $FilePath -Encoding UTF8
    $versions = [System.Collections.Generic.List[hashtable]]::new()
    $cur = $null
    $curSection = ''

    foreach ($line in $lines) {
        # Version header: ## [tag] — date
        if ($line -match '^\#\# \[([^\]]+)\]\s*[\u2014\u2013\-]\s*(\d{4}-\d{2}-\d{2})') {
            if ($null -ne $cur) { $versions.Add($cur) }
            $cur = @{
                Tag      = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Date     = $Matches[2]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Sections = @{}
                Raw      = "$line`n"
            }
            $curSection = ''
            continue
        }
        # Session-style header: ## ⚙ date — ...
        if ($line -match '^\#\# .+(\d{4}-\d{2}-\d{2})\s*[\u2014\u2013\-]') {
            if ($null -ne $cur) { $versions.Add($cur) }
            $cur = @{
                Tag      = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Date     = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Sections = @{}
                Raw      = "$line`n"
            }
            $curSection = ''
            continue
        }

        if ($null -eq $cur) { continue }
        $cur.Raw += "$line`n"

        # Section headers
        if ($line -match '^\#\#\# (Added|Changed|Fixed|Removed|Security|Deprecated|Pipeline Metrics)') {
            $curSection = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            if (-not $cur.Sections.ContainsKey($curSection)) {
                $cur.Sections[$curSection] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }

        # List items
        if ($curSection -and $line -match '^- (.+)') {
            $cur.Sections[$curSection].Add($Matches[1])  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }

        # Table rows (pipeline metrics)
        if ($curSection -eq 'Pipeline Metrics' -and $line -match '^\|' -and $line -notmatch '^\|[\s\-\|]+$') {
            $cur.Sections[$curSection].Add($line)
        }
    }
    if ($null -ne $cur) { $versions.Add($cur) }

    return $versions
}

# ══════════════════════════════════════════════════════════════
# FIND VERSION INDEX
# ══════════════════════════════════════════════════════════════
function Find-VersionIndex {
    param([System.Collections.Generic.List[hashtable]]$Versions, [string]$Tag)
    for ($i = 0; $i -lt @($Versions).Count; $i++) {
        if ($Versions[$i].Tag -eq $Tag) { return $i }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
    return -1
}

# ══════════════════════════════════════════════════════════════
# COLLECT ALL ITEMS FROM A VERSION
# ══════════════════════════════════════════════════════════════
function Get-VersionItems {
    param([hashtable]$Version)
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($sec in $Version.Sections.Keys) {
        foreach ($item in $Version.Sections[$sec]) {
            $items.Add("[$sec] $item")
        }
    }
    return $items
}

# ══════════════════════════════════════════════════════════════
# MODE: LIST
# ══════════════════════════════════════════════════════════════
if ($Mode -eq 'List') {
    Write-Log "Listing .mdv files in: $mdvDir"
    if (Test-Path $mdvDir) {
        $files = Get-ChildItem -Path $mdvDir -Filter '*.mdv' -File
        if (@($files).Count -eq 0) {
            Write-Log "No .mdv files found" 'Warning'
        } else {
            foreach ($f in $files) {
                Write-Log "  $($f.Name)  ($([math]::Round($f.Length / 1KB, 1)) KB)  $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
            }
        }
    }
    return
}

# ══════════════════════════════════════════════════════════════
# PARSE SOURCE CHANGELOG
# ══════════════════════════════════════════════════════════════
$readmePath = Join-Path $WorkspacePath '~README.md'
$changelogPath = Join-Path $readmePath "$ChangelogFile.md"
Write-Log "Parsing: $changelogPath"

$versions = Parse-Changelog -FilePath $changelogPath
Write-Log "Found $(@($versions).Count) version entries"

if (@($versions).Count -eq 0) {
    Write-Log "No versions parsed - check changelog format" 'Error'
    return
}

# ══════════════════════════════════════════════════════════════
# MODE: REFRESH (write index JSON)
# ══════════════════════════════════════════════════════════════
if ($Mode -eq 'Refresh') {
    $indexPath = Join-Path $mdvDir 'changelog-index.json'
    $indexData = @{
        schema    = 'ChangelogIndex/1.0'
        generated = (Get-Date -Format 'o')
        source    = $ChangelogFile
        versions  = @()
    }
    foreach ($v in $versions) {
        $sectionSummary = @{}
        foreach ($sec in $v.Sections.Keys) {
            $sectionSummary[$sec] = @($v.Sections[$sec]).Count  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
        $indexData.versions += @{
            tag      = $v.Tag
            date     = $v.Date
            sections = $sectionSummary
        }
    }
    $indexData | ConvertTo-Json -Depth 5 | Set-Content -Path $indexPath -Encoding UTF8
    Write-Log "Index written: $indexPath ($(@($versions).Count) versions)"
    return
}

# ══════════════════════════════════════════════════════════════
# VALIDATE VERSION PARAMETERS
# ══════════════════════════════════════════════════════════════
if (-not $FromVersion -or -not $ToVersion) {
    Write-Log "Both -FromVersion and -ToVersion are required for $Mode mode" 'Error'
    Write-Log "Available versions:"
    foreach ($v in $versions) { Write-Log "  $($v.Tag)  ($($v.Date))" }
    return
}

$fromIdx = Find-VersionIndex -Versions $versions -Tag $FromVersion
$toIdx   = Find-VersionIndex -Versions $versions -Tag $ToVersion

if ($fromIdx -lt 0) { Write-Log "Version not found: $FromVersion" 'Error'; return }
if ($toIdx -lt 0)   { Write-Log "Version not found: $ToVersion" 'Error'; return }

# ══════════════════════════════════════════════════════════════
# MODE: DIFF
# ══════════════════════════════════════════════════════════════
if ($Mode -eq 'Diff') {
    $vFrom = $versions[$fromIdx]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $vTo   = $versions[$toIdx]  # SIN-EXEMPT:P027 -- index access, context-verified safe

    $leftItems  = Get-VersionItems -Version $vFrom
    $rightItems = Get-VersionItems -Version $vTo

    $safeFrom = $FromVersion -replace '\.', '-'
    $safeTo   = $ToVersion -replace '\.', '-'
    $filename = "diff-${safeFrom}_vs_${safeTo}.mdv"
    $outPath  = Join-Path $mdvDir $filename

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<!-- Virtual Differential Markdown -->")
    [void]$sb.AppendLine("<!-- Generated: $(Get-Date -Format 'o') -->")
    [void]$sb.AppendLine("<!-- Source: $ChangelogFile.md -->")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Differential: $FromVersion vs $ToVersion")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Removed in $ToVersion (present in $FromVersion)")
    [void]$sb.AppendLine("")

    foreach ($item in $leftItems) {
        if ($rightItems -notcontains $item) {
            [void]$sb.AppendLine("- ~~$item~~")
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Added in $ToVersion (not in $FromVersion)")
    [void]$sb.AppendLine("")

    foreach ($item in $rightItems) {
        if ($leftItems -notcontains $item) {
            [void]$sb.AppendLine("- **$item**")
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Unchanged (common to both)")
    [void]$sb.AppendLine("")

    foreach ($item in $leftItems) {
        if ($rightItems -contains $item) {
            [void]$sb.AppendLine("- $item")
        }
    }

    $sb.ToString() | Set-Content -Path $outPath -Encoding UTF8
    Write-Log "Diff written: $outPath"
    Write-Log "  Removed: $(@($leftItems | Where-Object { $rightItems -notcontains $_ }).Count)"
    Write-Log "  Added:   $(@($rightItems | Where-Object { $leftItems -notcontains $_ }).Count)"
    Write-Log "  Common:  $(@($leftItems | Where-Object { $rightItems -contains $_ }).Count)"
}

# ══════════════════════════════════════════════════════════════
# MODE: COMBINED
# ══════════════════════════════════════════════════════════════
if ($Mode -eq 'Combined') {
    $lo = [Math]::Min($fromIdx, $toIdx)
    $hi = [Math]::Max($fromIdx, $toIdx)

    $safeFrom = $versions[$hi].Tag -replace '\.', '-'  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $safeTo   = $versions[$lo].Tag -replace '\.', '-'  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $filename = "combined-${safeFrom}_to_${safeTo}.mdv"
    $outPath  = Join-Path $mdvDir $filename

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<!-- Virtual Combined Markdown -->")
    [void]$sb.AppendLine("<!-- Generated: $(Get-Date -Format 'o') -->")
    [void]$sb.AppendLine("<!-- Source: $ChangelogFile.md -->")
    [void]$sb.AppendLine("<!-- Range: $($versions[$hi].Tag) to $($versions[$lo].Tag) -->")  # SIN-EXEMPT:P027 -- index access, context-verified safe
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Combined Changelog: $($versions[$hi].Tag) -> $($versions[$lo].Tag)")  # SIN-EXEMPT:P027 -- index access, context-verified safe
    [void]$sb.AppendLine("")

    # Merge all sections
    $merged = @{}
    $totalItems = 0
    for ($i = $lo; $i -le $hi; $i++) {
        $v = $versions[$i]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        foreach ($sec in $v.Sections.Keys) {
            if (-not $merged.ContainsKey($sec)) { $merged[$sec] = [System.Collections.Generic.List[string]]::new() }  # SIN-EXEMPT:P027 -- index access, context-verified safe
            foreach ($item in $v.Sections[$sec]) {
                $merged[$sec].Add("$item  [$($v.Tag)]")  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $totalItems++
            }
        }
    }

    foreach ($sec in $merged.Keys) {
        [void]$sb.AppendLine("## $sec ($(@($merged[$sec]).Count) items)")  # SIN-EXEMPT:P027 -- index access, context-verified safe
        [void]$sb.AppendLine("")
        foreach ($item in $merged[$sec]) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
            [void]$sb.AppendLine("- $item")
        }
        [void]$sb.AppendLine("")
    }

    $sb.ToString() | Set-Content -Path $outPath -Encoding UTF8
    Write-Log "Combined written: $outPath"
    Write-Log "  Versions: $($hi - $lo + 1)  |  Total items: $totalItems"
}

Write-Log "Done."

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





