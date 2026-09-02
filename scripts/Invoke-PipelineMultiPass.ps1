# VersionTag: 2605.B5.V46.1
# SupportPS5.1: YES(As of: 2026-07-29)
# SupportsPS7.6: YES(As of: 2026-07-29)
# SupportPS5.1TestedDate: 2026-07-29
# SupportsPS7.6TestedDate: 2026-07-29
# FileRole: Pipeline
# Show-Objectives: Resume interop-drift pipeline iterations from last known checkpoint with a configurable minimum-pass enforcement gate.
#Requires -Version 5.1
<#
.SYNOPSIS
    Resumes interop-drift pipeline iterations from the last completed pass,
    enforcing a minimum number of passes before stopping.
.DESCRIPTION
    1. Scans reports/interop-iter/iter-N.json to determine the last completed
       iteration number.
    2. Runs Invoke-InteropDriftIteration.ps1 sequentially for at least
       $MinPasses iterations, starting from (last + 1).
    3. Continues past $MinPasses only if fixes were applied in the last pass
       and $MaxPasses has not been reached.
    4. Emits a consolidated JSON summary to reports/interop-iter/.
.PARAMETER WorkspacePath
    Workspace root. Defaults to parent of the scripts directory.
.PARAMETER MinPasses
    Minimum number of pipeline iterations to run. Default: 3.
.PARAMETER MaxPasses
    Hard ceiling on total iterations run in one invocation. Default: 10.
.PARAMETER NoFix
    Pass-through to Invoke-InteropDriftIteration: skip auto-fix writes.
.PARAMETER NoPipelineDry
    Pass-through: skip pipeline-integrity dry check inside each iteration.
.PARAMETER NoSinScan
    Pass-through: skip SIN scan inside each iteration.
.OUTPUTS
    reports/interop-iter/multipass-<timestamp>.json
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 50)]
    [int]$MinPasses = 3,
    [ValidateRange(1, 50)]
    [int]$MaxPasses = 50,
    [ValidateRange(1, 50)]
    [int]$NoProgressLimit = 7,
    [switch]$NoFix,
    [switch]$NoPipelineDry,
    [switch]$NoSinScan,
    [switch]$NoDeanB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PassLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    Write-Host "[$ts][$Level] [MultiPass] $Msg"
}

# ── AI Action Log bootstrap ──────────────────────────────────────────────────
$script:_MpAiLoaded = $false
$script:_MpActionId = $null
$_mpAiLogModule = Join-Path $WorkspacePath 'modules\PwShGUI-AiActionLog.psm1'
if (-not (Test-Path -LiteralPath $_mpAiLogModule)) {
    $_mpAiLogModule = Join-Path $WorkspacePath 'modules/PwShGUI-AiActionLog.psm1'
}
try {
    if (Test-Path -LiteralPath $_mpAiLogModule) {
        Import-Module $_mpAiLogModule -Force -DisableNameChecking -ErrorAction Stop
        $script:_MpAiLoaded = $true
        $script:_MpActionId = 'multipass-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
        Write-AiActionStart `
            -ActionId   $script:_MpActionId `
            -ActionName 'Invoke-PipelineMultiPass' `
            -AgentId    'Invoke-PipelineMultiPass' `
            -Summary    "Multi-pass pipeline started (min=$MinPasses max=$MaxPasses)" `
            -Files      @() `
            -WorkspacePath $WorkspacePath | Out-Null
    }
}
catch {
    Write-PassLog "AI action log start failed (non-fatal): $($_.Exception.Message)" 'WARN'
}

function Invoke-MpAiFinish {
    param([string]$Status = 'success', [string]$Detail = '')
    if (-not $script:_MpAiLoaded -or -not $script:_MpActionId) { return }
    try {
        Write-AiActionFinish `
            -ActionId   $script:_MpActionId `
            -ActionName 'Invoke-PipelineMultiPass' `
            -AgentId    'Invoke-PipelineMultiPass' `
            -Summary    "Multi-pass finished: $Status $Detail" `
            -Files      @() `
            -Result     $Status `
            -WorkspacePath $WorkspacePath | Out-Null
    }
    catch { <# Intentional: non-fatal finish-log suppression #> }
}

# ---- Locate iteration script ----
$iterScript = Join-Path $WorkspacePath 'scripts\Invoke-InteropDriftIteration.ps1'
if (-not (Test-Path -LiteralPath $iterScript)) {
    $iterScript = Join-Path $WorkspacePath 'scripts/Invoke-InteropDriftIteration.ps1'
}
if (-not (Test-Path -LiteralPath $iterScript)) {
    throw "Invoke-InteropDriftIteration.ps1 not found under: $(Join-Path $WorkspacePath 'scripts')"
}

$iterDir = Join-Path $WorkspacePath 'reports'
$iterDir = Join-Path $iterDir 'interop-iter'
if (-not (Test-Path -LiteralPath $iterDir)) {
    New-Item -Path $iterDir -ItemType Directory -Force | Out-Null
}

# ---- Detect last completed iteration ----
function Get-LastIterationNumber {
    param([string]$ReportDir)
    $files = @(Get-ChildItem -Path $ReportDir -Filter 'iter-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^iter-(\d+)\.json$' } |
                Sort-Object @{ Expression = { [int]($_.Name -replace 'iter-(\d+)\.json', '$1') } } -Descending)
    if (@($files).Count -eq 0) { return 0 }
    $topName = $files[0].Name
    if ($topName -match '^iter-(\d+)\.json$') {
        return [int]$Matches[1]
    }
    return 0
}

$lastIter = Get-LastIterationNumber -ReportDir $iterDir
$startIter = $lastIter + 1
Write-PassLog "Last completed iteration: $lastIter  ->  Starting from: $startIter  (min passes: $MinPasses, max: $MaxPasses)"

$results = [System.Collections.ArrayList]::new()
$passesRun = 0
$consecutiveNoProgress = 0

for ($i = $startIter; $i -lt ($startIter + $MaxPasses); $i++) {
    Write-PassLog "--- Starting pass $i (pass $($passesRun + 1) of this run, min=$MinPasses) ---"

    # Build splatted arguments for the iteration script
    $iterArgs = @{
        Iteration     = $i
        WorkspacePath = $WorkspacePath
    }
    if ($NoFix) { $iterArgs.NoFix = $true }
    if ($NoPipelineDry) { $iterArgs.NoPipelineDry = $true }
    if ($NoSinScan) { $iterArgs.NoSinScan = $true }
    if ($NoDeanB) { $iterArgs.NoDeanB = $true }

    $result = $null
    try {
        $result = & $iterScript @iterArgs
    }
    catch {
        Write-PassLog "ERROR in iteration $i : $($_.Exception.Message)" 'ERROR'
        $result = [pscustomobject]@{
            iteration     = $i
            findings      = -1
            fixes         = -1
            byCategory    = 'ERROR'
            parseErrFiles = -1
            sinTotal      = -1
            sinCritical   = -1
            error         = $_.Exception.Message
        }
    }

    [void]$results.Add($result)
    $passesRun++

    $fixesThisPass = if ($null -ne $result -and $result.PSObject.Properties.Name -contains 'fixes') { [int]$result.fixes }    else { 0 }
    $findingsThisPass = if ($null -ne $result -and $result.PSObject.Properties.Name -contains 'findings') { [int]$result.findings } else { 0 }
    $deanBCreatedThisPass = if ($null -ne $result -and $result.PSObject.Properties.Name -contains 'deanBCreated') { [int]$result.deanBCreated } else { 0 }
    $inventoryBugsThisPass = if ($null -ne $result -and $result.PSObject.Properties.Name -contains 'inventoryBugsCreated') { [int]$result.inventoryBugsCreated } else { 0 }
    $previousFindings = if ($passesRun -gt 1) { [int]$results[$passesRun - 2].findings } else { $findingsThisPass }
    $improvementThisPass = ($fixesThisPass -gt 0 -or $deanBCreatedThisPass -gt 0 -or $inventoryBugsThisPass -gt 0 -or $findingsThisPass -lt $previousFindings)
    Write-PassLog "Pass $i complete — findings=$findingsThisPass fixes=$fixesThisPass deanBItems=$deanBCreatedThisPass inventoryBugs=$inventoryBugsThisPass improvement=$improvementThisPass noProgress=$consecutiveNoProgress/$NoProgressLimit"
    if ($null -ne $result) {
        Add-Member -InputObject $result -NotePropertyName 'improvement' -NotePropertyValue $improvementThisPass -Force
        if ($result.PSObject.Properties.Name -contains 'reportPath' -and (Test-Path -LiteralPath $result.reportPath)) {
            try {
                $iterationReport = Get-Content -LiteralPath $result.reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $stageRelay = @($iterationReport.stages | ForEach-Object { '{0}={1}' -f $_.name, $_.status })
                Add-Member -InputObject $result -NotePropertyName 'stageRelay' -NotePropertyValue $stageRelay -Force
                Add-Member -InputObject $result -NotePropertyName 'gateRelayPassed' -NotePropertyValue (@($iterationReport.stages | Where-Object { $_.status -in @('FAIL', 'STOP') }).Count -eq 0) -Force
            }
            catch {
                Add-Member -InputObject $result -NotePropertyName 'stageRelay' -NotePropertyValue @('REPORT_READ_ERROR') -Force
                Add-Member -InputObject $result -NotePropertyName 'gateRelayPassed' -NotePropertyValue $false -Force
            }
        }
    }

    # ── Drift-regression guard ───────────────────────────────────────────────
    # If findings INCREASED vs the previous pass, flag as DRIFT-REGRESSION.
    $driftRegression = $false
    if ($passesRun -ge 2) {
        $prevResult = $results[$passesRun - 2]
        $prevFindings = if ($null -ne $prevResult -and $prevResult.PSObject.Properties.Name -contains 'findings') { [int]$prevResult.findings } else { 0 }
        if ($findingsThisPass -gt $prevFindings) {
            $driftRegression = $true
            Write-PassLog "DRIFT-REGRESSION: findings increased from $prevFindings to $findingsThisPass in pass $i" 'WARN'
            # Stamp flag onto the result object so CI can detect it
            if ($null -ne $result) {
                Add-Member -InputObject $result -NotePropertyName 'driftRegression' -NotePropertyValue $true -Force
            }
        }
    }

    if (-not $improvementThisPass) {
        $consecutiveNoProgress++
    }
    else {
        $consecutiveNoProgress = 0
    }

    # Stop only after the configured consecutive no-progress window is reached.
    if ($passesRun -ge $MinPasses) {
        if ($consecutiveNoProgress -ge $NoProgressLimit) {
            Write-PassLog "No progression detected for $NoProgressLimit consecutive iterations — stopping convergence run."
            break
        }
    }
}

Write-PassLog "Multi-pass run complete: $passesRun pass(es) executed (iter $startIter to $($startIter + $passesRun - 1))."

# ---- Emit consolidated summary ----
$summary = [ordered]@{
    schema                = 'InteropDriftMultiPass/1.0'
    versionTag            = '2605.B5.V46.1'
    generatedAt           = (Get-Date).ToString('o')
    workspacePath         = $WorkspacePath
    resumedFromIter       = $lastIter
    startedAtIter         = $startIter
    minPasses             = $MinPasses
    maxPasses             = $MaxPasses
    noProgressLimit       = $NoProgressLimit
    passesRun             = $passesRun
    endedAtIter           = ($startIter + $passesRun - 1)
    noFix                 = [bool]$NoFix
    noPipelineDry         = [bool]$NoPipelineDry
    noSinScan             = [bool]$NoSinScan
    noDeanB               = [bool]$NoDeanB
    stoppedForNoProgress  = ($consecutiveNoProgress -ge $NoProgressLimit)
    consecutiveNoProgress = $consecutiveNoProgress
    passes                = @($results)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $iterDir "multipass-$stamp.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding UTF8
Write-PassLog "Summary written: $outFile"

Invoke-MpAiFinish -Status 'success' -Detail "passes=$passesRun endIter=$($startIter + $passesRun - 1)"
return [PSCustomObject]$summary

<# Outline:
    Wraps Invoke-InteropDriftIteration.ps1 in a resumable multi-pass loop.
    Detects last completed iteration, enforces a minimum pass count, and stops
    early only after the minimum is satisfied and no further fixes are being applied.
#>

<# Objectives-Review:
    Goal: ensure pipeline iterations always run a meaningful minimum number of passes
    before concluding, preventing premature convergence on partially-fixed workspaces.
    Future: bind MaxPasses to workspace metric severity to dynamically extend beyond
    the default ceiling when critical findings remain.
#>

<# Problems:
    LAUNCHBAT findings reference %scriptsDir% env vars that are not resolvable in
    the Linux CI environment; these will remain as logged findings until the batch
    files are updated to use PS-relative paths.
    MANIFEST unexported-function findings (LOW severity) are not auto-fixable by
    design — FunctionsToExport must be curated manually per module.
#>
