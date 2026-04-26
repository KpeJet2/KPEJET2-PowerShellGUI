# VersionTag: 2604.B2.V31.4
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    RE-memorAiZ -- Pipeline completeness enforcement, agent handback, and workspace memory gateway.
.DESCRIPTION
    Ensures all tasks seeking completion have:
      - Updated or newly created README files per changed directory
      - Minor version increments on all changed files
      - Manifest alignment via agentic-manifest rebuild
      - Dependency recalculation via script-dependency-matrix
      - Agent handback for incomplete work (tracked per agent)
      - Summary/Outline/Changes revision after all handbacks resolve
      - Consolidated workspace memory file for rapid re-evaluation
# TODO: HelpMenu | Show-REMemorAiZHelp | Actions: Inventory|Recall|Store|Prune|Help | Spec: config/help-menu-registry.json

    Pipeline Phases:
      Phase 1  INVENTORY   -- Scan workspace for changed/untracked files
      Phase 2  README      -- Verify/create README per directory with changes
      Phase 3  VERSION     -- Minor-increment all changed files
      Phase 4  MANIFEST    -- Rebuild agentic-manifest.json
      Phase 5  DEPENDENCY  -- Recalculate script dependency matrix
      Phase 6  HANDBACK    -- Route failures back to originating agents
      Phase 7  SUMMARIZE   -- Revise summaries, outlines, change logs
      Phase 8  MEMORIZE    -- Write workspace-memory-summary.json

    The memory file enables any agent (human or AI) to rapidly digest
    workspace state at start, interrupt, resume, guided, steered, or
    ending process -- maintaining project continuity and development intent.

.NOTES
    Author   : The Establishment
    Date     : 2026-04-08
    FileRole : Pipeline-Function
    Version  : 2604.B2.V31.1
    Category : Infrastructure
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ===============================================================================
#  MODULE STATE
# ===============================================================================

$script:SessionId        = [guid]::NewGuid().ToString().Substring(0,8)
$script:SessionStart     = Get-Date
$script:AgentHandbacks   = [ordered]@{}   # agentName -> @(failures)
$script:PhaseResults     = [ordered]@{}   # phaseName -> @{status; details; duration}
$script:ChangedFiles     = @()            # files detected as changed
$script:ReadmeActions    = @()            # readme create/update actions taken
$script:VersionBumps     = @()            # version increment records

# ===============================================================================
#  PRIVATE HELPERS
# ===============================================================================

function Write-RELog {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = 'Info')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts][RE-memorAiZ] $Message"
    Write-Output $line
    try { Write-AppLog -Message "[RE-memorAiZ] $Message" -Level $Level } catch { <# Intentional: non-fatal when PwShGUICore not loaded #> }
}

function Get-DirectoriesWithChanges {
    <#
    .SYNOPSIS  Identify directories containing recently modified files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$HoursBack = 24
    )
    $cutoff = (Get-Date).AddHours(-$HoursBack)
    $dirs = @{}
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1,*.psd1,*.json,*.md,*.xhtml -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\\.git\\|\\\.history\\|\\node_modules\\|\\~REPORTS\\|\\temp\\|\\logs\\' -and
            $_.LastWriteTime -gt $cutoff
        }
    foreach ($f in $files) {
        $dir = $f.DirectoryName
        if (-not $dirs.ContainsKey($dir)) {
            $dirs[$dir] = @()
        }
        $dirs[$dir] += $f
    }
    return @{ directories = $dirs; allFiles = $files }
}

function Test-ReadmeExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DirectoryPath)
    $readmePath = Join-Path $DirectoryPath 'README.md'
    return (Test-Path $readmePath)
}

function Build-ReadmeContent {
    <#
    .SYNOPSIS  Generate a README.md for a directory based on its contents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DirectoryPath,
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    $dirName = Split-Path $DirectoryPath -Leaf
    $relPath = $DirectoryPath.Replace($WorkspacePath, '').TrimStart('\','/')
    $files = Get-ChildItem -Path $DirectoryPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'README.md' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $dirName/")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("> VersionTag: 2604.B2.V31.1 | Auto-generated by RE-memorAiZ on $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("## Contents")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| File | Type | Size | Last Modified |')
    [void]$sb.AppendLine('|------|------|------|---------------|')

    foreach ($f in ($files | Sort-Object Name)) {
        $ext = $f.Extension.TrimStart('.')
        $sizeKB = [math]::Round($f.Length / 1KB, 1)
        $mod = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        [void]$sb.AppendLine("| $($f.Name) | $ext | ${sizeKB} KB | $mod |")
    }

    # List subdirs
    $subdirs = Get-ChildItem -Path $DirectoryPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^\.' }
    if (@($subdirs).Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Subdirectories')
        [void]$sb.AppendLine('')
        foreach ($d in ($subdirs | Sort-Object Name)) {
            $childCount = @(Get-ChildItem -Path $d.FullName -File -ErrorAction SilentlyContinue).Count
            [void]$sb.AppendLine("- **$($d.Name)/** ($childCount files)")
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine("*Generated by RE-memorAiZ pipeline - path: ``$relPath``*")

    return $sb.ToString()
}

# ===============================================================================
#  PHASE FUNCTIONS
# ===============================================================================

function Invoke-Phase1Inventory {
    <#
    .SYNOPSIS  Phase 1: Scan workspace for changed/untracked files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$HoursBack = 24
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog "Phase 1 INVENTORY: Scanning for changes in last ${HoursBack}h..." 'Info'

    $result = Get-DirectoriesWithChanges -WorkspacePath $WorkspacePath -HoursBack $HoursBack
    $script:ChangedFiles = @($result.allFiles)
    $dirCount = @($result.directories.Keys).Count
    $fileCount = @($script:ChangedFiles).Count

    Write-RELog "  Found $fileCount changed files across $dirCount directories" 'Info'

    $sw.Stop()
    $script:PhaseResults['Inventory'] = [ordered]@{
        status    = 'Complete'
        fileCount = $fileCount
        dirCount  = $dirCount
        duration  = $sw.Elapsed.TotalSeconds
        directories = @($result.directories.Keys | Sort-Object)
    }
    return $result
}

function Invoke-Phase2ReadmeCheck {
    <#
    .SYNOPSIS  Phase 2: Verify/create README per directory with changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][hashtable]$InventoryResult,
        [switch]$DryRun
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 2 README: Checking directory READMEs...' 'Info'

    $script:ReadmeActions = @()
    $created = 0
    $updated = 0
    $skipped = 0

    foreach ($dir in $InventoryResult.directories.Keys) {
        # Skip internal/generated dirs
        if ($dir -match '\\\.git\\|\\temp\\|\\logs\\|\\~REPORTS\\|\\\.history\\') {
            $skipped++
            continue
        }

        $readmePath = Join-Path $dir 'README.md'
        if (-not (Test-Path $readmePath)) {
            $content = Build-ReadmeContent -DirectoryPath $dir -WorkspacePath $WorkspacePath
            if (-not $DryRun) {
                Set-Content -Path $readmePath -Value $content -Encoding UTF8
            }
            $script:ReadmeActions += [ordered]@{
                action = 'Created'
                path   = $readmePath
                dir    = $dir
            }
            $created++
            Write-RELog "  README created: $readmePath" 'Info'
        } else {
            # Check if README is stale (older than newest file in dir)
            $readmeTime = (Get-Item $readmePath).LastWriteTime
            $newestFile = $InventoryResult.directories[$dir] |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($null -ne $newestFile -and $newestFile.LastWriteTime -gt $readmeTime -and $newestFile.Name -ne 'README.md') {
                $script:ReadmeActions += [ordered]@{
                    action     = 'StaleDetected'
                    path       = $readmePath
                    dir        = $dir
                    newestFile = $newestFile.Name
                }
                $updated++
                Write-RELog "  README stale: $readmePath (newer: $($newestFile.Name))" 'Warning'
            }
        }
    }

    $sw.Stop()
    $script:PhaseResults['ReadmeCheck'] = [ordered]@{
        status  = 'Complete'
        created = $created
        stale   = $updated
        skipped = $skipped
        actions = $script:ReadmeActions
        duration = $sw.Elapsed.TotalSeconds
    }
    Write-RELog "  README check: $created created, $updated stale, $skipped skipped" 'Info'
}

function Invoke-Phase3VersionBump {
    <#
    .SYNOPSIS  Phase 3: Minor-increment all changed .ps1/.psm1 files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [switch]$DryRun
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 3 VERSION: Incrementing minor versions on changed files...' 'Info'

    $script:VersionBumps = @()
    $bumped = 0
    $noTag  = 0

    $targetFiles = @($script:ChangedFiles) | Where-Object { $_.Extension -in @('.ps1','.psm1') }
    foreach ($f in $targetFiles) {
        try {
            $ver = Get-FileVersion -FilePath $f.FullName
            if ($null -eq $ver) {
                $noTag++
                continue
            }
            if (-not $DryRun) {
                $result = Step-MinorVersion -FilePath $f.FullName
                if ($null -ne $result) {
                    $script:VersionBumps += $result
                    $bumped++
                }
            } else {
                $newMinor = $ver.minor + 1
                $newTag = Format-VersionTag -Prefix $ver.prefix -Major $ver.major -Minor $newMinor
                $script:VersionBumps += [ordered]@{
                    file   = $f.FullName
                    before = $ver.full
                    after  = $newTag
                    dryRun = $true
                }
                $bumped++
            }
        } catch {
            Write-RELog "  Version bump failed: $($f.Name) -- $($_.Exception.Message)" 'Warning'
        }
    }

    $sw.Stop()
    $script:PhaseResults['VersionBump'] = [ordered]@{
        status  = 'Complete'
        bumped  = $bumped
        noTag   = $noTag
        bumps   = $script:VersionBumps
        duration = $sw.Elapsed.TotalSeconds
    }
    Write-RELog "  Version bumps: $bumped files, $noTag without VersionTag" 'Info'
}

function Invoke-Phase4ManifestAlign {
    <#
    .SYNOPSIS  Phase 4: Rebuild agentic-manifest.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [switch]$DryRun
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 4 MANIFEST: Rebuilding agentic-manifest.json...' 'Info'

    $manifestScript = Join-Path $WorkspacePath 'scripts\Build-AgenticManifest.ps1'
    $status = 'Skipped'
    $detail = ''

    if (Test-Path $manifestScript) {
        if (-not $DryRun) {
            try {
                & $manifestScript -ErrorAction Stop
                $status = 'Complete'
                $detail = 'Manifest rebuilt successfully'
                Write-RELog '  Manifest rebuilt' 'Info'
            } catch {
                $status = 'Failed'
                $detail = $_.Exception.Message
                Write-RELog "  Manifest rebuild failed: $detail" 'Error'
            }
        } else {
            $status = 'DryRun'
            $detail = "Would execute: $manifestScript"
        }
    } else {
        $status = 'Missing'
        $detail = "Build-AgenticManifest.ps1 not found at $manifestScript"
        Write-RELog "  $detail" 'Warning'
    }

    $sw.Stop()
    $script:PhaseResults['ManifestAlign'] = [ordered]@{
        status   = $status
        detail   = $detail
        duration = $sw.Elapsed.TotalSeconds
    }
}

function Invoke-Phase5DependencyCalc {
    <#
    .SYNOPSIS  Phase 5: Recalculate script dependency matrix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [switch]$DryRun
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 5 DEPENDENCY: Recalculating dependency matrix...' 'Info'

    $depScript = Join-Path $WorkspacePath 'scripts\Invoke-ScriptDependencyMatrix.ps1'
    $status = 'Skipped'
    $detail = ''

    if (Test-Path $depScript) {
        if (-not $DryRun) {
            try {
                & $depScript -ErrorAction Stop
                $status = 'Complete'
                $detail = 'Dependencies recalculated'
                Write-RELog '  Dependencies recalculated' 'Info'
            } catch {
                $status = 'Failed'
                $detail = $_.Exception.Message
                Write-RELog "  Dependency calc failed: $detail" 'Error'
            }
        } else {
            $status = 'DryRun'
            $detail = "Would execute: $depScript"
        }
    } else {
        $status = 'Missing'
        $detail = "Invoke-ScriptDependencyMatrix.ps1 not found at $depScript"
        Write-RELog "  $detail" 'Warning'
    }

    $sw.Stop()
    $script:PhaseResults['DependencyCalc'] = [ordered]@{
        status   = $status
        detail   = $detail
        duration = $sw.Elapsed.TotalSeconds
    }
}

function Invoke-Phase6AgentHandback {
    <#
    .SYNOPSIS  Phase 6: Route failures back to originating agents.
    .DESCRIPTION
        Inspects PhaseResults for failures, maps them to responsible agents,
        and records handback entries. Returns $true if handbacks remain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 6 HANDBACK: Checking for agent handback requirements...' 'Info'

    $handbacks = @()

    foreach ($phase in $script:PhaseResults.Keys) {
        $pr = $script:PhaseResults[$phase]
        if ($pr.status -eq 'Failed') {
            $agentName = switch ($phase) {
                'ManifestAlign'  { 'Build-AgenticManifest' }
                'DependencyCalc' { 'ScriptDependencyMatrix' }
                'VersionBump'    { 'VersionManager' }
                'ReadmeCheck'    { 'PipelineSteering' }
                default          { 'Unknown' }
            }
            $entry = [ordered]@{
                phase     = $phase
                agent     = $agentName
                error     = $pr.detail
                timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                resolved  = $false
            }
            $handbacks += $entry
            if (-not $script:AgentHandbacks.Contains($agentName)) {
                $script:AgentHandbacks[$agentName] = @()
            }
            $script:AgentHandbacks[$agentName] += $entry
            Write-RELog "  HANDBACK -> $agentName : $($pr.detail)" 'Warning'
        }
    }

    # Check stale READMEs as handback items for PipelineSteering
    $staleReadmes = @($script:ReadmeActions | Where-Object { $_.action -eq 'StaleDetected' })
    if (@($staleReadmes).Count -gt 0) {
        foreach ($stale in $staleReadmes) {
            $entry = [ordered]@{
                phase     = 'ReadmeCheck'
                agent     = 'PipelineSteering'
                error     = "Stale README: $($stale.path) (newer file: $($stale.newestFile))"
                timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
                resolved  = $false
            }
            if (-not $script:AgentHandbacks.Contains('PipelineSteering')) {
                $script:AgentHandbacks['PipelineSteering'] = @()
            }
            $script:AgentHandbacks['PipelineSteering'] += $entry
        }
        Write-RELog "  $(@($staleReadmes).Count) stale README(s) handed back to PipelineSteering" 'Warning'
    }

    $sw.Stop()
    $totalHandbacks = 0
    foreach ($k in $script:AgentHandbacks.Keys) {
        $totalHandbacks += @($script:AgentHandbacks[$k]).Count
    }

    $script:PhaseResults['AgentHandback'] = [ordered]@{
        status         = if ($totalHandbacks -gt 0) { 'HandbacksPending' } else { 'AllClear' }
        handbackCount  = $totalHandbacks
        agentsSummary  = [ordered]@{}
        duration       = $sw.Elapsed.TotalSeconds
    }
    foreach ($k in $script:AgentHandbacks.Keys) {
        $script:PhaseResults['AgentHandback'].agentsSummary[$k] = @($script:AgentHandbacks[$k]).Count
    }

    Write-RELog "  Handback check complete: $totalHandbacks pending across $(@($script:AgentHandbacks.Keys).Count) agents" 'Info'
    return ($totalHandbacks -gt 0)
}

function Invoke-Phase7Summarize {
    <#
    .SYNOPSIS  Phase 7: Revise summaries, outlines, and change log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 7 SUMMARIZE: Building session change summary...' 'Info'

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportDir = Join-Path $WorkspacePath '~REPORTS'
    if (-not (Test-Path $reportDir)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }

    $summary = [ordered]@{
        sessionId   = $script:SessionId
        started     = $script:SessionStart.ToString('yyyy-MM-ddTHH:mm:ss')
        completed   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        phases      = $script:PhaseResults
        versionBumps = @($script:VersionBumps | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                [ordered]@{ file = $_.file; before = $_.before; after = $_.after }
            } else {
                [ordered]@{ file = $_.file; before = if ($null -ne $_.before) { $_.before.full } else { 'unknown' }; after = $_.newTag }
            }
        })
        readmeActions = $script:ReadmeActions
        handbacks    = $script:AgentHandbacks
        changedFileCount = @($script:ChangedFiles).Count
    }

    $reportPath = Join-Path $reportDir "re-memoraiz-session-$ts.json"
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8
    Write-RELog "  Session report: $reportPath" 'Info'

    $sw.Stop()
    $script:PhaseResults['Summarize'] = [ordered]@{
        status     = 'Complete'
        reportPath = $reportPath
        duration   = $sw.Elapsed.TotalSeconds
    }
    return $reportPath
}

function Invoke-Phase8MemoryWrite {
    <#
    .SYNOPSIS  Phase 8: Write workspace memory summary for rapid re-evaluation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-RELog 'Phase 8 MEMORIZE: Writing workspace memory summary...' 'Info'

    $configDir = Join-Path $WorkspacePath 'config'
    $memoryPath = Join-Path $configDir 'workspace-memory-summary.json'

    # Collect workspace inventory
    $moduleCount = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' }).Count
    $scriptCount = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue).Count
    $testCount   = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'tests') -Filter '*.ps1' -File -ErrorAction SilentlyContinue).Count
    $sinCount    = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'sin_registry') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count

    # Collect version inventory
    $versions = @{}
    $versionFiles = Get-ChildItem -Path $WorkspacePath -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.history\\|\\node_modules\\|\\temp\\' }
    foreach ($vf in $versionFiles) {
        $m = Select-String -Path $vf.FullName -Pattern '^#\s*VersionTag:\s*(\S+)' | Select-Object -First 1
        if ($m) {
            $tag = $m.Matches[0].Groups[1].Value
            if (-not $versions.ContainsKey($tag)) { $versions[$tag] = 0 }
            $versions[$tag]++
        }
    }

    # Collect agent state
    $agentDirs = @(Get-ChildItem -Path (Join-Path $WorkspacePath 'agents') -Directory -ErrorAction SilentlyContinue)

    # Collect todo counts
    $todoDir = Join-Path $WorkspacePath 'todo'
    $todoFiles = @()
    $todoStats = [ordered]@{ total = 0; open = 0; done = 0 }
    if (Test-Path $todoDir) {
        $todoFiles = @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($tf in $todoFiles) {
            try {
                $td = Get-Content $tf.FullName -Raw | ConvertFrom-Json
                $todoStats.total++
                if ($td.status -eq 'DONE') { $todoStats.done++ } else { $todoStats.open++ }
            } catch { <# Intentional: skip malformed todo files #> }
        }
    }

    # Collect CronAiAthon pipeline state
    $pipelinePath = Join-Path $configDir 'cron-aiathon-pipeline.json'
    $pipelineStats = [ordered]@{}
    if (Test-Path $pipelinePath) {
        try {
            $pipeline = Get-Content $pipelinePath -Raw | ConvertFrom-Json
            if ($null -ne $pipeline.items) {
                $allItems = @($pipeline.items.PSObject.Properties.Value)
                $pipelineStats.totalItems = @($allItems).Count
                $pipelineStats.byStatus = [ordered]@{}
                foreach ($item in $allItems) {
                    $st = if ($null -ne $item.status) { $item.status } else { 'UNKNOWN' }
                    if (-not $pipelineStats.byStatus.Contains($st)) { $pipelineStats.byStatus[$st] = 0 }
                    $pipelineStats.byStatus[$st]++
                }
            }
        } catch { <# Intentional: pipeline file may be locked #> }
    }

    # Build the memory object
    $memory = [ordered]@{
        '$schema'          = 'PwShGUI-WorkspaceMemory/1.0'
        lastUpdated        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        lastUpdatedBy      = 'RE-memorAiZ'
        sessionId          = $script:SessionId
        projectName        = 'PowerShellGUI'
        projectRoot        = $WorkspacePath
        targetRuntime      = 'PowerShell 5.1'
        versionTagFormat   = 'YYMM.B<build>.V<major>.<minor>'
        currentVersionTag  = '2604.B2.V31.1'
        inventory          = [ordered]@{
            modules    = $moduleCount
            scripts    = $scriptCount
            tests      = $testCount
            sinPatterns = $sinCount
            agents     = @($agentDirs).Count
            agentNames = @($agentDirs | ForEach-Object { $_.Name })
        }
        versionDistribution = $versions
        pipelineState       = $pipelineStats
        todoSummary         = $todoStats
        lastSessionPhases   = $script:PhaseResults
        handbackRegistry    = $script:AgentHandbacks
        continuityNotes     = [ordered]@{
            resumeInstructions = 'Load this file to restore workspace context. Check handbackRegistry for pending agent work. Review lastSessionPhases for pipeline state.'
            interruptRecovery  = 'If session was interrupted, re-run Invoke-REmemorAiZ with -ResumeFrom to pick up from last completed phase.'
            intentSealing      = 'Use Show-WorkspaceIntentReview.ps1 to view/seal development intent. Sealed intents are pinned and cannot be overridden without explicit unseal.'
        }
        developmentIntent   = [ordered]@{
            chiefDirective     = 'Build a comprehensive PowerShell 5.1 WinForms application management suite with full lifecycle tooling'
            coreCapabilities   = @(
                'WinForms GUI application management'
                'Credential and secret lifecycle management (SASC/Bitwarden)'
                'Pipeline automation (CronAiAthon)'
                'Code quality governance (SIN patterns)'
                'Workspace integrity scanning'
                'Version management with CPSR reporting'
                'Agent-based code steering and review'
            )
            codingStandards    = @(
                'PS 5.1 strict mode (no PS7-only operators)'
                'UTF-8 WITH BOM for Unicode files'
                'VersionTag on every script/module'
                'SIN governance compliance (27 blocking + 7 advisory patterns)'
                '@() force-array before .Count'
                'try/catch on Import-Module (no SilentlyContinue)'
                '-Encoding UTF8 on all file writes'
            )
        }
    }

    $memory | ConvertTo-Json -Depth 10 | Set-Content -Path $memoryPath -Encoding UTF8
    Write-RELog "  Workspace memory written: $memoryPath" 'Info'

    $sw.Stop()
    $script:PhaseResults['MemoryWrite'] = [ordered]@{
        status     = 'Complete'
        memoryPath = $memoryPath
        duration   = $sw.Elapsed.TotalSeconds
    }
    return $memoryPath
}

# ===============================================================================
#  MAIN PIPELINE FUNCTION
# ===============================================================================

function Invoke-REmemorAiZ {
    <#
    .SYNOPSIS  Run the RE-memorAiZ pipeline: inventory, readme, version, manifest, deps, handback, summarize, memorize.
    .DESCRIPTION
        Executes all 8 phases in sequence. If Phase 6 (Handback) detects unresolved
        agent failures, it logs them and continues to summarization.

        Use -DryRun to preview all changes without writing files.
        Use -HoursBack to control the change detection window.
        Use -SkipManifest / -SkipDependency to bypass heavy rebuild phases.
        Use -ResumeFrom to pick up from a specific phase after interruption.
    .EXAMPLE
        Invoke-REmemorAiZ -WorkspacePath C:\PowerShellGUI
        Invoke-REmemorAiZ -WorkspacePath C:\PowerShellGUI -DryRun -HoursBack 48
        Invoke-REmemorAiZ -WorkspacePath C:\PowerShellGUI -ResumeFrom VersionBump
    .OUTPUTS
        Hashtable with session results, phase outcomes, and memory file path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [int]$HoursBack = 24,
        [switch]$DryRun,
        [switch]$SkipManifest,
        [switch]$SkipDependency,
        [ValidateSet('Inventory','ReadmeCheck','VersionBump','ManifestAlign','DependencyCalc','AgentHandback','Summarize','MemoryWrite')]
        [string]$ResumeFrom = ''
    )

    if (-not (Test-Path $WorkspacePath)) {
        Write-RELog "Workspace path not found: $WorkspacePath" 'Error'
        return $null
    }

    $banner = @"
 +==============================================================+
 |  RE-memorAiZ Pipeline v2604.B2.V31.1                        |
 |  Session: $($script:SessionId)                                       |
 |  Mode: $(if ($DryRun) { 'DRY RUN  ' } else { 'LIVE     ' })                                            |
 +==============================================================+
"@
    Write-Output $banner

    $phases = @('Inventory','ReadmeCheck','VersionBump','ManifestAlign','DependencyCalc','AgentHandback','Summarize','MemoryWrite')
    $startIdx = 0
    if ($ResumeFrom -ne '') {
        $startIdx = [array]::IndexOf($phases, $ResumeFrom)
        if ($startIdx -lt 0) { $startIdx = 0 }
        Write-RELog "Resuming from phase: $ResumeFrom (index $startIdx)" 'Info'
    }

    $inventoryResult = $null

    for ($i = $startIdx; $i -lt @($phases).Count; $i++) {
        $phaseName = $phases[$i]
        $phaseNum = $i + 1
        Write-Output "`n=== Phase $phaseNum/8: $phaseName ==="

        switch ($phaseName) {
            'Inventory' {
                $inventoryResult = Invoke-Phase1Inventory -WorkspacePath $WorkspacePath -HoursBack $HoursBack
            }
            'ReadmeCheck' {
                if ($null -eq $inventoryResult) {
                    $inventoryResult = Invoke-Phase1Inventory -WorkspacePath $WorkspacePath -HoursBack $HoursBack
                }
                Invoke-Phase2ReadmeCheck -WorkspacePath $WorkspacePath -InventoryResult $inventoryResult -DryRun:$DryRun
            }
            'VersionBump' {
                Invoke-Phase3VersionBump -WorkspacePath $WorkspacePath -DryRun:$DryRun
            }
            'ManifestAlign' {
                if ($SkipManifest) {
                    $script:PhaseResults['ManifestAlign'] = [ordered]@{ status = 'Skipped'; detail = 'User requested skip'; duration = 0 }
                    Write-RELog '  Manifest rebuild skipped by user' 'Info'
                } else {
                    Invoke-Phase4ManifestAlign -WorkspacePath $WorkspacePath -DryRun:$DryRun
                }
            }
            'DependencyCalc' {
                if ($SkipDependency) {
                    $script:PhaseResults['DependencyCalc'] = [ordered]@{ status = 'Skipped'; detail = 'User requested skip'; duration = 0 }
                    Write-RELog '  Dependency calc skipped by user' 'Info'
                } else {
                    Invoke-Phase5DependencyCalc -WorkspacePath $WorkspacePath -DryRun:$DryRun
                }
            }
            'AgentHandback' {
                $hasHandbacks = Invoke-Phase6AgentHandback -WorkspacePath $WorkspacePath
                if ($hasHandbacks) {
                    Write-RELog '  Handbacks pending -- continuing to summarization' 'Warning'
                }
            }
            'Summarize' {
                Invoke-Phase7Summarize -WorkspacePath $WorkspacePath
            }
            'MemoryWrite' {
                Invoke-Phase8MemoryWrite -WorkspacePath $WorkspacePath
            }
        }
    }

    # Final banner
    $elapsed = ((Get-Date) - $script:SessionStart).TotalSeconds
    Write-Output "`n=== RE-memorAiZ Pipeline Complete ==="
    Write-Output "  Session   : $($script:SessionId)"
    Write-Output "  Duration  : $([math]::Round($elapsed, 1))s"
    Write-Output "  Changed   : $(@($script:ChangedFiles).Count) files"
    Write-Output "  Bumped    : $(@($script:VersionBumps).Count) versions"
    Write-Output "  READMEs   : $(@($script:ReadmeActions).Count) actions"

    $hbCount = 0
    foreach ($k in $script:AgentHandbacks.Keys) { $hbCount += @($script:AgentHandbacks[$k]).Count }
    Write-Output "  Handbacks : $hbCount pending"
    Write-Output ''

    return [ordered]@{
        sessionId    = $script:SessionId
        elapsed      = $elapsed
        phases       = $script:PhaseResults
        handbacks    = $script:AgentHandbacks
        memoryPath   = if ($script:PhaseResults.Contains('MemoryWrite')) { $script:PhaseResults['MemoryWrite'].memoryPath } else { '' }
        reportPath   = if ($script:PhaseResults.Contains('Summarize')) { $script:PhaseResults['Summarize'].reportPath } else { '' }
    }
}

# ===============================================================================
#  EXPORTS
# ===============================================================================


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
    'Invoke-REmemorAiZ',
    'Invoke-Phase1Inventory',
    'Invoke-Phase2ReadmeCheck',
    'Invoke-Phase3VersionBump',
    'Invoke-Phase4ManifestAlign',
    'Invoke-Phase5DependencyCalc',
    'Invoke-Phase6AgentHandback',
    'Invoke-Phase7Summarize',
    'Invoke-Phase8MemoryWrite'
)






