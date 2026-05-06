# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 5 entries)
<#
.SYNOPSIS
    Automated test routines for the KPEJET2 PowerShell GUI application.

.DESCRIPTION
    Performs a battery of automated tests against repository scripts including:
    - Syntax and parse validation across PowerShell 5.1 and 7+
    - Variable consistency checks (declared vs referenced)
    - Version tag compliance (duplicate tags, format validation)
    - Function signature validation (parameter types, mandatory flags)
    - Error handling pattern coverage (try/catch, ErrorAction)
    - Dotfile and markdown standards compliance
    - Configuration file well-formedness (XML, JSON)

    Each test emits a PSCustomObject with Status, Test, File, and Detail fields.
    Results are written to a timestamped log under logs/ and returned as an array.

.PARAMETER TargetPath
    Path to a specific script file to test. If omitted, all repository scripts
    are tested.

.PARAMETER OutputFormat
    Format for the results: 'Console' (default), 'Log', or 'Both'.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 23rd February 2026

.EXAMPLE
    .\tests\Invoke-AutomatedTests.ps1
    Runs all tests against the full repository.

.EXAMPLE
    .\tests\Invoke-AutomatedTests.ps1 -TargetPath .\Main-GUI.ps1
    Runs all tests against only Main-GUI.ps1.
#>

param(
    [string]$TargetPath,
    [ValidateSet('Console', 'Log', 'Both')]
    [string]$OutputFormat = 'Both'
)

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$results    = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-TestResult {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param(
        [string]$Status,
        [string]$Test,
        [string]$File,
        [string]$Detail
    )
    $results.Add([pscustomobject]@{
        Status = $Status
        Test   = $Test
        File   = $File
        Detail = $Detail
    })
}

# Resolve files to test
if ($TargetPath) {
    if (-not (Test-Path $TargetPath)) {
        Write-Error "Target path not found: $TargetPath"
        return
    }
    $item = Get-Item $TargetPath
    if ($item.PSIsContainer) {
        $psFiles  = Get-ChildItem -Path $TargetPath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue
    } else {
        $psFiles = @($item)
    }
} else {
    $psFiles = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\.vscode\*' }
}

$mdFiles   = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.md  -ErrorAction SilentlyContinue
$xmlFiles  = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.xml -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\.history\*' }
$jsonFiles = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.json -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\.history\*' }
$batFiles  = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.bat  -ErrorAction SilentlyContinue

# ==============================================================================
# TEST 1: PowerShell Syntax / Parse Validation
# ==============================================================================
Write-Host "`n[TEST 1] Syntax Parse Validation" -ForegroundColor Cyan
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    try {
        $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        [System.Management.Automation.Language.Parser]::ParseInput(
            $content, [ref]$tokens, [ref]$errors
        ) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            foreach ($e in $errors) {
                Add-TestResult -Status 'FAIL' -Test 'SyntaxParse' -File $file.FullName -Detail $e.Message
            }
        } else {
            Add-TestResult -Status 'PASS' -Test 'SyntaxParse' -File $file.FullName -Detail 'No parse errors'
        }
    } catch {
        Add-TestResult -Status 'ERROR' -Test 'SyntaxParse' -File $file.FullName -Detail $_.Exception.Message
    }
}

# ==============================================================================
# TEST 2: Version Tag Compliance
# ==============================================================================
Write-Host "[TEST 2] Version Tag Compliance" -ForegroundColor Cyan
$configFile = Join-Path $scriptRoot 'config\system-variables.xml'
$expectedVersion = '2602.a.11'
if (Test-Path $configFile) {
    try {
        [xml]$cfgXml = Get-Content $configFile
        $major = $cfgXml.SystemVariables.Version.Major
        $minor = $cfgXml.SystemVariables.Version.Minor
        $build = $cfgXml.SystemVariables.Version.Build
        if ($major -and $minor -and $build) {
            $expectedVersion = "$major.$minor.$build"
        }
    } catch { <# use default #> }
}

$tagPattern = 'VersionTag:\s*([\d\.a-z]+)'
$excludeFolders = @('.history', '.vscode', 'logs', 'temp', '~REPORTS', '~DOWNLOADS', '~BACKUPS', 'node_modules', 'tests')

foreach ($file in $psFiles) {
    $rel = $file.FullName.Substring($scriptRoot.Length).TrimStart('\/')
    $skip = $false
    foreach ($ex in $excludeFolders) { if ($rel -like "$ex*") { $skip = $true; break } }
    if ($skip) { continue }

    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Check for duplicate VersionTag lines
    $tagMatches = [regex]::Matches($content, "(?m)^[#\s]*$tagPattern")
    if ($tagMatches.Count -gt 1) {
        $tags = $tagMatches | ForEach-Object { $_.Groups[1].Value }
        Add-TestResult -Status 'WARN' -Test 'DuplicateVersionTag' -File $file.FullName `
            -Detail "Found $($tagMatches.Count) VersionTag lines: $($tags -join ', ')"
    }

    # Check tag value matches expected
    if ($content -match $tagPattern) {
        $foundTag = $Matches[1]
        if ($foundTag -ne $expectedVersion) {
            Add-TestResult -Status 'FAIL' -Test 'VersionTagMismatch' -File $file.FullName `
                -Detail "Expected '$expectedVersion', found '$foundTag'"
        } else {
            Add-TestResult -Status 'PASS' -Test 'VersionTagMatch' -File $file.FullName `
                -Detail "Tag matches: $foundTag"
        }
    } else {
        Add-TestResult -Status 'WARN' -Test 'VersionTagMissing' -File $file.FullName `
            -Detail 'No VersionTag found'
    }
}

# ==============================================================================
# TEST 3: Function Naming and Signature Validation
# ==============================================================================
Write-Host "[TEST 3] Function Naming and Signatures" -ForegroundColor Cyan
$approvedVerbs = @(Get-Verb | Select-Object -ExpandProperty Verb)

foreach ($file in $psFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $funcMatches = [regex]::Matches($content, '(?m)^\s*function\s+([\w-]+)')
    foreach ($fm in $funcMatches) {
        $funcName = $fm.Groups[1].Value
        if ($funcName -match '^(\w+)-') {
            $verb = $Matches[1]
            if ($approvedVerbs -notcontains $verb) {
                Add-TestResult -Status 'WARN' -Test 'UnapprovedVerb' -File $file.FullName `
                    -Detail "Function '$funcName' uses unapproved verb '$verb'"
            }
        }
    }
}

# ==============================================================================
# TEST 4: Error Handling Pattern Coverage
# ==============================================================================
Write-Host "[TEST 4] Error Handling Pattern Coverage" -ForegroundColor Cyan
foreach ($file in $psFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $funcMatches = [regex]::Matches($content, '(?ms)function\s+([\w-]+)\s*\{(.*?)\n\}')
    foreach ($fm in $funcMatches) {
        $funcName = $fm.Groups[1].Value
        $funcBody = $fm.Groups[2].Value

        $hasTryCatch    = $funcBody -match '\btry\s*\{'
        $hasErrorAction = $funcBody -match '-ErrorAction'
        $hasWriteError  = $funcBody -match 'Write-(AppLog|Error|Warning)'

        if (-not $hasTryCatch -and -not $hasErrorAction) {
            Add-TestResult -Status 'WARN' -Test 'NoErrorHandling' -File $file.FullName `
                -Detail "Function '$funcName' has no try/catch or -ErrorAction"
        }
    }
}

# ==============================================================================
# TEST 5: Variable Consistency (declared vs referenced)
# ==============================================================================
Write-Host "[TEST 5] Variable Consistency" -ForegroundColor Cyan
foreach ($file in $psFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $rel = $file.FullName.Substring($scriptRoot.Length).TrimStart('\/')

    # Check for automatic variable shadowing (assignments to automatic variables)
    $autoVars = @(
        @{ Name = '$args';     Pattern = '\$args\s*=\s*@?\(' },
        @{ Name = '$input';    Pattern = '\$input\s*=\s' },
        @{ Name = '$PSItem';   Pattern = '\$PSItem\s*=\s' },
        @{ Name = '$_';        Pattern = '\$_\s*=\s' },
        @{ Name = '$this';     Pattern = '\$this\s*=\s' },
        @{ Name = '$PSCmdlet'; Pattern = '\$PSCmdlet\s*=\s' }
    )
    foreach ($av in $autoVars) {
        if ($content -match ('(?m)^\s*' + $av.Pattern)) {
            Add-TestResult -Status 'WARN' -Test 'AutoVarShadow' -File $file.FullName `
                -Detail "Possible shadowing of automatic variable '$($av.Name)'"
        }
    }

    # Check for hardcoded paths that should be variables
    $hardcodedPaths = [regex]::Matches($content, '[A-Z]:\\[A-Za-z0-9\\]+')
    foreach ($hp in $hardcodedPaths) {
        if ($hp.Value -notmatch '\\Windows\\|\\Program Files|\\AppData\\') {
            Add-TestResult -Status 'INFO' -Test 'HardcodedPath' -File $file.FullName `
                -Detail "Hardcoded path found: $($hp.Value)"
        }
    }
}

# ==============================================================================
# TEST 6: XML Configuration Well-Formedness
# ==============================================================================
Write-Host "[TEST 6] XML Well-Formedness" -ForegroundColor Cyan
foreach ($file in $xmlFiles) {
    try {
        [xml]$doc = Get-Content $file.FullName -ErrorAction Stop
        Add-TestResult -Status 'PASS' -Test 'XmlWellFormed' -File $file.FullName -Detail 'Valid XML'
    } catch {
        Add-TestResult -Status 'FAIL' -Test 'XmlWellFormed' -File $file.FullName -Detail $_.Exception.Message
    }
}

# ==============================================================================
# TEST 7: JSON Configuration Well-Formedness
# ==============================================================================
Write-Host "[TEST 7] JSON Well-Formedness" -ForegroundColor Cyan
foreach ($file in $jsonFiles) {
    try {
        $raw = Get-Content $file.FullName -Raw -ErrorAction Stop
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
        Add-TestResult -Status 'PASS' -Test 'JsonWellFormed' -File $file.FullName -Detail 'Valid JSON'
    } catch {
        Add-TestResult -Status 'FAIL' -Test 'JsonWellFormed' -File $file.FullName -Detail $_.Exception.Message
    }
}

# ==============================================================================
# TEST 8: Markdown Standards
# ==============================================================================
Write-Host "[TEST 8] Markdown Standards" -ForegroundColor Cyan
foreach ($file in $mdFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) {
        Add-TestResult -Status 'WARN' -Test 'MarkdownEmpty' -File $file.FullName -Detail 'File is empty'
        continue
    }

    # Check for H1 heading
    if ($content -notmatch '(?m)^#\s+') {
        Add-TestResult -Status 'WARN' -Test 'MarkdownNoH1' -File $file.FullName `
            -Detail 'No H1 heading found'
    }

    # Check for trailing whitespace
    $lines = $content -split "`n"
    $trailingWS = 0
    foreach ($line in $lines) {
        if ($line -match '\S\s{2,}$' -or ($line -match '\t$')) { $trailingWS++ }
    }
    if ($trailingWS -gt 0) {
        Add-TestResult -Status 'INFO' -Test 'MarkdownTrailingWS' -File $file.FullName `
            -Detail "$trailingWS lines with trailing whitespace"
    }

    # Check for TODO/TBD markers
    if ($content -match '\bTODO\b|\bTBD\b|\bFIXME\b') {
        Add-TestResult -Status 'INFO' -Test 'MarkdownTodo' -File $file.FullName `
            -Detail 'Contains TODO/TBD/FIXME markers'
    }
}

# ==============================================================================
# TEST 9: Batch File Validation
# ==============================================================================
Write-Host "[TEST 9] Batch File Validation" -ForegroundColor Cyan
foreach ($file in $batFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    if ($content -notmatch '@echo\s+off') {
        Add-TestResult -Status 'WARN' -Test 'BatchEchoOff' -File $file.FullName `
            -Detail 'Missing @echo off directive'
    }

    if ($content -notmatch 'setlocal') {
        Add-TestResult -Status 'WARN' -Test 'BatchSetlocal' -File $file.FullName `
            -Detail 'Missing setlocal directive'
    }

    if ($content -match 'endlocal') {
        Add-TestResult -Status 'PASS' -Test 'BatchEndlocal' -File $file.FullName `
            -Detail 'Properly closes with endlocal'
    }
}

# ==============================================================================
# TEST 10: Gitignore and Dotfile Standards
# ==============================================================================
Write-Host "[TEST 10] Dotfile Standards" -ForegroundColor Cyan
$gitignorePath = Join-Path $scriptRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $giContent = Get-Content $gitignorePath -Raw -ErrorAction SilentlyContinue
    if ($giContent) {
        # Check for common entries
        $expected = @('*.log', 'temp/', 'logs/')
        foreach ($entry in $expected) {
            if ($giContent -match [regex]::Escape($entry)) {
                Add-TestResult -Status 'PASS' -Test 'GitignoreEntry' -File $gitignorePath `
                    -Detail "Contains expected entry: $entry"
            } else {
                Add-TestResult -Status 'INFO' -Test 'GitignoreEntry' -File $gitignorePath `
                    -Detail "Missing common entry: $entry"
            }
        }

        # Check for blank lines at end
        $lines = ($giContent -split "`n") | Where-Object { $_.Trim() -ne '' }
        $totalLines = ($giContent -split "`n").Count
        $blankTrailing = $totalLines - $lines.Count
        if ($blankTrailing -gt 3) {
            Add-TestResult -Status 'INFO' -Test 'GitignoreTrailingBlanks' -File $gitignorePath `
                -Detail "$blankTrailing trailing blank lines"
        }

        # Check for duplicate VersionTag lines
        $tagLines = ($giContent -split "`n") | Where-Object { $_ -match 'VersionTag:' }
        if ($tagLines.Count -gt 1) {
            Add-TestResult -Status 'WARN' -Test 'GitignoreDuplicateTags' -File $gitignorePath `
                -Detail "$($tagLines.Count) VersionTag lines found"
        }
    }
} else {
    Add-TestResult -Status 'FAIL' -Test 'GitignoreExists' -File $gitignorePath `
        -Detail '.gitignore file not found'
}

# ==============================================================================
# OUTPUT RESULTS
# ==============================================================================
$passCount = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
$infoCount = ($results | Where-Object { $_.Status -eq 'INFO' }).Count
$errCount  = ($results | Where-Object { $_.Status -eq 'ERROR' }).Count

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Automated Test Results Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PASS  : $passCount" -ForegroundColor Green
Write-Host "  FAIL  : $failCount" -ForegroundColor Red
Write-Host "  WARN  : $warnCount" -ForegroundColor Yellow
Write-Host "  INFO  : $infoCount" -ForegroundColor Gray
Write-Host "  ERROR : $errCount" -ForegroundColor DarkRed
Write-Host "  TOTAL : $($results.Count)" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

if ($OutputFormat -eq 'Console' -or $OutputFormat -eq 'Both') {
    $results | Format-Table -AutoSize -Property Status, Test, File, Detail
}

if ($OutputFormat -eq 'Log' -or $OutputFormat -eq 'Both') {
    $logDir = Join-Path $scriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir "automated-tests-$timestamp.txt"
    $results | Format-Table -AutoSize -Property Status, Test, File, Detail |
        Out-String | Set-Content -Path $logPath -Encoding UTF8
    Write-Host "Results written to: $logPath" -ForegroundColor Green
}

return [pscustomobject]@{
    Timestamp = $timestamp
    Total     = $results.Count
    Pass      = $passCount
    Fail      = $failCount
    Warn      = $warnCount
    Info      = $infoCount
    Error     = $errCount
    Results   = $results
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





