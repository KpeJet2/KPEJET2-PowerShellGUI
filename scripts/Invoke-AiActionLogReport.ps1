# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-06
# SupportsPS7.6TestedDate: 2026-05-06
# FileRole: Pipeline

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path $PSScriptRoot -Parent),
    [switch]$IncludeTest,
    [switch]$SeedTestMode,
    [switch]$Archive,
    [datetime]$ArchiveBeforeDate = (Get-Date).AddMinutes(1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-AiActionLog.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$adapterPath = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-EventLogAdapter.psm1'
$adapterLoaded = $false
if (Test-Path -LiteralPath $adapterPath) {
    try {
        Import-Module $adapterPath -Force -DisableNameChecking
        $adapterLoaded = $true
    } catch {
        $adapterLoaded = $false
    }
}

$paths = Get-AiActionLogPaths -WorkspacePath $WorkspacePath

function Write-ReportLog {
    param([string]$Message, [string]$Severity = 'Info')
    if ($adapterLoaded) {
        try { Write-EventLogNormalized -Scope pipeline -Component 'AiActionLogReport' -Message $Message -Severity $Severity -WorkspacePath $WorkspacePath } catch { <# Intentional: non-fatal #> }
    }
    Write-Host ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Severity, $Message)
}

function New-TestTimestamp {
    param([int]$MinutesOffset)
    return (Get-Date).AddMinutes($MinutesOffset)
}

function Add-TestScenario {
    param(
        [string]$ActionId,
        [string]$ActionName,
        [string]$AgentId,
        [int]$StartOffset,
        [int[]]$ExtraStartOffsets,
        [int[]]$FinishOffsets,
        [string[]]$FinishResults,
        [switch]$LoggingError,
        [string]$ErrorMessage = 'Synthetic logging failure'
    )

    $extraStartOffsetsArr = @()
    if ($null -ne $ExtraStartOffsets) { $extraStartOffsetsArr += $ExtraStartOffsets }
    $finishOffsetsArr = @()
    if ($null -ne $FinishOffsets) { $finishOffsetsArr += $FinishOffsets }
    $finishResultsArr = @()
    if ($null -ne $FinishResults) { $finishResultsArr += $FinishResults }

    Write-AiActionStart -WorkspacePath $WorkspacePath -IsTest -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary ('TEST start for ' + $ActionName) -Files @(@{ path = 'tests/PwShGUI-AiActionLog.Tests.ps1'; change = 'modified' }) -Timestamp (New-TestTimestamp -MinutesOffset $StartOffset) | Out-Null
    foreach ($offset in $extraStartOffsetsArr) {
        Write-AiActionStart -WorkspacePath $WorkspacePath -IsTest -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary ('TEST duplicate start for ' + $ActionName) -Files @(@{ path = 'XHTML-ChangelogViewer.xhtml'; change = 'modified' }) -Timestamp (New-TestTimestamp -MinutesOffset $offset) | Out-Null
    }
    for ($i = 0; $i -lt $finishOffsetsArr.Count; $i++) {
        $result = if ($i -lt $finishResultsArr.Count) { $finishResultsArr[$i] } else { 'success' }
        Write-AiActionFinish -WorkspacePath $WorkspacePath -IsTest -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary ('TEST finish for ' + $ActionName) -Files @(@{ path = 'modules/PwShGUI-AiActionLog.psm1'; change = 'modified' }) -Result $result -Timestamp (New-TestTimestamp -MinutesOffset $finishOffsetsArr[$i]) | Out-Null
    }
    if ($LoggingError) {
        Write-AiActionLoggingError -WorkspacePath $WorkspacePath -IsTest -ActionId $ActionId -ActionName $ActionName -AgentId $AgentId -Summary ('TEST logging error for ' + $ActionName) -ErrorMessage $ErrorMessage -Timestamp (New-TestTimestamp -MinutesOffset ($StartOffset + 1)) | Out-Null
    }
}

if ($SeedTestMode) {
    Add-TestScenario -ActionId 'test-good-1' -ActionName 'Test single start finish' -AgentId 'TestHarness' -StartOffset -120 -FinishOffsets @(-118) -FinishResults @('success')
    Add-TestScenario -ActionId 'test-open-1' -ActionName 'Test single start no stop' -AgentId 'TestHarness' -StartOffset -110
    Add-TestScenario -ActionId 'test-multi-open-1' -ActionName 'Test multiple starts no stop' -AgentId 'TestHarness' -StartOffset -100 -ExtraStartOffsets @(-99, -98)
    Add-TestScenario -ActionId 'test-multi-resolved-1' -ActionName 'Test multiple starts one logical stop' -AgentId 'TestHarness' -StartOffset -90 -ExtraStartOffsets @(-89) -FinishOffsets @(-88) -FinishResults @('success')
    Add-TestScenario -ActionId 'test-multi-stop-1' -ActionName 'Test multiple logical stops' -AgentId 'TestHarness' -StartOffset -80 -FinishOffsets @(-79, -78) -FinishResults @('success', 'success')
    Write-AiActionFinish -WorkspacePath $WorkspacePath -IsTest -ActionId 'test-invalid-stop-1' -ActionName 'Test invalid stop ordering' -AgentId 'TestHarness' -Summary 'TEST stop without start' -Files @(@{ path = 'docs/AI-ACTIONS-LOG-STANDARD.md'; change = 'modified' }) -Result success -Timestamp (New-TestTimestamp -MinutesOffset -70) | Out-Null
    Add-TestScenario -ActionId 'test-failed-1' -ActionName 'Test failed action' -AgentId 'TestHarness' -StartOffset -60 -FinishOffsets @(-59) -FinishResults @('failed')
    Add-TestScenario -ActionId 'test-log-error-1' -ActionName 'Test logging error' -AgentId 'TestHarness' -StartOffset -50 -LoggingError
    Write-ReportLog -Message 'Seeded AI action test-mode scenarios' -Severity 'Info'
}

$summary = Get-AiActionLogSummary -IncludeTest:$IncludeTest -WorkspacePath $WorkspacePath
$summaryPath = Join-Path $paths.reportDir 'ai-actions-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$archiveInfo = $null
if ($Archive) {
    $archiveInfo = Invoke-AiActionLogArchive -IncludeTest:$IncludeTest -BeforeDate $ArchiveBeforeDate -WorkspacePath $WorkspacePath
    $archivePath = Join-Path $paths.reportDir 'ai-actions-archive-summary.json'
    $archiveInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $archivePath -Encoding UTF8
}

Write-ReportLog -Message ('AI action summary written: ' + $summaryPath) -Severity 'Info'
if ($Archive -and $null -ne $archiveInfo) {
    Write-ReportLog -Message 'AI action archives created' -Severity 'Info'
}

$summary