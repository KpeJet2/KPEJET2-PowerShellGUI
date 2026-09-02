# VersionTag: 2606.B5.V51.4
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
    [string]$OutputJson = '',
    [switch]$Quiet,
    [switch]$FailOnCritical,
    [string[]]$FailOnSinId = @(),
    [string[]]$IncludeFiles = @(),
    [string]$TargetPattern = '*',
    [ValidateSet('PS51', 'PS7', 'Both')]
    [string]$Runtime = 'Both',
    # Additional file extensions to discover/scan beyond the default *.ps1/*.psm1.
    # Per-pattern routing still respects each definition's scan_file_pattern field.
    [string[]]$ExtraExtensions = @(),
    # Path to a JSON baseline of accepted SIN counts per sin_id.
    # When supplied, -FailOnCritical only blocks on REGRESSIONS (current count > baseline count for any SIN).
    # Use -UpdateBaseline to overwrite the file with current counts (ratchet down).
    [string]$BaselineJson = '',
    [switch]$UpdateBaseline,
    # Ratchet enforcement mode (only meaningful with -BaselineJson + -FailOnCritical):
    #   Off        - ignore baseline; -FailOnCritical blocks on any CRITICAL finding
    #   Permissive - default; block only on regressions (current > baseline)
    #   Strict     - block on any drift (regressions OR un-recorded improvements);
    #                forces team to refresh baseline after every fix
    [ValidateSet('Off', 'Permissive', 'Strict')]
    [string]$RatchetMode = 'Permissive',
    # Scan mode:
    # Standard = current behavior (extension-filtered discovery + per-pattern file glob checks)
    # Omega    = scan all files except excluded folders; ignore per-pattern scan_file_pattern
    [ValidateSet('Standard', 'Omega')]
    [string]$ScanMode = 'Standard',
    # Excluded subfolders for OMEGA mode (name-only path segment matching)
    [string[]]$OmegaExcludeDirs = @('.git', '.history', '.venv', '.venv-pygame312', 'node_modules', '~ARCHIVED', '~DOWNLOADS', '~REPORTS', 'checkpoints', 'UPM', 'sin_registry', 'QUICK-APP', 'ActionPacks-master', 'temp', 'bin', 'obj'),
    # OMEGA integration switch:
    # - Manifest-related files -> Bug + Bugs2FIX
    # - Non-manifest files -> Items2ADD + checkpoint file
    [switch]$OmegaPipelineAutoRoute,
    # Upper bound per OMEGA pipeline write/status operation. On timeout/error,
    # scanner writes a lightweight fallback artifact under checkpoints/omega.
    [int]$OmegaRouteOpTimeoutMs = 4000,
    # When set, return only the summary object instead of the full findings array.
    # The JSON output file still contains the complete scan payload.
    [switch]$SummaryOnly,
    [switch]$FailOnInvalidRegistry,
    [ValidateRange(0, 100)]
    [int]$MinimumCoveragePercent = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$scanId = "SINSCAN-$(Get-Date -Format 'yyyyMMddHHmmss')"
$regexMatchTimeout = [TimeSpan]::FromMilliseconds(200)
$regexTimeoutAbortThreshold = 8
$script:RegexMatchTimeoutCount = 0

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-results.json'
}

# Safety guard: never write to ourselves
if ($OutputJson -eq $PSCommandPath) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-results.json'
}

$tempDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir -Force }

function Write-ScanLog {
    # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

function Test-RegexMatchSafe {
    param(
        [regex]$Regex,
        [string]$InputText
    )

    if ($null -eq $Regex) { return $false }
    if ($null -eq $InputText) { $InputText = '' }

    try {
        return $Regex.IsMatch($InputText)
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        $script:RegexMatchTimeoutCount++
        if (Test-Path -LiteralPath variable:script:CurrentPatternTimeouts) {
            $script:CurrentPatternTimeouts++
        }
        return $false
    }
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

function Get-SinRegistryDefinition {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$File,
        [Parameter(Mandatory)] [string]$Json
    )

    $errors = @()
    $usedAliases = @()
    try { $def = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ valid = $false; errors = @('invalid JSON: ' + $_.Exception.Message); definition = $null; usedAliases = @() } }
    if ($null -eq $def -or $null -eq $def.PSObject) {
        return [pscustomobject]@{ valid = $false; errors = @('definition must be a JSON object'); definition = $null; usedAliases = @() }
    }

    $props = @($def.PSObject.Properties.Name)
    $sinId = ''
    if ($props -contains 'sin_id') { $sinId = [string]$def.sin_id }
    elseif ($props -contains 'id') { $sinId = [string]$def.id; $usedAliases += 'id' }
    elseif ($props -contains 'pattern_id') {
        $rawPatternId = [string]$def.pattern_id
        if ($rawPatternId -match '^(?i)P\d+$') { $sinId = ('SIN-PATTERN-{0:D3}' -f [int]($rawPatternId -replace '^(?i)P', '')) }
        else { $sinId = 'SIN-PATTERN-' + $rawPatternId }
        $usedAliases += 'pattern_id'
    }
    else { $errors += 'missing sin_id (or compatible id/pattern_id)' }
    if ([string]::IsNullOrWhiteSpace($sinId)) { $errors += 'empty sin_id' }

    $scanRegex = ''
    if ($props -contains 'scan_regex') { $scanRegex = [string]$def.scan_regex }
    elseif ($props -contains 'scanner_pattern') { $scanRegex = [string]$def.scanner_pattern; $usedAliases += 'scanner_pattern' }
    elseif ($props -contains 'detection_regex') { $scanRegex = [string]$def.detection_regex; $usedAliases += 'detection_regex' }
    else { $errors += 'missing scan_regex (or compatible scanner_pattern/detection_regex)' }
    if ([string]::IsNullOrWhiteSpace($scanRegex)) { $errors += 'empty scan_regex' }
    if (-not ($props -contains 'title') -or [string]::IsNullOrWhiteSpace([string]$def.title)) { $errors += 'missing title' }
    if (-not ($props -contains 'severity') -or [string]::IsNullOrWhiteSpace([string]$def.severity)) { $errors += 'missing severity' }
    if ($props -contains 'severity' -and [string]$def.severity -notin @('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')) { $errors += 'severity must be CRITICAL, HIGH, MEDIUM, or LOW' }
    if ($scanRegex -notin @('BINARY_CHECK', 'FILE_SIZE_CHECK') -and -not [string]::IsNullOrWhiteSpace($scanRegex)) {
        try { $null = [regex]::new($scanRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout) }
        catch { $errors += 'invalid scan_regex: ' + $_.Exception.Message }
    }
    return [pscustomobject]@{
        valid       = (@($errors).Count -eq 0)
        errors      = @($errors)
        definition  = [ordered]@{ sinId = $sinId; scanRegex = $scanRegex; raw = $def }
        usedAliases = @($usedAliases)
    }
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$FullPath
    )

    $full = [System.IO.Path]::GetFullPath($FullPath)
    $root = [System.IO.Path]::GetFullPath($WorkspacePath)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length).TrimStart('\\', '/') -replace '/', '\\'
    }
    return $FullPath -replace '/', '\\'
}

function Test-PathUnderExcludedDir {
    param(
        [Parameter(Mandatory)] [string]$FullPath,
        [Parameter(Mandatory)] [string[]]$ExcludedNames
    )

    $normalized = ($FullPath -replace '/', '\\').ToLowerInvariant()
    foreach ($name in @($ExcludedNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $seg = '\\' + ($name.Trim() -replace '/', '\\').ToLowerInvariant() + '\\'
        if ($normalized -like "*$seg*") { return $true }
    }
    return $false
}

function Get-ManifestPathSet {
    param([string]$WorkspacePath)

    $pathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $manifestPath = Join-Path (Join-Path $WorkspacePath 'config') 'agentic-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $pathSet }

    try {
        $manifestObj = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $pathSet
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($manifestObj)

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node -is [System.Array]) {
            foreach ($child in $node) { $stack.Push($child) }
            continue
        }

        if ($node -is [string]) {
            $text = [string]$node
            if ($text -match '^[A-Za-z]:\\|^\\\\|^[^\\/]+\\[^\\/]+\.[A-Za-z0-9]+$|^[^\\/].*\.[A-Za-z0-9]+$') {
                $candidates.Add($text)
            }
            continue
        }

        if ($node.PSObject) {
            foreach ($p in $node.PSObject.Properties) {
                $name = [string]$p.Name
                $val = $p.Value
                if ($null -eq $val) { continue }
                if ($name -match '(?i)^(path|manifestPath|file|source|sourceFile|script|rootModule|modulePath)$') {
                    if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) {
                        $candidates.Add([string]$val)
                    }
                }
                $stack.Push($val)
            }
        }
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $raw = $c.Trim().Trim('"', '''')
        $resolved = $raw
        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $WorkspacePath $resolved
        }
        try {
            $relative = Get-NormalizedRelativePath -WorkspacePath $WorkspacePath -FullPath $resolved
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                [void]$pathSet.Add($relative)
            }
        }
        catch {
            continue
        }
    }

    return $pathSet
}

function New-OmegaCheckpointEntry {
    param(
        [string]$WorkspacePath,
        [string]$File,
        [object[]]$FileFindings,
        [string]$LinkedItemId = ''
    )

    $checkDir = Join-Path (Join-Path $WorkspacePath 'checkpoints') 'omega'
    if (-not (Test-Path -LiteralPath $checkDir)) { $null = New-Item -ItemType Directory -Path $checkDir -Force }

    $safeName = ($File -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'unknown-file' }
    $cpPath = Join-Path $checkDir ("OMEGA-CHECKPOINT-{0}.json" -f $safeName)

    $payload = [ordered]@{
        checkpointType = 'OMEGA'
        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
        file           = $File
        linkedItemId   = $LinkedItemId
        findingCount   = @($FileFindings).Count
        sinIds         = @(@($FileFindings | ForEach-Object { $_.sinId }) | Sort-Object -Unique)
        severities     = @(@($FileFindings | ForEach-Object { $_.severity }) | Sort-Object -Unique)
        findings       = @($FileFindings)
        note           = 'File is not present in current manifest index. Approval required before manifest integration.'
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cpPath -Encoding UTF8
    return $cpPath
}

function New-OmegaFallbackArtifact {
    param(
        [string]$WorkspacePath,
        [string]$RouteType,
        [string]$File,
        [object[]]$FileFindings,
        [string]$Operation,
        [string]$Reason,
        [bool]$TimedOut,
        [int]$ElapsedMs,
        [int]$TimeoutMs
    )

    $checkDir = Join-Path (Join-Path $WorkspacePath 'checkpoints') 'omega'
    if (-not (Test-Path -LiteralPath $checkDir)) { $null = New-Item -ItemType Directory -Path $checkDir -Force }

    $safeName = ($File -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'unknown-file' }
    $cpPath = Join-Path $checkDir ("OMEGA-ROUTE-FALLBACK-{0}-{1}.json" -f $RouteType, $safeName)

    $payload = [ordered]@{
        checkpointType = 'OMEGA_ROUTE_FALLBACK'
        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
        routeType      = $RouteType
        file           = $File
        operation      = $Operation
        timedOut       = [bool]$TimedOut
        elapsedMs      = [int]$ElapsedMs
        timeoutMs      = [int]$TimeoutMs
        reason         = $Reason
        findingCount   = @($FileFindings).Count
        sinIds         = @(@($FileFindings | ForEach-Object { $_.sinId }) | Sort-Object -Unique)
        severities     = @(@($FileFindings | ForEach-Object { $_.severity }) | Sort-Object -Unique)
        findings       = @($FileFindings)
        note           = 'OMEGA route operation was bounded and diverted to fallback artifact for downstream queue handling.'
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cpPath -Encoding UTF8
    return $cpPath
}

function Invoke-OmegaPipelineBoundedOperation {
    param(
        [Parameter(Mandatory)] [string]$PipelineModulePath,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [ValidateSet('AddItem', 'UpdateStatus')] [string]$Operation,
        [int]$TimeoutMs = 4000,
        [hashtable]$Item,
        [string]$ItemId = '',
        [string]$NewStatus = '',
        [string]$Notes = ''
    )

    $startedAt = Get-Date
    $itemJson = ''
    if ($null -ne $Item) {
        try { $itemJson = $Item | ConvertTo-Json -Depth 12 -Compress } catch { $itemJson = '' }
    }

    $job = Start-Job -ScriptBlock {
        param($modulePath, $wsPath, $op, $payloadJson, $itemId, $newStatus, $notes)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        Import-Module $modulePath -Force -DisableNameChecking -ErrorAction Stop

        if ($op -eq 'AddItem') {
            $obj = $payloadJson | ConvertFrom-Json -ErrorAction Stop
            $ht = [ordered]@{}
            foreach ($p in $obj.PSObject.Properties) {
                $ht[$p.Name] = $p.Value
            }
            $res = Add-PipelineItem -WorkspacePath $wsPath -Item $ht -SkipArtifactRefresh
            return ($res | ConvertTo-Json -Depth 12 -Compress)
        }

        if ($op -eq 'UpdateStatus') {
            $ok = Update-PipelineItemStatus -WorkspacePath $wsPath -ItemId $itemId -NewStatus $newStatus -Notes $notes
            return ([ordered]@{ ok = [bool]$ok } | ConvertTo-Json -Depth 6 -Compress)
        }

        throw "Unsupported bounded operation: $op"
    } -ArgumentList @($PipelineModulePath, $WorkspacePath, $Operation, $itemJson, $ItemId, $NewStatus, $Notes)

    $timeoutSec = [int][Math]::Ceiling(([double][Math]::Max(1, $TimeoutMs)) / 1000.0)
    $done = Wait-Job -Job $job -Timeout $timeoutSec

    if ($null -eq $done) {
        try { Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null } catch { <# Intentional: non-fatal #> }
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null } catch { <# Intentional: non-fatal #> }
        $elapsed = [int]((Get-Date) - $startedAt).TotalMilliseconds
        return [pscustomobject]@{
            ok        = $false
            timedOut  = $true
            elapsedMs = $elapsed
            error     = ("timeout>{0}ms" -f $TimeoutMs)
            result    = $null
        }
    }

    try {
        $raw = Receive-Job -Job $job -ErrorAction Stop | Select-Object -Last 1
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
            $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        $elapsed = [int]((Get-Date) - $startedAt).TotalMilliseconds
        return [pscustomobject]@{
            ok        = $true
            timedOut  = $false
            elapsedMs = $elapsed
            error     = ''
            result    = $parsed
        }
    }
    catch {
        $elapsed = [int]((Get-Date) - $startedAt).TotalMilliseconds
        return [pscustomobject]@{
            ok        = $false
            timedOut  = $false
            elapsedMs = $elapsed
            error     = $_.Exception.Message
            result    = $null
        }
    }
    finally {
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null } catch { <# Intentional: non-fatal #> }
    }
}

# ---- Load SIN-PATTERN definitions -----------------------------------------
$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
if (-not (Test-Path $sinRegistryDir)) {
    Write-ScanLog "[ERROR] sin_registry/ not found at: $sinRegistryDir" 'Red'
    exit 1
}

$patternFiles = @(Get-ChildItem -Path $sinRegistryDir -Filter 'SIN-PATTERN-*.json' -File -ErrorAction SilentlyContinue)
$patterns = New-Object System.Collections.Generic.List[object]
$registryInvalidDefinitions = New-Object System.Collections.Generic.List[object]
$registryAliasDefinitions = New-Object System.Collections.Generic.List[object]
$registryValidFiles = 0

foreach ($pf in $patternFiles) {
    try {
        $json = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($json)) {
            $registryInvalidDefinitions.Add([ordered]@{ file = $pf.Name; errors = @('empty definition') })
            continue
        }
        $validated = Get-SinRegistryDefinition -File $pf -Json $json
        if (-not $validated.valid) {
            $registryInvalidDefinitions.Add([ordered]@{ file = $pf.Name; errors = @($validated.errors) })
            Write-ScanLog "  [WARN] Invalid SIN definition in $($pf.Name): $(@($validated.errors) -join '; ')" 'Yellow'
            continue
        }
        $registryValidFiles++
        if (@($validated.usedAliases).Count -gt 0) { $registryAliasDefinitions.Add([ordered]@{ file = $pf.Name; aliases = @($validated.usedAliases) }) }
        $def = $validated.definition.raw
        $props = $def.PSObject.Properties.Name

        $sinId = $null
        if ($props -contains 'sin_id' -and -not [string]::IsNullOrWhiteSpace("$($def.sin_id)")) {
            $sinId = "$($def.sin_id)"
        }
        elseif ($props -contains 'id' -and -not [string]::IsNullOrWhiteSpace("$($def.id)")) {
            $sinId = "$($def.id)"
        }
        elseif ($props -contains 'pattern_id' -and -not [string]::IsNullOrWhiteSpace("$($def.pattern_id)")) {
            $patternIdText = "$($def.pattern_id)".Trim()
            if ($patternIdText -match '^(?i)P\d+$') {
                $digits = [int]($patternIdText -replace '^(?i)P', '')
                $sinId = ('SIN-PATTERN-{0:D3}' -f $digits)
            }
            else {
                $sinId = "SIN-PATTERN-$patternIdText"
            }
        }
        else {
            $sinId = if ($pf.BaseName -match '^(SIN-PATTERN-[^_]+)') { $Matches[1] } else { $pf.BaseName }
        }

        $scanRegex = $null
        if ($props -contains 'scan_regex' -and -not [string]::IsNullOrWhiteSpace("$($def.scan_regex)")) {
            $scanRegex = "$($def.scan_regex)"
        }
        elseif ($props -contains 'scanner_pattern' -and -not [string]::IsNullOrWhiteSpace("$($def.scanner_pattern)")) {
            $scanRegex = "$($def.scanner_pattern)"
        }
        elseif ($props -contains 'detection_regex' -and -not [string]::IsNullOrWhiteSpace("$($def.detection_regex)")) {
            $scanRegex = "$($def.detection_regex)"
        }

        if ($TargetPattern -ne '*' -and -not ($sinId -like "*$TargetPattern*")) { continue }

        if ([string]::IsNullOrWhiteSpace($scanRegex)) { continue }

        try { $null = [regex]::new($scanRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout) }
        catch {
            Write-ScanLog "  [WARN] Invalid scan_regex in $($pf.Name): $_" 'Yellow'
            continue
        }

        # Determine version scope and filter against -Runtime
        $scope = if ($props -contains 'ps_version_scope') { "$($def.ps_version_scope)" } else { 'BOTH' }
        if ($Runtime -eq 'PS7' -and $scope -eq 'PS51') { continue }   # PS5.1-only pattern - skip for PS7 target
        if ($Runtime -eq 'PS51' -and $scope -eq 'PS7') { continue }   # PS7-only pattern - skip for PS5.1 target

        $p = [ordered]@{
            SinId                 = $sinId
            Severity              = if ($props -contains 'severity') { "$($def.severity)" } else { 'MEDIUM' }
            Title                 = if ($props -contains 'title') { "$($def.title)" }    else { $sinId }
            ScanRegex             = $scanRegex
            Scope                 = $scope
            FileExcludeRegex      = if ($props -contains 'file_exclusion_regex' -and $null -ne $def.file_exclusion_regex) { "$($def.file_exclusion_regex)" } else { $null }
            ContextGuardRegex     = if ($props -contains 'context_guard_regex' -and $null -ne $def.context_guard_regex) { "$($def.context_guard_regex)" } else { $null }
            InlineGuardRegex      = if ($props -contains 'inline_guard_regex' -and $null -ne $def.inline_guard_regex) { "$($def.inline_guard_regex)" } else { $null }
            ContextGuardLines     = if ($props -contains 'context_guard_lines') { [int]$def.context_guard_lines } else { 0 }
            ContextGuardDirection = if ($props -contains 'context_guard_direction' -and $null -ne $def.context_guard_direction) { "$($def.context_guard_direction)" } else { 'above' }
            ScanFilePattern       = if ($props -contains 'scan_file_pattern' -and -not [string]::IsNullOrWhiteSpace("$($def.scan_file_pattern)")) { "$($def.scan_file_pattern)" } else { $null }
        }
        $patterns.Add($p)
    }
    catch {
        $registryInvalidDefinitions.Add([ordered]@{ file = $pf.Name; errors = @($_.Exception.Message) })
        Write-ScanLog "  [WARN] Failed to parse $($pf.Name): $_" 'Yellow'
    }
}

Write-ScanLog "SIN Pattern Scanner  [$scanId]" 'Cyan'
Write-ScanLog "Workspace : $WorkspacePath"
Write-ScanLog "Runtime   : $Runtime  (PS7-only patterns $(if ($Runtime -eq 'PS7') { 'SKIPPED' } elseif ($Runtime -eq 'PS51') { 'ONLY' } else { 'INCLUDED' }))"
Write-ScanLog "Patterns  : $($patterns.Count) loaded from $($patternFiles.Count) files"
Write-ScanLog ('-' * 60)

# ---- File discovery --------------------------------------------------------
$excludeDirs = @('.git', '.history', '.venv', '.venv-pygame312', 'node_modules',
    '~ARCHIVED', '~DOWNLOADS', '~REPORTS', 'checkpoints', 'UPM', 'sin_registry',
    'QUICK-APP', 'ActionPacks-master', 'temp')

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
$allowedExts = @('.ps1', '.psm1') + $normalizedExtras | Select-Object -Unique
Write-ScanLog ("Allowed exts : " + ($allowedExts -join ', ')) 'Cyan'

$allFiles = New-Object System.Collections.Generic.List[object]
if (@($IncludeFiles).Count -gt 0) {
    foreach ($inc in $IncludeFiles) {
        $path = if ([System.IO.Path]::IsPathRooted($inc)) { $inc } else { Join-Path $WorkspacePath $inc }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer) { continue }
        if ($ScanMode -ne 'Omega' -and $item.Extension.ToLowerInvariant() -notin $allowedExts) { continue }
        if (-not (@($allFiles | Where-Object { $_.FullName -eq $item.FullName }).Count -gt 0)) {
            $allFiles.Add($item)
        }
    }
}
else {
    if ($ScanMode -eq 'Omega') {
        $omegaFound = Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $omegaFound) {
            if (Test-PathUnderExcludedDir -FullPath $f.FullName -ExcludedNames $OmegaExcludeDirs) { continue }
            $allFiles.Add($f)
        }
    }
    else {
        $globs = @('*.ps1', '*.psm1') + ($normalizedExtras | ForEach-Object { '*' + $_ })
        foreach ($ext in ($globs | Select-Object -Unique)) {
            $found = Get-ChildItem -Path $WorkspacePath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $found) {
                $skip = $false
                $normalizedFullName = $f.FullName -replace '/', '\'
                foreach ($d in $excludeDirs) {
                    if ($normalizedFullName -like "*\$d\*") { $skip = $true; break }
                }
                if (-not $skip) { $allFiles.Add($f) }
            }
        }
    }
}

# Helper: does a file extension match a SIN pattern's scan_file_pattern (semicolon-delimited globs)?
function Test-PatternFileMatch {
    param([string]$FullName, [string]$ScanFilePattern)
    if ($ScanMode -eq 'Omega') { return $true }
    if ([string]::IsNullOrWhiteSpace($ScanFilePattern)) { return $true }
    $globs = $ScanFilePattern -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($g in $globs) {
        $g = $g.Trim()
        if ($g -like '*/*' -or $g -like '*\*') {
            # Path-relative glob (e.g. 'tests/Foo.ps1' or 'config/*.json')
            if ($FullName -like "*$($g.Replace('/','\'))*") { return $true }
        }
        else {
            $leaf = [System.IO.Path]::GetFileName($FullName)
            if ($leaf -like $g) { return $true }
        }
    }
    return $false
}

Write-ScanLog "Files to scan: $($allFiles.Count)"
Write-ScanLog "Scan mode    : $ScanMode"
$extBreakdown = $allFiles | Group-Object Extension | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-ScanLog ("  By extension: " + ($extBreakdown -join ', '))

# ---- Scan ------------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
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
                    $relPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\')
                    $findings.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; title = $pat.Title; file = $relPath; line = 1; content = '[NO BOM but non-ASCII bytes detected]' })
                    $patFinds++; $patRaw++; $totalRawMatches++
                }
            }
            # P023: double-encoded UTF-8 BOM (C3 AF C2 BB C2 BF) or mojibake marker (C3 A2 E2 80)
            if ($pat.SinId -like '*023*') {
                $doubleBom = $false
                if ($bytes.Length -ge 6 -and $bytes[0] -eq 0xC3 -and $bytes[1] -eq 0xAF -and $bytes[2] -eq 0xC2 -and $bytes[3] -eq 0xBB -and $bytes[4] -eq 0xC2 -and $bytes[5] -eq 0xBF) { $doubleBom = $true }
                $mojibake = $false
                for ($bi = 0; $bi -lt ($bytes.Length - 3); $bi++) {
                    if ($bytes[$bi] -eq 0xC3 -and $bytes[$bi + 1] -eq 0xA2 -and $bytes[$bi + 2] -eq 0xE2 -and $bytes[$bi + 3] -eq 0x80) { $mojibake = $true; break }
                }
                if ($doubleBom -or $mojibake) {
                    $relPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\')
                    $kind = if ($doubleBom) { '[Double-encoded BOM detected]' } else { '[Mojibake byte sequence C3 A2 E2 80 detected]' }
                    $findings.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; title = $pat.Title; file = $relPath; line = 1; content = $kind })
                    $patFinds++; $patRaw++; $totalRawMatches++
                }
            }
            # P082: batch/cmd displays non-ASCII UI (echo/set) without a `chcp 65001` codepage switch -> mojibake
            if ($pat.SinId -like '*082*') {
                $text = $null
                try { $text = [System.Text.Encoding]::UTF8.GetString($bytes) } catch { $text = $null }
                if ($null -ne $text) {
                    # Only displayed text matters: a chcp 65001 anywhere ahead of the echoes fixes rendering.
                    $hasChcpUtf8 = [regex]::IsMatch($text, '(?im)^\s*chcp\s+65001\b')
                    if (-not $hasChcpUtf8) {
                        $textLines = $text -split "`r`n|`n|`r"
                        for ($li = 0; $li -lt $textLines.Count; $li++) {
                            $ln = $textLines[$li]
                            # Skip REM / :: comment lines - comments are never rendered, so their Unicode is cosmetic-only.
                            $trim = $ln.TrimStart()
                            if ($trim -match '^(?i)@?\s*rem\b' -or $trim.StartsWith('::')) { continue }
                            $lineHasNonAscii = $false
                            foreach ($ch in $ln.ToCharArray()) { if ([int][char]$ch -gt 127) { $lineHasNonAscii = $true; break } }
                            if ($lineHasNonAscii) {
                                $relPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\')
                                $findings.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; title = $pat.Title; file = $relPath; line = ($li + 1); content = '[Displayed non-ASCII UI with no chcp 65001 -> mojibake risk]' })
                                $patFinds++; $patRaw++; $totalRawMatches++
                                break  # one finding per file is sufficient
                            }
                        }
                    }
                }
            }
        }
        $patternSummary.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; rawMatches = $patRaw; suppressed = $patSupp; findings = $patFinds })
        continue
    }

    if ($pat.ScanRegex -eq 'FILE_SIZE_CHECK') {
        $patRaw = 0; $patSupp = 0; $patFinds = 0
        $sizeLimitBytes = 5 * 1024 * 1024  # 5 MB
        foreach ($file in $allFiles) {
            if (-not (Test-PatternFileMatch -FullName $file.FullName -ScanFilePattern $pat.ScanFilePattern)) { continue }
            if ($file.Length -gt $sizeLimitBytes) {
                $relPath = $file.FullName.Replace($WorkspacePath, '').TrimStart('\')
                $sizeMB = [math]::Round($file.Length / 1MB, 2)
                $findings.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; title = $pat.Title; file = $relPath; line = 1; content = "[File size ${sizeMB}MB exceeds 5MB limit]" })
                $patFinds++; $patRaw++; $totalRawMatches++
            }
        }
        $patternSummary.Add([ordered]@{ sinId = $pat.SinId; severity = $pat.Severity; rawMatches = $patRaw; suppressed = $patSupp; findings = $patFinds })
        continue
    }
    # -- End special scan logic --

    $compiledScan = [regex]::new($pat.ScanRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout)
    $compiledExclude = if ($null -ne $pat.FileExcludeRegex) { [regex]::new($pat.FileExcludeRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout) } else { $null }
    $compiledGuard = if ($null -ne $pat.ContextGuardRegex) { [regex]::new($pat.ContextGuardRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout) } else { $null }
    $compiledInlineGuard = if ($null -ne $pat.InlineGuardRegex) { [regex]::new($pat.InlineGuardRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, $regexMatchTimeout) } else { $null }

    $patRaw = 0
    $patSupp = 0
    $patFinds = 0
    $script:CurrentPatternTimeouts = 0

    foreach ($file in $allFiles) {
        if ($script:CurrentPatternTimeouts -ge $regexTimeoutAbortThreshold) { break }
        if (-not (Test-PatternFileMatch -FullName $file.FullName -ScanFilePattern $pat.ScanFilePattern)) { continue }
        if ($null -ne $compiledExclude -and (Test-RegexMatchSafe -Regex $compiledExclude -InputText $file.FullName)) { continue }

        $lineArr = $null
        try { $lineArr = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop) }
        catch { continue }
        if ($null -eq $lineArr) { continue }
        $lineCount = $lineArr.Count

        $inBlockComment = $false
        $inHereStringDQ = $false
        $inHereStringSQ = $false

        for ($i = 0; $i -lt $lineCount; $i++) {
            if ($script:CurrentPatternTimeouts -ge $regexTimeoutAbortThreshold) { break }
            $line = $lineArr[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

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

            if ($line -match '^\s*#') { continue }
            if ($line -match '#\s*SIN-EXEMPT:') { continue }

            if (-not (Test-RegexMatchSafe -Regex $compiledScan -InputText $line)) { continue }
            $totalRawMatches++
            $patRaw++

            $suppressed = $false
            if ($null -ne $compiledInlineGuard -and (Test-RegexMatchSafe -Regex $compiledInlineGuard -InputText $line)) {
                $suppressed = $true
            }
            if ($null -ne $compiledGuard) {
                if ($pat.ContextGuardLines -eq 0) {
                    # ContextGuardLines=0 means same-line guard: suppress if the guard regex
                    # also matches the current line (e.g. TODO inside a string literal)
                    if (Test-RegexMatchSafe -Regex $compiledGuard -InputText $line) { $suppressed = $true }
                }
                else {
                    $guardDirection = "$($pat.ContextGuardDirection)".ToLowerInvariant()
                    switch ($guardDirection) {
                        'below' {
                            $gStart = [Math]::Min($lineCount - 1, $i + 1)
                            $gEnd = [Math]::Min($lineCount - 1, $i + $pat.ContextGuardLines)
                        }
                        'both' {
                            $gStart = [Math]::Max(0, $i - $pat.ContextGuardLines)
                            $gEnd = [Math]::Min($lineCount - 1, $i + $pat.ContextGuardLines)
                        }
                        default {
                            $gStart = [Math]::Max(0, $i - $pat.ContextGuardLines)
                            $gEnd = [Math]::Max(0, $i - 1)
                        }
                    }
                    for ($g = $gStart; $g -le $gEnd; $g++) {
                        if (Test-RegexMatchSafe -Regex $compiledGuard -InputText $lineArr[$g]) { $suppressed = $true; break }
                    }
                }
            }

            if ($suppressed) { $totalSuppressed++; $patSupp++; continue }

            $trimmed = $line.Trim()
            $snip = $trimmed.Substring(0, [Math]::Min(160, $trimmed.Length))
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

    if ($script:CurrentPatternTimeouts -ge $regexTimeoutAbortThreshold) {
        Write-ScanLog "  [WARN] $($pat.SinId): regex timeout threshold reached; remaining files skipped for this pattern" 'Yellow'
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
$highCount = @($findings | Where-Object { $_.severity -eq 'HIGH' }).Count
$medCount = @($findings | Where-Object { $_.severity -eq 'MEDIUM' }).Count
$lowCount = @($findings | Where-Object { $_.severity -eq 'LOW' }).Count
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
    Write-ScanLog "  Regex timeouts  : $($script:RegexMatchTimeoutCount)" $(if ($script:RegexMatchTimeoutCount -gt 0) { 'Yellow' } else { 'Gray' })

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
    }
    catch {
        Write-ScanLog "  [WARN] Failed to load baseline: $_" 'Yellow'
    }
}

$resultObj = [ordered]@{
    runtime                    = $Runtime
    scanMode                   = $ScanMode
    scanId                     = $scanId
    timestamp                  = (Get-Date -Format 'o')
    workspace                  = $WorkspacePath
    patternsLoaded             = $patterns.Count
    filesScanned               = $allFiles.Count
    totalFindings              = $findings.Count
    critical                   = $critCount
    high                       = $highCount
    medium                     = $medCount
    low                        = $lowCount
    blockedById                = $blockedById
    blockedCount               = $blockedCount
    regexTimeoutMs             = [int]$regexMatchTimeout.TotalMilliseconds
    regexTimeoutAbortThreshold = $regexTimeoutAbortThreshold
    regexTimeouts              = $script:RegexMatchTimeoutCount
    totalRawMatches            = $totalRawMatches
    totalSuppressed            = $totalSuppressed
    elapsedMs                  = $sw.ElapsedMilliseconds
    patternSummary             = $patternSummary.ToArray()
    findings                   = $findings.ToArray()
    countsBySinId              = $currentCounts
    baselinePath               = $BaselineJson
    baselineApplied            = $baselineApplied
    ratchetMode                = $RatchetMode
    regressions                = $regressions
    improvements               = $improvements
    registry                   = [ordered]@{
        filesDiscovered         = $patternFiles.Count
        validDefinitions        = $registryValidFiles
        invalidDefinitions      = $registryInvalidDefinitions.ToArray()
        invalidCount            = $registryInvalidDefinitions.Count
        compatibilityAliasCount = $registryAliasDefinitions.Count
        compatibilityAliases    = $registryAliasDefinitions.ToArray()
    }
    coverage                   = [ordered]@{
        staged              = (@($IncludeFiles).Count -gt 0)
        stagedFallback      = if (@($IncludeFiles).Count -gt 0) { 'explicit-include' } else { 'workspace-discovery' }
        discoveredFiles     = $allFiles.Count
        applicablePatterns  = $patterns.Count
        patternsWithMatches = @($patternSummary | Where-Object { [int]$_.rawMatches -gt 0 }).Count
        percent             = if ($patterns.Count -gt 0) { [math]::Round((100 * @($patternSummary | Where-Object { [int]$_.rawMatches -gt 0 }).Count) / $patterns.Count, 2) } else { 0 }
        minimumPercent      = $MinimumCoveragePercent
    }
}

# ---- OMEGA auto-route to pipeline + checkpoints ---------------------------
$omegaEnabled = [bool]$OmegaPipelineAutoRoute
$omegaModeSelected = ($ScanMode -eq 'Omega')
$omegaHasFindings = ($findings.Count -gt 0)
if ($omegaEnabled -and $omegaModeSelected -and $omegaHasFindings) {
    $pipelineModule = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
    $omegaSummary = [ordered]@{
        enabled              = $true
        routeTimeoutMs       = [int]$OmegaRouteOpTimeoutMs
        routeTimeouts        = 0
        manifestPathSetCount = 0
        fileGroups           = 0
        manifestLinked       = 0
        nonManifest          = 0
        bugsCreated          = 0
        bugs2FixCreated      = 0
        items2AddCreated     = 0
        checkpointsCreated   = 0
        fallbackArtifacts    = 0
        trace                = @()
        errors               = @()
    }

    if (Test-Path -LiteralPath $pipelineModule) {
        try {
            Import-Module $pipelineModule -Force -DisableNameChecking -ErrorAction Stop
            $manifestSet = Get-ManifestPathSet -WorkspacePath $WorkspacePath
            $omegaSummary.manifestPathSetCount = @($manifestSet).Count

            $grouped = @($findings | Group-Object file)
            $omegaSummary.fileGroups = @($grouped).Count

            foreach ($fg in $grouped) {
                $fileRel = [string]$fg.Name
                $fileFindings = @($fg.Group)
                $isManifestLinked = $manifestSet.Contains($fileRel)

                if ($isManifestLinked) {
                    $omegaSummary.manifestLinked++
                    try {
                        $sevOrder = @{ CRITICAL = 4; HIGH = 3; MEDIUM = 2; LOW = 1 }
                        $top = @($fileFindings | Sort-Object { if ($sevOrder.ContainsKey($_.severity)) { -1 * $sevOrder[$_.severity] } else { 0 } }) | Select-Object -First 1
                        $bug = New-PipelineItem -Type 'Bug' -Title ("OMEGA Manifest SIN: {0}" -f $fileRel) `
                            -Description ("OMEGA scan found {0} issue(s) in manifest-linked file {1}. SINs: {2}" -f @($fileFindings).Count, $fileRel, (@($fileFindings | ForEach-Object { $_.sinId } | Sort-Object -Unique) -join ', ')) `
                            -Priority (if ($null -ne $top -and $top.severity -eq 'CRITICAL') { 'CRITICAL' } elseif ($null -ne $top -and $top.severity -eq 'HIGH') { 'HIGH' } else { 'MEDIUM' }) `
                            -Source 'AutoCron' -Category 'manifest-omega' -AffectedFiles @($fileRel) -SuggestedBy 'OMEGA-Scanner'
                        $opBug = Invoke-OmegaPipelineBoundedOperation -PipelineModulePath $pipelineModule -WorkspacePath $WorkspacePath -Operation 'AddItem' -TimeoutMs $OmegaRouteOpTimeoutMs -Item $bug
                        $omegaSummary.trace += ([ordered]@{ file = $fileRel; route = 'manifest'; operation = 'AddItem(Bug)'; ok = [bool]$opBug.ok; timedOut = [bool]$opBug.timedOut; elapsedMs = [int]$opBug.elapsedMs; error = [string]$opBug.error })
                        if ($opBug.timedOut) { $omegaSummary.routeTimeouts++ }
                        if ($opBug.ok -and $null -ne $opBug.result) {
                            $omegaSummary.bugsCreated++
                            $addedBug = $opBug.result
                        }
                        else {
                            $cpPath = New-OmegaFallbackArtifact -WorkspacePath $WorkspacePath -RouteType 'manifest' -File $fileRel -FileFindings $fileFindings -Operation 'AddItem(Bug)' -Reason $opBug.error -TimedOut ([bool]$opBug.timedOut) -ElapsedMs ([int]$opBug.elapsedMs) -TimeoutMs ([int]$OmegaRouteOpTimeoutMs)
                            if (-not [string]::IsNullOrWhiteSpace($cpPath)) { $omegaSummary.checkpointsCreated++; $omegaSummary.fallbackArtifacts++ }
                            continue
                        }

                        $bugDescription = if ($addedBug.PSObject.Properties.Name -contains 'description') { [string]$addedBug.description } else { '' }
                        $fix = New-PipelineItem -Type 'Bugs2FIX' -Title ("FIX: {0}" -f $addedBug.title) `
                            -Description ("OMEGA auto-route fix for {0}: {1}" -f $addedBug.id, $bugDescription) `
                            -Priority $addedBug.priority -Source 'AutoCron' -Category 'manifest-omega' `
                            -AffectedFiles @($fileRel) -SuggestedBy 'OMEGA-Scanner' `
                            -ParentId $addedBug.id -BugReferrals @($addedBug.id) `
                            -SinId (if ($addedBug.PSObject.Properties.Name -contains 'sinId') { [string]$addedBug.sinId } else { '' }) `
                            -SinPattern (if ($addedBug.PSObject.Properties.Name -contains 'sinPattern') { [string]$addedBug.sinPattern } else { '' })
                        $opFix = Invoke-OmegaPipelineBoundedOperation -PipelineModulePath $pipelineModule -WorkspacePath $WorkspacePath -Operation 'AddItem' -TimeoutMs $OmegaRouteOpTimeoutMs -Item $fix
                        $omegaSummary.trace += ([ordered]@{ file = $fileRel; route = 'manifest'; operation = 'AddItem(Bugs2FIX)'; ok = [bool]$opFix.ok; timedOut = [bool]$opFix.timedOut; elapsedMs = [int]$opFix.elapsedMs; error = [string]$opFix.error })
                        if ($opFix.timedOut) { $omegaSummary.routeTimeouts++ }
                        if ($opFix.ok -and $null -ne $opFix.result) {
                            $omegaSummary.bugs2FixCreated++
                            $addedFix = $opFix.result
                            $opStatus = Invoke-OmegaPipelineBoundedOperation -PipelineModulePath $pipelineModule -WorkspacePath $WorkspacePath -Operation 'UpdateStatus' -TimeoutMs $OmegaRouteOpTimeoutMs -ItemId ([string]$addedFix.id) -NewStatus 'PLANNED' -Notes 'OMEGA auto-routed manifest issue'
                            $omegaSummary.trace += ([ordered]@{ file = $fileRel; route = 'manifest'; operation = 'UpdateStatus(PLANNED)'; ok = [bool]$opStatus.ok; timedOut = [bool]$opStatus.timedOut; elapsedMs = [int]$opStatus.elapsedMs; error = [string]$opStatus.error })
                            if ($opStatus.timedOut) { $omegaSummary.routeTimeouts++ }
                        }
                        else {
                            $cpPath = New-OmegaFallbackArtifact -WorkspacePath $WorkspacePath -RouteType 'manifest' -File $fileRel -FileFindings $fileFindings -Operation 'AddItem(Bugs2FIX)' -Reason $opFix.error -TimedOut ([bool]$opFix.timedOut) -ElapsedMs ([int]$opFix.elapsedMs) -TimeoutMs ([int]$OmegaRouteOpTimeoutMs)
                            if (-not [string]::IsNullOrWhiteSpace($cpPath)) { $omegaSummary.checkpointsCreated++; $omegaSummary.fallbackArtifacts++ }
                        }
                    }
                    catch {
                        $omegaSummary.errors += ("manifest-route {0}: {1}" -f $fileRel, $_.Exception.Message)
                    }
                }
                else {
                    $omegaSummary.nonManifest++
                    try {
                        $item = New-PipelineItem -Type 'Items2ADD' -Title ("FEATURES2ADD OMEGA checkpoint: {0}" -f $fileRel) `
                            -Description ("File is not represented in current manifest set. OMEGA findings: {0}. SINs: {1}. If approved, add to manifest and integrate pipeline flow." -f @($fileFindings).Count, (@($fileFindings | ForEach-Object { $_.sinId } | Sort-Object -Unique) -join ', ')) `
                            -Priority 'MEDIUM' -Source 'Subagent' -Category 'omega-checkpoint' -SuggestedBy 'OMEGA-Scanner' -AffectedFiles @($fileRel)
                        $opItem = Invoke-OmegaPipelineBoundedOperation -PipelineModulePath $pipelineModule -WorkspacePath $WorkspacePath -Operation 'AddItem' -TimeoutMs $OmegaRouteOpTimeoutMs -Item $item
                        $omegaSummary.trace += ([ordered]@{ file = $fileRel; route = 'nonmanifest'; operation = 'AddItem(Items2ADD)'; ok = [bool]$opItem.ok; timedOut = [bool]$opItem.timedOut; elapsedMs = [int]$opItem.elapsedMs; error = [string]$opItem.error })
                        if ($opItem.timedOut) { $omegaSummary.routeTimeouts++ }
                        if ($opItem.ok -and $null -ne $opItem.result) {
                            $addedItem = $opItem.result
                            $omegaSummary.items2AddCreated++
                            $cpPath = New-OmegaCheckpointEntry -WorkspacePath $WorkspacePath -File $fileRel -FileFindings $fileFindings -LinkedItemId $addedItem.id
                            if (-not [string]::IsNullOrWhiteSpace($cpPath)) { $omegaSummary.checkpointsCreated++ }
                        }
                        else {
                            $cpPath = New-OmegaFallbackArtifact -WorkspacePath $WorkspacePath -RouteType 'nonmanifest' -File $fileRel -FileFindings $fileFindings -Operation 'AddItem(Items2ADD)' -Reason $opItem.error -TimedOut ([bool]$opItem.timedOut) -ElapsedMs ([int]$opItem.elapsedMs) -TimeoutMs ([int]$OmegaRouteOpTimeoutMs)
                            if (-not [string]::IsNullOrWhiteSpace($cpPath)) { $omegaSummary.checkpointsCreated++; $omegaSummary.fallbackArtifacts++ }
                        }
                    }
                    catch {
                        $omegaSummary.errors += ("nonmanifest-route {0}: {1}" -f $fileRel, $_.Exception.Message)
                    }
                }
            }

            # OMEGA scan should not block on heavy artifact rebuilds; downstream cron can refresh artifacts.
            # try { $null = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath } catch { <# Intentional: non-fatal #> }
        }
        catch {
            $omegaSummary.errors += ("pipeline-module: " + $_.Exception.Message)
        }
    }
    else {
        $omegaSummary.errors += ("pipeline-module-missing: {0}" -f $pipelineModule)
    }

    $resultObj['omega'] = $omegaSummary
}

ConvertTo-Json $resultObj -Depth 8 | Set-Content -LiteralPath $OutputJson -Encoding UTF8

if ($SummaryOnly) {
    $resultObj = [ordered]@{
        runtime                    = $resultObj.runtime
        scanMode                   = $resultObj.scanMode
        scanId                     = $resultObj.scanId
        timestamp                  = $resultObj.timestamp
        workspace                  = $resultObj.workspace
        patternsLoaded             = $resultObj.patternsLoaded
        filesScanned               = $resultObj.filesScanned
        totalFindings              = $resultObj.totalFindings
        critical                   = $resultObj.critical
        high                       = $resultObj.high
        medium                     = $resultObj.medium
        low                        = $resultObj.low
        blockedById                = $resultObj.blockedById
        blockedCount               = $resultObj.blockedCount
        regexTimeoutMs             = $resultObj.regexTimeoutMs
        regexTimeoutAbortThreshold = $resultObj.regexTimeoutAbortThreshold
        regexTimeouts              = $resultObj.regexTimeouts
        totalRawMatches            = $resultObj.totalRawMatches
        totalSuppressed            = $resultObj.totalSuppressed
        elapsedMs                  = $resultObj.elapsedMs
        countsBySinId              = $resultObj.countsBySinId
        baselinePath               = $resultObj.baselinePath
        baselineApplied            = $resultObj.baselineApplied
        ratchetMode                = $resultObj.ratchetMode
        regressions                = $resultObj.regressions
        improvements               = $resultObj.improvements
    }
}

if (-not $Quiet) { Write-ScanLog "Results  : $OutputJson" }

if ($FailOnInvalidRegistry -and $registryInvalidDefinitions.Count -gt 0) {
    Write-ScanLog "[PIPELINE BLOCKED] $($registryInvalidDefinitions.Count) invalid SIN registry definition(s)." 'Red'
    exit 1
}
if ($MinimumCoveragePercent -gt 0 -and [double]$resultObj.coverage.percent -lt $MinimumCoveragePercent) {
    Write-ScanLog "[PIPELINE BLOCKED] Registry scan coverage $($resultObj.coverage.percent)% is below $MinimumCoveragePercent%." 'Red'
    exit 1
}

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
        }
        elseif ($RatchetMode -eq 'Strict' -and $improvements.Count -gt 0) {
            $blockNeeded = $true
            $blockReason = "Strict mode: $($improvements.Count) un-recorded improvement(s) - refresh baseline (-UpdateBaseline): " + (($improvements | ForEach-Object { "$($_.sinId): $($_.baseline)->$($_.current) (-$($_.delta))" }) -join '; ')
        }
        if ($blockNeeded) {
            Write-ScanLog "[PIPELINE BLOCKED] $blockReason" 'Red'
            exit 1
        }
        else {
            Write-ScanLog "[PIPELINE OK] $critCount CRITICAL finding(s) all within baseline tolerance. No regressions." 'Green'
        }
    }
    else {
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







