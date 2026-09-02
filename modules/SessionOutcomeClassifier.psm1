<#
.SYNOPSIS
    Session Resilience Loop -- outcome classification, retry ladder maths and
    retryable-session discovery.

.DESCRIPTION
    Pure(ish) helper functions consumed by scripts\Invoke-SessionResilienceLoop.ps1.
    Targets Windows PowerShell 5.1 and PowerShell 7+.

    Exported functions:
      Get-SessionLoopConfig      Load + validate the ladder configuration.
      Get-PendingTodoCount       Count todo items not in a terminal state.
      Get-FailedTestCount        Read failure count from an NUnit/JUnit results file.
      Get-SessionOutcome         Classify a finished session run.
      Get-SessionFailureSignature Stable hash of a failure for repeat detection.
      Get-NextRetryPlan          Advance / reset the retry ladder.
      Find-RetryableSession      Locate today's sessions whose last action failed.
      Show-SessionLoopDecision   Modal option box with per-button hover descriptions.

.NOTES
    VersionTag: 2608.B1.V1.0
#>

Set-StrictMode -Version Latest

$script:TerminalTodoStates = @('DONE', 'COMPLETE', 'COMPLETED', 'CLOSED', 'RESOLVED', 'CANCELLED', 'CANCELED', 'WONTFIX', 'DUPLICATE')

function Get-SessionLoopConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Session loop config not found: $ConfigPath"
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json
    }
    catch {
        throw "Session loop config is not valid JSON ($ConfigPath): $($_.Exception.Message)"
    }

    $ladder = @($cfg.ladder)
    if ($ladder.Count -eq 0) {
        throw "Session loop config has an empty ladder: $ConfigPath"
    }

    for ($i = 0; $i -lt $ladder.Count; $i++) {
        if ([int]$ladder[$i].maxAttempts -lt 1) {
            throw "Ladder phase $i has maxAttempts < 1 in $ConfigPath"
        }
    }

    return $cfg
}

function Get-PendingTodoCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TodoStatePath
    )

    if ([string]::IsNullOrWhiteSpace($TodoStatePath) -or -not (Test-Path -LiteralPath $TodoStatePath)) {
        return -1  # unknown - caller treats as "cannot prove completion"
    }

    try {
        $data = Get-Content -LiteralPath $TodoStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return -1
    }

    $items = @()
    if ($null -eq $data) {
        return -1
    }
    elseif ($data -is [System.Array]) {
        $items = @($data)
    }
    elseif ($data.PSObject.Properties.Name -contains 'items') {
        $items = @($data.items)
    }
    elseif ($data.PSObject.Properties.Name -contains 'todos') {
        $items = @($data.todos)
    }
    else {
        return -1
    }

    $pending = 0
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $status = $null
        foreach ($name in @('status', 'Status', 'state', 'State')) {
            if ($item.PSObject.Properties.Name -contains $name) {
                $status = [string]$item.$name
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($status)) { continue }
        $normalised = $status.Trim().ToUpperInvariant().Replace(' ', '_').Replace('-', '_')
        if ($script:TerminalTodoStates -notcontains $normalised) {
            $pending++
        }
    }

    return $pending
}

function Get-FailedTestCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TestResultsPath
    )

    if ([string]::IsNullOrWhiteSpace($TestResultsPath) -or -not (Test-Path -LiteralPath $TestResultsPath)) {
        return -1
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $TestResultsPath -Raw -Encoding UTF8
    }
    catch {
        return -1
    }

    if ($null -eq $xml -or $null -eq $xml.DocumentElement) {
        return -1
    }

    $root = $xml.DocumentElement
    foreach ($attr in @('failures', 'failed', 'total-failed')) {
        if ($root.HasAttribute($attr)) {
            $parsed = 0
            if ([int]::TryParse($root.GetAttribute($attr), [ref]$parsed)) {
                return $parsed
            }
        }
    }

    # NUnit2 style: count result="Failure" test-case nodes.
    $failures = @($xml.SelectNodes("//test-case[@result='Failure']"))
    if ($failures.Count -gt 0) { return $failures.Count }

    $junit = @($xml.SelectNodes('//testcase/failure'))
    if ($junit.Count -gt 0) { return $junit.Count }

    return 0
}

function Get-SessionOutcome {
    <#
    .SYNOPSIS
        Classify a completed session run into a single outcome enum.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TranscriptText,

        [Parameter(Mandatory = $true)]
        $Config,

        [int]$PendingTodoCount = -1,

        [int]$FailedTestCount = -1,

        [switch]$TimedOut
    )

    $immediateThreshold = 20
    if ($Config.PSObject.Properties.Name -contains 'immediateFailSeconds') {
        $immediateThreshold = [double]$Config.immediateFailSeconds
    }
    $nearImmediate = ($DurationSeconds -le $immediateThreshold)

    $text = if ($null -eq $TranscriptText) { '' } else { $TranscriptText }

    $outcome = $null
    $reason = ''

    if ($TimedOut.IsPresent) {
        $outcome = 'HANG'
        $reason = 'No output progress within the hang threshold.'
    }

    if ($null -eq $outcome -and $Config.PSObject.Properties.Name -contains 'failureRegex') {
        $rx = $Config.failureRegex
        foreach ($pair in @(@{ Key = 'crash'; Outcome = 'CRASH' }, @{ Key = 'quit'; Outcome = 'QUIT' })) {
            if ($null -ne $outcome) { break }
            if ($rx.PSObject.Properties.Name -notcontains $pair.Key) { continue }
            foreach ($pattern in @($rx.($pair.Key))) {
                if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
                if ($text -match $pattern) {
                    $outcome = $pair.Outcome
                    $reason = "Transcript matched $($pair.Key) pattern '$pattern'."
                    break
                }
            }
        }
    }

    if ($null -eq $outcome -and $ExitCode -ne 0) {
        $outcome = 'ERROR_EXIT'
        $reason = "Session exited with code $ExitCode."
    }

    if ($null -eq $outcome -and $FailedTestCount -gt 0) {
        $outcome = 'TEST_FAIL'
        $reason = "$FailedTestCount test(s) failed."
    }

    if ($null -eq $outcome -and $PendingTodoCount -gt 0) {
        $outcome = 'INCOMPLETE_TODOS'
        $reason = "$PendingTodoCount todo item(s) still open."
    }

    if ($null -eq $outcome -and ($PendingTodoCount -lt 0 -or $FailedTestCount -lt 0)) {
        $outcome = 'UNVERIFIED'
        $reason = 'Exit code 0 but todo state and/or test results could not be read.'
    }

    if ($null -eq $outcome) {
        $outcome = 'SUCCESS'
        $reason = 'Clean exit, no pending todos, no failing tests.'
    }

    return [pscustomobject]@{
        Outcome         = $outcome
        IsSuccess       = ($outcome -eq 'SUCCESS')
        NearImmediate   = $nearImmediate
        DurationSeconds = [math]::Round($DurationSeconds, 2)
        ExitCode        = $ExitCode
        PendingTodos    = $PendingTodoCount
        FailedTests     = $FailedTestCount
        Reason          = $reason
    }
}

function Get-SessionFailureSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Outcome,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TranscriptText,

        [int]$TailLines = 25
    )

    $text = if ($null -eq $TranscriptText) { '' } else { $TranscriptText }
    $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $tail = @()
    if ($lines.Count -gt 0) {
        $take = [math]::Min($TailLines, $lines.Count)
        $tail = @($lines[($lines.Count - $take)..($lines.Count - 1)])
    }

    $normalised = @()
    foreach ($line in $tail) {
        $n = $line.Trim()
        $n = [regex]::Replace($n, '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?', '<TS>')
        $n = [regex]::Replace($n, '\b\d{2}:\d{2}:\d{2}\b', '<TIME>')
        $n = [regex]::Replace($n, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<GUID>')
        $n = [regex]::Replace($n, '\b\d+\b', '<N>')
        $normalised += $n
    }

    $payload = "$Outcome|$ExitCode|" + ($normalised -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-NextRetryPlan {
    <#
    .SYNOPSIS
        Advance the retry ladder after a failed attempt.

    .DESCRIPTION
        Phases 0 and 1 are attempt-count driven (the first six Try Again presses,
        then the seventh with the steering comment). From phase 2 onward the
        ladder only escalates on near-immediate failures; a failure that took real
        work resets the ladder back to phase 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [int]$PhaseIndex,

        [Parameter(Mandatory = $true)]
        [int]$PhaseAttempt,

        [Parameter(Mandatory = $true)]
        [int]$TotalAttempts,

        [Parameter(Mandatory = $true)]
        [bool]$NearImmediate
    )

    $ladder = @($Config.ladder)
    $lastIndex = $ladder.Count - 1

    if ($PhaseIndex -lt 0) { $PhaseIndex = 0 }
    if ($PhaseIndex -gt $lastIndex) { $PhaseIndex = $lastIndex }

    $nextIndex = $PhaseIndex
    $nextAttempt = $PhaseAttempt
    $exhausted = $false
    $ladderReset = $false

    if ($PhaseIndex -ge 2 -and -not $NearImmediate) {
        $nextIndex = 0
        $nextAttempt = 0
        $ladderReset = $true
    }
    elseif ($PhaseAttempt -ge [int]$ladder[$PhaseIndex].maxAttempts) {
        if ($PhaseIndex -ge $lastIndex) {
            $exhausted = $true
        }
        else {
            $nextIndex = $PhaseIndex + 1
            $nextAttempt = 0
        }
    }

    $steeringFrom = 7
    if ($Config.PSObject.Properties.Name -contains 'steeringFromAttempt') {
        $steeringFrom = [int]$Config.steeringFromAttempt
    }

    $phase = $null
    $cursor = 0
    foreach ($candidate in $ladder) {
        if ($cursor -eq $nextIndex) {
            $phase = $candidate
            break
        }
        $cursor++
    }
    if ($null -eq $phase) {
        $phase = $ladder | Select-Object -First 1
    }
    $applySteering = (($TotalAttempts + 1) -ge $steeringFrom)

    return [pscustomobject]@{
        PhaseIndex    = $nextIndex
        PhaseName     = [string]$phase.name
        PhaseAttempt  = $nextAttempt
        DelaySeconds  = [int]$phase.delaySeconds
        ApplySteering = $applySteering
        LadderReset   = $ladderReset
        Exhausted     = $exhausted
    }
}

function Find-RetryableSession {
    <#
    .SYNOPSIS
        Find sessions that ran today and whose last recorded action was an error,
        failure or an offered "Try Again".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        $Config,

        [datetime]$Since = [datetime]::Today,

        [string[]]$AdditionalRoots = @(),

        [int]$TailLines = 60
    )

    $roots = @()
    if ($Config.PSObject.Properties.Name -contains 'sessionScanRoots') {
        foreach ($rel in @($Config.sessionScanRoots)) {
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $roots += (Join-Path $WorkspacePath $rel)
        }
    }
    foreach ($extra in @($AdditionalRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) { $roots += $extra }
    }

    $extensions = @('.log', '.json', '.txt')
    if ($Config.PSObject.Properties.Name -contains 'sessionScanExtensions') {
        $fromCfg = @($Config.sessionScanExtensions)
        if ($fromCfg.Count -gt 0) { $extensions = $fromCfg }
    }

    $maxFiles = 400
    if ($Config.PSObject.Properties.Name -contains 'sessionScanMaxFiles') {
        $maxFiles = [int]$Config.sessionScanMaxFiles
    }
    $maxBytes = 4096KB
    if ($Config.PSObject.Properties.Name -contains 'sessionScanMaxFileSizeKB') {
        $maxBytes = [int]$Config.sessionScanMaxFileSizeKB * 1KB
    }

    $candidates = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | # SIN-EXEMPT:P038 -- bounded by extension/date/size filters and max file cap
                Where-Object {
                    $_.LastWriteTime -ge $Since -and
                    $extensions -contains $_.Extension.ToLowerInvariant() -and
                    $_.Length -le $maxBytes -and
                    $_.Length -gt 0
                })
        $candidates += $found
    }

    $candidates = @($candidates | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt $maxFiles) {
        $candidates = @($candidates[0..($maxFiles - 1)])
    }

    $failPatterns = @()
    $tryAgainPatterns = @('try again', 'retry')
    if ($Config.PSObject.Properties.Name -contains 'failureRegex') {
        $rx = $Config.failureRegex
        foreach ($key in @('crash', 'quit', 'error')) {
            if ($rx.PSObject.Properties.Name -contains $key) {
                foreach ($p in @($rx.$key)) {
                    if (-not [string]::IsNullOrWhiteSpace($p)) { $failPatterns += $p }
                }
            }
        }
        if ($rx.PSObject.Properties.Name -contains 'tryAgain') {
            $fromCfg = @($rx.tryAgain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($fromCfg.Count -gt 0) { $tryAgainPatterns = $fromCfg }
        }
    }

    $results = @()
    foreach ($file in $candidates) {
        $lines = @()
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Tail $TailLines -ErrorAction Stop)
        }
        catch {
            continue
        }
        if ($lines.Count -eq 0) { continue }

        $tail = ($lines -join "`n")

        $matchedFail = $null
        foreach ($pattern in $failPatterns) {
            if ($tail -match $pattern) { $matchedFail = $pattern; break }
        }

        $offersTryAgain = $false
        foreach ($pattern in $tryAgainPatterns) {
            if ($tail -match $pattern) { $offersTryAgain = $true; break }
        }

        if ($null -eq $matchedFail -and -not $offersTryAgain) { continue }

        $lastLine = ''
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$i])) { $lastLine = $lines[$i].Trim(); break }
        }

        $score = 0
        if ($null -ne $matchedFail) { $score += 2 }
        if ($offersTryAgain) { $score += 3 }

        $recommendation = 'RESUME'
        if ($offersTryAgain) { $recommendation = 'TRY_AGAIN' }

        $results += [pscustomobject]@{
            SessionId      = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            Path           = $file.FullName
            LastWriteTime  = $file.LastWriteTime
            LastAction     = $lastLine
            FailurePattern = $matchedFail
            OffersTryAgain = $offersTryAgain
            Recommendation = $recommendation
            Score          = $score
        }
    }

    return @($results | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true })
}

function Show-SessionLoopDecision {
    <#
    .SYNOPSIS
        Modal decision box shown when a failure signature repeats N times.

    .DESCRIPTION
        Each option is a full-width button with a hover tooltip describing exactly
        what it does. Returns the chosen option key, or 'TIMEOUT' if the operator
        did not answer inside -TimeoutSeconds, or 'HEADLESS' when no desktop is
        available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [array]$Options,

        [int]$TimeoutSeconds = 900,

        [switch]$NonInteractive
    )

    if ($NonInteractive.IsPresent -or [Environment]::UserInteractive -eq $false) {
        return 'HEADLESS'
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        return 'HEADLESS'
    }

    $choice = 'TIMEOUT'

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(560, (150 + (46 * @($Options).Count)))

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point(16, 14)
    $label.Size = New-Object System.Drawing.Size(528, 96)
    $form.Controls.Add($label)

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 20000
    $tip.InitialDelay = 250
    $tip.ReshowDelay = 100
    $tip.ShowAlways = $true

    $y = 118
    foreach ($opt in @($Options)) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = [string]$opt.Label
        $button.Location = New-Object System.Drawing.Point(16, $y)
        $button.Size = New-Object System.Drawing.Size(528, 38)
        $button.Tag = [string]$opt.Key
        $tip.SetToolTip($button, [string]$opt.Description)
        $button.Add_Click({ # SIN-EXEMPT:P029 -- handler body is wrapped in try/catch
                try {
                    $script:SessionLoopDecisionChoice = [string]$this.Tag
                    $this.FindForm().Close()
                }
                catch {
                    Write-Verbose "Decision button click failed: $($_.Exception.Message)"
                }
            })
        $form.Controls.Add($button)
        $y += 46
    }

    $script:SessionLoopDecisionChoice = 'TIMEOUT'

    $timer = New-Object System.Windows.Forms.Timer
    if ($TimeoutSeconds -gt 0) {
        $timer.Interval = ($TimeoutSeconds * 1000)
        $timer.Add_Tick({ # SIN-EXEMPT:P029 -- handler body is wrapped in try/catch
                try {
                    $this.Stop()
                    $script:SessionLoopDecisionChoice = 'TIMEOUT'
                    [System.Windows.Forms.Application]::OpenForms | ForEach-Object { $_.Close() }
                }
                catch {
                    Write-Verbose "Decision timeout tick failed: $($_.Exception.Message)"
                }
            })
        $timer.Start()
    }

    try {
        [void]$form.ShowDialog()
        $choice = $script:SessionLoopDecisionChoice
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
        $tip.Dispose()
        $form.Dispose()
    }

    return $choice
}

Export-ModuleMember -Function @( # SIN-EXEMPT:P044 -- exports are covered by tests\Invoke-SessionResilienceLoop.Tests.ps1
    'Get-SessionLoopConfig',
    'Get-PendingTodoCount',
    'Get-FailedTestCount',
    'Get-SessionOutcome',
    'Get-SessionFailureSignature',
    'Get-NextRetryPlan',
    'Find-RetryableSession',
    'Show-SessionLoopDecision'
)
