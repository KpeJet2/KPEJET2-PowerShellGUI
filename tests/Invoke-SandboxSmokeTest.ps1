# VersionTag: 2608.B1.V54.3
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-14
# SupportsPS7.6TestedDate: 2026-08-14
# FileRole: TestOrchestrator
#Requires -Version 5.1
<#!
.SYNOPSIS
    Active sandbox smoke test entrypoint for Windows Sandbox launches.
.DESCRIPTION
    Delegates to tests\sandbox\Start-InteractiveSandbox.ps1 with startup automation
    so sandbox executes prechecks and ordered service/process startup.

    Startup sequence inside sandbox bootstrap:
      1) Pipeline prechecks
      2) Required framework/module installation
      3) Load MainGUI, TaskTrayApps Cluster Dash, CronAi-Athon process
      4) Launch local web services on ports 8042 then 8099
      5) Run requested smoke/browser action
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$OutputPath,
    [switch]$ChaosMode,
    [string[]]$ChaosConditions,
    [switch]$HeadlessOnly,
    [switch]$KeepSandbox,
    [int]$Timeout = 600,
    [switch]$SkipPS7Install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $WorkspacePath 'logs\sandbox-results'
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$startScript = Join-Path (Join-Path $WorkspacePath 'tests') 'sandbox\Start-InteractiveSandbox.ps1'
if (-not (Test-Path -LiteralPath $startScript)) {
    throw "Sandbox orchestrator not found: $startScript"
}

Write-Host ''
Write-Host ('=' * 68) -ForegroundColor Magenta
Write-Host '  WINDOWS SANDBOX SMOKE TEST ORCHESTRATOR' -ForegroundColor Yellow
Write-Host ('=' * 68) -ForegroundColor Magenta
Write-Host "Workspace : $WorkspacePath" -ForegroundColor Green
Write-Host "Output    : $OutputPath" -ForegroundColor Green
Write-Host ''

$networking = 'Enable'
$startParams = @{
    WorkspacePath = $WorkspacePath
    SessionName = 'smoke'
    Networking = $networking
    MemoryMB = 4096
    MaxIdleMinutes = 120
}

$session = & $startScript @startParams
if ($null -eq $session -or -not $session.PSObject.Properties.Name -contains 'SessionDir') {
    throw 'Sandbox session did not return expected metadata.'
}

$sendScript = Join-Path (Join-Path $WorkspacePath 'tests') 'sandbox\Send-SandboxCommand.ps1'
if (-not (Test-Path -LiteralPath $sendScript)) {
    throw "Sandbox command dispatcher not found: $sendScript"
}

$testAction = if ($ChaosMode) { 'Chaos' } else { 'Test' }
$sendParams = @{
    SessionDir = [string]$session.SessionDir
    Action = $testAction
    WaitTimeout = $Timeout
}
if ($HeadlessOnly) {
    $sendParams['Headless'] = $true
}

Write-Host "Dispatching sandbox action: $testAction" -ForegroundColor Cyan
& $sendScript @sendParams
$actionExit = $LASTEXITCODE

if ($KeepSandbox) {
    Write-Host "Sandbox retained for manual inspection: $($session.SessionDir)" -ForegroundColor Yellow
} else {
    Write-Host 'Shutting down sandbox session...' -ForegroundColor DarkGray
    & $sendScript -SessionDir ([string]$session.SessionDir) -Action Shutdown -NoWait | Out-Null
}

# Copy output artifacts from session folder into requested output path.
$sessionOut = Join-Path ([string]$session.SessionDir) 'output'
if (Test-Path -LiteralPath $sessionOut) {
    $stampDir = Join-Path $OutputPath ('sandbox-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
    Copy-Item -Path (Join-Path $sessionOut '*') -Destination $stampDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Sandbox artifacts copied to: $stampDir" -ForegroundColor Green
} else {
    Write-Host "No sandbox output folder found at: $sessionOut" -ForegroundColor Yellow
}

exit $actionExit
