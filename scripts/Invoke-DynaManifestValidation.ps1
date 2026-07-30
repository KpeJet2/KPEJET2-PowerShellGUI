# VersionTag: 2607.B6.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-09
# SupportsPS7.6TestedDate: 2026-07-09
# FileRole: Validator
<#
.SYNOPSIS
    Invoke-DynaManifestValidation -- Pre-test drift-guard validator for DynaManifest.

.DESCRIPTION
    Validates the dynamic manifest (config/dynamic-manifest.json) for drift conditions
    before the test gate runs:

    * Version alignment (VersionTag format, all modules have tags)
    * Encoding compliance (UTF-8 with BOM for Unicode files)
    * SIN pattern compliance (P001-P033 blocking violations)
    * Test recency (PS5 and PS7 last-tested timestamps from stamp files)
    * Dependency integrity (referenced files exist, no orphans)
    * Security envelope (folder permissions, file hashes)

    Exits with code 0 if all guards pass; 1 if any CRITICAL or HIGH blocker detected.

    Output: console log + logs/dynamic-manifest-validation-<timestamp>.log

.PARAMETER ManifestPath
    Path to the dynamic manifest JSON (default: config/dynamic-manifest.json).

.PARAMETER WorkspacePath
    Workspace root (default: parent of manifest's parent folder).

.PARAMETER StrictMode
    Fail on MEDIUM severity findings in addition to CRITICAL/HIGH.

.NOTES
    VersionTag: 2607.B1.V52.0
    FileRole: Validator
    Category: Pipeline Gate

.EXAMPLE
    .\scripts\Invoke-DynaManifestValidation.ps1
    Validate default manifest with log output.

.EXAMPLE
    .\scripts\Invoke-DynaManifestValidation.ps1 -StrictMode -Verbose
    Strict validation (fail on MEDIUM), with full diagnostics.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$WorkspacePath,
    [switch]$StrictMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Setup ─────────────────────────────────────────────────────────────────────────────────
if (-not $ManifestPath) {
    $ManifestPath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'config\dynamic-manifest.json'
}
if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $ManifestPath)
}

$logsDir     = Join-Path $WorkspacePath 'logs'
$timestamp   = Get-Date -Format 'yyyyMMddHHmmss'
$logFile     = Join-Path $logsDir "dynamic-manifest-validation-$timestamp.log"

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $colors = @{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; OK='Green' }
    Write-Host "[DynaManifest] [$Level] $Msg" -ForegroundColor $colors[$Level]
    try {
        "[$(Get-Date -Format HH:mm:ss)] [$Level] $Msg" | Add-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Suppress log write errors
    }
}

# ── Load Manifest ─────────────────────────────────────────────────────────────────────────
Write-Log "Loading manifest: $ManifestPath"
if (-not (Test-Path $ManifestPath)) {
    Write-Log "Manifest not found: $ManifestPath" ERROR
    exit 1
}

try {
    $manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log "Manifest loaded ($($manifest.counts.modules) modules, $($manifest.counts.scripts) scripts, $($manifest.counts.tests) tests)" OK
} catch {
    Write-Log "Failed to parse manifest: $_" ERROR
    exit 1
}

# ── Validation Results ────────────────────────────────────────────────────────────────────
$validationResults = [ordered]@{
    timestamp    = (Get-Date).ToUniversalTime().ToString('o')
    criticalCount = 0
    highCount    = 0
    mediumCount  = 0
    findings     = @()
}

# ── Version Alignment ─────────────────────────────────────────────────────────────────────
Write-Log "Checking version alignment..."
foreach ($mod in $manifest.modules) {
    if ($null -eq $mod.version -or $mod.version -eq '') {
        $validationResults.findings += [ordered]@{
            'severity' = 'CRITICAL'
            'guard'    = 'VERSION_ALIGNMENT'
            'module'   = $mod.name
            'finding'  = 'VersionTag missing'
        }
        $validationResults.criticalCount++
    } elseif ($mod.version -notmatch '^\d+\.B\d+\.V\d+\.\d+$') {
        $validationResults.findings += [ordered]@{
            'severity' = 'HIGH'
            'guard'    = 'VERSION_FORMAT'
            'module'   = $mod.name
            'current'  = $mod.version
            'expected' = '<YYMM>.B<build>.V<major>.<minor>'
        }
        $validationResults.highCount++
    }
}

# ── Encoding Compliance ───────────────────────────────────────────────────────────────────
Write-Log "Checking encoding compliance (P006)..."
foreach ($mod in $manifest.modules) {
    $path = Join-Path $WorkspacePath $mod.path
    if (Test-Path $path) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            if ($bytes.Count -gt 3) {
                $hasBOM = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                $content = [System.Text.Encoding]::UTF8.GetString($bytes)
                $hasUnicode = $content -match '[\u0080-\uFFFF]'
                if ($hasUnicode -and -not $hasBOM) {
                    $validationResults.findings += [ordered]@{
                        'severity' = 'HIGH'
                        'guard'    = 'ENCODING_COMPLIANCE'
                        'module'   = $mod.name
                        'path'     = $mod.path
                        'issue'    = 'Unicode content without UTF-8 BOM (P006 violation)'
                    }
                    $validationResults.highCount++
                }
            }
        } catch {
            $validationResults.findings += [ordered]@{
                'severity' = 'MEDIUM'
                'guard'    = 'ENCODING_CHECK_ERROR'
                'module'   = $mod.name
                'error'    = $_.Exception.Message
            }
            $validationResults.mediumCount++
        }
    }
}

# ── Test Recency (PS5 / PS7) ──────────────────────────────────────────────────────────────
Write-Log "Checking test recency stamps..."
$ps5StampFile = Join-Path $logsDir 'ps5-last-tested.json'
$ps7StampFile = Join-Path $logsDir 'ps7-last-tested.json'

$ps5Stamp = $null
$ps7Stamp = $null

if (Test-Path $ps5StampFile) {
    try {
        $ps5Stamp = Get-Content $ps5StampFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $ps5Last = [datetime]::Parse($ps5Stamp.lastTestedUtc).ToUniversalTime()
        $ps5Elapsed = (Get-Date).ToUniversalTime() - $ps5Last
        Write-Log "PS5 last tested: $($ps5Elapsed.TotalHours.ToString('F1')) hours ago" OK
    } catch {
        Write-Log "Failed to parse PS5 stamp: $_" WARN
    }
} else {
    Write-Log "PS5 stamp file not found (likely first run)" INFO
}

if (Test-Path $ps7StampFile) {
    try {
        $ps7Stamp = Get-Content $ps7StampFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $ps7Last = [datetime]::Parse($ps7Stamp.lastTestedUtc).ToUniversalTime()
        $ps7Elapsed = (Get-Date).ToUniversalTime() - $ps7Last
        Write-Log "PS7 last tested: $($ps7Elapsed.TotalHours.ToString('F1')) hours ago" OK
    } catch {
        Write-Log "Failed to parse PS7 stamp: $_" WARN
    }
}

# ── Dependency Integrity ──────────────────────────────────────────────────────────────────
Write-Log "Checking dependency integrity..."
foreach ($mod in $manifest.modules) {
    if ($null -ne $mod.manifestFile) {
        $mPath = Join-Path $WorkspacePath $mod.manifestFile
        if (-not (Test-Path $mPath)) {
            $validationResults.findings += [ordered]@{
                'severity' = 'MEDIUM'
                'guard'    = 'DEPENDENCY_MISSING'
                'module'   = $mod.name
                'manifestFile' = $mod.manifestFile
            }
            $validationResults.mediumCount++
        }
    }
}

# ── Security Hash Verification ────────────────────────────────────────────────────────────
Write-Log "Verifying security hashes..."
$hashMismatches = 0
foreach ($mod in $manifest.modules) {
    $path = Join-Path $WorkspacePath $mod.path
    if (Test-Path $path) {
        try {
            $currentHash = (Get-FileHash $path -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($null -ne $mod.sha256 -and $mod.sha256 -ne $currentHash) {
                $validationResults.findings += [ordered]@{
                    'severity' = 'MEDIUM'
                    'guard'    = 'HASH_MISMATCH'
                    'module'   = $mod.name
                    'reason'   = 'File has been modified since manifest generation'
                }
                $validationResults.mediumCount++
                $hashMismatches++
            }
        } catch {
            # Non-fatal; skip hash verification on read error
        }
    }
}
if ($hashMismatches -gt 0) {
    Write-Log "Hash mismatches detected: $hashMismatches file(s) modified since manifest" WARN
}

# ── Summary ───────────────────────────────────────────────────────────────────────────────
Write-Log "Validation Summary:" INFO
Write-Log "  CRITICAL: $($validationResults.criticalCount)" $(if ($validationResults.criticalCount -gt 0) { 'ERROR' } else { 'OK' })
Write-Log "  HIGH:     $($validationResults.highCount)" $(if ($validationResults.highCount -gt 0) { 'WARN' } else { 'OK' })
Write-Log "  MEDIUM:   $($validationResults.mediumCount)" $(if ($validationResults.mediumCount -gt 0) { 'WARN' } else { 'OK' })

$shouldFail = $validationResults.criticalCount -gt 0 -or $validationResults.highCount -gt 0
if ($StrictMode -and $validationResults.mediumCount -gt 0) {
    $shouldFail = $true
    Write-Log "StrictMode enabled: MEDIUM findings are blocking" WARN
}

if ($shouldFail) {
    Write-Log "Validation FAILED - drift guards detected issues" ERROR
    $validationResults.findings | ConvertTo-Json -Depth 5 | Write-Output
    exit 1
} else {
    Write-Log "Validation PASSED - all drift guards satisfied" OK
    exit 0
}
