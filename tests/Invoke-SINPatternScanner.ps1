# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS  SIN Pattern Scanner - automated code quality and security scanning.
.DESCRIPTION
    Reads all SIN-PATTERN-*.json definitions from the sin_registry folder,
    extracts their scan_regex patterns, and scans all matching files in the
    workspace. Produces a structured results object and optionally writes
    new SIN instances for each detection.

    Designed to run:
    - After every pipeline processing task (CronProcessor Step 3.5)
    - As part of pre-release validation (Invoke-ReleasePreFlight gate)
    - On-demand via Run-AllTests.ps1 integration
    - After any code generation or editing session

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Default: script parent directory.
.PARAMETER PatternFilter
    Optional SIN-PATTERN ID filter (wildcard). Default: * (all patterns).
.PARAMETER AutoRegister
    When set, creates new SIN entries in the registry for each finding.
.PARAMETER FailOnCritical
    Exit with code 1 if any CRITICAL severity findings are detected.
.PARAMETER OutputJson
    Path to write JSON results file. Default: temp/sin-scan-results.json.
.PARAMETER Quiet
    Suppress console output (for pipeline/CI integration).

.NOTES
    Integration points:
    - CronProcessor:   Add as Step 3.5 between Invoke-DeepTest and Invoke-BugDiscovery
    - PreFlight:       Add as Gate 6 after XHTML DOCTYPE check
    - Run-AllTests:    Add as phase between Pester and smoke test
    - SyntaxGuard:     Complements checks 1-9 with SIN-specific pattern matching
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$PatternFilter = '*',
    [switch]$AutoRegister,
    [switch]$FailOnCritical,
    [string]$OutputJson,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Defaults ────────────────────────────────────────────────────────────
if (-not $OutputJson) {
    $OutputJson = Join-Path $WorkspacePath 'temp\sin-scan-results.json'
}
$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
$timestamp      = (Get-Date).ToUniversalTime().ToString('o')
$scanId         = "SINSCAN-$(Get-Date -Format 'yyyyMMddHHmmss')"

# ── Load Pattern Definitions ───────────────────────────────────────────
function Get-SinPatternDefinitions {
    param([string]$RegistryDir, [string]$Filter)
    $patterns = @()
    # Use -Filter '*.json' then -like for [] character-class support (Win32 -Filter ignores [])
    $allPatternFiles = Get-ChildItem -Path $RegistryDir -Filter "SIN-PATTERN-*.json" -File -ErrorAction SilentlyContinue
    $patternFiles = @($allPatternFiles | Where-Object { $_.Name -like "SIN-PATTERN-$Filter.json" })
    foreach ($file in $patternFiles) {
        try {
            $def = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $props = $def.PSObject.Properties.Name
            $scanRegex   = if ($props -contains 'scan_regex')        { $def.scan_regex }        else { $null }
            $filePattern = if ($props -contains 'scan_file_pattern') { $def.scan_file_pattern } else { '*.ps1;*.psm1' }
            $scanExclude = if ($props -contains 'scan_exclude')      { $def.scan_exclude }      else { $null }
            $defRemedy   = if ($props -contains 'remedy')            { $def.remedy }             else { '' }
            $defPrevent  = if ($props -contains 'preventionRule')    { $def.preventionRule }     else { '' }
            # Improvement #1: Context-guard support — adjacent-line guard patterns
            $guardRegex  = if ($props -contains 'context_guard_regex') { $def.context_guard_regex } else { $null }
            $guardLines  = if ($props -contains 'context_guard_lines') { [int]$def.context_guard_lines } else { 3 }
            $guardDir    = if ($props -contains 'context_guard_direction') { $def.context_guard_direction } else { 'above' }
            # Evo2: Per-pattern file exclusion regex
            $fileExclude = if ($props -contains 'file_exclusion_regex') { $def.file_exclusion_regex } else { $null }
            # R2: Inline-only guard regex — tested ONLY on the finding line, never on adjacent lines
            $inlineGuard = if ($props -contains 'inline_guard_regex') { $def.inline_guard_regex } else { $null }

            if ($scanRegex -and $scanRegex -ne 'BINARY_CHECK' -and $scanRegex -ne 'FILE_SIZE_CHECK') {
                $patterns += [PSCustomObject]@{
                    SinId           = $def.sin_id
                    Title           = $def.title
                    Severity        = $def.severity
                    Category        = $def.category
                    Regex           = $scanRegex
                    FilePattern     = $filePattern
                    Exclude         = $scanExclude
                    Remedy          = $defRemedy
                    Prevention      = $defPrevent
                    ScanType        = 'regex'
                    GuardRegex      = $guardRegex
                    GuardLines      = $guardLines
                    GuardDir        = $guardDir
                    FileExcludeRegex = $fileExclude
                    InlineGuardRegex = $inlineGuard
                }
            }
            elseif ($scanRegex -eq 'FILE_SIZE_CHECK') {
                $patterns += [PSCustomObject]@{
                    SinId         = $def.sin_id
                    Title         = $def.title
                    Severity      = $def.severity
                    Category      = $def.category
                    Regex         = $null
                    FilePattern   = $filePattern
                    Exclude       = $null
                    Remedy        = $defRemedy
                    Prevention    = $defPrevent
                    ScanType      = 'filesize'
                }
            }
            elseif ($scanRegex -eq 'BINARY_CHECK') {
                # R2: Load byte signature for P023-style byte-level scans
                $byteSig = if ($props -contains 'scan_byte_signature') { $def.scan_byte_signature } else { $null }
                $patterns += [PSCustomObject]@{
                    SinId         = $def.sin_id
                    Title         = $def.title
                    Severity      = $def.severity
                    Category      = $def.category
                    Regex         = $null
                    FilePattern   = $filePattern
                    Exclude       = $null
                    Remedy        = $defRemedy
                    Prevention    = $defPrevent
                    ScanType      = 'binary-bom'
                    ByteSignature = $byteSig
                }
            }
        }
        catch {
            if (-not $Quiet) {
                Write-Warning "Failed to parse pattern file $($file.Name): $($_.Exception.Message)"
            }
        }
    }
    return $patterns
}

# ── File Collection ─────────────────────────────────────────────────────
function Get-ScanTargets {
    param([string]$Root, [string]$FilePattern, [string]$Exclude)
    $extensions = $FilePattern -split ';' | ForEach-Object { $_.Trim() }
    $files = @()
    foreach ($ext in $extensions) {
        $found = Get-ChildItem -Path $Root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.history[\\/]' -and
                           $_.FullName -notmatch '[\\/]node_modules[\\/]' -and
                           $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and
                           $_.FullName -notmatch '[\\/]temp[\\/].*backup' -and
                           $_.FullName -notmatch '[\\/]~REPORTS[\\/]' -and
                           $_.FullName -notmatch '[\\/]checkpoints[\\/]' -and
                           $_.FullName -notmatch '[\\/]\.venv' -and
                           $_.FullName -notmatch '[\\/]CONFIG-BACKUPS[\\/]' -and
                           $_.FullName -notmatch '[\\/]agentic-manifest-history[\\/]' -and
                           $_.FullName -notmatch '[\\/]UPM[\\/]' }
        if ($Exclude) {
            $excludeParts = $Exclude -split ';'
            foreach ($ep in $excludeParts) {
                $epTrimmed = $ep.Trim()
                if ($epTrimmed) {
                    $found = $found | Where-Object { $_.FullName -notmatch [regex]::Escape($epTrimmed) }
                }
            }
        }
        $files += $found
    }
    return @($files | Sort-Object FullName -Unique)
}

# ── R2: File content cache to avoid re-reading files per pattern ─────────
$script:FileContentCache = @{}

# ── Regex Scan ──────────────────────────────────────────────────────────
function Invoke-RegexPatternScan {
    param([PSCustomObject]$Pattern, [System.IO.FileInfo[]]$Files)
    $findings = @()
    # R3: Track raw matches for suppression transparency
    $script:RawMatchCount = 0
    $compiledRegex = $null
    try {
        $compiledRegex = [regex]::new($Pattern.Regex, 'IgnoreCase,Multiline')
    }
    catch {
        if (-not $Quiet) {
            Write-Warning "Invalid regex in $($Pattern.SinId): $($_.Exception.Message)"
        }
        return $findings
    }
    # Improvement #1: Pre-compile context guard regex if present
    $guardRegexCompiled = $null
    if ($Pattern.GuardRegex) {
        try { $guardRegexCompiled = [regex]::new($Pattern.GuardRegex, 'IgnoreCase') }
        catch { <# Intentional: invalid guard regex degrades to no-guard mode #> }
    }
    # Evo2: Per-pattern file exclusion (loaded from JSON file_exclusion_regex)
    $fileExclusionRx = $null
    if ($Pattern.FileExcludeRegex) {
        try { $fileExclusionRx = [regex]::new($Pattern.FileExcludeRegex, 'IgnoreCase') }
        catch { <# Intentional: invalid exclusion degrades gracefully #> }
    }
    # R2: Inline-only guard — tested ONLY on the finding line, never adjacent
    $inlineGuardRx = $null
    if ($Pattern.InlineGuardRegex) {
        try { $inlineGuardRx = [regex]::new($Pattern.InlineGuardRegex, 'IgnoreCase') }
        catch { <# Intentional: invalid inline guard degrades gracefully #> }
    }

    foreach ($file in $Files) {
        if ($null -ne $fileExclusionRx -and $fileExclusionRx.IsMatch($file.Name)) { continue }
        try {
            # R2: Use cached file content to avoid redundant I/O (25 patterns × 175 files)
            $cacheKey = $file.FullName
            if ($script:FileContentCache.ContainsKey($cacheKey)) {
                $content = $script:FileContentCache[$cacheKey].Content
                $lines   = $script:FileContentCache[$cacheKey].Lines
            } else {
                $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $lines = $content -split "`n"
                $script:FileContentCache[$cacheKey] = @{ Content = $content; Lines = $lines }
            }
            # Improvement #3: Track .EXAMPLE block state for help-block exclusion
            $inExampleBlock = $false
            # R3: Track multiline block comments (<# ... #>)
            $inBlockComment = $false
            # R3: Track here-strings (@"..."@ and @'...'@)
            $inHereString = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                # Improvement #3: .EXAMPLE block detection — skip content in comment-based help examples
                $trimmedForHelp = $lines[$i].Trim()
                # R3: Block comment tracking — <# opens, #> closes
                if (-not $inBlockComment -and $trimmedForHelp -match '<#') { $inBlockComment = $true }
                if ($inBlockComment -and $trimmedForHelp -match '#>') { $inBlockComment = $false; continue }
                if ($inBlockComment) { continue }
                # R3: Here-string tracking — line ENDING with @" or @' opens, line STARTING with "@ or '@ closes
                if (-not $inHereString -and $trimmedForHelp -match '@["'']$') { $inHereString = $true; continue }
                if ($inHereString -and $trimmedForHelp -match '^["'']@') { $inHereString = $false; continue }
                if ($inHereString) { continue }

                if ($trimmedForHelp -match '^\.\s*EXAMPLE') { $inExampleBlock = $true; continue }
                if ($inExampleBlock -and $trimmedForHelp -match '^\.\s*(SYNOPSIS|DESCRIPTION|PARAMETER|NOTES|LINK|INPUTS|OUTPUTS|COMPONENT|ROLE|FUNCTIONALITY|FORWARDHELPTARGETNAME|EXTERNALHELP)') {
                    $inExampleBlock = $false
                }
                if ($inExampleBlock -and $trimmedForHelp -match '^#>') { $inExampleBlock = $false }
                if ($inExampleBlock -and $Pattern.Category -ne 'security') { continue }

                if ($compiledRegex.IsMatch($lines[$i])) {
                    $script:RawMatchCount++
                    # R2: Skip matches inside comments (encoding exemption removed — BOM has own handler)
                    $trimmed = $lines[$i].TrimStart()
                    if ($trimmed.StartsWith('#')) { continue }
                    # R3: SIN-EXEMPT markers — supports #SIN-EXEMPT:P021, #SIN-EXEMPT:*, or comma-separated
                    if ($lines[$i] -match '#\s*SIN-EXEMPT:\s*(.+)') {
                        $exemptList = $Matches[1].Trim() -split '\s*,\s*'
                        # Extract pattern number keeping original digits (e.g. SIN-PATTERN-021-... → P021)
                        $patNum = 'P' + ($Pattern.SinId -replace '^SIN-PATTERN-(\d+).*','$1')
                        if ($exemptList -contains '*' -or $exemptList -contains $patNum -or $exemptList -contains $Pattern.SinId) { continue }
                    }
                    # Skip inline comments — if the match region is entirely after a #
                    $hashPos = $lines[$i].IndexOf('#')
                    if ($hashPos -ge 0) {
                        $matchObj = $compiledRegex.Match($lines[$i])
                        if ($matchObj.Success -and $matchObj.Index -gt $hashPos) { continue }
                    }
                    # Skip string-literal detection patterns (e.g. SIN pattern descriptions, test regex strings)
                    if ($trimmed -match '^\s*[\x27"].*[\x27"]\s*$' -and $Pattern.Category -ne 'security') { continue }
                    # Improvement #3: Skip matches inside hashtable/array string values
                    if ($trimmed -match '^\s*[\x27"]?\w+[\x27"]?\s*=' -and $trimmed -match '[\x27"][^[\x27"]*[\x27"]\s*$' -and $Pattern.Category -ne 'security') { continue }

                    # Improvement #1: Context-guard adjacent-line check
                    if ($null -ne $guardRegexCompiled) {
                        $guardFound = $false
                        $guardRange = $Pattern.GuardLines
                        if ($Pattern.GuardDir -eq 'above' -or $Pattern.GuardDir -eq 'both') {
                            $startLook = [Math]::Max(0, $i - $guardRange)
                            for ($g = $startLook; $g -lt $i; $g++) {
                                if ($guardRegexCompiled.IsMatch($lines[$g])) { $guardFound = $true; break }
                            }
                        }
                        if (-not $guardFound -and ($Pattern.GuardDir -eq 'below' -or $Pattern.GuardDir -eq 'both')) {
                            $endLook = [Math]::Min($lines.Count - 1, $i + $guardRange)
                            for ($g = ($i + 1); $g -le $endLook; $g++) {
                                if ($guardRegexCompiled.IsMatch($lines[$g])) { $guardFound = $true; break }
                            }
                        }
                        # Also check the match line itself for inline guard
                        if (-not $guardFound -and $guardRegexCompiled.IsMatch($lines[$i])) { $guardFound = $true }
                        if ($guardFound) { continue }
                    }
                    # R2: Inline-only guard — ONLY checks the finding line, not adjacent
                    if ($null -ne $inlineGuardRx -and $inlineGuardRx.IsMatch($lines[$i])) { continue }

                    $findings += [PSCustomObject]@{
                        PatternId  = $Pattern.SinId
                        Severity   = $Pattern.Severity
                        Category   = $Pattern.Category
                        File       = $file.FullName
                        RelPath    = $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                        Line       = $i + 1
                        Content    = $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 120))
                        Remedy     = $Pattern.Remedy
                        Title      = $Pattern.Title
                    }
                }
            }
        }
        catch {
            # File read failures are not scan failures
        }
    }
    return $findings
}

# ── File Size Scan ──────────────────────────────────────────────────────
function Invoke-FileSizeScan {
    param([PSCustomObject]$Pattern, [System.IO.FileInfo[]]$Files)
    $findings = @()
    foreach ($file in $Files) {
        $severity = $null
        if ($file.Length -gt 20MB) {
            $severity = 'CRITICAL'
        }
        elseif ($file.Length -gt 5MB) {
            $severity = 'HIGH'
        }
        if ($severity) {
            $sizeMB = [Math]::Round($file.Length / 1MB, 2)
            $findings += [PSCustomObject]@{
                PatternId  = $Pattern.SinId
                Severity   = $severity
                Category   = $Pattern.Category
                File       = $file.FullName
                RelPath    = $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                Line       = 0
                Content    = "File size: ${sizeMB} MB"
                Remedy     = $Pattern.Remedy
                Title      = $Pattern.Title
            }
        }
    }
    return $findings
}

# ── BOM/Encoding Scan ──────────────────────────────────────────────────
function Invoke-BomEncodingScan {
    param([PSCustomObject]$Pattern, [System.IO.FileInfo[]]$Files)
    $findings = @()
    # R2: Check if this is a byte-signature scan (P023) vs BOM scan (P006)
    $hasByteSig = ($Pattern.PSObject.Properties.Name -contains 'ByteSignature') -and ($null -ne $Pattern.ByteSignature)
    $sigBytes = $null
    if ($hasByteSig) {
        # Convert hex string like 'C3A2E280' to byte array
        $hexStr = $Pattern.ByteSignature
        $sigBytes = [byte[]]::new($hexStr.Length / 2)
        for ($b = 0; $b -lt $sigBytes.Length; $b++) {
            $sigBytes[$b] = [Convert]::ToByte($hexStr.Substring($b * 2, 2), 16)
        }
    }
    foreach ($file in $Files) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -lt 3) { continue }

            # R2: Byte-signature scan (e.g., P023 double-encoded UTF-8)
            if ($null -ne $sigBytes) {
                $sigLen = $sigBytes.Length
                $scanLimit = [Math]::Min($bytes.Length - $sigLen, 100000)
                for ($i = 0; $i -le $scanLimit; $i++) {
                    $match = $true
                    for ($j = 0; $j -lt $sigLen; $j++) {
                        if ($bytes[$i + $j] -ne $sigBytes[$j]) { $match = $false; break }
                    }
                    if ($match) {
                        # Calculate approximate line number
                        $lineNum = 1
                        for ($k = 0; $k -lt $i; $k++) { if ($bytes[$k] -eq 0x0A) { $lineNum++ } }
                        $hexContext = ($bytes[$i..([Math]::Min($i + 7, $bytes.Length - 1))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                        $findings += [PSCustomObject]@{
                            PatternId  = $Pattern.SinId
                            Severity   = $Pattern.Severity
                            Category   = $Pattern.Category
                            File       = $file.FullName
                            RelPath    = $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                            Line       = $lineNum
                            Content    = "Double-encoded UTF-8 signature at byte $i [$hexContext]"
                            Remedy     = $Pattern.Remedy
                            Title      = $Pattern.Title
                        }
                        break  # One finding per file is sufficient
                    }
                }
                continue  # Skip BOM check for byte-signature patterns
            }

            $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if (-not $hasBom) {
                # Check for non-ASCII bytes (multi-byte UTF-8 indicators)
                $hasNonAscii = $false
                $dangerousByte = $null
                for ($i = 0; $i -lt [Math]::Min($bytes.Length, 50000); $i++) {
                    if ($bytes[$i] -gt 0x7F) {
                        $hasNonAscii = $true
                        if ($bytes[$i] -in @(0x84, 0x91, 0x92, 0x93, 0x94)) {
                            $dangerousByte = '0x{0:X2}' -f $bytes[$i]
                        }
                        break
                    }
                }
                if ($hasNonAscii) {
                    $detail = "No BOM + non-ASCII content detected"
                    if ($dangerousByte) { $detail += " (dangerous byte $dangerousByte found)" }
                    $findings += [PSCustomObject]@{
                        PatternId  = $Pattern.SinId
                        Severity   = if ($dangerousByte) { 'HIGH' } else { 'MEDIUM' }
                        Category   = $Pattern.Category
                        File       = $file.FullName
                        RelPath    = $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                        Line       = 0
                        Content    = $detail
                        Remedy     = $Pattern.Remedy
                        Title      = $Pattern.Title
                    }
                }
            }
        }
        catch {
            # Binary read failures are not scan failures
        }
    }
    return $findings
}

# ── Duplicate Function Scan (Improvement #5: Load-Conflict Aware) ────────
function Invoke-DuplicateFunctionScan {
    param([PSCustomObject]$Pattern, [System.IO.FileInfo[]]$Files)
    $findings = @()
    $allFunctions = @{}

    # Improvement #5: Build module import graph from Main-GUI.ps1 to detect actual load conflicts
    $importGraph = @{}  # file => @(imported-file-paths)
    $mainGuiPath = Join-Path $WorkspacePath 'Main-GUI.ps1'
    if (Test-Path $mainGuiPath) {
        try {
            $mainContent = Get-Content $mainGuiPath -Raw -Encoding UTF8 -ErrorAction Stop
            $importMatches = [regex]::Matches($mainContent, 'Import-Module\s+[''"]?([^''";\s]+)[''"]?', 'IgnoreCase')
            foreach ($m in $importMatches) {
                $modRef = $m.Groups[1].Value
                $importGraph['Main-GUI.ps1'] += @($modRef)
            }
        }
        catch { <# Intentional: if Main-GUI unreadable, fall back to all-files mode #> }
    }
    # Build list of modules that are co-loaded (share a load context)
    $coLoadedModules = @{}
    foreach ($entry in $importGraph.GetEnumerator()) {
        $mods = @($entry.Value)
        foreach ($m in $mods) {
            $coLoadedModules[$m] = $mods
        }
    }

    foreach ($file in $Files) {
        try {
            $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $lines = $content -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*function\s+([\w-]+)') {
                    $funcName = $Matches[1]
                    if (-not $allFunctions.ContainsKey($funcName)) {
                        $allFunctions[$funcName] = @()
                    }
                    $allFunctions[$funcName] += [PSCustomObject]@{
                        File = $file.FullName
                        RelPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                        Line = $i + 1
                        FileName = $file.Name
                    }
                }
            }
        }
        catch { <# Intentional: file may fail to parse, skip gracefully #> }
    }

    foreach ($funcName in $allFunctions.Keys) {
        $locations = @($allFunctions[$funcName])
        if (@($locations).Count -le 1) { continue }

        # Improvement #5: Check if duplicates are in co-loaded modules (actual runtime conflict)
        $isRuntimeConflict = $false
        if (@($coLoadedModules.Keys).Count -gt 0) {
            $locFileNames = @($locations | ForEach-Object { $_.FileName })
            # Check if any pair of files are both in the co-loaded set
            for ($a = 0; $a -lt @($locFileNames).Count; $a++) {
                for ($b = $a + 1; $b -lt @($locFileNames).Count; $b++) {
                    $fileA = $locFileNames[$a]
                    $fileB = $locFileNames[$b]
                    # Same file = always conflict
                    if ($fileA -eq $fileB) { $isRuntimeConflict = $true; break }
                    # Both imported by Main-GUI = runtime conflict
                    $aLoaded = $coLoadedModules.ContainsKey($fileA) -or $coLoadedModules.ContainsKey(($fileA -replace '\.psm1$', ''))
                    $bLoaded = $coLoadedModules.ContainsKey($fileB) -or $coLoadedModules.ContainsKey(($fileB -replace '\.psm1$', ''))
                    if ($aLoaded -and $bLoaded) { $isRuntimeConflict = $true; break }
                }
                if ($isRuntimeConflict) { break }
            }
        }
        else {
            # No import graph available — treat all duplicates as potential conflicts
            $isRuntimeConflict = $true
        }

        if (-not $isRuntimeConflict) { continue }

        $locList = ($locations | ForEach-Object { "$($_.RelPath):$($_.Line)" }) -join '; '
        foreach ($loc in $locations) {
            $findings += [PSCustomObject]@{
                PatternId  = $Pattern.SinId
                Severity   = if (@($locations).Count -ge 5) { 'CRITICAL' } else { $Pattern.Severity }
                Category   = $Pattern.Category
                File       = $loc.File
                RelPath    = $loc.RelPath
                Line       = $loc.Line
                Content    = "function $funcName defined $(@($locations).Count)x: $locList"
                Remedy     = $Pattern.Remedy
                Title      = $Pattern.Title
            }
        }
    }
    return $findings
}

# ── Auto-Register SIN Instance ──────────────────────────────────────────
function Register-SinInstance {
    param([PSCustomObject]$Finding, [string]$RegistryDir)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $payload = "$($Finding.PatternId)|$($Finding.RelPath)|$($Finding.Line)"
    $hashBytes = $hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))
    $shortHash = [BitConverter]::ToString($hashBytes[0..3]).Replace('-', '').ToLower()
    $sinId = "SIN-$(Get-Date -Format 'yyyyMMdd')-$shortHash"
    $sinFile = Join-Path $RegistryDir "$sinId.json"

    if (Test-Path $sinFile) { return $null }

    $sin = [ordered]@{
        sin_id           = $sinId
        title            = "$($Finding.Title) in $($Finding.RelPath)"
        description      = "Automated detection by SIN Pattern Scanner. Pattern: $($Finding.PatternId). Match at line $($Finding.Line): $($Finding.Content)"
        category         = $Finding.Category
        severity         = $Finding.Severity
        file_path        = $Finding.RelPath
        line_number      = $Finding.Line
        agent_id         = 'SINPatternScanner'
        reported_by      = 'Invoke-SINPatternScanner.ps1'
        is_resolved      = $false
        occurrence_count = 1
        regression_count = 0
        created_at       = (Get-Date).ToUniversalTime().ToString('o')
        last_seen_at     = (Get-Date).ToUniversalTime().ToString('o')
        detection_method = "Automated SIN pattern scan: $($Finding.PatternId)"
        parent_pattern   = $Finding.PatternId
        remedy           = $Finding.Remedy
        remedy_tracking  = [ordered]@{
            attempts         = @()
            last_attempt_at  = $null
            total_attempts   = 0
            successful_count = 0
            failed_count     = 0
            status           = 'PENDING'
            auto_retry       = $true
        }
    }
    $sin | ConvertTo-Json -Depth 8 | Set-Content $sinFile -Encoding UTF8
    return $sinId
}

# ═══════════════════════════════════════════════════════════════════════
#                         MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════

if (-not $Quiet) {
    Write-Host "`n===== SIN PATTERN SCANNER =====" -ForegroundColor Cyan
    Write-Host "Scan ID:    $scanId"
    Write-Host "Workspace:  $WorkspacePath"
    Write-Host "Registry:   $sinRegistryDir"
    Write-Host "Timestamp:  $timestamp`n"
}

# Load pattern definitions
$patterns = @(Get-SinPatternDefinitions -RegistryDir $sinRegistryDir -Filter $PatternFilter)
if (-not $Quiet) {
    Write-Host "Loaded $(@($patterns).Count) pattern definitions" -ForegroundColor Gray
}

$allFindings  = @()
$scanSummary  = @()

foreach ($pattern in $patterns) {
    if (-not $Quiet) {
        Write-Host "  Scanning: $($pattern.SinId) [$($pattern.Severity)]..." -ForegroundColor DarkGray -NoNewline
    }

    $files = Get-ScanTargets -Root $WorkspacePath -FilePattern $pattern.FilePattern -Exclude $pattern.Exclude
    $findings = @()

    switch ($pattern.ScanType) {
        'regex' {
            if ($pattern.SinId -like 'SIN-PATTERN-011-DUPLICATE-FUNCTION-DEF*') {
                $findings = @(Invoke-DuplicateFunctionScan -Pattern $pattern -Files $files)
            }
            else {
                $findings = @(Invoke-RegexPatternScan -Pattern $pattern -Files $files)
            }
        }
        'filesize' {
            $findings = @(Invoke-FileSizeScan -Pattern $pattern -Files $files)
        }
        'binary-bom' {
            $findings = @(Invoke-BomEncodingScan -Pattern $pattern -Files $files)
        }
    }

    # R3: Capture suppression count (raw regex matches minus final findings)
    $rawMatches = if ($pattern.ScanType -eq 'regex' -and $pattern.SinId -notlike 'SIN-PATTERN-011-*') { $script:RawMatchCount } else { 0 }
    $suppressed = [Math]::Max(0, $rawMatches - @($findings).Count)

    $scanSummary += [PSCustomObject]@{
        PatternId    = $pattern.SinId
        Severity     = $pattern.Severity
        FilesScanned = $files.Count
        Findings     = $findings.Count
        RawMatches   = $rawMatches
        Suppressed   = $suppressed
    }

    if (-not $Quiet) {
        if ($findings.Count -eq 0) {
            Write-Host " CLEAN" -ForegroundColor Green
        }
        else {
            $color = switch ($pattern.Severity) { 'CRITICAL' { 'Red' } 'HIGH' { 'Magenta' } default { 'Yellow' } }
            Write-Host " $($findings.Count) finding(s)" -ForegroundColor $color
        }
    }

    $allFindings += $findings
}

# ── Auto-Register ───────────────────────────────────────────────────────
$registered = @()
if ($AutoRegister -and @($allFindings).Count -gt 0) {
    if (-not $Quiet) { Write-Host "`nAuto-registering findings..." -ForegroundColor Gray }
    foreach ($finding in $allFindings) {
        $sinId = Register-SinInstance -Finding $finding -RegistryDir $sinRegistryDir
        if ($sinId) { $registered += $sinId }
    }
    if (-not $Quiet) {
        Write-Host "  Registered $(@($registered).Count) new SIN(s)" -ForegroundColor Yellow
    }
}

# ── Results Object ──────────────────────────────────────────────────────
$criticalCount = @($allFindings | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$highCount     = @($allFindings | Where-Object { $_.Severity -eq 'HIGH' }).Count
$mediumCount   = @($allFindings | Where-Object { $_.Severity -eq 'MEDIUM' }).Count

$resultsObj = [ordered]@{
    scanId         = $scanId
    timestamp      = $timestamp
    workspace      = $WorkspacePath
    patternsLoaded = @($patterns).Count
    totalFindings  = @($allFindings).Count
    critical       = $criticalCount
    high           = $highCount
    medium         = $mediumCount
    # R3: Suppression transparency
    totalRawMatches = ($scanSummary | ForEach-Object { $_.RawMatches } | Measure-Object -Sum).Sum
    totalSuppressed = ($scanSummary | ForEach-Object { $_.Suppressed } | Measure-Object -Sum).Sum
    registered     = @($registered).Count
    patternSummary = $scanSummary
    findings       = $allFindings
}

# Write JSON results
$tempDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
$resultsObj | ConvertTo-Json -Depth 6 | Set-Content $OutputJson -Encoding UTF8

# ── Completion Banner ────────────────────────────────────────────────────
if (-not $Quiet) {
    if (Get-Command Write-ProcessBanner -ErrorAction SilentlyContinue) {
        $bannerOk = ($criticalCount -eq 0) -or (-not $FailOnCritical)
        Write-ProcessBanner -ProcessName 'SIN Pattern Scanner' -Success $bannerOk
    }
}

# ── Console Summary ─────────────────────────────────────────────────────
if (-not $Quiet) {
    Write-Host "`n===== SCAN SUMMARY =====" -ForegroundColor Cyan
    Write-Host "Patterns scanned:  $(@($patterns).Count)"
    Write-Host "Total findings:    $(@($allFindings).Count)"
    if ($criticalCount -gt 0) { Write-Host "  CRITICAL:        $criticalCount" -ForegroundColor Red }
    if ($highCount -gt 0)     { Write-Host "  HIGH:            $highCount" -ForegroundColor Magenta }
    if ($mediumCount -gt 0)   { Write-Host "  MEDIUM:          $mediumCount" -ForegroundColor Yellow }
    if (@($allFindings).Count -eq 0) {
        Write-Host "  ALL CLEAN" -ForegroundColor Green
    }
    Write-Host "Results:           $OutputJson"
    Write-Host "========================`n" -ForegroundColor Cyan

    # Detail table for findings
    if (@($allFindings).Count -gt 0) {
        $allFindings | Sort-Object @{Expression='Severity';Descending=$true}, PatternId |
            Format-Table -AutoSize @(
                @{ Label = 'Sev';     Expression = { $_.Severity }; Width = 8 }
                @{ Label = 'Pattern'; Expression = { $_.PatternId.Replace('SIN-PATTERN-','P') }; Width = 28 }
                @{ Label = 'File';    Expression = { $_.RelPath }; Width = 50 }
                @{ Label = 'Line';    Expression = { $_.Line }; Width = 6 }
                @{ Label = 'Match';   Expression = { $_.Content.Substring(0, [Math]::Min($_.Content.Length, 60)) } }
            )
    }
}

# ── Exit Code ───────────────────────────────────────────────────────────
if ($FailOnCritical -and $criticalCount -gt 0) {
    if (-not $Quiet) {
        Write-Host "FAIL: $criticalCount CRITICAL finding(s) detected. Pipeline blocked." -ForegroundColor Red
    }
    exit 1
}

# Return results object for pipeline consumption
$resultsObj

