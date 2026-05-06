# VersionTag: 2604.B2.V33.6

# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Launcher
# Start-LocalWebEngineService.ps1
# Manages the LocalWebEngine as a headless background service.
# Use -Action Start|Stop|Restart|Status|Help (default: Start).
# PID file written to logs/engine.pid for status tracking.
# Supports verbose event logging, rainbow status indicator, and log-to-file.
#Requires -Version 5.1
<#
.SYNOPSIS
    Manages the PowerShellGUI Local Web Engine as a headless background service.

.DESCRIPTION
    Launches Start-LocalWebEngine.ps1 in a hidden PowerShell window so it runs
    independently of the calling terminal. Tracks the process via a PID file so
    that Status/Stop/Restart commands work across sessions.

    Features:
      - Separate terminal execution (-SeparateTerminal)
      - Rainbow motion status indicator during startup/wait
      - Verbose operational event logging (-EventLevel)
      - Optional log-to-file for debug or standard event streams (-LogToFile)
      - Built-in help menu listing all switches (-Action Help)

.PARAMETER Action
    Start   - Launch the engine if not already running (default).
    Stop    - Kill the engine process and remove the PID file.
    Restart - Stop then Start.
    Status  - Report whether the engine is running and respond on the port.
    Help    - Show the interactive help menu with all switches.

.PARAMETER Port
    Port the engine listens on (default: 8042).

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace.

.PARAMETER SeparateTerminal
    Launch the engine in a visible separate terminal window instead of headless.

.PARAMETER EventLevel
    Minimum event severity to display/log. Default: Info.
    Values: Debug, Info, Warning, Error, Critical.

.PARAMETER LogToFile
    Path to a log file for persisting all events. If set, events are written
    to this file in addition to console output. Accepts 'auto' to use
    logs/engine-events-{timestamp}.log.

.PARAMETER Verbose
    Show verbose operational events (PS common parameter).

.PARAMETER ShowRainbow
    Display rainbow motion status indicator during startup and polling.
    Default: $true (disable with -ShowRainbow:$false).

.PARAMETER PollInterval
    Seconds between health-check polls during startup wait.  Default: 1.

.PARAMETER MaxWait
    Maximum seconds to wait for engine to respond after launch.  Default: 15.

.EXAMPLE
    .\Start-LocalWebEngineService.ps1 -Action Start -SeparateTerminal -EventLevel Debug -LogToFile auto

.EXAMPLE
    .\Start-LocalWebEngineService.ps1 -Action Help

.EXAMPLE
    .\Start-LocalWebEngineService.ps1 -Action Status -Verbose

.EXAMPLE
    .\Start-LocalWebEngineService.ps1 -Action Restart -ShowRainbow -LogToFile 'C:\logs\engine.log'
#>
Write-Host "[DEPRECATED] Start-LocalWebEngineService.ps1 is replaced by Start-LocalWebEngine.ps1 -Action RunAsService" -ForegroundColor Yellow
$ScriptDir = $PSScriptRoot
$engineScript = Join-Path $ScriptDir 'Start-LocalWebEngine.ps1'
if (-not (Test-Path $engineScript)) {
    Write-Host "Engine script not found: $engineScript" -ForegroundColor Red
    exit 1
}
& $engineScript -Action RunAsService @args
exit $LASTEXITCODE
if ($LogToFile -eq 'auto') {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:EventLogPath = Join-Path $LogsDir "engine-events-$ts.log"
} elseif (-not [string]::IsNullOrWhiteSpace($LogToFile)) {
    $script:EventLogPath = $LogToFile
}

function Write-SvcLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Level = 'INFO')
    $levelKey = switch ($Level) {
        'DEBUG'    { 'Debug' }
        'INFO'     { 'Info' }
        'WARN'     { 'Warning' }
        'WARNING'  { 'Warning' }
        'ERROR'    { 'Error' }
        'CRITICAL' { 'Critical' }
        default    { 'Info' }
    }
    $numLevel = if ($script:EventLevelOrder.ContainsKey($levelKey)) { $script:EventLevelOrder[$levelKey] } else { 1 }
    if ($numLevel -lt $script:MinLevel) { return }

    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts][$Level] $Msg"
    $color = switch ($Level) {
        'DEBUG'    { 'DarkGray' }
        'INFO'     { 'Cyan' }
        'WARN'     { 'Yellow' }
        'WARNING'  { 'Yellow' }
        'ERROR'    { 'Red' }
        'CRITICAL' { 'Magenta' }
        default    { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($script:EventLogPath)) {
        try { Add-Content -LiteralPath $script:EventLogPath -Value $line -Encoding UTF8 } catch { <# non-fatal #> }
    }
    # Also write to the service log
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { <# non-fatal #> }
}

# ─── Rainbow Motion Status Indicator (CLI) ────────────────────────────────────
$script:RainbowChars   = @([char]0x2588, [char]0x2593, [char]0x2592, [char]0x2591)  # Full..Light block
$script:RainbowColors  = @('Red','DarkYellow','Yellow','Green','Cyan','Blue','Magenta','DarkMagenta','Red','DarkYellow','Yellow','Green')
$script:RainbowPhase   = 0

function Write-RainbowStatus {
    <# Renders a single-line animated rainbow spinner with message #>
    param([string]$Message, [int]$Percent = -1)
    $phase  = $script:RainbowPhase
    $width  = 24
    $bar    = ''
    for ($i = 0; $i -lt $width; $i++) {
        $ci = ($i + $phase) % @($script:RainbowColors).Count
        $ch = $script:RainbowChars[($i + $phase) % @($script:RainbowChars).Count]
        Write-Host $ch -NoNewline -ForegroundColor $script:RainbowColors[$ci]
        $bar += $ch  # for log only
    }
    $pctText = if ($Percent -ge 0) { " $Percent%" } else { '' }
    Write-Host " $Message$pctText" -NoNewline -ForegroundColor 'White'
    Write-Host "`r" -NoNewline
    $script:RainbowPhase = ($phase + 1) % @($script:RainbowColors).Count
}

function Clear-RainbowLine {
    Write-Host ("`r" + (' ' * 100) + "`r") -NoNewline
}

function Get-EnginePid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8
        $n   = [int]$raw.Trim()
        if ($n -gt 0) { return $n } else { return $null }
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
    # Quick HTTP check - times out in 2s
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
    $cfgFile = Join-Path (Join-Path $WorkspacePath 'config') 'dependency-scan-config.json'
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $cfgObj = (Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($null -ne $cfgObj -and $null -ne $cfgObj.port) { $Port = [int]$cfgObj.port }
            Write-SvcLog "Config loaded: port=$Port" -Level 'DEBUG'
        } catch { <# use default port #> }
    }

    # Check already running
    $eid = Get-EnginePid
    if ($null -ne $eid -and (Test-EngineRunning $eid)) {
        Write-SvcLog "Engine is already running (PID $eid, port $Port)."
        return $true
    }

    Write-SvcLog "Launching engine on port $Port..."
    Write-SvcLog "Engine script: $EngineScript" -Level 'DEBUG'
    Write-SvcLog "Workspace: $WorkspacePath" -Level 'DEBUG'
    Write-SvcLog "Mode: $(if ($SeparateTerminal) { 'Separate terminal' } else { 'Headless background' })" -Level 'DEBUG'

    $engLogFile = Join-Path $LogsDir 'engine-stdout.log'
    $engErrFile = Join-Path $LogsDir 'engine-stderr.log'

    $procParams = @{
        FilePath     = 'powershell.exe'
        ArgumentList = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$EngineScript`"",
            '-Port', $Port,
            '-WorkspacePath', "`"$WorkspacePath`"",
            '-NoLaunchBrowser'
        )
        PassThru     = $true
        ErrorAction  = 'Stop'
    }

    if ($SeparateTerminal) {
        # Launch in a visible separate terminal window
        Write-SvcLog "Opening in separate terminal window..." -Level 'DEBUG'
        $proc = Start-Process @procParams
    } else {
        # Headless: redirect stdout+stderr to log files (P010: & operator, not iex)
        $procParams['NoNewWindow']            = $true
        $procParams['RedirectStandardOutput'] = $engLogFile
        $procParams['RedirectStandardError']  = $engErrFile
        $proc = Start-Process @procParams
    }

    # Brief wait to detect immediate crash
    Start-Sleep -Milliseconds 600
    if ($null -eq $proc -or $proc.HasExited) {
        $exitCode = if ($null -ne $proc) { $proc.ExitCode } else { -1 }
        Write-SvcLog "Engine process exited immediately (exit code $exitCode)." -Level 'ERROR'
        if (-not $SeparateTerminal) {
            if (Test-Path -LiteralPath $engErrFile) {
                $errContent = Get-Content -LiteralPath $engErrFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrEmpty($errContent)) { Write-SvcLog "Stderr: $errContent" -Level 'ERROR' }
            }
            if (Test-Path -LiteralPath $engLogFile) {
                $outContent = Get-Content -LiteralPath $engLogFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrEmpty($outContent)) { Write-SvcLog "Stdout: $outContent" -Level 'INFO' }
            }
        }
        return $false
    }

    # Write PID file
    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding UTF8 -Force
    Write-SvcLog "PID file written: $PidFile (PID $($proc.Id))" -Level 'DEBUG'

    # Wait with rainbow animation for engine to respond
    $deadline  = (Get-Date).AddSeconds($MaxWait)
    $responded = $false
    $elapsed   = 0

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ($PollInterval * 1000)
        $elapsed += $PollInterval

        # Check if process crashed during wait
        if ($proc.HasExited) {
            if ($ShowRainbow) { Clear-RainbowLine }
            Write-SvcLog "Engine process crashed during startup (exit code $($proc.ExitCode))." -Level 'ERROR'
            return $false
        }

        if (Test-EngineResponding) {
            $responded = $true
            break
        }

        # Animate rainbow status
        if ($ShowRainbow) {
            $pct = [math]::Min(95, [int](($elapsed / $MaxWait) * 100))
            Write-RainbowStatus -Message "Waiting for engine on :$Port" -Percent $pct
        } else {
            Write-SvcLog "Polling engine [$elapsed/${MaxWait}s]..." -Level 'DEBUG'
        }
    }

    if ($ShowRainbow) { Clear-RainbowLine }

    if ($responded) {
        Write-SvcLog "Engine started (PID $($proc.Id), port $Port) - responding OK."
        if ($ShowRainbow) {
            # Final green success bar
            Write-Host ([string]([char]0x2588) * 24) -NoNewline -ForegroundColor 'Green'
            Write-Host " Engine READY on :$Port (PID $($proc.Id))" -ForegroundColor 'Green'
        }
        return $true
    } else {
        Write-SvcLog "Engine PID $($proc.Id) launched but not yet responding on port $Port (still starting up)." -Level 'WARN'
        return $true
    }
}

# ─── Help Menu ─────────────────────────────────────────────────────────────────
function Show-HelpMenu {
    $banner = @'
 ____________________________________________________________________________________________
|                                                                                            |
|   Start-LocalWebEngineService.ps1  -  PwShGUI Engine Service Controller                   |
|____________________________________________________________________________________________|

'@
    Write-Host $banner -ForegroundColor Cyan

    $sections = @(
        @{ Header = 'SERVICE CONTROL SWITCHES'; Color = 'Green'; Items = @(
            @('-Action Start',    'Launch the engine (default). Detects already-running instances.'),
            @('-Action Stop',     'Kill the engine process and remove the PID file.'),
            @('-Action Restart',  'Stop then Start in sequence.'),
            @('-Action Status',   'Report PID, running state, port responsiveness, and write status JSON.'),
            @('-Action Help',     'Display this help menu.')
        )},
        @{ Header = 'EXECUTION PARAMETER CONTROLS'; Color = 'Yellow'; Items = @(
            @('-Port <int>',           'Port to listen on (default: 8042). Auto-reads config if available.'),
            @('-WorkspacePath <str>',  'Workspace root directory (auto-detected from script location).'),
            @('-SeparateTerminal',     'Launch engine in a visible separate terminal instead of headless.'),
            @('-PollInterval <int>',   'Seconds between health-check polls during startup (default: 1).'),
            @('-MaxWait <int>',        'Maximum seconds to wait for engine response (default: 15).')
        )},
        @{ Header = 'EVENT LEVEL LOGGING FLAGS'; Color = 'Magenta'; Items = @(
            @('-EventLevel Debug',     'Show all events including internal diagnostics and trace details.'),
            @('-EventLevel Info',      'Show informational events and above (default).'),
            @('-EventLevel Warning',   'Show warnings and errors only.'),
            @('-EventLevel Error',     'Show errors and critical failures only.'),
            @('-EventLevel Critical',  'Show only critical/fatal events.'),
            @('-Verbose',              'PowerShell verbose stream (additional operational details).')
        )},
        @{ Header = 'LOG-TO-FILE OPTIONS'; Color = 'DarkYellow'; Items = @(
            @('-LogToFile auto',       "Write all events to logs/engine-events-{timestamp}.log automatically."),
            @('-LogToFile <path>',     'Write all events to a specific file path for debug or audit.'),
            @('(omit -LogToFile)',     'Events are shown on console and written to engine-service.log only.')
        )},
        @{ Header = 'DISPLAY OPTIONS'; Color = 'Cyan'; Items = @(
            @('-ShowRainbow',              'Show animated rainbow status indicator during startup (default: $true).'),
            @('-ShowRainbow:$false',       'Disable rainbow animation (use plain text polling messages).')
        )}
    )

    foreach ($sec in $sections) {
        Write-Host ""
        Write-Host "  $($sec.Header)" -ForegroundColor $sec.Color
        Write-Host ("  " + ('-' * $sec.Header.Length)) -ForegroundColor DarkGray
        foreach ($item in $sec.Items) {
            Write-Host "    " -NoNewline
            Write-Host $item[0].PadRight(28) -NoNewline -ForegroundColor White
            Write-Host $item[1] -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "  EXAMPLES" -ForegroundColor Green
    Write-Host "  --------" -ForegroundColor DarkGray
    Write-Host "    .\Start-LocalWebEngineService.ps1 -Action Start -SeparateTerminal -EventLevel Debug -LogToFile auto" -ForegroundColor DarkCyan
    Write-Host "    .\Start-LocalWebEngineService.ps1 -Action Status -Verbose" -ForegroundColor DarkCyan
    Write-Host "    .\Start-LocalWebEngineService.ps1 -Action Restart -ShowRainbow -MaxWait 30" -ForegroundColor DarkCyan
    Write-Host "    .\Start-LocalWebEngineService.ps1 -Action Stop" -ForegroundColor DarkCyan
    Write-Host ""

    # Rainbow demo
    if ($ShowRainbow) {
        Write-Host "  Rainbow indicator demo:" -ForegroundColor DarkGray
        for ($d = 0; $d -lt 20; $d++) {
            Write-RainbowStatus -Message 'Demo in motion...' -Percent ($d * 5)
            Start-Sleep -Milliseconds 80
        }
        Clear-RainbowLine
        Write-Host ([string]([char]0x2588) * 24) -NoNewline -ForegroundColor 'Green'
        Write-Host " Complete!" -ForegroundColor Green
    }
}

# ─── Actions ───────────────────────────────────────────────────────────────────
Write-SvcLog "Action=$Action  Port=$Port  EventLevel=$EventLevel  Rainbow=$ShowRainbow  SepTerminal=$SeparateTerminal" -Level 'DEBUG'
if (-not [string]::IsNullOrWhiteSpace($script:EventLogPath)) {
    Write-SvcLog "Event log file: $($script:EventLogPath)" -Level 'DEBUG'
}

switch ($Action) {
    'Help' {
        Show-HelpMenu
        exit 0
    }
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

        Write-SvcLog "Checking engine status..." -Level 'DEBUG'

        $statusObj = [ordered]@{
            pid        = $eid
            running    = $running
            responding = $responding
            port       = $Port
            pidFile    = $PidFile
        }

        $statusColor = if ($running -and $responding) { 'Green' } elseif ($running) { 'Yellow' } else { 'Red' }

        if ($ShowRainbow) {
            # Rainbow header for status
            for ($i = 0; $i -lt 24; $i++) {
                $ci = $i % @($script:RainbowColors).Count
                Write-Host ([char]0x2588) -NoNewline -ForegroundColor $script:RainbowColors[$ci]
            }
            $stLabel = if ($running -and $responding) { ' ONLINE' } elseif ($running) { ' STARTING' } else { ' OFFLINE' }
            Write-Host $stLabel -ForegroundColor $statusColor
        }

        Write-Host ($statusObj | Format-List | Out-String) -ForegroundColor $statusColor

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
            Write-SvcLog "Status JSON written: $statusFile" -Level 'DEBUG'
        } catch { <# non-fatal #> }

        exit $(if ($running -and $responding) { 0 } else { 1 })
    }
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




