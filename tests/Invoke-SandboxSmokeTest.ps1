# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Launches a Windows Sandbox instance for isolated PwShGUI smoke testing.
.DESCRIPTION
    Generates a .wsb configuration file, maps the workspace into the sandbox
    as a read-only folder, and bootstraps a smoke test run inside a clean
    Windows Sandbox environment. Optionally includes chaos conditions.
    Requirements: Windows 10/11 Pro/Enterprise, Windows Sandbox enabled.
.PARAMETER WorkspacePath
    Root of the PwShGUI workspace.
.PARAMETER OutputPath
    Where to collect results on the host (default: logs\sandbox-results).
.PARAMETER ChaosMode
    Also run chaos conditions inside the sandbox.
.PARAMETER ChaosConditions
    Specific chaos conditions to apply (default: all). Only with -ChaosMode.
.PARAMETER HeadlessOnly
    Pass -HeadlessOnly to the smoke test inside the sandbox.
.PARAMETER KeepSandbox
    Do not auto-close the sandbox after test completion.
.PARAMETER Timeout
    Maximum seconds to wait for the sandbox process (default: 600).
.PARAMETER SkipPS7Install
    Skip PowerShell 7 installation inside the sandbox.
#>
param(
    [string]$WorkspacePath,
    [string]$OutputPath,
    [switch]$ChaosMode,
    [string[]]$ChaosConditions,
    [switch]$HeadlessOnly,
    [switch]$KeepSandbox,
    [int]$Timeout = 600,
    [switch]$SkipPS7Install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $WorkspacePath 'logs\sandbox-results'
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# -- Prerequisite checks
Write-Host "`n$("=" * 68)" -ForegroundColor Magenta
Write-Host "  WINDOWS SANDBOX SMOKE TEST LAUNCHER" -ForegroundColor Yellow
Write-Host "$("=" * 68)`n" -ForegroundColor Magenta

$sandboxExe = Get-Command WindowsSandbox.exe -EA SilentlyContinue
if (-not $sandboxExe) {
    $sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not (Test-Path $sandboxExe)) {
        Write-Host "[FAIL] WindowsSandbox.exe not found." -ForegroundColor Red
        Write-Host "       Enable via Settings > Apps > Optional Features > More Windows Features" -ForegroundColor DarkGray
        exit 1
    }
} else { $sandboxExe = $sandboxExe.Source }
Write-Host "[OK] WindowsSandbox.exe: $sandboxExe" -ForegroundColor Green

if (-not (Test-Path (Join-Path $WorkspacePath 'Main-GUI.ps1'))) {
    Write-Host "[FAIL] Main-GUI.ps1 not found in: $WorkspacePath" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Workspace: $WorkspacePath" -ForegroundColor Green

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
Write-Host "[OK] Output: $OutputPath" -ForegroundColor Green

# -- Generate bootstrap script (runs INSIDE sandbox)
$sandboxWS  = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source'
$sandboxOut = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output'
$sandboxBS  = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Bootstrap'
$localCopy  = 'C:\PwShGUI-Test'

$bsLines = @(
    '$ErrorActionPreference = "Continue"'
    '$logFile = "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output\sandbox-bootstrap.log"'
    'function Write-Log { param([string]$Msg); $line = "[$(Get-Date -Format HH:mm:ss)] $Msg"; Write-Host $line; Add-Content $logFile $line -Encoding UTF8 -EA SilentlyContinue }'
    'New-Item -ItemType Directory -Path "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output" -Force -EA SilentlyContinue | Out-Null'
    'Write-Log "Sandbox bootstrap starting..."'
    'Write-Log "PSVersion: $($PSVersionTable.PSVersion)"'
    'Write-Log "Copying workspace to local writable path..."'
    'Copy-Item "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source" "C:\PwShGUI-Test" -Recurse -Force -EA SilentlyContinue'
    'Write-Log "Copy complete."'
    'Set-ExecutionPolicy Bypass -Scope Process -Force'
)

# Smoke test command
$bsLines += '$smokeScript = "C:\PwShGUI-Test\tests\Invoke-GUISmokeTest.ps1"'
$bsLines += 'if (Test-Path $smokeScript) {'
$bsLines += '    Write-Log "Running smoke test (HeadlessOnly)..."'
$bsLines += '    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$smokeScript`" -HeadlessOnly" -Wait -PassThru -NoNewWindow'
$bsLines += '    Write-Log "Smoke test exit code: $($p.ExitCode)"'
$bsLines += '    $logDir = "C:\PwShGUI-Test\logs"'
$bsLines += '    if (Test-Path $logDir) { Copy-Item "$logDir\*" "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output" -Force -EA SilentlyContinue }'
$bsLines += '} else { Write-Log "ERROR: Smoke test script not found!" }'

# Chaos test command (conditional)
if ($ChaosMode) {
    $bsLines += '$chaosScript = "C:\PwShGUI-Test\tests\Invoke-ChaosTestConditions.ps1"'
    $bsLines += 'if (Test-Path $chaosScript) {'
    $bsLines += '    Write-Log "Running chaos conditions..."'
    $bsLines += '    $cp = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$chaosScript`" -WorkspacePath C:\PwShGUI-Test -RunSmokeTest -HeadlessOnly" -Wait -PassThru -NoNewWindow'
    $bsLines += '    Write-Log "Chaos test exit code: $($cp.ExitCode)"'
    $bsLines += '    Copy-Item "C:\PwShGUI-Test\logs\*Chaos*" "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output" -Force -EA SilentlyContinue'
    $bsLines += '} else { Write-Log "Chaos test script not found." }'
}

# Completion signal
$bsLines += 'Set-Content "C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output\DONE.flag" "complete" -Encoding UTF8'
$bsLines += 'Write-Log "Sandbox tests complete."'
if (-not $KeepSandbox) {
    $bsLines += 'Write-Log "Auto-closing in 10 seconds..."'
    $bsLines += 'Start-Sleep -Seconds 10'
}

# Write bootstrap to disk
$bootstrapDir = Join-Path $OutputPath "sandbox-run-$timestamp"
New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
$bootstrapPath = Join-Path $bootstrapDir 'sandbox-bootstrap.ps1'
$bsLines | Out-File $bootstrapPath -Encoding UTF8
Write-Host "[OK] Bootstrap script: $bootstrapPath" -ForegroundColor Green

# -- Generate .wsb configuration
$networkTag = if ($SkipPS7Install) { 'Disable' } else { 'Enable' }
$wsbXml = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$WorkspacePath</HostFolder>
      <SandboxFolder>$sandboxWS</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$bootstrapDir</HostFolder>
      <SandboxFolder>$sandboxBS</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$OutputPath</HostFolder>
      <SandboxFolder>$sandboxOut</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sandboxBS\sandbox-bootstrap.ps1</Command>
  </LogonCommand>
  <MemoryInMB>4096</MemoryInMB>
  <Networking>$networkTag</Networking>
</Configuration>
"@

$wsbPath = Join-Path $bootstrapDir "PwShGUI-SmokeTest-$timestamp.wsb"
$wsbXml | Out-File $wsbPath -Encoding UTF8
Write-Host "[OK] WSB config: $wsbPath" -ForegroundColor Green

# -- Launch sandbox
Write-Host "`n[Launch] Starting Windows Sandbox..." -ForegroundColor Cyan
$sandboxProc = Start-Process $sandboxExe -ArgumentList "`"$wsbPath`"" -PassThru

# -- Load waiting jokes for long-wait entertainment
$script:_WaitJokes = @()
$jokesPath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'config\waiting-jokes.json'
if (Test-Path $jokesPath) {
    try {
        $jokeData = Get-Content $jokesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:_WaitJokes = @($jokeData.jokes)
        Write-Host "[Init] Loaded $(@($script:_WaitJokes).Count) waiting jokes." -ForegroundColor DarkGray
    } catch { <# Intentional: jokes are optional #> }
}
$script:_JokeIndex = 0
function Show-WaitJoke {
    if (@($script:_WaitJokes).Count -eq 0) { return }
    $j = @($script:_WaitJokes)[$script:_JokeIndex % @($script:_WaitJokes).Count]
    $script:_JokeIndex++
    Write-Host ''
    Write-Host '  +' + ('─' * 64) + '+' -ForegroundColor DarkCyan
    Write-Host ('  | ' + '  Waiting Room Wisdom  ').PadRight(66) + '|' -ForegroundColor DarkCyan
    Write-Host '  +' + ('─' * 64) + '+' -ForegroundColor DarkCyan
    # Word-wrap at 62 chars
    $words = $j -split ' '
    $line = ''; $lineLen = 0
    foreach ($w in $words) {
        if (($lineLen + $w.Length + 1) -gt 62) {
            Write-Host ('  | ' + $line.TrimEnd()).PadRight(66) + '|' -ForegroundColor Cyan
            $line = $w + ' '; $lineLen = $w.Length + 1
        } else { $line += $w + ' '; $lineLen += $w.Length + 1 }
    }
    if ($line.Trim()) { Write-Host ('  | ' + $line.TrimEnd()).PadRight(66) + '|' -ForegroundColor Cyan }
    Write-Host '  +' + ('─' * 64) + '+' -ForegroundColor DarkCyan
    Write-Host ''
}

# Poll for completion
$doneFlag   = Join-Path $OutputPath 'DONE.flag'
$elapsed    = 0
$interval   = 5
$jokeEvery  = 30                    # show a joke every N seconds once joke-mode active
$jokeStart  = 90                    # start jokes after 90 seconds (1m30s)
$lastJokeSec = 0
Write-Host "[Wait] Polling for completion (timeout: ${Timeout}s)..." -ForegroundColor DarkGray
while ($elapsed -lt $Timeout) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    if (Test-Path $doneFlag) {
        Write-Host "[Done] Tests completed. (${elapsed}s)" -ForegroundColor Green
        Remove-Item $doneFlag -Force -EA SilentlyContinue
        break
    }
    # NOTE: WindowsSandbox.exe is a thin launcher that exits ~5s after spawning the VM.
    # Do NOT treat $sandboxProc.HasExited as completion. Instead, only break early once
    # the sandbox VM client itself is gone AND we're past a grace period.
    if ($elapsed -ge 30) {
        $vmProc = @(Get-Process -Name 'WindowsSandboxClient','WindowsSandboxRemoteSession','vmmemWindowsSandbox' -ErrorAction SilentlyContinue)
        if ($vmProc.Count -eq 0) {
            Write-Host "[Done] Sandbox VM no longer running. (${elapsed}s)" -ForegroundColor Yellow
            break
        }
    }
    # Regular progress tick
    if (($elapsed % 30) -eq 0) {
        Write-Host "  ... waiting (${elapsed}s / ${Timeout}s)" -ForegroundColor DarkGray
    }
    # Joke mode: 90 seconds onwards, every $jokeEvery seconds
    if ($elapsed -ge $jokeStart -and ($elapsed - $lastJokeSec) -ge $jokeEvery) {
        $lastJokeSec = $elapsed
        Show-WaitJoke
    }
}
if ($elapsed -ge $Timeout) { Write-Host "[TIMEOUT] Did not complete within ${Timeout}s." -ForegroundColor Red }

# -- Collect results
Write-Host "`n[Results] Checking sandbox output..." -ForegroundColor Cyan
$resultFiles = Get-ChildItem $OutputPath -File -EA SilentlyContinue
if ($resultFiles) {
    Write-Host "[Results] Files collected:" -ForegroundColor Green
    foreach ($f in $resultFiles) {
        $size = if ($f.Length -gt 1KB) { "$([math]::Round($f.Length/1KB,1))KB" } else { "$($f.Length)B" }
        Write-Host "  - $($f.Name)  ($size)"
    }
    $bsLog = Join-Path $OutputPath 'sandbox-bootstrap.log'
    if (Test-Path $bsLog) {
        Write-Host "`n[Bootstrap Log]" -ForegroundColor Cyan
        Get-Content $bsLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
} else { Write-Host "[Results] No output files -- sandbox may have failed." -ForegroundColor Yellow }

Write-Host "`n$("=" * 68)" -ForegroundColor Magenta
Write-Host "  SANDBOX SMOKE TEST COMPLETE" -ForegroundColor Yellow
Write-Host "  Results at: $OutputPath" -ForegroundColor White
Write-Host "$("=" * 68)`n" -ForegroundColor Magenta

[PSCustomObject]@{
    Timestamp    = $timestamp
    WsbConfig    = $wsbPath
    OutputPath   = $OutputPath
    ChaosMode    = [bool]$ChaosMode
    HeadlessOnly = [bool]$HeadlessOnly
    TimeoutUsed  = $elapsed
    ResultFiles  = @($resultFiles | Select-Object -ExpandProperty Name -EA SilentlyContinue)
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





