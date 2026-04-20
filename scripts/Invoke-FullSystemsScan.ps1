# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-FullSystemsScan -- Multithreaded/sequential workspace integrity orchestrator.
.DESCRIPTION
    Runs up to 5 read-only scans in parallel Start-Jobs and 3 dependency-producing scans
    sequentially. Writes a compact summary JSON to ~REPORTS/FullSystemsScan/.
    Delta mode: if the new summary matches the previous hash, the file is not written (no
    redundant disk growth). Rotates summaries > MaxSummaries to a dated archive zip.
    Space-saving: each scan contributes only a small summary block, not full raw dumps.
.PARAMETER WorkspacePath   Workspace root.  Defaults to $PSScriptRoot parent.
.PARAMETER DeltaMode       Skip writing summary if content hash matches previous.
.PARAMETER MaxSummaries    Summaries to retain before rotating older ones to archive zip.
.PARAMETER NoParallel      Run all scans sequentially (safety / low-memory environments).
.PARAMETER CreatePipeItems If set, add a pipeline item for each scan finding > 0 issues.
.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Script
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath  = (Split-Path -Parent $PSScriptRoot),
    [switch]$DeltaMode,
    [int]   $MaxSummaries   = 7,
    [switch]$NoParallel,
    [switch]$CreatePipeItems
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ─── IMPORTS ─────────────────────────────────────────────────────────────
$moduleBase = Join-Path $WorkspacePath 'modules'
$logModPath = Join-Path $moduleBase 'CronAiAthon-EventLog.psm1'
if (Test-Path $logModPath) {
    try { Import-Module $logModPath -Force -ErrorAction Stop } catch { <# Intentional: non-fatal #> }
}
$pipeModPath = Join-Path $moduleBase 'CronAiAthon-Pipeline.psm1'
if (Test-Path $pipeModPath) {
    try { Import-Module $pipeModPath -Force -ErrorAction Stop } catch { <# Intentional: non-fatal #> }
}

function Write-ScanLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Severity = 'Informational', [string]$Source = 'FullSystemsScan')
    if (Get-Command Write-CronLog -ErrorAction SilentlyContinue) {
        Write-CronLog -Message $Msg -Severity $Severity -Source $Source
    } else {
        Write-Verbose "[$Severity] $Msg"
    }
}
#endregion

#region ─── OUTPUT SETUP ────────────────────────────────────────────────────────
$outDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'FullSystemsScan'
if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
$archDir = Join-Path $outDir 'archive'

$runId   = Get-Date -Format 'yyyyMMdd-HHmmss'
$sumFile = Join-Path $outDir "scan-$runId.json"
Write-ScanLog "FullSystemsScan started: $runId"
#endregion

#region ─── HELPER: run a script, return PSObject { ScriptName, Issues, Summary, ErrorMsg } ─
function Invoke-ScanScript {
    param([string]$ScriptPath, [string]$Name, [hashtable]$ExtraArgs = @{})
    $result = [PSCustomObject]@{ Name = $Name; Issues = 0; Summary = 'not run'; ErrorMsg = ''; Elapsed = 0 }
    if (-not (Test-Path $ScriptPath)) {
        $result.Summary  = 'script not found'
        $result.ErrorMsg = $ScriptPath
        return $result
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $ScriptPath -WorkspacePath $WorkspacePath @ExtraArgs 2>&1
        # Attempt to extract meaningful count from any PSCustomObject output
        if ($out -is [System.Collections.IEnumerable] -and -not ($out -is [string])) {
            $arr = @($out)
            $result.Issues  = $arr.Count
            $result.Summary = "returned $($arr.Count) item(s)"
        } elseif ($out -and $out.PSObject.Properties.Name -contains 'TotalFindings') {
            $result.Issues  = [int]($out.TotalFindings)
            $result.Summary = "TotalFindings=$($out.TotalFindings)"
        } else {
            $result.Summary = [string]$out | Select-Object -First 1
        }
    } catch {
        $result.ErrorMsg = $_.Exception.Message
        $result.Summary  = "ERROR: $($_.Exception.Message)"
    }
    $sw.Stop()
    $result.Elapsed = $sw.Elapsed.TotalSeconds
    return $result
}
#endregion

#region ─── PARALLEL SCANS (read-only, no shared state writes) ──────────────────
$parallelScripts = @(
    @{ Name = 'SINPatternScanner';       Path = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SINPatternScanner.ps1' }
    @{ Name = 'SemiSinPenanceScanner';   Path = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SemiSinPenanceScanner.ps1' }
    @{ Name = 'ScriptDependencyMatrix';  Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-DependencyMatrix.ps1' }
    @{ Name = 'OrphanAudit';             Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-OrphanAudit.ps1' }
    @{ Name = 'ReferenceIntegrityCheck'; Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Test-ReferenceIntegrity.ps1' }
)

$parallelResults = @{}
if ($NoParallel) {
    Write-ScanLog "Running parallel scans sequentially (NoParallel switch)"
    foreach ($spec in $parallelScripts) {
        $parallelResults[$spec.Name] = Invoke-ScanScript -ScriptPath $spec.Path -Name $spec.Name
    }
} else {
    Write-ScanLog "Launching $(@($parallelScripts).Count) parallel scan jobs..."
    $jobs = [System.Collections.ArrayList]::new()
    foreach ($spec in $parallelScripts) {
        $scriptPath = $spec.Path
        $name       = $spec.Name
        $wsPath     = $WorkspacePath
        if (-not (Test-Path $scriptPath)) {
            $parallelResults[$name] = [PSCustomObject]@{
                Name = $name; Issues = 0; Summary = 'script not found'; ErrorMsg = $scriptPath; Elapsed = 0
            }
            continue
        }
        $job = Start-Job -ScriptBlock {
            param($sp, $wp, $nm)
            $r = [PSCustomObject]@{ Name = $nm; Issues = 0; Summary = 'not run'; ErrorMsg = ''; Elapsed = 0 }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $out = & $sp -WorkspacePath $wp 2>&1
                if ($out -is [System.Collections.IEnumerable] -and -not ($out -is [string])) {
                    $arr = @($out); $r.Issues = $arr.Count; $r.Summary = "returned $($arr.Count) item(s)"
                } elseif ($out -and ($out | Get-Member -Name 'TotalFindings' -ErrorAction SilentlyContinue)) {
                    $r.Issues = [int]($out.TotalFindings); $r.Summary = "TotalFindings=$($out.TotalFindings)"
                } else { $r.Summary = [string]$out }
            } catch { $r.ErrorMsg = $_.Exception.Message; $r.Summary = "ERROR: $($_.Exception.Message)" }
            $sw.Stop(); $r.Elapsed = $sw.Elapsed.TotalSeconds
            return $r
        } -ArgumentList $scriptPath, $wsPath, $name
        [void]$jobs.Add(@{ Job = $job; Name = $name })
    }

    Write-ScanLog "Waiting for $(@($jobs).Count) parallel jobs..."
    if (@($jobs).Count -gt 0) {
        Wait-Job -Job @($jobs | ForEach-Object { $_.Job }) -Timeout 300 | Out-Null
        foreach ($jb in $jobs) {
            try {
                $r = Receive-Job -Job $jb.Job -ErrorAction SilentlyContinue
                $parallelResults[$jb.Name] = $r
            } catch { $parallelResults[$jb.Name] = [PSCustomObject]@{ Name=$jb.Name; Issues=0; Summary='job receive failed'; ErrorMsg=$_.Exception.Message; Elapsed=0 } }
            Remove-Job -Job $jb.Job -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region ─── SEQUENTIAL SCANS (write-producing / dependency-ordered) ─────────────
Write-ScanLog "Running sequential dependency scans..."
$seqResults  = [System.Collections.ArrayList]::new()
$seqScripts  = @(
    @{ Name = 'PSEnvironmentScanner';  Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Test-PSEnvironment.ps1' }
    @{ Name = 'ConfigCoverageAudit';   Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ConfigCoverageAudit.ps1' }
    @{ Name = 'AgenticManifestRebuild'; Path = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-AgenticManifest.ps1' }
)
foreach ($spec in $seqScripts) {
    [void]$seqResults.Add((Invoke-ScanScript -ScriptPath $spec.Path -Name $spec.Name))
}
#endregion

#region ─── PIPELINE STEERER (dry-run, sequential) ───────────────────────────────
$steerResult = $null
$steerPath   = Join-Path (Join-Path (Join-Path $WorkspacePath 'agents') 'PipelineSteering') 'core\PipelineSteering.psm1'
if (-not (Test-Path $steerPath)) {
    $steerPath = Join-Path (Join-Path (Join-Path $WorkspacePath 'sovereign-kernel') 'agents') 'PipelineSteering\PipelineSteering.psm1'
}
if (Test-Path $steerPath) {
    try {
        Import-Module $steerPath -Force -ErrorAction Stop
        if (Get-Command Invoke-PipelineSteer -ErrorAction SilentlyContinue) {
            $steerOutRaw = Invoke-PipelineSteer -WorkspacePath $WorkspacePath -DryRun -ErrorAction SilentlyContinue
            $steerResult = [PSCustomObject]@{ Name = 'PipelineSteering'; Issues = 0; Summary = "DryRun OK"; Elapsed = 0 }
            if ($steerOutRaw -and $steerOutRaw.Recommendations) {
                $steerResult.Issues  = @($steerOutRaw.Recommendations).Count
                $steerResult.Summary = "DryRun: $($steerResult.Issues) recommendation(s)"
            }
        }
    } catch {
        $steerResult = [PSCustomObject]@{ Name = 'PipelineSteering'; Issues = 0; Summary = "DryRun failed: $($_.Exception.Message)"; Elapsed = 0 }
    }
} else {
    $steerResult = [PSCustomObject]@{ Name = 'PipelineSteering'; Issues = 0; Summary = 'module not found'; Elapsed = 0 }
}
#endregion

#region ─── ASSEMBLE SUMMARY ────────────────────────────────────────────────────
$allResults = [System.Collections.ArrayList]::new()
foreach ($k in $parallelResults.Keys) { [void]$allResults.Add($parallelResults[$k]) }
foreach ($r in $seqResults)           { [void]$allResults.Add($r) }
if ($steerResult)                     { [void]$allResults.Add($steerResult) }

$totalIssues = 0
foreach ($r in $allResults) {
    if ($r -and $r.PSObject.Properties.Name -contains 'Issues') { $totalIssues += [int]$r.Issues }
}

$summary = [ordered]@{
    schema        = 'FullSystemsScan/1.0'
    runId         = $runId
    timestamp     = [datetime]::UtcNow.ToString('o')
    workspacePath = $WorkspacePath
    totalIssues   = $totalIssues
    scanCount     = @($allResults).Count
    scans         = @($allResults | ForEach-Object {
        if ($_) { [ordered]@{ name = $_.Name; issues = $_.Issues; summary = $_.Summary; elapsed = [math]::Round($_.Elapsed,2) } }
    })
}
#endregion

#region ─── DELTA CHECK ──────────────────────────────────────────────────────────
$summaryJson = $summary | ConvertTo-Json -Depth 6 -Compress
$newHash     = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($summaryJson))
) -replace '-', ''

if ($DeltaMode) {
    $prevFiles = @(Get-ChildItem -Path $outDir -Filter 'scan-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if (@($prevFiles).Count -gt 0) {
        try {
            $prevJson = Get-Content -Path $prevFiles[0].FullName -Raw -ErrorAction SilentlyContinue
            $prevHash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($prevJson))
            ) -replace '-', ''
            if ($newHash -eq $prevHash) {
                Write-ScanLog "DeltaMode: summary unchanged (hash $($newHash.Substring(0,8))...) -- skipping write"
                return $summary
            }
        } catch { <# Intentional: non-fatal, proceed to write #> }
    }
}
#endregion

#region ─── WRITE SUMMARY ────────────────────────────────────────────────────────
$summaryJson | Set-Content -Path $sumFile -Encoding UTF8
Write-ScanLog "Summary written: $sumFile ($totalIssues total issues)"
#endregion

#region ─── ROTATION (compress overflow summaries) ───────────────────────────────
try {
    $existing = @(Get-ChildItem -Path $outDir -Filter 'scan-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (@($existing).Count -gt $MaxSummaries) {
        $toArchive = $existing[$MaxSummaries..($existing.Count - 1)]
        if (-not (Test-Path $archDir)) { New-Item -Path $archDir -ItemType Directory -Force | Out-Null }
        $monthTag  = Get-Date -Format 'yyyyMM'
        $zipPath   = Join-Path $archDir "$monthTag.zip"
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        if (-not (Test-Path $zipPath)) {
            [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create).Dispose()
        }
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            foreach ($f in $toArchive) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $f.Name) | Out-Null
                Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            }
        } finally { $zip.Dispose() }
        Write-ScanLog "Rotated $(@($toArchive).Count) old summaries to $zipPath"
    }
} catch {
    Write-Warning "Rotation error: $($_.Exception.Message)"
}
#endregion

#region ─── PIPELINE ITEMS ───────────────────────────────────────────────────────
if ($CreatePipeItems -and (Get-Command Add-PipelineItem -ErrorAction SilentlyContinue)) {
    foreach ($r in $allResults) {
        if ($r -and [int]$r.Issues -gt 0) {
            try {
                $title  = "ScanFindings-$($r.Name): $($r.Issues) issue(s) found - $runId"
                $detail = $r.Summary
                Add-PipelineItem -Title $title -Detail $detail -Priority 'MEDIUM' -WorkspacePath $WorkspacePath -ErrorAction SilentlyContinue
            } catch { <# Intentional: non-fatal pipeline logging #> }
        }
    }
}
#endregion

return [PSCustomObject]$summary
