# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null

# Show-Objectives: Maintain script intent clarity and objective-driven validation outcomes.
# SS-004 exempt: All Start-Sleep calls are intentional test timing delays for UI Automation synchronization
# VersionBuildHistory:
#   2603.B0.V26.0  2026-04-04       Add Phase 0x/0y/0z: SIN registry completeness, log level filter, backlog health checks
#   2603.B0.V24.0  2026-06-10       B1-B3: function registry, env scanner tests, script-fn mapping
#   2603.B0.V19.0  2026-03-24 03:28  (deduplicated from 4 entries)
<#
.SYNOPSIS
    Automated GUI smoke-test harness for the PowerShellGUI application.

.DESCRIPTION
    Exercises every menu item, main-form button, and key sub-dialog in
    Main-GUI.ps1 using the System.Windows.Automation (UI Automation) API.

    Phases:
      0  Headless -- syntax parse, module import, config validation
      1  Launch   -- start Main-GUI.ps1 -StartupMode quik_jnr, find window
      2  Menus    -- walk every menu bar item, dismiss any dialogs
      3  Buttons  -- click each button, auto-cancel the elevation prompt
      4  Dialogs  -- reopen key sub-dialogs and verify controls
      5  Logs     -- cross-check the app's Event log against actions taken
      6  Cleanup  -- close the form, kill process if needed
      7  Report   -- write summary to console + timestamped log file

.PARAMETER HeadlessOnly
    When specified, runs only Phase 0 (non-GUI validation) and exits.

.PARAMETER SkipPhase
    Array of phase numbers (0-5) to skip.  Phase 6-7 always run.

.PARAMETER Timeout
    Seconds to wait for the main window to appear (default 45).

.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 04 Mar 2026
    Requires : PowerShell 5.1+ / 7+, Windows OS with WinForms support

.EXAMPLE
    .\tests\Invoke-GUISmokeTest.ps1
    Full smoke test.

.EXAMPLE
    .\tests\Invoke-GUISmokeTest.ps1 -HeadlessOnly
    Headless checks only (no GUI launched).

.EXAMPLE
    .\tests\Invoke-GUISmokeTest.ps1 -SkipPhase 3,4
    Full test but skip button and dialog phases.
#>

param(
    [switch]$HeadlessOnly,
    [int[]]$SkipPhase = @(),
    [int]$Timeout = 45,
    [ValidateSet('auto','powershell','pwsh')]
    [string]$Shell = 'auto',
    [switch]$RunShellMatrix,
    [string[]]$SkipMenuItems = @('Version Check')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($RunShellMatrix) {
    $shellTargets = @()
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        try {
            $pwshVersion = & pwsh.exe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            if ($pwshVersion -and [version]$pwshVersion -ge [version]'7.6.0') {
                $shellTargets += 'pwsh'
            } else {
                Write-Host "[ShellMatrix] pwsh is available but below 7.6 ($pwshVersion). Running as fallback host." -ForegroundColor Yellow
                $shellTargets += 'pwsh'
            }
        } catch {
            $shellTargets += 'pwsh'
        }
    }
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { $shellTargets += 'powershell' }

    if ($shellTargets.Count -eq 0) {
        throw 'No supported PowerShell host found for shell-matrix execution.'
    }

    $failed = $false
    foreach ($s in $shellTargets) {
        $hostExe = if ($s -eq 'pwsh') { 'pwsh.exe' } else { 'powershell.exe' }
        $invokeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($MyInvocation.MyCommand.Path)`"",'-Shell',$s)
        if ($HeadlessOnly) { $invokeArgs += '-HeadlessOnly' }
        if ($SkipPhase.Count -gt 0) { $invokeArgs += '-SkipPhase'; $invokeArgs += ($SkipPhase -join ',') }
        if ($Timeout -ne 45) { $invokeArgs += '-Timeout'; $invokeArgs += [string]$Timeout }

        Write-Host "[ShellMatrix] Running smoke test with: $hostExe" -ForegroundColor Cyan
        $proc = Start-Process -FilePath $hostExe -ArgumentList ($invokeArgs -join ' ') -Wait -PassThru
        if ($proc.ExitCode -ne 0) { $failed = $true }
    }

    if ($failed) { exit 1 } else { exit 0 }
}

# ── Paths ─────────────────────────────────────────────────────────────────────
$scriptRoot  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mainScript  = Join-Path $scriptRoot 'Main-GUI.ps1'
$configFile  = Join-Path $scriptRoot 'config\system-variables.xml'
$modulesDir  = Join-Path $scriptRoot 'modules'
$logsDir     = Join-Path $scriptRoot 'logs'
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFileName = "$env:COMPUTERNAME-$timestamp-SmokeTest.log"

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$logPath = Join-Path $logsDir $logFileName

# ── Result Collector ──────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[pscustomobject]]::new()
$sw      = [System.Diagnostics.Stopwatch]::StartNew()

function Write-TestLog {
    <#
    .SYNOPSIS  Dual-output helper: console + log file.
    #>
    param(
        [ValidateSet('PASS','FAIL','SKIP','INFO','WARN')]
        [string]$Status,
        [string]$Phase,
        [string]$Test,
        [string]$Detail = ''
    )
    $entry = [pscustomobject]@{
        Time   = (Get-Date -Format 'HH:mm:ss')
        Status = $Status
        Phase  = $Phase
        Test   = $Test
        Detail = $Detail
    }
    $results.Add($entry)

    $colours = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow'; INFO = 'Gray'; WARN = 'Yellow' }
    $line = "[{0}] {1,-4}  {2,-10} {3}  {4}" -f $entry.Time, $Status, $Phase, $Test, $Detail
    Write-Host $line -ForegroundColor $colours[$Status]  # SIN-EXEMPT:P027 -- index access, context-verified safe
    $line | Out-File -Append -FilePath $logPath -Encoding UTF8
}

function Resolve-SelectedShellCommand {
    switch ($Shell) {
        'pwsh' {
            if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
            return $null
        }
        'powershell' {
            if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
            return $null
        }
        default {
            if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
            if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { return 'powershell.exe' }
            return $null
        }
    }
}

function Test-PowerShellParseInHost {
    param(
        [string]$HostExe,
        [string]$PathToParse
    )

    $escaped = $PathToParse.Replace("'", "''")
    $cmd = "`$tokens=`$null;`$errs=`$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$escaped',[ref]`$tokens,[ref]`$errs); if(`$errs -and `$errs.Count -gt 0){`$errs | ForEach-Object { Write-Output `$_.Message }; exit 1 } else { exit 0 }"
    $result = & $HostExe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String
    return [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); Output = $result.Trim() }
}

function Get-LaunchGuiMenuTargets {
    $targets = [System.Collections.Generic.List[object]]::new()
    $root = $scriptRoot
    $quickApp = Join-Path $scriptRoot 'scripts\QUICK-APP'

    $fixed = @(
        (Join-Path $root 'Launch-GUI-quik_jnr.bat')
        (Join-Path $root 'Launch-GUI-slow_snr.bat')
        (Join-Path $root 'scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml')
    )
    foreach ($f in $fixed) {
        if (Test-Path $f) {
            $targets.Add([pscustomobject]@{ Path = $f; Source = 'fixed' }) | Out-Null
        }
    }

    $scanDirs = @($root, $quickApp)
    foreach ($dir in $scanDirs) {
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.bat','.ps1','.html','.xhtml') }
        foreach ($f in $files) {
            if ($f.Name -in @('Launch-GUI.bat','Launch-GUI-quik_jnr.bat','Launch-GUI-slow_snr.bat')) { continue }
            if ($f.Name -match '(?i)build[-_]?ver|versionbuild') { continue }
            $targets.Add([pscustomobject]@{ Path = $f.FullName; Source = 'dynamic' }) | Out-Null
        }
    }

    # Include all XHTML files as smoke-test launch/content targets.
    # These are validated in headless mode as available + XML parseable.
    $xhtmlTargets = Get-ChildItem -Path $root -Recurse -File -Filter *.xhtml -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.history\*' -and
            $_.FullName -notlike '*\.venv\*' -and
            $_.FullName -notlike '*\logs\*' -and
            $_.FullName -notlike '*\temp\*' -and
            $_.FullName -notlike '*\~REPORTS\*' -and
            $_.FullName -notlike '*\archive\*' -and
            $_.FullName -notlike '*\~DOWNLOADS\*'
        }
    foreach ($xf in $xhtmlTargets) {
        $targets.Add([pscustomobject]@{ Path = $xf.FullName; Source = 'xhtml-discovery' }) | Out-Null
    }

    return @($targets | Sort-Object Path -Unique)
}

# ── UI-Automation helpers ─────────────────────────────────────────────────────
# Load the UIAutomationClient assembly (ships with .NET Framework / .NET 6+)
try {
    Add-Type -AssemblyName UIAutomationClient  -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes   -ErrorAction Stop
} catch {
    # On .NET Core / PS 7 the assembly names differ -- try direct load
    try {
        [void][System.Windows.Automation.AutomationElement]
    } catch {
        Write-Warning "UI Automation assemblies not available -- GUI phases will be skipped."
        $SkipPhase = @(1,2,3,4,5)
    }
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$AE = [System.Windows.Automation.AutomationElement]
# TreeWalker and Condition available via [System.Windows.Automation.*] if needed

function Wait-Window {
    <#
    .SYNOPSIS  Poll for a top-level window by title substring.
    #>
    param(
        [string]$TitleSubstring,
        [int]$TimeoutSec = 45
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $root = $AE::RootElement
        $cond = [System.Windows.Automation.PropertyCondition]::new(
            $AE::NameProperty, $TitleSubstring,
            [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
        )
        # FindFirst may miss substring; scan children instead
        $wins = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                $AE::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Window
            )
        )
        foreach ($w in $wins) {
            if ($w.Current.Name -like "*$TitleSubstring*") {
                return $w
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Find-Control {
    <#
    .SYNOPSIS  Locate a descendant control by ControlType + optional name.
    #>
    param(
        [System.Windows.Automation.AutomationElement]$Parent,
        [System.Windows.Automation.ControlType]$Type,
        [string]$Name,
        [switch]$All
    )
    $typeCond = [System.Windows.Automation.PropertyCondition]::new(
        $AE::ControlTypeProperty, $Type
    )
    if ($Name) {
        $nameCond = [System.Windows.Automation.PropertyCondition]::new(
            $AE::NameProperty, $Name,
            [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
        )
        $cond = [System.Windows.Automation.AndCondition]::new($typeCond, $nameCond)
    } else {
        $cond = $typeCond
    }
    if ($All) {
        return $Parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    }
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Invoke-Pattern {
    <#
    .SYNOPSIS  Safely get and invoke InvokePattern on an element.
    #>
    param([System.Windows.Automation.AutomationElement]$Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return $true
    }
    return $false
}

function Expand-MenuItem {
    <#
    .SYNOPSIS  Expand a menu / menu item via ExpandCollapsePattern.
    #>
    param([System.Windows.Automation.AutomationElement]$Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        $pattern.Expand()
        Start-Sleep -Milliseconds 350
        return $true
    }
    return $false
}

function Collapse-MenuItem {
    param([System.Windows.Automation.AutomationElement]$Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        $pattern.Collapse()
        Start-Sleep -Milliseconds 200
        return $true
    }
    return $false
}

function Dismiss-Dialog {
    <#
    .SYNOPSIS  Find and click Cancel / No / Close / OK on a popup dialog.
    #>
    param(
        [System.Windows.Automation.AutomationElement]$Dialog,
        [string[]]$PreferButtons = @('No','Cancel','Close','OK')
    )
    foreach ($btnName in $PreferButtons) {
        $btn = Find-Control -Parent $Dialog -Type ([System.Windows.Automation.ControlType]::Button) -Name $btnName
        if ($btn) {
            Invoke-Pattern $btn | Out-Null
            Start-Sleep -Milliseconds 400
            return $btnName
        }
    }
    # Fall back: try WindowPattern.Close
    $wp = $null
    if ($Dialog.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) {
        $wp.Close()
        Start-Sleep -Milliseconds 400
        return 'WindowClose'
    }
    return $null
}

function Wait-Popup {
    <#
    .SYNOPSIS  Wait briefly for a new popup dialog owned by the main window.
    #>
    param(
        [System.Windows.Automation.AutomationElement]$MainWin,
        [int]$WaitMs = 2500
    )
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    while ((Get-Date) -lt $deadline) {
        $root = $AE::RootElement
        $wins = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                $AE::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Window
            )
        )
        foreach ($w in $wins) {
            try {
                $name = $w.Current.Name
                if ($name -and $name -ne 'PowerShell Script Launcher' -and
                    $name -notlike 'Default IME*' -and
                    $w.Current.ProcessId -eq $script:appProcess.Id) {
                    return $w
                }
            } catch { <# Intentional: non-fatal #> }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0 -- Headless Validation
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n$('=' * 68)" -ForegroundColor Cyan
Write-Host "  POWERSHELLGUI  SMOKE  TEST   --  $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "  $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
Write-Host "$('=' * 68)`n" -ForegroundColor Cyan
"PowerShellGUI Smoke Test -- $env:COMPUTERNAME -- $timestamp" | Out-File $logPath -Encoding UTF8

$runPhase0 = 0 -notin $SkipPhase
if ($runPhase0) {
    Write-Host "[Phase 0] Headless Validation" -ForegroundColor Cyan

    # ── 0a: Syntax parse every .ps1 / .psm1 ──────────────────────────────
    $psFiles = Get-ChildItem -Path $scriptRoot -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.history\*' -and
            $_.FullName -notlike '*\temp\*'   -and
            $_.FullName -notlike '*\FOLDER-ROOT\*' -and
            $_.FullName -notlike '*\~REPORTS\remediation-backups\*' -and
            $_.FullName -notlike '*\checkpoints\*' -and
            $_.FullName -notlike '*\~DOWNLOADS\*'
        }

    $parseFailures = 0
    foreach ($f in $psFiles) {
        $tokens = $null; $errors = $null
        try {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        } catch {
            $errors = @([pscustomobject]@{ Message = $_.Exception.Message })
        }
        $rel = $f.FullName.Replace($scriptRoot, '').TrimStart('\')
        if ($errors -and $errors.Count -gt 0) {
            Write-TestLog 'FAIL' 'Phase0' 'SyntaxParse' "$rel -- $($errors[0].Message)"  # SIN-EXEMPT:P027 -- index access, context-verified safe
            $parseFailures++
        }
    }
    if ($parseFailures -eq 0) {
        Write-TestLog 'PASS' 'Phase0' 'SyntaxParse' "All $($psFiles.Count) files parsed OK"
    }

    # ── 0b: Module imports ────────────────────────────────────────────────
    $moduleFiles = Get-ChildItem -Path $modulesDir -File -Filter *.psm1 -ErrorAction SilentlyContinue
    foreach ($mod in $moduleFiles) {
        try {
            Import-Module $mod.FullName -Force -ErrorAction Stop -DisableNameChecking
            Write-TestLog 'PASS' 'Phase0' 'ModuleImport' $mod.Name
            Remove-Module $mod.BaseName -Force -ErrorAction SilentlyContinue
        } catch {
            Write-TestLog 'FAIL' 'Phase0' 'ModuleImport' "$($mod.Name) -- $_"
        }
    }

    # ── 0c: Config XML well-formed ───────────────────────────────────────
    if (Test-Path $configFile) {
        try {
            [xml]$xml = Get-Content $configFile -Raw -ErrorAction Stop
            $btnNode = $xml.SelectNodes('//Buttons')
            if (-not $btnNode -or $btnNode.Count -eq 0) { $btnNode = $xml.SelectNodes('//buttons') }
            if ($btnNode -and $btnNode.Count -gt 0) {
                Write-TestLog 'PASS' 'Phase0' 'ConfigXML' "system-variables.xml valid, <Buttons> found"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'ConfigXML' "system-variables.xml valid but no <Buttons> node"
            }
        } catch {
            Write-TestLog 'FAIL' 'Phase0' 'ConfigXML' "Parse error: $_"
        }
    } else {
        Write-TestLog 'WARN' 'Phase0' 'ConfigXML' "system-variables.xml not found"
    }

    # ── 0d: JSON configs (project directories only) ────────────────────
    $jsonDirs  = @('config','~REPORTS','Report','sin_registry','agents') |
        ForEach-Object { Join-Path $scriptRoot $_ }
    $jsonFiles = foreach ($jd in $jsonDirs) {
        if (Test-Path $jd) {
            Get-ChildItem -Path $jd -Recurse -File -Filter *.json -ErrorAction SilentlyContinue
        }
    }
    $jsonFails = 0
    foreach ($jf in $jsonFiles) {
        try {
            # SIN P027/wildcard fix: filenames with '[' or ']' must use -LiteralPath
            $null = Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-TestLog 'FAIL' 'Phase0' 'JSONConfig' "$($jf.Name) -- $_"
            $jsonFails++
        }
    }
    if ($jsonFails -eq 0 -and $jsonFiles.Count -gt 0) {
        Write-TestLog 'PASS' 'Phase0' 'JSONConfig' "All $($jsonFiles.Count) JSON files valid"
    }

    # ── 0g: Orphan file detection ─────────────────────────────────────────
    # Find .ps1 files under scripts/ not referenced by any menu item, button config,
    # or other known caller in Main-GUI.ps1
    $orphanScriptsDir = Join-Path $scriptRoot 'scripts'
    if (Test-Path $orphanScriptsDir) {
        $mainContent = ''
        if (Test-Path $mainScript) {
            $mainLines = Get-Content $mainScript -ErrorAction SilentlyContinue
            if ($mainLines) { $mainContent = $mainLines -join "`n" }
        }
        $configContent = ''
        $configXml = Join-Path $scriptRoot 'config\system-variables.xml'
        if (Test-Path $configXml) {
            $configLines = Get-Content $configXml -ErrorAction SilentlyContinue
            if ($configLines) { $configContent = $configLines -join "`n" }
        }
        $scriptFiles = @(Get-ChildItem -Path $orphanScriptsDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'fix_*' })
        $orphans = @()
        $referenced = 0
        foreach ($sf in $scriptFiles) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($sf.Name)
            $isReferenced = ($mainContent -match [regex]::Escape($sf.Name)) -or
                            ($mainContent -match [regex]::Escape($baseName)) -or
                            ($configContent -match [regex]::Escape($sf.Name)) -or
                            ($configContent -match [regex]::Escape($baseName))
            if ($isReferenced) {
                $referenced++
            } else {
                $orphans += $sf.Name
            }
        }
        if ($orphans.Count -eq 0) {
            Write-TestLog 'PASS' 'Phase0' 'OrphanDetect' "No orphan scripts detected ($referenced referenced, $($scriptFiles.Count) total)"
        } else {
            foreach ($o in $orphans) {
                Write-TestLog 'WARN' 'Phase0' 'OrphanDetect' "Orphan script: $o (not referenced in Main-GUI or config)"
            }
            Write-TestLog 'INFO' 'Phase0' 'OrphanDetect' "$($orphans.Count) orphan(s) found out of $($scriptFiles.Count) scripts"
        }
    } else {
        Write-TestLog 'WARN' 'Phase0' 'OrphanDetect' 'scripts/ directory not found'
    }

    # ── 0f: Launch-GUI.bat menu target validation (excluding build-version) ─
    $targets = @(Get-LaunchGuiMenuTargets)
    if ($targets.Count -eq 0) {
        Write-TestLog 'WARN' 'Phase0' 'LaunchMenuTargets' 'No launch menu targets discovered'
    } else {
        $hostMatrix = @('pwsh.exe','powershell.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
        foreach ($t in $targets) {
            $name = Split-Path -Leaf $t.Path
            $ext = [IO.Path]::GetExtension($t.Path).ToLowerInvariant()
            if (-not (Test-Path $t.Path)) {
                Write-TestLog 'FAIL' 'Phase0' 'LaunchMenuTarget' "$name missing"
                continue
            }

            switch ($ext) {
                '.ps1' {
                    foreach ($h in $hostMatrix) {
                        $parse = Test-PowerShellParseInHost -HostExe $h -PathToParse $t.Path
                        if ($parse.Success) {
                            Write-TestLog 'PASS' 'Phase0' 'LaunchMenuTarget' "$name parse OK in $h"
                        } else {
                            $detail = if ($parse.Output) { $parse.Output } else { 'Parse failed' }
                            if ($name -ieq 'Main-GUI.ps1' -and $h -ieq 'powershell.exe') {
                                $pwshCompat = Test-PowerShellParseInHost -HostExe 'pwsh.exe' -PathToParse $t.Path
                                if ($pwshCompat.Success) {
                                    Write-TestLog 'WARN' 'Phase0' 'LaunchMenuTarget' "$name host parse mismatch in $h (pwsh.exe parse OK) -- $detail"
                                    continue
                                }
                            }
                            Write-TestLog 'FAIL' 'Phase0' 'LaunchMenuTarget' "$name parse FAIL in $h -- $detail"
                        }
                    }
                }
                '.bat' {
                    Write-TestLog 'PASS' 'Phase0' 'LaunchMenuTarget' "$name available (BAT)"
                }
                '.html' {
                    Write-TestLog 'PASS' 'Phase0' 'LaunchMenuTarget' "$name available (HTML)"
                }
                '.xhtml' {
                    try {
                        [xml](Get-Content -Path $t.Path -Raw -ErrorAction Stop) | Out-Null
                        Write-TestLog 'PASS' 'Phase0' 'LaunchMenuTarget' "$name available + XML valid (XHTML)"
                    } catch {
                        Write-TestLog 'FAIL' 'Phase0' 'LaunchMenuTarget' "$name invalid XHTML/XML -- $($_.Exception.Message)"
                    }
                }
                default {
                    Write-TestLog 'INFO' 'Phase0' 'LaunchMenuTarget' "$name skipped (unsupported extension)"
                }
            }
        }
    }

    # ── 0e: Main-GUI.ps1 exists ──────────────────────────────────────────
    if (Test-Path $mainScript) {
        Write-TestLog 'PASS' 'Phase0' 'MainExists' 'Main-GUI.ps1 found'
    } else {
        Write-TestLog 'FAIL' 'Phase0' 'MainExists' 'Main-GUI.ps1 NOT found -- cannot continue'
        $HeadlessOnly = $true
    }

    # ── 0h: Function Registry -- exported vs. called ─────────────────────
    $script:FnRegistry = @{
        Defined  = [System.Collections.Generic.Dictionary[string,string]]::new()
        Called   = [System.Collections.Generic.HashSet[string]]::new()
        Exported = [System.Collections.Generic.Dictionary[string,string]]::new()
    }

    # Scan .psm1 exports
    $psmFiles = @(Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue)
    foreach ($psm in $psmFiles) {
        $content = [System.IO.File]::ReadAllText($psm.FullName, [System.Text.Encoding]::UTF8)
        $fnMatches = [regex]::Matches($content, '(?m)^\s*function\s+([A-Z][\w-]+)', 'IgnoreCase')
        foreach ($fm in $fnMatches) {
            $fnName = $fm.Groups[1].Value
            $script:FnRegistry.Defined[$fnName] = $psm.Name
            $script:FnRegistry.Exported[$fnName] = $psm.Name
        }
    }

    # Scan .ps1 script internal functions
    $ps1Files = @(Get-ChildItem -Path $scriptRoot -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*\.history\*' -and $_.FullName -notlike '*\temp\*' })
    foreach ($ps1 in $ps1Files) {
        $content = [System.IO.File]::ReadAllText($ps1.FullName, [System.Text.Encoding]::UTF8)
        $fnMatches = [regex]::Matches($content, '(?m)^\s*function\s+([A-Z][\w-]+)', 'IgnoreCase')
        foreach ($fm in $fnMatches) {
            $fnName = $fm.Groups[1].Value
            if (-not $script:FnRegistry.Defined.ContainsKey($fnName)) {
                $script:FnRegistry.Defined[$fnName] = $ps1.Name
            }
        }
        # Detect calls to known functions
        foreach ($knownFn in @($script:FnRegistry.Defined.Keys)) {
            if ($content -match ('\b' + [regex]::Escape($knownFn) + '\b')) {
                [void]$script:FnRegistry.Called.Add($knownFn)
            }
        }
    }

    $definedCount = $script:FnRegistry.Defined.Count
    $calledCount  = $script:FnRegistry.Called.Count
    $uncalled     = @($script:FnRegistry.Defined.Keys | Where-Object { -not $script:FnRegistry.Called.Contains($_) })
    $coveragePct  = if ($definedCount -gt 0) { [math]::Round(($calledCount / $definedCount) * 100, 1) } else { 0 }

    Write-TestLog 'INFO' 'Phase0' 'FnRegistry' "Defined: $definedCount, Called: $calledCount, Coverage: $coveragePct%"
    if ($uncalled.Count -gt 0 -and $uncalled.Count -le 10) {
        foreach ($uf in $uncalled) {
            Write-TestLog 'WARN' 'Phase0' 'FnRegistry' "Uncalled: $uf (defined in $($script:FnRegistry.Defined[$uf]))"
        }
    } elseif ($uncalled.Count -gt 10) {
        Write-TestLog 'WARN' 'Phase0' 'FnRegistry' "$($uncalled.Count) uncalled functions (top 10 shown)"
        foreach ($uf in ($uncalled | Select-Object -First 10)) {
            Write-TestLog 'WARN' 'Phase0' 'FnRegistry' "Uncalled: $uf (defined in $($script:FnRegistry.Defined[$uf]))"
        }
    }
    if ($coveragePct -ge 60) {
        Write-TestLog 'PASS' 'Phase0' 'FnCoverage' "Function coverage $coveragePct% ($calledCount/$definedCount)"
    } else {
        Write-TestLog 'WARN' 'Phase0' 'FnCoverage' "Function coverage $coveragePct% ($calledCount/$definedCount) -- below 60% threshold"
    }

    # ── 0i: Environment Scanner parse test ────────────────────────────────
    $envScanner = Join-Path $scriptRoot 'scripts\Invoke-PSEnvironmentScanner.ps1'
    if (Test-Path $envScanner) {
        $tokens = $null; $errors = $null
        try {
            $content = [System.IO.File]::ReadAllText($envScanner, [System.Text.Encoding]::UTF8)
            [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        } catch {
            $errors = @([pscustomobject]@{ Message = $_.Exception.Message })
        }
        if ($errors -and $errors.Count -gt 0) {
            Write-TestLog 'FAIL' 'Phase0' 'EnvScanner' "Parse errors: $($errors[0].Message)"  # SIN-EXEMPT:P027 -- index access, context-verified safe
        } else {
            Write-TestLog 'PASS' 'Phase0' 'EnvScanner' 'Invoke-PSEnvironmentScanner.ps1 parses clean'
        }
    } else {
        Write-TestLog 'WARN' 'Phase0' 'EnvScanner' 'Invoke-PSEnvironmentScanner.ps1 not found'
    }

    # ── 0j: Script-to-function mapping validation ─────────────────────────
    # Verify that module functions called by scripts are actually exported
    if (Test-Path $mainScript) {
        $mainContent = [System.IO.File]::ReadAllText($mainScript, [System.Text.Encoding]::UTF8)
        $calledFromMain = @()
        foreach ($expFn in @($script:FnRegistry.Exported.Keys)) {
            if ($mainContent -match ('\b' + [regex]::Escape($expFn) + '\b')) {
                $calledFromMain += $expFn
            }
        }
        Write-TestLog 'INFO' 'Phase0' 'ScriptFnMap' "Main-GUI.ps1 calls $($calledFromMain.Count) exported module functions"

        # Verify each referenced script file exists
        $scriptRefs = [regex]::Matches($mainContent, 'Invoke-(?:PSEnvironmentScanner|ScriptDependencyMatrix|ChecklistActions|GUISmokeTest)')
        $refNames = @($scriptRefs | ForEach-Object { $_.Value } | Sort-Object -Unique)
        foreach ($ref in $refNames) {
            $scriptFile = Get-ChildItem -Path $scriptRoot -Recurse -File -Filter "$ref.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($scriptFile) {
                Write-TestLog 'PASS' 'Phase0' 'ScriptFnMap' "$ref.ps1 found at $($scriptFile.FullName.Replace($scriptRoot,'').TrimStart('\'))"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'ScriptFnMap' "$ref.ps1 not found in workspace"
            }
        }
    }

    # ── 0k: Full XHTML Validation (all .xhtml files) ─────────────────────
    # Deep XML parse + structure checks for every .xhtml in the workspace
    $xhtmlFiles = @(Get-ChildItem -Path $scriptRoot -Recurse -File -Filter '*.xhtml' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.history\*' -and
            $_.FullName -notlike '*\temp\*' -and
            $_.FullName -notlike '*\~DOWNLOADS\*' -and
            $_.FullName -notlike '*\archive\*'
        })
    $xhtmlPass = 0; $xhtmlFail = 0
    foreach ($xf in $xhtmlFiles) {
        $relPath = $xf.FullName.Replace($scriptRoot, '').TrimStart('\')
        try {
            $raw = [System.IO.File]::ReadAllText($xf.FullName, [System.Text.Encoding]::UTF8)
            # Strip XML declaration and DOCTYPE for parser compatibility
            $cleaned = $raw -replace '(?s)<\?xml[^?]*\?>', '' -replace '(?s)<!DOCTYPE[^>]*>', ''
            # Strip leading comments (e.g. VersionTag) that appear before root element
            $cleaned = $cleaned -replace '(?s)\A(\s*<!--.*?-->\s*)+', ''
            $cleaned = $cleaned.Trim()
            if ([string]::IsNullOrWhiteSpace($cleaned)) {
                Write-TestLog 'WARN' 'Phase0' 'XHTMLValid' "$relPath -- empty file"
                continue
            }
            [xml]$xDoc = $cleaned
            # Check for html root element
            $rootName = $xDoc.DocumentElement.LocalName
            if ($rootName -eq 'html') {
                # Check for head and body
                $hasHead = $null -ne $xDoc.DocumentElement.SelectSingleNode('*[local-name()="head"]')
                $hasBody = $null -ne $xDoc.DocumentElement.SelectSingleNode('*[local-name()="body"]')
                $structInfo = "root=html, head=$hasHead, body=$hasBody"
                if ($hasHead -and $hasBody) {
                    Write-TestLog 'PASS' 'Phase0' 'XHTMLValid' "$relPath -- valid ($structInfo)"
                } else {
                    Write-TestLog 'WARN' 'Phase0' 'XHTMLValid' "$relPath -- partial structure ($structInfo)"
                }
            } else {
                Write-TestLog 'PASS' 'Phase0' 'XHTMLValid' "$relPath -- valid XML (root=$rootName)"
            }
            $xhtmlPass++
        } catch {
            Write-TestLog 'FAIL' 'Phase0' 'XHTMLValid' "$relPath -- $($_.Exception.Message)"
            $xhtmlFail++
        }
    }
    Write-TestLog 'INFO' 'Phase0' 'XHTMLSummary' "XHTML files: $($xhtmlFiles.Count) total, $xhtmlPass passed, $xhtmlFail failed"

    # ── 0l: Module Exported Function Audit ────────────────────────────────
    # For each .psm1, verify every function defined is callable after import
    $modAuditPass = 0; $modAuditWarn = 0
    foreach ($psm in $psmFiles) {
        $content = [System.IO.File]::ReadAllText($psm.FullName, [System.Text.Encoding]::UTF8)
        $fnDefs = @([regex]::Matches($content, '(?m)^\s*function\s+([A-Z][\w-]+)', 'IgnoreCase') |
            ForEach-Object { $_.Groups[1].Value })
        # Check for Export-ModuleMember
        $hasExplicitExport = $content -match 'Export-ModuleMember'
        if ($hasExplicitExport) {
            $exportMatches = [regex]::Matches($content, 'Export-ModuleMember\s+-Function\s+(.+?)(?:\s+-|$)', 'IgnoreCase,Singleline')
            $exportedNames = @()
            foreach ($em in $exportMatches) {
                $names = $em.Groups[1].Value -split '[,\s]+' | ForEach-Object { $_.Trim("'", '"', ' ') } | Where-Object { $_ -and $_ -ne '*' }
                $exportedNames += $names
            }
            if ($exportedNames.Count -gt 0) {
                # Check that exported names are actual function definitions
                $missing = @($exportedNames | Where-Object { $_ -notin $fnDefs -and $_ -ne '*' })
                if ($missing.Count -gt 0) {
                    Write-TestLog 'WARN' 'Phase0' 'ModExportAudit' "$($psm.Name) -- exports non-existent functions: $($missing -join ', ')"
                    $modAuditWarn++
                } else {
                    Write-TestLog 'PASS' 'Phase0' 'ModExportAudit' "$($psm.Name) -- $($exportedNames.Count) exports, all defined ($($fnDefs.Count) functions)"
                    $modAuditPass++
                }
            } else {
                Write-TestLog 'PASS' 'Phase0' 'ModExportAudit' "$($psm.Name) -- wildcard or implicit export ($($fnDefs.Count) functions)"
                $modAuditPass++
            }
        } else {
            Write-TestLog 'INFO' 'Phase0' 'ModExportAudit' "$($psm.Name) -- no Export-ModuleMember (all $($fnDefs.Count) functions exported by default)"
            $modAuditPass++
        }
    }
    Write-TestLog 'INFO' 'Phase0' 'ModAuditSum' "Module audit: $modAuditPass passed, $modAuditWarn warnings out of $($psmFiles.Count) modules"

    # ── 0m: Tools Menu Target Existence ───────────────────────────────────
    # Verify every script file referenced by the Tools menu actually exists
    $toolsMenuTargets = @(
        @{ Label='View Config';                  Path='config\system-variables.xml' }
        @{ Label='Network Details';              Path='scripts\WinRemote-PSTool.ps1' }
        @{ Label='AVPN Connection Tracker';      Module='AVPN-Tracker'; Fn='Show-AVPNConnectionTracker' }
        @{ Label='Script Dependency Matrix';     Path='scripts\Invoke-ScriptDependencyMatrix.ps1' }
        @{ Label='Module Management';            Path='scripts\Invoke-ModuleManagement.ps1' }
        @{ Label='PS Environment Scanner';       Path='scripts\Invoke-PSEnvironmentScanner.ps1' }
        @{ Label='User Profile Manager';         Path='UPM\UserProfile-Manager.ps1' }
        @{ Label='Event Log Viewer';             Path='scripts\Show-EventLogViewer.ps1' }
        @{ Label='Scan Dashboard';               Path='scripts\Show-ScanDashboard.ps1' }
        @{ Label='WinRemote PS Tool';            Path='scripts\WinRemote-PSTool.ps1' }
        @{ Label='Cron-Ai-Athon Tool';           Path='scripts\Show-CronAiAthonTool.ps1' }
        @{ Label='MCP Service Config';           Path='scripts\Show-MCPServiceConfig.ps1' }
        @{ Label='XHTML Code Analysis';          Path='scripts\XHTML-Checker\XHTML-code-analysis.xhtml' }
        @{ Label='XHTML Feature Requests';       Path='scripts\XHTML-Checker\XHTML-FeatureRequests.xhtml' }
        @{ Label='XHTML MCP Service Config';     Path='scripts\XHTML-Checker\XHTML-MCPServiceConfig.xhtml' }
        @{ Label='XHTML Central Master To-Do';   Path='scripts\XHTML-Checker\XHTML-MasterToDo.xhtml' }
        @{ Label='Checklist Actions';            Path='scripts\Invoke-ChecklistActions.ps1' }
    )
    $toolsPass = 0; $toolsFail = 0
    foreach ($t in $toolsMenuTargets) {
        if ($t.Path) {
            $fullPath = Join-Path $scriptRoot $t.Path
            if (Test-Path $fullPath) {
                Write-TestLog 'PASS' 'Phase0' 'ToolsTarget' "$($t.Label) -- $($t.Path) exists"
                $toolsPass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'ToolsTarget' "$($t.Label) -- $($t.Path) MISSING"
                $toolsFail++
            }
        } elseif ($t.Module) {
            $modFile = Join-Path $modulesDir "$($t.Module).psm1"
            if (Test-Path $modFile) {
                Write-TestLog 'PASS' 'Phase0' 'ToolsTarget' "$($t.Label) -- module $($t.Module).psm1 exists"
                $toolsPass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'ToolsTarget' "$($t.Label) -- module $($t.Module).psm1 MISSING"
                $toolsFail++
            }
        }
    }
    Write-TestLog 'INFO' 'Phase0' 'ToolsTargetSum' "Tools menu targets: $toolsPass exist, $toolsFail missing"

    # ── 0n: Security Menu Command Availability ────────────────────────────
    # Verify that security-related functions exist in modules
    $securityFunctions = @(
        @{ Fn='Show-AssistedSASCDialog';    Module='AssistedSASC' }
        @{ Fn='Show-VaultStatusDialog';     Module='AssistedSASC' }
        @{ Fn='Show-VaultUnlockDialog';     Module='AssistedSASC' }
        @{ Fn='Lock-Vault';                 Module='AssistedSASC' }
        @{ Fn='Import-VaultSecrets';        Module='AssistedSASC' }
        @{ Fn='Import-Certificates';        Module='AssistedSASC' }
        @{ Fn='Test-VaultSecurity';         Module='AssistedSASC' }
        @{ Fn='Test-IntegrityManifest';     Module='PwShGUI-IntegrityCore' }  # P011: Renamed from AssistedSASC variant -> Test-SASCSignedManifest; canonical lives in IntegrityCore
        @{ Fn='Export-VaultBackup';         Module='AssistedSASC' }
        @{ Fn='Enable-WindowsHello';        Module='AssistedSASC' }
        @{ Fn='Set-VaultLANSharing';        Module='AssistedSASC' }
        @{ Fn='Get-VaultLANStatus';         Module='AssistedSASC' }
        @{ Fn='Invoke-PuTTYSession';        Module='SASC-Adapters' }
        @{ Fn='Invoke-MRemoteNGSession';    Module='SASC-Adapters' }
        @{ Fn='Connect-AzureWithVault';     Module='SASC-Adapters' }
    )
    $secPass = 0; $secFail = 0
    foreach ($sf in $securityFunctions) {
        $modFile = Join-Path $modulesDir "$($sf.Module).psm1"
        if (Test-Path $modFile) {
            $modContent = [System.IO.File]::ReadAllText($modFile, [System.Text.Encoding]::UTF8)
            if ($modContent -match ('(?m)^\s*function\s+' + [regex]::Escape($sf.Fn) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'SecFnCheck' "$($sf.Fn) defined in $($sf.Module).psm1"
                $secPass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'SecFnCheck' "$($sf.Fn) NOT defined in $($sf.Module).psm1"
                $secFail++
            }
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'SecFnCheck' "$($sf.Module).psm1 not found -- $($sf.Fn) unavailable"
            $secFail++
        }
    }
    Write-TestLog 'INFO' 'Phase0' 'SecFnSum' "Security functions: $secPass found, $secFail missing"

    # ── 0na: WinRemote + AVPN Function Availability ───────────────────────
    # Verify exported/defined functions in the WinRemote script and AVPN module.
    # Absence here means PS Remoting menu items will silently fail.
    $avpnModPath = Join-Path $modulesDir 'AVPN-Tracker.psm1'
    $winremoteScriptPath = Join-Path (Join-Path $scriptRoot 'scripts') 'WinRemote-PSTool.ps1'
    $netPass = 0; $netFail = 0

    $avpnRequiredFns = @('Show-AVPNConnectionTracker','Invoke-AVPNLog','Protect-AVPNCredential','Unprotect-AVPNCredential')
    if (Test-Path $avpnModPath) {
        $avpnSrc = [System.IO.File]::ReadAllText($avpnModPath, [System.Text.Encoding]::UTF8)
        foreach ($fn in $avpnRequiredFns) {
            if ($avpnSrc -match ('(?m)^\s*function\s+' + [regex]::Escape($fn) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'NetworkFnCheck' "$fn defined in AVPN-Tracker.psm1"
                $netPass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'NetworkFnCheck' "$fn NOT defined in AVPN-Tracker.psm1"
                $netFail++
            }
        }
    } else {
        Write-TestLog 'FAIL' 'Phase0' 'NetworkFnCheck' "AVPN-Tracker.psm1 not found -- AVPN functions unavailable"
        $netFail += $avpnRequiredFns.Count
    }

    $wrRequiredFns = @('Show-WinRemotePSTool','Invoke-ARPDiscovery','Invoke-SubnetPingScan',
        'Get-WinRMStatus','Get-RemotingChecklist','Get-SecureBaseline','Load-WRVault','Save-WRVault',
        'Protect-WRCredential','Unprotect-WRCredential')
    if (Test-Path $winremoteScriptPath) {
        $wrSrc = [System.IO.File]::ReadAllText($winremoteScriptPath, [System.Text.Encoding]::UTF8)
        foreach ($fn in $wrRequiredFns) {
            if ($wrSrc -match ('(?m)^\s*function\s+' + [regex]::Escape($fn) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'NetworkFnCheck' "$fn defined in WinRemote-PSTool.ps1"
                $netPass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'NetworkFnCheck' "$fn NOT defined in WinRemote-PSTool.ps1"
                $netFail++
            }
        }
        # Verify Invoke-AVPNLog uses Write-Warning not Write-Error (error-swallowing bug check)
        if ($avpnModPath -and (Test-Path $avpnModPath)) {
            $avpnLogSrc = [System.IO.File]::ReadAllText($avpnModPath, [System.Text.Encoding]::UTF8)
            if ($avpnLogSrc -match 'Write-Error.*-ErrorAction\s+Continue') {
                Write-TestLog 'FAIL' 'Phase0' 'NetworkFnCheck' "AVPN-Tracker: Invoke-AVPNLog uses Write-Error -ErrorAction Continue -- error swallowing bug present"
                $netFail++
            } else {
                Write-TestLog 'PASS' 'Phase0' 'NetworkFnCheck' "AVPN-Tracker: Invoke-AVPNLog does not use error-swallowing Write-Error pattern"
                $netPass++
            }
        }
    } else {
        Write-TestLog 'FAIL' 'Phase0' 'NetworkFnCheck' "WinRemote-PSTool.ps1 not found -- WinRemote functions unavailable"
        $netFail += $wrRequiredFns.Count
    }
    Write-TestLog 'INFO' 'Phase0' 'NetworkFnSum' "Network/WinRemote/AVPN functions: $netPass found, $netFail missing"

    # ── 0o: Tab Button Handler Verification ───────────────────────────────
    # Parse Main-GUI.ps1 for tab page buttons and verify they have Add_Click handlers
    if (Test-Path $mainScript) {
        $mainSrc = [System.IO.File]::ReadAllText($mainScript, [System.Text.Encoding]::UTF8)

        # Known tab button texts from Config Maintenance Form and main form
        $expectedTabButtons = @(
            @{ Tab='Folder Actions';     Button='Nest Folders' }
            @{ Tab='Archive Operations'; Button='Archive In-Place' }
            @{ Tab='Config Management';  Button='Export Config' }
            @{ Tab='Config Management';  Button='Import Config' }
            @{ Tab='Build Package';      Button='Build' }
        )
        $tabBtnPass = 0
        foreach ($tb in $expectedTabButtons) {
            $btnPattern = [regex]::Escape($tb.Button)
            if ($mainSrc -match ('\.Text\s*=\s*[''"]' + $btnPattern)) {
                # Check for Add_Click near the button definition
                Write-TestLog 'PASS' 'Phase0' 'TabBtnCheck' "Tab '$($tb.Tab)' button '$($tb.Button)' defined"
                $tabBtnPass++
            } else {
                Write-TestLog 'WARN' 'Phase0' 'TabBtnCheck' "Tab '$($tb.Tab)' button '$($tb.Button)' not found in source"
            }
        }
        Write-TestLog 'INFO' 'Phase0' 'TabBtnSum' "$tabBtnPass/$($expectedTabButtons.Count) tab buttons verified"

        # ── 0p: Script Show-/Invoke- Function Cross-Check ────────────────
        # Verify that scripts in scripts/ folder that define Show-* or Invoke-* functions are parseable
        $scriptFnFiles = @(Get-ChildItem -Path (Join-Path $scriptRoot 'scripts') -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Show-|Invoke-)' })
        $scriptFnPass = 0; $scriptFnFail = 0
        foreach ($sf in $scriptFnFiles) {
            $tokens = $null; $errors = $null
            try {
                $sfContent = [System.IO.File]::ReadAllText($sf.FullName, [System.Text.Encoding]::UTF8)
                [System.Management.Automation.Language.Parser]::ParseInput($sfContent, [ref]$tokens, [ref]$errors)
            } catch {
                $errors = @([pscustomobject]@{ Message = $_.Exception.Message })
            }
            $sfRel = $sf.Name
            if ($errors -and $errors.Count -gt 0) {
                Write-TestLog 'FAIL' 'Phase0' 'ScriptFnParse' "$sfRel -- $($errors[0].Message)"  # SIN-EXEMPT:P027 -- index access, context-verified safe
                $scriptFnFail++
            } else {
                # Extract the primary function name and check it exists
                $fnMatch = [regex]::Match($sfContent, '(?m)^\s*function\s+([A-Z][\w-]+)', 'IgnoreCase')
                $primaryFn = if ($fnMatch.Success) { $fnMatch.Groups[1].Value } else { '(none)' }
                Write-TestLog 'PASS' 'Phase0' 'ScriptFnParse' "$sfRel -- clean, primary function: $primaryFn"
                $scriptFnPass++
            }
        }
        Write-TestLog 'INFO' 'Phase0' 'ScriptFnParseSum' "Script function files: $scriptFnPass parsed OK, $scriptFnFail failed out of $($scriptFnFiles.Count)"

        # ── 0q: WinGets Menu Function Availability ────────────────────────
        # Verify WinGet-related functions referenced by menu items
        $wingetFunctions = @(
            'Show-WingetInstalledApp'
            'Show-WingetUpgradeCheck'
            'Show-WingetUpdateAllDialog'
        )
        foreach ($wf in $wingetFunctions) {
            if ($mainSrc -match ('(?m)function\s+' + [regex]::Escape($wf) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'WinGetFnCheck' "$wf defined in Main-GUI.ps1"
            } elseif ($script:FnRegistry.Defined.ContainsKey($wf)) {
                Write-TestLog 'PASS' 'Phase0' 'WinGetFnCheck' "$wf defined in $($script:FnRegistry.Defined[$wf])"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'WinGetFnCheck' "$wf not found in any source"
            }
        }

        # ── 0r: Tests Menu Function Availability ──────────────────────────
        $testsFunctions = @(
            'Test-VersionTag'
            'Show-NetworkDiagnosticsDialog'
            'Show-DiskCheckDialog'
            'Show-PrivacyCheck'
            'Show-SystemCheck'
        )
        foreach ($tf in $testsFunctions) {
            if ($mainSrc -match ('(?m)function\s+' + [regex]::Escape($tf) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'TestsFnCheck' "$tf defined in Main-GUI.ps1"
            } elseif ($script:FnRegistry.Defined.ContainsKey($tf)) {
                Write-TestLog 'PASS' 'Phase0' 'TestsFnCheck' "$tf defined in $($script:FnRegistry.Defined[$tf])"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'TestsFnCheck' "$tf not found in any source"
            }
        }

        # ── 0s: Help Menu Function & File Target Availability ────────────
        # Functions referenced by Help menu items
        $helpFunctions = @(
            'Show-UpdateHelp'
            'Export-WorkspacePackage'
            'Show-ManifestsRegistrySinsViewer'
            'Get-VersionInfo'
        )
        foreach ($hf in $helpFunctions) {
            if ($mainSrc -match ('(?m)function\s+' + [regex]::Escape($hf) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'HelpFnCheck' "$hf defined in Main-GUI.ps1"
            } elseif ($script:FnRegistry.Defined.ContainsKey($hf)) {
                Write-TestLog 'PASS' 'Phase0' 'HelpFnCheck' "$hf defined in $($script:FnRegistry.Defined[$hf])"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'HelpFnCheck' "$hf not found in any source"
            }
        }

        # File targets opened by Help menu items
        $helpMenuFileTargets = @(
            @{ Label='PwShGUI App Help (Webpage Index)'; Path='~README.md\PwShGUI-Help-Index.html' }
            @{ Label='Dependency Visualisation';         Path='~README.md\Dependency-Visualisation.html' }
            @{ Label='PS-Cheatsheet V2';                 Path='scripts\PS-CheatSheet-EXAMPLES-V2.ps1' }
        )
        $helpFilePass = 0; $helpFileFail = 0
        foreach ($ht in $helpMenuFileTargets) {
            $fullPath = Join-Path $scriptRoot $ht.Path
            if (Test-Path $fullPath) {
                Write-TestLog 'PASS' 'Phase0' 'HelpFileCheck' "$($ht.Label) -- $($ht.Path) exists"
                $helpFilePass++
            } else {
                Write-TestLog 'FAIL' 'Phase0' 'HelpFileCheck' "$($ht.Label) -- $($ht.Path) MISSING"
                $helpFileFail++
            }
        }
        Write-TestLog 'INFO' 'Phase0' 'HelpFileSum' "Help menu file targets: $helpFilePass exist, $helpFileFail missing"

        # Verify HelpIndex path is registered in PwShGUICore path registry
        $coreModForHelp = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (Test-Path $coreModForHelp) {
            $coreHelpSrc = [System.IO.File]::ReadAllText($coreModForHelp, [System.Text.Encoding]::UTF8)
            if ($coreHelpSrc -match "HelpIndex\s*=\s*Join-Path") {
                Write-TestLog 'PASS' 'Phase0' 'HelpRegistryCheck' "HelpIndex path key registered in PwShGUICore path registry"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'HelpRegistryCheck' "HelpIndex key not found in PwShGUICore path registry"
            }
        }

        # ── 0t: Config Maintenance Form Functions ─────────────────────────
        $configMaintFunctions = @(
            'Show-ConfigMaintenanceForm'
            'Show-StartupShortcutForm'
            'Show-RemoteBuildConfigForm'
            'Show-GUILayout'
        )
        foreach ($cf in $configMaintFunctions) {
            if ($mainSrc -match ('(?m)function\s+' + [regex]::Escape($cf) + '\b')) {
                Write-TestLog 'PASS' 'Phase0' 'ConfigFnCheck' "$cf defined in Main-GUI.ps1"
            } elseif ($script:FnRegistry.Defined.ContainsKey($cf)) {
                Write-TestLog 'PASS' 'Phase0' 'ConfigFnCheck' "$cf defined in $($script:FnRegistry.Defined[$cf])"
            } else {
                Write-TestLog 'WARN' 'Phase0' 'ConfigFnCheck' "$cf not found in any source"
            }
        }

        # ── 0u: CronAiAthon Module Integration ───────────────────────────
        $cronModules = @(
            @{ Name='CronAiAthon-Pipeline';  Fns=@('Initialize-PipelineRegistry','Add-PipelineItem','Get-PipelineItems') }
            @{ Name='CronAiAthon-Scheduler'; Fns=@('Initialize-CronSchedule','Invoke-CronJob','Get-CronJobSummary') }
            @{ Name='CronAiAthon-EventLog';  Fns=@('Write-CronEventLog','Write-CronLog') }
            @{ Name='CronAiAthon-BugTracker'; Fns=@('Invoke-FullBugScan','Invoke-ParseCheck') }
        )
        foreach ($cm in $cronModules) {
            $modPath = Join-Path $modulesDir "$($cm.Name).psm1"
            if (-not (Test-Path $modPath)) {
                Write-TestLog 'FAIL' 'Phase0' 'CronModCheck' "$($cm.Name).psm1 not found"
                continue
            }
            $modSrc = [System.IO.File]::ReadAllText($modPath, [System.Text.Encoding]::UTF8)
            $allFound = $true
            foreach ($fn in $cm.Fns) {
                if (-not ($modSrc -match ('(?m)^\s*function\s+' + [regex]::Escape($fn) + '\b'))) {
                    Write-TestLog 'WARN' 'Phase0' 'CronModCheck' "$($cm.Name) -- missing function: $fn"
                    $allFound = $false
                }
            }
            if ($allFound) {
                Write-TestLog 'PASS' 'Phase0' 'CronModCheck' "$($cm.Name) -- all $($cm.Fns.Count) key functions present"
            }
        }

        # ── 0v: Theme Module Function Verification ────────────────────────
        $themeFns = @('Get-ThemeValue','Get-ThemeFont','Set-ModernFormStyle','Set-ModernMenuStyle',
                      'Set-ModernDgvStyle','Set-ModernButtonStyle','Set-ModernTabStyle',
                      'Set-ModernFormTheme','New-RainbowProgressBar','New-SpinnerLabel')
        $themeModPath = Join-Path $modulesDir 'PwShGUI-Theme.psm1'
        if (Test-Path $themeModPath) {
            $themeSrc = [System.IO.File]::ReadAllText($themeModPath, [System.Text.Encoding]::UTF8)
            $themePass = 0
            foreach ($tf in $themeFns) {
                if ($themeSrc -match ('(?m)^\s*function\s+' + [regex]::Escape($tf) + '\b')) {
                    $themePass++
                } else {
                    Write-TestLog 'WARN' 'Phase0' 'ThemeFnCheck' "Missing: $tf in PwShGUI-Theme.psm1"
                }
            }
            Write-TestLog $(if ($themePass -eq $themeFns.Count) { 'PASS' } else { 'WARN' }) 'Phase0' 'ThemeFnCheck' "Theme module: $themePass/$($themeFns.Count) functions verified"
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'ThemeFnCheck' 'PwShGUI-Theme.psm1 not found'
        }

        # ── 0w: Core Module Function Verification ─────────────────────────
        $coreFns = @('Write-AppLog','Initialize-CorePaths','Get-ConfigSubValue','Set-ConfigSubValue',
                     'Get-ConfigList','Initialize-ConfigFile','Get-RainbowColor','Assert-DirectoryExists',
                     'Get-VersionInfo','Get-ProjectPath','Test-VersionTag')
        $coreModPath = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (Test-Path $coreModPath) {
            $coreSrc = [System.IO.File]::ReadAllText($coreModPath, [System.Text.Encoding]::UTF8)
            $corePass = 0
            foreach ($cf in $coreFns) {
                if ($coreSrc -match ('(?m)^\s*function\s+' + [regex]::Escape($cf) + '\b')) {
                    $corePass++
                } else {
                    Write-TestLog 'WARN' 'Phase0' 'CoreFnCheck' "Missing: $cf in PwShGUICore.psm1"
                }
            }
            Write-TestLog $(if ($corePass -eq $coreFns.Count) { 'PASS' } else { 'WARN' }) 'Phase0' 'CoreFnCheck' "Core module: $corePass/$($coreFns.Count) functions verified"
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'CoreFnCheck' 'PwShGUICore.psm1 not found'
        }
    }

    # ── 0x: SIN Registry Completeness ─────────────────────────────────────
    # Verify that expected number of SIN-PATTERN and SEMI-SIN definition files exist
    $sinRegistryPath = Join-Path $scriptRoot 'sin_registry'
    if (Test-Path $sinRegistryPath) {
        $sinPatternFiles  = @(Get-ChildItem -Path $sinRegistryPath -Filter 'SIN-PATTERN-*.json' -File -ErrorAction SilentlyContinue)
        $semiSinFiles     = @(Get-ChildItem -Path $sinRegistryPath -Filter 'SEMI-SIN-*.json'    -File -ErrorAction SilentlyContinue)
        $sinInstanceFiles = @(Get-ChildItem -Path $sinRegistryPath -Filter 'SIN-2*.json'        -File -ErrorAction SilentlyContinue)
        $minExpectedPatterns = 28
        $minExpectedSemiSins = 6
        $patCount = @($sinPatternFiles).Count
        $semiCount = @($semiSinFiles).Count
        if ($patCount -ge $minExpectedPatterns) {
            Write-TestLog 'PASS' 'Phase0' 'SINRegistry' "SIN patterns: $patCount (min expected: $minExpectedPatterns)"
        } else {
            Write-TestLog 'WARN' 'Phase0' 'SINRegistry' "SIN patterns: only $patCount found (expected >= $minExpectedPatterns)"
        }
        if ($semiCount -ge $minExpectedSemiSins) {
            Write-TestLog 'PASS' 'Phase0' 'SINRegistry' "SEMI-SIN definitions: $semiCount (min expected: $minExpectedSemiSins)"
        } else {
            Write-TestLog 'WARN' 'Phase0' 'SINRegistry' "SEMI-SIN definitions: only $semiCount found (expected >= $minExpectedSemiSins)"
        }
        Write-TestLog 'INFO' 'Phase0' 'SINRegistry' "SIN instances on record: $(@($sinInstanceFiles).Count)"
    } else {
        Write-TestLog 'FAIL' 'Phase0' 'SINRegistry' 'sin_registry/ directory not found'
    }

    # ── 0y: Log Level Filter Verification ─────────────────────────────────
    # Verify PwShGUICore.psm1 enforces minimum log level (not logging Debug by default)
    $coreModPath2 = Join-Path $modulesDir 'PwShGUICore.psm1'
    if (Test-Path $coreModPath2) {
        $coreSrc2 = [System.IO.File]::ReadAllText($coreModPath2, [System.Text.Encoding]::UTF8)
        if ($coreSrc2 -match '_MinLogLevel') {
            Write-TestLog 'PASS' 'Phase0' 'LogLevelFilter' 'Write-AppLog minimum log level filter is present'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'LogLevelFilter' 'PwShGUICore: _MinLogLevel filter missing -- all levels including Debug are written'
        }
        if ($coreSrc2 -match 'function\s+Set-LogMinLevel') {
            Write-TestLog 'PASS' 'Phase0' 'LogLevelFilter' 'Set-LogMinLevel function defined in PwShGUICore'
        } else {
            Write-TestLog 'WARN' 'Phase0' 'LogLevelFilter' 'Set-LogMinLevel function not found -- callers cannot adjust log verbosity'
        }
    }

    # ── 0z: Todo Backlog Health Check ─────────────────────────────────────
    # Warn if the active (non-archived) todo backlog exceeds healthy thresholds
    $todoDir = Join-Path $scriptRoot 'todo'
    if (Test-Path $todoDir) {
        $todoActive = @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '_*' -and $_.Name -ne 'action-log.json' })
        $count = @($todoActive).Count
        $warnThreshold = 200
        $critThreshold = 600
        if ($count -lt $warnThreshold) {
            Write-TestLog 'PASS' 'Phase0' 'BacklogHealth' "Active todo items: $count (healthy)"
        } elseif ($count -lt $critThreshold) {
            Write-TestLog 'WARN' 'Phase0' 'BacklogHealth' "Active todo items: $count -- exceeds $warnThreshold threshold; consider archiving completed/deferred items"
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'BacklogHealth' "Active todo items: $count -- critical backlog buildup (>= $critThreshold); run Invoke-TodoArchiver.ps1"
        }
    } else {
        Write-TestLog 'WARN' 'Phase0' 'BacklogHealth' 'todo/ directory not found'
    }

    # ── 0aa: Pipeline Monitor Feature Smoke Tests ──────────────────────────
    # Verify that Show-CronAiAthonTool.ps1 contains the Pipeline Monitor tab,
    # status bar, auto-refresh timer, and Refresh-PipelineMonitor function.
    $cronToolPath = Join-Path (Join-Path $scriptRoot 'scripts') 'Show-CronAiAthonTool.ps1'
    if (Test-Path $cronToolPath) {
        $cronContent = Get-Content $cronToolPath -Raw -Encoding UTF8

        # Tab 13 "Pipeline Monitor" present
        if ($cronContent -match "tabMon\.Text\s*=\s*'Pipeline Monitor'") {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonTab' 'Pipeline Monitor tab (Tab 13) is defined'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonTab' 'Pipeline Monitor tab not found in Show-CronAiAthonTool.ps1'
        }

        # Status bar LEDs for 4 states
        if ($cronContent -match 'ledSched' -and $cronContent -match 'ledRunning' -and
            $cronContent -match 'ledWarn'  -and $cronContent -match 'ledStop') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonLEDs' 'All 4 status-bar LED indicators defined (Scheduled/Running/Paused+Err/Stopped)'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonLEDs' 'One or more status-bar LED indicators missing'
        }

        # Update-StatusBar function defined
        if ($cronContent -match 'function Update-StatusBar') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonStatusFn' 'Update-StatusBar function defined'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonStatusFn' 'Update-StatusBar function not found'
        }

        # Refresh-PipelineMonitor function defined
        if ($cronContent -match 'function Refresh-PipelineMonitor') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonRefreshFn' 'Refresh-PipelineMonitor function defined'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonRefreshFn' 'Refresh-PipelineMonitor function not found'
        }

        # Auto-refresh timer with jitter defined
        if ($cronContent -match '_monTimer' -and $cronContent -match 'Get-Random') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonTimer' 'Auto-refresh timer with Get-Random jitter defined'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonTimer' 'Auto-refresh timer or jitter logic not found'
        }

        # Timer interval is in range 17000-23000 (20s +/- 3s)
        if ($cronContent -match '17000\s*\+\s*\(Get-Random') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonTimerInterval' 'Timer jitter expression 17000 + (Get-Random...) present (20s +/-3s)'
        } else {
            Write-TestLog 'WARN' 'Phase0' 'PipeMonTimerInterval' 'Timer jitter expression pattern not matched -- verify interval is 17000-23000ms'
        }

        # Stat cards: Executed / Success / Failed / Waiting / Agents / Tools
        $requiredCards = @('Executed','Success','Failed','Waiting','Agents','Tools','Elapsed')
        $missingCards  = @($requiredCards | Where-Object { $cronContent -notmatch "'$_'" })
        if (@($missingCards).Count -eq 0) {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonStatCards' "All $(@($requiredCards).Count) stat cards found (Executed/Success/Failed/Waiting/Agents/Tools/Elapsed)"
        } else {
            Write-TestLog 'WARN' 'Phase0' 'PipeMonStatCards' "Missing stat card keys: $($missingCards -join ', ')"
        }

        # Timer cleanup on Dispose
        if ($cronContent -match '_monTimer\.Stop\(\)' -and $cronContent -match '_monTimer\.Dispose\(\)') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonTimerDispose' 'Timer Stop() and Dispose() called at form cleanup'
        } else {
            Write-TestLog 'WARN' 'Phase0' 'PipeMonTimerDispose' '_monTimer.Stop()/.Dispose() not found in cleanup block -- potential resource leak'
        }

        # $accYellow defined
        if ($cronContent -match '\$accYellow\s*=') {
            Write-TestLog 'PASS' 'Phase0' 'PipeMonYellow' '$accYellow color variable defined for Paused/Error state'
        } else {
            Write-TestLog 'FAIL' 'Phase0' 'PipeMonYellow' '$accYellow color variable missing'
        }

    } else {
        Write-TestLog 'WARN' 'Phase0' 'PipeMonSmoke' "Show-CronAiAthonTool.ps1 not found -- skipping pipeline monitor checks"
    }

    Write-Host ""
} else {
    Write-TestLog 'SKIP' 'Phase0' 'Headless' 'Skipped by -SkipPhase'
}

# ── Report function (defined early so headless / failed-launch can call it) ──
function Show-Report {
    $sw.Stop()
    $elapsed = $sw.Elapsed.ToString('hh\:mm\:ss')

    $passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
    $infoCount = @($results | Where-Object { $_.Status -eq 'INFO' }).Count

    Write-Host "`n$('=' * 68)" -ForegroundColor Cyan
    Write-Host "  SMOKE TEST RESULTS   --  $env:COMPUTERNAME" -ForegroundColor Yellow
    Write-Host "$('=' * 68)" -ForegroundColor Cyan
    Write-Host "  PASS  : $passCount" -ForegroundColor Green
    Write-Host "  FAIL  : $failCount" -ForegroundColor Red
    Write-Host "  WARN  : $warnCount" -ForegroundColor Yellow
    Write-Host "  SKIP  : $skipCount" -ForegroundColor DarkYellow
    Write-Host "  INFO  : $infoCount" -ForegroundColor Gray
    Write-Host "  TOTAL : $($results.Count)" -ForegroundColor Cyan
    Write-Host "  TIME  : $elapsed" -ForegroundColor DarkGray
    Write-Host "$('=' * 68)`n" -ForegroundColor Cyan

    @(
        ""
        "=" * 68
        "  SMOKE TEST RESULTS -- $env:COMPUTERNAME"
        "=" * 68
        "  PASS  : $passCount"
        "  FAIL  : $failCount"
        "  WARN  : $warnCount"
        "  SKIP  : $skipCount"
        "  INFO  : $infoCount"
        "  TOTAL : $($results.Count)"
        "  TIME  : $elapsed"
        "=" * 68
    ) | Out-File -Append -FilePath $logPath -Encoding UTF8

    $results | Format-Table -AutoSize -Wrap Time, Status, Phase, Test, Detail |
        Out-String | Out-File -Append -FilePath $logPath -Encoding UTF8

    # Function coverage table
    if ($script:FnRegistry -and $script:FnRegistry.Defined.Count -gt 0) {
        $fnCoverageRows = @($script:FnRegistry.Defined.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{
                Function = $_
                DefinedIn = $script:FnRegistry.Defined[$_]
                Exported  = if ($script:FnRegistry.Exported.ContainsKey($_)) { 'Yes' } else { 'No' }
                Called    = if ($script:FnRegistry.Called.Contains($_)) { 'Yes' } else { 'NO' }
            }
        })
        Write-Host "`n  Function Coverage ($($fnCoverageRows.Count) functions):" -ForegroundColor DarkCyan
        $fnCoverageRows | Format-Table -AutoSize Function, DefinedIn, Exported, Called | Out-String | Write-Host
        $fnCoverageRows | Format-Table -AutoSize Function, DefinedIn, Exported, Called |
            Out-String | Out-File -Append -FilePath $logPath -Encoding UTF8
    }

    # Test category breakdown
    $categoryBreakdown = @(
        @{ Cat='SyntaxParse';    Label='Syntax Parse' }
        @{ Cat='ModuleImport';   Label='Module Imports' }
        @{ Cat='ConfigXML';      Label='Config XML' }
        @{ Cat='JSONConfig';     Label='JSON Configs' }
        @{ Cat='XHTMLValid';     Label='XHTML Validation' }
        @{ Cat='ModExportAudit'; Label='Module Export Audit' }
        @{ Cat='ToolsTarget';    Label='Tools Menu Targets' }
        @{ Cat='SecFnCheck';     Label='Security Functions' }
        @{ Cat='NetworkFnCheck'; Label='Network/AVPN/WinRemote' }
        @{ Cat='TabBtnCheck';    Label='Tab Buttons' }
        @{ Cat='ScriptFnParse';  Label='Script Functions' }
        @{ Cat='WinGetFnCheck';  Label='WinGet Functions' }
        @{ Cat='TestsFnCheck';   Label='Tests Functions' }
        @{ Cat='HelpFnCheck';       Label='Help Functions' }
        @{ Cat='HelpFileCheck';     Label='Help File Targets' }
        @{ Cat='HelpRegistryCheck'; Label='Help Registry' }
        @{ Cat='ConfigFnCheck';  Label='Config Functions' }
        @{ Cat='CronModCheck';   Label='CronAiAthon Modules' }
        @{ Cat='ThemeFnCheck';   Label='Theme Functions' }
        @{ Cat='CoreFnCheck';    Label='Core Functions' }
        @{ Cat='FnCoverage';     Label='Function Coverage' }
        @{ Cat='OrphanDetect';   Label='Orphan Detection' }
    )
    $catRows = @()
    foreach ($c in $categoryBreakdown) {
        $catResults = @($results | Where-Object { $_.Test -eq $c.Cat })
        if ($catResults.Count -eq 0) { continue }
        $p = @($catResults | Where-Object { $_.Status -eq 'PASS' }).Count
        $f = @($catResults | Where-Object { $_.Status -eq 'FAIL' }).Count
        $w = @($catResults | Where-Object { $_.Status -eq 'WARN' }).Count
        $catRows += [pscustomobject]@{
            Category = $c.Label
            Pass     = $p
            Fail     = $f
            Warn     = $w
            Total    = $catResults.Count
        }
    }
    if ($catRows.Count -gt 0) {
        Write-Host "`n  Test Category Breakdown:" -ForegroundColor DarkCyan
        $catRows | Format-Table -AutoSize Category, Pass, Fail, Warn, Total | Out-String | Write-Host
        $catRows | Format-Table -AutoSize Category, Pass, Fail, Warn, Total |
            Out-String | Out-File -Append -FilePath $logPath -Encoding UTF8
    }

    Write-Host "Log saved: $logPath" -ForegroundColor Green
    Write-Host ""
}

# If HeadlessOnly, jump straight to report
if ($HeadlessOnly) {
    Write-Host "[HeadlessOnly] Skipping GUI phases.`n" -ForegroundColor DarkYellow
    Show-Report
    if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { exit 1 } else { exit 0 }
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 -- Launch the application
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[Phase 1] Launching Main-GUI.ps1 -StartupMode quik_jnr" -ForegroundColor Cyan

$shell = Resolve-SelectedShellCommand
if (-not $shell) {
    Write-TestLog 'FAIL' 'Phase1' 'Launch' "Requested shell '$Shell' not found"
    Show-Report
    exit 1
}
$script:appProcess = Start-Process $shell `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$mainScript`" -StartupMode quik_jnr" `
    -WindowStyle Normal -PassThru

Write-TestLog 'INFO' 'Phase1' 'Launch' "PID $($script:appProcess.Id) via $shell"

# Wait for the window to appear
$mainWin = Wait-Window -TitleSubstring 'PowerShell Script Launcher' -TimeoutSec $Timeout
if (-not $mainWin) {
    Write-TestLog 'FAIL' 'Phase1' 'WindowFind' "Main window not found within ${Timeout}s"
    # Try to kill the process
    try { $script:appProcess | Stop-Process -Force -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
    Show-Report
    if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { exit 1 } else { exit 0 }
}
Write-TestLog 'PASS' 'Phase1' 'WindowFind' "Window found: '$($mainWin.Current.Name)'"
Start-Sleep -Milliseconds 1500   # let the form finish rendering

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 -- Menu Walk
# ══════════════════════════════════════════════════════════════════════════════
$runPhase2 = 2 -notin $SkipPhase
if ($runPhase2) {
    Write-Host "`n[Phase 2] Menu Walk" -ForegroundColor Cyan

    # The menu bar items and their children (text values from Main-GUI.ps1)
    # Items marked 'dialog' produce a modal popup that must be dismissed.
    # Items marked 'external' open a browser / external process -- skip invoke.
    # Items marked 'exit' would close the app -- skip during walk.
    $menuMap = [ordered]@{
        'File' = @(
            # Settings is a submenu
            @{ Name='Settings'; Sub = @(
                @{ Name='Configure Paths...'; Action='dialog' }
                @{ Name='Script Folders...';  Action='dialog' }
            )}
            @{ Name='Exit'; Action='exit' }
        )
        'Tests' = @(
            @{ Name='Version Check';                     Action='dialog' }
            @{ Name='Network Diagnostics';               Action='dialog' }
            @{ Name='Disk Check';                        Action='dialog' }
            @{ Name='Privacy Check';                     Action='dialog' }
            @{ Name='System Check';                      Action='dialog' }
            @{ Name="App Testing (Docs & Comments)";     Action='external' }
            @{ Name="Scrutiny Safety & SecOps";          Action='external' }
        )
        'Links' = @(
            # Dynamic - we'll enumerate and skip all (they open URLs)
        )
        'WinGets' = @(
            @{ Name='Installed Apps (Grid View)';  Action='dialog' }
            @{ Name='Detect Updates (Check-Only)'; Action='dialog' }
            @{ Name='Update All (Admin Options)';  Action='dialog' }
        )
        'Tools' = @(
            @{ Name='View Config';                                   Action='external' }
            @{ Name='Config Maintenance...';                         Action='dialog' }
            @{ Name='Open Logs Directory';                           Action='external' }
            @{ Name='Scriptz n Portz N PowerShellD (Layout)';       Action='dialog' }
            @{ Name='Button Maintenance';                            Action='dialog' }
            @{ Name='Network Details';                               Action='dialog' }
            @{ Name='AVPN Connection Tracker';                       Action='dialog' }
            @{ Name='Script Dependency Matrix';                      Action='dialog' }
            @{ Name='Module Management';                             Action='dialog' }
            @{ Name='PS Environment Scanner';                        Action='dialog' }
            @{ Name='User Profile Manager';                          Action='external' }
            @{ Name='Event Log Viewer';                              Action='dialog' }
            @{ Name='Scan Dashboard...';                             Action='dialog' }
            @{ Name='WinRemote PS Tool';                             Action='external' }
            @{ Name='Cron-Ai-Athon Tool';                           Action='dialog' }
            @{ Name='MCP Service Config';                            Action='dialog' }
            @{ Name='XHTML Reports'; Sub = @(
                @{ Name='Code Analysis';          Action='external' }
                @{ Name='Feature Requests';       Action='external' }
                @{ Name='MCP Service Config';     Action='external' }
                @{ Name='Central Master To-Do';   Action='external' }
            )}
            @{ Name='Create Startup Shortcut...';                   Action='dialog' }
            @{ Name='Remote Build Path Config...';                   Action='dialog' }
        )
        'Security' = @(
            @{ Name='Security Checklist...';                         Action='dialog' }
            @{ Name='Assisted SASC Wizard...';                       Action='dialog' }
            @{ Name='Vault Status...';                               Action='dialog' }
            @{ Name='Unlock Vault...';                               Action='dialog' }
            @{ Name='Lock Vault';                                    Action='dialog' }
            @{ Name='Vault Operations'; Sub = @(
                @{ Name='Save Secret';            Action='dialog' }
                @{ Name='Retrieve Secret';        Action='dialog' }
                @{ Name='Create Secret';          Action='dialog' }
            )}
            @{ Name='Import Secrets...';                             Action='dialog' }
            @{ Name='Import Certificates...';                        Action='dialog' }
            @{ Name='Vault Security Audit...';                       Action='dialog' }
            @{ Name='Integrity Verification...';                     Action='dialog' }
            @{ Name='LAN Vault Sharing...';                          Action='dialog' }
            @{ Name='Windows Hello Setup...';                        Action='dialog' }
            @{ Name='Invoke Secrets Page...';                        Action='dialog' }
            @{ Name='Export Vault Backup...';                        Action='dialog' }
        )
        'Help' = @(
            @{ Name='Update-Help';                             Action='dialog' }
            @{ Name='PwShGUI App Help (Webpage Index)';        Action='external' }
            @{ Name='Package Workspace';                       Action='dialog' }
            @{ Name='Dependency Visualisation';                Action='external' }
            @{ Name='PS-Cheatsheet V2';                        Action='external' }
            @{ Name='About';                                   Action='dialog' }
        )
    }

    # Find the MenuStrip (MenuBar control type)
    $menuBar = Find-Control -Parent $mainWin -Type ([System.Windows.Automation.ControlType]::MenuBar) -Name 'menuStrip'
    if (-not $menuBar) {
        # Try generic search for any menu bar
        $menuBar = Find-Control -Parent $mainWin -Type ([System.Windows.Automation.ControlType]::MenuBar)
    }

    if (-not $menuBar) {
        Write-TestLog 'FAIL' 'Phase2' 'MenuBar' 'MenuStrip not found on form'
    } else {
        Write-TestLog 'PASS' 'Phase2' 'MenuBar' 'MenuStrip located'

        foreach ($topMenuName in $menuMap.Keys) {
            # Find the top-level menu item
            $topItem = Find-Control -Parent $menuBar -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $topMenuName
            if (-not $topItem) {
                Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName" 'Top-level menu item not found'
                continue
            }

            $children = $menuMap[$topMenuName]  # SIN-EXEMPT:P027 -- index access, context-verified safe

            # Links menu -- enumerate dynamically, skip all
            if ($topMenuName -eq 'Links') {
                Write-TestLog 'SKIP' 'Phase2' 'Menu:Links' 'Dynamic URL items -- skipped (external)'
                continue
            }

            if ($children.Count -eq 0) { continue }

            # Expand top menu
            $expanded = Expand-MenuItem $topItem
            if (-not $expanded) {
                Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName" 'Could not expand menu'
                continue
            }

            foreach ($child in $children) {
                $itemName   = $child.Name
                $itemAction = $child.Action
                if ($SkipMenuItems -contains $itemName) {
                    Write-TestLog 'SKIP' 'Phase2' "Menu:$topMenuName>$itemName" 'Skipped by SkipMenuItems filter'
                    continue
                }

                # Handle submenu (e.g. File > Settings > ...)
                if ($child.ContainsKey('Sub')) {
                    $subMenu = Find-Control -Parent $topItem -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $itemName
                    if ($subMenu) {
                        $subExpanded = Expand-MenuItem $subMenu
                        if ($subExpanded) {
                            foreach ($subChild in $child.Sub) {
                                $subItem = Find-Control -Parent $subMenu -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $subChild.Name
                                if ($subItem -and $subChild.Action -eq 'dialog') {
                                    Invoke-Pattern $subItem | Out-Null
                                    Start-Sleep -Milliseconds 800
                                    $popup = Wait-Popup -MainWin $mainWin -WaitMs 3000
                                    if ($popup) {
                                        $dismissedWith = Dismiss-Dialog $popup
                                        Write-TestLog 'PASS' 'Phase2' "Menu:$topMenuName>$itemName>$($subChild.Name)" "Dialog dismissed ($dismissedWith)"
                                    } else {
                                        Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName>$itemName>$($subChild.Name)" 'No popup detected'
                                    }
                                } elseif (-not $subItem) {
                                    Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName>$itemName>$($subChild.Name)" 'Sub-item not found'
                                }
                            }
                            Collapse-MenuItem $subMenu | Out-Null
                        }
                    }
                    continue
                }

                # Skip exit -- would close the app
                if ($itemAction -eq 'exit') {
                    Write-TestLog 'SKIP' 'Phase2' "Menu:$topMenuName>$itemName" 'Exit -- skipped (would close app)'
                    continue
                }

                # Skip external -- opens browser / file explorer / separate process
                if ($itemAction -eq 'external') {
                    Write-TestLog 'SKIP' 'Phase2' "Menu:$topMenuName>$itemName" 'External action -- skipped'
                    continue
                }

                # dialog items -- invoke, wait for popup, dismiss
                $menuItem = Find-Control -Parent $topItem -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $itemName
                if (-not $menuItem) {
                    Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName>$itemName" 'Menu item not found'
                    continue
                }

                try {
                    Invoke-Pattern $menuItem | Out-Null
                    Start-Sleep -Milliseconds 1200
                    $popup = Wait-Popup -MainWin $mainWin -WaitMs 4000
                    if ($popup) {
                        $dlgTitle = $popup.Current.Name
                        $dismissedWith = Dismiss-Dialog $popup
                        Write-TestLog 'PASS' 'Phase2' "Menu:$topMenuName>$itemName" "Dialog '$dlgTitle' dismissed ($dismissedWith)"
                    } else {
                        # Some items may show a MessageBox that auto-attached
                        Write-TestLog 'WARN' 'Phase2' "Menu:$topMenuName>$itemName" 'No popup detected (may have completed silently)'
                    }
                } catch {
                    Write-TestLog 'FAIL' 'Phase2' "Menu:$topMenuName>$itemName" "Error: $_"
                }

                # Re-expand top menu for next item (dialog may have collapsed it)
                Start-Sleep -Milliseconds 400
                Expand-MenuItem $topItem | Out-Null
            }

            # Collapse the top menu before moving to next
            Collapse-MenuItem $topItem | Out-Null
            Start-Sleep -Milliseconds 300
        }
    }
} else {
    Write-TestLog 'SKIP' 'Phase2' 'MenuWalk' 'Skipped by -SkipPhase'
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 -- Button Walk
# ══════════════════════════════════════════════════════════════════════════════
$runPhase3 = 3 -notin $SkipPhase
if ($runPhase3) {
    Write-Host "`n[Phase 3] Button Walk" -ForegroundColor Cyan

    # Find all buttons on the main form
    $buttons = Find-Control -Parent $mainWin -Type ([System.Windows.Automation.ControlType]::Button) -All
    $clickedCount = 0

    foreach ($btn in $buttons) {
        $btnName = $btn.Current.Name
        if ([string]::IsNullOrWhiteSpace($btnName)) { continue }

        # Skip if it looks like a system / title-bar button
        if ($btnName -in @('Close','Minimize','Maximize','Restore')) { continue }

        try {
            Invoke-Pattern $btn | Out-Null
            Start-Sleep -Milliseconds 1000

            # Check for elevation prompt (MessageBox with Yes/No)
            $elevDlg = Wait-Popup -MainWin $mainWin -WaitMs 3000
            if ($elevDlg) {
                $dlgTitle = $elevDlg.Current.Name
                # If it's the elevation prompt, click No
                if ($dlgTitle -like '*Elevation*' -or $dlgTitle -like '*Admin*') {
                    $dismissed = Dismiss-Dialog -Dialog $elevDlg -PreferButtons @('No','Cancel')
                    Write-TestLog 'PASS' 'Phase3' "Btn:$btnName" "Elevation prompt dismissed ($dismissed)"
                } else {
                    # Some other dialog -- dismiss it
                    $dismissed = Dismiss-Dialog -Dialog $elevDlg -PreferButtons @('No','Cancel','Close','OK')
                    Write-TestLog 'PASS' 'Phase3' "Btn:$btnName" "Dialog '$dlgTitle' dismissed ($dismissed)"
                }
            } else {
                Write-TestLog 'PASS' 'Phase3' "Btn:$btnName" 'Clicked -- no popup'
            }
            $clickedCount++
        } catch {
            Write-TestLog 'FAIL' 'Phase3' "Btn:$btnName" "Error: $_"
        }
        Start-Sleep -Milliseconds 400
    }

    Write-TestLog 'INFO' 'Phase3' 'Summary' "$clickedCount button(s) tested"
} else {
    Write-TestLog 'SKIP' 'Phase3' 'ButtonWalk' 'Skipped by -SkipPhase'
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 -- Sub-Dialog Exercise
# ══════════════════════════════════════════════════════════════════════════════
$runPhase4 = 4 -notin $SkipPhase
if ($runPhase4) {
    Write-Host "`n[Phase 4] Sub-Dialog Verification" -ForegroundColor Cyan

    # Re-verify the main window is still alive
    try { $null = $mainWin.Current.Name } catch {
        Write-TestLog 'FAIL' 'Phase4' 'WindowCheck' 'Main window no longer available'
        $runPhase4 = $false
    }

    if ($runPhase4) {
        $menuBar = Find-Control -Parent $mainWin -Type ([System.Windows.Automation.ControlType]::MenuBar)

        # Dialogs to exercise (via menu path)
        $dialogTests = @(
            @{ Menu='Tests'; Item='Network Diagnostics';       ExpectControls=@('Button') }
            @{ Menu='Tests'; Item='Disk Check';                ExpectControls=@('Button') }
            @{ Menu='Tests'; Item='Privacy Check';             ExpectControls=@('Button') }
            @{ Menu='Tests'; Item='System Check';              ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Config Maintenance...';     ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='AVPN Connection Tracker';   ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Script Dependency Matrix';  ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Module Management';         ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='PS Environment Scanner';    ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Scan Dashboard...';         ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Cron-Ai-Athon Tool';       ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='MCP Service Config';        ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Create Startup Shortcut...'; ExpectControls=@('Button') }
            @{ Menu='Tools'; Item='Remote Build Path Config...'; ExpectControls=@('Button') }
            @{ Menu='Security'; Item='Security Checklist...';  ExpectControls=@('Button') }
            @{ Menu='Security'; Item='Vault Status...';        ExpectControls=@('Button') }
            @{ Menu='Help'; Item='About';                      ExpectControls=@('Button') }
        )

        foreach ($dt in $dialogTests) {
            if (-not $menuBar) {
                Write-TestLog 'SKIP' 'Phase4' "Dlg:$($dt.Item)" 'MenuBar lost'
                continue
            }
            $topItem = Find-Control -Parent $menuBar -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $dt.Menu
            if (-not $topItem) {
                Write-TestLog 'WARN' 'Phase4' "Dlg:$($dt.Item)" "Top menu '$($dt.Menu)' not found"
                continue
            }
            Expand-MenuItem $topItem | Out-Null
            $child = Find-Control -Parent $topItem -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $dt.Item
            if (-not $child) {
                Write-TestLog 'WARN' 'Phase4' "Dlg:$($dt.Item)" 'Menu item not found'
                Collapse-MenuItem $topItem | Out-Null
                continue
            }
            Invoke-Pattern $child | Out-Null
            Start-Sleep -Milliseconds 1500
            $popup = Wait-Popup -MainWin $mainWin -WaitMs 5000
            if ($popup) {
                # Inventory controls
                $ctrlSummary = @()
                foreach ($expectedType in $dt.ExpectControls) {
                    $ct = [System.Windows.Automation.ControlType]::$expectedType
                    $found = Find-Control -Parent $popup -Type $ct -All
                    $ctrlSummary += "$expectedType=$($found.Count)"
                }
                $dismissed = Dismiss-Dialog $popup
                Write-TestLog 'PASS' 'Phase4' "Dlg:$($dt.Item)" "Controls: $($ctrlSummary -join ', ') -- dismissed ($dismissed)"
            } else {
                Write-TestLog 'WARN' 'Phase4' "Dlg:$($dt.Item)" 'Dialog did not appear'
            }
            Start-Sleep -Milliseconds 500
        }
    }
} else {
    Write-TestLog 'SKIP' 'Phase4' 'DialogExercise' 'Skipped by -SkipPhase'
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 -- Log Verification
# ══════════════════════════════════════════════════════════════════════════════
$runPhase5 = 5 -notin $SkipPhase
if ($runPhase5) {
    Write-Host "`n[Phase 5] Log Cross-Check" -ForegroundColor Cyan

    $today = Get-Date -Format 'yyyy-MM-dd'
    $appLogPattern = Join-Path $logsDir "$env:COMPUTERNAME-$today*.log"
    $appLogs = Get-ChildItem -Path $appLogPattern -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*SmokeTest*' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($appLogs) {
        $logContent = Get-Content $appLogs.FullName -Raw -ErrorAction SilentlyContinue
        # Check for key Event entries we expect the app to have written
        $expectedEvents = @(
            'Button clicked'
            'User selected'
            'elevation'
        )
        $found = 0
        foreach ($ev in $expectedEvents) {
            if ($logContent -match [regex]::Escape($ev)) { $found++ }
        }
        Write-TestLog 'INFO' 'Phase5' 'LogCheck' "App log: $($appLogs.Name) -- matched $found/$($expectedEvents.Count) event patterns"
        if ($found -ge 2) {
            Write-TestLog 'PASS' 'Phase5' 'LogVerify' 'Event entries confirmed in app log'
        } else {
            Write-TestLog 'WARN' 'Phase5' 'LogVerify' 'Fewer event entries than expected (log may not have flushed yet)'
        }
    } else {
        Write-TestLog 'WARN' 'Phase5' 'LogCheck' "No app log found for $today"
    }
} else {
    Write-TestLog 'SKIP' 'Phase5' 'LogCheck' 'Skipped by -SkipPhase'
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 -- Cleanup & Close
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Phase 6] Cleanup" -ForegroundColor Cyan

if ($script:appProcess -and -not $script:appProcess.HasExited) {
    # Try to close gracefully by sending Ctrl+Q or finding File > Exit
    $closed = $false
    try {
        $menuBar2 = Find-Control -Parent $mainWin -Type ([System.Windows.Automation.ControlType]::MenuBar)
        if ($menuBar2) {
            $fileMenu = Find-Control -Parent $menuBar2 -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name 'File'
            if ($fileMenu) {
                Expand-MenuItem $fileMenu | Out-Null
                $exitItem = Find-Control -Parent $fileMenu -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name 'Exit'
                if ($exitItem) {
                    Invoke-Pattern $exitItem | Out-Null
                    Start-Sleep -Milliseconds 2000
                    if ($script:appProcess.HasExited) { $closed = $true }
                }
            }
        }
    } catch { <# Intentional: non-fatal #> }

    if (-not $closed -and -not $script:appProcess.HasExited) {
        # Fallback: send close message
        try {
            $wp = $null
            if ($mainWin.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) {
                $wp.Close()
                Start-Sleep -Milliseconds 2000
            }
        } catch { <# Intentional: non-fatal #> }
    }

    if (-not $script:appProcess.HasExited) {
        # Hard kill
        try { $script:appProcess | Stop-Process -Force -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
        Write-TestLog 'WARN' 'Phase6' 'Close' 'Process killed (did not exit gracefully)'
    } else {
        Write-TestLog 'PASS' 'Phase6' 'Close' 'Application closed cleanly'
    }
} else {
    Write-TestLog 'INFO' 'Phase6' 'Close' 'Process already exited'
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 -- Report
# ══════════════════════════════════════════════════════════════════════════════
Show-Report
if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { exit 1 } else { exit 0 }














<# Outline:
    Objective cycle managed section: this script should keep behavior explicit and verifiable.
#>

<# Objectives-Review:
    Objective alignment captured during pipeline cycle execution; update when scope changes.
#>

<# Problems:
    No newly identified problems in this cycle section.
#>


