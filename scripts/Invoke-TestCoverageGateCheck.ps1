# VersionTag: 2604.B2.V32.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-TestCoverageGateCheck — Pipeline gate that fails if test coverage
    for scripts/ is below the configured threshold.  (IMPR-002-20260408)

.DESCRIPTION
    Compares the number of .ps1 files in scripts/ against the number of
    *.Tests.ps1 files in tests/.  If the coverage percentage is lower than
    (100 - MaxGapPercent) %, the script exits with code 1 so callers (CI,
    CronProcessor) detect the failure.

    A test file "covers" a script when the script's base name appears inside
    the test file's body OR the test file's base name contains the script's
    base name (case-insensitive).

    Output: JSON summary + Markdown table to ~REPORTS/.

.PARAMETER WorkspacePath
    Root of the workspace.  Default: parent of the scripts/ folder.

.PARAMETER MaxGapPercent
    Maximum allowed gap (uncovered scripts as % of total scripts).
    Default: 10.  Set to 0 for strict 100 % coverage.

.PARAMETER ReportOnly
    Print the report but always exit 0 (useful for audit/review runs).
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [ValidateRange(0, 100)]
    [int]$MaxGapPercent = 10,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}

$scriptsDir = Join-Path $WorkspacePath 'scripts'
$testsDir   = Join-Path $WorkspacePath 'tests'
$reportsDir = Join-Path $WorkspacePath '~REPORTS'

if (-not (Test-Path $scriptsDir)) { throw "scripts/ directory not found: $scriptsDir" }
if (-not (Test-Path $testsDir))   { throw "tests/ directory not found: $testsDir" }

# ── Enumerate subjects ────────────────────────────────────────────────────
$scripts = @(Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -File)
$tests   = @(Get-ChildItem -Path $testsDir   -Filter '*.Tests.ps1' -File)

# Pre-read test file bodies for name-in-body matching (once)
$testBodies = @{}
foreach ($t in $tests) {
    $testBodies[$t.Name] = (Get-Content -LiteralPath $t.FullName -Raw -Encoding UTF8)
}

# ── Coverage analysis ─────────────────────────────────────────────────────
$covered   = [System.Collections.ArrayList]::new()
$uncovered = [System.Collections.ArrayList]::new()

foreach ($script in $scripts) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script.Name)

    # Match 1: test file name contains script base name
    $matchByName = $tests | Where-Object {
        $_.Name -replace '\.Tests\.ps1$','' -like "*$baseName*"
    }

    # Match 2: script base name appears literally in any test file body
    $matchInBody = $testBodies.GetEnumerator() | Where-Object {
        $_.Value -match [regex]::Escape($baseName)
    }

    if ($matchByName -or $matchInBody) {
        [void]$covered.Add([PSCustomObject]@{ Script = $script.Name; MatchedBy = 'name or body' })
    } else {
        [void]$uncovered.Add([PSCustomObject]@{ Script = $script.Name; MatchedBy = 'NONE' })
    }
}

$total         = $scripts.Count
$coveredCount  = $covered.Count
$gapCount      = $uncovered.Count
$gapPercent    = if ($total -gt 0) { [math]::Round($gapCount / $total * 100, 1) } else { 0 }
$coverPercent  = 100 - $gapPercent
$passed        = $gapPercent -le $MaxGapPercent

# ── Write report ──────────────────────────────────────────────────────────
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$summary = [ordered]@{
    generatedAt      = (Get-Date).ToString('o')
    totalScripts     = $total
    totalTests       = $tests.Count
    coveredScripts   = $coveredCount
    uncoveredScripts = $gapCount
    gapPercent       = $gapPercent
    coveragePercent  = $coverPercent
    maxGapPercent    = $MaxGapPercent
    passed           = $passed
    uncoveredList    = @($uncovered | Select-Object -ExpandProperty Script)
}

if (Test-Path $reportsDir) {
    $outJson = Join-Path $reportsDir "test-coverage-gate-$timestamp.json"
    $outMd   = Join-Path $reportsDir "test-coverage-gate-$timestamp.md"

    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outJson -Encoding UTF8

    $mdLines = @(
        '# Test Coverage Gate Report',
        '',
        "Generated : $(Get-Date -Format 'o')",
        "Scripts   : $total",
        "Tests     : $($tests.Count)",
        "Covered   : $coveredCount ($coverPercent %)",
        "Uncovered : $gapCount ($gapPercent %)",
        "Gap Limit : $MaxGapPercent %",
        "Result    : $(if ($passed) { '**PASS**' } else { '**FAIL**' })",
        '',
        '## Uncovered Scripts',
        ''
    )
    foreach ($u in $uncovered) { $mdLines += "- $($u.Script)" }
    Set-Content -Path $outMd -Value $mdLines -Encoding UTF8

    Write-Output "Coverage report: $outJson"
}

# ── Console output ────────────────────────────────────────────────────────
Write-Output "Coverage: $coverPercent % ($coveredCount / $total scripts covered) | Gap: $gapPercent % | Limit: $MaxGapPercent %"  # SIN-EXEMPT: P021 — / is inside a string literal, not division

if ($passed) {
    Write-Output "PASS: test coverage within acceptable range."
} else {
    Write-Warning "FAIL: coverage gap $gapPercent % exceeds limit $MaxGapPercent %.  Uncovered ($gapCount):"
    $uncovered | Select-Object -ExpandProperty Script | ForEach-Object { Write-Warning "  $_" }
    if (-not $ReportOnly) {
        exit 1
    }
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




