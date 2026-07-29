# VersionTag: 2605.B5.V46.1
# SupportPS5.1: YES(As of: 2026-07-29)
# SupportsPS7.6: YES(As of: 2026-07-29)
# SupportPS5.1TestedDate: 2026-07-29
# SupportsPS7.6TestedDate: 2026-07-29
# FileRole: Pipeline
# Show-Objectives: Detect pipeline gate failures from JSON outputs, invoke escalating remediation, auto-create BUG items, and recommend rollback when all remediation fails.
#Requires -Version 5.1
<#
.SYNOPSIS
    Detects failing pipeline gates from their JSON output files, applies
    escalating auto-remediation, and creates BUG items when remediation fails.
.DESCRIPTION
    Escalation order (stops at the first level that fully resolves the gate):
      Level 1: PwShGUI-AutoRemediate (P002/P014/P017/P018/P019 auto-fixes)
      Level 2: Invoke-ErrorHandlingRemediation.ps1 (SEC11 violations)
      Level 3: Invoke-InteropDriftIteration.ps1 -NoSinScan (manifest/relpath fixes)
      Level 4: If all levels fail → create BUG via Convert-SinScanToBugs.ps1
               and emit a rollback recommendation to logs/integrity/.

    Gate detection checks the following output locations:
      - Parse/manifest gate: reports/interop-iter/iter-*.json  (parseErrFiles > 0 OR CRITICAL MANIFEST)
      - Error-handling gate: ~REPORTS/ErrorHandlingLoop/*.json (targetViolations > 0)
      - SIN scan gate:       reports/sin-scan-permissive.json  (critical > 0)
.PARAMETER WorkspacePath
    Workspace root. Defaults to parent of the scripts directory.
.PARAMETER DryRun
    Report what remediation would run without executing it.
.PARAMETER MaxEscalationLevel
    Maximum escalation level to attempt (1-4). Default: 4.
.EXAMPLE
    pwsh -File scripts\Invoke-PipelineAutoRepair.ps1
    pwsh -File scripts\Invoke-PipelineAutoRepair.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [switch]$DryRun,
    [ValidateRange(1,4)]
    [int]$MaxEscalationLevel = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$repairLog = [System.Collections.ArrayList]::new()
$logDir    = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$integrityLogDir = Join-Path $logDir 'integrity'
if (-not (Test-Path -LiteralPath $integrityLogDir)) { New-Item -Path $integrityLogDir -ItemType Directory -Force | Out-Null }

function Write-RepairLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    $line = "[$ts][$Level] [AutoRepair] $Msg"
    Write-Host $line
    [void]$repairLog.Add($line)
}

function Add-RepairEvent {
    param([string]$Gate, [string]$Level, [string]$Action, [bool]$Resolved, [string]$Detail = '')
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        gate      = $Gate
        level     = $Level
        action    = $Action
        resolved  = $Resolved
        detail    = $Detail
        dryRun    = [bool]$DryRun
    }
}

# ── Gate detection ────────────────────────────────────────────────────────────

$gates = [ordered]@{}

# Gate 1: Parse / manifest (latest iter-N.json)
$iterDir = Join-Path $WorkspacePath 'reports'
$iterDir = Join-Path $iterDir 'interop-iter'
$iterFiles = @(Get-ChildItem -Path $iterDir -Filter 'iter-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^iter-(\d+)\.json$' } |
    Sort-Object @{ Expression = { [int]($_.Name -replace 'iter-(\d+)\.json','$1') } } -Descending)
if (@($iterFiles).Count -gt 0) {
    try {
        $latestIter = Get-Content -LiteralPath $iterFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $parseErrors    = if ($latestIter.PSObject.Properties.Name -contains 'verify') { @($latestIter.verify.parse.parseErrors).Count } else { 0 }
        $critManifest   = @($latestIter.findings | Where-Object { $_.category -eq 'MANIFEST' -and $_.severity -eq 'CRITICAL' }).Count
        if ($parseErrors -gt 0 -or $critManifest -gt 0) {
            $gates['parse-manifest'] = [pscustomobject]@{
                name        = 'parse-manifest'
                failing     = $true
                parseErrors = $parseErrors
                critManifest = $critManifest
                detail      = "parseErrors=$parseErrors critManifest=$critManifest"
            }
        }
    } catch { Write-RepairLog "Could not read latest iter report: $_" 'WARN' }
}

# Gate 2: Error-handling loop (latest loop report)
$loopDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'ErrorHandlingLoop'
$loopFiles = @(Get-ChildItem -Path $loopDir -Filter 'error-handling-loop-*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
if (@($loopFiles).Count -gt 0) {
    try {
        $loopRpt  = Get-Content -LiteralPath $loopFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $hist     = @($loopRpt.history)
        $lastViol = if (@($hist).Count -gt 0) { [int]$hist[-1].targetViolations } else { 0 }
        if ($lastViol -gt 0) {
            $gates['error-handling'] = [pscustomobject]@{
                name       = 'error-handling'
                failing    = $true
                violations = $lastViol
                detail     = "targetViolations=$lastViol"
            }
        }
    } catch { Write-RepairLog "Could not read error-handling loop report: $_" 'WARN' }
}

# Gate 3: SIN scan (permissive)
$sinJson = Join-Path $WorkspacePath 'reports\sin-scan-permissive.json'
if (Test-Path -LiteralPath $sinJson) {
    try {
        $sinRpt  = Get-Content -LiteralPath $sinJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $crit    = if ($sinRpt.PSObject.Properties.Name -contains 'counts') { [int]$sinRpt.counts.critical } else { 0 }
        if ($crit -gt 0) {
            $gates['sin-scan'] = [pscustomobject]@{
                name     = 'sin-scan'
                failing  = $true
                critical = $crit
                detail   = "criticalFindings=$crit"
            }
        }
    } catch { Write-RepairLog "Could not read SIN scan report: $_" 'WARN' }
}

if (@($gates.Keys).Count -eq 0) {
    Write-RepairLog 'No failing gates detected. Pipeline appears healthy.' 'INFO'
    return [pscustomobject]@{ status = 'healthy'; gatesChecked = 3; events = @() }
}

Write-RepairLog "Failing gates detected: $($gates.Keys -join ', ')"
$events = [System.Collections.ArrayList]::new()

# ── Escalation ────────────────────────────────────────────────────────────────

foreach ($gateName in $gates.Keys) {
    $gate    = $gates[$gateName]
    $resolved = $false
    Write-RepairLog "--- Repairing gate: $gateName ($($gate.detail)) ---"

    # Level 1: Auto-remediate
    if ($MaxEscalationLevel -ge 1) {
        Write-RepairLog "Level 1: PwShGUI-AutoRemediate"
        if (-not $DryRun) {
            $autoRemModule = Join-Path $WorkspacePath 'modules\PwShGUI-AutoRemediate.psm1'
            if (Test-Path -LiteralPath $autoRemModule) {
                try {
                    Import-Module $autoRemModule -Force -DisableNameChecking -ErrorAction Stop
                    $r = Invoke-AutoRemediate -Path $WorkspacePath -Patterns @('P002','P014','P017','P018','P019')
                    $fixCount = if ($r.PSObject.Properties.Name -contains 'TotalFixes') { [int]$r.TotalFixes } else { 0 }
                    Write-RepairLog "Level 1 applied $fixCount fix(es)"
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L1-AutoRemediate' -Action 'applied' -Resolved ($fixCount -gt 0) -Detail "fixes=$fixCount"))
                    if ($fixCount -gt 0 -and $gateName -eq 'error-handling') { $resolved = $true }
                } catch {
                    Write-RepairLog "Level 1 failed: $_" 'WARN'
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L1-AutoRemediate' -Action 'error' -Resolved $false -Detail "$_"))
                }
            } else {
                Write-RepairLog "Level 1: AutoRemediate module not found — skipping" 'WARN'
            }
        } else {
            Write-RepairLog "Level 1: DryRun — would run PwShGUI-AutoRemediate"
            [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L1-AutoRemediate' -Action 'dry-run' -Resolved $false))
        }
    }

    # Level 2: Error-handling remediation
    if (-not $resolved -and $MaxEscalationLevel -ge 2 -and $gateName -eq 'error-handling') {
        Write-RepairLog "Level 2: Invoke-ErrorHandlingRemediation.ps1"
        $remScript = Join-Path $WorkspacePath 'scripts\Invoke-ErrorHandlingRemediation.ps1'
        if (Test-Path -LiteralPath $remScript) {
            if (-not $DryRun) {
                try {
                    & $remScript -Path $WorkspacePath -Pattern WriteWarning | Out-Null
                    & $remScript -Path $WorkspacePath -Pattern WriteError   | Out-Null
                    Write-RepairLog "Level 2 remediation applied"
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L2-ErrorHandlingRem' -Action 'applied' -Resolved $true))
                    $resolved = $true
                } catch {
                    Write-RepairLog "Level 2 failed: $_" 'WARN'
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L2-ErrorHandlingRem' -Action 'error' -Resolved $false -Detail "$_"))
                }
            } else {
                Write-RepairLog "Level 2: DryRun — would run Invoke-ErrorHandlingRemediation.ps1"
                [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L2-ErrorHandlingRem' -Action 'dry-run' -Resolved $false))
            }
        } else {
            Write-RepairLog "Level 2: script not found — skipping" 'WARN'
        }
    }

    # Level 3: Interop-drift iteration
    if (-not $resolved -and $MaxEscalationLevel -ge 3 -and $gateName -in @('parse-manifest','sin-scan')) {
        Write-RepairLog "Level 3: Invoke-InteropDriftIteration.ps1"
        $iterScript = Join-Path $WorkspacePath 'scripts\Invoke-InteropDriftIteration.ps1'
        if (Test-Path -LiteralPath $iterScript) {
            if (-not $DryRun) {
                try {
                    $lastN = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'reports\interop-iter') -Filter 'iter-*.json' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^iter-(\d+)\.json$' } |
                        Sort-Object @{ Expression = { [int]($_.Name -replace 'iter-(\d+)\.json','$1') } } -Descending)
                    $nextN = if (@($lastN).Count -gt 0) { [int](($lastN[0].Name -replace 'iter-(\d+)\.json','$1')) + 1 } else { 1 }
                    $r = & $iterScript -Iteration $nextN -WorkspacePath $WorkspacePath -NoPipelineDry -NoSinScan
                    $fixCount = if ($null -ne $r -and $r.PSObject.Properties.Name -contains 'fixes') { [int]$r.fixes } else { 0 }
                    Write-RepairLog "Level 3 applied $fixCount fix(es)"
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L3-InteropDrift' -Action 'applied' -Resolved ($fixCount -gt 0) -Detail "fixes=$fixCount iter=$nextN"))
                    if ($fixCount -gt 0) { $resolved = $true }
                } catch {
                    Write-RepairLog "Level 3 failed: $_" 'WARN'
                    [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L3-InteropDrift' -Action 'error' -Resolved $false -Detail "$_"))
                }
            } else {
                Write-RepairLog "Level 3: DryRun — would run Invoke-InteropDriftIteration.ps1"
                [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L3-InteropDrift' -Action 'dry-run' -Resolved $false))
            }
        }
    }

    # Level 4: Create BUG + rollback recommendation
    if (-not $resolved -and $MaxEscalationLevel -ge 4) {
        Write-RepairLog "Level 4: Creating BUG item and emitting rollback recommendation" 'WARN'

        # Create bug from SIN scan if available
        $bugScript = Join-Path $WorkspacePath 'scripts\Convert-SinScanToBugs.ps1'
        if (Test-Path -LiteralPath $bugScript) {
            $scanFile = Join-Path $WorkspacePath 'reports\sin-scan-permissive.json'
            if (Test-Path -LiteralPath $scanFile) {
                if (-not $DryRun) {
                    try {
                        & $bugScript -WorkspacePath $WorkspacePath -ScanResultsPath $scanFile -Apply -MaxItems 10 | Out-Null
                        Write-RepairLog "Level 4: Bug items created from SIN scan"
                    } catch {
                        Write-RepairLog "Level 4 bug creation failed: $_" 'WARN'
                    }
                }
            }
        }

        # Emit rollback recommendation
        $rollbackRec = [ordered]@{
            timestamp      = (Get-Date).ToString('o')
            gate           = $gateName
            detail         = $gate.detail
            recommendation = 'Consider rollback: all auto-remediation levels exhausted. Review Invoke-WorkspaceRollback.ps1.'
            rollbackScript = 'scripts/Invoke-WorkspaceRollback.ps1'
            logsDir        = $integrityLogDir
        }
        $recFile = Join-Path $integrityLogDir ("rollback-rec-$gateName-" + (Get-Date -Format 'yyyyMMddHHmmss') + '.json')
        if (-not $DryRun) {
            $rollbackRec | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recFile -Encoding UTF8
        }
        Write-RepairLog "Rollback recommendation written: $recFile" 'WARN'
        [void]$events.Add((Add-RepairEvent -Gate $gateName -Level 'L4-BugAndRollback' -Action 'recommended' -Resolved $false -Detail "rec=$recFile"))
    }
}

# ── Final report ──────────────────────────────────────────────────────────────

$reportOut = [ordered]@{
    schema       = 'PipelineAutoRepair/1.0'
    versionTag   = '2605.B5.V46.1'
    generatedAt  = (Get-Date).ToString('o')
    dryRun       = [bool]$DryRun
    gatesChecked = 3
    gatesFailing = @($gates.Keys)
    events       = @($events)
    repairLog    = @($repairLog)
}

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir  = Join-Path $WorkspacePath '~REPORTS'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
$outFile = Join-Path $outDir "pipeline-autorepair-$stamp.json"
if (-not $DryRun) {
    $reportOut | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding UTF8
}
Write-RepairLog "AutoRepair complete. Events: $(@($events).Count)  Report: $outFile"

return [PSCustomObject]$reportOut

<# Outline:
    Detects failing pipeline gates, escalates through auto-remediation layers,
    and creates BUG items when all automated remediation paths are exhausted.
    Safe to run repeatedly — all remediations are idempotent.
#>

<# Objectives-Review:
    Goal: reduce manual intervention needed after pipeline gate failures.
    Future: integrate with CronAiAthon event log for automated trigger on
    Run-FullPipeline.ps1 non-zero exit.
#>

<# Problems:
    Level 1 AutoRemediate requires -Confirm:$false to avoid interactive prompts in CI.
    Level 3 Interop-drift does not fix LAUNCHBAT or no-candidate RELPATH findings.
#>
