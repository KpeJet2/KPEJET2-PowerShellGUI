# VersionTag: 2608.B1.V54.4
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Bootstrap script that runs INSIDE Windows Sandbox for interactive GUI testing.
.DESCRIPTION
    Copies the read-only mapped workspace to a local writable path, sets up the
    environment, then enters a polling loop watching for command files (.cmd.json)
    from the host. Supports: Sync, Test, GUI, Exec, Shutdown actions.
    This script is auto-generated / invoked by Start-InteractiveSandbox.ps1.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [string]$SourcePath   = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Source',
    [string]$LocalPath    = 'C:\PwShGUI-Test',
    [string]$CommandPath  = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Cmd',
    [string]$OutputPath   = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output',
    [int]$PollInterval    = 2,
    [int]$MaxIdleMinutes  = 120,
    [ValidateSet('Enable', 'Disable')]
    [string]$Networking    = 'Disable'
)

$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy Bypass -Scope Process -Force

# ========================== LOGGING ==========================
$logFile = Join-Path $OutputPath 'sandbox-interactive.log'
function Write-SBLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    Write-Host $line -ForegroundColor $(switch ($Level) {
        'ERROR' { 'Red' }; 'WARN' { 'Yellow' }; 'OK' { 'Green' }; default { 'Gray' }
    })
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ========================== INIT ==========================
New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction SilentlyContinue | Out-Null
Write-SBLog '=================================================================='
Write-SBLog '  PwShGUI Interactive Sandbox Bootstrap'
Write-SBLog '=================================================================='
Write-SBLog "PSVersion: $($PSVersionTable.PSVersion)"
Write-SBLog "Source:    $SourcePath"
Write-SBLog "Local:     $LocalPath"
Write-SBLog "Commands:  $CommandPath"
Write-SBLog "Output:    $OutputPath"

# Write status file for host polling
function Set-SandboxStatus {
    param([string]$Status, [string]$Detail = '')
    $obj = @{
        status    = $Status
        detail    = $Detail
        timestamp = (Get-Date -Format 'o')
        pid       = $PID
    }
    $json = ConvertTo-Json $obj -Depth 5
    Set-Content -Path (Join-Path $OutputPath 'sandbox-status.json') -Value $json -Encoding UTF8
}

Set-SandboxStatus -Status 'INITIALIZING' -Detail 'Copying workspace'

# ========================== WORKSPACE COPY ==========================
if (Test-Path $SourcePath) {
    Write-SBLog "Copying workspace to writable path..."
    if (Test-Path $LocalPath) {
        Remove-Item $LocalPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item $SourcePath $LocalPath -Recurse -Force -ErrorAction SilentlyContinue
    $fileCount = @(Get-ChildItem $LocalPath -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-SBLog "Copy complete: $fileCount files" -Level 'OK'
} else {
    Write-SBLog "Source path not found: $SourcePath" -Level 'ERROR'
    Set-SandboxStatus -Status 'ERROR' -Detail 'Source path not found'
    return
}

# ========================== RUNTIME PREFLIGHT ==========================
# Windows Sandbox always includes Windows PowerShell 5.1, but pwsh, wt, Python,
# and dotnet are optional. Resolve what exists once and keep command arguments as
# arrays so script switches are passed as switches rather than reparsed text.
$script:PowerShellExe = 'powershell.exe'
$pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -ne $pwshCommand) {
    $script:PowerShellExe = $pwshCommand.Source
}
$modulePath = Join-Path $LocalPath 'modules'
if (Test-Path -LiteralPath $modulePath) {
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
}
$windowsPowerShellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
$windowsTerminalCommand = Get-Command wt.exe -ErrorAction SilentlyContinue
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
$guestRuntimeRows = @(
    @{ Name = 'PowerShell'; Command = $script:PowerShellExe },
    @{ Name = 'Windows PowerShell'; Command = if ($null -ne $windowsPowerShellCommand) { $windowsPowerShellCommand.Source } else { '' } },
    @{ Name = 'Windows Terminal'; Command = if ($null -ne $windowsTerminalCommand) { $windowsTerminalCommand.Source } else { '' } },
    @{ Name = 'Python'; Command = if ($null -ne $pythonCommand) { $pythonCommand.Source } else { '' } },
    @{ Name = 'dotnet'; Command = if ($null -ne $dotnetCommand) { $dotnetCommand.Source } else { '' } }
)
foreach ($runtime in $guestRuntimeRows) {
    if ([string]::IsNullOrWhiteSpace([string]$runtime.Command)) {
        Write-SBLog "Guest runtime not available: $($runtime.Name)" -Level 'WARN'
    } else {
        Write-SBLog "Guest runtime available: $($runtime.Name) -> $($runtime.Command)" -Level 'OK'
    }
}
$setupEnvScript = Join-Path (Join-Path $LocalPath 'scripts') 'Setup-ModuleEnvironment.ps1'
if (Test-Path -LiteralPath $setupEnvScript) {
    try {
        Write-SBLog 'Preloading workspace PowerShell modules without interactive prompts...'
        $setupArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$setupEnvScript,'-Action','Install','-Scope','CurrentUser','-WorkspacePath',$LocalPath)
        $setupPreload = Start-Process -FilePath $script:PowerShellExe -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
        if ($setupPreload.ExitCode -eq 0) {
            Write-SBLog 'Workspace PowerShell module preload completed.' -Level 'OK'
        } else {
            Write-SBLog "Workspace module preload returned exit code $($setupPreload.ExitCode); continuing with local modules." -Level 'WARN'
        }
    } catch {
        Write-SBLog "Workspace module preload skipped: $($_.Exception.Message)" -Level 'WARN'
    }
}

$preReqSetupScript = Join-Path (Join-Path $LocalPath 'scripts') 'Invoke-WorkspacePreReqs.ps1'
if ($Networking -eq 'Enable' -and (Test-Path -LiteralPath $preReqSetupScript)) {
    try {
        Write-SBLog 'Network enabled: running non-interactive workspace prerequisite setup...'
        $preReqSetupArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$preReqSetupScript,'-WorkspacePath',$LocalPath,'-Action','SetupAll')
        $preReqSetup = Start-Process -FilePath $script:PowerShellExe -ArgumentList $preReqSetupArgs -Wait -PassThru -NoNewWindow
        if ($preReqSetup.ExitCode -eq 0) {
            Write-SBLog 'Workspace prerequisite setup completed.' -Level 'OK'
        } else {
            Write-SBLog "Workspace prerequisite setup returned exit code $($preReqSetup.ExitCode); continuing with available guest runtimes." -Level 'WARN'
        }
    } catch {
        Write-SBLog "Workspace prerequisite setup skipped: $($_.Exception.Message)" -Level 'WARN'
    }
} elseif ($Networking -eq 'Disable') {
    Write-SBLog 'Network disabled: skipping online runtime installation; using preloaded/local guest tools.' -Level 'WARN'
}

# ========================== COMMAND HANDLERS ==========================
$script:guiProcess = $null
$script:iterationCount = 0
$script:mainGuiProcess = $null
$script:cronProcess = $null
$script:webEngine8042Process = $null
$script:clusterDashboardProcess = $null
$script:stackPrepared = $false

function Invoke-SyncWorkspace {
    <# Re-copies changed files from read-only source to local writable copy #>
    param([hashtable]$Params)
    Write-SBLog 'Syncing workspace from source...'
    $before = @(Get-ChildItem $LocalPath -Recurse -File -ErrorAction SilentlyContinue).Count
    # Selective sync: only overwrite changed files to preserve local edits
    $sourceFiles = Get-ChildItem $SourcePath -Recurse -File -ErrorAction SilentlyContinue
    $synced = 0
    foreach ($sf in $sourceFiles) {
        $rel  = $sf.FullName.Substring($SourcePath.Length)
        $dest = Join-Path $LocalPath $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        $destFile = Get-Item $dest -ErrorAction SilentlyContinue
        if ((-not $destFile) -or ($sf.LastWriteTimeUtc -gt $destFile.LastWriteTimeUtc)) {
            Copy-Item $sf.FullName $dest -Force -ErrorAction SilentlyContinue
            $synced++
        }
    }
    $after = @(Get-ChildItem $LocalPath -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-SBLog "Sync complete: $synced files updated ($before -> $after total)" -Level 'OK'
    return @{ synced = $synced; totalFiles = $after }
}

function Test-HttpEndpoint {
    <# Wait for HTTP endpoint success within timeout window. #>
    param(
        [Parameter(Mandatory)] [string]$Url,
        [int]$TimeoutSec = 60,
        [int]$PollSec = 2
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($null -ne $resp -and $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                return $true
            }
        } catch { <# Intentional: endpoint may still be starting #> }

        Start-Sleep -Seconds $PollSec
        $elapsed += $PollSec
    }

    return $false
}

function Invoke-PrepareSandboxRuntimeStack {
    <#
    .SYNOPSIS
        Prepare sandbox runtime stack before test execution.
    .DESCRIPTION
        Sequence:
          1) Pipeline prechecks
          2) Framework/module install
          3) Load MainGUI (TaskTray), Cluster Dash pre-stage, Cron process
          4) Launch local web services on 8042 then 8099
    #>
    param([hashtable]$Params)

    if ($script:stackPrepared) {
        return [ordered]@{
            exitCode = 0
            alreadyPrepared = $true
        }
    }

    $result = [ordered]@{
        exitCode = 0
        prechecks = [ordered]@{}
        install = [ordered]@{}
        startup = [ordered]@{}
        services = [ordered]@{}
        errors = @()
    }

    try {
        Write-SBLog 'Preparing sandbox runtime stack (pipeline prechecks + framework install + startup ordering)...'

        # 1) Pipeline prechecks
        $preReqScript = Join-Path (Join-Path $LocalPath 'scripts') 'Test-Prerequisites.ps1'
        if (-not (Test-Path -LiteralPath $preReqScript)) {
            throw "Pipeline precheck script missing: $preReqScript"
        }

        Write-SBLog 'Running pipeline precheck script (Test-Prerequisites.ps1)...'
        $preReqProc = Start-Process -FilePath $script:PowerShellExe -ArgumentList @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy','Bypass',
            '-File',$preReqScript
        ) -Wait -PassThru -NoNewWindow
        $result.prechecks.preReqScriptExitCode = $preReqProc.ExitCode
        if ($preReqProc.ExitCode -ne 0) {
            throw "Test-Prerequisites.ps1 failed with exit code $($preReqProc.ExitCode)."
        }

        $schedulerModule = Join-Path (Join-Path $LocalPath 'modules') 'CronAiAthon-Scheduler.psm1'
        if (Test-Path -LiteralPath $schedulerModule) {
            Write-SBLog 'Running CronAiAthon pipeline precheck (Invoke-PreRequisiteCheck)...'
            Import-Module -Name $schedulerModule -Force -DisableNameChecking -ErrorAction Stop
            $schedulerPreReq = Invoke-PreRequisiteCheck -WorkspacePath $LocalPath
            $result.prechecks.schedulerPassed = [bool]$schedulerPreReq.allPassed
            $result.prechecks.schedulerFailedChecks = [int]$schedulerPreReq.failed
            if (-not $schedulerPreReq.allPassed) {
                throw "CronAiAthon prechecks failed ($($schedulerPreReq.failed) failing checks)."
            }
        } else {
            Write-SBLog "Scheduler module not found for additional prechecks: $schedulerModule" -Level 'WARN'
            $result.prechecks.schedulerPassed = $false
        }

        # 2) Install required frameworks and modules
        if (Test-Path -LiteralPath $setupEnvScript) {
            Write-SBLog 'Installing required PowerShell module framework (Setup-ModuleEnvironment -Action Install)...'
            $setupProc = Start-Process -FilePath $script:PowerShellExe -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy','Bypass',
                '-File',$setupEnvScript,
                '-Action','Install',
                '-Scope','CurrentUser',
                '-WorkspacePath',$LocalPath
            ) -Wait -PassThru -NoNewWindow
            $result.install.moduleInstallExitCode = $setupProc.ExitCode
            if ($setupProc.ExitCode -ne 0) {
                throw "Setup-ModuleEnvironment install failed with exit code $($setupProc.ExitCode)."
            }
        } else {
            Write-SBLog "Setup script missing: $setupEnvScript" -Level 'WARN'
            $result.install.moduleInstallExitCode = -1
        }

        $requirementsPath = Join-Path (Join-Path (Join-Path $LocalPath 'scripts') 'service-cluster-dashboard') 'requirements.txt'
        $venvDir = Join-Path $LocalPath '.venv'
        $venvScripts = Join-Path $venvDir 'Scripts'
        $venvPython = Join-Path $venvScripts 'python.exe'
        $venvPip = Join-Path $venvScripts 'pip.exe'

        if (Test-Path -LiteralPath $requirementsPath) {
            if (-not (Test-Path -LiteralPath $venvPython)) {
                $pythonHost = $null
                $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
                if ($null -ne $pyCmd) { $pythonHost = $pyCmd.Source }
                if ($null -eq $pythonHost) {
                    $py3Cmd = Get-Command python.exe -ErrorAction SilentlyContinue
                    if ($null -ne $py3Cmd) { $pythonHost = $py3Cmd.Source }
                }
                if ($null -eq $pythonHost) {
                    throw 'No Python host found (py.exe/python.exe) to create virtual environment.'
                }

                Write-SBLog "Creating Python virtual environment: $venvDir"
                if ($pythonHost.ToLowerInvariant().EndsWith('py.exe')) {
                    & $pythonHost -3 -m venv $venvDir
                } else {
                    & $pythonHost -m venv $venvDir
                }
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
                    throw 'Failed to create Python virtual environment for dashboard dependencies.'
                }
            }

            if (-not (Test-Path -LiteralPath $venvPip)) {
                throw "pip not found in virtual environment: $venvPip"
            }

            Write-SBLog 'Installing Service Cluster Dashboard Python requirements...'
            & $venvPip install -r $requirementsPath --disable-pip-version-check
            $result.install.dashboardPipExitCode = $LASTEXITCODE
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to install dashboard requirements (exit code $LASTEXITCODE)."
            }
        } else {
            Write-SBLog "Dashboard requirements file missing: $requirementsPath" -Level 'WARN'
            $result.install.dashboardPipExitCode = -1
        }

        # 3) Load MainGUI (TaskTray), Cluster Dash pre-stage, and CronAiAthon process
        $mainGuiScript = Join-Path $LocalPath 'Main-GUI.ps1'
        if (Test-Path -LiteralPath $mainGuiScript) {
            if ($null -eq $script:mainGuiProcess -or $script:mainGuiProcess.HasExited) {
                Write-SBLog 'Loading MainGUI in TaskTray mode...'
                $script:mainGuiProcess = Start-Process -FilePath $script:PowerShellExe -ArgumentList @(
                    '-NoProfile',
                    '-NonInteractive',
                    '-ExecutionPolicy','Bypass',
                    '-File',$mainGuiScript,
                    '-StartupMode','quik_jnr',
                    '-TaskTray',
                    '-SuppressFromFooterCheckpoint'
                ) -PassThru -WindowStyle Hidden
            } else {
                Write-SBLog "MainGUI already running (PID $($script:mainGuiProcess.Id))."
            }
            $result.startup.mainGuiPid = if ($null -ne $script:mainGuiProcess) { $script:mainGuiProcess.Id } else { $null }
        } else {
            throw "Main-GUI script not found: $mainGuiScript"
        }

        $clusterServer = Join-Path (Join-Path (Join-Path $LocalPath 'scripts') 'service-cluster-dashboard') 'server.py'
        if (Test-Path -LiteralPath $clusterServer) {
            Write-SBLog 'Pre-loading TaskTrayApps Cluster Dash dependencies...'
            if (Test-Path -LiteralPath $venvPython) {
                & $venvPython -c "import fastapi, uvicorn"
                $result.startup.clusterDashPreloadExitCode = $LASTEXITCODE
                if ($LASTEXITCODE -ne 0) {
                    throw "Cluster Dash dependency preload failed (exit code $LASTEXITCODE)."
                }
            }
        } else {
            throw "TaskTrayApps Cluster Dash backend not found: $clusterServer"
        }

        $cronScript = Join-Path (Join-Path $LocalPath 'scripts') 'Invoke-CronProcessor.ps1'
        if (Test-Path -LiteralPath $cronScript) {
            if ($null -eq $script:cronProcess -or $script:cronProcess.HasExited) {
                Write-SBLog 'Starting CronAiAthon process...'
                $script:cronProcess = Start-Process -FilePath $script:PowerShellExe -ArgumentList @(
                    '-NoProfile',
                    '-NonInteractive',
                    '-ExecutionPolicy','Bypass',
                    '-File',$cronScript,
                    '-WorkspacePath',$LocalPath
                ) -PassThru -WindowStyle Hidden
            } else {
                Write-SBLog "CronAiAthon process already running (PID $($script:cronProcess.Id))."
            }
            $result.startup.cronPid = if ($null -ne $script:cronProcess) { $script:cronProcess.Id } else { $null }
        } else {
            throw "CronAiAthon script not found: $cronScript"
        }

        # 4) Launch local web services after process stack is loaded
        $engineServiceScript = Join-Path (Join-Path $LocalPath 'scripts') 'Start-LocalWebEngineService.ps1'
        if (-not (Test-Path -LiteralPath $engineServiceScript)) {
            throw "Engine service script missing: $engineServiceScript"
        }

        if (-not (Test-HttpEndpoint -Url 'http://127.0.0.1:8042/api/engine/status' -TimeoutSec 5 -PollSec 1)) {
            Write-SBLog 'Launching local webservice on port 8042...'
            $script:webEngine8042Process = Start-Process -FilePath $script:PowerShellExe -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy','Bypass',
                '-File',$engineServiceScript,
                '-Action','Start',
                '-Port','8042',
                '-WorkspacePath',$LocalPath,
                '-NoTray'
            ) -PassThru -WindowStyle Hidden
        } else {
            Write-SBLog 'Local webservice 8042 already online.'
        }

        if (-not (Test-HttpEndpoint -Url 'http://127.0.0.1:8042/api/engine/status' -TimeoutSec 45 -PollSec 3)) {
            throw 'Local webservice 8042 did not reach healthy status in time.'
        }
        $result.services.port8042 = 'ONLINE'

        $clusterLauncher = Join-Path (Join-Path (Join-Path $LocalPath 'scripts') 'service-cluster-dashboard') 'Launch-ServiceClusterDashboard.bat'
        if (-not (Test-Path -LiteralPath $clusterLauncher)) {
            throw "Cluster dashboard launcher missing: $clusterLauncher"
        }

        if (-not (Test-HttpEndpoint -Url 'http://127.0.0.1:8099/api/ping' -TimeoutSec 5 -PollSec 1)) {
            Write-SBLog 'Launching local webservice on port 8099 (Service Cluster Dashboard)...'
            $clusterLaunchCmd = ('"{0}" /AUTO' -f $clusterLauncher)
            $script:clusterDashboardProcess = Start-Process -FilePath 'cmd.exe' -ArgumentList @(
                '/c',
                $clusterLaunchCmd
            ) -WorkingDirectory (Split-Path -Parent $clusterLauncher) -PassThru -WindowStyle Hidden
        } else {
            Write-SBLog 'Local webservice 8099 already online.'
        }

        if (-not (Test-HttpEndpoint -Url 'http://127.0.0.1:8099/api/ping' -TimeoutSec 60 -PollSec 3)) {
            throw 'Local webservice 8099 did not reach healthy status in time.'
        }
        $result.services.port8099 = 'ONLINE'

        $script:stackPrepared = $true
        Write-SBLog 'Sandbox runtime stack preparation complete.' -Level 'OK'
    } catch {
        $result.exitCode = 1
        $result.errors += $_.Exception.Message
        Write-SBLog "Sandbox stack preparation failed: $($_.Exception.Message)" -Level 'ERROR'
    }

    return $result
}

function Invoke-RunTests {
    <# Runs the smoke test suite inside sandbox #>
    param([hashtable]$Params)

    $prep = Invoke-PrepareSandboxRuntimeStack -Params $Params
    if ($prep.exitCode -ne 0) {
        return @{ exitCode = 1; stage = 'prepare'; prepare = $prep }
    }

    $testScript = Join-Path $LocalPath 'tests\Invoke-GUISmokeTest.ps1'
    if (-not (Test-Path $testScript)) {
        Write-SBLog "Smoke test script not found: $testScript" -Level 'ERROR'
        return @{ exitCode = -1; error = 'Script not found' }
    }

    $testArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$testScript)
    if ($Params -and $Params.headless) { $testArgs += '-HeadlessOnly' }
    if ($Params -and $Params.skipPhase) { $testArgs += @('-SkipPhase',($Params.skipPhase -join ',')) }
    Write-SBLog "Running smoke test: $script:PowerShellExe $($testArgs -join ' ')"

    $testLogDir = Join-Path $LocalPath 'logs'
    $proc = Start-Process -FilePath $script:PowerShellExe -ArgumentList $testArgs -Wait -PassThru -NoNewWindow
    Write-SBLog "Smoke test exit code: $($proc.ExitCode)" -Level $(if ($proc.ExitCode -eq 0) { 'OK' } else { 'WARN' })

    # Copy result logs to output
    if (Test-Path $testLogDir) {
        $logFiles = Get-ChildItem $testLogDir -File -Filter '*SmokeTest*' -ErrorAction SilentlyContinue
        foreach ($lf in $logFiles) {
            Copy-Item $lf.FullName $OutputPath -Force -ErrorAction SilentlyContinue
        }
        Write-SBLog "Copied $(@($logFiles).Count) log files to output"
    }
    return @{ exitCode = $proc.ExitCode; logsCopied = @($logFiles).Count }
}

function Invoke-LaunchGUI {
    <# Launches Main-GUI.ps1 interactively inside sandbox #>
    param([hashtable]$Params)
    $mainScript = Join-Path $LocalPath 'Main-GUI.ps1'
    if (-not (Test-Path $mainScript)) {
        Write-SBLog "Main-GUI.ps1 not found: $mainScript" -Level 'ERROR'
        return @{ error = 'Script not found' }
    }

    # Kill existing GUI if running
    if ($script:guiProcess -and (-not $script:guiProcess.HasExited)) {
        Write-SBLog 'Stopping existing GUI process...'
        try { $script:guiProcess.Kill() } catch { Write-SBLog "Kill failed: $_" -Level 'WARN' }
        Start-Sleep -Seconds 2
    }

    $mode = if ($Params -and $Params.mode) { $Params.mode } else { 'quik_jnr' }
    $guiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$mainScript,'-StartupMode',$mode)
    Write-SBLog "Launching GUI: $script:PowerShellExe $($guiArgs -join ' ')"
    $script:guiProcess = Start-Process -FilePath $script:PowerShellExe -ArgumentList $guiArgs -PassThru
    Write-SBLog "GUI PID: $($script:guiProcess.Id)" -Level 'OK'
    return @{ pid = $script:guiProcess.Id; mode = $mode }
}

function Invoke-StopGUI {
    <# Stops the running GUI process #>
    param([hashtable]$Params)
    if ($script:guiProcess -and (-not $script:guiProcess.HasExited)) {
        Write-SBLog "Stopping GUI (PID $($script:guiProcess.Id))..."
        try {
            $script:guiProcess.CloseMainWindow() | Out-Null
            if (-not $script:guiProcess.WaitForExit(5000)) {
                $script:guiProcess.Kill()
            }
        } catch {
            Write-SBLog "Stop error: $_" -Level 'WARN'
        }
        Write-SBLog 'GUI stopped' -Level 'OK'
        return @{ stopped = $true }
    }
    Write-SBLog 'No GUI process running' -Level 'WARN'
    return @{ stopped = $false }
}

function Invoke-ExecCommand {
    <# Executes an arbitrary PowerShell command inside sandbox #>
    param([hashtable]$Params)
    if (-not $Params -or -not $Params.command) {
        Write-SBLog 'Exec: no command provided' -Level 'ERROR'
        return @{ error = 'No command' }
    }
    $cmd = $Params.command
    Write-SBLog "Exec: $cmd"
    try {
        $sb = [scriptblock]::Create($cmd)
        $result = & $sb 2>&1 | Out-String
        Write-SBLog "Exec result (truncated): $($result.Substring(0, [Math]::Min(200, $result.Length)))"
        return @{ output = $result; exitCode = 0 }
    } catch {
        Write-SBLog "Exec error: $_" -Level 'ERROR'
        return @{ error = $_.ToString(); exitCode = 1 }
    }
}

function Resolve-SandboxPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $LocalPath $Path)
}

function Invoke-OpenScript {
    param([hashtable]$Params)

    if (-not $Params -or [string]::IsNullOrWhiteSpace([string]$Params.path)) {
        return @{ exitCode = 1; error = 'OpenScript requires path' }
    }
    $scriptPath = Resolve-SandboxPath -Path ([string]$Params.path)
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @{ exitCode = 1; error = "Script not found: $scriptPath" }
    }
    $script:guiProcess = Start-Process -FilePath $script:PowerShellExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) -PassThru
    Write-SBLog "Opened script: $scriptPath (PID $($script:guiProcess.Id))" -Level 'OK'
    return @{ exitCode = 0; pid = $script:guiProcess.Id; path = $scriptPath }
}

function Invoke-OpenText {
    param([hashtable]$Params)

    if (-not $Params -or [string]::IsNullOrWhiteSpace([string]$Params.path)) {
        return @{ exitCode = 1; error = 'OpenText requires path' }
    }
    $textPath = Resolve-SandboxPath -Path ([string]$Params.path)
    if (-not (Test-Path -LiteralPath $textPath)) {
        return @{ exitCode = 1; error = "Text file not found: $textPath" }
    }
    $notepad = Join-Path $env:WINDIR 'System32\notepad.exe'
    $textProcess = Start-Process -FilePath $notepad -ArgumentList @($textPath) -PassThru
    Write-SBLog "Opened text file: $textPath (PID $($textProcess.Id))" -Level 'OK'
    return @{ exitCode = 0; pid = $textProcess.Id; path = $textPath }
}

function Invoke-ChaosTest {
    <# Runs chaos test conditions inside sandbox #>
    param([hashtable]$Params)
    $chaosScript = Join-Path $LocalPath 'tests\Invoke-ChaosTestConditions.ps1'
    if (-not (Test-Path $chaosScript)) {
        Write-SBLog "Chaos script not found" -Level 'ERROR'
        return @{ error = 'Chaos script not found' }
    }
    $chaosArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$chaosScript,'-WorkspacePath',$LocalPath,'-RunSmokeTest','-HeadlessOnly')
    Write-SBLog "Running chaos test..."
    $proc = Start-Process -FilePath $script:PowerShellExe -ArgumentList $chaosArgs -Wait -PassThru -NoNewWindow
    # Copy chaos logs
    $chaosLogs = Get-ChildItem (Join-Path $LocalPath 'logs') -Filter '*Chaos*' -ErrorAction SilentlyContinue
    foreach ($cl in $chaosLogs) {
        Copy-Item $cl.FullName $OutputPath -Force -ErrorAction SilentlyContinue
    }
    Write-SBLog "Chaos test exit code: $($proc.ExitCode)" -Level $(if ($proc.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    return @{ exitCode = $proc.ExitCode }
}

function Invoke-BrowserTest {
    <# Runs full browser compatibility test suite inside sandbox #>
    param([hashtable]$Params)

    $prep = Invoke-PrepareSandboxRuntimeStack -Params $Params
    if ($prep.exitCode -ne 0) {
        return @{ exitCode = 1; stage = 'prepare'; prepare = $prep }
    }

    $sandboxDir = Join-Path $LocalPath 'tests\sandbox'
    $installScript = Join-Path $sandboxDir 'Install-BrowserTestDependencies.ps1'
    $suiteScript   = Join-Path $sandboxDir 'Invoke-SandboxBrowserTestSuite.ps1'
    $archiveScript = Join-Path $sandboxDir 'Export-SandboxTestArchive.ps1'

    if (-not (Test-Path $installScript)) {
        Write-SBLog "Browser test install script not found" -Level 'ERROR'
        return @{ error = 'Install-BrowserTestDependencies.ps1 not found' }
    }

    Write-SBLog "Installing browser test dependencies..."
    $installArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$installScript,'-WorkspacePath',$LocalPath,'-OutputPath',$OutputPath)
    $proc1 = Start-Process -FilePath $script:PowerShellExe -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    if ($proc1.ExitCode -ne 0) {
        Write-SBLog "Dependency install failed: exit $($proc1.ExitCode)" -Level 'ERROR'
        return @{ exitCode = $proc1.ExitCode; stage = 'install' }
    }

    Write-SBLog "Running browser test suite..."
    $suiteArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$suiteScript,'-WorkspacePath',$LocalPath,'-OutputPath',$OutputPath,'-IncludeReadme')
    if ($Params -and $Params.ContainsKey('EdgeOnly') -and $Params['EdgeOnly']) {
        $suiteArgs += '-EdgeOnly'
    }
    if ($Params -and $Params.ContainsKey('SkipDataState') -and $Params['SkipDataState']) {
        $suiteArgs += '-SkipDataState'
    }
    $proc2 = Start-Process -FilePath $script:PowerShellExe -ArgumentList $suiteArgs -Wait -PassThru -NoNewWindow

    Write-SBLog "Creating test archive..."
    $archiveArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$archiveScript,'-OutputPath',$OutputPath)
    if ($Params -and $Params.ContainsKey('CertThumbprint')) {
        $archiveArgs += @('-CertThumbprint',[string]$Params['CertThumbprint'])
    }
    $proc3 = Start-Process -FilePath $script:PowerShellExe -ArgumentList $archiveArgs -Wait -PassThru -NoNewWindow

    Write-SBLog "Browser test complete. Suite:$($proc2.ExitCode) Archive:$($proc3.ExitCode)" -Level $(if ($proc2.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    return @{ suiteExitCode = $proc2.ExitCode; archiveExitCode = $proc3.ExitCode }
}

# ========================== COMMAND LOOP ==========================
Set-SandboxStatus -Status 'READY' -Detail 'Waiting for commands'
Write-SBLog '=================================================================='
Write-SBLog '  Sandbox READY -- Watching for commands'
Write-SBLog "  Poll interval: ${PollInterval}s | Max idle: ${MaxIdleMinutes}m"
Write-SBLog '=================================================================='

$lastActivity = Get-Date
$running = $true

while ($running) {
    Start-Sleep -Seconds $PollInterval

    # Check idle timeout
    $idle = (Get-Date) - $lastActivity
    if ($idle.TotalMinutes -ge $MaxIdleMinutes) {
        Write-SBLog "Idle timeout ($MaxIdleMinutes min) reached. Shutting down." -Level 'WARN'
        Set-SandboxStatus -Status 'IDLE_TIMEOUT'
        break
    }

    # Scan for command files
    $cmdFiles = Get-ChildItem $CommandPath -Filter '*.cmd.json' -ErrorAction SilentlyContinue |
                Sort-Object Name
    foreach ($cf in $cmdFiles) {
        $lastActivity = Get-Date
        $script:iterationCount++
        $cmdId = $cf.BaseName -replace '\.cmd$', ''

        try {
            $cmdData = Get-Content $cf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-SBLog "Failed to parse command: $($cf.Name) -- $_" -Level 'ERROR'
            Remove-Item $cf.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        $action = $cmdData.action
        $params = @{}
        if ($cmdData.PSObject.Properties.Name -contains 'params') {
            # Convert PSCustomObject to hashtable
            $cmdData.params.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value }
        }

        Write-SBLog "CMD [$cmdId] Action=$action Iteration=$($script:iterationCount)"
        Set-SandboxStatus -Status 'RUNNING' -Detail "Action: $action (iter $($script:iterationCount))"

        # Remove command file before processing (ack)
        Remove-Item $cf.FullName -Force -ErrorAction SilentlyContinue

        # Dispatch
        $result = switch ($action) {
            'Sync'     { Invoke-SyncWorkspace -Params $params }
            'Test'     { Invoke-RunTests -Params $params }
            'GUI'      { Invoke-LaunchGUI -Params $params }
            'OpenScript' { Invoke-OpenScript -Params $params }
            'OpenText' { Invoke-OpenText -Params $params }
            'StopGUI'  { Invoke-StopGUI -Params $params }
            'Exec'     { Invoke-ExecCommand -Params $params }
            'Chaos'       { Invoke-ChaosTest -Params $params }
            'BrowserTest' { Invoke-BrowserTest -Params $params }
            'Shutdown' {
                Write-SBLog 'Shutdown command received.' -Level 'WARN'
                $running = $false
                @{ shutdown = $true }
            }
            default {
                Write-SBLog "Unknown action: $action" -Level 'ERROR'
                @{ error = "Unknown action: $action" }
            }
        }

        # Write result file
        $resultObj = @{
            cmdId     = $cmdId
            action    = $action
            iteration = $script:iterationCount
            result    = $result
            timestamp = (Get-Date -Format 'o')
        }
        $resultPath = Join-Path $OutputPath "$cmdId.result.json"
        ConvertTo-Json $resultObj -Depth 5 | Set-Content $resultPath -Encoding UTF8

        Set-SandboxStatus -Status 'READY' -Detail "Last: $action (iter $($script:iterationCount))"
    }
}

# ========================== CLEANUP ==========================
Write-SBLog 'Sandbox bootstrap exiting.'
if ($script:guiProcess -and (-not $script:guiProcess.HasExited)) {
    Write-SBLog 'Killing GUI on exit...'
    try { $script:guiProcess.Kill() } catch { Write-SBLog "Kill failed: $_" -Level 'WARN' }
}
foreach ($tracked in @('mainGuiProcess','cronProcess','webEngine8042Process','clusterDashboardProcess')) {
    $proc = $null
    try { $proc = Get-Variable -Name $tracked -Scope Script -ErrorAction SilentlyContinue } catch { $proc = $null }
    if ($null -ne $proc -and $null -ne $proc.Value) {
        try {
            if (-not $proc.Value.HasExited) {
                Write-SBLog "Stopping process '$tracked' (PID $($proc.Value.Id))..."
                $proc.Value.Kill()
            }
        } catch {
            Write-SBLog "Unable to stop process '$tracked': $($_.Exception.Message)" -Level 'WARN'
        }
    }
}
Set-SandboxStatus -Status 'SHUTDOWN' -Detail "Iterations: $($script:iterationCount)"

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>







