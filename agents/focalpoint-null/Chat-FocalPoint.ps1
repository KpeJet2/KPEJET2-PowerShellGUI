# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
# Chat-FocalPoint.ps1 -- Interactive CLI client for the FocalPoint-null agent server

param(
    [string]$Server  = "http://localhost:8087",
    [string]$Message = ""   # Pass -Message "..." for single one-shot use
)

function Send-Message([string]$Text) {
    $payload = (ConvertTo-Json @{ message = $Text } -Depth 5)
    try {
        $resp = Invoke-WebRequest -Uri "$Server/chat" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $payload `
            -SkipHttpErrorCheck `
            -TimeoutSec 120

        $statusCode = [int]$resp.StatusCode
        $bodyText = $resp.Content

        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            try {
                $parsed = $bodyText | ConvertFrom-Json
                if ($parsed.response) {
                    return $parsed.response
                }
                return $bodyText
            } catch {
                return $bodyText
            }
        }

        if ($bodyText) {
            try {
                $parsed = $bodyText | ConvertFrom-Json
                if ($parsed.error) {
                    return "ERROR HTTP ${statusCode}: $($parsed.error)"
                }
                if ($parsed.response) {
                    return "ERROR HTTP ${statusCode}: $($parsed.response)"
                }
            } catch {
                return "ERROR HTTP ${statusCode}: $bodyText"
            }
            return "ERROR HTTP ${statusCode}: $bodyText"
        }

        return "ERROR HTTP ${statusCode}: Empty response body"
    } catch {
        $ex = $_.Exception
        return "ERROR: $($ex.Message)"
    }
}

# ── Health check ────────────────────────────────────────────────────────────
try {
    $health = Invoke-RestMethod "$Server/health" -TimeoutSec 3 -ErrorAction Stop
    Write-Host "  Connected to $($health.agent) at $Server" -ForegroundColor Green
} catch {
    Write-Error "Server not responding at $Server. Start it with .\Start-FocalPoint.ps1"
    exit 1
}

# ── One-shot mode ───────────────────────────────────────────────────────────
if ($Message) {
    Write-Host ""
    Write-Host "You: $Message" -ForegroundColor Cyan
    Write-Host ""
    $reply = Send-Message $Message
    Write-Host "FocalPoint: $reply" -ForegroundColor Yellow
    exit 0
}

# ── Interactive loop ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  FocalPoint-null chat -- type 'exit' or 'quit' to stop" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    Write-Host -NoNewline "You: " -ForegroundColor Cyan
    $input = Read-Host
    if ($input -match '^(exit|quit|q)$') { break }
    if ([string]::IsNullOrWhiteSpace($input)) { continue }

    Write-Host ""
    Write-Host -NoNewline "FocalPoint: " -ForegroundColor Yellow
    $reply = Send-Message $input
    Write-Host $reply
    Write-Host ""
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






