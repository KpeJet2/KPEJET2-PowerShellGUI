# VersionTag: 2606.B5.V51.4
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-23
# SupportsPS7.6TestedDate: 2026-05-23
# FileRole: UtilityScript

[CmdletBinding()]
param(
    [string]$WorkspacePath = '',
    [ValidateSet('PS51','PS7','Both')]
    [string]$Runtime = 'Both',
    [string[]]$IncludeFiles = @(),
    [string[]]$ExtraExtensions = @('.xhtml','.html','.js','.ts','.json','.md','.css','.psd1','.bat','.cmd'),
    [string]$OutputJson = '',
    [switch]$Quiet,
    [switch]$FailOnCritical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $WorkspacePath = Split-Path -Parent $scriptRoot
}

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-top15-issues-20260523.json'
}

$scannerPath = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SINPatternScanner.ps1'
if (-not (Test-Path -LiteralPath $scannerPath)) {
    throw "SIN scanner not found: $scannerPath"
}

# Top 15 issue batch (mapped in docs/SIN-TOP15-PROGRAMMING-ISSUES-RESEARCH-20260523.md).
$batchSinIds = @(
    'P001', # Hardcoded secrets
    'P002', # Empty catch
    'P003', # Silent import failure
    'P006', # UTF-8 BOM safety
    'P009', # Unvalidated path joins
    'P010', # Dynamic execution via iex
    'P020', # TLS cert bypass
    'P021', # Divide by zero
    'P022', # Null method/property call
    'P023', # Double-encoded UTF-8
    'P027', # Null array indexing
    'P029', # Unprotected event handlers
    'P038', # Unbounded recursive scan
    'P039', # BOM round-trip corruption
    'P041', # JSON schema property drift
    'P042', # Undeclared parameter passed
    'P047', # SIN schema drift
    'P059', # Active merge conflict markers
    'P063', # Typed catch PipelineStoppedException
    'P065', # Double event handler registration
    'P067', # JS fetch no abort timeout
    'P068', # Script-scope Controls.Add no guard
    'P069', # Replacement character corruption marker
    'P070', # PowerShell web request no timeout
    'P071'  # Blocking wait no timeout
)

$scanArgs = @{
    WorkspacePath = $WorkspacePath
    Runtime = $Runtime
    OutputJson = $OutputJson
    FailOnSinId = $batchSinIds
    ExtraExtensions = $ExtraExtensions
}
if (@($IncludeFiles).Count -gt 0) { $scanArgs['IncludeFiles'] = $IncludeFiles }
if ($Quiet) { $scanArgs['Quiet'] = $true }
if ($FailOnCritical) { $scanArgs['FailOnCritical'] = $true }

& $scannerPath @scanArgs
$exitCode = 0
if (Test-Path -LiteralPath variable:LASTEXITCODE) {
    $exitCode = [int]$LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $OutputJson)) {
    throw "Expected scanner output not found: $OutputJson"
}

$result = Get-Content -LiteralPath $OutputJson -Raw -Encoding UTF8 | ConvertFrom-Json
$blocked = @()
if ($null -ne $result.blockedById) {
    foreach ($p in $result.blockedById.PSObject.Properties) {
        if ([int]$p.Value -gt 0) {
            $blocked += ('{0}={1}' -f $p.Name, $p.Value)
        }
    }
}

$summary = [pscustomobject]@{
    Batch = 'TOP15-ISSUES-20260523'
    Runtime = $Runtime
    Patterns = ($batchSinIds -join ', ')
    TotalFindings = [int]$result.totalFindings
    Critical = [int]$result.critical
    High = [int]$result.high
    Medium = [int]$result.medium
    Low = [int]$result.low
    BlockedPatterns = if (@($blocked).Count -gt 0) { $blocked -join '; ' } else { '(none)' }
    OutputJson = $OutputJson
}

if (-not $Quiet) {
    $summary | Format-List | Out-String | Write-Output
}

exit $exitCode

