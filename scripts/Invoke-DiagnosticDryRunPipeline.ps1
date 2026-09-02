# VersionTag: 2607.B6.V53.0
# SupportPS5.1: YES(As of: 2026-05-25)
# SupportsPS7.6: YES(As of: 2026-05-25)
# FileRole: Pipeline
#Requires -Version 5.1
<#!
.SYNOPSIS
    Runs iterative, diagnostic-only dry-run phases with strict gate control.
.DESCRIPTION
    Executes a staged pipeline using existing scan/smoke routines. Each phase writes
    diagnostic logs and must pass before the next phase starts. Optional retry and
    interactive fix gates are supported for repeat dry-run loops.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 50)]
    [int]$Iterations = 1,
    [ValidateRange(0, 10)]
    [int]$MaxPhaseRetries = 1,
    [ValidateRange(30, 7200)]
    [int]$PhaseTimeoutSec = 1200,
    [switch]$InteractiveFixGate,
    [switch]$IncludeSandboxSimulation,
    [switch]$GenerateTestingPlan,
    [switch]$OpenTestingPlanPage,
    [ValidateSet('auto','pwsh','powershell')]
    [string]$Shell = 'auto',
    [string]$ReportRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path (Join-Path $WorkspacePath '~REPORTS') 'diagnostic-dryrun'
}
if (-not (Test-Path -LiteralPath $ReportRoot)) {
    $null = New-Item -Path $ReportRoot -ItemType Directory -Force
}

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $ReportRoot ("run-$runStamp")
$null = New-Item -Path $runDir -ItemType Directory -Force
$planJsonPath = Join-Path (Join-Path (Join-Path $WorkspacePath '~REPORTS') 'testing-plan') 'sandbox-testing-plan.json'

function Resolve-ShellExecutable {
    param([string]$Preferred)

    if ($Preferred -eq 'pwsh') {
        if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
        throw 'pwsh.exe requested but not found.'
    }
    if ($Preferred -eq 'powershell') {
        if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
        throw 'powershell.exe requested but not found.'
    }

    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
    throw 'No supported PowerShell executable found.'
}

function New-Phase {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ScriptRelativePath,
        [Parameter(Mandatory)] [string[]]$ScriptArgs,
        [switch]$Optional
    )

    [pscustomobject]@{
        Name = $Name
        ScriptRelativePath = $ScriptRelativePath
        ScriptArgs = $ScriptArgs
        Optional = [bool]$Optional
    }
}

function Write-DiagnosticLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','PASS','WARN','FAIL')] [string]$Level = 'INFO'
    )

    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = 'Gray'
    if ($Level -eq 'PASS') { $color = 'Green' }
    elseif ($Level -eq 'WARN') { $color = 'Yellow' }
    elseif ($Level -eq 'FAIL') { $color = 'Red' }
    Write-Host $line -ForegroundColor $color

    Add-Content -LiteralPath (Join-Path $runDir 'diagnostic-run.log') -Value $line -Encoding UTF8
}

function Invoke-PhaseProcess {
    param(
        [Parameter(Mandatory)] [pscustomobject]$Phase,
        [Parameter(Mandatory)] [string]$HostExe,
        [Parameter(Mandatory)] [string]$IterationDir,
        [Parameter(Mandatory)] [int]$PhaseIndex,
        [Parameter(Mandatory)] [int]$Attempt,
        [Parameter(Mandatory)] [int]$TimeoutSec
    )

    $scriptPath = Join-Path $WorkspacePath $Phase.ScriptRelativePath
    $stdoutPath = Join-Path $IterationDir ("{0:00}-{1}-attempt{2}-stdout.log" -f $PhaseIndex, $Phase.Name, $Attempt)
    $stderrPath = Join-Path $IterationDir ("{0:00}-{1}-attempt{2}-stderr.log" -f $PhaseIndex, $Phase.Name, $Attempt)

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [pscustomobject]@{
            Phase = $Phase.Name
            Script = $Phase.ScriptRelativePath
            Attempt = $Attempt
            ExitCode = 404
            DurationSec = 0
            Stdout = $stdoutPath
            Stderr = $stderrPath
            Passed = $false
            Message = "Script not found: $($Phase.ScriptRelativePath)"
        }
    }

    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $scriptPath)
    $args += @($Phase.ScriptArgs)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $HostExe -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if ($null -eq $proc) {
            $exitCode = 1
        } else {
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((-not $proc.HasExited) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 250
                try { $null = $proc.Refresh() } catch { <# Intentional: non-fatal refresh fallback #> }
            }

            if (-not $proc.HasExited) {
                try {
                    $taskKillArgs = @('/PID', [string]$proc.Id, '/T', '/F')
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList $taskKillArgs -NoNewWindow -Wait | Out-Null
                } catch {
                    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { <# Intentional: non-fatal kill fallback #> }
                }

                Add-Content -LiteralPath $stderrPath -Value ("Phase timeout after {0}s (root PID {1})" -f $TimeoutSec, $proc.Id) -Encoding UTF8
                $exitCode = 124
            } else {
                $exitCode = [int]$proc.ExitCode
            }
        }
    } catch {
        $exitCode = 1
        Set-Content -LiteralPath $stderrPath -Value $_.Exception.Message -Encoding UTF8
    }
    $sw.Stop()

    $passed = $exitCode -eq 0
    $phaseMessage = 'ok'
    if (-not $passed) {
        $phaseMessage = "ExitCode=$exitCode"
    }
    return [pscustomobject]@{
        Phase = $Phase.Name
        Script = $Phase.ScriptRelativePath
        Attempt = $Attempt
        ExitCode = $exitCode
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Stdout = $stdoutPath
        Stderr = $stderrPath
        Passed = $passed
        Message = $phaseMessage
    }
}

function Get-PhaseDefinitions {
    param([switch]$IncludeSandbox)

    $phases = @(
        (New-Phase -Name 'ValidateImports' -ScriptRelativePath 'scripts/Validate-ModuleImports.ps1' -ScriptArgs @('-WorkspacePath', $WorkspacePath)),
        (New-Phase -Name 'ModuleDiagnose' -ScriptRelativePath 'scripts/Setup-ModuleEnvironment.ps1' -ScriptArgs @('-Action', 'Diagnose', '-WorkspacePath', $WorkspacePath)),
        (New-Phase -Name 'FullSystemsScan' -ScriptRelativePath 'scripts/Invoke-FullSystemsScan.ps1' -ScriptArgs @('-WorkspacePath', $WorkspacePath, '-DeltaMode', '-ProgressQuiet', '-ParallelJobTimeoutSec', '120')),
        (New-Phase -Name 'SINPatternScan' -ScriptRelativePath 'tests/Invoke-SINPatternScanner.ps1' -ScriptArgs @('-WorkspacePath', $WorkspacePath, '-Runtime', 'Both', '-OutputJson', (Join-Path $WorkspacePath 'temp/sin-scan-results-diagnostic-dryrun.json'))),
        (New-Phase -Name 'SemiSinPenance' -ScriptRelativePath 'tests/Invoke-SemiSinPenanceScanner.ps1' -ScriptArgs @('-WorkspacePath', $WorkspacePath, '-OutputJson', (Join-Path $WorkspacePath 'temp/semisin-penance-results-diagnostic-dryrun.json'))),
        (New-Phase -Name 'HeadlessSmokeMatrix' -ScriptRelativePath 'tests/Invoke-GUISmokeTest.ps1' -ScriptArgs @('-HeadlessOnly', '-RunShellMatrix', '-Shell', 'auto'))
    )

    if ($IncludeSandbox) {
        $phases += (New-Phase -Name 'SandboxSimulation' -ScriptRelativePath 'tests/Invoke-SandboxSmokeTest.ps1' -ScriptArgs @('-WorkspacePath', $WorkspacePath, '-HeadlessOnly') -Optional)
    }

    return @($phases)
}

$hostExe = Resolve-ShellExecutable -Preferred $Shell
Write-DiagnosticLog -Message ("Diagnostic dry-run host: {0}" -f $hostExe)
Write-DiagnosticLog -Message ("Run folder: {0}" -f $runDir)

$allResults = @()
$runFailed = $false

for ($iter = 1; $iter -le $Iterations; $iter++) {
    $iterDir = Join-Path $runDir ("iteration-{0:00}" -f $iter)
    $null = New-Item -Path $iterDir -ItemType Directory -Force

    Write-DiagnosticLog -Level INFO -Message ("Iteration {0}/{1} started" -f $iter, $Iterations)
    $phases = Get-PhaseDefinitions -IncludeSandbox:$IncludeSandboxSimulation

    $phaseIndex = 0
    foreach ($phase in $phases) {
        $phaseIndex++
        $passed = $false

        for ($attempt = 1; $attempt -le ($MaxPhaseRetries + 1); $attempt++) {
            Write-DiagnosticLog -Level INFO -Message ("Phase {0:00} {1} attempt {2}" -f $phaseIndex, $phase.Name, $attempt)
            $result = Invoke-PhaseProcess -Phase $phase -HostExe $hostExe -IterationDir $iterDir -PhaseIndex $phaseIndex -Attempt $attempt -TimeoutSec $PhaseTimeoutSec
            $allResults += $result

            if ($result.Passed) {
                Write-DiagnosticLog -Level PASS -Message ("Phase {0:00} {1} passed in {2}s" -f $phaseIndex, $phase.Name, $result.DurationSec)
                $passed = $true
                break
            }

            Write-DiagnosticLog -Level FAIL -Message ("Phase {0:00} {1} failed ({2}). stdout={3} stderr={4}" -f $phaseIndex, $phase.Name, $result.Message, $result.Stdout, $result.Stderr)

            if ($InteractiveFixGate) {
                $response = Read-Host "Phase '$($phase.Name)' failed. Fix issue then enter R to retry, or S to stop"
                if ([string]::IsNullOrWhiteSpace($response) -or $response.Trim().ToUpperInvariant() -ne 'R') {
                    break
                }
            }
        }

        if (-not $passed) {
            $runFailed = $true
            Write-DiagnosticLog -Level WARN -Message ("Stopping iteration {0} before next phase because {1} did not pass" -f $iter, $phase.Name)
            break
        }
    }

    if ($runFailed) { break }
    Write-DiagnosticLog -Level PASS -Message ("Iteration {0}/{1} completed" -f $iter, $Iterations)
}

if ($GenerateTestingPlan -and -not $runFailed) {
    Write-DiagnosticLog -Level INFO -Message 'Generating sandbox testing-plan dataset'
    $builder = Join-Path (Join-Path $WorkspacePath 'scripts') 'Build-SandboxTestingPlan.ps1'
    $builderArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $builder, '-WorkspacePath', $WorkspacePath, '-IncludeRootXhtml')

    $planStdOut = Join-Path $runDir 'testing-plan-builder-stdout.log'
    $planStdErr = Join-Path $runDir 'testing-plan-builder-stderr.log'
    $planProc = Start-Process -FilePath $hostExe -ArgumentList $builderArgs -PassThru -Wait -NoNewWindow -RedirectStandardOutput $planStdOut -RedirectStandardError $planStdErr
    if ($null -eq $planProc -or $planProc.ExitCode -ne 0) {
        $runFailed = $true
        Write-DiagnosticLog -Level FAIL -Message ("Testing-plan generation failed. stdout={0} stderr={1}" -f $planStdOut, $planStdErr)
    } else {
        Write-DiagnosticLog -Level PASS -Message ("Testing-plan generated: {0}" -f $planJsonPath)
        if ($OpenTestingPlanPage -and (Test-Path -LiteralPath (Join-Path $WorkspacePath 'pages/Sandbox-TestingPlan.xhtml'))) {
            Start-Process (Join-Path $WorkspacePath 'pages/Sandbox-TestingPlan.xhtml') | Out-Null
        }
    }
}

$finalStatus = 'PASSED'
if ($runFailed) {
    $finalStatus = 'FAILED'
}

$summary = [ordered]@{
    schema = 'PwShGUI-DiagnosticDryRun/1.0'
    runStamp = $runStamp
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspacePath = $WorkspacePath
    hostExe = $hostExe
    iterationsRequested = $Iterations
    maxPhaseRetries = $MaxPhaseRetries
    includeSandboxSimulation = [bool]$IncludeSandboxSimulation
    generateTestingPlan = [bool]$GenerateTestingPlan
    status = $finalStatus
    tags = @('diagnostic-dryrun', 'smoke', 'scan', 'sin', 'sandbox', 'testing-plan')
    standards = @('SOV-Sys-zero', 'SIN-governance', 'DualEngine-SmokeGate')
    memoryLinks = @('/memories/repo/testing-plan-feedback-link.md')
    results = $allResults
}

$summaryPath = Join-Path $runDir 'diagnostic-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-DiagnosticLog -Level INFO -Message ("Summary JSON: {0}" -f $summaryPath)

if ($runFailed) {
    exit 1
}

exit 0

