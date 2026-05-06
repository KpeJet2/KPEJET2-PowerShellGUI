# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Live integration tests for Start-LocalWebEngine.ps1 — starts the HTTP engine and exercises all API endpoints.
.DESCRIPTION
    Starts the Local Web Engine on port 8042 via Start-LocalWebEngine.ps1,
    then makes real HTTP calls to verify each route responds correctly.
    Verifies CSRF protection, JSON structure, and graceful stop.
    AfterAll: stops the engine regardless of test outcome.
.NOTES
    Requires: PowerShell 5.1+, no other process bound to port 8042.
    Engine startup timeout: 6 seconds (12 × 500ms polls).
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WsPath      = Split-Path $PSScriptRoot -Parent
    $script:EngineScript = Join-Path $script:WsPath 'scripts\Start-LocalWebEngine.ps1'
    $script:BaseUrl     = 'http://127.0.0.1:8042'
    $script:EngineReady = $false
    $script:CsrfToken  = $null

    # Helper: HTTP GET — returns [pscustomobject]@{Status; Body; Json}
    function Invoke-EngineGet {
        param([string]$Path, [switch]$Raw)
        $uri = "$script:BaseUrl$Path"
        try {
            $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            $json = $null
            if (-not $Raw) {
                try { $json = $resp.Content | ConvertFrom-Json } catch { <# Intentional: non-fatal #> }
            }
            return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content; Json = $json }
        } catch {
            # PS7 HttpClient throws TaskCanceledException/HttpRequestException; PS5 throws WebException
            $code = 0
            if ($_.Exception -is [System.Net.WebException] -and $null -ne $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception.InnerException -is [System.Net.WebException] -and $null -ne $_.Exception.InnerException.Response) {
                $code = [int]$_.Exception.InnerException.Response.StatusCode
            }
            return [pscustomobject]@{ Status = $code; Body = $null; Json = $null }
        }
    }

    # Helper: HTTP POST with optional CSRF — returns [pscustomobject]@{Status; Body}
    function Invoke-EnginePost {
        param([string]$Path, [string]$Token = $null, [string]$ContentType = 'application/json', [string]$Body = '{}')
        $uri     = "$script:BaseUrl$Path"
        $headers = @{ 'Content-Type' = $ContentType }
        if ($Token) { $headers['X-CSRF-Token'] = $Token }
        try {
            $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $Body -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content }
        } catch {
            $code = 0
            if ($_.Exception -is [System.Net.WebException] -and $null -ne $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception.InnerException -is [System.Net.WebException] -and $null -ne $_.Exception.InnerException.Response) {
                $code = [int]$_.Exception.InnerException.Response.StatusCode
            }
            return [pscustomobject]@{ Status = $code; Body = $null }
        }
    }

    # Stop any running engine to start fresh (prevents single-threaded queue saturation)
    $pidFile = Join-Path $script:WsPath 'logs\engine.pid'
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $existingPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
        } catch { <# Intentional: non-fatal #> }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    # Also stop any other powershell process owning port 8042 via netstat
    try {
        $netLines = netstat -ano | Where-Object { $_ -match '127\.0\.0\.1:8042\s+0\.0\.0\.0:0\s+LISTENING' }
    } catch { $netLines = @() }
    # Brief wait for port release
    Start-Sleep -Milliseconds 800

    # Start engine with -NoLaunchBrowser to prevent browser competing for single-threaded queue
    if (Test-Path -LiteralPath $script:EngineScript) {
        $engineJob = Start-Job -ScriptBlock {
            param($scriptPath, $wsPath)
            & powershell.exe -NoProfile -NonInteractive -File $scriptPath -WorkspacePath $wsPath -NoLaunchBrowser
        } -ArgumentList $script:EngineScript, $script:WsPath
        $script:EngineJobId = $engineJob.Id

        # Poll for HTTP readiness (20 × 500ms = 10 seconds max)
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            try {
                $check = Invoke-WebRequest -Uri "$script:BaseUrl/api/csrf-token" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                if ($check.StatusCode -eq 200) {
                    $script:EngineReady = $true
                    try {
                        $tokenObj = $check.Content | ConvertFrom-Json
                        $script:CsrfToken = $tokenObj.csrfToken
                    } catch { <# Intentional: non-fatal #> }
                    break
                }
            } catch { <# Intentional: non-fatal #> }
        }
    }
}

AfterAll {
    # Graceful stop — attempt via API first
    if ($script:EngineReady -and $script:CsrfToken) {
        try { Invoke-EnginePost -Path '/api/engine/stop' -Token $script:CsrfToken | Out-Null } catch { <# Intentional: non-fatal #> }
        Start-Sleep -Milliseconds 800
    }
    # Stop the engine background job
    if ($script:EngineJobId) {
        Stop-Job -Id $script:EngineJobId -ErrorAction SilentlyContinue
        Remove-Job -Id $script:EngineJobId -Force -ErrorAction SilentlyContinue
    }
    # Force-kill if PID file still present
    $pidFile = Join-Path $script:WsPath 'logs\engine.pid'
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $pidVal = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        } catch { <# Intentional: non-fatal #> }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'LWE — Prerequisites' {
    It 'Engine script exists' {
        Test-Path -LiteralPath $script:EngineScript | Should -Be $true
    }
    It 'Engine started and is ready' {
        $script:EngineReady | Should -Be $true -Because 'Engine must bind port 8042 within 10 seconds'
    }
}

Describe 'LWE — PID file and process' {
    BeforeAll {
        $script:PidFile = Join-Path $script:WsPath 'logs\engine.pid'
    }
    It 'PID file exists after start' {
        Test-Path -LiteralPath $script:PidFile | Should -Be $true
    }
    It 'PID file contains a valid numeric process ID' {
        $raw = (Get-Content -LiteralPath $script:PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $raw | Should -Match '^\d+$'
    }
    It 'Process corresponding to PID is alive' {
        $raw = (Get-Content -LiteralPath $script:PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($raw -match '^\d+$') {
            $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
            $proc | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Pending -Because 'PID file missing or non-numeric'
        }
    }
}

Describe 'LWE — CSRF token endpoint' {
    It 'GET /api/csrf-token returns HTTP 200' {
        $r = Invoke-EngineGet '/api/csrf-token'
        $r.Status | Should -Be 200
    }
    It 'GET /api/csrf-token returns JSON with a non-empty csrfToken field' {
        $r = Invoke-EngineGet '/api/csrf-token'
        $r.Json | Should -Not -BeNullOrEmpty
        $r.Json.csrfToken | Should -Not -BeNullOrEmpty
    }
}

Describe 'LWE — Engine Status endpoint' {
    It 'GET /api/engine/status returns HTTP 200' {
        $r = Invoke-EngineGet '/api/engine/status'
        $r.Status | Should -Be 200
    }
    It 'GET /api/engine/status JSON contains pid field' {
        $r = Invoke-EngineGet '/api/engine/status'
        $r.Json.PSObject.Properties.Name | Should -Contain 'pid'
    }
    It 'GET /api/engine/status JSON contains port field' {
        $r = Invoke-EngineGet '/api/engine/status'
        $r.Json.PSObject.Properties.Name | Should -Contain 'port'
    }
}

Describe 'LWE — Scan status endpoint' {
    It 'GET /api/scan/status returns HTTP 200' {
        $r = Invoke-EngineGet '/api/scan/status'
        $r.Status | Should -Be 200
    }
    It 'GET /api/scan/status returns valid JSON' {
        $r = Invoke-EngineGet '/api/scan/status'
        $r.Json | Should -Not -BeNullOrEmpty
    }
}

Describe 'LWE — Engine events endpoint' {
    It 'GET /api/engine/events returns HTTP 200' {
        $r = Invoke-EngineGet '/api/engine/events'
        $r.Status | Should -Be 200
    }
    It 'GET /api/engine/events returns a JSON array' {
        $r = Invoke-EngineGet '/api/engine/events'
        $r.Body | Should -Match '^\s*\['
    }
}

Describe 'LWE — Log endpoint' {
    It 'GET /api/engine/log?name=stdout returns HTTP 200' {
        $r = Invoke-EngineGet '/api/engine/log?name=stdout'
        $r.Status | Should -Be 200
    }
    It 'GET /api/engine/log?name=stdout returns non-empty body' {
        $r = Invoke-EngineGet '/api/engine/log?name=stdout'
        $r.Body | Should -Not -BeNullOrEmpty
    }
}

Describe 'LWE — Unknown route handling' {
    It 'GET /api/nonexistent returns HTTP 404' {
        $r = Invoke-EngineGet '/api/nonexistent-route-xyz'
        $r.Status | Should -Be 404
    }
}

Describe 'LWE — CSRF protection on mutating routes' {
    It 'POST /api/scan/full without CSRF token returns HTTP 403' {
        $r = Invoke-EnginePost -Path '/api/scan/full' -Token $null
        $r.Status | Should -Be 403 -Because 'CSRF guard must reject requests without token'
    }
}

Describe 'LWE — Graceful stop via API' {
    It 'POST /api/engine/stop with valid CSRF token returns HTTP 200 or 202' {
        if (-not $script:CsrfToken) {
            Set-ItResult -Pending -Because 'No CSRF token captured — skipping stop test'
            return
        }
        $r = Invoke-EnginePost -Path '/api/engine/stop' -Token $script:CsrfToken
        $r.Status | Should -BeIn @(200, 202) -Because 'Engine should acknowledge graceful stop request'
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





