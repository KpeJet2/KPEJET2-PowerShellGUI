# VersionTag: 2605.B2.V31.7
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
    [int]$MaxIdleMinutes  = 120
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

# ========================== COMMAND HANDLERS ==========================
$script:guiProcess = $null
$script:iterationCount = 0

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

function Invoke-RunTests {
    <# Runs the smoke test suite inside sandbox #>
    param([hashtable]$Params)
    $testScript = Join-Path $LocalPath 'tests\Invoke-GUISmokeTest.ps1'
    if (-not (Test-Path $testScript)) {
        Write-SBLog "Smoke test script not found: $testScript" -Level 'ERROR'
        return @{ exitCode = -1; error = 'Script not found' }
    }

    $headless = if ($Params -and $Params.headless) { '-HeadlessOnly' } else { '' }
    $skipPhase = ''
    if ($Params -and $Params.skipPhase) {
        $skipPhase = "-SkipPhase $($Params.skipPhase -join ',')"
    }

    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$testScript`" $headless $skipPhase"
    Write-SBLog "Running smoke test: powershell.exe $args"

    $testLogDir = Join-Path $LocalPath 'logs'
    $proc = Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
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
    $guiArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScript`" -StartupMode $mode"
    Write-SBLog "Launching GUI: powershell.exe $guiArgs"
    $script:guiProcess = Start-Process powershell.exe -ArgumentList $guiArgs -PassThru
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

function Invoke-ChaosTest {
    <# Runs chaos test conditions inside sandbox #>
    param([hashtable]$Params)
    $chaosScript = Join-Path $LocalPath 'tests\Invoke-ChaosTestConditions.ps1'
    if (-not (Test-Path $chaosScript)) {
        Write-SBLog "Chaos script not found" -Level 'ERROR'
        return @{ error = 'Chaos script not found' }
    }
    $chaosArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$chaosScript`" -WorkspacePath $LocalPath -RunSmokeTest -HeadlessOnly"
    Write-SBLog "Running chaos test..."
    $proc = Start-Process powershell.exe -ArgumentList $chaosArgs -Wait -PassThru -NoNewWindow
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
    $sandboxDir = Join-Path $LocalPath 'tests\sandbox'
    $installScript = Join-Path $sandboxDir 'Install-BrowserTestDependencies.ps1'
    $suiteScript   = Join-Path $sandboxDir 'Invoke-SandboxBrowserTestSuite.ps1'
    $archiveScript = Join-Path $sandboxDir 'Export-SandboxTestArchive.ps1'

    if (-not (Test-Path $installScript)) {
        Write-SBLog "Browser test install script not found" -Level 'ERROR'
        return @{ error = 'Install-BrowserTestDependencies.ps1 not found' }
    }

    Write-SBLog "Installing browser test dependencies..."
    $installArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -WorkspacePath `"$LocalPath`" -OutputPath `"$OutputPath`""
    $proc1 = Start-Process powershell.exe -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    if ($proc1.ExitCode -ne 0) {
        Write-SBLog "Dependency install failed: exit $($proc1.ExitCode)" -Level 'ERROR'
        return @{ exitCode = $proc1.ExitCode; stage = 'install' }
    }

    Write-SBLog "Running browser test suite..."
    $suiteArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$suiteScript`" -WorkspacePath `"$LocalPath`" -OutputPath `"$OutputPath`" -IncludeReadme"
    if ($Params -and $Params.ContainsKey('EdgeOnly') -and $Params['EdgeOnly']) {
        $suiteArgs += ' -EdgeOnly'
    }
    if ($Params -and $Params.ContainsKey('SkipDataState') -and $Params['SkipDataState']) {
        $suiteArgs += ' -SkipDataState'
    }
    $proc2 = Start-Process powershell.exe -ArgumentList $suiteArgs -Wait -PassThru -NoNewWindow

    Write-SBLog "Creating test archive..."
    $archiveArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$archiveScript`" -OutputPath `"$OutputPath`""
    if ($Params -and $Params.ContainsKey('CertThumbprint')) {
        $archiveArgs += " -CertThumbprint `"$($Params['CertThumbprint'])`""
    }
    $proc3 = Start-Process powershell.exe -ArgumentList $archiveArgs -Wait -PassThru -NoNewWindow

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





