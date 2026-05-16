# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-01
# FileRole: Diagnostics
# Description: Scans all .ps1 and .psm1 files for central-config feature adoption.
#              Writes a JSON coverage report to ~REPORTS/ConfigCoverage/ and surfaces
#              SIN-class gaps as BUG pipeline items for downstream resolution.
#
# Usage:  .\Invoke-ConfigCoverageAudit.ps1 -WorkspacePath 'C:\PowerShellGUI'
#         Called automatically by CronAiAthon-Scheduler.psm1 task type ConfigCoverageAudit.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$WorkspacePath,

    [Parameter()]
    [switch]$PipelineItems,   # When set, surfaces top gaps into pipeline as BUG items

    [Parameter()]
    [switch]$Quiet             # Suppress host output (cron-friendly)
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── helpers ────────────────────────────────────────────────────────────────────
function Write-AuditLog {
    param([string]$Message, [string]$Severity = 'Informational')
    try {
        $logMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-EventLog.psm1'
        if (Test-Path $logMod) {
            try { Import-Module $logMod -Force -ErrorAction Stop } catch { Write-Warning "Failed to import log module: $_" }
            Write-CronLog -Message $Message -Severity $Severity -Source 'ConfigCoverageAudit'
        }
    } catch { <# Intentional: logging failure is non-fatal #> }
    if (-not $Quiet) { Write-Host "[ConfigCoverageAudit] $Message" }
}

# ── feature detection patterns ─────────────────────────────────────────────────
$features = [ordered]@{
    VersionTag         = '(?m)#\s*VersionTag\s*:\s*\d{4}\.\w+\.\w+'
    ErrorHandling      = '(?ms)try\s*\{.*?\}\s*catch'
    CmdletBinding      = '\[CmdletBinding'
    WorkspacePath      = '\$WorkspacePath'
    SINGovernance      = '(?i)sin[_-]pattern|sin.governance|Invoke-SIN|sin_registry'
    ModuleExport       = '
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember'
    CronLog            = 'Write-CronLog'
    CryptoThumbprint   = '(?i)thumbprint|Get-CertThumbprint|CryptoEngine'
    SecretsVault       = '(?i)Get-VaultItem|Set-VaultItem|vault'
    PipelineItem       = 'Add-PipelineItem|Get-PipelineItem'
    TodoRegistry       = '(?i)todo[_-]registry|\.todo\.json|New-TodoItem|Add-TodoItem'
    BugTracker         = '(?i)Invoke-FullBugScan|Add-BugItem|bug.tracker'
    ConvoVaultUsage    = '(?i)ConvoVault|Add-ConvoEntry|Get-ConvoEntries|Invoke-ConvoExchange'
    IntegrityCoreUsage = '(?i)IntegrityCore|Write-IntegrityLog|Test-IntegrityManifest'
    PipelineSteering   = '(?i)PipelineSteering|Invoke-PipelineStep|Step-Pipeline'
}

$excludeDirs = @('.git', '.history', '.venv', '__pycache__', 'node_modules', '~DOWNLOADS')

$files = Get-ChildItem -Path $WorkspacePath -Include '*.ps1','*.psm1' -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName -replace [regex]::Escape($WorkspacePath), ''
        $skip = $false
        foreach ($ex in $excludeDirs) {
            if ($rel -match [regex]::Escape($ex)) { $skip = $true; break }
        }
        -not $skip
    }

$totalFiles = @($files).Count
Write-AuditLog "Scanned $totalFiles script files"

# ── per-file analysis ──────────────────────────────────────────────────────────
$results = [System.Collections.ArrayList]::new()
$featureCounts = [ordered]@{}
foreach ($k in $features.Keys) { $featureCounts[$k] = 0 }  # SIN-EXEMPT:P027 -- index access, context-verified safe

# SIN-gap tracking (P002=empty-catch, P005=PS7-ops, P007=bad-versiontag, P015=hardcoded-path)
$sinGaps = [System.Collections.ArrayList]::new()

foreach ($file in $files) {
    try {
        $content   = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $fileFeatures = [ordered]@{}
        $adopted = 0
        foreach ($feat in $features.Keys) {
            $hit = $content -match $features[$feat]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $fileFeatures[$feat] = $hit  # SIN-EXEMPT:P027 -- index access, context-verified safe
            if ($hit) {
                $adopted++
                $featureCounts[$feat]++  # SIN-EXEMPT:P027 -- index access, context-verified safe
            }
        }

        $relPath = $file.FullName -replace [regex]::Escape($WorkspacePath + '\'), ''

        # Detect SIN violations
        $mySins = [System.Collections.ArrayList]::new()
        if ($content -match 'catch\s*\{\s*\}')                              { [void]$mySins.Add('P002-EmptyCatch') }
        if ($content -match '\?\?(?!=)|(?<!\?)\?\.')                         { [void]$mySins.Add('P005-PS7Operator') }
        if ($content -notmatch '(?m)#\s*VersionTag\s*:\s*\d{4}\.\w+\.\w+') { [void]$mySins.Add('P007-NoVersionTag') }
        if ($content -match 'C:\\PowerShellGUI')                             { [void]$mySins.Add('P015-HardcodedPath') }
        if ($content -match 'catch\s*\{[^}]*-ErrorAction\s+SilentlyContinue\s*\}'){ [void]$mySins.Add('P003-SilentImport') }

        foreach ($sin in $mySins) {
            [void]$sinGaps.Add([PSCustomObject]@{
                file = $relPath
                sin  = $sin
            })
        }

        [void]$results.Add([PSCustomObject]@{
            file         = $relPath
            adopted      = $adopted
            total        = @($features.Keys).Count
            pct          = [math]::Round(($adopted / @($features.Keys).Count) * 100, 1)
            features     = $fileFeatures
            sinGaps      = @($mySins)
        })
    } catch { <# Intentional: per-file failure is non-fatal #> }
}

# ── compute summary ────────────────────────────────────────────────────────────
$summary = [ordered]@{}
foreach ($k in $featureCounts.Keys) {
    $cnt = $featureCounts[$k]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $summary[$k] = [ordered]@{  # SIN-EXEMPT:P027 -- index access, context-verified safe
        count   = $cnt
        pctOfFiles = if ($totalFiles -gt 0) { [math]::Round(($cnt / $totalFiles) * 100, 1) } else { 0 }
    }
}

$avgAdoption = if (@($results).Count -gt 0) {
    [math]::Round((@($results | Measure-Object -Property pct -Average).Average), 1)
} else { 0 }

# ── top 20 least-covered files ─────────────────────────────────────────────────
$lowCoverage = @($results | Sort-Object pct | Select-Object -First 20)

# ── SIN gap breakdown ─────────────────────────────────────────────────────────
$sinBreakdown = @($sinGaps) | Group-Object sin | ForEach-Object {
    [PSCustomObject]@{ pattern = $_.Name; count = $_.Count }
} | Sort-Object count -Descending

# ── config-level checks (gap-2604-009) ────────────────────────────────────────
$configChecks = [System.Collections.ArrayList]::new()

# 1) Check cron schedule for required tasks
$schedulePath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-schedule.json'
if (Test-Path $schedulePath) {
    try {
        $sch = Get-Content $schedulePath -Raw | ConvertFrom-Json
        $schedTaskIds  = @($sch.tasks | Select-Object -ExpandProperty id)
        $schedTaskTypes= @($sch.tasks | Select-Object -ExpandProperty type)
        foreach ($reqType in @('FullSystemsScan','ConvoVaultExchange')) {
            $found = $schedTaskTypes -contains $reqType
            [void]$configChecks.Add([PSCustomObject]@{
                check  = "Schedule-$reqType"
                passed = $found
                detail = if ($found) { "Task type $reqType found in schedule" } else { "MISSING: No task of type $reqType in cron-aiathon-schedule.json" }
            })
            if (-not $found) {
                [void]$sinGaps.Add([PSCustomObject]@{
                    file = 'config/cron-aiathon-schedule.json'
                    sin  = "GAP-MissingScheduleTask-$reqType"
                })
            }
        }
    } catch { Write-AuditLog "Schedule config check failed: $($_.Exception.Message)" 'Warning' }
}

# 2) Check agentic-manifest.json includes ConvoVault and IntegrityCore
$manifestPath = Join-Path (Join-Path $WorkspacePath 'config') 'agentic-manifest.json'
if (Test-Path $manifestPath) {
    try {
        $mf = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $mfModules = @($mf.modules | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties.Name -contains 'name') { $_.name } })
        foreach ($reqMod in @('ConvoVault','IntegrityCore')) {
            $found = ($mfModules -match $reqMod).Count -gt 0
            [void]$configChecks.Add([PSCustomObject]@{
                check  = "AgenticManifest-$reqMod"
                passed = $found
                detail = if ($found) { "$reqMod present in agentic-manifest modules" } else { "MISSING: $reqMod not found in agentic-manifest.json modules" }
            })
            if (-not $found) {
                [void]$sinGaps.Add([PSCustomObject]@{
                    file = 'config/agentic-manifest.json'
                    sin  = "GAP-ManifestMissingModule-$reqMod"
                })
            }
        }
    } catch { Write-AuditLog "Agentic-manifest check failed: $($_.Exception.Message)" 'Warning' }
}

# 3) Check ConvoVault key presence
$cvKeyPath = Join-Path (Join-Path $WorkspacePath 'pki') 'convovault-master.key'
$cvKeyAlt  = Join-Path (Join-Path $WorkspacePath 'config') 'convovault.key'
$cvKeyPresent = (Test-Path $cvKeyPath) -or (Test-Path $cvKeyAlt)
[void]$configChecks.Add([PSCustomObject]@{
    check  = 'ConvoVaultKeyPresence'
    passed = $cvKeyPresent
    detail = if ($cvKeyPresent) { 'ConvoVault key found' } else { 'WARNING: No ConvoVault master key found (checked pki/ and config/)' }
})

Write-AuditLog "Config-level checks: $(@($configChecks).Count) checks — $(@($configChecks | Where-Object { -not $_.passed }).Count) failed"

# ── write report ───────────────────────────────────────────────────────────────
$reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'ConfigCoverage'
if (-not (Test-Path $reportDir)) { New-Item $reportDir -ItemType Directory -Force | Out-Null }
$reportStamp = Get-Date -Format 'yyyyMMddHHmm'
$reportPath  = Join-Path $reportDir "coverage-$reportStamp.json"

$report = [ordered]@{
    timestamp        = [datetime]::UtcNow.ToString('o')
    totalFiles       = $totalFiles
    avgAdoptionPct   = $avgAdoption
    featureSummary   = $summary
    sinGapSummary    = $sinBreakdown
    configChecks     = @($configChecks)
    lowCoverageTop20 = $lowCoverage
    allResults       = @($results)
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

Write-AuditLog "Report written: $reportPath"
Write-AuditLog "Average adoption: $avgAdoption%  |  SIN gaps found: $(@($sinGaps).Count)"

# ── optionally surface pipeline items ─────────────────────────────────────────
if ($PipelineItems) {
    try {
        $pipeMod = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
        if (Test-Path $pipeMod) {
            Import-Module $pipeMod -Force -ErrorAction Stop
            $groupTag = "ConfigCoverage-$reportStamp"

            # One BUG item per SIN pattern type found
            foreach ($sg in $sinBreakdown) {
                $bugTitle = "SIN gap: $($sg.pattern) found in $($sg.count) file(s)"
                Add-PipelineItem -WorkspacePath $WorkspacePath `
                    -Type 'BUG' -Title $bugTitle -Priority 'HIGH' -Status 'OPEN' `
                    -Category 'ConfigCoverageGap' -Tags @('SINGap', $sg.pattern, $groupTag) `
                    -Description "ConfigCoverageAudit detected $($sg.count) file(s) violating $($sg.pattern). See report: $reportPath"
                Write-AuditLog "Raised pipeline BUG: $bugTitle" 'Warning'
            }

            # Feature-adoption alerts for features below 20% adoption
            foreach ($feat in $summary.Keys) {
                if ($summary[$feat].pctOfFiles -lt 20 -and $summary[$feat].count -gt 0) {  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    $title = "Low adoption: $feat at $($summary[$feat].pctOfFiles)% ($($summary[$feat].count)/$totalFiles files)"  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    Add-PipelineItem -WorkspacePath $WorkspacePath `
                        -Type 'FeatureRequest' -Title $title -Priority 'MEDIUM' -Status 'OPEN' `
                        -Category 'ConfigCoverageGap' -Tags @('LowAdoption', $feat, $groupTag) `
                        -Description "Only $($summary[$feat].pctOfFiles)% of scripts use $feat. Consider a workspace-wide adoption sweep."  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    Write-AuditLog "Raised pipeline FeatureRequest: $title" 'Informational'
                }
            }
        }
    } catch {
        Write-AuditLog "Pipeline item creation failed: $($_.Exception.Message)" 'Warning'
    }
}

# ── emit result object for caller ─────────────────────────────────────────────
[PSCustomObject]@{
    reportPath     = $reportPath
    totalFiles     = $totalFiles
    avgAdoptionPct = $avgAdoption
    sinGapsFound   = @($sinGaps).Count
    featureSummary = $summary
}






