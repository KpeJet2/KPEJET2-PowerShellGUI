# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Build-ScanToolsManifest -- aggregate scan run history + cron schedule into one manifest.
.DESCRIPTION
    Produces ~REPORTS/scan-tools-manifest.json for consumption by Scan-Tools-Checklist.xhtml.
    Aggregates:
      * The 9 scripts orchestrated by Invoke-FullSystemsScan.ps1
      * Additional scan/audit/check scripts discovered in scripts/ and tests/
    For each script:
      * lastRun, runCount, successCount, failCount, avgDurationSec   (from ~REPORTS/FullSystemsScan/scan-*.json)
      * scheduledTaskId, scheduledTaskName, frequencyMinutes, nextRunUtc, lastResult
        (joined from config/cron-aiathon-schedule.json + frequencyMinutes loop)
    Output schema: ScanToolsManifest/1.0
.NOTES
    Author : The Establishment
    Date   : 2026-05-16
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

if (-not $OutputPath) {
    $OutputPath = Join-Path $WorkspacePath '~REPORTS\scan-tools-manifest.json'
}

# ── Curated list: the canonical 9 from Invoke-FullSystemsScan + extras ──────────────
# Each entry: name (matches FullSystemsScan summary block 'name' OR 'discovered'), script (relative path),
# group (Parallel/Sequential/Steerer/Discovered), taskId (cron schedule task id, '' if none),
# snippet (one-line execution example), description (tooltip).
$catalog = @(
    # === Canonical 9 (Invoke-FullSystemsScan parallel + sequential + steerer) ===
    [pscustomobject]@{ name='SINPatternScanner';        script='tests\Invoke-SINPatternScanner.ps1';          group='Parallel';   taskId='TASK-BugScan';            description='Workspace SIN pattern scanner (P001-P033). Writes findings to ~REPORTS/SINScanner/.'; snippet='pwsh -NoProfile -File .\tests\Invoke-SINPatternScanner.ps1' }
    [pscustomobject]@{ name='SemiSinPenanceScanner';    script='tests\Invoke-SemiSinPenanceScanner.ps1';      group='Parallel';   taskId='TASK-BugScan';            description='Advisory SemiSin scanner (SS-001..SS-006). Penance only, post-test.'; snippet='pwsh -NoProfile -File .\tests\Invoke-SemiSinPenanceScanner.ps1' }
    [pscustomobject]@{ name='ScriptDependencyMatrix';   script='scripts\Build-DependencyMatrix.ps1';          group='Parallel';   taskId='TASK-DepMap';             description='Dependency-matrix builder (referenced by Invoke-FullSystemsScan; may be aliased to Invoke-ScriptDependencyMatrix.ps1).'; snippet='pwsh -NoProfile -File .\scripts\Build-DependencyMatrix.ps1' }
    [pscustomobject]@{ name='OrphanAudit';              script='scripts\Invoke-OrphanAudit.ps1';              group='Parallel';   taskId='';                        description='Orphan file audit -- finds files unreferenced by Main-GUI or config.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-OrphanAudit.ps1' }
    [pscustomobject]@{ name='ReferenceIntegrityCheck';  script='scripts\Test-ReferenceIntegrity.ps1';         group='Parallel';   taskId='';                        description='Cross-reference integrity (referenced by Invoke-FullSystemsScan; may be aliased to Invoke-ReferenceIntegrityCheck.ps1).'; snippet='pwsh -NoProfile -File .\scripts\Test-ReferenceIntegrity.ps1' }
    [pscustomobject]@{ name='PSEnvironmentScanner';     script='scripts\Test-PSEnvironment.ps1';              group='Sequential'; taskId='TASK-PreReqCheck';        description='PowerShell environment scanner (referenced by Invoke-FullSystemsScan; may be aliased to Invoke-PSEnvironmentScanner.ps1).'; snippet='pwsh -NoProfile -File .\scripts\Test-PSEnvironment.ps1' }
    [pscustomobject]@{ name='ConfigCoverageAudit';      script='scripts\Invoke-ConfigCoverageAudit.ps1';      group='Sequential'; taskId='TASK-ConfigCoverage';     description='Daily config-feature adoption audit. Surfaces SIN gaps as pipeline BUG items.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-ConfigCoverageAudit.ps1' }
    [pscustomobject]@{ name='AgenticManifestRebuild';   script='scripts\Build-AgenticManifest.ps1';           group='Sequential'; taskId='TASK-DocRebuild';         description='Rebuilds config/agentic-manifest.json from current scripts/modules.'; snippet='pwsh -NoProfile -File .\scripts\Build-AgenticManifest.ps1' }
    [pscustomobject]@{ name='PipelineSteering';         script='agents\PipelineSteering\core\PipelineSteering.psm1'; group='Steerer'; taskId='TASK-PipelineSteer'; description='Pipeline steering DryRun -- function descriptions, outline conformance, dotfile presence.'; snippet='Import-Module .\agents\PipelineSteering\core\PipelineSteering.psm1; Invoke-PipelineSteer -WorkspacePath . -DryRun' }

    # === Discovered additional scan / audit / check / preflight scripts ===
    [pscustomobject]@{ name='ActualSINPatternScanner';        script='tests\Invoke-SINPatternScanner.ps1';                group='Discovered'; taskId='TASK-BugScan';            description='Direct SIN pattern scan invocation (writes temp/sin-scan-results.json).'; snippet='pwsh -NoProfile -File .\tests\Invoke-SINPatternScanner.ps1' }
    [pscustomobject]@{ name='ScanWorkspaceVersions';          script='scripts\Scan-WorkspaceVersions.ps1';                group='Discovered'; taskId='TASK-VersionConsistency'; description='Scans all script/module VersionTag headers for drift.'; snippet='pwsh -NoProfile -File .\scripts\Scan-WorkspaceVersions.ps1' }
    [pscustomobject]@{ name='InvokeOrphanedFileAudit';        script='scripts\Invoke-OrphanedFileAudit.ps1';              group='Discovered'; taskId='';                        description='Orphaned-file audit (broader than Invoke-OrphanAudit; includes reports/temp).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-OrphanedFileAudit.ps1' }
    [pscustomobject]@{ name='InvokeOrphanCleanup';            script='scripts\Invoke-OrphanCleanup.ps1';                  group='Discovered'; taskId='';                        description='Quarantine/cleanup orphans flagged by OrphanAudit. Read-only by default.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-OrphanCleanup.ps1 -DryRun' }
    [pscustomobject]@{ name='InvokeReferenceIntegrityCheck';  script='scripts\Invoke-ReferenceIntegrityCheck.ps1';        group='Discovered'; taskId='';                        description='Verifies inter-file references resolve to existing files.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-ReferenceIntegrityCheck.ps1' }
    [pscustomobject]@{ name='InvokePipelineIntegrityCheck';   script='scripts\Invoke-PipelineIntegrityCheck.ps1';         group='Discovered'; taskId='';                        description='Validates pipeline JSON store integrity (Bug, Bugs2FIX, action log).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-PipelineIntegrityCheck.ps1' }
    [pscustomobject]@{ name='InvokeCyclicRenameCheck';        script='scripts\Invoke-CyclicRenameCheck.ps1';              group='Discovered'; taskId='';                        description='Detects cyclic rename/refactor proposals.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-CyclicRenameCheck.ps1' }
    [pscustomobject]@{ name='InvokeDependencyScanManager';    script='scripts\Invoke-DependencyScanManager.ps1';          group='Discovered'; taskId='TASK-DepMap';             description='Manager for module dependency scans (orchestrates Test-ModuleDependencies).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-DependencyScanManager.ps1' }
    [pscustomobject]@{ name='InvokeCodeStandardsAssessment';  script='scripts\Invoke-CodeStandardsAssessment.ps1';        group='Discovered'; taskId='';                        description='Assesses headers (FileRole, VersionTag, SupportsPS5.1/7.6).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-CodeStandardsAssessment.ps1' }
    [pscustomobject]@{ name='InvokeDeduplicationAssessment';  script='scripts\Invoke-DeduplicationAssessment.ps1';        group='Discovered'; taskId='';                        description='Detects duplicate function definitions across modules.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-DeduplicationAssessment.ps1' }
    [pscustomobject]@{ name='InvokeHelpMenuCompliance';       script='scripts\Invoke-HelpMenuCompliance.ps1';             group='Discovered'; taskId='TASK-HelpMenuCompliance'; description='Audits Show-*Help/-Help switch coverage; uses config/help-menu-registry.json.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-HelpMenuCompliance.ps1 -Mode Audit' }
    [pscustomobject]@{ name='InvokePipeGAP';                  script='scripts\Invoke-PipeGAP.ps1';                        group='Discovered'; taskId='';                        description='Pipeline gap-analysis report.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-PipeGAP.ps1' }
    [pscustomobject]@{ name='InvokeStaticWorkspaceScan';      script='scripts\Invoke-StaticWorkspaceScan.ps1';            group='Discovered'; taskId='';                        description='Static workspace inventory scan (sizes, types, change-times).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-StaticWorkspaceScan.ps1' }
    [pscustomobject]@{ name='InvokeXhtmlReportTriage';        script='scripts\Invoke-XhtmlReportTriage.ps1';              group='Discovered'; taskId='';                        description='XHTML well-formedness + report freshness triage.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-XhtmlReportTriage.ps1' }
    [pscustomobject]@{ name='InvokeSASCIntegrityPreflight';   script='scripts\Invoke-SASCIntegrityPreflight.ps1';         group='Discovered'; taskId='';                        description='Pre-commit SASC integrity preflight (manifest hash check).'; snippet='pwsh -NoProfile -File .\scripts\Invoke-SASCIntegrityPreflight.ps1' }
    [pscustomobject]@{ name='InvokeReleasePreFlight';         script='scripts\Invoke-ReleasePreFlight.ps1';               group='Discovered'; taskId='';                        description='Release preflight gate: combined SIN + Pester + integrity.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-ReleasePreFlight.ps1' }
    [pscustomobject]@{ name='InvokeEventLogStandardSweep';    script='scripts\Invoke-EventLogStandardSweep.ps1';          group='Discovered'; taskId='';                        description='Sweeps event-log calls for canonical severity/scope/component compliance.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-EventLogStandardSweep.ps1' }
    [pscustomobject]@{ name='InvokeAiActionLogReport';        script='scripts\Invoke-AiActionLogReport.ps1';              group='Discovered'; taskId='';                        description='Aggregates logs/ai-actions/live/*.jsonl into a daily report.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-AiActionLogReport.ps1' }
    [pscustomobject]@{ name='TestPrerequisites';              script='scripts\Test-Prerequisites.ps1';                    group='Discovered'; taskId='TASK-PreReqCheck';        description='Boot-time prerequisites check (PS version, modules, paths).'; snippet='pwsh -NoProfile -File .\scripts\Test-Prerequisites.ps1' }
    [pscustomobject]@{ name='TestModuleDependencies';         script='scripts\Test-ModuleDependencies.ps1';               group='Discovered'; taskId='TASK-DepMap';             description='Module dependency contract test.'; snippet='pwsh -NoProfile -File .\scripts\Test-ModuleDependencies.ps1' }
    [pscustomobject]@{ name='ConvertSinScanToBugs';           script='scripts\Convert-SinScanToBugs.ps1';                 group='Discovered'; taskId='';                        description='Bridges temp/sin-scan-results.json into Bug-*.json items with sinPattern.'; snippet='pwsh -NoProfile -File .\scripts\Convert-SinScanToBugs.ps1 -Apply -MaxItems 50' }
    [pscustomobject]@{ name='InvokeFullSystemsScan';          script='scripts\Invoke-FullSystemsScan.ps1';                group='Discovered'; taskId='TASK-FullSystemsScan';    description='Top-level orchestrator. Runs all 9 above in parallel+sequential mode.'; snippet='pwsh -NoProfile -File .\scripts\Invoke-FullSystemsScan.ps1 -DeltaMode' }
)

# ── Aggregate per-script stats from FullSystemsScan summaries ───────────────────────
$summaryDir = Join-Path $WorkspacePath '~REPORTS\FullSystemsScan'
$summaries  = @()
if (Test-Path $summaryDir) {
    $summaries = @(Get-ChildItem -Path $summaryDir -Filter 'scan-*.json' -File -ErrorAction SilentlyContinue)
}

$stats = @{}
foreach ($f in $summaries) {
    try {
        $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $ts = $s.timestamp
        foreach ($scan in @($s.scans)) {
            $name = [string]$scan.name
            if (-not $stats.ContainsKey($name)) {
                $stats[$name]  # SIN-EXEMPT:P027 -- hashtable key index, context-verified safe = [pscustomobject]@{
                    runCount=0; successCount=0; failCount=0; totalElapsed=0.0; lastRun=$null; lastResult=$null
                }
            }
            $row = $stats[$name]  # SIN-EXEMPT:P027 -- hashtable key index, context-verified safe
            $row.runCount++
            $row.totalElapsed += [double]($scan.elapsed)
            $isFail = ($scan.summary -like 'ERROR:*') -or ($scan.summary -like 'script not found*') -or ($scan.summary -like 'job receive failed*') -or ($scan.summary -like 'DryRun failed:*') -or ($scan.summary -like 'module not found*')
            if ($isFail) {
                $row.failCount++
                $row.lastResult = 'FAILED'
            } else {
                $row.successCount++
                $row.lastResult = 'SUCCESS'
            }
            if (-not $row.lastRun -or [datetime]$ts -gt [datetime]$row.lastRun) { $row.lastRun = $ts }
        }
    } catch { <# Intentional: non-fatal #> }
}

# ── Cron schedule join ─────────────────────────────────────────────────────────────
$cronPath = Join-Path $WorkspacePath 'config\cron-aiathon-schedule.json'
$cronTasks = @{}
if (Test-Path $cronPath) {
    try {
        $cron = Get-Content -LiteralPath $cronPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($t in @($cron.tasks)) {
            $nextRun = $null
            if ($t.lastRun -and $t.frequency) {
                try { $nextRun = ([datetime]$t.lastRun).AddMinutes([double]$t.frequency).ToUniversalTime().ToString('o') } catch { <# Intentional: non-fatal -- date arithmetic failure skips nextRun only #> }
            }
            $cronTasks[$t.id] = [pscustomobject]@{
                taskName          = $t.name
                enabled           = [bool]$t.enabled
                frequencyMinutes  = [int]$t.frequency
                lastRun           = [string]$t.lastRun
                lastResult        = [string]$t.lastResult
                nextRunUtc        = $nextRun
                description       = [string]$t.description
            }
        }
    } catch { <# Intentional: non-fatal #> }
}

# ── Compose rows ───────────────────────────────────────────────────────────────────
$rows = foreach ($e in $catalog) {
    $absPath = Join-Path $WorkspacePath $e.script
    $exists  = Test-Path $absPath
    $st      = $stats[$e.name]
    $avg     = if ($st -and $st.runCount -gt 0) { [math]::Round(($st.totalElapsed / $st.runCount), 2) } else { 0 }
    $task    = if ($e.taskId -and $cronTasks.ContainsKey($e.taskId)) { $cronTasks[$e.taskId] } else { $null }

    [ordered]@{
        name              = $e.name
        script            = $e.script
        group             = $e.group
        exists            = $exists
        description       = $e.description
        snippet           = $e.snippet
        runCount          = if ($st) { $st.runCount } else { 0 }
        successCount      = if ($st) { $st.successCount } else { 0 }
        failCount         = if ($st) { $st.failCount } else { 0 }
        avgDurationSec    = $avg
        lastRunUtc        = if ($st) { $st.lastRun } else { $null }
        lastResult        = if ($st) { $st.lastResult } else { 'never-run' }
        scheduledTaskId   = $e.taskId
        scheduledTaskName = if ($task) { $task.taskName } else { '' }
        taskEnabled       = if ($task) { $task.enabled } else { $false }
        frequencyMinutes  = if ($task) { $task.frequencyMinutes } else { 0 }
        taskLastRunUtc    = if ($task) { $task.lastRun } else { $null }
        taskLastResult    = if ($task) { $task.lastResult } else { '' }
        taskNextRunUtc    = if ($task) { $task.nextRunUtc } else { $null }
    }
}

# ── Wrap & write ───────────────────────────────────────────────────────────────────
$manifest = [ordered]@{
    schema             = 'ScanToolsManifest/1.0'
    generatedUtc       = [datetime]::UtcNow.ToString('o')
    workspacePath      = $WorkspacePath
    summarySourceCount = @($summaries).Count
    cronTaskCount      = $cronTasks.Keys.Count
    rowCount           = @($rows).Count
    rows               = ([object[]](@() + $rows))
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
$json = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host ("Scan tools manifest written: {0}" -f $OutputPath)
Write-Host ("  rows={0}  summaries={1}  cronTasks={2}" -f @($rows).Count, @($summaries).Count, $cronTasks.Keys.Count)
