#Requires -Version 5.1
# Author: The Establishment
# Date: 2604
# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# FileRole: Script
<#
.SYNOPSIS
    Validate pipeline artifact coherence and detect stale interrupted items.
.DESCRIPTION
    Imports the CronAiAthon pipeline module, optionally refreshes derived artifacts,
    then validates that todo/_index.json, todo/_bundle.js, and
    todo/_master-aggregated.json are in sync with the active todo item files.
    Also reports stale OPEN, PLANNED, IN_PROGRESS, and BLOCKED items.
    Includes recursive discoverability checks, MIME/filter visibility checks,
    JSON payload sanitization checks, and SHA-256 evidence for core artifacts.
.EXAMPLE
    .\Invoke-PipelineIntegrityCheck.ps1
    .\Invoke-PipelineIntegrityCheck.ps1 -Refresh
#>
param(
    [string]$WorkspacePath,
    [switch]$Refresh,
    [switch]$WriteReport,
    [string]$ReportPath,
    [switch]$FailOnStale,
    [switch]$FailOnControlViolation,
    [int]$OpenDays = 14,
    [int]$PlannedDays = 7,
    [int]$InProgressDays = 3,
    [int]$BlockedDays = 7
)

$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent $PSScriptRoot
}

$modulePath = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Error "Pipeline module not found: $modulePath"
    return
}

Import-Module $modulePath -Force -ErrorAction Stop

function Get-WorkspaceRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $rootPrefix = $RootPath.TrimEnd('\\') + '\\'
    if ($FullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($rootPrefix.Length) -replace '/', '\\'
    }
    return $FullPath
}

function Get-ExpectedMimeType {
    param([Parameter(Mandatory = $true)][string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.json' { return 'application/json' }
        '.js' { return 'text/javascript' }
        '.ps1' { return 'text/plain' }
        '.psm1' { return 'text/plain' }
        '.psd1' { return 'text/plain' }
        '.md' { return 'text/markdown' }
        '.html' { return 'text/html' }
        '.xhtml' { return 'application/xhtml+xml' }
        '.xml' { return 'application/xml' }
        default { return 'application/octet-stream' }
    }
}

function Test-SafePayloadString {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return $true }
    if ($Text -match '(?i)<\s*/?script\b') { return $false }
    if ($Text -match '(?i)javascript\s*:') { return $false }
    if ($Text -match '(?i)data\s*:\s*text/html') { return $false }
    if ($Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return $false }
    return $true
}

function Test-JsonPayloadSafety {
    param([Parameter(Mandatory = $true)][string]$Path)

    $issues = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) {
        $issues.Add([pscustomobject]@{
            path = $Path
            kind = 'missing'
            detail = 'File does not exist'
        }) | Out-Null
        return [pscustomobject]@{ isSafe = $false; issues = @($issues) }
    }

    $raw = ''
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        $issues.Add([pscustomobject]@{
            path = $Path
            kind = 'read-error'
            detail = $_.Exception.Message
        }) | Out-Null
        return [pscustomobject]@{ isSafe = $false; issues = @($issues) }
    }

    if (-not (Test-SafePayloadString -Text $raw)) {
        $issues.Add([pscustomobject]@{
            path = $Path
            kind = 'unsafe-raw-string'
            detail = 'Raw payload contains blocked patterns or control bytes'
        }) | Out-Null
    }

    try {
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $issues.Add([pscustomobject]@{
            path = $Path
            kind = 'invalid-json'
            detail = $_.Exception.Message
        }) | Out-Null
        return [pscustomobject]@{ isSafe = $false; issues = @($issues) }
    }

    # Bounded scan keeps validation fast on very large aggregated JSON payloads.
    $scanLimit = [Math]::Min($raw.Length, 1048576)
    $scanSample = if ($scanLimit -gt 0) { $raw.Substring(0, $scanLimit) } else { '' }
    if (-not (Test-SafePayloadString -Text $scanSample)) {
        $issues.Add([pscustomobject]@{
            path = $Path
            kind = 'unsafe-sampled-string'
            detail = 'Sampled payload segment contains blocked patterns or control bytes'
        }) | Out-Null
    }

    return [pscustomobject]@{ isSafe = (@($issues).Count -eq 0); issues = @($issues) }
}

if ($Refresh) {
    Write-Host "Refreshing pipeline artifacts..." -ForegroundColor Cyan
    $refreshResult = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
    Write-Host "  Master: $($refreshResult.master)" -ForegroundColor Gray
    Write-Host "  Bundle: $($refreshResult.bundle)" -ForegroundColor Gray
    Write-Host "  Index:  $($refreshResult.index)" -ForegroundColor Gray
}

$result = Test-PipelineArtifactIntegrity -WorkspacePath $WorkspacePath -IncludeStaleCheck -OpenDays $OpenDays -PlannedDays $PlannedDays -InProgressDays $InProgressDays -BlockedDays $BlockedDays

$todoRoot = Join-Path $WorkspacePath 'todo'
$recursiveExcludeFolders = @('archive', 'completed', 'done', 'rejected', 'blocked', '.history')
$discoverableFiles = @()
if (Test-Path -LiteralPath $todoRoot) {
    $discoverableFiles = @(Get-ChildItem -LiteralPath $todoRoot -File -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object {
        $parts = $_.FullName.Substring($todoRoot.Length).TrimStart('\\') -split '[\\/]'
        $skip = $false
        foreach ($folderName in $recursiveExcludeFolders) {
            if ($parts -contains $folderName) {
                $skip = $true
                break
            }
        }
        if ($skip) { return $false }
        return ($_.Name -notlike '_index.json' -and $_.Name -notlike '_master-aggregated.json')
    })
}

$discoverability = [ordered]@{
    enabled = $true
    scanRoot = $todoRoot
    includePattern = '*.json'
    recursive = $true
    excludedFolders = $recursiveExcludeFolders
    discoveredCount = @($discoverableFiles).Count
    pipelineActiveCount = [int]$result.counts.activeFileCount
    countsAligned = (@($discoverableFiles).Count -ge [int]$result.counts.activeFileCount)
    sample = @($discoverableFiles | Select-Object -First 15 | ForEach-Object { Get-WorkspaceRelativePath -RootPath $WorkspacePath -FullPath $_.FullName })
}

$coreArtifacts = @(
    (Join-Path $todoRoot '_index.json'),
    (Join-Path $todoRoot '_master-aggregated.json'),
    (Join-Path $todoRoot '_bundle.js')
)

$mimeAllowList = @('application/json', 'text/javascript')
$artifactStatus = [System.Collections.Generic.List[object]]::new()
$payloadIssues = [System.Collections.Generic.List[object]]::new()
foreach ($artifactPath in $coreArtifacts) {
    $exists = Test-Path -LiteralPath $artifactPath
    $expectedMime = Get-ExpectedMimeType -Path $artifactPath
    $sha256 = $null
    $size = 0
    if ($exists) {
        $fileInfo = Get-Item -LiteralPath $artifactPath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $size = [int64]$fileInfo.Length
        }
        try {
            $sha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch {
            $payloadIssues.Add([pscustomobject]@{
                path = Get-WorkspaceRelativePath -RootPath $WorkspacePath -FullPath $artifactPath
                kind = 'hash-error'
                detail = $_.Exception.Message
            }) | Out-Null
        }
    } else {
        $payloadIssues.Add([pscustomobject]@{
            path = Get-WorkspaceRelativePath -RootPath $WorkspacePath -FullPath $artifactPath
            kind = 'missing-artifact'
            detail = 'Required artifact is missing'
        }) | Out-Null
    }

    $artifactStatus.Add([pscustomobject]@{
        path = Get-WorkspaceRelativePath -RootPath $WorkspacePath -FullPath $artifactPath
        exists = $exists
        sizeBytes = $size
        expectedMime = $expectedMime
        mimeAllowed = ($mimeAllowList -contains $expectedMime)
        sha256 = $sha256
    }) | Out-Null

    if ($exists -and $expectedMime -eq 'application/json') {
        $safeResult = Test-JsonPayloadSafety -Path $artifactPath
        foreach ($issue in @($safeResult.issues)) {
            $payloadIssues.Add([pscustomobject]@{
                path = Get-WorkspaceRelativePath -RootPath $WorkspacePath -FullPath $issue.path
                kind = $issue.kind
                detail = $issue.detail
            }) | Out-Null
        }
    }
}

$controlChecks = [ordered]@{
    recursiveDiscoverability = [bool]$discoverability.countsAligned
    requiredArtifactsPresent = (@($artifactStatus | Where-Object { -not $_.exists }).Count -eq 0)
    mimeAllowListConformant = (@($artifactStatus | Where-Object { -not $_.mimeAllowed }).Count -eq 0)
    payloadSanitized = (@($payloadIssues).Count -eq 0)
}

$controlsHealthy = (@($controlChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0)
$cryptoChainSource = @($artifactStatus | ForEach-Object { "$($_.path)|$($_.sha256)" }) -join "`n"
if ([string]::IsNullOrWhiteSpace($cryptoChainSource)) {
    $cryptoChainSource = '[no-artifacts]'
}
$invocationHash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cryptoChainSource))
).Replace('-', '')

$controls = [ordered]@{
    isHealthy = $controlsHealthy
    filters = [ordered]@{
        recursive = $true
        includePattern = '*.json'
        excludedFolders = $recursiveExcludeFolders
        mimeAllowList = $mimeAllowList
    }
    discoverability = $discoverability
    artifacts = @($artifactStatus)
    payloadIssues = @($payloadIssues)
    checks = $controlChecks
    cryptographicEvidence = [ordered]@{
        algorithm = 'SHA256'
        invocationHash = $invocationHash
        evidenceCount = @($artifactStatus).Count
    }
}

$overallHealthy = ([bool]$result.isHealthy -and [bool]$controls.isHealthy)

$report = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    refreshed = [bool]$Refresh
    failOnStale = [bool]$FailOnStale
    failOnControlViolation = [bool]$FailOnControlViolation
    thresholds = [ordered]@{
        openDays = $OpenDays
        plannedDays = $PlannedDays
        inProgressDays = $InProgressDays
        blockedDays = $BlockedDays
    }
    overallHealthy = [bool]$overallHealthy
    result = $result
    controls = $controls
}

$shouldWriteReport = ($WriteReport -or -not [string]::IsNullOrWhiteSpace($ReportPath))
$resolvedReportPath = $null
if ($shouldWriteReport) {
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineIntegrity'
        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        $ReportPath = Join-Path $reportDir ("integrity-{0}.json" -f (Get-Date -Format 'yyMMddHHmm'))
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -Path $ReportPath -Encoding UTF8
    $resolvedReportPath = $ReportPath
}

Write-Host "`n=== Pipeline Artifact Integrity ===" -ForegroundColor Cyan
Write-Host "Healthy: $overallHealthy" -ForegroundColor $(if ($overallHealthy) { 'Green' } else { 'Yellow' })
Write-Host "  Index count:      $($result.counts.indexCount)" -ForegroundColor White
Write-Host "  Master count:     $($result.counts.masterCount)" -ForegroundColor White
Write-Host "  Index file count: $($result.counts.indexFileCount)" -ForegroundColor White
Write-Host "  Bundle count:     $($result.counts.bundleCount)" -ForegroundColor White
Write-Host "  Active files:     $($result.counts.activeFileCount)" -ForegroundColor White

Write-Host "`nChecks:" -ForegroundColor White
$result.checks.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value) { 'Green' } else { 'Red' }
    Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor $color
}

Write-Host "`nControl Checks:" -ForegroundColor White
$controls.checks.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value) { 'Green' } else { 'Red' }
    Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor $color
}
Write-Host "  discoverability count: $($controls.discoverability.discoveredCount)" -ForegroundColor White
Write-Host "  pipeline active count: $($controls.discoverability.pipelineActiveCount)" -ForegroundColor White
Write-Host "  invocation SHA256:     $($controls.cryptographicEvidence.invocationHash)" -ForegroundColor Gray

if (@($controls.payloadIssues).Count -gt 0) {
    Write-Host "`nPayload/Sanitization Issues:" -ForegroundColor Yellow
    foreach ($issue in @($controls.payloadIssues | Select-Object -First 20)) {
        Write-Host "  [$($issue.kind)] $($issue.path) :: $($issue.detail)" -ForegroundColor DarkYellow
    }
}

if ($null -ne $result.interruptions) {
    Write-Host "`nStale Interruptions: $($result.interruptions.total)" -ForegroundColor $(if ($result.interruptions.total -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  OPEN:        $($result.interruptions.byStatus.OPEN)" -ForegroundColor White
    Write-Host "  PLANNED:     $($result.interruptions.byStatus.PLANNED)" -ForegroundColor White
    Write-Host "  IN_PROGRESS: $($result.interruptions.byStatus.IN_PROGRESS)" -ForegroundColor White
    Write-Host "  BLOCKED:     $($result.interruptions.byStatus.BLOCKED)" -ForegroundColor White

    foreach ($item in @($result.interruptions.items) | Sort-Object status, @{ Expression = 'ageDays'; Descending = $true }, id | Select-Object -First 15) {
        Write-Host "  [$($item.status)] $($item.id) age=$($item.ageDays)d threshold=$($item.threshold)d :: $($item.title)" -ForegroundColor DarkYellow
    }
}

if ($resolvedReportPath) {
    Write-Host "`nReport: $resolvedReportPath" -ForegroundColor Gray
}

if (-not $overallHealthy) {
    $failedChecks = @($result.checks.GetEnumerator() | Where-Object { -not $_.Value })
    $failedControlChecks = @($controls.checks.GetEnumerator() | Where-Object { -not $_.Value })
    if ($FailOnStale -or $FailOnControlViolation -or @($failedChecks).Count -gt 0 -or @($failedControlChecks).Count -gt 0) {
        exit 1
    }
}

exit 0
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





