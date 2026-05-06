# VersionTag: 2605.B2.V31.7
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-06
# SupportsPS7.6TestedDate: 2026-05-06
# FileRole: Module

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AiActionLogPaths {
    [CmdletBinding()]
    param([string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent))

    $root = if ($WorkspacePath -and (Test-Path -LiteralPath $WorkspacePath)) {
        (Resolve-Path -LiteralPath $WorkspacePath).Path
    } else {
        (Get-Location).Path
    }

    if ($root -like '*\modules') {
        $root = Split-Path -Path $root -Parent
    }

    $logRoot = Join-Path (Join-Path $root 'logs') 'ai-actions'
    $liveDir = Join-Path $logRoot 'live'
    $testDir = Join-Path $logRoot 'test'
    $reportDir = Join-Path (Join-Path $root '~REPORTS') 'ai-actions'
    $archiveRoot = Join-Path (Join-Path $root 'logs') 'archive'
    $archiveRoot = Join-Path $archiveRoot 'ai-actions'
    $archiveLiveDir = Join-Path $archiveRoot 'live'
    $archiveTestDir = Join-Path $archiveRoot 'test'

    foreach ($path in @($logRoot, $liveDir, $testDir, $reportDir, $archiveRoot, $archiveLiveDir, $archiveTestDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    return [ordered]@{
        workspaceRoot   = $root
        logRoot         = $logRoot
        liveDir         = $liveDir
        testDir         = $testDir
        reportDir       = $reportDir
        archiveRoot     = $archiveRoot
        archiveLiveDir  = $archiveLiveDir
        archiveTestDir  = $archiveTestDir
    }
}

function New-AiActionId {
    [CmdletBinding()]
    param([string]$Prefix = 'ai')

    return ('{0}-{1}-{2}' -f $Prefix.ToLowerInvariant(), (Get-Date -Format 'yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8)))
}

function ConvertTo-AiActionRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $root = (Resolve-Path -LiteralPath $WorkspacePath).Path
    $candidate = $Path -replace '/', '\\'

    if ([System.IO.Path]::IsPathRooted($candidate)) {
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate).Path } catch { $resolved = $candidate }
        if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $resolved.Substring($root.Length).TrimStart('\\')
        }
        throw "Path is outside workspace: $Path"
    }

    $normalized = $candidate.TrimStart('.').TrimStart('\\')
    if ($normalized -match '^[A-Za-z]:') { throw "Path is outside workspace: $Path" }
    return $normalized
}

function ConvertTo-AiActionFiles {
    [CmdletBinding()]
    param(
        [AllowNull()] [object[]]$Files,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    $items = @()
    foreach ($entry in @($Files)) {
        if ($null -eq $entry) { continue }

        $pathValue = $null
        $changeValue = 'unknown'

        if ($entry -is [string]) {
            $pathValue = $entry
        } elseif ($entry -is [System.Collections.IDictionary]) {
            if ($entry.Contains('path')) { $pathValue = [string]$entry['path'] }
            if ($entry.Contains('change')) { $changeValue = [string]$entry['change'] }
        } elseif ($entry.PSObject.Properties.Name -contains 'path') {
            $pathValue = [string]$entry.path
            if ($entry.PSObject.Properties.Name -contains 'change') { $changeValue = [string]$entry.change }
        }

        if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
        $items += [ordered]@{
            path   = (ConvertTo-AiActionRelativePath -Path $pathValue -WorkspacePath $WorkspacePath)
            change = if ([string]::IsNullOrWhiteSpace($changeValue)) { 'unknown' } else { $changeValue.ToLowerInvariant() }
        }
    }

    return @($items)
}

function Write-AiActionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('start','finish','logging-error')] [string]$RecordType,
        [Parameter(Mandatory)] [string]$ActionId,
        [Parameter(Mandatory)] [string]$ActionName,
        [Parameter(Mandatory)] [string]$AgentId,
        [Parameter(Mandatory)] [string]$Summary,
        [AllowNull()] [object[]]$Files,
        [ValidateSet('success','failed','cancelled','unknown')] [string]$Result = 'unknown',
        [string]$ErrorMessage,
        [string]$CorrelationId = '',
        [string]$SessionId = '',
        [switch]$IsTest,
        [datetime]$Timestamp = (Get-Date),
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    $paths = Get-AiActionLogPaths -WorkspacePath $WorkspacePath
    $destDir = if ($IsTest) { $paths.testDir } else { $paths.liveDir }
    $leafPrefix = if ($IsTest) { 'ai-actions-test-' } else { 'ai-actions-' }
    $destFile = Join-Path $destDir ($leafPrefix + $Timestamp.ToString('yyyyMMdd') + '.jsonl')

    $row = [ordered]@{
        schema      = 'PwShGUI-AiActionLog/1.0'
        ts          = $Timestamp.ToUniversalTime().ToString('o')
        recordType  = $RecordType
        actionId    = $ActionId
        actionName  = $ActionName
        agentId     = $AgentId
        summary     = $Summary
        corrId      = $CorrelationId
        sessionId   = $SessionId
        result      = if ($RecordType -eq 'finish') { $Result } else { $null }
        errorMessage = if ($RecordType -eq 'logging-error') { $ErrorMessage } else { $null }
        files       = @(ConvertTo-AiActionFiles -Files $Files -WorkspacePath $paths.workspaceRoot)
        isTest      = [bool]$IsTest
        host        = $env:COMPUTERNAME
        pid         = $PID
    }

    $json = $row | ConvertTo-Json -Depth 6 -Compress
    Add-Content -LiteralPath $destFile -Value $json -Encoding UTF8
    return $row
}

function Write-AiActionStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ActionId,
        [Parameter(Mandatory)] [string]$ActionName,
        [Parameter(Mandatory)] [string]$AgentId,
        [Parameter(Mandatory)] [string]$Summary,
        [AllowNull()] [object[]]$Files,
        [string]$CorrelationId = '',
        [string]$SessionId = '',
        [switch]$IsTest,
        [datetime]$Timestamp = (Get-Date),
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    return Write-AiActionRecord -RecordType start -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary $Summary -Files $Files -CorrelationId $CorrelationId -SessionId $SessionId -IsTest:$IsTest -Timestamp $Timestamp -WorkspacePath $WorkspacePath
}

function Write-AiActionFinish {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ActionId,
        [Parameter(Mandatory)] [string]$ActionName,
        [Parameter(Mandatory)] [string]$AgentId,
        [Parameter(Mandatory)] [string]$Summary,
        [AllowNull()] [object[]]$Files,
        [ValidateSet('success','failed','cancelled','unknown')] [string]$Result = 'success',
        [string]$CorrelationId = '',
        [string]$SessionId = '',
        [switch]$IsTest,
        [datetime]$Timestamp = (Get-Date),
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    return Write-AiActionRecord -RecordType finish -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary $Summary -Files $Files -Result $Result -CorrelationId $CorrelationId -SessionId $SessionId -IsTest:$IsTest -Timestamp $Timestamp -WorkspacePath $WorkspacePath
}

function Write-AiActionLoggingError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ActionId,
        [Parameter(Mandatory)] [string]$ActionName,
        [Parameter(Mandatory)] [string]$AgentId,
        [Parameter(Mandatory)] [string]$Summary,
        [Parameter(Mandatory)] [string]$ErrorMessage,
        [AllowNull()] [object[]]$Files,
        [string]$CorrelationId = '',
        [string]$SessionId = '',
        [switch]$IsTest,
        [datetime]$Timestamp = (Get-Date),
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    return Write-AiActionRecord -RecordType 'logging-error' -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary $Summary -Files $Files -ErrorMessage $ErrorMessage -CorrelationId $CorrelationId -SessionId $SessionId -IsTest:$IsTest -Timestamp $Timestamp -WorkspacePath $WorkspacePath
}

function Get-AiActionLogEntries {
    [CmdletBinding()]
    param(
        [switch]$IncludeTest,
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    $paths = Get-AiActionLogPaths -WorkspacePath $WorkspacePath
    $dirs = @($paths.liveDir)
    if ($IncludeTest) { $dirs += $paths.testDir }

    $entries = @()
    $parseErrors = 0
    foreach ($dir in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        foreach ($file in $files) {
            $lineNumber = 0
            $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
            foreach ($line in $lines) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $entry = $line | ConvertFrom-Json -ErrorAction Stop
                    $entry | Add-Member -NotePropertyName sourceFile -NotePropertyValue $file.FullName -Force
                    $entry | Add-Member -NotePropertyName sourceLine -NotePropertyValue $lineNumber -Force
                    $entries += $entry
                } catch {
                    $parseErrors++
                }
            }
        }
    }

    return [ordered]@{
        parseErrors = $parseErrors
        entries     = @($entries | Sort-Object -Property @{ Expression = { $_.ts } }, @{ Expression = { $_.sourceFile } }, @{ Expression = { $_.sourceLine } })
    }
}

function Get-AiActionLogSummary {
    [CmdletBinding()]
    param(
        [switch]$IncludeTest,
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    $payload = Get-AiActionLogEntries -IncludeTest:$IncludeTest -WorkspacePath $WorkspacePath
    $entries = @($payload.entries)
    $actionMap = @{}
    $uniqueAgents = @{}
    $uniqueFiles = @{}
    $fileChanges = [ordered]@{ created = 0; modified = 0; deleted = 0; unknown = 0 }
    $startRecords = 0
    $finishRecords = 0
    $successFinishRecords = 0
    $failedFinishRecords = 0
    $loggingErrors = 0
    $testRecords = 0
    $liveRecords = 0

    foreach ($entry in $entries) {
        if ($entry.agentId) { $uniqueAgents[[string]$entry.agentId] = $true }
        if ($entry.isTest) { $testRecords++ } else { $liveRecords++ }
        foreach ($file in @($entry.files)) {
            if ($null -eq $file) { continue }
            $pathValue = [string]$file.path
            $changeValue = [string]$file.change
            if (-not [string]::IsNullOrWhiteSpace($pathValue)) { $uniqueFiles[$pathValue] = $true }
            if ($fileChanges.Contains($changeValue)) { $fileChanges[$changeValue]++ } else { $fileChanges.unknown++ }
        }

        if ($entry.recordType -eq 'start') { $startRecords++ }
        elseif ($entry.recordType -eq 'finish') {
            $finishRecords++
            if ([string]$entry.result -eq 'success') { $successFinishRecords++ }
            elseif ([string]$entry.result -eq 'failed') { $failedFinishRecords++ }
        } elseif ($entry.recordType -eq 'logging-error') {
            $loggingErrors++
        }

        $actionId = [string]$entry.actionId
        if ([string]::IsNullOrWhiteSpace($actionId)) { continue }
        if (-not $actionMap.ContainsKey($actionId)) {
            $actionMap[$actionId] = [ordered]@{
                actionId            = $actionId
                actionName          = [string]$entry.actionName
                agentId             = [string]$entry.agentId
                isTest              = [bool]$entry.isTest
                startCount          = 0
                finishCount         = 0
                validFinishCount    = 0
                invalidFinishCount  = 0
                errorCount          = 0
                firstStartAt        = $null
                lastFinishAt        = $null
                lastResult          = 'open'
                files               = @()
                summaries           = @()
                durationSec         = $null
            }
        }

        $action = $actionMap[$actionId]
        if ($entry.summary) { $action.summaries += [string]$entry.summary }
        if (@($entry.files).Count -gt 0) { $action.files = @($entry.files) }

        if ($entry.recordType -eq 'start') {
            $action.startCount++
            if ($null -eq $action.firstStartAt -or ([datetime]$entry.ts) -lt ([datetime]$action.firstStartAt)) {
                $action.firstStartAt = [string]$entry.ts
            }
        } elseif ($entry.recordType -eq 'finish') {
            $action.finishCount++
            $finishTime = [datetime]$entry.ts
            if ($null -ne $action.firstStartAt) {
                if ($finishTime -ge ([datetime]$action.firstStartAt)) {
                    $action.validFinishCount++
                    $action.lastFinishAt = [string]$entry.ts
                    $action.lastResult = [string]$entry.result
                    $action.durationSec = [int][Math]::Round(($finishTime - ([datetime]$action.firstStartAt)).TotalSeconds)
                } else {
                    $action.invalidFinishCount++
                }
            } else {
                $action.invalidFinishCount++
            }
        } elseif ($entry.recordType -eq 'logging-error') {
            $action.errorCount++
        }
    }

    $actions = @($actionMap.Values | ForEach-Object {
        $status = 'open'
        if ($_.validFinishCount -gt 0) {
            if ($_.lastResult -eq 'failed') { $status = 'failed' }
            elseif ($_.validFinishCount -gt 1) { $status = 'multiple-stops' }
            elseif ($_.startCount -gt 1) { $status = 'duplicate-start-resolved' }
            else { $status = 'success' }
        } elseif ($_.invalidFinishCount -gt 0) {
            $status = 'invalid-stop-order'
        }

        [ordered]@{
            actionId           = $_.actionId
            actionName         = $_.actionName
            agentId            = $_.agentId
            isTest             = $_.isTest
            status             = $status
            startCount         = $_.startCount
            finishCount        = $_.finishCount
            validFinishCount   = $_.validFinishCount
            invalidFinishCount = $_.invalidFinishCount
            errorCount         = $_.errorCount
            firstStartAt       = $_.firstStartAt
            lastFinishAt       = $_.lastFinishAt
            lastResult         = $_.lastResult
            durationSec        = $_.durationSec
            files              = @($_.files)
            summary            = if (@($_.summaries).Count -gt 0) { [string]$_.summaries[-1] } else { '' }
        }
    } | Sort-Object -Property @{ Expression = { $_.lastFinishAt } ; Descending = $true }, @{ Expression = { $_.firstStartAt } ; Descending = $true })

    $multipleStartsSingleLogicalStop = @($actions | Where-Object { $_.startCount -gt 1 -and $_.validFinishCount -eq 1 -and $_.invalidFinishCount -eq 0 } | ForEach-Object {
        [ordered]@{ actionId = $_.actionId; actionName = $_.actionName; agentId = $_.agentId; isTest = $_.isTest }
    })

    $successfulActions = @($actions | Where-Object { $_.startCount -ge 1 -and $_.validFinishCount -ge 1 -and $_.lastResult -eq 'success' })
    $openActions = @($actions | Where-Object { $_.startCount -ge 1 -and $_.validFinishCount -eq 0 })
    $failedActions = @($actions | Where-Object { $_.lastResult -eq 'failed' })
    $invalidStopRecordCount = 0
    $durations = @()
    foreach ($action in $actions) {
        $invalidStopRecordCount += [int]$action.invalidFinishCount
        if ($null -ne $action.durationSec) { $durations += [double]$action.durationSec }
    }

    return [ordered]@{
        schema      = 'PwShGUI-AiActionSummary/1.0'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        includeTest = [bool]$IncludeTest
        metrics     = [ordered]@{
            uniqueAgents                          = @($uniqueAgents.Keys).Count
            totalActionsLogged                    = @($actions).Count
            totalRecords                          = @($entries).Count
            totalStartedRecords                   = $startRecords
            totalFinishedRecords                  = $finishRecords
            totalSuccessfulStartedStoppedActions  = @($successfulActions).Count
            totalSuccessfulFinishedRecords        = $successFinishRecords
            totalFailedFinishedRecords            = $failedFinishRecords
            startedWithNoStopRecorded             = @($openActions).Count
            multipleStartsWithNoStopRecorded      = @($actions | Where-Object { $_.startCount -gt 1 -and $_.validFinishCount -eq 0 }).Count
            multipleStartsSingleLogicalStop       = @($multipleStartsSingleLogicalStop).Count
            actionsWithMultipleLogicalStops       = @($actions | Where-Object { $_.validFinishCount -gt 1 }).Count
            actionsWithInvalidStopOrdering        = @($actions | Where-Object { $_.invalidFinishCount -gt 0 }).Count
            invalidStopRecordCount                = $invalidStopRecordCount
            totalActionsFailed                    = @($failedActions).Count
            totalActionLoggingFailuresOrErrors    = ($loggingErrors + [int]$payload.parseErrors)
            parseErrors                           = [int]$payload.parseErrors
            liveRecordCount                       = $liveRecords
            testRecordCount                       = $testRecords
            uniqueFilesTouched                    = @($uniqueFiles.Keys).Count
            totalCreatedFileMentions              = $fileChanges.created
            totalModifiedFileMentions             = $fileChanges.modified
            totalDeletedFileMentions              = $fileChanges.deleted
            totalUnknownFileMentions              = $fileChanges.unknown
            averageDurationSec                    = if ($durations.Count -gt 0) { [Math]::Round((($durations | Measure-Object -Average).Average), 2) } else { 0 }
        }
        fileChanges = $fileChanges
        multipleStartsSingleLogicalStopList = $multipleStartsSingleLogicalStop
        failedActions = @($failedActions | ForEach-Object { [ordered]@{ actionId = $_.actionId; actionName = $_.actionName; agentId = $_.agentId; isTest = $_.isTest } })
        actions      = @($actions)
        records      = @($entries)
    }
}

function Resolve-AiAction7ZipPath {
    [CmdletBinding()]
    param([string]$PreferredPath)

    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) { return $PreferredPath }
    foreach ($candidate in @("$env:ProgramFiles\7-Zip\7z.exe", "$env:ProgramFiles(x86)\7-Zip\7z.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function New-AiActionEncryptedZip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = '7-Zip CLI requires the password as plain text argument.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SevenZipPath,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string[]]$ItemPaths,
        [Parameter(Mandatory)] [string]$DestinationPath,
        [Parameter(Mandatory)] [string]$Password
    )

    $listFile = Join-Path $env:TEMP ('pwshgui_ai_actions_{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    try {
        $relativeItems = @()
        foreach ($item in @($ItemPaths)) {
            if ([string]::IsNullOrWhiteSpace($item)) { continue }
            $resolved = (Resolve-Path -LiteralPath $item).Path
            $relativeItems += $resolved.Substring($WorkspacePath.Length).TrimStart('\\')
        }
        Set-Content -LiteralPath $listFile -Value $relativeItems -Encoding ASCII
        $args = @('a', '-tzip', '-mem=AES256', "-p$Password", $DestinationPath, ("@{0}" -f $listFile))
        Push-Location $WorkspacePath
        & $SevenZipPath @args | Out-Null
        Pop-Location
    } finally {
        if (Test-Path -LiteralPath $listFile) { Remove-Item -LiteralPath $listFile -Force }
    }
}

function Invoke-AiActionLogArchive {
    [CmdletBinding()]
    param(
        [switch]$IncludeTest,
        [datetime]$BeforeDate = (Get-Date).AddMinutes(1),
        [string]$SevenZipPath,
        [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent)
    )

    $paths = Get-AiActionLogPaths -WorkspacePath $WorkspacePath
    $password = (Get-Date -Format 'ddMMyyyy') + '!'
    $resolvedSevenZip = Resolve-AiAction7ZipPath -PreferredPath $SevenZipPath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $results = @()

    foreach ($bucket in @(
        [ordered]@{ name = 'live'; source = $paths.liveDir; destination = $paths.archiveLiveDir },
        [ordered]@{ name = 'test'; source = $paths.testDir; destination = $paths.archiveTestDir }
    )) {
        if ($bucket.name -eq 'test' -and -not $IncludeTest) { continue }
        $items = @(Get-ChildItem -LiteralPath $bucket.source -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $BeforeDate })
        if (-not @($items).Count) { continue }

        $zipPath = Join-Path $bucket.destination ('ai-actions-{0}-{1}.zip' -f $bucket.name, $timestamp)
        $encZipPath = Join-Path $bucket.destination ('ai-actions-{0}-{1}.enc.zip' -f $bucket.name, $timestamp)
        Compress-Archive -Path @($items | ForEach-Object { $_.FullName }) -DestinationPath $zipPath -CompressionLevel Optimal -Force
        if ($resolvedSevenZip) {
            New-AiActionEncryptedZip -SevenZipPath $resolvedSevenZip -WorkspacePath $paths.workspaceRoot -ItemPaths @($items | ForEach-Object { $_.FullName }) -DestinationPath $encZipPath -Password $password
        }

        $results += [ordered]@{
            bucket          = $bucket.name
            itemCount       = @($items).Count
            zipPath         = $zipPath
            encryptedZipPath = if ($resolvedSevenZip) { $encZipPath } else { '' }
            passwordHint    = if ($resolvedSevenZip) { 'ddMMyyyy!' } else { '' }
        }
    }

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        archiveRuns = @($results)
        used7Zip    = [bool]$resolvedSevenZip
    }
}

Export-ModuleMember -Function @(
    'Get-AiActionLogPaths',
    'New-AiActionId',
    'Write-AiActionStart',
    'Write-AiActionFinish',
    'Write-AiActionLoggingError',
    'Get-AiActionLogEntries',
    'Get-AiActionLogSummary',
    'Invoke-AiActionLogArchive'
)