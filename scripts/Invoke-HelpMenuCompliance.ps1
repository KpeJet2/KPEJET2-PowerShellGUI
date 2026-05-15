# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: PipelineStep
<#
.SYNOPSIS
    Invoke-HelpMenuCompliance — Pipeline step: audit & stamp help-menu readiness.
.DESCRIPTION
    Reads config/help-menu-registry.json and scans every registered module/script
    for three compliance gates:
      1. Compact TODO marker present  (# TODO: HelpMenu | ...)
      2. Show-*Help function defined  (function Show-*Help {)
      3. Common switches wired        (-EventLevel, -LogToFile, -ShowRainbow)

    Modes:
      Audit   — report only, exit 0/1 on pass/fail
      Stamp   — inject compact TODO markers where missing (idempotent)
      Report  — write JSON summary to ~REPORTS/help-menu-compliance.json

    Designed as a CronAiAthon pipeline step (Step 3.x).
.PARAMETER Mode
    Audit | Stamp | Report  (default: Audit)
.PARAMETER WorkspacePath
    Root of the workspace (default: parent of $PSScriptRoot).
.PARAMETER DryRun
    Preview changes without writing files (Stamp mode).
.EXAMPLE
    .\Invoke-HelpMenuCompliance.ps1 -Mode Audit
.EXAMPLE
    .\Invoke-HelpMenuCompliance.ps1 -Mode Stamp -DryRun
.NOTES
    Pipeline integration: register via New-PipelineItem -Type ToDo
    Compact marker format (1 line):
      # TODO: HelpMenu | Show-<Fn> | Actions: A|B|C | Spec: config/help-menu-registry.json
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Audit','Stamp','Report')]
    [string]$Mode = 'Audit',

    [string]$WorkspacePath,

    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Paths ─────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}
$RegistryFile = Join-Path (Join-Path $WorkspacePath 'config') 'help-menu-registry.json'
$ModulesDir   = Join-Path $WorkspacePath 'modules'
$ScriptsDir   = Join-Path $WorkspacePath 'scripts'
$ReportDir    = Join-Path $WorkspacePath '~REPORTS'

if (-not (Test-Path -LiteralPath $RegistryFile)) {
    Write-Warning "Registry not found: $RegistryFile"
    exit 1
}

# ─── Load Registry ────────────────────────────────────────────────────────────
$registry = Get-Content -LiteralPath $RegistryFile -Raw -Encoding UTF8 | ConvertFrom-Json

# ─── Compact TODO Format ──────────────────────────────────────────────────────
# Single-line marker that replaces the old 13-line block.
# Format: # TODO: HelpMenu | Show-<Fn> | Actions: A|B|C | Spec: config/help-menu-registry.json
function Get-CompactTodoLine {
    param([string]$HelpFn, [string[]]$Actions)
    $actStr = $Actions -join '|'
    return "# TODO: HelpMenu | $HelpFn | Actions: $actStr | Spec: config/help-menu-registry.json"  # SIN-EXEMPT:P016 -- generates compliance markers, not stale debt
}

# ─── Scan a File ──────────────────────────────────────────────────────────────
function Test-FileCompliance {
    param(
        [string]$FilePath,
        [string]$HelpFn,
        [string[]]$Actions,
        [string]$ExpectedStatus
    )

    $result = [ordered]@{
        File       = $FilePath
        HelpFn     = $HelpFn
        HasTodo    = $false
        HasFn      = $false
        HasCommon  = $false
        Status     = $ExpectedStatus
        Compliant  = $false
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        $result.Status = 'FILE_NOT_FOUND'
        return $result
    }

    $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8

    # Gate 1: compact TODO marker
    $result.HasTodo = ($content -match 'TODO:\s*HelpMenu\s*\|')

    # Gate 2: Show-*Help function defined
    $escapedFn = [regex]::Escape($HelpFn)
    $result.HasFn = ($content -match "function\s+$escapedFn\b")

    # Gate 3: common switches (-EventLevel|-LogToFile|-ShowRainbow)
    $result.HasCommon = (
        ($content -match '\-EventLevel') -and
        ($content -match '\-LogToFile') -and
        ($content -match '\-ShowRainbow')
    )

    if ($result.HasFn -and $result.HasCommon) {
        $result.Compliant = $true
        $result.Status = 'DONE'
    } elseif ($result.HasTodo) {
        $result.Status = 'TODO'
    } else {
        $result.Status = 'MISSING'
    }

    return $result
}

# ─── Stamp Compact TODO ──────────────────────────────────────────────────────
function Add-CompactTodoMarker {
    param(
        [string]$FilePath,
        [string]$HelpFn,
        [string[]]$Actions
    )

    $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8

    # Already has compact marker — skip
    if ($content -match 'TODO:\s*HelpMenu\s*\|') { return $false }

    $compactLine = Get-CompactTodoLine -HelpFn $HelpFn -Actions $Actions

    # Remove old verbose block if present (the 13-line pattern)
    $oldBlockPattern = '(?m)^\s*#\s*[\u2550\u2500═─]+\r?\n\s*#\s*TODO:\s*Help Menu & Switch Enhancements\r?\n[\s\S]*?#\s*[\u2550\u2500═─]+\r?\n?'
    if ($content -match $oldBlockPattern) {
        $content = [regex]::Replace($content, $oldBlockPattern, "$compactLine`n")
    } else {
        # Insert after VersionTag header block (first blank line after line 2)
        $lines = $content -split "`n"
        $insertIdx = -1
        for ($i = 2; $i -lt [Math]::Min(20, @($lines).Count); $i++) {
            if ($lines[$i] -match '^\s*$') {
                $insertIdx = $i
                break
            }
        }
        if ($insertIdx -lt 0) { $insertIdx = 3 }

        $before = $lines[0..($insertIdx - 1)]
        $after  = if ($insertIdx -lt @($lines).Count) { $lines[$insertIdx..(@($lines).Count - 1)] } else { @() }
        $content = ($before + $compactLine + $after) -join "`n"
    }

    if (-not $DryRun) {
        Set-Content -LiteralPath $FilePath -Value $content -Encoding UTF8 -NoNewline
    }
    return $true
}

# ─── Main ─────────────────────────────────────────────────────────────────────
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results  = @()
$stamped  = 0
$total    = 0
$pass     = 0

# Process modules
$moduleSpecs = $registry.modules.PSObject.Properties
foreach ($prop in $moduleSpecs) {
    $name = $prop.Name
    $spec = $prop.Value
    $total++

    $path = Join-Path $ModulesDir "$name.psm1"
    $actions = @($spec.actions)
    $helpFn  = $spec.helpFn

    $r = Test-FileCompliance -FilePath $path -HelpFn $helpFn -Actions $actions -ExpectedStatus $spec.status

    if ($Mode -eq 'Stamp' -and (-not $r.HasTodo) -and (-not $r.HasFn)) {
        $didStamp = Add-CompactTodoMarker -FilePath $path -HelpFn $helpFn -Actions $actions
        if ($didStamp) {
            $stamped++
            $r.HasTodo = $true
            $r.Status  = 'TODO'
        }
    }

    if ($r.Compliant) { $pass++ }
    $results += $r
}

# Process scripts
$scriptSpecs = $registry.scripts.PSObject.Properties
foreach ($prop in $scriptSpecs) {
    $name = $prop.Name
    $spec = $prop.Value
    $total++

    $path = Join-Path $ScriptsDir "$name.ps1"
    $actions = @($spec.actions)
    $helpFn  = $spec.helpFn

    $r = Test-FileCompliance -FilePath $path -HelpFn $helpFn -Actions $actions -ExpectedStatus $spec.status
    if ($r.Compliant) { $pass++ }
    $results += $r
}

$sw.Stop()

# ─── Output ───────────────────────────────────────────────────────────────────
$summary = [ordered]@{
    timestamp   = (Get-Date -Format 'o')
    mode        = $Mode
    dryRun      = [bool]$DryRun
    total       = $total
    compliant   = $pass
    todo        = @($results | Where-Object { $_.Status -eq 'TODO' }).Count
    missing     = @($results | Where-Object { $_.Status -eq 'MISSING' }).Count
    done        = @($results | Where-Object { $_.Status -eq 'DONE' }).Count
    stamped     = $stamped
    elapsedMs   = $sw.ElapsedMilliseconds
}

# Console report
Write-Host ''
Write-Host '  HELP-MENU COMPLIANCE' -ForegroundColor Cyan
Write-Host '  --------------------' -ForegroundColor DarkGray

$statusColors = @{ DONE = 'Green'; TODO = 'Yellow'; MISSING = 'Red'; FILE_NOT_FOUND = 'DarkRed' }
foreach ($r in $results) {
    $icon = switch ($r.Status) { 'DONE' { '[OK]' }; 'TODO' { '[..]' }; default { '[!!]' } }
    $color = if ($statusColors.ContainsKey($r.Status)) { $statusColors[$r.Status] } else { 'Gray' }
    $short = Split-Path $r.File -Leaf
    Write-Host ("    {0} {1,-42} {2}" -f $icon, $short, $r.HelpFn) -ForegroundColor $color
}

Write-Host ''
Write-Host ("  Total: {0}  Done: {1}  TODO: {2}  Missing: {3}  Stamped: {4}  ({5}ms)" -f `
    $summary.total, $summary.done, $summary.todo, $summary.missing, $summary.stamped, $summary.elapsedMs) -ForegroundColor $(
    if ($summary.missing -gt 0) { 'Red' } elseif ($summary.todo -gt 0) { 'Yellow' } else { 'Green' }
)

# Report mode: write JSON
if ($Mode -eq 'Report') {
    if (-not (Test-Path -LiteralPath $ReportDir)) {
        New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null
    }
    $reportFile = Join-Path $ReportDir 'help-menu-compliance.json'
    $reportObj = [ordered]@{
        summary = $summary
        items   = $results
    }
    $reportObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding UTF8 -Force
    Write-Host "  Report: $reportFile" -ForegroundColor DarkGray
}

# Exit code: 0 = all compliant or all have TODO markers, 1 = missing entries
$exitCode = if ($summary.missing -gt 0) { 1 } else { 0 }
exit $exitCode

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





