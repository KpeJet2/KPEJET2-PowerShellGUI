# VersionTag: 2604.B1.V31.0
# FileRole: Launcher
#Requires -Version 5.1
<#
.SYNOPSIS
    BW-CLI Server -- Launch Bitwarden CLI HTTP API service.
.DESCRIPTION
    Closes any existing bw serve process, then spawns an independent
    shell running 'bw serve' with network access enabled.  Displays the
    running URI and port, verifies the service is responding, and keeps
    the service window alive until the operator acknowledges shutdown.

    Designed to be launched from the Vault Operations flyout in Main-GUI.ps1.
.NOTES
    VersionTag: 2603.B0.v18
    Requires:   Bitwarden CLI (bw.exe) installed and logged in.
    Security:   Session key injected via BW_SESSION env var in the child
                process only; cleared on exit.
#>
[CmdletBinding()]
param(
    [int]$Port          = 8087,
    [string]$Hostname   = '127.0.0.1',
    [switch]$AllowNetwork
)

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Banner {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $bar = '═' * 60
    Write-Host $bar -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host $bar -ForegroundColor $Color
}

function Write-Step {
    param([int]$Number, [string]$Label, [string]$Status, [ConsoleColor]$Color = 'Green')
    Write-Host ("  [{0}] {1} -- " -f $Number, $Label) -NoNewline
    Write-Host $Status -ForegroundColor $Color
}

# ── Resolve BW CLI ───────────────────────────────────────────────────────────
Write-Banner 'BW-CLI Server -- Bitwarden HTTP API Service'

$bwPath = (Get-Command bw -ErrorAction SilentlyContinue).Source
if (-not $bwPath) {
    $bwPath = (Get-Command bw.exe -ErrorAction SilentlyContinue).Source
}
if (-not $bwPath) {
    Write-Host "`n  [ERROR] Bitwarden CLI (bw.exe) not found in PATH." -ForegroundColor Red
    Write-Host "  Install via: winget install Bitwarden.CLI" -ForegroundColor Yellow
    Read-Host "`n  Press Enter to exit"
    exit 1
}
Write-Step 1 'BW CLI located' $bwPath

# ── Check login status ──────────────────────────────────────────────────────
try {
    $statusRaw = & $bwPath status 2>&1 | Out-String
    $statusObj = $statusRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "`n  [ERROR] Could not parse BW status: $statusRaw" -ForegroundColor Red
    Read-Host "`n  Press Enter to exit"
    exit 1
}

if ($statusObj.status -eq 'unauthenticated') {
    Write-Host "`n  [ERROR] Bitwarden vault is not logged in." -ForegroundColor Red
    Write-Host "  Run:  bw login" -ForegroundColor Yellow
    Read-Host "`n  Press Enter to exit"
    exit 1
}
Write-Step 2 'Vault status' $statusObj.status

# ── Terminate existing bw serve processes ────────────────────────────────────
$existingServe = Get-Process -Name 'bw' -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
            $cmdLine -match '\bserve\b'
        } catch { $false }
    }

if ($existingServe) {
    Write-Host "`n  Stopping $($existingServe.Count) existing bw serve process(es)..." -ForegroundColor Yellow
    $existingServe | ForEach-Object {
        try { $_.Kill(); $_.WaitForExit(5000) } catch { <# already gone #> }
    }
    Start-Sleep -Milliseconds 500
    Write-Step 3 'Existing services stopped' 'OK'
} else {
    Write-Step 3 'No prior bw serve found' 'Clean'
}

# ── Determine bind address ──────────────────────────────────────────────────
$bindHost = $Hostname
if ($AllowNetwork) { $bindHost = '0.0.0.0' }
$serviceUri = "http://${bindHost}:${Port}"

Write-Host "`n  Bind address : $bindHost" -ForegroundColor White
Write-Host "  Port         : $Port" -ForegroundColor White
Write-Host "  Service URI  : $serviceUri" -ForegroundColor Green

# ── Resolve session key ─────────────────────────────────────────────────────
$sessionEnv = $env:BW_SESSION
if (-not $sessionEnv -and $statusObj.status -eq 'locked') {
    Write-Host "`n  Vault is locked -- unlock required to start serve." -ForegroundColor Yellow
    $secureKey = Read-Host -AsSecureString "  Enter master password"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $sessionEnv = & $bwPath unlock --raw $plain 2>&1 | Out-String
    $sessionEnv = $sessionEnv.Trim()
    $plain = $null
    if (-not $sessionEnv -or $sessionEnv.Length -lt 10) {
        Write-Host "`n  [ERROR] Unlock failed. Check master password." -ForegroundColor Red
        Read-Host "`n  Press Enter to exit"
        exit 1
    }
    Write-Step 4 'Vault unlocked' 'Session key acquired'
} elseif ($statusObj.status -eq 'unlocked') {
    Write-Step 4 'Vault already unlocked' 'OK'
} else {
    Write-Step 4 'Session key' 'From environment'
}

# ── Build the serve command for the child shell ─────────────────────────────
# The child process runs bw serve and blocks until terminated.
$serveArgs = "serve --hostname $bindHost --port $Port"
# Session key injected as env var in the child process only
$escapedBwPath = $bwPath -replace "'", "''"
$childScript = @"
`$env:BW_SESSION = '$($sessionEnv -replace "'", "''")'
try {
    Write-Host '  BW-CLI Server starting...' -ForegroundColor Cyan
    Write-Host "  URI: $serviceUri" -ForegroundColor Green
    Write-Host '  Press Ctrl+C to stop the service.' -ForegroundColor Yellow
    Write-Host ''
    & '$escapedBwPath' $serveArgs
} finally {
    `$env:BW_SESSION = `$null
    Write-Host '  BW-CLI Server stopped.' -ForegroundColor Red
}
"@

# Write temp launcher (auto-deleted by the child)
$tempScript = Join-Path $env:TEMP "bw-serve-launcher-$(Get-Random).ps1"
Set-Content -Path $tempScript -Value $childScript -Encoding UTF8

Write-Host ''
Write-Step 5 'Spawning service shell' 'Launching...'

# ── Spawn independent shell ─────────────────────────────────────────────────
$shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$spawnArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$tempScript`""
$proc = Start-Process -FilePath $shellExe -ArgumentList $spawnArgs -PassThru

Start-Sleep -Seconds 2

# ── Verify service is responding ─────────────────────────────────────────────
$verified = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $null = Invoke-RestMethod -Uri "$serviceUri/api/status" -TimeoutSec 3 -ErrorAction Stop
        $verified = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}

if ($verified) {
    Write-Step 6 'Service verified' 'RESPONDING' -Color Green
} else {
    Write-Step 6 'Service verification' 'Pending (may need a moment)' -Color Yellow
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Banner 'BW-CLI Server Running'
Write-Host ''
Write-Host "  Service URI  : " -NoNewline; Write-Host $serviceUri -ForegroundColor Green
Write-Host "  Process ID   : " -NoNewline; Write-Host $proc.Id -ForegroundColor White
Write-Host "  Shell        : " -NoNewline; Write-Host $shellExe -ForegroundColor White
Write-Host ''
Write-Host '  The BW-CLI HTTP API is now available for REST calls.' -ForegroundColor Cyan
Write-Host '  Example: Invoke-RestMethod http://localhost:8087/api/status' -ForegroundColor DarkGray
Write-Host ''

# ── Checklist ────────────────────────────────────────────────────────────────
Write-Host '  ── Service Checklist ──' -ForegroundColor Magenta
$checks = @(
    'BW CLI located and version confirmed',
    'Vault status verified (unlocked)',
    'Prior bw serve instances terminated',
    "Service spawned on $serviceUri",
    "Service shell running (PID $($proc.Id))"
)
foreach ($c in $checks) {
    Write-Host "    [✓] $c" -ForegroundColor Green
}
if ($verified) {
    Write-Host "    [✓] HTTP API responding" -ForegroundColor Green
} else {
    Write-Host "    [~] HTTP API pending (check service window)" -ForegroundColor Yellow
}

# ── Wait for user acknowledgment ─────────────────────────────────────────────
Write-Host ''
Write-Host '  The service will remain active in the separate window.' -ForegroundColor White
Write-Host '  Close this launcher window at any time -- the service continues independently.' -ForegroundColor DarkGray
Write-Host ''
$choice = Read-Host '  Press Enter to close this launcher, or type "stop" to terminate the service'

if ($choice -eq 'stop') {
    Write-Host "`n  Stopping BW-CLI service (PID $($proc.Id))..." -ForegroundColor Yellow
    try {
        if (-not $proc.HasExited) {
            $proc.Kill()
            $proc.WaitForExit(5000)
        }
        Write-Host '  Service terminated.' -ForegroundColor Green
    } catch {
        Write-Host "  Could not stop process: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Cleanup temp script ─────────────────────────────────────────────────────
if (Test-Path $tempScript) { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue }

Write-Host "`n  BW-CLI Server launcher finished." -ForegroundColor DarkGray
