#Requires -Version 5.1
# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag
<#
.SYNOPSIS
    SyntaxGuard -- Automated syntax and integrity validation for PwShGUI workspace.
.DESCRIPTION
    Scans all .ps1 and .psm1 files for:
      - Parse errors (via Parser::ParseFile)
      - PS7-only operators used outside version guards
      - Em dash U+2014 in double-quoted strings (PS 5.1 parse bug)
      - Null bytes / UTF-16 LE encoding issues
      - Duplicate function definitions within a single file
      - Abnormal file sizes (>5MB WARN, >20MB FAIL)
      - Empty catch blocks (error swallowing)
      - SilentlyContinue on Import-Module (masked load failures)
    Returns structured results and exit code.
.PARAMETER WorkspacePath
    Root folder to scan. Defaults to parent of tests/.
.PARAMETER Strict
    Treat warnings as failures for CI gating.
.PARAMETER PassThru
    Return result objects to pipeline.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$Strict,
    [switch]$PassThru
)

Set-StrictMode -Version Latest

$script:Results = [System.Collections.ArrayList]::new()
$script:Counters = @{ Pass = 0; Warn = 0; Fail = 0; Info = 0 }

function Add-SGResult {
    param(
        [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [string]$Check,
        [string]$File,
        [string]$Detail
    )
    $entry = [PSCustomObject]@{
        Status = $Status; Check = $Check; File = $File
        Detail = $Detail; Time = (Get-Date -Format 'HH:mm:ss')
    }
    [void]$script:Results.Add($entry)
    $script:Counters[$Status]++
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'INFO' { 'Cyan' } }
    $rel = if ($File) { $File.Replace($WorkspacePath, '').TrimStart('\') } else { '' }
    Write-Host ("  [{0}] {1,-18} {2}  {3}" -f $Status, $Check, $rel, $Detail) -ForegroundColor $color
}

Write-Host "`n=== SyntaxGuard v1.0 ===" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspacePath" -ForegroundColor DarkGray

$excludePattern = '[\\/](\.[^\\\/]+|temp|node_modules|__pycache__)[\\/]'
$allFiles = Get-ChildItem -Path $WorkspacePath -Include '*.ps1','*.psm1' -Recurse -File |
    Where-Object { $_.FullName -notmatch $excludePattern -and -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden) }

Write-Host "Files to scan: $($allFiles.Count)" -ForegroundColor DarkGray
Write-Host ("=" * 60)

# CHECK 1: File Size Anomalies
Write-Host "`n--- Check 1: File Size ---" -ForegroundColor White
foreach ($f in $allFiles) {
    $sizeMB = $f.Length / 1MB
    if ($sizeMB -gt 20) {
        Add-SGResult 'FAIL' 'FileSize' $f.FullName ("CRITICAL: {0:N1} MB -- likely corrupted" -f $sizeMB)
    } elseif ($sizeMB -gt 5) {
        Add-SGResult 'WARN' 'FileSize' $f.FullName ("{0:N1} MB -- unusually large" -f $sizeMB)
    }
}
$bigCount = @($allFiles | Where-Object { $_.Length -gt 5MB }).Count
if ($bigCount -eq 0) {
    Add-SGResult 'PASS' 'FileSize' '' "All $($allFiles.Count) files under 5 MB"
}

# CHECK 2: Encoding and Null Bytes
Write-Host "`n--- Check 2: Encoding ---" -ForegroundColor White
$encodingIssues = 0
foreach ($f in $allFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nullIdx = [Array]::IndexOf($bytes, [byte]0)
    if ($nullIdx -ge 0 -and $nullIdx -lt $bytes.Length) {
        Add-SGResult 'FAIL' 'Encoding' $f.FullName "Null byte at offset $nullIdx"
        $encodingIssues++; continue
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        Add-SGResult 'WARN' 'Encoding' $f.FullName 'UTF-16 LE BOM -- should be UTF-8'
        $encodingIssues++
    }
}
if ($encodingIssues -eq 0) {
    Add-SGResult 'PASS' 'Encoding' '' "All $($allFiles.Count) files clean encoding"
}

# CHECK 3: Parse Errors
Write-Host "`n--- Check 3: Parse Errors ---" -ForegroundColor White
$parseFailCount = 0
foreach ($f in $allFiles) {
    try {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            Add-SGResult 'FAIL' 'ParseError' $f.FullName "Line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
            $parseFailCount++
        }
    } catch {
        Add-SGResult 'FAIL' 'ParseError' $f.FullName "Parser crash: $($_.Exception.Message)"
        $parseFailCount++
    }
}
if ($parseFailCount -eq 0) {
    Add-SGResult 'PASS' 'ParseError' '' "All $($allFiles.Count) files parse clean"
}

# CHECK 4: Em Dash (U+2014) in double-quoted strings
Write-Host "`n--- Check 4: Em Dash (U+2014) ---" -ForegroundColor White
$emDashHits = 0
foreach ($f in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.IndexOf([char]0x2014) -lt 0) { continue }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        if ($line -match '"[^"]*\u2014[^"]*"') {
            Add-SGResult 'FAIL' 'EmDash' $f.FullName "Line $($i+1): em dash in double-quoted string (PS 5.1 bug)"
            $emDashHits++
        } elseif ($trimmed -notmatch "^#|^'") {
            Add-SGResult 'WARN' 'EmDash' $f.FullName "Line $($i+1): em dash in code"
            $emDashHits++
        }
    }
}
if ($emDashHits -eq 0) {
    Add-SGResult 'PASS' 'EmDash' '' "No em dashes found"
}

# CHECK 5: PS7-Only Operators
Write-Host "`n--- Check 5: PS7-Only Operators ---" -ForegroundColor White
$ps7Hits = 0
foreach ($f in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        if ($line -match '(?<!\?)\?\?(?!\?)' -and $line -notmatch '#.*\?\?') {
            Add-SGResult 'WARN' 'PS7Operator' $f.FullName "Line $($i+1): ?? (null-coalescing)"
            $ps7Hits++
        }
        if ($line -match '\?\.\w' -and $line -notmatch '#.*\?\.' -and $line -notmatch "'\?\.'") {
            Add-SGResult 'WARN' 'PS7Operator' $f.FullName "Line $($i+1): ?. (null-conditional)"
            $ps7Hits++
        }
    }
}
if ($ps7Hits -eq 0) {
    Add-SGResult 'PASS' 'PS7Operator' '' "No PS7-only operators detected"
}

# CHECK 6: Duplicate Function Definitions
Write-Host "`n--- Check 6: Duplicate Functions ---" -ForegroundColor White
$dupCount = 0
foreach ($f in $allFiles) {
    try {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if (-not $ast) { continue }
        $fnDefs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $fnNames = @{}
        foreach ($fn in $fnDefs) {
            $name = $fn.Name
            if ($fnNames.ContainsKey($name)) {
                $fnNames[$name]++
                if ($fnNames[$name] -eq 2) {
                    Add-SGResult 'WARN' 'DuplicateFn' $f.FullName "'$name' defined multiple times"
                    $dupCount++
                }
            } else { $fnNames[$name] = 1 }
        }
    } catch { <# Intentional: file may fail to parse, skip gracefully #> }
}
if ($dupCount -eq 0) {
    Add-SGResult 'PASS' 'DuplicateFn' '' "No duplicate function definitions"
}




# CHECK 7: Corruption Detection (Content Multiplication)
Write-Host "`n--- Check 7: Corruption Detection ---" -ForegroundColor White
$corruptHits = 0
foreach ($f in $allFiles) {
    try {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if (-not $ast) { continue }
        $fnDefs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $fnCounts = @{}
        foreach ($fn in $fnDefs) {
            $name = $fn.Name
            if ($fnCounts.ContainsKey($name)) { $fnCounts[$name]++ } else { $fnCounts[$name] = 1 }
        }
        foreach ($name in $fnCounts.Keys) {
            if ($fnCounts[$name] -ge 5) {
                Add-SGResult 'FAIL' 'Corruption' $f.FullName "POTENTIAL CORRUPTION: '$name' defined $($fnCounts[$name])x (threshold: 5)"
                $corruptHits++
            }
        }
    } catch { <# Intentional: file may fail to parse, skip gracefully #> }
}
if ($corruptHits -eq 0) {
    Add-SGResult 'PASS' 'Corruption' '' 'No content-multiplication corruption detected'
}

# CHECK 8: Empty Catch Block Audit
Write-Host "`n--- Check 8: Empty Catch Blocks ---" -ForegroundColor White
$emptyCatchHits = 0
foreach ($f in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Match catch { } on single line
        if ($line -match 'catch\s*\{\s*\}') {
            Add-SGResult 'WARN' 'EmptyCatch' $f.FullName "Line $($i+1): empty catch block (should log with Write-AppLog)"
            $emptyCatchHits++
        }
        # Match catch { followed by lone }
        elseif ($line -match 'catch\s*\{\s*$' -and ($i + 1) -lt $lines.Count -and $lines[$i+1].Trim() -match '^\}$') {
            Add-SGResult 'WARN' 'EmptyCatch' $f.FullName "Line $($i+1): empty catch block (should log with Write-AppLog)"
            $emptyCatchHits++
        }
    }
}
if ($emptyCatchHits -eq 0) {
    Add-SGResult 'PASS' 'EmptyCatch' '' 'No empty catch blocks found'
}

# CHECK 9: SilentlyContinue on Import-Module
Write-Host "`n--- Check 9: Silent Import-Module ---" -ForegroundColor White
$silentImportHits = 0
foreach ($f in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        if ($line -match 'Import-Module\s+.*-ErrorAction\s+SilentlyContinue') {
            Add-SGResult 'WARN' 'SilentImport' $f.FullName "Line $($i+1): Import-Module with SilentlyContinue masks load failures"
            $silentImportHits++
        }
    }
}
if ($silentImportHits -eq 0) {
    Add-SGResult 'PASS' 'SilentImport' '' 'No silent Import-Module patterns found'
}

# SUMMARY
Write-Host ("`n" + "=" * 60)
Write-Host "SyntaxGuard Summary" -ForegroundColor Cyan
Write-Host ("  PASS: {0}  WARN: {1}  FAIL: {2}  INFO: {3}" -f $script:Counters.Pass, $script:Counters.Warn, $script:Counters.Fail, $script:Counters.Info)

$exitCode = 0
if ($script:Counters.Fail -gt 0) { $exitCode = 1 }
if ($Strict -and $script:Counters.Warn -gt 0) { $exitCode = 1 }

if ($exitCode -eq 0) {
    Write-Host "  RESULT: PASSED" -ForegroundColor Green
} else {
    Write-Host "  RESULT: FAILED" -ForegroundColor Red
}
Write-Host ("=" * 60)

if ($PassThru) { return $script:Results }
exit $exitCode

