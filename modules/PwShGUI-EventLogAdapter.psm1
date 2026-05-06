# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-29
# SupportsPS7.6TestedDate: 2026-04-29
# FileRole: Module
<#
.SYNOPSIS
    PwShGUI-EventLogAdapter -- single chokepoint for the canonical event log.

.DESCRIPTION
    Implements docs/EVENT-LOG-STANDARD.md. All modules / scripts / services
    that need to surface events to the XHTML viewers should call
    Write-EventLogNormalized (or one of the convenience wrappers).

    Read-side: Get-EventLogNormalized resolves per-scope JSONL rows applying
    the multi-tier cache rules (live > disk > replay > stale) so the viewer
    sees a single uniform shape regardless of where the data came from.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:_CanonicalSeverities = @('DEBUG','INFO','WARN','ERROR','CRITICAL','AUDIT')
$script:_CanonicalScopes     = @('pipeline','service','gui','sin','mcp','cron','engine','sec','net','root')
$script:_DiskCacheMaxAgeSec  = 300

# Severity translation table -- single source of truth.
# NOTE: PowerShell hashtables are case-insensitive, so 'Info'/'INFO'/'info'
# all hit the same key. Only one variant per logical name is listed.
$script:_SevMap = @{
    # Write-AppLog (also covers legacy uppercase XHTML 'INFO','WARN','ERROR','DEBUG')
    'Debug'         = 'DEBUG'
    'Info'          = 'INFO'
    'Warning'       = 'WARN'
    'Warn'          = 'WARN'
    'Error'         = 'ERROR'
    'Critical'      = 'CRITICAL'
    'Audit'         = 'AUDIT'
    # Write-CronLog extras
    'Emergency'     = 'CRITICAL'
    'Alert'         = 'ERROR'
    'Notice'        = 'INFO'
    'Informational' = 'INFO'
    # Legacy XHTML extras
    'BOOT'          = 'INFO'
    'CRASH'         = 'CRITICAL'
}

<#
.SYNOPSIS
  ConvertTo canonical severity.
#>
function ConvertTo-CanonicalSeverity {
    [OutputType([System.String])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Severity)
    if ($script:_SevMap.ContainsKey($Severity)) { return $script:_SevMap[$Severity] }
    $u = $Severity.ToUpperInvariant()
    if ($script:_CanonicalSeverities -contains $u) { return $u }
    return 'INFO'
}

<#
.SYNOPSIS
  Get event log normalized dir.
#>
function Get-EventLogNormalizedDir {
    [CmdletBinding()]
    param([string]$WorkspacePath = $PSScriptRoot)
    $root = if ($WorkspacePath -and (Test-Path $WorkspacePath)) { (Resolve-Path $WorkspacePath).Path } else { (Get-Location).Path }
    if ($root -like '*\modules') { $root = Split-Path $root -Parent }
    $dir = Join-Path (Join-Path $root 'logs') 'eventlog-normalized'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Write-EventLogNormalized {
    <#
    .SYNOPSIS  Emit one canonical JSONL row to logs/eventlog-normalized/<scope>-<yyyyMMdd>.jsonl
        .DESCRIPTION
      Detailed behaviour: Write event log normalized.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('pipeline','service','gui','sin','mcp','cron','engine','sec','net','root')]
        [string]$Scope,
        [Parameter(Mandatory)] [string]$Component,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Severity = 'Info',
        [string]$CorrId   = '',
        [string]$Source   = '',
        [string]$WorkspacePath = $PSScriptRoot
    )
    $row = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString('o')
        severity  = ConvertTo-CanonicalSeverity -Severity $Severity
        scope     = $Scope
        component = $Component
        msg       = $Message
        corrId    = $CorrId
        host      = $env:COMPUTERNAME
        pid       = $PID
        source    = $Source
    }
    $dir  = Get-EventLogNormalizedDir -WorkspacePath $WorkspacePath
    $file = Join-Path $dir ("$Scope-" + (Get-Date -Format 'yyyyMMdd') + '.jsonl')
    $line = ($row | ConvertTo-Json -Depth 5 -Compress)
    # P019: -Encoding UTF8 mandatory.
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8

    # V31.1 Kernel mirror: best-effort copy to sovereign-kernel/events/<scope>-<date>.jsonl
    # so kernel processes can subscribe without re-implementing the adapter contract.
    try {
        $root = if ($WorkspacePath -and (Test-Path $WorkspacePath)) { (Resolve-Path $WorkspacePath).Path } else { (Get-Location).Path }
        if ($root -like '*\modules') { $root = Split-Path $root -Parent }
        $kdir = Join-Path (Join-Path $root 'sovereign-kernel') 'events'
        if (-not (Test-Path -LiteralPath $kdir)) { New-Item -ItemType Directory -Path $kdir -Force | Out-Null }
        $kfile = Join-Path $kdir ("$Scope-" + (Get-Date -Format 'yyyyMMdd') + '.jsonl')
        Add-Content -LiteralPath $kfile -Value $line -Encoding UTF8
    } catch { <# Kernel mirror is best-effort; never block primary write #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
}

function Get-EventLogNormalized {
    <#
    .SYNOPSIS  Read canonical rows for a scope, applying the multi-tier cache rules.
    .DESCRIPTION
        Returns the viewer envelope { generatedAt, scope, cache, items[] }
        described in docs/EVENT-LOG-STANDARD.md section 4.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('pipeline','service','gui','sin','mcp','cron','engine','sec','net','root')]
        [string]$Scope,
        [int]   $Tail = 500,
        [string]$WorkspacePath = $PSScriptRoot
    )

    $dir   = Get-EventLogNormalizedDir -WorkspacePath $WorkspacePath
    $today = Join-Path $dir ("$Scope-" + (Get-Date -Format 'yyyyMMdd') + '.jsonl')
    $rows  = @()
    $tier  = 'stale'
    $path  = ''
    $ageSec = -1
    $fresh = $false

    if (Test-Path -LiteralPath $today) {
        $fi = Get-Item -LiteralPath $today
        $ageSec = [int][Math]::Round(((Get-Date) - $fi.LastWriteTime).TotalSeconds)
        $path = $today
        if ($ageSec -le $script:_DiskCacheMaxAgeSec) { $tier = 'disk'; $fresh = $true } else { $tier = 'replay' }
        $lines = @(Get-Content -LiteralPath $today -Encoding UTF8 -Tail $Tail -ErrorAction SilentlyContinue)
        foreach ($l in $lines) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            try { $rows += ($l | ConvertFrom-Json) } catch { <# Intentional: non-fatal (auto-remediated P002) #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
        }
    }

    # Aggregate root: union recent items from every other scope file dated today.
    if ($Scope -eq 'root') {
        $rows = @()
        $allFiles = @(Get-ChildItem -LiteralPath $dir -Filter ('*-' + (Get-Date -Format 'yyyyMMdd') + '.jsonl') -File -ErrorAction SilentlyContinue)
        foreach ($f in $allFiles) {
            $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -Tail $Tail -ErrorAction SilentlyContinue)
            foreach ($l in $lines) {
                if ([string]::IsNullOrWhiteSpace($l)) { continue }
                try { $rows += ($l | ConvertFrom-Json) } catch { <# Intentional: non-fatal (auto-remediated P002) #> Write-Verbose -Message ($_.Exception.Message) -Verbose:$false }
            }
        }
        # Sort newest first.
        if (@($rows).Count -gt 0) {
            $rows = @($rows | Sort-Object -Property ts -Descending | Select-Object -First $Tail)
        }
        $tier = if (@($allFiles).Count -gt 0) { 'disk' } else { 'stale' }
        $fresh = ($tier -eq 'disk')
        $path = $dir
    }

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        scope       = $Scope
        cache       = [ordered]@{
            tier   = $tier
            path   = $path
            ageSec = $ageSec
            fresh  = $fresh
        }
        items       = @($rows)
    }
}

function Test-EventLogStandardCompliance {
    <#
    .SYNOPSIS  Quick self-check used by the sweep script and unit tests.
        .DESCRIPTION
      Detailed behaviour: Test event log standard compliance.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent))
    $dir = Get-EventLogNormalizedDir -WorkspacePath $WorkspacePath
    return [ordered]@{
        ok            = (Test-Path $dir)
        normalizedDir = $dir
        scopes        = $script:_CanonicalScopes
        severities    = $script:_CanonicalSeverities
    }
}

Export-ModuleMember -Function @(
    'Write-EventLogNormalized',
    'Get-EventLogNormalized',
    'ConvertTo-CanonicalSeverity',
    'Get-EventLogNormalizedDir',
    'Test-EventLogStandardCompliance'
)

