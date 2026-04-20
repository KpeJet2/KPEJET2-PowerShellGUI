# VersionTag: 2604.B2.V31.0
# FileRole: Module
#Requires -Version 5.1
<#
.SYNOPSIS
    PwShGUI Tray Host Module -- background process host, custom tray icon,
    ApplicationContext lifecycle, and keyboard rehydration.
# TODO: HelpMenu | Show-TrayHostHelp | Actions: Start|Stop|Status|Minimize|Help | Spec: config/help-menu-registry.json

.DESCRIPTION
    Provides the "PShellCore" separated background processing layer:
    - Custom smiley tray icon (yellow face on crimson oval)
    - ApplicationContext-based lifecycle (form can hide/show without dying)
    - Background runspace pool for discrete thread execution
    - Spacebar keyboard monitor for CLI-based GUI rehydration
    - Verbose lifecycle logging

    Import after PwShGUICore:
        Import-Module (Join-Path $modulesDir 'PwShGUI-TrayHost.psm1') -Force

.NOTES
    Author   : The Establishment / FocalPoint-null-00
    Version  : 2604.B2.V31.0
    Created  : 28th March 2026
#>

# ========================== MODULE STATE ==========================
$script:_AppContext       = $null   # System.Windows.Forms.ApplicationContext
$script:_KeyboardTimer    = $null   # System.Windows.Forms.Timer - polls spacebar
$script:_TrayBitmapRef    = $null   # Keep GDI bitmap alive for icon handle
$script:_BackgroundPool   = $null   # RunspacePool for PShellCore tasks
$script:_BackgroundTasks  = [System.Collections.Generic.List[hashtable]]::new()
$script:_VerboseLifecycle = $true   # verbose lifecycle logging
$script:_HostForm         = $null   # reference to the main form
$script:_RestoreAction    = $null   # scriptblock to restore from tray

# ========================== TRAY ICON ==========================
function New-SmileyTrayIcon {
    <#
    .SYNOPSIS  Create a 32x32 smiley face icon (yellow on crimson oval) for the system tray.
    .OUTPUTS   [System.Drawing.Icon]
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # -- Crimson oval background --
    $crimson = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(220, 20, 60))
    $g.FillEllipse($crimson, 0, 0, 31, 31)
    $crimson.Dispose()

    # -- Yellow smiley face --
    $yellow = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(255, 220, 50))
    $g.FillEllipse($yellow, 4, 4, 23, 23)
    $yellow.Dispose()

    # -- Eyes (dark) --
    $eyes = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(50, 25, 10))
    $g.FillEllipse($eyes, 10, 10, 4, 5)
    $g.FillEllipse($eyes, 18, 10, 4, 5)
    $eyes.Dispose()

    # -- Smile arc --
    $pen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(50, 25, 10), 2)
    $g.DrawArc($pen, 9, 12, 14, 10, 15, 150)
    $pen.Dispose()

    $g.Dispose()

    # Keep bitmap reference alive (prevents handle invalidation via GC)
    $script:_TrayBitmapRef = $bmp
    $hIcon = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($hIcon)
}

# ========================== APPLICATION CONTEXT ==========================
function Initialize-TrayAppContext {
    <#
    .SYNOPSIS  Create the ApplicationContext that keeps the message loop alive
               independently of form visibility.
    .PARAMETER Form  The main WinForms form.
    .PARAMETER RestoreAction  ScriptBlock to restore the form from tray.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Form]$Form,

        [scriptblock]$RestoreAction
    )

    $script:_HostForm     = $Form
    $script:_RestoreAction = $RestoreAction
    $script:_AppContext   = New-Object System.Windows.Forms.ApplicationContext

    if ($script:_VerboseLifecycle -and (Get-Command Write-AppLog -ErrorAction SilentlyContinue)) {
        Write-AppLog "[TrayHost] ApplicationContext initialised -- form lifecycle decoupled from message loop" "Debug"
    }
    return $script:_AppContext
}

function Start-TrayApplicationLoop {
    <#
    .SYNOPSIS  Run the WinForms message loop via ApplicationContext.
               Blocks until Stop-TrayHost is called.
    .PARAMETER StartMinimized  If true, minimize form to tray immediately.
    #>
    [CmdletBinding()]
    param(
        [switch]$StartMinimized
    )

    if (-not $script:_AppContext) {
        throw "Initialize-TrayAppContext must be called before Start-TrayApplicationLoop"
    }

    $logAvail = Get-Command Write-AppLog -ErrorAction SilentlyContinue

    if ($StartMinimized -and $script:_HostForm) {
        $script:_HostForm.WindowState   = [System.Windows.Forms.FormWindowState]::Minimized
        $script:_HostForm.ShowInTaskbar = $false
        if ($logAvail) { Write-AppLog "[TrayHost] Starting minimized to system tray" "Debug" }
    }

    # Show the form (non-modal)
    $script:_HostForm.Show()

    if ($logAvail) { Write-AppLog "[TrayHost] Application message loop starting" "Debug" }

    # Block on the message loop (returns after ExitThread)
    [System.Windows.Forms.Application]::Run($script:_AppContext)

    if ($logAvail) { Write-AppLog "[TrayHost] Application message loop ended" "Debug" }
}

function Stop-TrayHost {
    <#
    .SYNOPSIS  Signal the ApplicationContext to exit, ending the message loop.
    #>
    [CmdletBinding()]
    param()

    $logAvail = Get-Command Write-AppLog -ErrorAction SilentlyContinue

    # Stop keyboard monitor
    if ($script:_KeyboardTimer) {
        $script:_KeyboardTimer.Stop()
        $script:_KeyboardTimer.Dispose()
        $script:_KeyboardTimer = $null
        if ($logAvail) { Write-AppLog "[TrayHost] Keyboard monitor stopped" "Debug" }
    }

    # Stop background pool
    Stop-BackgroundPool

    # Exit application loop
    if ($script:_AppContext) {
        try { [System.Windows.Forms.Application]::ExitThread() } catch { <# Intentional: non-fatal #> }
        $script:_AppContext = $null
        if ($logAvail) { Write-AppLog "[TrayHost] ExitThread called -- message loop will end" "Debug" }
    }

    # Dispose form if not already
    if ($script:_HostForm -and -not $script:_HostForm.IsDisposed) {
        $script:_HostForm.Dispose()
        if ($logAvail) { Write-AppLog "[TrayHost] Form disposed" "Debug" }
    }

    # Dispose tray bitmap
    if ($script:_TrayBitmapRef) {
        try { $script:_TrayBitmapRef.Dispose() } catch { <# Intentional: non-fatal #> }
        $script:_TrayBitmapRef = $null
    }
}

# ========================== KEYBOARD MONITOR ==========================
function Start-KeyboardMonitor {
    <#
    .SYNOPSIS  Start a WinForms Timer that polls console for spacebar press.
               When detected, restores the form from tray.
    .PARAMETER IntervalMs  Poll interval in milliseconds (default 300).
    #>
    [CmdletBinding()]
    param(
        [int]$IntervalMs = 300
    )

    if ($script:_KeyboardTimer) { return }  # already running

    $script:_KeyboardTimer = New-Object System.Windows.Forms.Timer
    $script:_KeyboardTimer.Interval = $IntervalMs
    $script:_KeyboardTimer.Add_Tick({
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Spacebar' -and $script:_HostForm -and
                    -not $script:_HostForm.IsDisposed -and
                    -not $script:_HostForm.Visible) {
                    if ($script:_RestoreAction) {
                        & $script:_RestoreAction
                    } else {
                        $script:_HostForm.Show()
                        $script:_HostForm.ShowInTaskbar = $true
                        $script:_HostForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                        $script:_HostForm.Activate()
                    }
                    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
                        Write-AppLog "[TrayHost] GUI rehydrated via SPACEBAR in calling shell" "Audit"
                    }
                    Write-Information '' -InformationAction Continue
                    Write-Information '***GUI-is-RESTORED-via-SPACEBAR***' -InformationAction Continue
                    Write-Information '' -InformationAction Continue
                }
            }
        } catch {
            # Console not available (e.g. ISE) -- silently skip
        }
    })
    $script:_KeyboardTimer.Start()

    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
        Write-AppLog "[TrayHost] Keyboard monitor started (poll=${IntervalMs}ms) -- press SPACEBAR in shell to restore GUI" "Debug"
    }
}

function Stop-KeyboardMonitor {
    <#
    .SYNOPSIS  Stop the spacebar keyboard monitor.
    #>
    [CmdletBinding()]
    param()
    if ($script:_KeyboardTimer) {
        $script:_KeyboardTimer.Stop()
        $script:_KeyboardTimer.Dispose()
        $script:_KeyboardTimer = $null
    }
}

# ========================== BACKGROUND POOL (PShellCore) ==========================
function Initialize-BackgroundPool {
    <#
    .SYNOPSIS  Create the PShellCore runspace pool for background task execution.
    .PARAMETER MinThreads  Minimum runspace threads (default 1).
    .PARAMETER MaxThreads  Maximum runspace threads (default 4).
    #>
    [CmdletBinding()]
    param(
        [int]$MinThreads = 1,
        [int]$MaxThreads = 4
    )

    if ($script:_BackgroundPool) { return }

    $script:_BackgroundPool = [runspacefactory]::CreateRunspacePool($MinThreads, $MaxThreads)
    $script:_BackgroundPool.Open()

    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
        Write-AppLog "[PShellCore] Background runspace pool initialised (threads: $MinThreads-$MaxThreads)" "Debug"
    }
}

function Invoke-BackgroundTask {
    <#
    .SYNOPSIS  Submit a scriptblock for execution in the PShellCore background pool.
    .PARAMETER ScriptBlock  The code to execute.
    .PARAMETER Parameters   Optional hashtable of parameters.
    .PARAMETER TaskName     Friendly name for logging.
    .OUTPUTS   [string] Task ID for tracking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters,

        [string]$TaskName = 'BackgroundTask'
    )

    if (-not $script:_BackgroundPool) {
        Initialize-BackgroundPool
    }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:_BackgroundPool
    [void]$ps.AddScript($ScriptBlock)
    if ($Parameters) {
        foreach ($kv in $Parameters.GetEnumerator()) {
            [void]$ps.AddParameter($kv.Key, $kv.Value)
        }
    }

    $handle = $ps.BeginInvoke()
    $taskId = "BG-$(Get-Date -Format 'HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,6))"

    $script:_BackgroundTasks.Add(@{
        Id         = $taskId
        Name       = $TaskName
        PowerShell = $ps
        Handle     = $handle
        StartedAt  = (Get-Date)
    })

    if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
        Write-AppLog "[PShellCore] Background task submitted: $TaskName ($taskId)" "Debug"
    }

    return $taskId
}

function Get-CompletedBackgroundTasks {
    <#
    .SYNOPSIS  Collect results from completed background tasks.
    .OUTPUTS   Array of hashtables with Id, Name, Result, Errors, Duration.
    #>
    [CmdletBinding()]
    param()

    $completed = @()
    $remaining = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($task in $script:_BackgroundTasks) {
        if ($task.Handle.IsCompleted) {
            $result  = $null
            $errors  = @()
            try {
                $result = $task.PowerShell.EndInvoke($task.Handle)
                if ($task.PowerShell.Streams.Error.Count -gt 0) {
                    $errors = @($task.PowerShell.Streams.Error | ForEach-Object { $_.ToString() })
                }
            } catch {
                $errors = @($_.ToString())
            }
            $task.PowerShell.Dispose()
            $duration = ((Get-Date) - $task.StartedAt).TotalSeconds
            $completed += @{
                Id       = $task.Id
                Name     = $task.Name
                Result   = $result
                Errors   = $errors
                Duration = [math]::Round($duration, 2)
            }
        } else {
            $remaining.Add($task)
        }
    }

    $script:_BackgroundTasks = $remaining
    return ,$completed
}

function Stop-BackgroundPool {
    <#
    .SYNOPSIS  Dispose all active background tasks and close the runspace pool.
    #>
    [CmdletBinding()]
    param()

    foreach ($task in $script:_BackgroundTasks) {
        try {
            if (-not $task.Handle.IsCompleted) {
                $task.PowerShell.Stop()
            }
            $task.PowerShell.Dispose()
        } catch { <# Intentional: non-fatal #> }
    }
    $script:_BackgroundTasks.Clear()

    if ($script:_BackgroundPool) {
        try { $script:_BackgroundPool.Close() } catch { <# Intentional: non-fatal #> }
        try { $script:_BackgroundPool.Dispose() } catch { <# Intentional: non-fatal #> }
        $script:_BackgroundPool = $null
        if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
            Write-AppLog "[PShellCore] Background runspace pool closed" "Debug"
        }
    }
}

# ========================== VERBOSE LOGGING ==========================
function Set-VerboseLifecycle {
    <#
    .SYNOPSIS  Enable or disable verbose lifecycle logging.
    #>
    [CmdletBinding()]
    param([bool]$Enabled = $true)
    $script:_VerboseLifecycle = $Enabled
}

function Get-TrayHostStatus {
    <#
    .SYNOPSIS  Return current TrayHost state for diagnostics.
    #>
    [CmdletBinding()]
    param()
    return @{
        AppContextActive   = ($null -ne $script:_AppContext)
        KeyboardMonitor    = ($null -ne $script:_KeyboardTimer)
        BackgroundPool     = ($null -ne $script:_BackgroundPool)
        ActiveTasks        = $script:_BackgroundTasks.Count
        FormVisible        = if ($script:_HostForm) { $script:_HostForm.Visible } else { $false }
        FormDisposed       = if ($script:_HostForm) { $script:_HostForm.IsDisposed } else { $true }
        VerboseLifecycle   = $script:_VerboseLifecycle
    }
}

# ========================== EXPORTS ==========================
Export-ModuleMember -Function @(
    'New-SmileyTrayIcon'
    'Initialize-TrayAppContext'
    'Start-TrayApplicationLoop'
    'Stop-TrayHost'
    'Start-KeyboardMonitor'
    'Stop-KeyboardMonitor'
    'Initialize-BackgroundPool'
    'Invoke-BackgroundTask'
    'Get-CompletedBackgroundTasks'
    'Stop-BackgroundPool'
    'Set-VerboseLifecycle'
    'Get-TrayHostStatus'
)

