# VersionTag: 2605.B2.V31.8
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-07
# SupportsPS7.6TestedDate: 2026-05-07
# FileRole: Launcher
# Local web engine compatibility wrapper with tray status host.
#Requires -Version 5.1
<#
.SYNOPSIS
    Compatibility wrapper for Local Web Engine service behavior.

.DESCRIPTION
    Uses scripts/Start-LocalWebEngine.ps1 as the canonical engine script.
    Start action launches the canonical engine hidden/minimized and can host
    a task tray COG status icon with flyout menus for static and localhost page links.
#>
[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Restart','Status','Help','LaunchWebpage','RunTray')]
    [string]$Action = 'Start',
    [int]$Port = 8042,
    [string]$WorkspacePath = '',
    [switch]$NoLaunchBrowser,
    [switch]$NoTray,
    [switch]$SeparateTerminal,
    [ValidateSet('Debug','Info','Warning','Error','Critical')]
    [string]$EventLevel = 'Info',
    [string]$LogToFile = '',
    [string]$ShowRainbow = 'true',
    [int]$PollInterval = 1,
    [int]$MaxWait = 15,
    [switch]$Force,
    [ValidateRange(5,300)]
    [int]$TrayPollSec = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$unboundArgs = @($MyInvocation.UnboundArguments)
if (@($unboundArgs).Count -gt 0 -and $unboundArgs[0] -is [string] -and $unboundArgs[0] -notmatch '^-') {
    $Action = [string]$unboundArgs[0]
}

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $scriptDir -Parent
}

$engineScript = Join-Path $scriptDir 'Start-LocalWebEngine.ps1'
if (-not (Test-Path -LiteralPath $engineScript)) {
    Write-Host "Engine script not found: $engineScript" -ForegroundColor Red
    exit 1
}

function Write-ServiceLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION','PASS','DEBUG')] [string]$Level = 'INFO'
    )

    $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'PASS' { 'Green' }
        'ACTION' { 'Cyan' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Resolve-PowerShellHost {
    [CmdletBinding()]
    param()

    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
    return $null
}

function Get-MonitorConfigPath {
    [CmdletBinding()]
    param()
    return Join-Path (Join-Path $WorkspacePath 'config') 'engine-monitor.targets.json'
}

function Get-MonitorConfigObject {
    [CmdletBinding()]
    param()

    $cfgPath = Get-MonitorConfigPath
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-ServiceLog -Level 'WARN' -Message "Unable to parse monitor config: $($_.Exception.Message)"
        return $null
    }
}

function Get-LauncherSetsFromConfig {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    $defaults = [ordered]@{
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

    if ($null -eq $Config -or -not ($Config.PSObject.Properties.Name -contains 'launcherSets')) {
        return $defaults
    }

    $sets = [ordered]@{ A = @($defaults.A); B = @($defaults.B) }
    foreach ($name in @('A','B')) {
        if ($Config.launcherSets.PSObject.Properties.Name -contains $name) {
            $vals = @($Config.launcherSets.$name | ForEach-Object { [string]$_ })
            if (@($vals).Count -gt 0) {
                $sets[$name] = $vals
            }
        }
    }

    return $sets
}

function Resolve-LauncherEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Entry)

    $ws = ([System.IO.Path]::GetFullPath($WorkspacePath) -replace '\\','/')
    return $Entry.Replace('{workspace}', $ws)
}

function Invoke-LauncherSetFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SetName,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$SetTable
    )

    if (-not $SetTable.Contains($SetName)) {
        Write-ServiceLog -Level 'WARN' -Message "Launcher set not found: $SetName"
        return
    }

    foreach ($entry in @($SetTable[$SetName])) {
        $value = Resolve-LauncherEntry -Entry ([string]$entry)
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        if ($value.StartsWith('file:///', [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $uri = [System.Uri]$value
                if (-not (Test-Path -LiteralPath $uri.LocalPath)) {
                    Write-ServiceLog -Level 'WARN' -Message "Launcher target not found: $($uri.LocalPath)"
                    continue
                }
            } catch {
                Write-ServiceLog -Level 'WARN' -Message "Invalid launcher URI: $value"
                continue
            }
        }

        try {
            Start-Process $value | Out-Null
        } catch {
            Write-ServiceLog -Level 'WARN' -Message ("Failed to launch {0}: {1}" -f $value, $_.Exception.Message)
        }
    }
}

function Invoke-EngineAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Start','Stop','Restart','Status','LaunchWebpage')]
        [string]$EngineAction,
        [switch]$Background
    )

    $hostExe = Resolve-PowerShellHost
    if ($null -eq $hostExe) {
        throw 'No PowerShell host executable found.'
    }

    $delegateArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$engineScript,'-Action',$EngineAction,'-Port',$Port,'-WorkspacePath',$WorkspacePath)
    if ($NoLaunchBrowser) {
        $delegateArgs += @('-NoLaunchBrowser')
    }
    if ($Force) {
        $delegateArgs += @('-Force')
    }

    if ($Background) {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $delegateArgs -PassThru -WindowStyle Hidden
        return [PSCustomObject]@{ Success = $true; ExitCode = 0; ProcessId = $proc.Id }
    }

    $capturedOutput = @(& $hostExe @delegateArgs 2>&1)
    $code = if ($LASTEXITCODE -eq $null) { 0 } else { [int]$LASTEXITCODE }
    if ($code -ne 0 -and @($capturedOutput).Count -gt 0) {
        Write-ServiceLog -Level 'WARN' -Message ("Engine action {0} exited {1}: {2}" -f $EngineAction, $code, ($capturedOutput -join ' | '))
    }
    return [PSCustomObject]@{ Success = ($code -eq 0); ExitCode = $code; ProcessId = $null }
}

function Get-EngineHttpStatus {
    [CmdletBinding()]
    param()

    $uri = "http://127.0.0.1:$Port/api/engine/status"
    try {
        $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        $obj = $null
        try {
            $obj = $resp.Content | ConvertFrom-Json
        } catch {
            $obj = $null
        }
        return [PSCustomObject]@{ Online = $true; StatusCode = [int]$resp.StatusCode; Body = $obj }
    } catch {
        return [PSCustomObject]@{ Online = $false; StatusCode = 0; Body = $null }
    }
}

function Get-AutoTargets {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    if ($null -eq $Config -or -not ($Config.PSObject.Properties.Name -contains 'targets')) {
        return @()
    }

    return @($Config.targets | Where-Object {
        $enabledFlag = if ($_.PSObject.Properties.Name -contains 'enabled') { [bool]$_.enabled } else { $true }
        $autoFlag = if ($_.PSObject.Properties.Name -contains 'autoStart') { [bool]$_.autoStart } else { $false }
        $enabledFlag -and $autoFlag
    })
}

function Get-TargetIsRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Target,
        [Parameter(Mandatory)] [object[]]$ProcessSnapshot
    )

    $hints = @()
    if ($Target.PSObject.Properties.Name -contains 'statusHints') {
        $hints = @($Target.statusHints | ForEach-Object { [string]$_ })
    }
    if (@($hints).Count -eq 0) {
        $hints = @([System.IO.Path]::GetFileName([string]$Target.path))
    }

    foreach ($proc in $ProcessSnapshot) {
        if ($null -eq $proc.CommandLine) { continue }
        $cmd = [string]$proc.CommandLine
        foreach ($hint in $hints) {
            if ([string]::IsNullOrWhiteSpace($hint)) { continue }
            if ($cmd.IndexOf($hint, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

function Get-ServiceHealth {
    [CmdletBinding()]
    param([AllowNull()] [object]$Config)

    $autoTargets = Get-AutoTargets -Config $Config
    $snapshot = @()
    try {
        $snapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, CommandLine)
    } catch {
        return [PSCustomObject]@{ State = 'error'; Running = 0; Warning = 0; Error = 1; Total = @($autoTargets).Count; Message = "Process snapshot failed: $($_.Exception.Message)" }
    }

    if (@($autoTargets).Count -eq 0) {
        return [PSCustomObject]@{ State = 'disabled'; Running = 0; Warning = 0; Error = 0; Total = 0; Message = 'No enabled autoStart targets.' }
    }

    $running = 0
    foreach ($target in $autoTargets) {
        if (Get-TargetIsRunning -Target $target -ProcessSnapshot $snapshot) {
            $running++
        }
    }

    $warnings = @($autoTargets).Count - $running
    $errors = 0
    $state = 'running'

    if ($running -eq 0) {
        $state = 'error'
        $errors = 1
    } elseif ($warnings -gt 0) {
        $state = 'warning'
    }

    $engineStatus = Get-EngineHttpStatus
    if (-not $engineStatus.Online) {
        if ($state -eq 'running') {
            $state = 'warning'
            $warnings++
        }
    }

    return [PSCustomObject]@{
        State = $state
        Running = $running
        Warning = $warnings
        Error = $errors
        Total = @($autoTargets).Count
        Message = "Auto targets running: $running/$(@($autoTargets).Count)"
    }
}

function New-CogIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('running','warning','error','disabled','idle')]
        [string]$State
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.Clear([System.Drawing.Color]::Transparent)

    $baseColor = switch ($State) {
        'running' { [System.Drawing.Color]::LimeGreen }
        'warning' { [System.Drawing.Color]::Gold }
        'error' { [System.Drawing.Color]::Tomato }
        'disabled' { [System.Drawing.Color]::Black }
        default { [System.Drawing.Color]::Gray }
    }

    $outerBrush = New-Object System.Drawing.SolidBrush($baseColor)
    $gfx.FillEllipse($outerBrush, 4, 4, 24, 24)
    $outerBrush.Dispose()

    $hubBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 245, 245, 245))
    $gfx.FillEllipse($hubBrush, 11, 11, 10, 10)
    $hubBrush.Dispose()

    $spokePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 45, 45, 45), 2)
    $spokes = @(
        @{x1=16;y1=1;x2=16;y2=7},
        @{x1=16;y1=25;x2=16;y2=31},
        @{x1=1;y1=16;x2=7;y2=16},
        @{x1=25;y1=16;x2=31;y2=16},
        @{x1=5;y1=5;x2=9;y2=9},
        @{x1=23;y1=23;x2=27;y2=27},
        @{x1=23;y1=9;x2=27;y2=5},
        @{x1=5;y1=27;x2=9;y2=23}
    )
    foreach ($s in $spokes) {
        $gfx.DrawLine($spokePen, $s.x1, $s.y1, $s.x2, $s.y2)
    }
    $spokePen.Dispose()

    if ($State -eq 'disabled') {
        $xPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
        $gfx.DrawLine($xPen, 6, 6, 26, 26)
        $gfx.DrawLine($xPen, 26, 6, 6, 26)
        $xPen.Dispose()
    }

    $gfx.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return [PSCustomObject]@{ Icon = $icon; Bitmap = $bmp }
}

function Get-PageEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FolderRelative,
        [switch]$IncludeMarkdown
    )

    $folderPath = Join-Path $WorkspacePath $FolderRelative
    if (-not (Test-Path -LiteralPath $folderPath)) {
        return @()
    }

    $extensions = @('*.xhtml','*.html')
    if ($IncludeMarkdown) {
        $extensions += @('*.md')
    }

    $items = @()
    foreach ($ext in $extensions) {
        $files = @(Get-ChildItem -LiteralPath $folderPath -File -Filter $ext -Recurse -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($WorkspacePath.Length).TrimStart('\') -replace '\\','/'
            $items += [PSCustomObject]@{ Name = $file.Name; RelativePath = $relative; FullPath = $file.FullName }
        }
    }

    return @($items | Sort-Object -Property RelativePath -Unique)
}

function Start-ServiceTray {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $config = Get-MonitorConfigObject
    $launcherSets = Get-LauncherSetsFromConfig -Config $config
    $folderDefs = @(
        [PSCustomObject]@{ Label = 'XHTML tools'; Relative = 'scripts/XHTML-Checker' },
        [PSCustomObject]@{ Label = '~README.md'; Relative = '~README.md' }
    )

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Visible = $true
    $notify.Text = 'Local Web Engine Service Wrapper'

    $context = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Status: loading...')
    $statusItem.Enabled = $false
    [void]$context.Items.Add($statusItem)
    [void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $staticRoot = New-Object System.Windows.Forms.ToolStripMenuItem('Open Static Pages')
    $serviceRoot = New-Object System.Windows.Forms.ToolStripMenuItem('Open Service Pages')

    foreach ($folder in $folderDefs) {
        $staticFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem($folder.Label)
        $serviceFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem($folder.Label)

        $entries = Get-PageEntries -FolderRelative $folder.Relative -IncludeMarkdown
        if (@($entries).Count -eq 0) {
            $emptyStatic = New-Object System.Windows.Forms.ToolStripMenuItem('(no pages)')
            $emptyStatic.Enabled = $false
            [void]$staticFolderItem.DropDownItems.Add($emptyStatic)

            $emptyService = New-Object System.Windows.Forms.ToolStripMenuItem('(no pages)')
            $emptyService.Enabled = $false
            [void]$serviceFolderItem.DropDownItems.Add($emptyService)
        } else {
            foreach ($entry in $entries) {
                $staticItem = New-Object System.Windows.Forms.ToolStripMenuItem($entry.Name)
                $serviceItem = New-Object System.Windows.Forms.ToolStripMenuItem($entry.Name)

                $staticItem.Tag = $entry.FullPath
                $serviceItem.Tag = $entry.RelativePath

                $staticItem.Add_Click({
                    param($sender)
                    $pathValue = [string]$sender.Tag
                    try {
                        Start-Process $pathValue | Out-Null
                    } catch {
                        Write-ServiceLog -Level 'WARN' -Message ("Failed to open static page {0}: {1}" -f $pathValue, $_.Exception.Message)
                    }
                })

                $serviceItem.Add_Click({
                    param($sender)
                    $relativeValue = [string]$sender.Tag
                    $url = "http://127.0.0.1:$Port/$relativeValue"
                    try {
                        Start-Process $url | Out-Null
                    } catch {
                        Write-ServiceLog -Level 'WARN' -Message ("Failed to open service page {0}: {1}" -f $url, $_.Exception.Message)
                    }
                })

                [void]$staticFolderItem.DropDownItems.Add($staticItem)
                [void]$serviceFolderItem.DropDownItems.Add($serviceItem)
            }
        }

        [void]$staticRoot.DropDownItems.Add($staticFolderItem)
        [void]$serviceRoot.DropDownItems.Add($serviceFolderItem)
    }

    [void]$context.Items.Add($staticRoot)
    [void]$context.Items.Add($serviceRoot)

    $launchA = New-Object System.Windows.Forms.ToolStripMenuItem('Launch Auto Five (A)')
    $launchA.Add_Click({ Invoke-LauncherSetFromConfig -SetName 'A' -SetTable $launcherSets })
    [void]$context.Items.Add($launchA)

    $launchB = New-Object System.Windows.Forms.ToolStripMenuItem('Launch Bigger 10 (B)')
    $launchB.Add_Click({ Invoke-LauncherSetFromConfig -SetName 'B' -SetTable $launcherSets })
    [void]$context.Items.Add($launchB)

    [void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh status now')
    [void]$context.Items.Add($refreshItem)

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem('Start engine')
    $startItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Start' -Background | Out-Null
        } catch {
            Write-ServiceLog -Level 'WARN' -Message "Tray start failed: $($_.Exception.Message)"
        }
    })
    [void]$context.Items.Add($startItem)

    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem('Restart engine')
    $restartItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Restart' | Out-Null
        } catch {
            Write-ServiceLog -Level 'WARN' -Message "Tray restart failed: $($_.Exception.Message)"
        }
    })
    [void]$context.Items.Add($restartItem)

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem('Stop engine')
    $stopItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Stop' | Out-Null
        } catch {
            Write-ServiceLog -Level 'WARN' -Message "Tray stop failed: $($_.Exception.Message)"
        }
    })
    [void]$context.Items.Add($stopItem)

    [void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit tray')
    [void]$context.Items.Add($exitItem)

    $notify.ContextMenuStrip = $context

    $script:CurrentTrayIconRef = $null

    $updateState = {
        $cfg = Get-MonitorConfigObject
        $health = Get-ServiceHealth -Config $cfg

        $iconState = switch ($health.State) {
            'running' { 'running' }
            'warning' { 'warning' }
            'error' { 'error' }
            'disabled' { 'disabled' }
            default { 'idle' }
        }

        $newIconRef = New-CogIcon -State $iconState
        if ($null -ne $script:CurrentTrayIconRef) {
            try { $script:CurrentTrayIconRef.Icon.Dispose() } catch { <# Intentional: non-fatal #> }
            try { $script:CurrentTrayIconRef.Bitmap.Dispose() } catch { <# Intentional: non-fatal #> }
        }
        $script:CurrentTrayIconRef = $newIconRef
        $notify.Icon = $newIconRef.Icon

        $statusItem.Text = "Status: $($health.State) | Running=$($health.Running)/$($health.Total) | Warn=$($health.Warning) | Err=$($health.Error)"
        $notify.Text = "LWE Service | $($health.State) | $($health.Running)/$($health.Total)"
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]($TrayPollSec * 1000)
    $timer.Add_Tick($updateState)

    $refreshItem.Add_Click($updateState)

    $exitItem.Add_Click({
        $timer.Stop()
        [System.Windows.Forms.Application]::ExitThread()
    })

    try {
        & $updateState
        $timer.Start()
        [System.Windows.Forms.Application]::Run()
    } finally {
        $timer.Stop()
        try { $timer.Dispose() } catch { <# Intentional: non-fatal #> }
        $notify.Visible = $false
        try { $notify.Dispose() } catch { <# Intentional: non-fatal #> }
        if ($null -ne $script:CurrentTrayIconRef) {
            try { $script:CurrentTrayIconRef.Icon.Dispose() } catch { <# Intentional: non-fatal #> }
            try { $script:CurrentTrayIconRef.Bitmap.Dispose() } catch { <# Intentional: non-fatal #> }
            $script:CurrentTrayIconRef = $null
        }
    }
}

$engineStatus = Get-EngineHttpStatus

switch ($Action) {
    'Help' {
        Write-Host ''
        Write-Host 'Start-LocalWebEngineService.ps1' -ForegroundColor Cyan
        Write-Host '  -Action Start|Stop|Restart|Status|LaunchWebpage|RunTray|Help'
        Write-Host '  -Port <int>            (default 8042)'
        Write-Host '  -WorkspacePath <path>  (default workspace root)'
        Write-Host '  -NoLaunchBrowser       suppress browser launch'
        Write-Host '  -NoTray                start without tray host'
        Write-Host '  -TrayPollSec <seconds> tray status refresh interval'
        Write-Host ''
        exit 0
    }
    'Status' {
        if ($engineStatus.Online) {
            $body = if ($null -ne $engineStatus.Body) { $engineStatus.Body | ConvertTo-Json -Depth 6 } else { '{}' }
            Write-Host $body
            exit 0
        }
        Write-ServiceLog -Level 'WARN' -Message "Engine appears offline on port $Port."
        exit 1
    }
    'LaunchWebpage' {
        Start-Process "http://127.0.0.1:$Port/" | Out-Null
        exit 0
    }
    'Stop' {
        $resultStop = Invoke-EngineAction -EngineAction 'Stop'
        if ($resultStop.Success) { exit 0 }
        exit 1
    }
    'Restart' {
        Invoke-EngineAction -EngineAction 'Stop' | Out-Null
        $restartLaunch = Invoke-EngineAction -EngineAction 'Start' -Background
        if ($restartLaunch.Success) {
            Write-ServiceLog -Level 'PASS' -Message "Engine restarted. PID=$($restartLaunch.ProcessId)"
            if (-not $NoTray) {
                Start-ServiceTray
            }
            exit 0
        }
        exit 1
    }
    'RunTray' {
        Start-ServiceTray
        exit 0
    }
    default {
        if (-not $engineStatus.Online -or $Force) {
            $startLaunch = Invoke-EngineAction -EngineAction 'Start' -Background
            if ($startLaunch.Success) {
                Write-ServiceLog -Level 'PASS' -Message "Canonical LocalWebEngine started hidden. PID=$($startLaunch.ProcessId)"
            }
        } else {
            Write-ServiceLog -Level 'INFO' -Message "Engine already running on port $Port. Wrapper will attach tray only."
        }

        if (-not $NoTray) {
            Start-ServiceTray
        }

        exit 0
    }
}

