# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Encoding compliance validator — checks BOM presence and double-encoding (P023).
.DESCRIPTION
    Scans workspace files for:
      1. UTF-8 BOM missing on files containing Unicode characters (SIN P006)
      2. Double-encoded UTF-8 / mojibake byte signature C3 A2 E2 80 (SIN P023)
      3. Stale BOM artifacts (0x3F bytes after BOM from prior repair)

    Returns a result object with findings count and details.
.NOTES
    VersionTag: 2604.B2.V31.0
    FileRole: Test
    Category: Encoding / Quality Gate
.PARAMETER WorkspacePath
    Root directory to scan. Defaults to parent of $PSScriptRoot.
.PARAMETER Quiet
    Suppress console output.
.EXAMPLE
    .\tests\Test-EncodingCompliance.ps1 -WorkspacePath 'C:\PowerShellGUI'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Findings = @()

function Test-FileEncoding {
    param([System.IO.FileInfo]$File)

    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    }
    catch {
        return  # Skip unreadable files
    }

    $byteCount = @($bytes).Count
    if ($byteCount -lt 3) { return }

    $hasBOM = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # Check for BOM artifact (0x3F at byte 3 after valid BOM)
    if ($hasBOM -and $byteCount -gt 3 -and $bytes[3] -eq 0x3F) {  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
        $script:Findings += [PSCustomObject]@{
            Type     = 'BOM_ARTIFACT'
            Severity = 'HIGH'
            File     = $File.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
            Detail   = 'BOM artifact: 0x3F byte at position 3 after valid BOM (repair residue)'
        }
    }

    # Check for double-encoded BOM (C3 AF C2 BB C2 BF instead of EF BB BF)
    if ($byteCount -ge 6) {
        if ($bytes[0] -eq 0xC3 -and $bytes[1] -eq 0xAF -and  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
            $bytes[2] -eq 0xC2 -and $bytes[3] -eq 0xBB -and  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
            $bytes[4] -eq 0xC2 -and $bytes[5] -eq 0xBF) {  # SIN-EXEMPT: P027 - $bytes[N] with .Length guard on adjacent/same line
            $script:Findings += [PSCustomObject]@{
                Type     = 'DOUBLE_ENCODED_BOM'
                Severity = 'CRITICAL'
                File     = $File.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                Detail   = 'Double-encoded BOM detected: C3 AF C2 BB C2 BF (should be EF BB BF)'
            }
        }
    }

    # Check for P023 mojibake signature anywhere in file (C3 A2 E2 80)
    for ($i = 0; $i -lt ($byteCount - 3); $i++) {
        if ($bytes[$i] -eq 0xC3 -and $bytes[$i+1] -eq 0xA2 -and
            $bytes[$i+2] -eq 0xE2 -and $bytes[$i+3] -eq 0x80) {
            $script:Findings += [PSCustomObject]@{
                Type     = 'MOJIBAKE_P023'
                Severity = 'CRITICAL'
                File     = $File.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                Detail   = "Double-encoded UTF-8 at byte offset $i (C3 A2 E2 80 signature)"
            }
            break  # One finding per file is sufficient
        }
    }

    # Check for Unicode content without BOM (P006)
    if (-not $hasBOM) {
        $hasUnicode = $false
        for ($i = 0; $i -lt ($byteCount - 1); $i++) {
            if ($bytes[$i] -ge 0x80) {
                $hasUnicode = $true
                break
            }
        }
        if ($hasUnicode) {
            $script:Findings += [PSCustomObject]@{
                Type     = 'MISSING_BOM'
                Severity = 'MEDIUM'
                File     = $File.FullName.Replace($WorkspacePath, '').TrimStart('\', '/')
                Detail   = 'File contains non-ASCII bytes but has no UTF-8 BOM (SIN P006)'
            }
        }
    }
}

# ── Main Scan ───────────────────────────────────────────────────────────
if (-not $Quiet) {
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host '   ENCODING  COMPLIANCE  VALIDATOR' -ForegroundColor Cyan
    Write-Host '   P006 (BOM) + P023 (double-encoding)' -ForegroundColor DarkCyan
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host ''
}

$extensions = @('*.ps1', '*.psm1', '*.psd1', '*.xhtml', '*.md', '*.json')
$excludeDirs = @('.history', 'node_modules', '__pycache__', 'temp', '.venv', '.venv-pygame312', 'checkpoints')

$allFiles = @()
foreach ($ext in $extensions) {
    $found = Get-ChildItem -Path $WorkspacePath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $skip = $false
            foreach ($exDir in $excludeDirs) {
                if ($_.FullName -match [regex]::Escape("\$exDir\")) { $skip = $true; break }
            }
            -not $skip
        }
    $allFiles += @($found)
}

if (-not $Quiet) { Write-Host "  Scanning $(@($allFiles).Count) files..." -ForegroundColor Gray }

foreach ($file in $allFiles) {
    Test-FileEncoding -File $file
}

# ── Results ─────────────────────────────────────────────────────────────
$critical = @($script:Findings | Where-Object { $_.Severity -eq 'CRITICAL' })
$high     = @($script:Findings | Where-Object { $_.Severity -eq 'HIGH' })
$medium   = @($script:Findings | Where-Object { $_.Severity -eq 'MEDIUM' })

if (-not $Quiet) {
    Write-Host "  Results: $(@($critical).Count) CRITICAL, $(@($high).Count) HIGH, $(@($medium).Count) MEDIUM" -ForegroundColor $(if (@($critical).Count -gt 0) { 'Red' } elseif (@($high).Count -gt 0) { 'Yellow' } else { 'Green' })
    foreach ($f in $script:Findings) {
        $color = switch ($f.Severity) { 'CRITICAL' { 'Red' }; 'HIGH' { 'Yellow' }; default { 'Gray' } }
        Write-Host "    [$($f.Severity)] $($f.Type): $($f.File)" -ForegroundColor $color
        Write-Host "           $($f.Detail)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

[PSCustomObject]@{
    totalFindings = @($script:Findings).Count
    critical      = @($critical).Count
    high          = @($high).Count
    medium        = @($medium).Count
    findings      = $script:Findings
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





