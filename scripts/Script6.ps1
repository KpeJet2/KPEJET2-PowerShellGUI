# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Scaffolding
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-24 03:28  (deduplicated from 5 entries)
#Requires -Version 5.1
<#
.SYNOPSIS
    Script6 - System Cleanup (Interactive with WhatIf Simulation)

.DESCRIPTION
    Performs comprehensive Windows system cleanup across multiple temporary,
    cache, and log locations.  Features an interactive checkbox selector
    for choosing specific cleanup targets, then:

      Y   Run cleanup immediately with full output and logging.
      W   WhatIf simulation -- enumerate affected files/sizes without changes,
          then optionally proceed for real.
      ESC / no selection   Abort without changes.

    Idle for 15 seconds auto-proceeds with a WhatIf preview of all targets.

    All actions are logged to the PwShGUI logs directory and a summary is
    displayed on completion with the log file path.

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Requires : PowerShell 5.1+
    Elevation: Recommended for full disk-cache and prefetch cleanup.

.LINK
    ~README.md/NETWORK-TOOLS-GUIDE.md
#>

# ========================== INITIALISATION ==========================
$ErrorActionPreference = 'Continue'
$scriptName   = 'Script6'
$workspaceDir = Split-Path -Parent $PSScriptRoot
$modulePath   = Join-Path $workspaceDir 'modules\PwShGUICore.psm1'
$logsDir      = Join-Path $workspaceDir 'logs'

# Import core module for logging
if (Test-Path $modulePath) {
    try { Import-Module $modulePath -Force -ErrorAction Stop } catch { Write-Warning "Failed to import core module: $_" }
    Initialize-CorePaths -ScriptDir $workspaceDir -LogsDir $logsDir
} else {
    # Minimal fallback if module is missing
    function Write-AppLog  { param($Message,$Level) Write-Host "[$Level] $Message" }  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    function Write-ScriptLog { param($Message,$ScriptName,$Level) Write-Host "[$ScriptName][$Level] $Message" }  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    function Export-LogBuffer { }  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
}

# Dedicated cleanup log
$timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$cleanupLog   = Join-Path $logsDir "SystemCleanup-$timestamp.log"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

function Write-CleanupLog {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param(
        [string]$Message,
        [ValidateSet('Debug','Info','Warning','Error','Critical','Audit')]
        [string]$Level = 'Info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $cleanupLog -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-ScriptLog $Message $scriptName $Level
}

# ========================== CLEANUP TARGETS ==========================
# Each target: Name, Description, Paths (array), FileFilter, Action
$cleanupTargets = @(
    @{
        Name        = 'User Temp Files'
        Description = 'Temporary files created by user applications'
        Paths       = @($env:TEMP)
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Windows Temp'
        Description = 'System-wide temporary directory'
        Paths       = @("$env:SystemRoot\Temp")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Windows Update Cache'
        Description = 'Downloaded update packages (safe to remove)'
        Paths       = @("$env:SystemRoot\SoftwareDistribution\Download")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Prefetch Files'
        Description = 'Application prefetch data (rebuilds automatically)'
        Paths       = @("$env:SystemRoot\Prefetch")
        FileFilter  = '*.pf'
        Action      = 'DeleteFiles'
    },
    @{
        Name        = 'Thumbnail Cache'
        Description = 'Explorer thumbnail database files'
        Paths       = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
        FileFilter  = 'thumbcache_*.db'
        Action      = 'DeleteFiles'
    },
    @{
        Name        = 'Windows Error Reports'
        Description = 'Crash dumps and WER report queues'
        Paths       = @(
            "$env:LOCALAPPDATA\CrashDumps"
            "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
        )
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Memory Dump Files'
        Description = 'Kernel and mini crash dump files'
        Paths       = @(
            "$env:SystemRoot\MEMORY.DMP"
            "$env:SystemRoot\Minidump"
        )
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Delivery Optimization Cache'
        Description = 'Windows Update peer-to-peer delivery cache'
        Paths       = @("$env:SystemRoot\SoftwareDistribution\DeliveryOptimization")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Windows CBS Logs'
        Description = 'Component-Based Servicing log files'
        Paths       = @("$env:SystemRoot\Logs\CBS")
        FileFilter  = '*.log'
        Action      = 'DeleteFiles'
    },
    @{
        Name        = 'Windows Installer Temp'
        Description = 'MSI installer patch-cache temp files'
        Paths       = @("$env:SystemRoot\Installer\`$PatchCache`$\Managed")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Edge Browser Cache'
        Description = 'Microsoft Edge temporary internet files'
        Paths       = @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\Cache_Data")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Chrome Browser Cache'
        Description = 'Google Chrome temporary internet files'
        Paths       = @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\Cache_Data")
        FileFilter  = '*'
        Action      = 'DeleteContents'
    },
    @{
        Name        = 'Firefox Browser Cache'
        Description = 'Mozilla Firefox temporary internet files'
        Paths       = @("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles")
        FileFilter  = 'cache2'
        Action      = 'DeleteSubfolders'
    },
    @{
        Name        = 'DNS Resolver Cache'
        Description = 'Flush the DNS client resolver cache'
        Paths       = @()
        FileFilter  = ''
        Action      = 'FlushDNS'
    },
    @{
        Name        = 'Recycle Bin'
        Description = 'Empty the Windows Recycle Bin for all drives'
        Paths       = @()
        FileFilter  = ''
        Action      = 'EmptyRecycleBin'
    }
)

# ========================== HELPER: SIZE FORMAT ==========================
function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB)     { return '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    else                    { return "$Bytes bytes" }
}

# ========================== HELPER: ENUMERATE TARGET ==========================
function Get-TargetItems {
    <#
    .SYNOPSIS  Returns file objects for a cleanup target (for sizing / WhatIf).
    #>
    param([hashtable]$Target)
    $items = @()
    foreach ($p in $Target.Paths) {
        if (-not (Test-Path $p)) { continue }
        $isFile = (Get-Item $p -ErrorAction SilentlyContinue) -is [System.IO.FileInfo]
        switch ($Target.Action) {
            'DeleteContents' {
                if ($isFile) {
                    $items += Get-Item $p -ErrorAction SilentlyContinue
                } else {
                    $items += Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            'DeleteFiles' {
                if ($isFile) {
                    $items += Get-Item $p -ErrorAction SilentlyContinue
                } else {
                    $items += Get-ChildItem -Path $p -Filter $Target.FileFilter -Force -ErrorAction SilentlyContinue
                }
            }
            'DeleteSubfolders' {
                $items += Get-ChildItem -Path $p -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -eq $Target.FileFilter } |
                          ForEach-Object { Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
            default { }  # DNS / Recycle Bin -- no file enumeration
        }
    }
    return $items
}

# ========================== HELPER: EXECUTE SINGLE TARGET ==========================
function Invoke-CleanupTarget {
    <#
    .SYNOPSIS  Perform the actual cleanup for one target. Returns summary hashtable.
    #>
    param([hashtable]$Target)

    $result = @{ Name = $Target.Name; FilesRemoved = 0; BytesFreed = 0; Errors = @() }

    switch ($Target.Action) {
        'FlushDNS' {
            try {
                $null = ipconfig /flushdns 2>&1
                Write-CleanupLog "  Flushed DNS resolver cache" 'Success'
                $result.FilesRemoved = 0
            } catch {
                $result.Errors += $_.ToString()
                Write-CleanupLog "  DNS flush failed: $_" 'Error'
            }
        }
        'EmptyRecycleBin' {
            try {
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                Write-CleanupLog "  Emptied Recycle Bin" 'Success'
            } catch {
                $result.Errors += $_.ToString()
                Write-CleanupLog "  Recycle Bin clear failed: $_" 'Error'
            }
        }
        default {
            foreach ($p in $Target.Paths) {
                if (-not (Test-Path $p)) { continue }
                $isFile = (Get-Item $p -ErrorAction SilentlyContinue) -is [System.IO.FileInfo]

                if ($Target.Action -eq 'DeleteContents') {
                    if ($isFile) {
                        try {
                            $sz = (Get-Item $p).Length
                            Remove-Item $p -Force -ErrorAction Stop
                            $result.FilesRemoved++; $result.BytesFreed += $sz
                        } catch { $result.Errors += "$p : $_" }
                    } else {
                        Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            try {
                                $sz = if ($_ -is [System.IO.FileInfo]) { $_.Length } else { 0 }
                                Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                                $result.FilesRemoved++; $result.BytesFreed += $sz
                            } catch { $result.Errors += "$($_.FullName) : $_" }
                        }
                    }
                }
                elseif ($Target.Action -eq 'DeleteFiles') {
                    Get-ChildItem -Path $p -Filter $Target.FileFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            $sz = if ($_ -is [System.IO.FileInfo]) { $_.Length } else { 0 }
                            Remove-Item $_.FullName -Force -ErrorAction Stop
                            $result.FilesRemoved++; $result.BytesFreed += $sz
                        } catch { $result.Errors += "$($_.FullName) : $_" }
                    }
                }
                elseif ($Target.Action -eq 'DeleteSubfolders') {
                    Get-ChildItem -Path $p -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq $Target.FileFilter } | ForEach-Object {
                        Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            try {
                                $sz = if ($_ -is [System.IO.FileInfo]) { $_.Length } else { 0 }
                                Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                                $result.FilesRemoved++; $result.BytesFreed += $sz
                            } catch { $result.Errors += "$($_.FullName) : $_" }
                        }
                    }
                }
            }
            $freed = Format-FileSize $result.BytesFreed
            Write-CleanupLog "  Removed $($result.FilesRemoved) items ($freed freed)" 'Success'
            if ($result.Errors.Count -gt 0) {
                Write-CleanupLog "  $($result.Errors.Count) items skipped (in-use/locked)" 'Warning'
            }
        }
    }
    return $result
}

# ========================== INTERACTIVE CHECKBOX SELECTOR ==========================
function Show-CleanupSelector {
    <#
    .SYNOPSIS  Interactive console checkbox menu for selecting cleanup targets.
    .DESCRIPTION
        Draws a navigable checkbox list with an ALL option at the top.
        Arrow keys move the highlight, SPACE toggles selection, ENTER proceeds,
        ESC aborts.  If no key is pressed for 15 seconds the selector
        auto-selects ALL targets and returns in WhatIf mode.
    .OUTPUTS  Hashtable with keys: Mode ('Selected','WhatIf','Abort'), SelectedIndices (int[])
    #>
    param([array]$Targets)

    $count      = $Targets.Count
    $totalItems = $count + 1          # index 0 = ALL, 1..$count = individual
    $selected   = [bool[]]::new($totalItems)
    $cursor     = 0
    $timeoutSec = 15
    $cw         = try { [Math]::Max(60, [Console]::WindowWidth - 4) } catch { 80 }

    # Pre-check which target paths exist
    $pathOk = @()
    foreach ($t in $Targets) {
        $ok = $false
        if ($t.Paths.Count -eq 0 -and $t.Action -in @('FlushDNS','EmptyRecycleBin')) { $ok = $true }
        else { foreach ($p in $t.Paths) { if (Test-Path $p) { $ok = $true; break } } }
        $pathOk += $ok
    }

    Write-Host ''
    Write-Host '  Select cleanup targets:' -ForegroundColor Yellow
    Write-Host '  (Up/Down to navigate, SPACE to toggle, ENTER to proceed, ESC to abort)' -ForegroundColor DarkGray
    Write-Host ''

    # Reserve vertical space so the buffer scrolls NOW rather than mid-render.
    # Menu needs: $totalItems rows + 2 legend rows + 1 countdown + 1 blank = totalItems+4
    $linesNeeded = $totalItems + 4
    $bufHeight   = try { [Console]::BufferHeight } catch { 300 }
    $curTop      = [Console]::CursorTop
    $available   = $bufHeight - $curTop - 1
    if ($available -lt $linesNeeded) {
        $deficit = $linesNeeded - $available
        for ($j = 0; $j -lt $deficit; $j++) { Write-Host '' }
        # Buffer scrolled by $deficit; adjust anchor
        $menuTop = [Console]::CursorTop - $deficit
        # Safety clamp
        if ($menuTop -lt 0) { $menuTop = 0 }
    } else {
        $menuTop = $curTop
    }
    [Console]::CursorVisible = $false

    try {
        # ---- rendering helpers (read parent-scope variables at call time) ----
        function Render-Menu {
            $safeTop = [Math]::Max(0, [Math]::Min($menuTop, [Console]::BufferHeight - $totalItems - 5))
            [Console]::SetCursorPosition(0, $safeTop)
            for ($i = 0; $i -lt $totalItems; $i++) {
                $hl  = ($i -eq $cursor)
                $chk = if ($selected[$i]) { 'X' } else { ' ' }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $ptr = if ($hl) { ' >> ' } else { '    ' }

                if ($i -eq 0) {
                    $line = "$ptr[$chk]  ** SELECT ALL **"  # SIN-EXEMPT:P027 -- index access, context-verified safe
                } else {
                    $ti = $i - 1
                    $st = if ($pathOk[$ti]) { '+' } else { '-' }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                    $line = "$ptr[$chk]  {0,2}. [{1}] {2}" -f $i, $st, $Targets[$ti].Name  # SIN-EXEMPT:P027 -- index access, context-verified safe
                }

                $padded = $line.PadRight($cw)
                if ($hl) {
                    Write-Host $padded -ForegroundColor White -BackgroundColor DarkCyan
                } else {
                    $fg = if ($i -eq 0) { 'Cyan' }
                          elseif ($pathOk[$i - 1]) { 'Green' }
                          else { 'DarkGray' }
                    Write-Host $padded -ForegroundColor $fg
                }
            }
            Write-Host ''
            Write-Host ('    [+] = path available    [-] = not found / skipped'.PadRight($cw)) -ForegroundColor DarkGray
            Write-Host ('    Up/Down  |  SPACE = Toggle  |  ENTER = Proceed  |  ESC = Abort'.PadRight($cw)) -ForegroundColor Yellow
        }

        function Render-Countdown([int]$sec) {
            $pos = [Math]::Max(0, [Math]::Min($menuTop + $totalItems + 3, [Console]::BufferHeight - 2))
            [Console]::SetCursorPosition(0, $pos)
            $txt = "    Auto WhatIf (all targets) in $sec seconds...  "
            Write-Host $txt.PadRight($cw) -ForegroundColor DarkGray
        }

        # Initial paint
        Render-Menu
        Render-Countdown $timeoutSec

        $sw      = [System.Diagnostics.Stopwatch]::StartNew()
        $lastSec = $timeoutSec

        while ($true) {
            $rem = [Math]::Max(0, $timeoutSec - [Math]::Floor($sw.Elapsed.TotalSeconds))

            # ---- timeout ----
            if ($rem -le 0) {
                for ($i = 0; $i -lt $totalItems; $i++) { $selected[$i] = $true }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                Render-Menu
                [Console]::CursorVisible = $true
                Write-Host ''
                Write-Host '  [TIMEOUT] Auto-selecting ALL targets for WhatIf preview...' -ForegroundColor Magenta
                return @{ Mode = 'WhatIf'; SelectedIndices = @(0..($count - 1)) }
            }

            # ---- live countdown update ----
            if ($rem -ne $lastSec) {
                $lastSec = $rem
                Render-Countdown $rem
            }

            # ---- key handling ----
            if ($host.UI.RawUI.KeyAvailable) {
                $k = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                $sw.Restart()   # reset timeout on any key

                switch ($k.VirtualKeyCode) {
                    38 {  # Up arrow
                        $cursor = if ($cursor -gt 0) { $cursor - 1 } else { $totalItems - 1 }
                        Render-Menu
                    }
                    40 {  # Down arrow
                        $cursor = if ($cursor -lt ($totalItems - 1)) { $cursor + 1 } else { 0 }
                        Render-Menu
                    }
                    32 {  # Space -- toggle
                        if ($cursor -eq 0) {
                            $ns = -not $selected[0]  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                            for ($i = 0; $i -lt $totalItems; $i++) { $selected[$i] = $ns }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                        } else {
                            $selected[$cursor] = -not $selected[$cursor]  # SIN-EXEMPT:P027 -- index access, context-verified safe
                            $allOn = $true
                            for ($i = 1; $i -lt $totalItems; $i++) {
                                if (-not $selected[$i]) { $allOn = $false; break }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                            }
                            $selected[0] = $allOn  # SIN-EXEMPT: P027 - iteration variable: always has elements inside foreach loop
                        }
                        Render-Menu
                    }
                    13 {  # Enter -- proceed with selection
                        $sel = @()
                        for ($i = 1; $i -lt $totalItems; $i++) {
                            if ($selected[$i]) { $sel += ($i - 1) }  # SIN-EXEMPT:P027 -- index access, context-verified safe
                        }
                        [Console]::CursorVisible = $true
                        return @{ Mode = 'Selected'; SelectedIndices = $sel }
                    }
                    27 {  # Escape -- abort
                        [Console]::CursorVisible = $true
                        return @{ Mode = 'Abort'; SelectedIndices = @() }
                    }
                }
            }

            Start-Sleep -Milliseconds 50
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

# ========================== BANNER ==========================
$host.UI.RawUI.WindowTitle = "PwShGUI - System Cleanup"
Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '     Script6 : System Cleanup                  ' -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Computer : $env:COMPUTERNAME"
Write-Host "  User     : $env:USERNAME"
Write-Host "  PS Ver   : $($PSVersionTable.PSVersion)"
Write-Host "  Time     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Log      : $cleanupLog"
Write-Host ''
Write-AppLog "System Cleanup launched" 'Audit'
Write-CleanupLog "=== System Cleanup Session Started ==="

# ========================== INTERACTIVE SELECTOR ==========================
$menuResult = Show-CleanupSelector -Targets $cleanupTargets

if ($menuResult.Mode -eq 'Abort' -or $menuResult.SelectedIndices.Count -eq 0) {
    Write-Host ''
    if ($menuResult.Mode -eq 'Abort') {
        Write-Host '  Aborted by user. No changes were made.' -ForegroundColor Red
        Write-CleanupLog 'User pressed ESC - cleanup aborted (no changes).' 'Event'
    } else {
        Write-Host '  No targets selected. Exiting.' -ForegroundColor Red
        Write-CleanupLog 'No targets selected - exiting (no changes).' 'Event'
    }
    Export-LogBuffer
    Write-Host ''
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 0
}

$selectedTargets = $menuResult.SelectedIndices | ForEach-Object { $cleanupTargets[$_] }  # SIN-EXEMPT:P027 -- index access, context-verified safe
$selectedNames   = ($selectedTargets | ForEach-Object { $_.Name }) -join ', '
Write-CleanupLog "Selected $($selectedTargets.Count) targets: $selectedNames"
Write-Host ''
Write-Host "  Selected $($selectedTargets.Count) of $($cleanupTargets.Count) cleanup targets." -ForegroundColor Cyan
Write-Host ''

if ($menuResult.Mode -eq 'WhatIf') {
    $choice = 'W'
    Write-Host '  Mode: WhatIf Simulation (auto-selected by timeout)' -ForegroundColor Magenta
    Write-Host ''
} else {
    Write-Host '  How would you like to proceed?' -ForegroundColor Yellow
    Write-Host '    Y  =  Run Cleanup now'
    Write-Host '    W  =  WhatIf simulation (preview only, no changes)'
    Write-Host '    Any other key = Abort'
    Write-Host ''
    Write-Host '  Press your choice... ' -NoNewline -ForegroundColor Cyan
    $key = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    $choice = $key.Character.ToString().ToUpper()
    Write-Host $choice
    Write-Host ''

    if ($choice -ne 'Y' -and $choice -ne 'W') {
        Write-Host '  Aborted. No changes were made.' -ForegroundColor Red
        Write-CleanupLog 'User aborted cleanup after selection (no changes).' 'Event'
        Export-LogBuffer
        Write-Host ''
        Write-Host '  Press any key to close...' -ForegroundColor DarkGray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 0
    }
}

# ========================== WHATIF SIMULATION ==========================
if ($choice -eq 'W') {
    Write-Host '  =============================================' -ForegroundColor Magenta
    Write-Host '     WhatIf Simulation -- Preview Only           ' -ForegroundColor Magenta
    Write-Host '  =============================================' -ForegroundColor Magenta
    Write-Host ''
    Write-CleanupLog '--- WhatIf Simulation Started ---'

    $totalWhatIfFiles = 0
    $totalWhatIfBytes = [long]0

    foreach ($t in $selectedTargets) {
        Write-Host "  [$($t.Name)]" -ForegroundColor Yellow

        if ($t.Action -eq 'FlushDNS') {
            Write-Host '    WhatIf: Would flush DNS resolver cache' -ForegroundColor Gray
            Write-CleanupLog "WhatIf: $($t.Name) -- flush DNS cache"
        }
        elseif ($t.Action -eq 'EmptyRecycleBin') {
            Write-Host '    WhatIf: Would empty the Recycle Bin on all drives' -ForegroundColor Gray
            Write-CleanupLog "WhatIf: $($t.Name) -- empty Recycle Bin"
        }
        else {
            $items = Get-TargetItems -Target $t
            $fileCount = ($items | Where-Object { $_ -is [System.IO.FileInfo] }).Count
            $dirCount  = ($items | Where-Object { $_ -is [System.IO.DirectoryInfo] }).Count
            $totalSize = ($items | Where-Object { $_ -is [System.IO.FileInfo] } | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $totalSize) { $totalSize = 0 }
            $sizeStr = Format-FileSize $totalSize

            $totalWhatIfFiles += $fileCount
            $totalWhatIfBytes += $totalSize

            if ($fileCount -eq 0 -and $dirCount -eq 0) {
                Write-Host '    (empty / not found)' -ForegroundColor DarkGray
            } else {
                Write-Host "    WhatIf: Would remove $fileCount files, $dirCount folders ($sizeStr)" -ForegroundColor Gray
                # Show up to 10 sample paths
                $sample = $items | Select-Object -First 10
                foreach ($s in $sample) {
                    $relPath = $s.FullName
                    $sz = if ($s -is [System.IO.FileInfo]) { " ($(Format-FileSize $s.Length))" } else { ' [dir]' }
                    Write-Host "      - $relPath$sz" -ForegroundColor DarkGray
                }
                if ($items.Count -gt 10) {
                    Write-Host "      ... and $($items.Count - 10) more items" -ForegroundColor DarkGray
                }
            }
            Write-CleanupLog "WhatIf: $($t.Name) -- $fileCount files, $dirCount dirs, $sizeStr"
        }
        Write-Host ''
    }

    $totalStr = Format-FileSize $totalWhatIfBytes
    Write-Host "  TOTAL estimated: $totalWhatIfFiles files, $totalStr" -ForegroundColor Cyan
    Write-CleanupLog "WhatIf Total: $totalWhatIfFiles files, $totalStr"
    Write-Host ''

    # After WhatIf -- ask to proceed for real
    Write-Host '  =============================================' -ForegroundColor Yellow
    Write-Host '  Do you now want to really run this System'     -ForegroundColor Yellow
    Write-Host '  Cleanup for real real?  (Y = Yes / N = No)'    -ForegroundColor Yellow
    Write-Host '  =============================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Press your choice... ' -NoNewline -ForegroundColor Cyan
    $key2 = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    $choice2 = $key2.Character.ToString().ToUpper()
    Write-Host $choice2
    Write-Host ''

    if ($choice2 -ne 'Y') {
        Write-Host '  Aborted after WhatIf preview. No changes were made.' -ForegroundColor Red
        Write-CleanupLog 'User aborted after WhatIf preview (no changes).' 'Event'
        Export-LogBuffer
        Write-Host ''
        Write-Host '  Press any key to close...' -ForegroundColor DarkGray
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 0
    }

    Write-Host '  Proceeding with real cleanup...' -ForegroundColor Green
    Write-CleanupLog 'User confirmed real cleanup after WhatIf.'
    Write-Host ''
}

# ========================== REAL EXECUTION ==========================
Write-Host '  =============================================' -ForegroundColor Green
Write-Host '     Executing System Cleanup                   ' -ForegroundColor Green
Write-Host '  =============================================' -ForegroundColor Green
Write-Host ''
Write-CleanupLog '=== Real Cleanup Execution Started ==='

$allResults   = @()
$totalRemoved = 0
$totalFreed   = [long]0
$totalErrors  = 0
$stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($t in $selectedTargets) {
    Write-Host "  [$($t.Name)]..." -NoNewline -ForegroundColor Yellow
    Write-CleanupLog "Cleaning: $($t.Name)"

    $result = Invoke-CleanupTarget -Target $t
    $allResults += $result

    $totalRemoved += $result.FilesRemoved
    $totalFreed   += $result.BytesFreed
    $totalErrors  += $result.Errors.Count

    if ($result.Errors.Count -eq 0) {
        Write-Host ' Done' -ForegroundColor Green
    } else {
        Write-Host " Done ($($result.Errors.Count) skipped)" -ForegroundColor DarkYellow
    }
}

$stopwatch.Stop()
Write-Host ''
Write-CleanupLog '=== Real Cleanup Execution Finished ==='

# ========================== SUMMARY ==========================
$freedStr   = Format-FileSize $totalFreed
$elapsed    = $stopwatch.Elapsed.ToString('mm\:ss')

Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '     CLEANUP SUMMARY                            ' -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Targets run   : $($selectedTargets.Count) of $($cleanupTargets.Count)"
Write-Host "  Items removed  : $totalRemoved"
Write-Host "  Space freed    : $freedStr"
Write-Host "  Errors/Skipped : $totalErrors"
Write-Host "  Elapsed time   : $elapsed"
Write-Host ''
Write-Host '  Changed areas:' -ForegroundColor Yellow
foreach ($r in $allResults) {
    if ($r.FilesRemoved -gt 0 -or ($r.Name -in @('DNS Resolver Cache','Recycle Bin'))) {
        $sizeNote = if ($r.BytesFreed -gt 0) { " ($(Format-FileSize $r.BytesFreed))" } else { '' }
        Write-Host ("    - {0}: {1} items removed{2}" -f $r.Name, $r.FilesRemoved, $sizeNote) -ForegroundColor Green
    }
}

$skippedAreas = $allResults | Where-Object { $_.FilesRemoved -eq 0 -and $_.Name -notin @('DNS Resolver Cache','Recycle Bin') }
if ($skippedAreas) {
    Write-Host ''
    Write-Host '  Unchanged / empty areas:' -ForegroundColor DarkGray
    foreach ($s in $skippedAreas) {
        Write-Host ("    - {0}" -f $s.Name) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host "  Full log: $cleanupLog" -ForegroundColor Cyan
Write-Host ''

Write-CleanupLog "Summary: $($selectedTargets.Count)/$($cleanupTargets.Count) targets, $totalRemoved items removed, $freedStr freed, $totalErrors errors, $elapsed elapsed"
Export-LogBuffer

# ========================== AUTO-CLOSE ==========================
Write-Host '  Window will close in 15 seconds (or press any key)...' -ForegroundColor DarkGray
$countdown = 15
$endTime   = (Get-Date).AddSeconds($countdown)
while ((Get-Date) -lt $endTime) {
    if ($host.UI.RawUI.KeyAvailable) {
        $null = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        break
    }
    Start-Sleep -Milliseconds 500
}
exit 0





















<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





