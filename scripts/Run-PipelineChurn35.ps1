# VersionTag: 2608.B1.V1.2
# SupportPS5.1: YES
# SupportsPS7.6: YES
# SupportPS5.1TestedDate: 2026-08-18
# SupportsPS7.6TestedDate: 2026-08-18
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Pipeline churn orchestrator: SIN remedy + AutoIssueFinder + N cron cycles + verify.
.DESCRIPTION
    One-shot orchestrator used by the 7-item / 2-cycle churn flow. Runs:
      1. SIN remedy engine over sin_registry/candidates -> Bugs2FIX
      2. AutoIssueFinder bug discovery (chronic parse-error allow-list respected by its own internals)
            3. Invoke-CronProcessor.ps1 -BatchSize 7 -Force, repeated up to -MaxCycles
         (stops early when the Bugs2FIX queue stops shrinking for 2 consecutive cycles
          AND the lowercase todo queue stops shrinking too).
      4. Reindex + manifest + bundle rebuild
      5. Encoding compliance + UI event safety scans
      6. Final queue snapshot and JSON summary
.PARAMETER MaxCycles
    Hard cap on cron processor cycles. Default: 2.
.PARAMETER BatchSize
    Items per cron cycle. Default: 7. Invalid prompted input uses 10 as a safety fallback.
.PARAMETER LogDir
    Directory for the per-cycle logs. Default: logs/pipeline-churn.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 100)] [int]$MaxCycles = 2,
    [int]$BatchSize = 7,
    [switch]$SkipPesterGate,
    [switch]$SkipEvolutionGate,
    [switch]$ValidateEvolutionOnly,
    [switch]$SkipSelfCiBugCreation,
    [switch]$ApproveFeatureRequests,
    [switch]$NonInteractive,
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$LogDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $WorkspacePath 'logs\pipeline-churn'
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLog = Join-Path $LogDir "churn-run-$stamp.log"
$summary = Join-Path $LogDir "churn-summary-$stamp.json"
$todoDir = Join-Path $WorkspacePath 'todo'
$sinDir = Join-Path $WorkspacePath 'sin_registry'

function Write-RunLog {
    param([string]$Msg, [string]$Level = 'Info')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-TimedIntegerInput {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][int]$DefaultValue,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    if ($NonInteractive.IsPresent) {
        Write-RunLog "$Prompt non-interactive mode; using default $DefaultValue"
        return $DefaultValue
    }

    Write-Host ("{0} [{1}] (waiting {2}s): " -f $Prompt, $DefaultValue, $TimeoutSeconds) -NoNewline
    $buffer = New-Object System.Text.StringBuilder
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Enter) { break }
                    if ($key.Key -eq [ConsoleKey]::Backspace) {
                        if ($buffer.Length -gt 0) {
                            $buffer.Remove($buffer.Length - 1, 1) | Out-Null
                            Write-Host "`b `b" -NoNewline
                        }
                        continue
                    }
                    if ($key.KeyChar -match '\d') {
                        $buffer.Append($key.KeyChar) | Out-Null
                        Write-Host $key.KeyChar -NoNewline
                    }
                }
                else {
                    Start-Sleep -Milliseconds 100
                }
            }
            catch {
                Write-Host ''
                Write-RunLog "Input unavailable; using default $DefaultValue ($($_.Exception.Message))" 'Warning'
                return $DefaultValue
            }
        }
    }
    finally {
        $timer.Stop()
    }
    Write-Host ''


    $value = 0
    if ([int]::TryParse($buffer.ToString(), [ref]$value) -and $value -ge 1) {
        return $value
    }
    Write-RunLog "Invalid or empty operator input; using default $DefaultValue" 'Warning'
    return $DefaultValue
}

function Test-PipelineEvolutionAlignment {
    param([Parameter(Mandatory = $true)][string]$Root)

    $required = @(
        'modules\CronAiAthon-Pipeline.psm1',
        'modules\CronAiAthon-Scheduler.psm1',
        'scripts\Invoke-CronProcessor.ps1',
        'scripts\Run-PipelineChurn35.ps1',
        'config\agentic-manifest.json',
        '.vscode\tasks.json'
    )
    $missing = @()
    foreach ($relativePath in $required) {
        $candidate = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $candidate)) { $missing += $relativePath }
    }
    if ($missing.Count -gt 0) {
        Write-RunLog ("Evolution alignment gate failed; missing: " + ($missing -join ', ')) 'Error'
        return $false
    }

    try {
        $manifest = Get-Content -LiteralPath (Join-Path $Root 'config\agentic-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifestText = $manifest | ConvertTo-Json -Depth 12 -Compress
        foreach ($expected in @('CronAiAthon-Pipeline.psm1', 'CronAiAthon-Scheduler.psm1', 'Invoke-CronProcessor.ps1', 'Run-PipelineChurn35.ps1')) {
            if ($manifestText -notmatch [regex]::Escape($expected)) {
                Write-RunLog "Evolution alignment gate failed; manifest lacks $expected" 'Error'
                return $false
            }
        }
        $taskText = Get-Content -LiteralPath (Join-Path $Root '.vscode\tasks.json') -Raw -Encoding UTF8
        if ($taskText -notmatch 'Run-PipelineChurn35\.ps1') {
            Write-RunLog 'Evolution alignment gate failed; VS Code tasks do not reference the churn orchestrator.' 'Error'
            return $false
        }
    }
    catch {
        Write-RunLog "Evolution alignment gate failed; manifest parse error: $($_.Exception.Message)" 'Error'
        return $false
    }
    Write-RunLog 'Evolution alignment gate passed: CronAiAthon, churn, processor, scheduler, and manifest are wired.'
    return $true
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

function Write-QueueSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Write-RunLog "$Label"
    $fields = @('Timestamp', 'TodoLower', 'TodoPA', 'TodoUpper', 'Bugs', 'Bugs2FIX', 'SinCandidates', 'SinFixes')
    $width = 0
    foreach ($field in $fields) {
        if ($field.Length -gt $width) { $width = $field.Length }
    }
    foreach ($field in $fields) {
        $value = ''
        if ($Snapshot.PSObject.Properties.Name -contains $field) {
            $value = [string]$Snapshot.$field
        }
        Write-RunLog ("    {0} : {1}" -f $field.PadRight($width), $value)
    }
}

function Write-ChurnCommentary {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-RunLog ("[Info]-[neverreallyaskedforbutitsgiven]-[{0}] {1}" -f $Category, $Message)
}

function Write-BatchProgress {
    param(
        [Parameter(Mandatory = $true)][int]$CycleNumber,
        [Parameter(Mandatory = $true)][int]$TotalCycles,
        [Parameter(Mandatory = $true)][int]$BatchNumber,
        [Parameter(Mandatory = $true)][int]$BatchSize,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    $percent = 0
    if ($TotalCycles -gt 0) {
        $percent = [math]::Round(($CycleNumber / $TotalCycles) * 100, 0)
    }
    $barWidth = 20
    $filled = [int][math]::Floor(($percent / 100) * $barWidth)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $barWidth) { $filled = $barWidth }
    $bar = ('#' * $filled) + ('.' * ($barWidth - $filled))
    Write-RunLog ("[batch progress] cycle {0}/{1} | batch {2} | size {3} | [{4}] {5}% | exit {6}" -f `
        $CycleNumber, $TotalCycles, $BatchNumber, $BatchSize, $bar, $percent, $ExitCode)
}

function Invoke-ChurnFailureTriage {
    param(
        [Parameter(Mandatory = $true)][int]$CycleNumber,
        [Parameter(Mandatory = $true)][string[]]$LogPaths
    )

    $evidence = @()
    foreach ($path in @($LogPaths)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            $text = [string]$line
            $kind = $null
            if ($text -match '(?i)crash|fatal|access violation|terminated unexpectedly') { $kind = 'CRASH' }
            elseif ($text -match '(?i)\berror\b|exception|failed|parsererror') { $kind = 'ERROR' }
            elseif ($text -match '(?i)\bwarning\b|skipped|timeout') { $kind = 'WARNING' }
            if ($null -ne $kind) {
                $evidence += [pscustomobject]@{ kind = $kind; path = $path; message = $text.Trim() }
            }
        }
    }

    $triagePath = Join-Path $LogDir ("churn-triage-{0:D2}-$stamp.json" -f $CycleNumber)
    $created = @()
    if (-not $SkipSelfCiBugCreation -and $evidence.Count -gt 0) {
        $pipelineMod = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
        try {
            if (Test-Path -LiteralPath $pipelineMod) {
                Import-Module $pipelineMod -Force -ErrorAction Stop
                $todoPath = Join-Path $WorkspacePath 'todo'
                $existingKeys = @{}
                foreach ($file in @(Get-ChildItem -LiteralPath $todoPath -Filter 'Bug-*.json' -File -ErrorAction SilentlyContinue)) {
                    try {
                        $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        $status = [string]$item.status
                        $normalizedStatus = $status.Trim().ToUpperInvariant().Replace('-', '_')
                        if ($normalizedStatus -in @('OPEN','IN_PROGRESS','PLANNED')) {
                            $existingKeys[([string]$item.title).Trim()] = $true
                        }
                    }
                    catch { Write-RunLog "Triage skipped malformed bug record $($file.Name): $($_.Exception.Message)" 'Warning' }
                }
                foreach ($group in @($evidence | Group-Object kind)) {
                    $title = "[SELF-CI][$($group.Name)] Pipeline churn cycle $CycleNumber evidence"
                    if ($existingKeys.ContainsKey($title)) { continue }
                    if (Get-Command New-PipelineItem -ErrorAction SilentlyContinue) {
                        $priority = 'MEDIUM'
                        if ($group.Name -eq 'CRASH') { $priority = 'CRITICAL' }
                        elseif ($group.Name -eq 'ERROR') { $priority = 'HIGH' }
                        $bug = New-PipelineItem -Type 'Bug' -Title $title `
                            -Description (($group.Group | Select-Object -First 10 | ForEach-Object { "$($_.path): $($_.message)" }) -join "`n") `
                            -Priority $priority `
                            -Source 'BugTracker' -Category 'churn-triage' -SuggestedBy 'PipelineChurn'
                        if (Get-Command Add-PipelineItem -ErrorAction SilentlyContinue) {
                            Add-PipelineItem -WorkspacePath $WorkspacePath -Item $bug -SkipArtifactRefresh | Out-Null
                            $created += $title
                            $existingKeys[$title] = $true
                        }
                    }
                }
            }
        }
        catch { Write-RunLog "Self-CI triage bug creation failed: $($_.Exception.Message)" 'Warning' }
    }

    [pscustomobject]@{
        cycle = $CycleNumber
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        evidence = @($evidence)
        createdBugTitles = @($created)
        creationGate = [pscustomobject]@{
            enabled = (-not $SkipSelfCiBugCreation)
            deduplicatedAgainst = 'OPEN, IN_PROGRESS, PLANNED (hyphenated values normalized)'
            source = 'Self-CI'
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $triagePath -Encoding UTF8 -Force
    Write-RunLog "[cycle $CycleNumber] triage evidence=$($evidence.Count) selfCiBugs=$($created.Count) report=$triagePath"
}

function Invoke-FeatureRequestApproval {
    if (-not $ApproveFeatureRequests.IsPresent) {
        Write-RunLog 'Feature-request approval disabled; existing proposals remain unchanged.'
        return 0
    }

    $pipelineMod = Join-Path $WorkspacePath 'modules\CronAiAthon-Pipeline.psm1'
    if (-not (Test-Path -LiteralPath $pipelineMod)) {
        Write-RunLog 'Feature-request approval skipped; pipeline module is missing.' 'Warning'
        return 0
    }

    try {
        Import-Module $pipelineMod -Force -ErrorAction Stop
        $pending = @(Get-PipelineItems -WorkspacePath $WorkspacePath -Type 'FeatureRequest' -Status 'PENDING_APPROVAL')
        $approved = 0
        foreach ($feature in $pending) {
            if ($null -eq $feature -or [string]::IsNullOrWhiteSpace([string]$feature.id)) { continue }
            $updated = Update-PipelineItemStatus -WorkspacePath $WorkspacePath -ItemId ([string]$feature.id) `
                -NewStatus 'PLANNED' -Notes 'Approved by explicit Pipeline Churn feature-request action.'
            if ($null -ne $updated) { $approved++ }
        }
        Write-RunLog "Feature-request approval completed: approved=$approved pending=$($pending.Count)"
        return $approved
    }
    catch {
        Write-RunLog "Feature-request approval failed: $($_.Exception.Message)" 'Warning'
        return 0
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
        if ($null -ne $ScriptArgs -and $null -ne $ScriptArgs.Keys) {
            & $ScriptPath @ScriptArgs *> $StepLog
        }
        else {
            & $ScriptPath *> $StepLog
        }
        $rc = if (Test-Path -LiteralPath variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        Write-RunLog "[$Name] exit=$rc log=$StepLog"
        return ($rc -eq 0)
    }
    catch {
        Write-RunLog "[$Name] exception: $($_.Exception.Message)" 'Error'
        Write-RunLog "[$Name] exception detail: $($_ | Out-String)" 'Error'
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
    }
    elseif (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
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

    if ($null -ne $ScriptArgs -and $null -ne $ScriptArgs.Keys) {
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
            }
            catch {
                Write-RunLog "[$Name] timeout cleanup warning: $($_.Exception.Message)" 'Warning'
            }
            $rc = 124
            Write-RunLog "[$Name] timed out after $TimeoutMs ms" 'Error'
        }
        else {
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
    }
    catch {
        Write-RunLog "[$Name] exception: $($_.Exception.Message)" 'Error'
        return $false
    }
}

if ($ValidateEvolutionOnly.IsPresent) {
    if (Test-PipelineEvolutionAlignment -Root $WorkspacePath) { exit 0 }
    exit 2
}

if ($BatchSize -lt 1 -or $BatchSize -gt 500) {
    $BatchSize = Read-TimedIntegerInput -Prompt 'Enter batch size (integer >= 1)' -DefaultValue 10 -TimeoutSeconds 15
}

if (-not $SkipEvolutionGate -and -not (Test-PipelineEvolutionAlignment -Root $WorkspacePath)) {
    Write-RunLog 'Pipeline churn stopped before mutation because the evolution alignment gate failed.' 'Error'
    exit 2
}

Write-RunLog "==== Pipeline churn start ===="
Write-RunLog "MaxCycles=$MaxCycles BatchSize=$BatchSize Workspace=$WorkspacePath"

$snapshots = New-Object System.Collections.Generic.List[object]
$initial = Get-QueueSnapshot
$snapshots.Add([PSCustomObject]@{ Phase = 'initial'; Cycle = 0; Snapshot = $initial }) | Out-Null
Write-QueueSnapshot -Snapshot $initial -Label 'Initial queue'
Write-ChurnCommentary -Category 'technocratic' -Message 'The queue has been measured, named, aligned, and politely placed under observation.'
Write-ChurnCommentary -Category 'gothic' -Message 'The backlog waits in its little crypt, confident that someone will eventually open the right file.'

# 1) SIN remedy engine — Convert-SinScanToBugs converts results to Bugs2FIX records
$sinRemedyScript = Join-Path $WorkspacePath 'scripts\Convert-SinScanToBugs.ps1'
$sinRemedyLog = Join-Path $LogDir "sin-remedy-$stamp.log"
if (Test-Path -LiteralPath $sinRemedyScript) {
    Write-RunLog "[sin-remedy] start -> $sinRemedyScript"
    try {
        & $sinRemedyScript -WorkspacePath $WorkspacePath -Apply -MaxItems $BatchSize *> $sinRemedyLog
        $sinRc = if (Test-Path -LiteralPath variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        Write-RunLog "[sin-remedy] exit=$sinRc log=$sinRemedyLog"
    }
    catch {
        Write-RunLog "[sin-remedy] exception: $($_.Exception.Message)" 'Error'
        Write-RunLog "[sin-remedy] exception detail: $($_ | Out-String)" 'Error'
    }
}
else {
    Write-RunLog "[sin-remedy] script missing, skipped: $sinRemedyScript" 'Warning'
}

# 2) AutoIssueFinder (preferred locations, try both)
$aif = Join-Path $WorkspacePath 'tools\AutoIssueFinder.ps1'
if (-not (Test-Path -LiteralPath $aif)) { $aif = Join-Path $WorkspacePath 'scripts\Invoke-AutoIssueFinder.ps1' }
if (Test-Path -LiteralPath $aif) {
    Invoke-Step -Name 'auto-issue-finder' -ScriptPath $aif -ScriptArgs @{ WorkspacePath = $WorkspacePath } | Out-Null
}
else {
    Write-RunLog "[auto-issue-finder] not found, skipped" 'Warning'
}

$approvedFeatureRequests = Invoke-FeatureRequestApproval

# 3) Cron cycles
$cron = Join-Path $WorkspacePath 'scripts\Invoke-CronProcessor.ps1'
$cronHostExe = $null
if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
    $cronHostExe = 'powershell.exe'
}
elseif (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
    $cronHostExe = 'pwsh.exe'
}

$cronTimeoutMs = 360000
$stagnantCycles = 0
$failedCycles = 0
$prev = $initial

function Test-ChildFailurePrompt {
    param([Parameter(Mandatory = $true)][string]$ErrorPath)
    if (-not (Test-Path -LiteralPath $ErrorPath)) { return $false }
    $text = Get-Content -LiteralPath $ErrorPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    return ($text -match '(?i)Missing closing|ParserError|Supply values for the following parameters|cmdlet .* at command pipeline position')
}

function Invoke-CronCycle {
    param(
        [Parameter(Mandatory = $true)][int]$CycleNumber,
        [Parameter(Mandatory = $true)][int]$CycleBatchSize
    )

    $cycleLog = Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.log" -f $CycleNumber)
    $cycleErrLog = Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.stderr.log" -f $CycleNumber)
    $rc = 1
    try {
        if ([string]::IsNullOrWhiteSpace($cronHostExe)) {
            throw 'No PowerShell host available for isolated cron cycle execution.'
        }
        $cronArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cron, '-Force', '-BatchSize', [string]$CycleBatchSize)
        if ($SkipPesterGate) { $cronArgs += '-SkipPesterGate' }
        $cronProc = Start-Process -FilePath $cronHostExe -ArgumentList $cronArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $cycleLog -RedirectStandardError $cycleErrLog
        if ($null -eq $cronProc) { throw 'Failed to start cron cycle process.' }
        $promptDetected = $false
        for ($probe = 0; $probe -lt 15 -and -not $cronProc.HasExited; $probe++) {
            Start-Sleep -Seconds 1
            if (Test-ChildFailurePrompt -ErrorPath $cycleErrLog) { $promptDetected = $true; break }
        }
        if ($promptDetected) {
            try { Stop-Process -Id $cronProc.Id -Force -ErrorAction SilentlyContinue } catch { Write-RunLog "[cycle $CycleNumber] early-stop cleanup warning: $($_.Exception.Message)" 'Warning' }
            $rc = 2
            Write-RunLog "[cycle $CycleNumber] stopped early: parser error or interactive prompt detected" 'Error'
        }
        else {
            $finished = $cronProc.WaitForExit($cronTimeoutMs)
        }
        if (-not $promptDetected -and -not $finished) {
            try { Stop-Process -Id $cronProc.Id -Force -ErrorAction SilentlyContinue } catch { Write-RunLog "[cycle $CycleNumber] timeout cleanup warning: $($_.Exception.Message)" 'Warning' }
            $rc = 124
            Write-RunLog "[cycle $CycleNumber] cron timed out after $cronTimeoutMs ms" 'Error'
        }
        else {
            $rc = [int]$cronProc.ExitCode
        }
        if ($rc -ne 0 -and (Test-Path -LiteralPath $cycleErrLog)) {
            $stderrTail = @((Get-Content -LiteralPath $cycleErrLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6) -join ' || ')
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) { Write-RunLog "[cycle $CycleNumber] cron stderr tail: $stderrTail" 'Warning' }
        }
    }
    catch {
        Write-RunLog ("[cycle $CycleNumber] cron threw: " + $_.Exception.Message) 'Error'
        $rc = 99
    }
    return $rc
}

for ($i = 1; $i -le $MaxCycles; $i++) {
    Write-RunLog "[cycle $i/$MaxCycles] cron start (BatchSize=$BatchSize SkipPesterGate=$SkipPesterGate)"
    Write-BatchProgress -CycleNumber $i -TotalCycles $MaxCycles -BatchNumber $i -BatchSize $BatchSize -ExitCode -1
    Write-ChurnCommentary -Category 'anal-retentive' -Message ("Batch {0} is now being counted individually, because ambiguity is how queues become folklore." -f $i)
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

        $promptDetected = $false
        for ($probe = 0; $probe -lt 15 -and -not $cronProc.HasExited; $probe++) {
            Start-Sleep -Seconds 1
            if (Test-ChildFailurePrompt -ErrorPath $cycleErrLog) { $promptDetected = $true; break }
        }
        if ($promptDetected) {
            try { Stop-Process -Id $cronProc.Id -Force -ErrorAction SilentlyContinue } catch { Write-RunLog "[cycle $i] early-stop cleanup warning: $($_.Exception.Message)" 'Warning' }
            $rc = 2
            Write-RunLog "[cycle $i] stopped early: parser error or interactive prompt detected" 'Error'
        }
        else {
            $finished = $cronProc.WaitForExit($cronTimeoutMs)
        }
        if (-not $promptDetected -and -not $finished) {
            try {
                Stop-Process -Id $cronProc.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-RunLog "[cycle $i] timeout cleanup warning: $($_.Exception.Message)" 'Warning'
            }
            $rc = 124
            Write-RunLog "[cycle $i] cron timed out after $cronTimeoutMs ms" 'Error'
        }
        else {
            $rc = [int]$cronProc.ExitCode
        }

        if ($rc -ne 0 -and (Test-Path -LiteralPath $cycleErrLog)) {
            $stderrTail = @((Get-Content -LiteralPath $cycleErrLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 6) -join ' || ')
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                Write-RunLog "[cycle $i] cron stderr tail: $stderrTail" 'Warning'
            }
        }
    }
    catch {
        Write-RunLog ("[cycle $i] cron threw: " + $_.Exception.Message) 'Error'
        $rc = 99
    }
    finally {
        Set-StrictMode -Off
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Continue'
    }

    if ($rc -ne 0) { $failedCycles++ }

    Write-BatchProgress -CycleNumber $i -TotalCycles $MaxCycles -BatchNumber $i -BatchSize $BatchSize -ExitCode $rc
    if ($rc -eq 0) {
        Write-ChurnCommentary -Category 'satirical' -Message 'The batch completed without demanding a commemorative plaque.'
    }
    else {
        Write-ChurnCommentary -Category 'melancholy' -Message ("Batch {0} returned exit {1}; the logs will remember what the operators preferred not to." -f $i, $rc)
    }

    try {
        $now = Get-QueueSnapshot
        $snapshots.Add([PSCustomObject]@{ Phase = 'cycle'; Cycle = $i; ExitCode = $rc; Snapshot = $now }) | Out-Null
        Write-QueueSnapshot -Snapshot $now -Label ("Queue after cycle {0}" -f $i)
        $delta = [PSCustomObject]@{
            Cycle          = $i
            ExitCode       = $rc
            TodoLowerDelta = ($now.TodoLower - $prev.TodoLower)
            Bugs2FIXDelta  = ($now.Bugs2FIX - $prev.Bugs2FIX)
            SinCandDelta   = ($now.SinCandidates - $prev.SinCandidates)
            SinFixesDelta  = ($now.SinFixes - $prev.SinFixes)
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
        }
        else {
            $stagnantCycles = 0
        }
        $prev = $now
    }
    catch {
        Write-RunLog ("[cycle $i] post-cycle snapshot threw: " + $_.Exception.Message) 'Error'
    }
}

$continuationCycles = 0
$remaining = Get-QueueSnapshot
$remainingWork = ($remaining.TodoLower + $remaining.TodoPA + $remaining.TodoUpper + $remaining.Bugs + $remaining.Bugs2FIX)
if ($remainingWork -gt 0) {
    $continuationCycles = Read-TimedIntegerInput -Prompt 'Todo queues remain. Enter number of additional cycles' -DefaultValue $MaxCycles -TimeoutSeconds 30
    $BatchSize = Read-TimedIntegerInput -Prompt 'Enter batch size for additional cycles (integer >= 1)' -DefaultValue $BatchSize -TimeoutSeconds 7
    for ($extra = 1; $extra -le $continuationCycles; $extra++) {
        $cycleNumber = $MaxCycles + $extra
        Write-RunLog "[continuation $extra/$continuationCycles] cron start (BatchSize=$BatchSize)"
        Write-BatchProgress -CycleNumber $cycleNumber -TotalCycles ($MaxCycles + $continuationCycles) -BatchNumber $extra -BatchSize $BatchSize -ExitCode -1
        Write-ChurnCommentary -Category 'neverreallyaskedforbutitsgiven' -Message 'Continuation has been granted the dignity of another precisely measured batch.'
        $rc = Invoke-CronCycle -CycleNumber $cycleNumber -CycleBatchSize $BatchSize
        if ($rc -ne 0) { $failedCycles++ }
        Invoke-ChurnFailureTriage -CycleNumber $cycleNumber -LogPaths @(
            (Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.log" -f $cycleNumber)),
            (Join-Path $LogDir ("cron-cycle-{0:D2}-$stamp.stderr.log" -f $cycleNumber))
        ) | Out-Null
        Write-BatchProgress -CycleNumber $cycleNumber -TotalCycles ($MaxCycles + $continuationCycles) -BatchNumber $extra -BatchSize $BatchSize -ExitCode $rc
        $now = Get-QueueSnapshot
        $snapshots.Add([PSCustomObject]@{ Phase = 'continuation'; Cycle = $cycleNumber; ExitCode = $rc; Snapshot = $now }) | Out-Null
        Write-QueueSnapshot -Snapshot $now -Label ("Queue after continuation batch {0}" -f $extra)
        if (($now.TodoLower + $now.TodoPA + $now.TodoUpper + $now.Bugs + $now.Bugs2FIX) -eq 0) {
            Write-RunLog "[continuation $extra] queues drained; stopping continuation"
            break
        }
    }
}

# 4) Post-churn reindex + manifest + bundle
if ($failedCycles -eq 0) {
    Invoke-StepIsolated -Name 'reindex-todo'      -ScriptPath (Join-Path $WorkspacePath 'scripts\Invoke-TodoManager.ps1')       -ScriptArgs @{ Reindex = $true } -TimeoutMs 120000 | Out-Null
    Invoke-StepIsolated -Name 'build-manifest'    -ScriptPath (Join-Path $WorkspacePath 'scripts\Build-AgenticManifest.ps1')    -ScriptArgs @{ OutputPath = (Join-Path $WorkspacePath 'config\agentic-manifest.json') } -TimeoutMs 120000 | Out-Null
    Invoke-StepIsolated -Name 'build-todo-bundle' -ScriptPath (Join-Path $WorkspacePath 'scripts\Invoke-TodoBundleRebuild.ps1') -ScriptArgs @{ WorkspacePath = $WorkspacePath } -TimeoutMs 180000 | Out-Null
}
else {
    Write-RunLog "Skipping derived-artifact rebuild because failedCycles=$failedCycles" 'Warning'
}

# 5) Encoding + UI safety
Invoke-StepIsolated -Name 'encoding-validate' -ScriptPath (Join-Path $WorkspacePath 'tests\Test-EncodingCompliance.ps1')       -ScriptArgs @{ WorkspacePath = $WorkspacePath; Quiet = $true } -TimeoutMs 180000 | Out-Null
Invoke-StepIsolated -Name 'ui-event-safety'   -ScriptPath (Join-Path $WorkspacePath 'tests\Invoke-UIEventSafetyScan.ps1')      -ScriptArgs @{ WorkspacePath = $WorkspacePath } -TimeoutMs 180000 | Out-Null

$final = Get-QueueSnapshot
$snapshots.Add([PSCustomObject]@{ Phase = 'final'; Cycle = -1; Snapshot = $final }) | Out-Null

$report = [PSCustomObject]@{
    Stamp              = $stamp
    MaxCycles          = $MaxCycles
    BatchSize          = $BatchSize
    ContinuationCycles = $continuationCycles
    FailedCycles       = $failedCycles
    ApprovedFeatureRequests = $approvedFeatureRequests
    Initial            = $initial
    Final              = $final
    Delta              = [PSCustomObject]@{
        TodoLower     = ($final.TodoLower - $initial.TodoLower)
        TodoPA        = ($final.TodoPA - $initial.TodoPA)
        Bugs          = ($final.Bugs - $initial.Bugs)
        Bugs2FIX      = ($final.Bugs2FIX - $initial.Bugs2FIX)
        SinCandidates = ($final.SinCandidates - $initial.SinCandidates)
        SinFixes      = ($final.SinFixes - $initial.SinFixes)
    }
    Snapshots          = $snapshots
    RunLog             = $runLog
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summary -Encoding UTF8
Write-RunLog "==== Pipeline churn end ==== summary: $summary"
$report | Format-List
if ($failedCycles -gt 0) { exit 1 }
exit 0


