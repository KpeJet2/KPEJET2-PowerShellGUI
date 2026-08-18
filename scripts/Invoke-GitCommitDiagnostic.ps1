# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# FileRole: Pipeline
<##
.SYNOPSIS
    Persist structured Git/pre-commit failure diagnostics and optionally create a Bugs2FIX item.
.DESCRIPTION
    Captures the failing gate, exit code, command, stderr/stdout, staged files, classification,
    severity, and remediation status. Alpha mode is soft-fail: diagnostics are still emitted and
    a remediation item is attempted, but the caller may continue after recording the failure.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)][string]$Gate,
    [int]$ExitCode = 1,
    [string]$Message = '',
    [string]$OutputText = '',
    [string]$ErrorText = '',
    [string]$CommitCommand = 'git commit',
    [switch]$AlphaSoftFail,
    [switch]$CreateBug2Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path
$logDir = Join-Path (Join-Path $WorkspacePath 'logs') 'git-errors'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$diagnosticId = "GITERROR-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8))"

$combined = (($Message, $OutputText, $ErrorText) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
$classification = 'COMMIT_GATE_FAILURE'
$severity = 'HIGH'
if ($combined -match '(?i)secret|credential|private key') { $classification = 'SECRET_GATE_FAILURE'; $severity = 'CRITICAL' }
elseif ($combined -match '(?i)baseline regression|drift') { $classification = 'BASELINE_REGRESSION'; $severity = 'HIGH' }
elseif ($combined -match '(?i)parser|missing closing|syntax') { $classification = 'PARSER_FAILURE'; $severity = 'CRITICAL' }
elseif ($combined -match '(?i)timeout|timed out|prompt') { $classification = 'TIMEOUT_OR_INTERACTIVE_PROMPT'; $severity = 'HIGH' }
elseif ($combined -match '(?i)reference|canonical path|link') { $classification = 'REFERENCE_OR_PATH_FAILURE'; $severity = 'HIGH' }

$relatedPermutations = @(
    'same gate with nonzero exit code',
    'same gate with parser or missing-brace output',
    'same gate with timeout or interactive prompt output',
    'same gate with baseline drift/regression output',
    'same gate with secret, path, reference, or UI safety output',
    'same failure repeated across staged-file combinations'
)

$stagedFiles = @(git -C $WorkspacePath diff --cached --name-only --diff-filter=ACMR 2>$null)
$record = [ordered]@{
    diagnosticId = $diagnosticId
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspace = $WorkspacePath
    gate = $Gate
    exitCode = $ExitCode
    classification = $classification
    severity = $severity
    relatedPermutations = $relatedPermutations
    alphaSoftFail = [bool]$AlphaSoftFail
    commitCommand = $CommitCommand
    message = $Message
    output = $OutputText
    error = $ErrorText
    stagedFiles = @($stagedFiles)
    remediation = [ordered]@{
        assessment = 'FAIL'
        jobLog = 'PENDING'
        bug2fix = 'PENDING'
        autonomousCommitSync = if ($AlphaSoftFail) { 'SOFT_FAIL_ALPHA' } else { 'BLOCKED' }
    }
}

$jsonPath = Join-Path $logDir "$diagnosticId.json"
$mdPath = Join-Path $logDir "$diagnosticId.md"
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
@(
    "# Git Commit Diagnostic: $diagnosticId",
    '',
    "- Gate: $Gate",
    "- Classification: $classification",
    "- Severity: $severity",
    "- Related permutations: $($relatedPermutations -join '; ')",
    "- Exit code: $ExitCode",
    "- Alpha soft-fail: $([bool]$AlphaSoftFail)",
    "- Assessment: FAIL",
    '',
    '## Reason',
    ($Message -replace "`r?`n", ' '),
    '',
    '## Captured output',
    '```text',
    $OutputText,
    $ErrorText,
    '```'
) | Set-Content -LiteralPath $mdPath -Encoding UTF8

$bug2fixCreated = $false
if ($CreateBug2Fix) {
    try {
        $modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
        Import-Module $modulePath -Force -ErrorAction Stop
        $title = "[GIT][$classification] $Gate"
        $active = @(Get-PipelineItems -WorkspacePath $WorkspacePath -Type 'Bugs2FIX' | Where-Object {
            ([string]$_.title).Trim() -eq $title -and ([string]$_.status).Trim().ToUpperInvariant().Replace('-', '_') -in @('OPEN','IN_PROGRESS','PLANNED')
        })
        if ($active.Count -eq 0) {
            $item = New-PipelineItem -Type 'Bugs2FIX' -Title $title -Description (($Message, $ErrorText, $OutputText) -join "`n") `
                -Priority $severity -Source 'BugTracker' -Category 'git-commit-diagnostic' -SuggestedBy 'PreCommit'
            $item.diagnosticId = $diagnosticId
            $item.classification = $classification
            $item.gate = $Gate
            Add-PipelineItem -WorkspacePath $WorkspacePath -Item $item -SkipArtifactRefresh | Out-Null
            $bug2fixCreated = $true
        }
        $record.remediation.bug2fix = if ($bug2fixCreated) { 'CREATED' } else { 'DEDUPLICATED' }
    }
    catch {
        $record.remediation.bug2fix = "ERROR: $($_.Exception.Message)"
    }
}

$record.remediation.jobLog = $mdPath
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-Host "[git-error] $classification severity=$severity gate=$Gate exit=$ExitCode" -ForegroundColor Red
Write-Host "[git-error] JSON: $jsonPath" -ForegroundColor Yellow
Write-Host "[git-error] MD  : $mdPath" -ForegroundColor Yellow
Write-Host "[git-error] Bug2FIX: $($record.remediation.bug2fix)" -ForegroundColor Yellow
if ($AlphaSoftFail) { Write-Warning '[git-error] Alpha soft-fail active: commit caller may continue after recording this failure.' }
if ($AlphaSoftFail) { exit 0 }
exit 1
