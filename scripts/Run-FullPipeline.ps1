<#
    Run-FullPipeline.ps1
    Orchestrates a full workspace pipeline: versioning, scans, tests, and smoke runs.

    Usage: .\Run-FullPipeline.ps1 [-RepoRoot <path>] [-ExcludeRegex <regex>]

    Notes:
    - Excludes folders whose name starts with '~' or '.' by default.
    - Runs available scripts if present, skips missing tools gracefully.

    # VersionTag: 2604.B1.V1.0
    # Encoding: UTF8 BOM recommended for PS 5.1
#>

param(
    [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [string]$ExcludeRegex = '^(~|\.)'
)

function Write-Log { param($Msg) Write-Output "[Run-FullPipeline] $Msg" }

function Invoke-IfExists {
    param(
        [string]$Path,
        [array]$Args
    )
    if (Test-Path $Path) {
        try {
            Write-Log "Executing: $Path"
            & $Path @Args
            Write-Log "Finished: $Path"
            return $true
        }
        catch {
            Write-Log "ERROR running $Path : $($_.Exception.Message)"
            return $false
        }
    }
    else {
        Write-Log "Not found, skipping: $Path"
        return $false
    }
}

Write-Log "Repository root: $RepoRoot"
Write-Log "Exclusion regex: $ExcludeRegex"

# 1) Version update
$fixUpdate = Join-Path $RepoRoot 'fix_update_version.ps1'
Invoke-IfExists $fixUpdate @()

# 2) Version check
$fixCheck = Join-Path $RepoRoot 'fix_check_version.ps1'
Invoke-IfExists $fixCheck @()

# 3) Start local web engine / scans
$localWeb = Join-Path $RepoRoot 'scripts\Start-LocalWebEngine.ps1'
Invoke-IfExists $localWeb @()

# 3a) Log changelog viewer status
$changelogPath = Join-Path $RepoRoot 'XHTML-ChangelogViewer.xhtml'
$changelogLog = Join-Path $RepoRoot 'logs' 'changelog-viewer.log'
if (Test-Path $changelogPath) {
    $summary = "[ChangelogViewer] $(Get-Date -Format o) - File exists, size: $((Get-Item $changelogPath).Length) bytes."
    try {
        Add-Content -Path $changelogLog -Value $summary -Encoding UTF8
        Write-Log "Changelog viewer status logged."
    }
    catch {
        Write-Log "ERROR logging changelog viewer: $($_.Exception.Message)"
    }
}
else {
    Write-Log "Changelog viewer file not found, skipping log."
}

# 4) SIN / integrity scans (optional helper scripts under tools or scripts)
$sinScript = Join-Path $RepoRoot 'tools\run-sin-scan.ps1'
if (-not (Invoke-IfExists $sinScript @())) {
    $sinAlt = Join-Path $RepoRoot 'scripts\Run-SIN-Scan.ps1'
    Invoke-IfExists $sinAlt @()
}

# 5) Module / unit tests
$testPath = Join-Path $RepoRoot 'sovereign-kernel\tests\Test-SovereignKernel.ps1'
Invoke-IfExists $testPath @()

# 6) Launch smoke/chaos/browser batch files found at repo root
Write-Log "Searching for Launch-*.bat files to run (root and top-level)."
$batFiles = Get-ChildItem -Path $RepoRoot -Filter 'Launch-*.bat' -File -Recurse | Where-Object {
    # Exclude files in directories starting with ~ or .
    $dirName = $_.Directory.Name
    -not ($dirName -match $ExcludeRegex)
}
foreach ($bat in $batFiles) {
    try {
        Write-Log "Starting batch: $($bat.FullName)"
        Start-Process -FilePath $bat.FullName -NoNewWindow -Wait
        Write-Log "Completed batch: $($bat.Name)"
    }
    catch {
        Write-Log "ERROR running batch $($bat.FullName): $($_.Exception.Message)"
    }
}

# VersionTag: 2604.B1.V1.0

<#
.DESCRIPTION
This script orchestrates the full pipeline process for the PowerShellGUI project.
It includes build/versioning, scanning, and testing steps, while excluding folders
that start with ~ or . (dot).

#>

# Import required modules
Import-Module -Name CronAiAthon-Pipeline -ErrorAction Stop

# Define exclusion patterns
$ExclusionPatterns = @('~*', '.*')

# Define pipeline steps
function Run-BuildVersioning {
    Write-Host "Running build/versioning steps..."
    . ./fix_update_version.ps1
    . ./fix_check_version.ps1
}

function Run-Scanning {
    Write-Host "Running scanning steps..."
    . ./scripts/Start-LocalWebEngine.ps1
}

function Run-Testing {
    Write-Host "Running testing steps..."
    . ./sovereign-kernel/tests/Test-SovereignKernel.ps1
    . ./Launch-SandboxSmokeTest.bat
    . ./Launch-ChaosTest.bat
    . ./Launch-SandboxBrowserTest.bat
}

# Main pipeline execution
Write-Host "Starting full pipeline process..."
Run-BuildVersioning
Run-Scanning
Run-Testing
Write-Host "Pipeline process completed."

Write-Log "Pipeline run complete. Review console output and logs for details."

exit 0
