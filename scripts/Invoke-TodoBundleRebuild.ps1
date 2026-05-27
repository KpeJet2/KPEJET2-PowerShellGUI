# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Invoke-TodoBundleRebuild.ps1
# Regenerates todo/_bundle.js from all individual JSON files in todo/
# This pre-built JS bundle is required for file:// protocol viewing of:
#   - ~README.md/PwShGUI-Checklists.xhtml (Items2Do / Bugs2FIX / Feature2ADD tabs)
#   - scripts/XHTML-Checker/XHTML-MasterToDo.xhtml (fallback data source)
# Run after any Add-PipelineItem, New-PipelineItem, or Invoke-TodoManager operation.
param(
    [string]$WorkspacePath = $PSScriptRoot
)

# If launched from scripts/, adjust to workspace root
if ($WorkspacePath -like '*scripts*') {
    $WorkspacePath = Split-Path $WorkspacePath -Parent
}

$todoDir  = Join-Path $WorkspacePath 'todo'
$outFile  = Join-Path $todoDir '_bundle.js'
$excludes = @('_index.json', '_bundle.js', '_master-aggregated.json', 'action-log.json')

Write-Host "[TodoBundle] Scanning $todoDir ..." -ForegroundColor Cyan

$files = Get-ChildItem -Path "$todoDir\*.json" | Where-Object { $excludes -notcontains $_.Name -and $_.FullName -notlike "*\~*\*" } | Sort-Object Name
if (-not $files -or @($files).Count -eq 0) {
    Write-Host "[TodoBundle] No JSON files found in $todoDir" -ForegroundColor Yellow
    return
}

$items = @()
$errors = 0
foreach ($f in $files) {
    try {
        $raw = Get-Content $f.FullName -Raw -Encoding UTF8
        $null = $raw | ConvertFrom-Json  # validate JSON
        $items += $raw.Trim()
    } catch {
        Write-Host "[TodoBundle] SKIP (invalid JSON): $($f.Name)" -ForegroundColor Yellow
        $errors++
    }
}

$totalCount = @($items).Count
Write-Host "[TodoBundle] Loaded $totalCount valid items ($errors skipped)" -ForegroundColor Green

# Build the JS file
$header = @"
/* Auto-generated todo data bundle -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
   Items: $totalCount | Errors: $errors
   Regenerate: powershell -File scripts/Invoke-TodoBundleRebuild.ps1
   Or from module: Invoke-TodoBundleRebuild (if exported) */
var _todoBundle = [
"@

$joined = ($items -join ",`n  ")
$footer = "`n];"

$content = $header + "`n  " + $joined + $footer

# Write with UTF-8 encoding (no BOM for JS files -- browsers handle it fine)
[System.IO.File]::WriteAllText($outFile, $content, [System.Text.UTF8Encoding]::new($false))

$size = [math]::Round((Get-Item $outFile).Length / 1KB, 1)
Write-Host "[TodoBundle] Written: $outFile ($size KB, $totalCount items)" -ForegroundColor Green


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





