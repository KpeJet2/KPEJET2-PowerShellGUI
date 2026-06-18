# VersionTag: 2606.B5.V51.4
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Pipeline churn orchestrator: SIN remedy + AutoIssueFinder + N cron cycles + verify.
.DESCRIPTION
    One-shot orchestrator used by the 25-todo / 35-cycle churn flow. Runs:
      1. SIN remedy engine over sin_registry/candidates -> Bugs2FIX
      2. AutoIssueFinder bug discovery (chronic parse-error allow-list respected by its own internals)
      3. Invoke-CronProcessor.ps1 -BatchSize 25 -Force, repeated up to -MaxCycles
         (stops early when the Bugs2FIX queue stops shrinking for 2 consecutive cycles
          AND the lowercase todo queue stops shrinking too).
      4. Reindex + manifest + bundle rebuild
      5. Encoding compliance + UI event safety scans
      6. Final queue snapshot and JSON summary
.PARAMETER MaxCycles
    Hard cap on cron processor cycles. Default: 35.
.PARAMETER BatchSize
    Items per cron cycle. Default: 25 (matches the requested churn batch).
.PARAMETER LogDir
    Directory for the per-cycle logs. Default: logs/pipeline-churn.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 100)] [int]$MaxCycles = 35,
    [ValidateRange(1, 500)] [int]$BatchSize = 25,
    [switch]$SkipPesterGate,
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$LogDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $WorkspacePath 'logs\pipeline-churn'
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLog    = Join-Path $LogDir "churn-run-$stamp.log"
$summary   = Join-Path $LogDir "churn-summary-$stamp.json"
$todoDir   = Join-Path $WorkspacePath 'todo'
$sinDir    = Join-Path $WorkspacePath 'sin_registry'

function Write-RunLog {
    param([string]$Msg, [string]$Level = 'Info')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-QueueSnapshot {
    [PSCustomObject]@{
        Timestamp     = (Get-Date -Format 'o')
        TodoLower     = @(Get-ChildItem $todoDir -Filter 'todo-*.json'     -File -EA SilentlyContinue).Count
        TodoPA        = @(Get-ChildItem $todoDir -Filter 'TODO-PA-*.json'  -File -EA SilentlyContinue).Count
        TodoUpper     = @(Get-ChildItem $todoDir -Filter 'ToDo-*.json'     -File -EA SilentlyContinue).Count
        Bugs          = @(Get-ChildItem $todoDir -Filter 'Bug-*.json'      -File -EA SilentlyContinue).Count
        Bugs2FIX      = @(Get-ChildItem $todoDir -Filter 'Bugs2FIX-*.json' -File -EA SilentlyContinue).Count
        SinCandidates = @(Get-ChildItem (Join-Path $sinDir 'candidates') -File -EA SilentlyContinue).Count
        SinFixes      = @(Get-ChildItem (Join-Path $sinDir 'fixes')      -File -EA SilentlyContinue).Count
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$ScriptArgs = @{},
        [string]$StepLog
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-RunLog "[$Name] script missing, skipped: $ScriptPath" 'Warning'
        return $false
    }
    if (-not $StepLog) { $StepLog = Join-Path $LogDir "$Name-$stamp.log" }
    Write-RunLog "[$Name] start -> $ScriptPath"
    try {
        if ($null -ne $ScriptArgs -and @($ScriptArgs.Keys).Count -gt 0) {
            & $ScriptPath @ScriptArgs *> $StepLog
        } else {
            & $ScriptPath *> $StepLog
        }
        $rc = if (Test-Path -LiteralPath variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        Write-RunLog "[$Name] exit=$rc log=$StepLog"
        return ($rc -eq 0)
    } catch {
        Write-RunLog "[$Name] exception: $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Invoke-StepIsolated {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$ScriptArgs = @{},
        [string]$StepLog,
        [int]$TimeoutMs = 180000
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-RunLog "[$Name] script missing, skipped: $ScriptPath" 'Warning'
        return $false
    }
    if (-not $StepLog) { $StepLog = Join-Path $LogDir "$Name-$stamp.log" }
    $stepErrLog = Join-Path $LogDir "$Name-$stamp.stderr.log"

    $stepHostExe = $null
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $stepHostExe = 'powershell.exe'
    } elseif (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $stepHostExe = 'pwsh.exe'
    }
    if ([string]::IsNullOrWhiteSpace($stepHostExe)) {
        Write-RunLog "[$Name] no PowerShell host available for isolated step" 'Error'
        return $false
    }

    $stepArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )

    if ($null -ne $ScriptArgs -and @($ScriptArgs.Keys).Count -gt 0) {
        foreach ($argName in $ScriptArgs.Keys) {
            $argValue = $ScriptArgs[$argName]
            if ($argValue -is [switch]) {
                if ($argValue.IsPresent) { $stepArgs += "-$argName" }
                continue
            }
            if ($argValue -is [bool]) {
                if ($argValue) { $stepArgs += "-$argName" }
                continue
            }
            if ($null -eq $argValue) { continue }
            $stepArgs += "-$argName"
            $stepArgs += [string]$argValue
        }
    }

    Write-RunLog "[$Name] start -> $ScriptPath (isolated timeout=${TimeoutMs}ms)"
    $rc = 1
    try {
        $stepProc = Start-Process -FilePath $stepHostExe -ArgumentList $stepArgs -WorkingDirectory $WorkspacePath -PassThru -NoNewWindow -RedirectStandardOutput $StepLog -RedirectStandardError $stepErrLog
        if ($null -eq $stepProc) {
            throw 'Failed to start isolated step process.'
        }

        $finished = $stepProc.WaitForExit($TimeoutMs)
        if (-not $finished) {
            try {
                Stop-Process -Id $stepProc.Id -Force -ErrorAction SilentlyContinue
            } catch {
                Write-RunLog "[$Name] timeout cleanup warning: $($_.Exception.Message)" 'Warning'
            }
            $rc = 124
            Write-RunLog "[$Name] timed out after $TimeoutMs ms" 'Error'
        } else {
            $rc = [int]$stepProc.ExitCode
        }

        if ($rc -ne 0 -and (Test-Path -LiteralPath $stepErrLog)) {
            $stderrTail = @((Get-Content -LiteralPath $stepErrLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6) -join ' || ')
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                Write-RunLog "[$Name] stderr tail: $stderrTail" 'Warning'
            }
        }

        Write-RunLog "[$Name] exit=$rc log=$StepLog"
        return ($rc -eq 0)
    } catch {
        Write-RunLog "[$Name] exception: $($_.Exception.Message)" 'Error'
        return $false
    }
}

Write-RunLog "==== Pipeline churn start ===="
Write-RunLog "MaxCycles=$MaxCycles BatchSize=$BatchSize Workspace=$WorkspacePath"

$snapshots = New-Object System.Collections.Generic.List[object]
$initial = Get-QueueSnapshot
$snapshots.Add([PSCustomObject]@{ Phase='initial'; Cycle=0; Snapshot=$initial }) | Out-Null
Write-RunLog ("Initial queue: " + ($initial | ConvertTo-Json -Compress -Depth 5))

# 1) SIN remedy engine — Convert-SinScanToBugs converts results to Bugs2FIX records
Invoke-Step -Name 'sin-remedy' -ScriptPath (Join-Path $WorkspacePath 'scripts\Convert-SinScanToBugs.ps1') `
    -ScriptArgs @{ WorkspacePath = $WorkspacePath; Apply = $true; MaxItems = $BatchSize } | Out-Null

# 2) AutoIssueFinder (preferred locations, try both)
$aif = Join-Path $WorkspacePath 'tools\AutoIssueFinder.ps1'
if (-not (Test-Path -LiteralPath $aif)) { $aif = Join-Path $WorkspacePath 'scripts\Invoke-AutoIssueFinder.ps1' }
if (Test-Path -LiteralPath $aif) {
    Invoke-Step -Name 'auto-issue-finder' -ScriptPath $aif -ScriptArgs @{ WorkspacePath = $WorkspacePath } | Out-Null
} else {
    Write-RunLog "[auto-issue-finder] not found, skipped" 'Warning'
}

# 3) Cron cycles
$cron = Join-Path $WorkspacePath 'scripts\Invoke-CronProcessor.ps1'
$cronHostExe = $null
if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
    $cronHostExe = 'powershell.exe'
} elseif (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
    $cronHostExe = 'pwsh.exe'
}

$cronTimeoutMs = 360000
$stagnantCycles = 0
$prev = $initial
for ($i = 1; $i -le $MaxCycles; $i++) {
    Write-RunLog "[cycle $i/$MaxCycles] cron start (BatchSize=$BatchSize SkipPesterGate=$SkipPesterGate)"
    $cycleLog = Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.log" -f $i)
    $cycleErrLog = Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.stderr.log" -f $i)
    $rc = 1
    try {
        if ([string]::IsNullOrWhiteSpace($cronHostExe)) {
            throw 'No PowerShell host available for isolated cron cycle execution.'
        }

        # Run cron in a child host to prevent downstream "exit" calls from terminating this orchestrator.
        $cronArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $cron,
            '-Force',
            '-BatchSize', [string]$BatchSize
        )
        if ($SkipPesterGate) { $cronArgs += '-SkipPesterGate' }

        $cronProc = Start-Process -FilePath $cronHostExe -ArgumentList $cronArgs -PassThru -NoNewWindow -RedirectStandardOutput $cycleLog -RedirectStandardError $cycleErrLog
        if ($null -eq $cronProc) {
            throw 'Failed to start cron cycle process.'
        }

        $finished = $cronProc.WaitForExit($cronTimeoutMs)
        if (-not $finished) {
            try {
                Stop-Process -Id $cronProc.Id -Force -ErrorAction SilentlyContinue
            } catch {
                Write-RunLog "[cycle $i] timeout cleanup warning: $($_.Exception.Message)" 'Warning'
            }
            $rc = 124
            Write-RunLog "[cycle $i] cron timed out after $cronTimeoutMs ms" 'Error'
        } else {
            $rc = [int]$cronProc.ExitCode
        }

        if ($rc -ne 0 -and (Test-Path -LiteralPath $cycleErrLog)) {
            $stderrTail = @((Get-Content -LiteralPath $cycleErrLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6) -join ' || ')
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                Write-RunLog "[cycle $i] cron stderr tail: $stderrTail" 'Warning'
            }
        }
    } catch {
        Write-RunLog ("[cycle $i] cron threw: " + $_.Exception.Message) 'Error'
        $rc = 99
    } finally {
        Set-StrictMode -Off
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Continue'
    }

    try {
        $now = Get-QueueSnapshot
        $snapshots.Add([PSCustomObject]@{ Phase='cycle'; Cycle=$i; ExitCode=$rc; Snapshot=$now }) | Out-Null
        $delta = [PSCustomObject]@{
            Cycle           = $i
            ExitCode        = $rc
            TodoLowerDelta  = ($now.TodoLower    - $prev.TodoLower)
            Bugs2FIXDelta   = ($now.Bugs2FIX     - $prev.Bugs2FIX)
            SinCandDelta    = ($now.SinCandidates- $prev.SinCandidates)
            SinFixesDelta   = ($now.SinFixes     - $prev.SinFixes)
        }
        Write-RunLog ("[cycle $i] delta " + ($delta | ConvertTo-Json -Compress -Depth 4))

        $shrank = ($delta.TodoLowerDelta -lt 0) -or ($delta.Bugs2FIXDelta -lt 0)
        if (-not $shrank) {
            $stagnantCycles++
            Write-RunLog "[cycle $i] no shrink; stagnant=$stagnantCycles"
            if ($stagnantCycles -ge 2 -and $now.Bugs2FIX -eq 0 -and $now.TodoLower -eq 0) {
                Write-RunLog "[cycle $i] queues drained and stagnant; early stop"
                break
            }
            if ($stagnantCycles -ge 3) {
                Write-RunLog "[cycle $i] stagnant 3 cycles; early stop (no further progress likely)"
                break
            }
        } else {
            $stagnantCycles = 0
        }
        $prev = $now
    } catch {
        Write-RunLog ("[cycle $i] post-cycle snapshot threw: " + $_.Exception.Message) 'Error'
    }
}

# 4) Post-churn reindex + manifest + bundle
Invoke-StepIsolated -Name 'reindex-todo'      -ScriptPath (Join-Path $WorkspacePath 'scripts\Invoke-TodoManager.ps1')       -ScriptArgs @{ Reindex = $true } -TimeoutMs 120000 | Out-Null
Invoke-StepIsolated -Name 'build-manifest'    -ScriptPath (Join-Path $WorkspacePath 'scripts\Build-AgenticManifest.ps1')    -ScriptArgs @{ OutputPath = (Join-Path $WorkspacePath 'config\agentic-manifest.json') } -TimeoutMs 120000 | Out-Null
Invoke-StepIsolated -Name 'build-todo-bundle' -ScriptPath (Join-Path $WorkspacePath 'scripts\Invoke-TodoBundleRebuild.ps1') -ScriptArgs @{ WorkspacePath = $WorkspacePath } -TimeoutMs 180000 | Out-Null

# 5) Encoding + UI safety
Invoke-StepIsolated -Name 'encoding-validate' -ScriptPath (Join-Path $WorkspacePath 'tests\Test-EncodingCompliance.ps1')       -ScriptArgs @{ WorkspacePath = $WorkspacePath; Quiet = $true } -TimeoutMs 180000 | Out-Null
Invoke-StepIsolated -Name 'ui-event-safety'   -ScriptPath (Join-Path $WorkspacePath 'tests\Invoke-UIEventSafetyScan.ps1')      -ScriptArgs @{ WorkspacePath = $WorkspacePath } -TimeoutMs 180000 | Out-Null

$final = Get-QueueSnapshot
$snapshots.Add([PSCustomObject]@{ Phase='final'; Cycle=-1; Snapshot=$final }) | Out-Null

$report = [PSCustomObject]@{
    Stamp       = $stamp
    MaxCycles   = $MaxCycles
    BatchSize   = $BatchSize
    Initial     = $initial
    Final       = $final
    Delta       = [PSCustomObject]@{
        TodoLower     = ($final.TodoLower     - $initial.TodoLower)
        TodoPA        = ($final.TodoPA        - $initial.TodoPA)
        Bugs          = ($final.Bugs          - $initial.Bugs)
        Bugs2FIX      = ($final.Bugs2FIX      - $initial.Bugs2FIX)
        SinCandidates = ($final.SinCandidates - $initial.SinCandidates)
        SinFixes      = ($final.SinFixes      - $initial.SinFixes)
    }
    Snapshots   = $snapshots
    RunLog      = $runLog
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summary -Encoding UTF8
Write-RunLog "==== Pipeline churn end ==== summary: $summary"
$report | Format-List
exit 0


