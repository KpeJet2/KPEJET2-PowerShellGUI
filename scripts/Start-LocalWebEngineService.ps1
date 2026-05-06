# VersionTag: 2604.B1.V32.1
# Start-LocalWebEngineService.ps1
# Manages the LocalWebEngine as a headless background service.
# Use -Action Start|Stop|Restart|Status (default: Start).
# PID file written to logs/engine.pid for status tracking.
#Requires -Version 5.1
<#
.SYNOPSIS
    Manages the PowerShellGUI Local Web Engine as a headless background service.
.DESCRIPTION
    Launches Start-LocalWebEngine.ps1 in a hidden PowerShell window so it runs
    independently of the calling terminal. Tracks the process via a PID file so
    that Status/Stop/Restart commands work across sessions.
.PARAMETER Action
    Start  — Launch the engine if not already running (default).
    Stop   — Kill the engine process and remove the PID file.
    Restart — Stop then Start.
    Status — Report whether the engine is running and respond on the port.
.PARAMETER Port
    Port the engine listens on (default: 8042).
.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.
.EXAMPLE
    .\Start-LocalWebEngineService.ps1 -Action Start
    .\Start-LocalWebEngineService.ps1 -Action Status
    .\Start-LocalWebEngineService.ps1 -Action Stop
#>
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Restart','Status')]
    [string]$Action        = 'Start',
    [int]   $Port          = 8042,
    [string]$WorkspacePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $ScriptDir -Parent
}

$EngineScript = Join-Path $ScriptDir 'Start-LocalWebEngine.ps1'
$LogsDir      = Join-Path $WorkspacePath 'logs'
$PidFile      = Join-Path $LogsDir 'engine.pid'
$LogFile      = Join-Path $LogsDir 'engine-service.log'

if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

# ─── Helpers ───────────────────────────────────────────────────────────────────
function Write-SvcLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    Write-Host $line -ForegroundColor $(if ($Level -eq 'ERROR') {'Red'} elseif ($Level -eq 'WARN') {'Yellow'} else {'Cyan'})
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { <# non-fatal #> }
}

function Get-EnginePid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8
        $n   = [int]$raw.Trim()
        return if ($n -gt 0) { $n } else { $null }
    } catch { return $null }
}

function Test-EngineRunning {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        return ($null -ne $proc -and -not $proc.HasExited)
    } catch { return $false }
}

function Test-EngineResponding {
    # Quick HTTP check — times out in 2s
    try {
        $req             = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/api/csrf-token")
        $req.Method      = 'GET'
        $req.Timeout     = 2000
        $resp            = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

function Stop-Engine {
    $eid = Get-EnginePid
    if ($null -ne $eid -and (Test-EngineRunning $eid)) {
        try {
            Stop-Process -Id $eid -Force -ErrorAction SilentlyContinue
            Write-SvcLog "Engine PID $eid stopped."
        } catch {
            Write-SvcLog "Could not stop PID $eid : $_" -Level 'WARN'
        }
    } else {
        Write-SvcLog "No running engine found to stop." -Level 'WARN'
    }
    if (Test-Path -LiteralPath $PidFile) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Start-Engine {
    if (-not (Test-Path -LiteralPath $EngineScript)) {
        Write-SvcLog "Engine script not found: $EngineScript" -Level 'ERROR'
        return $false
    }

    # Resolve config port if available
    $cfgFile = Join-Path $WorkspacePath 'config'
    $cfgFile = Join-Path $cfgFile 'dependency-scan-config.json'
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $cfgObj = (Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($null -ne $cfgObj -and $null -ne $cfgObj.port) { $Port = [int]$cfgObj.port }
        } catch { <# use default port #> }
    }

    # Check already running
    $eid = Get-EnginePid
    if ($null -ne $eid -and (Test-EngineRunning $eid)) {
        Write-SvcLog "Engine is already running (PID $eid, port $Port)."
        return $true
    }

    # Launch headless, redirecting stdout+stderr to log files (P010: & operator, not iex)
    $engLogFile = Join-Path $LogsDir 'engine-stdout.log'
    $engErrFile = Join-Path $LogsDir 'engine-stderr.log'
    $proc = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$EngineScript`"",
            '-Port', $Port,
            '-WorkspacePath', "`"$WorkspacePath`"",
            '-NoLaunchBrowser'
        ) `
        -NoNewWindow `
        -RedirectStandardOutput $engLogFile `
        -RedirectStandardError  $engErrFile `
        -PassThru `
        -ErrorAction Stop

    # Brief wait to detect immediate crash (port conflict, access denied, strict mode error)
    Start-Sleep -Milliseconds 600
    if ($null -eq $proc -or $proc.HasExited) {
        $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { -1 }
        Write-SvcLog "Engine process exited immediately (exit code $exitCode)." -Level 'ERROR'
        if (Test-Path -LiteralPath $engErrFile) {
            $errContent = Get-Content -LiteralPath $engErrFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrEmpty($errContent)) { Write-SvcLog "Stderr: $errContent" -Level 'ERROR' }
        }
        if (Test-Path -LiteralPath $engLogFile) {
            $outContent = Get-Content -LiteralPath $engLogFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrEmpty($outContent)) { Write-SvcLog "Stdout: $outContent" -Level 'INFO' }
        }
        return $false
    }

    # Write PID file
    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding UTF8 -Force

    # Wait up to 6 seconds for engine to respond
    $deadline = (Get-Date).AddSeconds(6)
    $responded = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-EngineResponding) { $responded = $true; break }
    }

    if ($responded) {
        Write-SvcLog "Engine started (PID $($proc.Id), port $Port) — responding OK."
        return $true
    } else {
        # It may still be starting up; don't kill it, just warn
        Write-SvcLog "Engine PID $($proc.Id) launched but not yet responding on port $Port (still starting up)." -Level 'WARN'
        return $true
    }
}

# ─── Actions ───────────────────────────────────────────────────────────────────
switch ($Action) {
    'Start' {
        $ok = Start-Engine
        exit $(if ($ok) { 0 } else { 1 })
    }
    'Stop' {
        Stop-Engine
        exit 0
    }
    'Restart' {
        Stop-Engine
        Start-Sleep -Seconds 1
        $ok = Start-Engine
        exit $(if ($ok) { 0 } else { 1 })
    }
    'Status' {
        $eid  = Get-EnginePid
        $running   = ($null -ne $eid) -and (Test-EngineRunning $eid)
        $responding = Test-EngineResponding

        $statusObj = [ordered]@{
            pid        = $eid
            running    = $running
            responding = $responding
            port       = $Port
            pidFile    = $PidFile
        }
        Write-Host ($statusObj | Format-List | Out-String) -ForegroundColor $(if ($running -and $responding) {'Green'} elseif ($running) {'Yellow'} else {'Red'})

        # Write a JSON status file for the Hub to read
        $statusFile = Join-Path $LogsDir 'engine-status.json'
        try {
            $statusJson = [ordered]@{
                running    = $running
                responding = $responding
                pid        = $eid
                port       = $Port
                checkedAt  = (Get-Date -Format 'o')
            }
            $statusJson | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statusFile -Encoding UTF8 -Force
        } catch { <# non-fatal #> }

        exit $(if ($running -and $responding) { 0 } else { 1 })
    }
}
