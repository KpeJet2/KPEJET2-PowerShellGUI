# VersionTag: 2604.B2.V1.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS  CI pre-commit gate: parse check + critical SIN scan + encoding + version tag alignment.
.DESCRIPTION
    Lightweight gate designed to run before every commit (or as CronProcessor pre-step).
    Catches the most common, high-impact issues without the full SIN scanner runtime:

      Gate 1 – PowerShell parse errors (all .ps1/.psm1 files in scope)
      Gate 2 – Critical SIN patterns (P001/P009/P010): hardcoded creds, IEX, path injection
      Gate 3 – Encoding violations: UTF-8 BOM required for .ps1/.psm1 (P006)
      Gate 4 – VersionTag present and non-empty in every staged .ps1/.psm1 (P007)

    Exit codes:
      0 = all gates passed
      1 = one or more gates failed (details in output / JSON report)

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.  Default: parent of $PSScriptRoot.
.PARAMETER StagedFiles
    Comma-separated or array of relative/absolute file paths to check.
    When omitted, checks all .ps1/.psm1 files under modules/, scripts/, tests/.
.PARAMETER OutputJson
    Path to write JSON gate report.  Default: temp\precommit-<timestamp>.json.
.PARAMETER Quiet
    Suppress per-finding console output; only print summary and exit code.
.PARAMETER FailOnWarning
    Treat Gate 3 (encoding) and Gate 4 (VersionTag) findings as failures.
    By default only Gates 1 and 2 (parse + critical SIN) block the commit.

.EXAMPLE
    # Run against all files
    pwsh -File tests\Invoke-PreCommitValidation.ps1

.EXAMPLE
    # Run against specific staged files only
    pwsh -File tests\Invoke-PreCommitValidation.ps1 -StagedFiles 'modules\Foo.psm1','scripts\Bar.ps1'

.EXAMPLE
    # CI — strict mode (warnings also fail)
    pwsh -File tests\Invoke-PreCommitValidation.ps1 -FailOnWarning -Quiet
#>
param(
    [string]  $WorkspacePath  = (Split-Path -Parent $PSScriptRoot),
    [string[]]$StagedFiles    = @(),
    [string]  $OutputJson     = '',
    [switch]  $Quiet,
    [switch]  $FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Gate {
    param([string]$Msg, [string]$Level = 'Info')
    if ($Quiet) { return }
    $colour = switch ($Level) {
        'Pass'  { 'Green'  }
        'Fail'  { 'Red'    }
        'Warn'  { 'Yellow' }
        'Head'  { 'Cyan'   }
        default { 'White'  }
    }
    Write-Host $Msg -ForegroundColor $colour
}

function Get-TargetFiles {
    param([string]$Root, [string[]]$Specific)
    if (@($Specific).Count -gt 0) {
        return @($Specific | ForEach-Object {
            $p = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Root $_ }
            if (Test-Path $p) { Get-Item $p } else { Write-Gate "[WARN] File not found: $_" 'Warn' }
        } | Where-Object { $_ })
    }
    $scan = @('modules','scripts','tests')
    $exclude = @('.history','checkpoints','UPM','~DOWNLOADS','~REPORTS','node_modules','.git','.venv')
    $allFiles = @()
    foreach ($dir in $scan) {
        $dirPath = Join-Path $Root $dir
        if (-not (Test-Path $dirPath)) { continue }
        $allFiles += Get-ChildItem -Path $dirPath -Recurse -Include '*.ps1','*.psm1' -File |
            Where-Object {
                $parts = $_.FullName -split '[\\/]'
                -not ($parts | Where-Object { $exclude -contains $_ })
            }
    }
    return $allFiles
}

# ── Gate 1: PowerShell parse check ───────────────────────────────────────────

function Invoke-ParseGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        $parseErrors = $null
        $tokens      = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $f.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($err in $parseErrors) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'Parse'
                Severity = 'ERROR'
                File     = $f.FullName
                Line     = $err.Extent.StartLineNumber
                Message  = $err.Message
            })
        }
    }
    return @($findings)
}

# ── Gate 2: Critical SIN patterns (P001 creds, P009 path-inject, P010 IEX) ──

function Invoke-CriticalSINGate {
    param([System.IO.FileInfo[]]$Files)
    $patterns = @(
        [PSCustomObject]@{
            Id      = 'P001'
            Name    = 'HARDCODED-CREDENTIALS'
            Regex   = [regex]::new('(?i)(password|passwd|pwd|secret|apikey|api_key|token|connectionstring)\s*[=:]\s*[''"][^$''\"]{4,}[''"]',
                        [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        [PSCustomObject]@{
            Id      = 'P009'
            Name    = 'UNVALIDATED-PATH-JOIN'
            Regex   = [regex]::new('Join-Path\s+.*\$_(\.|\[)|\$[a-zA-Z]+Path\s*=\s*.*\+.*\$_',
                        [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        [PSCustomObject]@{
            Id      = 'P010'
            Name    = 'IEX-DYNAMIC-STRING'
            Regex   = [regex]::new('(?i)(Invoke-Expression|\biex\b)\s+[^#\n]*\$',
                        [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
    )

    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        if (-not $lines) { continue }
        $inBlockComment = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $trimmed = $lines[$i].TrimStart()
            # Block comment tracking
            if (-not $inBlockComment -and $trimmed -match '<#') { $inBlockComment = $true }
            if ($inBlockComment -and $trimmed -match '#>') { $inBlockComment = $false; continue }
            if ($inBlockComment) { continue }
            # Pure comment line
            if ($trimmed.StartsWith('#')) { continue }
            # SIN-EXEMPT override
            if ($lines[$i] -match '#\s*SIN-EXEMPT:\s*\*') { continue }
            # String-aware inline comment position
            $commentPos = -1
            $inStrChar  = $null
            for ($ci = 0; $ci -lt $lines[$i].Length; $ci++) {
                $ch = $lines[$i][$ci]
                if ($null -eq $inStrChar) {
                    if ($ch -eq '"' -or $ch -eq "'") { $inStrChar = $ch }
                    elseif ($ch -eq '#') { $commentPos = $ci; break }
                } elseif ($ch -eq $inStrChar) { $inStrChar = $null }
            }
            foreach ($pat in $patterns) {
                if ($lines[$i] -match "#\s*SIN-EXEMPT:\s*[^,\r\n]*$($pat.Id)") { continue }
                $m = $pat.Regex.Match($lines[$i])
                if (-not $m.Success) { continue }
                # Skip if match is inside inline comment
                if ($commentPos -ge 0 -and $m.Index -ge $commentPos) { continue }
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'CriticalSIN'
                    Severity = 'ERROR'
                    File     = $f.FullName
                    Line     = $i + 1
                    Pattern  = $pat.Id
                    PatName  = $pat.Name
                    Message  = "$($pat.Id) $($pat.Name): $($m.Value.Substring(0,[Math]::Min($m.Value.Length,60)))"
                })
            }
        }
    }
    return @($findings)
}

# ── Gate 3: Encoding — UTF-8 BOM required ────────────────────────────────────

function Invoke-EncodingGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    foreach ($f in $Files) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -lt 3 -or $bytes[0] -ne $bom[0] -or $bytes[1] -ne $bom[1] -or $bytes[2] -ne $bom[2]) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'Encoding'
                    Severity = 'WARN'
                    File     = $f.FullName
                    Line     = 1
                    Message  = 'P006: Missing UTF-8 BOM'
                })
            }
        } catch {
            [void]$findings.Add([PSCustomObject]@{
                Gate    = 'Encoding'; Severity = 'WARN'
                File    = $f.FullName; Line = 0
                Message = "P006: Could not read file: $($_.Exception.Message)"
            })
        }
    }
    return @($findings)
}

# ── Gate 4: VersionTag present ────────────────────────────────────────────────

function Invoke-VersionTagGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        try {
            # Only check the first 5 lines to keep it fast
            $head = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -TotalCount 5 -ErrorAction SilentlyContinue
            $hasTag = $head | Where-Object { $_ -match '#\s*VersionTag:\s*\S+' }
            if (-not $hasTag) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'VersionTag'
                    Severity = 'WARN'
                    File     = $f.FullName
                    Line     = 1
                    Message  = 'P007: No VersionTag comment in first 5 lines'
                })
            }
        } catch { <# non-fatal — unreadable files flagged by encoding gate #> }
    }
    return @($findings)
}

# ── Main ─────────────────────────────────────────────────────────────────────

$timestamp = (Get-Date).ToUniversalTime().ToString('o')
if (-not $OutputJson) {
    $OutputJson = Join-Path $WorkspacePath ("temp\precommit-{0}.json" -f (Get-Date -Format 'yyMMddHHmmss'))
}

Write-Gate '' 'Info'
Write-Gate '══════════════════════ PRE-COMMIT VALIDATION ══════════════════════' 'Head'
Write-Gate "  Workspace : $WorkspacePath" 'Info'
Write-Gate "  Timestamp : $timestamp" 'Info'

$files = @(Get-TargetFiles -Root $WorkspacePath -Specific $StagedFiles)
Write-Gate "  Files     : $($files.Count)" 'Info'
Write-Gate '────────────────────────────────────────────────────────────────────' 'Head'

$allFindings = [System.Collections.ArrayList]::new()

# Gate 1 — Parse
Write-Gate '[Gate 1] PowerShell parse check...' 'Info'
$parseHits = @(Invoke-ParseGate -Files $files)
$parseHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($parseHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $parseHits | ForEach-Object { Write-Gate "  FAIL $($_.File):$($_.Line) — $($_.Message)" 'Fail' } }

# Gate 2 — Critical SIN
Write-Gate '[Gate 2] Critical SIN patterns (P001/P009/P010)...' 'Info'
$sinHits = @(Invoke-CriticalSINGate -Files $files)
$sinHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($sinHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $sinHits | ForEach-Object { Write-Gate "  FAIL $($_.File):$($_.Line) — $($_.Message)" 'Fail' } }

# Gate 3 — Encoding
Write-Gate '[Gate 3] UTF-8 BOM encoding check (P006)...' 'Info'
$encHits = @(Invoke-EncodingGate -Files $files)
$encHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($encHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $encHits | ForEach-Object { Write-Gate "  WARN $($_.File) — $($_.Message)" 'Warn' } }

# Gate 4 — VersionTag
Write-Gate '[Gate 4] VersionTag alignment (P007)...' 'Info'
$vtHits = @(Invoke-VersionTagGate -Files $files)
$vtHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($vtHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $vtHits | ForEach-Object { Write-Gate "  WARN $($_.File) — $($_.Message)" 'Warn' } }

# ── Summary ──────────────────────────────────────────────────────────────────

$errorCount   = @($allFindings | Where-Object { $_.Severity -eq 'ERROR' }).Count
$warnCount    = @($allFindings | Where-Object { $_.Severity -eq 'WARN'  }).Count
$blockingCount = $errorCount + $(if ($FailOnWarning) { $warnCount } else { 0 })

Write-Gate '════════════════════════════════════════════════════════════════════' 'Head'
Write-Gate "  Errors : $errorCount  |  Warnings : $warnCount" $(if ($errorCount -gt 0) { 'Fail' } else { 'Pass' })

$report = [ordered]@{
    generatedAt    = $timestamp
    source         = 'Invoke-PreCommitValidation.ps1'
    workspace      = $WorkspacePath
    filesChecked   = $files.Count
    errorCount     = $errorCount
    warnCount      = $warnCount
    passed         = ($blockingCount -eq 0)
    failOnWarning  = $FailOnWarning.IsPresent
    findings       = @($allFindings)
}

try {
    $outDir = Split-Path $OutputJson -Parent
    if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputJson -Encoding UTF8
    Write-Gate "  Report  : $OutputJson" 'Info'
} catch {
    Write-Gate "  [WARN] Could not write report: $($_.Exception.Message)" 'Warn'
}

if ($blockingCount -gt 0) {
    Write-Gate '  STATUS  : FAILED — commit blocked' 'Fail'
    exit 1
} else {
    Write-Gate '  STATUS  : PASSED — commit allowed' 'Pass'
    exit 0
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




