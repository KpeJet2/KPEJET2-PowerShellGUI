# VersionTag: 2607.B7.V53.0
# SupportPS5.1: yes
# SupportsPS7.6: yes
# feature:pipeline feature:stability phase:verify
<#
.SYNOPSIS
    Entry point for the Full Pester Suite CI job.
.DESCRIPTION
    Discovers and invokes all *.Tests.ps1 files in the tests/ directory via Pester v5.
    Returns a result object whose .summary property contains total, passed, and failed counts.
    Writes JUnit XML output to testResults.xml in the workspace root.
.PARAMETER RequirePester
    When $true, errors and exits if Pester 5+ is not available.
.PARAMETER IncludeModuleValidation
    Reserved for future module-validation passes. Currently accepted but not acted on.
.PARAMETER PesterOnly
    When present, restricts execution to Pester test files only (*.Tests.ps1).
.OUTPUTS
    [PSCustomObject] with a .summary property: { total, passed, failed, skipped }
#>
[CmdletBinding()]
param(
    [bool]   $RequirePester            = $false,
    [switch] $IncludeModuleValidation,
    [switch] $PesterOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Pester availability check ────────────────────────────────────────────────
$pesterMod = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterMod) {
    if ($RequirePester) {
        Write-Error 'Pester 5+ is required but not available. Run: Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser'
        exit 1
    }
    Write-Warning 'Pester 5+ not found; attempting to install…'
    Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
}

Import-Module Pester -MinimumVersion '5.0' -Force

# ── Discover test files ───────────────────────────────────────────────────────
$testsRoot   = $PSScriptRoot
$repoRoot    = Split-Path $testsRoot -Parent
$xmlOutput   = Join-Path $repoRoot 'testResults.xml'

$testFiles = Get-ChildItem -Path $testsRoot -Filter '*.Tests.ps1' -File |
    Sort-Object Name

if ($testFiles.Count -eq 0) {
    Write-Warning 'No *.Tests.ps1 files found under tests/.'
    return [PSCustomObject]@{
        summary = [PSCustomObject]@{ total = 0; passed = 0; failed = 0; skipped = 0 }
    }
}

Write-Host "Discovered $($testFiles.Count) test file(s) under '$testsRoot'."

# ── Configure Pester ──────────────────────────────────────────────────────────
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path              = $testFiles.FullName
$pesterConfig.Run.Exit              = $false   # we handle exit ourselves
$pesterConfig.Run.PassThru          = $true
$pesterConfig.Output.Verbosity      = 'Normal'
$pesterConfig.TestResult.Enabled    = $true
$pesterConfig.TestResult.OutputPath = $xmlOutput
$pesterConfig.TestResult.OutputFormat = 'JUnitXml'

# ── Run ───────────────────────────────────────────────────────────────────────
$run = Invoke-Pester -Configuration $pesterConfig

# ── Build summary result ──────────────────────────────────────────────────────
$total   = [int]$run.TotalCount
$passed  = [int]$run.PassedCount
$failed  = [int]$run.FailedCount
$skipped = [int]$run.SkippedCount

$result = [PSCustomObject]@{
    summary = [PSCustomObject]@{
        total   = $total
        passed  = $passed
        failed  = $failed
        skipped = $skipped
    }
    xmlOutput = $xmlOutput
    run       = $run
}

Write-Host "Results: total=$total  passed=$passed  failed=$failed  skipped=$skipped"

return $result
