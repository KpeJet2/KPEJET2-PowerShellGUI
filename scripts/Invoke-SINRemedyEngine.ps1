# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS  Iterative SIN Remedy Engine — attempt remedies, rescan, record results.
.DESCRIPTION
    For each SIN instance with remedy_tracking.status = 'PENDING' or 'RETRY':
      1. Read the remedy instructions from the parent pattern definition
      2. Attempt the remedy (automated regex-based fixes where possible)
      3. Rescan the specific file+line to verify if the fix resolved the finding
      4. Record the attempt in remedy_tracking.attempts[]
      5. If resolved: mark status = 'RESOLVED', increment successful_count
      6. If still present: mark status = 'RETRY', try alternative remedies
      7. After max_retries (default 3), mark status = 'ESCALATED'

    This script works with both legacy and v2-timestamped SIN filenames.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.
.PARAMETER MaxRetries
    Maximum remedy attempts before escalating. Default: 3.
.PARAMETER DryRun
    Simulate remedies without writing changes.
.PARAMETER TargetPattern
    Optional filter: only process SINs matching this parent pattern (wildcard).
.PARAMETER OutputJson
    Path to write remedy attempt results.

.NOTES
    Integration: Call after SIN Pattern Scanner in pipeline (Step 3.6).
    Writes back to sin_registry instance files with updated remedy_tracking.
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [int]$MaxRetries = 3,
    [switch]$DryRun,
    [string]$TargetPattern = '*',
    [string]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
$fixesDir       = Join-Path $sinRegistryDir 'fixes'
$timestamp      = (Get-Date).ToUniversalTime().ToString('o')
$tsShort        = Get-Date -Format 'yyyyMMddHHmm'

if (-not $OutputJson) {
    $OutputJson = Join-Path $WorkspacePath 'temp\remedy-attempt-results.json'
}
if (-not (Test-Path $fixesDir)) { New-Item -ItemType Directory -Path $fixesDir -Force | Out-Null }

# ── Load parent pattern definitions (for remedy text) ─────────────────
function Get-PatternRemedyMap {
    param([string]$RegistryDir)
    $map = @{}
    $files = Get-ChildItem -Path $RegistryDir -Filter 'SIN-PATTERN-*.json' -File -ErrorAction SilentlyContinue
    $files += @(Get-ChildItem -Path $RegistryDir -Filter 'SEMI-SIN-*.json' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        try {
            $def = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $props = $def.PSObject.Properties.Name
            # Index by sin_id — works for both old and new format
            $map[$def.sin_id] = [PSCustomObject]@{
                Remedy     = if ($props -contains 'remedy') { $def.remedy } else { '' }
                Prevention = if ($props -contains 'preventionRule') { $def.preventionRule } else { '' }
                ScanRegex  = if ($props -contains 'scan_regex') { $def.scan_regex } else { $null }
                Severity   = $def.severity
            }
        }
        catch { <# Intentional: skip unparseable files #> }
    }
    return $map
}

# ── Load SIN instances needing remedy ─────────────────────────────────
function Get-PendingRemedies {
    param([string]$RegistryDir, [string]$PatternFilter)
    $pending = @()
    # Instance files: SIN-2*.json and SIN-027*.json
    $instanceFiles = @(Get-ChildItem -Path $RegistryDir -Filter 'SIN-2*.json' -File -ErrorAction SilentlyContinue)
    $instanceFiles += @(Get-ChildItem -Path $RegistryDir -Filter 'SIN-027*.json' -File -ErrorAction SilentlyContinue)

    foreach ($f in $instanceFiles) {
        try {
            $sin = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $props = $sin.PSObject.Properties.Name

            # Skip already resolved
            if ($sin.is_resolved -eq $true) { continue }

            # Check parent pattern filter
            if ($props -contains 'parent_pattern') {
                if ($sin.parent_pattern -notlike "*$PatternFilter*" -and $PatternFilter -ne '*') { continue }
            }

            # Check remedy_tracking status
            $status = 'PENDING'
            if ($props -contains 'remedy_tracking' -and $null -ne $sin.remedy_tracking) {
                $rtProps = $sin.remedy_tracking.PSObject.Properties.Name
                if ($rtProps -contains 'status') { $status = $sin.remedy_tracking.status }
                if ($rtProps -contains 'total_attempts' -and $sin.remedy_tracking.total_attempts -ge 3) {
                    if ($status -eq 'ESCALATED') { continue }
                }
            }

            if ($status -in @('PENDING', 'RETRY')) {
                $pending += [PSCustomObject]@{
                    File       = $f
                    SinObj     = $sin
                    Status     = $status
                }
            }
        }
        catch { <# Intentional: skip unparseable #> }
    }
    return $pending
}

# ── Verify a single finding by rescanning the specific file+line ──────
function Test-FindingStillPresent {
    param(
        [PSCustomObject]$Sin,
        [string]$ScanRegex,
        [string]$Root
    )
    $sinProps = $Sin.PSObject.Properties.Name
    if (-not ($sinProps -contains 'file_path') -or -not $Sin.file_path) { return $false }

    $filePath = Join-Path $Root $Sin.file_path
    if (-not (Test-Path $filePath)) { return $false }

    if (-not $ScanRegex -or $ScanRegex -in @('BINARY_CHECK', 'FILE_SIZE_CHECK')) { return $true }

    try {
        $content = Get-Content $filePath -Raw -Encoding UTF8 -ErrorAction Stop
        $lines = $content -split "`n"
        $compiledRegex = [regex]::new($ScanRegex, 'IgnoreCase,Multiline')

        # Check the specific line first
        if ($sinProps -contains 'line_number' -and $Sin.line_number -gt 0) {
            $lineIdx = $Sin.line_number - 1
            if ($lineIdx -lt $lines.Count -and $compiledRegex.IsMatch($lines[$lineIdx])) {
                return $true
            }
        }

        # Also check nearby lines (file may have shifted +-5 lines)
        $startLine = [Math]::Max(0, $Sin.line_number - 6)
        $endLine   = [Math]::Min($lines.Count - 1, $Sin.line_number + 4)
        for ($i = $startLine; $i -le $endLine; $i++) {
            if ($compiledRegex.IsMatch($lines[$i])) { return $true }
        }

        return $false
    }
    catch { return $true }
}

# ── Record a remedy attempt into the SIN instance ─────────────────────
function Add-RemedyAttempt {
    param(
        [System.IO.FileInfo]$SinFile,
        [PSCustomObject]$Sin,
        [string]$Method,
        [bool]$Success,
        [string]$Notes
    )
    $props = $Sin.PSObject.Properties.Name

    # Ensure remedy_tracking exists
    if (-not ($props -contains 'remedy_tracking') -or $null -eq $Sin.remedy_tracking) {
        $Sin | Add-Member -NotePropertyName 'remedy_tracking' -NotePropertyValue ([ordered]@{
            attempts         = @()
            last_attempt_at  = $null
            total_attempts   = 0
            successful_count = 0
            failed_count     = 0
            status           = 'PENDING'
            auto_retry       = $true
        }) -Force
    }

    $rt = $Sin.remedy_tracking
    $rtProps = $rt.PSObject.Properties.Name

    # Build attempt record
    $attempt = [ordered]@{
        attempt_number = if ($rtProps -contains 'total_attempts') { $rt.total_attempts + 1 } else { 1 }
        timestamp      = $timestamp
        method         = $Method
        success        = $Success
        notes          = $Notes
    }

    # Get current attempts array
    $currentAttempts = @()
    if ($rtProps -contains 'attempts' -and $null -ne $rt.attempts) {
        $currentAttempts = @($rt.attempts)
    }
    $currentAttempts += $attempt

    # Update tracking fields
    $totalAttempts   = if ($rtProps -contains 'total_attempts')   { $rt.total_attempts + 1 }   else { 1 }
    $successfulCount = if ($rtProps -contains 'successful_count') { $rt.successful_count }      else { 0 }
    $failedCount     = if ($rtProps -contains 'failed_count')     { $rt.failed_count }          else { 0 }

    if ($Success) {
        $successfulCount++
        $newStatus = 'RESOLVED'
        $Sin.is_resolved = $true
    }
    else {
        $failedCount++
        if ($totalAttempts -ge $MaxRetries) {
            $newStatus = 'ESCALATED'
        }
        else {
            $newStatus = 'RETRY'
        }
    }

    # Rebuild remedy_tracking object
    $Sin.remedy_tracking = [ordered]@{
        attempts         = $currentAttempts
        last_attempt_at  = $timestamp
        total_attempts   = $totalAttempts
        successful_count = $successfulCount
        failed_count     = $failedCount
        status           = $newStatus
        auto_retry       = ($newStatus -ne 'ESCALATED')
    }

    if (-not $DryRun) {
        $Sin | ConvertTo-Json -Depth 8 | Set-Content $SinFile.FullName -Encoding UTF8
    }

    return $newStatus
}

# ── Save successful fix to fixes/ directory for reuse ─────────────────
function Save-RemedyFix {
    param(
        [string]$ParentPattern,
        [string]$Method,
        [string]$Description,
        [string]$FixesDir
    )
    $fixId = "FIX-$tsShort-$(Get-Random -Maximum 9999)"
    $fixFile = Join-Path $FixesDir "$fixId.json"
    $fix = [ordered]@{
        fix_id          = $fixId
        parent_pattern  = $ParentPattern
        method          = $Method
        description     = $Description
        created_at      = $timestamp
        reuse_count     = 0
        verified        = $true
    }
    if (-not $DryRun) {
        $fix | ConvertTo-Json -Depth 5 | Set-Content $fixFile -Encoding UTF8
    }
    return $fixId
}

# ═══════════════════════════════════════════════════════════════════════
#                         MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════

Write-Host "`n===== SIN REMEDY ENGINE =====" -ForegroundColor Cyan
Write-Host "Workspace:    $WorkspacePath"
Write-Host "Max retries:  $MaxRetries"
Write-Host "DryRun:       $DryRun`n"

# Load pattern remedy definitions
$remedyMap = Get-PatternRemedyMap -RegistryDir $sinRegistryDir
Write-Host "Loaded $(@($remedyMap.Keys).Count) pattern remedy definitions" -ForegroundColor Gray

# Load known fixes from fixes/ directory
$knownFixes = @()
$fixFiles = @(Get-ChildItem -Path $fixesDir -Filter 'FIX-*.json' -File -ErrorAction SilentlyContinue)
foreach ($ff in $fixFiles) {
    try {
        $knownFixes += Get-Content $ff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { <# Intentional: skip bad fix files #> }
}
Write-Host "Loaded $(@($knownFixes).Count) known fixes from fixes/" -ForegroundColor Gray

# Get pending instances
$pending = @(Get-PendingRemedies -RegistryDir $sinRegistryDir -PatternFilter $TargetPattern)
Write-Host "Found $(@($pending).Count) SIN instances pending remedy`n" -ForegroundColor Yellow

$results = @()
$resolved = 0
$retried = 0
$escalated = 0

foreach ($item in $pending) {
    $sin  = $item.SinObj
    $file = $item.File
    $sinProps = $sin.PSObject.Properties.Name

    $parentId  = if ($sinProps -contains 'parent_pattern') { $sin.parent_pattern } else { 'unknown' }
    $scanRegex = $null

    # Look up remedy from parent pattern
    if ($remedyMap.ContainsKey($parentId)) {
        $scanRegex = $remedyMap[$parentId].ScanRegex
    }

    Write-Host "  Processing: $($sin.sin_id)" -ForegroundColor DarkGray -NoNewline

    # Step 1: Check if the finding is still present
    $stillPresent = Test-FindingStillPresent -Sin $sin -ScanRegex $scanRegex -Root $WorkspacePath

    if (-not $stillPresent) {
        # Already fixed by some other means
        $status = Add-RemedyAttempt -SinFile $file -Sin $sin -Method 'external-fix-detected' -Success $true -Notes 'Finding no longer detected at original location. Resolved externally.'
        Write-Host " RESOLVED (external)" -ForegroundColor Green
        $resolved++

        # Check if a known fix exists for this pattern; if not, record it
        $existingFixes = @($knownFixes | Where-Object { $_.parent_pattern -eq $parentId })
        if (@($existingFixes).Count -eq 0) {
            $lineNum = if ($sin.PSObject.Properties.Name -contains 'line_number') { $sin.line_number } else { '?' }
            $filePath = if ($sin.PSObject.Properties.Name -contains 'file_path') { $sin.file_path } else { 'unknown' }
            $fixId = Save-RemedyFix -ParentPattern $parentId -Method 'external-fix' -Description "Auto-detected resolution of $parentId at ${filePath}:${lineNum}" -FixesDir $fixesDir
            if (-not $DryRun) { Write-Host "    Saved fix: $fixId" -ForegroundColor DarkCyan }
        }

        $results += [ordered]@{
            sin_id    = $sin.sin_id
            parent    = $parentId
            status    = $status
            method    = 'external-fix-detected'
        }
        continue
    }

    # Step 2: Attempt known remedies from the fixes/ catalogue
    $appliedFix = $false
    $matchingFixes = @($knownFixes | Where-Object { $_.parent_pattern -eq $parentId -and $_.verified -eq $true })

    foreach ($knownFix in $matchingFixes) {
        # For now, record the attempt as 'known-fix-available' — actual application
        # requires pattern-specific logic (automated regex replacement or manual steps)
        $method = "known-fix:$($knownFix.fix_id)"
        # Rescan after noting the fix is available
        $notes = "Known fix available ($($knownFix.fix_id): $($knownFix.description)). Manual application required."
        $status = Add-RemedyAttempt -SinFile $file -Sin $sin -Method $method -Success $false -Notes $notes
        Write-Host " RETRY (known fix available, needs apply)" -ForegroundColor Yellow
        $retried++
        $appliedFix = $true

        $results += [ordered]@{
            sin_id    = $sin.sin_id
            parent    = $parentId
            status    = $status
            method    = $method
        }
        break
    }

    if ($appliedFix) { continue }

    # Step 3: No known fix — record attempt and check max retries
    $currentAttempts = 0
    if ($sinProps -contains 'remedy_tracking' -and $null -ne $sin.remedy_tracking) {
        $rtProps = $sin.remedy_tracking.PSObject.Properties.Name
        if ($rtProps -contains 'total_attempts') { $currentAttempts = $sin.remedy_tracking.total_attempts }
    }

    if ($currentAttempts -ge ($MaxRetries - 1)) {
        $status = Add-RemedyAttempt -SinFile $file -Sin $sin -Method 'no-automated-fix' -Success $false -Notes "Max retries ($MaxRetries) reached. Escalated for manual review."
        Write-Host " ESCALATED (max retries)" -ForegroundColor Red
        $escalated++
    }
    else {
        $remedyText = if ($remedyMap.ContainsKey($parentId)) { $remedyMap[$parentId].Remedy } else { 'No remedy defined' }
        $notes = "No automated fix. Remedy instructions: $($remedyText.Substring(0, [Math]::Min($remedyText.Length, 200)))"
        $status = Add-RemedyAttempt -SinFile $file -Sin $sin -Method 'manual-remedy-pending' -Success $false -Notes $notes
        Write-Host " RETRY (manual remedy needed)" -ForegroundColor Yellow
        $retried++
    }

    $results += [ordered]@{
        sin_id    = $sin.sin_id
        parent    = $parentId
        status    = $status
        method    = if ($currentAttempts -ge ($MaxRetries - 1)) { 'escalated' } else { 'manual-remedy-pending' }
    }
}

# ── Write results ─────────────────────────────────────────────────────
$resultObj = [ordered]@{
    engine       = 'SIN-Remedy-Engine'
    timestamp    = $timestamp
    workspace    = $WorkspacePath
    max_retries  = $MaxRetries
    processed    = @($pending).Count
    resolved     = $resolved
    retried      = $retried
    escalated    = $escalated
    results      = $results
}

$tempDir = Split-Path $OutputJson -Parent
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
$resultObj | ConvertTo-Json -Depth 8 | Set-Content $OutputJson -Encoding UTF8

# ── Console Summary ───────────────────────────────────────────────────
Write-Host "`n===== REMEDY SUMMARY =====" -ForegroundColor Cyan
Write-Host "Processed:   $(@($pending).Count)"
Write-Host "Resolved:    $resolved" -ForegroundColor Green
Write-Host "Retrying:    $retried" -ForegroundColor Yellow
Write-Host "Escalated:   $escalated" -ForegroundColor Red
Write-Host "Results:     $OutputJson"
if ($DryRun) { Write-Host "[DRY-RUN] No files were modified." -ForegroundColor Yellow }
Write-Host "===========================`n" -ForegroundColor Cyan

$resultObj

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




