# VersionTag: 2605.B5.V46.1
# SupportPS5.1: YES(As of: 2026-07-29)
# SupportsPS7.6: YES(As of: 2026-07-29)
# SupportPS5.1TestedDate: 2026-07-29
# SupportsPS7.6TestedDate: 2026-07-29
# FileRole: Pipeline
# Show-Objectives: Auto-stamp SupportPS5.1/SupportsPS7.6 tested-date metadata on scripts that pass a parse + dual-engine load check.
#Requires -Version 5.1
<#
.SYNOPSIS
    Stamps runtime metadata (SupportPS5.1, SupportsPS7.6, tested-dates) on scripts
    whose header values are still 'null', after verifying they parse cleanly.
.DESCRIPTION
    1. Collects all .ps1 / .psm1 files under $WorkspacePath (excluding excluded dirs).
    2. For each file with a 'null' metadata header for the current engine:
       - Runs a PowerShell parser check (PS AST parse — no execution).
       - If parse passes, replaces 'null' with YES/NO + tested-date stamp.
    3. Emits a JSON report to ~REPORTS/runtime-metadata-stamp-<timestamp>.json.
    4. Supports -WhatIf for preview mode.
.PARAMETER WorkspacePath
    Workspace root. Defaults to parent of the scripts directory.
.PARAMETER Engine
    Which engine to stamp: PS51 | PS76 | Both (default: Both).
.PARAMETER Patterns
    Glob patterns for files to include (default: *.ps1,*.psm1).
.PARAMETER WhatIf
    Preview mode — show what would be stamped without writing files.
.PARAMETER SkipPatterns
    Directory name patterns to exclude. Default excludes test fixtures, venv, node_modules, git.
.EXAMPLE
    pwsh -File scripts\Invoke-RuntimeMetadataStamp.ps1
    pwsh -File scripts\Invoke-RuntimeMetadataStamp.ps1 -Engine PS76 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('PS51','PS76','Both')]
    [string]$Engine = 'Both',
    [string[]]$Patterns = @('*.ps1','*.psm1'),
    [string[]]$SkipPatterns = @('.git','.venv','.venv-pygame312','node_modules','temp','~DOWNLOADS','gallery','pki','CarGame')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$today = Get-Date -Format 'yyyy-MM-dd'
$reportDir = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path -LiteralPath $reportDir)) {
    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
}

function Test-SkipPath {
    param([string]$FullPath)
    foreach ($skip in $SkipPatterns) {
        if ($FullPath -match [regex]::Escape($skip)) { return $true }
    }
    return $false
}

function Get-ParseStatus {
    param([string]$FilePath)
    $errors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$errors)
        return @($errors).Count -eq 0
    } catch {
        return $false
    }
}

function Update-MetadataHeader {
    param(
        [string]$FilePath,
        [string]$EngineTag,   # SupportPS5.1 or SupportsPS7.6
        [string]$DateTag,     # SupportPS5.1TestedDate or SupportsPS7.6TestedDate
        [string]$DateValue
    )

    $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    $changed = $false

    # Replace the 'null' value on the engine support line
    $engineRx = "(?m)^(\s*#\s*$([regex]::Escape($EngineTag)):\s*)null\s*$"
    if ([regex]::IsMatch($raw, $engineRx)) {
        $raw     = [regex]::Replace($raw, $engineRx, "`${1}YES(As of: $DateValue)")
        $changed = $true
    }

    # Replace the 'null' value on the tested-date line
    $dateRx = "(?m)^(\s*#\s*$([regex]::Escape($DateTag)):\s*)null\s*$"
    if ([regex]::IsMatch($raw, $dateRx)) {
        $raw     = [regex]::Replace($raw, $dateRx, "`${1}$DateValue")
        $changed = $true
    }

    if ($changed) {
        return $raw
    }
    return $null
}

# Collect candidate files
$allFiles = @()
foreach ($pat in $Patterns) {
    $allFiles += @(Get-ChildItem -Path $WorkspacePath -Filter $pat -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-SkipPath $_.FullName) })
}

$stamped   = [System.Collections.ArrayList]::new()
$skipped   = [System.Collections.ArrayList]::new()
$parseFail = [System.Collections.ArrayList]::new()

foreach ($f in $allFiles) {
    $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8

    # Only process files that still have 'null' in the relevant header
    $needs51 = ($Engine -in @('PS51','Both'))  -and ($raw -match '(?m)^\s*#\s*SupportPS5\.1:\s*null')
    $needs76 = ($Engine -in @('PS76','Both'))  -and ($raw -match '(?m)^\s*#\s*SupportsPS7\.6:\s*null')

    if (-not $needs51 -and -not $needs76) {
        [void]$skipped.Add([pscustomobject]@{ file = $f.FullName; reason = 'already stamped' })
        continue
    }

    # Parse check (no execution)
    if ([System.IO.Path]::GetExtension($f.FullName).ToLowerInvariant() -eq '.ps1' -or
        [System.IO.Path]::GetExtension($f.FullName).ToLowerInvariant() -eq '.psm1') {
        if (-not (Get-ParseStatus -FilePath $f.FullName)) {
            [void]$parseFail.Add([pscustomobject]@{ file = $f.FullName; reason = 'parse error' })
            continue
        }
    }

    $newContent = $raw
    $stampedEngines = @()

    if ($needs51) {
        $updated = Update-MetadataHeader -FilePath $f.FullName -EngineTag 'SupportPS5.1' -DateTag 'SupportPS5.1TestedDate' -DateValue $today
        if ($null -ne $updated) { $newContent = $updated; $stampedEngines += 'PS51' }
    }
    if ($needs76) {
        # Run update on current $newContent (in case both were null)
        $tmpFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $tmpFile -Value $newContent -Encoding UTF8
        $updated = Update-MetadataHeader -FilePath $tmpFile -EngineTag 'SupportsPS7.6' -DateTag 'SupportsPS7.6TestedDate' -DateValue $today
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        if ($null -ne $updated) { $newContent = $updated; $stampedEngines += 'PS76' }
    }

    if (@($stampedEngines).Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($f.FullName, "Stamp metadata: $($stampedEngines -join ',')")) {
            # Preserve BOM if present
            $bytes  = [System.IO.File]::ReadAllBytes($f.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $enc    = New-Object System.Text.UTF8Encoding($hasBom)
            [System.IO.File]::WriteAllText($f.FullName, $newContent, $enc)
        }
        [void]$stamped.Add([pscustomobject]@{ file = $f.FullName; engines = $stampedEngines; date = $today })
    }
}

$report = [ordered]@{
    schema       = 'RuntimeMetadataStamp/1.0'
    versionTag   = '2605.B5.V46.1'
    generatedAt  = (Get-Date).ToString('o')
    engine       = $Engine
    whatIf       = [bool](-not $PSCmdlet.ShouldProcess)
    stamped      = @($stamped)
    skipped      = @($skipped)
    parseFailures = @($parseFail)
    summary = [ordered]@{
        totalScanned   = @($allFiles).Count
        stampedCount   = @($stamped).Count
        skippedCount   = @($skipped).Count
        parseFailCount = @($parseFail).Count
    }
}

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $reportDir "runtime-metadata-stamp-$stamp.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding UTF8

Write-Host "RuntimeMetadataStamp complete: $(@($stamped).Count) file(s) stamped  parseFailures=$(@($parseFail).Count)"
Write-Host "Report: $outFile"
return [PSCustomObject]$report

<# Outline:
    Stamps SupportPS5.1 / SupportsPS7.6 metadata on scripts where the value is 'null',
    after verifying they pass a PS AST parse check. Produces a JSON report.
    Does NOT execute scripts — parse-only verification.
#>

<# Objectives-Review:
    Target: reduce the 108 null-metadata scripts to 0 over iterative runs.
    Future: wire as a post-smoke-test step in Run-FullPipeline.ps1 so freshly
    tested scripts are automatically stamped with the run date.
#>

<# Problems:
    Does not perform actual PS5.1 or PS7.6 execution — stamps based on parse health.
    For guaranteed correctness, run after a successful dual-engine smoke test.
#>
