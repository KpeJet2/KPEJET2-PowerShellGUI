# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-VersionAlignmentTool -- Pre-change version validation, minor cleanup,
    major alignment, and cross-validation for the PwShGUI workspace.

.DESCRIPTION
    Modes:
      -ScanOnly         Show current vs proposed side-by-side (no changes)
      -SimulateMinor    Dry-run minor version normalisation
      -ApplyMinor       Write minor version alignment to files
      -SimulateMajor    Dry-run major version increment
      -ApplyMajor       Write major version increment to all files
      -CrossValidate    Post-change validation against manifest

    VersionTag format: YYMM.B<build>.V<major>.<minor>
      - V is always uppercase in canonical form
      - Minor increments per file edit
      - Major resets minor to 0: YYMM.Bx.V<NewMajor>.0

.NOTES
    Author   : The Establishment
    Date     : 2026-04-05
    FileRole : Script
    Version  : 2604.B2.V31.0
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$ScanOnly,
    [switch]$SimulateMinor,
    [switch]$ApplyMinor,
    [switch]$SimulateMajor,
    [switch]$ApplyMajor,
    [switch]$CrossValidate,
    [string]$TargetBuild = 'B2',
    [int]$NewMajor = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
#  CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

$script:YearMonth       = '2604'
$script:CanonicalPrefix = "$($script:YearMonth).$TargetBuild"
$script:VersionRegex    = '(?m)^#\s*VersionTag:\s*(\S+)'
$script:ExcludePattern  = '\\\.git\\|\\\.history\\|\\node_modules\\|\\__pycache__|\\checkpoints\\|\\~REPORTS\\|\\~DOWNLOADS\\|\\\.venv'

# ═══════════════════════════════════════════════════════════════════════════════
#  HELPER: Parse tag
# ═══════════════════════════════════════════════════════════════════════════════

function Parse-Tag {
    param([string]$Tag)
    if ($Tag -match '^(\d{4})\.(B\d+)\.[Vv](\d+)(?:\.(\d+))?$') {
        return @{
            ym     = $Matches[1]
            build  = $Matches[2]
            major  = [int]$Matches[3]
            minor  = if ($null -ne $Matches[4] -and $Matches[4] -ne '') { [int]$Matches[4] } else { 0 }
            raw    = $Tag
            vCase  = if ($Tag -cmatch '\.[Vv]') { if ($Tag -cmatch '\.V') { 'V' } else { 'v' } } else { 'V' }
        }
    }
    return $null
}

function Format-Tag {
    param([string]$YM, [string]$Build, [int]$Major, [int]$Minor)
    return "$YM.$Build.V$Major.$Minor"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SCAN: Collect all VersionTags
# ═══════════════════════════════════════════════════════════════════════════════

function Get-AllVersionTags {
    param([string]$Root)
    $files = Get-ChildItem -Path $Root -Recurse -File -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ExcludePattern }

    $results = @()
    foreach ($f in $files) {
        $match = Select-String -Path $f.FullName -Pattern $script:VersionRegex | Select-Object -First 1
        if ($match) {
            $tag = $match.Matches[0].Groups[1].Value.Trim()
            $parsed = Parse-Tag -Tag $tag
            $rel = $f.FullName.Replace("$Root\", '')
            $results += [PSCustomObject]@{
                RelPath   = $rel
                FullPath  = $f.FullName
                CurrentTag = $tag
                Parsed    = $parsed
                HasTag    = ($null -ne $parsed)
            }
        }
    }
    return $results
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MINOR CLEANUP: Normalise case, build prefix, preserve major.minor values
# ═══════════════════════════════════════════════════════════════════════════════

function Compute-MinorCleanup {
    param([array]$Inventory)

    $plan = @()
    foreach ($item in $Inventory) {
        if (-not $item.HasTag) { continue }
        $p = $item.Parsed

        # Canonical: uppercase V, target build prefix, preserve major.minor
        $canonical = Format-Tag -YM $script:YearMonth -Build $TargetBuild -Major $p.major -Minor $p.minor

        $needsChange = ($item.CurrentTag -cne $canonical)
        $changeReasons = @()
        if ($p.vCase -ne 'V')                                  { $changeReasons += 'case V→uppercase' }
        if ($p.build -ne $TargetBuild)                          { $changeReasons += "build $($p.build)→$TargetBuild" }
        if ("$($p.ym)" -ne $script:YearMonth)                  { $changeReasons += "yearmonth $($p.ym)→$($script:YearMonth)" }
        if ($item.CurrentTag -cne $canonical -and @($changeReasons).Count -eq 0) { $changeReasons += 'format normalise' }

        $plan += [PSCustomObject]@{
            RelPath       = $item.RelPath
            FullPath      = $item.FullPath
            CurrentTag    = $item.CurrentTag
            ProposedTag   = $canonical
            NeedsChange   = $needsChange
            ChangeReasons = ($changeReasons -join '; ')
        }
    }
    return $plan
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAJOR ALIGNMENT: Increment major, reset minor to 0
# ═══════════════════════════════════════════════════════════════════════════════

function Compute-MajorAlignment {
    param([array]$Inventory, [int]$TargetMajor)

    # Find highest current major across workspace
    $highestMajor = 0
    foreach ($item in $Inventory) {
        if ($item.HasTag -and $item.Parsed.major -gt $highestMajor) {
            $highestMajor = $item.Parsed.major
        }
    }

    if ($TargetMajor -le 0) { $TargetMajor = $highestMajor + 1 }

    $plan = @()
    foreach ($item in $Inventory) {
        if (-not $item.HasTag) { continue }
        $newTag = Format-Tag -YM $script:YearMonth -Build $TargetBuild -Major $TargetMajor -Minor 0
        $plan += [PSCustomObject]@{
            RelPath     = $item.RelPath
            FullPath    = $item.FullPath
            CurrentTag  = $item.CurrentTag
            ProposedTag = $newTag
            OldMajor    = $item.Parsed.major
            OldMinor    = $item.Parsed.minor
            NewMajor    = $TargetMajor
            NewMinor    = 0
        }
    }
    return @{ plan = $plan; targetMajor = $TargetMajor; highestCurrent = $highestMajor }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  APPLY: Write tags to files
# ═══════════════════════════════════════════════════════════════════════════════

function Apply-TagChanges {
    param([array]$Plan, [string]$Mode)

    $applied = 0
    $failed  = 0
    $log     = @()

    foreach ($item in $Plan) {
        if ($Mode -eq 'minor' -and $item.PSObject.Properties.Name -contains 'NeedsChange' -and -not $item.NeedsChange) { continue }
        if ($item.CurrentTag -eq $item.ProposedTag) { continue }

        try {
            $content = Get-Content -LiteralPath $item.FullPath -Raw -Encoding UTF8
            $escaped = [regex]::Escape("# VersionTag: $($item.CurrentTag)")
            $updated = $content -replace $escaped, "# VersionTag: $($item.ProposedTag)"

            if ($updated -eq $content) {
                # Try broader pattern
                $updated = $content -replace '(#\s*VersionTag:\s*)\S+', "`${1}$($item.ProposedTag)"
            }

            Set-Content -LiteralPath $item.FullPath -Value $updated -Encoding UTF8 -NoNewline
            $applied++
            $log += [PSCustomObject]@{
                File   = $item.RelPath
                Before = $item.CurrentTag
                After  = $item.ProposedTag
                Status = 'OK'
            }
        } catch {
            $failed++
            $log += [PSCustomObject]@{
                File   = $item.RelPath
                Before = $item.CurrentTag
                After  = $item.ProposedTag
                Status = "FAIL: $($_.Exception.Message)"
            }
        }
    }

    return @{ applied = $applied; failed = $failed; log = $log }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CROSS-VALIDATE: Compare file tags vs manifest
# ═══════════════════════════════════════════════════════════════════════════════

function Cross-Validate {
    param([string]$Root, [array]$Inventory)

    $manifestPath = Join-Path $Root 'config\agentic-manifest.json'
    $mismatches = @()
    $orphans    = @()

    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $manifestFiles = @{}

            # Collect module versions from manifest
            foreach ($m in @($manifest.modules)) {
                if ($m.path -and $m.version) {
                    $manifestFiles[$m.path.Replace('\\','\')] = $m.version
                }
            }

            # Compare
            foreach ($item in $Inventory) {
                $relNorm = $item.RelPath.Replace('/', '\')
                if ($manifestFiles.ContainsKey($relNorm)) {
                    $manifestVer = $manifestFiles[$relNorm]
                    if ($manifestVer -ne $item.CurrentTag) {
                        $mismatches += [PSCustomObject]@{
                            File         = $item.RelPath
                            FileTag      = $item.CurrentTag
                            ManifestTag  = $manifestVer
                            Status       = 'MISMATCH'
                        }
                    }
                }
            }

            # Find manifest entries with no matching file
            foreach ($path in $manifestFiles.Keys) {
                $fullPath = Join-Path $Root $path
                if (-not (Test-Path $fullPath)) {
                    $orphans += [PSCustomObject]@{
                        ManifestPath = $path
                        ManifestTag  = $manifestFiles[$path]
                        Status       = 'ORPHAN_IN_MANIFEST'
                    }
                }
            }
        } catch {
            Write-Warning "Manifest parse error: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Manifest not found at $manifestPath"
    }

    return @{ mismatches = $mismatches; orphans = $orphans; fileCount = @($Inventory).Count }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DISPLAY HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Show-SideBySide {
    param([array]$Plan, [string]$Title)

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $changed = @($Plan | Where-Object { $_.CurrentTag -ne $_.ProposedTag })
    $unchanged = @($Plan | Where-Object { $_.CurrentTag -eq $_.ProposedTag })

    if (@($changed).Count -gt 0) {
        Write-Host "  FILES THAT WILL CHANGE ($(@($changed).Count)):" -ForegroundColor Yellow
        $hdr = "  {0,-60} {1,-22} {2,-3} {3,-22}" -f 'File', 'Current', '', 'Proposed'
        Write-Host $hdr -ForegroundColor DarkGray
        Write-Host "  $('-' * 110)" -ForegroundColor DarkGray
        foreach ($c in $changed) {
            $short = if ($c.RelPath.Length -gt 58) { '...' + $c.RelPath.Substring($c.RelPath.Length - 55) } else { $c.RelPath }
            Write-Host ("  {0,-60} " -f $short) -NoNewline -ForegroundColor White
            Write-Host ("{0,-22}" -f $c.CurrentTag) -NoNewline -ForegroundColor Red
            Write-Host " -> " -NoNewline -ForegroundColor DarkGray
            Write-Host ("{0,-22}" -f $c.ProposedTag) -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "  Summary: $(@($changed).Count) changes, $(@($unchanged).Count) already correct" -ForegroundColor Cyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  PwShGUI Version Alignment Tool" -ForegroundColor Cyan
Write-Host "  Workspace: $WorkspacePath" -ForegroundColor DarkGray
Write-Host "  Target Build: $($script:CanonicalPrefix)" -ForegroundColor DarkGray
Write-Host ""

# Always scan first
$inventory = Get-AllVersionTags -Root $WorkspacePath
Write-Host "  Scanned $(@($inventory).Count) files with VersionTags" -ForegroundColor Gray

if ($ScanOnly -or (-not $SimulateMinor -and -not $ApplyMinor -and -not $SimulateMajor -and -not $ApplyMajor -and -not $CrossValidate)) {
    # Default: show current state
    $minorPlan = Compute-MinorCleanup -Inventory $inventory
    Show-SideBySide -Plan $minorPlan -Title "MINOR VERSION CLEANUP — Side-by-Side Preview"

    $stats = @{}
    foreach ($item in $inventory) {
        if ($item.HasTag) {
            $key = "$($item.Parsed.build).$($item.Parsed.vCase)"
            $stats[$key] = ($stats[$key] + 1)
        }
    }
    Write-Host "  Build/Case distribution:" -ForegroundColor Yellow
    foreach ($k in ($stats.Keys | Sort-Object)) {
        Write-Host "    $k : $($stats[$k]) files" -ForegroundColor Gray
    }
    Write-Host ""

    # Cross-validate
    $xv = Cross-Validate -Root $WorkspacePath -Inventory $inventory
    if (@($xv.mismatches).Count -gt 0) {
        Write-Host "  MANIFEST MISMATCHES ($(@($xv.mismatches).Count)):" -ForegroundColor Red
        foreach ($mm in $xv.mismatches) {
            Write-Host "    $($mm.File): file=$($mm.FileTag) manifest=$($mm.ManifestTag)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Manifest cross-check: no mismatches in mapped modules" -ForegroundColor Green
    }
    if (@($xv.orphans).Count -gt 0) {
        Write-Host "  ORPHAN MANIFEST ENTRIES ($(@($xv.orphans).Count)):" -ForegroundColor Red
        foreach ($o in $xv.orphans) {
            Write-Host "    $($o.ManifestPath) ($($o.ManifestTag))" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    return
}

if ($SimulateMinor) {
    $minorPlan = Compute-MinorCleanup -Inventory $inventory
    Show-SideBySide -Plan $minorPlan -Title "SIMULATE MINOR CLEANUP — Dry Run"
    Write-Host "  [DRY RUN] No files were modified." -ForegroundColor Yellow
    return
}

if ($ApplyMinor) {
    $minorPlan = Compute-MinorCleanup -Inventory $inventory
    Show-SideBySide -Plan $minorPlan -Title "APPLYING MINOR CLEANUP"
    $result = Apply-TagChanges -Plan $minorPlan -Mode 'minor'
    Write-Host "  Applied: $($result.applied) | Failed: $($result.failed)" -ForegroundColor $(if ($result.failed -gt 0) { 'Red' } else { 'Green' })
    foreach ($entry in $result.log) {
        $color = if ($entry.Status -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host "    [$($entry.Status)] $($entry.File): $($entry.Before) -> $($entry.After)" -ForegroundColor $color
    }
    Write-Host ""
    return
}

if ($SimulateMajor) {
    $majorResult = Compute-MajorAlignment -Inventory $inventory -TargetMajor $NewMajor
    Show-SideBySide -Plan $majorResult.plan -Title "SIMULATE MAJOR BUILD INCREMENT — V$($majorResult.targetMajor).0 (current highest: V$($majorResult.highestCurrent))"
    Write-Host "  [DRY RUN] No files were modified." -ForegroundColor Yellow
    Write-Host "  All $(@($majorResult.plan).Count) files would become: $($script:CanonicalPrefix).V$($majorResult.targetMajor).0" -ForegroundColor Cyan
    return
}

if ($ApplyMajor) {
    $majorResult = Compute-MajorAlignment -Inventory $inventory -TargetMajor $NewMajor
    Show-SideBySide -Plan $majorResult.plan -Title "APPLYING MAJOR BUILD INCREMENT — V$($majorResult.targetMajor).0"
    $result = Apply-TagChanges -Plan $majorResult.plan -Mode 'major'
    Write-Host "  Applied: $($result.applied) | Failed: $($result.failed)" -ForegroundColor $(if ($result.failed -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  New canonical tag: $($script:CanonicalPrefix).V$($majorResult.targetMajor).0" -ForegroundColor Cyan
    Write-Host ""
    return
}

if ($CrossValidate) {
    Write-Host "  Running post-change cross-validation..." -ForegroundColor Cyan
    $xv = Cross-Validate -Root $WorkspacePath -Inventory $inventory

    # Check all files share same build prefix
    $prefixes = @{}
    foreach ($item in $inventory) {
        if ($item.HasTag) {
            $key = "$($item.Parsed.ym).$($item.Parsed.build)"
            $prefixes[$key] = ($prefixes[$key] + 1)
        }
    }

    $caseMix = @($inventory | Where-Object { $_.HasTag -and $_.Parsed.vCase -ne 'V' })

    Write-Host ""
    Write-Host "  Cross-Validation Results:" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Total files scanned: $(@($inventory).Count)" -ForegroundColor White

    Write-Host "  Build prefix distribution:" -ForegroundColor White
    foreach ($k in ($prefixes.Keys | Sort-Object)) {
        $color = if (@($prefixes.Keys).Count -eq 1) { 'Green' } else { 'Yellow' }
        Write-Host "    $k : $($prefixes[$k]) files" -ForegroundColor $color
    }

    if (@($caseMix).Count -gt 0) {
        Write-Host "  CASE INCONSISTENCIES: $(@($caseMix).Count) files use lowercase 'v'" -ForegroundColor Red
        foreach ($cm in $caseMix) {
            Write-Host "    $($cm.RelPath): $($cm.CurrentTag)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Case consistency: ALL uppercase V" -ForegroundColor Green
    }

    if (@($xv.mismatches).Count -gt 0) {
        Write-Host "  Manifest mismatches: $(@($xv.mismatches).Count)" -ForegroundColor Red
        foreach ($mm in $xv.mismatches) {
            Write-Host "    $($mm.File): file=$($mm.FileTag) manifest=$($mm.ManifestTag)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Manifest alignment: PASS" -ForegroundColor Green
    }

    if (@($xv.orphans).Count -gt 0) {
        Write-Host "  Orphan manifest entries: $(@($xv.orphans).Count)" -ForegroundColor Yellow
    } else {
        Write-Host "  Orphan check: PASS" -ForegroundColor Green
    }

    Write-Host ""
    return
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




