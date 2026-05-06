# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Launcher
# Local web engine compatibility wrapper
# Compatibility wrapper that forwards service-control actions to Start-LocalWebEngine.ps1.
#Requires -Version 5.1
<#
.SYNOPSIS
    Compatibility wrapper for the Local Web Engine service controller.

.DESCRIPTION
    Preserves the historical entrypoint used by Main-GUI.ps1 and tests, but
    delegates all lifecycle actions to Start-LocalWebEngine.ps1. The legacy
    Start action maps to RunAsService so the actual engine runs detached.
#>
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Restart','Status','Help','LaunchWebpage')]
    [string]$Action = 'Start',
    [int]$Port = 8042,
    [string]$WorkspacePath = '',
    [switch]$NoLaunchBrowser,
    [switch]$SeparateTerminal,
    [ValidateSet('Debug','Info','Warning','Error','Critical')]
    [string]$EventLevel = 'Info',
    [string]$LogToFile = '',
    [string]$ShowRainbow = 'true',
    [int]$PollInterval = 1,
    [int]$MaxWait = 15,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$unboundArgs = @($MyInvocation.UnboundArguments)
if (@($unboundArgs).Count -gt 0 -and $unboundArgs[0] -is [string] -and $unboundArgs[0] -notmatch '^-') {
    $Action = [string]$unboundArgs[0]
}

$scriptDir = $PSScriptRoot
$engineScript = Join-Path $scriptDir 'Start-LocalWebEngine.ps1'
if (-not (Test-Path -LiteralPath $engineScript)) {
    Write-Host "Engine script not found: $engineScript" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $scriptDir -Parent
}

$delegateAction = if ($Action -eq 'Start') { 'RunAsService' } else { $Action }
Write-Host "[INFO] Local web engine wrapper forwarding action '$Action' -> '$delegateAction'" -ForegroundColor DarkCyan

$delegateParams = @{
    Action = $delegateAction
    Port = $Port
    WorkspacePath = $WorkspacePath
    NoLaunchBrowser = $NoLaunchBrowser
    SeparateTerminal = $SeparateTerminal
    EventLevel = $EventLevel
    LogToFile = $LogToFile
    ShowRainbow = $ShowRainbow
    PollInterval = $PollInterval
    MaxWait = $MaxWait
    Force = $Force
}

& $engineScript @delegateParams
exit $LASTEXITCODE
