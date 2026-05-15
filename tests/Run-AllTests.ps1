# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
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
    [switch]$IncludeShellMatrix,
    [switch]$AutoInstallPester,
    [bool]$RequirePester = $true,
    [bool]$IncludeModuleValidation = $true
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
    if (-not $pesterModule -and $AutoInstallPester) {
        try {
            Write-Host "[INFO] Installing Pester (CurrentUser scope)..." -ForegroundColor Cyan
            Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
            $pesterModule = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        } catch {
            Write-Host "[WARN] Auto-install of Pester failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not $pesterModule) {
        $msg = 'Pester module not installed. Install with: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
        if ($RequirePester) {
            Write-Host "[FAIL] $msg" -ForegroundColor Red
            $results.pester = @{ status = 'FAILED'; reason = $msg }
            $results.summary.failed += 1
        } else {
            Write-Host "[WARN] $msg" -ForegroundColor Yellow
            $results.pester = @{ status = 'SKIPPED'; reason = 'Pester not installed' }
        }
    } else {
        try { Import-Module Pester -MinimumVersion 5.0 -Force -ErrorAction Stop } catch { <# Intentional: fallback to any Pester version below #> }
        if (-not (Get-Module Pester | Where-Object { $_.Version -ge [version]'5.0' })) {
            try { Import-Module Pester -Force -ErrorAction Stop } catch { Write-Warning "Failed to import Pester: $_" }
        }

        $pesterFiles = Get-ChildItem -Path $testsDir -Filter '*.Tests.ps1' -File | Sort-Object Name
        if (@($pesterFiles).Count -eq 0) {
            if ($RequirePester) {
                $results.pester = @{ status = 'FAILED'; reason = 'No Pester test files found (*.Tests.ps1)' }
                $results.summary.failed += 1
                Write-Host '[FAIL] No Pester test files found (*.Tests.ps1)' -ForegroundColor Red
            } else {
                $results.pester = @{ status = 'SKIPPED'; reason = 'No Pester test files found (*.Tests.ps1)' }
                Write-Host '[WARN] No Pester test files found (*.Tests.ps1)' -ForegroundColor Yellow
            }
        } else {
            Write-Host "Found $($pesterFiles.Count) Pester test files:" -ForegroundColor Gray
            $pesterFiles | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Gray }

            try {
                $pesterResult = $null
                if (Get-Command -Name New-PesterConfiguration -ErrorAction SilentlyContinue) {
                    $pesterConfig = New-PesterConfiguration
                    $pesterConfig.Run.Path = $pesterFiles.FullName
                    $pesterConfig.Run.PassThru = $true
                    $pesterConfig.Output.Verbosity = 'Detailed'
                    $pesterResult = Invoke-Pester -Configuration $pesterConfig
                } else {
                    # Pester v4 compatibility path.
                    $pesterResult = Invoke-Pester -Script $pesterFiles.FullName -PassThru
                }

                $totalCount = if ($pesterResult.PSObject.Properties.Name -contains 'TotalCount') { [int]$pesterResult.TotalCount } elseif ($pesterResult.PSObject.Properties.Name -contains 'Total') { [int]$pesterResult.Total } else { 0 }
                $passedCount = if ($pesterResult.PSObject.Properties.Name -contains 'PassedCount') { [int]$pesterResult.PassedCount } elseif ($pesterResult.PSObject.Properties.Name -contains 'Passed') { [int]$pesterResult.Passed } else { 0 }
                $failedCount = if ($pesterResult.PSObject.Properties.Name -contains 'FailedCount') { [int]$pesterResult.FailedCount } elseif ($pesterResult.PSObject.Properties.Name -contains 'Failed') { [int]$pesterResult.Failed } else { 0 }
                $skippedCount = if ($pesterResult.PSObject.Properties.Name -contains 'SkippedCount') { [int]$pesterResult.SkippedCount } elseif ($pesterResult.PSObject.Properties.Name -contains 'Skipped') { [int]$pesterResult.Skipped } else { 0 }
                $durationText = if ($pesterResult.PSObject.Properties.Name -contains 'Duration') { $pesterResult.Duration.ToString() } elseif ($pesterResult.PSObject.Properties.Name -contains 'Time') { $pesterResult.Time.ToString() } else { '' }

                $results.pester = [ordered]@{
                    status    = if ($failedCount -eq 0) { 'PASSED' } else { 'FAILED' }
                    total     = $totalCount
                    passed    = $passedCount
                    failed    = $failedCount
                    skipped   = $skippedCount
                    duration  = $durationText
                }
                $results.summary.total   += $totalCount
                $results.summary.passed  += $passedCount
                $results.summary.failed  += $failedCount
                $results.summary.skipped += $skippedCount
            } catch {
                $results.pester = @{ status = 'ERROR'; message = $_.ToString() }
            }
        }
    }
}

# ── Module Accessibility Validation ─────────────────────────────────────────
if ($IncludeModuleValidation) {
    Write-Host "`n========== MODULE ACCESSIBILITY VALIDATION ==========" -ForegroundColor Cyan
    $moduleValidator = Join-Path $testsDir 'Invoke-ModuleGalleryValidator.ps1'
    if (Test-Path $moduleValidator) {
        try {
            $moduleJsonPath = Join-Path (Join-Path $scriptRoot 'temp') ("module-validation-{0}.json" -f $timestamp)
            & $moduleValidator -WorkspacePath $scriptRoot -TestPS51 -TestPS7 -TestSystemContext -Quiet -OutputJson $moduleJsonPath | Out-Null
            $moduleValidationResult = if (Test-Path -LiteralPath $moduleJsonPath) { Get-Content -LiteralPath $moduleJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            if ($null -eq $moduleValidationResult) {
                $results['moduleValidation'] = @{ status = 'ERROR'; message = 'Module validator did not produce readable JSON output' }
            } else {
                $failModules = if ($moduleValidationResult.PSObject.Properties.Name -contains 'verdictFAIL') { [int]$moduleValidationResult.verdictFAIL } else { 0 }
                $warnModules = if ($moduleValidationResult.PSObject.Properties.Name -contains 'verdictWARN') { [int]$moduleValidationResult.verdictWARN } else { 0 }
                $results['moduleValidation'] = [ordered]@{
                    status       = if ($failModules -gt 0) { 'FAILED' } else { 'PASSED' }
                    totalModules = if ($moduleValidationResult.PSObject.Properties.Name -contains 'totalModules') { [int]$moduleValidationResult.totalModules } else { 0 }
                    failed       = $failModules
                    warned       = $warnModules
                    outputJson   = $moduleJsonPath
                }
            }
        } catch {
            $results['moduleValidation'] = @{ status = 'ERROR'; message = $_.ToString() }
        }
    } else {
        $results['moduleValidation'] = @{ status = 'SKIPPED'; reason = 'Module validator not found' }
    }
}

# ── SIN Pattern Scan ──────────────────────────────────────────────────────────
Write-Host "`n========== SIN PATTERN SCAN ==========" -ForegroundColor Cyan
$sinScanner = Join-Path $testsDir 'Invoke-SINPatternScanner.ps1'
if (Test-Path $sinScanner) {
    try {
        $sinResult = & $sinScanner -WorkspacePath $scriptRoot
        $p027Count = if ($sinResult) { @($sinResult.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*27(?:\D|$)|NULL-ARRAY-INDEX|(?:^|-)P027(?:\D|$)' }).Count } else { 0 }
        $results['sinPatternScan'] = [ordered]@{
            status   = if ($sinResult -and ($sinResult.critical -gt 0 -or $p027Count -gt 0)) { 'FAILED' } else { 'PASSED' }
            total    = if ($sinResult) { $sinResult.totalFindings } else { 0 }
            critical = if ($sinResult) { $sinResult.critical }      else { 0 }
            p027     = $p027Count
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
if ($results.sinPatternScan) { Write-Host "SIN Scan: $($results.sinPatternScan.status) (C:$($results.sinPatternScan.critical) P027:$($results.sinPatternScan.p027) H:$($results.sinPatternScan.high) M:$($results.sinPatternScan.medium))" -ForegroundColor $(if ($results.sinPatternScan.status -eq 'PASSED') { 'Green' } else { 'Red' }) }
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
if ($results.moduleValidation) {
    $mvColor = if ($results.moduleValidation.status -eq 'PASSED') { 'Green' } else { 'Red' }
    $mvText = if ($results.moduleValidation.PSObject.Properties.Name -contains 'failed') {
        "$($results.moduleValidation.status) (Fail:$($results.moduleValidation.failed) Warn:$($results.moduleValidation.warned))"
    } else {
        "$($results.moduleValidation.status)"
    }
    Write-Host "Modules:  $mvText" -ForegroundColor $mvColor
}
Write-Host "Results:  $historyPath" -ForegroundColor Gray

if (($results.summary.failed -gt 0) -or ($results.fileTypeRoutines -and $results.fileTypeRoutines.failedRoutines -gt 0) -or ($results.sinPatternScan -and $results.sinPatternScan.status -eq 'FAILED') -or ($results.moduleValidation -and $results.moduleValidation.status -eq 'FAILED')) { exit 1 } else { exit 0 }


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





