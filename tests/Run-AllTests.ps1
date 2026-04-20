# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS  CI test orchestrator -- runs Pester + smoke test + shell-matrix.
.DESCRIPTION
    Pass 6: Runs all Pester test suites, then optionally runs smoke tests.
    Outputs results to console and todo/test-results-history.json.
.PARAMETER PesterOnly
    Run only Pester tests (skip smoke test).
.PARAMETER SmokeOnly
    Run only the smoke test (skip Pester).
.PARAMETER IncludeShellMatrix
    Also run smoke test shell-matrix (both PS 5.1 and pwsh).
#>
param(
    [switch]$PesterOnly,
    [switch]$SmokeOnly,
    [switch]$IncludeShellMatrix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testsDir   = Join-Path $scriptRoot 'tests'
$todoDir    = Join-Path $scriptRoot 'todo'
$timestamp  = Get-Date -Format 'yyyyMMddHHmmss'

$results = [ordered]@{
    runId        = "testrun-$timestamp"
    startedAt    = (Get-Date).ToUniversalTime().ToString('o')
    completedAt  = $null
    pester       = $null
    smoke        = $null
    fileTypeRoutines = $null
    summary      = [ordered]@{ total = 0; passed = 0; failed = 0; skipped = 0 }
}

function Invoke-FileTypeRoutineSet {
    $routineScript = Join-Path $testsDir 'Invoke-FileTypeFireUpAllEnginesRoutine.ps1'
    if (-not (Test-Path -LiteralPath $routineScript)) {
        return [ordered]@{ status = 'SKIPPED'; reason = 'File-type routine script not found'; failedRoutines = 0; routines = @() }
    }

    $routineResults = @()
    foreach ($kind in @('Script','Html')) {
        try {
            $routineResults += @(& $routineScript -FileType $kind -WorkspacePath $scriptRoot -Limit 10 -Quiet)
        } catch {
            $routineResults += [pscustomobject]@{
                routineName = "SmokeTest-$kind-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose"
                fileType = $kind.ToUpperInvariant()
                status = 'ERROR'
                lastRunAt = (Get-Date).ToUniversalTime().ToString('o')
                lastFieldRecordAt = (Get-Date).ToUniversalTime().ToString('o')
                filesProcessed = 0
                passed = 0
                failed = 1
                improvementsYielded = $_.ToString()
                logPath = ''
                inventoryPath = '~REPORTS/smoke-filetype-agent-inventory.json'
                records = @()
            }
        }
    }

    $failedRoutines = @($routineResults | Where-Object { $_.status -ne 'PASSED' }).Count
    return [ordered]@{
        status = if ($failedRoutines -gt 0) { 'FAILED' } else { 'PASSED' }
        failedRoutines = $failedRoutines
        routines = $routineResults
    }
}

# ── Pester Tests ──────────────────────────────────────────────────────────────
if (-not $SmokeOnly) {
    Write-Host "`n========== PESTER TEST SUITES ==========" -ForegroundColor Cyan

    # Check if Pester is available
    $pesterModule = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pesterModule) {
        Write-Host "[WARN] Pester module not installed. Install with: Install-Module Pester -Force -SkipPublisherCheck" -ForegroundColor Yellow
        $results.pester = @{ status = 'SKIPPED'; reason = 'Pester not installed' }
    } else {
        try { Import-Module Pester -MinimumVersion 5.0 -Force -ErrorAction Stop } catch { <# Intentional: fallback to any Pester version below #> }
        if (-not (Get-Module Pester | Where-Object { $_.Version -ge [version]'5.0' })) {
            try { Import-Module Pester -Force -ErrorAction Stop } catch { Write-Warning "Failed to import Pester: $_" }
        }

        $pesterFiles = Get-ChildItem -Path $testsDir -Filter '*.Tests.ps1' -File | Sort-Object Name
        Write-Host "Found $($pesterFiles.Count) Pester test files:" -ForegroundColor Gray
        $pesterFiles | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Gray }

        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = $pesterFiles.FullName
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'Detailed'

        try {
            $pesterResult = Invoke-Pester -Configuration $pesterConfig
            $results.pester = [ordered]@{
                status    = if ($pesterResult.FailedCount -eq 0) { 'PASSED' } else { 'FAILED' }
                total     = $pesterResult.TotalCount
                passed    = $pesterResult.PassedCount
                failed    = $pesterResult.FailedCount
                skipped   = $pesterResult.SkippedCount
                duration  = $pesterResult.Duration.ToString()
            }
            $results.summary.total   += $pesterResult.TotalCount
            $results.summary.passed  += $pesterResult.PassedCount
            $results.summary.failed  += $pesterResult.FailedCount
            $results.summary.skipped += $pesterResult.SkippedCount
        } catch {
            $results.pester = @{ status = 'ERROR'; message = $_.ToString() }
        }
    }
}

# ── SIN Pattern Scan ──────────────────────────────────────────────────────────
Write-Host "`n========== SIN PATTERN SCAN ==========" -ForegroundColor Cyan
$sinScanner = Join-Path $testsDir 'Invoke-SINPatternScanner.ps1'
if (Test-Path $sinScanner) {
    try {
        $sinResult = & $sinScanner -WorkspacePath $scriptRoot
        $results['sinPatternScan'] = [ordered]@{
            status   = if ($sinResult -and $sinResult.critical -gt 0) { 'FAILED' } else { 'PASSED' }
            total    = if ($sinResult) { $sinResult.totalFindings } else { 0 }
            critical = if ($sinResult) { $sinResult.critical }      else { 0 }
            high     = if ($sinResult) { $sinResult.high }          else { 0 }
            medium   = if ($sinResult) { $sinResult.medium }        else { 0 }
        }
    } catch {
        $results['sinPatternScan'] = @{ status = 'ERROR'; message = $_.ToString() }
    }
} else {
    $results['sinPatternScan'] = @{ status = 'SKIPPED'; reason = 'Scanner not found' }
}

# ── Smoke Tests ───────────────────────────────────────────────────────────────
if (-not $PesterOnly) {
    Write-Host "`n========== SMOKE TESTS ==========" -ForegroundColor Cyan
    $smokeScript = Join-Path $testsDir 'Invoke-GUISmokeTest.ps1'

    if (Test-Path $smokeScript) {
        try {
            if ($IncludeShellMatrix) {
                $smokeArgs = @('-HeadlessOnly', '-RunShellMatrix')
            } else {
                $smokeArgs = @('-HeadlessOnly')
            }

            $smokeProc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$smokeScript`"") + $smokeArgs) `
                -Wait -PassThru -NoNewWindow

            $results.smoke = [ordered]@{
                status   = if ($smokeProc.ExitCode -eq 0) { 'PASSED' } else { 'FAILED' }
                exitCode = $smokeProc.ExitCode
                mode     = if ($IncludeShellMatrix) { 'shell-matrix' } else { 'headless-only' }
            }
        } catch {
            $results.smoke = @{ status = 'ERROR'; message = $_.ToString() }
        }
    } else {
        $results.smoke = @{ status = 'SKIPPED'; reason = 'Smoke test script not found' }
    }
}

# ── SemiSin Penance Scan (ONLY if all tests passed) ──────────────────────────
$allTestsPassed = ($results.summary.failed -eq 0) -and
                  (-not $results.pester -or $results.pester.status -ne 'ERROR') -and
                  (-not $results.smoke  -or $results.smoke.status  -ne 'ERROR')

if ($allTestsPassed) {
    Write-Host "`n========== SEMI-SIN PENANCE SCAN ==========" -ForegroundColor DarkYellow
    $semiSinScanner = Join-Path $testsDir 'Invoke-SemiSinPenanceScanner.ps1'
    if (Test-Path $semiSinScanner) {
        try {
            $penanceResult = & $semiSinScanner -WorkspacePath $scriptRoot
            $results['semiSinPenance'] = [ordered]@{
                status          = 'COMPLETED'
                penanceWarnings = if ($penanceResult) { $penanceResult.penanceWarnings } else { 0 }
                baselineFiles   = if ($penanceResult) { $penanceResult.baselineFiles }   else { 0 }
            }
        } catch {
            $results['semiSinPenance'] = @{ status = 'ERROR'; message = $_.ToString() }
        }
    } else {
        $results['semiSinPenance'] = @{ status = 'SKIPPED'; reason = 'SemiSin scanner not found' }
    }
} else {
    Write-Host "`n========== SEMI-SIN PENANCE SCAN ==========" -ForegroundColor DarkYellow
    Write-Host "  [SKIPPED] Tests have failures -- SemiSin penance scan only runs after all tests pass." -ForegroundColor DarkGray
    $results['semiSinPenance'] = @{ status = 'SKIPPED'; reason = 'Prior tests had failures' }
}

# ── File-Type FireUp Routines ───────────────────────────────────────────────
Write-Host "`n========== FILE-TYPE FIREUP ROUTINES ==========" -ForegroundColor Cyan
try {
    $results.fileTypeRoutines = Invoke-FileTypeRoutineSet
} catch {
    $results.fileTypeRoutines = @{ status = 'ERROR'; message = $_.ToString(); failedRoutines = 1; routines = @() }
}

# ── Finalize ──────────────────────────────────────────────────────────────────
$results.completedAt = (Get-Date).ToUniversalTime().ToString('o')

# Write results to history
if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }
$historyPath = Join-Path $todoDir 'test-results-history.json'
$history = @()
if (Test-Path $historyPath) {
    try {
        $existing = Get-Content $historyPath -Raw | ConvertFrom-Json
        if ($existing -is [array]) { $history = @($existing) }
        else { $history = @($existing) }
    } catch { $history = @() }
}
$history += $results
$history | ConvertTo-Json -Depth 10 | Set-Content -Path $historyPath -Encoding UTF8

# Summary
Write-Host "`n========== TEST RESULTS SUMMARY ==========" -ForegroundColor Cyan
Write-Host "Run ID:   $($results.runId)" -ForegroundColor White
Write-Host "Total:    $($results.summary.total)" -ForegroundColor White
Write-Host "Passed:   $($results.summary.passed)" -ForegroundColor Green
Write-Host "Failed:   $($results.summary.failed)" -ForegroundColor $(if ($results.summary.failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Skipped:  $($results.summary.skipped)" -ForegroundColor Yellow
if ($results.pester)         { Write-Host "Pester:   $($results.pester.status)" -ForegroundColor $(if ($results.pester.status -eq 'PASSED') { 'Green' } else { 'Red' }) }
if ($results.sinPatternScan) { Write-Host "SIN Scan: $($results.sinPatternScan.status) (C:$($results.sinPatternScan.critical) H:$($results.sinPatternScan.high) M:$($results.sinPatternScan.medium))" -ForegroundColor $(if ($results.sinPatternScan.status -eq 'PASSED') { 'Green' } else { 'Red' }) }
if ($results.smoke)          { Write-Host "Smoke:    $($results.smoke.status)" -ForegroundColor $(if ($results.smoke.status -eq 'PASSED') { 'Green' } else { 'Red' }) }
if ($results.semiSinPenance) {
    $penColor = switch ($results.semiSinPenance.status) { 'COMPLETED' { if ($results.semiSinPenance.penanceWarnings -gt 0) { 'Yellow' } else { 'Green' } }; 'SKIPPED' { 'DarkGray' }; default { 'Red' } }
    $penText  = if ($results.semiSinPenance.status -eq 'COMPLETED') { "$($results.semiSinPenance.status) (Penance Warnings: $($results.semiSinPenance.penanceWarnings))" } else { "$($results.semiSinPenance.status)" }
    Write-Host "Penance:  $penText" -ForegroundColor $penColor
}
if ($results.fileTypeRoutines) {
    $routineColor = if ($results.fileTypeRoutines.status -eq 'PASSED') { 'Green' } else { 'Red' }
    Write-Host "FileType: $($results.fileTypeRoutines.status)" -ForegroundColor $routineColor
}
Write-Host "Results:  $historyPath" -ForegroundColor Gray

if (($results.summary.failed -gt 0) -or ($results.fileTypeRoutines -and $results.fileTypeRoutines.failedRoutines -gt 0)) { exit 1 } else { exit 0 }

