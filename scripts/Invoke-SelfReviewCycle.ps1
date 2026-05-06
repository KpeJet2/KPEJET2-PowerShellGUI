#Requires -Version 5.1
<#
.SYNOPSIS
    Self-Review Cycle Engine -- evaluates workspace health across 8 dimensions.
.DESCRIPTION
    Scores each dimension 0.0-1.0, computes a composite Workspace Health Score,
    generates feedback pipeline items for low-scoring areas, tracks improvement
    trends, and proposes config tuning suggestions based on metric history.

    Dimensions:
      1  SINCompliance    -- RESOLVED/total SIN ratio; open CRITICAL count
      2  PipelineVelocity -- closed/created ratio; backlog age
      3  ErrorRate        -- scheduler error/cycle ratio
      4  CodeStyle        -- SemiSin penance count; Write-Host in modules
      5  FormatCongruency -- VersionTag freshness; encoding compliance
      6  DocFreshness     -- stale docs ratio from DocFreshness reports
      7  TestCoverage     -- smoke test pass rate; deep-test parse failures
      8  KernelHealth     -- CycleManager divergence; Watchdog alert count

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Defaults to parent of $PSScriptRoot.
.PARAMETER QuickMode
    Run only the dimensions listed in config quickMode.dimensions (fast, <5s).
.PARAMETER DryRun
    Compute scores and report but do not write pipeline items or update history.
.NOTES
    Author    : The Establishment
    VersionTag: 2604.B1.v1.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [switch]$QuickMode,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not $WorkspacePath) { $WorkspacePath = Split-Path -Parent $PSScriptRoot }
$script:Root      = $WorkspacePath
$script:CfgPath   = Join-Path (Join-Path $script:Root 'config') 'self-review-config.json'
$script:HistPath  = Join-Path (Join-Path $script:Root 'config') 'self-review-history.json'
$script:LogDir    = Join-Path $script:Root 'logs'
$script:LogFile   = Join-Path $script:LogDir 'self-review.log'
$script:ReportDir = Join-Path (Join-Path $script:Root '~REPORTS') 'SelfReview'
$script:RunStart  = Get-Date

# ── Logging ────────────────────────────────────────────────────────────────
function Write-SRLog {
    param([string]$Message, [string]$Level = 'Info')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    Write-Verbose $line
}

# ── Load config ─────────────────────────────────────────────────────────────
function Get-SelfReviewConfig {
    if (-not (Test-Path $script:CfgPath)) {
        Write-SRLog 'self-review-config.json not found -- using built-in defaults' 'Warning'
        return $null
    }
    try {
        $raw = Get-Content -Path $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $raw
    } catch {
        Write-SRLog "Config parse error: $_" 'Warning'
        return $null
    }
}

function Get-DimensionCfg {
    param([object]$Cfg, [string]$Name)
    $defaults = @{ enabled = $true; weight = 0.125; alertOnDrop = $false; escalateBelow = 0.4 }
    if ($null -eq $Cfg -or $null -eq $Cfg.dimensions) { return $defaults }
    $d = $Cfg.dimensions.PSObject.Properties | Where-Object { $_.Name -eq $Name }
    if ($null -eq $d) { return $defaults }
    $v = $d.Value
    return @{
        enabled       = if ($null -ne $v.enabled)       { [bool]$v.enabled       } else { $true }
        weight        = if ($null -ne $v.weight)         { [double]$v.weight      } else { 0.125 }
        alertOnDrop   = if ($null -ne $v.alertOnDrop)    { [bool]$v.alertOnDrop   } else { $false }
        escalateBelow = if ($null -ne $v.escalateBelow)  { [double]$v.escalateBelow } else { 0.4 }
    }
}

function Get-Threshold {
    param([object]$Cfg, [string]$Key, [double]$Default)
    if ($null -eq $Cfg -or $null -eq $Cfg.thresholds) { return $Default }
    $p = $Cfg.thresholds.PSObject.Properties | Where-Object { $_.Name -eq $Key }
    if ($null -eq $p) { return $Default }
    return [double]$p.Value
}

# ── Validate weights sum to 1.0 ─────────────────────────────────────────────
function Get-ValidatedWeights {
    param([object]$Cfg)
    $names    = @('SINCompliance','PipelineVelocity','ErrorRate','CodeStyle','FormatCongruency','DocFreshness','TestCoverage','KernelHealth')
    $weights  = @{}
    $total    = 0.0
    foreach ($n in $names) {
        $d = Get-DimensionCfg -Cfg $Cfg -Name $n
        $w = if ($d.enabled) { $d.weight } else { 0.0 }
        $weights[$n] = $w
        $total += $w
    }
    # Normalise if not 1.0 (tolerates float rounding)
    if ($total -gt 0 -and [math]::Abs($total - 1.0) -gt 0.01) {
        Write-SRLog "Weights sum to $total -- normalising to 1.0" 'Warning'
        foreach ($n in $names) { $weights[$n] = if ($total -gt 0) { $weights[$n] / $total } else { 0.0 } }
    }
    return $weights
}

# ── History helpers ─────────────────────────────────────────────────────────
function Get-ReviewHistory {
    if (-not (Test-Path $script:HistPath)) { return @() }
    try {
        $raw = Get-Content -Path $script:HistPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($raw.runs)
    } catch { return @() }
}

function Save-ReviewHistory {
    param([array]$Runs)
    $obj = [ordered]@{
        meta = [ordered]@{ schema = 'SelfReviewHistory/1.0'; updated = (Get-Date).ToUniversalTime().ToString('o') }
        runs = $Runs
    }
    $json = $obj | ConvertTo-Json -Depth 8
    Set-Content -Path $script:HistPath -Value $json -Encoding UTF8
}

# ════════════════════════════════════════════════════════════════════════════
# DIMENSION SCORERS
# ════════════════════════════════════════════════════════════════════════════

function Get-SINComplianceScore {
    $sinDir  = Join-Path $script:Root 'sin_registry'
    $detail  = 'SIN registry not found'
    $score   = 0.5
    if (-not (Test-Path $sinDir)) { return @{ score = $score; detail = $detail; refinement = 'Create sin_registry/ folder and populate SIN definitions.' } }

    $instances = @(Get-ChildItem -Path $sinDir -Filter 'SIN-2*.json' -File -ErrorAction SilentlyContinue)
    $total     = @($instances).Count
    if ($total -eq 0) { return @{ score = 1.0; detail = 'No SIN instances on record.'; refinement = '' } }

    $resolved  = 0
    $critical  = 0
    foreach ($f in $instances) {
        try {
            $item = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $rt   = $item.remedy_tracking
            if ($null -ne $rt) {
                $st = [string]$rt.status
                if ($st -eq 'RESOLVED') { $resolved++ }
            }
            if ($item.severity -eq 'CRITICAL' -and ([string]$rt.status) -ne 'RESOLVED') { $critical++ }
        } catch { <# Intentional: non-fatal per-file parse skip #> }
    }

    $resolvedRatio = if ($total -gt 0) { $resolved / $total } else { 0.0 }
    $critPenalty   = [math]::Min(0.3, $critical * 0.05)
    $score         = [math]::Max(0.0, [math]::Round($resolvedRatio - $critPenalty, 3))
    $detail        = "$resolved/$total resolved; $critical open CRITICAL"
    $refinement    = if ($score -lt 0.6) { "Run scripts\Invoke-SINRemedyEngine.ps1 to process $($total - $resolved) pending SIN instances." } else { '' }

    return @{ score = $score; detail = $detail; refinement = $refinement }
}

function Get-PipelineVelocityScore {
    $pipeMod = Join-Path (Join-Path $script:Root 'modules') 'CronAiAthon-Pipeline.psm1'
    if (-not (Test-Path $pipeMod)) { return @{ score = 0.5; detail = 'Pipeline module not found.'; refinement = '' } }

    try {
        Import-Module $pipeMod -Force -ErrorAction Stop
        $metrics       = Get-PipelineHealthMetrics -WorkspacePath $script:Root
        $interruptions = Get-PipelineInterruptions  -WorkspacePath $script:Root

        $createdPerDay    = if ($null -ne $metrics -and $metrics.PSObject.Properties.Name -contains 'createdPerDay')  { [double]$metrics.createdPerDay  } else { 1.0 }
        $closedPerDay     = if ($null -ne $metrics -and $metrics.PSObject.Properties.Name -contains 'closedPerDay')   { [double]$metrics.closedPerDay   } else { 0.0 }
        $staleCount       = if ($null -ne $interruptions -and $interruptions.PSObject.Properties.Name -contains 'total') { [int]$interruptions.total } else { 0 }

        $velocityRatio    = if ($createdPerDay -gt 0) { [math]::Min(1.0, $closedPerDay / $createdPerDay) } else { 1.0 }
        $stalePenalty     = [math]::Min(0.4, $staleCount * 0.02)
        $score            = [math]::Max(0.0, [math]::Round($velocityRatio - $stalePenalty, 3))
        $detail           = "Velocity $([math]::Round($closedPerDay,2))/day closed vs $([math]::Round($createdPerDay,2))/day created; $staleCount stale items"
        $refinement       = if ($staleCount -gt 0) { "Triage $staleCount stale pipeline items older than threshold (OPEN>14d, IN_PROGRESS>3d)." } else { '' }

        return @{ score = $score; detail = $detail; refinement = $refinement }
    } catch {
        Write-SRLog "PipelineVelocity scorer error: $_" 'Warning'
        return @{ score = 0.5; detail = "Pipeline metrics unavailable: $_"; refinement = '' }
    }
}

function Get-ErrorRateScore {
    $schedPath = Join-Path (Join-Path $script:Root 'config') 'cron-aiathon-schedule.json'
    if (-not (Test-Path $schedPath)) { return @{ score = 0.5; detail = 'Schedule config not found.'; refinement = '' } }
    try {
        $sched       = Get-Content -Path $schedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stats       = $sched.jobStatistics
        $totalCycles = if ($null -ne $stats -and $stats.PSObject.Properties.Name -contains 'totalCycles') { [int]$stats.totalCycles } else { 0 }
        $totalErrors = if ($null -ne $stats -and $stats.PSObject.Properties.Name -contains 'totalErrors') { [int]$stats.totalErrors } else { 0 }
        $lastError   = if ($null -ne $stats -and $stats.PSObject.Properties.Name -contains 'lastErrorMessage') { [string]$stats.lastErrorMessage } else { '' }

        $errorRate   = if ($totalCycles -gt 0) { $totalErrors / $totalCycles } else { 0.0 }
        $score       = [math]::Max(0.0, [math]::Round(1.0 - ($errorRate * 3), 3))  # 33% error rate → 0.0
        $detail      = "$totalErrors errors in $totalCycles cycles ($([math]::Round($errorRate * 100, 1))%)"
        if ($lastError) { $detail += "; last: $($lastError.Substring(0, [math]::Min(80, $lastError.Length)))" }
        $refinement  = if ($score -lt 0.6 -and $lastError) { "Review last error: $lastError" } else { '' }

        return @{ score = $score; detail = $detail; refinement = $refinement }
    } catch {
        Write-SRLog "ErrorRate scorer error: $_" 'Warning'
        return @{ score = 0.5; detail = "Schedule stats unavailable: $_"; refinement = '' }
    }
}

function Get-CodeStyleScore {
    $modDir    = Join-Path $script:Root 'modules'
    $writeHost = 0
    $missingCB = 0
    $totalFns  = 0

    if (Test-Path $modDir) {
        $psFiles  = @(Get-ChildItem -Path $modDir -Filter '*.psm1' -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $psFiles) {
            try {
                $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8
                $writeHost += ([regex]::Matches($content, '(?m)^\s*Write-Host\b')).Count
                $fnMatches = [regex]::Matches($content, '(?m)^function\s+\S+')
                $totalFns  += $fnMatches.Count
                # Simple heuristic: functions without CmdletBinding in next 3 lines
                foreach ($m in $fnMatches) {
                    $startIdx = $m.Index
                    $snippet  = $content.Substring($startIdx, [math]::Min(200, $content.Length - $startIdx))
                    if ($snippet -notmatch '\[CmdletBinding\(\)\]') { $missingCB++ }
                }
            } catch { <# Intentional: non-fatal per-file parse skip #> }
        }
    }

    $whPenalty = [math]::Min(0.3, $writeHost * 0.01)
    $cbPenalty = if ($totalFns -gt 0) { [math]::Min(0.3, ($missingCB / $totalFns) * 0.5) } else { 0.0 }
    $score     = [math]::Max(0.0, [math]::Round(1.0 - $whPenalty - $cbPenalty, 3))
    $detail    = "Write-Host occurrences in modules: $writeHost; functions missing [CmdletBinding()]: $missingCB/$totalFns"
    $refinement = if ($missingCB -gt 0) { "$missingCB functions missing [CmdletBinding()] in modules/ -- add to gain -Verbose/-WhatIf support." } else { '' }

    return @{ score = $score; detail = $detail; refinement = $refinement }
}

function Get-FormatCongruencyScore {
    $staleTags = 0
    $totalScanned = 0
    $cutoff = (Get-Date).AddDays(-30)
    $searchDirs = @(
        Join-Path $script:Root 'modules'
        Join-Path $script:Root 'scripts'
    )
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $files = @(Get-ChildItem -Path $dir -Include '*.ps1','*.psm1' -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $totalScanned++
            if ($f.LastWriteTime -lt $cutoff) {
                try {
                    $head = Get-Content -Path $f.FullName -TotalCount 10 -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not ($head -match 'VersionTag:')) { $staleTags++ }
                } catch { <# Intentional: non-fatal #> }
            }
        }
    }

    $staleRatio = if ($totalScanned -gt 0) { $staleTags / $totalScanned } else { 0.0 }
    $score      = [math]::Max(0.0, [math]::Round(1.0 - ($staleRatio * 2), 3))
    $detail     = "$staleTags/$totalScanned scripts with stale/missing VersionTag (last write >30d)"
    $refinement = if ($staleTags -gt 0) { "$staleTags files have stale or missing VersionTag headers in modules/ or scripts/." } else { '' }

    return @{ score = $score; detail = $detail; refinement = $refinement }
}

function Get-DocFreshnessScore {
    $freshDir = Join-Path (Join-Path $script:Root '~REPORTS') 'DocFreshness'
    if (-not (Test-Path $freshDir)) { return @{ score = 0.7; detail = 'No DocFreshness reports found -- assuming OK.'; refinement = '' } }

    try {
        $reports = @(Get-ChildItem -Path $freshDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if (@($reports).Count -eq 0) { return @{ score = 0.7; detail = 'No DocFreshness report files.'; refinement = '' } }

        $latest  = Get-Content -Path $reports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $stale   = @($latest).Count   # report is array of stale files
        $docDir  = Join-Path $script:Root '~README.md'
        $total   = if (Test-Path $docDir) { @(Get-ChildItem -Path $docDir -Filter '*.md' -File -ErrorAction SilentlyContinue).Count } else { 1 }

        $staleRatio = if ($total -gt 0) { $stale / $total } else { 0.0 }
        $score      = [math]::Max(0.0, [math]::Round(1.0 - ($staleRatio * 1.5), 3))
        $detail     = "$stale/$total docs stale (report: $($reports[0].Name))"
        $refinement = if ($stale -gt 0) { "$stale documentation files need refresh -- run DocRebuild cron task to regenerate auto-docs." } else { '' }

        return @{ score = $score; detail = $detail; refinement = $refinement }
    } catch {
        Write-SRLog "DocFreshness scorer error: $_" 'Warning'
        return @{ score = 0.7; detail = "DocFreshness report unreadable: $_"; refinement = '' }
    }
}

function Get-TestCoverageScore {
    $smokeDir = Join-Path (Join-Path $script:Root '~REPORTS') 'SmokeTest'
    $bugDir   = Join-Path (Join-Path $script:Root '~REPORTS') 'BugScan'
    $score    = 0.8
    $detail   = 'No test reports found -- assuming baseline.'
    $refinement = ''

    try {
        # Check most recent smoke test report
        if (Test-Path $smokeDir) {
            $latest = @(Get-ChildItem -Path $smokeDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if (@($latest).Count -gt 0) {
                $rpt  = Get-Content -Path $latest[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $pass = if ($rpt.PSObject.Properties.Name -contains 'passed') { [int]$rpt.passed } else { 0 }
                $fail = if ($rpt.PSObject.Properties.Name -contains 'failed') { [int]$rpt.failed } else { 0 }
                $tot  = $pass + $fail
                $score  = if ($tot -gt 0) { [math]::Round($pass / $tot, 3) } else { 0.8 }
                $detail = "Smoke test: $pass/$tot passed"
                if ($fail -gt 0) { $refinement = "Smoke test failure rate $fail/$tot -- review tests\Invoke-GUISmokeTest.ps1 matrix." }
            }
        }
    } catch { <# Intentional: non-fatal smoke report read skip #> }

    # Parse failure penalty from BugScan reports (look for ParseError type bugs)
    try {
        if (Test-Path $bugDir) {
            $latest = @(Get-ChildItem -Path $bugDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if (@($latest).Count -gt 0) {
                $rpt = Get-Content -Path $latest[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $parseErrs = @($rpt | Where-Object { $_.PSObject.Properties.Name -contains 'type' -and $_.type -like '*parse*' }).Count
                if ($parseErrs -gt 0) {
                    $score = [math]::Max(0.0, $score - ($parseErrs * 0.02))
                    $detail += "; $parseErrs parse errors in last BugScan"
                }
            }
        }
    } catch { <# Intentional: non-fatal bug report read skip #> }

    return @{ score = $score; detail = $detail; refinement = $refinement }
}

function Get-KernelHealthScore {
    $kernelRoot = Join-Path $script:Root 'sovereign-kernel'
    if (-not (Test-Path $kernelRoot)) { return @{ score = 0.7; detail = 'sovereign-kernel/ not found -- skipping.'; refinement = '' } }

    $score      = 1.0
    $issues     = @()

    # Check cycle history for divergence
    $cycleHist = Join-Path $kernelRoot 'cycle-history.json'
    if (Test-Path $cycleHist) {
        try {
            $hist  = Get-Content -Path $cycleHist -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($hist)
            # More than 2 rollbacks in last 10 entries is a warning
            $recent   = if (@($items).Count -gt 10) { @($items)[-10..-1] } else { @($items) }
            $rollbacks = @($recent | Where-Object { $_.PSObject.Properties.Name -contains 'action' -and $_.action -eq 'CYCLE_ROLLBACK' }).Count
            if ($rollbacks -gt 2) {
                $issues   += "Kernel has $rollbacks rollbacks in recent history"
                $score    -= 0.2
            }
        } catch { <# Intentional: non-fatal history read #> }
    }

    # Check for degraded mode flag
    $degradedFlag = Join-Path $kernelRoot 'degraded-mode.flag'
    if (Test-Path $degradedFlag) {
        $issues += 'Kernel is in degraded mode'
        $score  -= 0.3
    }

    # Check latest watchdog ledger for unresolved alerts (presence of HALT events)
    $ledgerDir = Join-Path $kernelRoot 'ledger'
    if (Test-Path $ledgerDir) {
        try {
            $replicas = @(Get-ChildItem -Path $ledgerDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
            if (@($replicas).Count -gt 0) {
                $entries = @(Get-ChildItem -Path $replicas[0].FullName -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 20)
                $haltCount = 0
                foreach ($e in $entries) {
                    try {
                        $raw = Get-Content -Path $e.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        $evType = if ($raw.PSObject.Properties.Name -contains 'event_type') { [string]$raw.event_type } else { '' }
                        if ($evType -eq 'HALT') { $haltCount++ }
                    } catch { <# Intentional: non-fatal per-entry read skip #> }
                }
                if ($haltCount -gt 0) {
                    $issues += "$haltCount HALT event(s) in recent ledger"
                    $score  -= ($haltCount * 0.1)
                }
            }
        } catch { <# Intentional: non-fatal ledger read #> }
    }

    $score      = [math]::Max(0.0, [math]::Round($score, 3))
    $detail     = if (@($issues).Count -gt 0) { $issues -join '; ' } else { 'Kernel healthy -- no rollbacks, degraded mode, or recent HALT events.' }
    $refinement = if ($score -lt 0.7) { 'Kernel drift detected -- check cycle-history.json, run Invoke-HealCycle, or review watchdog ledger.' } else { '' }

    return @{ score = $score; detail = $detail; refinement = $refinement }
}

# ════════════════════════════════════════════════════════════════════════════
# TREND + FEEDBACK
# ════════════════════════════════════════════════════════════════════════════

function Get-TrendAnalysis {
    param([array]$History, [hashtable]$CurrentScores, [object]$Cfg)
    $window      = [int](Get-Threshold -Cfg $Cfg -Key 'trendWindow' -Default 5)
    $dropFrac    = Get-Threshold -Cfg $Cfg -Key 'dropAlertFraction'  -Default 0.10
    $improveFrac = Get-Threshold -Cfg $Cfg -Key 'improvementFraction' -Default 0.15

    $drops        = @()
    $improvements = @()

    if (@($History).Count -lt 2) { return @{ drops = $drops; improvements = $improvements } }

    $recent = if (@($History).Count -gt $window) { @($History)[-$window..-1] } else { @($History) }

    foreach ($dim in $CurrentScores.Keys) {
        $prevScores = @($recent | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'dimensions') {
                $d = $_.dimensions.PSObject.Properties | Where-Object { $_.Name -eq $dim }
                if ($null -ne $d) { [double]$d.Value.score } else { $null }
            }
        } | Where-Object { $null -ne $_ })

        if (@($prevScores).Count -eq 0) { continue }

        $prevAvg  = ($prevScores | Measure-Object -Average).Average
        $curr     = [double]$CurrentScores[$dim].score

        if ($prevAvg -gt 0 -and ($prevAvg - $curr) / $prevAvg -ge $dropFrac) {
            $drops += @{ dimension = $dim; previous = [math]::Round($prevAvg,3); current = [math]::Round($curr,3); drop = [math]::Round($prevAvg - $curr, 3) }
        }
        if ($prevAvg -gt 0 -and ($curr - $prevAvg) / $prevAvg -ge $improveFrac) {
            $improvements += @{ dimension = $dim; previous = [math]::Round($prevAvg,3); current = [math]::Round($curr,3); gain = [math]::Round($curr - $prevAvg,3) }
        }
    }

    return @{ drops = $drops; improvements = $improvements }
}

function Add-FeedbackItems {
    param(
        [hashtable]$DimScores,
        [hashtable]$Trend,
        [object]$Cfg,
        [string]$RunId
    )
    if ($DryRun) { return @() }

    $pipeMod = Join-Path (Join-Path $script:Root 'modules') 'CronAiAthon-Pipeline.psm1'
    if (-not (Test-Path $pipeMod)) { return @() }

    try {
        Import-Module $pipeMod -Force -ErrorAction Stop
    } catch {
        Write-SRLog "Pipeline module unavailable for feedback: $_" 'Warning'
        return @()
    }

    $escalThreshold = Get-Threshold -Cfg $Cfg -Key 'escalationThreshold' -Default 0.5
    $created        = @()

    # Load existing open items for dedup
    $existingTitles = @()
    try {
        $open = @(Get-PipelineItems -WorkspacePath $script:Root | Where-Object { $_.status -eq 'OPEN' })
        $existingTitles = @($open | ForEach-Object { [string]$_.title })
    } catch { <# Intentional: non-fatal dedup skip #> }

    foreach ($dim in $DimScores.Keys) {
        $ds       = $DimScores[$dim]
        $dimCfg   = Get-DimensionCfg -Cfg $Cfg -Name $dim
        $score    = [double]$ds.score
        $isBugDim = @($Trend.drops | Where-Object { $_.dimension -eq $dim })
        $isEscalate = ($score -lt $escalThreshold)

        if (($dimCfg.alertOnDrop -and @($isBugDim).Count -gt 0) -or $isEscalate) {
            $title = "[SelfReview] $dim score $score"
            if ($existingTitles -contains $title) { continue }  # dedup

            $priority = if ($isEscalate) { 'HIGH' } else { 'MEDIUM' }
            $type     = if ($isEscalate) { 'BUG' } else { 'Items2ADD' }
            $ref      = [string]$ds.refinement

            try {
                $item = New-PipelineItem -Title $title -Priority $priority -Type $type `
                    -Description "$($ds.detail). Refinement: $ref" -WorkspacePath $script:Root
                Add-PipelineItem -Item $item -WorkspacePath $script:Root | Out-Null
                $created += $title
                Write-SRLog "  Feedback item created: $title ($type/$priority)"
            } catch {
                Write-SRLog "  Failed to create feedback item for $dim`: $_" 'Warning'
            }
        }
    }

    # Positive reinforcement items
    foreach ($imp in @($Trend.improvements)) {
        $title = "[SelfReview] Improvement: $($imp.dimension) +$($imp.gain)"
        if ($existingTitles -notcontains $title) {
            try {
                $item = New-PipelineItem -Title $title -Priority 'LOW' -Type 'Items2ADD' `
                    -Description "Dimension $($imp.dimension) improved from $($imp.previous) to $($imp.current) (+$($imp.gain))." `
                    -WorkspacePath $script:Root
                Add-PipelineItem -Item $item -WorkspacePath $script:Root | Out-Null
                Write-SRLog "  Reinforcement item: $title"
            } catch { <# Intentional: non-fatal positive reinforcement skip #> }
        }
    }

    return $created
}

# ════════════════════════════════════════════════════════════════════════════
# CONFIG SUGGESTION ANALYSIS
# ════════════════════════════════════════════════════════════════════════════

function Invoke-ConfigSuggestionAnalysis {
    param([array]$History, [double]$CompositeScore, [double]$ElapsedSeconds, [object]$Cfg)

    if ($null -eq $Cfg -or -not $Cfg.suggestions.enabled) { return }
    if (@($History).Count -lt 2) { return }  # need at least 2 runs

    $minRebalance  = if ($null -ne $Cfg.suggestions.minRunsForWeightRebalance)  { [int]$Cfg.suggestions.minRunsForWeightRebalance  } else { 5 }
    $minTighten    = if ($null -ne $Cfg.suggestions.minRunsForThresholdTighten) { [int]$Cfg.suggestions.minRunsForThresholdTighten } else { 10 }
    $minDisable    = if ($null -ne $Cfg.suggestions.minRunsForDimensionDisable) { [int]$Cfg.suggestions.minRunsForDimensionDisable } else { 20 }
    $suppressDays  = if ($null -ne $Cfg.suggestions.suppressRejectedForDays)    { [int]$Cfg.suggestions.suppressRejectedForDays    } else { 30 }
    $runCount      = @($History).Count

    # Load existing suggested_overrides (avoid duplicating PENDING suggestions)
    $existingOverrides = @($Cfg.suggested_overrides)
    $newSuggestions    = [System.Collections.ArrayList]::new()

    # Helper: check if suggestion already pending
    $hasPending = {
        param([string]$Field)
        @($existingOverrides | Where-Object {
            $_.PSObject.Properties.Name -contains 'field' -and $_.field -eq $Field -and
            $_.PSObject.Properties.Name -contains 'status' -and $_.status -eq 'PENDING'
        }).Count -gt 0
    }

    # ── 1. Weight rebalancing (needs trendWindow runs) ──────────────────────
    if ($runCount -ge $minRebalance) {
        $window  = [int](Get-Threshold -Cfg $Cfg -Key 'trendWindow' -Default 5)
        $recent  = if ($runCount -gt $window) { @($History)[-$window..-1] } else { @($History) }
        $dimNames = @('SINCompliance','PipelineVelocity','ErrorRate','CodeStyle','FormatCongruency','DocFreshness','TestCoverage','KernelHealth')
        foreach ($dim in $dimNames) {
            $scores = @($recent | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'dimensions') {
                    $d = $_.dimensions.PSObject.Properties | Where-Object { $_.Name -eq $dim }
                    if ($null -ne $d) { [double]$d.Value.score } else { $null }
                }
            } | Where-Object { $null -ne $_ })

            if (@($scores).Count -lt 2) { continue }
            $avg    = ($scores | Measure-Object -Average).Average
            $sq     = ($scores | ForEach-Object { [math]::Pow($_ - $avg, 2) } | Measure-Object -Sum).Sum
            $stddev = [math]::Sqrt($sq / @($scores).Count)
            $dimCfg = Get-DimensionCfg -Cfg $Cfg -Name $dim

            $field = "dimensions.$dim.weight"
            if (-not (& $hasPending $field)) {
                if ($stddev -gt 0.15 -and $dimCfg.weight -lt 0.20) {
                    $suggested = [math]::Round([math]::Min(0.25, $dimCfg.weight + 0.05), 2)
                    [void]$newSuggestions.Add([ordered]@{
                        id             = "SRSUG-$(Get-Date -Format 'yyyyMMddHHmmss')-$dim"
                        field          = $field
                        currentValue   = $dimCfg.weight
                        suggestedValue = $suggested
                        reason         = "$dim has high score variance (stddev=$([math]::Round($stddev,3))) suggesting it needs more monitoring weight."
                        basedOnRuns    = @($scores).Count
                        confidence     = if ($stddev -gt 0.25) { 'HIGH' } else { 'MEDIUM' }
                        status         = 'PENDING'
                        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
                    })
                } elseif ($stddev -lt 0.05 -and $dimCfg.weight -gt 0.15) {
                    $suggested = [math]::Round([math]::Max(0.05, $dimCfg.weight - 0.03), 2)
                    [void]$newSuggestions.Add([ordered]@{
                        id             = "SRSUG-$(Get-Date -Format 'yyyyMMddHHmmss')-$dim-reduce"
                        field          = $field
                        currentValue   = $dimCfg.weight
                        suggestedValue = $suggested
                        reason         = "$dim is very stable (stddev=$([math]::Round($stddev,3))). Modest weight reduction frees capacity for volatile dimensions."
                        basedOnRuns    = @($scores).Count
                        confidence     = 'LOW'
                        status         = 'PENDING'
                        createdAt      = (Get-Date).ToUniversalTime().ToString('o')
                    })
                }
            }

            # Dimension disable suggestion
            if ($runCount -ge $minDisable -and $avg -ge 1.0 -and -not (& $hasPending "dimensions.$dim.enabled")) {
                [void]$newSuggestions.Add([ordered]@{
                    id             = "SRSUG-$(Get-Date -Format 'yyyyMMddHHmmss')-$dim-disable"
                    field          = "dimensions.$dim.enabled"
                    currentValue   = $true
                    suggestedValue = $false
                    reason         = "$dim has scored 1.0 for $runCount consecutive runs. Disabling it reduces overhead without losing signal."
                    basedOnRuns    = $runCount
                    confidence     = 'HIGH'
                    status         = 'PENDING'
                    createdAt      = (Get-Date).ToUniversalTime().ToString('o')
                })
            }
        }
    }

    # ── 2. Threshold tightening ─────────────────────────────────────────────
    if ($runCount -ge $minTighten -and -not (& $hasPending 'thresholds.blockingThreshold')) {
        $recentN       = if ($runCount -gt $minTighten) { @($History)[-$minTighten..-1] } else { @($History) }
        $recentScores  = @($recentN | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'compositeScore') { [double]$_.compositeScore } else { $null }
        } | Where-Object { $null -ne $_ })
        if (@($recentScores).Count -ge $minTighten) {
            $allHighRange = @($recentScores | Where-Object { $_ -ge 0.75 -and $_ -le 0.85 }).Count -eq @($recentScores).Count
            if ($allHighRange) {
                $current   = Get-Threshold -Cfg $Cfg -Key 'blockingThreshold' -Default 0.6
                $suggested = [math]::Round($current + 0.05, 2)
                [void]$newSuggestions.Add([ordered]@{
                    id             = "SRSUG-$(Get-Date -Format 'yyyyMMddHHmmss')-threshold-tighten"
                    field          = 'thresholds.blockingThreshold'
                    currentValue   = $current
                    suggestedValue = $suggested
                    reason         = "Composite score has been consistently in 0.75-0.85 band for $([math]::Round(@($recentScores).Count)) runs. Raising the blocking threshold tightens the quality gate."
                    basedOnRuns    = @($recentScores).Count
                    confidence     = 'MEDIUM'
                    status         = 'PENDING'
                    createdAt      = (Get-Date).ToUniversalTime().ToString('o')
                })
            }
        }
    }

    # ── 3. Frequency adjustment ─────────────────────────────────────────────
    if ($runCount -ge 3) {
        $recentElapsed = @($History[-3..-1] | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'runtimeSeconds') { [double]$_.runtimeSeconds } else { $null }
        } | Where-Object { $null -ne $_ })

        if (@($recentElapsed).Count -ge 2) {
            $avgElapsed = ($recentElapsed | Measure-Object -Average).Average
            $currentFreq = if ($null -ne $Cfg.fullFrequencyMinutes) { [int]$Cfg.fullFrequencyMinutes } else { 360 }

            if ($avgElapsed -lt 30 -and $currentFreq -gt 180 -and -not (& $hasPending 'fullFrequencyMinutes')) {
                [void]$newSuggestions.Add([ordered]@{
                    id             = "SRSUG-$(Get-Date -Format 'yyyyMMddHHmmss')-freq-reduce"
                    field          = 'fullFrequencyMinutes'
                    currentValue   = $currentFreq
                    suggestedValue = [math]::Max(120, $currentFreq - 60)
                    reason         = "Engine consistently completes in ~$([math]::Round($avgElapsed,0))s. Reducing frequency saves scheduler overhead."
                    basedOnRuns    = @($recentElapsed).Count
                    confidence     = 'LOW'
                    status         = 'PENDING'
                    createdAt      = (Get-Date).ToUniversalTime().ToString('o')
                })
            }
        }
    }

    if (@($newSuggestions).Count -eq 0) { return }
    if ($DryRun) {
        Write-SRLog "  [DRY-RUN] $(@($newSuggestions).Count) config suggestion(s) would be written."
        return
    }

    # Persist new suggestions into config file
    try {
        $cfgRaw  = Get-Content -Path $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $allOverrides = [System.Collections.ArrayList]::new()
        foreach ($o in @($cfgRaw.suggested_overrides)) { [void]$allOverrides.Add($o) }
        foreach ($s in @($newSuggestions))             { [void]$allOverrides.Add($s) }
        $cfgRaw.suggested_overrides = @($allOverrides)
        $cfgRaw | ConvertTo-Json -Depth 10 | Set-Content -Path $script:CfgPath -Encoding UTF8
        Write-SRLog "  Wrote $(@($newSuggestions).Count) new config suggestion(s) to self-review-config.json"
    } catch {
        Write-SRLog "Failed to persist config suggestions: $_" 'Warning'
    }
}

# ════════════════════════════════════════════════════════════════════════════
# ACCEPTED SUGGESTION MIGRATION
# ════════════════════════════════════════════════════════════════════════════

function Invoke-AcceptedSuggestionMigration {
    param([object]$Cfg)
    if ($DryRun -or $null -eq $Cfg) { return }

    $overrides = @($Cfg.suggested_overrides)
    $accepted  = @($overrides | Where-Object {
        $_.PSObject.Properties.Name -contains 'status' -and $_.status -eq 'ACCEPTED'
    })
    if (@($accepted).Count -eq 0) { return }

    $changed = $false
    foreach ($s in $accepted) {
        $field = [string]$s.field
        $val   = $s.suggestedValue
        try {
            # Only support top-level and 2-level field paths (e.g. thresholds.blockingThreshold)
            if ($field -match '^(\w+)\.(\w+)\.(\w+)$') {
                # 3-part: dimensions.SINCompliance.weight
                $top = $Matches[1]; $mid = $Matches[2]; $leaf = $Matches[3]
                if ($null -ne $Cfg.$top -and $null -ne $Cfg.$top.$mid) {
                    $Cfg.$top.$mid.$leaf = $val
                    $changed = $true
                }
            } elseif ($field -match '^(\w+)\.(\w+)$') {
                $top = $Matches[1]; $leaf = $Matches[2]
                if ($null -ne $Cfg.$top) {
                    $Cfg.$top.$leaf = $val
                    $changed = $true
                }
            } else {
                $Cfg.$field = $val
                $changed = $true
            }
            $s.status    = 'APPLIED'
            $s.appliedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-SRLog "  Config suggestion APPLIED: $field = $val"
        } catch {
            Write-SRLog "  Failed to apply suggestion '$field': $_" 'Warning'
        }
    }

    if ($changed) {
        try {
            $Cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $script:CfgPath -Encoding UTF8
        } catch {
            Write-SRLog "Failed to save migrated config: $_" 'Warning'
        }
    }
}

# ════════════════════════════════════════════════════════════════════════════
# MAIN CYCLE
# ════════════════════════════════════════════════════════════════════════════

Write-SRLog '=== Self-Review Cycle START ==='
$cfg     = Get-SelfReviewConfig
$weights = Get-ValidatedWeights -Cfg $cfg

# Apply any ACCEPTED suggestions before scoring
Invoke-AcceptedSuggestionMigration -Cfg $cfg

# Determine which dimensions to run
$allDims = @('SINCompliance','PipelineVelocity','ErrorRate','CodeStyle','FormatCongruency','DocFreshness','TestCoverage','KernelHealth')
if ($QuickMode -and $null -ne $cfg -and $null -ne $cfg.quickMode -and $cfg.quickMode.enabled) {
    $runDims = @($cfg.quickMode.dimensions)
} else {
    $runDims = $allDims
}

$dimScores = @{}
$scorers = @{
    SINCompliance    = { Get-SINComplianceScore    }
    PipelineVelocity = { Get-PipelineVelocityScore }
    ErrorRate        = { Get-ErrorRateScore        }
    CodeStyle        = { Get-CodeStyleScore        }
    FormatCongruency = { Get-FormatCongruencyScore }
    DocFreshness     = { Get-DocFreshnessScore     }
    TestCoverage     = { Get-TestCoverageScore     }
    KernelHealth     = { Get-KernelHealthScore     }
}

foreach ($dim in $runDims) {
    $dimCfg = Get-DimensionCfg -Cfg $cfg -Name $dim
    if (-not $dimCfg.enabled) {
        $dimScores[$dim] = @{ score = 1.0; detail = 'Disabled in config.'; refinement = '' }
        continue
    }
    Write-SRLog "  Scoring: $dim"
    try {
        $dimScores[$dim] = & $scorers[$dim]
    } catch {
        Write-SRLog "  Scorer failed for $dim`: $_" 'Warning'
        $dimScores[$dim] = @{ score = 0.5; detail = "Scorer error: $_"; refinement = '' }
    }
    Write-SRLog "  $dim = $($dimScores[$dim].score) | $($dimScores[$dim].detail)"
}

# For dimensions not run (quick mode), preserve from last history if available
$history = Get-ReviewHistory
foreach ($dim in $allDims) {
    if (-not $dimScores.ContainsKey($dim)) {
        if (@($history).Count -gt 0) {
            $lastRun = $history[-1]
            if ($null -ne $lastRun -and $lastRun.PSObject.Properties.Name -contains 'dimensions') {
                $prev = $lastRun.dimensions.PSObject.Properties | Where-Object { $_.Name -eq $dim }
                $dimScores[$dim] = if ($null -ne $prev) {
                    @{ score = [double]$prev.Value.score; detail = '(carried from last run)'; refinement = '' }
                } else {
                    @{ score = 0.5; detail = '(no prior data)'; refinement = '' }
                }
            } else {
                $dimScores[$dim] = @{ score = 0.5; detail = '(no prior data)'; refinement = '' }
            }
        } else {
            $dimScores[$dim] = @{ score = 0.5; detail = '(no prior data -- first run)'; refinement = '' }
        }
    }
}

# Weighted composite
$compositeScore = 0.0
foreach ($dim in $allDims) {
    $w = if ($weights.ContainsKey($dim)) { $weights[$dim] } else { 0.0 }
    $compositeScore += [double]$dimScores[$dim].score * $w
}
$compositeScore = [math]::Round($compositeScore, 4)

# Trend analysis
$trend   = Get-TrendAnalysis -History $history -CurrentScores $dimScores -Cfg $cfg
$elapsed = [math]::Round(((Get-Date) - $script:RunStart).TotalSeconds, 2)

Write-SRLog "  Composite score: $compositeScore | Drops: $(@($trend.drops).Count) | Improvements: $(@($trend.improvements).Count)"

# Feedback items into pipeline
$feedbackCreated = Add-FeedbackItems -DimScores $dimScores -Trend $trend -Cfg $cfg -RunId "SR-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Config suggestion analysis
Invoke-ConfigSuggestionAnalysis -History $history -CompositeScore $compositeScore -ElapsedSeconds $elapsed -Cfg $cfg

# Build run record
$dimSummary  = [ordered]@{}
foreach ($d in $allDims) {
    $dimSummary[$d] = [ordered]@{ score = $dimScores[$d].score; detail = $dimScores[$d].detail }
}

$runRecord = [ordered]@{
    runId          = "SR-$(Get-Date -Format 'yyyyMMddHHmmss')"
    timestamp      = (Get-Date).ToUniversalTime().ToString('o')
    mode           = if ($QuickMode) { 'quick' } else { 'full' }
    compositeScore = $compositeScore
    dimensions     = $dimSummary
    drops          = @($trend.drops)
    improvements   = @($trend.improvements)
    feedbackItems  = @($feedbackCreated)
    runtimeSeconds = $elapsed
    dryRun         = $DryRun.IsPresent
}

# Write report
if (-not (Test-Path $script:ReportDir)) { New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null }
$rptFile = Join-Path $script:ReportDir ("self-review-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmm'))
if (-not $DryRun) {
    $runRecord | ConvertTo-Json -Depth 8 | Set-Content -Path $rptFile -Encoding UTF8
}

# Update history (keep last 50 runs)
if (-not $DryRun) {
    $updatedHistory = @($history) + @($runRecord)
    if (@($updatedHistory).Count -gt 50) { $updatedHistory = @($updatedHistory[-50..-1]) }
    Save-ReviewHistory -Runs $updatedHistory
}

Write-SRLog "=== Self-Review Cycle END | Score: $compositeScore | Time: ${elapsed}s ==="

if ($DryRun) { Write-Host "[DRY-RUN] Self-Review: composite=$compositeScore drops=$(@($trend.drops).Count)" }

return $runRecord
