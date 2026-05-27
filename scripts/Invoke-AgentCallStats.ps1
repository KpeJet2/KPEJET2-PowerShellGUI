# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Invoke-AgentCallStats.ps1
# Computes per-agent call statistics (24h / 7d / all-time) by scanning JSONL log files
# in agents/focalpoint-null/logs/ and writes config/agent-call-stats.json.
# Usage:
#   .\Invoke-AgentCallStats.ps1 -WorkspacePath 'C:\PowerShellGUI'
#   .\Invoke-AgentCallStats.ps1 -WorkspacePath 'C:\PowerShellGUI' -PassThru
# Returns: writes JSON file; if -PassThru, emits $true on success.
# Called by: Start-LocalWebEngine.ps1 via /api/agent/stats  |  manually
#
# SIN Compliance: P001,P002,P004,P005,P006,P007,P009,P012,P014,P015,P017,P018
param(
    [string]$WorkspacePath = [regex]::Replace($PSScriptRoot, '[\\/]scripts$', ''),
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-AppLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Message, [string]$Level = 'Info')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$stamp][$Level] $Message"
}

# ── Paths ─────────────────────────────────────────────────────────────────────
$logsDir   = Join-Path $WorkspacePath 'agents'
$logsDir   = Join-Path $logsDir 'focalpoint-null'
$logsDir   = Join-Path $logsDir 'logs'
$statsFile = Join-Path $WorkspacePath 'config'
$statsFile = Join-Path $statsFile 'agent-call-stats.json'

Write-AppLog "Invoke-AgentCallStats: scanning $logsDir"

# ── Gather JSONL events ───────────────────────────────────────────────────────
$now    = Get-Date
$cutoff24h = $now.AddHours(-24)
$cutoff7d  = $now.AddDays(-7)

# counters keyed by agent_id
$counts = @{}

function Ensure-Agent {
    param([string]$id)
    if (-not $counts.ContainsKey($id)) {
        $counts[$id] = @{ calls24h = 0; calls7d = 0; callsTotal = 0; lastCall = $null }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }
}

if (Test-Path -LiteralPath $logsDir) {
    $jsonlFiles = @(Get-ChildItem -LiteralPath $logsDir -Filter '*.jsonl' -File)
    Write-AppLog "Found $(@($jsonlFiles).Count) JSONL file(s)"

    foreach ($file in $jsonlFiles) {
        $lines = @()
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        } catch {
            Write-AppLog "Skipping $($file.Name): $($_.Exception.Message)" -Level 'Warning'
            continue
        }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try { $entry = $line | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { continue }
            if ($null -eq $entry) { continue }

            # agent_id field
            $aid = $null
            if ($null -ne $entry.PSObject.Properties['agent_id']) { $aid = $entry.agent_id }
            elseif ($null -ne $entry.PSObject.Properties['agentId']) { $aid = $entry.agentId }
            if ([string]::IsNullOrWhiteSpace($aid)) { continue }

            # timestamp field
            $ts = $null
            if ($null -ne $entry.PSObject.Properties['timestamp']) { $ts = $entry.timestamp }
            $dtParsed = $null
            if (-not [string]::IsNullOrWhiteSpace($ts)) {
                try { $dtParsed = [datetime]::Parse($ts) } catch { $dtParsed = $null }
            }

            Ensure-Agent -id $aid
            $counts[$aid].callsTotal++  # SIN-EXEMPT:P027 -- index access, context-verified safe
            if ($null -ne $dtParsed) {
                if ($dtParsed -ge $cutoff24h) { $counts[$aid].calls24h++ }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                if ($dtParsed -ge $cutoff7d)  { $counts[$aid].calls7d++ }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                if ($null -eq $counts[$aid].lastCall -or $dtParsed -gt [datetime]::Parse($counts[$aid].lastCall)) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    $counts[$aid].lastCall = $dtParsed.ToString('o')  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }
            }
        }
    }
} else {
    Write-AppLog "JSONL log directory not found: $logsDir" -Level 'Warning'
}

# ── Merge with existing stats (preserve entries not covered by logs) ──────────
$existing = $null
if (Test-Path -LiteralPath $statsFile) {
    try { $existing = Get-Content -LiteralPath $statsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { <# non-fatal #> }
}

$statsObj = [ordered]@{}
if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['stats']) {
    foreach ($prop in $existing.stats.PSObject.Properties) {
        $statsObj[$prop.Name] = [ordered]@{
            calls24h    = $prop.Value.calls24h
            calls7d     = $prop.Value.calls7d
            callsTotal  = $prop.Value.callsTotal
            lastCall    = $prop.Value.lastCall
            logSource   = $prop.Value.logSource
        }
    }
}

# Overlay computed counts
foreach ($aid in $counts.Keys) {
    $src = if ($counts.ContainsKey($aid)) { 'agents/focalpoint-null/logs/' } else { '' }
    if (-not $statsObj.Contains($aid)) {
        $statsObj[$aid] = [ordered]@{  # SIN-EXEMPT:P027 -- index access, context-verified safe
            calls24h   = 0
            calls7d    = 0
            callsTotal = 0
            lastCall   = $null
            logSource  = $src
        }
    }
    $statsObj[$aid].calls24h   = $counts[$aid].calls24h  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $statsObj[$aid].calls7d    = $counts[$aid].calls7d  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $statsObj[$aid].callsTotal = $counts[$aid].callsTotal  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if ($null -ne $counts[$aid].lastCall) { $statsObj[$aid].lastCall = $counts[$aid].lastCall }  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $statsObj[$aid].logSource  = $src  # SIN-EXEMPT:P027 -- index access, context-verified safe
}

# ── Write output ──────────────────────────────────────────────────────────────
$output = [ordered]@{
    schemaVersion = 'AgentCallStats/1.0'
    generatedAt   = (Get-Date -Format 'o')
    note          = 'Auto-generated by Invoke-AgentCallStats.ps1. Re-run or call /api/agent/stats to refresh.'
    stats         = $statsObj
}

try {
    $json = $output | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $statsFile -Value $json -Encoding UTF8 -Force
    Write-AppLog "agent-call-stats.json updated ($(@($statsObj.Keys).Count) agents)"
} catch {
    Write-AppLog "Failed to write $statsFile : $($_.Exception.Message)" -Level 'Error'
    if ($PassThru) { return $false }
    exit 1
}

if ($PassThru) { return $true }

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





