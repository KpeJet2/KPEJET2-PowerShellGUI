# VersionTag: 2607.B7.V53.0
# FileRole: Script
# SupportPS5.1: true
# SupportsPS7.6: true
#Requires -Version 5.1
<#
.SYNOPSIS
    Per-file Pester triage harness. Runs each *.Tests.ps1 in isolation with a
    wallclock timeout, captures structured failure JSON, then aggregates.
.DESCRIPTION
    Phase 1 discovery tool. Each test file is run in a fresh child process so
    a hang in one file (e.g. AssistedSASC mandatory-param prompt) cannot poison
    the rest of the harvest. Stdout/stderr go to files via Start-Process so we
    cannot deadlock the way `*> $log` does in Run-PipelineChurn35.ps1.
.PARAMETER WorkspacePath
    Repository root. Defaults to the parent of $PSScriptRoot.
.PARAMETER Engine
    PS5 (default, powershell.exe) or PS7 (pwsh.exe).
.PARAMETER PerFileTimeoutSec
    Wallclock cap per test file. Defaults to 300 (5 min).
.PARAMETER OutputDir
    Where per-file JSONs go. Defaults to <Workspace>/~REPORTS/pester-triage/by-file.
.PARAMETER Include
    Optional regex; only matching file names will run.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [ValidateSet('PS5','PS7')] [string]$Engine = 'PS5',
    [int]$PerFileTimeoutSec = 300,
    [string]$OutputDir,
    [string]$Include
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}
$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path

$testsDir = Join-Path $WorkspacePath 'tests'
$runner   = Join-Path $WorkspacePath 'scripts\Invoke-PesterSingleFile.ps1'
if (-not (Test-Path -LiteralPath $runner)) { throw "Runner not found: $runner" }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $WorkspacePath ("~REPORTS\pester-triage\by-file-{0}-{1}" -f $Engine, $ts)
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$logDir = Join-Path $OutputDir '_proc-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$exe = if ($Engine -eq 'PS7') {
    (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
} else {
    (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
}
if (-not $exe) { throw "Engine binary for $Engine not found on PATH." }

$files = Get-ChildItem -LiteralPath $testsDir -Filter '*.Tests.ps1' -File |
    Sort-Object Name
if ($Include) { $files = @($files | Where-Object { $_.Name -match $Include }) }
$total = @($files).Count

Write-Host "[triage] Engine=$Engine Files=$total Timeout=${PerFileTimeoutSec}s Output=$OutputDir" -ForegroundColor Cyan

$summary = @()
$i = 0
foreach ($f in $files) {
    $i++
    $stamp = "{0:D3}" -f $i
    $outJson = Join-Path $OutputDir ("{0}-{1}.json" -f $stamp, ($f.BaseName -replace '\.','_'))
    $stdOut  = Join-Path $logDir   ("{0}-{1}.out.log" -f $stamp, $f.BaseName)
    $stdErr  = Join-Path $logDir   ("{0}-{1}.err.log" -f $stamp, $f.BaseName)

    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File', $runner,
        '-TestFile', $f.FullName,
        '-OutputJson', $outJson
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[{0}/{1}] {2}" -f $i, $total, $f.Name) -ForegroundColor Gray
    $p = $null
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList `
            -RedirectStandardOutput $stdOut -RedirectStandardError $stdErr `
            -WindowStyle Hidden -PassThru
    } catch {
        Write-Warning "  Start-Process failed: $($_.Exception.Message)"
        $summary += [ordered]@{
            file = $f.Name; status = 'SPAWN_ERROR'; total = 0; passed = 0; failed = 0
            skipped = 0; elapsedSec = 0; error = "$($_.Exception.Message)"; jsonPath = $outJson
        }
        continue
    }

    $timedOut = $false
    if (-not $p.WaitForExit($PerFileTimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill($true) } catch { try { $p.Kill() } catch { <# Intentional: already gone #> } }
        try { $p.WaitForExit(5000) | Out-Null } catch { <# Intentional: ignore #> }
    }
    $sw.Stop()
    $exitCode = if ($p -and -not $timedOut) { try { $p.ExitCode } catch { -1 } } else { -1 }

    $row = [ordered]@{
        file       = $f.Name
        status     = 'UNKNOWN'
        total      = 0
        passed     = 0
        failed     = 0
        skipped    = 0
        elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        timedOut   = $timedOut
        exitCode   = $exitCode
        error      = $null
        jsonPath   = $outJson
    }

    if ($timedOut) {
        $row.status = 'TIMEOUT'
        $row.error  = "Exceeded ${PerFileTimeoutSec}s wallclock"
        Write-Host ("  TIMEOUT after {0}s" -f $row.elapsedSec) -ForegroundColor Red
    }
    elseif (Test-Path -LiteralPath $outJson) {
        try {
            $j = Get-Content -LiteralPath $outJson -Raw -Encoding UTF8 | ConvertFrom-Json
            $row.status  = "$($j.status)"
            $row.total   = [int]$j.total
            $row.passed  = [int]$j.passed
            $row.failed  = [int]$j.failed
            $row.skipped = [int]$j.skipped
            if ($j.PSObject.Properties.Name -contains 'error' -and $j.error) { $row.error = "$($j.error)" }
            $colour = if ($row.failed -eq 0 -and $row.status -eq 'PASSED') { 'Green' }
                      elseif ($row.status -eq 'ERROR') { 'Magenta' }
                      else { 'Yellow' }
            Write-Host ("  {0}  total={1} passed={2} failed={3} skipped={4} ({5}s)" -f `
                $row.status, $row.total, $row.passed, $row.failed, $row.skipped, $row.elapsedSec) `
                -ForegroundColor $colour
        } catch {
            $row.status = 'PARSE_ERROR'
            $row.error  = "JSON parse failed: $($_.Exception.Message)"
            Write-Host "  PARSE_ERROR" -ForegroundColor Magenta
        }
    } else {
        $row.status = 'NO_OUTPUT'
        $row.error  = "Runner did not produce JSON (exit=$exitCode)"
        Write-Host "  NO_OUTPUT (exit=$exitCode)" -ForegroundColor Magenta
    }

    $summary += $row
}

$grandTotal = 0; $grandPassed = 0; $grandFailed = 0; $grandSkipped = 0
foreach ($r in $summary) {
    $grandTotal   += [int]$r.total
    $grandPassed  += [int]$r.passed
    $grandFailed  += [int]$r.failed
    $grandSkipped += [int]$r.skipped
}

$aggregate = [ordered]@{
    workspace        = $WorkspacePath
    engine           = $Engine
    timestamp        = $ts
    perFileTimeoutSec= $PerFileTimeoutSec
    fileCount        = $total
    grandTotal       = [int]$grandTotal
    grandPassed      = [int]$grandPassed
    grandFailed      = [int]$grandFailed
    grandSkipped     = [int]$grandSkipped
    timedOutCount    = @($summary | Where-Object { $_.timedOut }).Count
    errorCount       = @($summary | Where-Object { $_.status -in 'ERROR','NO_OUTPUT','PARSE_ERROR','SPAWN_ERROR' }).Count
    files            = $summary
}

$aggregatePath = Join-Path $OutputDir ("_aggregate-{0}-{1}.json" -f $Engine, $ts)
$json = $aggregate | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($aggregatePath, $json, (New-Object System.Text.UTF8Encoding $true))

Write-Host ""
Write-Host "[triage] DONE   files=$total  total=$grandTotal  passed=$grandPassed  failed=$grandFailed  skipped=$grandSkipped  timedOut=$($aggregate.timedOutCount)  errored=$($aggregate.errorCount)" -ForegroundColor Cyan
Write-Host "[triage] Aggregate: $aggregatePath" -ForegroundColor Cyan

exit ([int]($grandFailed -gt 0 -or $aggregate.errorCount -gt 0 -or $aggregate.timedOutCount -gt 0))


