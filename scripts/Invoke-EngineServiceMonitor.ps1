# VersionTag: 2605.B5.V46.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-06
# SupportsPS7.6TestedDate: 2026-05-06
# FileRole: ServiceMonitor
#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive CLI monitor for engine and service startup orchestration.
.DESCRIPTION
    Provides a rerunnable monitor entrypoint with uniform slash-switch actions:
      /AUTO (default), /0 test run, /1 start, /2 restart, /3 stop, /4 pipeline handoff.

    The monitor reads static targets from config/engine-monitor.targets.json and also
    auto-discovers new engine/service-style launch scripts via wildcard patterns.
.EXAMPLE
    .\scripts\Invoke-EngineServiceMonitor.ps1
    .\scripts\Invoke-EngineServiceMonitor.ps1 /AUTO
    .\scripts\Invoke-EngineServiceMonitor.ps1 /1
    .\scripts\Invoke-EngineServiceMonitor.ps1 /4
    .\scripts\Invoke-EngineServiceMonitor.ps1 -Interactive
#>
[CmdletBinding()]
param(
    [string]$Action = 'AUTO',
    [string]$WorkspacePath = '',
    [string]$TargetsPath = '',
    [string[]]$TargetName = @(),
    [switch]$Interactive,
    [switch]$Watch,
    [switch]$IncludeDisabled,
    [switch]$NoPipelineHandoff,
    [switch]$Quiet,
    [switch]$DryRun,
    [ValidateRange(5,120)]
    [int]$StartTimeoutSec = 20,
    [ValidateRange(5,300)]
    [int]$RefreshSec = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $WorkspacePath = Split-Path -Parent $PSScriptRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        $scriptDirFallback = Split-Path -Parent $MyInvocation.MyCommand.Path
        $WorkspacePath = Split-Path -Parent $scriptDirFallback
    } else {
        $WorkspacePath = (Get-Location).Path
    }
}

$script:MonitorLogPath = $null
$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:CurrentProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
$script:TerminalTabSettings = $null
$script:TerminalWindowId = ''
$script:TerminalWindowOpened = $false
$script:UserTerminalTabsLaunched = $false
$script:TerminalUnavailableWarned = $false
$script:MonitorConfigPath = ''
$script:MonitorOptions = $null
$script:LauncherSets = $null
$script:ReportPorts = @()

function Write-MonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION','PASS','FAIL','DEBUG')] [string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"

    if (-not $Quiet) {
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'FAIL'  { 'Red' }
            'WARN'  { 'Yellow' }
            'PASS'  { 'Green' }
            'ACTION' { 'Cyan' }
            'DEBUG' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }

    if ($script:MonitorLogPath) {
        Add-Content -LiteralPath $script:MonitorLogPath -Value $line -Encoding UTF8
    }
}

function ConvertTo-RelativePathSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RootPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($RootPath)
    $pathFull = [System.IO.Path]::GetFullPath($Path)

    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $pathFull.Substring($rootFull.Length).TrimStart('\')
        return ($trimmed -replace '\\', '/')
    }

    return ($pathFull -replace '\\', '/')
}

function Resolve-LegacySwitchAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CurrentAction,
        [AllowNull()] [object[]]$UnboundArguments
    )

    $resolved = $CurrentAction
    $legacyMap = @{
        'AUTO' = 'AUTO'
        '0' = '0'
        '1' = '1'
        '2' = '2'
        '3' = '3'
        '4' = '4'
        '5' = 'STATUS'
        '6' = 'REPORT'
        '7' = 'AUTOSTART'
        '8' = 'WATCH'
        'LIST' = 'LIST'
        'STATUS' = 'STATUS'
        'REPORT' = 'REPORT'
        'AUTOSTART' = 'AUTOSTART'
        'WATCH' = 'WATCH'
        'HELP' = 'HELP'
        '?' = 'HELP'
    }

    $inputTokens = @($UnboundArguments)
    if (@($inputTokens).Count -eq 0) { return $resolved }

    $first = $inputTokens[0]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    if ($first -isnot [string]) { return $resolved }

    $token = ([string]$first).Trim()
    $tokenMatch = [regex]::Match($token, '^/(.+)$')
    if (-not $tokenMatch.Success) { return $resolved }

    $raw = $tokenMatch.Groups[1].Value.ToUpperInvariant()
    if ($legacyMap.ContainsKey($raw)) {
        return $legacyMap[$raw]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }

    return $resolved
}

function Resolve-PowerShellHost {
    [CmdletBinding()]
    param([string]$HostPreference = 'auto')

    switch ($HostPreference) {
        'pwsh' {
            if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
        }
        'powershell' {
            if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
        }
        default {
            if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
            if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
        }
    }

    return $null
}

function New-DefaultUserTerminalTabs {
    [CmdletBinding()]
    param()

    return @(
        [PSCustomObject]@{ title = 'User nslookup'; shell = 'cmd.exe'; args = @('/k','nslookup') },
        [PSCustomObject]@{ title = 'User cmd'; shell = 'cmd.exe'; args = @('/k') },
        [PSCustomObject]@{ title = 'User pwsh'; shell = 'pwsh.exe'; args = @('-NoLogo','-NoExit') }
    )
}

function Get-TerminalTabSettings {
    [CmdletBinding()]
    param(
        [AllowNull()] [object]$Config
    )

    $settings = [ordered]@{
        enabled = $true
        windowIdPrefix = 'engine-monitor'
        launchUserTabs = $true
        userTabs = @(New-DefaultUserTerminalTabs)
    }

    if ($null -eq $Config) {
        return [PSCustomObject]$settings
    }

    if (-not ($Config.PSObject.Properties.Name -contains 'terminalTabs')) {
        return [PSCustomObject]$settings
    }

    $raw = $Config.terminalTabs
    if ($raw.PSObject.Properties.Name -contains 'enabled') {
        $settings.enabled = [bool]$raw.enabled
    }
    if ($raw.PSObject.Properties.Name -contains 'windowIdPrefix' -and -not [string]::IsNullOrWhiteSpace([string]$raw.windowIdPrefix)) {
        $settings.windowIdPrefix = [string]$raw.windowIdPrefix
    }
    if ($raw.PSObject.Properties.Name -contains 'launchUserTabs') {
        $settings.launchUserTabs = [bool]$raw.launchUserTabs
    }
    if ($raw.PSObject.Properties.Name -contains 'userTabs') {
        $parsedTabs = @()
        foreach ($tab in @($raw.userTabs)) {
            $tabTitle = if ($tab.PSObject.Properties.Name -contains 'title') { [string]$tab.title } else { '' }
            $tabShell = if ($tab.PSObject.Properties.Name -contains 'shell') { [string]$tab.shell } else { '' }
            $tabArgs = if ($tab.PSObject.Properties.Name -contains 'args') {
                @($tab.args | ForEach-Object { [string]$_ })
            } else {
                @()
            }

            if ([string]::IsNullOrWhiteSpace($tabShell)) { continue }
            if ([string]::IsNullOrWhiteSpace($tabTitle)) { $tabTitle = $tabShell }

            $parsedTabs += [PSCustomObject]@{
                title = $tabTitle
                shell = $tabShell
                args = $tabArgs
            }
        }

        if (@($parsedTabs).Count -gt 0) {
            $settings.userTabs = @($parsedTabs)
        }
    }

    return [PSCustomObject]$settings
}

function Resolve-WindowsTerminalExecutable {
    [CmdletBinding()]
    param()

    $command = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [string]$command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        $fallback = Join-Path $windowsApps 'wt.exe'
        if (Test-Path -LiteralPath $fallback) {
            return $fallback
        }
    }

    return $null
}

function Get-TerminalWindowId {
    [CmdletBinding()]
    param([string]$Prefix = 'engine-monitor')

    if ([string]::IsNullOrWhiteSpace($script:TerminalWindowId)) {
        $safePrefix = if ([string]::IsNullOrWhiteSpace($Prefix)) { 'engine-monitor' } else { $Prefix }
        $script:TerminalWindowId = "$safePrefix-$($script:RunStamp)"
    }

    return $script:TerminalWindowId
}

function ConvertTo-PowerShellSingleQuote {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    return "'" + $Text.Replace("'","''") + "'"
}

function Invoke-UserTerminalTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WindowsTerminalExe,
        [Parameter(Mandatory)] [string]$WindowId,
        [switch]$PreviewOnly
    )

    if ($script:UserTerminalTabsLaunched) { return }
    if ($null -eq $script:TerminalTabSettings) { return }
    if (-not $script:TerminalTabSettings.launchUserTabs) { return }

    foreach ($userTab in @($script:TerminalTabSettings.userTabs)) {
        $title = [string]$userTab.title
        $shell = [string]$userTab.shell
        $shellArgs = @()
        if ($userTab.PSObject.Properties.Name -contains 'args') {
            $shellArgs = @($userTab.args | ForEach-Object { [string]$_ })
        }
        if ([string]::IsNullOrWhiteSpace($shell)) { continue }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $shell }

        $windowSelector = if ($script:TerminalWindowOpened) { 'last' } else { 'new' }
        $newTabArgs = @('-w', $windowSelector, 'new-tab', '--title', $title, '--', $shell)
        if (@($shellArgs).Count -gt 0) {
            $newTabArgs += @($shellArgs)
        }

        if ($PreviewOnly) {
            Write-MonitorLog -Level 'DEBUG' -Message "DryRun: would launch user tab '$title' in terminal window $WindowId"
            continue
        }

        try {
            Start-Process -FilePath $WindowsTerminalExe -ArgumentList $newTabArgs -WindowStyle Normal | Out-Null
            Write-MonitorLog -Level 'INFO' -Message "User terminal tab launched: $title"
        } catch {
            Write-MonitorLog -Level 'WARN' -Message "Failed to launch user terminal tab '$title': $($_.Exception.Message)"
        }
    }

    $script:UserTerminalTabsLaunched = $true
}

function Start-TargetInTerminalTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Target,
        [AllowNull()] [string[]]$ModeParameters,
        [switch]$SkipWait,
        [switch]$PreviewOnly,
        [int]$TimeoutSec = 20
    )

    if ($null -eq $script:TerminalTabSettings -or -not $script:TerminalTabSettings.enabled) {
        return [PSCustomObject]@{ Handled = $false; Success = $false; Message = 'Terminal tabs disabled.'; ExitCode = 1; Pid = $null }
    }

    $windowsTerminal = Resolve-WindowsTerminalExecutable
    if ($null -eq $windowsTerminal) {
        if (-not $script:TerminalUnavailableWarned) {
            Write-MonitorLog -Level 'WARN' -Message 'Windows Terminal (wt.exe) not found; falling back to standard process launching.'
            $script:TerminalUnavailableWarned = $true
        }
        return [PSCustomObject]@{ Handled = $false; Success = $false; Message = 'wt.exe not found'; ExitCode = 1; Pid = $null }
    }

    $tabHost = Resolve-PowerShellHost -HostPreference 'pwsh'
    if ($null -eq $tabHost) {
        $tabHost = Resolve-PowerShellHost -HostPreference 'powershell'
    }
    if ($null -eq $tabHost) {
        return [PSCustomObject]@{ Handled = $false; Success = $false; Message = 'No PowerShell host for terminal tabs.'; ExitCode = 1; Pid = $null }
    }

    try {
        $path = Get-TargetAbsolutePath -Workspace $Workspace -Target $Target
    } catch {
        return [PSCustomObject]@{ Handled = $true; Success = $false; Message = $_.Exception.Message; ExitCode = 1; Pid = $null }
    }

    $windowId = Get-TerminalWindowId -Prefix $script:TerminalTabSettings.windowIdPrefix
    $title = "Service: $($Target.name)"
    $windowSelector = if ($script:TerminalWindowOpened) { 'last' } else { 'new' }

    $tabArgs = @('-w', $windowSelector, 'new-tab', '--title', $title, '--', $tabHost, '-NoLogo', '-NoExit', '-NoProfile')
    if ($Target.kind -eq 'PowerShellScript') {
        $tabArgs += @('-ExecutionPolicy', 'Bypass', '-File', $path)
        if (@($ModeParameters).Count -gt 0) {
            $tabArgs += @($ModeParameters)
        }
    } else {
        $quotedPath = ConvertTo-PowerShellSingleQuote -Text $path
        $quotedArgs = @()
        foreach ($item in @($ModeParameters)) {
            $quotedArgs += (ConvertTo-PowerShellSingleQuote -Text ([string]$item))
        }
        $invokeText = "& $quotedPath"
        if (@($quotedArgs).Count -gt 0) {
            $invokeText = $invokeText + ' ' + ($quotedArgs -join ' ')
        }
        $tabArgs += @('-Command', $invokeText)
    }

    if ($PreviewOnly) {
        Invoke-UserTerminalTabs -WindowsTerminalExe $windowsTerminal -WindowId $windowId -PreviewOnly
        return [PSCustomObject]@{
            Handled = $true
            Success = $true
            Message = "DryRun: would launch '$($Target.name)' in Windows Terminal tab window '$windowId'."
            ExitCode = 0
            Pid = $null
        }
    }

    try {
        Start-Process -FilePath $windowsTerminal -ArgumentList $tabArgs -WindowStyle Normal | Out-Null
        $script:TerminalWindowOpened = $true
        Invoke-UserTerminalTabs -WindowsTerminalExe $windowsTerminal -WindowId $windowId -PreviewOnly:$false

        if ($SkipWait) {
            return [PSCustomObject]@{
                Handled = $true
                Success = $true
                Message = "Launched '$($Target.name)' in Windows Terminal tab window '$windowId'."
                ExitCode = 0
                Pid = $null
            }
        }

        $running = Wait-TargetRunning -Target $Target -TimeoutSec $TimeoutSec
        return [PSCustomObject]@{
            Handled = $true
            Success = $running
            Message = if ($running) {
                "Running in Windows Terminal tab window '$windowId'."
            } else {
                "Launched in tab window '$windowId' but status probe did not confirm running."
            }
            ExitCode = if ($running) { 0 } else { 1 }
            Pid = $null
        }
    } catch {
        return [PSCustomObject]@{
            Handled = $true
            Success = $false
            Message = $_.Exception.Message
            ExitCode = 1
            Pid = $null
        }
    }
}

function Show-ActionHelp {
    [CmdletBinding()]
    param()

    $helpText = @'
Invoke-EngineServiceMonitor.ps1

Switch Actions (slash or -Action):
  /AUTO   Default. Show watch list, status scan, start missing auto services,
          retry with restart/stop, then hand unresolved failures to pipeline.
      Background service starts open one pwsh tab per service in a single
      Windows Terminal window and seed user tabs: nslookup, cmd, pwsh.
  /0      Test run. Startup sequence + test events + security query + exit.
  /1      Start watched services (or selected -TargetName values).
  /2      Restart watched services (or selected targets).
  /3      Stop watched services (or selected targets).
  /4      Pipeline process pass: integrity, process, headless smoke, optional restart.
  /5      Status only (alias of STATUS).
    /6      Port lineage report for monitored web services.
    /7      Interactive autoStart toggle editor for static monitor targets.
    /8      Watch mode: 20s countdown refresh with A/B launcher hotkeys.
  /LIST   Show watched services/scripts inventory.
  /STATUS Show status snapshot.
    /REPORT Show web service port listener + PID parent/grandparent report.
    /AUTOSTART Edit autoStart values and persist to config.
    /WATCH  Continuous refresh loop with countdown and hotkeys.
  /HELP   Show this help.

Examples:
  .\scripts\Invoke-EngineServiceMonitor.ps1
  .\scripts\Invoke-EngineServiceMonitor.ps1 /AUTO
  .\scripts\Invoke-EngineServiceMonitor.ps1 /1 -TargetName LocalWebEngineService
    .\scripts\Invoke-EngineServiceMonitor.ps1 /6
    .\scripts\Invoke-EngineServiceMonitor.ps1 /8
  .\scripts\Invoke-EngineServiceMonitor.ps1 -Interactive
'@
    Write-Host $helpText
}

function New-DefaultMonitorConfig {
    [CmdletBinding()]
    param()

    return [ordered]@{
        schema = 'EngineMonitorTargets/1.0'
        includePatterns = @(
            'scripts/*Engine*.ps1',
            'scripts/*Service*.ps1',
            'Launch-*.bat',
            'SmokeTest-*-FireUpAllEngines*.bat',
            'scripts/service-cluster-dashboard/Launch-*.bat',
            'scripts/windguits/**/Launch-*.bat'
        )
        excludePatterns = @('tests/*','~REPORTS/*','reports/*','logs/*','temp/*','.venv/*','~DOWNLOADS/*')
        targets = @()
        terminalTabs = [ordered]@{
            enabled = $true
            windowIdPrefix = 'engine-monitor'
            launchUserTabs = $true
            userTabs = @(
                [ordered]@{ title = 'User nslookup'; shell = 'cmd.exe'; args = @('/k','nslookup') },
                [ordered]@{ title = 'User cmd'; shell = 'cmd.exe'; args = @('/k') },
                [ordered]@{ title = 'User pwsh'; shell = 'pwsh.exe'; args = @('-NoLogo','-NoExit') }
            )
        }
        webServiceReportPorts = @(7042,7771,7772,7773,7774,7775,7776,7777,7778,7779,7080,8042,9042,10042,11042,22042)
        monitorOptions = [ordered]@{
            refreshSeconds = 20
            enableAutoStartEditor = $true
            enableHotkeys = $true
            autoRefreshStatus = $true
        }
        launcherSets = [ordered]@{
            A = @(
                'http://127.0.0.1:8042/',
                'http://127.0.0.1:8042/scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml',
                'file:///{workspace}/XHTML-ChangelogViewer.xhtml',
                'file:///{workspace}/~README.md/PwShGUI-Checklists.xhtml',
                'file:///{workspace}/~REPORTS/SIN-Scoreboard.xhtml'
            )
            B = @(
                'http://127.0.0.1:8042/',
                'http://127.0.0.1:8042/scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml',
                'file:///{workspace}/XHTML-ChangelogViewer.xhtml',
                'file:///{workspace}/~README.md/PwShGUI-Checklists.xhtml',
                'file:///{workspace}/~REPORTS/SIN-Scoreboard.xhtml',
                'file:///{workspace}/XHTML-WorkspaceHub.xhtml',
                'file:///{workspace}/scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml',
                'http://127.0.0.1:8042/XHTML-WorkspaceHub.xhtml',
                'http://127.0.0.1:8042/pages/dependency-vis',
                'http://127.0.0.1:8042/pages/menu-builder'
            )
        }
        pipeline = [ordered]@{
            integrityScript = 'scripts/Invoke-PipelineIntegrityCheck.ps1'
            integrityArgs = @('-WriteReport')
            processScript = 'scripts/Invoke-PipelineProcess20.ps1'
            processArgs = @('-DryRun')
            smokeScript = 'tests/Invoke-GUISmokeTest.ps1'
            smokeArgs = @('-HeadlessOnly')
            securityScript = 'tests/Invoke-SecurityIntegrityTests.ps1'
            securityArgs = @('-Mode','Advisory','-FailOnCritical')
        }
    }
}

function Get-MonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [string]$ConfigPath
    )

    $resolvedPath = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $cfgDir = Join-Path $Workspace 'config'
        $resolvedPath = Join-Path $cfgDir 'engine-monitor.targets.json'
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        Write-MonitorLog -Level 'WARN' -Message "Monitor config not found: $resolvedPath. Using defaults."
        return [PSCustomObject](New-DefaultMonitorConfig)
    }

    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'Config file is empty.'
        }
        $script:MonitorConfigPath = $resolvedPath
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-MonitorLog -Level 'ERROR' -Message "Failed to read monitor config: $($_.Exception.Message)"
        $script:MonitorConfigPath = $resolvedPath
        return [PSCustomObject](New-DefaultMonitorConfig)
    }
}

function Save-MonitorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Config,
        [string]$ConfigPath = ''
    )

    $resolvedPath = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        if (-not [string]::IsNullOrWhiteSpace($script:MonitorConfigPath)) {
            $resolvedPath = $script:MonitorConfigPath
        } else {
            $resolvedPath = Join-Path (Join-Path $Workspace 'config') 'engine-monitor.targets.json'
        }
    }

    $dir = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $resolvedPath -Value $json -Encoding UTF8
    $script:MonitorConfigPath = $resolvedPath
    return $resolvedPath
}

function Get-MonitorOptionSettings {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    $defaults = [ordered]@{
        refreshSeconds = 20
        enableAutoStartEditor = $true
        enableHotkeys = $true
        autoRefreshStatus = $true
    }

    if ($null -eq $Config -or -not ($Config.PSObject.Properties.Name -contains 'monitorOptions')) {
        return [PSCustomObject]$defaults
    }

    $opt = $Config.monitorOptions
    if ($opt.PSObject.Properties.Name -contains 'refreshSeconds') {
        $defaults.refreshSeconds = [int]$opt.refreshSeconds
    }
    if ($opt.PSObject.Properties.Name -contains 'enableAutoStartEditor') {
        $defaults.enableAutoStartEditor = [bool]$opt.enableAutoStartEditor
    }
    if ($opt.PSObject.Properties.Name -contains 'enableHotkeys') {
        $defaults.enableHotkeys = [bool]$opt.enableHotkeys
    }
    if ($opt.PSObject.Properties.Name -contains 'autoRefreshStatus') {
        $defaults.autoRefreshStatus = [bool]$opt.autoRefreshStatus
    }

    if ($defaults.refreshSeconds -lt 5) { $defaults.refreshSeconds = 20 }

    return [PSCustomObject]$defaults
}

function Get-LauncherSets {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    $defaults = (New-DefaultMonitorConfig).launcherSets
    $sets = [ordered]@{
        A = @($defaults.A)
        B = @($defaults.B)
    }

    if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains 'launcherSets')) {
        $rawSets = $Config.launcherSets
        foreach ($setName in @('A','B')) {
            if ($rawSets.PSObject.Properties.Name -contains $setName) {
                $values = @($rawSets.$setName | ForEach-Object { [string]$_ })
                if (@($values).Count -gt 0) {
                    $sets[$setName] = $values  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }
            }
        }
    }

    return $sets
}

function Get-WebServiceReportPorts {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    $defaults = @((New-DefaultMonitorConfig).webServiceReportPorts)
    if ($null -eq $Config -or -not ($Config.PSObject.Properties.Name -contains 'webServiceReportPorts')) {
        return $defaults
    }

    $ports = @()
    foreach ($rawPort in @($Config.webServiceReportPorts)) {
        $p = [int]$rawPort
        if ($p -gt 0) { $ports += $p }
    }

    if (@($ports).Count -eq 0) {
        return $defaults
    }

    return @($ports | Sort-Object -Unique)
}

function Resolve-LauncherValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [string]$Workspace
    )

    $ws = [System.IO.Path]::GetFullPath($Workspace)
    $ws = $ws -replace '\\', '/'
    return $Value.Replace('{workspace}', $ws)
}

function Invoke-LauncherSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SetName,
        [Parameter(Mandatory)] [string]$Workspace,
        [switch]$PreviewOnly
    )

    $hasSet = $false
    if ($null -ne $script:LauncherSets) {
        if ($script:LauncherSets -is [System.Collections.IDictionary]) {
            $hasSet = $script:LauncherSets.Contains($SetName)
        } elseif ($script:LauncherSets.PSObject.Properties.Name -contains $SetName) {
            $hasSet = $true
        }
    }

    if (-not $hasSet) {
        Write-MonitorLog -Level 'WARN' -Message "Launcher set not configured: $SetName"
        return
    }

    $entries = @($script:LauncherSets[$SetName])
    Write-MonitorLog -Level 'ACTION' -Message "Launcher set $SetName requested ($(@($entries).Count) entries)."

    foreach ($entry in $entries) {
        $resolved = Resolve-LauncherValue -Value ([string]$entry) -Workspace $Workspace
        if ([string]::IsNullOrWhiteSpace($resolved)) { continue }

        if ($resolved.StartsWith('file:///', [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $uri = [System.Uri]$resolved
                $filePath = $uri.LocalPath
                if (-not (Test-Path -LiteralPath $filePath)) {
                    Write-MonitorLog -Level 'WARN' -Message "Launcher file missing: $filePath"
                    continue
                }
            } catch {
                Write-MonitorLog -Level 'WARN' -Message "Invalid file URI in launcher set ${SetName}: ${resolved}"
                continue
            }
        }

        if ($PreviewOnly) {
            Write-MonitorLog -Level 'DEBUG' -Message "DryRun: would launch $resolved"
            continue
        }

        try {
            Start-Process $resolved | Out-Null
        } catch {
            Write-MonitorLog -Level 'WARN' -Message "Launcher failed for ${resolved}: $($_.Exception.Message)"
        }
    }
}

function Get-ListeningPortSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int[]]$Ports)

    $wanted = @($Ports | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if (@($wanted).Count -eq 0) { return @() }

    $items = @()
    $netCmd = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($null -ne $netCmd) {
        try {
            $items = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $wanted -contains $_.LocalPort } | Select-Object LocalAddress, LocalPort, State, OwningProcess)
        } catch {
            Write-MonitorLog -Level 'DEBUG' -Message "Get-NetTCPConnection unavailable: $($_.Exception.Message)"
            $items = @()
        }
    }

    if (@($items).Count -gt 0) {
        return $items
    }

    $fallback = @()
    try {
        $lines = @(netstat -ano -p tcp)
        foreach ($line in $lines) {
            $m = [regex]::Match([string]$line, '^\s*TCP\s+([^\s:]+):(\d+)\s+[^\s]+\s+LISTENING\s+(\d+)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }
            $localPort = [int]$m.Groups[2].Value
            if ($wanted -notcontains $localPort) { continue }
            $fallback += [PSCustomObject]@{
                LocalAddress = $m.Groups[1].Value
                LocalPort = $localPort
                State = 'LISTENING'
                OwningProcess = [int]$m.Groups[3].Value
            }
        }
    } catch {
        Write-MonitorLog -Level 'WARN' -Message "netstat listener fallback failed: $($_.Exception.Message)"
    }

    return $fallback
}

function Get-ProcessRecordById {
    [CmdletBinding()]
    param(
        [int]$ProcessId,
        [Parameter(Mandatory)] [hashtable]$Cache
    )

    if ($ProcessId -le 0) { return $null }
    $key = [string]$ProcessId
    if ($Cache.ContainsKey($key)) {
        return $Cache[$key]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    }

    $record = $null
    try {
        $record = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, Name, CommandLine
    } catch {
        $record = $null
    }

    $Cache[$key] = $record  # SIN-EXEMPT:P027 -- index access, context-verified safe
    return $record
}

function Get-ProcessLineage {
    [CmdletBinding()]
    param(
        [int]$ProcessId,
        [Parameter(Mandatory)] [hashtable]$Cache
    )

    $proc = Get-ProcessRecordById -ProcessId $ProcessId -Cache $Cache
    if ($null -eq $proc) {
        return [PSCustomObject]@{
            ProcessId = $ProcessId
            ProcessName = $null
            CommandLine = $null
            ParentProcessId = $null
            ParentName = $null
            ParentCommandLine = $null
            GrandParentProcessId = $null
            GrandParentName = $null
            GrandParentCommandLine = $null
        }
    }

    $parent = Get-ProcessRecordById -ProcessId ([int]$proc.ParentProcessId) -Cache $Cache
    $grand = $null
    if ($null -ne $parent) {
        $grand = Get-ProcessRecordById -ProcessId ([int]$parent.ParentProcessId) -Cache $Cache
    }

    return [PSCustomObject]@{
        ProcessId = [int]$proc.ProcessId
        ProcessName = [string]$proc.Name
        CommandLine = [string]$proc.CommandLine
        ParentProcessId = if ($null -ne $parent) { [int]$parent.ProcessId } else { $null }
        ParentName = if ($null -ne $parent) { [string]$parent.Name } else { $null }
        ParentCommandLine = if ($null -ne $parent) { [string]$parent.CommandLine } else { $null }
        GrandParentProcessId = if ($null -ne $grand) { [int]$grand.ProcessId } else { $null }
        GrandParentName = if ($null -ne $grand) { [string]$grand.Name } else { $null }
        GrandParentCommandLine = if ($null -ne $grand) { [string]$grand.CommandLine } else { $null }
    }
}

function Invoke-WebServicePortReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [switch]$PreviewOnly
    )

    $ports = @($script:ReportPorts)
    if (@($ports).Count -eq 0) {
        Write-MonitorLog -Level 'WARN' -Message 'No web service report ports configured.'
        return @()
    }

    $listeners = @((Get-ListeningPortSnapshot -Ports $ports))
    $cache = @{}
    $rows = @()

    foreach ($port in $ports) {
        $portListeners = @($listeners | Where-Object { [int]$_.LocalPort -eq [int]$port })
        if (@($portListeners).Count -eq 0) {
            $rows += [PSCustomObject]@{
                Port = [int]$port
                Listening = 'NO'
                Address = '-'
                PID = $null
                PPID = $null
                GPPID = $null
                Process = '-'
                Parent = '-'
                GrandParent = '-'
            }
            continue
        }

        foreach ($listener in $portListeners) {
            $pidValue = [int]$listener.OwningProcess
            $lineage = Get-ProcessLineage -ProcessId $pidValue -Cache $cache
            $rows += [PSCustomObject]@{
                Port = [int]$port
                Listening = 'YES'
                Address = [string]$listener.LocalAddress
                PID = $lineage.ProcessId
                PPID = $lineage.ParentProcessId
                GPPID = $lineage.GrandParentProcessId
                Process = if ([string]::IsNullOrWhiteSpace($lineage.ProcessName)) { '-' } else { $lineage.ProcessName }
                Parent = if ([string]::IsNullOrWhiteSpace($lineage.ParentName)) { '-' } else { $lineage.ParentName }
                GrandParent = if ([string]::IsNullOrWhiteSpace($lineage.GrandParentName)) { '-' } else { $lineage.GrandParentName }
                ProcessCommandLine = $lineage.CommandLine
                ParentCommandLine = $lineage.ParentCommandLine
                GrandParentCommandLine = $lineage.GrandParentCommandLine
            }
        }
    }

    $rows | Sort-Object -Property Port, PID | Format-Table -AutoSize | Out-String -Width 260 | Write-Host

    $reportRoot = Join-Path $Workspace 'reports'
    $reportDir = Join-Path $reportRoot 'engine-monitor'
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    $reportPath = Join-Path $reportDir ("webservices-lineage-$($script:RunStamp).json")
    $reportBody = [ordered]@{
        schema = 'EngineWebServiceLineage/1.0'
        stamp = (Get-Date).ToString('o')
        workspace = $Workspace
        ports = @($ports)
        rows = @($rows)
        previewOnly = [bool]$PreviewOnly
    }

    if ($PreviewOnly) {
        Write-MonitorLog -Level 'DEBUG' -Message "DryRun: web service lineage report skipped write ($reportPath)."
    } else {
        $reportBody | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-MonitorLog -Level 'INFO' -Message "Web service lineage report: $reportPath"
    }

    return $rows
}

function Invoke-AutoStartEditor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Config,
        [AllowNull()] [string[]]$NameSelection,
        [switch]$PreviewOnly
    )

    if (-not ($Config.PSObject.Properties.Name -contains 'targets')) {
        return [PSCustomObject]@{ Changed = $false; Config = $Config; ChangedTargets = @() }
    }

    $targetRows = @($Config.targets)
    if (@($targetRows).Count -eq 0) {
        return [PSCustomObject]@{ Changed = $false; Config = $Config; ChangedTargets = @() }
    }

    $indexMap = @{}
    for ($i = 0; $i -lt @($targetRows).Count; $i++) {
        $targetRow = $targetRows[$i]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $idx = $i + 1
        $autoVal = if ($targetRow.PSObject.Properties.Name -contains 'autoStart') { [bool]$targetRow.autoStart } else { $false }
        $enabledVal = if ($targetRow.PSObject.Properties.Name -contains 'enabled') { [bool]$targetRow.enabled } else { $true }
        Write-Host ("[{0}] autoStart={1,-5} enabled={2,-5} {3} ({4})" -f $idx, $autoVal, $enabledVal, $targetRow.name, $targetRow.path)
        $indexMap[[string]$idx] = $targetRow
    }

    $rawSelection = @($NameSelection)
    if (@($rawSelection).Count -eq 0) {
        $line = Read-Host 'Select target indexes or names to toggle autoStart (comma separated), Enter to cancel'
        if ([string]::IsNullOrWhiteSpace($line)) {
            return [PSCustomObject]@{ Changed = $false; Config = $Config; ChangedTargets = @() }
        }
        $rawSelection = @($line.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $picked = @{}
    foreach ($pick in $rawSelection) {
        if ($indexMap.ContainsKey($pick)) {
            $picked[[string]$indexMap[$pick].path] = $indexMap[$pick]  # SIN-EXEMPT:P027 -- index access, context-verified safe
            continue
        }

        foreach ($targetRow in $targetRows) {
            if ($targetRow.name.Equals($pick, [System.StringComparison]::OrdinalIgnoreCase) -or $targetRow.path.Equals($pick, [System.StringComparison]::OrdinalIgnoreCase)) {
                $picked[[string]$targetRow.path] = $targetRow
            }
        }
    }

    if (@($picked.Keys).Count -eq 0) {
        Write-MonitorLog -Level 'WARN' -Message 'No valid autostart targets selected for toggle.'
        return [PSCustomObject]@{ Changed = $false; Config = $Config; ChangedTargets = @() }
    }

    $changed = @()
    foreach ($key in @($picked.Keys)) {
        $targetRow = $picked[$key]  # SIN-EXEMPT:P027 -- index access, context-verified safe
        $current = if ($targetRow.PSObject.Properties.Name -contains 'autoStart') { [bool]$targetRow.autoStart } else { $false }
        $newValue = -not $current
        if ($targetRow.PSObject.Properties.Name -contains 'autoStart') {
            $targetRow.autoStart = $newValue
        } else {
            $targetRow | Add-Member -MemberType NoteProperty -Name autoStart -Value $newValue
        }
        $changed += [PSCustomObject]@{ Name = $targetRow.name; Path = $targetRow.path; AutoStart = $newValue }
        Write-MonitorLog -Level 'INFO' -Message "autoStart toggled -> $($targetRow.name): $newValue"
    }

    if (-not $PreviewOnly) {
        $savedPath = Save-MonitorConfig -Workspace $Workspace -Config $Config
        Write-MonitorLog -Level 'INFO' -Message "Monitor config updated: $savedPath"
    } else {
        Write-MonitorLog -Level 'DEBUG' -Message 'DryRun: monitor config not persisted.'
    }

    return [PSCustomObject]@{ Changed = (@($changed).Count -gt 0); Config = $Config; ChangedTargets = $changed }
}

function Wait-RefreshCountdown {
    [CmdletBinding()]
    param(
        [ValidateRange(5,300)] [int]$Seconds = 20,
        [Parameter(Mandatory)] [string]$Workspace,
        [switch]$EnableHotkeys,
        [switch]$PreviewOnly
    )

    for ($remaining = $Seconds; $remaining -ge 1; $remaining--) {
        Write-Host ("`rRefresh in {0,2}s | hotkeys: [A] Auto five, [B] Bigger 10, [Q] Quit watch    " -f $remaining) -NoNewline

        if ($EnableHotkeys) {
            try {
                if ([Console]::KeyAvailable) {
                    $keyInfo = [Console]::ReadKey($true)
                    $ch = ([string]$keyInfo.KeyChar).ToUpperInvariant()
                    Write-Host ''
                    if ($ch -eq 'A') {
                        Invoke-LauncherSet -SetName 'A' -Workspace $Workspace -PreviewOnly:$PreviewOnly
                        return 'A'
                    }
                    if ($ch -eq 'B') {
                        Invoke-LauncherSet -SetName 'B' -Workspace $Workspace -PreviewOnly:$PreviewOnly
                        return 'B'
                    }
                    if ($ch -eq 'Q') {
                        return 'Q'
                    }
                }
            } catch {
                Write-MonitorLog -Level 'DEBUG' -Message "Countdown key polling unavailable: $($_.Exception.Message)"
            }
        }

        Start-Sleep -Seconds 1
    }

    Write-Host ''
    return 'TIMEOUT'
}

function Invoke-WatchLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object[]]$Targets,
        [ValidateRange(5,300)] [int]$RefreshIntervalSec = 20,
        [switch]$PreviewOnly
    )

    Write-MonitorLog -Level 'INFO' -Message "Watch mode started. Refresh every $RefreshIntervalSec second(s)."
        $cycleCount = 0
    while ($true) {
            $cycleCount++
        $snap = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $Targets -ProcessSnapshot $snap

        if ($script:MonitorOptions.autoRefreshStatus) {
            Invoke-WebServicePortReport -Workspace $Workspace -PreviewOnly:$PreviewOnly | Out-Null
        }

        $signal = Wait-RefreshCountdown -Seconds $RefreshIntervalSec -Workspace $Workspace -EnableHotkeys:$script:MonitorOptions.enableHotkeys -PreviewOnly:$PreviewOnly
        if ($signal -eq 'Q') {
            Write-MonitorLog -Level 'INFO' -Message 'Watch mode ended by user keypress.'
            break
        }

        if ($PreviewOnly -and $cycleCount -ge 1) {
            Write-MonitorLog -Level 'INFO' -Message 'Watch mode DryRun completed after one cycle.'
            break
        }
    }
}

function Test-RelativePathAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [string[]]$Patterns
    )

    $items = @($Patterns)
    if (@($items).Count -eq 0) { return $false }

    foreach ($p in $items) {
        if ($RelativePath -like $p) { return $true }
    }

    return $false
}

function ConvertTo-TargetObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Raw,
        [string]$Source = 'static'
    )

    $path = [string]$Raw.path
    $name = if ([string]::IsNullOrWhiteSpace([string]$Raw.name)) {
        [System.IO.Path]::GetFileNameWithoutExtension($path)
    } else {
        [string]$Raw.name
    }

    $kind = if ([string]::IsNullOrWhiteSpace([string]$Raw.kind)) {
        if ($path -like '*.ps1') { 'PowerShellScript' } else { 'BatchFile' }
    } else {
        [string]$Raw.kind
    }

    $runModel = if ([string]::IsNullOrWhiteSpace([string]$Raw.runModel)) {
        if ($path -like '*Start-Engines.ps1') { 'oneshot' } else { 'background' }
    } else {
        [string]$Raw.runModel
    }

    $statusHints = @()
    if ($Raw.PSObject.Properties.Name -contains 'statusHints') {
        $statusHints = @($Raw.statusHints | ForEach-Object { [string]$_ })
    }
    if (@($statusHints).Count -eq 0) {
        $statusHints = @([System.IO.Path]::GetFileName($path))
    }

    $enabled = if ($Raw.PSObject.Properties.Name -contains 'enabled') { [bool]$Raw.enabled } else { $true }
    $autoStart = if ($Raw.PSObject.Properties.Name -contains 'autoStart') { [bool]$Raw.autoStart } else { $false }

    return [PSCustomObject]@{
        name = $name
        path = ($path -replace '\\', '/')
        kind = $kind
        runModel = $runModel
        enabled = $enabled
        autoStart = $autoStart
        host = if ([string]::IsNullOrWhiteSpace([string]$Raw.host)) { 'auto' } else { [string]$Raw.host }
        startArgs = @($Raw.startArgs)
        stopArgs = @($Raw.stopArgs)
        restartArgs = @($Raw.restartArgs)
        statusHints = $statusHints
        source = $Source
    }
}

function Get-DiscoveredTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns
    )

    $discovered = @()
    $files = @(Get-ChildItem -LiteralPath $Workspace -Recurse -File -ErrorAction SilentlyContinue)

    foreach ($file in $files) {
        $rel = ConvertTo-RelativePathSafe -Path $file.FullName -RootPath $Workspace
        if ($rel -ieq 'scripts/Invoke-EngineServiceMonitor.ps1') { continue }
        if (-not (Test-RelativePathAllowed -RelativePath $rel -Patterns $IncludePatterns)) { continue }
        if (Test-RelativePathAllowed -RelativePath $rel -Patterns $ExcludePatterns) { continue }

        $kind = if ($rel -like '*.ps1') { 'PowerShellScript' } else { 'BatchFile' }
        $runModel = if ($rel -like '*Start-Engines.ps1') { 'oneshot' } else { 'background' }
        if ($rel -like '*SmokeTest-*') { $runModel = 'oneshot' }

        $raw = [PSCustomObject]@{
            name = [System.IO.Path]::GetFileNameWithoutExtension($rel)
            path = $rel
            kind = $kind
            runModel = $runModel
            enabled = $true
            autoStart = $false
            host = 'auto'
            startArgs = @()
            stopArgs = @()
            restartArgs = @()
            statusHints = @([System.IO.Path]::GetFileName($rel))
        }

        $discovered += (ConvertTo-TargetObject -Raw $raw -Source 'discovered')
    }

    return @($discovered | Sort-Object -Property path -Unique)
}

function Get-MonitorTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Config,
        [switch]$AllowDisabled
    )

    $staticTargets = @()
    if ($Config.PSObject.Properties.Name -contains 'targets') {
        foreach ($raw in @($Config.targets)) {
            $target = ConvertTo-TargetObject -Raw $raw -Source 'static'
            $staticTargets += $target
        }
    }

    $include = if ($Config.PSObject.Properties.Name -contains 'includePatterns') { @($Config.includePatterns) } else { @() }
    $exclude = if ($Config.PSObject.Properties.Name -contains 'excludePatterns') { @($Config.excludePatterns) } else { @() }
    $discovered = Get-DiscoveredTargets -Workspace $Workspace -IncludePatterns $include -ExcludePatterns $exclude

    $lookup = @{}
    foreach ($d in $discovered) {
        $lookup[$d.path.ToLowerInvariant()] = $d
    }
    foreach ($s in $staticTargets) {
        $lookup[$s.path.ToLowerInvariant()] = $s
    }

    $targets = @($lookup.GetEnumerator() | ForEach-Object { $_.Value } | Sort-Object -Property name, path)

    if (-not $AllowDisabled) {
        $targets = @($targets | Where-Object { $_.enabled })
    }

    return $targets
}

function Get-TargetAbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Target
    )

    $candidate = Join-Path $Workspace $Target.path
    $full = [System.IO.Path]::GetFullPath($candidate)
    $root = [System.IO.Path]::GetFullPath($Workspace)

    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Target path escapes workspace: $($Target.path)"
    }

    return $full
}

function Get-ProcessSnapshot {
    [CmdletBinding()]
    param()

    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, CommandLine)
    } catch {
        Write-MonitorLog -Level 'WARN' -Message "Unable to query process snapshot: $($_.Exception.Message)"
        return @()
    }
}

function Get-TargetStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [AllowNull()] [object[]]$ProcessSnapshot
    )

    $snapshot = @($ProcessSnapshot)
    $hints = @($Target.statusHints)
    if (@($hints).Count -eq 0) {
        $hints = @([System.IO.Path]::GetFileName($Target.path))
    }

    $hitList = @()
    foreach ($proc in $snapshot) {
        if ($null -eq $proc.CommandLine) { continue }
        $cmd = [string]$proc.CommandLine
        foreach ($hint in $hints) {
            if ([string]::IsNullOrWhiteSpace($hint)) { continue }
            if ($cmd.IndexOf($hint, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hitList += $proc
                break
            }
        }
    }

    $ids = @($hitList | Select-Object -ExpandProperty ProcessId -Unique)

    return [PSCustomObject]@{
        Name = $Target.name
        Path = $Target.path
        Kind = $Target.kind
        RunModel = $Target.runModel
        Source = $Target.source
        Running = (@($ids).Count -gt 0)
        ProcessCount = @($ids).Count
        ProcessIds = @($ids)
    }
}

function Show-WatchedTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Targets,
        [AllowNull()] [object[]]$ProcessSnapshot
    )

    $rows = @()
    foreach ($t in $Targets) {
        $status = Get-TargetStatus -Target $t -ProcessSnapshot $ProcessSnapshot
        $rows += [PSCustomObject]@{
            Name = $t.name
            Running = if ($status.Running) { 'YES' } else { 'NO' }
            AutoStart = if ($t.autoStart) { 'YES' } else { 'NO' }
            RunModel = $t.runModel
            Kind = $t.kind
            Source = $t.source
            Path = $t.path
            PIDs = if (@($status.ProcessIds).Count -gt 0) { (@($status.ProcessIds) -join ',') } else { '-' }
        }
    }

    Write-MonitorLog -Level 'INFO' -Message ("Watched targets: " + @($rows).Count)
    $rows | Sort-Object -Property Name | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

function Invoke-TargetCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [ValidateSet('start','stop','restart')] [string]$Mode,
        [switch]$SkipWait,
        [switch]$PreviewOnly,
        [int]$TimeoutSec = 20
    )

    $path = Get-TargetAbsolutePath -Workspace $Workspace -Target $Target
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{
            Target = $Target.name
            Mode = $Mode
            Success = $false
            Message = "Target file missing: $path"
            ExitCode = 1
            Pid = $null
        }
    }

    $modeParameters = @{
        start = @($Target.startArgs)
        stop = @($Target.stopArgs)
        restart = @($Target.restartArgs)
    }
    $modeParametersToUse = @($modeParameters[$Mode])  # SIN-EXEMPT:P027 -- index access, context-verified safe

    if ($Mode -eq 'stop' -and @($modeParametersToUse).Count -eq 0) {
        return [PSCustomObject]@{
            Target = $Target.name
            Mode = $Mode
            Success = $true
            Message = 'No explicit stop command configured. Process-stop fallback will be used.'
            ExitCode = 0
            Pid = $null
        }
    }

    if ($Mode -eq 'restart' -and @($modeParametersToUse).Count -eq 0) {
        $stopResult = Invoke-TargetCommand -Workspace $Workspace -Target $Target -Mode 'stop' -SkipWait -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
        if (-not $stopResult.Success) {
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $false
                Message = "Restart stop step failed: $($stopResult.Message)"
                ExitCode = 1
                Pid = $null
            }
        }
        return Invoke-TargetCommand -Workspace $Workspace -Target $Target -Mode 'start' -SkipWait:$SkipWait -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
    }

    if ($Mode -eq 'start' -and $Target.runModel -eq 'background') {
        $tabResult = Start-TargetInTerminalTab -Workspace $Workspace -Target $Target -ModeParameters $modeParametersToUse -SkipWait:$SkipWait -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
        if ($tabResult.Handled) {
            if ($tabResult.Success -or $SkipWait -or $PreviewOnly) {
                return [PSCustomObject]@{
                    Target = $Target.name
                    Mode = $Mode
                    Success = $tabResult.Success
                    Message = $tabResult.Message
                    ExitCode = $tabResult.ExitCode
                    Pid = $tabResult.Pid
                }
            }

            Write-MonitorLog -Level 'WARN' -Message "Tab launch did not confirm running for $($Target.name); falling back to standard process launch."
        }
    }

    if ($PreviewOnly) {
        return [PSCustomObject]@{
            Target = $Target.name
            Mode = $Mode
            Success = $true
            Message = "DryRun: would invoke $($Target.path) $(@($modeParametersToUse) -join ' ')"
            ExitCode = 0
            Pid = $null
        }
    }

    if ($Target.kind -eq 'PowerShellScript') {
        $hostExe = Resolve-PowerShellHost -HostPreference $Target.host
        if ($null -eq $hostExe) {
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $false
                Message = 'No PowerShell host executable found.'
                ExitCode = 1
                Pid = $null
            }
        }

        $hostBaseParameters = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$path)
        $hostParameters = @($hostBaseParameters + @($modeParametersToUse))

        if ($Target.runModel -eq 'oneshot' -or $Mode -eq 'stop') {
            try {
                $nativeOutput = @(& $hostExe @hostParameters 2>&1)
                $exitCode = if ($LASTEXITCODE -eq $null) { 0 } else { [int]$LASTEXITCODE }
                $nativeText = if (@($nativeOutput).Count -gt 0) {
                    @($nativeOutput | ForEach-Object { [string]$_ }) -join ' | '
                } else {
                    ''
                }
                return [PSCustomObject]@{
                    Target = $Target.name
                    Mode = $Mode
                    Success = ($exitCode -eq 0)
                    Message = if ([string]::IsNullOrWhiteSpace($nativeText)) {
                        "Executed $hostExe $($Target.path)"
                    } else {
                        "Executed $hostExe $($Target.path) | Output: $nativeText"
                    }
                    ExitCode = $exitCode
                    Pid = $null
                }
            } catch {
                return [PSCustomObject]@{
                    Target = $Target.name
                    Mode = $Mode
                    Success = $false
                    Message = $_.Exception.Message
                    ExitCode = 1
                    Pid = $null
                }
            }
        }

        try {
            $proc = Start-Process -FilePath $hostExe -ArgumentList $hostParameters -PassThru -WindowStyle Minimized
            if ($SkipWait) {
                return [PSCustomObject]@{
                    Target = $Target.name
                    Mode = $Mode
                    Success = $true
                    Message = "Started in background with PID $($proc.Id)"
                    ExitCode = 0
                    Pid = $proc.Id
                }
            }

            $running = Wait-TargetRunning -Target $Target -TimeoutSec $TimeoutSec
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $running
                Message = if ($running) { "Running with PID $($proc.Id)" } else { "Started PID $($proc.Id) but status probe did not confirm running." }
                ExitCode = if ($running) { 0 } else { 1 }
                Pid = $proc.Id
            }
        } catch {
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $false
                Message = $_.Exception.Message
                ExitCode = 1
                Pid = $null
            }
        }
    }

    $batchParameters = @('/c', $path)
    if (@($modeParametersToUse).Count -gt 0) {
        $batchParameters += @($modeParametersToUse)
    }

    try {
        if ($Target.runModel -eq 'oneshot' -or $Mode -eq 'stop') {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $batchParameters -Wait -PassThru -WindowStyle Minimized
            $ok = ($p.ExitCode -eq 0)
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $ok
                Message = "Executed cmd.exe /c $($Target.path)"
                ExitCode = $p.ExitCode
                Pid = $null
            }
        }

        $proc2 = Start-Process -FilePath 'cmd.exe' -ArgumentList $batchParameters -PassThru -WindowStyle Minimized
        if ($SkipWait) {
            return [PSCustomObject]@{
                Target = $Target.name
                Mode = $Mode
                Success = $true
                Message = "Started in background with PID $($proc2.Id)"
                ExitCode = 0
                Pid = $proc2.Id
            }
        }

        $running2 = Wait-TargetRunning -Target $Target -TimeoutSec $TimeoutSec
        return [PSCustomObject]@{
            Target = $Target.name
            Mode = $Mode
            Success = $running2
            Message = if ($running2) { "Running with PID $($proc2.Id)" } else { "Started PID $($proc2.Id) but status probe did not confirm running." }
            ExitCode = if ($running2) { 0 } else { 1 }
            Pid = $proc2.Id
        }
    } catch {
        return [PSCustomObject]@{
            Target = $Target.name
            Mode = $Mode
            Success = $false
            Message = $_.Exception.Message
            ExitCode = 1
            Pid = $null
        }
    }
}

function Wait-TargetRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [ValidateRange(1,180)] [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $snapshot = Get-ProcessSnapshot
        $status = Get-TargetStatus -Target $Target -ProcessSnapshot $snapshot
        if ($status.Running) { return $true }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-TargetProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [switch]$PreviewOnly
    )

    $snapshot = Get-ProcessSnapshot
    $status = Get-TargetStatus -Target $Target -ProcessSnapshot $snapshot
    if (-not $status.Running) {
        return [PSCustomObject]@{ Success = $true; Message = 'No running process found.'; Count = 0 }
    }

    if ($PreviewOnly) {
        return [PSCustomObject]@{ Success = $true; Message = "DryRun: would stop $(@($status.ProcessIds).Count) process(es)."; Count = @($status.ProcessIds).Count }
    }

    $stopped = 0
    foreach ($procId in @($status.ProcessIds)) {
        if ($procId -eq $script:CurrentProcessId) { continue }
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $stopped++
        } catch {
            Write-MonitorLog -Level 'WARN' -Message "Unable to stop PID $procId for target $($Target.name): $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Success = $true
        Message = "Stopped $stopped process(es)."
        Count = $stopped
    }
}

function Invoke-TargetOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object[]]$Targets,
        [Parameter(Mandatory)] [ValidateSet('start','restart','stop')] [string]$Mode,
        [switch]$PreviewOnly,
        [int]$TimeoutSec = 20
    )

    $results = @()
    foreach ($target in $Targets) {
        Write-MonitorLog -Level 'ACTION' -Message ("$Mode -> $($target.name) [$($target.path)]")

        if ($Mode -eq 'stop') {
            $invokeStop = Invoke-TargetCommand -Workspace $Workspace -Target $target -Mode 'stop' -SkipWait -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
            $killStop = Stop-TargetProcesses -Target $target -PreviewOnly:$PreviewOnly
            $ok = ($invokeStop.Success -and $killStop.Success)
            $msg = "$($invokeStop.Message) | $($killStop.Message)"
            $results += [PSCustomObject]@{
                Target = $target.name
                Mode = $Mode
                Success = $ok
                Message = $msg
            }
            if ($ok) {
                Write-MonitorLog -Level 'PASS' -Message "$($target.name): $msg"
            } else {
                Write-MonitorLog -Level 'FAIL' -Message "$($target.name): $msg"
            }
            continue
        }

        if ($Mode -eq 'restart') {
            $stopOutcome = Invoke-TargetOperation -Workspace $Workspace -Targets @($target) -Mode 'stop' -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
            $stopFailed = @($stopOutcome | Where-Object { -not $_.Success })
            if (@($stopFailed).Count -gt 0) {
                $results += [PSCustomObject]@{
                    Target = $target.name
                    Mode = $Mode
                    Success = $false
                    Message = 'Restart failed during stop step.'
                }
                Write-MonitorLog -Level 'FAIL' -Message "$($target.name): restart stop step failed."
                continue
            }
            $startOutcome = Invoke-TargetCommand -Workspace $Workspace -Target $target -Mode 'start' -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
            $results += [PSCustomObject]@{
                Target = $target.name
                Mode = $Mode
                Success = $startOutcome.Success
                Message = $startOutcome.Message
            }
            if ($startOutcome.Success) {
                Write-MonitorLog -Level 'PASS' -Message "$($target.name): $($startOutcome.Message)"
            } else {
                Write-MonitorLog -Level 'FAIL' -Message "$($target.name): $($startOutcome.Message)"
            }
            continue
        }

        $startResult = Invoke-TargetCommand -Workspace $Workspace -Target $target -Mode 'start' -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
        $results += [PSCustomObject]@{
            Target = $target.name
            Mode = $Mode
            Success = $startResult.Success
            Message = $startResult.Message
        }

        if ($startResult.Success) {
            Write-MonitorLog -Level 'PASS' -Message "$($target.name): $($startResult.Message)"
        } else {
            Write-MonitorLog -Level 'FAIL' -Message "$($target.name): $($startResult.Message)"
        }
    }

    return $results
}

function Select-TargetsByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Targets,
        [AllowNull()] [string[]]$Names
    )

    $requested = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@($requested).Count -eq 0) {
        return $Targets
    }

    $out = @()
    foreach ($name in $requested) {
        $selectedTargets = @($Targets | Where-Object {
            $_.name.Equals($name, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.path.Equals($name, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if (@($selectedTargets).Count -eq 0) {
            Write-MonitorLog -Level 'WARN' -Message "Target not found for selection: $name"
            continue
        }
        $out += $selectedTargets
    }

    return @($out | Sort-Object -Property path -Unique)
}

function Invoke-PipelineStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [AllowNull()] [string[]]$StepParameters,
        [switch]$PreviewOnly
    )

    $full = Join-Path $Workspace $ScriptPath
    if (-not (Test-Path -LiteralPath $full)) {
        return [PSCustomObject]@{ Script = $ScriptPath; Success = $false; Message = 'Missing script'; ExitCode = 1 }
    }

    $hostExe = Resolve-PowerShellHost -HostPreference 'auto'
    if ($null -eq $hostExe) {
        return [PSCustomObject]@{ Script = $ScriptPath; Success = $false; Message = 'No PowerShell host found'; ExitCode = 1 }
    }

    $invokeParameters = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$full)
    $invokeParameters += @($StepParameters)

    $needsWorkspace = $false
    $leaf = [System.IO.Path]::GetFileName($ScriptPath)
    if ($leaf -in @('Invoke-PipelineIntegrityCheck.ps1','Invoke-PipelineProcess20.ps1','Invoke-SecurityIntegrityTests.ps1')) {
        $needsWorkspace = $true
    }

    $hasWorkspaceArg = $false
    foreach ($a in @($invokeParameters)) {
        if ([string]::IsNullOrWhiteSpace([string]$a)) { continue }
        if ([string]$a -ieq '-WorkspacePath') {
            $hasWorkspaceArg = $true
            break
        }
    }

    if ($needsWorkspace -and -not $hasWorkspaceArg) {
        $invokeParameters += @('-WorkspacePath',$Workspace)
    }

    if ($PreviewOnly) {
        return [PSCustomObject]@{ Script = $ScriptPath; Success = $true; Message = 'DryRun'; ExitCode = 0 }
    }

    try {
        $nativeOutput = @(& $hostExe @invokeParameters 2>&1)
        $code = if ($LASTEXITCODE -eq $null) { 0 } else { [int]$LASTEXITCODE }
        $nativeText = if (@($nativeOutput).Count -gt 0) {
            @($nativeOutput | ForEach-Object { [string]$_ }) -join ' | '
        } else {
            ''
        }
        return [PSCustomObject]@{
            Script = $ScriptPath
            Success = ($code -eq 0)
            Message = if ($code -eq 0) {
                if ([string]::IsNullOrWhiteSpace($nativeText)) { 'OK' } else { "OK | Output: $nativeText" }
            } else {
                if ([string]::IsNullOrWhiteSpace($nativeText)) { "ExitCode=$code" } else { "ExitCode=$code | Output: $nativeText" }
            }
            ExitCode = $code
        }
    } catch {
        return [PSCustomObject]@{
            Script = $ScriptPath
            Success = $false
            Message = $_.Exception.Message
            ExitCode = 1
        }
    }
}

function Invoke-PipelineHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object]$Config,
        [string]$Reason = 'manual',
        [AllowNull()] [object[]]$FailedTargets,
        [switch]$PreviewOnly
    )

    if (-not ($Config.PSObject.Properties.Name -contains 'pipeline')) {
        Write-MonitorLog -Level 'WARN' -Message 'No pipeline section in config. Skipping handoff.'
        return @()
    }

    $pipe = $Config.pipeline
    $steps = @()

    $integrityScript = if ($pipe.PSObject.Properties.Name -contains 'integrityScript') { [string]$pipe.integrityScript } else { '' }
    $processScript = if ($pipe.PSObject.Properties.Name -contains 'processScript') { [string]$pipe.processScript } else { '' }
    $smokeScript = if ($pipe.PSObject.Properties.Name -contains 'smokeScript') { [string]$pipe.smokeScript } else { '' }
    $securityScript = if ($pipe.PSObject.Properties.Name -contains 'securityScript') { [string]$pipe.securityScript } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($integrityScript)) {
        $steps += Invoke-PipelineStep -Workspace $Workspace -ScriptPath $integrityScript -StepParameters @($pipe.integrityArgs) -PreviewOnly:$PreviewOnly
    }
    if (-not [string]::IsNullOrWhiteSpace($processScript)) {
        $steps += Invoke-PipelineStep -Workspace $Workspace -ScriptPath $processScript -StepParameters @($pipe.processArgs) -PreviewOnly:$PreviewOnly
    }
    if (-not [string]::IsNullOrWhiteSpace($smokeScript)) {
        $steps += Invoke-PipelineStep -Workspace $Workspace -ScriptPath $smokeScript -StepParameters @($pipe.smokeArgs) -PreviewOnly:$PreviewOnly
    }
    if (-not [string]::IsNullOrWhiteSpace($securityScript)) {
        $steps += Invoke-PipelineStep -Workspace $Workspace -ScriptPath $securityScript -StepParameters @($pipe.securityArgs) -PreviewOnly:$PreviewOnly
    }

    foreach ($s in $steps) {
        if ($s.Success) {
            Write-MonitorLog -Level 'PASS' -Message "Pipeline step OK: $($s.Script)"
        } else {
            Write-MonitorLog -Level 'WARN' -Message "Pipeline step failed: $($s.Script) - $($s.Message)"
        }
    }

    $reportRoot = Join-Path $Workspace 'reports'
    $reportDir = Join-Path $reportRoot 'engine-monitor'
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    $report = [ordered]@{
        schema = 'EngineMonitorHandoff/1.0'
        stamp = (Get-Date).ToString('o')
        reason = $Reason
        failedTargetCount = @($FailedTargets).Count
        failedTargets = @($FailedTargets)
        pipelineSteps = @($steps)
        previewOnly = [bool]$PreviewOnly
    }

    $outFile = Join-Path $reportDir ("handoff-$($script:RunStamp).json")
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFile -Encoding UTF8
    Write-MonitorLog -Level 'INFO' -Message "Pipeline handoff report: $outFile"

    return $steps
}

function Invoke-AutoMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object[]]$Targets,
        [Parameter(Mandatory)] [object]$Config,
        [switch]$DisablePipeline,
        [switch]$PreviewOnly,
        [int]$TimeoutSec = 20
    )

    $snapshot = Get-ProcessSnapshot
    Show-WatchedTargets -Targets $Targets -ProcessSnapshot $snapshot

    $autoTargets = @($Targets | Where-Object { $_.autoStart })
    if (@($autoTargets).Count -eq 0) {
        Write-MonitorLog -Level 'WARN' -Message 'No autoStart targets are enabled. AUTO mode will only report status.'
        return @()
    }

    $initialMissing = @()
    foreach ($target in $autoTargets) {
        $status = Get-TargetStatus -Target $target -ProcessSnapshot $snapshot
        if ($target.runModel -eq 'background' -and -not $status.Running) {
            $initialMissing += $target
        }
        if ($target.runModel -eq 'oneshot') {
            $initialMissing += $target
        }
    }

    if (@($initialMissing).Count -eq 0) {
        Write-MonitorLog -Level 'PASS' -Message 'AUTO mode: all background auto targets already running.'
        return @()
    }

    Write-MonitorLog -Level 'ACTION' -Message ("AUTO mode: attempting startup for " + @($initialMissing).Count + ' target(s).')
    $startResults = Invoke-TargetOperation -Workspace $Workspace -Targets $initialMissing -Mode 'start' -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec

    $failed = @($startResults | Where-Object { -not $_.Success })
    if (@($failed).Count -gt 0) {
        Write-MonitorLog -Level 'WARN' -Message ("AUTO mode: " + @($failed).Count + ' target(s) failed start; attempting restart/stop recovery.')

        $failedTargets = @()
        foreach ($f in $failed) {
            $found = @($Targets | Where-Object { $_.name -eq $f.Target })
            if (@($found).Count -gt 0) { $failedTargets += $found[0] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
        }

        $restartResults = Invoke-TargetOperation -Workspace $Workspace -Targets $failedTargets -Mode 'restart' -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec
        $stillFailed = @($restartResults | Where-Object { -not $_.Success })

        if (@($stillFailed).Count -gt 0) {
            Write-MonitorLog -Level 'FAIL' -Message ("AUTO mode: unresolved after restart/stop recovery: " + @($stillFailed).Count)
            if (-not $DisablePipeline) {
                Write-MonitorLog -Level 'ACTION' -Message 'AUTO mode: handing unresolved targets to pipeline and praying for revival.'
                Invoke-PipelineHandoff -Workspace $Workspace -Config $Config -Reason 'auto-recovery-failed' -FailedTargets $stillFailed -PreviewOnly:$PreviewOnly | Out-Null
            }
            return $stillFailed
        }
    }

    Write-MonitorLog -Level 'PASS' -Message 'AUTO mode completed without unresolved failures.'
    return @()
}

function Invoke-TestRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [Parameter(Mandatory)] [object[]]$Targets,
        [Parameter(Mandatory)] [object]$Config,
        [switch]$PreviewOnly,
        [int]$TimeoutSec = 20
    )

    Write-MonitorLog -Level 'ACTION' -Message 'Test run /0 started.'
    $unresolved = Invoke-AutoMode -Workspace $Workspace -Targets $Targets -Config $Config -DisablePipeline:$true -PreviewOnly:$PreviewOnly -TimeoutSec $TimeoutSec

    Write-MonitorLog -Level 'ACTION' -Message 'Test run: generating synthetic monitor events.'
    $events = @(
        [PSCustomObject]@{ event='watchlist-loaded'; targetCount=@($Targets).Count; time=(Get-Date).ToString('o') },
        [PSCustomObject]@{ event='auto-mode-finished'; unresolved=@($unresolved).Count; time=(Get-Date).ToString('o') },
        [PSCustomObject]@{ event='security-query'; status='pending'; time=(Get-Date).ToString('o') }
    )

    $tempDir = Join-Path $Workspace 'temp'
    if (-not (Test-Path -LiteralPath $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $eventFile = Join-Path $tempDir ("engine-monitor-test-events-$($script:RunStamp).json")
    $events | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFile -Encoding UTF8
    Write-MonitorLog -Level 'INFO' -Message "Test events: $eventFile"

    $pipeSteps = Invoke-PipelineHandoff -Workspace $Workspace -Config $Config -Reason 'test-run' -FailedTargets $unresolved -PreviewOnly:$PreviewOnly
    $badPipe = @($pipeSteps | Where-Object { -not $_.Success })

    if (@($badPipe).Count -gt 0) {
        Write-MonitorLog -Level 'WARN' -Message ("Test run completed with " + @($badPipe).Count + ' pipeline/security step warning(s).')
    } else {
        Write-MonitorLog -Level 'PASS' -Message 'Test run completed cleanly.'
    }
}

function Read-InteractiveAction {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host 'Engine Monitor Menu' -ForegroundColor Cyan
    Write-Host '  /AUTO  - Auto recover and handoff failures'
    Write-Host '  /0     - Test run with logs + security query'
    Write-Host '  /1     - Start services'
    Write-Host '  /2     - Restart services'
    Write-Host '  /3     - Stop services'
    Write-Host '  /4     - Pipeline process/test/launch'
    Write-Host '  /5     - Status only'
    Write-Host '  /6     - Web service port lineage report'
    Write-Host '  /7     - Toggle autoStart values (save config)'
    Write-Host '  /8     - Watch mode (20s refresh + A/B hotkeys)'
    Write-Host '  /LIST  - Show watched inventory'
    Write-Host '  /HELP  - Show help'
    Write-Host ''

    $inputValue = Read-Host 'Choose action token (example: /AUTO)'
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return 'AUTO' }

    $resolved = Resolve-LegacySwitchAction -CurrentAction 'AUTO' -UnboundArguments @($inputValue)
    return $resolved
}

# --- Runtime preparation -----------------------------------------------------
$logsRoot = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path -LiteralPath $logsRoot)) {
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
}
$script:MonitorLogPath = Join-Path $logsRoot ("engine-monitor-$($script:RunStamp).log")
Write-MonitorLog -Level 'INFO' -Message "Engine monitor run started."
Write-MonitorLog -Level 'INFO' -Message "WorkspacePath=$WorkspacePath"
Write-MonitorLog -Level 'INFO' -Message "LogPath=$($script:MonitorLogPath)"

$Action = Resolve-LegacySwitchAction -CurrentAction $Action -UnboundArguments @($MyInvocation.UnboundArguments)
$Action = Resolve-LegacySwitchAction -CurrentAction $Action -UnboundArguments @($Action)
if ($Watch -and $Action -eq 'AUTO') {
    $Action = 'WATCH'
}
if ($Interactive) {
    $Action = Read-InteractiveAction
}

$Action = $Action.ToUpperInvariant()
$validActions = @('AUTO','0','1','2','3','4','5','6','7','8','LIST','STATUS','REPORT','AUTOSTART','WATCH','HELP')
if ($validActions -notcontains $Action) {
    Write-MonitorLog -Level 'ERROR' -Message "Unsupported action token: $Action"
    Show-ActionHelp
    exit 1
}

if ($Action -eq 'HELP') {
    Show-ActionHelp
    exit 0
}

$config = Get-MonitorConfig -Workspace $WorkspacePath -ConfigPath $TargetsPath
$script:MonitorOptions = Get-MonitorOptionSettings -Config $config
$script:LauncherSets = Get-LauncherSets -Config $config
$script:ReportPorts = Get-WebServiceReportPorts -Config $config

if (-not $PSBoundParameters.ContainsKey('RefreshSec')) {
    $RefreshSec = [int]$script:MonitorOptions.refreshSeconds
}

$script:TerminalTabSettings = Get-TerminalTabSettings -Config $config
$script:TerminalWindowId = ''
$script:UserTerminalTabsLaunched = $false
$script:TerminalUnavailableWarned = $false

if ($script:TerminalTabSettings.enabled) {
    $tabWindowId = Get-TerminalWindowId -Prefix $script:TerminalTabSettings.windowIdPrefix
    Write-MonitorLog -Level 'INFO' -Message "Terminal tab mode enabled. WindowId=$tabWindowId"
} else {
    Write-MonitorLog -Level 'INFO' -Message 'Terminal tab mode disabled by config.'
}

$targets = Get-MonitorTargets -Workspace $WorkspacePath -Config $config -AllowDisabled:$IncludeDisabled
$targets = Select-TargetsByName -Targets $targets -Names $TargetName

if (@($targets).Count -eq 0) {
    Write-MonitorLog -Level 'ERROR' -Message 'No targets available after filtering.'
    exit 1
}

switch ($Action) {
    'LIST' {
        $snap = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap
        break
    }
    'STATUS' {
        $snap2 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap2
        break
    }
    '5' {
        $snap3 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap3
        break
    }
    'AUTO' {
        $unresolvedAuto = Invoke-AutoMode -Workspace $WorkspacePath -Targets $targets -Config $config -DisablePipeline:$NoPipelineHandoff -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec
        $autoSnap = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $autoSnap
        if (@($unresolvedAuto).Count -gt 0) {
            exit 1
        }
        break
    }
    '0' {
        Invoke-TestRun -Workspace $WorkspacePath -Targets $targets -Config $config -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec
        break
    }
    '1' {
        $snap4 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap4
        $startResults = Invoke-TargetOperation -Workspace $WorkspacePath -Targets $targets -Mode 'start' -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec
        $snap4b = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap4b
        $fails = @($startResults | Where-Object { -not $_.Success })
        if (@($fails).Count -gt 0) { exit 1 }
        break
    }
    '2' {
        $snap5 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap5
        $restartResults = Invoke-TargetOperation -Workspace $WorkspacePath -Targets $targets -Mode 'restart' -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec
        $snap5b = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap5b
        $fails2 = @($restartResults | Where-Object { -not $_.Success })
        if (@($fails2).Count -gt 0) { exit 1 }
        break
    }
    '3' {
        $snap6 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap6
        $stopResults = Invoke-TargetOperation -Workspace $WorkspacePath -Targets $targets -Mode 'stop' -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec
        $snap6b = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap6b
        $fails3 = @($stopResults | Where-Object { -not $_.Success })
        if (@($fails3).Count -gt 0) { exit 1 }
        break
    }
    '4' {
        $snap7 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap7
        $steps = Invoke-PipelineHandoff -Workspace $WorkspacePath -Config $config -Reason 'manual-/4' -FailedTargets @() -PreviewOnly:$DryRun
        $stepFails = @($steps | Where-Object { -not $_.Success })
        if (@($stepFails).Count -gt 0) { exit 1 }
        break
    }
    '6' {
        Invoke-WebServicePortReport -Workspace $WorkspacePath -PreviewOnly:$DryRun | Out-Null
        break
    }
    'REPORT' {
        Invoke-WebServicePortReport -Workspace $WorkspacePath -PreviewOnly:$DryRun | Out-Null
        break
    }
    '7' {
        if (-not $script:MonitorOptions.enableAutoStartEditor) {
            Write-MonitorLog -Level 'WARN' -Message 'AutoStart editor is disabled by monitorOptions.'
            break
        }
        $editResult = Invoke-AutoStartEditor -Workspace $WorkspacePath -Config $config -NameSelection $TargetName -PreviewOnly:$DryRun
        if ($editResult.Changed) {
            $config = $editResult.Config
            $targets = Get-MonitorTargets -Workspace $WorkspacePath -Config $config -AllowDisabled:$IncludeDisabled
            $targets = Select-TargetsByName -Targets $targets -Names $TargetName
            Invoke-AutoMode -Workspace $WorkspacePath -Targets $targets -Config $config -DisablePipeline:$NoPipelineHandoff -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec | Out-Null
        }
        $snap8 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap8
        break
    }
    'AUTOSTART' {
        if (-not $script:MonitorOptions.enableAutoStartEditor) {
            Write-MonitorLog -Level 'WARN' -Message 'AutoStart editor is disabled by monitorOptions.'
            break
        }
        $editResultAlias = Invoke-AutoStartEditor -Workspace $WorkspacePath -Config $config -NameSelection $TargetName -PreviewOnly:$DryRun
        if ($editResultAlias.Changed) {
            $config = $editResultAlias.Config
            $targets = Get-MonitorTargets -Workspace $WorkspacePath -Config $config -AllowDisabled:$IncludeDisabled
            $targets = Select-TargetsByName -Targets $targets -Names $TargetName
            Invoke-AutoMode -Workspace $WorkspacePath -Targets $targets -Config $config -DisablePipeline:$NoPipelineHandoff -PreviewOnly:$DryRun -TimeoutSec $StartTimeoutSec | Out-Null
        }
        $snap9 = Get-ProcessSnapshot
        Show-WatchedTargets -Targets $targets -ProcessSnapshot $snap9
        break
    }
    '8' {
        Invoke-WatchLoop -Workspace $WorkspacePath -Targets $targets -RefreshIntervalSec $RefreshSec -PreviewOnly:$DryRun
        break
    }
    'WATCH' {
        Invoke-WatchLoop -Workspace $WorkspacePath -Targets $targets -RefreshIntervalSec $RefreshSec -PreviewOnly:$DryRun
        break
    }
    default {
        Write-MonitorLog -Level 'ERROR' -Message "Unsupported action: $Action"
        Show-ActionHelp
        exit 1
    }
}

Write-MonitorLog -Level 'INFO' -Message 'Engine monitor run completed.'
exit 0
