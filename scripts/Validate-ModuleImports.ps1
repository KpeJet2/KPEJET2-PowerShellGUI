# Scans all scripts for forbidden import patterns (external/global modules)
$workspaceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$allowedModulePath = Join-Path $workspaceRoot 'modules'
Get-ChildItem $workspaceRoot -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match 'Import-Module\s+[\'\"]?([a-zA-Z]:|\\\\)') {
        Write-Warning "External module import found in $($_.FullName)"
    }
    if ($content -match 'Import-Module\s+[^\'\"\.\\]') {
        Write-Warning "Potential global module import found in $($_.FullName)"
    }
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>

