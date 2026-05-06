# VersionTag: 2604.B2.V32.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Runs targeted post-smoke validation for a file type and writes inventory status.

.DESCRIPTION
    Forked from the FireUpAllEngines smoke-chain idea, but scoped to a specific
    file class. The Script routine validates PowerShell-family files and the
    Html routine validates HTML/XHTML documents. Each run processes files
    sequentially, records last-write dates, emits failure details, and updates a
    shared agent inventory report for checklist surfacing.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Script','Html')]
    [string]$FileType,

    [string]$WorkspacePath,

    [int]$Limit = 10,

    [string]$InventoryPath,

    [switch]$UseExitCode,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}

if (-not (Test-Path -LiteralPath $WorkspacePath)) {
    throw "WorkspacePath not found: $WorkspacePath"
}

$reportsDir = Join-Path $WorkspacePath '~REPORTS'
$logsDir = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path -LiteralPath $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
    $InventoryPath = Join-Path $reportsDir 'smoke-filetype-agent-inventory.json'
}

$timestamp = Get-Date
$routineName = if ($FileType -eq 'Script') {
    'SmokeTest-Scripts-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose'
} else {
    'SmokeTest-HTML-FireUpAllEnginesForPreProdIdlePerfCallCatchLogsClose'
}
$reportKey = if ($FileType -eq 'Script') { 'scriptRun' } else { 'htmlRun' }
$logFileName = if ($FileType -eq 'Script') {
    'SmokeTest-Scripts-FireUpAllEngines.log'
} else {
    'SmokeTest-HTML-FireUpAllEngines.log'
}
$logPath = Join-Path $logsDir $logFileName

function Write-RoutineLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Out-File -FilePath $logPath -Append -Encoding UTF8
    if (-not $Quiet) {
        Write-Host $line
    }
}

function Get-WorkspaceRelativePath {
    param([string]$FullPath)
    $root = ($WorkspacePath.TrimEnd('\') + '\')
    $value = $FullPath
    if ($value.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring($root.Length)
    }
    return ($value -replace '\\','/')
}

function Test-ExcludedPath {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$FullPath)
    $parts = $FullPath -replace '\\','/' -split '/'
    $excludedNames = @('.git','node_modules','.venv','.venv-pygame312','logs','~REPORTS','temp','todo','checkpoints','.history')
    foreach ($name in $excludedNames) {
        if ($parts -contains $name) {
            return $true
        }
    }
    return $false
}

function Get-ReferencedTargetPath {
    param(
        [string]$BaseDirectory,
        [string]$ReferenceValue
    )
    if ([string]::IsNullOrWhiteSpace($ReferenceValue)) {
        return $null
    }

    $trimmed = $ReferenceValue.Trim()
    if ($trimmed -match '^(https?|mailto|javascript):') { return $null }
    if ($trimmed.StartsWith('#')) { return $null }

    $clean = $trimmed.Split('?')[0].Split('#')[0]
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($clean)) {
        return $clean
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $clean))
}

function Test-ScriptFile {
    param([System.IO.FileInfo]$File)

    $raw = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $lines = @(Get-Content -LiteralPath $File.FullName -Encoding UTF8)
    $failures = New-Object System.Collections.Generic.List[string]
    $errorHref = $null

    $hasVersionTag = $false
    $scanCount = [Math]::Min(@($lines).Count, 3)
    for ($index = 0; $index -lt $scanCount; $index++) {
        if ($lines[$index] -match 'VersionTag:') {
            $hasVersionTag = $true
            break
        }
    }
    if (-not $hasVersionTag) {
        $failures.Add('Missing VersionTag header in first 3 lines.')
    }

    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) {
        $messages = @()
        foreach ($parseError in @($parseErrors)) {
            $messages += $parseError.Message
        }
        $failures.Add("AST parse errors: " + ($messages -join ' || '))
    }

    $p005Matches = @([regex]::Matches($raw, '(?<!\?)\?\?(?!\?)|\?\.'))
    if (@($p005Matches).Count -gt 0) {
        $failures.Add('Contains PS7-only operator token(s) (SIN P005).')
    }

    if (@($failures).Count -gt 0) {
        $errorHref = Get-WorkspaceRelativePath -FullPath $File.FullName
    }

    return [ordered]@{
        filePath          = Get-WorkspaceRelativePath -FullPath $File.FullName
        fileType          = 'SCRIPT'
        status            = if (@($failures).Count -gt 0) { 'FAIL' } else { 'PASS' }
        lastFieldRecordAt = $File.LastWriteTime.ToString('o')
        errorHref         = $errorHref
        failureDetails    = if (@($failures).Count -gt 0) { $failures -join ' | ' } else { '' }
        checks            = [ordered]@{
            hasVersionTag  = $hasVersionTag
            parseErrorCount = @($parseErrors).Count
            p005MatchCount = @($p005Matches).Count
        }
    }
}

function Test-HtmlFile {
    param([System.IO.FileInfo]$File)

    $raw = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $failures = New-Object System.Collections.Generic.List[string]
    $missingRefs = New-Object System.Collections.Generic.List[string]
    $baseDirectory = Split-Path $File.FullName -Parent

    if ($File.Extension -ieq '.xhtml' -and $raw -notmatch '^<\?xml\s+version=') {
        $failures.Add('Missing XML declaration as first content for XHTML.')
    }

    if ($File.Extension -ieq '.xhtml') {
        try {
            $xmlDoc = New-Object System.Xml.XmlDocument
            $xmlDoc.PreserveWhitespace = $true
            $xmlDoc.LoadXml($raw)
        } catch {
            $failures.Add("XHTML parse error: $($_.Exception.Message)")
        }
    }

    $refMatches = [regex]::Matches($raw, '(href|src)\s*=\s*["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $refMatches) {
        $refValue = $match.Groups[2].Value
        try {
            $resolvedPath = Get-ReferencedTargetPath -BaseDirectory $baseDirectory -ReferenceValue $refValue
        } catch {
            $failures.Add("Invalid reference path '$refValue': $($_.Exception.Message)")
            continue
        }
        if ($null -ne $resolvedPath -and -not (Test-Path -LiteralPath $resolvedPath)) {
            $missingRefs.Add(($resolvedPath -replace '\\','/'))
        }
    }

    if (@($missingRefs).Count -gt 0) {
        $failures.Add('Missing referenced data: ' + (@($missingRefs) -join ', '))
    }

    $errorHref = $null
    if (@($missingRefs).Count -gt 0) {
        $errorHref = Get-WorkspaceRelativePath -FullPath $missingRefs[0]
    } elseif (@($failures).Count -gt 0) {
        $errorHref = Get-WorkspaceRelativePath -FullPath $File.FullName
    }

    return [ordered]@{
        filePath          = Get-WorkspaceRelativePath -FullPath $File.FullName
        fileType          = 'HTML'
        status            = if (@($failures).Count -gt 0) { 'FAIL' } else { 'PASS' }
        lastFieldRecordAt = $File.LastWriteTime.ToString('o')
        errorHref         = $errorHref
        failureDetails    = if (@($failures).Count -gt 0) { $failures -join ' | ' } else { '' }
        checks            = [ordered]@{
            missingReferenceCount = @($missingRefs).Count
            referenceCount        = @($refMatches).Count
        }
    }
}

function Get-SelectedFiles {
    $extensions = if ($FileType -eq 'Script') {
        @('.ps1','.psm1','.psd1')
    } else {
        @('.html','.xhtml')
    }

    $files = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $extension = $_.Extension.ToLowerInvariant()
        ($extensions -contains $extension) -and (-not (Test-ExcludedPath -FullPath $_.FullName))
    } | Sort-Object FullName | Select-Object -First $Limit)

    return $files
}

Write-RoutineLog "Starting $routineName"
$selectedFiles = @(Get-SelectedFiles)
$records = New-Object System.Collections.Generic.List[object]

foreach ($file in $selectedFiles) {
    Write-RoutineLog ("Checking {0}" -f (Get-WorkspaceRelativePath -FullPath $file.FullName))
    $record = if ($FileType -eq 'Script') { Test-ScriptFile -File $file } else { Test-HtmlFile -File $file }
    $records.Add([pscustomobject]$record)
    Write-RoutineLog ("  -> {0}" -f $record.status)
}

$passed = @($records | Where-Object { $_.status -eq 'PASS' }).Count
$failed = @($records | Where-Object { $_.status -eq 'FAIL' }).Count
$missingReferenceTotal = if ($FileType -eq 'Html') {
    @($records | ForEach-Object { [int]$_.checks.missingReferenceCount } | Measure-Object -Sum).Sum
} else {
    0
}
$sortedRecords = @($records | Sort-Object -Property lastFieldRecordAt -Descending)
$lastFieldRecordAt = if ($sortedRecords.Count -gt 0) {
    $sortedRecords[0].lastFieldRecordAt
} else {
    $timestamp.ToString('o')
}

$totalRecords = $records.Count
$improvementSummary = ''
if ($FileType -eq 'Script') {
    $versionTagVisible = @($records | Where-Object { $_.checks.hasVersionTag }).Count
    $improvementSummary = [string]::Format('{0}/{1} parse-clean script files, {2}/{1} with VersionTag visibility, .bat files excluded by design.', $passed, $totalRecords, $versionTagVisible)
} else {
    $improvementSummary = [string]::Format('{0}/{1} HTML/XHTML files passed reference validation, {2} broken reference path(s) surfaced with direct ERROR links.', $passed, $totalRecords, $missingReferenceTotal)
}

$runFileType = $FileType.ToUpperInvariant()
$runStatus = if ($failed -gt 0) { 'FAILED' } else { 'PASSED' }
$runLastAt = $timestamp.ToString('o')
$runLogPath = Get-WorkspaceRelativePath -FullPath $logPath
$runInventoryPath = Get-WorkspaceRelativePath -FullPath $InventoryPath
$recordArray = $records.ToArray()

$runSummary = [pscustomobject][ordered]@{
    routineName       = $routineName
    fileType          = $runFileType
    status            = $runStatus
    lastRunAt         = $runLastAt
    lastFieldRecordAt = $lastFieldRecordAt
    filesProcessed    = $totalRecords
    passed            = $passed
    failed            = $failed
    improvementsYielded = $improvementSummary
    logPath           = $runLogPath
    inventoryPath     = $runInventoryPath
    records           = $recordArray
}

$existingReport = $null
if (Test-Path -LiteralPath $InventoryPath) {
    try {
        $existingReport = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $existingReport = $null
    }
}

$scriptRun = if ($existingReport -and $existingReport.PSObject.Properties.Name -contains 'scriptRun') { $existingReport.scriptRun } else { $null }
$htmlRun = if ($existingReport -and $existingReport.PSObject.Properties.Name -contains 'htmlRun') { $existingReport.htmlRun } else { $null }
if ($reportKey -eq 'scriptRun') { $scriptRun = $runSummary } else { $htmlRun = $runSummary }

$agentInventory = @()
if ($null -ne $scriptRun) {
    $agentInventory += [pscustomobject]@{
        name                = $scriptRun.routineName
        fileType            = $scriptRun.fileType
        status              = $scriptRun.status
        lastRunAt           = $scriptRun.lastRunAt
        lastFieldRecordAt   = $scriptRun.lastFieldRecordAt
        filesProcessed      = $scriptRun.filesProcessed
        passed              = $scriptRun.passed
        failed              = $scriptRun.failed
        improvementsYielded = $scriptRun.improvementsYielded
        logPath             = $scriptRun.logPath
        inventoryPath       = $scriptRun.inventoryPath
    }
}
if ($null -ne $htmlRun) {
    $agentInventory += [pscustomobject]@{
        name                = $htmlRun.routineName
        fileType            = $htmlRun.fileType
        status              = $htmlRun.status
        lastRunAt           = $htmlRun.lastRunAt
        lastFieldRecordAt   = $htmlRun.lastFieldRecordAt
        filesProcessed      = $htmlRun.filesProcessed
        passed              = $htmlRun.passed
        failed              = $htmlRun.failed
        improvementsYielded = $htmlRun.improvementsYielded
        logPath             = $htmlRun.logPath
        inventoryPath       = $htmlRun.inventoryPath
    }
}

$report = [ordered]@{
    meta = [ordered]@{
        schema      = 'PwShGUI-SmokeFileTypeAgentInventory/1.0'
        lastUpdated = $timestamp.ToString('o')
        generatedBy = 'tests/Invoke-FileTypeFireUpAllEnginesRoutine.ps1'
        workspace   = $WorkspacePath
    }
    agentInventory = $agentInventory
    scriptRun      = $scriptRun
    htmlRun        = $htmlRun
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventoryPath -Encoding UTF8
Write-RoutineLog ("Completed {0}: processed={1}, passed={2}, failed={3}" -f $routineName, $records.Count, $passed, $failed)

$resultObject = [pscustomobject]$runSummary
if ($UseExitCode) {
    if ($failed -gt 0) {
        exit 1
    }
    exit 0
}

return $resultObject

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




