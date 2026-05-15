# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2604.B2.V31.0  2026-04-12  Initial: non-essential duplication assessment for workspace optimisation
#Requires -Version 5.1
<#
.SYNOPSIS
    Scan the PowerShellGUI workspace for non-essential content duplication.

.DESCRIPTION
    Detects duplicate file content (hash-based), repeated function definitions across scripts,
    overlapping large comment/documentation blocks, and redundant script stubs.
    Outputs a structured report and updates the scan exclusion list with folders confirmed as non-essential.

.PARAMETER WorkspacePath
    Root of the workspace to scan. Defaults to the parent of this script's Scripts folder.

.PARAMETER OutputPath
    Path to write the JSON report. Defaults to ~REPORTS/dedup-assessment-<date>.json

.PARAMETER UpdateExclusionList
    If set, appends newly identified non-essential paths to the dependency-scan-config.json excludedFolders list.

.PARAMETER IncludePatterns
    Additional file extensions to scan (default: .ps1 .psm1 .psd1 .json .xml .xhtml .html).

.EXAMPLE
    .\Invoke-DeduplicationAssessment.ps1
    .\Invoke-DeduplicationAssessment.ps1 -UpdateExclusionList

.NOTES
    SIN compliance: P001=no creds, P002=catch logs, P004=@().Count, P005=no PS7, P006=UTF8-BOM,
                    P009=Join-Path validated, P012=-Encoding UTF8, P014=ConvertTo-Json -Depth,
                    P015=no hardcoded paths, P018=Join-Path max 2 args, P021=div guard.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$WorkspacePath,
    [string]$OutputPath,
    [switch]$UpdateExclusionList,
    [string[]]$IncludePatterns = @('.ps1','.psm1','.psd1','.json','.xml','.xhtml','.html','.bat','.css','.js')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve workspace root ──────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not (Test-Path $WorkspacePath)) { $WorkspacePath = Split-Path $PSScriptRoot -Parent }
    if (-not (Test-Path $WorkspacePath)) { $WorkspacePath = $PSScriptRoot }
}

$reportDir = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $reportDir "dedup-assessment-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
}

# ── Known non-essential/generated folders (baseline exclusions) ─────────────────
$baseExclusions = @(
    '~DOWNLOADS',
    '~REPORTS',
    'temp',
    '.git',
    '.history',
    'logs',
    'vault-backups',
    'node_modules',
    '~REPORTS',
    'checkpoints',
    'LOCAL',
    'REPORTS',
    '.venv',
    '.venv-pygame312',
    'agentic-manifest-history',
    'CONFIG-BACKUPS',
    'ssh-downloads'
)

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Invoke-DeduplicationAssessment  |  2604.B2.V31.0" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Workspace : $WorkspacePath" -ForegroundColor Gray
Write-Host "Output    : $OutputPath" -ForegroundColor Gray
Write-Host ""

# ── Collect files ───────────────────────────────────────────────────────────────
Write-Host "Collecting workspace files..." -ForegroundColor Yellow
$allFiles = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $parts = $_.FullName -replace '\\','/' -split '/'
        $skip  = $false
        foreach ($ex in $baseExclusions) { if ($parts -contains $ex) { $skip = $true; break } }
        if ($skip) { return $false }
        return ($IncludePatterns -contains $_.Extension)
    }
)
Write-Host "  Found $(@($allFiles).Count) files to analyse" -ForegroundColor Gray

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 1: Hash-based exact content duplicates
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 1: Hash-based duplicate file content..." -ForegroundColor Yellow

$hashBuckets = @{}
$sha = [System.Security.Cryptography.SHA256]::Create()

foreach ($f in $allFiles) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        if (-not $hashBuckets.ContainsKey($hash)) { $hashBuckets[$hash] = [System.Collections.Generic.List[string]]::new() }
        $hashBuckets[$hash].Add($f.FullName)
    } catch { <# Intentional: skip unreadable files (binary locks etc.) #> }
}
$sha.Dispose()

$exactDuplicates = @()
foreach ($kv in $hashBuckets.GetEnumerator()) {
    if (@($kv.Value).Count -gt 1) {
        $exactDuplicates += [PSCustomObject]@{
            SHA256 = $kv.Key
            Count  = @($kv.Value).Count
            SizeMB = [math]::Round([System.IO.FileInfo]::new($kv.Value[0]).Length / 1MB, 3)
            Files  = @($kv.Value | ForEach-Object { $_.Replace($WorkspacePath, '').TrimStart('\\/') })
        }
    }
}
$exactDuplicates = @($exactDuplicates | Sort-Object Count -Descending)
Write-Host "  Found $(@($exactDuplicates).Count) duplicate content group(s)" -ForegroundColor $(if (@($exactDuplicates).Count -gt 0) { 'Red' } else { 'Green' })

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 2: Duplicate function definitions across PS files
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 2: Duplicate function definitions across PS files..." -ForegroundColor Yellow

$funcIndex = @{}  # funcName -> list of "relPath:lineNo"
$psFiles = @($allFiles | Where-Object { $_.Extension -in @('.ps1','.psm1') })

foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -ErrorAction Stop
        $rel   = $f.FullName.Replace($WorkspacePath, '').TrimStart('\\/') 
        for ($i = 0; $i -lt @($lines).Count; $i++) {
            if ($lines[$i] -match '^function\s+([\w-]+)') {
                $fn = $Matches[1]
                if (-not $funcIndex.ContainsKey($fn)) { $funcIndex[$fn] = [System.Collections.Generic.List[string]]::new() }
                $funcIndex[$fn].Add("${rel}:L$($i+1)")
            }
        }
    } catch { <# Intentional: skip locked/unreadable files #> }
}

$dupFunctions = @()
foreach ($kv in $funcIndex.GetEnumerator()) {
    if (@($kv.Value).Count -gt 1) {
        $dupFunctions += [PSCustomObject]@{
            FunctionName = $kv.Key
            Count        = @($kv.Value).Count
            Locations    = @($kv.Value)
        }
    }
}
$dupFunctions = @($dupFunctions | Sort-Object Count -Descending)
Write-Host "  Found $(@($dupFunctions).Count) function name(s) defined in multiple files" -ForegroundColor $(if (@($dupFunctions).Count -gt 0) { 'Yellow' } else { 'Green' })

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 3: Stub / placeholder scripts (very small PS files < 150 bytes)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 3: Stub/placeholder script files..." -ForegroundColor Yellow

$stubs = @($psFiles | Where-Object { $_.Length -lt 150 } | ForEach-Object {
    [PSCustomObject]@{
        File   = $_.FullName.Replace($WorkspacePath,'').TrimStart('\\/') 
        Bytes  = $_.Length
        Note   = "Potential stub -- review for consolidation or removal"
    }
} | Sort-Object Bytes)
Write-Host "  Found $(@($stubs).Count) stub/placeholder file(s) (<150 bytes)" -ForegroundColor $(if (@($stubs).Count -gt 0) { 'Yellow' } else { 'Green' })

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 4: VersionTag build label repetition in non-canonical locations
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 4: Repeated VersionTag label duplication within single files..." -ForegroundColor Yellow

$vtagDuplicates = @()
foreach ($f in $psFiles) {
    try {
        $lines = Get-Content $f.FullName -ErrorAction Stop
        $tags  = @($lines | Where-Object { $_ -match '^\s*#\s*VersionTag:' })
        if (@($tags).Count -gt 1) {
            $vtagDuplicates += [PSCustomObject]@{
                File  = $f.FullName.Replace($WorkspacePath,'').TrimStart('\\/') 
                Count = @($tags).Count
                Note  = "Multiple VersionTag headers -- SIN P007 concern"
            }
        }
    } catch { <# Intentional: non-fatal #> }
}
Write-Host "  Found $(@($vtagDuplicates).Count) file(s) with duplicate VersionTag headers" -ForegroundColor $(if (@($vtagDuplicates).Count -gt 0) { 'Yellow' } else { 'Green' })

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 5: Large generated/archive files in non-generated locations
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 5: Oversized blowout files (>200KB outside generated dirs)..." -ForegroundColor Yellow

$oversized = @($allFiles | Where-Object { $_.Length -gt 200KB } | ForEach-Object {
    [PSCustomObject]@{
        File  = $_.FullName.Replace($WorkspacePath,'').TrimStart('\\/') 
        SizeKB = [math]::Round($_.Length / 1KB, 1)
        Note  = "Large file -- verify not result of content multiplication (SIN SS-001)"
    }
} | Sort-Object SizeKB -Descending)
Write-Host "  Found $(@($oversized).Count) oversized file(s) (>200KB)" -ForegroundColor $(if (@($oversized).Count -gt 0) { 'Yellow' } else { 'Green' })

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 6: Recommended additional exclusion folders
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 6: Identifying non-essential folders for scan exclusion..." -ForegroundColor Yellow

$additionalExclusions = @()
$candidateExcludeDirs = @(
    @{ Path='scripts\PS-CheatSheet-EXAMPLES'; Reason="Example scripts — not part of functional codebase" },
    @{ Path='scripts\~DOWNLOADS';            Reason="Downloaded temporaries" },
    @{ Path='scripts\~REPORTS';              Reason="Generated report outputs" },
    @{ Path='scripts\config';               Reason="Nested config mirror (use root config/)" },
    @{ Path='scripts\logs';                 Reason="Nested logs mirror (use root logs/)" },
    @{ Path='modules\LOCAL';               Reason="Local module cache — contents mirror installed" },
    @{ Path='modules\temp';                Reason="Module temp files" },
    @{ Path='modules\~DOWNLOADS';          Reason="Module download cache" },
    @{ Path='modules\~REPORTS';            Reason="Module-level report outputs" },
    @{ Path='pki\vault-backups';           Reason="Vault backup archives — binary, not scannable" },
    @{ Path='sin_registry\fixes';          Reason="Fix archive records — not functional code" }
)
foreach ($cd in $candidateExcludeDirs) {
    $full = Join-Path $WorkspacePath $cd.Path
    if (Test-Path $full) {
        $additionalExclusions += [PSCustomObject]@{
            RelPath = $cd.Path
            AbsPath = $full
            Reason  = $cd.Reason
        }
    }
}
Write-Host "  Identified $(@($additionalExclusions).Count) candidate additional exclusion folder(s)" -ForegroundColor Cyan

# ── Update exclusion list if requested ─────────────────────────────────────────
if ($UpdateExclusionList -and @($additionalExclusions).Count -gt 0) {
    $scanCfgPath = Join-Path $WorkspacePath (Join-Path 'config' 'dependency-scan-config.json')
    if (Test-Path $scanCfgPath) {
        try {
            $scanCfg = Get-Content $scanCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existing = @($scanCfg.excludedFolders)
            $added    = 0
            foreach ($ae in $additionalExclusions) {
                if (-not ($existing -contains $ae.RelPath)) {
                    $existing += $ae.RelPath
                    $added++
                }
            }
            if ($added -gt 0) {
                $scanCfg.excludedFolders = $existing
                $scanCfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $scanCfgPath -Encoding UTF8
                Write-Host "  Added $added new exclusion(s) to dependency-scan-config.json" -ForegroundColor Green
            } else { Write-Host "  All candidate exclusions already present in config" -ForegroundColor Gray }
        } catch { Write-Warning "  Failed to update dependency-scan-config.json: $_" }
    } else { Write-Warning "  dependency-scan-config.json not found at $scanCfgPath — skipping update" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS 7: Re-occurrence root causes (patterns that cause duplication)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Analysis 7: Root-cause patterns for re-occurrences..." -ForegroundColor Yellow

$rootCauses = @(
    [PSCustomObject]@{
        Pattern  = "Script-A.ps1 through Script-F.ps1 placeholders"
        Risk     = "Medium"
        Detail   = "Numbered placeholder scripts accumulate without consolidation into proper modules. Recommend archiving Script-[A-F].ps1 stubs."
        Files    = @($psFiles | Where-Object { $_.Name -match '^Script-?[A-F][\.\-]' } | ForEach-Object { $_.Name })
    },
    [PSCustomObject]@{
        Pattern  = "Script1.ps1 through Script6.ps1 numeric placeholders"
        Risk     = "Medium"
        Detail   = "Numeric-variant stubs duplicate the letter-variant issue. Consolidate test stubs into tests/ with proper Pester wrappers."
        Files    = @($psFiles | Where-Object { $_.Name -match '^Script\d+\.ps1$' } | ForEach-Object { $_.Name })
    },
    [PSCustomObject]@{
        Pattern  = "VersionBuildHistory repetition in module headers"
        Risk     = "Low"
        Detail   = "Each module carries a full build history comment. As history grows, file sizes increase. Consider linking to ENHANCEMENTS-LOG.md instead of embedding per-file history."
        Files    = @()
    },
    [PSCustomObject]@{
        Pattern  = "Nested config/ and logs/ mirroring inside scripts/"
        Risk     = "Medium"
        Detail   = "The scripts/ folder contains its own config/ and logs/ subdirectories that mirror root-level canonical locations. Causes confusion and stale data divergence."
        Files    = @()
    },
    [PSCustomObject]@{
        Pattern  = "Multiple 'PS-CheatSheet-EXAMPLES' variants"
        Risk     = "Low"
        Detail   = "PS-CheatSheet-EXAMPLES.ps1, PS-CheatSheet-EXAMPLES-V2.ps1, and the PS-CheatSheet-EXAMPLES/ folder all exist simultaneously. Consolidate into single versioned asset."
        Files    = @($psFiles | Where-Object { $_.Name -like '*CheatSheet*' } | ForEach-Object { $_.Name })
    }
)
Write-Host "  $(@($rootCauses).Count) root-cause pattern(s) identified" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
$totalWasted = if (@($exactDuplicates).Count -gt 0) {
    ($exactDuplicates | Measure-Object -Property SizeMB -Sum).Sum
} else { 0 }

$report = [PSCustomObject]@{
    meta = [PSCustomObject]@{
        version     = "2604.B2.V31.0"
        generated   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        generator   = "scripts/Invoke-DeduplicationAssessment.ps1"
        workspace   = $WorkspacePath
        filesScanned = @($allFiles).Count
    }
    summary = [PSCustomObject]@{
        exactDuplicateGroups   = @($exactDuplicates).Count
        estimatedWastedMB      = [math]::Round($totalWasted, 3)
        duplicateFunctionCount = @($dupFunctions).Count
        stubFiles              = @($stubs).Count
        vtagDups               = @($vtagDuplicates).Count
        oversizedFiles         = @($oversized).Count
        additionalExclusions   = @($additionalExclusions).Count
        rootCausePatterns      = @($rootCauses).Count
    }
    exactDuplicates       = $exactDuplicates
    duplicateFunctions    = $dupFunctions
    stubFiles             = $stubs
    versionTagDuplicates  = $vtagDuplicates
    oversizedFiles        = $oversized
    additionalExclusions  = $additionalExclusions
    rootCauses            = $rootCauses
    baseExclusionList     = $baseExclusions
}

# Write report
if ($PSCmdlet.ShouldProcess($OutputPath, "Write dedup assessment report")) {
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host " DEDUPLICATION ASSESSMENT COMPLETE" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  Exact duplicate groups : $(@($exactDuplicates).Count)" -ForegroundColor $(if (@($exactDuplicates).Count -gt 0) {'Red'} else {'Green'})
    Write-Host "  Estimated wasted space : $([math]::Round($totalWasted,2)) MB" -ForegroundColor White
    Write-Host "  Dup function names     : $(@($dupFunctions).Count)" -ForegroundColor $(if (@($dupFunctions).Count -gt 0) {'Yellow'} else {'Green'})
    Write-Host "  Stub/placeholder files : $(@($stubs).Count)" -ForegroundColor Yellow
    Write-Host "  VersionTag dup headers : $(@($vtagDuplicates).Count)" -ForegroundColor $(if (@($vtagDuplicates).Count -gt 0) {'Yellow'} else {'Green'})
    Write-Host "  Oversized files        : $(@($oversized).Count)" -ForegroundColor $(if (@($oversized).Count -gt 0) {'Yellow'} else {'Green'})
    Write-Host "  Candidates to exclude  : $(@($additionalExclusions).Count)" -ForegroundColor Cyan
    Write-Host "  Root-cause patterns    : $(@($rootCauses).Count)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Report: $OutputPath" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Cyan

    # Open report in explorer if interactive
    try {
        if (-not $NonInteractive -and $Host.Name -ne 'Default Host') {
            Start-Process explorer.exe "/select,`"$OutputPath`""
        }
    } catch { <# Intentional: non-fatal #> }
}

return $report

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





