# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI Cron Processor - 10-minute automated maintenance cycle.
.DESCRIPTION
    Runs a maintenance cycle when Main-GUI is NOT running:
      1.   Feature status check
      2.   Manifest revision / pre-flight
      3.   Deep parse test on all PS scripts
      3.5  SIN pattern scan
      3.6  SIN remedy engine
      3.7  Error handling compliance scan
      3.8  Encoding compliance validation (P006/P023)
      4.   Bug discovery via AutoIssueFinder
      5.   Headless smoke test matrix
      6.   XHTML data rebuild from todo/ JSONs
      7.   Reindex todo/_index.json
      7a.  Directory tree rebuild
      7b.  Agentic manifest rebuild
      7c.  Todo bundle rebuild
      9.5  Self-review health check
      8.   Pipeline integrity gate
      8.5  Reference integrity validation

    Designed to be called by a Windows Scheduled Task (see Register-CronTask.ps1).
.NOTES
    VersionTag: 2604.B2.V31.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun,
    [ValidateRange(1,500)] [int]$BatchSize = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:Root      = Split-Path -Parent $PSScriptRoot   # c:\PowerShellGUI
$script:TodoDir   = Join-Path $script:Root 'todo'
$script:LogDir    = Join-Path $script:Root 'logs'
$script:LogFile   = Join-Path $script:LogDir 'cron-processor.log'
$script:Results   = @{ Started = (Get-Date -Format 'o'); Steps = @{} }

# ── Logging ─────────────────────────────────────────────────
function Write-CronProcessorLog {
    param(
        [string]$Message,
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    if ($Level -eq 'Error') { Write-Warning $line } else { Write-Verbose $line }
}

function Test-CronTodoProperty {
    param(
        [object]$Record,
        [string]$Name
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return ($Record.PSObject.Properties.Name -contains $Name)
}

function Get-CronTodoPropertyValue {
    param(
        [object]$Record,
        [string[]]$Names,
        $DefaultValue = $null
    )

    if ($null -eq $Record -or @($Names).Count -eq 0) {
        return $DefaultValue
    }

    foreach ($name in $Names) {
        if (-not (Test-CronTodoProperty -Record $Record -Name $name)) {
            continue
        }

        $prop = $Record.PSObject.Properties[$name]
        if ($null -eq $prop) {
            continue
        }

        $value = $prop.Value
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        return $value
    }

    return $DefaultValue
}

function Get-CronTodoFirstStringValue {
    param(
        [object]$Record,
        [string[]]$Names,
        [string]$DefaultValue = ''
    )

    $value = Get-CronTodoPropertyValue -Record $Record -Names $Names -DefaultValue $null
    if ($null -eq $value) {
        return $DefaultValue
    }

    if ($value -is [string]) {
        return [string]$value
    }

    $items = @($value)
    if (@($items).Count -gt 0 -and $null -ne $items[0]) {
        return [string]$items[0]
    }

    return $DefaultValue
}

# ── Step 0: GUI check ──────────────────────────────────────
function Test-MainGUIRunning {
    $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like '*PwShGUI*' -or $_.MainWindowTitle -like '*PowerShell GUI*' }
    return ($null -ne $procs -and @($procs).Count -gt 0)
}

# ── Step 1: Feature check ──────────────────────────────────
function Invoke-FeatureCheck {
    Write-CronProcessorLog 'Step 1: Feature status check'
    $featureFiles = Get-ChildItem -Path $script:TodoDir -Filter 'feature-*.json' -ErrorAction SilentlyContinue
    $implemented = 0; $open = 0
    foreach ($f in $featureFiles) {
        try {
            $item = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $st = ([string](Get-CronTodoPropertyValue -Record $item -Names @('status','source_status') -DefaultValue 'OPEN')).ToUpper()
            if ($st -eq 'IMPLEMENTED' -or $st -eq 'CLOSED') { $implemented++ } else { $open++ }
        } catch {
            Write-CronProcessorLog "  Could not parse $($f.Name): $_" 'Warning'
        }
    }
    $msg = "Features: $(@($featureFiles).Count) total, $open open, $implemented implemented"
    Write-CronProcessorLog "  $msg"
    $script:Results.Steps['FeatureCheck'] = $msg
}

# ── Step 2: Manifest revision ──────────────────────────────
function Invoke-ManifestRevision {
    Write-CronProcessorLog 'Step 2: Manifest revision / pre-flight'
    $preFlightScript = Join-Path $script:Root 'scripts\Invoke-ReleasePreFlight.ps1'
    if (-not (Test-Path $preFlightScript)) {
        Write-CronProcessorLog '  Invoke-ReleasePreFlight.ps1 not found, skipping' 'Warning'
        $script:Results.Steps['ManifestRevision'] = 'SKIPPED - script not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['ManifestRevision'] = 'DRY-RUN skipped'
        return
    }
    try {
        & $preFlightScript 2>&1 | Out-Null
        $script:Results.Steps['ManifestRevision'] = 'Completed'
        Write-CronProcessorLog '  Pre-flight completed'
    } catch {
        Write-CronProcessorLog "  Pre-flight error: $_" 'Error'
        $script:Results.Steps['ManifestRevision'] = "ERROR: $_"
    }
}

# ── Step 3: Deep parse test ────────────────────────────────
function Invoke-DeepTest {
    Write-CronProcessorLog 'Step 3: Deep parse validation'
    # Long-standing parse-error scripts with broken comment-help/param blocks.
    # Tracked separately; suppress duplicate Bugs2FIX item creation each cron cycle.
    # Remove a name from this list once the underlying parse error is fixed.
    $knownBadParseFiles = @(
        'Invoke-DataMigration.ps1',
        'New-PwShGUIModule.ps1',
        'Show-CronAiAthonTool.ps1'
    )
    $scripts = Get-ChildItem -Path $script:Root -Include '*.ps1','*.psm1' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history*' -and $_.FullName -notlike '*node_modules*' -and $_.FullName -notlike '*remediation-backups*' -and $_.FullName -notlike '*~REPORTS*' }
    $pass = 0; $fail = 0; $failFiles = @(); $skipped = 0
    foreach ($s in $scripts) {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) {
            $fail++
            $failFiles += $s.Name
            if ($knownBadParseFiles -contains $s.Name) {
                $skipped++
                continue
            }
            # Auto-create a bug item for parse failures
            if (-not $DryRun) {
                $bugId = "bug-parse-$($s.BaseName)-$(Get-Date -Format 'yyyyMMdd')"
                $bugPath = Join-Path $script:TodoDir "$bugId.json"
                if (-not (Test-Path $bugPath)) {
                    $bugItem = @{
                        todo_id     = $bugId
                        category    = 'bug'
                        type        = 'bug'
                        title       = "Parse error in $($s.Name)"
                        description = "Parse validation failed: $($errors[0].Message)"  # SIN-EXEMPT: P027 - $errors[0] only accessed inside parse-fail condition block
                        priority    = 'HIGH'
                        severity    = 'HIGH'
                        status      = 'OPEN'
                        created_at  = (Get-Date -Format 'o')
                        suggested_by = 'CronProcessor-DeepTest'
                        file_refs   = @($s.FullName -replace [regex]::Escape($script:Root + '\'), '')
                        notes       = "Auto-detected by cron deep-test cycle"
                    }
                    $bugItem | ConvertTo-Json -Depth 5 | Set-Content -Path $bugPath -Encoding UTF8
                }
            }
        } else { $pass++ }
    }
    $msg = "Parse: $pass pass, $fail fail"
    if (@($failFiles).Count -gt 0) { $msg += " ($($failFiles -join ', '))" }
    if ($skipped -gt 0) { $msg += " [bug-creation skipped for $skipped known-bad file(s)]" }
    Write-CronProcessorLog "  $msg"
    $script:Results.Steps['DeepTest'] = $msg
}

# ── Step 3.5: SIN Pattern Scan ─────────────────────────────
function Invoke-SINPatternScan {
    Write-CronProcessorLog 'Step 3.5: SIN pattern scan'
    $scanner = Join-Path $script:Root 'tests\Invoke-SINPatternScanner.ps1'
    if (-not (Test-Path $scanner)) {
        Write-CronProcessorLog '  Invoke-SINPatternScanner.ps1 not found, skipping' 'Warning'
        $script:Results.Steps['SINPatternScan'] = 'SKIPPED - scanner not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['SINPatternScan'] = 'DRY-RUN skipped'
        return
    }
    try {
        $scanResult = & $scanner -WorkspacePath $script:Root -Quiet -FailOnCritical
        $total = if ($null -ne $scanResult -and $scanResult.PSObject.Properties.Name -contains 'totalFindings') { [int]$scanResult.totalFindings } else { 0 }
        $crit  = if ($null -ne $scanResult -and $scanResult.PSObject.Properties.Name -contains 'critical')      { [int]$scanResult.critical }      else { 0 }
        $p027 = if ($null -ne $scanResult -and $scanResult.PSObject.Properties.Name -contains 'findings') { @($scanResult.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*27(?:\D|$)|NULL-ARRAY-INDEX|(?:^|-)P027(?:\D|$)' }).Count } else { 0 }
        $p041 = if ($null -ne $scanResult -and $scanResult.PSObject.Properties.Name -contains 'findings') { @($scanResult.findings | Where-Object { $_.sinId -match 'SIN-PATTERN-0*41(?:\D|$)|JSON-SCHEMA-PROPERTY-DRIFT|(?:^|-)P041(?:\D|$)' }).Count } else { 0 }
        $msg = "SIN scan: $total finding(s), $crit critical, $p027 P027, $p041 P041"
        Write-CronProcessorLog "  $msg"
        if ($crit -gt 0 -or $p027 -gt 0 -or $p041 -gt 0) {
            $blockReason = @()
            if ($crit -gt 0) { $blockReason += "$crit CRITICAL" }
            if ($p027 -gt 0) { $blockReason += "$p027 P027" }
            if ($p041 -gt 0) { $blockReason += "$p041 P041" }
            $script:Results.Steps['SINPatternScan'] = "BLOCKED: $($blockReason -join ', ') SIN finding(s) -- $msg"
            Write-CronProcessorLog "  [PIPELINE BLOCKED] $($blockReason -join ', ') SIN finding(s) detected" 'Error'
        } else {
            $script:Results.Steps['SINPatternScan'] = $msg
        }
    } catch {
        Write-CronProcessorLog "  SIN pattern scan error: $_" 'Error'
        $script:Results.Steps['SINPatternScan'] = "ERROR: $_"
    }
}

# ── Step 3.55: Full Pester Suite Gate ─────────────────────
function Invoke-FullPesterSuiteGate {
    Write-CronProcessorLog 'Step 3.55: Full Pester suite gate'
    $runAllTests = Join-Path $script:Root 'tests\Run-AllTests.ps1'
    if (-not (Test-Path $runAllTests)) {
        Write-CronProcessorLog '  Run-AllTests.ps1 not found, blocking pipeline' 'Error'
        $script:Results.Steps['PesterSuiteGate'] = 'FAILED - Run-AllTests.ps1 not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['PesterSuiteGate'] = 'DRY-RUN skipped'
        return
    }

    $hostTargets = @()
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        $hostTargets += [pscustomobject]@{ Name = 'pwsh'; Exe = 'pwsh.exe' }
    }
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $hostTargets += [pscustomobject]@{ Name = 'powershell'; Exe = 'powershell.exe' }
    }
    if (@($hostTargets).Count -eq 0) {
        Write-CronProcessorLog '  No PowerShell host found for Pester gate, blocking pipeline' 'Error'
        $script:Results.Steps['PesterSuiteGate'] = 'FAILED - no host executable available'
        return
    }

    $failed = 0
    $hostResults = @()
    foreach ($target in $hostTargets) {
        try {
            $argList = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$runAllTests`"",
                '-PesterOnly',
                '-RequirePester', 'true',
                '-IncludeModuleValidation', 'true'
            )
            $proc = Start-Process -FilePath $target.Exe -ArgumentList $argList -Wait -PassThru -NoNewWindow
            $hostResults += "$($target.Name)=$($proc.ExitCode)"
            if ($proc.ExitCode -ne 0) {
                $failed++
            }
        } catch {
            $failed++
            $hostResults += "$($target.Name)=EXCEPTION"
            Write-CronProcessorLog "  Pester gate execution failed on $($target.Name): $_" 'Error'
        }
    }

    if ($failed -gt 0) {
        $msg = "FAILED - Pester gate host failures: $($hostResults -join ', ')"
        $script:Results.Steps['PesterSuiteGate'] = $msg
        Write-CronProcessorLog "  $msg" 'Error'
        return
    }

    $msg = "PASSED - $($hostResults -join ', ')"
    $script:Results.Steps['PesterSuiteGate'] = $msg
    Write-CronProcessorLog "  $msg"
}

# ── Step 3.6: SIN Remedy Engine ────────────────────────────
function Invoke-SINRemedyAttempt {
    Write-CronProcessorLog 'Step 3.6: SIN remedy engine'
    $remedyEngine = Join-Path $script:Root 'scripts\Invoke-SINRemedyEngine.ps1'
    if (-not (Test-Path $remedyEngine)) {
        Write-CronProcessorLog '  Invoke-SINRemedyEngine.ps1 not found, skipping' 'Warning'
        $script:Results.Steps['SINRemedyEngine'] = 'SKIPPED - engine not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['SINRemedyEngine'] = 'DRY-RUN skipped'
        return
    }
    try {
        $remedyResult = & $remedyEngine -WorkspacePath $script:Root
        $processed = if ($remedyResult -and $remedyResult.processed) { $remedyResult.processed } else { 0 }
        $resolved  = if ($remedyResult -and $remedyResult.resolved)  { $remedyResult.resolved }  else { 0 }
        $escalated = if ($remedyResult -and $remedyResult.escalated) { $remedyResult.escalated } else { 0 }
        $msg = "Remedy: $processed processed, $resolved resolved, $escalated escalated"
        Write-CronProcessorLog "  $msg"
        $script:Results.Steps['SINRemedyEngine'] = $msg
    } catch {
        Write-CronProcessorLog "  SIN remedy engine error: $_" 'Error'
        $script:Results.Steps['SINRemedyEngine'] = "ERROR: $_"
    }
}

# ── Step 4: Bug discovery ──────────────────────────────────
function Invoke-ScheduledTaskDispatch {
    <#
    .SYNOPSIS  Step 3.7: Dispatch frequency-based scheduled tasks that are now due.
    .DESCRIPTION
        Reads cron-aiathon-schedule.json and calls Invoke-CronJob for every
        enabled task whose lastRun + frequency window has elapsed (or has never run).
        Skips tasks disabled in the schedule.  Each dispatched task updates its own
        lastRun via Invoke-CronJob → Save-CronSchedule so the next cycle correctly
        suppresses it until the next frequency window.
    #>
    Write-CronProcessorLog 'Step 3.7: Scheduled task dispatch'
    if ($DryRun) {
        $script:Results.Steps['ScheduledTaskDispatch'] = 'DRY-RUN skipped'
        return
    }
    $schedulerMod = Join-Path $script:Root 'modules\CronAiAthon-Scheduler.psm1'
    if (-not (Test-Path $schedulerMod)) {
        $script:Results.Steps['ScheduledTaskDispatch'] = 'SKIPPED - CronAiAthon-Scheduler.psm1 not found'
        Write-CronProcessorLog '  Scheduler module not found, skipping' 'Warning'
        return
    }
    try {
        Import-Module $schedulerMod -Force -ErrorAction Stop
        $schedule = Initialize-CronSchedule -WorkspacePath $script:Root
        $now      = Get-Date
        $ran = 0; $skipped = 0; $errors = 0
        foreach ($task in @($schedule.tasks)) {
            if (-not $task.enabled) { $skipped++; continue }
            # Determine if the task is due
            $isDue = $false
            if (-not $task.lastRun) {
                $isDue = $true
            } else {
                try {
                    $lastRunDt = [datetime]::Parse($task.lastRun)
                    $freqMins  = [int]$task.frequency
                    $isDue     = ($now - $lastRunDt).TotalMinutes -ge $freqMins
                } catch {
                    $isDue = $true  # unparseable lastRun — treat as overdue
                }
            }
            if (-not $isDue) { $skipped++; continue }
            Write-CronProcessorLog "  Dispatching task: $($task.id) [$($task.type)]"
            try {
                $cronJobParams = @{ WorkspacePath = $script:Root; TaskId = $task.id }
                if ($BatchSize -gt 0) { $cronJobParams['BatchSize'] = $BatchSize }
                $jobResult = Invoke-CronJob @cronJobParams
                # P022: guard against output-leak arrays returning alongside the result dict
                $realResult = if ($jobResult -is [array]) {
                    @($jobResult | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }) | Select-Object -Last 1
                } else { $jobResult }
                $status = if ($null -ne $realResult -and $realResult['success']) { 'OK' } else { 'FAIL' }
                Write-CronProcessorLog "  Task $($task.id): $status — $($realResult.detail)"
                $ran++
            } catch {
                Write-CronProcessorLog "  Task $($task.id) ERROR: $_" 'Error'
                $errors++
            }
        }
        $msg = "Dispatched: $ran ran, $skipped skipped, $errors errors"
        Write-CronProcessorLog "  $msg"
        $script:Results.Steps['ScheduledTaskDispatch'] = $msg
    } catch {
        Write-CronProcessorLog "  Scheduled task dispatch error: $_" 'Error'
        $script:Results.Steps['ScheduledTaskDispatch'] = "ERROR: $_"
    }
}

# ── Step 4: Bug discovery ──────────────────────────────────
function Invoke-BugDiscovery {
    Write-CronProcessorLog 'Step 4: Bug discovery via AutoIssueFinder'
    $aifModule = Join-Path $script:Root 'modules\PwShGUI_AutoIssueFinder.psm1'
    if (-not (Test-Path $aifModule)) {
        Write-CronProcessorLog '  PwShGUI_AutoIssueFinder.psm1 not found, skipping' 'Warning'
        $script:Results.Steps['BugDiscovery'] = 'SKIPPED - module not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['BugDiscovery'] = 'DRY-RUN skipped'
        return
    }
    try {
        Import-Module $aifModule -Force -ErrorAction Stop
        if (Get-Command Invoke-AutoIssueFinder -ErrorAction SilentlyContinue) {
            $findings = Invoke-AutoIssueFinder -Path $script:Root -ErrorAction SilentlyContinue
            $count = if ($findings) { @($findings).Count } else { 0 }
            $script:Results.Steps['BugDiscovery'] = "$count issue(s) found"
            Write-CronProcessorLog "  AutoIssueFinder: $count issue(s)"
        } else {
            $script:Results.Steps['BugDiscovery'] = 'SKIPPED - function not available'
        }
    } catch {
        Write-CronProcessorLog "  AutoIssueFinder error: $_" 'Error'
        $script:Results.Steps['BugDiscovery'] = "ERROR: $_"
    }
}

# ── Step 5: Smoke test ─────────────────────────────────────
function Invoke-SmokeTest {
    Write-CronProcessorLog 'Step 5: Headless smoke test'
    $smokeScript = Join-Path $script:Root 'tests\Invoke-GUISmokeTest.ps1'
    if (-not (Test-Path $smokeScript)) {
        Write-CronProcessorLog '  Invoke-GUISmokeTest.ps1 not found, skipping' 'Warning'
        $script:Results.Steps['SmokeTest'] = 'SKIPPED - script not found'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['SmokeTest'] = 'DRY-RUN skipped'
        return
    }
    try {
        & $smokeScript -RunShellMatrix 2>&1 | Out-Null
        $script:Results.Steps['SmokeTest'] = 'Completed'
        Write-CronProcessorLog '  Smoke test completed'
    } catch {
        Write-CronProcessorLog "  Smoke test error: $_" 'Error'
        $script:Results.Steps['SmokeTest'] = "ERROR: $_"
    }
}

# ── Step 6: XHTML data rebuild ─────────────────────────────
function Invoke-XhtmlUpdate {
    Write-CronProcessorLog 'Step 6: XHTML data rebuild from todo/ JSONs'
    $featureJsonPath = Join-Path $script:Root 'scripts\XHTML-Checker\PsGUI-FeatureRequests.json'
    $bugJsonPath     = Join-Path $script:Root 'scripts\XHTML-Checker\PsGUI-BugTracker.json'

    # Rebuild features JSON from todo/feature-*.json files
    $featureFiles = Get-ChildItem -Path $script:TodoDir -Filter 'feature-*.json' -ErrorAction SilentlyContinue
    $features = @()
    foreach ($f in $featureFiles) {
        try {
            $item = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $statusMap = @{ 'OPEN' = 'Proposed'; 'IN-PROGRESS' = 'ALPHA Testing'; 'IMPLEMENTED' = 'Released'; 'CLOSED' = 'Deferred' }
            $rawStatus = ([string](Get-CronTodoPropertyValue -Record $item -Names @('status','source_status') -DefaultValue 'OPEN')).ToUpper()
            $mappedStatus = if ($statusMap.ContainsKey($rawStatus)) { $statusMap[$rawStatus] } else { 'Proposed' }
            $featureId = Get-CronTodoFirstStringValue -Record $item -Names @('source_id','id','todo_id') -DefaultValue $f.BaseName
            $features += @{
                id          = $featureId
                title       = (Get-CronTodoFirstStringValue -Record $item -Names @('title') -DefaultValue $featureId)
                status      = $mappedStatus
                description = (Get-CronTodoFirstStringValue -Record $item -Names @('description','notes') -DefaultValue '')
                created     = (Get-CronTodoFirstStringValue -Record $item -Names @('created_at','createdAt','created','firstSeenAt','lastSeenAt','modified') -DefaultValue '')
            }
        } catch { Write-Warning "[CronProcessor] Feature parse error in $($f.Name): $_" }
    }
    $featureOutput = @{ meta = @{ lastModified = (Get-Date -Format 'o'); source = 'CronProcessor' }; features = $features }
    if (-not $DryRun) {
        $featureOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $featureJsonPath -Encoding UTF8
    }

    # Rebuild bugs JSON from todo/bug-*.json files
    $bugFiles = Get-ChildItem -Path $script:TodoDir -Filter 'bug-*.json' -ErrorAction SilentlyContinue
    $bugs = @()
    $bid = 1
    foreach ($bf in $bugFiles) {
        try {
            $item = Get-Content -Path $bf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $statusMap = @{ 'OPEN' = 'Open'; 'IMPLEMENTED' = 'Fixed'; 'CLOSED' = "Won't Fix" }
            $rawStatus = [string](Get-CronTodoPropertyValue -Record $item -Names @('status') -DefaultValue 'OPEN')
            $mappedStatus = if ($statusMap.ContainsKey($rawStatus.ToUpper())) { $statusMap[$rawStatus.ToUpper()] } else { 'Open' }
            $scriptRef = Get-CronTodoFirstStringValue -Record $item -Names @('file_refs','affectedFiles') -DefaultValue ''
            $description = Get-CronTodoFirstStringValue -Record $item -Names @('description','notes') -DefaultValue ''
            $createdAt = Get-CronTodoFirstStringValue -Record $item -Names @('created_at','createdAt','created','firstSeenAt','lastSeenAt','modified') -DefaultValue ''
            $bugs += @{
                id          = $bid
                script      = $scriptRef
                status      = $mappedStatus
                description = $description
                created     = $createdAt
            }
            $bid++
        } catch { Write-Warning "[CronProcessor] Bug parse error in $($bf.Name): $_" }
    }
    $bugOutput = @{ meta = @{ lastModified = (Get-Date -Format 'o'); source = 'CronProcessor' }; bugs = $bugs }
    if (-not $DryRun) {
        $bugOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $bugJsonPath -Encoding UTF8
    }

    $msg = "XHTML rebuild: $(@($features).Count) features, $(@($bugs).Count) bugs written"
    Write-CronProcessorLog "  $msg"
    $script:Results.Steps['XhtmlUpdate'] = $msg
}

# ── Step 7: Reindex ────────────────────────────────────────
function Invoke-Reindex {
    Write-CronProcessorLog 'Step 7: Reindex todo/_index.json'
    $todoMgr = Join-Path $script:Root 'scripts\Invoke-TodoManager.ps1'
    if (Test-Path $todoMgr) {
        if (-not $DryRun) {
            & $todoMgr -Reindex 2>&1 | Out-Null
        }
        $script:Results.Steps['Reindex'] = 'Completed'
        Write-CronProcessorLog '  Reindex completed'
    } else {
        $script:Results.Steps['Reindex'] = 'SKIPPED - TodoManager not found'
    }
}

# ── Step 9.5: Self-Review Check (quick mode) ───────────────
function Invoke-SelfReviewCheck {
    Write-CronProcessorLog 'Step 9.5: Quick self-review health check'
    $srScript = Join-Path $script:Root 'scripts\Invoke-SelfReviewCycle.ps1'
    if (-not (Test-Path $srScript)) {
        $script:Results.Steps['SelfReviewCheck'] = 'SKIPPED - Invoke-SelfReviewCycle.ps1 not found'
        Write-CronProcessorLog '  Self-review script not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['SelfReviewCheck'] = 'DRY-RUN skipped'
        return
    }
    try {
        $srOut = & $srScript -WorkspacePath $script:Root -QuickMode -ErrorAction Stop
        $score = if ($null -ne $srOut -and $srOut.PSObject.Properties.Name -contains 'compositeScore') { $srOut.compositeScore } else { $null }
        if ($null -ne $score) {
            if ($score -lt 0.5) {
                $script:Results.Steps['SelfReviewCheck'] = "WARNING: score=$score (below 0.5 -- check pipeline feedback items)"
                Write-CronProcessorLog "  Quick self-review score LOW: $score" 'Warning'
            } else {
                $script:Results.Steps['SelfReviewCheck'] = "score=$score"
                Write-CronProcessorLog "  Quick self-review score: $score"
            }
        } else {
            $script:Results.Steps['SelfReviewCheck'] = 'Completed (score unavailable)'
        }
    } catch {
        $script:Results.Steps['SelfReviewCheck'] = "ERROR: $_"
        Write-CronProcessorLog "  Self-review check error: $_" 'Error'
    }
}

# ── Step 8: Integrity Gate ─────────────────────────────────
function Invoke-IntegrityGate {
    Write-CronProcessorLog 'Step 8: Pipeline integrity gate (fail on stale interruptions)'
    $pipeMod = Join-Path $script:Root 'modules\CronAiAthon-Pipeline.psm1'
    if (-not (Test-Path $pipeMod)) {
        $script:Results.Steps['IntegrityGate'] = 'SKIPPED - pipeline module not found'
        Write-CronProcessorLog '  Pipeline module not found, skipping integrity gate' 'Warning'
        return
    }

    if ($DryRun) {
        $script:Results.Steps['IntegrityGate'] = 'DRY-RUN skipped'
        return
    }

    try {
        Import-Module $pipeMod -Force -ErrorAction Stop

        # Check integrity BEFORE refresh — so the result reflects actual drift state.
        # Refreshing first would always make isHealthy=true, making failure detection dead code.
        $preRefreshIntegrity = Test-PipelineArtifactIntegrity -WorkspacePath $script:Root -IncludeStaleCheck

        # Now refresh artifacts so dashboards stay current regardless of gate result
        $refreshResult = Invoke-PipelineArtifactRefresh -WorkspacePath $script:Root

        $reportDir = Join-Path (Join-Path $script:Root '~REPORTS') 'PipelineIntegrity'
        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        $reportPath = Join-Path $reportDir ("cron-integrity-{0}.json" -f (Get-Date -Format 'yyMMddHHmm'))
        [ordered]@{
            generatedAt       = (Get-Date).ToUniversalTime().ToString('o')
            source            = 'Invoke-CronProcessor.ps1'
            preRefreshChecked = $true
            refreshed         = $refreshResult
            integrity         = $preRefreshIntegrity
        } | ConvertTo-Json -Depth 12 | Set-Content -Path $reportPath -Encoding UTF8

        if (-not $preRefreshIntegrity.isHealthy) {
            $failedChecks = @($preRefreshIntegrity.checks.GetEnumerator() | Where-Object { -not $_.Value })
            $failureDetail = if (@($failedChecks).Count -gt 0) {
                @($failedChecks | ForEach-Object { $_.Key }) -join ', '
            } else {
                'stale interruptions detected'
            }
            $script:Results.Steps['IntegrityGate'] = "FAILED - $failureDetail"
            Write-CronProcessorLog "  Integrity gate failed: $failureDetail (report: $reportPath)" 'Error'
            return
        }

        $script:Results.Steps['IntegrityGate'] = "Passed (report: $reportPath)"
        Write-CronProcessorLog "  Integrity gate passed (report: $reportPath)"
    } catch {
        $script:Results.Steps['IntegrityGate'] = "ERROR: $_"
        Write-CronProcessorLog "  Integrity gate error: $_" 'Error'
    }
}

# ── Step 3.7: Error Handling Compliance Scan ───────────────
function Invoke-ErrorHandlingComplianceScan {
    Write-CronProcessorLog 'Step 3.7: Error handling compliance scan'
    $ehScript = Join-Path $script:Root 'tests\Test-ErrorHandlingCompliance.ps1'
    if (-not (Test-Path $ehScript)) {
        $script:Results.Steps['ErrorHandlingCompliance'] = 'SKIPPED - scanner not found'
        Write-CronProcessorLog '  Test-ErrorHandlingCompliance.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['ErrorHandlingCompliance'] = 'DRY-RUN skipped'
        return
    }
    try {
        $ehResult = & $ehScript -Path $script:Root
        $total = if ($null -ne $ehResult -and $ehResult.PSObject.Properties.Name -contains 'totalViolations') { $ehResult.totalViolations } else { 0 }
        $msg = "ErrorHandling: $total violation(s)"
        Write-CronProcessorLog "  $msg"
        $script:Results.Steps['ErrorHandlingCompliance'] = $msg
    } catch {
        Write-CronProcessorLog "  Error handling compliance error: $_" 'Error'
        $script:Results.Steps['ErrorHandlingCompliance'] = "ERROR: $_"
    }
}

# ── Step 3.8: Encoding Compliance Validation ───────────────
function Invoke-EncodingValidation {
    Write-CronProcessorLog 'Step 3.8: Encoding compliance validation (P006/P023)'
    $encScript = Join-Path $script:Root 'tests\Test-EncodingCompliance.ps1'
    if (-not (Test-Path $encScript)) {
        $script:Results.Steps['EncodingValidation'] = 'SKIPPED - validator not found'
        Write-CronProcessorLog '  Test-EncodingCompliance.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['EncodingValidation'] = 'DRY-RUN skipped'
        return
    }
    try {
        $encResult = & $encScript -WorkspacePath $script:Root -Quiet
        $total = if ($null -ne $encResult -and $encResult.PSObject.Properties.Name -contains 'totalFindings') { $encResult.totalFindings } else { 0 }
        $crit  = if ($null -ne $encResult -and $encResult.PSObject.Properties.Name -contains 'critical')      { $encResult.critical }      else { 0 }
        $msg = "Encoding: $total finding(s), $crit critical"
        Write-CronProcessorLog "  $msg"
        $script:Results.Steps['EncodingValidation'] = $msg
    } catch {
        Write-CronProcessorLog "  Encoding validation error: $_" 'Error'
        $script:Results.Steps['EncodingValidation'] = "ERROR: $_"
    }
}

# ── Step 7a: Directory Tree Rebuild ────────────────────────
function Invoke-DirectoryTreeRebuild {
    Write-CronProcessorLog 'Step 7a: Directory tree rebuild'
    $treeScript = Join-Path $script:Root 'scripts\Build-DirectoryTree.ps1'
    if (-not (Test-Path $treeScript)) {
        $script:Results.Steps['DirectoryTreeRebuild'] = 'SKIPPED - Build-DirectoryTree.ps1 not found'
        Write-CronProcessorLog '  Build-DirectoryTree.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['DirectoryTreeRebuild'] = 'DRY-RUN skipped'
        return
    }
    try {
        & $treeScript 2>&1 | Out-Null
        $script:Results.Steps['DirectoryTreeRebuild'] = 'Completed'
        Write-CronProcessorLog '  Directory tree rebuilt'
    } catch {
        Write-CronProcessorLog "  Directory tree rebuild error: $_" 'Error'
        $script:Results.Steps['DirectoryTreeRebuild'] = "ERROR: $_"
    }
}

# ── Step 7b: Agentic Manifest Rebuild ──────────────────────
function Invoke-ManifestRebuild {
    Write-CronProcessorLog 'Step 7b: Agentic manifest rebuild'
    $manifestScript = Join-Path $script:Root 'scripts\Build-AgenticManifest.ps1'
    if (-not (Test-Path $manifestScript)) {
        $script:Results.Steps['ManifestRebuild'] = 'SKIPPED - Build-AgenticManifest.ps1 not found'
        Write-CronProcessorLog '  Build-AgenticManifest.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['ManifestRebuild'] = 'DRY-RUN skipped'
        return
    }
    try {
        & $manifestScript 2>&1 | Out-Null
        $script:Results.Steps['ManifestRebuild'] = 'Completed'
        Write-CronProcessorLog '  Agentic manifest rebuilt'
    } catch {
        Write-CronProcessorLog "  Manifest rebuild error: $_" 'Error'
        $script:Results.Steps['ManifestRebuild'] = "ERROR: $_"
    }
}

# ── Step 7b-ii: Version Alignment Cross-Validate (IMPL-20260405-003) ───────
function Invoke-VersionAlignmentCrossValidate {
    Write-CronProcessorLog 'Step 7b-ii: Version alignment cross-validate'
    $vatScript = Join-Path $script:Root 'scripts\Invoke-VersionAlignmentTool.ps1'
    if (-not (Test-Path $vatScript)) {
        $script:Results.Steps['VersionAlignCrossValidate'] = 'SKIPPED - Invoke-VersionAlignmentTool.ps1 not found'
        Write-CronProcessorLog '  Invoke-VersionAlignmentTool.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['VersionAlignCrossValidate'] = 'DRY-RUN skipped'
        return
    }
    try {
        $vatResult = & $vatScript -CrossValidate -WorkspacePath $script:Root 2>&1
        $script:Results.Steps['VersionAlignCrossValidate'] = 'Completed'
        Write-CronProcessorLog '  Version alignment cross-validate passed'
        $vatResult | Where-Object { $_ -match 'WARN|FAIL|mismatch' } | ForEach-Object {
            Write-CronProcessorLog "  VAT: $_" 'Warning'
        }
    } catch {
        Write-CronProcessorLog "  Version alignment cross-validate error: $_" 'Warning'
        $script:Results.Steps['VersionAlignCrossValidate'] = "WARNING: $_"
        # Non-fatal — version drift is informational, not a cycle blocker
    }
}

# ── Step 7c: Todo Bundle Rebuild ───────────────────────────
function Invoke-TodoBundleRebuild {
    Write-CronProcessorLog 'Step 7c: Todo bundle rebuild'
    $bundleScript = Join-Path $script:Root 'scripts\Invoke-TodoBundleRebuild.ps1'
    if (-not (Test-Path $bundleScript)) {
        $script:Results.Steps['TodoBundleRebuild'] = 'SKIPPED - Invoke-TodoBundleRebuild.ps1 not found'
        Write-CronProcessorLog '  Invoke-TodoBundleRebuild.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['TodoBundleRebuild'] = 'DRY-RUN skipped'
        return
    }
    try {
        & $bundleScript 2>&1 | Out-Null
        $script:Results.Steps['TodoBundleRebuild'] = 'Completed'
        Write-CronProcessorLog '  Todo bundle rebuilt'
    } catch {
        Write-CronProcessorLog "  Todo bundle rebuild error: $_" 'Error'
        $script:Results.Steps['TodoBundleRebuild'] = "ERROR: $_"
    }
}

# ── Step 8.5: Reference Integrity Validation ───────────────
function Invoke-ReferenceIntegrityValidation {
    Write-CronProcessorLog 'Step 8.5: Reference integrity validation'
    $refScript = Join-Path $script:Root 'scripts\Invoke-ReferenceIntegrityCheck.ps1'
    if (-not (Test-Path $refScript)) {
        $script:Results.Steps['ReferenceIntegrity'] = 'SKIPPED - Invoke-ReferenceIntegrityCheck.ps1 not found'
        Write-CronProcessorLog '  Invoke-ReferenceIntegrityCheck.ps1 not found, skipping' 'Warning'
        return
    }
    if ($DryRun) {
        $script:Results.Steps['ReferenceIntegrity'] = 'DRY-RUN skipped'
        return
    }
    try {
        $refResult = & $refScript -RootPath $script:Root -ErrorAction Stop
        $broken = if ($null -ne $refResult -and $refResult.PSObject.Properties.Name -contains 'brokenLinks') { @($refResult.brokenLinks).Count } else { 0 }
        $msg = "RefIntegrity: $broken broken link(s)"
        Write-CronProcessorLog "  $msg"
        $script:Results.Steps['ReferenceIntegrity'] = $msg
    } catch {
        Write-CronProcessorLog "  Reference integrity check error: $_" 'Error'
        $script:Results.Steps['ReferenceIntegrity'] = "ERROR: $_"
    }
}

# ═══════════════════════════════════════════════════════════
# MAIN CYCLE
# ═══════════════════════════════════════════════════════════
Write-CronProcessorLog '=== Cron Processor Cycle START ==='
$script:_CronCycleSw = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $Force -and (Test-MainGUIRunning)) {
    Write-CronProcessorLog 'Main GUI is active, skipping cycle'
    Write-CronProcessorLog '=== Cron Processor Cycle END (GUI active) ==='
    return
}

Invoke-FeatureCheck
Invoke-ManifestRevision
Invoke-DeepTest
Invoke-SINPatternScan
Invoke-FullPesterSuiteGate
Invoke-SINRemedyAttempt
Invoke-ScheduledTaskDispatch
Invoke-ErrorHandlingComplianceScan
Invoke-EncodingValidation
Invoke-BugDiscovery
Invoke-SmokeTest
Invoke-XhtmlUpdate
Invoke-Reindex
Invoke-DirectoryTreeRebuild
Invoke-ManifestRebuild
Invoke-VersionAlignmentCrossValidate
Invoke-TodoBundleRebuild
Invoke-SelfReviewCheck
Invoke-IntegrityGate
Invoke-ReferenceIntegrityValidation

# Summary
$script:Results.Completed = Get-Date -Format 'o'
$summary = ($script:Results.Steps.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ' | '
Write-CronProcessorLog "Cycle summary: $summary"
Write-CronProcessorLog '=== Cron Processor Cycle END ==='
$script:_CronCycleSw.Stop()
$integrityStep = [string]($script:Results.Steps['IntegrityGate'])
$sinStep = [string]($script:Results.Steps['SINPatternScan'])
$pesterStep = [string]($script:Results.Steps['PesterSuiteGate'])
if (Get-Command Write-ProcessBanner -ErrorAction SilentlyContinue) {
    $cronSuccess = -not ($integrityStep -like 'FAILED*' -or $integrityStep -like 'ERROR*' -or $sinStep -like 'BLOCKED*' -or $sinStep -like 'ERROR*' -or $pesterStep -like 'FAILED*')
    Write-ProcessBanner -ProcessName 'Cron Processor Cycle' -Stopwatch $script:_CronCycleSw -Success $cronSuccess
}
if ($integrityStep -like 'FAILED*' -or $integrityStep -like 'ERROR*') {
    throw "Integrity gate FAILED: $integrityStep"
}
if ($sinStep -like 'BLOCKED*' -or $sinStep -like 'ERROR*') {
    throw "SIN pattern scan FAILED: $sinStep"
}
if ($pesterStep -like 'FAILED*') {
    throw "Pester suite gate FAILED: $pesterStep"
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





