# VersionTag: 2604.B1.V32.3
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-08
# FileRole: CrashHandler
#Requires -Version 5.1
<#
.SYNOPSIS
    Post-crash cleanup for the Local Web Engine.
.DESCRIPTION
    Called automatically from Start-LocalWebEngine.ps1 finally block on dirty exit.
    Also callable manually for inspection/triage.

    Actions performed:
      1. Reads engine-crash.log for latest crash event
      2. Scans logs/ and ~REPORTS/ for partial/uncommitted content:
           - 0-byte files created during crash window
           - JSON files missing closing brace (truncated)
           - Files modified within CrashWindowSec of the crash timestamp
      3. Moves suspicious files to logs/crash-quarantine/{crashId}/
      4. Writes ~REPORTS/crash-report-{ts}.json with full audit trail

    Does NOT delete files — only quarantines (moves) for human inspection.

.PARAMETER WorkspacePath
    Root of workspace. Defaults to parent of $PSScriptRoot.
.PARAMETER CrashWindowSec
    Files modified within this many seconds of crash time are flagged. Default: 30.
.PARAMETER Silent
    Suppress console output (used when called from engine finally block).
.PARAMETER DryRun
    Report what would be quarantined but do not move any files.
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [int]$CrashWindowSec = 30,
    [switch]$Silent,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Paths ────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}
$WorkspacePath  = [System.IO.Path]::GetFullPath($WorkspacePath)
$LogsDir        = Join-Path $WorkspacePath 'logs'
$ReportsDir     = Join-Path $WorkspacePath '~REPORTS'
$CrashLogFile   = Join-Path $LogsDir 'engine-crash.log'
$BootstrapLog   = Join-Path $LogsDir 'engine-bootstrap.log'
$StdoutLog      = Join-Path $LogsDir 'engine-stdout.log'
$Timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$CrashId        = "crash-$Timestamp"
$QuarantineDir  = Join-Path (Join-Path $LogsDir 'crash-quarantine') $CrashId
$ReportFile     = Join-Path $ReportsDir "crash-report-$Timestamp.json"
$PipelinePath   = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'

function Write-CleanupLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Level = 'INFO')
    if (-not $Silent) {
        $ts = Get-Date -Format 'HH:mm:ss'
        $clr = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Cyan'} }
        Write-Host "[$ts][CrashCleanup][$Level] $Msg" -ForegroundColor $clr
    }
}

function Push-DirtyShutdownBug2Fix {
    param(
        [string]$Title,
        [string]$Description,
        [string]$PipelineFile
    )
    if (-not (Test-Path -LiteralPath $PipelineFile)) { return $false }
    try {
        $now = Get-Date
        $seed = "$Title|$Description|$($now.ToString('yyyyMMddHHmmss'))"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $idHash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))[0..3]).Replace('-','').ToLower()
        $sha.Dispose()
        $bug = [ordered]@{
            id              = "Bug-$($now.ToString('yyyyMMddHHmmss'))-$idHash"
            type            = 'Bug'
            status          = 'OPEN'
            priority        = 'HIGH'
            category        = 'dirty-shutdown-fault'
            title           = $Title
            description     = $Description
            affectedFiles   = @()
            source          = 'Invoke-EngineCrashCleanup'
            created         = $now.ToString('o')
            modified        = $now.ToString('o')
            completedAt     = $null
            linkedFeatures  = @()
            linkedBugs      = @()
            tags            = @('engine','dirty-shutdown','bug2fix')
            notes           = "CrashId=$CrashId; Report=$ReportFile"
            sessionModCount = 0
            parentId        = ''
            executionAgent  = ''
        }
        $raw = Get-Content -LiteralPath $PipelineFile -Raw -Encoding UTF8
        if ([string]::IsNullOrEmpty($raw)) { return $false }
        $pipe = $raw | ConvertFrom-Json
        if ($null -eq $pipe -or $null -eq $pipe.bugs) { return $false }
        $newBugs = [System.Collections.ArrayList]@()
        foreach ($b in @($pipe.bugs)) { $null = $newBugs.Add($b) }
        $null = $newBugs.Add($bug)
        $pipe.bugs = @($newBugs)
        if ($null -ne $pipe.meta) { $pipe.meta.lastModified = (Get-Date -Format 'o') }
        Set-Content -LiteralPath $PipelineFile -Value ($pipe | ConvertTo-Json -Depth 10) -Encoding UTF8 -Force
        Write-CleanupLog "Bug2FIX created: $($bug.id)" 'WARN'
        return $true
    } catch {
        Write-CleanupLog "Failed to create Bug2FIX: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

Write-CleanupLog "=== Invoke-EngineCrashCleanup: $CrashId ==="

# ─── Read crash event from crash log ─────────────────────────────────────────
$crashEvent = $null
$crashTime  = $null
if (Test-Path -LiteralPath $CrashLogFile) {
    try {
        $rawLines = @(Get-Content -LiteralPath $CrashLogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        # Last JSON line = most recent crash
        $lastJson = $rawLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
        if (-not [string]::IsNullOrEmpty($lastJson)) {
            $crashEvent = $lastJson | ConvertFrom-Json
            if ($null -ne $crashEvent -and $null -ne $crashEvent.timestamp) {
                try {
                    $crashTime = [datetime]::Parse($crashEvent.timestamp)
                } catch {
                    Write-CleanupLog "Could not parse crash timestamp '$($crashEvent.timestamp)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    } catch {
        Write-CleanupLog "Could not parse crash log: $_" 'WARN'
    }
}
if ($null -eq $crashTime) { $crashTime = Get-Date }
Write-CleanupLog "Crash reference time: $($crashTime.ToString('yyyy-MM-dd HH:mm:ss'))"

# ─── Collect log tails for report ────────────────────────────────────────────
$engineLogTail = @()
$bootstrapLogTail = @()
try {
    if (Test-Path -LiteralPath $StdoutLog) {
        $engineLogTail = @(Get-Content -LiteralPath $StdoutLog -Encoding UTF8 -Tail 30 -ErrorAction SilentlyContinue)
    }
} catch { <# non-fatal #> }
try {
    if (Test-Path -LiteralPath $BootstrapLog) {
        $bootstrapLogTail = @(Get-Content -LiteralPath $BootstrapLog -Encoding UTF8 -Tail 20 -ErrorAction SilentlyContinue)
    }
} catch { <# non-fatal #> }

# ─── Scan for partial/suspicious files ───────────────────────────────────────
$targetDirs = @($LogsDir, $ReportsDir, (Join-Path $WorkspacePath 'temp'))
$suspiciousFiles = [System.Collections.ArrayList]@()
$windowStart = $crashTime.AddSeconds(-$CrashWindowSec)
$windowEnd   = $crashTime.AddSeconds($CrashWindowSec)

Write-CleanupLog "Scanning for files touched in window: $($windowStart.ToString('HH:mm:ss')) - $($windowEnd.ToString('HH:mm:ss'))"

foreach ($dir in $targetDirs) {
    if (-not (Test-Path $dir)) { continue }
    try {
        $filesInDir = @(Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                # Exclude quarantine dirs themselves
                -not $_.FullName.Contains('crash-quarantine')
            })
        foreach ($file in $filesInDir) {
            $reason = $null
            # Zero-byte files
            if ($file.Length -eq 0) { $reason = 'zero-byte file' }
            # Files modified within crash window
            elseif ($file.LastWriteTime -ge $windowStart -and $file.LastWriteTime -le $windowEnd) {
                $reason = "modified within crash window ($($file.LastWriteTime.ToString('HH:mm:ss')))"
            }
            # Truncated JSON (missing closing brace)
            if ($null -eq $reason -and $file.Extension -eq '.json' -and $file.Length -gt 0) {
                try {
                    $tail = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail 3 -ErrorAction SilentlyContinue
                    $lastLine = ($tail | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
                    if ($null -ne $lastLine -and -not ($lastLine.TrimEnd() -match '}|\]|,')) {
                        $reason = 'JSON appears truncated (last line has no closing bracket)'
                    }
                } catch { <# non-fatal — skip this check #> }
            }
            if ($null -ne $reason) {
                $null = $suspiciousFiles.Add([pscustomobject]@{
                    fullPath  = $file.FullName
                    relPath   = $file.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                    reason    = $reason
                    sizeBytes = $file.Length
                    modified  = $file.LastWriteTime.ToString('o')
                    quarantined = $false
                })
            }
        }
    } catch {
        Write-CleanupLog "Failed scanning dir $dir : $_" 'WARN'
    }
}

Write-CleanupLog "Found $(@($suspiciousFiles).Count) suspicious files"

# ─── Quarantine phase ─────────────────────────────────────────────────────────
$quarantineList = [System.Collections.ArrayList]@()
if (@($suspiciousFiles).Count -gt 0) {
    if (-not $DryRun) {
        if (-not (Test-Path $QuarantineDir)) {
            $null = New-Item -ItemType Directory -Path $QuarantineDir -Force
            Write-CleanupLog "Created quarantine dir: $QuarantineDir"
        }
    }
    foreach ($sf in $suspiciousFiles) {
        if ($DryRun) {
            Write-CleanupLog "[DRY-RUN] Would quarantine: $($sf.relPath) — $($sf.reason)" 'WARN'
            $sf.quarantined = $false
        } else {
            $dest = Join-Path $QuarantineDir $sf.relPath.Replace('\','-').Replace('/','_')
            try {
                # Also keep a README stub beside it
                Move-Item -LiteralPath $sf.fullPath -Destination $dest -Force
                $sf.quarantined = $true
                Write-CleanupLog "Quarantined: $($sf.relPath) → $(Split-Path $dest -Leaf)" 'WARN'
            } catch {
                Write-CleanupLog "Failed to quarantine $($sf.relPath): $_" 'ERROR'
            }
        }
        $null = $quarantineList.Add($sf)
    }
}

# ─── Write quarantine README ──────────────────────────────────────────────────
if (-not $DryRun -and (Test-Path $QuarantineDir)) {
    $readme = @"
CRASH QUARANTINE — $CrashId
==============================
Crash time : $($crashTime.ToString('yyyy-MM-dd HH:mm:ss'))
Engine PID : $(if ($null -ne $crashEvent) { $crashEvent.pid } else { 'unknown' })
Files held : $(@($quarantineList | Where-Object { $_.quarantined }).Count)

Review each file and restore or purge manually.
Full report: $ReportFile
"@
    try { Set-Content -LiteralPath (Join-Path $QuarantineDir 'README.txt') -Value $readme -Encoding UTF8 } catch { <# Intentional: non-fatal — quarantine README write is best-effort #> }
}

# ─── Write crash report ───────────────────────────────────────────────────────
if (-not (Test-Path $ReportsDir)) { $null = New-Item -ItemType Directory -Path $ReportsDir -Force }
$report = [pscustomobject]@{
    schemaVersion       = 'CrashReport/1.0'
    crashId             = $CrashId
    generated           = (Get-Date -Format 'o')
    crashTime           = $crashTime.ToString('o')
    cleanExit           = $false
    dryRun              = $DryRun.IsPresent
    crashEvent          = $crashEvent
    quarantineDir       = $QuarantineDir
    quarantinedCount    = @($quarantineList | Where-Object { $_.quarantined }).Count
    suspiciousCount     = @($suspiciousFiles).Count
    suspiciousFiles     = @($quarantineList)
    bootstrapLogTail    = $bootstrapLogTail
    engineLogTail       = $engineLogTail
}
try {
    $rJson = $report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $ReportFile -Value $rJson -Encoding UTF8
    Write-CleanupLog "Crash report saved: $ReportFile" 'OK'
} catch {
    Write-CleanupLog "Failed to write crash report: $_" 'ERROR'
}

if (@($suspiciousFiles).Count -gt 0) {
    $reasons = @($suspiciousFiles | Select-Object -First 6 | ForEach-Object { "$($_.relPath): $($_.reason)" })
    $lastLog = if ($null -ne $crashEvent -and $null -ne $crashEvent.lastLogLine) { $crashEvent.lastLogLine } else { 'n/a' }
    $bugText = "Dirty shutdown detected suspicious artifacts ($(@($suspiciousFiles).Count)). Sample: $($reasons -join ' | '). Last log line: $lastLog"
    $null = Push-DirtyShutdownBug2Fix -Title '[DIRTY SHUTDOWN] Suspicious post-crash artifacts detected' -Description $bugText -PipelineFile $PipelinePath
}

Write-CleanupLog "Cleanup complete. Quarantined: $(@($quarantineList | Where-Object { $_.quarantined }).Count) files."

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




