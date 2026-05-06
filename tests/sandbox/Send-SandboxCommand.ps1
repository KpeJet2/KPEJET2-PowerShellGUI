# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Sends iteration commands to a running Windows Sandbox session.
.DESCRIPTION
    Writes command files to the shared command folder that the sandbox
    bootstrap script polls and executes. Waits for results and displays them.

    Supported actions:
      Sync     - Re-sync workspace changes into sandbox
      Test     - Run headless smoke tests
      GUI      - Launch Main-GUI.ps1 interactively in sandbox
      StopGUI  - Stop the running GUI process
      Chaos    - Run chaos test conditions
      Exec     - Execute a custom PowerShell command
      Iterate  - Full cycle: Sync + Test + GUI
      Status   - Check sandbox status (no command sent)
      Shutdown - Gracefully shut down the sandbox

.PARAMETER SessionDir
    Path to the sandbox session directory (printed by Start-InteractiveSandbox).
.PARAMETER Action
    The action to perform.
.PARAMETER Command
    PowerShell command string (for -Action Exec).
.PARAMETER GUIMode
    Startup mode for GUI launch: quik_jnr or slow_snr (default: quik_jnr).
.PARAMETER Headless
    For Test action: run only headless tests (no GUI phases).
.PARAMETER SkipPhase
    For Test action: phase numbers to skip.
.PARAMETER WaitTimeout
    Seconds to wait for a result (default: 300).
.PARAMETER NoWait
    Send command and return immediately without waiting for result.

.EXAMPLE
    .\Send-SandboxCommand.ps1 -SessionDir 'C:\PowerShellGUI\temp\sandbox-interactive-20260404-100000' -Action Sync

.EXAMPLE
    .\Send-SandboxCommand.ps1 -SessionDir $s.SessionDir -Action Iterate

.NOTES
    Author : The Establishment
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SessionDir,

    [Parameter(Mandatory)]
    [ValidateSet('Sync', 'Test', 'GUI', 'StopGUI', 'Chaos', 'Exec', 'Iterate', 'Status', 'Shutdown')]
    [string]$Action,

    [string]$Command,
    [ValidateSet('quik_jnr', 'slow_snr')]
    [string]$GUIMode = 'quik_jnr',
    [switch]$Headless,
    [int[]]$SkipPhase = @(),
    [int]$WaitTimeout = 300,
    [switch]$NoWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ========================== VALIDATE SESSION ==========================
$commandDir = Join-Path $SessionDir 'cmd'
$outputDir  = Join-Path $SessionDir 'output'

if (-not (Test-Path $SessionDir)) {
    Write-Host "[FAIL] Session directory not found: $SessionDir" -ForegroundColor Red
    Write-Host "       Run Start-InteractiveSandbox.ps1 first." -ForegroundColor DarkGray
    exit 1
}
if (-not (Test-Path $commandDir)) {
    Write-Host "[FAIL] Command directory not found: $commandDir" -ForegroundColor Red
    exit 1
}

# ========================== STATUS CHECK ==========================
$statusFile = Join-Path $outputDir 'sandbox-status.json'
function Show-SandboxStatus {
    if (Test-Path $statusFile) {
        try {
            $st = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $color = switch ($st.status) {
                'READY'       { 'Green' }
                'RUNNING'     { 'Cyan' }
                'ERROR'       { 'Red' }
                'SHUTDOWN'    { 'DarkGray' }
                'IDLE_TIMEOUT'{ 'Yellow' }
                default       { 'White' }
            }
            Write-Host "[Sandbox] Status=$($st.status)  Detail=$($st.detail)  Time=$($st.timestamp)" -ForegroundColor $color
            return $st.status
        } catch {
            Write-Host "[Sandbox] Status file unreadable." -ForegroundColor Yellow
            return 'UNKNOWN'
        }
    } else {
        Write-Host "[Sandbox] No status file yet -- sandbox may still be starting." -ForegroundColor Yellow
        return 'UNKNOWN'
    }
}

if ($Action -eq 'Status') {
    Show-SandboxStatus | Out-Null
    # Also show recent results
    $results = Get-ChildItem $outputDir -Filter '*.result.json' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 5
    if (@($results).Count -gt 0) {
        Write-Host ""
        Write-Host "[Recent Results]" -ForegroundColor Cyan
        foreach ($r in $results) {
            try {
                $rd = Get-Content $r.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-Host "  $($rd.cmdId): $($rd.action) -> $(ConvertTo-Json $rd.result -Depth 3 -Compress)" -ForegroundColor Gray
            } catch {
                Write-Host "  $($r.Name): (parse error)" -ForegroundColor DarkGray
            }
        }
    }
    exit 0
}

# Check sandbox is alive
$currentStatus = Show-SandboxStatus
if ($currentStatus -in @('SHUTDOWN', 'IDLE_TIMEOUT', 'ERROR')) {
    Write-Host "[WARN] Sandbox is $currentStatus. Command may not be processed." -ForegroundColor Yellow
}

# ========================== SEND COMMAND(S) ==========================
function Send-SingleCommand {
    param(
        [string]$CmdAction,
        [hashtable]$CmdParams = @{},
        [int]$Sequence = 1
    )
    $cmdId = "$(Get-Date -Format 'yyyyMMddHHmmss')-$($Sequence.ToString('D3'))"
    $cmdObj = @{
        action    = $CmdAction
        params    = $CmdParams
        timestamp = (Get-Date -Format 'o')
    }
    $cmdPath = Join-Path $commandDir "$cmdId.cmd.json"
    ConvertTo-Json $cmdObj -Depth 5 | Set-Content $cmdPath -Encoding UTF8
    Write-Host "[Sent] $CmdAction -> $cmdId" -ForegroundColor Cyan
    return $cmdId
}

function Wait-ForResult {
    param([string]$CmdId, [int]$TimeoutSec)
    $resultPath = Join-Path $outputDir "$CmdId.result.json"
    $elapsed = 0
    $interval = 2
    while ($elapsed -lt $TimeoutSec) {
        if (Test-Path $resultPath) {
            try {
                $result = Get-Content $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                return $result
            } catch {
                Start-Sleep -Seconds 1
                $elapsed += 1
                continue
            }
        }
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        if (($elapsed % 30) -eq 0) {
            Write-Host "  ... waiting for result (${elapsed}s / ${TimeoutSec}s)" -ForegroundColor DarkGray
        }
    }
    Write-Host "[TIMEOUT] No result within ${TimeoutSec}s for $CmdId" -ForegroundColor Yellow
    return $null
}

function Show-Result {
    param($Result)
    if (-not $Result) { return }
    $detail = $Result.result
    Write-Host ""
    Write-Host "[Result] Action=$($Result.action)  Iteration=$($Result.iteration)  Time=$($Result.timestamp)" -ForegroundColor Green
    if ($detail) {
        $detailJson = ConvertTo-Json $detail -Depth 5
        Write-Host $detailJson -ForegroundColor Gray
    }
    Write-Host ""
}

# Handle composite actions
if ($Action -eq 'Iterate') {
    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  Iteration Cycle: Sync -> Test -> GUI" -ForegroundColor Yellow
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Sync
    $syncId = Send-SingleCommand -CmdAction 'Sync' -Sequence 1
    if (-not $NoWait) {
        $syncResult = Wait-ForResult -CmdId $syncId -TimeoutSec 60
        Show-Result $syncResult
    }

    # Step 2: Test (headless)
    $testParams = @{ headless = $true }
    $testId = Send-SingleCommand -CmdAction 'Test' -CmdParams $testParams -Sequence 2
    if (-not $NoWait) {
        $testResult = Wait-ForResult -CmdId $testId -TimeoutSec $WaitTimeout
        Show-Result $testResult
        if ($testResult -and $testResult.result -and $testResult.result.exitCode -ne 0) {
            Write-Host "[WARN] Tests did not pass (exit=$($testResult.result.exitCode)). Skipping GUI launch." -ForegroundColor Yellow
            Write-Host "       Fix issues and re-run: -Action Iterate" -ForegroundColor DarkGray
            exit $testResult.result.exitCode
        }
    }

    # Step 3: Launch GUI
    $guiId = Send-SingleCommand -CmdAction 'GUI' -CmdParams @{ mode = $GUIMode } -Sequence 3
    if (-not $NoWait) {
        $guiResult = Wait-ForResult -CmdId $guiId -TimeoutSec 30
        Show-Result $guiResult
    }

    Write-Host "[Iterate] Cycle complete. GUI should be visible in the sandbox window." -ForegroundColor Green
    exit 0
}

# Single action
$params = @{}
switch ($Action) {
    'Test' {
        $params = @{ headless = [bool]$Headless }
        if (@($SkipPhase).Count -gt 0) { $params.skipPhase = $SkipPhase }
    }
    'GUI'      { $params = @{ mode = $GUIMode } }
    'Exec'     {
        if (-not $Command) {
            Write-Host "[FAIL] -Command required for Exec action." -ForegroundColor Red
            exit 1
        }
        $params = @{ command = $Command }
    }
}

$cmdId = Send-SingleCommand -CmdAction $Action -CmdParams $params

if ($NoWait) {
    Write-Host "[Sent] Command dispatched (no wait). Check results later with -Action Status" -ForegroundColor Green
    exit 0
}

$result = Wait-ForResult -CmdId $cmdId -TimeoutSec $WaitTimeout
Show-Result $result

if ($result -and $result.result -and $null -ne $result.result.exitCode) {
    exit $result.result.exitCode
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





