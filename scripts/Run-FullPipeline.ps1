# VersionTag: 2605.B5.V46.1
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates full workspace pipeline with blocking full-suite tests.
.DESCRIPTION
    Runs versioning, maintenance diagnostics, optional scans, then executes
    tests/Run-AllTests.ps1 as a blocking gate so full Pester coverage and module
    accessibility validation are enforced in one place.
#>
param(
    [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [string]$ExcludeRegex = '^(~|\.)',
    [switch]$SkipLaunchBatches,
    [switch]$AutoInstallPester,
    [switch]$NoModuleValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Msg)
    Write-Output "[Run-FullPipeline] $Msg"
}

function Invoke-IfExists {
    param(
        [string]$Path,
        [array]$ScriptArgs = @(),
        [switch]$Required
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Required) {
            throw "Required script not found: $Path"
        }
        Write-Log "Not found, skipping: $Path"
        return $true
    }

    try {
        Write-Log "Executing: $Path"
        & $Path @ScriptArgs
        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
            throw "Non-zero exit code $LASTEXITCODE from $Path"
        }
        Write-Log "Finished: $Path"
        return $true
    } catch {
        Write-Log "ERROR running $Path : $($_.Exception.Message)"
        return $false
    }
}

function Invoke-SetupModuleEnvironmentDiagnose {
    param([string]$ScriptPath, [string]$Workspace)

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    try {
        Write-Log "Executing: $ScriptPath -Action Diagnose -WorkspacePath $Workspace"
        & $ScriptPath -Action 'Diagnose' -WorkspacePath $Workspace
        if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
            throw "Non-zero exit code $LASTEXITCODE from $ScriptPath"
        }
        Write-Log "Finished: $ScriptPath"
        return $true
    } catch {
        Write-Log "ERROR running $ScriptPath : $($_.Exception.Message)"
        return $false
    }
}

Write-Log "Repository root: $RepoRoot"
Write-Log "Exclusion regex: $ExcludeRegex"

# 1) Version update + check
$fixUpdate = Join-Path $RepoRoot 'fix_update_version.ps1'
$fixCheck = Join-Path $RepoRoot 'fix_check_version.ps1'
if (-not (Invoke-IfExists -Path $fixUpdate)) { exit 1 }
if (-not (Invoke-IfExists -Path $fixCheck)) { exit 1 }

# 1.1) Viewer/changelog sync + AI action summary refresh
$syncViewer = Join-Path $RepoRoot 'scripts\Sync-ChangelogViewerData.ps1'
if (-not (Invoke-IfExists -Path $syncViewer -ScriptArgs @('-WorkspacePath', $RepoRoot, '-RefreshAiActionSummary:$true', '-IncludeTestAiActions'))) { exit 1 }

# 2) Module environment diagnostics
$validateImports = Join-Path $RepoRoot 'scripts\Validate-ModuleImports.ps1'
$setupModuleEnv = Join-Path $RepoRoot 'scripts\Setup-ModuleEnvironment.ps1'
if (-not (Invoke-IfExists -Path $validateImports -ScriptArgs @('-WorkspacePath', $RepoRoot))) { exit 1 }
if (-not (Invoke-SetupModuleEnvironmentDiagnose -ScriptPath $setupModuleEnv -Workspace $RepoRoot)) { exit 1 }

# 3) Manifest refresh
$buildAgenticManifest = Join-Path $RepoRoot 'scripts\Build-AgenticManifest.ps1'
if (-not (Invoke-IfExists -Path $buildAgenticManifest -ScriptArgs @('-OutputPath', (Join-Path $RepoRoot 'config\agentic-manifest.json')))) { exit 1 }

# 4) Optional local engine + SIN script helpers
$localWeb = Join-Path $RepoRoot 'scripts\Start-LocalWebEngine.ps1'
if (-not (Invoke-IfExists -Path $localWeb)) { exit 1 }

$sinScript = Join-Path $RepoRoot 'tools\run-sin-scan.ps1'
$sinAlt = Join-Path $RepoRoot 'scripts\Run-SIN-Scan.ps1'
if (-not (Invoke-IfExists -Path $sinScript)) {
    if (-not (Invoke-IfExists -Path $sinAlt)) { exit 1 }
}

# 4.1) Proactive UI event safety scan
$uiEventSafetyScan = Join-Path $RepoRoot 'tests\Invoke-UIEventSafetyScan.ps1'
if (-not (Invoke-IfExists -Path $uiEventSafetyScan -ScriptArgs @('-WorkspacePath', $RepoRoot))) { exit 1 }

# 5) Full test gate (Pester + SIN + smoke + module accessibility)
$runAllTests = Join-Path $RepoRoot 'tests\Run-AllTests.ps1'
$testArgs = @('-RequirePester', $true)
if ($AutoInstallPester) {
    $testArgs += @('-AutoInstallPester')
}
if ($NoModuleValidation) {
    $testArgs += @('-IncludeModuleValidation', $false)
} else {
    $testArgs += @('-IncludeModuleValidation', $true)
}
if (-not (Invoke-IfExists -Path $runAllTests -ScriptArgs $testArgs -Required)) { exit 1 }

# 6) Optional launch batch runs
if (-not $SkipLaunchBatches) {
    Write-Log 'Searching for Launch-*.bat files to run (excluding hidden/system roots).'
    $batFiles = Get-ChildItem -Path $RepoRoot -Filter 'Launch-*.bat' -File -Recurse | Where-Object {
        $dirName = $_.Directory.Name
        -not ($dirName -match $ExcludeRegex)
    }
    foreach ($bat in $batFiles) {
        try {
            Write-Log "Starting batch: $($bat.FullName)"
            $proc = Start-Process -FilePath $bat.FullName -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                throw "Batch exited with code $($proc.ExitCode)"
            }
            Write-Log "Completed batch: $($bat.Name)"
        } catch {
            Write-Log "ERROR running batch $($bat.FullName): $($_.Exception.Message)"
            exit 1
        }
    }
}

Write-Log 'Pipeline run complete. All gates passed.'
exit 0

