# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 4 entries)
#Requires -Version 5.1

<#
.SYNOPSIS
# --- Structured lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Started: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
    Standalone Module Management tool for the PwShGUI workspace.

.DESCRIPTION
    Independent of the dependency matrix and visualisation, this tool:
    - Scans all PSModulePath directories for installed modules
    - Scans workspace modules/ and scripts/ subfolders for .psm1/.psd1 files
    - Cross-references with script dependency data (if available) to match
      which scripts reference which modules
    - Lists installed, missing, and errored modules with folder counts
    - Shows repository sources where modules were obtained
    - Exports an installer script to install all missing public modules
    - Exports a full module inventory (installed + missing) as CSV/JSON

.PARAMETER WorkspacePath
    Root directory of the workspace. Defaults to parent of scripts folder.

.PARAMETER ReportPath
    Directory for output reports. Defaults to ~REPORTS under workspace.

.PARAMETER ExportInstaller
    Generate a self-contained installer script for all missing modules.

.PARAMETER ExportInventory
    Export full module inventory as JSON and CSV.

.PARAMETER WhatIfOnly
    Show what would happen without making changes.

.PARAMETER AutoInstallMissing
    Automatically install missing public modules from preferred repositories
    (LOCAL first when available, then PSGallery).

.PARAMETER UseWorkspaceModules
    Load workspace-local modules where available.

.EXAMPLE
    .\scripts\Invoke-ModuleManagement.ps1
    # Report on all installed and missing modules.

.EXAMPLE
    .\scripts\Invoke-ModuleManagement.ps1 -ExportInstaller -ExportInventory
    # Generate installer and full inventory files.

.EXAMPLE
    .\scripts\Invoke-ModuleManagement.ps1 -AutoInstallMissing -WhatIfOnly
    # Dry-run showing what would be installed from preferred repositories.
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$ReportPath,
    [switch]$ExportInstaller,
    [switch]$ExportInventory,
    [switch]$WhatIfOnly,
    [switch]$AutoInstallMissing,
    [switch]$UseWorkspaceModules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Output ("Module management error: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo) { Write-Output $_.InvocationInfo.PositionMessage }
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# PATH SETUP
# ═══════════════════════════════════════════════════════════════════════════════

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $scriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    $WorkspacePath  = Split-Path -Parent $scriptRootPath
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $WorkspacePath '~REPORTS'
}
if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║              MODULE MANAGEMENT TOOL                        ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

function Write-PercentRow {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param(
        [int]$Percent,
        [string]$Label
    )
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    $color = if ($p -lt 35) { 'Red' } elseif ($p -lt 70) { 'Yellow' } else { 'Green' }
    Write-Host ("[{0,3}%] {1}" -f $p, $Label) -ForegroundColor $color
}

function Get-RepositoryHint {
    param(
        [string]$ModuleRoot
    )

    if ([string]::IsNullOrWhiteSpace($ModuleRoot)) { return $null }
    $root = $ModuleRoot.ToLowerInvariant()

    if (
        $root -like '*\system32\windowspowershell\v1.0\modules*' -or
        $root -like '*\program files\windowspowershell\modules*' -or
        $root -like '*\program files\powershell\*\modules*'
    ) {
        return 'built-in/system'
    }

    if (
        $root -like '*\documents\windowspowershell\modules*' -or
        $root -like '*\documents\powershell\modules*'
    ) {
        return 'manual/user-scope'
    }

    return 'manual/local'
}

Write-PercentRow -Percent 2 -Label 'Starting module maintenance scan'

# Helper: Ensure PowerShellGet module available
function Ensure-PowerShellGet {
    try {
        if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
            Write-Host '[INFO] PowerShellGet not present. Attempting to install via Install-Module...' -ForegroundColor Cyan
            Install-Module -Name PowerShellGet -Scope CurrentUser -Force -ErrorAction Stop
        }
        try { Import-Module PowerShellGet -ErrorAction Stop } catch { Write-Warning "Ensure-PowerShellGet: Import-Module failed: $($_.Exception.Message)" }
        return $true
    } catch {
        Write-Warning "Ensure-PowerShellGet: failed to install/import PowerShellGet: $($_.Exception.Message)"
        return $false
    }
}

# Helper: Ensure NuGet provider is available for Install-Module/Install-PackageProvider
function Ensure-NuGetProvider {
    try {
        $prov = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $prov) {
            Write-Host '[INFO] NuGet provider not found. Installing PackageProvider NuGet...' -ForegroundColor Cyan
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop
        }
        return $true
    } catch {
        Write-Warning "Ensure-NuGetProvider: failed to install/import NuGet provider: $($_.Exception.Message)"
        return $false
    }
}

# Helper: Close any top-level windows that appear to be a missing-modules interactive dialog
function Close-MissingModulesGui {
    try {
        Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Win32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    public const uint WM_CLOSE = 0x0010;
}
"@ -ErrorAction SilentlyContinue

        $closed = 0
        $found = [System.Collections.Generic.List[object]]::new()
        $callback = [Win32+EnumWindowsProc]{
            param($hWnd, $lParam)
            if (-not [Win32]::IsWindowVisible($hWnd)) { return $true }
            $len = [Win32]::GetWindowTextLength($hWnd)
            if ($len -le 0) { return $true }
            $sb = New-Object System.Text.StringBuilder ($len + 1)
            [Win32]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
            $title = $sb.ToString()
            if ($title -match '(?i)missing|module|install|required') {
                try { [Win32]::SendMessage($hWnd, [Win32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null; $found.Add($title); $closed++ } catch { <# Intentional: non-fatal -- WM_CLOSE may fail on protected windows #> }
            }
            return $true
        }
        [Win32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        if ($closed -gt 0) { Write-Host "[INFO] Closed $closed interactive window(s): $($found -join ', ')" -ForegroundColor Cyan }
        return $closed -gt 0
    } catch {
        Write-Warning "Close-MissingModulesGui: $($_.Exception.Message)"
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1) SCAN PSModulePath -- every folder the system can load modules from
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host '── Scanning PSModulePath directories ──' -ForegroundColor Yellow
Write-PercentRow -Percent 12 -Label 'Scanning PSModulePath'
# Exclusion patterns applied to PSModulePath scanning (same as workspace)
$sysExcludePatterns = @(
    "$WorkspacePath\.git\*",
    "$WorkspacePath\.history\*",
    "$WorkspacePath\~REPORTS\archive\*"
)

$psModPaths = @(($env:PSModulePath -split ';') | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_ -ErrorAction SilentlyContinue)
})

$folderModuleCount = @{}  # path → count of modules
$allInstalledModules = @{}  # lowercase-name → [pscustomobject]

foreach ($modRoot in $psModPaths) {
    $count = 0
    $subDirs = @(Get-ChildItem -Path $modRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $subDirs) {
        $modName = $dir.Name
        $modKey  = $modName.ToLowerInvariant()

        # Look for .psd1 or .psm1 inside the folder
        $manifest = Get-ChildItem -Path $dir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $psm      = Get-ChildItem -Path $dir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $manifest -and -not $psm) {
            # Check one level deeper (versioned folder)
            $verDir = Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($verDir) {
                $manifest = Get-ChildItem -Path $verDir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                $psm      = Get-ChildItem -Path $verDir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }

        if (-not $manifest -and -not $psm) { continue }
        $count++

        $version    = $null
        $repository = $null
        $author     = $null
        $description = $null
        $loadError  = $null

        if ($manifest) {
            try {
                $data = Import-PowerShellDataFile -Path $manifest.FullName -ErrorAction Stop
                $version     = if ($data.ContainsKey('ModuleVersion'))  { [string]$data.ModuleVersion }  else { $null }
                $author      = if ($data.ContainsKey('Author'))         { [string]$data.Author }         else { $null }
                $description = if ($data.ContainsKey('Description'))    { [string]$data.Description }    else { $null }
            } catch {
                $loadError = $_.Exception.Message
            }
        }

        # Try to find repository info from PSGetModuleInfo.xml
        $psgetXml = Join-Path $dir.FullName 'PSGetModuleInfo.xml'
        if (-not (Test-Path $psgetXml)) {
            # Check versioned subfolder
            $verDirs = @(Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue)
            foreach ($vd in $verDirs) {
                $candidate = Join-Path $vd.FullName 'PSGetModuleInfo.xml'
                if (Test-Path $candidate) { $psgetXml = $candidate; break }
            }
        }
        if (Test-Path $psgetXml) {
            try {
                $xmlContent = [xml](Get-Content $psgetXml -Raw -ErrorAction SilentlyContinue)
                $repoNode = $xmlContent.SelectSingleNode('//S[@N="Repository"]')
                if ($repoNode) { $repository = $repoNode.InnerText }
            } catch { <# Intentional: non-fatal #> }
        }

        if (-not $repository) {
            $repository = Get-RepositoryHint -ModuleRoot $modRoot
        }

        if (-not $allInstalledModules.ContainsKey($modKey)) {
            $allInstalledModules[$modKey] = [pscustomobject]@{
                module      = $modName
                version     = $version
                author      = $author
                description = $description
                repository  = $repository
                path        = $dir.FullName
                folderRoot  = $modRoot
                loadError   = $loadError
                status      = if ($loadError) { 'error' } else { 'installed' }
            }
        }
    }
    $folderModuleCount[$modRoot] = $count
}

Write-Host ''
Write-Host "PSModulePath directories ($($psModPaths.Count) folders scanned):" -ForegroundColor White
foreach ($p in $psModPaths) {
    $c = if ($folderModuleCount.ContainsKey($p)) { $folderModuleCount[$p] } else { 0 }
    Write-Host "  $c modules  $p" -ForegroundColor Gray
}
$totalInstalled = $allInstalledModules.Count
Write-Host "Total distinct installed modules: $totalInstalled" -ForegroundColor Green
Write-Host ''

# ═══════════════════════════════════════════════════════════════════════════════
# 2) SCAN WORKSPACE -- modules/ and scripts/ subfolders
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host '── Scanning workspace modules & scripts ──' -ForegroundColor Yellow
Write-PercentRow -Percent 30 -Label 'Scanning workspace modules'
$workspaceModules = @{}  # lowercase-name → [pscustomobject]
$wsScanPaths = @(
    (Join-Path $WorkspacePath 'modules'),
    (Join-Path $WorkspacePath 'scripts'),
    (Join-Path $WorkspacePath 'agents')
)

# Exclusion patterns (same as Script Dependency Matrix)
$wsExcludePatterns = @(
    "$WorkspacePath\.git\*",
    "$WorkspacePath\.history\*",
    "$WorkspacePath\~REPORTS\archive\*"
)

$wsFolderCounts = @{}
foreach ($wsRoot in $wsScanPaths) {
    $count = 0
    if (Test-Path $wsRoot) {
        $wsFiles = @(Get-ChildItem -Path $wsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $f = $_
            if ($f.Extension -notin @('.psm1', '.psd1')) { return $false }
            foreach ($excl in $wsExcludePatterns) {
                if ($f.FullName -like $excl) { return $false }
            }
            return $true
        })
        foreach ($wf in $wsFiles) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($wf.Name)
            if ([string]::IsNullOrWhiteSpace($baseName)) { continue }
            $wsKey = $baseName.ToLowerInvariant()
            $count++

            $wsVersion     = $null
            $wsAuthor      = $null
            $wsDescription = $null
            if ($wf.Extension -ieq '.psd1') {
                try {
                    $wsManifest = Import-PowerShellDataFile -Path $wf.FullName -ErrorAction Stop
                    if ($wsManifest.ContainsKey('ModuleVersion')) { $wsVersion     = [string]$wsManifest.ModuleVersion }
                    if ($wsManifest.ContainsKey('Author'))        { $wsAuthor      = [string]$wsManifest.Author }
                    if ($wsManifest.ContainsKey('Description'))   { $wsDescription = [string]$wsManifest.Description }
                } catch { <# Intentional: non-fatal #> }
            }

            if (-not $workspaceModules.ContainsKey($wsKey)) {
                $workspaceModules[$wsKey] = [pscustomobject]@{
                    module      = $baseName
                    version     = $wsVersion
                    author      = $wsAuthor
                    description = $wsDescription
                    path        = $wf.FullName
                    folder      = $wsRoot
                }
            }
        }
    }
    $relPath = $wsRoot.Substring($WorkspacePath.Length).TrimStart('\')
    $wsFolderCounts[$relPath] = $count
}

Write-Host ''
foreach ($kv in $wsFolderCounts.GetEnumerator()) {
    Write-Host "  $($kv.Value) module files  $($kv.Key)\" -ForegroundColor Gray
}
Write-Host "Total workspace module files: $(($wsFolderCounts.Values | Measure-Object -Sum).Sum)" -ForegroundColor Green
Write-Host ''

# Build an ordered repository list for Install-Module operations.
function Get-InstallRepositoryOrder {
    $preferred = @('LOCAL', 'PSGallery')
    $ordered = New-Object 'System.Collections.Generic.List[string]'

    $repos = @(Get-PSRepository -ErrorAction SilentlyContinue)
    foreach ($name in $preferred) {
        $match = $repos | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($match) { $ordered.Add($name) | Out-Null }
    }

    if ($ordered.Count -eq 0) {
        foreach ($repo in $repos) {
            if (-not [string]::IsNullOrWhiteSpace($repo.Name)) {
                $ordered.Add([string]$repo.Name) | Out-Null
            }
        }
    }

    return @($ordered | Select-Object -Unique)
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3) CROSS-REFERENCE WITH SCRIPT DEPENDENCY DATA (if available)
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host '── Checking for script dependency data ──' -ForegroundColor Yellow
Write-PercentRow -Percent 48 -Label 'Loading script dependency cross-reference'
$scriptRefData = $null
$moduleRefPointer = Join-Path $ReportPath 'module-references-pointer.json'

if (Test-Path $moduleRefPointer) {
    try {
        $pointer = Get-Content $moduleRefPointer -Raw | ConvertFrom-Json
        $refFile = Join-Path $ReportPath $pointer.filename
        if (Test-Path $refFile) {
            $scriptRefData = Get-Content $refFile -Raw | ConvertFrom-Json
            Write-Host "  Script reference data loaded: $($pointer.filename)" -ForegroundColor Green
            Write-Host "  Module references: $($scriptRefData.summary.moduleReferenceCount)  |  Distinct: $($scriptRefData.summary.distinctModuleCount)" -ForegroundColor Gray
        } else {
            Write-Host "  Reference file not found: $($pointer.filename)" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  Could not read reference pointer: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
} else {
    # Try legacy pointer
    $legacyPointer = Join-Path $ReportPath 'module-dependency-matrix-pointer.json'
    if (Test-Path $legacyPointer) {
        try {
            $pointer = Get-Content $legacyPointer -Raw | ConvertFrom-Json
            $refFile = Join-Path $ReportPath $pointer.filename
            if (Test-Path $refFile) {
                $scriptRefData = Get-Content $refFile -Raw | ConvertFrom-Json
                Write-Host "  Script reference data loaded (legacy): $($pointer.filename)" -ForegroundColor Green
            }
        } catch { <# Intentional: non-fatal #> }
    }
}

if (-not $scriptRefData) {
    Write-Host '  No script dependency data available. Run Script Dependency Matrix first for cross-referencing.' -ForegroundColor DarkYellow
    Write-Host '  Module management will continue with system and workspace scans only.' -ForegroundColor DarkYellow
}
Write-Host ''

# ═══════════════════════════════════════════════════════════════════════════════
# 4) BUILD CONSOLIDATED MODULE INVENTORY
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host '── Building module inventory ──' -ForegroundColor Yellow
Write-PercentRow -Percent 64 -Label 'Building consolidated module inventory'
$inventory = New-Object 'System.Collections.Generic.List[object]'
$missingList = New-Object 'System.Collections.Generic.List[object]'
$workspaceAvailableList = New-Object 'System.Collections.Generic.List[object]'
$errorList  = New-Object 'System.Collections.Generic.List[object]'

# First: add all installed modules
foreach ($kv in $allInstalledModules.GetEnumerator()) {
    $mod = $kv.Value
    $wsMatch = if ($workspaceModules.ContainsKey($kv.Key)) { $workspaceModules[$kv.Key] } else { $null }
    $scriptRefs = 0
    $referencedBy = @()

    if ($scriptRefData -and $scriptRefData.modules) {
        $refMatch = $scriptRefData.modules | Where-Object { $_.module -ieq $mod.module } | Select-Object -First 1
        if ($refMatch) {
            $scriptRefs = [int]$refMatch.referencedByScriptCount
            if ($refMatch.references) {
                $referencedBy = @($refMatch.references | Select-Object -ExpandProperty source -Unique)
            }
        }
    }

    $inventory.Add([pscustomobject]@{
        module          = $mod.module
        status          = $mod.status
        version         = $mod.version
        author          = $mod.author
        repository      = $mod.repository
        installPath     = $mod.path
        workspacePath   = if ($wsMatch) { $wsMatch.path } else { $null }
        scriptRefCount  = $scriptRefs
        referencedBy    = $referencedBy
        loadError       = $mod.loadError
    }) | Out-Null
}

# Second: add modules referenced by scripts but NOT installed
if ($scriptRefData -and $scriptRefData.modules) {
    foreach ($refMod in $scriptRefData.modules) {
        $refKey = $refMod.module.ToLowerInvariant()
        if ($allInstalledModules.ContainsKey($refKey)) { continue }

        $wsMatch = if ($workspaceModules.ContainsKey($refKey)) { $workspaceModules[$refKey] } else { $null }
        $referencedBy = @()
        if ($refMod.references) {
            $referencedBy = @($refMod.references | Select-Object -ExpandProperty source -Unique)
        }

        $modStatus = 'missing'
        if ($wsMatch) { $modStatus = 'workspace-available' }

        $entry = [pscustomobject]@{
            module          = $refMod.module
            status          = $modStatus
            version         = $null
            author          = $null
            repository      = $null
            installPath     = $null
            workspacePath   = if ($wsMatch) { $wsMatch.path } else { $null }
            scriptRefCount  = [int]$refMod.referencedByScriptCount
            referencedBy    = $referencedBy
            loadError       = $null
        }

        $inventory.Add($entry) | Out-Null
        if ($modStatus -eq 'missing') {
            $missingList.Add($entry) | Out-Null
        } else {
            $workspaceAvailableList.Add($entry) | Out-Null
        }
    }
}

# Third: add workspace modules not installed and not referenced by scripts
foreach ($kv in $workspaceModules.GetEnumerator()) {
    $already = $inventory | Where-Object { $_.module -ieq $kv.Value.module } | Select-Object -First 1
    if ($already) { continue }

    $entry = [pscustomobject]@{
        module          = $kv.Value.module
        status          = 'workspace-only'
        version         = $kv.Value.version
        author          = $null
        repository      = 'workspace'
        installPath     = $null
        workspacePath   = $kv.Value.path
        scriptRefCount  = 0
        referencedBy    = @()
        loadError       = $null
    }
    $inventory.Add($entry) | Out-Null
}

# Collect errors
foreach ($mod in $inventory) {
    if ($mod.loadError) { $errorList.Add($mod) | Out-Null }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5) DISPLAY SUMMARY REPORT
# ═══════════════════════════════════════════════════════════════════════════════

$installedCount = @($inventory | Where-Object { $_.status -eq 'installed' }).Count
$missingCount   = @($inventory | Where-Object { $_.status -eq 'missing' }).Count
$wsAvailCount   = @($inventory | Where-Object { $_.status -eq 'workspace-available' }).Count
$wsOnlyCount    = @($inventory | Where-Object { $_.status -eq 'workspace-only' }).Count
$errorCount     = $errorList.Count

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                 MODULE INVENTORY SUMMARY                   ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Total modules tracked:   $($inventory.Count)" -ForegroundColor White
Write-Host "  Installed:               $installedCount" -ForegroundColor Green
Write-Host "  Missing:                 $missingCount" -ForegroundColor $(if ($missingCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Workspace-available:     $wsAvailCount" -ForegroundColor Yellow
Write-Host "  Workspace-only:          $wsOnlyCount" -ForegroundColor Yellow
Write-Host "  Load errors:             $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

# ── Module folders breakdown ──
Write-Host '── Modules per scanned folder ──' -ForegroundColor Yellow
foreach ($p in $psModPaths) {
    $c = if ($folderModuleCount.ContainsKey($p)) { $folderModuleCount[$p] } else { 0 }
    $label = $p
    if ($p -like '*\WindowsPowerShell\*') { $label = "[User]  $p" }
    elseif ($p -like '*\PowerShell\*' -and $p -like '*Documents*') { $label = "[User-PS7]  $p" }
    elseif ($p -like '*\system32\*' -or $p -like '*\Program Files*') { $label = "[System]  $p" }
    else { $label = "[Other]  $p" }
    Write-Host "  $c  $label" -ForegroundColor Gray
}
foreach ($kv in $wsFolderCounts.GetEnumerator()) {
    Write-Host "  $($kv.Value)  [Workspace]  $($kv.Key)\" -ForegroundColor Gray
}
Write-Host ''

# ── Missing modules ──
if ($missingCount -gt 0) {
    Write-Host '── Missing Modules ──' -ForegroundColor Red
    foreach ($m in ($missingList | Sort-Object module)) {
        $wsFlag = if ($m.workspacePath) { ' (workspace-available)' } else { '' }
        $refStr = if ($m.scriptRefCount -gt 0) { " [referenced by $($m.scriptRefCount) script(s)]" } else { '' }
        Write-Host "  MISSING: $($m.module)$wsFlag$refStr" -ForegroundColor Red
    }
    Write-Host ''
}

# ── Workspace-available modules ──
if ($wsAvailCount -gt 0) {
    Write-Host '── Workspace-Available Modules (Not Installed) ──' -ForegroundColor Yellow
    foreach ($m in ($workspaceAvailableList | Sort-Object module)) {
        $refStr = if ($m.scriptRefCount -gt 0) { " [referenced by $($m.scriptRefCount) script(s)]" } else { '' }
        Write-Host "  WORKSPACE: $($m.module)$refStr" -ForegroundColor Yellow
    }
    Write-Host ''
}

# ── Errored modules ──
if ($errorCount -gt 0) {
    Write-Host '── Modules with Load Errors ──' -ForegroundColor Red
    foreach ($m in ($errorList | Sort-Object module)) {
        Write-Host "  ERROR: $($m.module) -- $($m.loadError)" -ForegroundColor Red
    }
    Write-Host ''
}

# ── Repository breakdown ──
Write-Host '── Repository Sources ──' -ForegroundColor Yellow
$repoGroups = $inventory | Where-Object { $_.repository } | Group-Object repository | Sort-Object Count -Descending
if ($repoGroups) {
    foreach ($rg in $repoGroups) {
        Write-Host "  $($rg.Count) modules  from  $($rg.Name)" -ForegroundColor Gray
    }
} else {
    Write-Host '  No repository metadata found (modules installed locally or from workspace)' -ForegroundColor DarkGray
}
$noRepo = @($inventory | Where-Object { -not $_.repository -and $_.status -eq 'installed' }).Count
if ($noRepo -gt 0) {
    Write-Host "  $noRepo modules  no repository metadata (built-in or manually installed)" -ForegroundColor DarkGray
}
Write-Host ''

# ── Script cross-reference ──
if ($scriptRefData) {
    $refdMods = @($inventory | Where-Object { $_.scriptRefCount -gt 0 } | Sort-Object scriptRefCount -Descending)
    if ($refdMods.Count -gt 0) {
        Write-Host '── Modules Referenced by Scripts ──' -ForegroundColor Yellow
        foreach ($rm in $refdMods) {
            $statusColor = switch -Wildcard ($rm.status) {
                'installed' { 'Green' }
                'missing*'  { 'Red' }
                default     { 'Yellow' }
            }
            Write-Host "  $($rm.status.PadRight(30)) $($rm.module.PadRight(35)) refs: $($rm.scriptRefCount)" -ForegroundColor $statusColor
        }
        Write-Host ''
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6) AUTO-INSTALL MISSING MODULES
# ═══════════════════════════════════════════════════════════════════════════════

if ($AutoInstallMissing -and ($missingCount -gt 0 -or $wsAvailCount -gt 0)) {
    Write-Host '── Auto-Install Missing Modules ──' -ForegroundColor Cyan
    Write-PercentRow -Percent 78 -Label 'Auto-install phase'
    # Ensure package infra available to avoid interactive provider prompts
    $havePSGet = Ensure-PowerShellGet
    $haveNuGet = Ensure-NuGetProvider
    $installCandidates = @($missingList) + @($workspaceAvailableList)
    foreach ($m in ($installCandidates | Sort-Object module)) {
        # Skip workspace-only modules that can't be installed from gallery
        if ($m.workspacePath -and $UseWorkspaceModules) {
            $wsRoot = Split-Path -Parent (Split-Path -Parent $m.workspacePath)
            if ($WhatIfOnly) {
                Write-Host "  WHATIF: Load workspace module $($m.module) from $wsRoot" -ForegroundColor DarkYellow
            } else {
                try {
                    if ($env:PSModulePath -notlike "*$wsRoot*") {
                        $env:PSModulePath = "$wsRoot;$env:PSModulePath"
                    }
                    Import-Module -Name $m.module -ErrorAction Stop
                    Write-Host "  LOADED: $($m.module) from workspace ($wsRoot)" -ForegroundColor Yellow
                } catch {
                    Write-Warning "  Failed to load workspace module $($m.module): $($_.Exception.Message)"
                }
            }
            continue
        }

        if ($WhatIfOnly) {
            $repoOrder = @(Get-InstallRepositoryOrder)
            if ($repoOrder.Count -gt 0) {
                Write-Host "  WHATIF: Install-Module -Name $($m.module) -Scope CurrentUser (repo order: $($repoOrder -join ', '))" -ForegroundColor Cyan
            } else {
                Write-Host "  WHATIF: Install-Module -Name $($m.module) -Scope CurrentUser (no explicit repository available)" -ForegroundColor Cyan
            }
        } else {
            $repoOrder = @(Get-InstallRepositoryOrder)
            $installed = $false
            $attemptErrors = New-Object 'System.Collections.Generic.List[string]'


            # Sanitize module token: strip flags and trailing params, skip placeholder/variable tokens
            $rawToken = $m.module
            $moduleToken = ($rawToken -split '\s+')[0]
            $moduleToken = $moduleToken.Trim("'", '"', [char]13, [char]10)
            if ($moduleToken -match '^\$' -or [string]::IsNullOrWhiteSpace($moduleToken)) {
                Write-Warning "  Skipping invalid/placeholder module token: '$rawToken'"
                continue
            }
            # Allow names matching typical PowerShell module name characters only
            if (-not ($moduleToken -match '^[A-Za-z0-9_.-]+$')) {
                Write-Warning "  Skipping module with unsafe characters: '$rawToken' -> sanitized '$moduleToken'"
                continue
            }

            # PSGallery/non-PSGallery mapping/whitelist (from modules/README.md)
            $psgalleryModules = @(
                'Pester','Microsoft.PowerShell.SecretStore','Microsoft.PowerShell.SecretManagement','Az.Accounts','Az.Billing','Az.KeyVault','Az.Storage','Az.Sql','Az.Resources','Az.Compute','AzureAD','MSOnline','SqlServer','SimplySQL','DFSN','PrintManagement','NetTCPIP','VMware.VimAutomation.Core','VMware.VimAutomation.Storage','VMware.VumAutomation','WindowsServerBackup','ActiveDirectory','ExchangeOnlineManagement','SkypeOnlineConnector','microsoftteams','Microsoft.Graph.Users','Microsoft.Graph.Groups','Microsoft.Graph.Teams','Microsoft.Graph.Mail','Microsoft.Graph.Authentication','Microsoft.Graph.Identity.DirectoryManagement','Microsoft.Graph.Identity.SignIns','Microsoft.Graph.DeviceManagement','Microsoft.Graph.DeviceManagement.Functions','Microsoft.Graph.Users.Actions'
            )
            # Workspace-only modules (from modules/README.md)
            $workspaceModules = @(
                'PwShGUICore','PwShGUI-IntegrityCore','PwShGUI-Theme','PwShGUI-VersionManager','PwShGUI-TrayHost','PwShGUI-PSVersionStandards','Get-LaunchTelemetry','AssistedSASC','SASC-Adapters','PKIChainManager','UserProfileManager','AVPN-Tracker','PwShGUI-ConvoVault','PwShGUI_AutoIssueFinder','PwShGUI-SchemaTranslator','_TEMPLATE-Module','CronAiAthon-Pipeline','CronAiAthon-Scheduler','CronAiAthon-EventLog','CronAiAthon-BugTracker','SINGovernance','RE-memorAiZ','WorkspaceIntentReview'
            )
            if ($workspaceModules -contains $moduleToken) {
                Write-Host "  Workspace module '$moduleToken' -- not installed from PSGallery, skip online install." -ForegroundColor Yellow
                continue
            }
            if (-not ($psgalleryModules -contains $moduleToken)) {
                Write-Warning "  Module '$moduleToken' is not in PSGallery or workspace list. Skipping online install."
                continue
            }

            if ($repoOrder.Count -gt 0) {
                foreach ($repoName in $repoOrder) {
                    try {
                        Install-Module -Name $moduleToken -Repository $repoName -Scope CurrentUser -Force -ErrorAction Stop
                        Write-Host "  INSTALLED: $moduleToken from $repoName" -ForegroundColor Green
                        $installed = $true
                        break
                    } catch {
                        # Try to close any interactive missing-modules GUI and retry once
                        $attemptErrors.Add("${repoName}: $($_.Exception.Message)") | Out-Null
                        Close-MissingModulesGui | Out-Null
                        try {
                            Install-Module -Name $moduleToken -Repository $repoName -Scope CurrentUser -Force -ErrorAction Stop
                            Write-Host "  INSTALLED (retry): $moduleToken from $repoName" -ForegroundColor Green
                            $installed = $true
                            break
                        } catch {
                            $attemptErrors.Add("${repoName}-retry: $($_.Exception.Message)") | Out-Null
                        }
                    }
                }
            }

            if (-not $installed) {
                try {
                    Install-Module -Name $moduleToken -Scope CurrentUser -Force -ErrorAction Stop
                    Write-Host "  INSTALLED: $moduleToken (default repository resolution)" -ForegroundColor Green
                    $installed = $true
                } catch {
                    $attemptErrors.Add("default: $($_.Exception.Message)") | Out-Null
                    # Attempt to close interactive prompts and retry once
                    Close-MissingModulesGui | Out-Null
                    try {
                        Install-Module -Name $moduleToken -Scope CurrentUser -Force -ErrorAction Stop
                        Write-Host "  INSTALLED (retry): $moduleToken (default)" -ForegroundColor Green
                        $installed = $true
                    } catch {
                        $attemptErrors.Add("default-retry: $($_.Exception.Message)") | Out-Null
                    }
                }
            }

            if (-not $installed) {
                $details = if ($attemptErrors.Count -gt 0) { $attemptErrors -join ' | ' } else { 'No repository attempts were possible.' }
                Write-Warning "  Install failed for $($m.module): $details"
            }
        }
    }
    Write-Host ''
}

# ═══════════════════════════════════════════════════════════════════════════════
# 7) EXPORT INSTALLER SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════

if ($ExportInstaller -and $missingCount -gt 0) {
    $installerPath = Join-Path $ReportPath "install-missing-modules-$timestamp.ps1"
    Write-Host '── Generating Installer Script ──' -ForegroundColor Cyan
    Write-PercentRow -Percent 86 -Label 'Generating installer script'

    $installerLines = @(
        '# Auto-generated module installer script',
        "# Generated: $(Get-Date -Format 'o')",
        "# Workspace: $WorkspacePath",
        '#Requires -Version 5.1',
        '',
        '[CmdletBinding()]',
        'param([switch]$WhatIf)',
        '',
        '$ErrorActionPreference = ''Stop''',
        '$modules = @('
    )

    foreach ($m in ($missingList | Sort-Object module)) {
        $wsPath = if ($m.workspacePath) { $m.workspacePath.Replace("'", "''") } else { '' }
        $installerLines += "    @{ Name = '$($m.module)'; WorkspacePath = '$wsPath' }"
    }

    $installerLines += @(
        ')',
        '',
        'foreach ($mod in $modules) {',
        '    $modName = $mod.Name',
        '    Write-Host "Processing: $modName" -ForegroundColor Cyan',
        '',
        '    $installed = Get-Module -ListAvailable -Name $modName -ErrorAction SilentlyContinue | Select-Object -First 1',
        '    if ($installed) {',
        '        Write-Host "  Already installed: $modName ($($installed.Version))" -ForegroundColor Green',
        '        continue',
        '    }',
        '',
        '    if ($mod.WorkspacePath -and (Test-Path $mod.WorkspacePath)) {',
        '        Write-Host "  Available in workspace: $($mod.WorkspacePath)" -ForegroundColor Yellow',
        '        continue',
        '    }',
        '',
        '    if ($WhatIf) {',
        '        Write-Host "  WHATIF: Install-Module -Name $modName -Scope CurrentUser" -ForegroundColor DarkYellow',
        '    } else {',
        '        try {',
        '            Install-Module -Name $modName -Scope CurrentUser -Force -ErrorAction Stop',
        '            Write-Host "  Installed: $modName" -ForegroundColor Green',
        '        } catch {',
        '            Write-Warning "  Failed to install $modName : $($_.Exception.Message)"',
        '        }',
        '    }',
        '}',
        '',
        'Write-Host "`nInstaller complete." -ForegroundColor Cyan'
    )

    Set-Content -Path $installerPath -Value $installerLines -Encoding UTF8
    Write-Host "  Installer script: $installerPath" -ForegroundColor Green
    Write-Output "InstallerScript: $installerPath"
    Write-Host ''
} elseif ($ExportInstaller -and $missingCount -eq 0) {
    Write-Host '  No missing modules -- installer not needed.' -ForegroundColor Green
    Write-Host ''
}

# ═══════════════════════════════════════════════════════════════════════════════
# 8) EXPORT FULL INVENTORY
# ═══════════════════════════════════════════════════════════════════════════════

if ($ExportInventory) {
    $invJsonPath = Join-Path $ReportPath "module-inventory-$timestamp.json"
    $invCsvPath  = Join-Path $ReportPath "module-inventory-$timestamp.csv"
    $invMdPath   = Join-Path $ReportPath "module-inventory-$timestamp.md"

    Write-Host '── Exporting Module Inventory ──' -ForegroundColor Cyan
    Write-PercentRow -Percent 92 -Label 'Exporting inventory artifacts'

    $exportData = [pscustomobject]@{
        generatedAt    = (Get-Date).ToString('o')
        workspace      = $WorkspacePath
        totalModules   = $inventory.Count
        installed      = $installedCount
        missing        = $missingCount
        workspaceOnly  = $wsOnlyCount
        errors         = $errorCount
        folderCounts   = $folderModuleCount
        wsFolderCounts = $wsFolderCounts
        modules        = $inventory.ToArray()
    }

    $exportData | ConvertTo-Json -Depth 6 | Set-Content -Path $invJsonPath -Encoding UTF8

    $inventory | Select-Object module, status, version, author, repository, installPath, workspacePath, scriptRefCount, loadError |
        Export-Csv -Path $invCsvPath -NoTypeInformation -Encoding UTF8

    # Markdown summary
    $mdLines = @(
        '# Module Inventory',
        '',
        "Generated: $(Get-Date -Format 'o')",
        "Workspace: $WorkspacePath",
        '',
        "| Metric | Count |",
        "|---|---:|",
        "| Total Tracked | $($inventory.Count) |",
        "| Installed | $installedCount |",
        "| Missing | $missingCount |",
        "| Workspace-Only | $wsOnlyCount |",
        "| Load Errors | $errorCount |",
        '',
        '## Modules per Folder',
        '',
        '| Folder | Count |',
        '|---|---:|'
    )
    foreach ($p in $psModPaths) {
        $c = if ($folderModuleCount.ContainsKey($p)) { $folderModuleCount[$p] } else { 0 }
        $mdLines += "| $p | $c |"
    }
    foreach ($kv in $wsFolderCounts.GetEnumerator()) {
        $mdLines += "| [Workspace] $($kv.Key) | $($kv.Value) |"
    }
    $mdLines += ''
    $mdLines += '## Full Module List'
    $mdLines += ''
    $mdLines += '| Module | Status | Version | Repository | ScriptRefs |'
    $mdLines += '|---|---|---|---|---:|'
    foreach ($m in ($inventory | Sort-Object module)) {
        $mdLines += "| $($m.module) | $($m.status) | $($m.version) | $($m.repository) | $($m.scriptRefCount) |"
    }
    Set-Content -Path $invMdPath -Value $mdLines -Encoding UTF8

    Write-Host "  JSON: $invJsonPath" -ForegroundColor Green
    Write-Host "  CSV:  $invCsvPath" -ForegroundColor Green
    Write-Host "  MD:   $invMdPath" -ForegroundColor Green
    Write-Output "InventoryJSON: $invJsonPath"
    Write-Output "InventoryCSV: $invCsvPath"
    Write-Output "InventoryMD: $invMdPath"
    Write-Host ''
}

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                    SCAN COMPLETE                           ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-PercentRow -Percent 100 -Label 'Module maintenance complete'
Write-Host "  Installed: $installedCount  |  Missing: $missingCount  |  Workspace: $wsOnlyCount  |  Errors: $errorCount" -ForegroundColor White
Write-Host ''

Write-Output "Installed: $installedCount"
Write-Output "Missing: $missingCount"
Write-Output "WorkspaceOnly: $wsOnlyCount"
Write-Output "Errors: $errorCount"
Write-Output "TotalTracked: $($inventory.Count)"






# --- End lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Completed: $($MyInvocation.MyCommand.Name)" -Level 'Info'
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





