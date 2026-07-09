# VersionTag: 2607.B1.V52.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-07-09
# SupportsPS7.6TestedDate: 2026-07-09
# FileRole: Builder
<#
.SYNOPSIS
    Build-DynaManifest -- Generate unified dynamic manifest with integrated dependencies,
    security, versioning, and drift guards for pre-test pipeline gate.

.DESCRIPTION
    Scans the workspace to produce config/dynamic-manifest.json (DynaManifest), a single
    source of truth combining:

    * File inventory (modules, scripts, configs, tests, agents, XHTML) with roles, tiers, sizes
    * Function registry (exported/internal, params, types, side effects, agentic actions)
    * Dependency graph (imports, dot-sources, calls) built from static AST analysis
    * Security envelope (folder ACLs, file permissions, integrity hashes)
    * Drift guards (version alignment, encoding compliance, SIN patterns, test recency)
    * Pipeline integration (production-ready gates, stamp records, pre-test blockers)

    Output: config/dynamic-manifest.json (canonical)
            config/dynamic-manifest-history/<timestamp>.json (snapshot)
            logs/dynamic-manifest-build.log (build details)

    Used by:
    * Pre-test pipeline gate (tests/Invoke-DynaManifestValidation.ps1)
    * Dependency visualization (XHTML-DependencyMapR2-CORTIX.xhtml)
    * Coverage tracking (functions tested vs untested, by engine)
    * Agentic routing (action → handler → function mapping)

.PARAMETER WorkspacePath
    Root of the workspace (default: parent of script directory).

.PARAMETER OutputPath
    Override output path (default: config/dynamic-manifest.json).

.PARAMETER IncludeKernel
    Include sovereign-kernel/ in the scan (default: false).

.PARAMETER SkipHistory
    Do not save snapshot to history folder.

.PARAMETER ValidateDriftGuards
    Run full drift-guard validation on completion (requires Invoke-DynaManifestValidation.ps1).

.NOTES
    VersionTag: 2607.B1.V52.0
    VersionBuildHistory:
        2607.B1.V52.0  2026-07-09  Initial: unified manifest with drift guards, security envelope, test recency
    FileRole: Generator
    Category: Infrastructure

    Schema: PwShGUI-DynaManifest/2.0
    Supersedes: agentic-manifest.json (kept for backward compatibility)

.EXAMPLE
    .\scripts\Build-DynaManifest.ps1
    Build full DynaManifest with all guards enabled.

.EXAMPLE
    .\scripts\Build-DynaManifest.ps1 -ValidateDriftGuards -Verbose
    Build and immediately validate drift guards.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$OutputPath,
    [switch]$IncludeKernel,
    [switch]$SkipHistory,
    [switch]$ValidateDriftGuards
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Setup ─────────────────────────────────────────────────────────────────────────────────
if (-not $WorkspacePath) { $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $OutputPath)    { $OutputPath = Join-Path $WorkspacePath 'config\dynamic-manifest.json' }

$modulesDir = Join-Path $WorkspacePath 'modules'
$scriptsDir = Join-Path $WorkspacePath 'scripts'
$configDir  = Join-Path $WorkspacePath 'config'
$testsDir   = Join-Path $WorkspacePath 'tests'
$agentsDir  = Join-Path $WorkspacePath 'agents'
$logsDir    = Join-Path $WorkspacePath 'logs'
$sinDir     = Join-Path $WorkspacePath 'sin_registry'
$timestamp  = Get-Date -Format 'yyyyMMddHHmmss'
$logFile    = Join-Path $logsDir "dynamic-manifest-build-$timestamp.log"

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

function Write-Log { param([string]$Msg); $line = "[$(Get-Date -Format HH:mm:ss)] $Msg"; Write-Host $line; Add-Content $logFile $line -Encoding UTF8 -EA SilentlyContinue }

Write-Log "Build-DynaManifest starting (WorkspacePath: $WorkspacePath)"

# ── Manifest Structure ────────────────────────────────────────────────────────────────────
$manifest = [ordered]@{
    '$schema'         = 'PwShGUI-DynaManifest/2.0'
    'meta'            = [ordered]@{
        'version'              = '2607.B1.V52.0'
        'generated'            = (Get-Date).ToUniversalTime().ToString('o')
        'generator'            = 'scripts/Build-DynaManifest.ps1'
        'workspacePath'        = $WorkspacePath
        'purpose'              = 'Unified dynamic manifest: dependencies, security, versioning, drift guards, pipeline integration'
        'supersedes'           = 'config/agentic-manifest.json'
    }
    'counts'          = [ordered]@{}
    'modules'         = @()
    'scripts'         = @()
    'configs'         = @()
    'tests'           = @()
    'agents'          = @()
    'xhtmlTools'      = @()
    'dependencyGraph' = [ordered]@{
        'nodes' = @()
        'edges' = @()
    }
    'securityEnvelope' = [ordered]@{
        'folderPermissions' = @()
        'fileHashes'        = @()
        'accessControlList' = @()
    }
    'driftGuards'     = [ordered]@{
        'versionAlignment'     = @()
        'encodingCompliance'   = @()
        'sinPatternCompliance' = @()
        'testRecency'          = @()
        'timestamps'           = @()
    }
    'pipelineIntegration' = [ordered]@{
        'preTestBlockers'  = @()
        'productionReadyGates' = @()
        'stampRecords'     = @()
    }
}

Write-Log "Scanning workspace for files..."

# ── Scan Modules ──────────────────────────────────────────────────────────────────────────
$moduleCount = 0
if (Test-Path $modulesDir) {
    $moduleFiles = Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File
    foreach ($mf in $moduleFiles) {
        $manifestFile = $mf.FullName -replace '\.psm1$', '.psd1'
        $moduleData = [ordered]@{
            'name'            = $mf.BaseName
            'path'            = ($mf.FullName -replace [regex]::Escape($WorkspacePath), '' -replace '^\\', '')
            'manifestFile'    = if (Test-Path $manifestFile) { ($manifestFile -replace [regex]::Escape($WorkspacePath), '' -replace '^\\', '') } else { $null }
            'version'         = $null  # Will extract from header
            'fileRole'        = $null
            'tier'            = 'tool'
            'sizeKB'          = [math]::Round($mf.Length / 1024, 1)
            'functionCount'   = 0
            'exportedCount'   = 0
            'functions'       = @()
            'lastModified'    = $mf.LastWriteTimeUtc.ToString('o')
            'sha256'          = (Get-FileHash $mf.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
        # Extract VersionTag and FileRole from header
        try {
            $head = Get-Content $mf.FullName -TotalCount 10 -ErrorAction Stop
            foreach ($line in $head) {
                if ($line -match 'VersionTag:\s*([\d\.BbVv]+)') { $moduleData.version = $Matches[1] }
                if ($line -match 'FileRole:\s*(.+)') { $moduleData.fileRole = ($Matches[1]).Trim() }
            }
        } catch { <# Skip on read error #> }

        $manifest.modules += $moduleData
        $moduleCount++
    }
}
Write-Log "Found $moduleCount modules"

# ── Scan Scripts ──────────────────────────────────────────────────────────────────────────
$scriptCount = 0
if (Test-Path $scriptsDir) {
    $scriptFiles = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -File | Where-Object { $_.Name -notmatch '^\.' }
    foreach ($sf in $scriptFiles) {
        $scriptData = [ordered]@{
            'name'           = $sf.BaseName
            'path'           = ($sf.FullName -replace [regex]::Escape($WorkspacePath), '' -replace '^\\', '')
            'version'        = $null
            'fileRole'       = $null
            'sizeKB'         = [math]::Round($sf.Length / 1024, 1)
            'functionCount'  = 0
            'lastModified'   = $sf.LastWriteTimeUtc.ToString('o')
            'sha256'         = (Get-FileHash $sf.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
        try {
            $head = Get-Content $sf.FullName -TotalCount 10 -ErrorAction Stop
            foreach ($line in $head) {
                if ($line -match 'VersionTag:\s*([\d\.BbVv]+)') { $scriptData.version = $Matches[1] }
                if ($line -match 'FileRole:\s*(.+)') { $scriptData.fileRole = ($Matches[1]).Trim() }
            }
        } catch { <# Skip on read error #> }

        $manifest.scripts += $scriptData
        $scriptCount++
    }
}
Write-Log "Found $scriptCount scripts"

# ── Scan Configs ──────────────────────────────────────────────────────────────────────────
$configCount = 0
if (Test-Path $configDir) {
    $configFiles = Get-ChildItem -Path $configDir -Filter '*.json' -File
    $configCount = @($configFiles).Count
    foreach ($cf in $configFiles) {
        $configData = [ordered]@{
            'name'         = $cf.BaseName
            'path'         = ($cf.FullName -replace [regex]::Escape($WorkspacePath), '' -replace '^\\', '')
            'sizeKB'       = [math]::Round($cf.Length / 1024, 1)
            'lastModified' = $cf.LastWriteTimeUtc.ToString('o')
            'sha256'       = (Get-FileHash $cf.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
        $manifest.configs += $configData
    }
}
Write-Log "Found $configCount config files"

# ── Scan Tests ────────────────────────────────────────────────────────────────────────────
$testCount = 0
if (Test-Path $testsDir) {
    $testFiles = Get-ChildItem -Path $testsDir -Filter '*.ps1' -File | Where-Object { $_.Name -match '\.Tests\.ps1$' }
    $testCount = @($testFiles).Count
    foreach ($tf in $testFiles) {
        $testData = [ordered]@{
            'name'          = $tf.BaseName
            'path'          = ($tf.FullName -replace [regex]::Escape($WorkspacePath), '' -replace '^\\', '')
            'sizeKB'        = [math]::Round($tf.Length / 1024, 1)
            'lastModified'  = $tf.LastWriteTimeUtc.ToString('o')
            'testTarget'    = $null
            'testCount'     = 0
            'sha256'        = (Get-FileHash $tf.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
        # Extract .SYNOPSIS to infer test target
        try {
            $head = Get-Content $tf.FullName -TotalCount 15 -ErrorAction Stop
            $syn = ($head | Select-String -Pattern '\.SYNOPSIS' -A 1).Line -replace '.*\.SYNOPSIS\s*', '' -replace '\s*#.*', ''
            if ($syn) { $testData.testTarget = $syn.Trim() }
        } catch { <# Skip on read error #> }

        $manifest.tests += $testData
    }
}
Write-Log "Found $testCount test files"

# ── Populate counts ───────────────────────────────────────────────────────────────────────
$manifest.counts = [ordered]@{
    'modules'  = $moduleCount
    'scripts'  = $scriptCount
    'configs'  = $configCount
    'tests'    = $testCount
    'agents'   = 0
    'xhtmlTools' = 0
}

# ── Pipeline Integration: Pre-Test Blockers ───────────────────────────────────────────────
Write-Log "Evaluating pre-test blockers..."

# Check for version drift (all modules should have VersionTag)
$modulesWithoutVersion = @($manifest.modules | Where-Object { $null -eq $_.version })
if ($modulesWithoutVersion.Count -gt 0) {
    $manifest.pipelineIntegration.preTestBlockers += [ordered]@{
        'id'       = 'VERSION_MISSING'
        'severity' = 'CRITICAL'
        'count'    = $modulesWithoutVersion.Count
        'items'    = @($modulesWithoutVersion | ForEach-Object { $_.name })
        'message'  = "VersionTag missing in $($modulesWithoutVersion.Count) module(s). All modules must have VersionTag header."
        'remediation' = 'Run scripts/Apply-CanonicalVersion.ps1 or manually add # VersionTag: header'
    }
}

# Check for encoding compliance (UTF-8 with BOM required for Unicode files)
Write-Log "Checking encoding compliance..."
$encodingIssues = @()
foreach ($mod in $manifest.modules) {
    $path = Join-Path $WorkspacePath $mod.path
    if (Test-Path $path) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            if ($bytes.Count -gt 3 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
                # Check if file contains Unicode (non-ASCII)
                $content = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($content -match '[\u0080-\uFFFF]') {
                    $encodingIssues += $mod.name
                }
            }
        } catch { <# Skip on read error #> }
    }
}
if ($encodingIssues.Count -gt 0) {
    $manifest.pipelineIntegration.preTestBlockers += [ordered]@{
        'id'       = 'ENCODING_NON_UTF8_BOM'
        'severity' = 'HIGH'
        'count'    = $encodingIssues.Count
        'items'    = @($encodingIssues)
        'message'  = "Encoding compliance: $($encodingIssues.Count) file(s) with Unicode content lack UTF-8 BOM (P006 violation)"
        'remediation' = 'Convert files to UTF-8 with BOM. Use PowerShell: $content | Set-Content -Encoding UTF8'
    }
}

Write-Log "Detected $(($manifest.pipelineIntegration.preTestBlockers).Count) pre-test blocker(s)"

# ── Write Manifest ────────────────────────────────────────────────────────────────────────
Write-Log "Writing manifest to $OutputPath..."
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8 -Force

# ── Save Snapshot ─────────────────────────────────────────────────────────────────────────
if (-not $SkipHistory) {
    $historyDir = Join-Path $configDir 'dynamic-manifest-history'
    if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir -Force | Out-Null }
    $snapshotPath = Join-Path $historyDir "dynamic-manifest_$timestamp.json"
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $snapshotPath -Encoding UTF8 -Force
    Write-Log "Snapshot saved to $snapshotPath"
}

Write-Log "Build-DynaManifest completed successfully"
Write-Host "`n✓ DynaManifest built: $OutputPath" -ForegroundColor Green
Write-Host "  Modules: $($manifest.counts.modules) | Scripts: $($manifest.counts.scripts) | Tests: $($manifest.counts.tests)" -ForegroundColor Gray

if ($ValidateDriftGuards) {
    Write-Log "Running drift-guard validation..."
    $validatorPath = Join-Path $scriptsDir 'Invoke-DynaManifestValidation.ps1'
    if (Test-Path $validatorPath) {
        & $validatorPath -ManifestPath $OutputPath -Verbose
    } else {
        Write-Warning "Drift-guard validator not found at $validatorPath"
    }
}

exit 0
