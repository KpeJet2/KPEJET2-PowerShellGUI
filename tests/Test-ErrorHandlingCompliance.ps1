<#
.SYNOPSIS
    Validates error handling compliance across PowerShellGUI workspace.

.DESCRIPTION
    Scans all .ps1 and .psm1 files for error handling violations:
    - SIN-PATTERN-003: SilentlyContinue on I/O operations
    - SIN-PATTERN-002: Empty catch blocks
    - Section 12: Missing try/catch on I/O operations
    - Section 11: Write-Warning/Write-Error instead of Write-AppLog in modules
    
    Generates detailed compliance report with remediation guidance.

.PARAMETER Path
    Root path to scan. Defaults to C:\PowerShellGUI

.PARAMETER Exclude
    Folders to exclude from scan (e.g., .git, .history, node_modules)

.PARAMETER ReportPath
    Where to save the compliance report. Defaults to ~REPORTS/error-handling-compliance-YYYYMMDD.json

.PARAMETER Detailed
    Include detailed line-by-line analysis in report

.EXAMPLE
    .\Test-ErrorHandlingCompliance.ps1
    Scans entire workspace and generates report

.EXAMPLE
    .\Test-ErrorHandlingCompliance.ps1 -Path "C:\PowerShellGUI\modules" -Detailed
    Scans only modules folder with detailed output

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 4th April 2026
    Modified : 4th April 2026
    FileRole : Test
    
.LINK
    ~README.md/ERROR-HANDLING-TEMPLATES.md
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
#>

# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot),
    
    [string[]]$Exclude = @('.git', '.history', '.vscode', 'node_modules', '.venv', 'pki', 'temp', 'remediation-backups'),
    
    [string]$ReportPath = '',
    
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

# Region: Configuration

$ViolationPatterns = @{
    'SIN-003-SilentlyContinue' = @{
        Pattern     = '-ErrorAction\s+SilentlyContinue'
        Description = 'Using -ErrorAction SilentlyContinue on I/O operations'
        Severity    = 'CRITICAL'
        Category    = 'SIN-PATTERN-003'
        IOContexts  = @('Get-Content', 'Set-Content', 'Out-File', 'Add-Content', 
                        'ConvertFrom-Json', 'ConvertTo-Json', 'Get-ChildItem', 
                        'Test-Path', 'New-Item', 'Remove-Item', 'Copy-Item', 
                        'Move-Item', 'Import-Module', 'Get-Item')
    }
    'SIN-002-EmptyCatch' = @{
        Pattern     = 'catch\s*\{\s*\}'
        Description = 'Empty catch block without Write-AppLog or intentional comment'
        Severity    = 'CRITICAL'
        Category    = 'SIN-PATTERN-002'
    }
    'SEC11-WriteWarning' = @{
        Pattern     = 'Write-Warning'
        Description = 'Write-Warning instead of Write-AppLog in modules'
        Severity    = 'HIGH'
        Category    = 'Section-11'
        ApplyTo     = '.psm1'
    }
    'SEC11-WriteError' = @{
        Pattern     = 'Write-Error(?!\s+-ErrorRecord)'
        Description = 'Write-Error instead of Write-AppLog in modules'
        Severity    = 'HIGH'
        Category    = 'Section-11'
        ApplyTo     = '.psm1'
    }
    'SEC12-UnwrappedIO' = @{
        Pattern     = '(Get-Content|Set-Content|Out-File|Add-Content|ConvertFrom-Json|ConvertTo-Json|New-Item|Remove-Item)'
        Description = 'I/O operation outside try/catch block'
        Severity    = 'CRITICAL'
        Category    = 'Section-12'
        RequiresContext = $true
    }
}

$IOOperations = @(
    'Get-Content', 'Set-Content', 'Out-File', 'Add-Content',
    'ConvertFrom-Json', 'ConvertTo-Json', 'Export-Csv', 'Import-Csv',
    'New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item',
    'Get-ChildItem', 'Test-Path', 'Get-Item', 'Get-ItemProperty'
)

# EndRegion

# Region: Helper Functions

function Write-ComplianceLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info'
    )
    
    $colors = @{
        'Info'    = 'Cyan'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
        'Success' = 'Green'
        'Debug'   = 'Gray'
    }
    
    $prefix = switch ($Level) {
        'Info'    { '[INFO]' }
        'Warning' { '[WARN]' }
        'Error'   { '[ERROR]' }
        'Success' { '[✓]' }
        'Debug'   { '[DEBUG]' }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $colors[$Level]
}

function Test-LineInTryCatch {
    <#
    .SYNOPSIS
        Checks if a line is within a try/catch block.
    #>
    param(
        [string[]]$Lines,
        [int]$TargetLineIndex
    )
    
    $tryDepth = 0
    $inTry = $false
    
    for ($i = 0; $i -lt $TargetLineIndex; $i++) {
        $line = $Lines[$i].Trim()
        
        # Count try blocks
        if ($line -match '^\s*try\s*\{') {
            $tryDepth++
            $inTry = $true
        }
        
        # Count closing braces (approximate - may have false positives)
        if ($line -match '^\s*\}\s*$' -and $tryDepth -gt 0) {
            $tryDepth--
            if ($tryDepth -eq 0) { $inTry = $false }
        }
        
        # Check for catch blocks
        if ($line -match '^\s*catch\s*\{?' -and $tryDepth -gt 0) {
            continue
        }
    }
    
    return $inTry
}

function Get-FunctionContext {
    <#
    .SYNOPSIS
        Gets the function name containing a given line.
    #>
    param(
        [string[]]$Lines,
        [int]$TargetLineIndex
    )
    
    for ($i = $TargetLineIndex; $i -ge 0; $i--) {
        if ($Lines[$i] -match '^\s*function\s+([\w-]+)') {
            return $matches[1]
        }
    }
    
    return '<script-level>'
}

function Test-FileViolations {
    <#
    .SYNOPSIS
        Scans a single file for error handling violations.
    #>
    param(
        [string]$FilePath,
        [hashtable]$Patterns,
        [switch]$Detailed
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-ComplianceLog "File not found: $FilePath" -Level Error
        return @()
    }
    
    try {
        $content = Get-Content $FilePath -Raw -ErrorAction Stop
        $lines = Get-Content $FilePath -ErrorAction Stop
    } catch {
        Write-ComplianceLog "Failed to read $FilePath : $_" -Level Error
        return @()
    }
    
    $violations = @()
    $fileExt = [System.IO.Path]::GetExtension($FilePath)
    
    foreach ($patternKey in $Patterns.Keys) {
        $patternDef = $Patterns[$patternKey]
        
        # Skip if pattern only applies to specific file types
        if ($patternDef.ContainsKey('ApplyTo') -and $patternDef.ApplyTo -and $fileExt -ne $patternDef.ApplyTo) {
            continue
        }
        
        # Handle context-sensitive patterns (Section 12 - unwrapped I/O)
        if ($patternDef.ContainsKey('RequiresContext') -and $patternDef.RequiresContext) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                
                # Check if line contains I/O operation
                $hasIO = $false
                foreach ($op in $IOOperations) {
                    if ($line -match "\b$op\b") {
                        $hasIO = $true
                        break
                    }
                }
                
                if (-not $hasIO) { continue }
                
                # Check if line is in try/catch
                $inTry = Test-LineInTryCatch -Lines $lines -TargetLineIndex $i
                
                if (-not $inTry) {
                    # Check if line uses -ErrorAction Stop (acceptable pattern)
                    if ($line -match '-ErrorAction\s+Stop') {
                        continue
                    }
                    
                    # Check if line is in a function that's CmdletBinding with ErrorActionPreference
                    $functionName = Get-FunctionContext -Lines $lines -TargetLineIndex $i
                    
                    $violations += [PSCustomObject]@{
                        File        = $FilePath
                        Line        = $i + 1
                        Column      = 1
                        Severity    = $patternDef.Severity
                        Category    = $patternDef.Category
                        Description = $patternDef.Description
                        Code        = $line.Trim()
                        Function    = $functionName
                        Pattern     = $patternKey
                    }
                }
            }
        } else {
            # Simple regex pattern matching
            $regex = [regex]::new($patternDef.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $matches = $regex.Matches($content)
            
            foreach ($match in $matches) {
                # Calculate line number
                $lineNumber = ($content.Substring(0, $match.Index) -split "`n").Count
                
                # For SilentlyContinue, check if it's on an I/O operation
                if ($patternKey -eq 'SIN-003-SilentlyContinue') {
                    $lineText = $lines[$lineNumber - 1]
                    $isIOOperation = $false
                    
                    foreach ($ioOp in $patternDef.IOContexts) {
                        if ($lineText -match "\b$ioOp\b") {
                            $isIOOperation = $true
                            break
                        }
                    }
                    
                    if (-not $isIOOperation) { continue }
                }
                
                # For empty catch, check if there's an intentional comment
                if ($patternKey -eq 'SIN-002-EmptyCatch') {
                    # Look for intentional comment in or near catch block
                    $contextStart = [Math]::Max(0, $lineNumber - 3)
                    $contextEnd = [Math]::Min($lines.Count - 1, $lineNumber + 2)
                    $context = $lines[$contextStart..$contextEnd] -join "`n"
                    
                    if ($context -match '<#\s*Intentional') {
                        continue  # Has intentional comment, skip
                    }
                }
                
                $functionName = Get-FunctionContext -Lines $lines -TargetLineIndex ($lineNumber - 1)
                
                $violations += [PSCustomObject]@{
                    File        = $FilePath
                    Line        = $lineNumber
                    Column      = $match.Index - ($content.Substring(0, $match.Index).LastIndexOf("`n"))
                    Severity    = $patternDef.Severity
                    Category    = $patternDef.Category
                    Description = $patternDef.Description
                    Code        = $lines[$lineNumber - 1].Trim()
                    Function    = $functionName
                    Pattern     = $patternKey
                }
            }
        }
    }
    
    return $violations
}

function Export-ComplianceReport {
    <#
    .SYNOPSIS
        Exports compliance report to JSON and Markdown.
    #>
    param(
        [object[]]$Violations,
        [string]$OutputPath,
        [hashtable]$Summary
    )
    
    $jsonReport = @{
        meta = @{
            generated = (Get-Date).ToUniversalTime().ToString('o')
            scanner   = 'Test-ErrorHandlingCompliance.ps1'
            version   = '2604.B2.v1.0'
        }
        summary = $Summary
        violations = $Violations
    }
    
    try {
        $jsonReport | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8 -ErrorAction Stop
        Write-ComplianceLog "JSON report saved: $OutputPath" -Level Success
    } catch {
        Write-ComplianceLog "Failed to save JSON report: $_" -Level Error
    }
    
    # Also create Markdown report
    $mdPath = $OutputPath -replace '\.json$', '.md'
    $mdContent = @"
# Error Handling Compliance Report

**Generated:** $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  
**Scanner:** Test-ErrorHandlingCompliance.ps1 v2604.B2.v1.0  
**Workspace:** $($Summary.workspace)

---

## Executive Summary

**Files Scanned:** $($Summary.filesScanned)  
**Total Violations:** $($Summary.totalViolations)  
**Files with Violations:** $($Summary.filesWithViolations)

### Violations by Severity

| Severity | Count | Percentage |
|----------|-------|------------|
| CRITICAL | $($Summary.bySeverity.CRITICAL) | $([Math]::Round(($Summary.bySeverity.CRITICAL / $Summary.totalViolations) * 100, 1))% |
| HIGH | $($Summary.bySeverity.HIGH) | $([Math]::Round(($Summary.bySeverity.HIGH / $Summary.totalViolations) * 100, 1))% |
| MEDIUM | $($Summary.bySeverity.MEDIUM) | $([Math]::Round(($Summary.bySeverity.MEDIUM / $Summary.totalViolations) * 100, 1))% |

### Violations by Category

$(($Summary.byCategory.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "- **$($_.Key)**: $($_.Value) violations" }) -join "`n")

---

## Top 10 Files with Most Violations

| Rank | File | Violations |
|------|------|------------|
$(($Summary.topFiles | Select-Object -First 10 | ForEach-Object { $i = 1 } { "| $i | $($_.File) | $($_.Count) |"; $i++ }) -join "`n")

---

## Detailed Violations

$(@($Violations | Group-Object File | ForEach-Object {
    $file = $_.Name
    $fileViolations = $_.Group
    
    @"
### $file

**Total Violations:** $($fileViolations.Count)

| Line | Severity | Category | Description |
|------|----------|----------|-------------|
$(($fileViolations | ForEach-Object { "| $($_.Line) | $($_.Severity) | $($_.Category) | $($_.Description) |" }) -join "`n")

"@
}) -join "`n`n")

---

## Remediation Guidance

### Critical Priority (SIN-PATTERN-003, Section-12)

**SilentlyContinue on I/O Operations:**
``````powershell
# BEFORE (NON-COMPLIANT)
`$data = Get-Content `$path -ErrorAction SilentlyContinue

# AFTER (COMPLIANT - Template 3)
try {
    `$data = Get-Content `$path -Raw -ErrorAction Stop
    Write-AppLog -Message "Loaded `$path" -Level Debug
} catch {
    Write-AppLog -Message "Failed to load `$path : `$_" -Level Error
    return `$null
}
``````

**Unwrapped I/O Operations:**
``````powershell
# BEFORE (NON-COMPLIANT)
`$data | ConvertTo-Json | Set-Content `$path

# AFTER (COMPLIANT - Template 3)
try {
    `$data | ConvertTo-Json -Depth 10 | Set-Content `$path -Encoding UTF8 -ErrorAction Stop
    Write-AppLog -Message "Saved `$path" -Level Info
} catch {
    Write-AppLog -Message "Failed to save `$path : `$_" -Level Error
    throw
}
``````

### High Priority (Section-11, Write-Warning)

Replace `Write-Warning` with `Write-AppLog -Level Warning` in all modules (.psm1 files).

### References

- [ERROR-HANDLING-TEMPLATES.md](~README.md/ERROR-HANDLING-TEMPLATES.md)
- [REFERENCE-CONSISTENCY-STANDARD.md](~README.md/REFERENCE-CONSISTENCY-STANDARD.md)
- [error-handling-templates.ps1](config/error-handling-templates.ps1)

---

*End of Report*
"@
    
    try {
        $mdContent | Set-Content -Path $mdPath -Encoding UTF8 -ErrorAction Stop
        Write-ComplianceLog "Markdown report saved: $mdPath" -Level Success
    } catch {
        Write-ComplianceLog "Failed to save Markdown report: $_" -Level Error
    }
}

# EndRegion

# Region: Main Execution

Write-ComplianceLog "Starting error handling compliance scan..." -Level Info
Write-ComplianceLog "Workspace: $Path" -Level Info

# Get all PowerShell files
$excludePattern = ($Exclude | ForEach-Object { [regex]::Escape($_) }) -join '|'
$files = @()

try {
    $files = Get-ChildItem -Path $Path -Recurse -Include *.ps1,*.psm1 -File -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch $excludePattern }
} catch {
    Write-ComplianceLog "Failed to enumerate files: $_" -Level Error
    exit 1
}

Write-ComplianceLog "Found $(@($files).Count) PowerShell files to scan" -Level Info

# Scan each file
$allViolations = @()
$filesScanned = 0
$filesWithViolations = 0

foreach ($file in $files) {
    $filesScanned++
    
    if ($filesScanned % 10 -eq 0) {
        Write-ComplianceLog "Progress: $filesScanned / $(@($files).Count) files scanned..." -Level Debug
    }
    
    $violations = Test-FileViolations -FilePath $file.FullName -Patterns $ViolationPatterns -Detailed:$Detailed
    
    if (@($violations).Count -gt 0) {
        $filesWithViolations++
        $allViolations += $violations
        
        if ($Detailed) {
            Write-ComplianceLog "$($file.Name): $(@($violations).Count) violations" -Level Warning
        }
    }
}

Write-ComplianceLog "" -Level Info
Write-ComplianceLog "Scan complete!" -Level Success
Write-ComplianceLog "Files scanned: $filesScanned" -Level Info
Write-ComplianceLog "Files with violations: $filesWithViolations" -Level Info
Write-ComplianceLog "Total violations: $(@($allViolations).Count)" -Level $(if (@($allViolations).Count -eq 0) { 'Success' } else { 'Warning' })

# Generate summary
$summary = @{
    workspace           = $Path
    filesScanned        = $filesScanned
    filesWithViolations = $filesWithViolations
    totalViolations     = @($allViolations).Count
    bySeverity          = @{
        CRITICAL = @($allViolations | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
        HIGH     = @($allViolations | Where-Object { $_.Severity -eq 'HIGH' }).Count
        MEDIUM   = @($allViolations | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
    }
    byCategory          = @{}
    topFiles            = @()
}

# Group by category
$allViolations | Group-Object Category | ForEach-Object {
    $summary.byCategory[$_.Name] = $_.Count
}

# Top files with most violations
$summary.topFiles = @($allViolations | Group-Object File | 
    Select-Object @{N='File';E={$_.Name}}, Count | 
    Sort-Object Count -Descending)

# Display summary
Write-ComplianceLog "" -Level Info
Write-ComplianceLog "=== Violations by Severity ===" -Level Info
Write-ComplianceLog "CRITICAL: $($summary.bySeverity.CRITICAL)" -Level $(if ($summary.bySeverity.CRITICAL -gt 0) { 'Error' } else { 'Success' })
Write-ComplianceLog "HIGH:     $($summary.bySeverity.HIGH)" -Level $(if ($summary.bySeverity.HIGH -gt 0) { 'Warning' } else { 'Success' })
Write-ComplianceLog "MEDIUM:   $($summary.bySeverity.MEDIUM)" -Level $(if ($summary.bySeverity.MEDIUM -gt 0) { 'Warning' } else { 'Success' })

Write-ComplianceLog "" -Level Info
Write-ComplianceLog "=== Violations by Category ===" -Level Info
$summary.byCategory.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-ComplianceLog "$($_.Key): $($_.Value)" -Level Info
}

if ($summary.topFiles.Count -gt 0) {
    Write-ComplianceLog "" -Level Info
    Write-ComplianceLog "=== Top 5 Files with Most Violations ===" -Level Info
    $summary.topFiles | Select-Object -First 5 | ForEach-Object {
        $relativePath = $_.File -replace [regex]::Escape($Path), ''
        Write-ComplianceLog "$($_.Count) violations: $relativePath" -Level Warning
    }
}

# Export report
if (-not $ReportPath) {
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $ReportPath = Join-Path $Path "~REPORTS\error-handling-compliance-$timestamp.json"
}

$reportDir = Split-Path $ReportPath -Parent
if (-not (Test-Path $reportDir)) {
    try {
        New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-ComplianceLog "Failed to create report directory: $_" -Level Error
        exit 1
    }
}

Export-ComplianceReport -Violations $allViolations -OutputPath $ReportPath -Summary $summary

# Exit with appropriate code
if ($summary.bySeverity.CRITICAL -gt 0) {
    Write-ComplianceLog "" -Level Error
    Write-ComplianceLog "CRITICAL violations found. Review report for details." -Level Error
    exit 1
} elseif ($summary.bySeverity.HIGH -gt 0) {
    Write-ComplianceLog "" -Level Warning
    Write-ComplianceLog "HIGH severity violations found. Review report for details." -Level Warning
    exit 2
} else {
    Write-ComplianceLog "" -Level Success
    Write-ComplianceLog "No critical violations found!" -Level Success
    exit 0
}

# EndRegion
