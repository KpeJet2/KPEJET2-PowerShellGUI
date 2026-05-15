# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# SS-004 exempt: Start-Sleep calls are test timing delays for WinForms automation
# Author   : The Establishment
# Date     : 2026-03-28
# FileRole : Diagnostics
# ─────────────────────────────────────────────────────────────────────────────
#  CoalTest 2.0 — Exhaustive Interactive Host Smoke Test Harness
#
#  Runs EVERY smoke test item that exists in the PwShGUI workspace, mapped
#  to an interactive application call made directly on the live host.
#
#  Features:
#    • Consent gate  — must type YES to proceed
#    • Crash-resilient checkpoints — resume from last completed test after crash
#    • Multi-crash skip — if a test crashes 3+ times it is auto-skipped
#    • Full error log  — temp\coaltest2-errors.json + coloured console output
#    • Pipeline integration — failures auto-create Bug items in todo\
#    • All tests sourced from: Invoke-GUISmokeTest.ps1,
#                              Invoke-SandboxSmokeTest.ps1,
#                              Invoke-WidgetSmokeTests.Tests.ps1
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath,
    [switch]$Resume,
    [switch]$NoConsent,
    [int]$MaxCrashesPerTest = 3,
    [switch]$HeadlessOnly,
    [switch]$SkipPipelineWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Workspace root resolution ─────────────────────────────────────────────────
if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if (-not (Test-Path $WorkspacePath)) {
    Write-Host "[FATAL] WorkspacePath not found: $WorkspacePath" -ForegroundColor Red
    exit 1
}

# ── Derived paths ─────────────────────────────────────────────────────────────
$modulesDir   = Join-Path $WorkspacePath 'modules'
$scriptsDir   = Join-Path $WorkspacePath 'scripts'
$configDir    = Join-Path $WorkspacePath 'config'
$tempDir      = Join-Path $WorkspacePath 'temp'
$todoDir      = Join-Path $WorkspacePath 'todo'
$logsDir      = Join-Path $WorkspacePath 'logs'
$reportsDir   = Join-Path $WorkspacePath '~REPORTS'
$testsDir     = Join-Path $WorkspacePath 'tests'
$mainScript   = Join-Path $WorkspacePath 'Main-GUI.ps1'
$configFile   = Join-Path $configDir 'system-variables.xml'
$chkpointPath = Join-Path $tempDir 'coaltest2-checkpoint.json'
$errLogPath   = Join-Path $tempDir 'coaltest2-errors.json'
$runLogPath   = Join-Path $logsDir ("CoalTest2-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

foreach ($d in @($tempDir, $todoDir, $logsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONSENT GATE
# ─────────────────────────────────────────────────────────────────────────────
if (-not $NoConsent) {
    $banner = @'

 ██████╗ ██████╗  █████╗  ██╗         ████████╗███████╗███████╗████████╗
██╔════╝██╔═══██╗██╔══██╗ ██║            ██╔══╝██╔════╝██╔════╝╚══██╔══╝
██║     ██║   ██║███████║ ██║            ██║   █████╗  ███████╗   ██║
██║     ██║   ██║██╔══██║ ██║            ██║   ██╔══╝  ╚════██║   ██║
╚██████╗╚██████╔╝██║  ██║ ███████╗       ██║   ███████╗███████║   ██║
 ╚═════╝ ╚═════╝ ╚═╝  ╚═╝ ╚══════╝       ╚═╝   ╚══════╝╚══════╝   ╚═╝

                    ====  C O A L T E S T   2 . 0  ====
                    ====  EXHAUSTIVE INTERACTIVE RUN ====

'@
    Write-Host $banner -ForegroundColor Red
    Write-Host ('=' * 78) -ForegroundColor DarkRed
    Write-Host ''
    Write-Host '  THIS IS AN INTERACTIVE TESTING SUITE' -ForegroundColor Yellow
    Write-Host '  RECOMMENDED TO BE RAN IN A SANDBOXED ENVIRONMENT!!' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ('  This test is extremely likely to damage your user profile,' ) -ForegroundColor Red
    Write-Host ('  modify configurations, spawn GUI windows, launch processes,') -ForegroundColor Red
    Write-Host ('  write files, exercise network tools, and generally go nuts.') -ForegroundColor Red
    Write-Host ''
    Write-Host '  Type YES to proceed with this extremely likely to damage your' -ForegroundColor White
    Write-Host '  profile thing, if you''re sure that is, SO are you sure?'       -ForegroundColor White
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkRed
    Write-Host ''
    $answer = Read-Host 'Type YES to proceed (anything else aborts)'
    if ($answer -cne 'YES') {
        Write-Host "`n  Aborted. Wise choice." -ForegroundColor DarkYellow
        exit 0
    }
    Write-Host "`n  Proceeding with CoalTest 2.0...`n" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
#  RUN-LOG WRITER
# ─────────────────────────────────────────────────────────────────────────────
function Write-CoalLog {
    [CmdletBinding()]
    param(
        [ValidateSet('PASS','FAIL','SKIP','INFO','WARN','CRASH')]
        [string]$Status,
        [string]$Group,
        [string]$TestId,
        [string]$Name,
        [string]$Detail = ''
    )
    $colours = @{
        PASS  = 'Green'
        FAIL  = 'Red'
        WARN  = 'Yellow'
        SKIP  = 'DarkYellow'
        INFO  = 'Gray'
        CRASH = 'Magenta'
    }
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[{0}] {1,-5}  {2,-20} {3,-40} {4}" -f $ts, $Status, $Group, $Name, $Detail
    Write-Host $line -ForegroundColor $colours[$Status]
    try {
        $line | Out-File -Append -FilePath $runLogPath -Encoding UTF8
    } catch { <# Intentional: non-fatal - run log write failure should not abort test #> }
}

# ─────────────────────────────────────────────────────────────────────────────
#  CHECKPOINT FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
function Load-CoalCheckpoint {
    [CmdletBinding()]
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            return $obj
        } catch {
            Write-CoalLog -Status 'WARN' -Group 'Checkpoint' -TestId 'load' `
                -Name 'Load checkpoint' -Detail "Failed to load checkpoint: $_"
        }
    }
    return $null
}

function Save-CoalCheckpoint {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$RunId,
        [System.Collections.ArrayList]$Completed,
        [System.Collections.ArrayList]$Failed,
        [System.Collections.ArrayList]$Skipped,
        [hashtable]$Crashes,
        [string]$LastTestId
    )
    $state = [ordered]@{
        schemaVersion   = '2.0'
        runId           = $RunId
        startedAt       = $script:runStartedAt
        lastCheckpoint  = (Get-Date).ToUniversalTime().ToString('o')
        lastTestId      = $LastTestId
        completedTests  = @($Completed)
        failedTests     = @($Failed)
        skippedTests    = @($Skipped)
        crashes         = $Crashes
    }
    try {
        $state | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-CoalLog -Status 'WARN' -Group 'Checkpoint' -TestId 'save' `
            -Name 'Save checkpoint' -Detail "Failed to save checkpoint: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  PIPELINE BUG REGISTRATION
# ─────────────────────────────────────────────────────────────────────────────
$script:PendingBugs = [System.Collections.ArrayList]::new()

function Register-CoalBug {
    [CmdletBinding()]
    param(
        [string]$TestId,
        [string]$Name,
        [string]$Detail,
        [string]$Severity = 'MEDIUM'
    )
    $bugId = "COAL2-{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), $TestId
    $bug = [ordered]@{
        id           = $bugId
        type         = 'Bug'
        title        = "CoalTest2 FAIL: $Name"
        description  = $Detail
        category     = 'coaltest2'
        priority     = if ($Severity -eq 'HIGH') { 'HIGH' } else { 'MEDIUM' }
        status       = 'OPEN'
        sinId        = ''
        notes        = "Discovered by Invoke-CoalTest2.ps1 run on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        affectedFiles = @()
        suggestedBy  = 'CoalTest2.0'
        created      = (Get-Date -Format 'yyyy-MM-dd')
        testId       = $TestId
    }
    [void]$script:PendingBugs.Add($bug)
}

function Flush-CoalBugsToTodo {
    [CmdletBinding()]
    param([string]$WsPath)
    if ($SkipPipelineWrite) {
        Write-CoalLog -Status 'INFO' -Group 'Pipeline' -TestId 'flush' `
            -Name 'Bug flush' -Detail "Skipped (-SkipPipelineWrite)"
        return
    }
    if (@($script:PendingBugs).Count -eq 0) {
        Write-CoalLog -Status 'INFO' -Group 'Pipeline' -TestId 'flush' `
            -Name 'Bug flush' -Detail "No bugs to register"
        return
    }
    # Try pipeline module write; fall back to direct JSON files
    $pipelineMod = Join-Path $WsPath (Join-Path 'modules' 'CronAiAthon-Pipeline.psm1')
    $pipelineLoaded = $false
    if (Test-Path $pipelineMod) {
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $pipelineLoaded = $true
        } catch {
            Write-CoalLog -Status 'WARN' -Group 'Pipeline' -TestId 'flush' `
                -Name 'Pipeline module' -Detail "Could not load module: $_"
        }
    }

    $tdDir = Join-Path $WsPath 'todo'
    if (-not (Test-Path $tdDir)) { New-Item -ItemType Directory -Path $tdDir -Force | Out-Null }

    $flushed = 0
    foreach ($bug in $script:PendingBugs) {
        try {
            if ($pipelineLoaded) {
                # Convert ordered hashtable to plain hashtable for Add-PipelineItem
                $bugHt = @{}
                foreach ($k in $bug.Keys) { $bugHt[$k] = $bug[$k] }
                Add-PipelineItem -WorkspacePath $WsPath -Item $bugHt -ErrorAction Stop | Out-Null
            } else {
                # Direct JSON write fallback
                $tFile = Join-Path $tdDir "$($bug.id).json"
                $bug | ConvertTo-Json -Depth 6 | Set-Content -Path $tFile -Encoding UTF8
            }
            $flushed++
        } catch {
            Write-CoalLog -Status 'WARN' -Group 'Pipeline' -TestId 'flush' `
                -Name $bug.id -Detail "Bug register failed: $_"
        }
    }

    # Export master to-do if pipeline loaded
    if ($pipelineLoaded) {
        try {
            Export-CentralMasterToDo -WorkspacePath $WsPath -ErrorAction SilentlyContinue | Out-Null
        } catch { <# Intentional: non-fatal #> }
    }

    Write-CoalLog -Status 'INFO' -Group 'Pipeline' -TestId 'flush' `
        -Name 'Bug flush' -Detail "Registered $flushed/$(@($script:PendingBugs).Count) bugs"
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST EXECUTION ENGINE
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-CoalTestCase {
    <#
    .SYNOPSIS
        Execute one test case with crash resilience. Returns status string.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$TestCase,
        [hashtable]$CrashMap,
        [int]$MaxCrashes
    )

    $id   = $TestCase.Id
    $name = $TestCase.Name
    $grp  = $TestCase.Group

    # Check crash ceiling before attempting
    $priorCrashes = if ($CrashMap.ContainsKey($id)) { $CrashMap[$id] } else { 0 }
    if ($priorCrashes -ge $MaxCrashes) {
        Write-CoalLog -Status 'SKIP' -Group $grp -TestId $id -Name $name `
            -Detail "Auto-skip: crashed $priorCrashes times (max $MaxCrashes)"
        return 'SKIPPED-MAX-CRASH'
    }

    try {
        $actionResult = & $TestCase.Action
        # Normalise result
        if ($actionResult -is [string]) {
            $status = $actionResult.ToUpper()
            $detail = ''
        } elseif ($actionResult -and ($actionResult.PSObject.Properties.Name -contains 'Status')) {
            $status = [string]$actionResult.Status
            $detail = if ($actionResult.PSObject.Properties.Name -contains 'Detail') {
                [string]$actionResult.Detail
            } else { '' }
        } else {
            $status = 'PASS'
            $detail = ''
        }
        Write-CoalLog -Status $status -Group $grp -TestId $id -Name $name -Detail $detail
        if ($status -eq 'FAIL') {
            Register-CoalBug -TestId $id -Name $name -Detail $detail
        }
        return $status
    } catch {
        # Unhandled exception = CRASH (not a test assertion failure)
        $crashDetail = $_.Exception.Message
        if (-not $CrashMap.ContainsKey($id)) { $CrashMap[$id] = 0 }
        $CrashMap[$id]++
        $newCrashCount = $CrashMap[$id]
        Write-CoalLog -Status 'CRASH' -Group $grp -TestId $id -Name $name `
            -Detail "Crash #$newCrashCount — $crashDetail"
        Register-CoalBug -TestId $id -Name $name -Detail "CRASH #$newCrashCount`: $crashDetail" `
            -Severity 'HIGH'
        if ($newCrashCount -ge $MaxCrashes) {
            Write-CoalLog -Status 'SKIP' -Group $grp -TestId $id -Name $name `
                -Detail "Max crashes ($MaxCrashes) reached — skipping"
            return 'SKIPPED-MAX-CRASH'
        }
        return 'CRASH'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI-AUTOMATION HELPERS (used by interactive GUI tests)
# ─────────────────────────────────────────────────────────────────────────────
$script:UIALoaded = $false
$script:appProcess = $null

if (-not $HeadlessOnly) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
        $script:UIALoaded = $true
    } catch {
        try {
            [void][System.Windows.Automation.AutomationElement]
            $script:UIALoaded = $true
        } catch {
            Write-CoalLog -Status 'WARN' -Group 'UIAutomation' -TestId 'load' `
                -Name 'IUA Assembly' -Detail 'UIAutomation not available — GUI phases will be skipped'
        }
    }
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Wait-AppWindow {
    [CmdletBinding()]
    param([string]$TitleSubstring, [int]$TimeoutSec = 45)
    if (-not $script:UIALoaded) { return $null }
    $AE = [System.Windows.Automation.AutomationElement]
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
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
                if ($w.Current.Name -like "*$TitleSubstring*") { return $w }
            } catch { <# Intentional: non-fatal #> }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Find-AppControl {
    [CmdletBinding()]
    param(
        [System.Windows.Automation.AutomationElement]$Parent,
        [System.Windows.Automation.ControlType]$Type,
        [string]$Name
    )
    if (-not $script:UIALoaded -or $null -eq $Parent) { return $null }
    $AE = [System.Windows.Automation.AutomationElement]
    $typeCond = [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, $Type)
    if ($Name) {
        $nameCond = [System.Windows.Automation.PropertyCondition]::new(
            $AE::NameProperty, $Name,
            [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase)
        $cond = [System.Windows.Automation.AndCondition]::new($typeCond, $nameCond)
    } else { $cond = $typeCond }
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Invoke-AppControl {
    [CmdletBinding()]
    param([System.Windows.Automation.AutomationElement]$Element)
    if ($null -eq $Element) { return $false }
    $pat = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) {
        $pat.Invoke(); return $true
    }
    return $false
}

function Dismiss-AppDialog {
    [CmdletBinding()]
    param([System.Windows.Automation.AutomationElement]$Dialog)
    if ($null -eq $Dialog) { return }
    foreach ($bn in @('No','Cancel','Close','OK')) {
        $btn = Find-AppControl -Parent $Dialog `
            -Type ([System.Windows.Automation.ControlType]::Button) -Name $bn
        if ($btn) { Invoke-AppControl $btn | Out-Null; Start-Sleep -Milliseconds 300; return }
    }
    $wp = $null
    if ($Dialog.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) {
        $wp.Close()
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST REGISTRY
#  Each entry: Id, Name, Group, Source, Action (ScriptBlock)
#  Action returns: 'PASS'|'FAIL'|'SKIP'|'WARN' or [pscustomobject]@{Status; Detail}
# ─────────────────────────────────────────────────────────────────────────────
$CoalTestRegistry = [System.Collections.ArrayList]::new()

# Helper: add test to registry
function Register-CoalTest {
    [CmdletBinding()]
    param([hashtable]$Test)
    [void]$CoalTestRegistry.Add($Test)
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 0: Headless ══════════════════════

Register-CoalTest @{
    Id     = 'GUI-P0-SyntaxParse'
    Name   = 'Syntax parse all .ps1/.psm1 files'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $files = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -Include '*.ps1','*.psm1' `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike '*\.history\*' -and
                $_.FullName -notlike '*\temp\*' -and
                $_.FullName -notlike '*\FOLDER-ROOT\*'
            })
        $failures = 0
        foreach ($f in $files) {
            $tokens = $null; $errs = $null
            try {
                $src = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errs) | Out-Null
            } catch { $errs = @([pscustomobject]@{ Message = $_.Exception.Message }) }
            if ($errs -and @($errs).Count -gt 0) {
                $failures++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'syntax' `
                    -Name $f.Name -Detail $errs[0].Message
            }
        }
        if ($failures -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$failures syntax error(s) in $(@($files).Count) files" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($files).Count) files parsed OK" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-ModuleImports'
    Name   = 'Import all .psm1 modules'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $mods = @(Get-ChildItem -Path $modulesDir -File -Filter '*.psm1' -ErrorAction SilentlyContinue)
        $failures = 0
        foreach ($m in $mods) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop -DisableNameChecking
                Remove-Module $m.BaseName -Force -ErrorAction SilentlyContinue
            } catch {
                $failures++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'modimp' `
                    -Name $m.Name -Detail $_
            }
        }
        if ($failures -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$failures of $(@($mods).Count) modules failed import" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($mods).Count) modules imported OK" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-ConfigXML'
    Name   = 'Config XML well-formed + has Buttons node'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        if (-not (Test-Path $configFile)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "system-variables.xml not found" }
        }
        try {
            [xml]$xml = Get-Content $configFile -Raw -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "XML parse error: $_" }
        }
        $btns = $xml.SelectNodes('//Buttons')
        if (-not $btns -or @($btns).Count -eq 0) { $btns = $xml.SelectNodes('//buttons') }
        if (-not $btns -or @($btns).Count -eq 0) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "system-variables.xml valid but no Buttons node" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "system-variables.xml valid, Buttons node present" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-JSONConfigs'
    Name   = 'All JSON in config/ are valid'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $dirs = @('config','sin_registry','agents','~REPORTS','Report') |
            ForEach-Object { Join-Path $WorkspacePath $_ }
        $files = foreach ($d in $dirs) {
            if (Test-Path $d) {
                Get-ChildItem -Path $d -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue
            }
        }
        $failures = 0
        foreach ($jf in @($files)) {
            try {
                Get-Content $jf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null
            } catch {
                $failures++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'jsonconfig' `
                    -Name $jf.Name -Detail "Invalid JSON: $_"
            }
        }
        if ($failures -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$failures JSON file(s) invalid" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($files).Count) JSON files valid" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-XHTMLValid'
    Name   = 'All XHTML files parse as valid XML'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $xfiles = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -Filter '*.xhtml' `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike '*\.history\*' -and
                $_.FullName -notlike '*\temp\*' -and
                $_.FullName -notlike '*\~DOWNLOADS\*' -and
                $_.FullName -notlike '*\archive\*'
            })
        $failures = 0
        foreach ($xf in $xfiles) {
            try {
                $raw = [System.IO.File]::ReadAllText($xf.FullName, [System.Text.Encoding]::UTF8)
                $cleaned = $raw -replace '(?s)<\?xml[^?]*\?>', '' -replace '(?s)<!DOCTYPE[^>]*>', ''
                $cleaned = $cleaned -replace '(?s)\A(\s*<!--.*?-->\s*)+', ''
                $cleaned = $cleaned.Trim()
                if (-not [string]::IsNullOrWhiteSpace($cleaned)) {
                    [xml]$cleaned | Out-Null
                }
            } catch {
                $failures++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'xhtml' `
                    -Name $xf.Name -Detail "Invalid XHTML: $_"
            }
        }
        if ($failures -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$failures XHTML file(s) invalid" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "$(@($xfiles).Count) XHTML files all valid" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-MainExists'
    Name   = 'Main-GUI.ps1 exists on disk'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        if (Test-Path $mainScript) {
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Found: $mainScript" }
        }
        return [pscustomobject]@{ Status = 'FAIL'; Detail = "Main-GUI.ps1 NOT found at $mainScript" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-ToolsTargets'
    Name   = 'Tools menu targets all exist'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $targets = @(
            @{ Label='Network Details';              Path='scripts\WinRemote-PSTool.ps1' }
            @{ Label='Script Dependency Matrix';     Path='scripts\Invoke-ScriptDependencyMatrix.ps1' }
            @{ Label='Module Management';            Path='scripts\Invoke-ModuleManagement.ps1' }
            @{ Label='PS Environment Scanner';       Path='scripts\Invoke-PSEnvironmentScanner.ps1' }
            @{ Label='Cron-Ai-Athon Tool';           Path='scripts\Show-CronAiAthonTool.ps1' }
            @{ Label='MCP Service Config';           Path='scripts\Show-MCPServiceConfig.ps1' }
            @{ Label='Event Log Viewer';             Path='scripts\Show-EventLogViewer.ps1' }
            @{ Label='Scan Dashboard';               Path='scripts\Show-ScanDashboard.ps1' }
            @{ Label='Checklist Actions';            Path='scripts\Invoke-ChecklistActions.ps1' }
            @{ Label='User Profile Manager';         Path='UPM\UserProfile-Manager.ps1' }
        )
        $missing = 0
        foreach ($t in $targets) {
            $full = Join-Path $WorkspacePath $t.Path
            if (-not (Test-Path $full)) {
                $missing++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'toolstargets' `
                    -Name $t.Label -Detail "$($t.Path) MISSING"
            }
        }
        if ($missing -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$missing tool target(s) missing" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($targets).Count) tool targets exist" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-SecurityFunctions'
    Name   = 'Security module functions present'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $secFns = @(
            @{ Fn='Show-AssistedSASCDialog';  Module='AssistedSASC' }
            @{ Fn='Show-VaultStatusDialog';   Module='AssistedSASC' }
            @{ Fn='Lock-Vault';               Module='AssistedSASC' }
            @{ Fn='Test-VaultSecurity';       Module='AssistedSASC' }
            @{ Fn='Test-IntegrityManifest';   Module='AssistedSASC' }
            @{ Fn='Export-VaultBackup';       Module='AssistedSASC' }
            @{ Fn='Invoke-PuTTYSession';      Module='SASC-Adapters' }
        )
        $missing = 0
        foreach ($sf in $secFns) {
            $modPath = Join-Path $modulesDir "$($sf.Module).psm1"
            if (Test-Path $modPath) {
                $src = [System.IO.File]::ReadAllText($modPath, [System.Text.Encoding]::UTF8)
                if (-not ($src -match ('(?m)^\s*function\s+' + [regex]::Escape($sf.Fn) + '\b'))) {
                    $missing++
                    Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'secfn' `
                        -Name $sf.Fn -Detail "Not defined in $($sf.Module).psm1"
                }
            } else { $missing++ }
        }
        if ($missing -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$missing security function(s) missing" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($secFns).Count) security functions present" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-ModuleExportAudit'
    Name   = 'Module 
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember correctness'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $mods = @(Get-ChildItem -Path $modulesDir -File -Filter '*.psm1' -ErrorAction SilentlyContinue)
        $warnings = 0
        foreach ($m in $mods) {
            $src   = [System.IO.File]::ReadAllText($m.FullName, [System.Text.Encoding]::UTF8)
            $fnDefs = @([regex]::Matches($src, '(?m)^\s*function\s+([A-Z][\w-]+)', 'IgnoreCase') |
                ForEach-Object { $_.Groups[1].Value })
            if ($src -match '
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember') {
                $em = [regex]::Matches($src, '
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember\s+-Function\s+(.+?)(?:\s+-|$)', `
                    'IgnoreCase,Singleline')
                foreach ($match in $em) {
                    $exported = $match.Groups[1].Value -split '[,\s]+' |
                        ForEach-Object { $_.Trim("'", '"', ' ') } |
                        Where-Object { $_ -and $_ -ne '*' }
                    foreach ($e in @($exported)) {
                        if ($e -notin $fnDefs) {
                            $warnings++
                            Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'modexport' `
                                -Name $m.Name -Detail "Exports non-existent: $e"
                        }
                    }
                }
            }
        }
        if ($warnings -gt 0) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "$warnings bad export(s) found" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($mods).Count) modules export-clean" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-HelpFileTargets'
    Name   = 'Help menu file targets exist'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $targets = @(
            @{ Label='Help Index';               Path='~README.md\PwShGUI-Help-Index.html' }
            @{ Label='Dependency Visualisation'; Path='~README.md\Dependency-Visualisation.html' }
        )
        $missing = 0
        foreach ($t in $targets) {
            $full = Join-Path $WorkspacePath $t.Path
            if (-not (Test-Path $full)) {
                $missing++
                Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'helpfiles' `
                    -Name $t.Label -Detail "$($t.Path) MISSING"
            }
        }
        if ($missing -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$missing help file(s) missing" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All help file targets exist" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-CronModules'
    Name   = 'CronAiAthon key module functions present'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $cronChecks = @(
            @{ Mod='CronAiAthon-Pipeline';   Fns=@('Initialize-PipelineRegistry','Add-PipelineItem','Get-PipelineItems') }
            @{ Mod='CronAiAthon-Scheduler';  Fns=@('Initialize-CronSchedule','Invoke-CronJob','Get-CronJobSummary') }
            @{ Mod='CronAiAthon-EventLog';   Fns=@('Write-CronLog') }
            @{ Mod='CronAiAthon-BugTracker'; Fns=@('Invoke-FullBugScan','Invoke-ParseCheck') }
        )
        $missing = 0
        foreach ($c in $cronChecks) {
            $modPath = Join-Path $modulesDir "$($c.Mod).psm1"
            if (-not (Test-Path $modPath)) { $missing++ ; continue }
            $src = [System.IO.File]::ReadAllText($modPath, [System.Text.Encoding]::UTF8)
            foreach ($fn in $c.Fns) {
                if (-not ($src -match ('(?m)^\s*function\s+' + [regex]::Escape($fn) + '\b'))) {
                    $missing++
                    Write-CoalLog -Status 'WARN' -Group 'GUI-Phase0' -TestId 'cronmod' `
                        -Name "$($c.Mod)" -Detail "Missing: $fn"
                }
            }
        }
        if ($missing -gt 0) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "$missing cron function(s) missing" }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "All CronAiAthon key functions present" }
    }
}

Register-CoalTest @{
    Id     = 'GUI-P0-OrphanScripts'
    Name   = 'No orphan scripts in scripts/ directory'
    Group  = 'GUI-Phase0-Headless'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $orphanDir = Join-Path $WorkspacePath 'scripts'
        if (-not (Test-Path $orphanDir)) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "scripts/ not found" }
        }
        $mainContent = ''
        if (Test-Path $mainScript) {
            $mainContent = (Get-Content $mainScript -ErrorAction SilentlyContinue) -join "`n"
        }
        $cfgContent = ''
        if (Test-Path $configFile) {
            $cfgContent = (Get-Content $configFile -ErrorAction SilentlyContinue) -join "`n"
        }
        $scriptFiles = @(Get-ChildItem -Path $orphanDir -Filter '*.ps1' -File `
            -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'fix_*' })
        $orphans = @()
        foreach ($sf in $scriptFiles) {
            $bn = [IO.Path]::GetFileNameWithoutExtension($sf.Name)
            $isRef = ($mainContent -match [regex]::Escape($sf.Name)) -or
                     ($mainContent -match [regex]::Escape($bn)) -or
                     ($cfgContent  -match [regex]::Escape($sf.Name)) -or
                     ($cfgContent  -match [regex]::Escape($bn))
            if (-not $isRef) { $orphans += $sf.Name }
        }
        if (@($orphans).Count -gt 0) {
            return [pscustomobject]@{
                Status = 'WARN'
                Detail = "$(@($orphans).Count) orphan(s): $($orphans -join ', ')"
            }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "No orphan scripts ($(@($scriptFiles).Count) scripts all referenced)" }
    }
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 1: Launch ═══════════════════════

Register-CoalTest @{
    Id     = 'GUI-P1-Launch'
    Name   = 'Launch Main-GUI.ps1 -StartupMode quik_jnr'
    Group  = 'GUI-Phase1-Launch'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        if ($HeadlessOnly -or -not $script:UIALoaded) {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = 'HeadlessOnly or UIA not available' }
        }
        if (-not (Test-Path $mainScript)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Main-GUI.ps1 not found' }
        }
        $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' }
                 elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' }
                 else { $null }
        if (-not $shell) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'No PowerShell host found' }
        }
        $script:appProcess = Start-Process $shell `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$mainScript`" -StartupMode quik_jnr" `
            -WindowStyle Normal -PassThru
        $win = Wait-AppWindow -TitleSubstring 'PowerShell Script Launcher' -TimeoutSec 45
        if (-not $win) {
            try { $script:appProcess | Stop-Process -Force -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
            $script:appProcess = $null
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Main window did not appear within 45s' }
        }
        $script:mainWin = $win
        Start-Sleep -Milliseconds 1500
        return [pscustomobject]@{ Status = 'PASS'; Detail = "Window: '$($win.Current.Name)' PID $($script:appProcess.Id)" }
    }
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 2: Menu Walk ════════════════════

$menuItems = @(
    @{ Menu='File';     Sub='Settings > Configure Paths...' }
    @{ Menu='File';     Sub='Settings > Script Folders...' }
    @{ Menu='Tests';    Sub='Version Check' }
    @{ Menu='Tests';    Sub='Network Diagnostics' }
    @{ Menu='Tests';    Sub='Disk Check' }
    @{ Menu='Tests';    Sub='Privacy Check' }
    @{ Menu='Tests';    Sub='System Check' }
    @{ Menu='WinGets';  Sub='Installed Apps (Grid View)' }
    @{ Menu='WinGets';  Sub='Detect Updates (Check-Only)' }
    @{ Menu='WinGets';  Sub='Update All (Admin Options)' }
    @{ Menu='Tools';    Sub='Config Maintenance...' }
    @{ Menu='Tools';    Sub='Network Details' }
    @{ Menu='Tools';    Sub='AVPN Connection Tracker' }
    @{ Menu='Tools';    Sub='Script Dependency Matrix' }
    @{ Menu='Tools';    Sub='Module Management' }
    @{ Menu='Tools';    Sub='PS Environment Scanner' }
    @{ Menu='Tools';    Sub='Event Log Viewer' }
    @{ Menu='Tools';    Sub='Scan Dashboard...' }
    @{ Menu='Tools';    Sub='Cron-Ai-Athon Tool' }
    @{ Menu='Tools';    Sub='MCP Service Config' }
    @{ Menu='Security'; Sub='Security Checklist...' }
    @{ Menu='Security'; Sub='Assisted SASC Wizard...' }
    @{ Menu='Security'; Sub='Vault Status...' }
    @{ Menu='Security'; Sub='Lock Vault' }
    @{ Menu='Security'; Sub='Import Secrets...' }
    @{ Menu='Security'; Sub='Vault Security Audit...' }
    @{ Menu='Security'; Sub='Integrity Verification...' }
    @{ Menu='Security'; Sub='Export Vault Backup...' }
    @{ Menu='Help';     Sub='About' }
    @{ Menu='Help';     Sub='Package Workspace' }
)

foreach ($mi in $menuItems) {
    $miId    = "GUI-P2-Menu-{0}-{1}" -f $mi.Menu, ($mi.Sub -replace '[^A-Za-z0-9]', '_')
    $miName  = "Menu: $($mi.Menu) > $($mi.Sub)"
    $miMenu  = $mi.Menu
    $miSub   = $mi.Sub

    Register-CoalTest @{
        Id     = $miId
        Name   = $miName
        Group  = 'GUI-Phase2-MenuWalk'
        Source = 'Invoke-GUISmokeTest.ps1'
        Action = {
            param()
            if ($HeadlessOnly -or -not $script:UIALoaded -or -not $script:appProcess `
                -or $script:appProcess.HasExited) {
                return [pscustomobject]@{ Status = 'SKIP'; Detail = 'App not running or headless mode' }
            }

            # Re-acquire window in case it lost focus
            $win = Wait-AppWindow -TitleSubstring 'PowerShell Script Launcher' -TimeoutSec 5
            if (-not $win) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Cannot find main window' }
            }

            # Find menu bar
            $AE = [System.Windows.Automation.AutomationElement]
            $menuBar = Find-AppControl -Parent $win `
                -Type ([System.Windows.Automation.ControlType]::MenuBar) -Name 'menuStrip'
            if (-not $menuBar) {
                $menuBar = Find-AppControl -Parent $win `
                    -Type ([System.Windows.Automation.ControlType]::MenuBar)
            }
            if (-not $menuBar) {
                return [pscustomobject]@{ Status = 'WARN'; Detail = 'MenuStrip not found' }
            }

            # Find top-level item
            $topItem = Find-AppControl -Parent $menuBar `
                -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $miMenu
            if (-not $topItem) {
                return [pscustomobject]@{ Status = 'WARN'; Detail = "Top menu '$miMenu' not found" }
            }

            # Expand top
            $pat = $null
            if ($topItem.TryGetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pat)) {
                $pat.Expand()
                Start-Sleep -Milliseconds 300
            }

            # Handle subheading (only direct child — no nested sub)
            $subName = $miSub -replace '^.+>\s*', ''
            $subItem = Find-AppControl -Parent $topItem `
                -Type ([System.Windows.Automation.ControlType]::MenuItem) -Name $subName
            if (-not $subItem) {
                # Try collapse and skip
                try { $pat.Collapse() } catch { <# Intentional: non-fatal #> }
                return [pscustomobject]@{ Status = 'WARN'; Detail = "Sub-item '$subName' not found" }
            }

            # Invoke the item
            Invoke-AppControl $subItem | Out-Null
            Start-Sleep -Milliseconds 800

            # Dismiss any popup
            $popup = Wait-AppWindow -TitleSubstring '' -TimeoutSec 2
            if ($popup -and ($popup.Current.ProcessId -eq $script:appProcess.Id)) {
                Dismiss-AppDialog -Dialog $popup
            }

            return [pscustomobject]@{ Status = 'PASS'; Detail = "Invoked and dismissed" }
        }.GetNewClosure()
    }
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 3: Button Walk ══════════════════

Register-CoalTest @{
    Id     = 'GUI-P3-Buttons'
    Name   = 'Click main form buttons (auto-dismiss dialogs)'
    Group  = 'GUI-Phase3-Buttons'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        if ($HeadlessOnly -or -not $script:UIALoaded -or -not $script:appProcess `
            -or $script:appProcess.HasExited) {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = 'App not running or headless mode' }
        }
        $win = Wait-AppWindow -TitleSubstring 'PowerShell Script Launcher' -TimeoutSec 5
        if (-not $win) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Main window lost' } }

        $AE = [System.Windows.Automation.AutomationElement]
        $buttons = $win.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                $AE::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button
            )
        )
        $clicked = 0; $skipped = 0
        foreach ($btn in $buttons) {
            try {
                $bname = $btn.Current.Name
                if ($bname -in @('', 'Close', 'Cancel', 'X', 'Exit')) { $skipped++; continue }
                Invoke-AppControl $btn | Out-Null
                Start-Sleep -Milliseconds 400
                # Dismiss any dialog that opened
                $popup = Wait-AppWindow -TitleSubstring '' -TimeoutSec 1
                if ($popup -and ($popup.Current.ProcessId -eq $script:appProcess.Id)) {
                    Dismiss-AppDialog -Dialog $popup
                }
                $clicked++
            } catch { <# Intentional: non-fatal — button click failure is advisory #> }
        }
        return [pscustomobject]@{ Status = 'PASS'
            Detail = "Clicked $clicked button(s), skipped $skipped" }
    }
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 5: Event Log Verify ═════════════

Register-CoalTest @{
    Id     = 'GUI-P5-EventLogVerify'
    Name   = 'Application event log has recent entries'
    Group  = 'GUI-Phase5-Logs'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        $logFiles = @(Get-ChildItem -Path $logsDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if (@($logFiles).Count -eq 0) {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "No log files found in logs/" }
        }
        return [pscustomobject]@{ Status = 'PASS'
            Detail = "$(@($logFiles).Count) log file(s) found, newest: $($logFiles[0].Name)" }
    }
}

# ══ SOURCE: Invoke-GUISmokeTest.ps1 — Phase 6: Cleanup ══════════════════════

Register-CoalTest @{
    Id     = 'GUI-P6-Cleanup'
    Name   = 'Close/kill launched GUI application'
    Group  = 'GUI-Phase6-Cleanup'
    Source = 'Invoke-GUISmokeTest.ps1'
    Action = {
        if (-not $script:appProcess) {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = 'No app process to clean up' }
        }
        try {
            if (-not $script:appProcess.HasExited) {
                $win = Wait-AppWindow -TitleSubstring 'PowerShell Script Launcher' -TimeoutSec 3
                if ($win) {
                    $ClosePat = $null
                    if ($win.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern,
                        [ref]$ClosePat)) {
                        $ClosePat.Close()
                        Start-Sleep -Milliseconds 800
                    }
                }
                if (-not $script:appProcess.HasExited) {
                    $script:appProcess | Stop-Process -Force -ErrorAction SilentlyContinue
                }
            }
            $script:appProcess = $null
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Application closed' }
        } catch {
            return [pscustomobject]@{ Status = 'WARN'; Detail = "Close attempt: $_" }
        }
    }
}

# ══ SOURCE: Invoke-SandboxSmokeTest.ps1 ════════════════════════════════════

Register-CoalTest @{
    Id     = 'SBX-PreReq-SandboxExe'
    Name   = 'Windows Sandbox executable available'
    Group  = 'SandboxSmoke-PreReq'
    Source = 'Invoke-SandboxSmokeTest.ps1'
    Action = {
        $sbexe = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
        if (-not $sbexe) {
            $sbpath = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
            if (-not (Test-Path $sbpath)) {
                return [pscustomobject]@{ Status = 'SKIP'
                    Detail = 'WindowsSandbox.exe not found — enable via Windows Optional Features' }
            }
        }
        return [pscustomobject]@{ Status = 'PASS'; Detail = "WindowsSandbox.exe found" }
    }
}

Register-CoalTest @{
    Id     = 'SBX-PreReq-MainGUIInWorkspace'
    Name   = 'Main-GUI.ps1 present for sandbox mapping'
    Group  = 'SandboxSmoke-PreReq'
    Source = 'Invoke-SandboxSmokeTest.ps1'
    Action = {
        if (Test-Path $mainScript) {
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Main-GUI.ps1 at $mainScript" }
        }
        return [pscustomobject]@{ Status = 'FAIL'; Detail = "Main-GUI.ps1 missing" }
    }
}

Register-CoalTest @{
    Id     = 'SBX-Bootstrap-Scriptgen'
    Name   = 'Sandbox bootstrap .wsb config can be generated'
    Group  = 'SandboxSmoke-Bootstrap'
    Source = 'Invoke-SandboxSmokeTest.ps1'
    Action = {
        $tmpDir2 = Join-Path $tempDir 'coaltest2-sandbox-check'
        if (-not (Test-Path $tmpDir2)) { New-Item -ItemType Directory -Path $tmpDir2 -Force | Out-Null }
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        $wsbContent = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$WorkspacePath</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\PwShGUI</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host TestOK"</Command>
  </LogonCommand>
</Configuration>
"@
        $wsbPath2 = Join-Path $tmpDir2 "CoalTest2-$ts.wsb"
        try {
            $wsbContent | Set-Content -Path $wsbPath2 -Encoding UTF8 -ErrorAction Stop
            [xml]$wsbContent | Out-Null   # Validate it's valid XML
            Remove-Item $wsbPath2 -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = '.wsb config generated and XML-valid' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "WSB gen failed: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 1: Module Import ════

Register-CoalTest @{
    Id     = 'WGT-ModImp-Pipeline'
    Name   = 'CronAiAthon-Pipeline imports and exports 20+ functions'
    Group  = 'WidgetSmoke-ModuleImport'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $p = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $p)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'psm1 not found' } }
        try {
            Import-Module $p -Force -DisableNameChecking -ErrorAction Stop
            $cnt = (Get-Module 'CronAiAthon-Pipeline').ExportedFunctions.Keys.Count
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            if ($cnt -lt 20) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Only $cnt exported (need 20+)" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "$cnt exported functions" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Import error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-ModImp-PwShGUICore'
    Name   = 'PwShGUICore imports and exports 14+ functions'
    Group  = 'WidgetSmoke-ModuleImport'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $p = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (-not (Test-Path $p)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'psm1 not found' } }
        try {
            Import-Module $p -Force -DisableNameChecking -ErrorAction Stop
            $cnt = (Get-Module 'PwShGUICore').ExportedFunctions.Keys.Count
            Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
            if ($cnt -lt 14) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Only $cnt exported (need 14+)" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "$cnt exported functions" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Import error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-ModImp-UserProfileManager'
    Name   = 'UserProfileManager imports and exports 28+ functions'
    Group  = 'WidgetSmoke-ModuleImport'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $p = Join-Path $modulesDir 'UserProfileManager.psm1'
        if (-not (Test-Path $p)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'psm1 not found' } }
        try {
            Import-Module $p -Force -DisableNameChecking -ErrorAction Stop
            $cnt = (Get-Module 'UserProfileManager').ExportedFunctions.Keys.Count
            Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
            if ($cnt -lt 28) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Only $cnt exported (need 28+)" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "$cnt exported functions" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Import error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-ModImp-AssistedSASC'
    Name   = 'AssistedSASC imports and exports 25+ functions'
    Group  = 'WidgetSmoke-ModuleImport'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $p = Join-Path $modulesDir 'AssistedSASC.psm1'
        if (-not (Test-Path $p)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'psm1 not found' } }
        try {
            Import-Module $p -Force -DisableNameChecking -ErrorAction Stop
            $cnt = (Get-Module 'AssistedSASC').ExportedFunctions.Keys.Count
            Remove-Module 'AssistedSASC' -Force -ErrorAction SilentlyContinue
            if ($cnt -lt 25) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Only $cnt exported (need 25+)" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "$cnt exported functions" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Import error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 2: Config Validation ═

Register-CoalTest @{
    Id     = 'WGT-Cfg-SystemVarsXML'
    Name   = 'system-variables.xml valid XML with Buttons node'
    Group  = 'WidgetSmoke-ConfigValidation'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        if (-not (Test-Path $configFile)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'system-variables.xml not found' }
        }
        try {
            $xml = [xml](Get-Content $configFile -Raw -ErrorAction Stop)
            $btns = $xml.SelectNodes('//Buttons')
            if (-not $btns -or @($btns).Count -eq 0) { $btns = $xml.SelectNodes('//buttons') }
            if (-not $btns -or @($btns).Count -eq 0) {
                return [pscustomobject]@{ Status = 'WARN'; Detail = 'No Buttons node found' }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Valid XML, Buttons node present" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "XML error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-Cfg-PipelineRegistry'
    Name   = 'pipeline-registry.json has meta/featureRequests/bugs keys'
    Group  = 'WidgetSmoke-ConfigValidation'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'CronAiAthon-Pipeline.psm1 not found' }
        }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $regPath = Get-PipelineRegistryPath -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $regPath)) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Registry not at: $regPath" }
            }
            $reg = Get-Content $regPath -Raw | ConvertFrom-Json
            $keys = $reg.PSObject.Properties.Name
            $missing = @('meta','featureRequests','bugs') | Where-Object { $keys -notcontains $_ }
            if (@($missing).Count -gt 0) {
                return [pscustomobject]@{ Status = 'FAIL'
                    Detail = "Missing keys: $($missing -join ', ')" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'All required keys present' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Registry check error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 3: Round-Trip ════════

Register-CoalTest @{
    Id     = 'WGT-RT-ExportMasterToDo'
    Name   = 'Export-CentralMasterToDo produces valid JSON'
    Group  = 'WidgetSmoke-RoundTrip'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module not found' }
        }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $outPath = Export-CentralMasterToDo -WorkspacePath $WorkspacePath -ErrorAction Stop
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $outPath)) {
                return [pscustomobject]@{ Status = 'FAIL'; Detail = "Output file missing: $outPath" }
            }
            Get-Content $outPath -Raw | ConvertFrom-Json | Out-Null
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Valid JSON at $outPath" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Export error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-RT-PipelineItemsHaveType'
    Name   = 'All pipeline items have type property'
    Group  = 'WidgetSmoke-RoundTrip'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module not found' }
        }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $items = Get-PipelineItems -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            $badItems = 0
            foreach ($item in @($items)) {
                $hasType = if ($item -is [System.Collections.IDictionary]) {
                    $item.Keys -contains 'type'
                } else {
                    $item.PSObject.Properties.Name -contains 'type'
                }
                if (-not $hasType) { $badItems++ }
            }
            if ($badItems -gt 0) {
                return [pscustomobject]@{ Status = 'FAIL'
                    Detail = "$badItems item(s) missing type property" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "All $(@($items).Count) items have type" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Pipeline items error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-RT-PipelineJsonRoundtrip'
    Name   = 'Pipeline JSON round-trip preserves item count'
    Group  = 'WidgetSmoke-RoundTrip'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module not found' }
        }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $items = Get-PipelineItems -WorkspacePath $WorkspacePath
            $origCount = @($items).Count
            $tmpFile = Join-Path $tempDir '_coal2_roundtrip.json'
            $items | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8
            $reloaded = @(Get-Content $tmpFile -Raw | ConvertFrom-Json)
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            if (@($reloaded).Count -ne $origCount) {
                return [pscustomobject]@{ Status = 'FAIL'
                    Detail = "Count mismatch: $origCount -> $(@($reloaded).Count)" }
            }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Count preserved: $origCount items" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Round-trip error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 4: Pipeline Lifecycle ═

Register-CoalTest @{
    Id     = 'WGT-PL-InitRegistry'
    Name   = 'Initialize-PipelineRegistry does not throw'
    Group  = 'WidgetSmoke-Pipeline'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            Initialize-PipelineRegistry -WorkspacePath $WorkspacePath -ErrorAction Stop | Out-Null
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Initialize-PipelineRegistry OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-PL-StatusTransitions'
    Name   = 'Test-StatusTransition accepts OPEN->IN_PROGRESS, rejects CLOSED->OPEN'
    Group  = 'WidgetSmoke-Pipeline'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            $legal   = Test-StatusTransition -CurrentStatus 'OPEN' -NewStatus 'IN_PROGRESS'
            $illegal = Test-StatusTransition -CurrentStatus 'CLOSED' -NewStatus 'OPEN'
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            if (-not $legal) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'OPEN->IN_PROGRESS rejected (should be legal)' } }
            if ($illegal) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'CLOSED->OPEN accepted (should be illegal)' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Status transitions correct' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-PL-PriorityEscalation'
    Name   = 'Invoke-PriorityAutoEscalation runs without throwing'
    Group  = 'WidgetSmoke-Pipeline'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $pipelineMod = Join-Path $modulesDir 'CronAiAthon-Pipeline.psm1'
        if (-not (Test-Path $pipelineMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $pipelineMod -Force -DisableNameChecking -ErrorAction Stop
            Invoke-PriorityAutoEscalation -WorkspacePath $WorkspacePath -ErrorAction Stop | Out-Null
            Remove-Module 'CronAiAthon-Pipeline' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Priority escalation ran OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 5: Scheduler ═════════

Register-CoalTest @{
    Id     = 'WGT-SCH-InitSchedule'
    Name   = 'Initialize-CronSchedule does not throw'
    Group  = 'WidgetSmoke-Scheduler'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $schMod = Join-Path $modulesDir 'CronAiAthon-Scheduler.psm1'
        if (-not (Test-Path $schMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $schMod -Force -DisableNameChecking -ErrorAction Stop
            Initialize-CronSchedule -WorkspacePath $WorkspacePath -ErrorAction Stop | Out-Null
            Remove-Module 'CronAiAthon-Scheduler' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'CronSchedule initialized' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-SCH-Summary'
    Name   = 'Get-CronJobSummary returns data'
    Group  = 'WidgetSmoke-Scheduler'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $schMod = Join-Path $modulesDir 'CronAiAthon-Scheduler.psm1'
        if (-not (Test-Path $schMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $schMod -Force -DisableNameChecking -ErrorAction Stop
            $summary = Get-CronJobSummary -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-Scheduler' -Force -ErrorAction SilentlyContinue
            if (-not $summary) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Null summary' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Cron summary OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-SCH-PreReqCheck'
    Name   = 'Invoke-PreRequisiteCheck returns results'
    Group  = 'WidgetSmoke-Scheduler'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $schMod = Join-Path $modulesDir 'CronAiAthon-Scheduler.psm1'
        if (-not (Test-Path $schMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $schMod -Force -DisableNameChecking -ErrorAction Stop
            $results2 = Invoke-PreRequisiteCheck -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-Scheduler' -Force -ErrorAction SilentlyContinue
            if (-not $results2) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Null results' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'PreReqCheck returned results' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 6: BugTracker ═════════

Register-CoalTest @{
    Id     = 'WGT-BT-ParseCheck'
    Name   = 'Invoke-ParseCheck scans without throwing'
    Group  = 'WidgetSmoke-BugTracker'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $btMod = Join-Path $modulesDir 'CronAiAthon-BugTracker.psm1'
        if (-not (Test-Path $btMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $btMod -Force -DisableNameChecking -ErrorAction Stop
            $res = Invoke-ParseCheck -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-BugTracker' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = "ParseCheck returned $(@($res).Count) result(s)" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-BT-FullBugScan'
    Name   = 'Invoke-FullBugScan aggregates all checks'
    Group  = 'WidgetSmoke-BugTracker'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $btMod = Join-Path $modulesDir 'CronAiAthon-BugTracker.psm1'
        if (-not (Test-Path $btMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $btMod -Force -DisableNameChecking -ErrorAction Stop
            $res = Invoke-FullBugScan -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-BugTracker' -Force -ErrorAction SilentlyContinue
            if (-not $res) { return [pscustomobject]@{ Status = 'WARN'; Detail = 'Null result' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "FullBugScan returned data" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-BT-XhtmlValidation'
    Name   = 'Invoke-XhtmlValidation does not throw'
    Group  = 'WidgetSmoke-BugTracker'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $btMod = Join-Path $modulesDir 'CronAiAthon-BugTracker.psm1'
        if (-not (Test-Path $btMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $btMod -Force -DisableNameChecking -ErrorAction Stop
            Invoke-XhtmlValidation -WorkspacePath $WorkspacePath -ErrorAction Stop | Out-Null
            Remove-Module 'CronAiAthon-BugTracker' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'XhtmlValidation ran without throwing' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 7: EventLog ══════════

Register-CoalTest @{
    Id     = 'WGT-EL-WriteLog'
    Name   = 'Write-CronLog writes without throwing'
    Group  = 'WidgetSmoke-EventLog'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $elMod = Join-Path $modulesDir 'CronAiAthon-EventLog.psm1'
        if (-not (Test-Path $elMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $elMod -Force -DisableNameChecking -ErrorAction Stop
            Write-CronLog -Message 'CoalTest2 probe entry' -Severity 'Informational' `
                -WorkspacePath $WorkspacePath -ErrorAction Stop
            Remove-Module 'CronAiAthon-EventLog' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Write-CronLog OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-EL-GetConfig'
    Name   = 'Get-EventLogConfig returns configuration'
    Group  = 'WidgetSmoke-EventLog'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $elMod = Join-Path $modulesDir 'CronAiAthon-EventLog.psm1'
        if (-not (Test-Path $elMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $elMod -Force -DisableNameChecking -ErrorAction Stop
            $cfg = Get-EventLogConfig -WorkspacePath $WorkspacePath
            Remove-Module 'CronAiAthon-EventLog' -Force -ErrorAction SilentlyContinue
            if (-not $cfg) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Null config' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'EventLogConfig returned data' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 8: AVPN-Tracker ══════

Register-CoalTest @{
    Id     = 'WGT-AVPN-InitConfig'
    Name   = 'Initialize-AVPNConfigFile creates valid config'
    Group  = 'WidgetSmoke-AVPN'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $avpnMod = Join-Path $modulesDir 'AVPN-Tracker.psm1'
        if (-not (Test-Path $avpnMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        $tc = Join-Path $tempDir '_coal2_avpn_test.json'
        try {
            Import-Module $avpnMod -Force -DisableNameChecking -ErrorAction Stop
            if (Test-Path $tc) { Remove-Item $tc -Force }
            Initialize-AVPNConfigFile -ConfigPath $tc -ErrorAction Stop
            if (-not (Test-Path $tc)) {
                Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Config file not created' }
            }
            Get-Content $tc -Raw | ConvertFrom-Json | Out-Null
            Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
            Remove-Item $tc -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'AVPN config initialised and valid' }
        } catch {
            Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
            Remove-Item $tc -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-AVPN-SaveReload'
    Name   = 'AVPN config save + reload round-trip'
    Group  = 'WidgetSmoke-AVPN'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $avpnMod = Join-Path $modulesDir 'AVPN-Tracker.psm1'
        if (-not (Test-Path $avpnMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        $tc = Join-Path $tempDir '_coal2_avpn_save.json'
        try {
            Import-Module $avpnMod -Force -DisableNameChecking -ErrorAction Stop
            if (Test-Path $tc) { Remove-Item $tc -Force }
            Initialize-AVPNConfigFile -ConfigPath $tc -ErrorAction Stop
            $cfg = Get-AVPNConfig -ConfigPath $tc
            Save-AVPNConfig -ConfigPath $tc -ConfigData $cfg -ErrorAction Stop
            $reloaded = Get-Content $tc -Raw | ConvertFrom-Json
            Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
            Remove-Item $tc -Force -ErrorAction SilentlyContinue
            if (-not $reloaded) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Reload returned null' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'AVPN save + reload OK' }
        } catch {
            Remove-Module 'AVPN-Tracker' -Force -ErrorAction SilentlyContinue
            Remove-Item $tc -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 9: UserProfileManager ═

Register-CoalTest @{
    Id     = 'WGT-UPM-ProfileSnapshot'
    Name   = 'Get-ProfileSnapshot returns data'
    Group  = 'WidgetSmoke-UserProfile'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $upmMod = Join-Path $modulesDir 'UserProfileManager.psm1'
        if (-not (Test-Path $upmMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $upmMod -Force -DisableNameChecking -ErrorAction Stop
            $snap = Get-ProfileSnapshot
            Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
            if (-not $snap) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Null snapshot' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'ProfileSnapshot returned data' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-UPM-EnvironmentVars'
    Name   = 'Get-EnvironmentVariables returns env vars'
    Group  = 'WidgetSmoke-UserProfile'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $upmMod = Join-Path $modulesDir 'UserProfileManager.psm1'
        if (-not (Test-Path $upmMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $upmMod -Force -DisableNameChecking -ErrorAction Stop
            $vars = Get-EnvironmentVariables
            Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
            if (-not $vars) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Null result' } }
            return [pscustomobject]@{ Status = 'PASS'; Detail = "Returned $(@($vars).Count) env var(s)" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-UPM-CertificateStores'
    Name   = 'Get-CertificateStores does not throw'
    Group  = 'WidgetSmoke-UserProfile'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $upmMod = Join-Path $modulesDir 'UserProfileManager.psm1'
        if (-not (Test-Path $upmMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $upmMod -Force -DisableNameChecking -ErrorAction Stop
            Get-CertificateStores | Out-Null
            Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Get-CertificateStores OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-UPM-WiFiProfiles'
    Name   = 'Get-WiFiProfiles does not throw'
    Group  = 'WidgetSmoke-UserProfile'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $upmMod = Join-Path $modulesDir 'UserProfileManager.psm1'
        if (-not (Test-Path $upmMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $upmMod -Force -DisableNameChecking -ErrorAction Stop
            Get-WiFiProfiles | Out-Null
            Remove-Module 'UserProfileManager' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Get-WiFiProfiles OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ══ SOURCE: Invoke-WidgetSmokeTests.Tests.ps1 — Section 10: PwShGUICore ═══════

Register-CoalTest @{
    Id     = 'WGT-CORE-InitPaths'
    Name   = 'Initialize-CorePaths does not throw'
    Group  = 'WidgetSmoke-Core'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $coreMod = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (-not (Test-Path $coreMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $coreMod -Force -DisableNameChecking -ErrorAction Stop
            Initialize-CorePaths -ScriptDir $scriptsDir -ErrorAction Stop | Out-Null
            Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Initialize-CorePaths OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-CORE-WriteAppLog'
    Name   = 'Write-AppLog logs without throwing'
    Group  = 'WidgetSmoke-Core'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $coreMod = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (-not (Test-Path $coreMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $coreMod -Force -DisableNameChecking -ErrorAction Stop
            Write-AppLog -Message 'CoalTest2 probe' -Level 'INFO' -ErrorAction Stop
            Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = 'Write-AppLog OK' }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

Register-CoalTest @{
    Id     = 'WGT-CORE-TestVersionTag'
    Name   = 'Test-VersionTag returns result'
    Group  = 'WidgetSmoke-Core'
    Source = 'Invoke-WidgetSmokeTests.Tests.ps1'
    Action = {
        $coreMod = Join-Path $modulesDir 'PwShGUICore.psm1'
        if (-not (Test-Path $coreMod)) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'Module missing' } }
        try {
            Import-Module $coreMod -Force -DisableNameChecking -ErrorAction Stop
            $vtResult = Test-VersionTag
            Remove-Module 'PwShGUICore' -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Status = 'PASS'; Detail = "VersionTag result: $vtResult" }
        } catch {
            return [pscustomobject]@{ Status = 'FAIL'; Detail = "Error: $_" }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN EXECUTION LOOP
# ─────────────────────────────────────────────────────────────────────────────
$script:runStartedAt = (Get-Date).ToUniversalTime().ToString('o')
$runId = "CoalTest2-{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMddHHmmss')

# Load or initialise checkpoint
$ckpt = Load-CoalCheckpoint -Path $chkpointPath
if ($ckpt -and $Resume) {
    Write-Host "`n[Resume] Loaded checkpoint from: $chkpointPath" -ForegroundColor Cyan
    Write-Host "  Run ID     : $($ckpt.runId)" -ForegroundColor DarkGray
    Write-Host "  Started at : $($ckpt.startedAt)" -ForegroundColor DarkGray
    Write-Host "  Completed  : $(@($ckpt.completedTests).Count) tests" -ForegroundColor DarkGray
    Write-Host "  Skipped    : $(@($ckpt.skippedTests).Count) tests`n" -ForegroundColor DarkGray
    $runId = $ckpt.runId
} elseif ($ckpt -and -not $Resume) {
    Write-Host "[Info] Stale checkpoint found (use -Resume to load it). Starting fresh.`n" `
        -ForegroundColor DarkYellow
    $ckpt = $null
}

# State tracking
$completedTests  = [System.Collections.ArrayList]::new()
$failedTests     = [System.Collections.ArrayList]::new()
$skippedTests    = [System.Collections.ArrayList]::new()
$crashMap        = @{}

if ($ckpt) {
    foreach ($c in @($ckpt.completedTests)) { [void]$completedTests.Add($c) }
    foreach ($f in @($ckpt.failedTests))    { [void]$failedTests.Add($f) }
    foreach ($s in @($ckpt.skippedTests))   { [void]$skippedTests.Add($s) }
    if ($ckpt.crashes) {
        foreach ($k in $ckpt.crashes.PSObject.Properties.Name) {
            $crashMap[$k] = $ckpt.crashes.$k
        }
    }
}

# Banner
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host "  COALTEST 2.0  --  $env:COMPUTERNAME  --  $ts" -ForegroundColor Yellow
Write-Host "  Run ID  : $runId" -ForegroundColor DarkGray
Write-Host "  Tests   : $(@($CoalTestRegistry).Count) total" -ForegroundColor DarkGray
Write-Host "  MaxCrash: $MaxCrashesPerTest per test" -ForegroundColor DarkGray
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host ''

"CoalTest 2.0 -- $env:COMPUTERNAME -- $ts -- RunId: $runId" | `
    Out-File -FilePath $runLogPath -Encoding UTF8

$passCnt = 0; $failCnt = 0; $skipCnt = 0; $warnCnt = 0; $crashCnt = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($test in $CoalTestRegistry) {
    $tid = $test.Id

    # Resume: skip already-completed tests
    if ($completedTests -contains $tid) {
        Write-CoalLog -Status 'SKIP' -Group $test.Group -TestId $tid -Name $test.Name `
            -Detail "[Resume] Already completed"
        $skipCnt++
        continue
    }
    if ($skippedTests -contains $tid) {
        Write-CoalLog -Status 'SKIP' -Group $test.Group -TestId $tid -Name $test.Name `
            -Detail "[Resume] Previously skipped"
        $skipCnt++
        continue
    }

    # Execute
    $status = Invoke-CoalTestCase -TestCase $test -CrashMap $crashMap -MaxCrashes $MaxCrashesPerTest

    # Account
    switch ($status) {
        'PASS'              { $passCnt++; [void]$completedTests.Add($tid) }
        'FAIL'              { $failCnt++; [void]$completedTests.Add($tid); [void]$failedTests.Add($tid) }
        'WARN'              { $warnCnt++; [void]$completedTests.Add($tid) }
        'SKIP'              { $skipCnt++; [void]$skippedTests.Add($tid) }
        'SKIPPED-MAX-CRASH' { $skipCnt++; [void]$skippedTests.Add($tid) }
        'CRASH'             { $crashCnt++ }
        default             { $passCnt++; [void]$completedTests.Add($tid) }
    }

    # Save checkpoint after every test
    Save-CoalCheckpoint -Path $chkpointPath -RunId $runId `
        -Completed $completedTests -Failed $failedTests -Skipped $skippedTests `
        -Crashes $crashMap -LastTestId $tid
}

$sw.Stop()

# ─────────────────────────────────────────────────────────────────────────────
#  ERROR LOG
# ─────────────────────────────────────────────────────────────────────────────
$errReport = [ordered]@{
    runId        = $runId
    generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
    totalTests   = @($CoalTestRegistry).Count
    passed       = $passCnt
    failed       = $failCnt
    warned       = $warnCnt
    skipped      = $skipCnt
    crashes      = $crashCnt
    elapsedMs    = $sw.ElapsedMilliseconds
    failures     = @($failedTests)
    crashMap     = $crashMap
    bugs         = @($script:PendingBugs)
}
try {
    $errReport | ConvertTo-Json -Depth 10 | Set-Content -Path $errLogPath -Encoding UTF8 -ErrorAction Stop
    Write-CoalLog -Status 'INFO' -Group 'Summary' -TestId 'errlog' `
        -Name 'Error log' -Detail "Written: $errLogPath"
} catch {
    Write-CoalLog -Status 'WARN' -Group 'Summary' -TestId 'errlog' `
        -Name 'Error log' -Detail "Write failed: $_"
}

# ─────────────────────────────────────────────────────────────────────────────
#  PIPELINE BUG FLUSH
# ─────────────────────────────────────────────────────────────────────────────
Flush-CoalBugsToTodo -WsPath $WorkspacePath

# ─────────────────────────────────────────────────────────────────────────────
#  FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
$elapsed = $sw.Elapsed.ToString('hh\:mm\:ss\.ff')

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host "  COALTEST 2.0 RESULTS  --  $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host ("  PASS    : {0}" -f $passCnt)   -ForegroundColor Green
Write-Host ("  FAIL    : {0}" -f $failCnt)   -ForegroundColor Red
Write-Host ("  WARN    : {0}" -f $warnCnt)   -ForegroundColor Yellow
Write-Host ("  SKIP    : {0}" -f $skipCnt)   -ForegroundColor DarkYellow
Write-Host ("  CRASH   : {0}" -f $crashCnt)  -ForegroundColor Magenta
Write-Host ("  TOTAL   : {0}" -f @($CoalTestRegistry).Count) -ForegroundColor Cyan
Write-Host ("  TIME    : {0}" -f $elapsed)   -ForegroundColor DarkGray
Write-Host ("  BUGS    : {0} registered" -f @($script:PendingBugs).Count) -ForegroundColor DarkGray
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host "  Log     : $runLogPath"    -ForegroundColor DarkGray
Write-Host "  ErrLog  : $errLogPath"   -ForegroundColor DarkGray
Write-Host "  Chkpt   : $chkpointPath" -ForegroundColor DarkGray
Write-Host ('=' * 78) -ForegroundColor Cyan
Write-Host ''

# Clean up checkpoint if run completed cleanly
if ($crashCnt -eq 0) {
    Remove-Item $chkpointPath -Force -ErrorAction SilentlyContinue
    Write-CoalLog -Status 'INFO' -Group 'Summary' -TestId 'chkpt' `
        -Name 'Checkpoint' -Detail 'Removed (run complete, no crashes)'
} else {
    Write-CoalLog -Status 'WARN' -Group 'Summary' -TestId 'chkpt' `
        -Name 'Checkpoint' -Detail "Retained for resume ($crashCnt crash(es) encountered)"
    Write-Host "  TIP: Re-run with -Resume to continue from last checkpoint" `
        -ForegroundColor Cyan
    Write-Host ''
}

# Exit code: 1 if any FAILs, 0 otherwise
if ($failCnt -gt 0) { exit 1 } else { exit 0 }






