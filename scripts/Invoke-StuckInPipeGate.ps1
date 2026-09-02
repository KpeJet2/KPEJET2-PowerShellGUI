# VersionTag: 2607.B6.V54.0
# SupportPS5.1: YES(As of: 2026-07-28)
# SupportsPS7.6: YES(As of: 2026-07-28)
# SupportPS5.1TestedDate: 2026-07-28
# SupportsPS7.6TestedDate: 2026-07-28
# FileRole: Script
#Requires -Version 5.1
<#
.SYNOPSIS
    Self-healing Stuck-in-the-Pipe gate for stale, corrupted, and abandoned pipeline artifacts.
.DESCRIPTION
    Detects and repairs queue/pipeline drift before the Integrity Gate:
      - stale interruptions (OPEN/PLANNED/IN_PROGRESS/BLOCKED beyond threshold)
      - corrupt JSON artifacts in todo/ and queue folders
      - optional feature-request smoke path (date stamp in README test file)
      - optional missing-component detection with remediation attempt and Bugs2FIX linkage
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [ValidateRange(1,10)] [int]$MaxPasses = 3,
    [int]$OpenDays = 14,
    [int]$PlannedDays = 7,
    [int]$InProgressDays = 3,
    [int]$BlockedDays = 7,
    [switch]$RunFeatureRequestSelfTest,
    [string]$FeatureReadmePath = 'README.TEST.md',
    [switch]$TestMissingComponents,
    [string[]]$RequiredComponents = @(
        'modules\CronAiAthon-Pipeline.psm1',
        'scripts\Invoke-PipelineProcess20.ps1'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'Write-AppLog' -ErrorAction SilentlyContinue)) {
    function Write-AppLog {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string]$Message,
            [string]$Level = 'Info'
        )

        Write-Verbose -Message ("[$Level] $Message") -Verbose:$false
    }
}

function Write-StuckGateLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warning','Error','Debug')] [string]$Level = 'Info'
    )

    if (Get-Command -Name 'Write-CronLog' -ErrorAction SilentlyContinue) {
        $severity = switch ($Level) {
            'Error' { 'Error' }
            'Warning' { 'Warning' }
            'Debug' { 'Debug' }
            default { 'Informational' }
        }
        Write-CronLog -Message $Message -Severity $severity | Out-Null
        return
    }

    if (Get-Command -Name 'Write-AppLog' -ErrorAction SilentlyContinue) {
        Write-AppLog -Message $Message -Level $Level
        return
    }

    Write-Verbose -Message ("[$Level] $Message") -Verbose:$false
}

function Get-GateModulePath {
    [OutputType([System.String])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Leaf
    )

    return (Join-Path (Join-Path $Root 'modules') $Leaf)
}

function Resolve-QueueCorruption {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root)

    $result = [ordered]@{
        scanned = 0
        corrupt = 0
        moved = 0
        movedFiles = @()
    }

    $scanRoots = @(
        (Join-Path $Root 'todo'),
        (Join-Path (Join-Path $Root 'todo') 'QUEUES-ToDo')
    )

    foreach ($scanRoot in $scanRoots) {
        if (-not (Test-Path $scanRoot)) { continue }

        $jsonFiles = @(Get-ChildItem -Path $scanRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('_index.json', '_master-aggregated.json') })

        foreach ($jf in $jsonFiles) {
            $result.scanned++
            $isCorrupt = $false
            try {
                $null = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $isCorrupt = $true
            }

            if ($isCorrupt) {
                $result.corrupt++
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $target = "{0}.corrupt-{1}" -f $jf.FullName, $stamp
                Move-Item -LiteralPath $jf.FullName -Destination $target -Force
                $result.moved++
                $result.movedFiles += $target
                $null = Write-StuckGateLog -Message "Quarantined corrupt artifact: $($jf.FullName)" -Level Warning
            }
        }
    }

    return [pscustomobject]$result
}

function Repair-StaleInterruptions {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [object]$InterruptionReport
    )

    $result = [ordered]@{
        considered = 0
        requeued = 0
        errors = @()
    }

    foreach ($item in @($InterruptionReport.items)) {
        if ($null -eq $item) { continue }
        $itemId = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($itemId)) { continue }

        $result.considered++
        try {
            $note1 = "Auto-heal gate: marked BLOCKED from stale state ageDays=$($item.ageDays) threshold=$($item.threshold)"
            $note2 = "Auto-heal gate: re-queued after stale reset pass"

            $null = Update-PipelineItemStatus -WorkspacePath $Root -ItemId $itemId -NewStatus 'BLOCKED' -Notes $note1 -Force
            $null = Update-PipelineItemStatus -WorkspacePath $Root -ItemId $itemId -NewStatus 'OPEN' -Notes $note2 -Force
            $result.requeued++
        } catch {
            $result.errors += ("{0}: {1}" -f $itemId, $_.Exception.Message)
        }
    }

    return [pscustomobject]$result
}

function Invoke-FeatureRequestSmoke {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$RelativeReadme
    )

    $result = [ordered]@{
        success = $false
        featureId = ''
        readmePath = ''
        error = ''
    }

    try {
        $readmePath = Join-Path $Root $RelativeReadme
        $readmeDir = Split-Path -Parent $readmePath
        if (-not (Test-Path $readmeDir)) {
            New-Item -Path $readmeDir -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path $readmePath)) {
            Set-Content -LiteralPath $readmePath -Value '# TEST README' -Encoding UTF8 -Force
        }

        $item = New-PipelineItem -Type 'FeatureRequest' -Title 'TEST FeatureRequest: Add date stamp to README test file' -Description 'Gate self-test feature request' -Source 'Manual' -Category 'feature'
        $added = Add-PipelineItem -WorkspacePath $Root -Item $item

        $null = Update-PipelineItemStatus -WorkspacePath $Root -ItemId $added.id -NewStatus 'IN_PROGRESS' -Notes 'Self-test execution started'

        $stamp = (Get-Date).ToUniversalTime().ToString('o')
        Add-Content -LiteralPath $readmePath -Value ("DateStamp: {0}" -f $stamp) -Encoding UTF8

        $null = Update-PipelineItemStatus -WorkspacePath $Root -ItemId $added.id -NewStatus 'DONE' -Notes 'Self-test execution completed'

        $result.success = $true
        $result.featureId = $added.id
        $result.readmePath = $readmePath
    } catch {
        $result.error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Invoke-MissingComponentChecks {
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string[]]$Components
    )

    $result = [ordered]@{
        totalChecked = 0
        totalMissing = 0
        remediated = 0
        remediationFailed = 0
        missing = @()
        bugLinks = @()
    }

    foreach ($component in $Components) {
        if ([string]::IsNullOrWhiteSpace($component)) { continue }

        $result.totalChecked++
        $componentPath = Join-Path $Root $component
        if (Test-Path $componentPath) { continue }

        $result.totalMissing++
        $result.missing += $component

        $componentLeaf = Split-Path -Leaf $component
        $archiveCandidate = Join-Path (Join-Path $Root '~ARCHIVED') $componentLeaf

        if (Test-Path $archiveCandidate) {
            $targetDir = Split-Path -Parent $componentPath
            if (-not (Test-Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }

            try {
                Copy-Item -LiteralPath $archiveCandidate -Destination $componentPath -Force -ErrorAction Stop
                $result.remediated++
                continue
            } catch {
                # Continue to failure-link path below.
            }
        }

        $result.remediationFailed++

        try {
            $ex = New-Object System.IO.FileNotFoundException("Missing required component: $component")
            $err = New-Object System.Management.Automation.ErrorRecord($ex, 'MissingComponentNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $component)
            $linked = Add-ErrorToPipeline -Exception $err -FunctionName 'Invoke-StuckInPipeGate' -WorkspacePath $Root -AffectedFiles @($component) -ErrorSource 'DependencyError' -UseTestPesterNaming
            if ($null -ne $linked -and $linked.Success) {
                $result.bugLinks += $linked.Bugs2FixId
            } else {
                $fallback = New-PipelineItem -Type 'Bugs2FIX' -Title ("FIX: Missing component {0}" -f $componentLeaf) -Description ("Gate remediation failed for missing component: {0}" -f $component) -Source 'BugTracker' -Category 'dependency'
                $fallback.id = "TEST-PEST-FALLBACK-$([guid]::NewGuid().ToString().Substring(0,8))"
                Add-PipelineItem -WorkspacePath $Root -Item $fallback | Out-Null
                $result.bugLinks += $fallback.id
            }
        } catch {
            $null = Write-StuckGateLog -Message ("Failed to create Bugs2FIX for missing component '{0}': {1}" -f $component, $_.Exception.Message) -Level Warning
        }
    }

    return [pscustomobject]$result
}

$pipelineModulePath = Get-GateModulePath -Root $WorkspacePath -Leaf 'CronAiAthon-Pipeline.psm1'
$errorLinkerPath = Get-GateModulePath -Root $WorkspacePath -Leaf 'CronAiAthon-ErrorLinker.psm1'

if (-not (Test-Path $pipelineModulePath)) {
    throw "Required module not found: $pipelineModulePath"
}

Import-Module $pipelineModulePath -Force -ErrorAction Stop
if (Test-Path $errorLinkerPath) {
    Import-Module $errorLinkerPath -Force -ErrorAction Stop
}

$result = [ordered]@{
    workspacePath = $WorkspacePath
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    passesAttempted = 0
    selfHealed = $false
    passDetails = @()
    repair = [ordered]@{
        corruptArtifactsCleared = 0
        itemsRequeued = 0
        interruptionsDetected = 0
        interruptionsCleared = 0
    }
    featureRequestTest = $null
    missingComponents = $null
}

for ($pass = 1; $pass -le $MaxPasses; $pass++) {
    $result.passesAttempted = $pass

    $integrityBefore = Test-PipelineArtifactIntegrity -WorkspacePath $WorkspacePath -IncludeStaleCheck -OpenDays $OpenDays -PlannedDays $PlannedDays -InProgressDays $InProgressDays -BlockedDays $BlockedDays
    $interruptions = if ($null -ne $integrityBefore.interruptions) { $integrityBefore.interruptions } else { [ordered]@{ total = 0; items = @() } }

    $result.repair.interruptionsDetected += [int]$interruptions.total

    $corruptRepair = Resolve-QueueCorruption -Root $WorkspacePath
    $requeueRepair = Repair-StaleInterruptions -Root $WorkspacePath -InterruptionReport $interruptions

    $result.repair.corruptArtifactsCleared += [int]$corruptRepair.moved
    $result.repair.itemsRequeued += [int]$requeueRepair.requeued

    Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath | Out-Null

    $integrityAfter = Test-PipelineArtifactIntegrity -WorkspacePath $WorkspacePath -IncludeStaleCheck -OpenDays $OpenDays -PlannedDays $PlannedDays -InProgressDays $InProgressDays -BlockedDays $BlockedDays

    $cleared = if ($integrityAfter.interruptions) {
        [Math]::Max(0, ([int]$interruptions.total - [int]$integrityAfter.interruptions.total))
    } else {
        [int]$interruptions.total
    }
    $result.repair.interruptionsCleared += $cleared

    $result.passDetails += [ordered]@{
        pass = $pass
        beforeHealthy = [bool]$integrityBefore.isHealthy
        beforeInterruptions = [int]$interruptions.total
        corruptMoved = [int]$corruptRepair.moved
        requeued = [int]$requeueRepair.requeued
        afterHealthy = [bool]$integrityAfter.isHealthy
        afterInterruptions = if ($integrityAfter.interruptions) { [int]$integrityAfter.interruptions.total } else { 0 }
    }

    if ($integrityAfter.isHealthy) {
        $result.selfHealed = $true
        break
    }
}

if ($RunFeatureRequestSelfTest) {
    $result.featureRequestTest = Invoke-FeatureRequestSmoke -Root $WorkspacePath -RelativeReadme $FeatureReadmePath
}

if ($TestMissingComponents) {
    if (-not (Get-Command -Name 'Add-ErrorToPipeline' -ErrorAction SilentlyContinue)) {
        throw 'Missing component checks require CronAiAthon-ErrorLinker.psm1 to be available.'
    }
    $result.missingComponents = Invoke-MissingComponentChecks -Root $WorkspacePath -Components $RequiredComponents
}

[pscustomobject]$result | ConvertTo-Json -Depth 12
