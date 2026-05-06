# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS  Reindex the SIN Registry — rename all SIN-PATTERN and SEMI-SIN files
           to include a _yyyyMMddhhmm timestamp suffix.
.DESCRIPTION
    Scans sin_registry/ for all SIN-PATTERN-*.json and SEMI-SIN-*.json files.
    For each file:
      1. Reads the JSON content
      2. Appends _yyyyMMddhhmm (from the file's created_at or current time) to the filename
      3. Updates the internal sin_id to match the new name
      4. Adds remedy_tracking schema fields if not present
      5. Writes the updated file under the new name
      6. Removes the old file
      7. Logs the mapping to sin_registry/REINDEX-MAP.json

    Also updates all SIN-YYYYMMDD instance files to reference the new parent_pattern IDs.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.
.PARAMETER DryRun
    Preview renames without writing any files.
.PARAMETER Force
    Skip confirmation prompt.

.NOTES
    Run once to migrate. Safe to re-run (idempotent — skips files already timestamped).
    After running, execute the SIN scanner to verify all patterns still load correctly.
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
$timestamp = Get-Date -Format 'yyyyMMddHHmm'

if (-not (Test-Path $sinRegistryDir)) {
    Write-Error "SIN registry not found at: $sinRegistryDir"
    return
}

# ── Detect files already in new format ─────────────────────────────────
# New format: SIN-PATTERN-NNN-NAME_yyyyMMddhhmm.json
# Old format: SIN-PATTERN-NNN-NAME.json (no underscore+12digits before .json)
function Test-AlreadyTimestamped {
    param([string]$FileName)
    return ($FileName -match '_\d{12}\.json$')
}

# ── Extract timestamp from created_at or use current ──────────────────
function Get-ReindexTimestamp {
    param([PSCustomObject]$SinDef)
    $props = $SinDef.PSObject.Properties.Name
    if ($props -contains 'created_at' -and $SinDef.created_at) {
        try {
            $dt = [DateTime]::Parse($SinDef.created_at)
            return $dt.ToString('yyyyMMddHHmm')
        }
        catch {
            return $timestamp
        }
    }
    return $timestamp
}

Write-Host "`n===== SIN REGISTRY REINDEX =====" -ForegroundColor Cyan
Write-Host "Registry:   $sinRegistryDir"
Write-Host "Timestamp:  $timestamp (fallback)"
Write-Host "DryRun:     $DryRun`n"

# ── Phase 1: Collect all pattern & semi-sin files ─────────────────────
$patternFiles = @(Get-ChildItem -Path $sinRegistryDir -Filter 'SIN-PATTERN-*.json' -File -ErrorAction SilentlyContinue)
$semiSinFiles = @(Get-ChildItem -Path $sinRegistryDir -Filter 'SEMI-SIN-*.json' -File -ErrorAction SilentlyContinue)

Write-Host "Found $(@($patternFiles).Count) SIN-PATTERN files" -ForegroundColor Gray
Write-Host "Found $(@($semiSinFiles).Count) SEMI-SIN files" -ForegroundColor Gray

$reindexMap = @()
$allFiles = @($patternFiles) + @($semiSinFiles)
$skipped = 0
$renamed = 0

if (-not $Force -and -not $DryRun) {
    Write-Host "`nThis will rename $(@($allFiles).Count) files. Continue? [Y/N]: " -ForegroundColor Yellow -NoNewline
    $confirm = Read-Host
    if ($confirm -notin @('Y', 'y', 'Yes', 'yes')) {
        Write-Host "Aborted." -ForegroundColor Red
        return
    }
}

# ── Phase 2: Rename and update each file ──────────────────────────────
foreach ($file in $allFiles) {
    # Skip if already timestamped
    if (Test-AlreadyTimestamped -FileName $file.Name) {
        Write-Host "  SKIP (already timestamped): $($file.Name)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    try {
        $content = Get-Content $file.FullName -Raw -Encoding UTF8
        $sin = $content | ConvertFrom-Json

        $fileTs = Get-ReindexTimestamp -SinDef $sin

        # Build new filename: insert _yyyyMMddhhmm before .json
        $baseName = $file.BaseName   # e.g. SIN-PATTERN-001-HARDCODED-CREDENTIALS
        $newName  = "${baseName}_${fileTs}.json"
        $newPath  = Join-Path $sinRegistryDir $newName

        # Update internal sin_id to match new filename (without .json)
        $oldSinId = $sin.sin_id
        $newSinId = "${baseName}_${fileTs}"

        $sin.sin_id = $newSinId

        # Add reindex_metadata
        $reindexMeta = [ordered]@{
            previous_sin_id = $oldSinId
            previous_file   = $file.Name
            reindexed_at    = (Get-Date).ToUniversalTime().ToString('o')
            reindex_format  = 'v2-timestamped'
        }
        if (-not ($sin.PSObject.Properties.Name -contains 'reindex_metadata')) {
            $sin | Add-Member -NotePropertyName 'reindex_metadata' -NotePropertyValue $reindexMeta -Force
        }

        # Add remedy_tracking schema if not present
        if (-not ($sin.PSObject.Properties.Name -contains 'remedy_tracking')) {
            $remedyTracking = [ordered]@{
                attempts          = @()
                last_attempt_at   = $null
                total_attempts    = 0
                successful_count  = 0
                failed_count      = 0
                status            = 'PENDING'
                auto_retry        = $true
            }
            $sin | Add-Member -NotePropertyName 'remedy_tracking' -NotePropertyValue $remedyTracking -Force
        }

        # Add trusted_fix fields if not present (for systematic remedy recording)
        $props = $sin.PSObject.Properties.Name
        if (-not ($props -contains 'trusted_fix_count'))  { $sin | Add-Member -NotePropertyName 'trusted_fix_count'  -NotePropertyValue 0 -Force }
        if (-not ($props -contains 'trusted_fix_status')) { $sin | Add-Member -NotePropertyName 'trusted_fix_status' -NotePropertyValue 'new' -Force }
        if (-not ($props -contains 'trusted_fix_notes'))  { $sin | Add-Member -NotePropertyName 'trusted_fix_notes'  -NotePropertyValue '' -Force }

        $mapEntry = [ordered]@{
            old_file   = $file.Name
            new_file   = $newName
            old_sin_id = $oldSinId
            new_sin_id = $newSinId
            timestamp  = $fileTs
        }
        $reindexMap += $mapEntry

        if ($DryRun) {
            Write-Host "  [DRY-RUN] $($file.Name) -> $newName" -ForegroundColor Yellow
        }
        else {
            $sin | ConvertTo-Json -Depth 8 | Set-Content $newPath -Encoding UTF8
            Remove-Item $file.FullName -Force
            Write-Host "  RENAMED: $($file.Name) -> $newName" -ForegroundColor Green
        }
        $renamed++
    }
    catch {
        Write-Warning "  FAILED: $($file.Name) - $($_.Exception.Message)"
    }
}

# ── Phase 3: Update SIN instance files (parent_pattern references) ────
Write-Host "`nUpdating SIN instance parent_pattern references..." -ForegroundColor Cyan
$instanceFiles = @(Get-ChildItem -Path $sinRegistryDir -Filter 'SIN-2*.json' -File -ErrorAction SilentlyContinue)
$instanceFiles += @(Get-ChildItem -Path $sinRegistryDir -Filter 'SIN-027*.json' -File -ErrorAction SilentlyContinue)
$updatedInstances = 0

# Build lookup from old to new sin_id
$idMap = @{}
foreach ($entry in $reindexMap) {
    $idMap[$entry.old_sin_id] = $entry.new_sin_id
}

foreach ($instFile in $instanceFiles) {
    try {
        $instContent = Get-Content $instFile.FullName -Raw -Encoding UTF8
        $inst = $instContent | ConvertFrom-Json
        $instProps = $inst.PSObject.Properties.Name

        $changed = $false

        if ($instProps -contains 'parent_pattern' -and $idMap.ContainsKey($inst.parent_pattern)) {
            $inst.parent_pattern = $idMap[$inst.parent_pattern]
            $changed = $true
        }

        # Also add remedy_tracking to instance files
        if (-not ($instProps -contains 'remedy_tracking')) {
            $inst | Add-Member -NotePropertyName 'remedy_tracking' -NotePropertyValue ([ordered]@{
                attempts          = @()
                last_attempt_at   = $null
                total_attempts    = 0
                successful_count  = 0
                failed_count      = 0
                status            = 'PENDING'
                auto_retry        = $true
            }) -Force
            $changed = $true
        }

        if ($changed) {
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Update instance: $($instFile.Name)" -ForegroundColor Yellow
            }
            else {
                $inst | ConvertTo-Json -Depth 8 | Set-Content $instFile.FullName -Encoding UTF8
            }
            $updatedInstances++
        }
    }
    catch {
        Write-Warning "  Instance update failed: $($instFile.Name) - $($_.Exception.Message)"
    }
}

# ── Phase 4: Write reindex map ────────────────────────────────────────
$mapPath = Join-Path $sinRegistryDir 'REINDEX-MAP.json'
$mapObj = [ordered]@{
    reindexed_at = (Get-Date).ToUniversalTime().ToString('o')
    format       = 'SIN-PATTERN-NNN-NAME_yyyyMMddhhmm.json'
    total_renamed = $renamed
    total_skipped = $skipped
    instances_updated = $updatedInstances
    mappings     = $reindexMap
}

if (-not $DryRun) {
    $mapObj | ConvertTo-Json -Depth 6 | Set-Content $mapPath -Encoding UTF8
    Write-Host "`nReindex map written: $mapPath" -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────
Write-Host "`n===== REINDEX SUMMARY =====" -ForegroundColor Cyan
Write-Host "Files renamed:      $renamed"
Write-Host "Files skipped:      $skipped"
Write-Host "Instances updated:  $updatedInstances"
Write-Host "Reindex map:        $mapPath"
if ($DryRun) { Write-Host "`n[DRY-RUN] No files were modified." -ForegroundColor Yellow }
Write-Host "============================`n" -ForegroundColor Cyan

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





