function Import-WorkspaceModule {
    param([string]$Name)
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..' ) 'modules'
    $fullPath = Join-Path $modulePath $Name
    Import-Module $fullPath -Force
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
Export-ModuleMember -Function Import-WorkspaceModule

