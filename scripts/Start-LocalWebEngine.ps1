# VersionTag: 2605.B5.V46.0
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
if ([string]::IsNullOrEmpty($WorkspacePath)) {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}
if ($AsService -and $Action -eq 'Start') {
    $Action = 'RunAsService'
}

switch ($Action) {
    'Start' {
        # Continue into canonical in-process engine startup flow below.
    }
    'Stop' {
        $baseUrl = "http://127.0.0.1:$Port"
        $stopRequested = $false
        try {
            $csrfResp = Invoke-WebRequest -Uri ($baseUrl + '/api/csrf-token') -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $csrfObj = $csrfResp.Content | ConvertFrom-Json
            $token = if ($null -ne $csrfObj -and $csrfObj.PSObject.Properties.Name -contains 'csrfToken') { [string]$csrfObj.csrfToken } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $headers = @{ 'X-CSRF-Token' = $token; 'Content-Type' = 'application/json' }
                Invoke-WebRequest -Uri ($baseUrl + '/api/engine/stop') -Method Post -Headers $headers -Body '{}' -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop | Out-Null
                Write-Host "Stop requested via HTTP API on port $Port" -ForegroundColor Yellow
                $stopRequested = $true
            }
        } catch {
            Write-Host "Stop API request failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        if (-not $stopRequested) {
            $logsDir = Join-Path $WorkspacePath 'logs'
            $stopSignal = Join-Path $logsDir 'engine.stop'
            $pidFile = Join-Path $logsDir 'engine.pid'
            $pidValue = $null
            $pidRunning = $false

            if (Test-Path -LiteralPath $pidFile) {
                try {
                    $pidText = (Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8).Trim()
                    if ($pidText -match '^\d+$') {
                        $pidValue = [int]$pidText
                        $pidRunning = @((Get-Process -Id $pidValue -ErrorAction SilentlyContinue)).Count -gt 0
                    }
                } catch {
                    $pidRunning = $false
                }
            }

            if ($pidRunning) {
                try {
                    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
                    Set-Content -LiteralPath $stopSignal -Value '1' -Encoding UTF8 -Force
                    Write-Host "Stop signal file written: $stopSignal" -ForegroundColor Yellow
                    $stopRequested = $true
                } catch {
                    Write-Host "Failed to write stop signal: $($_.Exception.Message)" -ForegroundColor DarkYellow
                }

                if ($Force -and $null -ne $pidValue) {
                    try {
                        Stop-Process -Id $pidValue -Force -ErrorAction Stop
                        Write-Host "Force-stopped engine PID $pidValue" -ForegroundColor Yellow
                        $stopRequested = $true
                    } catch {
                        Write-Host "Force stop failed: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                if (Test-Path -LiteralPath $stopSignal) {
                    Remove-Item -LiteralPath $stopSignal -Force -ErrorAction SilentlyContinue
                }
                Write-Host "Engine is not running on port $Port. Nothing to stop." -ForegroundColor DarkYellow
                exit 0
            }
        }

        if ($stopRequested) { exit 0 }
        exit 1
    }
    'Restart' {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { $null }
        if ($null -eq $hostExe) {
            Write-Host 'No PowerShell host available for restart.' -ForegroundColor Red
            exit 1
        }

        $scriptPath = $MyInvocation.MyCommand.Path
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Stop -Port $Port -WorkspacePath $WorkspacePath -NoLaunchBrowser:$NoLaunchBrowser -Force:$Force
        Start-Sleep -Milliseconds 700
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Start -Port $Port -WorkspacePath $WorkspacePath -NoLaunchBrowser:$NoLaunchBrowser -Force:$Force
        exit $LASTEXITCODE
    }
    'Status' {
        $statusUrl = "http://127.0.0.1:$Port/api/engine/status"
        try {
            $resp = Invoke-WebRequest -Uri $statusUrl -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
            Write-Host $resp.Content
            exit 0
        } catch {
            Write-Host "Engine offline on port $Port" -ForegroundColor Yellow
            exit 1
        }
    }
    'LaunchWebpage' {
        Start-Process "http://127.0.0.1:$Port/"
        exit 0
    }
    'RunAsService' {
        $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { $null }
        if ($null -eq $hostExe) {
            Write-Host 'No PowerShell host available for RunAsService.' -ForegroundColor Red
            exit 1
        }

        $serviceArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$MyInvocation.MyCommand.Path,'-Action','Start','-Port',$Port,'-WorkspacePath',$WorkspacePath)
        if ($NoLaunchBrowser) { $serviceArgs += @('-NoLaunchBrowser') }
        if ($Force) { $serviceArgs += @('-Force') }
        $svcProc = Start-Process -FilePath $hostExe -ArgumentList $serviceArgs -PassThru -WindowStyle Hidden
        Write-Host "RunAsService launched hidden PID $($svcProc.Id) on port $Port" -ForegroundColor Cyan
        exit 0
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
$script:EngineLogFile      = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-stdout.log'
$script:BootstrapLogFile   = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-bootstrap.log'
$script:CrashLogFile       = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-crash.log'
$script:EngineInstanceFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-instance-current.json'
$script:StopSignalFile     = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.stop'
$script:_ExitClean         = $false   # set $true on graceful stop; $false = dirty exit
$script:_BootstrapErrors   = [System.Collections.ArrayList]@()
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

# ─── Write engine instance state file ──────────────────────────────────────────
<#
.SYNOPSIS
Write engine instance state (Running/Stopped) to engine-instance-current.json
.DESCRIPTION
Creates or updates engine-instance-current.json with heartbeat info for offline detection.
.PARAMETER State
Instance state: 'Running' or 'Stopped'.
.PARAMETER CleanStop
Whether stop was graceful (true) or dirty exit (false).
.PARAMETER ExitKind
Exit kind: CLEAN_STOP, DIRTY_EXIT, or null if running.
#>
function Write-EngineInstanceState {
    [CmdletBinding()]
    param(
        [ValidateSet('Running', 'Stopped')][string]$State = 'Running',
        [bool]$CleanStop = $false,
        [string]$ExitKind = $null
    )
    try {
        $instanceData = @{
            state       = $State
            pid         = $PID
            port        = $Port
            startedAt   = if ($State -eq 'Running') { $script:_EngineStartTime } else { $null }
            stoppedAt   = if ($State -eq 'Stopped') { (Get-Date -Format 'o') } else { $null }
            cleanStop   = $CleanStop
            exitKind    = $ExitKind
            serverTime  = (Get-Date -Format 'o')
            workspacePath = $WorkspacePath
        }
        $json = $instanceData | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $script:EngineInstanceFile -Value $json -Encoding UTF8 -Force
    } catch {
        Write-EngineLog "Failed to write instance state: $_" -Level 'WARN'
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
    if ($reqOrigin -and ($reqOrigin -eq 'null' -or $reqOrigin -match '^(https?://(127\.0\.0\.1|localhost)(:\d+)?$)|^file://|^vscode-webview://|^vscode-file://|^vscode://|^https?://[^/]*vscode[^/]*(:\d+)?$|^https?://[^/]*vscode-cdn\.net(:\d+)?$')) {
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
    $upSec = [int]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency - $script:_EngineStartEpoch)
    $nowIso = (Get-Date -Format 'o')
    Send-Json -Context $Context -Object @{
        running     = $true
        responding  = $true
        pid         = $PID
        port        = $Port
        state       = 'Running'
        uptime      = $upSec
        uptimeSec   = $upSec
        startupTime = $script:_EngineStartTime
        startedAt   = $script:_EngineStartTime
        serverTime  = $nowIso
        heartbeat   = @{
            ok         = $true
            status     = 'alive'
            ageSec     = 0
            at         = $nowIso
            startedAt  = $script:_EngineStartTime
            uptime     = $upSec
            serverTime = $nowIso
        }
        instanceFile = $script:EngineInstanceFile
    }
}
$script:_EngineStartTime  = (Get-Date -Format 'o')
$script:_EngineStartEpoch = [System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency

# ─── Route: GET /api/engine/log?name=stdout|stderr|service ───────────────────
<#
.SYNOPSIS
Get the latest engine log lines.
.DESCRIPTION
Returns the last N lines from the specified engine log file as JSON.
Supports ?name=<logname> and ?tail=<count> query parameters.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-EngineLog {
    [CmdletBinding()]
    param($Context)
    # Allowed log file names only — prevent path traversal
    $nameParam = $Context.Request.QueryString['name']
    $tailParam = $Context.Request.QueryString['tail']
    $allowedNames = @{ stdout = 'engine-stdout.log'; stderr = 'engine-stderr.log'; service = 'engine-service.log'; bootstrap = 'engine-bootstrap.log'; crash = 'engine-crash.log' }
    $logKey = if ($null -ne $nameParam -and $allowedNames.ContainsKey($nameParam)) { $nameParam } else { 'stdout' }
    $tail = if ($null -ne $tailParam -and $tailParam -match '^\d+$') { [int]$tailParam } else { 50 }
    if ($tail -gt 5000) { $tail = 5000 }  # cap max tail
    $logFile = Join-Path $WorkspacePath (Join-Path 'logs' $allowedNames[$logKey])
    $lines = @()
    if (Test-Path -LiteralPath $logFile) {
        $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail $tail -ErrorAction SilentlyContinue)
    }
    Send-Json -Context $Context -Object @{
        logName  = $logKey
        logFile  = $logFile
        lines    = $lines
        lineCount = @($lines).Count
        tail     = $tail
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
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        try {
            $bodyStr = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        $parsed = $bodyStr | ConvertFrom-Json
        $menuFile = Join-Path $WorkspacePath 'config'
        $menuFile = Join-Path $menuFile 'menu-layout.json'
        Set-Content -LiteralPath $menuFile -Value ($parsed | ConvertTo-Json -Depth 8) -Encoding UTF8 -Force
        Send-Json -Context $Context -Object @{ saved = $true }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Save failed: $_"
    }
}

# ─── Route: GET /api/config/bootstrap-menu ───────────────────────────────────
<#
.SYNOPSIS
Get bootstrap tray menu configuration.
.DESCRIPTION
Returns the bootstrap tray menu configuration JSON used by Start-LocalWebEngineService.ps1.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-BootstrapMenuConfig {
    [CmdletBinding()]
    param($Context)

    $cfgFile = Join-Path (Join-Path $WorkspacePath 'config') 'bootstrap-menu.config.json'
    $obj = $null
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $obj = (Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8) | ConvertFrom-Json
        } catch {
            Send-Error -Context $Context -StatusCode 500 -Message "Config parse failed: $_"
            return
        }
    }
    if ($null -eq $obj) {
        $obj = [ordered]@{
            schema = 'BootstrapMenuConfig/1.0'
            headings = @()
        }
    }
    Send-Json -Context $Context -Object $obj
}

function Test-BootstrapMenuConfigObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Config,
        [ref]$ValidationError
    )

    $ValidationError.Value = ''

    if ($null -eq $Config) {
        $ValidationError.Value = 'payload is null'
        return $false
    }

    if (-not ($Config.PSObject.Properties.Name -contains 'headings')) {
        $ValidationError.Value = 'headings[] is required'
        return $false
    }

    if (-not ($Config.PSObject.Properties.Name -contains 'schema') -or [string]::IsNullOrWhiteSpace([string]$Config.schema)) {
        $Config | Add-Member -NotePropertyName schema -NotePropertyValue 'BootstrapMenuConfig/1.0' -Force
    }

    $headings = @($Config.headings)
    $allowedTypes = @('url','file','folder','script','engineaction','enginekill','command','webpagescripts','separator')

    for ($h = 0; $h -lt @($headings).Count; $h++) {
        $heading = $headings[$h]
        $headingName = if ($null -ne $heading -and $heading.PSObject.Properties.Name -contains 'name') { [string]$heading.name } else { '' }
        if ([string]::IsNullOrWhiteSpace($headingName)) {
            $ValidationError.Value = "headings[$h].name is required"
            return $false
        }

        if ($null -eq $heading -or -not ($heading.PSObject.Properties.Name -contains 'items')) {
            $ValidationError.Value = "headings[$h].items is required"
            return $false
        }

        $items = @($heading.items)
        for ($i = 0; $i -lt @($items).Count; $i++) {
            $item = $items[$i]
            if ($null -eq $item) {
                $ValidationError.Value = "headings[$h].items[$i] is null"
                return $false
            }

            $itemType = if ($item.PSObject.Properties.Name -contains 'type') { [string]$item.type } else { '' }
            if ([string]::IsNullOrWhiteSpace($itemType)) {
                $ValidationError.Value = "headings[$h].items[$i].type is required"
                return $false
            }

            $itemTypeLower = $itemType.ToLowerInvariant()
            if ($allowedTypes -notcontains $itemTypeLower) {
                $ValidationError.Value = "headings[$h].items[$i].type '$itemType' is not supported"
                return $false
            }

            if ($itemTypeLower -eq 'separator') {
                continue
            }

            if ($itemTypeLower -eq 'webpagescripts') {
                if (-not ($item.PSObject.Properties.Name -contains 'sourcePages') -or @($item.sourcePages).Count -eq 0) {
                    $ValidationError.Value = "headings[$h].items[$i].sourcePages[] is required for webpageScripts"
                    return $false
                }
                continue
            }

            $target = if ($item.PSObject.Properties.Name -contains 'target') { [string]$item.target } else { '' }
            if ([string]::IsNullOrWhiteSpace($target)) {
                $ValidationError.Value = "headings[$h].items[$i].target is required"
                return $false
            }
        }
    }

    return $true
}

function New-BootstrapMenuSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ConfigFile)

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        return $null
    }

    try {
        $configRoot = Join-Path $WorkspacePath 'config'
        $historyDir = Join-Path $configRoot 'bootstrap-menu.history'
        if (-not (Test-Path -LiteralPath $historyDir)) {
            New-Item -Path $historyDir -ItemType Directory -Force | Out-Null
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $snapshotName = "bootstrap-menu.config.$stamp.json"
        $snapshotPath = Join-Path $historyDir $snapshotName

        Copy-Item -LiteralPath $ConfigFile -Destination $snapshotPath -Force -ErrorAction Stop
        return ($snapshotPath.Substring($WorkspacePath.Length + 1) -replace '\\', '/')
    } catch {
        Write-BootstrapLog "Bootstrap snapshot creation failed: $_" 'WARN'
        return $null
    }
}

function Get-BootstrapMenuSnapshots {
    [CmdletBinding()]
    param()

    $historyDir = Join-Path (Join-Path $WorkspacePath 'config') 'bootstrap-menu.history'
    if (-not (Test-Path -LiteralPath $historyDir)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $historyDir -File -Filter 'bootstrap-menu.config.*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )
}

function Invoke-BootstrapMenuSnapshotRetention {
    [CmdletBinding()]
    param([int]$Keep = 50)

    if ($Keep -lt 1) {
        $Keep = 1
    }

    $snapshots = @(Get-BootstrapMenuSnapshots)
    if (@($snapshots).Count -le $Keep) {
        return 0
    }

    $removedCount = 0
    $toRemove = @($snapshots | Select-Object -Skip $Keep)
    foreach ($snapshot in $toRemove) {
        try {
            Remove-Item -LiteralPath $snapshot.FullName -Force -ErrorAction Stop
            $removedCount++
        } catch {
            Write-BootstrapLog "Bootstrap snapshot retention removal failed for $($snapshot.FullName): $_" 'WARN'
        }
    }

    return $removedCount
}

function Resolve-BootstrapRollbackSnapshot {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$RequestedSnapshot,
        [AllowEmptyString()] [string]$ExcludeSnapshotLeaf
    )

    $snapshots = @(Get-BootstrapMenuSnapshots)
    if (@($snapshots).Count -eq 0) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($RequestedSnapshot)) {
        foreach ($snap in $snapshots) {
            if ([string]::IsNullOrWhiteSpace($ExcludeSnapshotLeaf) -or $snap.Name -ne $ExcludeSnapshotLeaf) {
                return $snap
            }
        }
        return $null
    }

    $requestedLeaf = Split-Path -Path ($RequestedSnapshot -replace '/', '\\') -Leaf
    if ([string]::IsNullOrWhiteSpace($requestedLeaf)) {
        return $null
    }

    if ($requestedLeaf -notmatch '^bootstrap-menu\.config\.\d{8}-\d{6}-\d{3}\.json$') {
        return $null
    }

    foreach ($snap in $snapshots) {
        if ($snap.Name -eq $requestedLeaf) {
            if (-not [string]::IsNullOrWhiteSpace($ExcludeSnapshotLeaf) -and $snap.Name -eq $ExcludeSnapshotLeaf) {
                return $null
            }
            return $snap
        }
    }

    return $null
}

function Get-BootstrapMenuSnapshotHistory {
    [CmdletBinding()]
    param($Context)

    try {
        $items = @()
        $snapshots = @(Get-BootstrapMenuSnapshots)
        foreach ($snapshot in $snapshots) {
            $items += [ordered]@{
                name = [string]$snapshot.Name
                path = ($snapshot.FullName.Substring($WorkspacePath.Length + 1) -replace '\\', '/')
                modifiedUtc = $snapshot.LastWriteTimeUtc.ToString('o')
                size = [int64]$snapshot.Length
            }
        }

        Send-Json -Context $Context -Object @{
            snapshots = $items
            count = @($items).Count
        }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "History query failed: $_"
    }
}

function Rollback-BootstrapMenuConfig {
    [CmdletBinding()]
    param($Context)

    $incomingToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $incomingToken -or $incomingToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }

    try {
        $requestedSnapshot = ''
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        try {
            $bodyStr = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($bodyStr)) {
            $rollbackReq = $null
            try {
                $rollbackReq = $bodyStr | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Send-Error -Context $Context -StatusCode 400 -Message 'Invalid rollback payload: malformed JSON'
                return
            }

            if ($null -ne $rollbackReq -and $rollbackReq.PSObject.Properties.Name -contains 'snapshot') {
                $requestedSnapshot = [string]$rollbackReq.snapshot
            }
        }

        $cfgFile = Join-Path (Join-Path $WorkspacePath 'config') 'bootstrap-menu.config.json'
        if (-not (Test-Path -LiteralPath $cfgFile)) {
            Send-Error -Context $Context -StatusCode 404 -Message 'Bootstrap config file not found'
            return
        }

        $backupBeforeRollback = New-BootstrapMenuSnapshot -ConfigFile $cfgFile
        $backupLeaf = ''
        if (-not [string]::IsNullOrWhiteSpace($backupBeforeRollback)) {
            $backupLeaf = Split-Path -Path $backupBeforeRollback -Leaf
        }

        $sourceSnapshot = Resolve-BootstrapRollbackSnapshot -RequestedSnapshot $requestedSnapshot -ExcludeSnapshotLeaf $backupLeaf

        if ($null -eq $sourceSnapshot -and [string]::IsNullOrWhiteSpace($requestedSnapshot)) {
            Send-Error -Context $Context -StatusCode 404 -Message 'No bootstrap snapshots available for rollback'
            return
        }

        if ($null -eq $sourceSnapshot) {
            Send-Error -Context $Context -StatusCode 404 -Message "Requested snapshot not found or not eligible: $requestedSnapshot"
            return
        }

        Copy-Item -LiteralPath $sourceSnapshot.FullName -Destination $cfgFile -Force -ErrorAction Stop

        $restoredHeadingsCount = 0
        try {
            $restoredObj = (Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($null -ne $restoredObj -and $restoredObj.PSObject.Properties.Name -contains 'headings') {
                $restoredHeadingsCount = @($restoredObj.headings).Count
            }
        } catch {
            $restoredHeadingsCount = 0
        }

        $retainedRemoved = Invoke-BootstrapMenuSnapshotRetention -Keep 50
        $restoredFromRel = ($sourceSnapshot.FullName.Substring($WorkspacePath.Length + 1) -replace '\\', '/')

        Send-Json -Context $Context -Object @{
            rolledBack = $true
            file = 'config/bootstrap-menu.config.json'
            restoredFrom = $restoredFromRel
            requestedSnapshot = $requestedSnapshot
            backupCreated = $backupBeforeRollback
            headings = $restoredHeadingsCount
            removedSnapshots = $retainedRemoved
        }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Rollback failed: $_"
    }
}

# ─── Route: POST /api/config/bootstrap-menu ──────────────────────────────────
<#
.SYNOPSIS
Save bootstrap tray menu configuration.
.DESCRIPTION
Validates and writes bootstrap tray menu configuration JSON used by Start-LocalWebEngineService.ps1.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Save-BootstrapMenuConfig {
    [CmdletBinding()]
    param($Context)

    $incomingToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $incomingToken -or $incomingToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }

    try {
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        try {
            $bodyStr = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        $parsed = $bodyStr | ConvertFrom-Json
        if ($null -eq $parsed) {
            Send-Error -Context $Context -StatusCode 400 -Message 'Invalid payload: body is empty or malformed JSON'
            return
        }

        if ($parsed.PSObject.Properties.Name -contains 'schema' -and -not [string]::IsNullOrWhiteSpace([string]$parsed.schema)) {
            if ([string]$parsed.schema -ne 'BootstrapMenuConfig/1.0') {
                Send-Error -Context $Context -StatusCode 400 -Message "Unsupported schema: $($parsed.schema)"
                return
            }
        } else {
            $parsed | Add-Member -NotePropertyName schema -NotePropertyValue 'BootstrapMenuConfig/1.0' -Force
        }

        $validationError = ''
        if (-not (Test-BootstrapMenuConfigObject -Config $parsed -ValidationError ([ref]$validationError))) {
            Send-Error -Context $Context -StatusCode 400 -Message "Invalid payload: $validationError"
            return
        }

        $cfgFile = Join-Path (Join-Path $WorkspacePath 'config') 'bootstrap-menu.config.json'
        $snapshotRel = New-BootstrapMenuSnapshot -ConfigFile $cfgFile
        Set-Content -LiteralPath $cfgFile -Value ($parsed | ConvertTo-Json -Depth 12) -Encoding UTF8 -Force
        $retainedRemoved = Invoke-BootstrapMenuSnapshotRetention -Keep 50
        Send-Json -Context $Context -Object @{
            saved = $true
            file = 'config/bootstrap-menu.config.json'
            schema = [string]$parsed.schema
            snapshot = $snapshotRel
            removedSnapshots = $retainedRemoved
        }
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

# ─── Route: GET /api/hub/version ─────────────────────────────────────────────
<#
.SYNOPSIS
Get the canonical workspace VersionTag from CHANGELOG.md.
.DESCRIPTION
Reads the first '# VersionTag: <tag>' line from CHANGELOG.md and returns it as JSON.
Falls back to '0000.B0.V0.0' if the file is missing or unreadable.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-HubVersion {
    [CmdletBinding()]
    param($Context)
    $tag = '0000.B0.V0.0'
    $source = 'fallback'
    $generatedAt = (Get-Date -Format 'o')
    try {
        $clog = Join-Path $WorkspacePath 'CHANGELOG.md'
        if (Test-Path -LiteralPath $clog) {
            $first = Get-Content -LiteralPath $clog -TotalCount 1 -Encoding UTF8
            if ($null -ne $first -and $first -match '^\s*#\s*VersionTag:\s*([0-9]{4}\.B\d+\.V\d+\.\d+)') {
                $tag = $Matches[1]
                $source = 'CHANGELOG.md'
            }
        }
    } catch { <# non-fatal — keep fallback #> }
    Send-Json -Context $Context -Object @{
        versionTag  = $tag
        source      = $source
        generatedAt = $generatedAt
    }
}

# ─── Route: GET /api/hub/schema ──────────────────────────────────────────────
<#
.SYNOPSIS
Get the WorkspaceHub schema contract.
.DESCRIPTION
Returns schema version, supported schemas, and server time.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-HubSchema {
    [CmdletBinding()]
    param($Context)
    Send-Json -Context $Context -Object @{
        schemaVersion = 'PwShGUI-Hub/1.0'
        supportedSchemas = @('PwShGUI-Hub/1.0', 'legacy/scan-v1')
        serverTime = (Get-Date -Format 'o')
    }
}

# ─── Route: GET /api/history/list ───────────────────────────────────────────
<#
.SYNOPSIS
Get aggregated history from cron-aiathon-history.json and action-log.json.
.DESCRIPTION
Returns up to 100 recent history entries, sorted by timestamp descending.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-HistoryList {
    [CmdletBinding()]
    param($Context)
    $historyFile   = Join-Path (Join-Path $WorkspacePath 'logs') 'cron-aiathon-history.json'
    $actionLogFile = Join-Path (Join-Path $WorkspacePath 'todo') 'action-log.json'
    $engineHistFile= Join-Path (Join-Path $WorkspacePath 'logs') 'engine-runtime-history.jsonl'
    $items = [System.Collections.ArrayList]@()

    # Load cron-aiathon-history.json entries (scheduled scan jobs)
    if (Test-Path -LiteralPath $historyFile) {
        try {
            $histData = Get-Content -LiteralPath $historyFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $histData -and $histData.PSObject.Properties.Name -contains 'tasks') {
                foreach ($task in @($histData.tasks)) {
                    if ($null -ne $task) {
                        $null = $items.Add(@{
                            source    = 'cron-history'
                            eventType = if ($task.PSObject.Properties.Name -contains 'taskName') { $task.taskName } else { 'cron-task' }
                            id        = if ($task.PSObject.Properties.Name -contains 'taskId') { $task.taskId } else { '' }
                            title     = if ($task.PSObject.Properties.Name -contains 'taskName') { $task.taskName } else { 'Unknown' }
                            timestamp = if ($task.PSObject.Properties.Name -contains 'endTime') { $task.endTime } else { if ($task.PSObject.Properties.Name -contains 'startTime') { $task.startTime } else { '' } }
                            success   = if ($task.PSObject.Properties.Name -contains 'success') { $task.success } else { $null }
                            duration  = if ($task.PSObject.Properties.Name -contains 'durationMs') { ([math]::Round($task.durationMs/1000,1).ToString() + 's') } else { '' }
                        })
                    }
                }
            }
        } catch { <# non-fatal — skip unreadable history #> }
    }

    # Load action-log.json entries (todo/bug status changes)
    if (Test-Path -LiteralPath $actionLogFile) {
        try {
            $logData = Get-Content -LiteralPath $actionLogFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $logData -and $logData.PSObject.Properties.Name -contains 'actions') {
                foreach ($action in @($logData.actions)) {
                    if ($null -ne $action) {
                        $null = $items.Add(@{
                            source    = 'action-log'
                            eventType = if ($action.PSObject.Properties.Name -contains 'source') { $action.source } else { 'action' }
                            id        = if ($action.PSObject.Properties.Name -contains 'id') { $action.id } else { '' }
                            title     = if ($action.PSObject.Properties.Name -contains 'title') { $action.title } else { 'Action' }
                            timestamp = if ($action.PSObject.Properties.Name -contains 'timestamp') { $action.timestamp } else { '' }
                            status    = if ($action.PSObject.Properties.Name -contains 'status') { $action.status } else { '' }
                        })
                    }
                }
            }
        } catch { <# non-fatal — skip unreadable action log #> }
    }

    # Load engine-runtime-history.jsonl entries (engine/scan-job lifecycle events)
    if (Test-Path -LiteralPath $engineHistFile) {
        try {
            $lines = @(Get-Content -LiteralPath $engineHistFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            foreach ($ln in $lines) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                try {
                    $evt = $ln | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $evt) { continue }
                    $null = $items.Add(@{
                        source    = 'engine-runtime'
                        eventType = if ($evt.PSObject.Properties.Name -contains 'type') { $evt.type } else { 'engine-event' }
                        id        = if ($evt.PSObject.Properties.Name -contains 'pid') { ('pid-' + $evt.pid) } else { '' }
                        title     = if ($evt.PSObject.Properties.Name -contains 'target') { ($evt.target + ' / ' + $evt.type) } else { $evt.type }
                        timestamp = if ($evt.PSObject.Properties.Name -contains 'timestamp') { $evt.timestamp } else { '' }
                        status    = if ($evt.PSObject.Properties.Name -contains 'result') { $evt.result } else { '' }
                        version   = if ($evt.PSObject.Properties.Name -contains 'version') { $evt.version } else { '' }
                    })
                } catch { <# skip malformed jsonl line #> }
            }
        } catch { <# non-fatal — skip unreadable engine history #> }
    }

    # Sort by timestamp descending, return top 500 across all sources
    $sorted = @($items | Sort-Object { $_.timestamp } -Descending | Select-Object -First 500)
    # Emit both 'items' and 'history' aliases for frontend compatibility
    Send-Json -Context $Context -Object @{
        items   = $sorted
        history = $sorted
        count   = @($sorted).Count
        sources = @('cron-history','action-log','engine-runtime')
    }
}

# ─── Route: GET /api/pipeline/approvals ──────────────────────────────────────
<#
.SYNOPSIS
Get pending approval items from todo/*.json files.
.DESCRIPTION
Scans todo folder for items with status=PENDING_APPROVAL.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Get-PipelineApprovals {
    [CmdletBinding()]
    param($Context)
    $todoDir = Join-Path $WorkspacePath 'todo'
    $approvals = [System.Collections.ArrayList]@()
    
    if (Test-Path -LiteralPath $todoDir) {
        $jsonFiles = @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($file in $jsonFiles) {
            try {
                $obj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $obj) {
                    $status = if ($obj.PSObject.Properties.Name -contains 'status') { [string]$obj.status } else { '' }
                    if ($status -ceq 'PENDING_APPROVAL') {  # case-sensitive per governance
                        $null = $approvals.Add(@{
                            id = if ($obj.PSObject.Properties.Name -contains 'id') { $obj.id } else { $file.BaseName }
                            type = if ($obj.PSObject.Properties.Name -contains 'type') { $obj.type } else { 'Unknown' }
                            title = if ($obj.PSObject.Properties.Name -contains 'title') { $obj.title } else { '' }
                            priority = if ($obj.PSObject.Properties.Name -contains 'priority') { $obj.priority } else { 'MEDIUM' }
                            created = if ($obj.PSObject.Properties.Name -contains 'created') { $obj.created } else { '' }
                            description = if ($obj.PSObject.Properties.Name -contains 'description') { $obj.description } else { '' }
                            filePath = $file.FullName
                        })
                    }
                }
            } catch { <# non-fatal — skip unreadable todo file #> }
        }
    }
    
    $sorted = @($approvals | Sort-Object { $_.priority; $_.created } -Descending)
    Send-Json -Context $Context -Object @{ items = $sorted; count = @($sorted).Count }
}

# ─── Route: POST /api/pipeline/approvals ─────────────────────────────────────
<#
.SYNOPSIS
Apply approval actions (approve, reject, done) to items.
.DESCRIPTION
Expects JSON body: { action: 'approve'|'reject'|'done', ids: [...] }
Updates corresponding todo/*.json files with new status.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Set-PipelineApprovals {
    [CmdletBinding()]
    param($Context)
    # CSRF validation
    $csrfToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $csrfToken -or $csrfToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    
    # Read JSON body
    $bodyReader = [System.IO.StreamReader]::new($Context.Request.InputStream)
    $body = $bodyReader.ReadToEnd()
    $bodyReader.Close()
    
    $payload = $null
    try { $payload = $body | ConvertFrom-Json } catch { <# Intentional: invalid JSON #> }
    
    if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains 'action') -or -not ($payload.PSObject.Properties.Name -contains 'ids')) {
        Send-Error -Context $Context -StatusCode 400 -Message 'Missing action or ids in request body'
        return
    }
    
    $action = [string]$payload.action
    $ids = @($payload.ids)
    $statusMap = @{ 'approve' = 'IN_PROGRESS'; 'reject' = 'CLOSED'; 'done' = 'DONE' }
    $newStatus = $statusMap[$action]
    
    if ([string]::IsNullOrWhiteSpace($newStatus)) {
        Send-Error -Context $Context -StatusCode 400 -Message "Unknown action: $action"
        return
    }
    
    $todoDir = Join-Path $WorkspacePath 'todo'
    $updated = 0
    $failed = @()
    
    foreach ($id in $ids) {
        $idStr = [string]$id
        $foundFile = $null
        
        # Search for matching file
        if (Test-Path -LiteralPath $todoDir) {
            $jsonFiles = @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
            foreach ($file in $jsonFiles) {
                try {
                    $obj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $fileId = if ($obj.PSObject.Properties.Name -contains 'id') { [string]$obj.id } else { '' }
                    if ($fileId -eq $idStr) {
                        $foundFile = $file
                        break
                    }
                } catch { <# skip unreadable #> }
            }
        }
        
        if ($null -eq $foundFile) {
            $failed += $idStr
            continue
        }
        
        # Update status and write back
        try {
            $obj = Get-Content -LiteralPath $foundFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $obj | Add-Member -MemberType NoteProperty -Name 'status' -Value $newStatus -Force
            $obj | Add-Member -MemberType NoteProperty -Name 'modified' -Value (Get-Date -Format 'o') -Force
            $json = $obj | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $foundFile.FullName -Value $json -Encoding UTF8 -Force
            $updated++
        } catch {
            $failed += $idStr
        }
    }
    
    Send-Json -Context $Context -Object @{
        action = $action
        updated = $updated
        failed = $failed
        newStatus = $newStatus
    }
}

# ─── Route: POST /api/pipeline/process ──────────────────────────────────────
<#
.SYNOPSIS
Run the pipeline processor job (Invoke-PipelineProcess20.ps1).
.DESCRIPTION
Launches Invoke-PipelineProcess20.ps1 as a background job and returns job info.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Invoke-PipelineProcess {
    [CmdletBinding()]
    param($Context)
    # CSRF validation
    $csrfToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $csrfToken -or $csrfToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    
    $scriptPath = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-PipelineProcess20.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Send-Error -Context $Context -StatusCode 500 -Message 'Invoke-PipelineProcess20.ps1 not found'
        return
    }
    
    # Launch as background job
    $jobId = [guid]::NewGuid().ToString()
    $null = Start-Job -ScriptBlock {
        param($script, $ws)
        & powershell.exe -NoProfile -NonInteractive -File $script -WorkspacePath $ws -PassThru
    } -ArgumentList $scriptPath, $WorkspacePath -Name "pipeline-$jobId"
    
    Send-Json -Context $Context -Object @{
        started = $true
        jobId = $jobId
        script = $scriptPath
        timestamp = (Get-Date -Format 'o')
    } -StatusCode 202
}

# ─── Route: POST /api/test/crashdump ────────────────────────────────────────
<#
.SYNOPSIS
Create a test crash dump entry.
.DESCRIPTION
Writes a deterministic test crash dump to engine-crash.log for testing.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function New-TestCrashDump {
    [CmdletBinding()]
    param($Context)
    # CSRF validation
    $csrfToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $csrfToken -or $csrfToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    
    try {
        $testCrash = @{
            exitKind      = 'TEST_CRASH'
            timestamp     = (Get-Date -Format 'o')
            pid           = $PID
            port          = $Port
            workspacePath = $WorkspacePath
            reason        = 'Test crash dump created via /api/test/crashdump'
            testMarker    = 'TEST-' + [guid]::NewGuid().ToString().Substring(0, 8)
        } | ConvertTo-Json -Depth 4
        
        Add-Content -LiteralPath $script:CrashLogFile -Value $testCrash -Encoding UTF8
        Send-Json -Context $Context -Object @{ created = $true; type = 'crash'; timestamp = (Get-Date -Format 'o') }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Failed to create test crash: $_"
    }
}

# ─── Route: POST /api/test/eventlog ─────────────────────────────────────────
<#
.SYNOPSIS
Create a test event log entry.
.DESCRIPTION
Writes a deterministic test event to engine event logs for testing.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function New-TestEventLog {
    [CmdletBinding()]
    param($Context)
    # CSRF validation
    $csrfToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $csrfToken -or $csrfToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    
    try {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $testId = 'TEST-' + [guid]::NewGuid().ToString().Substring(0, 8)
        $eventLine = "[$ts][SERVICE][INFO] Test event: $testId"
        Add-Content -LiteralPath $script:EngineLogFile -Value $eventLine -Encoding UTF8
        Send-Json -Context $Context -Object @{ created = $true; type = 'event'; testId = $testId; timestamp = (Get-Date -Format 'o') }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Failed to create test event: $_"
    }
}

# ─── Route: POST /api/test/history ──────────────────────────────────────────
<#
.SYNOPSIS
Create a test history entry.
.DESCRIPTION
Appends a test entry to action-log.json for testing.
.PARAMETER Context
The HttpListenerContext for the request.
#>
function New-TestHistory {
    [CmdletBinding()]
    param($Context)
    # CSRF validation
    $csrfToken = $Context.Request.Headers['X-CSRF-Token']
    if ($null -eq $csrfToken -or $csrfToken -ne $SessionToken) {
        Send-Error -Context $Context -StatusCode 403 -Message 'CSRF token mismatch'
        return
    }
    
    try {
        $actionLogFile = Join-Path (Join-Path $WorkspacePath 'todo') 'action-log.json'
        $testId = 'TEST-' + [guid]::NewGuid().ToString().Substring(0, 8)
        $testAction = @{
            id = $testId
            title = "Test history entry: $testId"
            timestamp = (Get-Date -Format 'o')
            status = 'IN_PROGRESS'
            source = 'api-test'
        }
        
        # Append to action log (create if missing)
        if (Test-Path -LiteralPath $actionLogFile) {
            $log = Get-Content -LiteralPath $actionLogFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not ($log.PSObject.Properties.Name -contains 'actions')) {
                $log | Add-Member -MemberType NoteProperty -Name 'actions' -Value @()
            }
            $log.actions += $testAction
            $json = $log | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $actionLogFile -Value $json -Encoding UTF8 -Force
        } else {
            $newLog = @{ meta = @{ schema = 'PwShGUI-ActionLog/1.0'; description = 'Test log entry' }; actions = @($testAction) }
            $json = $newLog | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $actionLogFile -Value $json -Encoding UTF8 -Force
        }
        
        Send-Json -Context $Context -Object @{ created = $true; type = 'history'; testId = $testId; timestamp = (Get-Date -Format 'o') }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Failed to create test history: $_"
    }
}

# ─── Route: POST /api/runtime/tool-exit (no CSRF — sendBeacon) ──────────────
<#
.SYNOPSIS
Record a tool exit event via sendBeacon.
.DESCRIPTION
Appends to runtime history log on page unload. No CSRF validation (sendBeacon limitation).
.PARAMETER Context
The HttpListenerContext for the request.
#>
function Add-RuntimeToolExit {
    [CmdletBinding()]
    param($Context)
    try {
        $runtimeHistFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine-runtime-history.jsonl'
        $exitEvent = @{
            type = 'tool-exit'
            timestamp = (Get-Date -Format 'o')
            pid = $PID
            runtime = [int]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency - $script:_EngineStartEpoch)
        } | ConvertTo-Json -Depth 3
        
        Add-Content -LiteralPath $runtimeHistFile -Value $exitEvent -Encoding UTF8
        Send-Json -Context $Context -Object @{ recorded = $true; timestamp = (Get-Date -Format 'o') }
    } catch {
        Send-Error -Context $Context -StatusCode 500 -Message "Failed to record tool exit: $_"
    }
}

# ─── Main listener loop ────────────────────────────────────────────────────────
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
Write-BootstrapLog "HttpListener initialising on http://127.0.0.1:$Port/" 'INFO'
try {
    $listener.Start()
    Register-ConsoleShutdownHandler
    $pidFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.pid'
    try {
        Set-Content -LiteralPath $pidFile -Value $PID -Encoding UTF8 -Force
    } catch {
        Write-BootstrapLog "Unable to write PID file at ${pidFile}: $_" 'WARN'
    }
    # Write engine instance state
    Write-EngineInstanceState -State 'Running' -CleanStop $false -ExitKind $null
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
        if ($null -ne $legacyRedirects -and $legacyRedirects.Count -gt 0 -and $legacyRedirects.ContainsKey($urlKey)) {
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
            '^/api/config/bootstrap-menu$' {
                if ($method -eq 'GET')      { Get-BootstrapMenuConfig -Context $context }
                elseif ($method -eq 'POST') { Save-BootstrapMenuConfig -Context $context }
                else                        { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/config/bootstrap-menu/history$' {
                if ($method -eq 'GET') { Get-BootstrapMenuSnapshotHistory -Context $context }
                else                   { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/config/bootstrap-menu/rollback$' {
                if ($method -eq 'POST') { Rollback-BootstrapMenuConfig -Context $context }
                else                    { Send-Error -Context $context -StatusCode 405 }
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
            '^/api/hub/schema$' {
                if ($method -eq 'GET') { Get-HubSchema -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/hub/version$' {
                if ($method -eq 'GET') { Get-HubVersion -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/history/list$' {
                if ($method -eq 'GET') { Get-HistoryList -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/pipeline/approvals$' {
                if ($method -eq 'GET')  { Get-PipelineApprovals -Context $context }
                elseif ($method -eq 'POST') { Set-PipelineApprovals -Context $context }
                else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/pipeline/process$' {
                if ($method -eq 'POST') { Invoke-PipelineProcess -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/test/crashdump$' {
                if ($method -eq 'POST') { New-TestCrashDump -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/test/eventlog$' {
                if ($method -eq 'POST') { New-TestEventLog -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/test/history$' {
                if ($method -eq 'POST') { New-TestHistory -Context $context } else { Send-Error -Context $context -StatusCode 405 }
                break
            }
            '^/api/runtime/tool-exit$' {
                if ($method -eq 'POST') { Add-RuntimeToolExit -Context $context } else { Send-Error -Context $context -StatusCode 405 }
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
            '^/pages/bootstrap-menu-config$' {
                Get-StaticFile -Context $context -RelPath 'scripts\XHTML-Checker\XHTML-BootstrapMenuConfig.xhtml'
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
            '^/(.+\.(xhtml|html|md|css|js|json|png|jpg|gif|svg|ico))$' {
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
    $pidFileCleanup = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.pid'
    if (Test-Path -LiteralPath $pidFileCleanup) {
        try {
            Remove-Item -LiteralPath $pidFileCleanup -Force -ErrorAction Stop
        } catch {
            Write-EngineLog "PID cleanup warning: $($_.Exception.Message)" -Level 'WARN'
        }
    }
    $listener.Stop()
    $listener.Close()
    $exitKind = if ($script:_ExitClean) { 'CLEAN_STOP' } else { 'DIRTY_EXIT' }
    $exitMsg  = "Engine exited [$exitKind] at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host $exitMsg -ForegroundColor DarkCyan
    Write-EngineLog $exitMsg -Level 'INFO'
    # Write instance state before crash dump (so offline detection is immediate)
    Write-EngineInstanceState -State 'Stopped' -CleanStop $script:_ExitClean -ExitKind $exitKind
    # Write structured crash event on dirty exit
    if (-not $script:_ExitClean) {
        $lastLogLine = 'unavailable'
        try {
            $lastLogLine = @(Get-Content -LiteralPath $script:EngineLogFile -Encoding UTF8 -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
        } catch { <# Intentional: non-fatal, fallback already set to unavailable #> }

        $crashEvent = [pscustomobject]@{
            exitKind     = $exitKind
            timestamp    = (Get-Date -Format 'o')
            pid          = $PID
            port         = $Port
            workspacePath= $WorkspacePath
            lastLogLine  = $lastLogLine
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






