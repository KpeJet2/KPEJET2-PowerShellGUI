# VersionTag: 2606.B5.V51.4
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS  CI pre-commit gate: parse check + critical SIN scan + P027 null-index scan + encoding + version tag alignment + todo artifact guard.
.DESCRIPTION
    Lightweight gate designed to run before every commit (or as CronProcessor pre-step).
    Catches the most common, high-impact issues without the full SIN scanner runtime:

      Gate 1 - PowerShell parse errors (all .ps1/.psm1 files in scope)
      Gate 2 - Critical SIN patterns (P001/P009/P010): hardcoded creds, IEX, path injection
      Gate 3 - P027 null-array-index findings from the SIN scanner
      Gate 4 - Encoding violations: UTF-8 BOM required for .ps1/.psm1 (P006)
    Gate 5 - VersionTag present and non-empty in every staged .ps1/.psm1 (P007)
    Gate 6 - Todo artifact guard: no merge markers in todo/_master-aggregated.json and object-root JSON for active todo files
    Gate 7 - Pipeline control report verification

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
    [switch]  $SkipPipelineMetricGate,
    [switch]  $PipelineMetricIncludeGuiCoverage,
    [switch]  $AutoCorrectFailures,
    [ValidateSet('FullWorkspace','KnowSafeRemidiations','KnowSafeRemediations','FastFix_Auto-Correct','SpecificFocus')]
    [string]  $AutoCorrectScope = 'KnowSafeRemidiations',
    [string[]]$AutoCorrectFocusTargets = @(),
    [int]     $AutoCorrectRecentDays = 14,
    # Gate 3 (P027) performance guards. P027 scanner is O(n) per file but its AST walk
    # is heavy on very large files; skip oversize files and cap the total count to keep
    # pre-commit under ~30s.
    [int]     $MaxP027FileSizeKB = 256,
    [int]     $MaxP027Files       = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path

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

function Get-WorkspaceRelativePath {
    param([string]$Root, [string]$Path)

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if ($pathFull -eq $rootFull) { return '.' }
    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($rootFull.Length).TrimStart('\', '/')
    }
    return $pathFull
}

function Get-AdditionalScanCandidateInventory {
    param([string]$Root)

    $defaultScanRoots = @('modules', 'scripts', 'tests')
    $excludeDirNames = @('.git', '.venv', 'node_modules', 'temp', 'logs', 'reports', 'Report', 'checkpoints', '.history', '~DOWNLOADS', '~REPORTS')

    $scannedRootPaths = @()
    foreach ($name in $defaultScanRoots) {
        $candidate = Join-Path $Root $name
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $scannedRootPaths += [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $candidateFiles = @()
    try {
        $candidateFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.ps1', '.psm1' -and
                $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                $_.FullName -notmatch '[\\/]\.venv[\\/]' -and
                $_.FullName -notmatch '[\\/]node_modules[\\/]' -and
                $_.FullName -notmatch '[\\/]temp[\\/]' -and
                $_.FullName -notmatch '[\\/]logs[\\/]' -and
                $_.FullName -notmatch '[\\/]reports?[\\/]' -and
                $_.FullName -notmatch '[\\/]checkpoints[\\/]' -and
                $_.FullName -notmatch '[\\/]\.history[\\/]' -and
                $_.FullName -notmatch '[\\/]~DOWNLOADS[\\/]' -and
                $_.FullName -notmatch '[\\/]~REPORTS[\\/]'
            })
    } catch {
        $candidateFiles = @()
    }

    $notScannedFolders = [System.Collections.ArrayList]::new()
    $notScannedScripts = [System.Collections.ArrayList]::new()
    $notScannedModules = [System.Collections.ArrayList]::new()

    foreach ($file in @($candidateFiles)) {
        $fullName = [System.IO.Path]::GetFullPath($file.FullName)
        $relativePath = Get-WorkspaceRelativePath -Root $Root -Path $fullName
        $isInDefaultScope = $false
        foreach ($scanRoot in $scannedRootPaths) {
            if ($fullName.StartsWith($scanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isInDefaultScope = $true
                break
            }
        }
        if ($isInDefaultScope) { continue }

        $segments = @($relativePath -split '[\\/]')
        $skipByFolder = $false
        foreach ($segment in $segments) {
            if ($excludeDirNames -contains $segment) {
                $skipByFolder = $true
                break
            }
        }
        if ($skipByFolder) { continue }

        $parentDir = Split-Path -Parent $fullName
        $parentRelative = Get-WorkspaceRelativePath -Root $Root -Path $parentDir
        if ($parentRelative -and $parentRelative -ne '.' -and -not ($notScannedFolders -contains $parentRelative)) {
            [void]$notScannedFolders.Add($parentRelative)
        }

        if ($file.Extension -eq '.psm1') {
            [void]$notScannedModules.Add($relativePath)
        } else {
            [void]$notScannedScripts.Add($relativePath)
        }
    }

    return [ordered]@{
        scannedRoots       = @($defaultScanRoots)
        notScannedFolders  = @($notScannedFolders | Sort-Object)
        notScannedScripts  = @($notScannedScripts | Sort-Object)
        notScannedModules  = @($notScannedModules | Sort-Object)
    }
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
        & $scriptPath -WorkspacePath $Root -WriteReport -ReportPath $reportPath -FailOnControlViolation -EnableContentPolicyChecks
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

        $controlIssues = @()
        if ($report.controls.PSObject.Properties.Name -contains 'payloadIssues') {
            $controlIssues += @($report.controls.payloadIssues)
        }
        if ($report.controls.PSObject.Properties.Name -contains 'structuralIssues') {
            $controlIssues += @($report.controls.structuralIssues)
        }

        foreach ($controlIssue in @($controlIssues)) {
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

function Invoke-PipelineMetricGate {
    param(
        [string]$Root,
        [switch]$IncludeGuiCoverage
    )

    $findings = [System.Collections.ArrayList]::new()
    $harnessPath = Join-Path $Root 'tests\Invoke-PipelineMetricIncrementHarness.ps1'
    if (-not (Test-Path -LiteralPath $harnessPath)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineMetric'
            Severity = 'ERROR'
            File     = $harnessPath
            Line     = 0
            Message  = 'Pipeline metric increment harness not found'
        })
        return @($findings)
    }

    $reportPath = Join-Path (Join-Path $Root 'temp') ('precommit-pipeline-metric-{0}.json' -f (Get-Date -Format 'yyMMddHHmmssfff'))
    $psArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$harnessPath`"",
        '-WorkspacePath', "`"$Root`"",
        '-OutputPath', "`"$reportPath`""
    )
    if (-not $IncludeGuiCoverage) {
        $psArgs += '-SkipGuiCoverage'
    }

    try {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $proc = Start-Process -FilePath $hostExe -ArgumentList $psArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'PipelineMetric'
                Severity = 'ERROR'
                File     = $harnessPath
                Line     = 0
                Message  = "Metric harness failed with exit code $($proc.ExitCode)"
            })
        }
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineMetric'
            Severity = 'ERROR'
            File     = $harnessPath
            Line     = 0
            Message  = "Metric harness invocation failed: $($_.Exception.Message)"
        })
        return @($findings)
    }

    if (-not (Test-Path -LiteralPath $reportPath)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineMetric'
            Severity = 'ERROR'
            File     = $reportPath
            Line     = 0
            Message  = 'Metric harness report missing'
        })
        return @($findings)
    }

    try {
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not $report.pass) {
            foreach ($item in @($report.oneItemResults | Where-Object { -not $_.passed })) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'PipelineMetric'
                    Severity = 'ERROR'
                    File     = $reportPath
                    Line     = 0
                    Message  = "Queue '$($item.queueName)' delta validation failed"
                })
            }
            foreach ($gui in @($report.guiCoverage | Where-Object { -not $_.passed })) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'PipelineMetric'
                    Severity = 'ERROR'
                    File     = $reportPath
                    Line     = 0
                    Message  = "GUI coverage failed: $($gui.name)"
                })
            }
            if (@($findings).Count -eq 0) {
                [void]$findings.Add([PSCustomObject]@{
                    Gate     = 'PipelineMetric'
                    Severity = 'ERROR'
                    File     = $reportPath
                    Line     = 0
                    Message  = 'Metric harness reported failure'
                })
            }
        }
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'PipelineMetric'
            Severity = 'ERROR'
            File     = $reportPath
            Line     = 0
            Message  = "Could not parse metric harness report: $($_.Exception.Message)"
        })
    }

    return @($findings)
}

function Invoke-TodoArtifactGuardGate {
    param([string]$Root)

    $findings = [System.Collections.ArrayList]::new()
    $todoDir = Join-Path $Root 'todo'
    $masterPath = Join-Path $todoDir '_master-aggregated.json'

    if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'TodoArtifactGuard'
            Severity = 'ERROR'
            File     = $masterPath
            Line     = 0
            Message  = 'Missing required artifact: todo/_master-aggregated.json'
        })
        return @($findings)
    }

    try {
        $masterRaw = Get-Content -LiteralPath $masterPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($masterRaw -match '(?m)^<<<<<<<\s' -or $masterRaw -match '(?m)^=======\s*$' -or $masterRaw -match '(?m)^>>>>>>>\s') {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'TodoArtifactGuard'
                Severity = 'ERROR'
                File     = $masterPath
                Line     = 0
                Message  = 'Merge conflict markers detected in todo/_master-aggregated.json'
            })
        }
        $null = $masterRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'TodoArtifactGuard'
            Severity = 'ERROR'
            File     = $masterPath
            Line     = 0
            Message  = "Invalid master aggregate JSON: $($_.Exception.Message)"
        })
    }

    if (-not (Test-Path -LiteralPath $todoDir -PathType Container)) {
        return @($findings)
    }

    $excludeNames = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')
    $activeFiles = @(
        Get-ChildItem -LiteralPath $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" } |
        Sort-Object Name
    )

    foreach ($file in @($activeFiles)) {
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [System.Array]) {
                # Only enforce object-root for item-like files; skip helper datasets.
                if ($file.Name -match '^(Bug|Bugs2FIX|Feature|ToDo|todo-|NOID-)') {
                    [void]$findings.Add([PSCustomObject]@{
                        Gate     = 'TodoArtifactGuard'
                        Severity = 'ERROR'
                        File     = $file.FullName
                        Line     = 1
                        Message  = 'Active todo item must be object-root JSON (array root is not allowed)'
                    })
                }
            }
        } catch {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'TodoArtifactGuard'
                Severity = 'ERROR'
                File     = $file.FullName
                Line     = 0
                Message  = "Invalid active todo JSON: $($_.Exception.Message)"
            })
        }
    }

    return @($findings)
}

function Invoke-LogDriftGate {
    param([string]$Root)

    $findings = [System.Collections.ArrayList]::new()

    $rootLogs = @()
    try {
        $rootLogs = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.log' -ErrorAction SilentlyContinue)
    } catch {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'LogDrift'
            Severity = 'ERROR'
            File     = $Root
            Line     = 0
            Message  = "Failed to enumerate root log files: $($_.Exception.Message)"
        })
        return @($findings)
    }

    foreach ($logFile in @($rootLogs)) {
        [void]$findings.Add([PSCustomObject]@{
            Gate     = 'LogDrift'
            Severity = 'ERROR'
            File     = $logFile.FullName
            Line     = 0
            Message  = 'Root-level log drift detected; move log under logs\\<subfolder>'
        })
    }

    $logsDir = Join-Path $Root 'logs'
    if (Test-Path -LiteralPath $logsDir -PathType Container) {
        $topLevelLogs = @(Get-ChildItem -LiteralPath $logsDir -File -Filter '*.log' -ErrorAction SilentlyContinue)
        foreach ($logFile in @($topLevelLogs)) {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'LogDrift'
                Severity = 'ERROR'
                File     = $logFile.FullName
                Line     = 0
                Message  = 'Top-level logs\\*.log drift detected; move file under logs\\<subfolder>'
            })
        }
    }

    $viewerPath = Join-Path $Root 'XHTML-ChangelogViewer.xhtml'
    if (Test-Path -LiteralPath $viewerPath -PathType Leaf) {
        try {
            $viewerContent = Get-Content -LiteralPath $viewerPath -Raw -Encoding UTF8 -ErrorAction Stop
            $regex = [regex]"path:\s*'(?<path>logs\\[^']+\.log)'"
            foreach ($match in $regex.Matches($viewerContent)) {
                $relPath = $match.Groups['path'].Value
                $resolvedPath = Join-Path $Root ($relPath -replace '/', '\\')
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    [void]$findings.Add([PSCustomObject]@{
                        Gate     = 'LogDrift'
                        Severity = 'ERROR'
                        File     = $viewerPath
                        Line     = 0
                        Message  = "Viewer log reference does not resolve after cleanup: $relPath"
                    })
                }
            }
        } catch {
            [void]$findings.Add([PSCustomObject]@{
                Gate     = 'LogDrift'
                Severity = 'ERROR'
                File     = $viewerPath
                Line     = 0
                Message  = "Could not validate viewer log references: $($_.Exception.Message)"
            })
        }
    }

    return @($findings)
}

function Invoke-PreCommitGateRecoveryLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter(Mandatory)] [scriptblock]$ShouldRetry,
        [int]$MaxAttempts = 3,
        [string]$Label = 'gate recovery'
    )

    $attemptResults = [System.Collections.ArrayList]::new()
    $lastResult = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $lastResult = & $Action -Attempt $attempt
        [void]$attemptResults.Add([PSCustomObject]@{
            attempt = $attempt
            passed = if ($lastResult.PSObject.Properties['passed']) { [bool]$lastResult.passed } else { $false }
            blockingCount = if ($lastResult.PSObject.Properties['blockingCount']) { [int]$lastResult.blockingCount } else { 0 }
        })

        if (-not (& $ShouldRetry -Attempt $attempt -Result $lastResult)) {
            break
        }
    }

    return [PSCustomObject]@{
        label = $Label
        attempts = @($attemptResults).Count
        passed = if ($lastResult -and $lastResult.PSObject.Properties['passed']) { [bool]$lastResult.passed } else { $false }
        result = $lastResult
        attemptResults = @($attemptResults)
    }
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

Write-Gate '[Gate 6] Todo artifact guard (_master merge markers + object-root active todos)...' 'Info'
$todoArtifactHits = @(Invoke-TodoArtifactGuardGate -Root $WorkspacePath)
$todoArtifactHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($todoArtifactHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $todoArtifactHits | ForEach-Object { Write-Gate "  FAIL $($_.File) - $($_.Message)" 'Fail' } }

if (-not $SkipPipelineControlGate) {
    Write-Gate '[Gate 7] Pipeline controls (recursive discovery, MIME, sanitization, SHA256)...' 'Info'
    $pipelineControlHits = @(Invoke-PipelineControlGate -Root $WorkspacePath)
    $pipelineControlHits | ForEach-Object { [void]$allFindings.Add($_) }
    if (@($pipelineControlHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
    else { $pipelineControlHits | ForEach-Object { Write-Gate "  FAIL $($_.File) - $($_.Message)" 'Fail' } }
}

if (-not $SkipPipelineMetricGate) {
    Write-Gate '[Gate 8] Pipeline one-item metric increment harness...' 'Info'
    $metricHits = @(Invoke-PipelineMetricGate -Root $WorkspacePath -IncludeGuiCoverage:$PipelineMetricIncludeGuiCoverage)
    $metricHits | ForEach-Object { [void]$allFindings.Add($_) }
    if (@($metricHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
    else { $metricHits | ForEach-Object { Write-Gate "  FAIL $($_.File) - $($_.Message)" 'Fail' } }
}

Write-Gate '[Gate 9] Log drift and viewer log-reference guard...' 'Info'
$logDriftHits = @(Invoke-LogDriftGate -Root $WorkspacePath)
$logDriftHits | ForEach-Object { [void]$allFindings.Add($_) }
if (@($logDriftHits).Count -eq 0) { Write-Gate '  Passed' 'Pass' }
else { $logDriftHits | ForEach-Object { Write-Gate "  FAIL $($_.File) - $($_.Message)" 'Fail' } }

$errorCount = @($allFindings | Where-Object { $_.Severity -eq 'ERROR' }).Count
$warnCount = @($allFindings | Where-Object { $_.Severity -eq 'WARN' }).Count
$blockingCount = $errorCount + $(if ($FailOnWarning) { $warnCount } else { 0 })

Write-Gate '============================================================' 'Head'
Write-Gate "  Errors : $errorCount  |  Warnings : $warnCount" $(if ($errorCount -gt 0) { 'Fail' } else { 'Pass' })

$additionalScanCandidates = Get-AdditionalScanCandidateInventory -Root $WorkspacePath

$report = [ordered]@{
    generatedAt   = $timestamp
    source        = 'Invoke-PreCommitValidation.ps1'
    workspace     = $WorkspacePath
    filesChecked  = @($files).Count
    errorCount    = $errorCount
    warnCount     = $warnCount
    passed        = ($blockingCount -eq 0)
    failOnWarning = $FailOnWarning.IsPresent
    autoCorrect   = $null
    autoCorrectScope = $AutoCorrectScope
    findings      = @($allFindings)
    additionalScanCandidates = $additionalScanCandidates
}

try {
    $outDir = Split-Path $OutputJson -Parent
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
    Write-Gate "  Report  : $OutputJson" 'Info'
} catch {
    Write-Gate "  [WARN] Could not write report: $($_.Exception.Message)" 'Warn'
}

if ($AutoCorrectFailures -and $blockingCount -gt 0) {
    $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $childArgsBase = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-WorkspacePath', $WorkspacePath,
        '-OutputJson', $OutputJson,
        '-Quiet'
    )
    if ($FailOnWarning) { $childArgsBase += '-FailOnWarning' }
    if ($SkipPipelineControlGate) { $childArgsBase += '-SkipPipelineControlGate' }
    if ($SkipPipelineMetricGate) { $childArgsBase += '-SkipPipelineMetricGate' }
    if ($PipelineMetricIncludeGuiCoverage) { $childArgsBase += '-PipelineMetricIncludeGuiCoverage' }
    if (@($StagedFiles).Count -gt 0) {
        $childArgsBase += '-StagedFiles'
        $childArgsBase += @($StagedFiles)
    }

    $recoveryLoop = Invoke-PreCommitGateRecoveryLoop -Label 'pre-commit auto-correction' -MaxAttempts 3 -Action {
        param([int]$Attempt)
        $attemptOutputJson = if ($Attempt -eq 1) { $OutputJson } else { Join-Path (Split-Path $OutputJson -Parent) ("precommit-retry-{0}-{1}.json" -f $Attempt, (Get-Date -Format 'yyMMddHHmmssfff')) }

        if ($Attempt -gt 1) {
            Write-Gate "[AutoCorrect] Attempt $Attempt/3 after previous failure..." 'Info'
            $autoCorrectModule = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-AutoCorrectGate.psm1'
            if (Test-Path -LiteralPath $autoCorrectModule) {
                try {
                    Import-Module -LiteralPath $autoCorrectModule -Force -DisableNameChecking -ErrorAction Stop
                    $autoCorrectReport = Invoke-AutoCorrectGate -WorkspacePath $WorkspacePath -FailItems @($allFindings) -MaxAttempts 3 -Scope $AutoCorrectScope -FocusTargets @($AutoCorrectFocusTargets) -RecentDays $AutoCorrectRecentDays
                    Write-Gate ("  AutoCorrect: corrected={0} escalated={1} stopped={2}" -f $autoCorrectReport.corrected, $autoCorrectReport.escalated, $autoCorrectReport.stopped) 'Info'
                } catch {
                    Write-Gate "  [WARN] AutoCorrect failed: $($_.Exception.Message)" 'Warn'
                }
            } else {
                Write-Gate "  [WARN] AutoCorrect module not found: $autoCorrectModule" 'Warn'
            }
        }

        $procArgs = $childArgsBase + @('-AutoCorrectFailures')
        $proc = Start-Process -FilePath $hostExe -ArgumentList $procArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            $childReport = if (Test-Path -LiteralPath $attemptOutputJson) { Get-Content -LiteralPath $attemptOutputJson -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            if ($null -ne $childReport) {
                $report = [ordered]@{
                    passed = [bool]$childReport.passed
                    blockingCount = [int]$childReport.errorCount + $(if ($childReport.failOnWarning) { [int]$childReport.warnCount } else { 0 })
                    errorCount = [int]$childReport.errorCount
                    warnCount = [int]$childReport.warnCount
                    findings = @($childReport.findings)
                    autoCorrect = $childReport.autoCorrect
                }
                return [PSCustomObject]$report
            }
            return [PSCustomObject]@{ passed = $false; blockingCount = 1; errorCount = 1; warnCount = 0; findings = @(); autoCorrect = $null }
        }

        $childReport = Get-Content -LiteralPath $attemptOutputJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $blockingCount = [int]$childReport.errorCount + $(if ($childReport.failOnWarning) { [int]$childReport.warnCount } else { 0 })
        return [PSCustomObject]@{
            passed = [bool]$childReport.passed
            blockingCount = $blockingCount
            errorCount = [int]$childReport.errorCount
            warnCount = [int]$childReport.warnCount
            findings = @($childReport.findings)
            autoCorrect = $childReport.autoCorrect
            report = $childReport
        }
    } -ShouldRetry {
        param([int]$Attempt, [object]$Result)
        return ($Attempt -lt 3 -and -not [bool]$Result.passed -and [int]$Result.blockingCount -gt 0)
    }

    if ($recoveryLoop.passed) {
        $report = $recoveryLoop.result.report
        $blockingCount = [int]$recoveryLoop.result.blockingCount
        if ($report) {
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
        }
    }
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



