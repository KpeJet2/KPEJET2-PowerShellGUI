# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS  CI pre-commit gate: parse check + critical SIN scan + P027 null-index scan + encoding + version tag alignment.
.DESCRIPTION
    Lightweight gate designed to run before every commit (or as CronProcessor pre-step).
    Catches the most common, high-impact issues without the full SIN scanner runtime:

      Gate 1 - PowerShell parse errors (all .ps1/.psm1 files in scope)
      Gate 2 - Critical SIN patterns (P001/P009/P010): hardcoded creds, IEX, path injection
      Gate 3 - P027 null-array-index findings from the SIN scanner
      Gate 4 - Encoding violations: UTF-8 BOM required for .ps1/.psm1 (P006)
      Gate 5 - VersionTag present and non-empty in every staged .ps1/.psm1 (P007)

    Exit codes:
      0 = all gates passed
      1 = one or more gates failed (details in output / JSON report)

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.  Default: parent of $PSScriptRoot.
.PARAMETER StagedFiles
    Comma-separated or array of relative/absolute file paths to check.
    When omitted, checks all .ps1/.psm1 files under modules/, scripts/, tests/.
.PARAMETER OutputJson
    Path to write JSON gate report.  Default: temp\precommit-<timestamp>.json.
.PARAMETER Quiet
    Suppress per-finding console output; only print summary and exit code.
.PARAMETER FailOnWarning
    Treat Gate 4 (encoding) and Gate 5 (VersionTag) findings as failures.
    By default only Gates 1-3 block the commit.

.EXAMPLE
    pwsh -File tests\Invoke-PreCommitValidation.ps1

.EXAMPLE
    pwsh -File tests\Invoke-PreCommitValidation.ps1 -StagedFiles 'modules\Foo.psm1','scripts\Bar.ps1'

.EXAMPLE
    pwsh -File tests\Invoke-PreCommitValidation.ps1 -FailOnWarning -Quiet
#>
param(
    [string]  $WorkspacePath  = (Split-Path -Parent $PSScriptRoot),
    [string[]]$StagedFiles    = @(),
    [string]  $OutputJson     = '',
    [switch]  $Quiet,
    [switch]  $FailOnWarning,
    [switch]  $SkipPipelineControlGate,
    # Gate 3 (P027) performance guards. P027 scanner is O(n) per file but its AST walk
    # is heavy on very large files; skip oversize files and cap the total count to keep
    # pre-commit under ~30s.
    [int]     $MaxP027FileSizeKB = 256,
    [int]     $MaxP027Files       = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Gate {
    param([string]$Msg, [string]$Level = 'Info')
    if ($Quiet) { return }
    $colour = switch ($Level) {
        'Pass'  { 'Green' }
        'Fail'  { 'Red' }
        'Warn'  { 'Yellow' }
        'Head'  { 'Cyan' }
        default { 'White' }
    }
    Write-Host $Msg -ForegroundColor $colour
}

function Get-TargetFiles {
    param([string]$Root, [string[]]$Specific)

    if (@($Specific).Count -gt 0) {
        return @($Specific | ForEach-Object {
            $path = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Root $_ }
            if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path } else { Write-Gate "[WARN] File not found: $_" 'Warn' }
        } | Where-Object { $_ })
    }

    $scan = @('modules', 'scripts', 'tests')
    $exclude = @('.history', 'checkpoints', 'UPM', '~DOWNLOADS', '~REPORTS', 'node_modules', '.git', '.venv')
    $allFiles = @()
    foreach ($dir in $scan) {
        $dirPath = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $dirPath)) { continue }
        $allFiles += Get-ChildItem -Path $dirPath -Recurse -Include '*.ps1', '*.psm1' -File |
            Where-Object {
                $parts = $_.FullName -split '[\\/]'
                -not ($parts | Where-Object { $exclude -contains $_ })
            }
    }
    return $allFiles
}

function Invoke-ParseGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        $parseErrors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($err in $parseErrors) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'Parse'
                Severity = 'ERROR'
                File     = $f.FullName
                Line     = $err.Extent.StartLineNumber
                Message  = $err.Message
            })
        }
    }
    return @($findings)
}

function Invoke-CriticalSINGate {
    param([System.IO.FileInfo[]]$Files)
    $patterns = @(
        [PSCustomObject]@{
            Id = 'P001'
            Name = 'HARDCODED-CREDENTIALS'
            Regex = [regex]::new('(?i)(password|passwd|pwd|secret|apikey|api_key|token|connectionstring)\s*[=:]\s*[''\"][^$''\"]{4,}[''\"]', [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        [PSCustomObject]@{
            Id = 'P009'
            Name = 'UNVALIDATED-PATH-JOIN'
            Regex = [regex]::new('Join-Path\s+.*\$_(\.|\[)|\$[a-zA-Z]+Path\s*=\s*.*\+.*\$_', [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
        [PSCustomObject]@{
            Id = 'P010'
            Name = 'IEX-DYNAMIC-STRING'
            Regex = [regex]::new('(?i)(Invoke-Expression|\biex\b)\s+[^#\n]*\$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
        }
    )

    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        if (-not $lines) { continue }
        $inBlockComment = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lineText = if ($i -lt @($lines).Count) { [string]$lines[$i] } else { '' }
            $trimmed = $lineText.TrimStart()
            if (-not $inBlockComment -and $trimmed -match '<#') { $inBlockComment = $true }
            if ($inBlockComment -and $trimmed -match '#>') { $inBlockComment = $false; continue }
            if ($inBlockComment) { continue }
            if ($trimmed.StartsWith('#')) { continue }
            if ($lineText -match '#\s*SIN-EXEMPT:\s*\*') { continue }

            $commentPos = -1
            $inStrChar = $null
            $lineLength = $lineText.Length
            for ($ci = 0; $ci -lt $lineLength; $ci++) {
                $ch = $lineText.Substring($ci, 1)
                if ($null -eq $inStrChar) {
                    if ($ch -eq '"' -or $ch -eq "'") { $inStrChar = $ch }
                    elseif ($ch -eq '#') { $commentPos = $ci; break }
                } elseif ($ch -eq $inStrChar) {
                    $inStrChar = $null
                }
            }

            foreach ($pat in $patterns) {
                if ($lineText -match "#\s*SIN-EXEMPT:\s*[^,\r\n]*$($pat.Id)") { continue }
                $match = $pat.Regex.Match($lineText)
                if (-not $match.Success) { continue }
                if ($commentPos -ge 0 -and $match.Index -ge $commentPos) { continue }
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'CriticalSIN'
                    Severity = 'ERROR'
                    File     = $f.FullName
                    Line     = $i + 1
                    Pattern  = $pat.Id
                    PatName  = $pat.Name
                    Message  = "$($pat.Id) $($pat.Name): $($match.Value.Substring(0, [Math]::Min($match.Value.Length, 60)))"
                })
            }
        }
    }
    return @($findings)
}

function Invoke-P027Gate {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Root,
        [int]$MaxFileSizeKB = 256,
        [int]$MaxFiles      = 200
    )

    $scanner = Join-Path $Root 'tests\Invoke-SINPatternScanner.ps1'
    $findings = [System.Collections.ArrayList]::new()
    if (-not (Test-Path -LiteralPath $scanner)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'P027'
            Severity = 'ERROR'
            File     = $scanner
            Line     = 0
            Message  = 'P027 scanner not found'
        })
        return @($findings)
    }

    # Performance guard: filter oversized files and cap total count.
    $maxBytes = $MaxFileSizeKB * 1KB
    $eligible = @($Files | Where-Object { $_.Length -le $maxBytes })
    $skippedSize = @($Files).Count - @($eligible).Count
    if (@($eligible).Count -gt $MaxFiles) {
        $skippedCap = @($eligible).Count - $MaxFiles
        $eligible = @($eligible | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxFiles)
        if (-not $Quiet) { Write-Gate ("  [INFO] P027 gate capped: scanning {0} files (skipped {1} over cap, {2} oversize)" -f $MaxFiles, $skippedCap, $skippedSize) 'Warn' }
    } elseif ($skippedSize -gt 0 -and -not $Quiet) {
        Write-Gate ("  [INFO] P027 gate skipped {0} oversize file(s) (>{1}KB)" -f $skippedSize, $MaxFileSizeKB) 'Warn'
    }
    if (@($eligible).Count -eq 0) { return @($findings) }

    $scanOutputJson = Join-Path (Join-Path $Root 'temp') ('precommit-p027-{0}.json' -f (Get-Date -Format 'yyMMddHHmmssfff'))
    $scanResult = & $scanner -WorkspacePath $Root -IncludeFiles @($eligible.FullName) -Quiet -OutputJson $scanOutputJson
    if ($null -eq $scanResult) {
        return @($findings)
    }

    foreach ($hit in @($scanResult.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*27(?:\D|$)|NULL-ARRAY-INDEX|(?:^|-)P027(?:\D|$)' })) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'P027'
            Severity = 'ERROR'
            File     = (Join-Path $Root $hit.file)
            Line     = $hit.line
            Pattern  = $hit.sinId
            Message  = "$($hit.sinId): $($hit.content)"
        })
    }
    return @($findings)
}

function Invoke-EncodingGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    foreach ($f in $Files) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -lt 3 -or $bytes[0] -ne $bom[0] -or $bytes[1] -ne $bom[1] -or $bytes[2] -ne $bom[2]) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'Encoding'
                    Severity = 'WARN'
                    File     = $f.FullName
                    Line     = 1
                    Message  = 'P006: Missing UTF-8 BOM'
                })
            }
        } catch {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'Encoding'
                Severity = 'WARN'
                File     = $f.FullName
                Line     = 0
                Message  = "P006: Could not read file: $($_.Exception.Message)"
            })
        }
    }
    return @($findings)
}

function Invoke-VersionTagGate {
    param([System.IO.FileInfo[]]$Files)
    $findings = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) {
        try {
            $head = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -TotalCount 5 -ErrorAction SilentlyContinue
            $hasTag = $head | Where-Object { $_ -match '#\s*VersionTag:\s*\S+' }
            if (-not $hasTag) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'VersionTag'
                    Severity = 'WARN'
                    File     = $f.FullName
                    Line     = 1
                    Message  = 'P007: No VersionTag comment in first 5 lines'
                })
            }
        } catch { <# Intentional: unreadable files are already handled by other gates. #> }
    }
    return @($findings)
}

function Invoke-PipelineControlGate {
    param([string]$Root)

    $findings = [System.Collections.ArrayList]::new()
    $scriptPath = Join-Path $Root 'scripts\Invoke-PipelineIntegrityCheck.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineControls'
            Severity = 'ERROR'
            File     = $scriptPath
            Line     = 0
            Message  = 'Pipeline integrity script not found'
        })
        return @($findings)
    }

    $reportPath = Join-Path (Join-Path $Root 'temp') ('precommit-pipeline-controls-{0}.json' -f (Get-Date -Format 'yyMMddHHmmssfff'))
    try {
        & $scriptPath -WorkspacePath $Root -WriteReport -ReportPath $reportPath -FailOnControlViolation
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineControls'
            Severity = 'ERROR'
            File     = $scriptPath
            Line     = 0
            Message  = "Pipeline control invocation failed: $($_.Exception.Message)"
        })
    }

    if (-not (Test-Path -LiteralPath $reportPath)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineControls'
            Severity = 'ERROR'
            File     = $reportPath
            Line     = 0
            Message  = 'Pipeline control report missing'
        })
        return @($findings)
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not $report.controls.isHealthy) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'PipelineControls'
                Severity = 'ERROR'
                File     = $reportPath
                Line     = 0
                Message  = 'Pipeline integrity report indicates unhealthy control layer'
            })
        }

        if (-not $report.overallHealthy -and -not $Quiet) {
            Write-Gate '  [INFO] Pipeline baseline is unhealthy (artifact drift/stale backlog), but control layer check is isolated in Gate 6.' 'Warn'
        }

        if (-not $report.controls.cryptographicEvidence.invocationHash) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'PipelineControls'
                Severity = 'ERROR'
                File     = $reportPath
                Line     = 0
                Message  = 'Cryptographic invocation hash missing from controls report'
            })
        }

        foreach ($controlIssue in @($report.controls.payloadIssues)) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'PipelineControls'
                Severity = 'ERROR'
                File     = [string]$controlIssue.path
                Line     = 0
                Message  = "Payload issue ($($controlIssue.kind)): $($controlIssue.detail)"
            })
        }
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineControls'
            Severity = 'ERROR'
            File     = $reportPath
            Line     = 0
            Message  = "Could not parse pipeline control report: $($_.Exception.Message)"
        })
    }

    return @($findings)
}

$timestamp = (Get-Date).ToUniversalTime().ToString('o')
if (-not $OutputJson) {
    $OutputJson = Join-Path $WorkspacePath ("temp\precommit-{0}.json" -f (Get-Date -Format 'yyMMddHHmmss'))
}
if ($OutputJson -eq $PSCommandPath) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') ("precommit-{0}.json" -f (Get-Date -Format 'yyMMddHHmmss'))
}

Write-Gate '' 'Info'
Write-Gate '============================================================' 'Head'
Write-Gate '  PRE-COMMIT VALIDATION' 'Head'
Write-Gate '============================================================' 'Head'
Write-Gate "  Workspace : $WorkspacePath" 'Info'
Write-Gate "  Timestamp : $timestamp" 'Info'

$files = @(Get-TargetFiles -Root $WorkspacePath -Specific $StagedFiles)
Write-Gate "  Files     : $(@($files).Count)" 'Info'
Write-Gate '------------------------------------------------------------' 'Head'

$allFindings = [System.Collections.ArrayList]::new()

Write-Gate '[Gate 1] PowerShell parse check...' 'Info'
$parseHits = @(Invoke-ParseGate -Files $files)
$parseHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($parseHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $parseHits | ForEach-Object { Write-Gate "  FAIL $($_.File):$($_.Line) - $($_.Message)" 'Fail' } }

Write-Gate '[Gate 2] Critical SIN patterns (P001/P009/P010)...' 'Info'
$sinHits = @(Invoke-CriticalSINGate -Files $files)
$sinHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($sinHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $sinHits | ForEach-Object { Write-Gate "  FAIL $($_.File):$($_.Line) - $($_.Message)" 'Fail' } }

Write-Gate '[Gate 3] P027 null-array-index scan...' 'Info'
$p027Hits = @(Invoke-P027Gate -Files $files -Root $WorkspacePath -MaxFileSizeKB $MaxP027FileSizeKB -MaxFiles $MaxP027Files)
$p027Hits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($p027Hits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $p027Hits | ForEach-Object { Write-Gate "  FAIL $($_.File):$($_.Line) - $($_.Message)" 'Fail' } }

Write-Gate '[Gate 4] UTF-8 BOM encoding check (P006)...' 'Info'
$encHits = @(Invoke-EncodingGate -Files $files)
$encHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($encHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $encHits | ForEach-Object { Write-Gate "  WARN $($_.File) - $($_.Message)" 'Warn' } }

Write-Gate '[Gate 5] VersionTag alignment (P007)...' 'Info'
$vtHits = @(Invoke-VersionTagGate -Files $files)
$vtHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($vtHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $vtHits | ForEach-Object { Write-Gate "  WARN $($_.File) - $($_.Message)" 'Warn' } }

if (-not $SkipPipelineControlGate) {
    Write-Gate '[Gate 6] Pipeline controls (recursive discovery, MIME, sanitization, SHA256)...' 'Info'
    $pipelineControlHits = @(Invoke-PipelineControlGate -Root $WorkspacePath)
    $pipelineControlHits | ForEach-Object { [void]$allFindings.Add($_) }
    if (@($pipelineControlHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
    else { $pipelineControlHits | ForEach-Object { Write-Gate "  FAIL $($_.File) - $($_.Message)" 'Fail' } }
}

$errorCount = @($allFindings | Where-Object { $_.Severity -eq 'ERROR' }).Count
$warnCount = @($allFindings | Where-Object { $_.Severity -eq 'WARN' }).Count
$blockingCount = $errorCount + $(if ($FailOnWarning) { $warnCount } else { 0 })

Write-Gate '============================================================' 'Head'
Write-Gate "  Errors : $errorCount  |  Warnings : $warnCount" $(if ($errorCount -gt 0) { 'Fail' } else { 'Pass' })

$report = [ordered]@{
    generatedAt   = $timestamp
    source        = 'Invoke-PreCommitValidation.ps1'
    workspace     = $WorkspacePath
    filesChecked  = @($files).Count
    errorCount    = $errorCount
    warnCount     = $warnCount
    passed        = ($blockingCount -eq 0)
    failOnWarning = $FailOnWarning.IsPresent
    findings      = @($allFindings)
}

try {
    $outDir = Split-Path $OutputJson -Parent
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
    Write-Gate "  Report  : $OutputJson" 'Info'
} catch {
    Write-Gate "  [WARN] Could not write report: $($_.Exception.Message)" 'Warn'
}

if ($blockingCount -gt 0) {
    Write-Gate '  STATUS  : FAILED - commit blocked' 'Fail'
    exit 1
}

Write-Gate '  STATUS  : PASSED - commit allowed' 'Pass'
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

