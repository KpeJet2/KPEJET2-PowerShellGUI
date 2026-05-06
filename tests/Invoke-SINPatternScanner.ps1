# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    SIN Pattern Scanner -- scans workspace PS files against all SIN-PATTERN-*.json definitions.
.DESCRIPTION
    Loads every SIN-PATTERN-*.json from sin_registry/, reads the scan_regex field, and
    runs it against all *.ps1 and *.psm1 files in the workspace. Suppresses false positives
    via file_exclusion_regex (skip whole file) and context_guard_regex (skip if guard appears
    within context_guard_lines above the match). Skips full comment lines and SIN-EXEMPT: markers.

    Returns a summary object and writes JSON to $OutputJson (default: temp/sin-scan-results.json).
    With -FailOnCritical, exits with code 1 if any CRITICAL findings are detected.

    NOTE: Output is ALWAYS written to $OutputJson. The script NEVER overwrites itself.

    RUNTIME TARGETING:
    Use -Runtime to specify the target PowerShell version for the code being scanned.
    - PS51 : Flag all patterns including PS5.1-only compatibility patterns (P005, P018, P024)
    - PS7  : Skip patterns whose ps_version_scope='PS51' (they are valid in PS7.6 target code)
    - Both : (default) Flag all patterns regardless of version scope
    This project targets PS7.6 as the optimal runtime (PwShGUI-PSVersionStandards.psm1). When
    scanning code written exclusively for PS7.6, use -Runtime PS7 to eliminate false positives.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Default: parent of script directory.
.PARAMETER OutputJson
    Path for JSON results output. Default: <WorkspacePath>\temp\sin-scan-results.json
.PARAMETER Quiet
    Suppress all console output.
.PARAMETER FailOnCritical
    Exit 1 if any CRITICAL-severity findings are found (pipeline gate).
.PARAMETER FailOnSinId
    Exit 1 if any findings match one of the supplied SIN IDs or ID fragments.
.PARAMETER IncludeFiles
    Optional explicit file list to scan instead of workspace discovery. Paths may be
    absolute or relative to WorkspacePath.
.PARAMETER TargetPattern
    Optional string to filter which SIN-PATTERN IDs are loaded (substring match on sin_id).
.PARAMETER Runtime
    Target runtime: PS51 | PS7 | Both. Controls which ps_version_scope patterns are included.
    Default: Both (all patterns). Use PS7 when scanning code targeting PowerShell 7.6+
.PARAMETER OutputJson
    Path for JSON results output. Default: <WorkspacePath>\temp\sin-scan-results.json
.PARAMETER Quiet
    Suppress all console output.
.PARAMETER FailOnCritical
    Exit 1 if any CRITICAL-severity findings are found (pipeline gate).
.PARAMETER TargetPattern,
    [ValidateSet('PS51','PS7','Both')]
    [string]$Runtime       = 'Both'
    Optional string to filter which SIN-PATTERN IDs are loaded (substring match on sin_id).
.PARAMETER Runtime
    Target runtime: PS51 | PS7 | Both. Controls which ps_version_scope patterns are included.
    Default: Both (all patterns). Use PS7 when scanning code targeting PowerShell 7.6+.
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputJson    = '',
    [switch]$Quiet,
    [switch]$FailOnCritical,
    [string[]]$FailOnSinId = @(),
    [string[]]$IncludeFiles = @(),
    [string]$TargetPattern = '*',
    [ValidateSet('PS51','PS7','Both')]
    [string]$Runtime       = 'Both',
    # Additional file extensions to discover/scan beyond the default *.ps1/*.psm1.
    # Per-pattern routing still respects each definition's scan_file_pattern field.
    [string[]]$ExtraExtensions = @(),
    # Path to a JSON baseline of accepted SIN counts per sin_id.
    # When supplied, -FailOnCritical only blocks on REGRESSIONS (current count > baseline count for any SIN).
    # Use -UpdateBaseline to overwrite the file with current counts (ratchet down).
    [string]$BaselineJson  = '',
    [switch]$UpdateBaseline,
    # Ratchet enforcement mode (only meaningful with -BaselineJson + -FailOnCritical):
    #   Off        - ignore baseline; -FailOnCritical blocks on any CRITICAL finding
    #   Permissive - default; block only on regressions (current > baseline)
    #   Strict     - block on any drift (regressions OR un-recorded improvements);
    #                forces team to refresh baseline after every fix
    [ValidateSet('Off','Permissive','Strict')]
    [string]$RatchetMode = 'Permissive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sw     = [System.Diagnostics.Stopwatch]::StartNew()
$scanId = "SINSCAN-$(Get-Date -Format 'yyyyMMddHHmmss')"

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-results.json'
}

# Safety guard: never write to ourselves
if ($OutputJson -eq $PSCommandPath) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-results.json'
}

$tempDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir -Force }

function Write-ScanLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

function Test-SinIdMatch {
    param(
        [string]$FindingSinId,
        [string]$TargetId
    )

    if ([string]::IsNullOrWhiteSpace($FindingSinId) -or [string]::IsNullOrWhiteSpace($TargetId)) {
        return $false
    }

    if ($FindingSinId -like "*$TargetId*") {
        return $true
    }

    if ($TargetId -match '^[Pp]0*(\d+)$') {
        return ($FindingSinId -match ('SIN-PATTERN-0*{0}(?:\D|$)' -f $Matches[1]))
    }

    return $false
}

# ---- Load SIN-PATTERN definitions -----------------------------------------
$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
if (-not (Test-Path $sinRegistryDir)) {
    Write-ScanLog "[ERROR] sin_registry/ not found at: $sinRegistryDir" 'Red'
    exit 1
}

$patternFiles = @(Get-ChildItem -Path $sinRegistryDir -Filter 'SIN-PATTERN-*.json' -File -ErrorAction SilentlyContinue)
$patterns = New-Object System.Collections.Generic.List[object]

foreach ($pf in $patternFiles) {
    try {
        $json = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8
        $def  = $json | ConvertFrom-Json
        $props = $def.PSObject.Properties.Name

        if ($TargetPattern -ne '*' -and -not ($def.sin_id -like "*$TargetPattern*")) { continue }

        if (-not ($props -contains 'scan_regex') -or [string]::IsNullOrWhiteSpace($def.scan_regex)) { continue }

        try { $null = [regex]::new($def.scan_regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        catch {
            Write-ScanLog "  [WARN] Invalid scan_regex in $($pf.Name): $_" 'Yellow'
            continue
        }

        # Determine version scope and filter against -Runtime
        $scope = if ($props -contains 'ps_version_scope') { "$($def.ps_version_scope)" } else { 'BOTH' }
        if ($Runtime -eq 'PS7'  -and $scope -eq 'PS51') { continue }   # PS5.1-only pattern - skip for PS7 target
        if ($Runtime -eq 'PS51' -and $scope -eq 'PS7')  { continue }   # PS7-only pattern - skip for PS5.1 target

        $p = [ordered]@{
            SinId             = "$($def.sin_id)"
            Severity          = if ($props -contains 'severity') { "$($def.severity)" } else { 'MEDIUM' }
            Title             = if ($props -contains 'title')    { "$($def.title)" }    else { "$($def.sin_id)" }
            ScanRegex         = "$($def.scan_regex)"
            Scope             = $scope
            FileExcludeRegex  = if ($props -contains 'file_exclusion_regex' -and $null -ne $def.file_exclusion_regex) { "$($def.file_exclusion_regex)" } else { $null }
            ContextGuardRegex = if ($props -contains 'context_guard_regex'  -and $null -ne $def.context_guard_regex)  { "$($def.context_guard_regex)"  } else { $null }
            InlineGuardRegex  = if ($props -contains 'inline_guard_regex'   -and $null -ne $def.inline_guard_regex)   { "$($def.inline_guard_regex)"   } else { $null }
            ContextGuardLines = if ($props -contains 'context_guard_lines') { [int]$def.context_guard_lines } else { 0 }
            ContextGuardDirection = if ($props -contains 'context_guard_direction' -and $null -ne $def.context_guard_direction) { "$($def.context_guard_direction)" } else { 'above' }
            ScanFilePattern   = if ($props -contains 'scan_file_pattern' -and -not [string]::IsNullOrWhiteSpace("$($def.scan_file_pattern)")) { "$($def.scan_file_pattern)" } else { $null }
        }
        $patterns.Add($p)
    } catch {
        Write-ScanLog "  [WARN] Failed to parse $($pf.Name): $_" 'Yellow'
    }
}

Write-ScanLog "SIN Pattern Scanner  [$scanId]" 'Cyan'
Write-ScanLog "Workspace : $WorkspacePath"
Write-ScanLog "Runtime   : $Runtime  (PS7-only patterns $(if ($Runtime -eq 'PS7') { 'SKIPPED' } elseif ($Runtime -eq 'PS51') { 'ONLY' } else { 'INCLUDED' }))"
Write-ScanLog "Patterns  : $($patterns.Count) loaded from $($patternFiles.Count) files"
Write-ScanLog ('-' * 60)

# ---- File discovery --------------------------------------------------------
$excludeDirs = @('.git','.history','.venv','.venv-pygame312','node_modules',
                 '~DOWNLOADS','~REPORTS','checkpoints','UPM','sin_registry',
                 'QUICK-APP','ActionPacks-master','temp')

# Normalize ExtraExtensions to lowercase with leading dot (e.g. '.bat').
# Tolerate CLI quirk where '.bat,.xhtml' arrives as a single string by splitting on comma/semicolon.
$normalizedExtras = @()
foreach ($raw in $ExtraExtensions) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    foreach ($ex in ($raw -split '[,;]')) {
        if ([string]::IsNullOrWhiteSpace($ex)) { continue }
        $clean = $ex.Trim().ToLowerInvariant().TrimStart('*')
        if (-not $clean.StartsWith('.')) { $clean = '.' + $clean }
        $normalizedExtras += $clean
    }
}
$allowedExts = @('.ps1','.psm1') + $normalizedExtras | Select-Object -Unique
Write-ScanLog ("Allowed exts : " + ($allowedExts -join ', ')) 'Cyan'

$allFiles = New-Object System.Collections.Generic.List[object]
if (@($IncludeFiles).Count -gt 0) {
    foreach ($inc in $IncludeFiles) {
        $path = if ([System.IO.Path]::IsPathRooted($inc)) { $inc } else { Join-Path $WorkspacePath $inc }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer) { continue }
        if ($item.Extension.ToLowerInvariant() -notin $allowedExts) { continue }
        if (-not (@($allFiles | Where-Object { $_.FullName -eq $item.FullName }).Count -gt 0)) {
            $allFiles.Add($item)
        }
    }
} else {
    $globs = @('*.ps1','*.psm1') + ($normalizedExtras | ForEach-Object { '*' + $_ })
    foreach ($ext in ($globs | Select-Object -Unique)) {
        $found = Get-ChildItem -Path $WorkspacePath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $skip = $false
            foreach ($d in $excludeDirs) {
                if ($f.FullName -like "*\$d\*") { $skip = $true; break }
            }
            if (-not $skip) { $allFiles.Add($f) }
        }
    }
}

# Helper: does a file extension match a SIN pattern's scan_file_pattern (semicolon-delimited globs)?
function Test-PatternFileMatch {
    param([string]$FullName, [string]$ScanFilePattern)
    if ([string]::IsNullOrWhiteSpace($ScanFilePattern)) { return $true }
    $globs = $ScanFilePattern -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($g in $globs) {
        $g = $g.Trim()
        if ($g -like '*/*' -or $g -like '*\*') {
            # Path-relative glob (e.g. 'tests/Foo.ps1' or 'config/*.json')
            if ($FullName -like "*$($g.Replace('/','\'))*") { return $true }
        } else {
            $leaf = [System.IO.Path]::GetFileName($FullName)
            if ($leaf -like $g) { return $true }
        }
    }
    return $false
}

Write-ScanLog "Files to scan: $($allFiles.Count)"
$extBreakdown = $allFiles | Group-Object Extension | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-ScanLog ("  By extension: " + ($extBreakdown -join ', '))

# ---- Scan ------------------------------------------------------------------
$findings       = New-Object System.Collections.Generic.List[object]
$patternSummary = New-Object System.Collections.Generic.List[object]
$totalRawMatches = 0
$totalSuppressed = 0

foreach ($pat in $patterns) {

    # -- Special binary/size scan logic for BINARY_CHECK / FILE_SIZE_CHECK patterns --
    if ($pat.ScanRegex -eq 'BINARY_CHECK') {
        $patRaw = 0; $patSupp = 0; $patFinds = 0
        foreach ($file in $allFiles) {
            if (-not (Test-PatternFileMatch -FullName $file.FullName -ScanFilePattern $pat.ScanFilePattern)) { continue }
            $bytes = $null
            try { $bytes = [System.IO.File]::ReadAllBytes($file.FullName) } catch { continue }
            if ($null -eq $bytes -or $bytes.Length -eq 0) { continue }
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

            # P006: any non-ASCII byte present but no BOM
            if ($pat.SinId -like '*006*') {
                $hasNonAscii = $false
                foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }
                if ($hasNonAscii -and -not $hasBom) {
                    $relPath = $file.FullName.Replace($WorkspacePath,'').TrimStart('\')
                    $findings.Add([ordered]@{ sinId=$pat.SinId; severity=$pat.Severity; title=$pat.Title; file=$relPath; line=1; content='[NO BOM but non-ASCII bytes detected]' })
                    $patFinds++; $patRaw++; $totalRawMatches++
                }
            }
            # P023: double-encoded UTF-8 BOM (C3 AF C2 BB C2 BF) or mojibake marker (C3 A2 E2 80)
            if ($pat.SinId -like '*023*') {
                $doubleBom = $false
                if ($bytes.Length -ge 6 -and $bytes[0] -eq 0xC3 -and $bytes[1] -eq 0xAF -and $bytes[2] -eq 0xC2 -and $bytes[3] -eq 0xBB -and $bytes[4] -eq 0xC2 -and $bytes[5] -eq 0xBF) { $doubleBom = $true }
                $mojibake = $false
                for ($bi = 0; $bi -lt ($bytes.Length - 3); $bi++) {
                    if ($bytes[$bi] -eq 0xC3 -and $bytes[$bi+1] -eq 0xA2 -and $bytes[$bi+2] -eq 0xE2 -and $bytes[$bi+3] -eq 0x80) { $mojibake = $true; break }
                }
                if ($doubleBom -or $mojibake) {
                    $relPath = $file.FullName.Replace($WorkspacePath,'').TrimStart('\')
                    $kind = if ($doubleBom) { '[Double-encoded BOM detected]' } else { '[Mojibake byte sequence C3 A2 E2 80 detected]' }
                    $findings.Add([ordered]@{ sinId=$pat.SinId; severity=$pat.Severity; title=$pat.Title; file=$relPath; line=1; content=$kind })
                    $patFinds++; $patRaw++; $totalRawMatches++
                }
            }
        }
        $patternSummary.Add([ordered]@{ sinId=$pat.SinId; severity=$pat.Severity; rawMatches=$patRaw; suppressed=$patSupp; findings=$patFinds })
        continue
    }

    if ($pat.ScanRegex -eq 'FILE_SIZE_CHECK') {
        $patRaw = 0; $patSupp = 0; $patFinds = 0
        $sizeLimitBytes = 5 * 1024 * 1024  # 5 MB
        foreach ($file in $allFiles) {
            if (-not (Test-PatternFileMatch -FullName $file.FullName -ScanFilePattern $pat.ScanFilePattern)) { continue }
            if ($file.Length -gt $sizeLimitBytes) {
                $relPath = $file.FullName.Replace($WorkspacePath,'').TrimStart('\')
                $sizeMB  = [math]::Round($file.Length / 1MB, 2)
                $findings.Add([ordered]@{ sinId=$pat.SinId; severity=$pat.Severity; title=$pat.Title; file=$relPath; line=1; content="[File size ${sizeMB}MB exceeds 5MB limit]" })
                $patFinds++; $patRaw++; $totalRawMatches++
            }
        }
        $patternSummary.Add([ordered]@{ sinId=$pat.SinId; severity=$pat.Severity; rawMatches=$patRaw; suppressed=$patSupp; findings=$patFinds })
        continue
    }
    # -- End special scan logic --

    $compiledScan    = [regex]::new($pat.ScanRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $compiledExclude = if ($null -ne $pat.FileExcludeRegex)  { [regex]::new($pat.FileExcludeRegex,  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } else { $null }
    $compiledGuard   = if ($null -ne $pat.ContextGuardRegex) { [regex]::new($pat.ContextGuardRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } else { $null }
    $compiledInlineGuard = if ($null -ne $pat.InlineGuardRegex) { [regex]::new($pat.InlineGuardRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } else { $null }

    $patRaw   = 0
    $patSupp  = 0
    $patFinds = 0

    foreach ($file in $allFiles) {
        if (-not (Test-PatternFileMatch -FullName $file.FullName -ScanFilePattern $pat.ScanFilePattern)) { continue }
        if ($null -ne $compiledExclude -and $compiledExclude.IsMatch($file.FullName)) { continue }

        $lineArr = $null
        try { $lineArr = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop) }
        catch { continue }
        if ($null -eq $lineArr) { continue }
        $lineCount = $lineArr.Count

        $inBlockComment  = $false
        $inHereStringDQ  = $false
        $inHereStringSQ  = $false

        for ($i = 0; $i -lt $lineCount; $i++) {
            $line = $lineArr[$i]
            if ([string]::IsNullOrWhiteSpace($line))    { continue }

            # -- Track multi-line context (block comments + here-strings) --
            if ($inBlockComment) {
                if ($line -match '#>') { $inBlockComment = $false }
                continue  # always skip block-comment body lines (incl. closing #>)
            }
            if ($inHereStringDQ) {
                if ($line -match '^"@') { $inHereStringDQ = $false }
                continue
            }
            if ($inHereStringSQ) {
                if ($line -match "^'@") { $inHereStringSQ = $false }
                continue
            }
            # Block-comment opener: <# ... #> same-line or multi-line
            if ($line -match '<#') {
                if ($line -notmatch '#>') { $inBlockComment = $true }
                continue  # skip the opener line itself in both cases
            }
            # Here-string openers (must start with @" or @' at end of line)
            if ($line -match '@"') { $inHereStringDQ = $true; continue }
            if ($line -match "@'") { $inHereStringSQ = $true; continue }

            if ($line -match '^\s*#')                   { continue }
            if ($line -match '#\s*SIN-EXEMPT:')         { continue }

            if (-not $compiledScan.IsMatch($line)) { continue }
            $totalRawMatches++
            $patRaw++

            $suppressed = $false
            if ($null -ne $compiledInlineGuard -and $compiledInlineGuard.IsMatch($line)) {
                $suppressed = $true
            }
            if ($null -ne $compiledGuard) {
                if ($pat.ContextGuardLines -eq 0) {
                    # ContextGuardLines=0 means same-line guard: suppress if the guard regex
                    # also matches the current line (e.g. TODO inside a string literal)
                    if ($compiledGuard.IsMatch($line)) { $suppressed = $true }
                } else {
                    $guardDirection = "$($pat.ContextGuardDirection)".ToLowerInvariant()
                    switch ($guardDirection) {
                        'below' {
                            $gStart = [Math]::Min($lineCount - 1, $i + 1)
                            $gEnd   = [Math]::Min($lineCount - 1, $i + $pat.ContextGuardLines)
                        }
                        'both' {
                            $gStart = [Math]::Max(0, $i - $pat.ContextGuardLines)
                            $gEnd   = [Math]::Min($lineCount - 1, $i + $pat.ContextGuardLines)
                        }
                        default {
                            $gStart = [Math]::Max(0, $i - $pat.ContextGuardLines)
                            $gEnd   = [Math]::Max(0, $i - 1)
                        }
                    }
                    for ($g = $gStart; $g -le $gEnd; $g++) {
                        if ($compiledGuard.IsMatch($lineArr[$g])) { $suppressed = $true; break }
                    }
                }
            }

            if ($suppressed) { $totalSuppressed++; $patSupp++; continue }

            $trimmed = $line.Trim()
            $snip    = $trimmed.Substring(0, [Math]::Min(160, $trimmed.Length))
            $relPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\')

            $findings.Add([ordered]@{
                sinId    = $pat.SinId
                severity = $pat.Severity
                title    = $pat.Title
                file     = $relPath
                line     = ($i + 1)
                content  = $snip
            })
            $patFinds++
        }
    }

    $patternSummary.Add([ordered]@{
        sinId      = $pat.SinId
        severity   = $pat.Severity
        rawMatches = $patRaw
        suppressed = $patSupp
        findings   = $patFinds
    })
}

# ---- P011 cross-file deduplication -----------------------------------------
# P011 scan_logic requires seeing a function name in 2+ different files to flag it.
# The line-by-line scanner collects all function definitions; here we filter to true dups.
$p011SinId = 'SIN-PATTERN-011-DUPLICATE-FUNCTION-DEF_202604042257'
$p011Findings = @($findings | Where-Object { $_.sinId -eq $p011SinId })
if (@($p011Findings).Count -gt 0) {
    $funcRx = [regex]::new('^\s*function\s+([\w-]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    # Build map: funcName -> list of unique files
    $funcFiles = @{}
    foreach ($f in $p011Findings) {
        $m = $funcRx.Match($f.content)
        if ($m.Success) {
            $name = $m.Groups[1].Value.ToLower()
            if (-not $funcFiles.ContainsKey($name)) { $funcFiles[$name] = [System.Collections.Generic.HashSet[string]]::new() }
            [void]$funcFiles[$name].Add($f.file)
        }
    }
    # Remove findings for function names that only appear in one file (not real dups)
    $suppressed = 0
    $toRemove = New-Object System.Collections.Generic.List[object]
    foreach ($f in $p011Findings) {
        $m = $funcRx.Match($f.content)
        $name = if ($m.Success) { $m.Groups[1].Value.ToLower() } else { $null }
        if ($null -eq $name -or $funcFiles[$name].Count -lt 2) {
            $toRemove.Add($f); $suppressed++
        }
    }
    foreach ($r in $toRemove) { [void]$findings.Remove($r) }
    $totalSuppressed += $suppressed
    Write-ScanLog "P011 post-filter: $suppressed single-file function defs suppressed; $(@($findings | Where-Object { $_.sinId -eq $p011SinId }).Count) real cross-file dups remain"
}
# ---- End P011 dedup --------------------------------------------------------

$sw.Stop()

$critCount = @($findings | Where-Object { $_.severity -eq 'CRITICAL' }).Count
$highCount = @($findings | Where-Object { $_.severity -eq 'HIGH'     }).Count
$medCount  = @($findings | Where-Object { $_.severity -eq 'MEDIUM'   }).Count
$lowCount  = @($findings | Where-Object { $_.severity -eq 'LOW'      }).Count
$blockedById = [ordered]@{}
foreach ($blockId in @($FailOnSinId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $matchCount = @($findings | Where-Object { Test-SinIdMatch -FindingSinId $_.sinId -TargetId $blockId }).Count
    $blockedById[$blockId] = $matchCount
}
$blockedCount = @($blockedById.Values | Where-Object { [int]$_ -gt 0 }).Count

if (-not $Quiet) {
    Write-ScanLog ''
    Write-ScanLog "Scan complete  ($($sw.ElapsedMilliseconds)ms)" 'Cyan'
    Write-ScanLog "  Patterns loaded : $($patterns.Count)"
    Write-ScanLog "  Files scanned   : $($allFiles.Count)"
    Write-ScanLog "  CRITICAL        : $critCount" $(if ($critCount -gt 0) { 'Red' }    else { 'Gray' })
    Write-ScanLog "  HIGH            : $highCount" $(if ($highCount -gt 0) { 'Yellow' } else { 'Gray' })
    Write-ScanLog "  MEDIUM          : $medCount"
    Write-ScanLog "  LOW             : $lowCount"
    Write-ScanLog "  Total findings  : $($findings.Count)"

    if ($findings.Count -gt 0) {
        Write-ScanLog ''
        foreach ($f in ($findings.ToArray() | Sort-Object severity, sinId)) {
            $col = switch ($f.severity) { 'CRITICAL' { 'Red' } 'HIGH' { 'Yellow' } default { 'White' } }
            Write-ScanLog "  [$($f.severity)] $($f.sinId) -- $($f.file):$($f.line)" $col
        }
    }
}

# -- Baseline ratchet (computed BEFORE result-object emit) --
# Build current counts per SIN id, compare against baseline, compute regressions.
$currentCounts = @{}
foreach ($f in $findings) {
    if (-not $currentCounts.ContainsKey($f.sinId)) { $currentCounts[$f.sinId] = 0 }
    $currentCounts[$f.sinId] = [int]$currentCounts[$f.sinId] + 1
}

$regressions = @()
$improvements = @()
$baselineApplied = $false
if (-not [string]::IsNullOrWhiteSpace($BaselineJson) -and (Test-Path -LiteralPath $BaselineJson) -and -not $UpdateBaseline -and $RatchetMode -ne 'Off') {
    try {
        $baselineObj = Get-Content -LiteralPath $BaselineJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $baseCounts = @{}
        if ($baselineObj.PSObject.Properties.Name -contains 'counts' -and $null -ne $baselineObj.counts) {
            foreach ($p in $baselineObj.counts.PSObject.Properties) { $baseCounts[$p.Name] = [int]$p.Value }
        }
        # Regressions: current > baseline for any SIN currently present
        foreach ($sinId in $currentCounts.Keys) {
            $cur = [int]$currentCounts[$sinId]
            $base = if ($baseCounts.ContainsKey($sinId)) { [int]$baseCounts[$sinId] } else { 0 }
            if ($cur -gt $base) { $regressions += [pscustomobject]@{ sinId = $sinId; baseline = $base; current = $cur; delta = ($cur - $base) } }
        }
        # Improvements: baseline > current (or current absent) - opportunity to ratchet down
        foreach ($sinId in $baseCounts.Keys) {
            $cur = if ($currentCounts.ContainsKey($sinId)) { [int]$currentCounts[$sinId] } else { 0 }
            $base = [int]$baseCounts[$sinId]
            if ($cur -lt $base) { $improvements += [pscustomobject]@{ sinId = $sinId; baseline = $base; current = $cur; delta = ($base - $cur) } }
        }
        $baselineApplied = $true
        Write-ScanLog ("Baseline applied [$RatchetMode]: {0} tracked sin_ids; regressions: {1}; improvements: {2}" -f $baseCounts.Keys.Count, $regressions.Count, $improvements.Count) 'Cyan'
    } catch {
        Write-ScanLog "  [WARN] Failed to load baseline: $_" 'Yellow'
    }
}

$resultObj = [ordered]@{
    runtime         = $Runtime
    scanId          = $scanId
    timestamp       = (Get-Date -Format 'o')
    workspace       = $WorkspacePath
    patternsLoaded  = $patterns.Count
    filesScanned    = $allFiles.Count
    totalFindings   = $findings.Count
    critical        = $critCount
    high            = $highCount
    medium          = $medCount
    low             = $lowCount
    blockedById     = $blockedById
    blockedCount    = $blockedCount
    totalRawMatches = $totalRawMatches
    totalSuppressed = $totalSuppressed
    elapsedMs       = $sw.ElapsedMilliseconds
    patternSummary  = $patternSummary.ToArray()
    findings        = $findings.ToArray()
    countsBySinId   = $currentCounts
    baselinePath    = $BaselineJson
    baselineApplied = $baselineApplied
    ratchetMode     = $RatchetMode
    regressions     = $regressions
    improvements    = $improvements
}

ConvertTo-Json $resultObj -Depth 8 | Set-Content -LiteralPath $OutputJson -Encoding UTF8

if (-not $Quiet) { Write-ScanLog "Results  : $OutputJson" }

# Optional: write/update baseline file (must be after scan; uses $currentCounts)
if (-not [string]::IsNullOrWhiteSpace($BaselineJson) -and $UpdateBaseline) {
    $baselineDir = Split-Path $BaselineJson -Parent
    if ($baselineDir -and -not (Test-Path $baselineDir)) { $null = New-Item -ItemType Directory -Path $baselineDir -Force }
    $baselineObj = [ordered]@{
        generated_at = (Get-Date -Format 'o')
        scan_id      = $scanId
        workspace    = $WorkspacePath
        counts       = $currentCounts
        note         = 'Baseline = current accepted SIN debt. Pipeline blocks only on regressions above these counts. Decrease this file (ratchet) when SINs are remediated.'
    }
    ConvertTo-Json $baselineObj -Depth 6 | Set-Content -LiteralPath $BaselineJson -Encoding UTF8
    Write-ScanLog "Baseline updated -> $BaselineJson ($($currentCounts.Keys.Count) sin_ids tracked)" 'Cyan'
}

if ($FailOnCritical -and $critCount -gt 0) {
    if ($baselineApplied) {
        $blockNeeded = $false
        $blockReason = ''
        if ($regressions.Count -gt 0) {
            $blockNeeded = $true
            $blockReason = "$($regressions.Count) regression(s): " + (($regressions | ForEach-Object { "$($_.sinId): $($_.baseline)->$($_.current) (+$($_.delta))" }) -join '; ')
        } elseif ($RatchetMode -eq 'Strict' -and $improvements.Count -gt 0) {
            $blockNeeded = $true
            $blockReason = "Strict mode: $($improvements.Count) un-recorded improvement(s) - refresh baseline (-UpdateBaseline): " + (($improvements | ForEach-Object { "$($_.sinId): $($_.baseline)->$($_.current) (-$($_.delta))" }) -join '; ')
        }
        if ($blockNeeded) {
            Write-ScanLog "[PIPELINE BLOCKED] $blockReason" 'Red'
            exit 1
        } else {
            Write-ScanLog "[PIPELINE OK] $critCount CRITICAL finding(s) all within baseline tolerance. No regressions." 'Green'
        }
    } else {
        Write-ScanLog "[PIPELINE BLOCKED] $critCount CRITICAL SIN finding(s). Fix before proceeding (or supply -BaselineJson + run once with -UpdateBaseline to ratchet)." 'Red'
        exit 1
    }
}

if ($blockedCount -gt 0) {
    $blockedSummary = @(
        foreach ($blockId in $blockedById.Keys) {
            if ([int]$blockedById[$blockId] -gt 0) {
                "$blockId=$($blockedById[$blockId])"
            }
        }
    ) -join ', '
    Write-ScanLog "[PIPELINE BLOCKED] Targeted SIN finding(s) detected: $blockedSummary" 'Red'
    throw "Targeted SIN finding(s) detected: $blockedSummary"
}

return $resultObj

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





