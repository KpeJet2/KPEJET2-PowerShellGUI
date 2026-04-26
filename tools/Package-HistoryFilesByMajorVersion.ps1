# Package-HistoryFilesByMajorVersion.ps1
# Zips all history files by Major Version (e.g., V30, V31, V32)

param(
    [string]$HistoryDir = "$PSScriptRoot/../history",
    [string]$OutputDir = "$PSScriptRoot/../history-archives"
)

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

$historyFiles = Get-ChildItem -Path $HistoryDir -File -Recurse
$grouped = $historyFiles | Group-Object { if ($_ -match 'V(\d+)') { "V$($Matches[1])" } else { 'VUnknown' } }

foreach ($group in $grouped) {
    $zipName = Join-Path $OutputDir ("history-" + $group.Name + ".zip")
    if (Test-Path $zipName) { Remove-Item $zipName -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tempDir = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    foreach ($file in $group.Group) {
        Copy-Item $file.FullName -Destination (Join-Path $tempDir $file.Name)
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipName)
    Remove-Item $tempDir -Recurse -Force
    Write-Host "Packaged $($group.Group.Count) files into $zipName"
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

