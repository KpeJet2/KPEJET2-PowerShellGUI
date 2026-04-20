# VersionTag: 2604.B1.V31.0
# FileRole: Pipeline
<#
.SYNOPSIS
    Automated batch remediation for common error handling violations.

.DESCRIPTION
    Applies automated fixes for easily correctable patterns:
    - SEC11-WriteWarning: Write-Warning → Write-AppLog -Level Warning
    - SEC11-WriteError: Write-Error → Write-AppLog -Level Error  
    - SIN-003: -ErrorAction SilentlyContinue → try/catch pattern (selective)
    
    Backs up files before modification and generates remediation report.

.PARAMETER Path
    Root path containing files to remediate. Defaults to C:\PowerShellGUI

.PARAMETER FileFilter
    Specific files to target (e.g., 'UserProfileManager.psm1'). Wildcards supported.

.PARAMETER Pattern
    Which patterns to fix: WriteWarning, WriteError, SilentlyContinue, All

.PARAMETER WhatIf
    Show what would be changed without making changes

.PARAMETER BackupDir
    Where to store file backups. Defaults to ~REPORTS/remediation-backups/TIMESTAMP

.EXAMPLE
    .\Invoke-ErrorHandlingRemediation.ps1 -Pattern WriteWarning
    Fix all Write-Warning → Write-AppLog conversions

.EXAMPLE
    .\Invoke-ErrorHandlingRemediation.ps1 -FileFilter "UserProfile*.psm1" -Pattern All
    Fix all patterns in UserProfile modules

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th April 2026
    Modified : 4th April 2026
    FileRole : Remediation Script
#>

# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot),
    
    [string]$FileFilter = '*',
    
    [ValidateSet('WriteWarning', 'WriteError', 'SilentlyContinue', 'All')]
    [string]$Pattern = 'All',
    
    [string]$BackupDir = ''
)

$ErrorActionPreference = 'Stop'

# Create backup directory
if (-not $BackupDir) {
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $BackupDir = Join-Path $Path "~REPORTS\remediation-backups\$timestamp"
}

if (-not (Test-Path $BackupDir)) {
    try {
        New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop | Out-Null
        Write-Host "[INFO] Backup directory created: $BackupDir" -ForegroundColor Cyan
    } catch {
        Write-Host "[ERROR] Failed to create backup directory: $_" -ForegroundColor Red
        exit 1
    }
}

# Get compliance report
$reportFiles = Get-ChildItem -Path (Join-Path $Path '~REPORTS') -Filter 'error-handling-compliance-*.json' |
    Sort-Object LastWriteTime -Descending

if (@($reportFiles).Count -eq 0) {
    Write-Host "[ERROR] No compliance report found. Run Test-ErrorHandlingCompliance.ps1 first." -ForegroundColor Red
    exit 1
}

$reportPath = $reportFiles[0].FullName
Write-Host "[INFO] Using compliance report: $($reportFiles[0].Name)" -ForegroundColor Cyan  # SIN-EXEMPT: P027 - array guarded by Count check or conditional on prior/surrounding line

try {
    $report = Get-Content $reportPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "[ERROR] Failed to load compliance report: $_" -ForegroundColor Red
    exit 1
}

# Filter violations by pattern
$targetViolations = @($report.violations)

if ($FileFilter -ne '*') {
    $targetViolations = @($targetViolations | Where-Object { 
        $_.File -like "*$FileFilter*" 
    })
}

if ($Pattern -ne 'All') {
    $patternMap = @{
        'WriteWarning'       = 'SEC11-WriteWarning'
        'WriteError'         = 'SEC11-WriteError'
        'SilentlyContinue'   = 'SIN-003-SilentlyContinue'
    }
    
    $targetViolations = @($targetViolations | Where-Object { 
        $_.Pattern -eq $patternMap[$Pattern] 
    })
}

$filesToFix = $targetViolations | Group-Object File

Write-Host "[INFO] Found $(@($targetViolations).Count) violations in $(@($filesToFix).Count) files" -ForegroundColor Cyan

if (@($targetViolations).Count -eq 0) {
    Write-Host "[INFO] No violations to fix. Exiting." -ForegroundColor Green
    exit 0
}

# Process each file
$fixedCount = 0
$skippedCount = 0
$errorCount = 0

foreach ($fileGroup in $filesToFix) {
    $filePath = $fileGroup.Name
    $violations = $fileGroup.Group
    
    Write-Host "`n[INFO] Processing: $filePath" -ForegroundColor Cyan
    Write-Host "  Violations: $(@($violations).Count)" -ForegroundColor Gray
    
    if (-not (Test-Path $filePath)) {
        Write-Host "  [SKIP] File not found" -ForegroundColor Yellow
        $skippedCount++
        continue
    }
    
    # Backup file
    $backupPath = Join-Path $BackupDir ([System.IO.Path]::GetFileName($filePath))
    try {
        Copy-Item -Path $filePath -Destination $backupPath -Force -ErrorAction Stop
    } catch {
        Write-Host "  [ERROR] Backup failed: $_" -ForegroundColor Red
        $errorCount++
        continue
    }
    
    # Read file
    try {
        $content = Get-Content $filePath -Raw -ErrorAction Stop
        $originalContent = $content
    } catch {
        Write-Host "  [ERROR] Failed to read file: $_" -ForegroundColor Red
        $errorCount++
        continue
    }
    
    # Apply fixes based on violation patterns
    $changesMade = 0
    
    foreach ($violation in $violations) {
        switch -Regex ($violation.Pattern) {
            '^SEC11-WriteWarning$' {
                # Replace Write-Warning with Write-AppLog
                $oldPattern = 'Write-Warning\s+'
                $newReplacement = 'Write-AppLog -Message '
                
                # More precise replacement with -Level Warning
                $oldPattern2 = 'Write-Warning\s+"([^"]+)"'
                $newReplacement2 = 'Write-AppLog -Message "$1" -Level Warning'
                
                $oldPattern3 = "Write-Warning\s+'([^']+)'"
                $newReplacement3 = "Write-AppLog -Message '$1' -Level Warning"
                
                $oldPattern4 = 'Write-Warning\s+\("([^"]+)"\)'
                $newReplacement4 = 'Write-AppLog -Message "$1" -Level Warning'
                
                $oldPattern5 = 'Write-Warning\s+\(\$([^\)]+)\)'
                $newReplacement5 = 'Write-AppLog -Message $$$1 -Level Warning'
                
                # Apply replacements
                $newContent = $content -replace $oldPattern2, $newReplacement2
                $newContent = $newContent -replace $oldPattern3, $newReplacement3
                $newContent = $newContent -replace $oldPattern4, $newReplacement4
                $newContent = $newContent -replace $oldPattern5, $newReplacement5
                
                if ($newContent -ne $content) {
                    $content = $newContent
                    $changesMade++
                }
            }
            
            '^SEC11-WriteError$' {
                # Replace Write-Error with Write-AppLog
                $oldPattern = 'Write-Error\s+"([^"]+)"'
                $newReplacement = 'Write-AppLog -Message "$1" -Level Error'
                
                $oldPattern2 = "Write-Error\s+'([^']+)'"
                $newReplacement2 = "Write-AppLog -Message '$1' -Level Error"
                
                $newContent = $content -replace $oldPattern, $newReplacement
                $newContent = $newContent -replace $oldPattern2, $newReplacement2
                
                if ($newContent -ne $content) {
                    $content = $newContent
                    $changesMade++
                }
            }
            
            '^SIN-003-SilentlyContinue$' {
                # This requires context-sensitive replacement - skip for now
                # Manual review needed to ensure try/catch is appropriate
                Write-Host "  [SKIP] SilentlyContinue at line $($violation.Line) - manual review required" -ForegroundColor Yellow
            }
        }
    }
    
    # Write changes if any
    if ($content -ne $originalContent) {
        try {
            $content | Set-Content -Path $filePath -Encoding UTF8 -ErrorAction Stop
            Write-Host "  [SUCCESS] Applied $changesMade changes" -ForegroundColor Green
            $fixedCount++
        } catch {
            Write-Host "  [ERROR] Failed to write file: $_" -ForegroundColor Red
            # Restore from backup
            try {
                Copy-Item -Path $backupPath -Destination $filePath -Force -ErrorAction Stop
                Write-Host "  [INFO] Restored from backup" -ForegroundColor Yellow
            } catch {
                Write-Host "  [ERROR] Failed to restore backup: $_" -ForegroundColor Red
            }
            $errorCount++
        }
    } else {
        Write-Host "  [SKIP] No changes needed (pattern may have been fixed already)" -ForegroundColor Yellow
        $skippedCount++
    }
}

# Summary
Write-Host "`n=== Remediation Summary ===" -ForegroundColor Cyan
Write-Host "Files fixed:   $fixedCount" -ForegroundColor Green
Write-Host "Files skipped: $skippedCount" -ForegroundColor Yellow
Write-Host "Errors:        $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Backups:       $BackupDir" -ForegroundColor Gray

# Generate remediation report
$remediationReport = @{
    meta = @{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        script    = 'Invoke-ErrorHandlingRemediation.ps1'
        version   = '2604.B2.v1.0'
        pattern   = $Pattern
        fileFilter = $FileFilter
    }
    summary = @{
        filesFixed   = $fixedCount
        filesSkipped = $skippedCount
        errors       = $errorCount
        backupDir    = $BackupDir
    }
    filesProcessed = @($filesToFix | ForEach-Object {
        @{
            file = $_.Name
            violations = $_.Count
        }
    })
}

$reportOutPath = Join-Path $BackupDir 'remediation-report.json'
try {
    $remediationReport | ConvertTo-Json -Depth 10 | Set-Content -Path $reportOutPath -Encoding UTF8 -ErrorAction Stop
    Write-Host "`n[SUCCESS] Remediation report saved: $reportOutPath" -ForegroundColor Green
} catch {
    Write-Host "`n[ERROR] Failed to save remediation report: $_" -ForegroundColor Red
}

exit $(if ($errorCount -gt 0) { 1 } else { 0 })
