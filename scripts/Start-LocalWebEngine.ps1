# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Launcher
# Start-LocalWebEngine.ps1
# Loopback HTTP/WebSocket server for PowerShellGUI workspace tools.
# Listens on http://127.0.0.1:8042/ — serves XHTML pages, APIs, and WebSocket progress.
# Security: loopback-only, CSRF token, Content Security Policy headers.
#Requires -Version 5.1

<#
.SYNOPSIS
    Starts the PowerShellGUI Local Web Engine on localhost.
.DESCRIPTION
    Loopback-only HttpListener server on http://127.0.0.1:<Port>/
    Serves XHTML pages, REST API, and WebSocket progress for PowerShellGUI tools.
.PARAMETER Port
    TCP port to listen on (default: 8042).
.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Defaults to the parent of this script folder.
.PARAMETER NoLaunchBrowser
    Suppress automatic browser launch on start.
.PARAMETER Help
    Display this help text and exit.
.EXAMPLE
    .\Start-LocalWebEngine.ps1
    .\Start-LocalWebEngine.ps1 -Port 9000 -NoLaunchBrowser
    .\Start-LocalWebEngine.ps1 -Help
#>
[CmdletBinding()]

[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Restart','Status','LaunchWebpage','Help','RunAsService')]
    [string]$Action = 'Start',
    [int]$Port = 8042,
    [string]$WorkspacePath = '',
    [switch]$NoLaunchBrowser,
    [switch]$Help,
    [switch]$AsService,
    [switch]$Force,
    [int]$PortRetryMax = 5
)


# Unified help
if ($Help -or $Action -eq 'Help') {
    Write-Host @"
Start-LocalWebEngine.ps1 — Unified Launcher/Service
  -Action Start|Stop|Restart|Status|LaunchWebpage|Help|RunAsService
  -Port <int>              # Port to bind (default: 8042)
  -WorkspacePath <path>    # Workspace root
  -NoLaunchBrowser         # Suppress browser launch
  -AsService               # Run as background service
  -Force                   # Force restart/stop
  -PortRetryMax <n>        # Max port increments if busy
  -Help                    # Show this help
"@
    exit 0
}

# Main control flow
switch ($Action) {
    'Start' {
        # TODO: Implement negotiation/version check, safe restart, port fallback
        # If another instance is healthy, return status/version
        # If not, try to restart or prompt user
        # If port busy, try next port up to PortRetryMax
        # Start engine normally
    }
    'Stop' {
        # TODO: Implement stop logic (find PID, signal/kill, cleanup)
    }
    'Restart' {
        # TODO: Stop then Start
    }
    'Status' {
        # TODO: Query engine status/version, print result
    }
    'LaunchWebpage' {
        # TODO: Open browser to engine URL
    }
    'RunAsService' {
        # TODO: Start as background service (hidden window, PID tracking)
    }
    default {
        Write-Host "Unknown action: $Action" -ForegroundColor Red
        exit 1
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Engine stop flag (file-based signal; ThreadPool cannot reach $script: scope) ──
$script:_EngineStop = $false

# ─── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($WorkspacePath)) {
    $WorkspacePath = Split-Path $ScriptDir -Parent
}

$ConfigFile = Join-Path $WorkspacePath 'config'
$ConfigFile = Join-Path $ConfigFile 'dependency-scan-config.json'

# ─── Log file paths ───────────────────────────────────────────────────────────
$script:EngineLogFile    = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-stdout.log'
$script:BootstrapLogFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-bootstrap.log'
$script:CrashLogFile     = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-crash.log'
$script:StopSignalFile   = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.stop'
$script:_ExitClean       = $false   # set $true on graceful stop; $false = dirty exit
$script:_BootstrapErrors = [System.Collections.ArrayList]@()
$script:_ConsoleCancelHandler = $null

function Write-EngineLog {
    param([string]$Msg, [string]$Level = 'DEBUG')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    Write-Host $line
    try { Add-Content -LiteralPath $script:EngineLogFile -Value $line -Encoding UTF8 } catch { <# Intentional: non-fatal — log write cannot recurse into itself #> }
}

# Bootstrap log: written BEFORE HttpListener starts — survives engine non-start
function Write-BootstrapLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][BOOT][$Level] $Msg"
    Write-Host $line
    try { Add-Content -LiteralPath $script:BootstrapLogFile -Value $line -Encoding UTF8 } catch { <# Intentional: non-fatal — bootstrap log write cannot recurse into itself #> }
    if ($Level -eq 'ERROR' -or $Level -eq 'WARN') {
        $null = $script:_BootstrapErrors.Add([pscustomobject]@{ ts = $ts; level = $Level; msg = $Msg })
    }
}

function Request-EngineStop {
    [CmdletBinding()]
    param(
        [string]$Reason = 'Stop requested',
        [switch]$MarkClean
    )
    if ($MarkClean) {
        $script:_ExitClean = $true
    }
    try {
        Set-Content -LiteralPath $script:StopSignalFile -Value '1' -Encoding UTF8 -Force
    } catch {
        Write-EngineLog "Failed to write stop signal: $_" -Level 'WARN'
    }
    Write-EngineLog $Reason -Level 'INFO'
}

# Native C# Ctrl+C handler — script-block delegates throw 'no Runspace available'
# when the OS calls them on the signal thread (PSInvalidOperationException), which
# tears the process down (exit 0xE0434352). A real .NET delegate has no such issue.
if (-not ('PwShGUI.EngineCancelHandler' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace PwShGUI {
    public static class EngineCancelHandler {
        public static string StopFile;
        private static ConsoleCancelEventHandler _handler;
        public static void Register(string stopFile) {
            StopFile = stopFile;
            if (_handler != null) { return; }
            _handler = new ConsoleCancelEventHandler(OnCancel);
            Console.CancelKeyPress += _handler;
        }
        public static void Unregister() {
            if (_handler != null) {
                try { Console.CancelKeyPress -= _handler; } catch { }
                _handler = null;
            }
        }
        private static void OnCancel(object sender, ConsoleCancelEventArgs e) {
            try { e.Cancel = true; } catch { }
            try {
                if (!string.IsNullOrEmpty(StopFile)) {
                    File.WriteAllText(StopFile, "1");
                }
            } catch { }
            try { Console.WriteLine("Console stop requested - shutting down engine..."); } catch { }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
    } catch {
        Write-BootstrapLog "EngineCancelHandler type compile failed: $_" 'WARN'
    }
}

function Register-ConsoleShutdownHandler {
    [CmdletBinding()]
    param()
    if ($Host.Name -ne 'ConsoleHost') {
        return
    }
    try {
        if ('PwShGUI.EngineCancelHandler' -as [type]) {
            [PwShGUI.EngineCancelHandler]::Register($script:StopSignalFile)
            $script:_ConsoleCancelHandler = $true
        }
    } catch {
        Write-BootstrapLog "Console shutdown handler registration failed: $_" 'WARN'
    }
}

function Unregister-ConsoleShutdownHandler {
    [CmdletBinding()]
    param()
    if ($script:_ConsoleCancelHandler) {
        try {
            if ('PwShGUI.EngineCancelHandler' -as [type]) {
                [PwShGUI.EngineCancelHandler]::Unregister()
            }
        } catch { <# Intentional: non-fatal — handler removal is best-effort during shutdown #> }
        $script:_ConsoleCancelHandler = $null
    }
}

# ─── Pre-start bootstrap sequence ─────────────────────────────────────────────
Write-BootstrapLog "=== Engine Bootstrap Start ==="
Write-BootstrapLog "PID=$PID  PSVersion=$($PSVersionTable.PSVersion)  Host=$($Host.Name)" 'INFO'
Write-BootstrapLog "WorkspacePath=$WorkspacePath"

# Port availability pre-check
try {
    $tcpTest = New-Object System.Net.Sockets.TcpClient
    $conn = $tcpTest.BeginConnect('127.0.0.1', $Port, $null, $null)
    $portInUse = $conn.AsyncWaitHandle.WaitOne(300)
    if ($portInUse) {
        try { $tcpTest.EndConnect($conn) } catch { <# Intentional: non-fatal, TCP EndConnect cleanup #> }
        Write-BootstrapLog "Port $Port may already be in use" 'WARN'
    } else {
        Write-BootstrapLog "Port $Port is available" 'INFO'
    }
    $tcpTest.Close()
} catch { Write-BootstrapLog "Port check error: $_" 'WARN' }

# ─── Load config ───────────────────────────────────────────────────────────────
$cfg = $null
try {
    if (Test-Path -LiteralPath $ConfigFile) {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrEmpty($raw)) {
            $cfg = $raw | ConvertFrom-Json
            Write-BootstrapLog "Config loaded: $ConfigFile" 'INFO'
        }
    } else {
        Write-BootstrapLog "Config file not found at: $ConfigFile — using defaults" 'WARN'
    }
} catch {
    Write-BootstrapLog "Config parse error: $_ — using defaults" 'WARN'
}

if ($null -ne $cfg -and $null -ne $cfg.port) { $Port = [int]$cfg.port }

# ─── Import core module ────────────────────────────────────────────────────────

# Import core module using manifest (.psd1)
$coreManifestPath = Join-Path $WorkspacePath 'modules'
$coreManifestPath = Join-Path $coreManifestPath 'PwShGUICore.psd1'
if (Test-Path -LiteralPath $coreManifestPath) {
    try {
        Import-Module $coreManifestPath -Force
        Write-BootstrapLog 'PwShGUICore.psd1 imported successfully' 'INFO'
    } catch {
        Write-BootstrapLog "PwShGUICore.psd1 import failed: $_" 'ERROR'
    }
} else {
    Write-BootstrapLog "PwShGUICore.psd1 not found at: $coreManifestPath" 'WARN'
}

# ─── Generate CSRF session token ───────────────────────────────────────────────
$rng          = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$tokenBytes   = New-Object byte[] 32
$rng.GetBytes($tokenBytes)
$SessionToken = [Convert]::ToBase64String($tokenBytes)
$rng.Dispose()

# ─── WebSocket client registry ─────────────────────────────────────────────────
$WsClients = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()

<#
.SYNOPSIS
Send a JSON message to all connected WebSocket clients.
.DESCRIPTION
Iterates through all registered WebSocket clients and sends the provided JSON message. Removes dead connections.
.PARAMETER JsonMessage
The JSON string to send to all clients.
#>
function Send-WsMessage {
    [CmdletBinding()]
    param([string]$JsonMessage)
    $encodedBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonMessage)
    $segment      = [System.ArraySegment[byte]]::new($encodedBytes)
    $deadKeys     = [System.Collections.ArrayList]@()
    foreach ($kvp in $WsClients.GetEnumerator()) {
        $ws = $kvp.Value
        try {
            if ($null -ne $ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, `
                    [System.Threading.CancellationToken]::None).Wait(2000) | Out-Null
            } else {
                $null = $deadKeys.Add($kvp.Key)
            }
        } catch {
            $null = $deadKeys.Add($kvp.Key)
        }
    }
    foreach ($dk in $deadKeys) {
        $removed = $null
        $WsClients.TryRemove($dk, [ref]$removed) | Out-Null
    }
}

# ─── Helper: safe file read ────────────────────────────────────────────────────
<#
.SYNOPSIS
Safely read a file from the workspace, validating the path.
.DESCRIPTION
Validates and normalizes the provided relative path, blocks traversal, and ensures the file is within the workspace before reading.
.PARAMETER RelativePath
The relative path to the file within the workspace.
#>
function Read-WorkspaceFile {
    [CmdletBinding()]
    param([string]$RelativePath)
    # P009: validate path before joining
    if ([string]::IsNullOrEmpty($RelativePath)) { return $null }
    $cleanRel = $RelativePath.TrimStart('/', '\').Replace('/', '\')
    # Block path traversal
    if ($cleanRel -match '\.\.') { return $null }
    $fullPath = Join-Path $WorkspacePath $cleanRel
    # Ensure resolved path is still within workspace
    $resolved = try { [System.IO.Path]::GetFullPath($fullPath) } catch { return $null }
    $wsResolved = try { [System.IO.Path]::GetFullPath($WorkspacePath) } catch { return $null }
    if (-not $resolved.StartsWith($wsResolved)) { return $null }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 } catch { return $null }
}

# ─── Helper: build HTTP response ──────────────────────────────────────────────
<#
.SYNOPSIS
Send an HTTP response with headers and body.
.DESCRIPTION
Builds and sends an HTTP response with security and CORS headers, content type, and body.
.PARAMETER Context
The HttpListenerContext for the response.
.PARAMETER StatusCode
HTTP status code to send (default 200).
.PARAMETER ContentType
MIME type for the response.
.PARAMETER Body
Response body as a string.
.PARAMETER ExtraHeaders
Additional headers to set.
#>
function Send-Response {
    [CmdletBinding()]
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode      = 200,
        [string]$ContentType  = 'application/json; charset=utf-8',
        [string]$Body         = '',
        [hashtable]$ExtraHeaders = @{}
    )
    $resp = $Context.Response
    $resp.StatusCode    = $StatusCode
    $resp.ContentType   = $ContentType
    # Security headers
    $resp.Headers.Set('X-Content-Type-Options', 'nosniff')
    $resp.Headers.Set('X-Frame-Options', 'SAMEORIGIN')
    $resp.Headers.Set('Content-Security-Policy',
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' http://127.0.0.1:$Port ws://127.0.0.1:$Port wss://127.0.0.1:$Port")
    $resp.Headers.Set('Cache-Control', 'no-cache, no-store, must-revalidate')
    # CORS — engine is 127.0.0.1 only, so any same-machine page may call it.
    # Browsers send Origin: null for file:// pages — that MUST be reflected verbatim,
    # not normalised to http://127.0.0.1:$Port (which would cause the browser to
    # silently drop the response and the page to render an "(offline)" cache fallback).
    $reqOrigin = $Context.Request.Headers['Origin']
    $allowCreds = $false
    if ($reqOrigin -and ($reqOrigin -eq 'null' -or $reqOrigin -match '^(https?://(127\.0\.0\.1|localhost)(:\d+)?$)|^file://')) {
        $resp.Headers.Set('Access-Control-Allow-Origin', $reqOrigin)
        $resp.Headers.Set('Vary', 'Origin')
        # Browsers reject Allow-Credentials when origin is "null" or "*" — only set for real origins.
        if ($reqOrigin -ne 'null') { $allowCreds = $true }
    } else {
        $resp.Headers.Set('Access-Control-Allow-Origin', 'http://127.0.0.1:' + $Port)
        $allowCreds = $true
    }
    if ($allowCreds) { $resp.Headers.Set('Access-Control-Allow-Credentials', 'true') }
    $resp.Headers.Set('Access-Control-Allow-Headers', 'Content-Type, X-CSRF-Token, X-Requested-With')
    $resp.Headers.Set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, HEAD, OPTIONS')
    $resp.Headers.Set('Access-Control-Max-Age', '600')
    foreach ($kv in $ExtraHeaders.GetEnumerator()) { $resp.Headers.Set($kv.Key, $kv.Value) }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $resp.ContentLength64 = $bytes.Length
    try {
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.OutputStream.Close()
    } catch { <# client disconnected #> }
}

<#
.SYNOPSIS
Send a JSON response to the client.
.DESCRIPTION
Serializes the provided object to JSON and sends it as an HTTP response.
.PARAMETER Context
The HttpListenerContext for the response.
.PARAMETER Object
The object to serialize to JSON.
.PARAMETER StatusCode
HTTP status code to send (default 200).
#>
function Send-Json {
    [CmdletBinding()]
    param($Context, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 5
    Send-Response -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $json
}

<#
.SYNOPSIS
Send an error response as JSON.
.DESCRIPTION
Sends a JSON error object with a message and code.
.PARAMETER Context
The HttpListenerContext for the response.
.PARAMETER StatusCode
HTTP status code to send (default 400).
.PARAMETER Message
Error message to include in the response.
#>
function Send-Error {
    [CmdletBinding()]
    param($Context, [int]$StatusCode = 400, [string]$Message = 'Bad Request')
    Send-Json -Context $Context -Object @{ error = $Message; code = $StatusCode } -StatusCode $StatusCode
}

# ─── Route: GET /api/scan/status ──────────────────────────────────────────────
<#
.SYNOPSIS
Get the current scan checkpoint and progress.
.DESCRIPTION
Returns the latest scan checkpoint and progress log as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-ScanStatus {
    [CmdletBinding()]
    param($Context)
    $cpSub  = if ($null -ne $cfg -and $null -ne $cfg.paths -and
                  $cfg.paths.PSObject.Properties.Name -contains 'checkpointFile') {
                  $cfg.paths.checkpointFile
              } else { Join-Path 'checkpoints' 'dependency-scan-checkpoint.json' }
    $pgSub  = if ($null -ne $cfg -and $null -ne $cfg.paths -and
                  $cfg.paths.PSObject.Properties.Name -contains 'scanProgressLog') {
                  $cfg.paths.scanProgressLog
              } else { Join-Path 'logs' 'scan-progress.json' }
    $cpFile = Join-Path $WorkspacePath $cpSub
    $pgFile = Join-Path $WorkspacePath $pgSub

    $checkpoint = $null
    $progress   = $null
    if (Test-Path -LiteralPath $cpFile) {
        try { $checkpoint = (Get-Content -LiteralPath $cpFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { <# non-fatal #> }
    }
    if (Test-Path -LiteralPath $pgFile) {
        try { $progress = (Get-Content -LiteralPath $pgFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { <# non-fatal #> }
    }
    Send-Json -Context $Context -Object @{ checkpoint = $checkpoint; progress = $progress; serverTime = (Get-Date -Format 'o') }
}

# ─── Route: GET /api/scan/crashes ─────────────────────────────────────────────
<#
.SYNOPSIS
Get recent scan crash dumps.
.DESCRIPTION
Returns up to 50 recent scan crash dump files as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-ScanCrashes {
    [CmdletBinding()]
    param($Context)
    $crashSub = if ($null -ne $cfg -and $null -ne $cfg.paths -and
                    $cfg.paths.PSObject.Properties.Name -contains 'crashDumpDir') {
                    $cfg.paths.crashDumpDir
                } else { Join-Path 'logs' 'crash-dumps' }
    $crashDir = Join-Path $WorkspacePath $crashSub
    $dumps = [System.Collections.ArrayList]@()
    if (Test-Path $crashDir) {
        $files = @(Get-ChildItem -Path $crashDir -Filter 'crash-*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 50)
        foreach ($f in $files) {
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                if (-not [string]::IsNullOrEmpty($raw)) {
                    $obj = $raw | ConvertFrom-Json
                    $null = $dumps.Add($obj)
                }
            } catch { <# non-fatal — skip unreadable dump #> }
        }
    }
    Send-Json -Context $Context -Object @{ crashes = @($dumps); count = @($dumps).Count }
}

# ─── Route: GET /api/engine/status ───────────────────────────────────────────
<#
.SYNOPSIS
Get the current engine status and uptime.
.DESCRIPTION
Returns engine running status, PID, port, uptime, and server time as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-EngineStatus {
    [CmdletBinding()]
    param($Context)
    Send-Json -Context $Context -Object @{
        running    = $true
        responding = $true
        pid        = $PID
        port       = $Port
        startedAt  = $script:_EngineStartTime
        uptime     = [int]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency - $script:_EngineStartEpoch)
        serverTime = (Get-Date -Format 'o')
    }
}
$script:_EngineStartTime  = (Get-Date -Format 'o')
$script:_EngineStartEpoch = [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency

# ─── Route: GET /api/engine/log?name=stdout|stderr|service ───────────────────
<#
.SYNOPSIS
Get the latest engine log lines.
.DESCRIPTION
Returns the last 50 lines from the specified engine log file as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-EngineLog {
    [CmdletBinding()]
    param($Context)
    # Allowed log file names only — prevent path traversal
    $nameParam = $Context.Request.QueryString['name']
    $allowedNames = @{ stdout = 'engine-stdout.log'; stderr = 'engine-stderr.log'; service = 'engine-service.log'; bootstrap = 'engine-bootstrap.log'; crash = 'engine-crash.log' }
    $logKey = if ($null -ne $nameParam -and $allowedNames.ContainsKey($nameParam)) { $nameParam } else { 'stdout' }
    $logFile = Join-Path $WorkspacePath (Join-Path 'logs' $allowedNames[$logKey])
    $lines = @()
    if (Test-Path -LiteralPath $logFile) {
        $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 50 -ErrorAction SilentlyContinue)
    }
    Send-Json -Context $Context -Object @{
        logName  = $logKey
        logFile  = $logFile
        lines    = $lines
        lineCount = @($lines).Count
    }
}

# ─── Route: GET /api/engine/events  (aggregated structured event log) ────────
<#
.SYNOPSIS
Get recent engine event log entries.
.DESCRIPTION
Returns up to 2000 recent event log entries from all engine logs as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-EngineEvents {
    [CmdletBinding()]
    param($Context)
    $tailParam = $Context.Request.QueryString['tail']
    $tail = if ($null -ne $tailParam -and $tailParam -match '^\d+$') { [int]$tailParam } else { 200 }
    if ($tail -gt 2000) { $tail = 2000 }
    $logMap = @{
        bootstrap = 'engine-bootstrap.log'
        stdout    = 'engine-stdout.log'
        service   = 'engine-service.log'
        crash     = 'engine-crash.log'
    }
    $events = [System.Collections.ArrayList]@()
    foreach ($kv in $logMap.GetEnumerator()) {
        $logFile = Join-Path (Join-Path $WorkspacePath 'logs') $kv.Value
        if (-not (Test-Path -LiteralPath $logFile)) { continue }
        try {
            $fileLines = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            foreach ($ln in $fileLines) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                # Parse: [yyyy-MM-dd HH:mm:ss][LEVEL] msg  or  JSON crash line
                $level = 'INFO'
                $ts    = ''
                $msg   = $ln
                if ($ln -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[([A-Z_]+)\]\s*(.*)$') {
                    $ts  = $Matches[1]; $level = $Matches[2]; $msg = $Matches[3]
                } elseif ($ln -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\[BOOT\]\[([A-Z]+)\]\s*(.*)$') {
                    $ts  = $Matches[1]; $level = $Matches[2]; $msg = $Matches[3]
                } elseif ($ln.TrimStart().StartsWith('{')) {
                    $level = 'CRASH'; $msg = $ln
                }
                $null = $events.Add([pscustomobject]@{
                    source = $kv.Key; ts = $ts; level = $level; msg = $msg
                })
            }
        } catch { <# non-fatal — skip unreadable log #> }
    }
    # Sort by ts if present, then return most-recent $tail
    $sorted  = @($events | Sort-Object { if ($_.ts) { $_.ts } else { '' } })
    $trimmed = if ($sorted.Count -gt $tail) { $sorted[($sorted.Count - $tail)..($sorted.Count - 1)] } else { $sorted }
    Send-Json -Context $Context -Object @{
        events    = $trimmed
        total     = @($events).Count
        returned  = @($trimmed).Count
        logFiles  = @($logMap.Keys)
        serverTime= (Get-Date -Format 'o')
    }
}

# ─── Route: GET /api/engine/logs/list ────────────────────────────────────────
<#
.SYNOPSIS
List all known engine log files and their status.
.DESCRIPTION
Returns a list of known engine log files, their existence, and size as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-EngineLogsList {
    [CmdletBinding()]
    param($Context)
    $logsDir = Join-Path $WorkspacePath 'logs'
    $knownNames = @{ stdout='engine-stdout.log'; stderr='engine-stderr.log'; service='engine-service.log'; bootstrap='engine-bootstrap.log'; crash='engine-crash.log' }
    $result = [System.Collections.ArrayList]@()
    foreach ($kv in $knownNames.GetEnumerator()) {
        $lp = Join-Path $logsDir $kv.Value
        $exists = Test-Path -LiteralPath $lp
        $sizeBytes = if ($exists) { (Get-Item -LiteralPath $lp).Length } else { 0 }
        $null = $result.Add([pscustomobject]@{
            name     = $kv.Key
            filename = $kv.Value
            exists   = $exists
            sizeKB   = [Math]::Round($sizeBytes / 1KB, 1)
        })
    }
    Send-Json -Context $Context -Object @{ logs = @($result) }
}

# ─── Route: POST /api/scan/full | /api/scan/incremental ───────────────────────
<#
.SYNOPSIS
Trigger a dependency scan job.
.DESCRIPTION
Starts a background job to run the dependency scan manager script.
.PARAMETER Context
The HttpListenerContext for the request.
.PARAMETER ScanMode
The scan mode to use (full or incremental).
#>
function Invoke-Scan {
    [CmdletBinding()]
    param($Context, [string]$ScanMode)
    # CSRF check — token must match header X-CSRF-Token
    $incomingToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $incomingToken -or $incomingToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    $managerScript = Join-Path $WorkspacePath 'scripts'
    $managerScript = Join-Path $managerScript 'Invoke-DependencyScanManager.ps1'
    if (-not (Test-Path -LiteralPath $managerScript)) {
        Send-Error -Context $Context -StatusCode 500 -Message 'DependencyScanManager.ps1 not found'
        return
    }
    # Launch background job (P010: & operator, not iex)
    $null = Start-Job -ScriptBlock {
        param($script, $mode, $ws)
        & powershell.exe -NoProfile -NonInteractive -File $script -Mode $mode -WorkspacePath $ws
    } -ArgumentList $managerScript, $ScanMode, $WorkspacePath
    $msg = [ordered]@{ event = 'scan_started'; mode = $ScanMode; timestamp = (Get-Date -Format 'o') }
    Send-WsMessage -JsonMessage ($msg | ConvertTo-Json -Depth 3)
    Send-Json -Context $Context -Object @{ accepted = $true; mode = $ScanMode } -StatusCode 202
}

# ─── Route: POST /api/scan/static ────────────────────────────────────────────
<#
.SYNOPSIS
Trigger a static workspace scan job.
.DESCRIPTION
Starts a background job to run the static workspace scan script.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Invoke-StaticScan {
    [CmdletBinding()]
    param($Context)
    $incomingToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $incomingToken -or $incomingToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    $staticScript = Join-Path $WorkspacePath 'scripts'
    $staticScript = Join-Path $staticScript 'Invoke-StaticWorkspaceScan.ps1'
    if (-not (Test-Path -LiteralPath $staticScript)) {
        Send-Error -Context $Context -StatusCode 500 -Message 'Invoke-StaticWorkspaceScan.ps1 not found'
        return
    }
    # Launch background job (P010: & operator, not iex)
    $null = Start-Job -ScriptBlock {
        param($script, $ws)
        & powershell.exe -NoProfile -NonInteractive -File $script -WorkspacePath $ws
    } -ArgumentList $staticScript, $WorkspacePath
    $msg = [ordered]@{ event = 'scan_started'; mode = 'Static'; timestamp = (Get-Date -Format 'o') }
    Send-WsMessage -JsonMessage ($msg | ConvertTo-Json -Depth 3)
    Send-Json -Context $Context -Object @{ accepted = $true; mode = 'Static' } -StatusCode 202
}

# ─── Route: GET /api/agent/stats ──────────────────────────────────────────────
<#
.SYNOPSIS
Get agent call statistics.
.DESCRIPTION
Returns agent call statistics from the stats file or by running the stats script.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-AgentStats {
    [CmdletBinding()]
    param($Context)
    # Try live stats file first; compute 24h/7d counts from JSONL logs
    $statsFile = Join-Path $WorkspacePath 'config'
    $statsFile = Join-Path $statsFile 'agent-call-stats.json'
    $statsData = $null
    if (Test-Path -LiteralPath $statsFile) {
        try { $statsData = Get-Content -LiteralPath $statsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { <# non-fatal #> }
    }
    # If Invoke-AgentCallStats.ps1 exists, attempt a fast in-process update
    $agCalcScript = Join-Path $WorkspacePath 'scripts'
    $agCalcScript = Join-Path $agCalcScript 'Invoke-AgentCallStats.ps1'
    if (Test-Path -LiteralPath $agCalcScript) {
        try {
            $updated = & powershell.exe -NoProfile -NonInteractive -File $agCalcScript `
                -WorkspacePath $WorkspacePath -PassThru -ErrorAction Stop
            if ($null -ne $updated) {
                if (Test-Path -LiteralPath $statsFile) {
                    try { $statsData = Get-Content -LiteralPath $statsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { <# non-fatal #> }
                }
            }
        } catch { <# Intentional: non-fatal if stats script fails #> }
    }
    if ($null -eq $statsData) {
        Send-Json -Context $Context -Object @{ error = 'stats_unavailable'; stats = @{} } -StatusCode 200
    } else {
        Send-Json -Context $Context -Object $statsData
    }
}

# ─── Route: GET /api/config/menus ─────────────────────────────────────────────
<#
.SYNOPSIS
Get the workspace menu layout.
.DESCRIPTION
Returns the menu layout JSON from the config directory.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-Menus {
    [CmdletBinding()]
    param($Context)
    $menuFile = Join-Path $WorkspacePath 'config'
    $menuFile = Join-Path $menuFile 'menu-layout.json'
    $obj = $null
    if (Test-Path -LiteralPath $menuFile) {
        try { $obj = (Get-Content -LiteralPath $menuFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { <# non-fatal #> }
    }
    Send-Json -Context $Context -Object $obj
}

# ─── Route: POST /api/config/menus ────────────────────────────────────────────
<#
.SYNOPSIS
Save the workspace menu layout.
.DESCRIPTION
Saves the provided menu layout JSON to the config directory.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Save-Menus {
    [CmdletBinding()]
    param($Context)
    $incomingToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $incomingToken -or $incomingToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    try {
        $bodyBytes = New-Object byte[] 65536
        $read = $Context.Request.InputStream.Read($bodyBytes, 0, 65536)
        $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $read)
        $parsed = $bodyStr | ConvertFrom-Json
        $menuFile = Join-Path $WorkspacePath 'config'
        $menuFile = Join-Path $menuFile 'menu-layout.json'
        Set-Content -LiteralPath $menuFile -Value ($parsed | ConvertTo-Json -Depth 8) -Encoding UTF8 -Force
        Send-Json -Context $Context -Object @{ saved = $true }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Save failed: $_"
    }
}

# ─── Route: GET /api/workspace/files ──────────────────────────────────────────
<#
.SYNOPSIS
List workspace files matching given extensions.
.DESCRIPTION
Returns a list of files in the workspace matching the provided extensions as JSON.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-WorkspaceFiles {
    [CmdletBinding()]
    param($Context)
    $ext = $Context.Request.QueryString['ext']
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '*.xhtml,*.html,*.json,*.css,*.js' }
    $includePatterns = $ext.Split(',') | ForEach-Object { $_.Trim() }
    $excludeDirs = @('.git','.venv','.venv-pygame312','.history','node_modules','CarGame','~DOWNLOADS')
    $results = @()
    foreach ($pattern in $includePatterns) {
        $files = Get-ChildItem -Path $WorkspacePath -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $skip = $false
            foreach ($ed in $excludeDirs) {
                if ($f.FullName -match [regex]::Escape("\$ed\")) { $skip = $true; break }
            }
            if (-not $skip) {
                $relPath = $f.FullName.Substring($WorkspacePath.Length + 1) -replace '\\', '/'
                $results += [ordered]@{
                    name     = $f.Name
                    path     = $relPath
                    size     = $f.Length
                    modified = $f.LastWriteTime.ToString('o')
                }
            }
        }
    }
    # Deduplicate by path
    $seen = @{}
    $unique = @()
    foreach ($r in $results) {
        if (-not $seen.ContainsKey($r.path)) {
            $seen[$r.path] = $true
            $unique += $r
        }
    }
    $unique = @($unique | Sort-Object { $_.path })
    Send-Json -Context $Context -Object @{ files = $unique; count = @($unique).Count }
}

# ─── Route: static file serve ─────────────────────────────────────────────────
<#
.SYNOPSIS
Serve a static file from the workspace.
.DESCRIPTION
Reads and returns the content of a static file from the workspace.
.PARAMETER Context
The HttpListenerContext for the request.
.PARAMETER RelPath
The relative path to the file to serve.
#>
function Get-StaticFile {
    [CmdletBinding()]
    param($Context, [string]$RelPath)
    $content = Read-WorkspaceFile -RelativePath $RelPath
    if ($null -eq $content) {
        Send-Error -Context $Context -StatusCode 404 -Message "Not found: $RelPath"
        return
    }
    $ext = [System.IO.Path]::GetExtension($RelPath).ToLower()
    $ct = switch ($ext) {
        '.html'  { 'text/html; charset=utf-8'              }
        '.xhtml' { 'application/xhtml+xml; charset=utf-8'  }
        '.js'    { 'application/javascript; charset=utf-8' }
        '.css'   { 'text/css; charset=utf-8'               }
        '.json'  { 'application/json; charset=utf-8'       }
        default  { 'text/plain; charset=utf-8'             }
    }
    Send-Response -Context $Context -StatusCode 200 -ContentType $ct -Body $content
}

# ─── WebSocket handler (runs in scriptblock via background runspace) ───────────
<#
.SYNOPSIS
Handle a WebSocket connection for real-time events.
.DESCRIPTION
Accepts a WebSocket connection, registers the client, and manages the message loop.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Start-WebSocketHandler {
    [CmdletBinding()]
    param([System.Net.HttpListenerContext]$Context)
    try {
        $wsCtx = $Context.AcceptWebSocketAsync('').GetAwaiter().GetResult()
        $ws    = $wsCtx.WebSocket
        $wsId  = [System.Guid]::NewGuid().ToString()
        $WsClients.TryAdd($wsId, $ws) | Out-Null

        # Send hello + CSRF token
        $hello = @{ event = 'connected'; wsId = $wsId; csrfToken = $SessionToken; serverTime = (Get-Date -Format 'o') }
        $helloBytes = [System.Text.Encoding]::UTF8.GetBytes(($hello | ConvertTo-Json -Depth 3))
        $ws.SendAsync([System.ArraySegment[byte]]::new($helloBytes), `
            [System.Net.WebSockets.WebSocketMessageType]::Text, $true, `
            [System.Threading.CancellationToken]::None).Wait(3000) | Out-Null

        # Read loop
        $buf = New-Object byte[] 4096
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), `
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
            # Ping/keepalive — echo back
            $msgStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $result.Count)
            if ($msgStr -match '"type":"ping"') {
                $pong = [System.Text.Encoding]::UTF8.GetBytes('{"type":"pong"}')
                $ws.SendAsync([System.ArraySegment[byte]]::new($pong), `
                    [System.Net.WebSockets.WebSocketMessageType]::Text, $true, `
                    [System.Threading.CancellationToken]::None).Wait(1000) | Out-Null
            }
        }
    } catch { <# client disconnected #> }
    finally {
        $removed = $null
        $WsClients.TryRemove($wsId, [ref]$removed) | Out-Null
        try { $ws.Dispose() } catch { <# non-fatal #> }
    }
}

# ─── Main listener loop ────────────────────────────────────────────────────────
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
Write-BootstrapLog "HttpListener initialising on http://127.0.0.1:$Port/" 'INFO'
try {
    $listener.Start()
    Register-ConsoleShutdownHandler
    Write-Host ""
    Write-Host "  PowerShellGUI Local Web Engine" -ForegroundColor Cyan
    Write-Host "  Listening on http://127.0.0.1:$Port/" -ForegroundColor Cyan
    Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkCyan
    Write-Host ""
    Write-BootstrapLog "=== Bootstrap Complete — HttpListener active on port $Port ===" 'INFO'
    Write-EngineLog "Engine started on port $Port, workspace: $WorkspacePath" -Level 'INFO'
} catch {
    Write-BootstrapLog "FATAL: HttpListener failed to start on port $Port — $_" 'ERROR'
    Write-EngineLog "Failed to start HttpListener on port $Port — $_" -Level 'ERROR'
    Write-Error "Failed to start HttpListener on port $Port. $_"
    exit 1
}

if (-not $NoLaunchBrowser) {
    Start-Process "http://127.0.0.1:$Port/"
}

# Progress file path — polled in the main loop idle tick to broadcast to WS clients
$pgScanSub = if ($null -ne $cfg -and $null -ne $cfg.paths -and
                 $cfg.paths.PSObject.Properties.Name -contains 'scanProgressLog') {
                 $cfg.paths.scanProgressLog
             } else { Join-Path 'logs' 'scan-progress.json' }
$pgPath    = Join-Path $WorkspacePath $pgScanSub
$script:lastProgressContent = ''

try {
    # Use GetContextAsync + Task.Wait(ms) instead of BeginGetContext + AsyncWaitHandle.WaitOne
    # — the old APM pattern (BeginGetContext) has broken AsyncWaitHandle signalling in .NET 8+ (PS 7.x).
    # GetContextAsync works reliably on both .NET Framework 4.7.2 (PS 5.1) and .NET 8/9 (PS 7.x).
    $pendingTask = $null
    while ($listener.IsListening) {
        $context = $null
        try {
            if ($null -eq $pendingTask) {
                $pendingTask = $listener.GetContextAsync()
            }
            # Wait with timeout to allow graceful shutdown
            if (-not $pendingTask.Wait(500)) {
                # Check for graceful stop signal written by /api/engine/stop
                if (Test-Path -LiteralPath $script:StopSignalFile) {
                    Remove-Item -LiteralPath $script:StopSignalFile -Force -ErrorAction SilentlyContinue
                    Write-EngineLog 'Stop signal file detected — shutting down' -Level 'INFO'
                    $script:_ExitClean = $true
                    break
                }
                # Idle tick — broadcast any new scan-progress data to WebSocket clients
                try {
                    if (Test-Path -LiteralPath $pgPath) {
                        $raw = Get-Content -LiteralPath $pgPath -Raw -Encoding UTF8
                        if (-not [string]::IsNullOrEmpty($raw) -and $raw -ne $script:lastProgressContent) {
                            $script:lastProgressContent = $raw
                            Send-WsMessage -JsonMessage ('{"event":"scan_progress","data":' + $raw + '}')
                        }
                    }
                } catch { <# non-fatal — progress file may not exist yet #> }
                continue
            }
            $context = $pendingTask.Result
            $pendingTask = $null  # consumed — next iteration starts a new async accept
        } catch [System.Net.HttpListenerException] {
            break  # Listener stopped
        } catch {
            $pendingTask = $null  # discard faulted task
            continue
        }

        $req    = $context.Request
        $method = $req.HttpMethod.ToUpper()
        $url    = $req.Url.AbsolutePath.TrimEnd('/')
        if ([string]::IsNullOrEmpty($url)) { $url = '/' }

        # Legacy filename + permalink redirects for dependency visualisation page.
        $legacyRedirects = @{
            '/xhtml-dependencyvis.xhtml'                       = '/scripts/XHTML-Checker/XHTML-VisualisationVenn.xhtml'
            '/scripts/xhtml-checker/xhtml-dependencyvis.xhtml' = '/scripts/XHTML-Checker/XHTML-VisualisationVenn.xhtml'
            '/pages/xhtml-dependencyvis'                        = '/scripts/XHTML-Checker/XHTML-VisualisationVenn.xhtml'
            '/permalink/dependency-venn'                        = '/scripts/XHTML-Checker/XHTML-VisualisationVenn.xhtml'
            '/venn'                                              = '/scripts/XHTML-Checker/XHTML-VisualisationVenn.xhtml'
        }
        $urlKey = $url.ToLowerInvariant()
        if ($legacyRedirects.ContainsKey($urlKey)) {
            $target = $legacyRedirects[$urlKey]
            Send-Response -Context $context -StatusCode 302 -ContentType 'text/plain; charset=utf-8' -Body "Redirecting to $target" -ExtraHeaders @{ Location = $target }
            continue
        }

        # ── WebSocket upgrade ────────────────────────────────────────────
        if ($req.IsWebSocketRequest -and $url -eq '/ws') {
            # Start-Job creates a new process without script functions — use a runspace instead
            $wsCtxRef  = $context
            $wsClRef   = $WsClients
            $wsTokRef  = $SessionToken
            $wsPsInst  = [System.Management.Automation.PowerShell]::Create()
            $null = $wsPsInst.AddScript({
                param($wsCtx, $wsClients, $csrfToken)
                $wsId = $null
                $ws   = $null
                try {
                    $acc    = $wsCtx.AcceptWebSocketAsync('').GetAwaiter().GetResult()
                    $ws     = $acc.WebSocket
                    $wsId   = [System.Guid]::NewGuid().ToString()
                    $wsClients.TryAdd($wsId, $ws) | Out-Null
                    $hello  = @{ event='connected'; wsId=$wsId; csrfToken=$csrfToken; serverTime=(Get-Date -Format 'o') }
                    $helloB = [System.Text.Encoding]::UTF8.GetBytes(($hello | ConvertTo-Json -Depth 3))
                    $ws.SendAsync(
                        [System.ArraySegment[byte]]::new($helloB),
                        [System.Net.WebSockets.WebSocketMessageType]::Text,
                        $true,
                        [System.Threading.CancellationToken]::None
                    ).Wait(3000) | Out-Null
                    $buf = New-Object byte[] 4096
                    while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        $rcv = $ws.ReceiveAsync(
                            [System.ArraySegment[byte]]::new($buf),
                            [System.Threading.CancellationToken]::None
                        ).GetAwaiter().GetResult()
                        if ($rcv.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
                        $msg = [System.Text.Encoding]::UTF8.GetString($buf, 0, $rcv.Count)
                        if ($msg -match '"type":"ping"') {
                            $pongB = [System.Text.Encoding]::UTF8.GetBytes('{"type":"pong"}')
                            $ws.SendAsync(
                                [System.ArraySegment[byte]]::new($pongB),
                                [System.Net.WebSockets.WebSocketMessageType]::Text,
                                $true,
                                [System.Threading.CancellationToken]::None
                            ).Wait(1000) | Out-Null
                        }
                    }
                } catch { <# client disconnected #> }
                finally {
                    $removed = $null
                    if ($null -ne $wsId -and $null -ne $wsClients) {
                        $wsClients.TryRemove($wsId, [ref]$removed) | Out-Null
                    }
                    if ($null -ne $ws) { try { $ws.Dispose() } catch { <# Intentional: non-fatal, WebSocket disposal #> } }
                }
            }).AddArgument($wsCtxRef).AddArgument($wsClRef).AddArgument($wsTokRef)
            $null = $wsPsInst.BeginInvoke()   # fire-and-forget; runspace self-cleans on WS close
            continue
        }

        # ── CORS preflight ────────────────────────────────────────────────
        if ($method -eq 'OPTIONS') {
            Send-Response -Context $context -StatusCode 204 -Body ''
            continue
        }

        # ── API routes ───────────────────────────────────────────────────
        switch -Regex ($url) {
            '^/api/scan/status$' {
                if ($method -eq 'GET') { Get-ScanStatus -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/scan/crashes$' {
                if ($method -eq 'GET') { Get-ScanCrashes -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/scan/full$' {
                if ($method -eq 'POST') { Invoke-Scan -Context $context -ScanMode 'Full' } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/scan/incremental$' {
                if ($method -eq 'POST') { Invoke-Scan -Context $context -ScanMode 'Incremental' } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/scan/static$' {
                if ($method -eq 'POST') { Invoke-StaticScan -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/agent/stats$' {
                if ($method -eq 'GET') { Get-AgentStats -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/workspace/files$' {
                if ($method -eq 'GET') { Get-WorkspaceFiles -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/config/menus$' {
                if ($method -eq 'GET')      { Get-Menus -Context $context }
                elseif ($method -eq 'POST') { Save-Menus -Context $context }
                else                        { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/csrf-token$' {
                Send-Json -Context $context -Object @{ csrfToken = $SessionToken }
                break
            }
            '^/api/engine/status$' {
                if ($method -eq 'GET') { Get-EngineStatus -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/engine/log$' {
                if ($method -eq 'GET') { Get-EngineLog -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/engine/events$' {
                if ($method -eq 'GET') { Get-EngineEvents -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/engine/logs/list$' {
                if ($method -eq 'GET') { Get-EngineLogsList -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/engine/stop$' {
                if ($method -eq 'POST') {
                    $tok = $context.Request.Headers['X-CSRF-Token']
                    if ($null -eq $tok -or $tok -ne $SessionToken) {
                        Send-Error -Context $context -StatusCode 403 -Message 'CSRF token mismatch'
                    } else {
                        Send-Json -Context $context -Object @{ stopping = $true }
                        Request-EngineStop -Reason 'Stop requested via /api/engine/stop' -MarkClean
                    }
                } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            # ── Page routes ──────────────────────────────────────────────
            '^/$' {
                Get-StaticFile -Context $context -RelPath 'XHTML-WorkspaceHub.xhtml'
                break
            }
            '^/pages/dependency-vis$' {
                Get-StaticFile -Context $context -RelPath '~README.md\Dependency-Visualisation.html'
                break
            }
            '^/pages/menu-builder$' {
                Get-StaticFile -Context $context -RelPath 'scripts\XHTML-Checker\XHTML-MenuBuilder.xhtml'
                break
            }
            '^/pages/bw-vault$' {
                Get-StaticFile -Context $context -RelPath 'BW-Vault-Checklist.xhtml'
                break
            }
            # ── Static assets ────────────────────────────────────────────
            '^/styles/(.+)$' {
                $file = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
                Get-StaticFile -Context $context -RelPath "styles\$file"
                break
            }
            '^/scripts/(.+)$' {
                $file = $Matches[1]  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
                Get-StaticFile -Context $context -RelPath "scripts\$file"
                break
            }
            # ── Generic static file fallback (workspace-relative) ────────
            '^/(.+\.(xhtml|html|css|js|json|png|jpg|gif|svg|ico))$' {
                $relFile = $Matches[1] -replace '/', '\'  # SIN-EXEMPT: P027 - $Matches[N] accessed only after successful -match operator
                # P009: validate path does not escape workspace
                if ($relFile -match '\.\.' -or $relFile -match '[\x00-\x1f]') {
                    Send-Error -Context $context -StatusCode 400 -Message 'Invalid path'
                } else {
                    Get-StaticFile -Context $context -RelPath $relFile
                }
                break
            }
            default {
                Send-Error -Context $context -StatusCode 404 -Message "Route not found: $url"
            }
        }
    }
} finally {
    Unregister-ConsoleShutdownHandler
    $listener.Stop()
    $listener.Close()
    $exitKind = if ($script:_ExitClean) { 'CLEAN_STOP' } else { 'DIRTY_EXIT' }
    $exitMsg  = "Engine exited [$exitKind] at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host $exitMsg -ForegroundColor DarkCyan
    Write-EngineLog $exitMsg -Level 'INFO'
    # Write structured crash event on dirty exit
    if (-not $script:_ExitClean) {
        $crashEvent = [pscustomobject]@{
            exitKind     = $exitKind
            timestamp    = (Get-Date -Format 'o')
            pid          = $PID
            port         = $Port
            workspacePath= $WorkspacePath
            lastLogLine  = try {
                @(Get-Content -LiteralPath $script:EngineLogFile -Encoding UTF8 -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
            } catch { 'unavailable' }
        }
        try {
            $crashJson = $crashEvent | ConvertTo-Json -Depth 4
            Add-Content -LiteralPath $script:CrashLogFile -Value $crashJson -Encoding UTF8
        } catch { <# Intentional: non-fatal — crash log write failure cannot be recovered within crash handler #> }
        # Invoke crash cleanup script if it exists
        $cleanupScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-EngineCrashCleanup.ps1'
        if (Test-Path -LiteralPath $cleanupScript) {
            try { & $cleanupScript -WorkspacePath $WorkspacePath -Silent } catch { <# Intentional: non-fatal, cleanup is best-effort in crash handler #> }
        }
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





