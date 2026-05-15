# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Launcher
#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap all PowerShellGUI module engines for the current PowerShell session.
.DESCRIPTION
    1. Ensures C:\PowerShellGUI\modules is in PSModulePath (Process scope now + User scope persistently).
    2. Imports each core engine module in dependency order.
    3. Calls Initialize-CorePaths so PwShGUICore registers all workspace paths.
    4. Reports pass/fail for every module.

    Can be dot-sourced so imported modules persist in the caller's scope:
        . .\scripts\Start-Engines.ps1
    Or run standalone for a diagnostic check:
        .\scripts\Start-Engines.ps1
.PARAMETER Quiet
    Suppress banner and per-module status output.
.EXAMPLE
    .\scripts\Start-Engines.ps1
    . .\scripts\Start-Engines.ps1
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Paths ───────────────────────────────────────────────────────────────────
$_seScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($_seScriptDir)) {
    $_seScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$_seRoot    = Split-Path -Parent $_seScriptDir
$_seMods    = Join-Path $_seRoot 'modules'

# ── Ensure modules dir is in PSModulePath ───────────────────────────────────
$_seProc = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
if ([string]::IsNullOrEmpty($_seProc)) { $_seProc = '' }
if ($_seProc.Split(';') -notcontains $_seMods) {
    [System.Environment]::SetEnvironmentVariable('PSModulePath', "$_seMods;$_seProc", 'Process')
    $env:PSModulePath = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
}

$_seUser = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'User')
if ([string]::IsNullOrEmpty($_seUser)) { $_seUser = '' }
if ($_seUser.Split(';') -notcontains $_seMods) {
    $newUserPath = ($_seMods + ';' + $_seUser).TrimEnd(';')  # SIN-EXEMPT:P009 -- internal vars from $PSScriptRoot/env, not external input
    [System.Environment]::SetEnvironmentVariable('PSModulePath', $newUserPath, 'User')
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  PowerShellGUI -- Engine Bootstrap                        ' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "  Modules dir : $_seMods"
    Write-Host ''
}

# ── Engine list -- in dependency order ──────────────────────────────────────
# Format: @{ Name = '...'; Init = { scriptblock run after import, or $null } }
$_seEngines = @(
    @{ Name = 'PwShGUICore';                  Init = { Initialize-CorePaths -ScriptDir $_seRoot } }
    @{ Name = 'CronAiAthon-EventLog';         Init = $null }
    @{ Name = 'CronAiAthon-Scheduler';        Init = $null }
    @{ Name = 'CronAiAthon-Pipeline';         Init = $null }
    @{ Name = 'CronAiAthon-BugTracker';       Init = $null }
    @{ Name = 'PwShGUI-IntegrityCore';        Init = $null }
    @{ Name = 'SINGovernance';                Init = $null }
    @{ Name = 'AssistedSASC';                 Init = $null }
    @{ Name = 'SASC-Adapters';                Init = $null }
    @{ Name = 'AVPN-Tracker';                 Init = $null }
    @{ Name = 'UserProfileManager';           Init = $null }
    @{ Name = 'PwShGUI-VersionManager';       Init = $null }
)

$_sePass = 0
$_seFail = 0
$_seSkip = 0

foreach ($_seEngine in $_seEngines) {
    $_seName = $_seEngine.Name
    $_seModFile = Join-Path $_seMods "$_seName.psm1"

    if (-not (Test-Path -LiteralPath $_seModFile)) {
        if (-not $Quiet) {
            Write-Host ("  [SKIP] {0,-38} (file not found)" -f $_seName) -ForegroundColor DarkYellow
        }
        $_seSkip++
        continue
    }

    try {
        Import-Module -Name $_seModFile -Force -ErrorAction Stop

        # Run optional post-import initializer
        if ($null -ne $_seEngine.Init) {
            & $_seEngine.Init
        }

        if (-not $Quiet) {
            Write-Host ("  [OK]   {0}" -f $_seName) -ForegroundColor Green
        }
        $_sePass++
    } catch {
        if (-not $Quiet) {
            Write-Host ("  [FAIL] {0,-38} -- {1}" -f $_seName, $_.Exception.Message) -ForegroundColor Red
        }
        Write-Warning "Start-Engines: failed to load '$_seName' -- $($_.Exception.Message)"
        $_seFail++
    }
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    $statusColour = if ($_seFail -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host ("  Loaded: {0}   Failed: {1}   Skipped: {2}" -f $_sePass, $_seFail, $_seSkip) -ForegroundColor $statusColour
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

# ── Return summary hashtable (useful when dot-sourced) ──────────────────────
$script:EngineBootstrapResult = @{
    Pass    = $_sePass
    Fail    = $_seFail
    Skipped = $_seSkip
    ModsDir = $_seMods
}

# Clean up local variables that were prefixed to avoid scope pollution
Remove-Variable -Name '_seScriptDir','_seRoot','_seMods','_seProc','_seUser','_seEngines','_sePass','_seFail','_seSkip' -ErrorAction SilentlyContinue

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





