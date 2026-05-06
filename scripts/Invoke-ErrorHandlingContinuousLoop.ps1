# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Runs iterative error-handling scan/remediation loops until convergence.
.DESCRIPTION
    Repeatedly executes Test-ErrorHandlingCompliance.ps1, applies automated remediation
    via Invoke-ErrorHandlingRemediation.ps1, and stops when no further reduction is seen
    or max iterations is reached.
.PARAMETER WorkspacePath
    Workspace root path. Defaults to parent of script folder.
.PARAMETER MaxIterations
    Maximum loop iterations.
.PARAMETER TargetFilePatterns
    Optional wildcard patterns to limit remediation scope.
.PARAMETER IncludeSilentlyContinue
    Include SIN-003 targets in reporting (manual remediation guidance only).
.NOTES
    Author   : The Establishment
    Date     : 2026-04-04
    FileRole : Script
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [int]$MaxIterations = 5,
    [string[]]$TargetFilePatterns = @('*'),
    [switch]$IncludeSilentlyContinue
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$testsDir = Join-Path $WorkspacePath 'tests'
$scriptsDir = Join-Path $WorkspacePath 'scripts'
$reportsDir = Join-Path $WorkspacePath '~REPORTS'
$loopDir = Join-Path $reportsDir 'ErrorHandlingLoop'

$scanScript = Join-Path $testsDir 'Test-ErrorHandlingCompliance.ps1'
$remedScript = Join-Path $scriptsDir 'Invoke-ErrorHandlingRemediation.ps1'

if (-not (Test-Path $scanScript)) { throw "Missing scanner script: $scanScript" }
if (-not (Test-Path $remedScript)) { throw "Missing remediation script: $remedScript" }
if (-not (Test-Path $loopDir)) {
    New-Item -Path $loopDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
}

function Get-LatestComplianceReport {
    param([Parameter(Mandatory = $true)][string]$ReportRoot)
    $files = @(Get-ChildItem -Path $ReportRoot -Filter 'error-handling-compliance-*.json' -File -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending)
    if (@($files).Count -eq 0) {
        throw 'No compliance report files found after scan run.'
    }
    return $files[0].FullName
}

function Get-FilteredStats {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [switch]$WithSilentlyContinue
    )

    $normalizedPatterns = [System.Collections.ArrayList]::new()
    foreach ($raw in @($Patterns)) {
        foreach ($piece in ([string]$raw -split ',')) {
            $trimmed = $piece.Trim().Trim('"', "'")
            if ($trimmed) { [void]$normalizedPatterns.Add($trimmed) }
        }
    }
    if (@($normalizedPatterns).Count -eq 0) { [void]$normalizedPatterns.Add('*') }

    $violations = @($Report.violations)
    if (@($normalizedPatterns).Count -gt 0 -and -not (@($normalizedPatterns).Count -eq 1 -and $normalizedPatterns[0] -eq '*')) {
        $violations = @($violations | Where-Object {
            $f = [string]$_.File
            $leaf = [System.IO.Path]::GetFileName($f)
            $matched = $false
            foreach ($p in $normalizedPatterns) {
                if ($f -like "*$p*" -or $leaf -ieq $p) { $matched = $true; break }
            }
            $matched
        })
    }

    $autoPatterns = @('SEC11-WriteWarning', 'SEC11-WriteError')
    if ($WithSilentlyContinue) { $autoPatterns += 'SIN-003-SilentlyContinue' }

    $target = @($violations | Where-Object { $_.Pattern -in $autoPatterns })

    return [ordered]@{
        totalViolations = @($violations).Count
        targetViolations = @($target).Count
        byPattern = @(@($target | Group-Object Pattern | Sort-Object Name) | ForEach-Object {
            [ordered]@{
                pattern = $_.Name
                count = $_.Count
            }
        })
        files = @(@($target | Group-Object File | Sort-Object Name) | ForEach-Object {
            [ordered]@{
                file = $_.Name
                count = $_.Count
            }
        })
    }
}

$history = [System.Collections.ArrayList]::new()
$prevTargetCount = $null

for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
    Write-Host "[Loop] Iteration $iteration/$MaxIterations - scanning..." -ForegroundColor Cyan
    & $scanScript -Path $WorkspacePath -Exclude @('.git','.history','.vscode','node_modules','.venv','pki','temp','remediation-backups') -Detailed | Out-Null

    $latest = Get-LatestComplianceReport -ReportRoot $reportsDir
    $report = Get-Content -Path $latest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $stats = Get-FilteredStats -Report $report -Patterns $TargetFilePatterns -WithSilentlyContinue:$IncludeSilentlyContinue

    $entry = [ordered]@{
        iteration = $iteration
        complianceReport = $latest
        targetViolations = $stats.targetViolations
        totalViolations = $stats.totalViolations
        byPattern = $stats.byPattern
    }

    [void]$history.Add($entry)

    Write-Host "[Loop] Iteration $iteration target violations: $($stats.targetViolations)" -ForegroundColor Yellow

    if ($stats.targetViolations -le 0) {
        Write-Host '[Loop] No target violations remain; stopping.' -ForegroundColor Green
        break
    }

    if ($null -ne $prevTargetCount -and $stats.targetViolations -ge $prevTargetCount) {
        Write-Host '[Loop] No further reduction detected; stopping to avoid churn.' -ForegroundColor Yellow
        break
    }

    $prevTargetCount = $stats.targetViolations

    foreach ($patternName in @('WriteWarning', 'WriteError')) {
        foreach ($fileItem in $stats.files) {
            $leaf = Split-Path -Leaf ([string]$fileItem.file)
            try {
                & $remedScript -Path $WorkspacePath -FileFilter $leaf -Pattern $patternName | Out-Null
            } catch {
                Write-Host "[Loop] Remediation failed for $leaf ($patternName): $_" -ForegroundColor Red
            }
        }
    }
}

$loopReport = [ordered]@{
    schema = 'ErrorHandlingLoop/1.0'
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    maxIterations = $MaxIterations
    includeSilentlyContinue = [bool]$IncludeSilentlyContinue
    targetFilePatterns = @($TargetFilePatterns)
    history = @($history)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outPath = Join-Path $loopDir "error-handling-loop-$stamp.json"
$loopReport | ConvertTo-Json -Depth 10 | Set-Content -Path $outPath -Encoding UTF8 -ErrorAction Stop
Write-Host "[Loop] Report saved: $outPath" -ForegroundColor Green

return [PSCustomObject]$loopReport

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





