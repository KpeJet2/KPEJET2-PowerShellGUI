# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Builder
#Requires -Version 5.1
<#
.SYNOPSIS
    Build or update the widget tools inventory (widget-tools-inventory.json).

.DESCRIPTION
    Scans the workspace for Show-*.ps1 scripts, validates existing inventory entries,
    detects new/missing tools, and optionally generates inventory stubs.

    Enforces consistent widget tool maintenance by:
      - Discovering all Show-*.ps1 files
      - Checking for menu integration in Main-GUI.ps1
      - Validating batch launchers & READMEs
      - Detecting version mismatches
      - Generating statistics

.PARAMETER WorkspacePath
    Root of the PwShGUI workspace. Auto-detected if run from scripts/.

.PARAMETER Report
    Generate read-only report without modifying inventory.json.

.PARAMETER AddMissing
    Automatically add stub entries for discovered Show-*.ps1 not in inventory.

.PARAMETER Validate
    Run consistency checks and report violations.

.EXAMPLE
    .\scripts\Build-ToolsInventory.ps1 -Report
    # Generate read-only discovery report

.EXAMPLE
    .\scripts\Build-ToolsInventory.ps1 -AddMissing
    # Add stub entries for any new Show-*.ps1 scripts

.EXAMPLE
    .\scripts\Build-ToolsInventory.ps1 -Validate
    # Check for inventory/filesystem/menu inconsistencies

.NOTES
    Author  : The Establishment
    Version : 2604.B2.V31.0
    Created : 04 Apr 2026
#>

[CmdletBinding(DefaultParameterSetName='Report')]
param(
    [string]$WorkspacePath = $PSScriptRoot,
    [Parameter(ParameterSetName='ReportMode')]
    [switch]$Report,
    [Parameter(ParameterSetName='UpdateMode')]
    [switch]$AddMissing,
    [Parameter(ParameterSetName='ValidateMode')]
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve workspace ──────────────────────────────────────────
if ($WorkspacePath -match '[/\\]scripts$') {
    $WorkspacePath = Split-Path $WorkspacePath
}

# ── Paths ──────────────────────────────────────────────────────
$inventoryPath = Join-Path $WorkspacePath 'config\widget-tools-inventory.json'
$scriptsDir    = Join-Path $WorkspacePath 'scripts'
$mainGuiPath   = Join-Path $WorkspacePath 'Main-GUI.ps1'

# ── Discover Show-* scripts ────────────────────────────────────
Write-Host "`n[DISCOVERY] Scanning for Show-*.ps1 scripts..." -ForegroundColor Cyan
$showScripts = Get-ChildItem $scriptsDir -Filter 'Show-*.ps1' -File -ErrorAction Stop

Write-Host "  Found $(@($showScripts).Count) Show-*.ps1 scripts:" -ForegroundColor Gray
foreach ($s in $showScripts) {
    Write-Host "    - $($s.Name)" -ForegroundColor DarkGray
}

# ── Load inventory ─────────────────────────────────────────────
if (-not (Test-Path $inventoryPath)) {
    Write-Host "`n[ERROR] Inventory not found: $inventoryPath" -ForegroundColor Red
    Write-Host "  Create a baseline inventory.json first." -ForegroundColor Yellow
    exit 1
}

Write-Host "`n[LOAD] Reading inventory: $inventoryPath" -ForegroundColor Cyan
$inventory = Get-Content $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10

Write-Host "  Current inventory: $(@($inventory.tools).Count) tools registered" -ForegroundColor Gray

# ── Cross-reference ────────────────────────────────────────────
Write-Host "`n[CROSS-REFERENCE] Matching filesystem to inventory..." -ForegroundColor Cyan

$registeredScripts = $inventory.tools | ForEach-Object { $_.scriptName }
$filesystemScripts = $showScripts | ForEach-Object { $_.Name }

$missing = $filesystemScripts | Where-Object { $_ -notin $registeredScripts }
$orphaned = $registeredScripts | Where-Object { $_ -notin $filesystemScripts }

if (@($missing).Count -gt 0) {
    Write-Host "`n  ⚠️  Scripts NOT in inventory:" -ForegroundColor Yellow
    foreach ($m in $missing) {
        Write-Host "    - $m" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ✅ All filesystem scripts are registered" -ForegroundColor Green
}

if (@($orphaned).Count -gt 0) {
    Write-Host "`n  ⚠️  Inventory entries with MISSING scripts:" -ForegroundColor Yellow
    foreach ($o in $orphaned) {
        Write-Host "    - $o" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ✅ All inventory entries have corresponding scripts" -ForegroundColor Green
}

# ── Menu integration check ─────────────────────────────────────
Write-Host "`n[MENU INTEGRATION] Checking Main-GUI.ps1..." -ForegroundColor Cyan

if (-not (Test-Path $mainGuiPath)) {
    Write-Host "  ⚠️  Main-GUI.ps1 not found, skipping menu check" -ForegroundColor Yellow
} else {
    $mainGuiContent = Get-Content $mainGuiPath -Raw -Encoding UTF8

    $menuIntegrated = @()
    $notIntegrated = @()

    foreach ($tool in $inventory.tools) {
        if ($null -ne $tool.menuPath) {
            # Check if script is dot-sourced or invoked in Main-GUI
            if ($mainGuiContent -match [regex]::Escape($tool.scriptName)) {
                $menuIntegrated += $tool.scriptName
            } else {
                $notIntegrated += $tool.scriptName
            }
        }
    }

    Write-Host "  ✅ Menu-integrated: $(@($menuIntegrated).Count)" -ForegroundColor Green
    if (@($notIntegrated).Count -gt 0) {
        Write-Host "  ⚠️  Inventory claims menu integration but script NOT found in Main-GUI:" -ForegroundColor Yellow
        foreach ($n in $notIntegrated) {
            Write-Host "    - $n" -ForegroundColor Yellow
        }
    }
}

# ── Batch launchers & READMEs ──────────────────────────────────
Write-Host "`n[ASSETS] Verifying batch launchers & READMEs..." -ForegroundColor Cyan

foreach ($tool in $inventory.tools) {
    if ($null -ne $tool.batchLauncher) {
        $batchPath = Join-Path $WorkspacePath $tool.batchLauncher
        if (-not (Test-Path $batchPath)) {
            Write-Host "  ⚠️  $($tool.scriptName): Missing batch launcher $($tool.batchLauncher)" -ForegroundColor Yellow
        }
    }

    if ($null -ne $tool.readme) {
        $readmePath = Join-Path $WorkspacePath $tool.readme
        if (-not (Test-Path $readmePath)) {
            Write-Host "  ⚠️  $($tool.scriptName): Missing README $($tool.readme)" -ForegroundColor Yellow
        }
    }
}

# ── Validation mode ────────────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'ValidateMode') {
    Write-Host "`n[VALIDATION] Running consistency checks..." -ForegroundColor Cyan

    $issues = 0

    # Check: All Show-*.ps1 registered
    if (@($missing).Count -gt 0) {
        $issues += @($missing).Count
    }

    # Check: No orphaned entries
    if (@($orphaned).Count -gt 0) {
        $issues += @($orphaned).Count
    }

    # Check: Version tags in scripts match inventory
    foreach ($tool in $inventory.tools) {
        $scriptPath = Join-Path $WorkspacePath $tool.path
        if (Test-Path $scriptPath) {
            $content = Get-Content $scriptPath -Raw -Encoding UTF8
            if ($content -match '# VersionTag:\s*(.+)') {
                $fileVersion = $Matches[1].Trim()
                if ($fileVersion -ne $tool.version) {
                    Write-Host "  ⚠️  $($tool.scriptName): Version mismatch (file=$fileVersion, inventory=$($tool.version))" -ForegroundColor Yellow
                    $issues++
                }
            }
        }
    }

    Write-Host "`n[SUMMARY] Validation complete: $issues issue(s) found" -ForegroundColor $(if ($issues -eq 0) { 'Green' } else { 'Yellow' })

    if ($issues -eq 0) {
        Write-Host "  ✅ Widget tools inventory is consistent" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "  ⚠️  Fix issues above to maintain inventory consistency" -ForegroundColor Yellow
        exit 1
    }
}

# ── Report mode (default) ──────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'ReportMode' -or $Report) {
    Write-Host "`n[REPORT] Widget Tools Inventory Summary" -ForegroundColor Cyan
    Write-Host "  Total tools registered  : $(@($inventory.tools).Count)" -ForegroundColor Gray
    Write-Host "  Total Show-*.ps1 files  : $(@($showScripts).Count)" -ForegroundColor Gray
    Write-Host "  Missing from inventory  : $(@($missing).Count)" -ForegroundColor $(if (@($missing).Count -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Orphaned inventory items: $(@($orphaned).Count)" -ForegroundColor $(if (@($orphaned).Count -gt 0) { 'Yellow' } else { 'Green' })

    Write-Host "`n[CATEGORIES]" -ForegroundColor Cyan
    foreach ($cat in $inventory.categories.PSObject.Properties) {
        $toolCount = @($cat.Value.tools).Count
        Write-Host "  $($cat.Name): $toolCount tool(s)" -ForegroundColor Gray
    }

    Write-Host "`n[LAUNCH MODES]" -ForegroundColor Cyan
    foreach ($mode in $inventory.statistics.byLaunchMode.PSObject.Properties) {
        Write-Host "  $($mode.Name): $($mode.Value)" -ForegroundColor Gray
    }

    Write-Host "`n[STATISTICS]" -ForegroundColor Cyan
    Write-Host "  Active tools         : $($inventory.statistics.totalActive)" -ForegroundColor Green
    Write-Host "  With batch launcher  : $($inventory.statistics.withBatchLauncher)" -ForegroundColor Gray
    Write-Host "  With README          : $($inventory.statistics.withReadme)" -ForegroundColor Gray
    Write-Host "  Require elevation    : $($inventory.statistics.requireElevation)" -ForegroundColor Yellow
}

# ── Add missing mode ───────────────────────────────────────────
if ($PSCmdlet.ParameterSetName -eq 'UpdateMode' -and $AddMissing) {
    if (@($missing).Count -eq 0) {
        Write-Host "`n[UPDATE] No missing scripts to add. Inventory is up to date." -ForegroundColor Green
        exit 0
    }

    Write-Host "`n[UPDATE] Adding $(@($missing).Count) missing tool(s) to inventory..." -ForegroundColor Cyan

    foreach ($missingScript in $missing) {
        $scriptPath = Join-Path $scriptsDir $missingScript
        $content = Get-Content $scriptPath -Raw -Encoding UTF8 -ErrorAction Continue

        # Extract version tag
        $version = if ($content -match '# VersionTag:\s*(.+)') { $Matches[1].Trim() } else { "UNKNOWN" }

        # Extract function name (assume Show-* function)
        $functionName = $missingScript -replace '\.ps1$', ''

        # Generate new tool ID
        $maxId = ($inventory.tools | ForEach-Object { [int]($_.id -replace 'tool-', '') } | Measure-Object -Maximum).Maximum
        $newId = "tool-$(($maxId + 1).ToString('000'))"

        $newTool = [PSCustomObject]@{
            id = $newId
            name = $functionName -replace 'Show-', '' -replace '(?<=[a-z])(?=[A-Z])', ' '
            scriptName = $missingScript
            functionName = $functionName
            path = "scripts/$missingScript"
            version = $version
            category = "Uncategorized"
            status = "ACTIVE"
            menuPath = $null
            menuLabel = $null
            description = "TODO: Add description"
            features = @()
            dependencies = @()
            launchMode = "standalone"
            singleInstance = $false
            requiresElevation = $false
            batchLauncher = $null
            readme = $null
            lastUpdated = (Get-Date -Format 'yyyy-MM-dd')
            maintainer = "The Establishment"
        }

        $inventory.tools += $newTool
        Write-Host "  ✅ Added $missingScript as $newId" -ForegroundColor Green
    }

    # Update total count
    $inventory.meta.totalTools = @($inventory.tools).Count
    $inventory.meta.generated = (Get-Date -Format 'o')

    # Save inventory
    Write-Host "`n[SAVE] Writing updated inventory to $inventoryPath" -ForegroundColor Cyan
    $inventory | ConvertTo-Json -Depth 10 | Set-Content $inventoryPath -Encoding UTF8 -Force

    Write-Host "  ✅ Inventory updated successfully" -ForegroundColor Green
    Write-Host "`n  ⚠️  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "    1. Edit config/widget-tools-inventory.json to fill in descriptions, categories, menu paths" -ForegroundColor Gray
    Write-Host "    2. Add menu entries to Main-GUI.ps1 if needed" -ForegroundColor Gray
    Write-Host "    3. Run Build-AgenticManifest.ps1 to rebuild agentic-manifest.json" -ForegroundColor Gray
}

Write-Host ""

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





