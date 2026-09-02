# VersionTag: 2608.B1.V54.1
<#
.SYNOPSIS
    Supervises ONE chat/agent session at a time and presses "Try Again" for you
    until all todo work is complete, all tests pass and the tree is commit-able.

.DESCRIPTION
    Runs a single session, classifies how it ended (error / failure / quit /
    crash / hang / incomplete todos / failing tests) and re-runs it under an
    escalating retry ladder:

        attempts 1-6   immediate retry
        attempt  7     immediate retry + steering comment
        then           15s x 5min -> 60s x 45min -> 120s x 2h -> 180s x 3h -> 300s x 48h

    Only near-immediate failures escalate the ladder; a failure that took real
    work resets it to the start. When the same failure signature repeats
    -IdenticalFailureAbortCount times an option box is shown so the operator can
    choose how to proceed (each button carries a hover description).

.PARAMETER SessionCommand
    The command re-run on every "Try Again". Supports the {{STEERING}} token,
    which is replaced by the steering comment from attempt 7 onward. The child
    process also receives the comment via $env:SESSION_LOOP_STEERING.

.EXAMPLE
    .\Invoke-SessionResilienceLoop.ps1 -DetectOnly

.EXAMPLE
    .\Invoke-SessionResilienceLoop.ps1 -SessionCommand '.\scripts\Run-FullPipeline.ps1 -CI'

.NOTES
    VersionTag: 2608.B1.V1.0
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),

    [string]$SessionCommand,

    [string]$ConfigPath,

    [string]$TodoStatePath,

    [string]$TestResultsPath,

    [int]$ImmediateFailSeconds = 0,

    [int]$HangSeconds = 0,

    [int]$IdenticalFailureAbortCount = 0,

    [double]$MaxWallClockHours = 54,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Detect')]
    [switch]$DetectOnly,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$ResumeToday,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Stop')]
    [switch]$Stop,

    [Alias('2BxPrimeTimesLucky')]
    [switch]$PrimeGate,

    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ────────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $WorkspacePath)) {
    throw "WorkspacePath does not exist: $WorkspacePath"
}
$WorkspacePath = (Resolve-Path -LiteralPath $WorkspacePath).Path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Join-Path $WorkspacePath 'config') 'session-resilience-loop.json'
}
$controlProfilePath = Join-Path (Join-Path $WorkspacePath 'config') 'session-resilience-control-profile.json'
$logRoot = Join-Path (Join-Path $WorkspacePath 'logs') 'session-loop'
$ledgerPath = Join-Path $logRoot 'ledger.json'
$sessionIndexPath = Join-Path $logRoot 'session-index.jsonl'
$statePath = Join-Path $logRoot 'state.json'
$lockPath = Join-Path $logRoot '.session-loop.lock'
$stopPath = Join-Path $logRoot 'session-loop.stop'
$pausePath = Join-Path $logRoot 'session-loop.pause'

if (-not (Test-Path -LiteralPath $logRoot)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}

$modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'SessionOutcomeClassifier.psm1'
try {
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    throw "Failed to import SessionOutcomeClassifier: $($_.Exception.Message)"
}

$config = Get-SessionLoopConfig -ConfigPath $ConfigPath
$controlProfile = $null
if (Test-Path -LiteralPath $controlProfilePath) {
    try {
        $controlProfile = Get-Content -LiteralPath $controlProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Control profile is not valid JSON ($controlProfilePath): $($_.Exception.Message)"
    }
}

if ($PrimeGate.IsPresent) {
    if ($null -eq $controlProfile -or $controlProfile.PSObject.Properties.Name -notcontains 'secretGate') {
        throw 'Prime gate requested but no valid control profile secretGate is configured.'
    }
    $primeValue = [int]$controlProfile.secretGate.prime
    $isPrime = $primeValue -gt 1
    for ($factor = 2; $factor -le [math]::Sqrt($primeValue); $factor++) {
        if (($primeValue % $factor) -eq 0) { $isPrime = $false; break }
    }
    if (-not $isPrime -or $primeValue -ge 13) {
        throw "Prime gate configuration is invalid: expected a prime below 13, got $primeValue."
    }
}

if ($ImmediateFailSeconds -gt 0) {
    $config.immediateFailSeconds = $ImmediateFailSeconds
}
if ($HangSeconds -le 0) {
    $HangSeconds = [int]$config.hangSeconds
}
if ($IdenticalFailureAbortCount -le 0) {
    $IdenticalFailureAbortCount = [int]$config.identicalFailureAbortCount
}
if ([string]::IsNullOrWhiteSpace($TodoStatePath)) {
    $TodoStatePath = Join-Path (Join-Path $WorkspacePath 'logs') 'session-loop-todo.json'
}
if ([string]::IsNullOrWhiteSpace($TestResultsPath)) {
    $TestResultsPath = Join-Path $WorkspacePath 'testResults.xml'
}

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-LoopLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Colour = 'Gray'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$stamp] $Text" -ForegroundColor $Colour
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $json = $Data | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -Force
}

function Read-JsonArray {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return @()
    }
    if ($null -eq $data) { return @() }
    return @($data)
}

function Add-SessionIndexRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Record
    )
    $line = $Record | ConvertTo-Json -Depth 8 -Compress
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Find-IndexedRetryableSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$Since
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json
            if ($null -ne $row -and [datetime]$row.startedAt -ge $Since -and
                [string]$row.outcome -ne 'SUCCESS' -and [bool]$row.offersTryAgain) {
                $rows += $row
            }
        }
        catch {
            Write-LoopLine "Ignoring malformed session-index record: $($_.Exception.Message)" 'Yellow'
        }
    }
    return @($rows | Sort-Object -Property @{ Expression = 'startedAt'; Descending = $true })
}

function Test-LockOwnerAlive {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $lock = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $false
    }
    if ($null -eq $lock -or $lock.PSObject.Properties.Name -notcontains 'pid') { return $false }
    $owner = Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue
    return ($null -ne $owner)
}

function Get-SessionShell {
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) { return $pwshCmd.Source }
    $psCmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $psCmd) { return $psCmd.Source }
    throw 'Neither pwsh.exe nor powershell.exe could be located.'
}

function Invoke-OneSession {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][int]$AttemptNumber,
        [Parameter(Mandatory = $true)][int]$IdleTimeoutSeconds,
        [AllowEmptyString()][string]$Steering = ''
    )

    $tag = 'attempt-{0:d4}' -f $AttemptNumber
    $outFile = Join-Path $OutDir "$tag.out.log"
    $errFile = Join-Path $OutDir "$tag.err.log"

    $resolved = $Command.Replace('{{STEERING}}', $Steering)
    $env:SESSION_LOOP_STEERING = $Steering
    $env:SESSION_LOOP_ATTEMPT = "$AttemptNumber"

    $shell = Get-SessionShell
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $resolved)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = -1

    $proc = Start-Process -FilePath $shell -ArgumentList $argList -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $lastSize = -1L
    $lastProgress = Get-Date

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $size = 0L
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) {
                $size += (Get-Item -LiteralPath $f).Length
            }
        }
        if ($size -ne $lastSize) {
            $lastSize = $size
            $lastProgress = Get-Date
        }
        elseif ($IdleTimeoutSeconds -gt 0 -and ((Get-Date) - $lastProgress).TotalSeconds -ge $IdleTimeoutSeconds) {
            $timedOut = $true
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            }
            catch {
                Write-LoopLine "Could not kill hung session PID $($proc.Id): $($_.Exception.Message)" 'Yellow'
            }
            break
        }
    }

    try {
        $waitTicks = 0
        while (-not $proc.HasExited -and $waitTicks -lt 25) {
            Start-Sleep -Milliseconds 200
            $waitTicks++
        }
        if (-not $proc.HasExited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Write-LoopLine "Failed to terminate session PID $($proc.Id): $($_.Exception.Message)" 'Yellow' }
            $exitCode = -1
        }
        else {
            $exitCode = $proc.ExitCode
        }
    }
    catch {
        $exitCode = -1
    }
    $sw.Stop()

    $transcript = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) {
            $transcript += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
            $transcript += "`n"
        }
    }

    return [pscustomobject]@{
        ExitCode        = $exitCode
        DurationSeconds = $sw.Elapsed.TotalSeconds
        TimedOut        = $timedOut
        TranscriptPath  = $outFile
        TranscriptText  = $transcript
    }
}

function Invoke-CommitGate {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][int]$AttemptNumber
    )

    if ($null -eq $Profile -or $Profile.PSObject.Properties.Name -notcontains 'commitGate' -or
        -not [bool]$Profile.commitGate.enabled) {
        return [pscustomobject]@{ Passed = $false; ExitCode = -1; Reason = 'Commit gate is not configured or enabled.'; TranscriptPath = '' }
    }

    $command = ([string]$Profile.commitGate.command).Replace('{{WORKSPACE}}', $Workspace)
    $gateOutput = Join-Path $OutputDirectory ('attempt-{0:d4}.commit-gate.log' -f $AttemptNumber)
    $gateError = Join-Path $OutputDirectory ('attempt-{0:d4}.commit-gate.err.log' -f $AttemptNumber)
    $shell = Get-SessionShell
    try {
        $process = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) `
            -PassThru -NoNewWindow -RedirectStandardOutput $gateOutput -RedirectStandardError $gateError
        $timeoutSeconds = [int]$Profile.commitGate.timeoutSeconds
        $waited = 0
        while (-not $process.HasExited -and $waited -lt $timeoutSeconds) {
            Start-Sleep -Seconds 1
            $waited++
        }
        if (-not $process.HasExited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { Write-LoopLine "Commit gate timeout cleanup failed: $($_.Exception.Message)" 'Yellow' }
            return [pscustomobject]@{ Passed = $false; ExitCode = -1; Reason = 'Commit gate timed out.'; TranscriptPath = $gateOutput }
        }
        $requiredCode = [int]$Profile.commitGate.requireExitCode
        $passed = ($process.ExitCode -eq $requiredCode)
        return [pscustomobject]@{
            Passed         = $passed
            ExitCode       = $process.ExitCode
            Reason         = if ($passed) { 'Commit gate passed.' } else { "Commit gate exited with code $($process.ExitCode)." }
            TranscriptPath = $gateOutput
        }
    }
    catch {
        return [pscustomobject]@{ Passed = $false; ExitCode = -1; Reason = "Commit gate launch failed: $($_.Exception.Message)"; TranscriptPath = $gateOutput }
    }
}

function Show-RepeatFailureDecision {
    param(
        [Parameter(Mandatory = $true)][int]$RepeatCount,
        [Parameter(Mandatory = $true)][string]$Signature,
        [Parameter(Mandatory = $true)][string]$LastReason,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [switch]$Headless
    )

    $options = @(
        [pscustomobject]@{
            Key         = 'CONTINUE'
            Label       = 'Keep trying (stay on the current ladder)'
            Description = "Presses Try Again again and keeps the current backoff phase. Use this when you believe the failure is transient (network, rate limit, flaky test) and time will clear it. The loop keeps running until the 48-hour band is exhausted."
        },
        [pscustomobject]@{
            Key         = 'RESET'
            Label       = 'Reset the ladder and retry immediately'
            Description = "Throws away the accumulated backoff and starts again at attempt 1 with no delay, but keeps the steering comment attached. Use this after you have manually fixed something outside the loop and want a fast fresh run."
        },
        [pscustomobject]@{
            Key         = 'PAUSE'
            Label       = 'Pause the loop (leave it resumable)'
            Description = "Stops launching new sessions and waits, holding the lock and the ledger. Delete logs\session-loop\session-loop.pause to resume exactly where it stopped. Use this while you investigate by hand."
        },
        [pscustomobject]@{
            Key         = 'STOP'
            Label       = 'Stop the loop and write the final report'
            Description = "Ends supervision now, releases the single-flight lock, and writes the forensic report (attempt history, failure signatures, last transcript) to logs\session-loop. Use this when the failure is clearly deterministic and needs a human fix."
        },
        [pscustomobject]@{
            Key         = 'OPEN_LEDGER'
            Label       = 'Open the ledger, then keep trying'
            Description = "Opens logs\session-loop\ledger.json in your default editor so you can inspect every attempt, then resumes the loop on the current ladder phase. Nothing is cancelled."
        }
    )

    $message = "The same failure has now repeated $RepeatCount times in a row.`r`n`r`n" +
    "Signature : $($Signature.Substring(0, [math]::Min(16, $Signature.Length)))`r`n" +
    "Last cause: $LastReason`r`n`r`n" +
    'Hover any button for a full description of what it does.'

    return Show-SessionLoopDecision -Title 'Session Resilience Loop - repeated failure' `
        -Message $message -Options $options -TimeoutSeconds $TimeoutSeconds -NonInteractive:$Headless
}

# ── Mode: Stop ───────────────────────────────────────────────────────────────
if ($Stop.IsPresent) {
    Set-Content -LiteralPath $stopPath -Value '1' -Encoding UTF8 -Force
    Write-LoopLine "Stop signal written: $stopPath" 'Yellow'
    if ((Test-Path -LiteralPath $lockPath) -and -not (Test-LockOwnerAlive -Path $lockPath)) {
        Remove-Item -LiteralPath $lockPath -Force
        Write-LoopLine 'Stale lock removed.' 'Yellow'
    }
    return
}

# ── Mode: Status ─────────────────────────────────────────────────────────────
if ($Status.IsPresent) {
    $ledger = Read-JsonArray -Path $ledgerPath
    Write-LoopLine "Ledger entries: $(@($ledger).Count)" 'Cyan'
    if (Test-Path -LiteralPath $statePath) {
        Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | Write-Host
    }
    $lockAlive = Test-LockOwnerAlive -Path $lockPath
    Write-LoopLine "Loop active: $lockAlive" 'Cyan'
    if (@($ledger).Count -gt 0) {
        @($ledger) | Select-Object -Last 10 |
            Format-Table Attempt, PhaseName, Outcome, DurationSeconds, DelaySeconds, Steering -AutoSize |
                Out-String | Write-Host
    }
    return
}

# ── Mode: DetectOnly ─────────────────────────────────────────────────────────
if ($DetectOnly.IsPresent) {
    $found = @(Find-RetryableSession -WorkspacePath $WorkspacePath -Config $config -Since ([datetime]::Today))
    if ($found.Count -eq 0) {
        Write-LoopLine 'No retryable session found for today.' 'Green'
        return
    }
    $bestCandidate = $found | Select-Object -First 1
    Write-LoopLine "Retryable sessions found today: $($found.Count)" 'Yellow'
    $found | Select-Object -First 15 |
        Format-Table SessionId, Recommendation, LastWriteTime, FailurePattern -AutoSize |
            Out-String | Write-Host
    Write-LoopLine "Best candidate: $($bestCandidate.Path)" 'Cyan'
    Write-LoopLine "Last action  : $($bestCandidate.LastAction)" 'Cyan'
    return
}

# ── Mode: Run ────────────────────────────────────────────────────────────────
$selectedRetryableSession = $null
if ($ResumeToday.IsPresent) {
    $found = @(Find-IndexedRetryableSession -Path $sessionIndexPath -Since ([datetime]::Today))
    if ($found.Count -eq 0) {
        $found = @(Find-RetryableSession -WorkspacePath $WorkspacePath -Config $config -Since ([datetime]::Today))
    }
    if ($found.Count -eq 0) {
        throw 'ResumeToday was requested but no retryable session from today was found.'
    }
    $selectedRetryableSession = $found | Select-Object -First 1
    Write-LoopLine "Resuming top retryable session: $($selectedRetryableSession.Path)" 'Cyan'
    Write-LoopLine "Last action: $($selectedRetryableSession.LastAction)" 'Cyan'
    if ([string]::IsNullOrWhiteSpace($SessionCommand) -and
        $selectedRetryableSession.PSObject.Properties.Name -contains 'command' -and
        -not [string]::IsNullOrWhiteSpace([string]$selectedRetryableSession.command)) {
        $SessionCommand = [string]$selectedRetryableSession.command
        Write-LoopLine 'Replaying the indexed session command contract.' 'Cyan'
    }
}

if ([string]::IsNullOrWhiteSpace($SessionCommand)) {
    $defaultPipeline = Join-Path (Join-Path $WorkspacePath 'scripts') 'Run-FullPipeline.ps1'
    if (Test-Path -LiteralPath $defaultPipeline) {
        $SessionCommand = "& '$defaultPipeline' -WorkspacePath '$WorkspacePath' -CI"
        Write-LoopLine "SessionCommand not supplied. Defaulting to: $SessionCommand" 'Yellow'
    }
}

if ([string]::IsNullOrWhiteSpace($SessionCommand)) {
    throw 'Provide -SessionCommand (the work re-run on every Try Again), or keep scripts\Run-FullPipeline.ps1 available for default execution.'
}

if (Test-LockOwnerAlive -Path $lockPath) {
    throw "Another session loop is already running (lock: $lockPath). Use -Status, or -Stop to end it."
}
if (Test-Path -LiteralPath $lockPath) {
    Remove-Item -LiteralPath $lockPath -Force
}
if (Test-Path -LiteralPath $stopPath) {
    Remove-Item -LiteralPath $stopPath -Force
}

Save-Json -Path $lockPath -Data ([pscustomobject]@{
        pid               = $PID
        startedAt         = (Get-Date).ToString('o')
        command           = $SessionCommand
        resumeToday       = $ResumeToday.IsPresent
        targetSessionPath = if ($null -eq $selectedRetryableSession) { '' } else { [string]$selectedRetryableSession.Path }
    })

$ladder = @($config.ladder)
$phaseIndex = 0
$phaseAttempt = 0
$totalAttempts = 0
$applySteering = $false
$ledger = @()
$signatureRuns = @{}
$lastSignature = ''
$repeatCount = 0
$finalOutcome = 'EXHAUSTED'
$loopStart = Get-Date

Write-LoopLine "Session Resilience Loop starting (PID $PID)" 'Cyan'
Write-LoopLine "Command: $SessionCommand" 'Gray'
if ($DryRun.IsPresent) { Write-LoopLine 'DRY RUN - no sessions are launched, delays are simulated.' 'Yellow' }

try {
    while ($true) {
        if (Test-Path -LiteralPath $stopPath) {
            Write-LoopLine 'Stop signal detected - ending loop.' 'Yellow'
            $finalOutcome = 'STOPPED'
            break
        }
        if ((Get-Date) - $loopStart -gt [timespan]::FromHours($MaxWallClockHours)) {
            Write-LoopLine "Wall-clock cap of $MaxWallClockHours h reached." 'Yellow'
            $finalOutcome = 'WALL_CLOCK_CAP'
            break
        }
        while ((Test-Path -LiteralPath $pausePath) -and -not (Test-Path -LiteralPath $stopPath)) {
            Write-LoopLine 'Paused - delete session-loop.pause to resume.' 'Yellow'
            Start-Sleep -Seconds 10
        }

        $totalAttempts++
        $steeringText = ''
        if ($applySteering) { $steeringText = [string]$config.steeringComment }

        $phaseItem = $ladder | Select-Object -Skip $phaseIndex -First 1
        if ($null -eq $phaseItem) {
            $phaseItem = $ladder | Select-Object -First 1
            $phaseIndex = 0
        }
        $phaseName = [string]$phaseItem.name

        Write-LoopLine ("Attempt {0} | phase {1} ({2}) | steering: {3}" -f `
                $totalAttempts, $phaseIndex, $phaseName, [bool]$applySteering) 'White'

        if ($DryRun.IsPresent) {
            $run = [pscustomobject]@{
                ExitCode        = 1
                DurationSeconds = 1.0
                TimedOut        = $false
                TranscriptPath  = ''
                TranscriptText  = 'DRYRUN: simulated near-immediate failure'
            }
        }
        else {
            $run = Invoke-OneSession -Command $SessionCommand -OutDir $logRoot `
                -AttemptNumber $totalAttempts -IdleTimeoutSeconds $HangSeconds -Steering $steeringText
        }

        $pendingTodos = Get-PendingTodoCount -TodoStatePath $TodoStatePath
        $failedTests = Get-FailedTestCount -TestResultsPath $TestResultsPath

        $outcome = Get-SessionOutcome -ExitCode $run.ExitCode -DurationSeconds $run.DurationSeconds `
            -TranscriptText $run.TranscriptText -Config $config `
            -PendingTodoCount $pendingTodos -FailedTestCount $failedTests -TimedOut:$run.TimedOut

        $phaseAttempt++

        $commitGate = [pscustomobject]@{ Passed = $false; ExitCode = -1; Reason = 'Commit gate not reached.'; TranscriptPath = '' }
        if ($outcome.IsSuccess) {
            $commitGate = Invoke-CommitGate -Profile $controlProfile -Workspace $WorkspacePath -OutputDirectory $logRoot -AttemptNumber $totalAttempts
            if (-not $commitGate.Passed) {
                $outcome = [pscustomobject]@{
                    Outcome         = 'COMMIT_GATE_FAIL'
                    IsSuccess       = $false
                    NearImmediate   = $true
                    DurationSeconds = $outcome.DurationSeconds
                    ExitCode        = $commitGate.ExitCode
                    PendingTodos    = $pendingTodos
                    FailedTests     = $failedTests
                    Reason          = $commitGate.Reason
                }
            }
        }

        $plan = $null
        $signature = ''
        if (-not $outcome.IsSuccess) {
            $signature = Get-SessionFailureSignature -Outcome $outcome.Outcome -ExitCode $run.ExitCode `
                -TranscriptText $run.TranscriptText
            if ($signature -eq $lastSignature) { $repeatCount++ } else { $repeatCount = 1 }
            $lastSignature = $signature
            $signatureRuns.Set_Item($signature, $repeatCount)

            $plan = Get-NextRetryPlan -Config $config -PhaseIndex $phaseIndex -PhaseAttempt $phaseAttempt `
                -TotalAttempts $totalAttempts -NearImmediate ([bool]$outcome.NearImmediate)
        }

        $plannedDelay = 0
        if ($null -ne $plan) { $plannedDelay = [int]$plan.DelaySeconds }

        $ledger += [pscustomobject]@{
            Attempt           = $totalAttempts
            PhaseIndex        = $phaseIndex
            PhaseName         = $phaseName
            PhaseAttempt      = $phaseAttempt
            StartedAt         = (Get-Date).ToString('o')
            DurationSeconds   = $outcome.DurationSeconds
            ExitCode          = $run.ExitCode
            Outcome           = $outcome.Outcome
            Reason            = $outcome.Reason
            NearImmediate     = $outcome.NearImmediate
            PendingTodos      = $pendingTodos
            FailedTests       = $failedTests
            Steering          = $applySteering
            TargetSessionPath = if ($null -eq $selectedRetryableSession) { '' } else { [string]$selectedRetryableSession.Path }
            Signature         = $signature
            RepeatCount       = $repeatCount
            DelaySeconds      = $plannedDelay
            TranscriptPath    = $run.TranscriptPath
        }
        Save-Json -Path $ledgerPath -Data $ledger
        Add-SessionIndexRecord -Path $sessionIndexPath -Record ([pscustomobject]@{
                sessionId         = if ($null -eq $selectedRetryableSession) { "session-$PID" } else { [string]$selectedRetryableSession.SessionId }
                command           = $SessionCommand
                workspace         = $WorkspacePath
                attempt           = $totalAttempts
                startedAt         = (Get-Date).ToString('o')
                outcome           = $outcome.Outcome
                offersTryAgain    = (-not $outcome.IsSuccess)
                lastAction        = $outcome.Reason
                Path              = $run.TranscriptPath
                transcriptPath    = $run.TranscriptPath
                targetSessionPath = if ($null -eq $selectedRetryableSession) { '' } else { [string]$selectedRetryableSession.Path }
            })

        if ($outcome.IsSuccess) {
            Write-LoopLine 'SUCCESS - all todos done, tests pass, ready to commit.' 'Green'
            $finalOutcome = 'SUCCESS'
            if ($PrimeGate.IsPresent) {
                if (-not (Test-Path -LiteralPath $logRoot)) {
                    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
                }
                $safeLogRoot = (Resolve-Path -LiteralPath $logRoot).Path
                $reviewEventPath = Join-Path $safeLogRoot 'recursive-review-requested.json'
                [pscustomobject]@{
                    event         = 'RECURSIVE_REVIEW_REQUESTED'
                    prime         = [int]$controlProfile.secretGate.prime
                    createdAt     = (Get-Date).ToString('o')
                    ledgerPath    = $ledgerPath
                    totalAttempts = $totalAttempts
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reviewEventPath -Encoding UTF8 -Force
                Write-LoopLine "Prime-gated recursive review requested: $reviewEventPath" 'Magenta'
            }
            break
        }

        Write-LoopLine "Failure: $($outcome.Outcome) - $($outcome.Reason)" 'Red'

        if ($IdenticalFailureAbortCount -gt 0 -and $repeatCount -ge $IdenticalFailureAbortCount) {
            Write-LoopLine "Identical failure repeated $repeatCount times - asking the operator." 'Magenta'
            $timeout = 900
            if ($config.PSObject.Properties.Name -contains 'decisionPromptTimeoutSeconds') {
                $timeout = [int]$config.decisionPromptTimeoutSeconds
            }
            $headless = ($NonInteractive.IsPresent -or $DryRun.IsPresent)
            $decision = Show-RepeatFailureDecision -RepeatCount $repeatCount -Signature $signature `
                -LastReason $outcome.Reason -TimeoutSeconds $timeout -Headless:$headless

            Write-LoopLine "Operator decision: $decision" 'Magenta'
            switch ($decision) {
                'STOP' { $finalOutcome = 'OPERATOR_STOP' }
                'PAUSE' { Set-Content -LiteralPath $pausePath -Value '1' -Encoding UTF8 -Force }
                'RESET' {
                    $phaseIndex = 0
                    $phaseAttempt = 0
                    $repeatCount = 0
                    $plan = $null
                }
                'OPEN_LEDGER' {
                    try { Invoke-Item -LiteralPath $ledgerPath } catch { Write-LoopLine "Could not open ledger: $($_.Exception.Message)" 'Yellow' }
                }
                default { $repeatCount = 0 }
            }
            if ($finalOutcome -eq 'OPERATOR_STOP') { break }
        }

        if ($null -ne $plan) {
            if ($plan.Exhausted) {
                Write-LoopLine 'Retry ladder exhausted.' 'Red'
                $finalOutcome = 'EXHAUSTED'
                break
            }
            if ($plan.LadderReset) {
                Write-LoopLine 'Failure was not near-immediate - ladder reset to phase 0.' 'Yellow'
            }
            $phaseIndex = $plan.PhaseIndex
            $phaseAttempt = $plan.PhaseAttempt
            $applySteering = $plan.ApplySteering

            if ($plan.DelaySeconds -gt 0) {
                Write-LoopLine "Waiting $($plan.DelaySeconds)s before the next Try Again..." 'Gray'
                if (-not $DryRun.IsPresent) { Start-Sleep -Seconds $plan.DelaySeconds }
            }
        }

        Save-Json -Path $statePath -Data ([pscustomobject]@{
                updatedAt     = (Get-Date).ToString('o')
                totalAttempts = $totalAttempts
                phaseIndex    = $phaseIndex
                phaseAttempt  = $phaseAttempt
                steering      = $applySteering
                lastOutcome   = $outcome.Outcome
                lastSignature = $lastSignature
                repeatCount   = $repeatCount
            })

        if ($DryRun.IsPresent -and $totalAttempts -ge 40) {
            Write-LoopLine 'Dry run sample complete (40 attempts simulated).' 'Yellow'
            $finalOutcome = 'DRYRUN'
            break
        }
    }
}
finally {
    Save-Json -Path $statePath -Data ([pscustomobject]@{
            updatedAt     = (Get-Date).ToString('o')
            totalAttempts = $totalAttempts
            phaseIndex    = $phaseIndex
            phaseAttempt  = $phaseAttempt
            steering      = $applySteering
            finalOutcome  = $finalOutcome
            elapsedHours  = [math]::Round(((Get-Date) - $loopStart).TotalHours, 3)
        })
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    $env:SESSION_LOOP_STEERING = $null
    $env:SESSION_LOOP_ATTEMPT = $null
}

Write-LoopLine "Final outcome: $finalOutcome after $totalAttempts attempt(s)." 'Cyan'
Write-LoopLine "Ledger: $ledgerPath" 'Gray'

if ($finalOutcome -eq 'SUCCESS' -or $finalOutcome -eq 'DRYRUN') { exit 0 }
exit 1
