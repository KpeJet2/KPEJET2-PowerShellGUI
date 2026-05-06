# VersionTag: 2604.B1.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
<#
.SYNOPSIS
    Archives completed, rejected, and blocked todo work items to typed subfolders.
.DESCRIPTION
    Reads every JSON file in todo/ (excluding _* bundle files and already-archived ~* subdirs),
    inspects each item's status and type, then routes it to the correct archive subfolder:

        ~Archive/   Bug and Bugs2FIX items with status DONE/completed.
                    Filename appended with ~FIXED.
                    JSON enriched with archiveMetadata (hindsightNote placeholder + fixSteps).

        ~DONE/      All other types (ToDo, feature, FeatureRequest, Items2ADD, etc.)
                    with status DONE/completed.
                    Filename appended with ~DONE_YYYYMMDD-HHmmss.

        ~BLOCKED/   Any type with status REJECTED, DENIED, BLOCKED, CANCELLED, WONTFIX.
                    Filename appended with ~BLOCKED_YYYYMMDD-HHmmss.

    Items with status OPEN, PLANNED, or IN_PROGRESS are left untouched.
    After archiving, callers should re-run Invoke-TodoBundleRebuild.ps1 to refresh _bundle.js.

.PARAMETER WorkspacePath
    Workspace root. Defaults to the parent of the scripts/ folder.
    Accepts either the workspace root or the scripts/ subfolder path.

.PARAMETER DryRun
    Lists what WOULD be moved without actually moving anything.

.EXAMPLE
    .\scripts\Invoke-TodoArchiver.ps1
    .\scripts\Invoke-TodoArchiver.ps1 -DryRun
    .\scripts\Invoke-TodoArchiver.ps1 -WorkspacePath C:\PowerShellGUI

.NOTES
    Author:     The Establishment
    Date:       2026-04-03
    VersionTag: 2603.B1.v1.1
    FileRole:   Archiver
    Category:   Infrastructure

    SIN Compliance:
      P006 - No Unicode chars in this file; no BOM needed.
             Bug/Bugs2FIX JSON enrichment written via WriteAllText+UTF8Encoding for safety.
      P007 - VersionTag present above.
      P012 - Set-Content not used for JSON output; WriteAllText used instead.
      P014 - ConvertTo-Json -Depth 10 used throughout.
      P015 - No hardcoded absolute paths; all via $WorkspacePath + Join-Path.
      P018 - All Join-Path calls use max 2 arguments (nested where needed).
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = $PSScriptRoot,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve workspace root ─────────────────────────────────────────────────────
# Script lives in scripts\ - parent is workspace root
if ($WorkspacePath -like '*\scripts' -or $WorkspacePath -like '*\scripts\') {
    $WorkspacePath = Split-Path $WorkspacePath -Parent
}

# ── Paths ──────────────────────────────────────────────────────────────────────
$TodoDir      = Join-Path $WorkspacePath 'todo'
$ArchiveDir   = Join-Path $TodoDir '~Archive'
$DoneDir      = Join-Path $TodoDir '~DONE'
$BlockedDir   = Join-Path $TodoDir '~BLOCKED'
$DeferredDir  = Join-Path $TodoDir '~DEFERRED'

if (-not (Test-Path $TodoDir)) {
    Write-Error "[TodoArchiver] todo/ directory not found at: $TodoDir"
    exit 1
}

# ── Status routing tables ──────────────────────────────────────────────────────
$DoneStatuses     = @('DONE', 'completed', 'COMPLETED', 'RESOLVED', 'CLOSED', 'FIXED')
$BlockedStatuses  = @('REJECTED', 'DENIED', 'BLOCKED', 'CANCELLED', 'WONTFIX', 'DUPLICATE')
$DeferredStatuses = @('DEFERRED', 'DEFERRED_SPRINT', 'BACKLOG')
$BugTypes        = @('Bug', 'Bugs2FIX')

# ── Stats ──────────────────────────────────────────────────────────────────────
$stats = @{ Fixed = 0; Done = 0; Blocked = 0; Deferred = 0; Skipped = 0; Errors = 0 }
$archiveTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ── Helper: Write-ArchiveLog ───────────────────────────────────────────────────
function Write-ArchiveLog {
    param([string]$Message, [string]$Level = 'INFO')
    $colour = switch ($Level) {
        'FIXED'   { 'Green' }
        'DONE'    { 'Cyan' }
        'BLOCKED' { 'Yellow' }
        'WARN'    { 'DarkYellow' }
        'ERROR'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host "[TodoArchiver] $Message" -ForegroundColor $colour
}

# ── Helper: Ensure-ArchiveDir ──────────────────────────────────────────────────
function Ensure-ArchiveDir {
    param([string]$DirPath)
    if (-not (Test-Path $DirPath)) {
        if ($DryRun) {
            Write-ArchiveLog "DRY-RUN: Would create directory: $DirPath" 'INFO'
        } else {
            New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
            Write-ArchiveLog "Created archive folder: $DirPath" 'INFO'
        }
    }
}

# ── Create archive subfolders ──────────────────────────────────────────────────
Ensure-ArchiveDir $ArchiveDir
Ensure-ArchiveDir $DoneDir
Ensure-ArchiveDir $BlockedDir
Ensure-ArchiveDir $DeferredDir

# ── Scan todo root (flat, no recursion into ~* folders) ────────────────────────
# NOTE: Get-ChildItem without -Recurse only returns items in $TodoDir itself.
# The FullName filter below provides explicit defence for any future -Recurse use.
$todoFiles = Get-ChildItem -Path $TodoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -notlike '_*' -and
        $_.Name -notlike 'action-log*' -and
        $_.FullName -notlike "*\~*\*"
    } |
    Sort-Object Name

$total = @($todoFiles).Count
Write-ArchiveLog "Scanning $total JSON files in $TodoDir ..."

# ── Process each file ─────────────────────────────────────────────────────────
foreach ($f in $todoFiles) {
    $item = $null
    try {
        $raw  = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        $item = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-ArchiveLog "Cannot parse $($f.Name): $($_.Exception.Message)" 'ERROR'
        $stats.Errors++
        continue
    }

    # Safe property reads (P004 guard not needed here as we use PSObject.Properties)
    $status = if ($item.PSObject.Properties.Name -contains 'status') { [string]$item.status } else { '' }
    $type   = if ($item.PSObject.Properties.Name -contains 'type')   { [string]$item.type   } else { '' }
    $title  = if ($item.PSObject.Properties.Name -contains 'title')  { [string]$item.title  } else { $f.BaseName }

    # ── DONE / completed ──────────────────────────────────────────────────────
    if ($status -in $DoneStatuses) {

        if ($type -in $BugTypes) {
            # ── Bug / Bugs2FIX → ~Archive with ~FIXED suffix ─────────────────
            Ensure-ArchiveDir $ArchiveDir
            $newName = $f.BaseName + '~FIXED' + $f.Extension
            $destPath = Join-Path $ArchiveDir $newName

            if ($DryRun) {
                Write-ArchiveLog "DRY-RUN: ~FIXED  $($f.Name)  >>  ~Archive\$newName" 'FIXED'
                $stats.Fixed++
                continue
            }

            # Enrich JSON with archive metadata before moving
            $archiveMeta = [ordered]@{
                archivedAt         = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                archiveFolder      = '~Archive'
                archiveReason      = 'FIXED - all required fix implementations resolved'
                hindsightNote      = 'TODO: Document retrospective approach - what would you do differently if starting again?'
                fixImplementations = 'TODO: List every fix step that was required to fully resolve this bug item'
            }
            Add-Member -InputObject $item -NotePropertyName 'archiveMetadata' -NotePropertyValue $archiveMeta -Force

            $enrichedJson = $item | ConvertTo-Json -Depth 10

            # Write with UTF-8 BOM (SIN P006 - safe for Unicode data in todo JSON)
            $utf8Bom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($destPath, $enrichedJson, $utf8Bom)
            Remove-Item $f.FullName -Force

            Write-ArchiveLog "~FIXED   $($f.Name)  >>  ~Archive\$newName" 'FIXED'
            $stats.Fixed++

        } else {
            # ── All other types → ~DONE ───────────────────────────────────────
            Ensure-ArchiveDir $DoneDir
            $newName  = $f.BaseName + '~DONE_' + $archiveTimestamp + $f.Extension
            $destPath = Join-Path $DoneDir $newName

            if ($DryRun) {
                Write-ArchiveLog "DRY-RUN: ~DONE   $($f.Name)  >>  ~DONE\$newName" 'DONE'
                $stats.Done++
                continue
            }

            Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
            Write-ArchiveLog "~DONE    $($f.Name)  >>  ~DONE\$newName" 'DONE'
            $stats.Done++
        }

    # ── REJECTED / DENIED / BLOCKED ───────────────────────────────────────────
    } elseif ($status -in $BlockedStatuses) {
        Ensure-ArchiveDir $BlockedDir
        $newName  = $f.BaseName + '~BLOCKED_' + $archiveTimestamp + $f.Extension
        $destPath = Join-Path $BlockedDir $newName

        if ($DryRun) {
            Write-ArchiveLog "DRY-RUN: ~BLOCKED $($f.Name)  >>  ~BLOCKED\$newName" 'BLOCKED'
            $stats.Blocked++
            continue
        }

        Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
        Write-ArchiveLog "~BLOCKED $($f.Name)  >>  ~BLOCKED\$newName" 'BLOCKED'
        $stats.Blocked++

    # ── DEFERRED / BACKLOG ────────────────────────────────────────────────────
    } elseif ($status -in $DeferredStatuses) {
        Ensure-ArchiveDir $DeferredDir
        $newName  = $f.BaseName + '~DEFERRED_' + $archiveTimestamp + $f.Extension
        $destPath = Join-Path $DeferredDir $newName

        if ($DryRun) {
            Write-ArchiveLog "DRY-RUN: ~DEFERRED $($f.Name)  >>  ~DEFERRED\$newName" 'BLOCKED'
            $stats.Deferred++
            continue
        }

        Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
        Write-ArchiveLog "~DEFERRED $($f.Name)  >>  ~DEFERRED\$newName" 'BLOCKED'
        $stats.Deferred++

    } else {
        # OPEN / PLANNED / IN_PROGRESS - leave untouched
        $stats.Skipped++
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
$dryLabel = if ($DryRun) { ' [DRY-RUN - no files moved]' } else { '' }
Write-Host ''
Write-Host ("[TodoArchiver] Complete$dryLabel") -ForegroundColor White
Write-Host ("  ~FIXED:   $($stats.Fixed)  (Bug/Bugs2FIX DONE -> ~Archive/)") -ForegroundColor Green
Write-Host ("  ~DONE:    $($stats.Done)  (Other types DONE -> ~DONE/)") -ForegroundColor Cyan
Write-Host ("  ~BLOCKED:  $($stats.Blocked)  (Rejected/Denied/Blocked -> ~BLOCKED/)") -ForegroundColor Yellow
Write-Host ("  ~DEFERRED: $($stats.Deferred)  (Deferred/Backlog -> ~DEFERRED/)") -ForegroundColor DarkYellow
Write-Host ("  Skipped:   $($stats.Skipped)  (OPEN/PLANNED/IN_PROGRESS - untouched)") -ForegroundColor Gray
if ($stats.Errors -gt 0) {
    Write-Host ("  Errors:   $($stats.Errors)  (check above for details)") -ForegroundColor Red
}
Write-Host ''
if (-not $DryRun -and ($stats.Fixed + $stats.Done + $stats.Blocked) -gt 0) {
    Write-Host '[TodoArchiver] Run Invoke-TodoBundleRebuild.ps1 to refresh _bundle.js' -ForegroundColor DarkCyan
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




