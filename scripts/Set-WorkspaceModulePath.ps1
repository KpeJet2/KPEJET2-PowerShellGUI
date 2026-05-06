# Sets PSModulePath to workspace modules only
$workspaceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceModules = Join-Path $workspaceRoot 'modules'
$env:PSModulePath = $workspaceModules
Write-Host "[INFO] PSModulePath set to: $env:PSModulePath"

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>

