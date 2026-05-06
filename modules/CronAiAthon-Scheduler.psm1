# VersionTag: 2604.B2.V32.2
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    Cron-Ai-Athon Scheduler -- manages cyclic job execution, job history,
    pre-requisite checks, and autopilot subagent dispatch.
# TODO: HelpMenu | Show-SchedulerHelp | Actions: Schedule|Pause|Resume|Cancel|List|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides the scheduling engine behind Cron-Ai-Athon:
      - Task schedule setup and persistence
      - Pre-requisite validation before job runs
      - Manual and automatic (cron-style) job execution
      - Job statistics tracking (cycles, errors, items done, bugs found, etc.)
      - Subagent dispatch tallying
      - Question tracking (autopilot vs commander answers)
      - Self-suggested additions from autopilot

    Job configuration stored in config/cron-aiathon-schedule.json.
    Job history stored in logs/cron-aiathon-history.json.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 28th March 2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ========================== SCHEDULE CONFIG ==========================

function Get-CronSchedulePath {
    param([string]$WorkspacePath)
    return (Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-schedule.json')
}

function Get-CronHistoryPath {
    param([string]$WorkspacePath)
    return (Join-Path (Join-Path $WorkspacePath 'logs') 'cron-aiathon-history.json')
}

function Initialize-CronSchedule {
    <#
    .SYNOPSIS  Create or load the Cron-Ai-Athon schedule configuration.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $schedPath = Get-CronSchedulePath -WorkspacePath $WorkspacePath
    if (Test-Path $schedPath) {
        return (Get-Content $schedPath -Raw | ConvertFrom-Json)
    }

    $schedule = [ordered]@{
        meta = [ordered]@{
            schema      = 'CronAiAthon-Schedule/1.0'
            created     = (Get-Date).ToUniversalTime().ToString('o')
            description = 'Cron-Ai-Athon task scheduling configuration.'
        }
        enabled       = $true
        frequencyMinutes = 120
        lastRunTime   = $null
        nextRunTime   = (Get-Date).AddMinutes(120).ToUniversalTime().ToString('o')
        maxConcurrentJobs = 1
        autoStartOnGUILaunch = $false
        tasks = @(
            [ordered]@{
                id        = 'TASK-BugScan'
                name      = 'Full Bug Scan'
                enabled   = $true
                type      = 'BugScan'
                frequency = 120
                lastRun   = $null
                lastResult = $null
            },
            [ordered]@{
                id        = 'TASK-PipelineProcess'
                name      = 'Pipeline Processing'
                enabled   = $true
                type      = 'PipelineProcess'
                frequency = 60
                lastRun   = $null
                lastResult = $null
            },
            [ordered]@{
                id        = 'TASK-MasterAggregate'
                name      = 'Master ToDo Aggregation'
                enabled   = $true
                type      = 'MasterAggregate'
                frequency = 30
                lastRun   = $null
                lastResult = $null
            },
            [ordered]@{
                id        = 'TASK-SinRegistryReview'
                name      = 'Sin Registry Review'
                enabled   = $true
                type      = 'SinRegistryReview'
                frequency = 240
                lastRun   = $null
                lastResult = $null
            },
            [ordered]@{
                id        = 'TASK-PreReqCheck'
                name      = 'Pre-Requisite Check'
                enabled   = $true
                type      = 'PreReqCheck'
                frequency = 480
                lastRun   = $null
                lastResult = $null
            }
        )
        jobStatistics = [ordered]@{
            totalCycles          = 0
            totalErrors          = 0
            totalItemsDone       = 0
            totalBugsFound       = 0
            totalTestsMade       = 0
            totalPlansMade       = 0
            totalSubagentCalls   = 0
            subagentTally        = [ordered]@{}
            lastErrorMessage     = ''
            lastErrorTime        = $null
            questionsTotal       = 0
            questionsAutopilot   = 0
            questionsCommander   = 0
            questionsUnanswered  = 0
        }
        autopilotSuggestions = [ordered]@{
            items       = @()
            implemented = 0
            pending     = 0
            rejected    = 0
            blocked     = 0
            failed      = 0
        }
        runningQueue = @()
    }

    $configDir = Join-Path $WorkspacePath 'config'
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $schedule | ConvertTo-Json -Depth 10 | Set-Content -Path $schedPath -Encoding UTF8
    return ($schedule | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

function Save-CronSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] $Schedule
    )
    $schedPath = Get-CronSchedulePath -WorkspacePath $WorkspacePath
    $Schedule | ConvertTo-Json -Depth 10 | Set-Content -Path $schedPath -Encoding UTF8
}

function Initialize-CronLogging {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    if (Get-Command Write-CronLog -ErrorAction SilentlyContinue) {
        return
    }

    $eventLogModulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-EventLog.psm1'
    if (Test-Path $eventLogModulePath) {
        try {
            Import-Module $eventLogModulePath -Force -ErrorAction Stop
        } catch {
            Write-Warning "Initialize-CronLogging: Failed to import CronAiAthon-EventLog.psm1: $($_.Exception.Message)"
        }
    }

    if (-not (Get-Command Write-CronLog -ErrorAction SilentlyContinue)) {
        function Write-CronLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
            param(
                [Parameter(Mandatory)] [string]$Message,
                [string]$Severity = 'Informational',
                [string]$Source = 'CronAiAthon-Scheduler'
            )

            $prefix = "[$Severity][$Source]"
            Write-Verbose "$prefix $Message"
        }
    }
}

# ========================== PRE-REQUISITE CHECK ==========================

function Invoke-PreRequisiteCheck {
    <#
    .SYNOPSIS  Run pre-flight checks before any Cron-Ai-Athon job.
    .OUTPUTS   [ordered] hashtable with pass/fail details.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $checks = @()

    # Check required directories
    foreach ($dir in @('config','modules','scripts','todo','sin_registry','logs','tests')) {
        $dirPath = Join-Path $WorkspacePath $dir
        $checks += [ordered]@{
            check  = "Directory: $dir"
            status = if (Test-Path $dirPath) { 'PASS' } else { 'FAIL' }
            detail = $dirPath
        }
    }

    # Check required modules
    foreach ($mod in @('CronAiAthon-Pipeline','CronAiAthon-BugTracker','CronAiAthon-EventLog')) {
        $modPath = Join-Path (Join-Path $WorkspacePath 'modules') "$mod.psm1"
        $checks += [ordered]@{
            check  = "Module: $mod"
            status = if (Test-Path $modPath) { 'PASS' } else { 'WARN' }
            detail = $modPath
        }
    }

    # Check PwShGUICore
    $coreMod = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUICore.psm1'
    $checks += [ordered]@{
        check  = 'Module: PwShGUICore'
        status = if (Test-Path $coreMod) { 'PASS' } else { 'FAIL' }
        detail = $coreMod
    }

    # Check pipeline registry
    $regPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
    $checks += [ordered]@{
        check  = 'Pipeline Registry'
        status = if (Test-Path $regPath) { 'PASS' } else { 'WARN' }
        detail = 'Will be created on first run if missing'
    }

    # Check schedule config
    $schedPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-schedule.json'
    $checks += [ordered]@{
        check  = 'Schedule Config'
        status = if (Test-Path $schedPath) { 'PASS' } else { 'WARN' }
        detail = 'Will be created on first run if missing'
    }

    $passCount = @($checks | Where-Object { $_.status -eq 'PASS' }).Count
    $failCount = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
    $warnCount = @($checks | Where-Object { $_.status -eq 'WARN' }).Count

    return [ordered]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        totalChecks = $checks.Count
        passed     = $passCount
        failed     = $failCount
        warnings   = $warnCount
        allPassed  = ($failCount -eq 0)
        checks     = $checks
    }
}

# ========================== JOB EXECUTION ==========================

function Invoke-CronJob {
    <#
    .SYNOPSIS  Execute a single Cron-Ai-Athon job task.
    .PARAMETER TaskId    The task ID from the schedule.
    .PARAMETER WorkspacePath  Root workspace path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$TaskId
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $task = @($schedule.tasks) | Where-Object { $_.id -eq $TaskId }
    if (-not $task) { return [ordered]@{ success = $false; error = "Task $TaskId not found" } }

    $startTime = Get-Date
    $result = [ordered]@{
        taskId    = $TaskId
        taskName  = $task.name
        startTime = $startTime.ToUniversalTime().ToString('o')
        endTime   = $null
        success   = $false
        itemsProcessed = 0
        bugsFound = 0
        errors    = @()
        detail    = ''
    }

    Initialize-CronLogging -WorkspacePath $WorkspacePath

    try {
        switch ($task.type) {
            'BugScan' {
                $bugMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-BugTracker.psm1'
                if (Test-Path $bugMod) { Import-Module $bugMod -Force -ErrorAction Stop }
                $bugs = Invoke-FullBugScan -WorkspacePath $WorkspacePath
                $bugs = @($bugs)
                $result.bugsFound = $bugs.Count
                $result.detail = "$($bugs.Count) bugs detected across all vectors"

                if ($bugs.Count -gt 0) {
                    $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                    if (Test-Path $pipeMod) { Import-Module $pipeMod -Force -ErrorAction Stop }
                    $processed = Invoke-BugToPipelineProcessor -WorkspacePath $WorkspacePath -DetectedBugs $bugs
                    $result.itemsProcessed = @($processed).Count
                }
                $result.success = $true
            }
            'PipelineProcess' {
                $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                if (Test-Path $pipeMod) { Import-Module $pipeMod -Force -ErrorAction Stop }
                $items = Get-PipelineItems -WorkspacePath $WorkspacePath -Status 'OPEN'
                $items = @($items)
                $null = Invoke-PipelineArtifactRefresh -WorkspacePath $WorkspacePath
                $health = $null
                try {
                    $health = Get-PipelineHealthMetrics -WorkspacePath $WorkspacePath
                } catch {
                    $result.errors += "Pipeline health metrics warning: $($_.Exception.Message)"
                }
                $result.itemsProcessed = $items.Count
                $result.detail = "$($items.Count) open items in pipeline; artifacts refreshed (master/bundle/index) and health sampled"
                if ($null -ne $health -and $health.PSObject.Properties['openItems']) {
                    $result.detail += "; openItems=$($health.openItems)"
                }
                $result.success = $true
            }
            'MasterAggregate' {
                $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                if (Test-Path $pipeMod) { Import-Module $pipeMod -Force -ErrorAction Stop }
                $outPath = Export-CentralMasterToDo -WorkspacePath $WorkspacePath
                $result.detail = "Master ToDo exported to $outPath"
                $result.success = $true
            }
            'SinRegistryReview' {
                $sinDir = Join-Path $WorkspacePath 'sin_registry'
                $sinCount = 0
                if (Test-Path $sinDir) {
                    $sinCount = @(Get-ChildItem -Path $sinDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
                }
                $result.detail = "$sinCount sin entries in registry"
                $result.itemsProcessed = $sinCount
                $result.success = $true
            }
            'PreReqCheck' {
                $preReq = Invoke-PreRequisiteCheck -WorkspacePath $WorkspacePath
                $result.detail = "Passed: $($preReq.passed)/$($preReq.totalChecks), Failed: $($preReq.failed), Warn: $($preReq.warnings)"
                $result.success = $preReq.allPassed
                if (-not $preReq.allPassed) {
                    $failedChecks = @($preReq.checks | Where-Object { $_.status -eq 'FAIL' })
                    foreach ($fc in $failedChecks) {
                        $result.errors += "FAIL: $($fc.check) - $($fc.detail)"
                    }
                }
            }
            'ReportRetention' {
                # Purge ~REPORTS/ subdirs older than 30 days, archive to ~REPORTS/archive/
                $reportsDir = Join-Path $WorkspacePath '~REPORTS'
                $archiveDir = Join-Path $reportsDir 'archive'
                if (-not (Test-Path $archiveDir)) { New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null }
                $cutoff = (Get-Date).AddDays(-30)
                $purged = 0
                if (Test-Path $reportsDir) {
                    $oldDirs = @(Get-ChildItem -Path $reportsDir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'archive' -and $_.LastWriteTime -lt $cutoff })
                    foreach ($d in $oldDirs) {
                        $destZip = Join-Path $archiveDir "$($d.Name)_archived-$(Get-Date -Format 'yyMMddHHmm').zip"
                        try {
                            Compress-Archive -Path $d.FullName -DestinationPath $destZip -Force
                            Remove-Item -Path $d.FullName -Recurse -Force
                            $purged++
                        } catch { $result.errors += "Retention: $($_.Exception.Message)" }
                    }
                }
                $result.itemsProcessed = $purged
                $result.detail = "$purged report folder(s) archived/purged (cutoff: 30 days)"
                $result.success = $true
            }
            'DocFreshness' {
                # Scan ~README.md/*.md for stale VersionTags and LastWriteTime > 30 days
                $docDir = Join-Path $WorkspacePath '~README.md'
                $stale = @()
                if (Test-Path $docDir) {
                    $mdFiles = @(Get-ChildItem -Path $docDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
                    $cutoff = (Get-Date).AddDays(-30)
                    foreach ($f in $mdFiles) {
                        $age = ((Get-Date) - $f.LastWriteTime).Days
                        $head = Get-Content $f.FullName -TotalCount 5 -ErrorAction SilentlyContinue
                        $tag = ($head | Where-Object { $_ -match 'VersionTag' }) -replace '.*VersionTag:\s*', '' -replace '[`>]', ''
                        if ($f.LastWriteTime -lt $cutoff) {
                            $stale += [ordered]@{ file = $f.Name; ageDays = $age; versionTag = ($tag | Select-Object -First 1) }
                        }
                    }
                }
                $result.itemsProcessed = $stale.Count
                $result.detail = "$($stale.Count) of $($mdFiles.Count) docs stale (>30 days)"
                if ($stale.Count -gt 0) {
                    # Write freshness report
                    $freshDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'DocFreshness'
                    if (-not (Test-Path $freshDir)) { New-Item -Path $freshDir -ItemType Directory -Force | Out-Null }
                    $rptPath = Join-Path $freshDir "freshness_$(Get-Date -Format 'yyyyMMdd-HHmm').json"
                    $stale | ConvertTo-Json -Depth 3 | Set-Content -Path $rptPath -Encoding UTF8
                    $result.detail += " - report: $rptPath"
                }
                $result.success = $true
            }
            'DocRebuild' {
                # Regenerate canonical documentation: manifest, MODULE-FUNCTION-INDEX, DIRECTORY-TREE
                $rebuilt = @()
                # 1. Agentic Manifest + MODULE-FUNCTION-INDEX
                $manifestScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-AgenticManifest.ps1'
                if (Test-Path $manifestScript) {
                    try {
                        & $manifestScript
                        $rebuilt += 'agentic-manifest.json'
                        $rebuilt += 'MODULE-FUNCTION-INDEX.md'
                    } catch { $result.errors += "Manifest: $($_.Exception.Message)" }
                }
                # 1b. IMPL-20260405-003: Version alignment cross-validation gate after manifest rebuild
                $verAlignScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-VersionAlignmentTool.ps1'
                if (Test-Path $verAlignScript) {
                    try {
                        $xvOutput = powershell -NoProfile -NonInteractive -File $verAlignScript `
                            -WorkspacePath $WorkspacePath -CrossValidate 2>&1
                        $xvMismatches = @($xvOutput | Select-String 'Manifest mismatches: [^0]')
                        if ($xvMismatches.Count -gt 0) {
                            $result.errors += "VersionAlign(CrossValidate): version drift detected - $($xvMismatches[0].ToString().Trim())"
                        }
                        $rebuilt += 'VersionAlign-CrossValidate'
                    } catch { $result.errors += "VersionAlign: $($_.Exception.Message)" }
                }
                # 2. Directory Tree
                $treeScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-DirectoryTree.ps1'
                if (Test-Path $treeScript) {
                    try {
                        & $treeScript
                        $rebuilt += 'DIRECTORY-TREE.md'
                    } catch { $result.errors += "DirTree: $($_.Exception.Message)" }
                }
                # 3. Todo Bundle
                $bundleScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-TodoBundleRebuild.ps1'
                if (Test-Path $bundleScript) {
                    try {
                        & $bundleScript
                        $rebuilt += '_bundle.js'
                    } catch { $result.errors += "Bundle: $($_.Exception.Message)" }
                }

                # 4. Enforce pipeline integrity after document and artifact rebuild
                $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                if (Test-Path $pipeMod) {
                    try {
                        Import-Module $pipeMod -Force -ErrorAction Stop
                        $integrity = Test-PipelineArtifactIntegrity -WorkspacePath $WorkspacePath -IncludeStaleCheck
                        $integrityDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineIntegrity'
                        if (-not (Test-Path $integrityDir)) {
                            New-Item -Path $integrityDir -ItemType Directory -Force | Out-Null
                        }
                        $integrityPath = Join-Path $integrityDir ("scheduler-integrity-{0}.json" -f (Get-Date -Format 'yyMMddHHmm'))
                        [ordered]@{
                            generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                            source = 'CronAiAthon-Scheduler.DocRebuild'
                            taskId = $TaskId
                            integrity = $integrity
                        } | ConvertTo-Json -Depth 12 | Set-Content -Path $integrityPath -Encoding UTF8

                        if (-not $integrity.isHealthy) {
                            $result.errors += "IntegrityGate: unhealthy pipeline state (see $integrityPath)"
                        }
                    } catch {
                        $result.errors += "IntegrityGate: $($_.Exception.Message)"
                    }
                }

                $result.itemsProcessed = $rebuilt.Count
                $result.detail = "Rebuilt: $($rebuilt -join ', ')"
                $result.success = ($result.errors.Count -eq 0)
            }
            'DepMap' {
                # Step 7d: Run workspace dependency map + script dependency matrix (IMPL-20260405-002)
                $depMapScript   = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-WorkspaceDependencyMap.ps1'
                $scriptMatrixScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ScriptDependencyMatrix.ps1'
                $processed = 0
                if (Test-Path $depMapScript) {
                    try {
                        & $depMapScript -WorkspacePath $WorkspacePath
                        $processed++
                    } catch {
                        $result.errors += "DepMap(WorkspaceMap): $($_.Exception.Message)"
                    }
                } else {
                    $result.errors += 'Invoke-WorkspaceDependencyMap.ps1 not found'
                }
                # IMPL-20260405-002: wire ScriptDependencyMatrix as periodic step
                if (Test-Path $scriptMatrixScript) {
                    try {
                        & $scriptMatrixScript -WorkspacePath $WorkspacePath
                        $processed++
                    } catch {
                        $result.errors += "DepMap(ScriptMatrix): $($_.Exception.Message)"
                    }
                } else {
                    $result.errors += 'Invoke-ScriptDependencyMatrix.ps1 not found'
                }
                $result.itemsProcessed = $processed
                $result.detail = "Dependency map steps completed: $processed"
                $result.success = ($result.errors.Count -eq 0)
            }
            'CertMonitor' {
                # Scan PKI folder for expiring or expired certificates and write a report
                $pkiPath    = Join-Path $WorkspacePath 'pki'
                $reportDir  = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'CertMonitor'
                if (-not (Test-Path $reportDir)) { New-Item $reportDir -ItemType Directory -Force | Out-Null }
                $reportPath = Join-Path $reportDir "cert-monitor-$(Get-Date -Format 'yyyyMMddHHmm').json"
                try {
                    if (-not (Test-Path $pkiPath)) {
                        $result.detail  = 'PKI folder not found - skipping cert monitor'
                        $result.success = $true
                    } else {
                        $cerFiles = Get-ChildItem $pkiPath -Filter '*.cer' -Recurse -ErrorAction SilentlyContinue
                        $findings = [System.Collections.ArrayList]::new()
                        foreach ($f in $cerFiles) {
                            try {
                                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($f.FullName)
                                $daysLeft = ([datetime]$cert.NotAfter - [datetime]::UtcNow).Days
                                $status   = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -lt 90) { 'EXPIRING' } else { 'OK' }
                                [void]$findings.Add([PSCustomObject]@{
                                    file       = ($f.FullName -replace [regex]::Escape($WorkspacePath), '.')
                                    subject    = $cert.Subject
                                    thumbprint = $cert.Thumbprint
                                    notAfter   = $cert.NotAfter.ToString('o')
                                    daysLeft   = $daysLeft
                                    status     = $status
                                })
                                if ($status -ne 'OK') {
                                    Write-CronLog -Message "CertMonitor: $status cert - $($cert.Subject) ($daysLeft days)" -Severity Warning -Source 'CertMonitor'
                                }
                            } catch { <# skip unreadable cert files - non-fatal #> }
                        }
                        $report = [ordered]@{
                            timestamp = [datetime]::UtcNow.ToString('o')
                            pkiPath   = $pkiPath
                            total     = @($findings).Count
                            expired   = @($findings | Where-Object { $_.status -eq 'EXPIRED' }).Count
                            expiring  = @($findings | Where-Object { $_.status -eq 'EXPIRING' }).Count
                            ok        = @($findings | Where-Object { $_.status -eq 'OK' }).Count
                            certs     = @($findings)
                        }
                        $report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8
                        $result.itemsProcessed = @($findings).Count
                        $result.detail  = "Scanned $(@($cerFiles).Count) certs: $($report.expired) expired, $($report.expiring) expiring, $($report.ok) OK"
                        $result.success = $true
                    }
                } catch {
                    $result.errors += "CertMonitor: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'TabErrorFix' {
                # Process pipeline BUG items tagged as TabScanError and attempt resolution
                try {
                    $bugMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-BugTracker.psm1'
                    if (Test-Path $bugMod) { Import-Module $bugMod -Force -ErrorAction Stop }
                    $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                    if (Test-Path $pipeMod) { Import-Module $pipeMod -Force -ErrorAction Stop }
                    $openItems = @(Get-PipelineItems -WorkspacePath $WorkspacePath | Where-Object {
                        $_.type -eq 'BUG' -and $_.status -eq 'OPEN' -and
                        ($_.category -eq 'TabScanError' -or ($_.tags -like '*TabScan*'))
                    })
                    $resolved = 0
                    foreach ($item in $openItems) {
                        try {
                            # Re-run a targeted bug scan to check if the issue is already resolved
                            $scanResult = Invoke-FullBugScan -WorkspacePath $WorkspacePath -Quiet
                            $stillOpen = @($scanResult.findings | Where-Object { $_.title -eq $item.title })
                            if (@($stillOpen).Count -eq 0) {
                                Update-PipelineItemStatus -WorkspacePath $WorkspacePath -ItemId $item.id -Status 'DONE'
                                Write-CronLog -Message "TabErrorFix: resolved BUG item [$($item.id)] - $($item.title)" -Severity Informational -Source 'TabErrorFix'
                                $resolved++
                            }
                        } catch { <# Intentional: per-item failure is non-fatal; continue loop #> }
                    }
                    $result.itemsProcessed = @($openItems).Count
                    $result.detail  = "Processed $(@($openItems).Count) TabScanError BUG items; resolved $resolved"
                    $result.success = $true
                } catch {
                    $result.errors += "TabErrorFix: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'AutopilotSuggestion' {
                # Emit one AI autopilot suggestion per run (must complete within 7-second budget)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'AutopilotSuggestions'
                    if (-not (Test-Path $reportDir)) { New-Item $reportDir -ItemType Directory -Force | Out-Null }

                    # Gather fast health signals (must stay under 7s total)
                    $suggestion  = $null
                    $schedPath   = Get-CronSchedulePath -WorkspacePath $WorkspacePath
                    $sched       = Get-Content $schedPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                    $totalErrors = if ($sched) { [int]$sched.jobStatistics.totalErrors } else { 0 }
                    $totalCycles = if ($sched) { [int]$sched.jobStatistics.totalCycles } else { 0 }
                    $errorRate   = if ($totalCycles -gt 0) { [math]::Round(($totalErrors / $totalCycles) * 100, 1) } else { 0 }

                    # Quick pipeline open-item count
                    $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
                    $openCount = 0
                    if ($sw.Elapsed.TotalSeconds -lt 4 -and (Test-Path $pipeMod)) {
                        try {
                            Import-Module $pipeMod -Force -ErrorAction Stop
                            $openCount = @(Get-PipelineItems -WorkspacePath $WorkspacePath | Where-Object { $_.status -eq 'OPEN' }).Count
                        } catch { <# Intentional: pipeline unavailable is non-fatal #> }
                    }

                    # Select one actionable suggestion from signals gathered
                    if ($errorRate -gt 10) {
                        $suggestion = "Cron error rate is $errorRate% ($totalErrors/$totalCycles cycles). Run Invoke-BugToPipelineProcessor to triage scheduler failures."
                    } elseif ($openCount -gt 50) {
                        $suggestion = "Pipeline has $openCount OPEN items. Consider running PipelineProcess cron task, or filtering by priority HIGH and batch-resolving."
                    } elseif ($openCount -gt 0) {
                        $suggestion = "$openCount open pipeline item(s) pending. Check the Pipeline Queue tab and advance oldest OPEN items."
                    } else {
                        $dayOfWeek = [datetime]::Now.DayOfWeek
                        $suggestion = switch ($dayOfWeek) {
                            'Monday'    { 'Start the week: run SIN Pattern Scanner (tests\Invoke-SINPatternScanner.ps1) for a fresh governance baseline.' }
                            'Wednesday' { 'Mid-week: run Config Coverage Audit (Invoke-ConfigCoverageAudit.ps1) to catch any drifting files.' }
                            'Friday'    { 'End of week: run DocRebuild cron task to refresh MODULE-FUNCTION-INDEX.md and DIRECTORY-TREE.md.' }
                            default     { "All clear - no open pipeline items. Consider reviewing the CertMonitor report for expiring PKI certificates." }
                        }
                    }

                    if ($suggestion -and $sw.Elapsed.TotalSeconds -lt 7) {
                        Add-AutopilotSuggestion -WorkspacePath $WorkspacePath -Text $suggestion
                        $reportPath = Join-Path $reportDir "autopilot-$(Get-Date -Format 'yyyyMMddHHmm').json"
                        [ordered]@{ timestamp = [datetime]::UtcNow.ToString('o'); suggestion = $suggestion } |
                            ConvertTo-Json -Depth 3 | Set-Content -Path $reportPath -Encoding UTF8
                        Write-CronLog -Message "AutopilotSuggestion: $suggestion" -Severity Informational -Source 'AutopilotSuggestion'
                        $result.detail  = "Posted suggestion in $([math]::Round($sw.Elapsed.TotalSeconds,2))s"
                        $result.success = $true
                    } else {
                        $result.detail  = 'No suggestion generated (time limit reached or no signal found)'
                        $result.success = $true
                    }
                    $result.itemsProcessed = 1
                } catch {
                    $result.errors += "AutopilotSuggestion: $($_.Exception.Message)"
                    $result.success = $false
                } finally {
                    $sw.Stop()
                }
            }
            'ConfigCoverageAudit' {
                # Run the config-coverage audit script and surface gaps as pipeline items
                try {
                    $auditScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ConfigCoverageAudit.ps1'
                    if (-not (Test-Path $auditScript)) {
                        $result.detail  = 'Invoke-ConfigCoverageAudit.ps1 not found - skipping'
                        $result.success = $true
                    } else {
                        $null = & $auditScript -WorkspacePath $WorkspacePath 2>&1
                        $result.detail  = "ConfigCoverageAudit completed. Review ~REPORTS/ConfigCoverage/ for gaps."
                        $result.success = $true
                        $result.itemsProcessed = 1
                        Write-CronLog -Message 'ConfigCoverageAudit: audit script executed successfully' -Severity Informational -Source 'ConfigCoverageAudit'
                    }
                } catch {
                    $result.errors += "ConfigCoverageAudit: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'SecMaint' {
                # Rotate service-account passwords, validate vault entries, check PKI cert expiry
                try {
                    $vaultMod = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
                    if (Test-Path $vaultMod) { Import-Module $vaultMod -Force -ErrorAction Stop }
                    $rotated  = 0
                    $issues   = [System.Collections.ArrayList]::new()

                    # Rotate PSGUIAgentSvc
                    $agentAcct = 'PSGUIAgentSvc'
                    if (Get-LocalUser -Name $agentAcct -ErrorAction SilentlyContinue) {
                        $newPwd = [System.Web.Security.Membership]::GeneratePassword(20, 4)
                        try {
                            $secPwd = ConvertTo-SecureString $newPwd -AsPlainText -Force
                            Set-LocalUser -Name $agentAcct -Password $secPwd
                            Set-VaultItem -Key "svc/$agentAcct" -Value $newPwd
                            $rotated++
                            Write-CronLog -Message "SecMaint: rotated password for $agentAcct" -Severity Informational -Source 'SecMaint'
                        } catch {
                            [void]$issues.Add("Rotate $agentAcct`: $($_.Exception.Message)")
                        }
                    }

                    # Rotate PSGUIPipelineSvc
                    $svcAcct = 'PSGUIPipelineSvc'
                    if (Get-LocalUser -Name $svcAcct -ErrorAction SilentlyContinue) {
                        $newPwd = [System.Web.Security.Membership]::GeneratePassword(20, 4)
                        try {
                            $secPwd = ConvertTo-SecureString $newPwd -AsPlainText -Force
                            Set-LocalUser -Name $svcAcct -Password $secPwd
                            Set-VaultItem -Key "svc/$svcAcct" -Value $newPwd
                            $rotated++
                            Write-CronLog -Message "SecMaint: rotated password for $svcAcct" -Severity Informational -Source 'SecMaint'
                        } catch {
                            [void]$issues.Add("Rotate $svcAcct`: $($_.Exception.Message)")
                        }
                    }

                    # Validate vault cert entry
                    $certVaultKey = 'cert/PSGUICertAdmin-pfx'
                    $pfxB64 = Get-VaultItem -Key $certVaultKey -ErrorAction SilentlyContinue
                    if ($pfxB64) {
                        try {
                            $certPwd = Get-VaultItem -Key 'cert/PSGUICertAdmin-pwd' -ErrorAction SilentlyContinue
                            $pfxBytes = [Convert]::FromBase64String($pfxB64)
                            $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                            $certSecPwd = if ($certPwd) { ConvertTo-SecureString $certPwd -AsPlainText -Force } else { $null }
                            $cert2.Import($pfxBytes, $certSecPwd, 'DefaultKeySet')
                            $daysLeft = ([datetime]$cert2.NotAfter - [datetime]::UtcNow).Days
                            if ($daysLeft -lt 30) {
                                [void]$issues.Add("PSGUICertAdmin cert expires in $daysLeft days - recreate via Security Accounts tab")
                                Write-CronLog -Message "SecMaint: PSGUICertAdmin cert expires in $daysLeft days" -Severity Warning -Source 'SecMaint'
                            }
                        } catch {
                            [void]$issues.Add("Cert validation: $($_.Exception.Message)")
                        }
                    }

                    $result.itemsProcessed = $rotated
                    $result.detail  = "Rotated $rotated account(s). Issues: $(@($issues).Count)"
                    if (@($issues).Count -gt 0) { $result.errors += $issues }
                    $result.success = ($result.errors.Count -eq 0)
                } catch {
                    $result.errors += "SecMaint: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'PipelineSteer' {
                # DryRun steering scan - report only, no file changes
                try {
                    $steerMod = Join-Path (Join-Path $WorkspacePath 'agents') (Join-Path 'PipelineSteering' (Join-Path 'core' 'PipelineSteering.psm1'))
                    if (-not (Test-Path $steerMod)) {
                        $result.detail  = 'PipelineSteering.psm1 not found - skipping'
                        $result.success = $true
                    } else {
                        Import-Module $steerMod -Force -ErrorAction Stop
                        $steerResult    = Invoke-PipelineSteerSession -WorkspacePath $WorkspacePath -SkipPipelineScan
                        $result.detail  = "PipelineSteer DryRun: FnGaps=$($steerResult.FunctionGapCount) OutlineIssues=$($steerResult.OutlineIssueCount) DotfilesNeeded=$($steerResult.DotfileNeedCount)"
                        $result.success = $true
                        $result.itemsProcessed = $steerResult.FunctionGapCount + $steerResult.OutlineIssueCount + $steerResult.DotfileNeedCount
                        Write-CronLog -Message "PipelineSteer: DryRun scan complete: $($result.detail)" -Severity Informational -Source 'PipelineSteer'
                    }
                } catch {
                    $result.errors += "PipelineSteer: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'PipelineSteerApply' {
                # Apply-mode steering: fix files, bump versions, run post-scan
                try {
                    $steerMod = Join-Path (Join-Path $WorkspacePath 'agents') (Join-Path 'PipelineSteering' (Join-Path 'core' 'PipelineSteering.psm1'))
                    if (-not (Test-Path $steerMod)) {
                        $result.detail  = 'PipelineSteering.psm1 not found - skipping'
                        $result.success = $true
                    } else {
                        Import-Module $steerMod -Force -ErrorAction Stop
                        $steerResult    = Invoke-PipelineSteerSession -WorkspacePath $WorkspacePath -Apply
                        $result.detail  = "PipelineSteerApply: fixed OutlineIssues=$(@($steerResult.OutlineIssues | Where-Object { $_.Fixed }).Count) Dotfiles=$(@($steerResult.DotfilesNeeded | Where-Object { $_.Applied }).Count)"
                        $result.success = $true
                        $result.itemsProcessed = $steerResult.FunctionGapCount + $steerResult.OutlineIssueCount
                        Write-CronLog -Message "PipelineSteerApply: complete: $($result.detail)" -Severity Informational -Source 'PipelineSteerApply'
                    }
                } catch {
                    $result.errors += "PipelineSteerApply: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'RollbackArchive' {
                # Export a rollback archive to enabled location(s)
                try {
                    $rbScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-WorkspaceRollback.ps1'
                    if (-not (Test-Path $rbScript)) {
                        $result.detail  = 'Invoke-WorkspaceRollback.ps1 not found - skipping'
                        $result.success = $true
                    } else {
                        $locCfg  = Join-Path (Join-Path $WorkspacePath 'config') 'My-LookupLocationsConfig.json'
                        $locs    = @()
                        if (Test-Path $locCfg) {
                            $locData = Get-Content $locCfg -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                            $locs    = @($locData.locations) | Where-Object { $_.enabled -eq $true }
                        }
                        $exported = 0
                        foreach ($loc in $locs) {
                            try {
                                & $rbScript -Action Export -WorkspacePath $WorkspacePath -LocationId $loc.id 2>&1 | Out-Null
                                $exported++
                            } catch {
                                $result.errors += "RollbackArchive export to $($loc.id): $($_.Exception.Message)"
                            }
                        }
                        $result.detail  = "RollbackArchive: exported to $exported location(s)"
                        $result.success = ($result.errors.Count -eq 0)
                        $result.itemsProcessed = $exported
                        Write-CronLog -Message "RollbackArchive: $exported archive(s) created" -Severity Informational -Source 'RollbackArchive'
                    }
                } catch {
                    $result.errors += "RollbackArchive: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'ConvoVaultExchange' {
                # Invoke one Rumi/Sumi conversation exchange and export encrypted web bundle
                try {
                    $cvMod = Join-Path (Join-Path $WorkspacePath 'modules') 'PwShGUI-ConvoVault.psm1'
                    if (-not (Test-Path $cvMod)) {
                        $result.detail  = 'PwShGUI-ConvoVault.psm1 not found -- skipping'
                        $result.success = $true
                    } else {
                        Import-Module $cvMod -Force -ErrorAction Stop
                        $exchange = Invoke-ConvoExchange -WorkspacePath $WorkspacePath -SessionTag "Cron-$(Get-Date -Format 'yyyyMMdd')"
                        $bundleOut = Export-ConvoBundle -WorkspacePath $WorkspacePath
                        if ($exchange) {
                            $result.detail = "ConvoVaultExchange: entry $($exchange.id) saved; bundle exported $($bundleOut.EntryCount) entries."
                        } else {
                            $result.detail = "ConvoVaultExchange: exchange produced no output"
                        }
                        $result.success        = $true
                        $result.itemsProcessed = 1
                        Write-CronLog -Message $result.detail -Severity Informational -Source 'ConvoVaultExchange'
                    }
                } catch {
                    $result.errors += "ConvoVaultExchange: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'FullSystemsScan' {
                # Run multithreaded workspace integrity scan with delta mode and space-saving rotation
                try {
                    $fssScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-FullSystemsScan.ps1'
                    if (-not (Test-Path $fssScript)) {
                        $result.detail  = 'Invoke-FullSystemsScan.ps1 not found -- skipping'
                        $result.success = $true
                    } else {
                        $fssOut = & $fssScript -WorkspacePath $WorkspacePath -DeltaMode -Parallel 2>&1
                        if ($fssOut -and $fssOut.PSObject.Properties.Name -contains 'totalIssues') {
                            $result.detail         = "FullSystemsScan: $($fssOut.totalIssues) total issues across $($fssOut.scanCount) scans (runId: $($fssOut.runId))"
                            $result.itemsProcessed = [int]$fssOut.totalIssues
                        } else {
                            $result.detail = "FullSystemsScan: completed (no structured output)"
                        }
                        $result.success = $true
                        Write-CronLog -Message $result.detail -Severity Informational -Source 'FullSystemsScan'
                    }
                } catch {
                    $result.errors += "FullSystemsScan: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'ErrorHandlingLoop' {
                # Iterative error-handling scan/remediation convergence loop
                try {
                    $loopScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-ErrorHandlingContinuousLoop.ps1'
                    if (-not (Test-Path $loopScript)) {
                        $result.detail  = 'Invoke-ErrorHandlingContinuousLoop.ps1 not found -- skipping'
                        $result.success = $true
                    } else {
                        $loopOut = & $loopScript -WorkspacePath $WorkspacePath -MaxIterations 3 -TargetFilePatterns @('Main-GUI.ps1','UserProfileManager.psm1','Invoke-ScriptDependencyMatrix.ps1','Invoke-PSEnvironmentScanner.ps1') -IncludeSilentlyContinue
                        $iterCount = @($loopOut.history).Count
                        $latestTarget = 0
                        if ($iterCount -gt 0) {
                            $latestTarget = [int]$loopOut.history[$iterCount - 1].targetViolations
                        }
                        $result.itemsProcessed = $iterCount
                        $result.detail = "ErrorHandlingLoop: $iterCount iteration(s), latest target violations=$latestTarget"
                        $result.success = $true
                        Write-CronLog -Message $result.detail -Severity Informational -Source 'ErrorHandlingLoop'
                    }
                } catch {
                    $result.errors += "ErrorHandlingLoop: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'SelfReview' {
                try {
                    $srScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-SelfReviewCycle.ps1'
                    if (-not (Test-Path $srScript)) {
                        $result.detail  = 'Invoke-SelfReviewCycle.ps1 not found'
                        $result.success = $false
                    } else {
                        $srOut = & $srScript -WorkspacePath $WorkspacePath -ErrorAction Stop
                        $compositeScore     = if ($null -ne $srOut -and $srOut.PSObject.Properties.Name -contains 'compositeScore') { $srOut.compositeScore } else { 0 }
                        $feedbackCount      = @($srOut.feedbackItems).Count
                        $suggestionsWritten = if ($null -ne $srOut -and $srOut.PSObject.Properties.Name -contains 'suggestionsWritten') { [int]$srOut.suggestionsWritten } else { 0 }
                        $result.detail         = "SelfReview: composite=$compositeScore drops=$(@($srOut.drops).Count) feedback=$feedbackCount suggestions=$suggestionsWritten"
                        $result.itemsProcessed = $feedbackCount
                        $result.success        = $true
                        Write-CronLog -Message $result.detail -Severity Informational -Source 'SelfReview'
                    }
                } catch {
                    $result.errors += "SelfReview: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            'KoeRumaMilestone' {
                # gap-2604-001: Monthly milestone event for koe-RumA agent
                try {
                    $milestoneDir = Join-Path $WorkspacePath '~REPORTS\KoeRumaMilestone'
                    if (-not (Test-Path $milestoneDir)) {
                        New-Item -Path $milestoneDir -ItemType Directory -Force | Out-Null
                    }
                    $milestoneStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $enhancements   = Join-Path $WorkspacePath 'logs\ENHANCEMENTS.md'

                    # Call Invoke-MilestoneEvent if available; otherwise write minimal record
                    $milestoneScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-MilestoneEvent.ps1'
                    if (Test-Path $milestoneScript) {
                        & $milestoneScript -WorkspacePath $WorkspacePath -EnhancementsLogPath $enhancements -ErrorAction Stop
                        $result.detail = "Invoke-MilestoneEvent completed"
                    } else {
                        # Fallback: write a minimal milestone record
                        $mRecord = [ordered]@{
                            milestoneId   = "KRM-$milestoneStamp"
                            generatedAt   = (Get-Date).ToString('o')
                            workspacePath = $WorkspacePath
                            status        = 'milestone-recorded'
                            note          = 'koe-RumA monthly milestone - Invoke-MilestoneEvent.ps1 not found, minimal record written'
                        }
                        $mRecord | ConvertTo-Json -Depth 3 |
                            Set-Content (Join-Path $milestoneDir "milestone-$milestoneStamp.json") -Encoding UTF8
                        $result.detail = "Monthly milestone recorded (minimal): KRM-$milestoneStamp"
                    }
                    $result.success = $true
                    Write-CronLog -Message $result.detail -Severity Informational -Source 'KoeRumaMilestone'
                } catch {
                    $result.errors += "KoeRumaMilestone: $($_.Exception.Message)"
                    $result.success = $false
                }
            }
            default {
                $result.detail = "Unknown task type: $($task.type)"
            }
        }
    } catch {
        $result.success = $false
        $result.errors += $_.Exception.Message
        $result.detail = "Exception: $($_.Exception.Message)"
    }

    $endTime = Get-Date
    $result.endTime = $endTime.ToUniversalTime().ToString('o')

    # Update schedule statistics
    $schedule = Get-Content (Get-CronSchedulePath -WorkspacePath $WorkspacePath) -Raw | ConvertFrom-Json
    $schedule.jobStatistics.totalCycles++
    if (-not $result.success) {
        $schedule.jobStatistics.totalErrors++
        $schedule.jobStatistics.lastErrorMessage = if ($result.errors.Count -gt 0) { $result.errors[0] } else { $result.detail }
        $schedule.jobStatistics.lastErrorTime = $endTime.ToUniversalTime().ToString('o')
    }
    $schedule.jobStatistics.totalBugsFound += $result.bugsFound
    $schedule.jobStatistics.totalItemsDone += $result.itemsProcessed
    $schedule.lastRunTime = $endTime.ToUniversalTime().ToString('o')
    $schedule.nextRunTime = $endTime.AddMinutes($schedule.frequencyMinutes).ToUniversalTime().ToString('o')

    # Update task-specific last run + consecutive-failure counter (IMPR-006)
    foreach ($t in @($schedule.tasks)) {
        if ($t.id -eq $TaskId) {
            $t.lastRun = $endTime.ToUniversalTime().ToString('o')
            $t.lastResult = if ($result.success) { 'SUCCESS' } else { 'FAILED' }

            # Track consecutive failures for dead-letter queue
            if (-not (Get-Member -InputObject $t -Name 'consecutiveFailures' -MemberType NoteProperty)) {
                $t | Add-Member -MemberType NoteProperty -Name 'consecutiveFailures' -Value 0 -Force
            }
            if ($result.success) {
                $t.consecutiveFailures = 0
            } else {
                $t.consecutiveFailures = [int]$t.consecutiveFailures + 1
                if ($t.consecutiveFailures -ge 3) {
                    # Move to dead-letter queue
                    $deadLetterDir = Join-Path $WorkspacePath 'todo\dead-letter'
                    if (-not (Test-Path $deadLetterDir)) {
                        New-Item -Path $deadLetterDir -ItemType Directory -Force | Out-Null
                    }
                    $dlStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $dlFile  = Join-Path $deadLetterDir "dead-$TaskId-$dlStamp.json"
                    [ordered]@{
                        id                 = $TaskId
                        name               = $task.name
                        type               = $task.type
                        consecutiveFailures = $t.consecutiveFailures
                        deadLetteredAt     = $endTime.ToUniversalTime().ToString('o')
                        lastErrors         = $result.errors
                        detail             = $result.detail
                        schedulePath       = (Get-CronSchedulePath -WorkspacePath $WorkspacePath)
                    } | ConvertTo-Json -Depth 5 | Set-Content -Path $dlFile -Encoding UTF8

                    $t.enabled = $false
                    $t.consecutiveFailures = 0
                    $result.errors += "DEAD-LETTER: task disabled after 3 consecutive failures - see $dlFile"
                    Write-CronLog -Message "Task $TaskId moved to dead-letter after 3 consecutive failures." -Severity 'Error' -Source 'DeadLetterQueue'
                }
            }
        }
    }

    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule

    # Append to history
    Add-CronJobHistory -WorkspacePath $WorkspacePath -JobResult $result

    return $result
}

function Invoke-AllCronJobs {
    <#
    .SYNOPSIS  Run all enabled tasks in sequence (manual full cycle).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $results = @()

    foreach ($task in @($schedule.tasks)) {
        if ($task.enabled) {
            $results += Invoke-CronJob -WorkspacePath $WorkspacePath -TaskId $task.id
        }
    }

    return $results
}

# ========================== JOB HISTORY ==========================

function Add-CronJobHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [hashtable]$JobResult
    )

    $histPath = Get-CronHistoryPath -WorkspacePath $WorkspacePath
    $logsDir = Join-Path $WorkspacePath 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

    $history = @()
    if (Test-Path $histPath) {
        try {
            $existing = Get-Content $histPath -Raw | ConvertFrom-Json
            if ($existing -is [array]) { $history = @($existing) }
            else { $history = @($existing) }
        } catch { $history = @() }
    }

    $history += $JobResult

    # Keep last 500 entries
    if ($history.Count -gt 500) {
        $history = $history | Select-Object -Last 500
    }

    $history | ConvertTo-Json -Depth 10 | Set-Content -Path $histPath -Encoding UTF8
}

function Get-CronJobHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [int]$Last = 50
    )

    $histPath = Get-CronHistoryPath -WorkspacePath $WorkspacePath
    if (-not (Test-Path $histPath)) { return @() }

    try {
        $history = Get-Content $histPath -Raw | ConvertFrom-Json
        return ($history | Select-Object -Last $Last)
    } catch { return @() }
}

function Get-CronJobSummary {
    <#
    .SYNOPSIS  Get a summary of job statistics for the GUI dashboard.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $stats = $schedule.jobStatistics

    return [ordered]@{
        enabled           = $schedule.enabled
        frequency         = "$($schedule.frequencyMinutes) min"
        lastRunTime       = $schedule.lastRunTime
        nextRunTime       = $schedule.nextRunTime
        totalCycles       = $stats.totalCycles
        totalErrors       = $stats.totalErrors
        totalItemsDone    = $stats.totalItemsDone
        totalBugsFound    = $stats.totalBugsFound
        totalTestsMade    = $stats.totalTestsMade
        totalPlansMade    = $stats.totalPlansMade
        totalSubagentCalls = $stats.totalSubagentCalls
        lastError         = $stats.lastErrorMessage
        lastErrorTime     = $stats.lastErrorTime
        questionsTotal    = $stats.questionsTotal
        questionsAutopilot = $stats.questionsAutopilot
        questionsCommander = $stats.questionsCommander
        questionsUnanswered = $stats.questionsUnanswered
        autopilotSuggestions = $schedule.autopilotSuggestions
        runningQueue      = $schedule.runningQueue
        taskCount         = @($schedule.tasks).Count
        enabledTasks      = @($schedule.tasks | Where-Object { $_.enabled }).Count
    }
}

function Set-CronFrequency {
    <#
    .SYNOPSIS  Change the job run frequency.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [int]$FrequencyMinutes
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $schedule.frequencyMinutes = $FrequencyMinutes
    $schedule.nextRunTime = (Get-Date).AddMinutes($FrequencyMinutes).ToUniversalTime().ToString('o')
    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule
}

function Add-AutopilotSuggestion {
    <#
    .SYNOPSIS  Record an autopilot self-suggestion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$Title,
        [string]$Description = '',
        [string]$Category = 'enhancement'
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $suggestion = [ordered]@{
        id          = 'SUGGEST-' + (Get-Date -Format 'yyyyMMddHHmmss')
        title       = $Title
        description = $Description
        category    = $Category
        status      = 'pending'
        created     = (Get-Date).ToUniversalTime().ToString('o')
    }

    $items = @($schedule.autopilotSuggestions.items)
    $items += $suggestion
    $schedule.autopilotSuggestions.items = $items
    $schedule.autopilotSuggestions.pending++
    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule
    return $suggestion
}

function Update-AutopilotSuggestionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$SuggestionId,
        [Parameter(Mandatory)]
        [ValidateSet('implemented','pending','rejected','blocked','failed')]
        [string]$NewStatus
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $oldStatus = ''
    foreach ($item in $schedule.autopilotSuggestions.items) {
        if ($item.id -eq $SuggestionId) {
            $oldStatus = $item.status
            $item.status = $NewStatus
            break
        }
    }

    if ($oldStatus) {
        $schedule.autopilotSuggestions.$oldStatus--
        $schedule.autopilotSuggestions.$NewStatus++
    }
    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule
}

function Register-SubagentCall {
    <#
    .SYNOPSIS  Tally a subagent invocation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$AgentName
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $schedule.jobStatistics.totalSubagentCalls++

    if ($schedule.jobStatistics.subagentTally.PSObject.Properties[$AgentName]) {
        $schedule.jobStatistics.subagentTally.$AgentName++
    } else {
        $schedule.jobStatistics.subagentTally | Add-Member -NotePropertyName $AgentName -NotePropertyValue 1 -Force
    }

    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule
}

function Register-Question {
    <#
    .SYNOPSIS  Track a question arising from Cron-Ai-Athon work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [ValidateSet('autopilot','commander','unanswered')]
        [string]$AnsweredBy = 'unanswered'
    )

    $schedule = Initialize-CronSchedule -WorkspacePath $WorkspacePath
    $schedule.jobStatistics.questionsTotal++
    switch ($AnsweredBy) {
        'autopilot'  { $schedule.jobStatistics.questionsAutopilot++ }
        'commander'  { $schedule.jobStatistics.questionsCommander++ }
        'unanswered' { $schedule.jobStatistics.questionsUnanswered++ }
    }
    Save-CronSchedule -WorkspacePath $WorkspacePath -Schedule $schedule
}

# ========================== HELP MENU ==========================

function Show-SchedulerHelp {
    <#
    .SYNOPSIS  Display quick usage help for CronAiAthon scheduler operations.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Schedule','Pause','Resume','Cancel','List','Help')]
        [string]$Action = 'Help',

        [ValidateSet('Debug','Info','Warning','Error','Critical')]
        [string]$EventLevel = 'Info',

        [string]$LogToFile = 'auto',
        [switch]$ShowRainbow
    )

    if ($ShowRainbow) {
        Write-Host '=== CronAiAthon Scheduler Help ===' -ForegroundColor Cyan
    }

    $lines = @(
        'Actions: Schedule | Pause | Resume | Cancel | List | Help',
        "Selected Action: $Action",
        "EventLevel: $EventLevel",
        'Examples:',
        '  Show-SchedulerHelp -Action List',
        '  Show-SchedulerHelp -Action Schedule -EventLevel Warning',
        '  Show-SchedulerHelp -Action Resume -LogToFile auto',
        '  Show-SchedulerHelp -Action Help -ShowRainbow'
    )
    foreach ($line in $lines) {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($LogToFile)) {
        $logPath = if ($LogToFile -eq 'auto') {
            Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs') 'scheduler-events-help.log'
        } else {
            $LogToFile
        }
        try {
            $logDir = Split-Path -Path $logPath -Parent
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $logPath -Value ("[{0}] Help viewed: Action={1}; EventLevel={2}" -f (Get-Date -Format o), $Action, $EventLevel) -Encoding UTF8
        } catch {
            Write-Verbose "Show-SchedulerHelp log write failed: $($_.Exception.Message)"
        }
    }
}

# ========================== EXPORTS ==========================

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Initialize-CronSchedule',
    'Save-CronSchedule',
    'Invoke-PreRequisiteCheck',
    'Invoke-CronJob',
    'Invoke-AllCronJobs',
    'Add-CronJobHistory',
    'Get-CronJobHistory',
    'Get-CronJobSummary',
    'Set-CronFrequency',
    'Add-AutopilotSuggestion',
    'Update-AutopilotSuggestionStatus',
    'Register-SubagentCall',
    'Register-Question',
    'Get-CronSchedulePath',
    'Get-CronHistoryPath',
    'Show-SchedulerHelp'
)







