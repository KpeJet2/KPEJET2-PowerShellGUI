# VersionTag: 2605.B2.V31.7
# PowerShell Pre-commit UTF-8 BOM Checker
# Scans all .ps1/.psm1/.psd1/.xhtml/.xml/.md files for UTF-8 BOM compliance
# Usage: .\tools\Check-BOM.ps1 or add to pre-commit hook/CI pipeline

param(
    [string]$Root = (Get-Location).Path
)

$extensions = @('.ps1','.psm1','.psd1','.xhtml','.xml','.md')
$files = Get-ChildItem -Path $Root -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLower() }

$nonBom = @()
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3) {
        if (!($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            $nonBom += $file.FullName
        }
    } else {
        $nonBom += $file.FullName
    }
}

if ($nonBom.Count -gt 0) {
    Write-Host "Files missing UTF-8 BOM:" -ForegroundColor Yellow
    $nonBom | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
} else {
    Write-Host "All checked files have UTF-8 BOM." -ForegroundColor Green
    exit 0
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


