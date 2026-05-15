# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-05
# FileRole: Scanner
#Requires -Version 5.1
<#
.SYNOPSIS
    Orphaned File Audit — detects files not referenced in the agentic manifest and proposes remediation.
.DESCRIPTION
    Pipeline stages:
      1. COLLECT — enumerate all .ps1/.psm1/.psd1/.xhtml/.json/.css files in workspace (excluding ignored dirs)
      2. COMPARE — extract all 'path' fields from agentic-manifest.json (modules, scripts, xhtmlTools,
                   configs, tests, styles, agents, guiForms sections) into a reference set
      3. DIFF    — compute orphaned files (on disk, not in manifest) and ghost nodes (in manifest, not on disk)
      4. PLACEMENT — check each orphaned file against naming-convention → expected folder map
      5. REPORT  — write JSONL report to ~REPORTS/orphan-audit-{ts}.json
      6. TODOS   — append ToDo entries to config/cron-aiathon-pipeline.json (optional, -WriteTodos)
.PARAMETER WorkspacePath
    Root of workspace. Defaults to parent of script directory.
.PARAMETER ManifestPath
    Path to agentic-manifest.json. Defaults to <WorkspacePath>\config\agentic-manifest.json.
.PARAMETER WriteTodos
    When set, appends OPEN ToDo items to config/cron-aiathon-pipeline.json.
.PARAMETER IncludeGhosts
    When set, also reports manifest nodes whose paths do not exist on disk.
.EXAMPLE
    .\scripts\Invoke-OrphanedFileAudit.ps1
    .\scripts\Invoke-OrphanedFileAudit.ps1 -WriteTodos -IncludeGhosts
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$ManifestPath,
    [switch]$WriteTodos,
    [switch]$IncludeGhosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ─── Path Setup ────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
}
$WorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath)

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path (Join-Path $WorkspacePath 'config') 'agentic-manifest.json'
}
$ReportPath   = Join-Path $WorkspacePath '~REPORTS'
$PipelinePath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'

# ─── Exclusion list (mirrors Invoke-WorkspaceDependencyMap) ───────────────────────
$ExcludeNames = @('.git','.history','.venv','.venv-pygame312','archive','todo','temp',
                  '~DOWNLOADS','~REPORTS','checkpoints','node_modules','pki','Report',
                  'secdump','remediation-backups','__pycache__')

# ─── Naming convention → expected folder map ─────────────────────────────────────
# Maps regex patterns on filename to expected relative subfolder (backslash-separated)
$NamingRules = [ordered]@{
    '^XHTML-.*\.xhtml$'                       = 'scripts\XHTML-Checker'
    '^_BASE-.*\.xhtml$'                       = 'scripts\XHTML-Checker'
    '^_TEMPLATE-.*\.xhtml$'                   = 'scripts\XHTML-Checker'
    '^PwShGUI-.*\.xhtml$'                     = 'scripts\XHTML-Checker'
    '^.*\.xhtml$'                             = 'scripts\XHTML-Checker'
    '^Invoke-.*\.ps1$'                        = 'scripts'
    '^Start-.*\.ps1$'                         = 'scripts'
    '^Build-.*\.ps1$'                         = 'scripts'
    '^Export-.*\.ps1$'                        = 'scripts'
    '^Show-.*Dashboard.*\.ps1$'               = 'scripts'
    '^Get-.*\.ps1$'                           = 'scripts'
    '^Set-.*\.ps1$'                           = 'scripts'
    '^New-.*\.ps1$'                           = 'scripts'
    '^.*\.Tests\.ps1$'                        = 'tests'
    '^.*-Tests\.ps1$'                         = 'tests'
    '^.*-Test\.ps1$'                          = 'tests'
    '^Test-.*\.ps1$'                          = 'tests'
    '^.*\.psm1$'                              = 'modules'
    '^.*\.psd1$'                              = 'modules'
}

# ─── Stage 1: Collect files on disk ──────────────────────────────────────────────
Write-Host '[10%] Collecting file inventory...'
$scanExtensions = @('*.ps1','*.psm1','*.psd1','*.xhtml','*.json','*.css','*.html')

function Test-IsExcluded {
    param([string]$Path)
    foreach ($ex in $ExcludeNames) {
        if ($Path -split '[\\/]' | Where-Object { $_ -eq $ex }) { return $true }
    }
    return $false
}

$allDiskFiles = [System.Collections.Generic.List[pscustomobject]]@()
foreach ($ext in $scanExtensions) {
    $files = @(Get-ChildItem -Path $WorkspacePath -Recurse -Filter $ext -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if (Test-IsExcluded -Path $f.FullName) { continue }
        $rel = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\','/')
        $allDiskFiles.Add([pscustomobject]@{
            FullPath = $f.FullName
            RelPath  = $rel
            RelLower = $rel.ToLower()
            Name     = $f.Name
            Ext      = $f.Extension.ToLower()
            SizeKB   = [Math]::Round($f.Length / 1KB, 1)
        })
    }
}
Write-Host "  Found $(@($allDiskFiles).Count) files on disk."

# ─── Stage 2: Read manifest reference set ────────────────────────────────────────
Write-Host '[25%] Reading agentic manifest...'
$manifest = $null
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Warning "Manifest not found at: $ManifestPath"
} else {
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
        $manifest = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse manifest: $_"
    }
}

$manifestPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-ManifestSection {
    param($Section)
    if ($null -eq $Section) { return }
    foreach ($item in @($Section)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['path']) {
            $p = $item.path
            if (-not [string]::IsNullOrWhiteSpace($p)) {
                $null = $manifestPaths.Add($p.TrimStart('\','/'))
            }
        }
    }
}

if ($null -ne $manifest) {
    Add-ManifestSection $manifest.modules
    Add-ManifestSection $manifest.scripts
    Add-ManifestSection $manifest.xhtmlTools
    Add-ManifestSection $manifest.configs
    Add-ManifestSection $manifest.tests
    Add-ManifestSection $manifest.styles
    Add-ManifestSection $manifest.agents
    Add-ManifestSection $manifest.guiForms
    # Also scan dependency edge from/to paths
    if ($null -ne $manifest.dependencyEdges) {
        foreach ($edge in @($manifest.dependencyEdges)) {
            if ($null -ne $edge.from) { $null = $manifestPaths.Add($edge.from.ToString().TrimStart('\','/')) }
            if ($null -ne $edge.to)   { $null = $manifestPaths.Add($edge.to.ToString().TrimStart('\','/'))   }
        }
    }
    Write-Host "  Manifest contains $(@($manifestPaths).Count) distinct paths."
}

# ─── Stage 3: Diff ───────────────────────────────────────────────────────────────
Write-Host '[40%] Computing diff (orphans + ghosts)...'

$orphans = [System.Collections.Generic.List[pscustomobject]]@()   # on disk, NOT in manifest
$tracked = [System.Collections.Generic.List[pscustomobject]]@()   # on disk AND in manifest

foreach ($f in $allDiskFiles) {
    $inManifest = $manifestPaths.Contains($f.RelPath)
    if ($inManifest) {
        $tracked.Add($f)
    } else {
        $orphans.Add($f)
    }
}

$ghosts = [System.Collections.Generic.List[pscustomobject]]@()    # in manifest, NOT on disk
if ($IncludeGhosts -and $null -ne $manifest) {
    foreach ($p in $manifestPaths) {
        $full = Join-Path $WorkspacePath $p
        if (-not (Test-Path -LiteralPath $full)) {
            $ghosts.Add([pscustomobject]@{ ManifestPath = $p; FullPath = $full })
        }
    }
}

Write-Host "  Orphaned (on disk, not in manifest): $(@($orphans).Count)"
Write-Host "  Tracked  (on disk AND in manifest):  $(@($tracked).Count)"
if ($IncludeGhosts) {
    Write-Host "  Ghost    (in manifest, not on disk):  $(@($ghosts).Count)"
}

# ─── Stage 4: Placement check ────────────────────────────────────────────────────
Write-Host '[55%] Checking file placement vs naming standards...'

function Get-ExpectedFolder {
    param([string]$FileName)
    foreach ($kv in $NamingRules.GetEnumerator()) {
        if ($FileName -match $kv.Key) { return $kv.Value }
    }
    return $null
}

$placementIssues = [System.Collections.Generic.List[pscustomobject]]@()

foreach ($f in $orphans) {
    $expectedFolder = Get-ExpectedFolder -FileName $f.Name
    $actualFolder   = Split-Path $f.RelPath -Parent
    $actualFolder   = if ([string]::IsNullOrEmpty($actualFolder)) { '(root)' } else { $actualFolder }
    $misplaced      = $false
    $proposedPath   = $null
    if (-not [string]::IsNullOrEmpty($expectedFolder)) {
        $expectedFolder = $expectedFolder.TrimStart('\','/')
        if ($actualFolder.ToLower() -ne $expectedFolder.ToLower()) {
            $misplaced    = $true
            $proposedPath = Join-Path $expectedFolder $f.Name
        }
    }
    $null = $f.PSObject.Properties.Add(
        [System.Management.Automation.PSNoteProperty]::new('ExpectedFolder', $expectedFolder)
    )
    $null = $f.PSObject.Properties.Add(
        [System.Management.Automation.PSNoteProperty]::new('ActualFolder',   $actualFolder)
    )
    $null = $f.PSObject.Properties.Add(
        [System.Management.Automation.PSNoteProperty]::new('Misplaced',      $misplaced)
    )
    $null = $f.PSObject.Properties.Add(
        [System.Management.Automation.PSNoteProperty]::new('ProposedRelPath',$proposedPath)
    )
    if ($misplaced) { $placementIssues.Add($f) }
}

Write-Host "  Placement issues (wrong folder per naming standard): $(@($placementIssues).Count)"

# ─── Stage 5: Write report ───────────────────────────────────────────────────────
Write-Host '[70%] Writing audit report...'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
if (-not (Test-Path $ReportPath)) { $null = New-Item -ItemType Directory -Path $ReportPath -Force }

$reportData = [pscustomobject]@{
    schemaVersion  = 'OrphanAudit/1.0'
    generated      = (Get-Date -Format 'o')
    workspace      = $WorkspacePath
    manifestPath   = $ManifestPath
    manifestSchema = if ($null -ne $manifest -and $null -ne $manifest.PSObject.Properties["`$schema"]) { $manifest.'$schema' } else { 'unknown' }
    summary        = [pscustomobject]@{
        totalDiskFiles    = @($allDiskFiles).Count
        trackedFiles      = @($tracked).Count
        orphanedFiles     = @($orphans).Count
        ghostNodes        = @($ghosts).Count
        placementIssues   = @($placementIssues).Count
    }
    orphaned       = @($orphans)
    ghosts         = @($ghosts)
    placementIssues = @($placementIssues)
}

$reportFile = Join-Path $ReportPath "orphan-audit-$timestamp.json"
ConvertTo-Json -InputObject $reportData -Depth 6 |
    Set-Content -LiteralPath $reportFile -Encoding UTF8

Write-Host "  Report: $reportFile ($([Math]::Round((Get-Item -LiteralPath $reportFile).Length / 1KB, 1)) KB)"

# ─── Stage 6: Console Summary ────────────────────────────────────────────────────
Write-Host ''
Write-Host '══════════════════════════════════════════════════════════════'
Write-Host '  ORPHANED FILE AUDIT RESULTS'
Write-Host '══════════════════════════════════════════════════════════════'
Write-Host "  Total disk files scanned : $(@($allDiskFiles).Count)"
Write-Host "  Tracked in manifest      : $(@($tracked).Count)"
Write-Host "  ORPHANED (not in manifest): $(@($orphans).Count)"
if ($IncludeGhosts) {
    Write-Host "  GHOST   (not on disk)    : $(@($ghosts).Count)"
}
Write-Host "  Placement issues          : $(@($placementIssues).Count)"
Write-Host ''

if (@($orphans).Count -gt 0) {
    Write-Host '  ─── Top Orphaned Files ─────────────────────────────────────'
    $showCount = [Math]::Min(30, @($orphans).Count)
    for ($i = 0; $i -lt $showCount; $i++) {
        $o = $orphans[$i]
        $badge  = if ($o.Misplaced) { ' [MISPLACED]' } else { '' }
        $proposed = if ($o.Misplaced) { " → $($o.ProposedRelPath)" } else { '' }
        Write-Host "    $($o.RelPath)$badge$proposed"
    }
    if (@($orphans).Count -gt $showCount) {
        Write-Host "    ... and $(@($orphans).Count - $showCount) more (see report)"
    }
    Write-Host ''
}

# ─── Stage 7: ToDo generation ────────────────────────────────────────────────────
$todosAdded = 0
if ($WriteTodos -and @($orphans).Count -gt 0) {
    Write-Host '[85%] Writing ToDo items to pipeline...'
    $pipeline = $null
    if (Test-Path -LiteralPath $PipelinePath) {
        try {
            $rawPipe = Get-Content -LiteralPath $PipelinePath -Raw -Encoding UTF8
            $pipeline = $rawPipe | ConvertFrom-Json
        } catch {
            Write-Warning "Could not parse pipeline JSON: $_"
        }
    }

    if ($null -eq $pipeline) {
        Write-Warning 'Pipeline JSON not available — skipping ToDo write.'
    } else {
        $now = Get-Date -Format 'o'
        # Collect existing ToDo IDs to avoid duplicates
        $existingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $pipeline.PSObject.Properties['toDos']) {
            foreach ($t in @($pipeline.toDos)) {
                if ($null -ne $t -and -not [string]::IsNullOrEmpty($t.id)) {
                    $null = $existingIds.Add($t.id)
                }
            }
        }

        $newTodos = [System.Collections.ArrayList]@()
        foreach ($o in $orphans) {
            # Build deterministic ID from file path
            $hash = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($o.RelPath)
            $hashBytes = $hash.ComputeHash($bytes)
            $hash.Dispose()
            $shortId = ([System.BitConverter]::ToString($hashBytes[0..3]) -replace '-','').ToLower()
            $todoId  = "TODO-ORPHAN-$shortId"
            if ($existingIds.Contains($todoId)) { continue }

            $action = if ($o.Misplaced) {
                "Move to $($o.ProposedRelPath) and add to agentic-manifest.json"
            } else {
                "Add to agentic-manifest.json in appropriate section"
            }
            $priority = if ($o.Misplaced) { 'MEDIUM' } else { 'LOW' }
            $category = if ($o.Misplaced) { 'placement' } else { 'manifest-gap' }
            $orphanTag = if ($o.Misplaced) { 'misplaced' } else { 'untracked' }

            $item = [ordered]@{
                id              = $todoId
                type            = 'ToDo'
                status          = 'OPEN'
                priority        = $priority
                category        = $category
                title           = if ($o.Misplaced) { "[ORPHAN+MISPLACED] $($o.Name)" } else { "[ORPHAN] $($o.Name)" }
                description     = "$action. File: $($o.RelPath)"
                affectedFiles   = @($o.FullPath)
                source          = 'Invoke-OrphanedFileAudit'
                created         = $now
                modified        = $now
                completedAt     = $null
                linkedFeatures  = @()
                linkedBugs      = @()
                tags            = @('orphan', $orphanTag)
                notes           = "Detected by orphan audit run on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). ScanReport: $reportFile"
                sessionModCount = 0
                parentId        = ''
                executionAgent  = ''
            }
            $null = $newTodos.Add($item)
            $todosAdded++
        }

        if ($todosAdded -gt 0) {
            # Ensure toDos array exists
            if ($null -eq $pipeline.PSObject.Properties['toDos']) {
                $pipeline | Add-Member -MemberType NoteProperty -Name 'toDos' -Value @()
            }
            # Merge new todos
            $merged = [System.Collections.ArrayList]@()
            foreach ($t in @($pipeline.toDos)) { $null = $merged.Add($t) }
            foreach ($t in $newTodos) { $null = $merged.Add($t) }
            $pipeline.toDos = @($merged)
            # Update meta lastModified
            if ($null -ne $pipeline.meta) { $pipeline.meta.lastModified = $now }

            ConvertTo-Json -InputObject $pipeline -Depth 10 |
                Set-Content -LiteralPath $PipelinePath -Encoding UTF8
            Write-Host "  Added $todosAdded new ToDo items to pipeline JSON."
        } else {
            Write-Host '  No new ToDo items (all orphans already have existing entries).'
        }
    }
}

# ─── Done ─────────────────────────────────────────────────────────────────────────────
$sw.Stop()
$elapsed = $sw.Elapsed.TotalSeconds
Write-ProcessBanner -ProcessName 'Invoke-OrphanedFileAudit' -StartTime ([DateTime]::UtcNow.AddSeconds(-$elapsed)) -Success $true -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "  Report saved: $reportFile"
if ($WriteTodos) { Write-Host "  ToDos added:  $todosAdded" }
Write-Host ''

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





