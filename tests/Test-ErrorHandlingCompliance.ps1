# VersionTag: 2607.B6.V53.0
# FileRole: Test
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-29
# SupportsPS7.6TestedDate: 2026-07-29
#Requires -Version 5.1
<#
.SYNOPSIS
    Scans workspace PowerShell files for error-handling compliance violations.
.DESCRIPTION
    Detects the following patterns across all *.ps1 and *.psm1 files:
      - SEC11-WriteWarning  : bare Write-Warning usage (should use Write-AppLog)
      - SEC11-WriteError    : bare Write-Error usage   (should use Write-AppLog)
      - SIN-003-SilentlyContinue : -ErrorAction SilentlyContinue usage

    Lines marked with SIN-EXEMPT or that are pure comment lines are skipped.
    Writes a JSON compliance report to <Path>/~REPORTS/error-handling-compliance-<timestamp>.json
    and returns the report object.
.PARAMETER Path
    Workspace root path. Defaults to the parent of the script's directory.
.PARAMETER Exclude
    Array of folder/path fragments to exclude from scanning (e.g. '.git', 'node_modules').
.PARAMETER Detailed
    When set, includes the full matched line text in each violation entry.
.EXAMPLE
    .\Test-ErrorHandlingCompliance.ps1 -Path . -Exclude @('.git','node_modules') -Detailed
#>
[CmdletBinding()]
param(
    [string]  $Path    = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Exclude = @('.git', '.history', '.vscode', 'node_modules', '.venv', 'pki', 'temp', 'remediation-backups'),
    [switch]  $Detailed
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── helpers ────────────────────────────────────────────────────────────────────

function Test-ExcludedPath {
    param([string]$FilePath, [string[]]$Exclusions)
    foreach ($ex in $Exclusions) {
        if ($FilePath -like "*$ex*") { return $true }
    }
    return $false
}

# ── discovery ──────────────────────────────────────────────────────────────────

$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$reportsDir   = Join-Path $resolvedPath '~REPORTS'

if (-not (Test-Path $reportsDir)) {
    New-Item -Path $reportsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
}

$allFiles = @(Get-ChildItem -Path $resolvedPath -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-ExcludedPath -FilePath $_.FullName -Exclusions $Exclude) })

# ── scan patterns ─────────────────────────────────────────────────────────────
#   Each entry: Id (report label), Regex (match trigger)
$scanPatterns = @(
    [ordered]@{ Id = 'SEC11-WriteWarning';       Regex = '(?i)\bWrite-Warning\b' }
    [ordered]@{ Id = 'SEC11-WriteError';         Regex = '(?i)\bWrite-Error\b' }
    [ordered]@{ Id = 'SIN-003-SilentlyContinue'; Regex = '(?i)-ErrorAction\s+SilentlyContinue' }
)

# ── scan ──────────────────────────────────────────────────────────────────────

$violations = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
    } catch {
        Write-Host "[WARN] Could not read $($file.FullName): $_" -ForegroundColor Yellow
        continue
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()

        # Skip pure comment lines and SIN-EXEMPT markers
        if ($trimmed -match '^#') { continue }
        if ($line -match 'SIN-EXEMPT') { continue }

        foreach ($sp in $scanPatterns) {
            if ($line -match $sp.Id) { continue }   # skip: line is about the pattern id itself

            if ($line -match $sp.Regex) {
                $entry = [ordered]@{
                    File    = $file.FullName
                    Pattern = $sp.Id
                    Line    = ($i + 1)
                }
                if ($Detailed) {
                    $entry['Text'] = $line.TrimEnd()
                }
                [void]$violations.Add([PSCustomObject]$entry)
            }
        }
    }
}

# ── report ────────────────────────────────────────────────────────────────────

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $reportsDir "error-handling-compliance-$timestamp.json"

$byPattern = @(@($violations | Group-Object Pattern | Sort-Object Name) | ForEach-Object {
    [ordered]@{ pattern = $_.Name; count = $_.Count }
})

$report = [ordered]@{
    schema    = 'ErrorHandlingCompliance/1.0'
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    path      = $resolvedPath
    filesScanned   = @($allFiles).Count
    totalViolations = @($violations).Count
    byPattern = $byPattern
    violations = @($violations)
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8 -ErrorAction Stop

Write-Host "[ErrorHandlingCompliance] $(@($violations).Count) violation(s) across $(@($allFiles).Count) files. Report: $reportPath" -ForegroundColor Cyan

return [PSCustomObject]$report
