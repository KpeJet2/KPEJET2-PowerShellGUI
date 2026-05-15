# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    PipeGAP - Pipeline Gap Analysis and Alignment Process.

.DESCRIPTION
    PipeGAP is the ongoing pipeline alignment orchestrator for the PowerShellGUI
    workspace.  It performs seven diagnostic passes on every run:

      1. AUDIT   - Scan all .md workplan files in ~README.md\ for unresolved
                   "- [ ]" checkbox items; cross-reference against todo/*.json status.
    2. TRIAGE  - Load every individual todo JSON and emit an OPEN/DONE breakdown;
             skip non-todo JSON artifacts and flag malformed todo files.
    3. SESSION - Enforce session gap coverage (gap-2604-001..014 + IMPL/IMPR
             alignment) and surface any still-open implementation gaps.
    4. RELIC   - Identify scripts\*.ps1 not listed in config\agentic-manifest.json
                   and therefore invisible to the pipeline.
    5. PARSE   - Syntax-parse all modules\*.psm1, scripts\*.ps1, and agent core
                   *.psm1 files using the PowerShell AST; emit any parse errors.
    6. STALE   - Report age of DIRECTORY-TREE.md and _master-aggregated.json;
                   trigger rebuilds when -Rebuild is passed.
    7. REPORT  - Write PipeGAP-<yyyyMMdd-HHmmss>.json and .md to
                   ~REPORTS\PipelineNormalization\.

.PARAMETER WorkspacePath
    Workspace root directory.  Defaults to the parent of this script's directory.

.PARAMETER Rebuild
    When supplied, also invoke Invoke-TodoBundleRebuild.ps1 (refreshes
    _master-aggregated.json), Build-DirectoryTree.ps1 (refreshes
    DIRECTORY-TREE.md), and Invoke-BugStatusRollup for all open bugs in
    the pipeline registry (promotes Bug status from child Bugs2FIX states).

.PARAMETER ReportOnly
    Skip all side-effects; only scan and report (implied when -Rebuild is absent).

.PARAMETER StaleThresholdDays
    Number of days after which an artifact is flagged stale (default: 3).

.EXAMPLE
    .\scripts\Invoke-PipeGAP.ps1
    .\scripts\Invoke-PipeGAP.ps1 -WorkspacePath C:\PowerShellGUI -Rebuild
    .\scripts\Invoke-PipeGAP.ps1 -StaleThresholdDays 1

.NOTES
    FileRole:  Orchestration
    Area:      PipeGAP / PipelineAlignment
    Created:   2026-04-10
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath       = '',
    [switch]$Rebuild,
    [switch]$ReportOnly,
    [int]   $StaleThresholdDays  = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $WorkspacePath = Split-Path $PSScriptRoot -Parent
    } else {
        $WorkspacePath = (Get-Location).Path
    }
}

# -- Helpers -------------------------------------------------------------------

function Write-PipeLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $colour = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        'OK'    { 'Green'  }
        default { 'Cyan'   }
    }
    Write-Host "[$ts PipeGAP $Level] $Message" -ForegroundColor $colour
}

function Get-TodoFiles {
    param([string]$TodoPath)
    Get-ChildItem -Path $TodoPath -Filter 'todo-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^_|action-log\.json' } |
        Sort-Object Name
}

# -------------------------------------------------------------------------------
#  PHASE 1 - AUDIT: .MD WORKPLAN CHECKER
# -------------------------------------------------------------------------------

function Invoke-WorkplanAudit {
    param([string]$ReadmePath)

    Write-PipeLog 'Phase 1 - AUDIT: scanning .md workplan files for checked + unchecked items...'

    $uncheckedItems = [System.Collections.ArrayList]::new()
    $checkedItems   = [System.Collections.ArrayList]::new()

    $mdFiles = Get-ChildItem -Path $ReadmePath -Filter '*.md' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike '#*' -and $_.Name -ne 'VERSION-UPDATES-REDIRECT.md' }

    foreach ($f in $mdFiles) {
        $lines = Get-Content $f.FullName -ErrorAction SilentlyContinue
        $lineNum = 0
        foreach ($line in $lines) {
            $lineNum++
            if ($line -match '^\s*-\s*\[\s*\]\s+(.+)$') {
                [void]$uncheckedItems.Add([PSCustomObject]@{
                    File     = $f.Name
                    Line     = $lineNum
                    Item     = $Matches[1].Trim()
                    Checked  = $false
                })
            } elseif ($line -match '^\s*-\s*\[\s*[xX]\s*\]\s+(.+)$') {
                [void]$checkedItems.Add([PSCustomObject]@{
                    File     = $f.Name
                    Line     = $lineNum
                    Item     = $Matches[1].Trim()
                    Checked  = $true
                })
            }
        }
    }

    $totalUnchecked = @($uncheckedItems).Count
    $totalChecked   = @($checkedItems).Count
    $totalChecklist = $totalUnchecked + $totalChecked
    $completionPct  = if ($totalChecklist -gt 0) { [math]::Round((100.0 * $totalChecked / $totalChecklist), 1) } else { 100.0 }

    $byFile = foreach ($f in $mdFiles) {
        $u = @($uncheckedItems | Where-Object { $_.File -eq $f.Name }).Count
        $c = @($checkedItems   | Where-Object { $_.File -eq $f.Name }).Count
        if (($u + $c) -gt 0) {
            [PSCustomObject]@{
                Name      = $f.Name
                Checked   = $c
                Unchecked = $u
                Total     = $u + $c
            }
        }
    }
    $byFile = @($byFile | Sort-Object -Property Unchecked, Total -Descending)

    Write-PipeLog "  Checklist items: checked=$totalChecked unchecked=$totalUnchecked completion=$completionPct% across $($mdFiles.Count) .md files"
    foreach ($g in ($byFile | Select-Object -First 5)) {
        Write-PipeLog "  $($g.Name): checked=$($g.Checked) unchecked=$($g.Unchecked)" -Level 'WARN'
    }

    return [PSCustomObject]@{
        TotalChecked   = $totalChecked
        TotalUnchecked = $totalUnchecked
        TotalChecklist = $totalChecklist
        CompletionPct  = $completionPct
        FileCount      = $mdFiles.Count
        CheckedItems   = @($checkedItems)
        UncheckedItems = @($uncheckedItems)
        ByFile         = @($byFile)
    }
}

# -------------------------------------------------------------------------------
#  PHASE 2 - TRIAGE: TODO JSON STATUS RECONCILIATION
# -------------------------------------------------------------------------------

function Invoke-TodoTriage {
    param([string]$TodoPath)

    Write-PipeLog 'Phase 2 - TRIAGE: reconciling todo JSON status...'

    $statuses = @{
        OPEN        = 0
        PLANNED     = 0
        IN_PROGRESS = 0
        TESTING     = 0
        PENDING_APPROVAL = 0
        DONE        = 0
        CLOSED      = 0
        BLOCKED     = 0
        FAILED      = 0
        UNKNOWN     = 0
    }

    $openItems      = [System.Collections.ArrayList]::new()
    $plannedItems   = [System.Collections.ArrayList]::new()
    $missingStatus  = [System.Collections.ArrayList]::new()

    foreach ($f in Get-TodoFiles -TodoPath $TodoPath) {
        try {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-PipeLog "  PARSE ERROR in $($f.Name): $_" -Level 'WARN'
            continue
        }
        if ($null -eq $j -or $null -eq $j.PSObject -or -not $j.PSObject.Properties['status']) {
            [void]$missingStatus.Add($f.Name)
            $statuses['UNKNOWN']++
            continue
        }

        $s = if ($j.status) { [string]$j.status.ToUpper() } else { 'UNKNOWN' }
        if ($statuses.ContainsKey($s)) { $statuses[$s]++ } else { $statuses['UNKNOWN']++ }

        if ($s -eq 'OPEN') {
            [void]$openItems.Add([PSCustomObject]@{
                File     = $f.Name
                Id       = $j.id
                Title    = if ($j.title) { $j.title.SubString(0, [Math]::Min(80, $j.title.Length)) } else { '(no title)' }
                Priority = $j.priority
            })
        } elseif ($s -eq 'PLANNED') {
            [void]$plannedItems.Add([PSCustomObject]@{
                File     = $f.Name
                Id       = $j.id
                Title    = if ($j.title) { $j.title.SubString(0, [Math]::Min(80, $j.title.Length)) } else { '(no title)' }
                Priority = $j.priority
            })
        }
    }

    $total = ($statuses.Values | Measure-Object -Sum).Sum

    Write-PipeLog "  Total individual todos: $total"
    Write-PipeLog "  OPEN: $($statuses.OPEN)  PLANNED: $($statuses.PLANNED)  PENDING_APPROVAL: $($statuses.PENDING_APPROVAL)  DONE: $($statuses.DONE)  CLOSED: $($statuses.CLOSED)"
    if (@($missingStatus).Count -gt 0) {
        Write-PipeLog "  Skipped malformed todo files: $(@($missingStatus).Count)" -Level 'WARN'
    }
    if ($statuses.OPEN -gt 0) {
        Write-PipeLog "  $($statuses.OPEN) OPEN todos remain - review required" -Level 'WARN'
    } else {
        Write-PipeLog '  No OPEN todos - backlog clear' -Level 'OK'
    }

    return [PSCustomObject]@{
        Total        = $total
        ByStatus     = $statuses
        OpenItems    = @($openItems)
        PlannedItems = @($plannedItems)
        MissingStatusFiles = @($missingStatus)
    }
}

# -------------------------------------------------------------------------------
#  PHASE 3 - SESSION GAP COVERAGE
# -------------------------------------------------------------------------------

function Invoke-SessionGapCoverage {
    param([string]$TodoPath)

    Write-PipeLog 'Phase 3 - SESSION: validating gap/implementation coverage...'

    $allTodos = foreach ($f in (Get-TodoFiles -TodoPath $TodoPath)) {
        try {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($j -and $j.PSObject.Properties['id']) {
                [PSCustomObject]@{
                    File   = $f.Name
                    Id     = [string]$j.id
                    Status = if ($j.PSObject.Properties['status']) { [string]$j.status } else { 'UNKNOWN' }
                    Title  = if ($j.PSObject.Properties['title']) { [string]$j.title } else { '' }
                }
            }
        } catch {
            $null
        }
    }

    $expectedGapIds = 1..14 | ForEach-Object { 'gap-2604-{0:D3}' -f $_ }
    $presentGapIds  = @($allTodos | Where-Object { $_.Id -match '^gap-2604-\d{3}$' } | Select-Object -ExpandProperty Id)
    $missingGapIds  = @($expectedGapIds | Where-Object { $_ -notin $presentGapIds })

    $activeGapItems = @($allTodos | Where-Object {
        $_.Id -match '^gap-2604-\d{3}$' -and $_.Status.ToUpper() -notin @('DONE','CLOSED')
    })

    $activeImplItems = @($allTodos | Where-Object {
        $_.Id -match '^IMPL-20260405-\d{3}$|^IMPR-\d{3}-20260408$' -and $_.Status.ToUpper() -notin @('DONE','CLOSED')
    })

    if (@($missingGapIds).Count -eq 0) {
        Write-PipeLog '  Session gap inventory complete (gap-2604-001..014 present)' -Level 'OK'
    } else {
        Write-PipeLog "  Missing expected gap IDs: $(@($missingGapIds).Count)" -Level 'WARN'
    }

    if (@($activeGapItems).Count -gt 0) {
        Write-PipeLog "  Active gap items remaining: $(@($activeGapItems).Count)" -Level 'WARN'
    } else {
        Write-PipeLog '  All gap-2604 items are DONE/CLOSED' -Level 'OK'
    }

    if (@($activeImplItems).Count -gt 0) {
        Write-PipeLog "  Active IMPL/IMPR items remaining: $(@($activeImplItems).Count)" -Level 'WARN'
    }

    return [PSCustomObject]@{
        ExpectedGapIds    = @($expectedGapIds)
        MissingGapIds     = @($missingGapIds)
        ActiveGapItems    = @($activeGapItems)
        ActiveImplItems   = @($activeImplItems)
        ActiveGapCount    = @($activeGapItems).Count
        ActiveImplCount   = @($activeImplItems).Count
    }
}

# -------------------------------------------------------------------------------
#  PHASE 4 - RELIC: SCRIPTS NOT IN AGENTIC-MANIFEST
# -------------------------------------------------------------------------------

function Invoke-RelicDetection {
    param([string]$WorkspacePath)

    Write-PipeLog 'Phase 4 - RELIC: detecting scripts not in agentic-manifest...'

    $manifestPath = Join-Path $WorkspacePath 'config\agentic-manifest.json'
    $scriptsPath  = Join-Path $WorkspacePath 'scripts'

    if (-not (Test-Path $manifestPath)) {
        Write-PipeLog '  agentic-manifest.json not found - skipping relic check' -Level 'WARN'
        return [PSCustomObject]@{ Relics = @(); ManifestMissing = $true }
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    # Collect all script paths referenced in the manifest
    $manifestRefs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($m in @($manifest.modules)) {
        $entryPoint = if ($m.PSObject.Properties['entry_point']) { $m.entry_point } else { $null }
        $scriptPath = if ($m.PSObject.Properties['script'])      { $m.script } else { $null }
        $sourceFile = if ($m.PSObject.Properties['source_file']) { $m.source_file } else { $null }
        $fileList   = if ($m.PSObject.Properties['files'])       { $m.files } else { $null }

        if ($entryPoint) { [void]$manifestRefs.Add([IO.Path]::GetFileName([string]$entryPoint)) }
        if ($scriptPath) { [void]$manifestRefs.Add([IO.Path]::GetFileName([string]$scriptPath)) }
        if ($sourceFile) { [void]$manifestRefs.Add([IO.Path]::GetFileName([string]$sourceFile)) }
        if ($fileList) {
            foreach ($fi in @($fileList)) { [void]$manifestRefs.Add([IO.Path]::GetFileName([string]$fi)) }
        }
    }

    # Also scan manifest.scripts array (main script catalog built by Build-AgenticManifest)
    if ($manifest.PSObject.Properties['scripts'] -and $null -ne $manifest.scripts) {
        foreach ($s in @($manifest.scripts)) {
            if ($s.PSObject.Properties['path'] -and $s.path) {
                [void]$manifestRefs.Add([IO.Path]::GetFileName([string]$s.path))
            }
        }
    }

    # Also accept matches on module id/name vs base file name
    $manifestIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @($manifest.modules)) {
        if ($m.PSObject.Properties['id'] -and $m.id)   { [void]$manifestIds.Add([string]$m.id) }
        if ($m.PSObject.Properties['name'] -and $m.name) { [void]$manifestIds.Add([string]$m.name) }
    }
    # Also register script names from manifest.scripts
    if ($manifest.PSObject.Properties['scripts'] -and $null -ne $manifest.scripts) {
        foreach ($s in @($manifest.scripts)) {
            if ($s.PSObject.Properties['name'] -and $s.name) {
                [void]$manifestIds.Add([string]$s.name)
            }
        }
    }

    $relics  = [System.Collections.ArrayList]::new()
    $exclude = @('_TEMPLATE', 'Test-', 'Run-All', 'Invoke-PipeGAP')  # known non-manifest scripts
    # Patterns intentionally excluded by Build-AgenticManifest (mirror its filter)
    $manifestBuilderExclusions = @(
        'Script-?.ps1',   # single-char scaffolding scripts (Script-A through Script-Z)  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
        'Script?.ps1',    # numbered scaffolding scripts  (Script1 through Script9)  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
        'PS-CheatSheet*'  # cheat sheet example files
    )

    $ps1Files = Get-ChildItem -Path $scriptsPath -Filter '*.ps1' -ErrorAction SilentlyContinue
    foreach ($f in $ps1Files) {
        $skip = $false
        foreach ($ex in $exclude) { if ($f.Name -like "*$ex*") { $skip = $true; break } }
        if (-not $skip) {
            foreach ($pat in $manifestBuilderExclusions) { if ($f.Name -like $pat) { $skip = $true; break } }
        }
        if ($skip) { continue }

        $inManifest = ($manifestRefs.Contains($f.Name)) -or
                      ($manifestIds.Contains([IO.Path]::GetFileNameWithoutExtension($f.Name)))

        if (-not $inManifest) {
            [void]$relics.Add([PSCustomObject]@{
                File      = $f.Name
                SizeKB    = [math]::Round($f.Length / 1KB, 1)
                Modified  = $f.LastWriteTime.ToString('yyyy-MM-dd')
                InManifest = $false
            })
        }
    }

    $count = @($relics).Count
    if ($count -eq 0) {
        Write-PipeLog '  All scripts are referenced in agentic-manifest' -Level 'OK'
    } else {
        Write-PipeLog "  $count relic scripts found (not in agentic-manifest)" -Level 'WARN'
        $relics | Select-Object -First 8 | ForEach-Object {
            Write-PipeLog "    $($_.File) [$($_.SizeKB)KB, modified $($_.Modified)]"
        }
    }

    return [PSCustomObject]@{
        RelicCount      = $count
        Relics          = @($relics)
        ManifestMissing = $false
    }
}

# -------------------------------------------------------------------------------
#  PHASE 5 - PARSE: SYNTAX CHECK CORE FILES
# -------------------------------------------------------------------------------

function Invoke-CoreParseCheck {
    param([string]$WorkspacePath)

    Write-PipeLog 'Phase 5 - PARSE: syntax-checking core .ps1 and .psm1 files...'

    $scanPaths = @(
        (Join-Path $WorkspacePath 'modules')
        (Join-Path $WorkspacePath 'scripts')
        (Join-Path $WorkspacePath 'sovereign-kernel\core')
        (Join-Path $WorkspacePath 'agents\PipelineSteering\core')
        (Join-Path $WorkspacePath 'agents\koe-RumA\core')
        (Join-Path $WorkspacePath 'agents\H-Ai-Nikr-Agi\core')
        (Join-Path $WorkspacePath 'agents\focalpoint-null\core')
    )

    $results = [System.Collections.ArrayList]::new()
    $errCount = 0

    foreach ($p in $scanPaths) {
        if (-not (Test-Path $p)) { continue }
        $files = Get-ChildItem -Path $p -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $f.FullName, [ref]$null, [ref]$errors)

            $parseErrors = @($errors | Where-Object { $null -ne $_.ErrorId })
            $ok   = ($parseErrors.Count -eq 0)
            $errCount += $parseErrors.Count

            [void]$results.Add([PSCustomObject]@{
                File       = $f.FullName.Replace($WorkspacePath + '\', '')
                ParseOK    = $ok
                ErrorCount = $parseErrors.Count
                FirstError = if ($parseErrors.Count -gt 0) { "$($parseErrors[0].Message) (L$($parseErrors[0].Extent.StartLineNumber))" } else { '' }
            })

            if (-not $ok) {
                Write-PipeLog "  PARSE ERROR in $($f.Name): $($parseErrors[0].Message)" -Level 'ERROR'
            }
        }
    }

    $fileCount = @($results).Count
    $failCount = @($results | Where-Object { -not $_.ParseOK }).Count

    if ($failCount -eq 0) {
        Write-PipeLog "  All $fileCount files parsed OK" -Level 'OK'
    } else {
        Write-PipeLog "  $failCount / $fileCount files have parse errors" -Level 'ERROR'
    }

    return [PSCustomObject]@{
        TotalFiles  = $fileCount
        FailCount   = $failCount
        TotalErrors = $errCount
        Results     = @($results)
    }
}

# -------------------------------------------------------------------------------
#  PHASE 6 - STALE: ARTIFACT AGE CHECK (+ OPTIONAL REBUILD)
# -------------------------------------------------------------------------------

function Invoke-StaleArtifactCheck {
    param(
        [string]$WorkspacePath,
        [int]   $ThresholdDays,
        [switch]$Rebuild
    )

    Write-PipeLog "Phase 6 - STALE: checking artifact freshness (threshold: ${ThresholdDays}d)..."

    $now       = Get-Date
    $artifacts = @(
        [PSCustomObject]@{
            Name        = 'DIRECTORY-TREE.md'
            Path        = Join-Path (Join-Path $WorkspacePath '~README.md') 'DIRECTORY-TREE.md'
            RebuildScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-DirectoryTree.ps1'
        }
        [PSCustomObject]@{
            Name        = '_master-aggregated.json'
            Path        = Join-Path (Join-Path $WorkspacePath 'todo') '_master-aggregated.json'
            RebuildScript = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-TodoBundleRebuild.ps1'
        }
    )

    $staleList = [System.Collections.ArrayList]::new()

    foreach ($a in $artifacts) {
        if (-not (Test-Path $a.Path)) {
            Write-PipeLog "  MISSING: $($a.Name)" -Level 'WARN'
            [void]$staleList.Add([PSCustomObject]@{
                Artifact = $a.Name
                AgeDays  = $null
                Stale    = $true
                Rebuilt  = $false
                Missing  = $true
            })
            continue
        }
        $item = Get-Item $a.Path
        $age  = ($now - $item.LastWriteTime).TotalDays
        $stale = $age -gt $ThresholdDays

        $rebuilt = $false
        if ($stale -and $Rebuild -and (Test-Path $a.RebuildScript)) {
            Write-PipeLog "  Rebuilding $($a.Name) via $([IO.Path]::GetFileName($a.RebuildScript))..." -Level 'WARN'
            try {
                & $a.RebuildScript -WorkspacePath $WorkspacePath -ErrorAction Stop
                $rebuilt = $true
                Write-PipeLog "  Rebuild OK: $($a.Name)" -Level 'OK'
            } catch {
                Write-PipeLog "  Rebuild FAILED: $($a.Name) - $_" -Level 'ERROR'
            }
        } elseif ($stale) {
            Write-PipeLog ("  STALE: $($a.Name) is {0:N0} days old (threshold: $ThresholdDays d)" -f $age) -Level 'WARN'
        } else {
            Write-PipeLog ("  OK: $($a.Name) is {0:N0} days old" -f $age) -Level 'OK'
        }

        [void]$staleList.Add([PSCustomObject]@{
            Artifact = $a.Name
            AgeDays  = [math]::Round($age, 1)
            Stale    = $stale
            Rebuilt  = $rebuilt
            Missing  = $false
        })
    }

    return [PSCustomObject]@{
        Checked    = @($staleList).Count
        StaleCount = @($staleList | Where-Object { $_.Stale }).Count
        Items      = @($staleList)
    }
}

# -------------------------------------------------------------------------------
#  PHASE 7 - REPORT: WRITE JSON + MD SUMMARY
# -------------------------------------------------------------------------------

function Write-PipeGAPReport {
    param(
        [string]       $WorkspacePath,
        [PSCustomObject]$Audit,
        [PSCustomObject]$Triage,
        [PSCustomObject]$SessionGap,
        [PSCustomObject]$Relic,
        [PSCustomObject]$Parse,
        [PSCustomObject]$Stale,
        [datetime]     $SessionStart
    )

    $elapsed   = ((Get-Date) - $SessionStart).TotalSeconds
    $timestamp = $SessionStart.ToString('yyyyMMdd-HHmmss')
    $reportDir = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'PipelineNormalization'

    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # -- JSON report -----------------------------------------------------------
    $report = [PSCustomObject]@{
        schema         = 'PipeGAP/1.0'
        generated      = $SessionStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        elapsedSeconds = [math]::Round($elapsed, 1)
        health         = [PSCustomObject]@{
            workplanChecked   = $Audit.TotalChecked
            workplanUnchecked = $Audit.TotalUnchecked
            workplanCompletionPct = $Audit.CompletionPct
            openTodos         = $Triage.ByStatus.OPEN
            plannedTodos      = $Triage.ByStatus.PLANNED
            pendingApprovalTodos = $Triage.ByStatus.PENDING_APPROVAL
            activeSessionGaps = $SessionGap.ActiveGapCount
            activeSessionImpl = $SessionGap.ActiveImplCount
            relicScripts      = $Relic.RelicCount
            parseFailures     = $Parse.FailCount
            staleArtifacts    = $Stale.StaleCount
        }
        workplanAudit  = $Audit
        todoTriage     = $Triage
        sessionGapCoverage = $SessionGap
        relicDetection = $Relic
        parseCheck     = $Parse
        staleArtifacts = $Stale
    }

    $jsonPath = Join-Path $reportDir "PipeGAP-$timestamp.json"
    try {
        $report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8 -ErrorAction Stop
        Write-PipeLog "Report written: $jsonPath" -Level 'OK'
    } catch {
        Write-PipeLog "WARNING: could not write JSON report: $_" -Level 'WARN'
    }

    # -- Markdown summary ------------------------------------------------------
    $h = $report.health
    $mdLines = @(
        "# PipeGAP Report - $($SessionStart.ToString('yyyy-MM-dd HH:mm'))"
        ""
        "| Metric | Value |"
        "|--------|-------|"
        "| Workplan checked items | $($h.workplanChecked) |"
        "| Workplan unchecked items | $($h.workplanUnchecked) |"
        "| Workplan completion % | $($h.workplanCompletionPct) |"
        "| OPEN todos (individual) | $($h.openTodos) |"
        "| PLANNED todos | $($h.plannedTodos) |"
        "| PENDING_APPROVAL todos | $($h.pendingApprovalTodos) |"
        "| Active session gaps | $($h.activeSessionGaps) |"
        "| Active session IMPL/IMPR | $($h.activeSessionImpl) |"
        "| Relic scripts (not in manifest) | $($h.relicScripts) |"
        "| Parse failures | $($h.parseFailures) |"
        "| Stale artifacts | $($h.staleArtifacts) |"
        ""
        "## OPEN Todos"
        ""
    )

    foreach ($t in ($Triage.OpenItems | Select-Object -First 20)) {
        $mdLines += "- **[$($t.Id)]** $($t.Title)"
    }

    $mdLines += @(
        ""
        "## Workplan Comparison (Top Files)"
        ""
    )
    foreach ($b in ($Audit.ByFile | Select-Object -First 8)) {
        $mdLines += "- **$($b.Name)**: checked=$($b.Checked) unchecked=$($b.Unchecked) total=$($b.Total)"
    }

    $mdLines += @(
        ""
        "## Session Gap Coverage"
        ""
    )
    if (@($SessionGap.MissingGapIds).Count -gt 0) {
        foreach ($m in $SessionGap.MissingGapIds) {
            $mdLines += "- **MISSING GAP ID**: $m"
        }
    } else {
        $mdLines += "- All expected gap IDs present (gap-2604-001..014)."
    }
    foreach ($g in ($SessionGap.ActiveGapItems | Select-Object -First 20)) {
        $mdLines += "- **ACTIVE GAP** [$($g.Id)] $($g.Title) ($($g.Status))"
    }
    foreach ($i in ($SessionGap.ActiveImplItems | Select-Object -First 20)) {
        $mdLines += "- **ACTIVE IMPL/IMPR** [$($i.Id)] $($i.Title) ($($i.Status))"
    }

    $mdLines += @(
        ""
        "## Parse Results"
        ""
        "Files checked: $($Parse.TotalFiles)  Failures: $($Parse.FailCount)"
        ""
    )
    foreach ($r in ($Parse.Results | Where-Object { -not $_.ParseOK })) {
        $mdLines += "- **FAIL** ``$($r.File)``  $($r.FirstError)"
    }

    $mdLines += @(
        ""
        "## Stale Artifacts"
        ""
    )
    foreach ($s in $Stale.Items) {
        $ageStr = if ($null -eq $s.AgeDays) { 'MISSING' } else { "$($s.AgeDays) days" }
        $flag   = if ($s.Stale) { '-' } else { '-' }
        $mdLines += "- $flag **$($s.Artifact)**: $ageStr"
    }

    $mdLines += @(
        ""
        "---"
        "_Generated by Invoke-PipeGAP.ps1 in $([math]::Round($elapsed,1))s_"
    )

    $mdPath = Join-Path $reportDir "PipeGAP-$timestamp.md"
    try {
        $mdLines | Set-Content -Path $mdPath -Encoding UTF8 -ErrorAction Stop
        Write-PipeLog "Markdown summary: $mdPath" -Level 'OK'
    } catch {
        Write-PipeLog "WARNING: could not write markdown report: $_" -Level 'WARN'
    }

    return $report
}

# -------------------------------------------------------------------------------
#  ENTRY POINT
# -------------------------------------------------------------------------------

$_sessionStart = Get-Date
Write-PipeLog "Invoke-PipeGAP starting - workspace: $WorkspacePath"
Write-PipeLog "Rebuild: $($Rebuild.IsPresent) | ReportOnly: $($ReportOnly.IsPresent) | StaleThreshold: ${StaleThresholdDays}d"

# Resolve paths
$_readmePath = Join-Path $WorkspacePath '~README.md'
$_todoPath   = Join-Path $WorkspacePath 'todo'

# Guard: workspace must exist
if (-not (Test-Path $WorkspacePath)) {
    Write-PipeLog "WorkspacePath '$WorkspacePath' not found - aborting" -Level 'ERROR'
    return
}

# Phase 1
$_auditResult  = Invoke-WorkplanAudit  -ReadmePath $_readmePath

# Phase 2
$_triageResult = Invoke-TodoTriage     -TodoPath $_todoPath

# Phase 3
$_sessionGapResult = Invoke-SessionGapCoverage -TodoPath $_todoPath

# Phase 4
$_relicResult  = Invoke-RelicDetection -WorkspacePath $WorkspacePath

# Phase 5
$_parseResult  = Invoke-CoreParseCheck -WorkspacePath $WorkspacePath

# Phase 6
$_staleResult  = Invoke-StaleArtifactCheck `
                     -WorkspacePath  $WorkspacePath `
                     -ThresholdDays  $StaleThresholdDays `
                     -Rebuild:($Rebuild -and -not $ReportOnly)

# Phase 6.5 — BUG STATUS ROLLUP (only when -Rebuild)
$_rollupCount = 0
if ($Rebuild -and -not $ReportOnly) {
    Write-PipeLog 'Phase 6.5 - ROLLUP: running Invoke-BugStatusRollup for open bugs...'
    $pipeModule = Join-Path (Join-Path $WorkspacePath 'modules') 'CronAiAthon-Pipeline.psm1'
    if (Test-Path $pipeModule) {
        try {
            Import-Module $pipeModule -Force -ErrorAction Stop
            $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
            if (Test-Path $regPath) {
                $reg = Get-Content $regPath -Raw | ConvertFrom-Json
                foreach ($bugItem in @($reg.bugs)) {
                    if ($null -ne $bugItem -and
                        $bugItem.PSObject.Properties['id'] -and
                        $bugItem.PSObject.Properties['status'] -and
                        $bugItem.status -notin @('DONE','CLOSED')) {
                        try {
                            Invoke-BugStatusRollup -WorkspacePath $WorkspacePath -BugItemId $bugItem.id
                            $_rollupCount++
                        } catch {
                            Write-PipeLog "  Rollup error for $($bugItem.id): $_" -Level 'WARN'
                        }
                    }
                }
                Write-PipeLog ("Phase 6.5 - ROLLUP: processed {0} open bug item(s)" -f $_rollupCount) -Level 'OK'
            } else {
                Write-PipeLog 'Phase 6.5 - ROLLUP: registry not found, skipping' -Level 'WARN'
            }
        } catch {
            Write-PipeLog "Phase 6.5 - ROLLUP: pipeline module load failed - $_" -Level 'WARN'
        }
    } else {
        Write-PipeLog 'Phase 6.5 - ROLLUP: CronAiAthon-Pipeline.psm1 not found, skipping' -Level 'WARN'
    }
}

# Phase 7
$_finalReport = Write-PipeGAPReport `
    -WorkspacePath $WorkspacePath `
    -Audit         $_auditResult  `
    -Triage        $_triageResult `
    -SessionGap    $_sessionGapResult `
    -Relic         $_relicResult  `
    -Parse         $_parseResult  `
    -Stale         $_staleResult  `
    -SessionStart  $_sessionStart

$_elapsed = ((Get-Date) - $_sessionStart).TotalSeconds
Write-PipeLog ("PipeGAP complete in {0:N1}s - Unchecked:{1}  OpenTodos:{2}  ActiveGaps:{3}  Relics:{4}  ParseFail:{5}  Stale:{6}  BugRollup:{7}" -f `
    $_elapsed,
    $_finalReport.health.workplanUnchecked,
    $_finalReport.health.openTodos,
    $_finalReport.health.activeSessionGaps,
    $_finalReport.health.relicScripts,
    $_finalReport.health.parseFailures,
    $_finalReport.health.staleArtifacts,
    $_rollupCount
) -Level 'OK'

return $_finalReport

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





