# VersionTag: 2605.B5.V46.0
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

function Resolve-WorkspaceRootPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PathValue)

    $candidate = [System.IO.Path]::GetFullPath($PathValue)
    $hasScripts = Test-Path -LiteralPath (Join-Path $candidate 'scripts') -PathType Container
    $hasModules = Test-Path -LiteralPath (Join-Path $candidate 'modules') -PathType Container
    if ($hasScripts -and $hasModules) {
        return $candidate
    }

    if ((Split-Path -Leaf $candidate).ToLowerInvariant() -eq 'scripts') {
        $parent = Split-Path -Parent $candidate
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $parentHasScripts = Test-Path -LiteralPath (Join-Path $parent 'scripts') -PathType Container
            $parentHasModules = Test-Path -LiteralPath (Join-Path $parent 'modules') -PathType Container
            if ($parentHasScripts -and $parentHasModules) {
                return [System.IO.Path]::GetFullPath($parent)
            }
        }
    }

    return $candidate
}

$originalWorkspacePath = $WorkspacePath
$WorkspacePath = Resolve-WorkspaceRootPath -PathValue $WorkspacePath
if ($WorkspacePath -ne $originalWorkspacePath) {
    Write-Host ("[workspace-normalize] '{0}' -> '{1}'" -f $originalWorkspacePath, $WorkspacePath) -ForegroundColor DarkGray
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

function Get-ResolutionHint {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$ErrorText)

    $text = if ($null -eq $ErrorText) { '' } else { [string]$ErrorText }
    if ($text -match '(?i)401|unauthorized|invalid cluster token') {
        return 'Auth token mismatch. Relaunch Service Cluster Dashboard, then reconnect using the token from scripts/service-cluster-dashboard/cluster.token.'
    }
    if ($text -match '(?i)No PowerShell host executable found') {
        return 'PowerShell host not found. Ensure pwsh.exe or powershell.exe is available on PATH.'
    }
    if ($text -match '(?i)not found|cannot find path|target not found') {
        return 'Target path missing. Verify workspace root and that the script/file exists at the configured location.'
    }
    if ($text -match '(?i)access is denied|permission') {
        return 'Permission issue. Re-run elevated if required and verify antivirus/app-control is not blocking the script.'
    }
    if ($text -match '(?i)timed out|timeout') {
        return 'Operation timed out. Check whether the engine/service is already starting and review logs/engine-service.log.'
    }
    return 'Review logs/engine-service.log and logs/engine-bootstrap.log, then retry with -Action Status for quick diagnostics.'
}

function Write-ServiceWarningWithHint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Context,
        [Parameter(Mandatory)] [string]$ErrorText
    )

    Write-ServiceLog -Level 'WARN' -Message ("{0}: {1}" -f $Context, $ErrorText)
    $hint = Get-ResolutionHint -ErrorText $ErrorText
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        Write-ServiceLog -Level 'INFO' -Message ("Hint: {0}" -f $hint)
    }
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

function ConvertTo-StringArray {
    [CmdletBinding()]
    param([AllowNull()] [object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @([string]$Value)
    }
    return @($Value | ForEach-Object { [string]$_ })
}

function Resolve-WorkspaceChildPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }

    $candidate = $PathValue -replace '/', '\\'
    $isRooted = [System.IO.Path]::IsPathRooted($candidate)
    $combined = if ($isRooted) { $candidate } else { Join-Path $WorkspacePath $candidate }

    $resolved = $null
    try { $resolved = [System.IO.Path]::GetFullPath($combined) } catch { return $null }

    if (-not (Test-Path -LiteralPath $resolved)) {
        # Fallback: if WorkspacePath already points at scripts/, avoid scripts/scripts/* doubling.
        if (-not $isRooted -and $candidate.StartsWith('scripts\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $trimmed = $candidate.Substring('scripts\'.Length)
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $fallbackCombined = Join-Path $WorkspacePath $trimmed
                try {
                    $fallbackResolved = [System.IO.Path]::GetFullPath($fallbackCombined)
                    if (Test-Path -LiteralPath $fallbackResolved) {
                        $resolved = $fallbackResolved
                    }
                } catch {
                    <# Intentional: non-fatal fallback path parse #>
                }
            }
        }
    }

    $wsRoot = [System.IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\\')
    $resolvedNorm = $resolved.TrimEnd('\\')
    $wsPrefix = $wsRoot + '\\'

    if ($resolvedNorm -ne $wsRoot -and -not $resolvedNorm.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $resolved
}

function Get-TrayServiceDefinitions {
    [CmdletBinding()]
    param()

    return @(
        [PSCustomObject]@{
            Name = 'ServiceClusterDashboard'
            Path = 'scripts/service-cluster-dashboard/Launch-ServiceDashboard.bat'
            StartArgs = @()
            StatusHints = @('Launch-ServiceDashboard.bat','uvicorn server:app','--port 8099')
        },
        [PSCustomObject]@{
            Name = 'EngineBootstrap'
            Path = 'scripts/Start-Engines.ps1'
            StartArgs = @('-Quiet')
            StatusHints = @('Start-Engines.ps1')
        },
        [PSCustomObject]@{
            Name = 'Start-EngineServiceMonitor'
            Path = 'scripts/Invoke-EngineServiceMonitor.ps1'
            StartArgs = @('/AUTO','-Quiet')
            StatusHints = @('Invoke-EngineServiceMonitor.ps1','engine-monitor')
        },
        [PSCustomObject]@{
            Name = 'Invoke-CronProcessor.ps1 #1'
            Path = 'scripts/Invoke-CronProcessor.ps1'
            StartArgs = @()
            StatusHints = @('Invoke-CronProcessor.ps1')
        },
        [PSCustomObject]@{
            Name = 'Invoke-CronProcessor.ps1 #2'
            Path = 'scripts/Invoke-CronProcessor.ps1'
            StartArgs = @()
            StatusHints = @('Invoke-CronProcessor.ps1')
        }
    )
}

function Start-TrayService {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Definition)

    $resolved = Resolve-WorkspaceChildPath -PathValue ([string]$Definition.Path)
    if ($null -eq $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Service target not found: $($Definition.Path)"
    }

    $args = ConvertTo-StringArray -Value $Definition.StartArgs
    $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()

    if ($ext -eq '.ps1') {
        $hostExe = Resolve-PowerShellHost
        if ($null -eq $hostExe) {
            throw 'No PowerShell host executable found.'
        }
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$resolved) + $args
        Start-Process -FilePath $hostExe -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
        return
    }

    if ($ext -in @('.bat','.cmd')) {
        $cmdArgs = @('/c', '"' + $resolved + '"') + $args
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WindowStyle Hidden | Out-Null
        return
    }

    throw "Unsupported service file extension: $ext"
}

function Test-TrayServiceRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Definition,
        [Parameter(Mandatory)] [object[]]$ProcessSnapshot
    )

    $targetLike = [PSCustomObject]@{
        path = [string]$Definition.Path
        statusHints = @($Definition.StatusHints)
    }
    return (Get-TargetIsRunning -Target $targetLike -ProcessSnapshot $ProcessSnapshot)
}

function Resolve-BootstrapTokens {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    $wsPath = [System.IO.Path]::GetFullPath($WorkspacePath)
    $wsUriPath = $wsPath -replace '\\', '/'
    return $Text.Replace('{port}', [string]$Port).Replace('{workspace}', $wsPath).Replace('{workspaceUri}', $wsUriPath)
}

function Get-BootstrapMenuConfigPath {
    [CmdletBinding()]
    param()

    return Join-Path (Join-Path $WorkspacePath 'config') 'bootstrap-menu.config.json'
}

function Get-DefaultBootstrapMenuConfig {
    [CmdletBinding()]
    param()

    return [ordered]@{
        schema = 'BootstrapMenuConfig/1.0'
        headings = @(
            [ordered]@{ name = 'Services'; items = @(
                [ordered]@{ label = 'Engine Status JSON'; type = 'url'; target = 'http://127.0.0.1:{port}/api/engine/status' },
                [ordered]@{ label = 'Start Local WebEngine'; type = 'engineAction'; target = 'Start' },
                [ordered]@{ label = 'Stop Local WebEngine'; type = 'engineAction'; target = 'Stop' },
                [ordered]@{ label = 'Restart Local WebEngine'; type = 'engineAction'; target = 'Restart' },
                [ordered]@{ label = 'Kill Local WebEngine (Force)'; type = 'engineKill'; target = 'force' }
            ) },
            [ordered]@{ name = 'SCRIPT-Tests'; items = @(
                [ordered]@{ label = 'LWE Integration Tests'; type = 'script'; target = 'tests/Start-LocalWebEngineIntegration.Tests.ps1' },
                [ordered]@{ label = 'LWE Unit Tests'; type = 'script'; target = 'tests/Start-LocalWebEngine.Tests.ps1' },
                [ordered]@{ label = 'WebEngine Sustained Test'; type = 'script'; target = 'tests/Test-WebEngineSustained.ps1' }
            ) },
            [ordered]@{ name = 'Reports'; items = @(
                [ordered]@{ label = 'Open ~REPORTS Folder'; type = 'folder'; target = '~REPORTS' },
                [ordered]@{ label = 'Open reports Folder'; type = 'folder'; target = 'reports' },
                [ordered]@{ label = 'Engine Events API'; type = 'url'; target = 'http://127.0.0.1:{port}/api/engine/events' }
            ) },
            [ordered]@{ name = 'WebPages-127.0.0.1'; items = @(
                [ordered]@{ label = 'Workspace Hub'; type = 'url'; target = 'http://127.0.0.1:{port}/' },
                [ordered]@{ label = 'Service Cluster Controller'; type = 'url'; target = 'http://127.0.0.1:{port}/scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml' },
                [ordered]@{ label = 'Menu Builder'; type = 'url'; target = 'http://127.0.0.1:{port}/pages/menu-builder' }
            ) },
            [ordered]@{ name = 'WebPages-LocalFolder'; items = @(
                [ordered]@{ label = 'XHTML-WorkspaceHub.xhtml'; type = 'file'; target = 'XHTML-WorkspaceHub.xhtml' },
                [ordered]@{ label = 'XHTML-ServiceClusterController.xhtml'; type = 'file'; target = 'scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml' },
                [ordered]@{ label = 'XHTML-MenuBuilder.xhtml'; type = 'file'; target = 'scripts/XHTML-Checker/XHTML-MenuBuilder.xhtml' }
            ) },
            [ordered]@{ name = 'system tools'; items = @(
                [ordered]@{ label = 'Services Console'; type = 'command'; target = 'services.msc' },
                [ordered]@{ label = 'Task Manager'; type = 'command'; target = 'taskmgr.exe' },
                [ordered]@{ label = 'Event Viewer'; type = 'command'; target = 'eventvwr.msc' }
            ) },
            [ordered]@{ name = 'URLs'; items = @(
                [ordered]@{ label = 'Local MCP (3000)'; type = 'url'; target = 'http://127.0.0.1:3000/mcp' },
                [ordered]@{ label = 'GitHub Repo'; type = 'url'; target = 'https://github.com/KpeJet2/KPEJET2-PowerShellGUI' },
                [ordered]@{ label = 'Bootstrap Menu Config UI'; type = 'url'; target = 'http://127.0.0.1:{port}/pages/bootstrap-menu-config' }
            ) },
            [ordered]@{ name = 'WebPage-SCRIPTs'; items = @(
                [ordered]@{ label = 'Detect scripts referenced by pages'; type = 'webpageScripts'; sourcePages = @(
                    'XHTML-WorkspaceHub.xhtml',
                    'scripts/XHTML-Checker/XHTML-ServiceClusterController.xhtml',
                    'scripts/XHTML-Checker/XHTML-MenuBuilder.xhtml'
                ) }
            ) }
        )
    }
}

function Get-BootstrapMenuConfig {
    [CmdletBinding()]
    param()

    $cfgPath = Get-BootstrapMenuConfigPath
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        return (Get-DefaultBootstrapMenuConfig)
    }

    try {
        $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return (Get-DefaultBootstrapMenuConfig)
        }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'headings')) {
            return (Get-DefaultBootstrapMenuConfig)
        }
        return $obj
    } catch {
        Write-ServiceLog -Level 'WARN' -Message "Bootstrap menu config parse failed: $($_.Exception.Message)"
        return (Get-DefaultBootstrapMenuConfig)
    }
}

function Invoke-ConfiguredScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ScriptRelative,
        [AllowNull()] [object]$ScriptArgs
    )

    $resolved = Resolve-WorkspaceChildPath -PathValue (Resolve-BootstrapTokens -Text $ScriptRelative)
    if ($null -eq $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Write-ServiceLog -Level 'WARN' -Message "Script target not found or denied: $ScriptRelative"
        return
    }

    $argList = ConvertTo-StringArray -Value $ScriptArgs
    $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($ext -eq '.ps1') {
        $hostExe = Resolve-PowerShellHost
        if ($null -eq $hostExe) {
            Write-ServiceLog -Level 'WARN' -Message 'No PowerShell host found to launch script target.'
            return
        }
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$resolved) + $argList
        Start-Process -FilePath $hostExe -ArgumentList $psArgs | Out-Null
        return
    }

    if ($ext -in @('.bat', '.cmd')) {
        $cmdArgs = @('/c', '"' + $resolved + '"') + $argList
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs | Out-Null
        return
    }

    Write-ServiceLog -Level 'WARN' -Message "Unsupported script extension for bootstrap action: $resolved"
}

function Get-WebpageScriptMap {
    [CmdletBinding()]
    param([AllowNull()] [object]$SourcePages)

    $pages = ConvertTo-StringArray -Value $SourcePages
    $map = [ordered]@{}

    foreach ($pageRel in $pages) {
        $pageResolved = Resolve-WorkspaceChildPath -PathValue (Resolve-BootstrapTokens -Text $pageRel)
        if ($null -eq $pageResolved -or -not (Test-Path -LiteralPath $pageResolved -PathType Leaf)) { continue }

        $raw = ''
        try {
            $raw = Get-Content -LiteralPath $pageResolved -Raw -Encoding UTF8
        } catch {
            continue
        }

        $scriptHits = [System.Collections.ArrayList]@()
        $scriptMatches = [regex]::Matches($raw, '(?i)(?:^|["''(=\s])(/?scripts/[A-Za-z0-9_\-./]+\.(?:ps1|bat|cmd|psm1))')
        foreach ($m in $scriptMatches) {
            if ($m.Groups.Count -lt 2) { continue }
            $val = [string]$m.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($val)) { continue }
            $normRel = $val.TrimStart('/') -replace '/', '\\'
            $resolvedScript = Resolve-WorkspaceChildPath -PathValue $normRel
            if ($null -eq $resolvedScript -or -not (Test-Path -LiteralPath $resolvedScript -PathType Leaf)) { continue }
            [void]$scriptHits.Add($normRel)
        }

        $uniqueScripts = @($scriptHits | Sort-Object -Unique)
        if (@($uniqueScripts).Count -gt 0) {
            $pageKey = $pageRel -replace '\\', '/'
            $map[$pageKey] = $uniqueScripts
        }
    }

    return $map
}

function Test-EngineProcessIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$ProcessId,
        [datetime]$PidFileWriteTimeUtc = ([datetime]::MinValue)
    )

    if ($ProcessId -le 0) {
        return $false
    }

    $procMeta = $null
    try {
        $procMeta = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    } catch {
        Write-ServiceLog -Level 'WARN' -Message "Unable to query process metadata for PID ${ProcessId}: $($_.Exception.Message)"
        return $false
    }

    if ($null -eq $procMeta) {
        Write-ServiceLog -Level 'WARN' -Message "No process metadata returned for PID $ProcessId"
        return $false
    }

    $cmdLine = if ($procMeta.PSObject.Properties.Name -contains 'CommandLine') { [string]$procMeta.CommandLine } else { '' }
    $exePath = if ($procMeta.PSObject.Properties.Name -contains 'ExecutablePath') { [string]$procMeta.ExecutablePath } else { '' }

    if ([string]::IsNullOrWhiteSpace($cmdLine)) {
        Write-ServiceLog -Level 'WARN' -Message "Cannot validate PID $ProcessId identity: command line unavailable"
        return $false
    }

    $creationUtc = $null
    if ($procMeta.PSObject.Properties.Name -contains 'CreationDate' -and -not [string]::IsNullOrWhiteSpace([string]$procMeta.CreationDate)) {
        $creationRaw = [string]$procMeta.CreationDate
        try {
            $creationLocal = [System.Management.ManagementDateTimeConverter]::ToDateTime($creationRaw)
            $creationUtc = $creationLocal.ToUniversalTime()
        } catch {
            try {
                $creationUtc = ([datetime]::Parse($creationRaw)).ToUniversalTime()
            } catch {
                $creationUtc = $null
            }
        }
    }
    if ($null -eq $creationUtc) {
        Write-ServiceLog -Level 'WARN' -Message "Cannot validate PID $ProcessId identity: process creation time unavailable"
        return $false
    }

    $cmdLower = $cmdLine.ToLowerInvariant()
    $exeLower = if ([string]::IsNullOrWhiteSpace($exePath)) { '' } else { $exePath.ToLowerInvariant() }

    if ($PidFileWriteTimeUtc -ne [datetime]::MinValue) {
        $pidFileTsUtc = $PidFileWriteTimeUtc.ToUniversalTime()
        if ($creationUtc -gt $pidFileTsUtc.AddMinutes(5)) {
            Write-ServiceLog -Level 'WARN' -Message "Engine kill denied: PID $ProcessId start time does not match PID file timestamp"
            return $false
        }
    }

    $isPwshHost = ($cmdLower -match 'pwsh(\\.exe)?' -or $cmdLower -match 'powershell(\\.exe)?' -or $exeLower -match '\\pwsh\\.exe$' -or $exeLower -match '\\powershell\\.exe$')
    if (-not $isPwshHost) {
        Write-ServiceLog -Level 'WARN' -Message "Engine kill denied: PID $ProcessId is not a PowerShell host"
        return $false
    }

    $engineScriptPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $WorkspacePath 'scripts') 'Start-LocalWebEngine.ps1')).ToLowerInvariant()
    if ($cmdLower -notmatch [regex]::Escape($engineScriptPath) -and $cmdLower -notmatch [regex]::Escape('start-localwebengine.ps1')) {
        Write-ServiceLog -Level 'WARN' -Message "Engine kill denied: PID $ProcessId command line does not match LocalWebEngine script"
        return $false
    }

    $workspaceMarker = [System.IO.Path]::GetFullPath($WorkspacePath).ToLowerInvariant()
    if ($cmdLower -notmatch [regex]::Escape($workspaceMarker)) {
        Write-ServiceLog -Level 'WARN' -Message "Engine kill denied: PID $ProcessId command line does not include workspace marker"
        return $false
    }

    $portPattern = '(?i)(?:^|\s)-port(?:\s+|:)' + [regex]::Escape([string]$Port) + '(?:\s|$)'
    if ($cmdLine -notmatch $portPattern) {
        Write-ServiceLog -Level 'WARN' -Message "Engine kill denied: PID $ProcessId command line does not include expected port $Port"
        return $false
    }

    return $true
}

function Invoke-BootstrapMenuAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Entry)

    $type = if ($Entry.PSObject.Properties.Name -contains 'type') { [string]$Entry.type } else { 'url' }
    $target = if ($Entry.PSObject.Properties.Name -contains 'target') { [string]$Entry.target } else { '' }
    $entryArgs = if ($Entry.PSObject.Properties.Name -contains 'args') { $Entry.args } else { @() }

    switch ($type.ToLowerInvariant()) {
        'url' {
            if ([string]::IsNullOrWhiteSpace($target)) { return }
            $url = Resolve-BootstrapTokens -Text $target
            Start-Process $url | Out-Null
            break
        }
        'file' {
            $path = Resolve-WorkspaceChildPath -PathValue (Resolve-BootstrapTokens -Text $target)
            if ($null -eq $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-ServiceLog -Level 'WARN' -Message "File target not found or denied: $target"
                break
            }
            Start-Process $path | Out-Null
            break
        }
        'folder' {
            $path = Resolve-WorkspaceChildPath -PathValue (Resolve-BootstrapTokens -Text $target)
            if ($null -eq $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
                Write-ServiceLog -Level 'WARN' -Message "Folder target not found or denied: $target"
                break
            }
            Start-Process $path | Out-Null
            break
        }
        'script' {
            Invoke-ConfiguredScript -ScriptRelative $target -ScriptArgs $entryArgs
            break
        }
        'engineaction' {
            if ($target -in @('Start', 'Stop', 'Restart', 'Status', 'LaunchWebpage')) {
                $backgroundAction = ($target -in @('Start','Stop','Restart'))
                Invoke-EngineAction -EngineAction $target -Background:$backgroundAction | Out-Null
            } else {
                Write-ServiceLog -Level 'WARN' -Message "Invalid engineAction target: $target"
            }
            break
        }
        'enginekill' {
            $pidFile = Join-Path (Join-Path $WorkspacePath 'logs') 'engine.pid'
            if (-not (Test-Path -LiteralPath $pidFile)) {
                Write-ServiceLog -Level 'WARN' -Message 'Engine PID file not found for kill action.'
                break
            }
            try {
                $pidFileWriteUtc = ([datetime]::MinValue)
                try {
                    $pidFileWriteUtc = (Get-Item -LiteralPath $pidFile -ErrorAction Stop).LastWriteTimeUtc
                } catch {
                    Write-ServiceLog -Level 'WARN' -Message "Unable to read PID file timestamp: $($_.Exception.Message)"
                }

                $pidText = (Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8).Trim()
                if ($pidText -match '^\d+$') {
                    $initialPid = [int]$pidText

                    $gracefulResult = $null
                    try {
                        $gracefulResult = Invoke-EngineAction -EngineAction 'Stop'
                    } catch {
                        Write-ServiceLog -Level 'WARN' -Message "Graceful stop attempt failed for PID ${initialPid}: $($_.Exception.Message)"
                    }

                    $gracefulRequested = ($null -ne $gracefulResult -and $gracefulResult.PSObject.Properties.Name -contains 'Success' -and [bool]$gracefulResult.Success)
                    if ($gracefulRequested) {
                        try {
                            Wait-Process -Id $initialPid -Timeout 2 -ErrorAction SilentlyContinue
                        } catch {
                            <# Intentional: non-fatal wait timeout or process race #>
                        }

                        $aliveAfterGraceful = $false
                        try {
                            $aliveProc = Get-Process -Id $initialPid -ErrorAction Stop
                            $aliveAfterGraceful = ($null -ne $aliveProc)
                        } catch {
                            $aliveAfterGraceful = $false
                        }

                        if (-not $aliveAfterGraceful) {
                            Write-ServiceLog -Level 'ACTION' -Message "Engine stopped gracefully (PID $initialPid)"
                            break
                        }
                    }

                    $enginePid = $initialPid
                    if (Test-Path -LiteralPath $pidFile) {
                        $refreshedPidText = (Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8).Trim()
                        if ($refreshedPidText -match '^\d+$') {
                            $enginePid = [int]$refreshedPidText
                            try {
                                $pidFileWriteUtc = (Get-Item -LiteralPath $pidFile -ErrorAction Stop).LastWriteTimeUtc
                            } catch {
                                Write-ServiceLog -Level 'WARN' -Message "Unable to refresh PID file timestamp: $($_.Exception.Message)"
                            }
                        }
                    }

                    $runningProc = $null
                    try {
                        $runningProc = Get-Process -Id $enginePid -ErrorAction Stop
                    } catch {
                        $runningProc = $null
                    }
                    if ($null -eq $runningProc) {
                        Write-ServiceLog -Level 'INFO' -Message "Engine PID $enginePid is no longer running; no force-kill required."
                        break
                    }

                    if (-not (Test-EngineProcessIdentity -ProcessId $enginePid -PidFileWriteTimeUtc $pidFileWriteUtc)) {
                        Write-ServiceLog -Level 'WARN' -Message "Engine kill skipped: identity validation failed for PID $enginePid"
                        break
                    }
                    Stop-Process -Id $enginePid -Force -ErrorAction Stop
                    Write-ServiceLog -Level 'ACTION' -Message "Force-killed engine PID $enginePid after graceful stop attempt"
                } else {
                    Write-ServiceLog -Level 'WARN' -Message "Engine PID file content is invalid for kill action: $pidText"
                }
            } catch {
                Write-ServiceLog -Level 'WARN' -Message "Engine kill failed: $($_.Exception.Message)"
            }
            break
        }
        'command' {
            if ([string]::IsNullOrWhiteSpace($target)) {
                Write-ServiceLog -Level 'WARN' -Message 'Command target not allowed by policy: (empty target)'
                break
            }
            $allowed = @('services.msc', 'eventvwr.msc', 'taskmgr.exe', 'compmgmt.msc', 'perfmon.exe')
            $targetLower = $target.ToLowerInvariant()
            if ($allowed -notcontains $targetLower) {
                Write-ServiceLog -Level 'WARN' -Message "Command target not allowed by policy: $target"
                break
            }
            $cmdArgs = ConvertTo-StringArray -Value $entryArgs
            Start-Process -FilePath $target -ArgumentList $cmdArgs | Out-Null
            break
        }
        default {
            Write-ServiceLog -Level 'WARN' -Message "Unsupported bootstrap menu entry type: $type"
        }
    }
}

function Get-BootstrapMenuRenderState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$BootstrapConfig
    )

    $headingStates = [System.Collections.ArrayList]@()

    foreach ($heading in @($BootstrapConfig.headings)) {
        $headingName = if ($heading.PSObject.Properties.Name -contains 'name') { [string]$heading.name } else { 'Untitled' }
        $renderItems = [System.Collections.ArrayList]@()
        $items = if ($heading.PSObject.Properties.Name -contains 'items') { @($heading.items) } else { @() }

        if (@($items).Count -eq 0) {
            [void]$renderItems.Add([pscustomobject]@{
                kind = 'empty'
                label = '(no entries)'
            })
        } else {
            foreach ($entry in $items) {
                $entryType = if ($entry.PSObject.Properties.Name -contains 'type') { [string]$entry.type } else { 'url' }
                $entryTypeLower = $entryType.ToLowerInvariant()

                if ($entryTypeLower -eq 'separator') {
                    [void]$renderItems.Add([pscustomobject]@{ kind = 'separator' })
                    continue
                }

                if ($entryTypeLower -eq 'webpagescripts') {
                    $map = Get-WebpageScriptMap -SourcePages $entry.sourcePages
                    if (@($map.Keys).Count -eq 0) {
                        [void]$renderItems.Add([pscustomobject]@{
                            kind = 'empty'
                            label = '(no scripts discovered)'
                        })
                        continue
                    }

                    $pageStates = [System.Collections.ArrayList]@()
                    foreach ($pageKey in @($map.Keys | Sort-Object)) {
                        $scriptsByFolder = [ordered]@{}
                        foreach ($scriptRel in @($map[$pageKey] | Sort-Object)) {
                            $folderKey = Split-Path $scriptRel -Parent
                            if ([string]::IsNullOrWhiteSpace($folderKey)) { $folderKey = '(root)' }
                            if (-not $scriptsByFolder.Contains($folderKey)) {
                                $scriptsByFolder[$folderKey] = New-Object System.Collections.ArrayList
                            }
                            [void]$scriptsByFolder[$folderKey].Add($scriptRel)
                        }

                        $folderStates = [System.Collections.ArrayList]@()
                        foreach ($folderKey in @($scriptsByFolder.Keys | Sort-Object)) {
                            $scriptStates = [System.Collections.ArrayList]@()
                            foreach ($scriptRel in @($scriptsByFolder[$folderKey] | Sort-Object)) {
                                $scriptLeaf = Split-Path $scriptRel -Leaf
                                [void]$scriptStates.Add([pscustomobject]@{
                                    label = $scriptLeaf
                                    scriptRelative = $scriptRel
                                })
                            }
                            [void]$folderStates.Add([pscustomobject]@{
                                name = $folderKey
                                scripts = @($scriptStates)
                            })
                        }

                        [void]$pageStates.Add([pscustomobject]@{
                            name = $pageKey
                            folders = @($folderStates)
                        })
                    }

                    [void]$renderItems.Add([pscustomobject]@{
                        kind = 'webpagescripts'
                        pages = @($pageStates)
                    })
                    continue
                }

                $label = if ($entry.PSObject.Properties.Name -contains 'label') { [string]$entry.label } else { '(unnamed)' }
                $tooltip = ''
                if ($entry.PSObject.Properties.Name -contains 'target') {
                    $tooltip = [string]$entry.target
                }

                [void]$renderItems.Add([pscustomobject]@{
                    kind = 'entry'
                    label = $label
                    entry = $entry
                    tooltip = $tooltip
                })
            }
        }

        [void]$headingStates.Add([pscustomobject]@{
            name = $headingName
            items = @($renderItems)
        })
    }

    return [pscustomobject]@{ headings = @($headingStates) }
}

function Add-BootstrapQuickAccessMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.ToolStripMenuItem]$RootMenu,
        [Parameter(Mandatory)] [object]$BootstrapConfig
    )

    $renderState = Get-BootstrapMenuRenderState -BootstrapConfig $BootstrapConfig
    foreach ($headingState in @($renderState.headings)) {
        $headingName = if ($headingState.PSObject.Properties.Name -contains 'name') { [string]$headingState.name } else { 'Untitled' }
        $headingMenu = New-Object System.Windows.Forms.ToolStripMenuItem($headingName)

        foreach ($node in @($headingState.items)) {
            $nodeKind = if ($node.PSObject.Properties.Name -contains 'kind') { [string]$node.kind } else { 'entry' }

            switch ($nodeKind.ToLowerInvariant()) {
                'separator' {
                    [void]$headingMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
                    continue
                }
                'empty' {
                    $emptyLabel = if ($node.PSObject.Properties.Name -contains 'label') { [string]$node.label } else { '(no entries)' }
                    $emptyItem = New-Object System.Windows.Forms.ToolStripMenuItem($emptyLabel)
                    $emptyItem.Enabled = $false
                    [void]$headingMenu.DropDownItems.Add($emptyItem)
                    continue
                }
                'webpagescripts' {
                    foreach ($pageNode in @($node.pages)) {
                        $pageMenu = New-Object System.Windows.Forms.ToolStripMenuItem([string]$pageNode.name)
                        foreach ($folderNode in @($pageNode.folders)) {
                            $folderMenu = New-Object System.Windows.Forms.ToolStripMenuItem([string]$folderNode.name)
                            foreach ($scriptNode in @($folderNode.scripts)) {
                                $scriptItem = New-Object System.Windows.Forms.ToolStripMenuItem([string]$scriptNode.label)
                                $scriptItem.Tag = [ordered]@{ type = 'script'; target = [string]$scriptNode.scriptRelative; args = @() }
                                $scriptItem.ToolTipText = [string]$scriptNode.scriptRelative
                                $scriptItem.Add_Click({
                                    param($menuItemArg)
                                    try {
                                        Invoke-BootstrapMenuAction -Entry $menuItemArg.Tag
                                    } catch {
                                        Write-ServiceLog -Level 'WARN' -Message "Bootstrap script launch failed: $($_.Exception.Message)"
                                    }
                                })
                                [void]$folderMenu.DropDownItems.Add($scriptItem)
                            }
                            [void]$pageMenu.DropDownItems.Add($folderMenu)
                        }
                        [void]$headingMenu.DropDownItems.Add($pageMenu)
                    }
                    continue
                }
                default {
                    $entryLabel = if ($node.PSObject.Properties.Name -contains 'label') { [string]$node.label } else { '(unnamed)' }
                    $item = New-Object System.Windows.Forms.ToolStripMenuItem($entryLabel)
                    $item.Tag = if ($node.PSObject.Properties.Name -contains 'entry') { $node.entry } else { $null }
                    if ($node.PSObject.Properties.Name -contains 'tooltip' -and -not [string]::IsNullOrWhiteSpace([string]$node.tooltip)) {
                        $item.ToolTipText = [string]$node.tooltip
                    }
                    $item.Add_Click({
                        param($menuItemArg)
                        try {
                            Invoke-BootstrapMenuAction -Entry $menuItemArg.Tag
                        } catch {
                            Write-ServiceLog -Level 'WARN' -Message "Bootstrap action failed: $($_.Exception.Message)"
                        }
                    })
                    [void]$headingMenu.DropDownItems.Add($item)
                }
            }
        }

        if (@($headingMenu.DropDownItems).Count -eq 0) {
            $fallbackItem = New-Object System.Windows.Forms.ToolStripMenuItem('(no entries)')
            $fallbackItem.Enabled = $false
            [void]$headingMenu.DropDownItems.Add($fallbackItem)
        }

        [void]$RootMenu.DropDownItems.Add($headingMenu)
    }
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

    $showError = {
        param(
            [Parameter(Mandatory)] [string]$Title,
            [Parameter(Mandatory)] [string]$ErrorText
        )
        Write-ServiceWarningWithHint -Context $Title -ErrorText $ErrorText
        try {
            $hint = Get-ResolutionHint -ErrorText $ErrorText
            $msg = $ErrorText
            if (-not [string]::IsNullOrWhiteSpace($hint)) {
                $msg = $ErrorText + "`r`nHint: " + $hint
            }
            $notify.BalloonTipTitle = $Title
            $notify.BalloonTipText = $msg.Substring(0, [Math]::Min(240, $msg.Length))
            $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
            $notify.ShowBalloonTip(5000)
        } catch {
            <# Intentional: non-fatal tray tooltip failure #>
        }
    }

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
                    param($menuItemArg)
                    $pathValue = [string]$menuItemArg.Tag
                    try {
                        Start-Process $pathValue | Out-Null
                    } catch {
                        Write-ServiceLog -Level 'WARN' -Message ("Failed to open static page {0}: {1}" -f $pathValue, $_.Exception.Message)
                    }
                })

                $serviceItem.Add_Click({
                    param($menuItemArg)
                    $relativeValue = [string]$menuItemArg.Tag
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

    $bootstrapRoot = New-Object System.Windows.Forms.ToolStripMenuItem('Bootstrap Quick Access')
    $reloadBootstrapMenu = {
        try {
            $bootstrapRoot.DropDownItems.Clear()
            $bootstrapConfig = Get-BootstrapMenuConfig
            Add-BootstrapQuickAccessMenu -RootMenu $bootstrapRoot -BootstrapConfig $bootstrapConfig
            Write-ServiceLog -Level 'INFO' -Message 'Bootstrap quick access menu reloaded from config.'
        } catch {
            Write-ServiceLog -Level 'WARN' -Message "Bootstrap menu reload failed: $($_.Exception.Message)"
        }
    }
    & $reloadBootstrapMenu
    [void]$context.Items.Add($bootstrapRoot)

    $serviceFlyoutRoot = New-Object System.Windows.Forms.ToolStripMenuItem('Services Startup + Monitor')
    $serviceDefs = @(Get-TrayServiceDefinitions)
    $serviceNodes = [System.Collections.ArrayList]@()
    foreach ($svc in $serviceDefs) {
        $svcItem = New-Object System.Windows.Forms.ToolStripMenuItem([string]$svc.Name)
        $svcItem.CheckOnClick = $true
        $svcItem.Tag = $svc
        $svcItem.ToolTipText = [string]$svc.Path
        $svcItem.Add_Click({
            param($sender)
            $menuItemArg = [System.Windows.Forms.ToolStripMenuItem]$sender
            $svcDef = $menuItemArg.Tag
            try {
                $snapshot = @()
                try {
                    $snapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, CommandLine)
                } catch {
                    $snapshot = @()
                }

                $isRunning = $false
                if (@($snapshot).Count -gt 0) {
                    $isRunning = Test-TrayServiceRunning -Definition $svcDef -ProcessSnapshot $snapshot
                }

                if ($isRunning) {
                    $menuItemArg.Checked = $true
                    Write-ServiceLog -Level 'INFO' -Message ("Service already running: {0}" -f $svcDef.Name)
                    return
                }

                Start-TrayService -Definition $svcDef
                $menuItemArg.Checked = $true
                Write-ServiceLog -Level 'ACTION' -Message ("Service start requested: {0}" -f $svcDef.Name)
            } catch {
                $menuItemArg.Checked = $false
                & $showError ("Service start failed: " + $svcDef.Name) $_.Exception.Message
            }
        })
        [void]$serviceFlyoutRoot.DropDownItems.Add($svcItem)
        [void]$serviceNodes.Add([PSCustomObject]@{ Item = $svcItem; Definition = $svc })
    }
    [void]$context.Items.Add($serviceFlyoutRoot)

    $launchA = New-Object System.Windows.Forms.ToolStripMenuItem('Launch Auto Five (A)')
    $launchA.Add_Click({ Invoke-LauncherSetFromConfig -SetName 'A' -SetTable $launcherSets })
    [void]$context.Items.Add($launchA)

    $launchB = New-Object System.Windows.Forms.ToolStripMenuItem('Launch Bigger 10 (B)')
    $launchB.Add_Click({ Invoke-LauncherSetFromConfig -SetName 'B' -SetTable $launcherSets })
    [void]$context.Items.Add($launchB)

    [void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $bootstrapConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem('Configure Bootstrap Menu...')
    $bootstrapConfigItem.Add_Click({
        $url = "http://127.0.0.1:$Port/pages/bootstrap-menu-config"
        try {
            Start-Process $url | Out-Null
        } catch {
            Write-ServiceLog -Level 'WARN' -Message ("Failed to launch bootstrap config page {0}: {1}" -f $url, $_.Exception.Message)
        }
    })
    [void]$context.Items.Add($bootstrapConfigItem)

    $reloadBootstrapItem = New-Object System.Windows.Forms.ToolStripMenuItem('Reload Bootstrap Menu')
    $reloadBootstrapItem.Add_Click({
        & $reloadBootstrapMenu
    })
    [void]$context.Items.Add($reloadBootstrapItem)

    [void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh status now')
    [void]$context.Items.Add($refreshItem)

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem('Start engine')
    $startItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Start' -Background | Out-Null
        } catch {
            & $showError 'Tray start failed' $_.Exception.Message
        }
    })
    [void]$context.Items.Add($startItem)

    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem('Restart engine')
    $restartItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Restart' -Background | Out-Null
        } catch {
            & $showError 'Tray restart failed' $_.Exception.Message
        }
    })
    [void]$context.Items.Add($restartItem)

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem('Stop engine')
    $stopItem.Add_Click({
        try {
            Invoke-EngineAction -EngineAction 'Stop' -Background | Out-Null
        } catch {
            & $showError 'Tray stop failed' $_.Exception.Message
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

        $snap = @()
        try {
            $snap = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, Name, CommandLine)
        } catch {
            $snap = @()
        }
        foreach ($node in @($serviceNodes)) {
            $runningNow = $false
            if (@($snap).Count -gt 0) {
                $runningNow = Test-TrayServiceRunning -Definition $node.Definition -ProcessSnapshot $snap
            }
            $node.Item.Checked = [bool]$runningNow
        }
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

