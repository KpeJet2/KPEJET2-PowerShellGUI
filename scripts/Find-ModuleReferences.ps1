# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 8 entries)
# Find all references to PwShGUI_AutoIssueFinder module and display in GridView
$rootPath = Split-Path -Parent $PSScriptRoot
$results = @()

Write-Host "`nSearching for PwShGUI_AutoIssueFinder references..." -ForegroundColor Cyan

# Define files to search
$fileTypes = @('*.ps1', '*.psm1', '*.json', '*.xml', '*.txt')
$allFiles = foreach ($ft in $fileTypes) {
    Get-ChildItem -Path $rootPath -Filter $ft -Recurse -File -ErrorAction SilentlyContinue
}

Write-Host "Scanning $($allFiles.Count) files..." -ForegroundColor Yellow

foreach ($file in $allFiles) {
    try {
        $lineNumber = 0
        $lines = Get-Content -Path $file.FullName -ErrorAction Stop
        
        foreach ($line in $lines) {
            $lineNumber++
            if ($line -match 'PwShGUI_AutoIssueFinder|AutoIssueFinder') {
                # Extract variable name if present
                $variableName = "Direct Reference"
                if ($line -match '\$(\w+)\s*=.*AutoIssueFinder') {
                    $variableName = "`$$($Matches[1])"
                } elseif ($line -match 'Import-Module') {
                    $variableName = "Import-Module"
                } elseif ($line -match 'Invoke-') {
                    $variableName = "Function Call"
                }
                
                # Extract the string path value
                $stringValue = "N/A"
                if ($line -match '(scripts|modules)[/\\]PwShGUI_AutoIssueFinder\.\w+') {
                    $stringValue = $Matches[0]
                } elseif ($line -match '[''"]([^''"]*AutoIssueFinder[^''"]*\.psm1)[''"]') {
                    $stringValue = $Matches[1]
                }
                
                # Calculate resolved path
                $resolvedValue = "N/A"
                if ($stringValue -ne "N/A" -and $stringValue -match '^(scripts|modules)') {
                    $resolvedValue = Join-Path $rootPath $stringValue
                } elseif ($stringValue -match '^[cC]:\\') {
                    $resolvedValue = $stringValue
                }
                
                # Check if path exists
                $pathStatus = "N/A"
                if ($resolvedValue -match '^[cC]:\\') {
                    $pathStatus = if (Test-Path $resolvedValue -ErrorAction SilentlyContinue) { 
                        "EXISTS" 
                    } else { 
                        "NOT FOUND" 
                    }
                }
                
                $results += [PSCustomObject]@{
                    FileName = $file.Name
                    FilePath = $file.FullName
                    LineNumber = $lineNumber
                    VariableName = $variableName
                    StringValue = $stringValue
                    ResolvedPath = $resolvedValue
                    PathStatus = $pathStatus
                    LineContent = $line.Trim().Substring(0, [Math]::Min(100, $line.Trim().Length))
                }
            }
        }
    } catch {
        Write-Warning "Could not process $($file.FullName): $_"
    }
}

# Display summary in console
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  MODULE REFERENCE SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Total references found: $($results.Count)" -ForegroundColor Cyan
Write-Host "`nFiles containing references:" -ForegroundColor Yellow
$results | Group-Object FileName | Select-Object Name, Count | Sort-Object Name | Format-Table -AutoSize

Write-Host "`nPath Status Summary:" -ForegroundColor Yellow
$statusGroup = $results | Where-Object { $_.PathStatus -ne "N/A" } | Group-Object PathStatus
foreach ($group in $statusGroup) {
    $color = if ($group.Name -eq "EXISTS") { "Green" } else { "Red" }
    Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
}

# Show files needing updates
Write-Host "`nFiles needing path updates (scripts\ -> modules\):" -ForegroundColor Magenta
$needsUpdate = $results | Where-Object { $_.StringValue -like "*scripts*AutoIssueFinder*" }
if ($needsUpdate) {
    $needsUpdate | Select-Object FileName, LineNumber, StringValue | Format-Table -AutoSize
} else {
    Write-Host "  None found!" -ForegroundColor Green
}

Write-Host "`nOpening GridView for detailed analysis..." -ForegroundColor Cyan
$results | Sort-Object FilePath, LineNumber | Out-GridView -Title "PwShGUI_AutoIssueFinder References - Moved from scripts\ to modules\" -Wait











