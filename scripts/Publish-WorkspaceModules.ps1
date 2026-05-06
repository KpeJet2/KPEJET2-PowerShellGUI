# Publishes all modules in ./modules to the local WorkspaceRepo
$workspaceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesPath = Join-Path $workspaceRoot 'modules'
$repoName = 'WorkspaceRepo'
Get-ChildItem $modulesPath -Directory | ForEach-Object {
    $moduleManifest = Get-ChildItem $_.FullName -Filter *.psd1 | Select-Object -First 1
    if ($moduleManifest) {
        Publish-Module -Path $_.FullName -Repository $repoName -Force
        Write-Host "[INFO] Published $($_.Name) to $repoName"
    } else {
        Write-Warning "No module manifest found for $($_.Name)"
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

