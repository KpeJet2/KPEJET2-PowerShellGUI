# VersionTag: 2608.B1.V54.6
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-17
# SupportsPS7.6TestedDate: 2026-08-17
# FileRole: HostRemediation
#Requires -Version 5.1
<#!
.SYNOPSIS
    Independent host prerequisite remediation and per-instance localhost fix manifest.
.DESCRIPTION
    Does not invoke the pipeline. Generate is read-only. Apply explicitly runs the
    existing prerequisite setup action and records the host/runtime configuration.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Check', 'Generate', 'Apply')]
    [string]$Action = 'Check',
    [string]$InstanceId = '',
    [string]$FixRoot = '',
    [switch]$NoPrereqCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $WorkspacePath).Path
if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    $InstanceId = $env:COMPUTERNAME
}
if ([string]::IsNullOrWhiteSpace($FixRoot)) {
    $FixRoot = Join-Path (Join-Path $root 'temp') 'host-fixes'
}
if (-not (Test-Path -LiteralPath $FixRoot)) {
    $null = New-Item -ItemType Directory -Path $FixRoot -Force
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$nonce = ([guid]::NewGuid().ToString('N')).Substring(0, 12)
$safeInstance = ($InstanceId -replace '[^A-Za-z0-9_.-]', '_')
$fixId = ('localhost-fix-' + $safeInstance + '-' + $PID + '-' + $stamp + '-' + $nonce)
$manifestPath = Join-Path $FixRoot ($fixId + '.json')

function Get-HostPorts {
    $rows = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $rows = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
                [ordered]@{ address = [string]$_.LocalAddress; port = [int]$_.LocalPort; owningProcess = [int]$_.OwningProcess }
            })
    }
    return @($rows | Sort-Object port, address, owningProcess -Unique)
}

function Get-HostConfiguration {
    $workspaceConfig = Join-Path (Join-Path $root 'config') 'system-variables.xml'
    $configHash = ''
    if (Test-Path -LiteralPath $workspaceConfig) {
        $configHash = (Get-FileHash -LiteralPath $workspaceConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    return [PSCustomObject][ordered]@{
        instanceId       = $InstanceId
        fixId            = $fixId
        generatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        computerName     = $env:COMPUTERNAME
        userName         = $env:USERNAME
        userProfile      = $env:USERPROFILE
        systemRoot       = $env:SystemRoot
        workspacePath    = $root
        processId        = $PID
        powershell       = $PSVersionTable.PSVersion.ToString()
        currentDirectory = (Get-Location).Path
        environment      = [ordered]@{
            Path         = $env:Path
            PSModulePath = $env:PSModulePath
            TEMP         = $env:TEMP
            ProgramFiles = $env:ProgramFiles
            LocalAppData = $env:LOCALAPPDATA
        }
        workspaceConfig  = [ordered]@{
            path   = $workspaceConfig
            sha256 = $configHash
        }
        listeningPorts   = @(Get-HostPorts)
        prereqCommand    = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'scripts\Invoke-WorkspacePreReqs.ps1') + '" -WorkspacePath "' + $root + '" -Action CheckAll')
        applyCommand     = ('pwsh -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -WorkspacePath "' + $root + '" -InstanceId "' + $InstanceId + '" -Action Apply')
    }
}

$config = Get-HostConfiguration
$config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (-not $NoPrereqCheck) {
    $prereqScript = Join-Path (Join-Path $root 'scripts') 'Invoke-WorkspacePreReqs.ps1'
    if (Test-Path -LiteralPath $prereqScript) {
        $checkAction = if ($Action -eq 'Apply') { 'SetupAll' } else { 'CheckAll' }
        Write-Host ('[HostFix] Running independent prerequisite action: ' + $checkAction) -ForegroundColor Cyan
        & $prereqScript -WorkspacePath $root -Action $checkAction
        $config | Add-Member -NotePropertyName prereqExitCode -NotePropertyValue ([int]$LASTEXITCODE) -Force
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }
}

Write-Host ('[HostFix] Instance manifest: ' + $manifestPath) -ForegroundColor Green
Write-Host ('[HostFix] No pipeline process was invoked.') -ForegroundColor DarkGray
if ($Action -eq 'Apply') {
    Write-Host '[HostFix] Host setup was explicitly requested; review the report and reboot guidance.' -ForegroundColor Yellow
}

[PSCustomObject]@{
    FixId          = $fixId
    InstanceId     = $InstanceId
    ManifestPath   = $manifestPath
    Action         = $Action
    WorkspacePath  = $root
    PrereqExitCode = if ($config.PSObject.Properties.Name -contains 'prereqExitCode') { $config.prereqExitCode } else { $null }
}
