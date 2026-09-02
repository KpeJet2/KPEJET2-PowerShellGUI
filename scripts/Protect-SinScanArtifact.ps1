# VersionTag: 2608.B1.V54.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Script
#Requires -Version 5.1
<#
.SYNOPSIS
    Redact private paths and matched source content from a SIN scan JSON artifact.
.DESCRIPTION
    Sanitises the JSON emitted by tests/Invoke-SINPatternScanner.ps1 so it is safe to
    publish as a CI artifact: drops findings whose path touches a private root
    (sovereign-kernel, logs, pki, checkpoints, ...) or leaks host/user identifiers,
    redacts the matched line content, and blanks the absolute workspace path.

    Exits 0 when the scan file is absent so it can run with `if: always()`.
.PARAMETER ScanJson
    Path to the SIN scan results JSON to sanitise in place.
.PARAMETER PrivateRootPattern
    Override regex identifying paths/identifiers that must never be published.
.EXAMPLE
    ./scripts/Protect-SinScanArtifact.ps1 -ScanJson reports/sin-scan-strict.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ScanJson,

    [string]$PrivateRootPattern = '(?i)(^|[\\/])(sovereign-kernel|logs|Report|reports|checkpoints|pki|temp|\.history|\.snapshots)([\\/]|$)|localhost|127\.0\.0\.1|msaib|XPS15-MS-'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScanJson)) {
    Write-Host "SIN scan artifact not found: $ScanJson (nothing to redact)."
    exit 0
}

$scan = Get-Content -LiteralPath $ScanJson -Raw -Encoding UTF8 | ConvertFrom-Json

if ($scan.PSObject.Properties.Name -contains 'workspace') {
    $scan.workspace = '[REDACTED]'
}

$dropped = 0
if ($scan.PSObject.Properties.Name -contains 'findings') {
    $safeFindings = @()
    foreach ($finding in @($scan.findings)) {
        $candidatePath = ''
        foreach ($prop in @('file', 'path', 'fullPath')) {
            if ($finding.PSObject.Properties.Name -contains $prop) {
                $candidatePath = $candidatePath + ' ' + [string]$finding.$prop
            }
        }

        if ($candidatePath -match $PrivateRootPattern) {
            $dropped++
            continue
        }

        if ($finding.PSObject.Properties.Name -contains 'content') {
            $finding.content = '[REDACTED]'
        }

        $safeFindings += $finding
    }
    $scan.findings = $safeFindings
}

$scan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ScanJson -Encoding UTF8
Write-Host ("Redacted {0}: dropped {1} private finding(s)." -f $ScanJson, $dropped) -ForegroundColor Green
