# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Module

<#
.SYNOPSIS
  Import workspace module.
#>
function Import-WorkspaceModule {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($Name -notmatch '^[A-Za-z0-9\-_.]+$') {
        throw "Invalid module name: $Name"
    }

    $modulePath = Join-Path (Join-Path $PSScriptRoot '..' ) 'modules'
    $manifestPath = Join-Path $modulePath ($Name + '.psd1')
    $scriptPath = Join-Path $modulePath ($Name + '.psm1')

    if (Test-Path $manifestPath) {
        Import-Module $manifestPath -Force -ErrorAction Stop
        return
    }

    if (Test-Path $scriptPath) {
        Import-Module $scriptPath -Force -ErrorAction Stop
        return
    }

    throw "Module not found as .psd1 or .psm1 in $modulePath : $Name"
}

<# Outline:
    Imports a workspace module by short name from <workspace>/modules. Prefers the .psd1 manifest
    when present (so version/required-modules metadata is honoured) and falls back to the .psm1.
    Validates the requested name against ^[A-Za-z0-9\-_.]+$ to prevent path-traversal injection.
#>

<# Problems:
    None. Import-Module is invoked with -ErrorAction Stop so failures surface to the caller
    (no SilentlyContinue per SIN-PATTERN-P003).
#>

<# ToDo:
    Optional: support -MinimumVersion / -RequiredVersion pass-through to Import-Module.
#>
Export-ModuleMember -Function Import-WorkspaceModule



