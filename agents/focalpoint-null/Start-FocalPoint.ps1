# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1
# Start-FocalPoint.ps1 -- Launch the FocalPoint-null agent server

Set-Location $PSScriptRoot

# ── Load .env ──────────────────────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env not found. Copy .env.example to .env and fill in your credentials."
    exit 1
}

foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
    $parts = $line -split '=', 2
    if ($parts.Count -eq 2) {
        $key   = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"')
        [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

# ── Locate Python (venv preferred) ─────────────────────────────────────────
$projectRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
$python = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) {
        Write-Error "Python not found. Run: python -m venv $projectRoot\.venv && pip install -r requirements.txt"
        exit 1
    }
}

# ── Validate token ──────────────────────────────────────────────────────────
if (-not $env:GITHUB_TOKEN -or $env:GITHUB_TOKEN -eq "your_github_pat_here") {
    Write-Warning "GITHUB_TOKEN not set in .env - LLM calls will fail. Set a valid GitHub PAT."
}

# ── Launch ──────────────────────────────────────────────────────────────────
$host_addr = if ($env:HTTP_HOST) { $env:HTTP_HOST } else { "0.0.0.0" }
$port      = if ($env:HTTP_PORT)  { $env:HTTP_PORT }  else { "8087" }

Write-Host ""
Write-Host "  FocalPoint-null agent server" -ForegroundColor Cyan
Write-Host "  http://$host_addr`:$port/health" -ForegroundColor Green
Write-Host "  http://$host_addr`:$port/chat   (POST)" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

& $python main.py








<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>






