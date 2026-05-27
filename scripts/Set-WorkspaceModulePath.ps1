# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-04-28
# SupportsPS7.6TestedDate: 2026-04-28
# FileRole: Environment
# Prepends workspace modules directory to PSModulePath (preserves system/user paths)
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$workspaceModules = Join-Path $workspaceRoot 'modules'
if ($env:PSModulePath -notlike "*$workspaceModules*") {
    $env:PSModulePath = "$workspaceModules;$env:PSModulePath"
}
Write-Host "[INFO] PSModulePath prepended with: $workspaceModules"

<# Outline:
    Idempotently prepends <workspace>/modules to $env:PSModulePath for the current process so
    Import-Module <ShortName> resolves project modules ahead of system/user paths. Safe to dot-source
    multiple times: the prepend is guarded by a -notlike check.
#>

<# Problems:
    None. Write-Host is intentional (interactive bootstrap path, not a module function) and is
    therefore exempt from SEMI-SIN-003.
#>

<# ToDo:
    Optional: persist the prepend per-user via [Environment]::SetEnvironmentVariable when invoked
    with a -Persist switch.
#>



