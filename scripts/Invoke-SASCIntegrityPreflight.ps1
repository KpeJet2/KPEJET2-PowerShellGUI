# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-05-05)
# SupportsPS7.6: YES(As of: 2026-05-05)
# SupportPS5.1TestedDate: 2026-05-05
# SupportsPS7.6TestedDate: 2026-05-05
# FileRole: Preflight
#Requires -Version 5.1
<#
.SYNOPSIS
    Run SASC integrity drift preflight and optional signed-manifest refresh.
.DESCRIPTION
    Thin wrapper over Invoke-SASCIntegrityPreflight from PwShGUI-IntegrityCore.
    Intended for CI, launch diagnostics, and operator preflight checks.
.EXITCODES
    0 = passed
    2 = failed or still degraded
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$Interactive,
    [switch]$AutoRegenerate,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspacePath)
if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
    throw "WorkspacePath not found: $resolvedWorkspace"
}

$integrityCoreManifest = Join-Path (Join-Path $resolvedWorkspace 'modules') 'PwShGUI-IntegrityCore.psd1'
if (-not (Test-Path -LiteralPath $integrityCoreManifest)) {
    throw "IntegrityCore manifest not found: $integrityCoreManifest"
}

Import-Module -Name $integrityCoreManifest -Force -ErrorAction Stop
if (-not (Get-Command Invoke-SASCIntegrityPreflight -ErrorAction SilentlyContinue)) {
    throw 'Invoke-SASCIntegrityPreflight is not available after importing PwShGUI-IntegrityCore'
}

$result = Invoke-SASCIntegrityPreflight -WorkspacePath $resolvedWorkspace -Interactive:$Interactive -AutoRegenerate:$AutoRegenerate

if (-not $Quiet) {
    $result | ConvertTo-Json -Depth 8
}

if (-not $result.Passed) {
    exit 2
}

exit 0
