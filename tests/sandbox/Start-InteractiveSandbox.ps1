# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Launches a persistent Windows Sandbox for interactive, iterative GUI testing.
.DESCRIPTION
    Generates a .wsb configuration with three mapped folders:
      - Source (read-only):  The PwShGUI workspace
      - Commands (read-write): Host sends iteration commands here
      - Output (read-write):   Sandbox writes results/logs here

    Inside the sandbox, a bootstrap script copies the workspace locally,
    then enters a polling loop waiting for command files. From the host,
    use Send-SandboxCommand.ps1 to iterate: sync code, run tests, launch
    the GUI, execute ad-hoc commands -- all without recreating the sandbox.

.PARAMETER WorkspacePath
    Root of the PwShGUI workspace. Defaults to parent of tests folder.
.PARAMETER SessionName
    Name for this sandbox session. Used in folder naming.
.PARAMETER MemoryMB
    Sandbox memory allocation in MB (default: 4096).
.PARAMETER Networking
    Enable or Disable sandbox networking (default: Disable for isolation).
.PARAMETER vGPU
    Enable or Disable GPU passthrough (default: Enable for WinForms rendering).
.PARAMETER AutoLaunchGUI
    Automatically launch Main-GUI.ps1 after bootstrap completes.
.PARAMETER MaxIdleMinutes
    Auto-shutdown sandbox after this many idle minutes (default: 120).
.PARAMETER NoWait
    Return immediately after launching sandbox (don't monitor).

.EXAMPLE
    .\tests\sandbox\Start-InteractiveSandbox.ps1
    Launches sandbox with defaults, waits for it to become ready.

.EXAMPLE
    .\tests\sandbox\Start-InteractiveSandbox.ps1 -AutoLaunchGUI -Networking Enable
    Launches sandbox, auto-opens the GUI, with network enabled.

.NOTES
    Author   : The Establishment
    Requires : Windows 10/11 Pro/Enterprise, Windows Sandbox feature enabled
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$SessionName = 'interactive',
    [int]$MemoryMB = 4096,
    [ValidateSet('Enable', 'Disable')]
    [string]$Networking = 'Disable',
    [ValidateSet('Enable', 'Disable')]
    [string]$vGPU = 'Enable',
    [switch]$AutoLaunchGUI,
    [int]$MaxIdleMinutes = 120,
    [switch]$NoWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ========================== RESOLVE PATHS ==========================
if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
}
if (-not (Test-Path (Join-Path $WorkspacePath 'Main-GUI.ps1'))) {
    Write-Host "[FAIL] Main-GUI.ps1 not found in: $WorkspacePath" -ForegroundColor Red
    Write-Host "       Specify -WorkspacePath to the PwShGUI root folder." -ForegroundColor DarkGray
    exit 1
}

$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir  = Join-Path $WorkspacePath "temp\sandbox-$SessionName-$timestamp"
$commandDir  = Join-Path $sessionDir 'cmd'
$outputDir   = Join-Path $sessionDir 'output'
$bootstrapDir = Join-Path $sessionDir 'bootstrap'

New-Item -ItemType Directory -Path $commandDir -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

# ========================== BANNER ==========================
Write-Host ""
Write-Host ("=" * 68) -ForegroundColor Cyan
Write-Host "  PwShGUI Interactive Sandbox Launcher" -ForegroundColor Yellow
Write-Host ("=" * 68) -ForegroundColor Cyan
Write-Host ""

# ========================== PREREQUISITE CHECKS ==========================
$sandboxExe = $null
$cmdResult = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
if ($cmdResult) {
    $sandboxExe = $cmdResult.Source
} else {
    $fallback = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (Test-Path $fallback) {
        $sandboxExe = $fallback
    }
}
if (-not $sandboxExe) {
    Write-Host "[FAIL] WindowsSandbox.exe not found." -ForegroundColor Red
    Write-Host "       Enable: Settings > Apps > Optional Features > More Windows Features > Windows Sandbox" -ForegroundColor DarkGray
    Write-Host "       Requires Windows 10/11 Pro or Enterprise." -ForegroundColor DarkGray
    exit 1
}
Write-Host "[OK] Sandbox:   $sandboxExe" -ForegroundColor Green
Write-Host "[OK] Workspace: $WorkspacePath" -ForegroundColor Green
Write-Host "[OK] Session:   $sessionDir" -ForegroundColor Green
Write-Host "[OK] Isolation:  Network=$Networking  vGPU=$vGPU  Memory=${MemoryMB}MB" -ForegroundColor Green
Write-Host ""

# ========================== COPY BOOTSTRAP SCRIPT ==========================
$srcBootstrap = Join-Path $WorkspacePath 'tests\sandbox\Invoke-SandboxBootstrap.ps1'
if (-not (Test-Path $srcBootstrap)) {
    Write-Host "[FAIL] Bootstrap script not found: $srcBootstrap" -ForegroundColor Red
    exit 1
}
Copy-Item $srcBootstrap $bootstrapDir -Force

# ========================== GENERATE WSB CONFIG ==========================
$sandboxWS  = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source'
$sandboxCmd = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Cmd'
$sandboxOut = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output'
$sandboxBS  = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Bootstrap'

# Build logon command
$logonArgs = "-NoProfile -ExecutionPolicy Bypass -File $sandboxBS\Invoke-SandboxBootstrap.ps1"
$logonArgs += " -MaxIdleMinutes $MaxIdleMinutes"

$wsbXml = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$WorkspacePath</HostFolder>
      <SandboxFolder>$sandboxWS</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$commandDir</HostFolder>
      <SandboxFolder>$sandboxCmd</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$outputDir</HostFolder>
      <SandboxFolder>$sandboxOut</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$bootstrapDir</HostFolder>
      <SandboxFolder>$sandboxBS</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe $logonArgs</Command>
  </LogonCommand>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <Networking>$Networking</Networking>
  <vGPU>$vGPU</vGPU>
</Configuration>
"@

$wsbPath = Join-Path $sessionDir "PwShGUI-$SessionName-$timestamp.wsb"
Set-Content -Path $wsbPath -Value $wsbXml -Encoding UTF8
Write-Host "[OK] WSB config: $wsbPath" -ForegroundColor Green

# ========================== SAVE SESSION METADATA ==========================
$sessionMeta = @{
    sessionName   = $SessionName
    timestamp     = $timestamp
    workspacePath = $WorkspacePath
    sessionDir    = $sessionDir
    commandDir    = $commandDir
    outputDir     = $outputDir
    wsbPath       = $wsbPath
    networking    = $Networking
    memoryMB      = $MemoryMB
    vGPU          = $vGPU
    maxIdleMin    = $MaxIdleMinutes
}
$metaPath = Join-Path $sessionDir 'session-meta.json'
ConvertTo-Json $sessionMeta -Depth 5 | Set-Content $metaPath -Encoding UTF8

# ========================== LAUNCH ==========================
Write-Host ""
Write-Host "[Launch] Starting Windows Sandbox..." -ForegroundColor Cyan
$sandboxProc = Start-Process $sandboxExe -ArgumentList "`"$wsbPath`"" -PassThru
Write-Host "[Launch] Sandbox PID: $($sandboxProc.Id)" -ForegroundColor Green

# ========================== WAIT FOR READY ==========================
if (-not $NoWait) {
    Write-Host ""
    Write-Host "[Wait] Waiting for sandbox to become READY..." -ForegroundColor DarkGray

    # Load waiting jokes for long-wait entertainment
    $waitJokes = @()
    $jokesPath = Join-Path $WorkspacePath 'config\waiting-jokes.json'
    if (Test-Path $jokesPath) {
        try {
            $jokeData = Get-Content $jokesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $waitJokes = @($jokeData.jokes)
        } catch { <# Intentional: jokes are optional #> }
    }
    $jokeIdx = 0
    function Show-SandboxWaitJoke {
        param([array]$Jokes, [ref]$Idx)
        if (@($Jokes).Count -eq 0) { return }
        $j = @($Jokes)[$Idx.Value % @($Jokes).Count]
        $Idx.Value++
        Write-Host ''
        Write-Host ('  +' + ('─' * 64) + '+') -ForegroundColor DarkCyan
        Write-Host ('  |  Sandbox Patience Theatre  ').PadRight(66) + '|' -ForegroundColor DarkCyan
        Write-Host ('  +' + ('─' * 64) + '+') -ForegroundColor DarkCyan
        $words = $j -split ' '; $line = ''; $lineLen = 0
        foreach ($w in $words) {
            if (($lineLen + $w.Length + 1) -gt 62) {
                Write-Host ('  | ' + $line.TrimEnd()).PadRight(66) + '|' -ForegroundColor Cyan
                $line = $w + ' '; $lineLen = $w.Length + 1
            } else { $line += $w + ' '; $lineLen += $w.Length + 1 }
        }
        if ($line.Trim()) { Write-Host ('  | ' + $line.TrimEnd()).PadRight(66) + '|' -ForegroundColor Cyan }
        Write-Host ('  +' + ('─' * 64) + '+') -ForegroundColor DarkCyan
        Write-Host ''
    }

    $statusFile  = Join-Path $outputDir 'sandbox-status.json'
    $maxWaitSec  = 300
    $elapsed     = 0
    $interval    = 3
    $jokeStart   = 90    # start jokes at 1 min 30 sec
    $jokeEvery   = 30    # one joke every 30 seconds after that
    $lastJokeSec = 0
    $ready       = $false

    while ($elapsed -lt $maxWaitSec) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        if (Test-Path $statusFile) {
            try {
                $status = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($status.status -eq 'READY') {
                    $ready = $true
                    break
                }
                if ($status.status -eq 'ERROR') {
                    Write-Host "[FAIL] Sandbox bootstrap error: $($status.detail)" -ForegroundColor Red
                    exit 1
                }
            } catch {
                # Status file being written, retry
            }
        }
        # Check if sandbox VM is actually running
        $sandboxAlive = ($null -ne (Get-Process WindowsSandbox -ErrorAction SilentlyContinue)) -or
                        ($null -ne (Get-Process vmwp -ErrorAction SilentlyContinue))
        if (-not $sandboxAlive -and -not $sandboxProc.HasExited) { $sandboxAlive = $true }
        if (-not $sandboxAlive) {
            Write-Host "[FAIL] Sandbox exited unexpectedly (no WindowsSandbox or vmwp process found)." -ForegroundColor Red
            exit 1
        }
        if (($elapsed % 15) -eq 0) {
            Write-Host "  ... waiting (${elapsed}s / ${maxWaitSec}s)" -ForegroundColor DarkGray
        }
        # Joke mode: 90s onwards, every $jokeEvery seconds
        if ($elapsed -ge $jokeStart -and ($elapsed - $lastJokeSec) -ge $jokeEvery) {
            $lastJokeSec = $elapsed
            Show-SandboxWaitJoke -Jokes $waitJokes -Idx ([ref]$jokeIdx)
        }
    }

    if ($ready) {
        Write-Host "[OK] Sandbox is READY (${elapsed}s)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Sandbox did not report READY within ${maxWaitSec}s (may still be starting)" -ForegroundColor Yellow
    }

    # Auto-launch GUI if requested
    if ($AutoLaunchGUI -and $ready) {
        Write-Host "[Auto] Sending GUI launch command..." -ForegroundColor Cyan
        $guiCmd = @{
            action    = 'GUI'
            params    = @{ mode = 'quik_jnr' }
            timestamp = (Get-Date -Format 'o')
        }
        $guiCmdPath = Join-Path $commandDir "$(Get-Date -Format 'yyyyMMddHHmmss')-001.cmd.json"
        ConvertTo-Json $guiCmd -Depth 5 | Set-Content $guiCmdPath -Encoding UTF8
        Write-Host "[Auto] GUI launch command sent." -ForegroundColor Green
    }
}

# ========================== USAGE INSTRUCTIONS ==========================
Write-Host ""
Write-Host ("=" * 68) -ForegroundColor Cyan
Write-Host "  Sandbox is running. Iterate using Send-SandboxCommand.ps1:" -ForegroundColor Yellow
Write-Host ("=" * 68) -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Sync code changes into sandbox:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Sync" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Run headless smoke tests:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Test" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Launch GUI interactively (visible in sandbox window):" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action GUI" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Stop the running GUI:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action StopGUI" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Run chaos tests:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Chaos" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Execute custom command inside sandbox:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Exec -Command 'Get-Process'" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Full iteration cycle (sync + test + launch GUI):" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Iterate" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Shut down sandbox:" -ForegroundColor White
Write-Host "  .\tests\sandbox\Send-SandboxCommand.ps1 -SessionDir '$sessionDir' -Action Shutdown" -ForegroundColor Gray
Write-Host ""
Write-Host "  Results/logs: $outputDir" -ForegroundColor DarkGray
Write-Host ""

# Return session info for scripting
[PSCustomObject]@{
    SessionName = $SessionName
    Timestamp   = $timestamp
    SessionDir  = $sessionDir
    CommandDir  = $commandDir
    OutputDir   = $outputDir
    WsbPath     = $wsbPath
    SandboxPID  = $sandboxProc.Id
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




