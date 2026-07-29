# VersionTag: 2607.B6.V53.0
# FileRole: Script
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
    [switch]$NoModuleValidation,
    [switch]$SkipPipelineMetricHarness,
    [switch]$EnableAutoCorrect,
    [ValidateSet('FullWorkspace','KnowSafeRemidiations','KnowSafeRemediations','FastFix_Auto-Correct','SpecificFocus')]
    [string]$AutoCorrectScope = 'KnowSafeRemidiations',
    [string[]]$AutoCorrectFocusTargets = @(),
    [int]$AutoCorrectRecentDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Msg)
    Write-Output "[Run-FullPipeline] $Msg"
}

# ── AI Action Log bootstrap ──────────────────────────────────────────────────
$script:_AiLogLoaded  = $false
$script:_AiActionId   = $null
$script:_AiLogModule  = Join-Path $RepoRoot 'modules\PwShGUI-AiActionLog.psm1'
try {
    if (Test-Path -LiteralPath $script:_AiLogModule) {
        Import-Module $script:_AiLogModule -Force -DisableNameChecking -ErrorAction Stop
        $script:_AiLogLoaded = $true
        $script:_AiActionId  = 'pipeline-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,6))
        Write-AiActionStart `
            -ActionId   $script:_AiActionId `
            -ActionName 'Run-FullPipeline' `
            -AgentId    'Run-FullPipeline' `
            -Summary    'Full pipeline run started' `
            -Files      @() `
            -WorkspacePath $RepoRoot | Out-Null
    }
} catch {
    Write-Log "AI action log start failed (non-fatal): $($_.Exception.Message)"
    try {
        if ($script:_AiLogLoaded -and $script:_AiActionId) {
            Write-AiActionLoggingError -ActionId $script:_AiActionId -ActionName 'Run-FullPipeline' `
                -AgentId 'Run-FullPipeline' -Summary 'Logging init error' `
                -ErrorMessage $_.Exception.Message -Files @() -WorkspacePath $RepoRoot | Out-Null
        }
    } catch { <# Intentional: non-fatal logging-error suppression #> }
}

function Invoke-AiActionFinishSafe {
    param([string]$ResultStatus = 'success', [string[]]$TouchedFiles = @())
    if (-not $script:_AiLogLoaded -or -not $script:_AiActionId) { return }
    try {
        $fileObjs = @($TouchedFiles | ForEach-Object { @{ path = $_; kind = 'modified' } })
        Write-AiActionFinish `
            -ActionId   $script:_AiActionId `
            -ActionName 'Run-FullPipeline' `
            -AgentId    'Run-FullPipeline' `
            -Summary    "Full pipeline run finished: $ResultStatus" `
            -Files      $fileObjs `
            -Result     $ResultStatus `
            -WorkspacePath $RepoRoot | Out-Null
    } catch { <# Intentional: non-fatal finish-log suppression #> }
}

function Invoke-IfExists {
    param(
        [string]$Path,
<<<<<<< HEAD
        [array]$ScriptArgs = @(),
        [hashtable]$ScriptParams = @{},
=======
        [object]$ScriptArgs = @(),
>>>>>>> origin/main
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
<<<<<<< HEAD
        if ($ScriptParams.Count -gt 0) {
            & $Path @ScriptParams
        } else {
            & $Path @ScriptArgs
=======
        if ($null -eq $ScriptArgs) {
            & $Path
        } elseif ($ScriptArgs -is [System.Collections.IDictionary]) {
            & $Path @ScriptArgs
        } elseif ($ScriptArgs -is [System.Collections.IEnumerable] -and -not ($ScriptArgs -is [string])) {
            & $Path @($ScriptArgs)
        } else {
            & $Path $ScriptArgs
        }
        $scriptSucceeded = $?
        if (-not $scriptSucceeded) {
            throw "Script returned a failure status: $Path"
>>>>>>> origin/main
        }
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

function Invoke-UIEventSafetyNestedGate {
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    try {
        Write-Log "Executing nested failure gate: $ScriptPath -WorkspacePath $WorkspacePath -AsObject"
        $scan = & $ScriptPath -WorkspacePath $WorkspacePath -AsObject

        if ($null -eq $scan) {
            throw 'UI event safety scan returned no result object.'
        }

        if (-not ($scan.PSObject.Properties.Name -contains 'Checks')) {
            throw 'UI event safety scan result is missing Checks collection.'
        }

        $checks = @($scan.Checks)
        if (@($checks).Count -eq 0) {
            throw 'UI event safety scan returned an empty Checks collection.'
        }

        $allPass = $true
        foreach ($check in $checks) {
            $status = ''
            $name = ''
            if ($check.PSObject.Properties.Name -contains 'Status') { $status = [string]$check.Status }
            if ($check.PSObject.Properties.Name -contains 'Name') { $name = [string]$check.Name }

            if ($status -ne 'PASS') {
                $allPass = $false
                Write-Log ("UIEventSafety FAIL: " + $name + " status=" + $status)
            } else {
                Write-Log ("UIEventSafety PASS: " + $name)
            }
        }

        if (-not $allPass) {
            throw 'UI event safety nested gate failed: one or more checks are not PASS.'
        }

        Write-Log 'UI event safety nested gate passed: all checks are PASS.'
        return $true
    } catch {
        Write-Log "ERROR running nested UI event safety gate: $($_.Exception.Message)"
        return $false
    }
}

Write-Log "Repository root: $RepoRoot"
Write-Log "Exclusion regex: $ExcludeRegex"

function Invoke-PipelineStep {
    param([string]$StepName, [scriptblock]$Body)
    Write-Log "Step: $StepName"
    $ok = & $Body
    if (-not $ok) {
        Write-Log "FAILED at step: $StepName"
        Invoke-AiActionFinishSafe -ResultStatus 'failed'
        exit 1
    }
}

# 1) Version update + check
$fixUpdate = Join-Path $RepoRoot 'fix_update_version.ps1'
$fixCheck = Join-Path $RepoRoot 'fix_check_version.ps1'
Invoke-PipelineStep 'version-update' { Invoke-IfExists -Path $fixUpdate }
Invoke-PipelineStep 'version-check'  { Invoke-IfExists -Path $fixCheck }

# 1.1) Viewer/changelog sync + AI action summary refresh
$syncViewer = Join-Path $RepoRoot 'scripts\Sync-ChangelogViewerData.ps1'
<<<<<<< HEAD
if (-not (Invoke-IfExists -Path $syncViewer -ScriptParams @{ WorkspacePath = $RepoRoot; RefreshAiActionSummary = $true; IncludeTestAiActions = $true })) { exit 1 }
=======
Invoke-PipelineStep 'changelog-sync' { Invoke-IfExists -Path $syncViewer -ScriptArgs @{ WorkspacePath = $RepoRoot; RefreshAiActionSummary = $true; IncludeTestAiActions = $true } }
>>>>>>> origin/main

# 2) Module environment diagnostics
$validateImports = Join-Path $RepoRoot 'scripts\Validate-ModuleImports.ps1'
$setupModuleEnv = Join-Path $RepoRoot 'scripts\Setup-ModuleEnvironment.ps1'
<<<<<<< HEAD
if (-not (Invoke-IfExists -Path $validateImports -ScriptParams @{ WorkspacePath = $RepoRoot })) { exit 1 }
if (-not (Invoke-SetupModuleEnvironmentDiagnose -ScriptPath $setupModuleEnv -Workspace $RepoRoot)) { exit 1 }

# 3) Manifest refresh
$buildAgenticManifest = Join-Path $RepoRoot 'scripts\Build-AgenticManifest.ps1'
if (-not (Invoke-IfExists -Path $buildAgenticManifest -ScriptParams @{ OutputPath = Join-Path $RepoRoot 'config\agentic-manifest.json' })) { exit 1 }

# 3.1) DynaManifest generation (unified dynamic manifest with drift guards, security, versioning)
$buildDynaManifest = Join-Path $RepoRoot 'scripts\Build-DynaManifest.ps1'
if (-not (Invoke-IfExists -Path $buildDynaManifest -ScriptParams @{ WorkspacePath = $RepoRoot })) { exit 1 }

# 3.2) DynaManifest drift-guard validation (pre-test blocker gate)
$validateDynaManifest = Join-Path $RepoRoot 'scripts\Invoke-DynaManifestValidation.ps1'
if (-not (Invoke-IfExists -Path $validateDynaManifest -ScriptParams @{ ManifestPath = Join-Path $RepoRoot 'config\dynamic-manifest.json'; WorkspacePath = $RepoRoot } -Required)) {
    Write-Log "DynaManifest validation failed - drift guards detected blocker issues"
    exit 1
}
=======
Invoke-PipelineStep 'validate-imports'  { Invoke-IfExists -Path $validateImports -ScriptArgs @{ WorkspacePath = $RepoRoot } }
Invoke-PipelineStep 'setup-module-env' { Invoke-SetupModuleEnvironmentDiagnose -ScriptPath $setupModuleEnv -Workspace $RepoRoot }

# 3) Manifest refresh
$buildAgenticManifest = Join-Path $RepoRoot 'scripts\Build-AgenticManifest.ps1'
Invoke-PipelineStep 'agentic-manifest' { Invoke-IfExists -Path $buildAgenticManifest -ScriptArgs @{ OutputPath = (Join-Path $RepoRoot 'config\agentic-manifest.json') } }
>>>>>>> origin/main

# 4) Optional local engine + SIN script helpers
$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$localWeb = Join-Path $RepoRoot 'scripts\Start-LocalWebEngine.ps1'
if ($isWindowsHost) {
    Invoke-PipelineStep 'local-web-engine' { Invoke-IfExists -Path $localWeb -ScriptArgs @{ Action = 'RunAsService'; NoLaunchBrowser = $true } }
} else {
    Write-Log 'Non-Windows host detected; skipping local web engine startup helper.'
}

$sinScript = Join-Path $RepoRoot 'tools\run-sin-scan.ps1'
$sinAlt = Join-Path $RepoRoot 'scripts\Run-SIN-Scan.ps1'
$sinScanner = Join-Path $RepoRoot 'tests\Invoke-SINPatternScanner.ps1'
if (Test-Path -LiteralPath $sinScript) {
    Invoke-PipelineStep 'sin-scan' { Invoke-IfExists -Path $sinScript }
} elseif (Test-Path -LiteralPath $sinAlt) {
    Invoke-PipelineStep 'sin-scan-alt' { Invoke-IfExists -Path $sinAlt }
} else {
    Invoke-PipelineStep 'sin-scan-tests' { Invoke-IfExists -Path $sinScanner -ScriptArgs @{ WorkspacePath = $RepoRoot } -Required }
}

# 4.1) Proactive UI event safety scan
$uiEventSafetyScan = Join-Path $RepoRoot 'tests\Invoke-UIEventSafetyScan.ps1'
<<<<<<< HEAD
if (-not (Invoke-UIEventSafetyNestedGate -ScriptPath $uiEventSafetyScan -WorkspacePath $RepoRoot)) { exit 1 }

# 5) Full test gate (Pester + SIN + smoke + module accessibility)
$runAllTests = Join-Path $RepoRoot 'tests\Run-AllTests.ps1'
$testParams = @{ RequirePester = $true }
if ($AutoInstallPester) {
    $testParams['AutoInstallPester'] = $true
}
if ($NoModuleValidation) {
    $testParams['IncludeModuleValidation'] = $false
} else {
    $testParams['IncludeModuleValidation'] = $true
}
if (-not (Invoke-IfExists -Path $runAllTests -ScriptParams $testParams -Required)) { exit 1 }

# 5.1) One-item metric increment gate
if (-not $SkipPipelineMetricHarness) {
    $metricHarness = Join-Path $RepoRoot 'tests\Invoke-PipelineMetricIncrementHarness.ps1'
    if (-not (Invoke-IfExists -Path $metricHarness -ScriptParams @{ WorkspacePath = $RepoRoot; SkipGuiCoverage = $true })) { exit 1 }
}

# 5.2) Optional auto-correct gate.
if ($EnableAutoCorrect) {
    $autoCorrectGate = Join-Path $RepoRoot 'tests\Invoke-PreCommitValidation.ps1'
    $autoCorrectDir = Join-Path (Join-Path $RepoRoot 'reports') 'pipeline-autocorrect-gate'
    if (-not (Test-Path -LiteralPath $autoCorrectDir)) {
        $null = New-Item -ItemType Directory -Path $autoCorrectDir -Force
    }

    $autoCorrectReport = Join-Path $autoCorrectDir 'run-fullpipeline-autocorrect-latest.json'
    $autoCorrectParams = @{
        WorkspacePath = $RepoRoot
        OutputJson = $autoCorrectReport
        AutoCorrectFailures = $true
        AutoCorrectScope = $AutoCorrectScope
        AutoCorrectFocusTargets = @($AutoCorrectFocusTargets)
        AutoCorrectRecentDays = $AutoCorrectRecentDays
    }

    if (-not (Invoke-IfExists -Path $autoCorrectGate -ScriptParams $autoCorrectParams -Required)) { exit 1 }
}
=======
Invoke-PipelineStep 'ui-event-safety' { Invoke-IfExists -Path $uiEventSafetyScan -ScriptArgs @{ WorkspacePath = $RepoRoot } }

# 5) Full test gate (Pester + SIN + smoke + module accessibility)
$runAllTests = Join-Path $RepoRoot 'tests\Run-AllTests.ps1'
$testArgs = @{ RequirePester = $true }
if ($AutoInstallPester) {
    $testArgs.AutoInstallPester = $true
}
if ($NoModuleValidation) {
    $testArgs.IncludeModuleValidation = $false
} else {
    $testArgs.IncludeModuleValidation = $true
}
Invoke-PipelineStep 'run-all-tests' { Invoke-IfExists -Path $runAllTests -ScriptArgs $testArgs -Required }
>>>>>>> origin/main

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
            Invoke-AiActionFinishSafe -ResultStatus 'failed'
            exit 1
        }
    }
}

Write-Log 'Pipeline run complete. All gates passed.'
Invoke-AiActionFinishSafe -ResultStatus 'success' -TouchedFiles @('scripts/Run-FullPipeline.ps1')
exit 0
<<<<<<< HEAD



=======
>>>>>>> origin/main
