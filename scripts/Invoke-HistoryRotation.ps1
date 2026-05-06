# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Rotates .history files, keeping only the most recent N per source file.
.DESCRIPTION
    Scans the .history/ directory tree, groups files by their base name
    (stripping the timestamp suffix), and deletes all but the newest
    $KeepCount versions of each file.
.PARAMETER RootPath   Workspace root (default: parent of script directory).
.PARAMETER KeepCount  Number of history versions to retain per file (default: 5).
.PARAMETER WhatIf     Preview deletions without removing files.
.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 24th March 2026
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RootPath  = (Split-Path -Parent $PSScriptRoot),
    [int]$KeepCount    = 5
)

$historyDir = Join-Path $RootPath '.history'
if (-not (Test-Path $historyDir)) {
    Write-Host "No .history directory found at $historyDir" -ForegroundColor Yellow
    exit 0
}

$allFiles = Get-ChildItem -Path $historyDir -Recurse -File
# Group by base name (strip _YYYYMMDDHHMMSS timestamp suffix before extension)
$groups = $allFiles | Group-Object {
    $_.Name -replace '_\d{14}(?=\.[^.]+$)', ''
}

$totalDeleted = 0
foreach ($g in $groups) {
    $sorted = $g.Group | Sort-Object LastWriteTime -Descending
    if ($sorted.Count -le $KeepCount) { continue }
    $toRemove = $sorted | Select-Object -Skip $KeepCount
    foreach ($f in $toRemove) {
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete old history snapshot')) {
            Remove-Item -LiteralPath $f.FullName -Force
            $totalDeleted++
        }
    }
}

Write-Host "History rotation complete: $totalDeleted file(s) removed, keeping $KeepCount per source." -ForegroundColor Green

