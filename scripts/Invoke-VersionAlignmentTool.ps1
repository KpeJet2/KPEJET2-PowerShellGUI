# VersionTag: 2605.B5.V46.0
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
    [string]$WorkspacePath,
    [switch]$ScanOnly,
    [switch]$SimulateMinor,
    [switch]$ApplyMinor,
    [switch]$SimulateMajor,
    [switch]$ApplyMajor,
    [switch]$CrossValidate,
    [switch]$Interactive,
    # Optional overrides; when omitted the tool derives them from the highest
    # VersionTag found on disk (single source of truth).
    [string]$YearMonth,
    [string]$TargetBuild,
    [int]$NewMajor = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve workspace root (param default cannot reference $PSScriptRoot reliably under -File invocation)
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $WorkspacePath = Split-Path -Parent $scriptDir
}

# ===============================================================================
#  CONSTANTS
# ===============================================================================

# Initial defaults; superseded by Get-HighestOnDiskTag once inventory is scanned.
$script:YearMonth       = if ($PSBoundParameters.ContainsKey('YearMonth') -and $YearMonth) { $YearMonth } else { (Get-Date).ToString('yyMM') }
$script:CanonicalPrefix = "$($script:YearMonth).$(if ($TargetBuild) { $TargetBuild } else { 'B0' })"
$script:VersionRegex    = '(?m)^#\s*VersionTag:\s*(\S+)'
$script:ExcludePattern  = '\\\.git\\|\\\.history\\|\\node_modules\\|\\__pycache__|\\checkpoints\\|\\~REPORTS\\|\\~DOWNLOADS\\|\\\.venv'

# ===============================================================================
#  HELPER: Parse tag
# ===============================================================================

function Parse-Tag {
    param([string]$Tag)
    if ($Tag -match '^(\d{4})\.(B\d+)\.[Vv](\d+)(?:\.(\d+))?$') {
        return @{
            ym     = $Matches[1]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            build  = $Matches[2]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            major  = [int]$Matches[3]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            minor  = if ($null -ne $Matches[4] -and $Matches[4] -ne '') { [int]$Matches[4] } else { 0 }  # SIN-EXEMPT:P027 -- index access, context-verified safe
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

function Get-HighestOnDiskTag {
    <#
    .SYNOPSIS
        Returns the highest VersionTag in the inventory ordered by
        (YearMonth, B, VMajor, VMinor). Single source of truth used to
        seed proposals -- not the previously hardcoded '2604' constant.
    #>
    param([array]$Inventory)
    $tagged = @($Inventory | Where-Object { $_.HasTag })
    if ($tagged.Count -eq 0) { return $null }
    $sorted = $tagged | Sort-Object `
        @{Expression={[int]$_.Parsed.ym};Descending=$true}, `
        @{Expression={[int]($_.Parsed.build -replace '[^0-9]','')};Descending=$true}, `
        @{Expression={$_.Parsed.major};Descending=$true}, `
        @{Expression={$_.Parsed.minor};Descending=$true}
    return $sorted[0].Parsed  # SIN-EXEMPT:P027 -- index access, context-verified safe
}

function Read-DefaultedInput {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string]$Default
    )
    $resp = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($resp)) { return $Default }
    return $resp.Trim()
}

function Invoke-InteractivePrompt {
    <#
    .SYNOPSIS
        Walks the user through YYMM / B# / V## / Minor with sensible defaults
        derived from the highest tag found on disk. ENTER accepts the default
        for each segment; any explicit value overrides.
    #>
    param([array]$Inventory)
    $highest = Get-HighestOnDiskTag -Inventory $Inventory
    $currentYM = (Get-Date).ToString('yyMM')

    if ($highest) {
        $defYM    = if ([int]$currentYM -gt [int]$highest.ym) { $currentYM } else { $highest.ym }
        $defBuild = $highest.build
        $defVMaj  = $highest.major + 1
        $defVMin  = 0
        Write-Host ""
        Write-Host "  Highest on disk : $($highest.ym).$($highest.build).V$($highest.major).$($highest.minor)" -ForegroundColor Cyan
    } else {
        $defYM    = $currentYM
        $defBuild = 'B0'
        $defVMaj  = 1
        $defVMin  = 0
        Write-Host "  No existing tags found; using fresh defaults." -ForegroundColor Yellow
    }
    Write-Host "  Press ENTER to accept the proposed default for each segment." -ForegroundColor DarkGray
    Write-Host ""

    $ym = Read-DefaultedInput -Prompt '  YEAR-MONTH (YYMM)' -Default $defYM
    while ($ym -notmatch '^\d{4}$') {
        Write-Host "    Invalid -- must be 4 digits (e.g. $currentYM)" -ForegroundColor Red
        $ym = Read-DefaultedInput -Prompt '  YEAR-MONTH (YYMM)' -Default $defYM
    }

    $build = Read-DefaultedInput -Prompt '  BUILD (B#)' -Default $defBuild
    if ($build -match '^\d+$') { $build = "B$build" }
    while ($build -notmatch '^[Bb]\d+$') {
        Write-Host "    Invalid -- must be B followed by digits (e.g. B2)" -ForegroundColor Red
        $build = Read-DefaultedInput -Prompt '  BUILD (B#)' -Default $defBuild
        if ($build -match '^\d+$') { $build = "B$build" }
    }
    $build = 'B' + ($build -replace '[^0-9]','')

    $vMajRaw = Read-DefaultedInput -Prompt '  MAJOR VERSION (V##)' -Default ([string]$defVMaj)
    $vMaj = 0
    while (-not [int]::TryParse(($vMajRaw -replace '[^0-9]',''), [ref]$vMaj)) {
        Write-Host "    Invalid -- must be a number" -ForegroundColor Red
        $vMajRaw = Read-DefaultedInput -Prompt '  MAJOR VERSION (V##)' -Default ([string]$defVMaj)
    }

    $vMinRaw = Read-DefaultedInput -Prompt '  MINOR VERSION (.#)' -Default ([string]$defVMin)
    $vMin = 0
    while (-not [int]::TryParse(($vMinRaw -replace '[^0-9]',''), [ref]$vMin)) {
        Write-Host "    Invalid -- must be a number" -ForegroundColor Red
        $vMinRaw = Read-DefaultedInput -Prompt '  MINOR VERSION (.#)' -Default ([string]$defVMin)
    }

    $proposed = "$ym.$build.V$vMaj.$vMin"
    Write-Host ""
    Write-Host "  Resulting target tag: $proposed" -ForegroundColor Green
    return @{
        YearMonth = $ym
        Build     = $build
        VMajor    = $vMaj
        VMinor    = $vMin
        Tag       = $proposed
        Highest   = $highest
    }
}

# ===============================================================================
#  SCAN: Collect all VersionTags
# ===============================================================================

function Get-AllVersionTags {
    param([string]$Root)
    $files = Get-ChildItem -Path $Root -Recurse -File -Include '*.ps1','*.psm1','*.psd1' -ErrorAction SilentlyContinue |
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

# ===============================================================================
#  MINOR CLEANUP: Normalise case, build prefix, preserve major.minor values
# ===============================================================================

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
        if ($p.vCase -ne 'V')                                  { $changeReasons += 'case V->uppercase' }
        if ($p.build -ne $TargetBuild)                          { $changeReasons += "build $($p.build)->$TargetBuild" }
        if ("$($p.ym)" -ne $script:YearMonth)                  { $changeReasons += "yearmonth $($p.ym)->$($script:YearMonth)" }
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

# ===============================================================================
#  MAJOR ALIGNMENT: Increment major, reset minor to 0
# ===============================================================================

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

# ===============================================================================
#  APPLY: Write tags to files
# ===============================================================================

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

# ===============================================================================
#  CROSS-VALIDATE: Compare file tags vs manifest
# ===============================================================================

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
                    $manifestVer = $manifestFiles[$relNorm]  # SIN-EXEMPT:P027 -- index access, context-verified safe
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
                        ManifestTag  = $manifestFiles[$path]  # SIN-EXEMPT:P027 -- index access, context-verified safe
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

# ===============================================================================
#  DISPLAY HELPERS
# ===============================================================================

function Show-SideBySide {
    param([array]$Plan, [string]$Title)

    Write-Host ""
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "===========================================================" -ForegroundColor Cyan
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

# ===============================================================================
#  MAIN EXECUTION
# ===============================================================================

Write-Host ""
Write-Host "  PwShGUI Version Alignment Tool" -ForegroundColor Cyan
Write-Host "  Workspace: $WorkspacePath" -ForegroundColor DarkGray

# Always scan first
$inventory = Get-AllVersionTags -Root $WorkspacePath
Write-Host "  Scanned $(@($inventory).Count) files with VersionTags" -ForegroundColor Gray

# Single source of truth: derive YearMonth + TargetBuild from the highest tag
# actually present on disk (unless explicitly overridden via parameters).
$onDiskHighest = Get-HighestOnDiskTag -Inventory $inventory
if ($onDiskHighest) {
    if (-not $PSBoundParameters.ContainsKey('YearMonth') -or [string]::IsNullOrWhiteSpace($YearMonth)) {
        $script:YearMonth = $onDiskHighest.ym
    }
    if (-not $PSBoundParameters.ContainsKey('TargetBuild') -or [string]::IsNullOrWhiteSpace($TargetBuild)) {
        $TargetBuild = $onDiskHighest.build
    }
}
$script:CanonicalPrefix = "$($script:YearMonth).$TargetBuild"
$proposedNextMajor = if ($onDiskHighest) { $onDiskHighest.major + 1 } else { 1 }
$proposedNextTag   = if ($onDiskHighest) {
    "$($onDiskHighest.ym).$($onDiskHighest.build).V$($onDiskHighest.major).$($onDiskHighest.minor + 1)"
} else { "$($script:YearMonth).B0.V1.0" }

Write-Host "  Target Build  : $($script:CanonicalPrefix)" -ForegroundColor DarkGray
if ($onDiskHighest) {
    Write-Host "  Highest on disk: $($onDiskHighest.ym).$($onDiskHighest.build).V$($onDiskHighest.major).$($onDiskHighest.minor)" -ForegroundColor Cyan
    Write-Host "  Proposed next  : $proposedNextTag  (or major bump -> $($script:CanonicalPrefix).V$proposedNextMajor.0)" -ForegroundColor Cyan
} else {
    Write-Host "  Highest on disk: (none found)" -ForegroundColor Yellow
}
Write-Host ""

# Interactive mode: prompt the user for each segment with on-disk-derived defaults,
# then feed the resulting values into the major-alignment plan as the new canonical tag.
if ($Interactive) {
    $chosen = Invoke-InteractivePrompt -Inventory $inventory
    $script:YearMonth       = $chosen.YearMonth
    $TargetBuild            = $chosen.Build
    $script:CanonicalPrefix = "$($script:YearMonth).$TargetBuild"
    $NewMajor               = $chosen.VMajor
    $confirm = Read-DefaultedInput -Prompt '  Apply this tag to ALL files? (Y/N)' -Default 'N'
    if ($confirm -match '^[Yy]') {
        $majorResult = Compute-MajorAlignment -Inventory $inventory -TargetMajor $NewMajor
        # Override the minor portion to honour the user's chosen MINOR value
        foreach ($p in $majorResult.plan) {
            $p.ProposedTag = Format-Tag -YM $script:YearMonth -Build $TargetBuild -Major $NewMajor -Minor $chosen.VMinor
            $p.NewMinor    = $chosen.VMinor
        }
        Show-SideBySide -Plan $majorResult.plan -Title "INTERACTIVE APPLY -> $($chosen.Tag)"
        $result = Apply-TagChanges -Plan $majorResult.plan -Mode 'major'
        Write-Host "  Applied: $($result.applied) | Failed: $($result.failed)" -ForegroundColor $(if ($result.failed -gt 0) { 'Red' } else { 'Green' })
        Write-Host "  New canonical tag: $($chosen.Tag)" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host "  Aborted by user (no files modified)." -ForegroundColor Yellow
    }
    return
}

if ($ScanOnly -or (-not $SimulateMinor -and -not $ApplyMinor -and -not $SimulateMajor -and -not $ApplyMajor -and -not $CrossValidate)) {
    # Default: show current state
    $minorPlan = Compute-MinorCleanup -Inventory $inventory
    Show-SideBySide -Plan $minorPlan -Title "MINOR VERSION CLEANUP - Side-by-Side Preview"

    $stats = @{}
    foreach ($item in $inventory) {
        if ($item.HasTag) {
            $key = "$($item.Parsed.build).$($item.Parsed.vCase)"
            $stats[$key] = ($stats[$key] + 1)  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
    }
    Write-Host "  Build/Case distribution:" -ForegroundColor Yellow
    foreach ($k in ($stats.Keys | Sort-Object)) {
        Write-Host "    $k : $($stats[$k]) files" -ForegroundColor Gray  # SIN-EXEMPT:P027 -- index access, context-verified safe
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
    Show-SideBySide -Plan $minorPlan -Title "SIMULATE MINOR CLEANUP - Dry Run"
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
    Show-SideBySide -Plan $majorResult.plan -Title "SIMULATE MAJOR BUILD INCREMENT - V$($majorResult.targetMajor).0 (current highest: V$($majorResult.highestCurrent))"
    Write-Host "  [DRY RUN] No files were modified." -ForegroundColor Yellow
    Write-Host "  All $(@($majorResult.plan).Count) files would become: $($script:CanonicalPrefix).V$($majorResult.targetMajor).0" -ForegroundColor Cyan
    return
}

if ($ApplyMajor) {
    $majorResult = Compute-MajorAlignment -Inventory $inventory -TargetMajor $NewMajor
    Show-SideBySide -Plan $majorResult.plan -Title "APPLYING MAJOR BUILD INCREMENT - V$($majorResult.targetMajor).0"
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
            $prefixes[$key] = ($prefixes[$key] + 1)  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }
    }

    $caseMix = @($inventory | Where-Object { $_.HasTag -and $_.Parsed.vCase -ne 'V' })

    Write-Host ""
    Write-Host "  Cross-Validation Results:" -ForegroundColor Cyan
    Write-Host "  -------------------------" -ForegroundColor DarkGray
    Write-Host "  Total files scanned: $(@($inventory).Count)" -ForegroundColor White

    Write-Host "  Build prefix distribution:" -ForegroundColor White
    foreach ($k in ($prefixes.Keys | Sort-Object)) {
        $color = if (@($prefixes.Keys).Count -eq 1) { 'Green' } else { 'Yellow' }
        Write-Host "    $k : $($prefixes[$k]) files" -ForegroundColor $color  # SIN-EXEMPT:P027 -- index access, context-verified safe
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






