# VersionTag: 2607.B6.V53.1
<#
.SYNOPSIS
Collect local network connection telemetry and publish to LocalWebEngine NetMon API.

.DESCRIPTION
Reads active connection snapshots from netstat, normalizes records, and POSTs batches
into /api/netmon/connections for XHTML-NetMonDashModComP consumption.

.PARAMETER WorkspacePath
Workspace root path. Defaults to parent folder of this script's directory.

.PARAMETER EngineBaseUrl
Base URL for LocalWebEngine.

.PARAMETER PollSeconds
Polling interval when running in continuous mode.

.PARAMETER Continuous
When set, keeps polling and publishing until interrupted.

.PARAMETER SampleLimit
Maximum number of records per batch.

.PARAMETER IncludeLoopback
Include loopback peers such as 127.0.0.1.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [string]$EngineBaseUrl = 'http://127.0.0.1:8042',
    [int]$PollSeconds = 10,
    [switch]$Continuous,
    [int]$SampleLimit = 120,
    [switch]$IncludeLoopback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NetMonCollectorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level = 'INFO'
    )

    $logsRoot = Join-Path $WorkspacePath 'logs'
    $netmonRoot = Join-Path $logsRoot 'netmon'
    if (-not (Test-Path -LiteralPath $netmonRoot)) {
        New-Item -Path $netmonRoot -ItemType Directory -Force | Out-Null
    }
    $logFile = Join-Path $netmonRoot 'netmon-collector.log'
    $line = ('[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Get-NetMonCsrfToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BaseUrl)

    $url = ($BaseUrl.TrimEnd('/') + '/api/csrf-token')
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
    $token = $null
    if ($null -ne $resp.csrfToken) { $token = [string]$resp.csrfToken }
    elseif ($null -ne $resp.token) { $token = [string]$resp.token }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'CSRF token response did not contain csrfToken or token property.'
    }
    return $token
}

function Resolve-ServiceFromPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$Port)

    switch ($Port) {
        80 { return 'http' }
        443 { return 'https' }
        22 { return 'ssh' }
        3389 { return 'rdp' }
        445 { return 'smb' }
        53 { return 'dns' }
        25 { return 'smtp' }
        110 { return 'pop3' }
        143 { return 'imap' }
        default { return ('port-' + $Port) }
    }
}

function ConvertFrom-NetstatEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    $value = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return [ordered]@{ ip = ''; port = 0 }
    }

    if ($value -eq '*:*' -or $value -eq '*') {
        return [ordered]@{ ip = '*'; port = 0 }
    }

    $lastColon = $value.LastIndexOf(':')
    if ($lastColon -lt 0) {
        return [ordered]@{ ip = $value; port = 0 }
    }

    $ip = $value.Substring(0, $lastColon)
    $portText = $value.Substring($lastColon + 1)
    $port = 0
    if ($portText -match '^\d+$') {
        $port = [int]$portText
    }

    if ($ip.StartsWith('[') -and $ip.EndsWith(']')) {
        $ip = $ip.TrimStart('[').TrimEnd(']')
    }

    return [ordered]@{ ip = $ip; port = $port }
}

function Test-RemoteCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RemoteIp,
        [switch]$IncludeLoopback
    )

    if ([string]::IsNullOrWhiteSpace($RemoteIp)) { return $false }
    if ($RemoteIp -eq '*' -or $RemoteIp -eq '0.0.0.0' -or $RemoteIp -eq '::') { return $false }

    if (-not $IncludeLoopback) {
        if ($RemoteIp -eq '127.0.0.1' -or $RemoteIp -eq '::1') { return $false }
    }

    return $true
}

function Get-NetMonConnectionSnapshot {
    [CmdletBinding()]
    param(
        [int]$SampleLimit = 120,
        [switch]$IncludeLoopback
    )

    $lines = @(netstat -ano -p tcp)
    $records = [System.Collections.ArrayList]@()
    foreach ($line in @($lines)) {
        if ($line -notmatch '^\s*TCP\s+') { continue }
        $parts = @($line -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (@($parts).Count -lt 5) { continue }

        $proto = [string]$parts[0]
        $localText = [string]$parts[1]
        $remoteText = [string]$parts[2]
        $state = [string]$parts[3]

        if ($state -notin @('ESTABLISHED','SYN_SENT','SYN_RECEIVED')) { continue }

        $local = ConvertFrom-NetstatEndpoint -Text $localText
        $remote = ConvertFrom-NetstatEndpoint -Text $remoteText
        if (-not (Test-RemoteCandidate -RemoteIp ([string]$remote.ip) -IncludeLoopback:$IncludeLoopback)) { continue }

        $service = Resolve-ServiceFromPort -Port ([int]$local.port)
        $rec = [ordered]@{
            ts        = (Get-Date -Format 'o')
            ip        = [string]$remote.ip
            country   = 'UNKNOWN'
            protocol  = $proto
            service   = $service
            status    = if ($state -eq 'ESTABLISHED') { 'SUCCESS' } else { 'FAILED' }
            bytesIn   = 0
            bytesOut  = 0
            latencyMs = 0
            source    = 'netstat'
        }
        $null = $records.Add($rec)
        if (@($records).Count -ge $SampleLimit) { break }
    }

    return @($records)
}

function Publish-NetMonRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BaseUrl,
        [Parameter(Mandatory)] [string]$CsrfToken,
        [Parameter(Mandatory)] [object[]]$Records
    )

    if (@($Records).Count -lt 1) { return 0 }

    $uri = ($BaseUrl.TrimEnd('/') + '/api/netmon/connections')
    $headers = @{ 'X-CSRF-Token' = $CsrfToken }
    $body = @{ connections = @($Records) } | ConvertTo-Json -Depth 7

    $null = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 8
    return @($Records).Count
}

if ($PollSeconds -lt 2) { $PollSeconds = 2 }
if ($SampleLimit -lt 1) { $SampleLimit = 1 }
if ($SampleLimit -gt 1000) { $SampleLimit = 1000 }

Write-NetMonCollectorLog -Message ('Collector starting. BaseUrl=' + $EngineBaseUrl + ' Continuous=' + [string]$Continuous.IsPresent + ' PollSeconds=' + $PollSeconds + ' SampleLimit=' + $SampleLimit)
Write-Host ('[NetMonCollector] Start: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan

$sentTotal = 0
$loop = $true
while ($loop) {
    try {
        $token = Get-NetMonCsrfToken -BaseUrl $EngineBaseUrl
        $snapshot = @(Get-NetMonConnectionSnapshot -SampleLimit $SampleLimit -IncludeLoopback:$IncludeLoopback)
        $sent = Publish-NetMonRecords -BaseUrl $EngineBaseUrl -CsrfToken $token -Records $snapshot
        $sentTotal += $sent

        $msg = ('Published {0} records this cycle (total {1}).' -f $sent, $sentTotal)
        Write-NetMonCollectorLog -Message $msg -Level 'INFO'
        Write-Host ('[NetMonCollector] ' + $msg) -ForegroundColor Green
    } catch {
        $errMsg = $_.Exception.Message
        Write-NetMonCollectorLog -Message ('Cycle failed: ' + $errMsg) -Level 'ERROR'
        Write-Host ('[NetMonCollector] ERROR: ' + $errMsg) -ForegroundColor Red
    }

    if (-not $Continuous) {
        $loop = $false
    } else {
        Start-Sleep -Seconds $PollSeconds
    }
}

Write-NetMonCollectorLog -Message ('Collector stopped. Total sent=' + $sentTotal) -Level 'INFO'
Write-Host ('[NetMonCollector] Stop. Total sent: ' + $sentTotal) -ForegroundColor Yellow
