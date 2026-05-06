# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# Test-WebEngineSustained.ps1
# Sustained I/O test: starts engine, runs sanitized requests for 15+ seconds,
# validates all responses, then performs clean shutdown with confirmation.
#Requires -Version 5.1
param(
    [int]$Port          = 8042,
    [int]$TestDuration  = 18,
    [string]$WorkspacePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($WorkspacePath)) {
    $WorkspacePath = Split-Path $ScriptDir -Parent
}

# ─── Colour helpers ──────────────────────────────────────────────────────────
function Write-T { param([string]$Msg, [string]$Color = 'Gray')
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

function Write-Pass { param([string]$Msg) Write-T "[PASS] $Msg" 'Green' }
function Write-Fail { param([string]$Msg) Write-T "[FAIL] $Msg" 'Red' }
function Write-Info { param([string]$Msg) Write-T "[INFO] $Msg" 'Cyan' }
function Write-Warn { param([string]$Msg) Write-T "[WARN] $Msg" 'Yellow' }

# ─── Results tracking ───────────────────────────────────────────────────────
$script:TestResults = [System.Collections.ArrayList]::new()
$script:PassCount   = 0
$script:FailCount   = 0

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail = '', [int]$Ms = 0)
    $null = $script:TestResults.Add([ordered]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
        Ms     = $Ms
    })
    if ($Passed) { $script:PassCount++; Write-Pass "$Name ($Ms ms)" }
    else         { $script:FailCount++; Write-Fail "$Name - $Detail" }
}

# ─── HTTP helper with sanitized output ───────────────────────────────────────
function Invoke-SafeRequest {
    param(
        [string]$Method  = 'GET',
        [string]$Path    = '/api/engine/status',
        [string]$Body    = '',
        [hashtable]$Headers = @{},
        [int]$TimeoutMs  = 5000
    )
    $url = "http://127.0.0.1:$Port$Path"
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method  = $Method
        $req.Timeout = $TimeoutMs
        $req.ContentType = 'application/json; charset=utf-8'
        foreach ($kv in $Headers.GetEnumerator()) {
            $req.Headers.Add($kv.Key, $kv.Value)
        }
        if ($Method -eq 'POST' -and -not [string]::IsNullOrEmpty($Body)) {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentLength = $bodyBytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Close()
        }
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        $sw.Stop()
        return [ordered]@{
            StatusCode = [int]$resp.StatusCode
            Body       = $content
            Headers    = $resp.Headers
            Ms         = $sw.ElapsedMilliseconds
            Error      = $null
        }
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $errResp = $_.Exception.Response
        $statusCode = if ($null -ne $errResp) { [int]$errResp.StatusCode } else { 0 }
        $errBody = ''
        if ($null -ne $errResp) {
            try {
                $errReader = New-Object System.IO.StreamReader($errResp.GetResponseStream())
                $errBody = $errReader.ReadToEnd()
                $errReader.Close()
            } catch { <# Intentional: non-fatal #> }
        }
        return [ordered]@{
            StatusCode = $statusCode
            Body       = $errBody
            Headers    = $null
            Ms         = $sw.ElapsedMilliseconds
            Error      = $_.Exception.Message
        }
    }
    catch {
        $sw.Stop()
        return [ordered]@{
            StatusCode = 0
            Body       = ''
            Headers    = $null
            Ms         = $sw.ElapsedMilliseconds
            Error      = $_.Exception.Message
        }
    }
}

# ─── Sanitized input vectors for injection/traversal testing ─────────────────
$script:MaliciousInputs = @(
    '../../../etc/passwd',
    '..\..\..\..\windows\system32\config\sam',
    '<script>alert(1)</script>',
    '"; DROP TABLE users; --',
    '%00%0d%0aInjected-Header: evil',
    'styles/../../config/sasc-vault-config.json',
    'styles/%2e%2e%2fconfig%2fsystem-variables.xml',
    [string]([char]0x00) + 'null-byte',
    'a' * 5000
)

# ════════════════════════════════════════════════════════════════════════════════
#                           PHASE 1: ENGINE STARTUP
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '  SUSTAINED WEB ENGINE TEST (15s+ constant I/O)' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''

# Check if engine already running
$preCheck = Invoke-SafeRequest -Path '/api/engine/status' -TimeoutMs 2000
$engineWasRunning = ($preCheck.StatusCode -eq 200)

if ($engineWasRunning) {
    Write-Info "Engine already running on port $Port - using existing instance"
} else {
    Write-Info "Starting engine directly..."
    $engineScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Start-LocalWebEngine.ps1'
    if (-not (Test-Path -LiteralPath $engineScript)) {
        Write-Fail "Engine script not found: $engineScript"
        exit 1
    }

    # Start engine in a separate process
    $startProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        "& '$engineScript' -Port $Port -WorkspacePath '$WorkspacePath' -NoLaunchBrowser"
    ) -PassThru

    # Wait for engine to respond
    $deadline = (Get-Date).AddSeconds(20)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $check = Invoke-SafeRequest -Path '/api/engine/status' -TimeoutMs 2000
        if ($check.StatusCode -eq 200) {
            $ready = $true
            break
        }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''

    if (-not $ready) {
        Write-Fail "Engine did not start within 20 seconds"
        exit 1
    }
    Write-Pass "Engine started and responding on port $Port (PID $($startProc.Id))"
}

# ════════════════════════════════════════════════════════════════════════════════
#                   PHASE 2: CSRF TOKEN ACQUISITION
# ════════════════════════════════════════════════════════════════════════════════
Write-Info "Acquiring CSRF token..."
$csrfResp = Invoke-SafeRequest -Path '/api/csrf-token'
$csrfToken = ''
if ($csrfResp.StatusCode -eq 200) {
    try {
        $csrfObj = $csrfResp.Body | ConvertFrom-Json
        $csrfToken = $csrfObj.csrfToken
        Add-TestResult 'CSRF-Token-Acquire' $true '' $csrfResp.Ms
    } catch {
        Add-TestResult 'CSRF-Token-Acquire' $false "JSON parse: $_"
    }
} else {
    Add-TestResult 'CSRF-Token-Acquire' $false "Status=$($csrfResp.StatusCode)"
}

# ════════════════════════════════════════════════════════════════════════════════
#                   PHASE 3: SUSTAINED 15+ SECOND I/O TEST
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  --- SUSTAINED I/O TEST ($TestDuration seconds) ---' -ForegroundColor Yellow
Write-Host ''

$testStart   = [System.Diagnostics.Stopwatch]::StartNew()
$iteration   = 0
$totalReqs   = 0

while ($testStart.Elapsed.TotalSeconds -lt $TestDuration) {
    $iteration++
    $elapsed = [math]::Round($testStart.Elapsed.TotalSeconds, 1)
    Write-Host "  --- Iteration $iteration (${elapsed}s) ---" -ForegroundColor DarkCyan

    # ── TEST: Engine status endpoint ──
    $r = Invoke-SafeRequest -Path '/api/engine/status'
    $totalReqs++
    if ($r.StatusCode -eq 200) {
        try {
            $obj = $r.Body | ConvertFrom-Json
            $valid = ($obj.running -eq $true -and $obj.responding -eq $true -and $null -ne $obj.pid)
            Add-TestResult "I$iteration-EngineStatus" $valid "running=$($obj.running) responding=$($obj.responding)" $r.Ms
        } catch {
            Add-TestResult "I$iteration-EngineStatus" $false "Parse: $_" $r.Ms
        }
    } else {
        Add-TestResult "I$iteration-EngineStatus" $false "HTTP $($r.StatusCode)" $r.Ms
    }

    # ── TEST: CSRF token (idempotent) ──
    $r = Invoke-SafeRequest -Path '/api/csrf-token'
    $totalReqs++
    if ($r.StatusCode -eq 200) {
        $obj = $r.Body | ConvertFrom-Json
        $tokenMatch = ($obj.csrfToken -eq $csrfToken)
        Add-TestResult "I$iteration-CSRFConsistency" $tokenMatch "Token stable=$tokenMatch" $r.Ms
    } else {
        Add-TestResult "I$iteration-CSRFConsistency" $false "HTTP $($r.StatusCode)" $r.Ms
    }

    # ── TEST: Scan status (read-only) ──
    $r = Invoke-SafeRequest -Path '/api/scan/status'
    $totalReqs++
    Add-TestResult "I$iteration-ScanStatus" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Scan crashes (read-only) ──
    $r = Invoke-SafeRequest -Path '/api/scan/crashes'
    $totalReqs++
    Add-TestResult "I$iteration-ScanCrashes" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Logs list ──
    $r = Invoke-SafeRequest -Path '/api/engine/logs/list'
    $totalReqs++
    Add-TestResult "I$iteration-LogsList" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Engine log tail ──
    $r = Invoke-SafeRequest -Path '/api/engine/log?name=stdout'
    $totalReqs++
    Add-TestResult "I$iteration-LogTail-stdout" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Engine events ──
    $r = Invoke-SafeRequest -Path '/api/engine/events?tail=10'
    $totalReqs++
    Add-TestResult "I$iteration-EngineEvents" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Agent stats ──
    $r = Invoke-SafeRequest -Path '/api/agent/stats'
    $totalReqs++
    Add-TestResult "I$iteration-AgentStats" ($r.StatusCode -eq 200) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Root page (XHTML) ──
    $r = Invoke-SafeRequest -Path '/'
    $totalReqs++
    # Root serves the workspace hub XHTML - 200 if file exists, 404 if not
    $rootOk = ($r.StatusCode -eq 200 -or $r.StatusCode -eq 404)
    Add-TestResult "I$iteration-RootPage" $rootOk "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: 404 for unknown route ──
    $r = Invoke-SafeRequest -Path '/api/nonexistent/route'
    $totalReqs++
    Add-TestResult "I$iteration-404Route" ($r.StatusCode -eq 404) "HTTP $($r.StatusCode)" $r.Ms

    # ── TEST: Security headers on response ──
    $r = Invoke-SafeRequest -Path '/api/csrf-token'
    $totalReqs++
    if ($null -ne $r.Headers) {
        $hasXCTO = ($null -ne $r.Headers['X-Content-Type-Options'])
        $hasXFO  = ($null -ne $r.Headers['X-Frame-Options'])
        $hasCSP  = ($null -ne $r.Headers['Content-Security-Policy'])
        $allSec  = ($hasXCTO -and $hasXFO -and $hasCSP)
        Add-TestResult "I$iteration-SecurityHeaders" $allSec "XCTO=$hasXCTO XFO=$hasXFO CSP=$hasCSP" $r.Ms
    } else {
        Add-TestResult "I$iteration-SecurityHeaders" $false 'No headers in response' $r.Ms
    }

    # ── TEST: CSRF enforcement (POST without token) ──
    $r = Invoke-SafeRequest -Method 'POST' -Path '/api/scan/full'
    $totalReqs++
    Add-TestResult "I$iteration-CSRFBlock-NoToken" ($r.StatusCode -eq 403) "Expected 403, got $($r.StatusCode)" $r.Ms

    # ── TEST: CSRF enforcement (POST with wrong token) ──
    $r = Invoke-SafeRequest -Method 'POST' -Path '/api/scan/full' -Headers @{ 'X-CSRF-Token' = 'INVALID-TOKEN-12345' }
    $totalReqs++
    Add-TestResult "I$iteration-CSRFBlock-BadToken" ($r.StatusCode -eq 403) "Expected 403, got $($r.StatusCode)" $r.Ms

    # ── TEST: Method not allowed ──
    $r = Invoke-SafeRequest -Method 'POST' -Path '/api/engine/status'
    $totalReqs++
    Add-TestResult "I$iteration-MethodNotAllowed" ($r.StatusCode -eq 405) "Expected 405, got $($r.StatusCode)" $r.Ms

    # ── TEST: Path traversal attempts ──
    for ($mi = 0; $mi -lt @($script:MaliciousInputs).Count; $mi++) {
        $malInput = $script:MaliciousInputs[$mi]
        # Sanitize for URL - truncate extremely long inputs
        $safePath = $malInput
        if ($safePath.Length -gt 200) { $safePath = $safePath.Substring(0, 200) }
        # URL-encode the path to make it a valid HTTP request
        $encodedPath = [System.Uri]::EscapeDataString($safePath)
        $r = Invoke-SafeRequest -Path "/styles/$encodedPath" -TimeoutMs 3000
        $totalReqs++
        # Should get 404 (not found) or 400 (bad request), never 200 with sensitive content
        $traversalBlocked = ($r.StatusCode -ne 200 -or ($r.Body -notmatch 'password|secret|key|token|credential'))
        $inputPreview = if ($malInput.Length -gt 40) { $malInput.Substring(0,40) + '...' } else { $malInput }
        Add-TestResult "I$iteration-Traversal-$mi" $traversalBlocked "Input='$inputPreview' HTTP=$($r.StatusCode)" $r.Ms
    }

    # ── TEST: Allowed log name param validation ──
    $r = Invoke-SafeRequest -Path '/api/engine/log?name=../../secrets'
    $totalReqs++
    # Should fall back to 'stdout' (default) - not serve arbitrary files
    $logSafe = ($r.StatusCode -eq 200)
    if ($logSafe) {
        try {
            $obj = $r.Body | ConvertFrom-Json
            $logSafe = ($obj.logName -eq 'stdout')  # Fell back to safe default
        } catch { $logSafe = $false }
    }
    Add-TestResult "I$iteration-LogNameSanitize" $logSafe "Traversal in log name param" $r.Ms
}

$testStart.Stop()

# ════════════════════════════════════════════════════════════════════════════════
#                          PHASE 4: RESULTS SUMMARY
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '  TEST RESULTS SUMMARY' -ForegroundColor Cyan
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Duration     : $([math]::Round($testStart.Elapsed.TotalSeconds, 1))s" -ForegroundColor Gray
Write-Host "  Iterations   : $iteration" -ForegroundColor Gray
Write-Host "  Total HTTP   : $totalReqs requests" -ForegroundColor Gray
Write-Host "  Tests run    : $(@($script:TestResults).Count)" -ForegroundColor Gray
Write-Host "  Passed       : $($script:PassCount)" -ForegroundColor Green
Write-Host "  Failed       : $($script:FailCount)" -ForegroundColor $(if ($script:FailCount -gt 0) { 'Red' } else { 'Green' })

$avgMs = 0
if (@($script:TestResults).Count -gt 0) {
    $avgMs = [math]::Round(($script:TestResults | ForEach-Object { $_.Ms } | Measure-Object -Average).Average, 1)
}
Write-Host "  Avg response : ${avgMs}ms" -ForegroundColor Gray
Write-Host ''

# Show failures
if ($script:FailCount -gt 0) {
    Write-Host '  FAILURES:' -ForegroundColor Red
    foreach ($t in $script:TestResults) {
        if (-not $t.Passed) {
            Write-Host "    - $($t.Name): $($t.Detail)" -ForegroundColor DarkRed
        }
    }
    Write-Host ''
}

# Save report
$reportFile = Join-Path (Join-Path $WorkspacePath 'temp') 'sustained-test-results.json'
$report = [ordered]@{
    meta = [ordered]@{
        timestamp  = (Get-Date -Format 'o')
        durationS  = [math]::Round($testStart.Elapsed.TotalSeconds, 1)
        iterations = $iteration
        totalReqs  = $totalReqs
        passed     = $script:PassCount
        failed     = $script:FailCount
        avgMs      = $avgMs
        port       = $Port
    }
    results = @($script:TestResults)
}
$json = $report | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($reportFile, $json, [System.Text.UTF8Encoding]::new($true))
Write-Info "Report saved: $reportFile"

# ════════════════════════════════════════════════════════════════════════════════
#                    PHASE 5: CLEAN SHUTDOWN WITH CONFIRMATION
# ════════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '  ================================================' -ForegroundColor Yellow
Write-Host '  CLEAN SHUTDOWN' -ForegroundColor Yellow
Write-Host '  ================================================' -ForegroundColor Yellow
Write-Host ''

if (-not $engineWasRunning) {
    # We started it, so we offer to stop it
    Write-Host '  The engine was started by this test.' -ForegroundColor Gray
    Write-Host '  Do you want to stop the engine now? (Y/N) ' -NoNewline -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match '^[Yy]') {
        Write-Info "Stopping engine via /api/engine/stop..."
        # Use the CSRF token to request a clean stop
        $stopResp = Invoke-SafeRequest -Method 'POST' -Path '/api/engine/stop' -Headers @{ 'X-CSRF-Token' = $csrfToken }
        if ($stopResp.StatusCode -eq 200) {
            Write-Pass "Engine stop accepted (HTTP 200)"
            # Wait for process to exit
            Start-Sleep -Seconds 2
            $postCheck = Invoke-SafeRequest -Path '/api/engine/status' -TimeoutMs 2000
            if ($postCheck.StatusCode -eq 0 -or $postCheck.Error -ne $null) {
                Write-Pass "Engine confirmed stopped (no response)"
            } else {
                Write-Warn "Engine may still be shutting down..."
                # Fallback: use PID file to force-stop
                $pidFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.pid'
                if (Test-Path -LiteralPath $pidFile) {
                    $pid2 = [int](Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8).Trim()
                    if ($pid2 -gt 0) {
                        try {
                            Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
                            Write-Pass "Force-stopped PID $pid2"
                        } catch { Write-Warn "Could not force-stop PID $pid2" }
                    }
                    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Warn "Stop request returned HTTP $($stopResp.StatusCode)"
            Write-Warn 'Falling back to PID-based stop...'
            $pidFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.pid'
            if (Test-Path -LiteralPath $pidFile) {
                $pid2 = [int](Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8).Trim()
                if ($pid2 -gt 0) {
                    try {
                        Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
                        Write-Pass "Force-stopped PID $pid2"
                    } catch { Write-Warn "Could not force-stop PID $pid2" }
                }
            }
        }
    } else {
        Write-Info "Engine left running (PID in logs/engine.pid)"
    }
} else {
    Write-Info "Engine was already running before test - leaving it running"
    Write-Host '  Stop manually? (Y/N) ' -NoNewline -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match '^[Yy]') {
        Write-Info "Stopping engine..."
        $stopResp = Invoke-SafeRequest -Method 'POST' -Path '/api/engine/stop' -Headers @{ 'X-CSRF-Token' = $csrfToken }
        if ($stopResp.StatusCode -eq 200) {
            Start-Sleep -Seconds 2
            Write-Pass "Engine stop requested"
        } else {
            Write-Warn 'Engine stop API did not respond cleanly; no service wrapper fallback is used.'
        }
    } else {
        Write-Info "Engine left running"
    }
}

Write-Host ''
$exitCode = if ($script:FailCount -eq 0) { 0 } else { 1 }
$finalColor = if ($exitCode -eq 0) { 'Green' } else { 'Red' }
Write-Host "  TEST COMPLETE: $($script:PassCount) passed, $($script:FailCount) failed" -ForegroundColor $finalColor
Write-Host ''
exit $exitCode

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





