# VersionTag: 2607.B6.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Script
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [Alias('FailItemsPath')]
    [string]$ReportJson = '',
    [ValidateSet('FullWorkspace','KnowSafeRemidiations','KnowSafeRemediations','FastFix_Auto-Correct','SpecificFocus')]
    [string]$Scope = 'KnowSafeRemidiations',
    [string[]]$FocusTargets = @(),
    [int]$RecentDays = 14,
    [switch]$WhatIf,
    [int]$MaxAttempts = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
$modulePath = Join-Path (Join-Path $workspaceFull 'modules') 'PwShGUI-AutoCorrectGate.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required module not found: $modulePath"
}

Import-Module -Name $modulePath -Force -DisableNameChecking -ErrorAction Stop

$items = @()
if (-not [string]::IsNullOrWhiteSpace($ReportJson)) {
    if (-not (Test-Path -LiteralPath $ReportJson)) {
        throw "ReportJson does not exist: $ReportJson"
    }

    $payload = Get-Content -LiteralPath $ReportJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($payload -is [System.Array]) {
        $items = @($payload)
    } elseif ($payload.PSObject.Properties.Name -contains 'findings') {
        $items = @($payload.findings)
    } elseif ($payload.PSObject.Properties.Name -contains 'items') {
        $items = @($payload.items)
    } else {
        $items = @($payload)
    }
} else {
    $defaultFailPath = Join-Path (Join-Path $workspaceFull 'temp') 'sin-scan-results.json'
    if (Test-Path -LiteralPath $defaultFailPath) {
        try {
            $defaultPayload = Get-Content -LiteralPath $defaultFailPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($defaultPayload.PSObject.Properties.Name -contains 'findings') {
                $items = @($defaultPayload.findings)
            }
        } catch {
            $items = @()
        }
    }
}

$invokeParams = @{
    WorkspacePath = $workspaceFull
    FailItems     = @($items)
    Scope         = $Scope
    FocusTargets  = @($FocusTargets)
    RecentDays    = $RecentDays
}
if ($MaxAttempts -gt 0) {
    $invokeParams['MaxAttempts'] = $MaxAttempts
}

$result = Invoke-AutoCorrectGate @invokeParams -WhatIf:$WhatIf
$result
