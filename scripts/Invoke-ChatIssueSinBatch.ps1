# VersionTag: 2605.B5.V51.1
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
    $OutputJson = Join-Path (Join-Path $WorkspacePath 'temp') 'sin-scan-chat-issues-20260523.json'
}

$scannerPath = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-SINPatternScanner.ps1'
if (-not (Test-Path -LiteralPath $scannerPath)) {
    throw "SIN scanner not found: $scannerPath"
}

# Focused batch derived from this chat's failure modes.
$batchSinIds = @(
    'P006', # UTF-8 no BOM with Unicode bytes
    'P022', # Null method/property calls
    'P023', # Double-encoded UTF-8 / mojibake bytes
    'P039', # BOM round-trip corruption risk
    'P063', # Typed catch PipelineStoppedException in delegates
    'P068', # Script-scope Controls.Add without guard
    'P069'  # Replacement character corruption marker
)

$scanArgs = @{
    WorkspacePath = $WorkspacePath
    Runtime = $Runtime
    OutputJson = $OutputJson
    FailOnSinId = $batchSinIds
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
    Batch = 'CHAT-ISSUES-20260523'
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
