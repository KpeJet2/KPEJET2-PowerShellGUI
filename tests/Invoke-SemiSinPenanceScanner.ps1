# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS  SemiSin Penance Scanner - post-test quality warnings.
.DESCRIPTION
    Runs ONLY after all tests have passed. Loads SEMI-SIN-*.json definitions
    from the sin_registry and performs soft-gate checks that produce
    "Penance Warnings!" rather than hard failures.

    Current SemiSin checks:
      SEMI-SIN-001  File size grew over 51% since last baseline
      SEMI-SIN-002  File is not located in a recognized workspace folder

    Baseline tracking:
      On first run (or with -UpdateBaseline), captures file sizes into
      temp/semisin-baseline.json. Subsequent runs compare against that
      baseline to detect abnormal growth.

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Default: script parent's parent.
.PARAMETER UpdateBaseline
    Force a fresh baseline snapshot (resets all size tracking).
.PARAMETER Quiet
    Suppress console output (returns object only).
.PARAMETER OutputJson
    Path to write JSON results. Default: temp/semisin-penance-results.json.

.NOTES
    Integration: called by Run-AllTests.ps1 ONLY when all prior phases pass.
    Exit codes: always 0 (penance warnings never block the pipeline).
#>
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$UpdateBaseline,
    [switch]$Quiet,
    [string]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ───────────────────────────────────────────────────────────────
$sinRegistryDir = Join-Path $WorkspacePath 'sin_registry'
$tempDir        = Join-Path $WorkspacePath 'temp'
$baselinePath   = Join-Path $tempDir 'semisin-baseline.json'
if (-not $OutputJson) {
    $OutputJson = Join-Path $tempDir 'semisin-penance-results.json'
}
$scanId    = "PENANCE-$(Get-Date -Format 'yyyyMMddHHmmss')"
$timestamp = (Get-Date).ToUniversalTime().ToString('o')

if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

# ── Load SemiSin Definitions ───────────────────────────────────────────
function Get-SemiSinDefinitions {
    param([string]$RegistryDir)
    $defs = @()
    $files = Get-ChildItem -Path $RegistryDir -Filter 'SEMI-SIN-*.json' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $json = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $defs += $json
        }
        catch {
            if (-not $Quiet) { Write-Warning "Failed to parse $($f.Name): $_" }
        }
    }
    return $defs
}

# ── Collect Workspace Files ────────────────────────────────────────────
function Get-WorkspaceFiles {
    param([string]$Root, [string]$FilePattern, [string[]]$ExcludeDirs)
    $extensions = $FilePattern -split ';' | ForEach-Object { $_.Trim() }
    $all = @()
    foreach ($ext in $extensions) {
        $found = Get-ChildItem -Path $Root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
        $all += $found
    }
    # Apply directory exclusions
    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        $all = @($all | Where-Object {
            $path = $_.FullName
            $excluded = $false
            foreach ($dir in $ExcludeDirs) {
                if ($path -match "[\\/]$([regex]::Escape($dir))[\\/]") { $excluded = $true; break }
            }
            -not $excluded
        })
    }
    # Also exclude .history and virtual environments
    $all = @($all | Where-Object { $_.FullName -notmatch '[\\/]\.history[\\/]' -and $_.FullName -notmatch '[\\/]\.venv[^\\/]*[\\/]' })
    return $all
}

# ── Baseline Management ────────────────────────────────────────────────
function Read-Baseline {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $map = @{}
            foreach ($prop in $raw.PSObject.Properties) {
                $map[$prop.Name] = [long]$prop.Value
            }
            return $map
        }
        catch { return @{} }
    }
    return @{}
}

function Write-Baseline {
    param([string]$Path, [hashtable]$SizeMap)
    $ordered = [ordered]@{}
    foreach ($key in ($SizeMap.Keys | Sort-Object)) {
        $ordered[$key] = $SizeMap[$key]
    }
    $ordered | ConvertTo-Json -Depth 2 | Set-Content -Path $Path -Encoding UTF8
}

function Build-CurrentSizeMap {
    param([System.IO.FileInfo[]]$Files, [string]$Root)
    $map = @{}
    foreach ($f in $Files) {
        $relPath = $f.FullName.Replace($Root, '').TrimStart('\', '/')
        $map[$relPath] = $f.Length
    }
    return $map
}

# ═══════════════════════════════════════════════════════════════════════
#  CHECK 1:  SEMI-SIN-001  Size Growth > 51%
# ═══════════════════════════════════════════════════════════════════════
function Invoke-SizeGrowthCheck {
    param(
        [PSCustomObject]$Definition,
        [hashtable]$CurrentSizes,
        [hashtable]$BaselineSizes
    )
    $findings = @()

    $props = $Definition.PSObject.Properties.Name
    $threshold = if ($props -contains 'scan_threshold_pct') { $Definition.scan_threshold_pct / 100.0 } else { 0.51 }

    foreach ($relPath in $CurrentSizes.Keys) {
        if ($BaselineSizes.ContainsKey($relPath)) {
            $oldSize = [long]$BaselineSizes[$relPath]
            $newSize = [long]$CurrentSizes[$relPath]
            if ($oldSize -gt 0) {
                $growthPct = ($newSize - $oldSize) / $oldSize
                if ($growthPct -gt $threshold) {
                    $pctDisplay = [math]::Round($growthPct * 100, 1)
                    $findings += [PSCustomObject]@{
                        SemiSinId  = $Definition.sin_id
                        Severity   = 'PENANCE'
                        Category   = $Definition.category
                        File       = $relPath
                        Detail     = "Grew ${pctDisplay}% (${oldSize}B -> ${newSize}B)"
                        Remedy     = if ($props -contains 'remedy') { $Definition.remedy } else { '' }
                        Title      = $Definition.title
                    }
                }
            }
        }
        # New files (no baseline entry) are not flagged -- they get baselined on this run
    }
    return $findings
}

# ═══════════════════════════════════════════════════════════════════════
#  CHECK 2:  SEMI-SIN-002  File Outside Workspace Folder
# ═══════════════════════════════════════════════════════════════════════
function Invoke-WorkspaceLocationCheck {
    param(
        [PSCustomObject]$Definition,
        [System.IO.FileInfo[]]$AllFiles,
        [string]$Root
    )
    $findings = @()

    $props = $Definition.PSObject.Properties.Name

    # Recognized sub-folders
    $recognized = @('modules','scripts','tests','config','styles','agents',
                    'todo','sin_registry','sovereign-kernel','UPM','pki',
                    'Report','~README.md','~REPORTS','checkpoints','logs','temp')
    if ($props -contains 'recognized_folders') {
        $recognized = @($Definition.recognized_folders)
    }

    # Allowed root file patterns
    $allowedRoot = @('Main-GUI.ps1','View-Config.ps1','Launch-*.bat','*.xhtml','CarGame')
    if ($props -contains 'allowed_root_patterns') {
        $allowedRoot = @($Definition.allowed_root_patterns)
    }

    foreach ($file in $AllFiles) {
        $relPath = $file.FullName.Replace($Root, '').TrimStart('\', '/')
        # Check if file is at root level (no directory separator)
        if ($relPath -notmatch '[\\/]') {
            # Root-level file -- check against allowed patterns
            $allowed = $false
            foreach ($pattern in $allowedRoot) {
                if ($file.Name -like $pattern) { $allowed = $true; break }
            }
            if (-not $allowed) {
                $findings += [PSCustomObject]@{
                    SemiSinId  = $Definition.sin_id
                    Severity   = 'PENANCE'
                    Category   = $Definition.category
                    File       = $relPath
                    Detail     = "Root-level file not in allowed list: $($file.Name)"
                    Remedy     = if ($props -contains 'remedy') { $Definition.remedy } else { '' }
                    Title      = $Definition.title
                }
            }
        }
        else {
            # File is in a subdirectory -- check if the top-level folder is recognized
            $topFolder = ($relPath -split '[\\/]')[0]
            if ($topFolder -and $recognized -notcontains $topFolder) {
                $findings += [PSCustomObject]@{
                    SemiSinId  = $Definition.sin_id
                    Severity   = 'PENANCE'
                    Category   = $Definition.category
                    File       = $relPath
                    Detail     = "Unrecognized folder: '$topFolder' is not in the workspace structure"
                    Remedy     = if ($props -contains 'remedy') { $Definition.remedy } else { '' }
                    Title      = $Definition.title
                }
            }
        }
    }
    return $findings
}

# ── REGEX_ADVISORY Scan ─────────────────────────────────────────────────
function Invoke-RegexAdvisoryCheck {
    param(
        [PSCustomObject]$Definition,
        [string]$Root
    )
    $findings = @()
    $props = $Definition.PSObject.Properties.Name

    # Read scan_regex
    $regex = if ($props -contains 'scan_regex') { $Definition.scan_regex } else { $null }
    if (-not $regex) { return $findings }

    # File pattern (e.g. '*.psm1')
    $filePattern  = if ($props -contains 'scan_file_pattern') { $Definition.scan_file_pattern } else { '*.ps1;*.psm1' }
    $excludeDirs  = @('.history','node_modules','__pycache__','temp','.venv','.venv-pygame312','checkpoints')
    if ($props -contains 'scan_exclude_dirs') {
        $excludeDirs = @($Definition.scan_exclude_dirs)
    }
    # Always exclude backup/remediation directories to reduce false positives
    $excludeDirs += @('remediation-backups')
    # scan_exceptions = filenames to skip (e.g. "SINGovernance.psm1")
    $exceptions = @()
    if ($props -contains 'scan_exceptions') {
        $exceptions = @($Definition.scan_exceptions)
    }

    # Collect target files
    $extensions = $filePattern -split ';' | ForEach-Object { $_.Trim() }
    $targetFiles = @()
    foreach ($ext in $extensions) {
        $found = Get-ChildItem -Path $Root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $skip = $false
                foreach ($exDir in $excludeDirs) {
                    if ($_.FullName -match [regex]::Escape("\$exDir\")) { $skip = $true; break }
                }
                -not $skip
            }
        $targetFiles += @($found)
    }

    # Filter out exception filenames
    if ($exceptions.Count -gt 0) {
        $targetFiles = @($targetFiles | Where-Object { $exceptions -notcontains $_.Name })
    }

    $rootNorm = $Root.TrimEnd('\','/') + '\'
    foreach ($file in $targetFiles) {
        try {
            $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            for ($i = 0; $i -lt @($lines).Count; $i++) {
                if ($lines[$i] -match $regex) {
                    # Skip full comment lines to reduce false positives
                    $trimmedLine = $lines[$i].TrimStart()
                    if ($trimmedLine.StartsWith('#')) { continue }
                    # Skip SIN-EXEMPT markers
                    if ($lines[$i] -match '#\s*SIN-EXEMPT:') { continue }
                    $relPath = $file.FullName.Replace($rootNorm, '')
                    $findings += [PSCustomObject]@{
                        SemiSinId  = $Definition.sin_id
                        Severity   = 'PENANCE'
                        Category   = if ($props -contains 'category') { $Definition.category } else { 'advisory' }
                        File       = $relPath
                        Line       = ($i + 1)
                        Detail     = "Line $($i+1): $($lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 80)))"
                        Remedy     = if ($props -contains 'remedy') { $Definition.remedy } else { '' }
                        Title      = $Definition.title
                    }
                }
            }
        }
        catch {
            # Skip files that can't be read
        }
    }
    return $findings
}

# ═══════════════════════════════════════════════════════════════════════
#  MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════
if (-not $Quiet) {
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor DarkYellow
    Write-Host '   SEMI-SIN  PENANCE  SCANNER' -ForegroundColor Yellow
    Write-Host '   Post-test quality gate (warnings only)' -ForegroundColor DarkYellow
    Write-Host '  ============================================' -ForegroundColor DarkYellow
    Write-Host ''
}

# Load definitions
$defs = Get-SemiSinDefinitions -RegistryDir $sinRegistryDir
if (-not $Quiet) { Write-Host "  Loaded $($defs.Count) SemiSin definitions" -ForegroundColor Gray }

# Collect all workspace files (broadest pattern across all definitions)
$allPatterns = @()
foreach ($d in $defs) {
    $p = $d.PSObject.Properties.Name
    if ($p -contains 'scan_file_pattern') { $allPatterns += $d.scan_file_pattern }
}
$mergedPattern = ($allPatterns | Sort-Object -Unique) -join ';'
if (-not $mergedPattern) { $mergedPattern = '*.ps1;*.psm1;*.json' }

$excludeDirs = @('.history','node_modules','__pycache__','.venv','.venv-pygame312')
$allFiles = Get-WorkspaceFiles -Root $WorkspacePath -FilePattern $mergedPattern -ExcludeDirs $excludeDirs

# Build current size map
$currentSizes = Build-CurrentSizeMap -Files $allFiles -Root ($WorkspacePath.TrimEnd('\','/') + '\')

# Read or create baseline
$baselineSizes = Read-Baseline -Path $baselinePath
$isFirstRun = ($baselineSizes.Count -eq 0)

if ($UpdateBaseline -or $isFirstRun) {
    Write-Baseline -Path $baselinePath -SizeMap $currentSizes
    if (-not $Quiet) {
        if ($isFirstRun) {
            Write-Host "  [BASELINE] First run -- captured $($currentSizes.Count) file sizes as baseline" -ForegroundColor Cyan
        } else {
            Write-Host "  [BASELINE] Forced update -- captured $($currentSizes.Count) file sizes" -ForegroundColor Cyan
        }
    }
    # Re-read so growth check has the fresh baseline (will find 0 growth)
    $baselineSizes = Read-Baseline -Path $baselinePath
}

# Run each SemiSin check
$allFindings = @()

foreach ($def in $defs) {
    $scanType = $null
    if ($def.PSObject.Properties.Name -contains 'scan_type') { $scanType = $def.scan_type }

    switch ($scanType) {
        'SIZE_GROWTH_CHECK' {
            $found = @(Invoke-SizeGrowthCheck -Definition $def -CurrentSizes $currentSizes -BaselineSizes $baselineSizes)
            $allFindings += $found
            if (-not $Quiet) {
                $label = $def.sin_id
                if ($found.Count -gt 0) {
                    Write-Host "  [!] $label : $($found.Count) Penance Warning(s)!" -ForegroundColor Yellow
                    foreach ($f in $found) {
                        Write-Host "        $($f.File) -- $($f.Detail)" -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "  [OK] $label : No abnormal growth detected" -ForegroundColor DarkGreen
                }
            }
        }
        'WORKSPACE_LOCATION_CHECK' {
            $found = @(Invoke-WorkspaceLocationCheck -Definition $def -AllFiles $allFiles -Root ($WorkspacePath.TrimEnd('\','/') + '\'))
            $allFindings += $found
            if (-not $Quiet) {
                $label = $def.sin_id
                if ($found.Count -gt 0) {
                    Write-Host "  [!] $label : $($found.Count) Penance Warning(s)!" -ForegroundColor Yellow
                    foreach ($f in $found) {
                        Write-Host "        $($f.File) -- $($f.Detail)" -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "  [OK] $label : All files in recognized folders" -ForegroundColor DarkGreen
                }
            }
        }
        'REGEX_ADVISORY' {
            $found = @(Invoke-RegexAdvisoryCheck -Definition $def -Root $WorkspacePath)
            $allFindings += $found
            if (-not $Quiet) {
                $label = $def.sin_id
                if ($found.Count -gt 0) {
                    Write-Host "  [!] $label : $($found.Count) Penance Warning(s)!" -ForegroundColor Yellow
                    # Show up to 5 examples to keep output manageable
                    $show = @($found | Select-Object -First 5)
                    foreach ($f in $show) {
                        Write-Host "        $($f.File):$($f.Line) -- $($f.Detail)" -ForegroundColor DarkYellow
                    }
                    if ($found.Count -gt 5) {
                        Write-Host "        ... and $($found.Count - 5) more" -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "  [OK] $label : No advisory findings" -ForegroundColor DarkGreen
                }
            }
        }
        default {
            if (-not $Quiet) {
                Write-Host "  [SKIP] $($def.sin_id) : Unknown scan_type '$scanType'" -ForegroundColor DarkGray
            }
        }
    }
}

# Update baseline after successful scan (track new files, keep current sizes)
Write-Baseline -Path $baselinePath -SizeMap $currentSizes

# ── Summary ─────────────────────────────────────────────────────────────
$resultObj = [PSCustomObject]@{
    scanId          = $scanId
    timestamp       = $timestamp
    scanClass       = 'SemiSin'
    totalFindings   = $allFindings.Count
    penanceWarnings = $allFindings.Count
    baselineFiles   = $currentSizes.Count
    findings        = $allFindings
}

# Write JSON results
try {
    $resultObj | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputJson -Encoding UTF8
}
catch {
    if (-not $Quiet) { Write-Warning "Could not write results to $OutputJson : $_" }
}

# Console summary
if (-not $Quiet) {
    Write-Host ''
    if ($allFindings.Count -gt 0) {
        Write-Host "  ===  PENANCE WARNINGS: $($allFindings.Count)  ===" -ForegroundColor Yellow
        Write-Host '  These are advisory -- they do NOT block the pipeline.' -ForegroundColor DarkYellow
    } else {
        Write-Host '  === NO PENANCE WARNINGS ===' -ForegroundColor Green
        Write-Host '  All SemiSin checks passed cleanly.' -ForegroundColor DarkGreen
    }
    Write-Host "  Baseline: $($currentSizes.Count) files tracked" -ForegroundColor Gray
    Write-Host "  Results:  $OutputJson" -ForegroundColor Gray
    Write-Host ''
}

# Return structured result (never exit non-zero -- penance is advisory)
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





