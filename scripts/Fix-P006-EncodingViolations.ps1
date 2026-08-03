# VersionTag: 2607.B7.V53.0
# FileRole: Utility
#Requires -Version 5.1
<#
.SYNOPSIS
    Fix-P006-EncodingViolations -- Remediate UTF-8 BOM encoding issues across workspace files.

.DESCRIPTION
    Scans specified directories for files with Unicode content but missing UTF-8 BOM (P006 violation).
    Converts all such files to UTF-8 with BOM encoding.

    Reports: # fixed, # failed, # skipped.
#>
[CmdletBinding()]
param(
    [string[]]$Directories = @('modules', 'scripts', 'tests'),
    [string]$WorkspacePath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string[]]$Filters = @('*.psm1', '*.ps1', '*.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$stats = [ordered]@{ Fixed = 0; Failed = 0; Skipped = 0 }

foreach ($dir in $Directories) {
    $fullPath = Join-Path $WorkspacePath $dir
    if (-not (Test-Path $fullPath)) {
        Write-Verbose "Skipping non-existent directory: $fullPath"
        continue
    }

    Write-Host "Scanning: $fullPath" -ForegroundColor Cyan

    foreach ($filter in $Filters) {
        $files = Get-ChildItem -Path $fullPath -Filter $filter -File -Recurse -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $hasBOM = $bytes.Count -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

                if (-not $hasBOM) {
                    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                    $hasUnicode = $text -match '[\x80-\xFF]'

                    if ($hasUnicode) {
                        $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                        $content | Set-Content $file.FullName -Encoding UTF8 -Force -ErrorAction Stop
                        Write-Host "  ✓ $($file.Name)" -ForegroundColor Green
                        $stats.Fixed++
                    } else {
                        $stats.Skipped++
                    }
                } else {
                    $stats.Skipped++
                }
            } catch {
                Write-Host "  ✗ $($file.Name): $_" -ForegroundColor Red
                $stats.Failed++
            }
        }
    }
}

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Fixed:   $($stats.Fixed)" -ForegroundColor Green
Write-Host "  Failed:  $($stats.Failed)" -ForegroundColor $(if ($stats.Failed -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Skipped: $($stats.Skipped)" -ForegroundColor Gray

if ($stats.Failed -gt 0) { exit 1 }
exit 0
