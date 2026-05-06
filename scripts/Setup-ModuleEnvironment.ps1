# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Environment
#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses, registers, and installs PowerShellGUI project modules for local use.
.DESCRIPTION
    Provides four operations:
      -Diagnose   : Scans execution policies, PSModulePath, repositories, and manifest coverage
      -Register   : Registers a LOCAL PSRepository pointing at the project modules folder
      -Install    : Copies project modules into a user or system module path for auto-discovery
      -Uninstall  : Removes installed module copies from the target path
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose','Register','Install','Uninstall')]
    [string]$Action,

    [ValidateSet('CurrentUser','AllUsers')]
    [string]$Scope = 'CurrentUser',

    [string]$WorkspacePath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath -or -not (Test-Path -LiteralPath $WorkspacePath)) {
    throw "Workspace path is not valid: $WorkspacePath"
}

$modulesDir = Join-Path $WorkspacePath 'modules'
$logsDir = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path -LiteralPath $modulesDir)) {
    throw "Modules directory not found: $modulesDir"
}
if (-not (Test-Path -LiteralPath $logsDir)) {
    $null = New-Item -Path $logsDir -ItemType Directory -Force
}

function Write-DiagLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $line = "[$ts][$Level] $Message"
    $color = 'White'
    if ($Level -eq 'OK') { $color = 'Green' }
    elseif ($Level -eq 'WARN') { $color = 'Yellow' }
    elseif ($Level -eq 'ERROR') { $color = 'Red' }
    elseif ($Level -eq 'DEBUG') { $color = 'DarkGray' }
    Write-Host $line -ForegroundColor $color
    return $line
}

function Invoke-ModuleValidatorAudit {
    param([switch]$ThrowOnFail)

    $validator = Join-Path (Join-Path $WorkspacePath 'tests') 'Invoke-ModuleGalleryValidator.ps1'
    if (-not (Test-Path -LiteralPath $validator)) {
        Write-DiagLog -Message "Module validator not found: $validator" -Level WARN | Out-Null
        return $null
    }

    $auditJson = Join-Path (Join-Path $WorkspacePath 'temp') ("module-audit-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        & $validator -WorkspacePath $WorkspacePath -TestPS51 -TestPS7 -TestSystemContext -Quiet -OutputJson $auditJson | Out-Null
        if (-not (Test-Path -LiteralPath $auditJson)) {
            throw 'Module validator did not produce JSON output.'
        }

        $audit = Get-Content -LiteralPath $auditJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $failCount = if ($audit.PSObject.Properties.Name -contains 'verdictFAIL') { [int]$audit.verdictFAIL } else { 0 }
        $warnCount = if ($audit.PSObject.Properties.Name -contains 'verdictWARN') { [int]$audit.verdictWARN } else { 0 }
        $total = if ($audit.PSObject.Properties.Name -contains 'totalModules') { [int]$audit.totalModules } else { 0 }

        Write-DiagLog -Message "Module validator audit: Total=$total Fail=$failCount Warn=$warnCount (JSON: $auditJson)" -Level INFO | Out-Null
        if ($failCount -gt 0 -and $ThrowOnFail) {
            throw "Module validator found $failCount failing module(s)."
        }
        return $audit
    } catch {
        Write-DiagLog -Message "Module validator audit failed: $($_.Exception.Message)" -Level ERROR | Out-Null
        if ($ThrowOnFail) { throw }
        return $null
    }
}

function Get-ModuleTargetRoot {
    param([string]$ScopeName)

    $isPwshCore = $PSVersionTable.PSVersion.Major -ge 6
    if ($ScopeName -eq 'AllUsers') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw 'AllUsers scope requires elevation (Run as Administrator).'
        }
        if ($isPwshCore) {
            return (Join-Path $env:ProgramFiles (Join-Path 'PowerShell' 'Modules'))
        }
        return (Join-Path $env:ProgramFiles (Join-Path 'WindowsPowerShell' 'Modules'))
    }

    if ($isPwshCore) {
        return (Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'PowerShell' 'Modules')))
    }
    return (Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'WindowsPowerShell' 'Modules')))
}

function Invoke-Diagnose {
    $logFile = Join-Path $logsDir ("module-environment-diag-" + (Get-Date -Format 'yyyyMMdd-HHmm') + '.log')
    $out = [System.Collections.Generic.List[string]]::new()

    $out.Add((Write-DiagLog -Message "Engine: PowerShell $($PSVersionTable.PSVersion)" -Level INFO))
    if ($PSVersionTable.PSVersion -ge [version]'7.6.0') {
        $out.Add((Write-DiagLog -Message 'Primary runtime path active (PS7.6+).' -Level OK))
    } else {
        $out.Add((Write-DiagLog -Message 'Fallback runtime path active (PS5.1 compatible).' -Level WARN))
    }

    $out.Add((Write-DiagLog -Message "WorkspacePath: $WorkspacePath" -Level INFO))
    $out.Add((Write-DiagLog -Message "ModulesPath:   $modulesDir" -Level INFO))

    $paths = @($env:PSModulePath -split ';')
    foreach ($p in $paths) {
        if (-not $p) { continue }
        $exists = Test-Path -LiteralPath $p
        $out.Add((Write-DiagLog -Message ("PSModulePath entry: " + $p + " (Exists=" + $exists + ")") -Level INFO))
    }

    $repos = Get-PSRepository -ErrorAction SilentlyContinue
    if (@($repos).Count -eq 0) {
        $out.Add((Write-DiagLog -Message 'No PS repositories discovered.' -Level WARN))
    } else {
        foreach ($r in $repos) {
            $lvl = 'INFO'
            if ($r.Trusted) { $lvl = 'OK' }
            $out.Add((Write-DiagLog -Message ("Repo " + $r.Name + " => " + $r.SourceLocation + " Trusted=" + $r.Trusted) -Level $lvl))
        }
    }

    $modules = @(Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    foreach ($m in $modules) {
        $man = Join-Path $modulesDir ($m.BaseName + '.psd1')
        $hasManifest = Test-Path -LiteralPath $man
        $lvl = 'OK'
        if (-not $hasManifest) { $lvl = 'WARN' }
        $out.Add((Write-DiagLog -Message ("Module " + $m.BaseName + " Manifest=" + $hasManifest) -Level $lvl))
    }

    $out | Out-File -FilePath $logFile -Encoding UTF8
    Write-DiagLog -Message "Diagnostic log saved: $logFile" -Level INFO | Out-Null
    [void](Invoke-ModuleValidatorAudit)
}

function Invoke-Register {
    $repoName = 'PwShGUI-Local'
    $publishDir = Join-Path $modulesDir 'Local'

    if (-not (Test-Path -LiteralPath $publishDir)) {
        $null = New-Item -Path $publishDir -ItemType Directory -Force
    }

    $existing = Get-PSRepository -Name $repoName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-PSRepository -Name $repoName -InstallationPolicy Trusted
        Write-DiagLog -Message "Repository '$repoName' already exists and is now trusted." -Level OK | Out-Null
        return
    }

    Register-PSRepository -Name $repoName -SourceLocation $modulesDir -PublishLocation $publishDir -InstallationPolicy Trusted
    Write-DiagLog -Message "Registered repository '$repoName' => $modulesDir" -Level OK | Out-Null
}

function Invoke-Install {
    $targetRoot = Get-ModuleTargetRoot -ScopeName $Scope
    if (-not (Test-Path -LiteralPath $targetRoot)) {
        $null = New-Item -Path $targetRoot -ItemType Directory -Force
    }

    $modules = @(Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    $installed = 0

    foreach ($m in $modules) {
        $name = $m.BaseName
        $psd1 = Join-Path $modulesDir ($name + '.psd1')

        $version = '1.0.0'
        if (Test-Path -LiteralPath $psd1) {
            try {
                $manifest = Import-PowerShellDataFile -Path $psd1 -ErrorAction Stop
                if ($manifest.ModuleVersion) {
                    $version = [string]$manifest.ModuleVersion
                }
            } catch {
                Write-DiagLog -Message "Could not read module version for $name; defaulting to 1.0.0" -Level WARN | Out-Null
            }
        }

        $destVersionDir = Join-Path (Join-Path $targetRoot $name) $version
        if (-not (Test-Path -LiteralPath $destVersionDir)) {
            $null = New-Item -Path $destVersionDir -ItemType Directory -Force
        }

        Copy-Item -Path $m.FullName -Destination $destVersionDir -Force
        if (Test-Path -LiteralPath $psd1) {
            Copy-Item -Path $psd1 -Destination $destVersionDir -Force
        }

        $installed++
        Write-DiagLog -Message "Installed $name v$version -> $destVersionDir" -Level OK | Out-Null
    }

    Write-DiagLog -Message "Install complete. Installed modules: $installed" -Level INFO | Out-Null
    [void](Invoke-ModuleValidatorAudit -ThrowOnFail)
}

function Invoke-Uninstall {
    $targetRoot = Get-ModuleTargetRoot -ScopeName $Scope
    $modules = @(Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    $removed = 0

    foreach ($m in $modules) {
        $name = $m.BaseName
        $targetDir = Join-Path $targetRoot $name
        if (Test-Path -LiteralPath $targetDir) {
            Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $targetDir -Recurse -Force
            $removed++
            Write-DiagLog -Message "Removed module: $name" -Level OK | Out-Null
        }
    }

    Write-DiagLog -Message "Uninstall complete. Removed modules: $removed" -Level INFO | Out-Null
}

switch ($Action) {
    'Diagnose'  { Invoke-Diagnose }
    'Register'  { Invoke-Register }
    'Install'   { Invoke-Install }
    'Uninstall' { Invoke-Uninstall }
}

<# Outline:
    Standardized environment diagnostics, repository registration, and module install/uninstall orchestration.
#>

<# Problems:
    None.
#>

<# ToDo:
    Add optional export of machine-readable diagnostics JSON.
#>

