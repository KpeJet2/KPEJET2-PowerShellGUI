# VersionTag: 2605.B2.V31.8
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
#Requires -Version 5.1

<#
.SYNOPSIS
    Comprehensive PowerShell Environment Scanner with tabbed GUI.

.DESCRIPTION
    WinForms-based environment scanner providing deep visibility into:
    - Module inventory (installed, missing, workspace, errors)
    - Script manifest with dependency mapping
    - PS Resource Repositories, Resources, Execution Policy
    - PS Repositories, Environments, Packages, Providers, Drives
    - Package Sources, Logging Providers
    - Orphan/unreferenced file detection
    - Get-PSScriptFileInfo integration
    - Digital signature verification
    - Security audit score cross-reference
    - Cascading failure overlay for missing dependencies

.PARAMETER WorkspacePath
    Root of workspace. Defaults to parent of script directory.

.PARAMETER AutoScan
    Run all scans automatically on launch.

.EXAMPLE
    .\scripts\Invoke-PSEnvironmentScanner.ps1
    .\scripts\Invoke-PSEnvironmentScanner.ps1 -AutoScan
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [switch]$AutoScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ═══════════════════════════════════════════════════════════════════════════════
# PATH SETUP
# ═══════════════════════════════════════════════════════════════════════════════
$scriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent $scriptRootPath
}
$modulesDir = Join-Path $WorkspacePath 'modules'
$scriptsDir = Join-Path $WorkspacePath 'scripts'
$reportsDir = Join-Path $WorkspacePath '~REPORTS'
$testsDir   = Join-Path $WorkspacePath 'tests'

# Try to load core module for logging
$coreModulePath = Join-Path $modulesDir 'PwShGUICore.psm1'
if (Test-Path $coreModulePath) {
    try { Import-Module $coreModulePath -Force -ErrorAction Stop } catch { <# Intentional: non-fatal #> }
}

# File type classifications
$moduleExtensions = @('.psm1')
$scriptExtensions = @('.ps1', '.bat', '.vbs', '.pwsh', '.cmd', '.com', '.vb', '.ini', '.xml', '.xhtml', '.json')

# Scan exclusion patterns
$excludePatterns = @('*.git*', '*.history*', '*~REPORTS\archive*', '*node_modules*', '*__pycache__*')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ═══════════════════════════════════════════════════════════════════════════════
# SCAN ENGINE -- Collects all environment data
# ═══════════════════════════════════════════════════════════════════════════════

$script:ScanResults = @{}
$script:ScanProgress = [System.Collections.Generic.List[object]]::new()
$script:ColoredGrids = @{}
$script:RainbowBar = $null          # Global rainbow progress bar (set in Build-ScannerGUI)
$script:RainbowStatusLabel = $null  # Status label beside the bar

# ── Sarcastic / humorous status messages when calculations fluctuate ──
$script:SarcasticMessages = @(
    'So much is going on right now...just gimme a sec will ya!'
    'Hold your horses -- I am counting things at light speed!'
    'Patience is a virtue...or so they tell me.'
    'Crunching numbers like a caffeinated accountant...'
    'Sifting through digital dust bunnies...'
    'Almost there -- said every progress bar ever.'
    'The hamsters powering this scan need a water break.'
    "If I had a dollar for every file I've scanned..."
    'Processing faster than your WiFi on a good day.'
    'This is fine. Everything is fine.'
    'Doing science...stand back.'
    'Scanning harder than a barcode reader at checkout.'
)
$script:SarcasticIndex = 0

function Get-SarcasticMessage {
    $msg = $script:SarcasticMessages[$script:SarcasticIndex]
    $script:SarcasticIndex = ($script:SarcasticIndex + 1) % $script:SarcasticMessages.Count
    return $msg
}

function Start-RainbowProgress {
    <# Resets and shows the global rainbow progress bar with an initial status message #>
    param([string]$StatusText = 'Starting...')
    if ($script:RainbowBar) {
        & $script:RainbowBar.Reset
        $script:RainbowBar.Panel.Visible = $true
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($script:RainbowStatusLabel) {
        $script:RainbowStatusLabel.Text = $StatusText
        $script:RainbowStatusLabel.ForeColor = [System.Drawing.Color]::Cyan
    }
}

function Update-RainbowProgress {
    <# Advances the global rainbow bar and updates the status text #>
    param(
        [int]$Percent,
        [string]$StatusText
    )
    if ($script:RainbowBar) {
        & $script:RainbowBar.Update $Percent
    }
    if ($script:RainbowStatusLabel) {
        $script:RainbowStatusLabel.Text = $StatusText
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Complete-RainbowProgress {
    <# Fills the rainbow bar to 100% and sets a completion message #>
    param([string]$StatusText = 'Complete')
    if ($script:RainbowBar) {
        & $script:RainbowBar.Complete
    }
    if ($script:RainbowStatusLabel) {
        $script:RainbowStatusLabel.Text = $StatusText
        $script:RainbowStatusLabel.ForeColor = [System.Drawing.Color]::LimeGreen
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Format-ThroughputOrSarcasm {
    <# Returns MB/s throughput string or a sarcastic message if the rate fluctuates or is unavailable #>
    param(
        [long]$BytesProcessed,
        [double]$ElapsedSeconds
    )
    if ($ElapsedSeconds -le 0.01 -or $BytesProcessed -le 0) {
        return Get-SarcasticMessage
    }
    $mbPerSec = [math]::Round(($BytesProcessed / 1MB) / $ElapsedSeconds, 2)
    if ($mbPerSec -lt 0.01) {
        return Get-SarcasticMessage
    }
    return "$mbPerSec MB/s"
}

$script:Checklist = @(
    @{ Key = 'Modules'; Step = 'Module inventory'; Function = 'Scan-Modules' },
    @{ Key = 'Scripts'; Step = 'Script and file matrix'; Function = 'Scan-Scripts' },
    @{ Key = 'PSResourceRepositories'; Step = 'PSResource repositories'; Function = 'Scan-PSResourceRepositories' },
    @{ Key = 'PSResources'; Step = 'PS resources'; Function = 'Scan-PSResources' },
    @{ Key = 'ExecutionPolicy'; Step = 'Execution policy'; Function = 'Scan-ExecutionPolicy' },
    @{ Key = 'PSRepositories'; Step = 'PowerShell repositories'; Function = 'Scan-PSRepositories' },
    @{ Key = 'Packages'; Step = 'Packages'; Function = 'Scan-Packages' },
    @{ Key = 'PackageProviders'; Step = 'Package providers'; Function = 'Scan-Packages' },
    @{ Key = 'PSProviders'; Step = 'PS providers'; Function = 'Scan-PSProviders' },
    @{ Key = 'PSDrives'; Step = 'PS drives'; Function = 'Scan-PSProviders' },
    @{ Key = 'PackageSources'; Step = 'Package sources'; Function = 'Scan-PackageSources' },
    @{ Key = 'LoggingProviders'; Step = 'Logging providers'; Function = 'Scan-LoggingProviders' },
    @{ Key = 'OrphanFiles'; Step = 'Orphan files'; Function = 'Scan-OrphanFiles' },
    @{ Key = 'CascadeFailures'; Step = 'Cascade failures'; Function = 'Build-CascadeFailureMap' },
    @{ Key = 'PreflightBaseline'; Step = 'Pre-flight baseline'; Function = 'Scan-PreflightBaseline' }
)

function Get-PercentColor {
    param([int]$Percent)
    if ($Percent -lt 35) { return [System.Drawing.Color]::OrangeRed }
    if ($Percent -lt 70) { return [System.Drawing.Color]::Gold }
    return [System.Drawing.Color]::LimeGreen
}

function Get-RainbowColor {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    <# Returns an RGB color along the rainbow spectrum for a 0-100 value #>
    param([int]$Percent)
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    # 6-stop rainbow: Red(0) -> Orange(17) -> Yellow(33) -> Green(50) -> Cyan(67) -> Blue(83) -> Violet(100)
    $stops = @(
        @{ P = 0;   R = 255; G = 0;   B = 0   },   # Red
        @{ P = 17;  R = 255; G = 140; B = 0   },   # Orange
        @{ P = 33;  R = 255; G = 230; B = 0   },   # Yellow
        @{ P = 50;  R = 0;   G = 200; B = 50  },   # Green
        @{ P = 67;  R = 0;   G = 210; B = 210 },   # Cyan
        @{ P = 83;  R = 40;  G = 80;  B = 255 },   # Blue
        @{ P = 100; R = 160; G = 32;  B = 240 }    # Violet
    )
    # Find the two stops to interpolate between
    $lo = $stops[0]; $hi = $stops[-1]  # SIN-EXEMPT: P027 - array guarded by Count check or conditional on prior/surrounding line
    for ($i = 0; $i -lt $stops.Count - 1; $i++) {
        if ($p -ge $stops[$i].P -and $p -le $stops[$i + 1].P) {
            $lo = $stops[$i]; $hi = $stops[$i + 1]; break
        }
    }
    $range = $hi.P - $lo.P
    $t = if ($range -gt 0) { ($p - $lo.P) / $range } else { 0 }
    $r = [int]($lo.R + ($hi.R - $lo.R) * $t)
    $g = [int]($lo.G + ($hi.G - $lo.G) * $t)
    $b = [int]($lo.B + ($hi.B - $lo.B) * $t)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Paint-RainbowProgressBar {
    <# Owner-draws a rainbow gradient progress bar inside a DataGridView cell #>
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [System.Windows.Forms.DataGridViewCellPaintingEventArgs]$e,
        [int]$Percent
    )
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    $cellBounds = $e.CellBounds
    # Paint background first
    $e.PaintBackground($cellBounds, $true)

    # Bar insets
    $barX = $cellBounds.X + 2
    $barY = $cellBounds.Y + 3
    $barW = $cellBounds.Width - 5
    $barH = $cellBounds.Height - 7
    if ($barW -lt 4 -or $barH -lt 4) { $e.Handled = $true; return }

    # Track background (dark groove)
    $trackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(25, 25, 25))
    $e.Graphics.FillRectangle($trackBrush, $barX, $barY, $barW, $barH)
    $trackBrush.Dispose()

    # Track border
    $borderPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 70, 70)), 1
    $e.Graphics.DrawRectangle($borderPen, $barX, $barY, $barW, $barH)
    $borderPen.Dispose()

    # Filled portion with rainbow gradient
    $fillW = [int]([Math]::Round($barW * $p / 100))
    if ($fillW -gt 1) {
        $fillRect = New-Object System.Drawing.Rectangle ($barX + 1), ($barY + 1), ($fillW - 1), ($barH - 1)
        $c1 = Get-RainbowColor ([int]([Math]::Max(0, $p - 30)))
        $c2 = Get-RainbowColor $p
        try {
            $gradBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
                $fillRect, $c1, $c2,
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
            )
            $e.Graphics.FillRectangle($gradBrush, $fillRect)
            $gradBrush.Dispose()
        } catch {
            # Fallback to solid fill if gradient fails (e.g. zero-width rect)
            $solidBrush = New-Object System.Drawing.SolidBrush $c2
            $e.Graphics.FillRectangle($solidBrush, $fillRect)
            $solidBrush.Dispose()
        }
    }

    # Draw percentage text centered on bar
    $text = "$p%"
    $textFont = New-Object System.Drawing.Font ('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
    $textSize = $e.Graphics.MeasureString($text, $textFont)
    $textX = $barX + ($barW - $textSize.Width) / 2
    $textY = $barY + ($barH - $textSize.Height) / 2
    $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
    $e.Graphics.DrawString($text, $textFont, $shadow, ($textX + 1), ($textY + 1))
    $shadow.Dispose()
    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $e.Graphics.DrawString($text, $textFont, $textBrush, $textX, $textY)
    $textBrush.Dispose()
    $textFont.Dispose()

    $e.Handled = $true
}

function Update-ProgressRow {
    param(
        [string]$Step,
        [string]$Key,
        [string]$Status,
        [int]$Percent,
        [string]$Detail
    )

    $existing = $script:ScanProgress | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if ($existing) {
        $existing.Status = $Status
        $existing.Percent = $Percent
        $existing.Detail = $Detail
    } else {
        $script:ScanProgress.Add([pscustomobject]@{
            Step = $Step
            Key = $Key
            Status = $Status
            Percent = $Percent
            Detail = $Detail
        }) | Out-Null
    }

    if ($script:grids -and $script:grids.ContainsKey('ScanProgress')) {
        $script:ScanResults['ScanProgress'] = $script:ScanProgress.ToArray()
        Populate-GridByKey -Key 'ScanProgress'
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-ResultCountForKey {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return 0 }
    if (-not $script:ScanResults.ContainsKey($Key)) { return 0 }
    return @($script:ScanResults[$Key]).Count
}

function Invoke-ScanStep {
    param(
        [string]$Step,
        [string]$Key,
        [scriptblock]$Action,
        [int]$StartPercent,
        [int]$EndPercent,
        [int]$StepIndex = 0,
        [int]$StepTotal = 0,
        [string]$PhaseText
    )

    $seqLabel = if ($StepTotal -gt 0 -and $StepIndex -gt 0) { "[{0}/{1}]" -f $StepIndex, $StepTotal } else { '[--/--]' }
    $statusText = if ([string]::IsNullOrWhiteSpace($PhaseText)) { "$seqLabel $Step" } else { "$seqLabel $PhaseText" }
    $runDetail = if ($StepTotal -gt 0 -and $StepIndex -gt 0) {
        "Running task $StepIndex of $StepTotal"
    } else {
        'Running'
    }

    Update-RainbowProgress -Percent $StartPercent -StatusText $statusText
    Update-ProgressRow -Step $Step -Key $Key -Status 'Running' -Percent $StartPercent -Detail $runDetail
    Write-Console ("[{0,3}%] {1} {2} -- started" -f $StartPercent, $seqLabel, $Step) 'Cyan'

    $stepTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $stepTimer.Stop()
        $durationSec = [math]::Round($stepTimer.Elapsed.TotalSeconds, 1)
        $rowCount = Get-ResultCountForKey -Key $Key
        $doneDetail = "Completed in {0:N1}s | rows: {1}" -f $durationSec, $rowCount
        Update-ProgressRow -Step $Step -Key $Key -Status 'Complete' -Percent $EndPercent -Detail $doneDetail
        Write-Console ("[{0,3}%] {1} {2} -- complete ({3:N1}s, rows={4})" -f $EndPercent, $seqLabel, $Step, $durationSec, $rowCount) 'Green'
    } catch {
        $stepTimer.Stop()
        $durationSec = [math]::Round($stepTimer.Elapsed.TotalSeconds, 1)
        $msg = $_.Exception.Message
        $errDetail = "Failed in {0:N1}s | {1}" -f $durationSec, $msg
        Update-RainbowProgress -Percent $StartPercent -StatusText ("{0} failed" -f $statusText)
        Update-ProgressRow -Step $Step -Key $Key -Status 'Error' -Percent $StartPercent -Detail $errDetail
        Write-Console ("[{0,3}%] {1} {2} -- failed ({3:N1}s): {4}" -f $StartPercent, $seqLabel, $Step, $durationSec, $msg) 'Red'
    }
}

function Get-MissingTabChecklist {
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:Checklist) {
        if (-not $script:ScanResults.ContainsKey($item.Key)) {
            $missing.Add([pscustomobject]@{ Key = $item.Key; Step = $item.Step; Function = $item.Function; Reason = 'Missing result key' }) | Out-Null
            continue
        }
        $data = $script:ScanResults[$item.Key]
        if ($null -eq $data -or ($data -is [array] -and $data.Count -eq 0)) {
            $missing.Add([pscustomobject]@{ Key = $item.Key; Step = $item.Step; Function = $item.Function; Reason = 'No rows returned' }) | Out-Null
        }
    }
    return $missing.ToArray()
}

function Write-ScanChecklistSummary {
    param([string]$Header = 'Scan checklist')

    Write-Console "── $Header ──" 'Yellow'
    $total = @($script:Checklist).Count
    $index = 0
    foreach ($item in $script:Checklist) {
        $index++
        Write-Console ("  [{0,2}/{1}] {2,-24} => {3}" -f $index, $total, $item.Step, $item.Function) 'Gray'
    }
}

function Invoke-ExternalScanScripts {
    Write-Console '── Running existing external scan scripts ──' 'Yellow'
    $matrixScript = Join-Path $WorkspacePath 'scripts\Invoke-ScriptDependencyMatrix.ps1'
    $moduleScript = Join-Path $WorkspacePath 'scripts\Invoke-ModuleManagement.ps1'

    if (Test-Path $matrixScript) {
        try {
            $null = & $matrixScript -WorkspacePath $WorkspacePath -ReportPath $reportsDir -TempPath (Join-Path $WorkspacePath 'temp') 2>&1 | Out-String
            Write-Console '  External script dependency matrix: completed' 'Green'
        } catch {
            Write-Console ("  External script dependency matrix failed: {0}" -f $_.Exception.Message) 'Red'
        }
    } else {
        Write-Console '  External script dependency matrix not found' 'DarkYellow'
    }

    if (Test-Path $moduleScript) {
        try {
            $null = & $moduleScript -WorkspacePath $WorkspacePath -ReportPath $reportsDir 2>&1 | Out-String
            Write-Console '  External module management scan: completed' 'Green'
        } catch {
            Write-Console ("  External module management scan failed: {0}" -f $_.Exception.Message) 'Red'
        }
    } else {
        Write-Console '  External module management script not found' 'DarkYellow'
    }
}

function Write-Console {
    param([string]$Text, [string]$Color = 'White')
    if ($script:consoleBox) {
        $script:consoleBox.SelectionStart = $script:consoleBox.TextLength
        $colorMap = @{
            Red = [System.Drawing.Color]::OrangeRed; Green = [System.Drawing.Color]::LimeGreen
            Yellow = [System.Drawing.Color]::Gold; Cyan = [System.Drawing.Color]::Cyan
            White = [System.Drawing.Color]::WhiteSmoke; Gray = [System.Drawing.Color]::DarkGray
            DarkYellow = [System.Drawing.Color]::Goldenrod; Magenta = [System.Drawing.Color]::Orchid
        }
        $c = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { [System.Drawing.Color]::WhiteSmoke }
        $script:consoleBox.SelectionColor = $c
        $script:consoleBox.AppendText("$Text`r`n")
        $script:consoleBox.ScrollToCaret()
    }
}

function Invoke-FullScan {
    $script:ScanProgress = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $script:Checklist) {
        Update-ProgressRow -Step $item.Step -Key $item.Key -Status 'Pending' -Percent 0 -Detail 'Not started'
    }
    Update-ProgressRow -Step 'External script checks' -Key 'ExternalScans' -Status 'Pending' -Percent 0 -Detail 'Queued'

    Start-RainbowProgress -StatusText 'Full environment scan starting...'

    Write-Console "═══════════════════════════════════════════════════" "Cyan"
    Write-Console "  PS ENVIRONMENT SCANNER -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Cyan"
    Write-Console "  Workspace: $WorkspacePath" "Cyan"
    Write-Console "═══════════════════════════════════════════════════" "Cyan"
    Write-Console ""

    Write-ScanChecklistSummary -Header 'Scan Now checklist (tabs and source functions)'

    $scanTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $scanTaskCount = 14
    $scanTaskIndex = 0

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Module inventory' -Key 'Modules' -StartPercent 2 -EndPercent 12 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning modules...' -Action { Scan-Modules }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Script and file matrix' -Key 'Scripts' -StartPercent 12 -EndPercent 20 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning scripts...' -Action { Scan-Scripts }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'PSResource repositories' -Key 'PSResourceRepositories' -StartPercent 20 -EndPercent 28 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning PSResource repos...' -Action { Scan-PSResourceRepositories }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'PS resources' -Key 'PSResources' -StartPercent 28 -EndPercent 34 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning PS resources...' -Action { Scan-PSResources }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Execution policy' -Key 'ExecutionPolicy' -StartPercent 34 -EndPercent 40 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning execution policy...' -Action { Scan-ExecutionPolicy }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'PowerShell repositories' -Key 'PSRepositories' -StartPercent 40 -EndPercent 46 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning PS repositories...' -Action { Scan-PSRepositories }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Packages and providers' -Key 'Packages' -StartPercent 46 -EndPercent 56 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText (Get-SarcasticMessage) -Action { Scan-Packages }
    $packageProviderRows = Get-ResultCountForKey -Key 'PackageProviders'
    Update-ProgressRow -Step 'Package providers' -Key 'PackageProviders' -Status 'Complete' -Percent 56 -Detail ("Populated via Scan-Packages | rows: {0}" -f $packageProviderRows)

    $scanTaskIndex++
    Invoke-ScanStep -Step 'PS providers and drives' -Key 'PSProviders' -StartPercent 56 -EndPercent 64 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning PS providers & drives...' -Action { Scan-PSProviders }
    $psDriveRows = Get-ResultCountForKey -Key 'PSDrives'
    Update-ProgressRow -Step 'PS drives' -Key 'PSDrives' -Status 'Complete' -Percent 64 -Detail ("Populated via Scan-PSProviders | rows: {0}" -f $psDriveRows)

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Package sources' -Key 'PackageSources' -StartPercent 64 -EndPercent 70 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning package sources...' -Action { Scan-PackageSources }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Logging providers' -Key 'LoggingProviders' -StartPercent 70 -EndPercent 76 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning logging & diagnostics...' -Action { Scan-LoggingProviders }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Orphan files' -Key 'OrphanFiles' -StartPercent 76 -EndPercent 84 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Scanning orphan files...' -Action { Scan-OrphanFiles }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Cascade failures' -Key 'CascadeFailures' -StartPercent 84 -EndPercent 90 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Building cascade failure map...' -Action { Build-CascadeFailureMap }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'Pre-flight baseline' -Key 'PreflightBaseline' -StartPercent 90 -EndPercent 94 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Building pre-flight baseline...' -Action { Scan-PreflightBaseline }

    $scanTaskIndex++
    Invoke-ScanStep -Step 'External script checks' -Key 'ExternalScans' -StartPercent 94 -EndPercent 98 -StepIndex $scanTaskIndex -StepTotal $scanTaskCount -PhaseText 'Running external checks...' -Action { Invoke-ExternalScanScripts }

    $scanTimer.Stop()

    $missing = Get-MissingTabChecklist
    if ($missing.Count -gt 0) {
        Write-Console 'Missing tab data detected after scan:' 'Red'
        foreach ($m in $missing) {
            Write-Console ("  Tab={0} | Function={1} | Reason={2}" -f $m.Key, $m.Function, $m.Reason) 'DarkYellow'
        }
    }

    # Calculate totals for the completion summary
    $totalItems = 0
    $totalSizeBytes = [long]0
    foreach ($kv in $script:ScanResults.GetEnumerator()) {
        if ($kv.Value -is [array]) { $totalItems += $kv.Value.Count }
    }
    $modResults = $script:ScanResults['Modules']
    $scriptResults = $script:ScanResults['Scripts']
    if ($modResults) { foreach ($m in $modResults) { if ($m.FileSize) { $totalSizeBytes += [long]$m.FileSize } } }
    if ($scriptResults) { foreach ($s in $scriptResults) { if ($s.FileSize) { $totalSizeBytes += [long]$s.FileSize } } }
    $totalSizeMB = [math]::Round($totalSizeBytes / 1MB, 2)
    $throughput = Format-ThroughputOrSarcasm -BytesProcessed $totalSizeBytes -ElapsedSeconds $scanTimer.Elapsed.TotalSeconds

    Write-Console "" "White"
    Write-Console "═══════════════════════════════════════════════════" "Green"
    if ($missing.Count -eq 0) {
        Write-Console "  SCAN COMPLETE -- All tabs populated" "Green"
    } else {
        Write-Console "  SCAN COMPLETE -- Some tabs still missing data (see checklist above)" "Yellow"
    }
    Write-Console ("  Total items: {0} | Size scanned: {1} MB | Elapsed: {2:N1}s | {3}" -f $totalItems, $totalSizeMB, $scanTimer.Elapsed.TotalSeconds, $throughput) "Cyan"
    Write-Console "═══════════════════════════════════════════════════" "Green"

    Complete-RainbowProgress -StatusText ("Done -- {0} items | {1} MB | {2:N1}s | {3}" -f $totalItems, $totalSizeMB, $scanTimer.Elapsed.TotalSeconds, $throughput)

    try {
        if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
        $scanDate = Get-Date -Format 'yyyyMMdd'
        $scanTime = Get-Date -Format 'HHmmss'
        $ip = (Get-PrimaryIPv4) -replace ':','-'
        $user = if ([string]::IsNullOrWhiteSpace($env:USERNAME)) { 'USER' } else { $env:USERNAME }
        $historyName = "{0}-{1}-{2}-{3}[{4}].json" -f $(if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { 'MACHINE' } else { $env:COMPUTERNAME }), $ip, $scanDate, $scanTime, $user
        $historyPath = Join-Path $reportsDir $historyName
        $script:ScanResults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $historyPath -Encoding UTF8
        Write-Console "History snapshot: $historyPath" 'Gray'
    } catch {
        Write-Console "Failed to persist history snapshot: $($_.Exception.Message)" 'DarkYellow'
    }

    if ($script:historyCombo) {
        try {
            $script:historyCombo.Items.Clear()
            $files = Get-ScanHistoryFiles
            foreach ($hf in $files) {
                $comboItem = New-Object PSObject -Property @{ Text = $hf.Name; Tag = $hf.FullName }
                [void]$script:historyCombo.Items.Add($comboItem)
            }
            if ($script:historyCombo.Items.Count -gt 0 -and $script:historyCombo.SelectedIndex -lt 0) {
                $script:historyCombo.SelectedIndex = 0
            }
        } catch { <# Intentional: non-fatal #> }
    }

    Populate-AllGrids
}

# ─────────────────────────────────────────────────────────────────
# MODULE SCAN
# ─────────────────────────────────────────────────────────────────
function Scan-Modules {
    Write-Console "── Scanning Modules ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()

    # 1) Workspace modules
    $wsModules = @{}
    if (Test-Path $modulesDir) {
        Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $fileSize = $_.Length
            $signed = $false
            try { $sig = Get-AuthenticodeSignature -FilePath $_.FullName -ErrorAction SilentlyContinue; if ($sig.Status -eq 'Valid') { $signed = $true } } catch { <# Intentional: non-fatal #> }
            $loadError = $null
            try { $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null) } catch { $loadError = $_.Exception.Message }

            $wsModules[$name.ToLowerInvariant()] = $true
            $results.Add([PSCustomObject]@{
                Name        = $name
                Type        = 'psm1'
                Status      = 'Workspace'
                Path        = $_.FullName
                FileSize    = $fileSize
                FileSizeKB  = [math]::Round($fileSize / 1KB, 1)
                Signed      = $signed
                LoadError   = $loadError
                ScriptDeps  = 0
                DependentScripts = ''
                Repository  = 'workspace'
                Version     = ''
            })
        }
    }

    # 2) PSModulePath installed modules
    $psModPaths = @(($env:PSModulePath -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_ -ErrorAction SilentlyContinue) })
    $installedCount = 0
    foreach ($modRoot in $psModPaths) {
        Get-ChildItem -Path $modRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_
            $modName = $dir.Name
            $manifest = Get-ChildItem -Path $dir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $psm = Get-ChildItem -Path $dir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $manifest -and -not $psm) {
                $verDir = Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($verDir) {
                    $manifest = Get-ChildItem -Path $verDir.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    $psm = Get-ChildItem -Path $verDir.FullName -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                }
            }
            if (-not $manifest -and -not $psm) { return }
            $installedCount++

            $version = ''; $repository = ''; $loadErr = $null
            if ($manifest) {
                try {
                    $data = Import-PowerShellDataFile -Path $manifest.FullName -ErrorAction Stop
                    if ($data.ContainsKey('ModuleVersion')) { $version = [string]$data.ModuleVersion }
                } catch { $loadErr = $_.Exception.Message }
            }

            $psgetXml = Join-Path $dir.FullName 'PSGetModuleInfo.xml'
            if (Test-Path $psgetXml) {
                try {
                    $xmlC = [xml](Get-Content $psgetXml -Raw -ErrorAction SilentlyContinue)
                    $rn = $xmlC.SelectSingleNode('//S[@N="Repository"]')
                    if ($rn) { $repository = $rn.InnerText }
                } catch { <# Intentional: non-fatal #> }
            }

            $targetFile = if ($psm) { $psm.FullName } elseif ($manifest) { $manifest.FullName } else { $dir.FullName }
            $fSize = if (Test-Path $targetFile -PathType Leaf) { (Get-Item $targetFile).Length } else { 0 }

            $results.Add([PSCustomObject]@{
                Name        = $modName
                Type        = if ($psm) { 'psm1' } else { 'psd1' }
                Status      = if ($loadErr) { 'Error' } else { 'Installed' }
                Path        = $dir.FullName
                FileSize    = $fSize
                FileSizeKB  = [math]::Round($fSize / 1KB, 1)
                Signed      = $false
                LoadError   = $loadErr
                ScriptDeps  = 0
                DependentScripts = ''
                Repository  = $repository
                Version     = $version
            })
        }
    }

    # 3) Cross-reference: scan scripts for Import-Module references
    $scriptModuleRefs = @{}
    $allScriptFiles = @()
    @($WorkspacePath, $scriptsDir, $testsDir) | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem -Path $_ -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $excluded = $false
                foreach ($ep in $excludePatterns) { if ($_.FullName -like $ep) { $excluded = $true; break } }
                if (-not $excluded) { $allScriptFiles += $_ }
            }
        }
    }

    foreach ($sf in $allScriptFiles) {
        try {
            $content = Get-Content $sf.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Match Import-Module with variable paths
            $importMatches = [regex]::Matches($content, '(?im)Import-Module\s+(.+?)(?:\s+-|$)')
            foreach ($m in $importMatches) {
                $rawRef = $m.Groups[1].Value.Trim().Trim('"', "'")
                # Resolve common variable patterns
                $resolvedNames = @()
                if ($rawRef -match 'PwShGUICore') { $resolvedNames += 'PwShGUICore' }
                if ($rawRef -match 'AVPN-Tracker') { $resolvedNames += 'AVPN-Tracker' }
                if ($rawRef -match 'AssistedSASC') { $resolvedNames += 'AssistedSASC' }
                if ($rawRef -match 'SASC-Adapters') { $resolvedNames += 'SASC-Adapters' }
                if ($rawRef -match 'UserProfileManager') { $resolvedNames += 'UserProfileManager' }
                if ($rawRef -match 'HelpFilesUpdate') { $resolvedNames += 'PwSh-HelpFilesUpdateSource-ReR' }
                if ($rawRef -match 'AutoIssueFinder') { $resolvedNames += 'PwShGUI_AutoIssueFinder' }

                # Also try to extract module name from path-like references
                if ($rawRef -match "([A-Za-z0-9_-]+)\.psm1") {
                    $extractedName = $Matches[1]
                    if ($resolvedNames -notcontains $extractedName) { $resolvedNames += $extractedName }
                }

                # Direct module name (not a path)
                if ($rawRef -notmatch '[\\/\$]' -and $rawRef -notmatch '\.psm1') {
                    $resolvedNames += $rawRef
                }

                foreach ($rn in $resolvedNames) {
                    $key = $rn.ToLowerInvariant()
                    if (-not $scriptModuleRefs.ContainsKey($key)) { $scriptModuleRefs[$key] = @() }
                    $scriptModuleRefs[$key] += $sf.Name
                }
            }

            # Match #Requires -Modules
            $requiresMatches = [regex]::Matches($content, '(?im)#Requires\s+-Modules?\s+(.+)$')
            foreach ($m in $requiresMatches) {
                $modNames = $m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") }
                foreach ($mn in $modNames) {
                    $key = $mn.ToLowerInvariant()
                    if (-not $scriptModuleRefs.ContainsKey($key)) { $scriptModuleRefs[$key] = @() }
                    $scriptModuleRefs[$key] += $sf.Name
                }
            }
        } catch { <# Intentional: non-fatal #> }
    }

    # Apply cross-reference counts
    foreach ($mod in $results) {
        $key = $mod.Name.ToLowerInvariant()
        if ($scriptModuleRefs.ContainsKey($key)) {
            $refs = @($scriptModuleRefs[$key] | Select-Object -Unique)
            $mod.ScriptDeps = $refs.Count
            $mod.DependentScripts = ($refs -join ', ')
        }
    }

    # 4) Find referenced but not installed/workspace modules
    foreach ($kv in $scriptModuleRefs.GetEnumerator()) {
        $modKey = $kv.Key
        $existing = $results | Where-Object { $_.Name.ToLowerInvariant() -eq $modKey }
        if (-not $existing) {
            $refs = @($kv.Value | Select-Object -Unique)
            $results.Add([PSCustomObject]@{
                Name        = $kv.Key
                Type        = 'unknown'
                Status      = 'Missing'
                Path        = ''
                FileSize    = 0
                FileSizeKB  = 0
                Signed      = $false
                LoadError   = 'Module not found in any location'
                ScriptDeps  = $refs.Count
                DependentScripts = ($refs -join ', ')
                Repository  = ''
                Version     = ''
            })
        }
    }

    $script:ScanResults['Modules'] = $results.ToArray()

    $wsCount = @($results | Where-Object { $_.Status -eq 'Workspace' }).Count
    $instCount = @($results | Where-Object { $_.Status -eq 'Installed' }).Count
    $missCount = @($results | Where-Object { $_.Status -eq 'Missing' }).Count
    $errCount = @($results | Where-Object { $_.Status -eq 'Error' }).Count
    Write-Console "  Workspace: $wsCount | Installed: $instCount | Missing: $missCount | Errors: $errCount" "Green"
    Write-Console "  Total: $($results.Count) modules tracked" "Gray"
}

# ─────────────────────────────────────────────────────────────────
# SCRIPT SCAN
# ─────────────────────────────────────────────────────────────────
function Scan-Scripts {
    Write-Console "── Scanning Scripts ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()

    $scanDirs = @($WorkspacePath)
    foreach ($scanDir in $scanDirs) {
        if (-not (Test-Path $scanDir)) { continue }
        Get-ChildItem -Path $scanDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $ext = $_.Extension.ToLowerInvariant()
            ($ext -in $scriptExtensions -or $ext -in $moduleExtensions) -and
            ($_.FullName -notlike '*.git*') -and ($_.FullName -notlike '*.history*') -and
            ($_.FullName -notlike '*~REPORTS\archive*')
        } | ForEach-Object {
            $f = $_
            $ext = $f.Extension.ToLowerInvariant().TrimStart('.')
            $fileType = if ($ext -eq 'psm1') { 'Module' } else { $ext.ToUpper() }

            $signed = $false
            if ($ext -in @('ps1', 'psm1', 'psd1')) {
                try { $sig = Get-AuthenticodeSignature -FilePath $f.FullName -ErrorAction SilentlyContinue; if ($sig.Status -eq 'Valid') { $signed = $true } } catch { <# Intentional: non-fatal #> }
            }

            # Try Get-PSScriptFileInfo
            $scriptInfo = $null
            $scriptVersion = ''
            $scriptAuthor = ''
            $scriptDesc = ''
            if ($ext -eq 'ps1') {
                try {
                    if (Get-Command Get-PSScriptFileInfo -ErrorAction SilentlyContinue) {
                        $scriptInfo = Get-PSScriptFileInfo -Path $f.FullName -ErrorAction SilentlyContinue
                        if ($scriptInfo) {
                            $scriptVersion = $scriptInfo.Version
                            $scriptAuthor = $scriptInfo.Author
                            $scriptDesc = $scriptInfo.Description
                        }
                    }
                } catch { <# Intentional: non-fatal #> }
            }

            # Security score cross-reference
            $safetyScore = ''
            $isAdminScript = $false
            try {
                $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    if ($content -match '#Requires\s+-RunAsAdministrator') { $isAdminScript = $true }
                    if ($content -match 'Start-Process.*-Verb\s+RunAs') { $isAdminScript = $true }
                }
            } catch { <# Intentional: non-fatal #> }

            $relPath = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\')

            $results.Add([PSCustomObject]@{
                FileName    = $f.Name
                RelPath     = $relPath
                FullPath    = $f.FullName
                FileType    = $fileType
                Extension   = $ext
                FileSize    = $f.Length
                FileSizeKB  = [math]::Round($f.Length / 1KB, 1)
                Signed      = $signed
                Version     = $scriptVersion
                Author      = $scriptAuthor
                Description = $scriptDesc
                IsAdmin     = $isAdminScript
                SafetyScore = $safetyScore
                LastModified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                Referenced   = $true
            })
        }
    }

    $script:ScanResults['Scripts'] = $results.ToArray()
    $typeGroups = $results | Group-Object FileType | Sort-Object Count -Descending
    foreach ($tg in $typeGroups) {
        Write-Console "  $($tg.Name): $($tg.Count) files" "Gray"
    }
    Write-Console "  Total: $($results.Count) files scanned" "Green"
}

# ─────────────────────────────────────────────────────────────────
# PS RESOURCE REPOSITORIES
# ─────────────────────────────────────────────────────────────────
function Scan-PSResourceRepositories {
    Write-Console "── Scanning PSResourceRepositories ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {
            Get-PSResourceRepository -ErrorAction SilentlyContinue | ForEach-Object {
                $results.Add([PSCustomObject]@{
                    Name     = $_.Name
                    Uri      = [string]$_.Uri
                    Trusted  = $_.Trusted
                    Priority = $_.Priority
                    Type     = 'PSResourceRepository'
                    Status   = 'Available'
                })
            }
            Write-Console "  Found $($results.Count) PSResource repositories" "Green"
        } else {
            Write-Console "  Get-PSResourceRepository not available (PSResourceGet not installed)" "DarkYellow"
        }
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PSResourceRepositories'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PS RESOURCES
# ─────────────────────────────────────────────────────────────────
function Scan-PSResources {
    Write-Console "── Scanning PSResources ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        if (Get-Command Get-PSResource -ErrorAction SilentlyContinue) {
            Get-PSResource -ErrorAction SilentlyContinue | ForEach-Object {
                $results.Add([PSCustomObject]@{
                    Name         = $_.Name
                    Version      = [string]$_.Version
                    Type         = [string]$_.Type
                    Repository   = $_.Repository
                    InstalledLocation = $_.InstalledLocation
                    Description  = if ($_.Description -and $_.Description.Length -gt 80) { $_.Description.Substring(0,80) + '...' } else { [string]$_.Description }
                })
            }
            Write-Console "  Found $($results.Count) PSResources" "Green"
        } else {
            Write-Console "  Get-PSResource not available" "DarkYellow"
        }
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PSResources'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# EXECUTION POLICY
# ─────────────────────────────────────────────────────────────────
function Scan-ExecutionPolicy {
    Write-Console "── Scanning Execution Policy ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Get-ExecutionPolicy -List | ForEach-Object {
            $results.Add([PSCustomObject]@{
                Scope            = [string]$_.Scope
                ExecutionPolicy  = [string]$_.ExecutionPolicy
                IsEffective      = ($_.Scope -eq 'Process' -or $_.Scope -eq 'CurrentUser')
                RiskLevel        = switch ([string]$_.ExecutionPolicy) {
                    'Unrestricted' { 'HIGH' }
                    'Bypass'       { 'CRITICAL' }
                    'RemoteSigned' { 'Medium' }
                    'AllSigned'    { 'Low' }
                    'Restricted'   { 'Locked' }
                    default        { 'Undefined' }
                }
            })
        }
        $effective = Get-ExecutionPolicy
        Write-Console "  Effective policy: $effective" "Green"
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['ExecutionPolicy'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PS REPOSITORIES
# ─────────────────────────────────────────────────────────────────
function Scan-PSRepositories {
    Write-Console "── Scanning PSRepositories ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Get-PSRepository -ErrorAction SilentlyContinue | ForEach-Object {
            $results.Add([PSCustomObject]@{
                Name               = $_.Name
                SourceLocation     = [string]$_.SourceLocation
                PublishLocation    = [string]$_.PublishLocation
                InstallationPolicy = [string]$_.InstallationPolicy
                PackageManagement  = [string]$_.PackageManagementProvider
                Trusted            = ($_.InstallationPolicy -eq 'Trusted')
            })
        }
        Write-Console "  Found $($results.Count) PS repositories" "Green"
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PSRepositories'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PACKAGES & PACKAGE PROVIDERS
# ─────────────────────────────────────────────────────────────────
function Scan-Packages {
    Write-Console "── Scanning Packages & Providers ──" "Yellow"
    $provResults = [System.Collections.Generic.List[object]]::new()
    try {
        Get-PackageProvider -ErrorAction SilentlyContinue | ForEach-Object {
            $provResults.Add([PSCustomObject]@{
                Name          = $_.Name
                Version       = [string]$_.Version
                DynamicOptions = ''
                Type          = 'PackageProvider'
            })
        }
        Write-Console "  Package providers: $($provResults.Count)" "Green"
    } catch { Write-Console "  PackageProvider error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PackageProviders'] = $provResults.ToArray()

    $pkgResults = [System.Collections.Generic.List[object]]::new()
    try {
        Get-Package -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
            $pkgResults.Add([PSCustomObject]@{
                Name        = $_.Name
                Version     = [string]$_.Version
                Source      = $_.Source
                ProviderName = $_.ProviderName
                Status      = $_.Status
                Summary     = if ($_.Summary -and $_.Summary.Length -gt 60) { $_.Summary.Substring(0,60) + '...' } else { $_.Summary }
            })
        }
        Write-Console "  Packages found: $($pkgResults.Count)" "Green"
    } catch { Write-Console "  Package scan: $($_.Exception.Message)" "DarkYellow" }
    $script:ScanResults['Packages'] = $pkgResults.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PS PROVIDERS & PS DRIVES
# ─────────────────────────────────────────────────────────────────
function Scan-PSProviders {
    Write-Console "── Scanning PSProviders & PSDrives ──" "Yellow"
    $provResults = [System.Collections.Generic.List[object]]::new()
    try {
        Get-PSProvider -ErrorAction SilentlyContinue | ForEach-Object {
            $provResults.Add([PSCustomObject]@{
                Name       = $_.Name
                Capabilities = ($_.Capabilities -join ', ')
                Home       = $_.Home
                Drives     = ($_.Drives.Name -join ', ')
            })
        }
        Write-Console "  PS Providers: $($provResults.Count)" "Green"
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PSProviders'] = $provResults.ToArray()

    $driveResults = [System.Collections.Generic.List[object]]::new()
    try {
        Get-PSDrive -ErrorAction SilentlyContinue | ForEach-Object {
            $driveResults.Add([PSCustomObject]@{
                Name     = $_.Name
                Provider = [string]$_.Provider
                Root     = $_.Root
                Used     = if ($_.Used) { [math]::Round($_.Used / 1GB, 2).ToString() + ' GB' } else { '' }
                Free     = if ($_.Free) { [math]::Round($_.Free / 1GB, 2).ToString() + ' GB' } else { '' }
            })
        }
        Write-Console "  PS Drives: $($driveResults.Count)" "Green"
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PSDrives'] = $driveResults.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PACKAGE SOURCES
# ─────────────────────────────────────────────────────────────────
function Scan-PackageSources {
    Write-Console "── Scanning Package Sources ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Get-PackageSource -ErrorAction SilentlyContinue | ForEach-Object {
            $results.Add([PSCustomObject]@{
                Name         = $_.Name
                Location     = $_.Location
                ProviderName = $_.ProviderName
                IsTrusted    = $_.IsTrusted
                IsRegistered = $_.IsRegistered
            })
        }
        Write-Console "  Package sources: $($results.Count)" "Green"
    } catch { Write-Console "  Error: $($_.Exception.Message)" "Red" }
    $script:ScanResults['PackageSources'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# PS LOGGING PROVIDERS (Experimental)
# ─────────────────────────────────────────────────────────────────
function Scan-LoggingProviders {
    Write-Console "── Scanning Logging & Diagnostics ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()

    # Check common logging configuration
    $logSettings = @(
        @{ Name = 'ScriptBlockLogging'; RegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; ValueName = 'EnableScriptBlockLogging' },
        @{ Name = 'ModuleLogging'; RegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'; ValueName = 'EnableModuleLogging' },
        @{ Name = 'Transcription'; RegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'; ValueName = 'EnableTranscripting' }
    )

    foreach ($ls in $logSettings) {
        $enabled = $false
        $value = ''
        try {
            if (Test-Path $ls.RegPath) {
                $regVal = Get-ItemProperty -Path $ls.RegPath -Name $ls.ValueName -ErrorAction SilentlyContinue
                if ($regVal) { $enabled = [bool]$regVal.($ls.ValueName); $value = [string]$regVal.($ls.ValueName) }
            }
        } catch { <# Intentional: non-fatal #> }
        $results.Add([PSCustomObject]@{
            Name     = $ls.Name
            Enabled  = $enabled
            Value    = $value
            Source   = 'GPO/Registry'
            RegPath  = $ls.RegPath
        })
    }

    # Check PSReadLine history -- guard against command not available
    try {
        $histPath = $null
        if (Get-Command Get-PSReadLineOption -ErrorAction SilentlyContinue) {
            $rlOpt = Get-PSReadLineOption -ErrorAction Stop
            if ($rlOpt) { $histPath = $rlOpt.HistorySavePath }
        }
        if ($histPath -and (Test-Path $histPath -ErrorAction SilentlyContinue)) {
            $histSize = (Get-Item $histPath -ErrorAction Stop).Length
            $results.Add([PSCustomObject]@{
                Name     = 'PSReadLineHistory'
                Enabled  = $true
                Value    = [math]::Round($histSize / 1KB, 1).ToString() + ' KB'
                Source   = 'PSReadLine'
                RegPath  = $histPath
            })
        }
    } catch {
        Write-Console ("  PSReadLine check skipped: {0}" -f $_.Exception.Message) 'DarkYellow'
    }

    # Check $PROFILE existence -- guard against missing note properties
    $profileNames = @('CurrentUserCurrentHost', 'CurrentUserAllHosts', 'AllUsersCurrentHost', 'AllUsersAllHosts')
    foreach ($pName in $profileNames) {
        $profPath = $null
        $exists = $false
        $sizeText = 'Not found'
        try {
            if ($null -ne $PROFILE) {
                $profPath = $PROFILE.PSObject.Properties[$pName].Value
            }
            if ($profPath) {
                $exists = Test-Path $profPath -ErrorAction SilentlyContinue
                if ($exists) {
                    $sizeText = [math]::Round((Get-Item $profPath -ErrorAction Stop).Length / 1KB, 1).ToString() + ' KB'
                }
            }
        } catch { <# Intentional: non-fatal -- profile property may not exist #> }
        $results.Add([PSCustomObject]@{
            Name     = "Profile_$pName"
            Enabled  = $exists
            Value    = $sizeText
            Source   = 'Profile'
            RegPath  = if ($profPath) { [string]$profPath } else { '' }
        })
    }

    Write-Console "  Logging/diagnostic items: $($results.Count)" "Green"
    $script:ScanResults['LoggingProviders'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# ORPHAN / UNREFERENCED FILE DETECTION
# ─────────────────────────────────────────────────────────────────
function Scan-OrphanFiles {
    Write-Console "── Scanning for Orphan/Unreferenced Files ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()

    # Get all workspace files
    $allFiles = @(Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notlike '*.git*' -and $_.FullName -notlike '*.history*' -and
        $_.FullName -notlike '*~REPORTS\archive*' -and $_.FullName -notlike '*~REPORTS\dependency*' -and
        $_.Extension -in @('.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.vbs', '.xml', '.json', '.xhtml', '.ini')
    })

    # Read Main-GUI.ps1 content for reference checking
    $mainGuiPath = Join-Path $WorkspacePath 'Main-GUI.ps1'
    $mainContent = ''
    if (Test-Path $mainGuiPath) { $mainContent = Get-Content $mainGuiPath -Raw -ErrorAction SilentlyContinue }

    # Collect all script contents for cross-referencing
    $allContents = @{}
    $allFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.bat', '.cmd') } | ForEach-Object {
        try { $allContents[$_.FullName] = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue } catch { <# Intentional: non-fatal #> }
    }
    foreach ($f in $allFiles) {
        $refByMain = $false
        $refByAny = $false
        $refCount = 0

        $searchNames = @($f.Name, [System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        foreach ($sn in $searchNames) {
            if ($mainContent -match [regex]::Escape($sn)) { $refByMain = $true }
            # Check how many other files reference this
            foreach ($kv in $allContents.GetEnumerator()) {
                if ($kv.Key -ne $f.FullName -and $kv.Value -match [regex]::Escape($sn)) {
                    $refByAny = $true
                    $refCount++
                }
            }
        }

        $relPath = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\')
        $status = if ($refByMain) { 'MainGUI-Ref' } elseif ($refByAny) { 'Script-Ref' } else { 'ORPHAN' }

        $results.Add([PSCustomObject]@{
            FileName     = $f.Name
            RelPath      = $relPath
            Status       = $status
            RefByMainGUI = $refByMain
            RefByScripts = $refByAny
            RefCount     = $refCount
            FileSize     = $f.Length
            FileSizeKB   = [math]::Round($f.Length / 1KB, 1)
            Extension    = $f.Extension
            LastModified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        })
    }

    $orphanCount = @($results | Where-Object { $_.Status -eq 'ORPHAN' }).Count
    $mainRefCount = @($results | Where-Object { $_.RefByMainGUI }).Count
    Write-Console "  Total files: $($results.Count) | Main-GUI refs: $mainRefCount | Orphans: $orphanCount" "Green"
    $script:ScanResults['OrphanFiles'] = $results.ToArray()
}

# ─────────────────────────────────────────────────────────────────
# CASCADE FAILURE MAP -- what breaks when modules are missing
# ─────────────────────────────────────────────────────────────────
function Build-CascadeFailureMap {
    Write-Console "── Building Cascade Failure Map ──" "Yellow"
    $results = [System.Collections.Generic.List[object]]::new()

    $modules = $script:ScanResults['Modules']
    if (-not $modules) { return }

    $missingMods = @($modules | Where-Object { $_.Status -in @('Missing', 'Error') })
    if ($missingMods.Count -eq 0) {
        Write-Console "  No missing/errored modules -- no cascading failures" "Green"
        $script:ScanResults['CascadeFailures'] = @()
        return
    }

    foreach ($mm in $missingMods) {
        if (-not $mm.DependentScripts) { continue }
        $depScripts = $mm.DependentScripts -split ',\s*'

        foreach ($ds in $depScripts) {
            # Find functions exported by this module
            $failedFunctions = @()
            if ($mm.Path -and (Test-Path $mm.Path)) {
                try {
                    $modContent = Get-Content $mm.Path -Raw -ErrorAction SilentlyContinue
                    $funcMatches = [regex]::Matches($modContent, '(?m)^function\s+([A-Za-z][\w-]+)')
                    $failedFunctions = @($funcMatches | ForEach-Object { $_.Groups[1].Value })
                } catch { <# Intentional: non-fatal #> }
            }

            $results.Add([PSCustomObject]@{
                MissingModule   = $mm.Name
                ModuleStatus    = $mm.Status
                AffectedScript  = $ds
                FailedFunctions = ($failedFunctions -join ', ')
                FunctionCount   = $failedFunctions.Count
                Impact          = if ($failedFunctions.Count -gt 10) { 'CRITICAL' } elseif ($failedFunctions.Count -gt 3) { 'HIGH' } else { 'Medium' }
            })
        }
    }

    Write-Console "  Cascade failure entries: $($results.Count)" $(if ($results.Count -gt 0) { 'Red' } else { 'Green' })
    $script:ScanResults['CascadeFailures'] = $results.ToArray()
}

function Get-PrimaryIPv4 {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254*' -and $_.InterfaceAlias -notmatch 'Loopback|vEthernet' } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch { <# Intentional: non-fatal #> }
    return '0.0.0.0'
}

function Get-ScanHistoryFiles {
    if (-not (Test-Path $reportsDir)) { return @() }
    return @(Get-ChildItem -Path $reportsDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object {
        $_.BaseName -match '^[^\-]+-[0-9\.]+-\d{8}-\d{6}\[[^\]]+\]$'
    } | Sort-Object LastWriteTime -Descending)
}

function Tag-ObsoleteScanHistory {
    <#
    .SYNOPSIS  Tags redundant/old scan history files as "Trash to lint".
    .DESCRIPTION
        Keeps the newest scan per day per machine-user combo.
        Older duplicates within the same day are renamed with a
        [TRASH-TO-LINT] prefix so they can be identified and cleaned up.
        Files older than 30 days are also tagged.
    #>
    param([int]$MaxAgeDays = 30)

    if (-not (Test-Path $reportsDir)) {
        Write-Console '  No reports directory found.' 'DarkYellow'
        return
    }

    $allHistory = Get-ScanHistoryFiles
    if ($allHistory.Count -eq 0) {
        Write-Console '  No scan history files found.' 'DarkYellow'
        return
    }

    Write-Console ('── Tagging obsolete scan history ({0} files) ──' -f $allHistory.Count) 'Yellow'
    $taggedCount = 0
    $cutoffDate = (Get-Date).AddDays(-$MaxAgeDays)
    $seen = @{}

    foreach ($hf in $allHistory) {
        # Parse machine-user-date from filename: {MACHINE}-{IP}-{DATE}-{TIME}[{USER}].json
        $baseName = $hf.BaseName
        $match = [regex]::Match($baseName, '^(.+)-(\d{8})-\d{6}\[([^\]]+)\]$')
        if (-not $match.Success) { continue }

        $machineIp = $match.Groups[1].Value
        $dateStr = $match.Groups[2].Value
        $user = $match.Groups[3].Value
        $dayKey = "$machineIp|$dateStr|$user"

        $shouldTag = $false
        # Tag files older than cutoff
        if ($hf.LastWriteTime -lt $cutoffDate) {
            $shouldTag = $true
        }
        # Tag duplicate same-day scans (keep only the newest = first seen since sorted desc)
        if ($seen.ContainsKey($dayKey)) {
            $shouldTag = $true
        }
        $seen[$dayKey] = $true

        if ($shouldTag -and $hf.Name -notlike '*TRASH-TO-LINT*') {
            $newName = '[TRASH-TO-LINT] ' + $hf.Name
            $newPath = Join-Path $hf.DirectoryName $newName
            try {
                Rename-Item -Path $hf.FullName -NewName $newName -ErrorAction Stop
                $taggedCount++
                Write-Console ("  Tagged: {0}" -f $hf.Name) 'DarkYellow'
            } catch {
                Write-Console ("  Failed to tag {0}: {1}" -f $hf.Name, $_.Exception.Message) 'Red'
            }
        }
    }

    Write-Console ("  Tagged {0} obsolete scan(s) as Trash-to-lint" -f $taggedCount) 'Green'
}

function Get-HistoryBaselineValues {
    param([string]$HistoryFile)
    if (-not $HistoryFile -or -not (Test-Path $HistoryFile)) { return @{} }
    try {
        $obj = Get-Content -Path $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return @{}
    }

    $repos = if ($null -ne $obj.PSRepositories) { @($obj.PSRepositories) } else { @() }
    $mods  = if ($null -ne $obj.Modules) { @($obj.Modules) } else { @() }
    $pkgProviders = if ($null -ne $obj.PackageProviders) { @($obj.PackageProviders) } else { @() }
    $pkgSources   = if ($null -ne $obj.PackageSources) { @($obj.PackageSources) } else { @() }
    $execPolicy   = if ($null -ne $obj.ExecutionPolicy) { @($obj.ExecutionPolicy) } else { @() }
    $envBlock     = $obj.Environment

    $processPolicy  = $execPolicy | Where-Object { $_.Scope -eq 'Process' } | Select-Object -First 1
    $currentPolicy  = $execPolicy | Where-Object { $_.Scope -eq 'CurrentUser' } | Select-Object -First 1

    return @{
        ModulesCount = (@($mods | Where-Object { $_.Status -in @('Installed', 'Workspace') }).Count)
        PSRepositoryTrusted = (@($repos | Where-Object { $_.Trusted }).Count)
        PSGalleryPresent = [bool]($repos | Where-Object { $_.Name -eq 'PSGallery' } | Select-Object -First 1)
        PackageProvidersCount = $pkgProviders.Count
        PackageSourcesTrusted = (@($pkgSources | Where-Object { $_.IsTrusted }).Count)
        ProcessExecPolicy = if ($processPolicy) { [string]$processPolicy.ExecutionPolicy } else { '' }
        CurrentUserExecPolicy = if ($currentPolicy) { [string]$currentPolicy.ExecutionPolicy } else { '' }
        PsModulePathSet = if ($null -ne $envBlock -and $null -ne $envBlock.PSModulePath) { -not [string]::IsNullOrWhiteSpace([string]$envBlock.PSModulePath) } else { $false }
        PathSet = if ($null -ne $envBlock -and $null -ne $envBlock.Path) { -not [string]::IsNullOrWhiteSpace([string]$envBlock.Path) } else { $false }
    }
}

function Get-PrereqBaselineConfig {
    $baselinePath = Join-Path $WorkspacePath 'config\prerequisites-baseline.json'
    if (Test-Path $baselinePath) {
        try {
            $obj = Get-Content -Path $baselinePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.tools) {
                return $obj
            }
        } catch {
            Write-Console "  Failed to parse prerequisites-baseline.json: $($_.Exception.Message)" 'DarkYellow'
        }
    }

    $fallbackJson = @'
{
  "tools": [
    { "name": "PowerShell 7 x64", "key": "pwsh", "required": true, "minimumVersion": "7.5.0", "recommendedVersion": "7.5.4", "wingetId": "Microsoft.PowerShell", "installIfMissing": true },
    { "name": ".NET SDK x64", "key": "dotnet-sdk", "required": true, "minimumVersion": "8.0.100", "recommendedVersion": "9.0.100", "wingetId": "Microsoft.DotNet.SDK.9", "installIfMissing": true },
    { "name": ".NET WindowsDesktop Runtime x64", "key": "dotnet-desktop-runtime", "required": true, "minimumVersion": "8.0.0", "recommendedVersion": "9.0.0", "wingetId": "Microsoft.DotNet.DesktopRuntime.9", "installIfMissing": true },
    { "name": "Python", "key": "python", "required": true, "minimumVersion": "3.11.0", "recommendedVersion": "3.12.0", "wingetId": "Python.Python.3.12", "installIfMissing": true },
    { "name": "Windows Terminal", "key": "windows-terminal", "required": true, "minimumVersion": "1.20.0", "recommendedVersion": "1.21.0", "wingetId": "Microsoft.WindowsTerminal", "installIfMissing": true },
    { "name": "mRemoteNG", "key": "mremoteng", "required": false, "minimumVersion": "1.77.0", "recommendedVersion": "1.78.0", "wingetId": "mRemoteNG.mRemoteNG", "installIfMissing": false }
  ],
  "repositories": {
    "psRepository": { "requiredNames": ["PSGallery"], "minimumTrustedCount": 1 },
    "psResourceRepository": { "requiredNames": ["PSGallery"], "minimumTrustedCount": 1 }
  },
  "modules": [
    { "name": "PowerShellGet", "required": true, "minimumVersion": "2.2.5" },
    { "name": "PackageManagement", "required": true, "minimumVersion": "1.4.8.1" },
    { "name": "Microsoft.PowerShell.PSResourceGet", "required": true, "minimumVersion": "1.0.0" }
  ],
  "environmentVariables": [
    { "name": "Path", "required": true },
    { "name": "PSModulePath", "required": true },
    { "name": "TEMP", "required": true },
    { "name": "ProgramFiles", "required": true }
  ]
}
'@
    return ($fallbackJson | ConvertFrom-Json)
}

function Get-ComparableVersion {
    param([string]$RawVersion)
    if ([string]::IsNullOrWhiteSpace($RawVersion)) { return $null }
    $m = [regex]::Match($RawVersion, '(\d+)(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = $m.Value.Split('.')
    while ($parts.Count -lt 4) { $parts += '0' }
    $normalized = ($parts[0..3] -join '.')
    try { return [version]$normalized } catch { return $null }
}

function Test-VersionAtLeast {
    param(
        [string]$CurrentVersion,
        [string]$MinimumVersion
    )
    $cv = Get-ComparableVersion -RawVersion $CurrentVersion
    $mv = Get-ComparableVersion -RawVersion $MinimumVersion
    if (-not $cv -or -not $mv) { return $false }
    return ($cv -ge $mv)
}

function Get-HighestModuleVersion {
    param([string]$ModuleName)
    try {
        $mod = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($mod) { return [string]$mod.Version }
    } catch { <# Intentional: non-fatal #> }
    return ''
}

function Get-ToolVersionByKey {
    param([string]$ToolKey)

    switch ($ToolKey.ToLowerInvariant()) {
        'pwsh' {
            try {
                if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                    return [string]$PSVersionTable.PSVersion
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'dotnet-sdk' {
            try {
                if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                    return ((& dotnet --version 2>&1 | Out-String).Trim())
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'dotnet-desktop-runtime' {
            try {
                if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                    $lines = @(& dotnet --list-runtimes 2>&1)
                    $versions = @($lines | ForEach-Object {
                        $match = [regex]::Match([string]$_, '^Microsoft\.WindowsDesktop\.App\s+([0-9]+\.[0-9]+\.[0-9]+)')
                        if ($match.Success) { $match.Groups[1].Value }
                    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($versions.Count -gt 0) {
                        return [string](($versions | Sort-Object { Get-ComparableVersion $_ } -Descending | Select-Object -First 1))
                    }
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'python' {
            try {
                if (Get-Command python -ErrorAction SilentlyContinue) {
                    return ((& python --version 2>&1 | Out-String).Trim())
                }
                if (Get-Command py -ErrorAction SilentlyContinue) {
                    return ((& py -V 2>&1 | Out-String).Trim())
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'windows-terminal' {
            try {
                if (Get-Command wt -ErrorAction SilentlyContinue) {
                    return ((& wt -v 2>&1 | Out-String).Trim())
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'mremoteng' {
            try {
                $candidatePaths = @(
                    (Join-Path $env:ProgramFiles 'mRemoteNG\mRemoteNG.exe'),
                    (Join-Path ${env:ProgramFiles(x86)} 'mRemoteNG\mRemoteNG.exe')
                )
                foreach ($cp in $candidatePaths) {
                    if ($cp -and (Test-Path $cp)) {
                        return [string](Get-Item $cp).VersionInfo.ProductVersion
                    }
                }
                $cmd = Get-Command mRemoteNG -ErrorAction SilentlyContinue
                if ($cmd) {
                    return [string](Get-Item $cmd.Source).VersionInfo.ProductVersion
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        'winget' {
            try {
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    return ((& winget --version 2>&1 | Out-String).Trim())
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
        default {
            try {
                $cmd = Get-Command $ToolKey -ErrorAction SilentlyContinue
                if ($cmd) {
                    return [string](Get-Item $cmd.Source).VersionInfo.ProductVersion
                }
            } catch { <# Intentional: non-fatal #> }
            return ''
        }
    }
}

function Invoke-PrerequisiteWingetUpdates {
    param([switch]$IncludeOptional)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Console 'WinGet is not available on this machine.' 'Red'
        return
    }

    $baselineConfig = Get-PrereqBaselineConfig
    $tools = @($baselineConfig.tools | Where-Object { -not [string]::IsNullOrWhiteSpace($_.wingetId) })
    if (-not $IncludeOptional) {
        $tools = @($tools | Where-Object { $_.required })
    }

    if ($tools.Count -eq 0) {
        Write-Console 'No WinGet-backed prerequisites configured.' 'DarkYellow'
        return
    }

    Write-Console '── Running WinGet prerequisite remediation ──' 'Yellow'
    foreach ($tool in $tools) {
        try {
            $id = [string]$tool.wingetId
            Write-Console ("  Checking updates: {0} ({1})" -f $tool.name, $id) 'Cyan'

            $upgradeOut = (& winget upgrade --id $id --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-String)
            if ($upgradeOut -match 'No applicable update found') {
                Write-Console ("    Up to date: {0}" -f $tool.name) 'Green'
                continue
            }
            if ($upgradeOut -match 'No installed package found' -or $upgradeOut -match 'No package found matching input criteria') {
                if ($tool.installIfMissing) {
                    Write-Console ("    Not installed; installing: {0}" -f $id) 'Yellow'
                    $null = & winget install --id $id --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-String
                    Write-Console ("    Install attempted: {0}" -f $tool.name) 'Green'
                } else {
                    Write-Console ("    Optional and not installed: {0}" -f $tool.name) 'DarkYellow'
                }
                continue
            }

            if ($upgradeOut -match 'Successfully installed' -or $upgradeOut -match 'Successfully upgraded') {
                Write-Console ("    Updated: {0}" -f $tool.name) 'Green'
            } else {
                Write-Console ("    WinGet output for {0}: {1}" -f $tool.name, ($upgradeOut.Trim())) 'Gray'
            }
        } catch {
            Write-Console ("    WinGet remediation failed for {0}: {1}" -f $tool.name, $_.Exception.Message) 'Red'
        }
    }
}

function Scan-PreflightBaseline {
    Write-Console "── Building Pre-flight Baseline ──" "Yellow"

    $repos = @($script:ScanResults['PSRepositories'])
    $resourceRepos = @($script:ScanResults['PSResourceRepositories'])
    $mods = @($script:ScanResults['Modules'])
    $pkgProviders = @($script:ScanResults['PackageProviders'])
    $pkgSources = @($script:ScanResults['PackageSources'])
    $execRows = @($script:ScanResults['ExecutionPolicy'])
    $baselineConfig = Get-PrereqBaselineConfig

    $current = @{
        ModulesCount = (@($mods | Where-Object { $_.Status -in @('Installed', 'Workspace') }).Count)
        PSRepositoryTrusted = (@($repos | Where-Object { $_.Trusted }).Count)
        PSGalleryPresent = [bool]($repos | Where-Object { $_.Name -eq 'PSGallery' } | Select-Object -First 1)
        PackageProvidersCount = $pkgProviders.Count
        PackageSourcesTrusted = (@($pkgSources | Where-Object { $_.IsTrusted }).Count)
        ProcessExecPolicy = [string](($execRows | Where-Object { $_.Scope -eq 'Process' } | Select-Object -First 1).ExecutionPolicy)
        CurrentUserExecPolicy = [string](($execRows | Where-Object { $_.Scope -eq 'CurrentUser' } | Select-Object -First 1).ExecutionPolicy)
        PsModulePathSet = -not [string]::IsNullOrWhiteSpace($env:PSModulePath)
        PathSet = -not [string]::IsNullOrWhiteSpace($env:Path)
    }

    $baseline = @{
        ModulesCount = 10
        PSRepositoryTrusted = 1
        PSGalleryPresent = $true
        PackageProvidersCount = 2
        PackageSourcesTrusted = 1
        ProcessExecPolicy = 'RemoteSigned'
        CurrentUserExecPolicy = 'RemoteSigned'
        PsModulePathSet = $true
        PathSet = $true
    }

    $historyMap = @{}
    if ($script:historyCombo -and $script:historyCombo.SelectedItem) {
        $selectedPath = [string]$script:historyCombo.SelectedItem.Tag
        $historyMap = Get-HistoryBaselineValues -HistoryFile $selectedPath
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $checks = @(
        @{ Name='Modules installed'; Key='ModulesCount'; Impact='Module loading can fail for script and matrix scans.'; Fix='Install missing modules via Module Management.' },
        @{ Name='Trusted PS repositories'; Key='PSRepositoryTrusted'; Impact='Install/update actions may prompt or fail trust checks.'; Fix='Set-PSRepository -InstallationPolicy Trusted for approved repos.' },
        @{ Name='PSGallery available'; Key='PSGalleryPresent'; Impact='Public module install path unavailable.'; Fix='Register-PSRepository -Default.' },
        @{ Name='Package providers'; Key='PackageProvidersCount'; Impact='Package commands cannot resolve providers.'; Fix='Install-PackageProvider NuGet, PowerShellGet.' },
        @{ Name='Trusted package sources'; Key='PackageSourcesTrusted'; Impact='Package installation blocked/untrusted.'; Fix='Set-PackageSource -Trusted where appropriate.' },
        @{ Name='Process execution policy'; Key='ProcessExecPolicy'; Impact='Scripts may be blocked in current session.'; Fix='Set-ExecutionPolicy -Scope Process RemoteSigned.' },
        @{ Name='CurrentUser execution policy'; Key='CurrentUserExecPolicy'; Impact='Persistent script execution restrictions.'; Fix='Set-ExecutionPolicy -Scope CurrentUser RemoteSigned.' },
        @{ Name='PSModulePath set'; Key='PsModulePathSet'; Impact='Module auto-discovery is impaired.'; Fix='Restore PSModulePath env var.' },
        @{ Name='PATH set'; Key='PathSet'; Impact='Core tools and package commands may fail.'; Fix='Repair PATH in system/user environment variables.' }
    )

    foreach ($c in $checks) {
        $cur = $current[$c.Key]
        $base = $baseline[$c.Key]
        $hist = if ($historyMap.ContainsKey($c.Key)) { $historyMap[$c.Key] } else { '' }
        $status = 'OK'
        if ($cur -is [bool]) {
            if (-not $cur) { $status = 'ERROR' }
        } elseif ($cur -is [int]) {
            if ([int]$cur -lt [int]$base) { $status = 'WARN' }
        } else {
            if ([string]$cur -ne [string]$base) { $status = 'WARN' }
        }

        $rows.Add([pscustomobject]@{
            Check = $c.Name
            Baseline = [string]$base
            Current = [string]$cur
            History = [string]$hist
            Status = $status
            Impacted = $c.Impact
            Guidance = $c.Fix
        }) | Out-Null
    }

    # Config-driven app/tool minimum version checks
    foreach ($tool in @($baselineConfig.tools)) {
        $toolCurrent = Get-ToolVersionByKey -ToolKey ([string]$tool.key)
        $minVersion = [string]$tool.minimumVersion
        $recommendedVersion = [string]$tool.recommendedVersion
        $isRequired = [bool]$tool.required

        $status = 'OK'
        $guidance = ''
        if ([string]::IsNullOrWhiteSpace($toolCurrent)) {
            $status = if ($isRequired) { 'ERROR' } else { 'WARN' }
            $guidance = if ($tool.wingetId) {
                "Install via WinGet: winget install --id $($tool.wingetId)"
            } else {
                'Install or add this tool to PATH.'
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($minVersion) -and -not (Test-VersionAtLeast -CurrentVersion $toolCurrent -MinimumVersion $minVersion)) {
            $status = if ($isRequired) { 'WARN' } else { 'WARN' }
            $guidance = if ($tool.wingetId) {
                "Upgrade via WinGet: winget upgrade --id $($tool.wingetId)"
            } else {
                'Upgrade to baseline version or newer.'
            }
        }

        if ([string]::IsNullOrWhiteSpace($guidance)) {
            $guidance = if ($tool.wingetId) {
                "Optional refresh: winget upgrade --id $($tool.wingetId)"
            } else {
                'No action required.'
            }
        }

        $baselineText = if (-not [string]::IsNullOrWhiteSpace($recommendedVersion)) {
            "min $minVersion | stable $recommendedVersion"
        } else {
            "min $minVersion"
        }

        $rows.Add([pscustomobject]@{
            Check = "Prerequisite tool: $($tool.name)"
            Baseline = $baselineText
            Current = if ([string]::IsNullOrWhiteSpace($toolCurrent)) { 'Not detected' } else { $toolCurrent }
            History = ''
            Status = $status
            Impacted = if ($isRequired) { 'Core operability risk for update, automation, or launch flows.' } else { 'Optional capability unavailable.' }
            Guidance = $guidance
        }) | Out-Null
    }

    # Repository checks from baseline config
    if ($baselineConfig.repositories -and $baselineConfig.repositories.psRepository) {
        $reqPsRepoNames = @($baselineConfig.repositories.psRepository.requiredNames)
        foreach ($repoName in $reqPsRepoNames) {
            $repoRow = $repos | Where-Object { $_.Name -eq $repoName } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Check = "PSRepository present: $repoName"
                Baseline = 'required'
                Current = if ($repoRow) { 'Present' } else { 'Missing' }
                History = ''
                Status = if ($repoRow) { 'OK' } else { 'ERROR' }
                Impacted = 'Install-Module and update workflows can fail.'
                Guidance = "Register-PSRepository -Default or register '$repoName' manually."
            }) | Out-Null
        }

        $minTrusted = [int]$baselineConfig.repositories.psRepository.minimumTrustedCount
        $trustedCount = (@($repos | Where-Object { $_.Trusted }).Count)
        $rows.Add([pscustomobject]@{
            Check = 'Trusted PSRepository count'
            Baseline = ">= $minTrusted"
            Current = [string]$trustedCount
            History = ''
            Status = if ($trustedCount -ge $minTrusted) { 'OK' } else { 'WARN' }
            Impacted = 'Prompts or blocked installs for repository-backed packages.'
            Guidance = 'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted (or approved internal repos).'
        }) | Out-Null
    }

    if ($baselineConfig.repositories -and $baselineConfig.repositories.psResourceRepository) {
        $reqResRepoNames = @($baselineConfig.repositories.psResourceRepository.requiredNames)
        foreach ($repoName in $reqResRepoNames) {
            $repoRow = $resourceRepos | Where-Object { $_.Name -eq $repoName } | Select-Object -First 1
            $rows.Add([pscustomobject]@{
                Check = "PSResource repository present: $repoName"
                Baseline = 'required'
                Current = if ($repoRow) { 'Present' } else { 'Missing' }
                History = ''
                Status = if ($repoRow) { 'OK' } else { 'WARN' }
                Impacted = 'Find-PSResource / Install-PSResource may be unavailable for expected feeds.'
                Guidance = "Set-PSResourceRepository -Name '$repoName' -Trusted or register equivalent repository."
            }) | Out-Null
        }

        $minTrusted = [int]$baselineConfig.repositories.psResourceRepository.minimumTrustedCount
        $trustedCount = (@($resourceRepos | Where-Object { $_.Trusted }).Count)
        $rows.Add([pscustomobject]@{
            Check = 'Trusted PSResource repository count'
            Baseline = ">= $minTrusted"
            Current = [string]$trustedCount
            History = ''
            Status = if ($trustedCount -ge $minTrusted) { 'OK' } else { 'WARN' }
            Impacted = 'PSResource-based install/update flow may prompt or fail.'
            Guidance = 'Trust approved PSResource repositories for non-interactive installs.'
        }) | Out-Null
    }

    # Required module minimum version checks
    foreach ($modReq in @($baselineConfig.modules)) {
        $modName = [string]$modReq.name
        $modRequired = [bool]$modReq.required
        $modMinVersion = [string]$modReq.minimumVersion
        $installedVersion = Get-HighestModuleVersion -ModuleName $modName
        $status = 'OK'

        if ([string]::IsNullOrWhiteSpace($installedVersion)) {
            $status = if ($modRequired) { 'ERROR' } else { 'WARN' }
        } elseif (-not [string]::IsNullOrWhiteSpace($modMinVersion) -and -not (Test-VersionAtLeast -CurrentVersion $installedVersion -MinimumVersion $modMinVersion)) {
            $status = if ($modRequired) { 'WARN' } else { 'WARN' }
        }

        $rows.Add([pscustomobject]@{
            Check = "Required module: $modName"
            Baseline = if ([string]::IsNullOrWhiteSpace($modMinVersion)) { 'installed' } else { "min $modMinVersion" }
            Current = if ([string]::IsNullOrWhiteSpace($installedVersion)) { 'Not installed' } else { $installedVersion }
            History = ''
            Status = $status
            Impacted = 'Module-dependent scripts or package workflows can fail.'
            Guidance = "Install-Module -Name $modName -Scope CurrentUser -Force"
        }) | Out-Null
    }

    # Environment variable sanity from baseline config
    foreach ($ev in @($baselineConfig.environmentVariables)) {
        $evName = [string]$ev.name
        $isRequired = [bool]$ev.required
        $evCurrent = [System.Environment]::GetEnvironmentVariable($evName)
        $isSet = -not [string]::IsNullOrWhiteSpace($evCurrent)
        $rows.Add([pscustomobject]@{
            Check = "Environment variable: $evName"
            Baseline = if ($isRequired) { 'set' } else { 'optional' }
            Current = if ($isSet) { 'Set' } else { 'Missing/Empty' }
            History = ''
            Status = if ($isSet -or -not $isRequired) { 'OK' } else { 'ERROR' }
            Impacted = 'Tool discovery, module loading, and script execution may be unstable.'
            Guidance = "Set environment variable '$evName' at User or Machine scope as appropriate."
        }) | Out-Null
    }

    $script:ScanResults['PreflightBaseline'] = $rows.ToArray()
    $script:ScanResults['Environment'] = @([pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        PSVersion = [string]$PSVersionTable.PSVersion
        PSModulePath = $env:PSModulePath
        Path = $env:Path
        TimeStamp = (Get-Date).ToString('o')
    })

    Write-Console "  Pre-flight baseline checks: $($rows.Count)" "Green"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GUI BUILDER
# ═══════════════════════════════════════════════════════════════════════════════

function Build-ScannerGUI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PS Environment Scanner -- $WorkspacePath"
    $form.Size = New-Object System.Drawing.Size(1200, 800)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Top button bar
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = 'Top'
    $btnPanel.Height = 40
    $btnPanel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $form.Controls.Add($btnPanel)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = "Scan Now"
    $btnScan.Location = New-Object System.Drawing.Point(10, 7)
    $btnScan.Size = New-Object System.Drawing.Size(120, 26)
    $btnScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnScan.ForeColor = [System.Drawing.Color]::White
    $btnScan.FlatStyle = 'Flat'
    $btnScan.Add_Click({ Invoke-FullScan })
    $btnPanel.Controls.Add($btnScan)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "Export All (JSON)"
    $btnExport.Location = New-Object System.Drawing.Point(140, 7)
    $btnExport.Size = New-Object System.Drawing.Size(120, 26)
    $btnExport.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnExport.ForeColor = [System.Drawing.Color]::White
    $btnExport.FlatStyle = 'Flat'
    $btnExport.Add_Click({
        Start-RainbowProgress -StatusText 'Exporting scan results...'
        $scanDate = Get-Date -Format 'yyyyMMdd'
        $scanTime = Get-Date -Format 'HHmmss'
        $ip = (Get-PrimaryIPv4) -replace ':','-'
        $user = if ([string]::IsNullOrWhiteSpace($env:USERNAME)) { 'USER' } else { $env:USERNAME }
        $historyName = "{0}-{1}-{2}-{3}[{4}].json" -f $(if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { 'MACHINE' } else { $env:COMPUTERNAME }), $ip, $scanDate, $scanTime, $user
        $outPath = Join-Path $reportsDir $historyName
        if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
        Update-RainbowProgress -Percent 50 -StatusText ('Writing {0}...' -f $historyName)
        $script:ScanResults | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outPath -Encoding UTF8
        Complete-RainbowProgress -StatusText ('Exported: {0}' -f $historyName)
        Write-Console "Exported to: $outPath" "Green"
        [System.Windows.Forms.MessageBox]::Show("Exported to:`n$outPath", "Export Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $btnPanel.Controls.Add($btnExport)

    $btnPrereqWinget = New-Object System.Windows.Forms.Button
    $btnPrereqWinget.Text = "Run Prereq WinGet"
    $btnPrereqWinget.Location = New-Object System.Drawing.Point(270, 7)
    $btnPrereqWinget.Size = New-Object System.Drawing.Size(150, 26)
    $btnPrereqWinget.BackColor = [System.Drawing.Color]::FromArgb(70, 90, 45)
    $btnPrereqWinget.ForeColor = [System.Drawing.Color]::White
    $btnPrereqWinget.FlatStyle = 'Flat'
    $btnPrereqWinget.Add_Click({
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Run WinGet prerequisite remediation now?`n`nYes = Required + Optional tools`nNo = Required tools only`nCancel = Abort",
            'Prerequisite WinGet Remediation',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        Start-RainbowProgress -StatusText 'Running WinGet prerequisite remediation...'
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-PrerequisiteWingetUpdates -IncludeOptional
        } else {
            Invoke-PrerequisiteWingetUpdates
        }
        Update-RainbowProgress -Percent 80 -StatusText 'Refreshing pre-flight baseline...'

        Scan-PreflightBaseline
        Populate-AllGrids
        Complete-RainbowProgress -StatusText 'WinGet remediation complete'
    })
    $btnPanel.Controls.Add($btnPrereqWinget)

    # Cascade overlay checkbox
    $chkCascade = New-Object System.Windows.Forms.CheckBox
    $chkCascade.Text = "Show Cascade Failures Overlay"
    $chkCascade.Location = New-Object System.Drawing.Point(430, 10)
    $chkCascade.Size = New-Object System.Drawing.Size(230, 20)
    $chkCascade.ForeColor = [System.Drawing.Color]::OrangeRed
    $chkCascade.Add_CheckedChanged({
        if ($this.Checked) {
            Highlight-CascadeFailures
        } else {
            Populate-AllGrids  # Reset to normal
        }
    })
    $btnPanel.Controls.Add($chkCascade)

    # Rainbow progress bar (from PwShGUI-Theme module or inline fallback)
    $rainbowBarCreated = $false
    if (Get-Command New-RainbowProgressBar -ErrorAction SilentlyContinue) {  # SIN-EXEMPT:P042 -- Get-Command not invocation; -Width/-Height declared on target
        $script:RainbowBar = New-RainbowProgressBar -Width 280 -Height 16
        $script:RainbowBar.Panel.Location = New-Object System.Drawing.Point(670, 12)
        $script:RainbowBar.Panel.Visible = $false
        $btnPanel.Controls.Add($script:RainbowBar.Panel)
        $rainbowBarCreated = $true
    }

    # Status label (to right of progress bar)
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Ready -- Click 'Scan Now' to begin"
    $lblStatus.Location = New-Object System.Drawing.Point($(if ($rainbowBarCreated) { 960 } else { 670 }), 12)
    $lblStatus.Size = New-Object System.Drawing.Size($(if ($rainbowBarCreated) { 220 } else { 500 }), 18)
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblStatus.AutoSize = $false
    $btnPanel.Controls.Add($lblStatus)
    $script:RainbowStatusLabel = $lblStatus

    # Tab Control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = 'Fill'
    $tabControl.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $form.Controls.Add($tabControl)

    # Define tabs
    $tabDefs = @(
        @{ Name = 'Console';              Key = 'Console' },
        @{ Name = 'Scan Progress';        Key = 'ScanProgress' },
        @{ Name = 'Modules';              Key = 'Modules' },
        @{ Name = 'Scripts & Files';      Key = 'Scripts' },
        @{ Name = 'PSResourceRepos';      Key = 'PSResourceRepositories' },
        @{ Name = 'PSResources';          Key = 'PSResources' },
        @{ Name = 'Execution Policy';     Key = 'ExecutionPolicy' },
        @{ Name = 'PSRepositories';       Key = 'PSRepositories' },
        @{ Name = 'Packages';             Key = 'Packages' },
        @{ Name = 'Pkg Providers';        Key = 'PackageProviders' },
        @{ Name = 'PS Providers';         Key = 'PSProviders' },
        @{ Name = 'PS Drives';            Key = 'PSDrives' },
        @{ Name = 'Pkg Sources';          Key = 'PackageSources' },
        @{ Name = 'Logging & Diag';       Key = 'LoggingProviders' },
        @{ Name = 'Orphan Files';         Key = 'OrphanFiles' },
        @{ Name = 'Cascade Failures';     Key = 'CascadeFailures' },
        @{ Name = 'Pre-flight Baseline';  Key = 'PreflightBaseline' }
    )

    $script:grids = @{}

    foreach ($td in $tabDefs) {
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $td.Name
        $tab.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
        $tab.ForeColor = [System.Drawing.Color]::WhiteSmoke
        $tabControl.TabPages.Add($tab)

        if ($td.Key -eq 'Console') {
            # Console tab gets a RichTextBox
            $rtb = New-Object System.Windows.Forms.RichTextBox
            $rtb.Dock = 'Fill'
            $rtb.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
            $rtb.ForeColor = [System.Drawing.Color]::WhiteSmoke
            $rtb.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
            $rtb.ReadOnly = $true
            $rtb.WordWrap = $false
            $rtb.ScrollBars = 'Both'
            $tab.Controls.Add($rtb)
            $script:consoleBox = $rtb
        } else {
            # Summary label above grid
            $summaryLabel = New-Object System.Windows.Forms.Label
            $summaryLabel.Dock = 'Top'
            $summaryLabel.Height = 24
            $summaryLabel.Text = "  $($td.Name) -- scan not yet run"
            $summaryLabel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
            $summaryLabel.ForeColor = [System.Drawing.Color]::Cyan
            $summaryLabel.TextAlign = 'MiddleLeft'
            $summaryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
            $tab.Controls.Add($summaryLabel)

            # DataGridView
            $dgv = New-Object System.Windows.Forms.DataGridView
            $dgv.Dock = 'Fill'
            $dgv.BackgroundColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
            $dgv.ForeColor = [System.Drawing.Color]::WhiteSmoke
            $dgv.GridColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
            $dgv.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
            $dgv.DefaultCellStyle.ForeColor = [System.Drawing.Color]::WhiteSmoke
            $dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
            $dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
            $dgv.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
            $dgv.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::Cyan
            $dgv.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
            $dgv.EnableHeadersVisualStyles = $false
            $dgv.RowHeadersVisible = $false
            $dgv.AllowUserToAddRows = $false
            $dgv.AllowUserToDeleteRows = $false
            $dgv.ReadOnly = $true
            $dgv.AutoSizeColumnsMode = 'AllCells'
            $dgv.SelectionMode = 'FullRowSelect'
            $dgv.BorderStyle = 'None'
            $dgv.CellBorderStyle = 'SingleHorizontal'
            $dgv.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
            $tab.Controls.Add($dgv)

            $script:grids[$td.Key] = @{ Grid = $dgv; Summary = $summaryLabel }

            # Add filter row above every data grid (standard for all tabs)
            Add-GridFilterRow -TabPage $tab -Dgv $dgv -Key $td.Key

            # Wire up rainbow progress bar painting for the ScanProgress grid
            if ($td.Key -eq 'ScanProgress') {
                $dgv.Add_CellPainting({
                    param($sender, $e)
                    if ($e.RowIndex -lt 0) { return }
                    if (-not $sender.Columns.Contains('Percent')) { return }
                    if ($e.ColumnIndex -ne $sender.Columns['Percent'].Index) { return }
                    try {
                        $pRaw = $sender.Rows[$e.RowIndex].Cells['Percent'].Value
                        $pVal = 0
                        if ([int]::TryParse([string]$pRaw, [ref]$pVal)) {
                            Paint-RainbowProgressBar -Grid $sender -e $e -Percent $pVal
                        }
                    } catch { <# Intentional: non-fatal painting error #> }
                })
                # Also paint the Status column with step-phase colors
                $dgv.Add_CellFormatting({
                    param($sender, $e)
                    if ($e.RowIndex -lt 0) { return }
                    try {
                        $row = $sender.Rows[$e.RowIndex]
                        if ($sender.Columns.Contains('Status')) {
                            $status = [string]$row.Cells['Status'].Value
                            switch ($status) {
                                'Complete' { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::LimeGreen }
                                'Running'  { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Cyan }
                                'Pending'  { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
                                'Error'    { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                            }
                        }
                    } catch { <# Intentional: non-fatal #> }
                })
            }

            if ($td.Key -eq 'PreflightBaseline') {
                $historyPanel = New-Object System.Windows.Forms.Panel
                $historyPanel.Dock = 'Top'
                $historyPanel.Height = 28
                $historyPanel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)

                $historyLabel = New-Object System.Windows.Forms.Label
                $historyLabel.Text = 'History compare:'
                $historyLabel.Location = New-Object System.Drawing.Point(8, 6)
                $historyLabel.Size = New-Object System.Drawing.Size(100, 18)
                $historyLabel.ForeColor = [System.Drawing.Color]::WhiteSmoke
                $historyPanel.Controls.Add($historyLabel)

                $historyCombo = New-Object System.Windows.Forms.ComboBox
                $historyCombo.Location = New-Object System.Drawing.Point(112, 3)
                $historyCombo.Size = New-Object System.Drawing.Size(520, 22)
                $historyCombo.DropDownStyle = 'DropDownList'
                $historyCombo.DisplayMember = 'Text'
                $script:historyCombo = $historyCombo
                $historyPanel.Controls.Add($historyCombo)

                $refreshHistoryBtn = New-Object System.Windows.Forms.Button
                $refreshHistoryBtn.Text = 'Refresh History'
                $refreshHistoryBtn.Location = New-Object System.Drawing.Point(640, 2)
                $refreshHistoryBtn.Size = New-Object System.Drawing.Size(110, 24)
                $refreshHistoryBtn.Add_Click({
                    $historyCombo.Items.Clear()
                    $files = Get-ScanHistoryFiles
                    foreach ($hf in $files) {
                        $comboItem = New-Object PSObject -Property @{ Text = $hf.Name; Tag = $hf.FullName }
                        [void]$historyCombo.Items.Add($comboItem)
                    }
                    if ($historyCombo.Items.Count -gt 0) { $historyCombo.SelectedIndex = 0 }
                })
                $historyPanel.Controls.Add($refreshHistoryBtn)

                $historyCombo.Add_SelectedIndexChanged({
                    Scan-PreflightBaseline
                    Populate-AllGrids
                })

                $tab.Controls.Add($historyPanel)
                $historyPanel.BringToFront()
            }
        }
    }

    # Bring form controls to proper z-order
    $tabControl.BringToFront()

    return $form
}

function Get-GridSummaryText {
    <# Builds a summary string with totals, accumulated size and qty for each grid key #>
    param([string]$Key, [array]$Data)
    $count = $Data.Count
    $extra = ''

    # Compute accumulated size if the data has FileSize or FileSizeKB
    $totalSizeKB = 0
    $hasSizeCol = $false
    foreach ($item in $Data) {
        if ($null -ne $item.PSObject.Properties['FileSize']) {
            $hasSizeCol = $true
            $totalSizeKB += [math]::Round([long]$item.FileSize / 1KB, 1)
        } elseif ($null -ne $item.PSObject.Properties['FileSizeKB']) {
            $hasSizeCol = $true
            $totalSizeKB += [double]$item.FileSizeKB
        }
    }
    if ($hasSizeCol -and $totalSizeKB -gt 0) {
        if ($totalSizeKB -ge 1024) {
            $extra += (" | Total size: {0:N1} MB" -f ($totalSizeKB / 1024))
        } else {
            $extra += (" | Total size: {0:N1} KB" -f $totalSizeKB)
        }
    }

    # Key-specific summaries
    switch ($Key) {
        'ScanProgress' {
            $pending = @($Data | Where-Object { $_.Status -eq 'Pending' }).Count
            $running = @($Data | Where-Object { $_.Status -eq 'Running' }).Count
            $complete = @($Data | Where-Object { $_.Status -eq 'Complete' }).Count
            $error = @($Data | Where-Object { $_.Status -eq 'Error' }).Count
            $extra += " | Pending:$pending Running:$running Complete:$complete Error:$error"
        }
        'Modules' {
            $ws = @($Data | Where-Object { $_.Status -eq 'Workspace' }).Count
            $inst = @($Data | Where-Object { $_.Status -eq 'Installed' }).Count
            $miss = @($Data | Where-Object { $_.Status -eq 'Missing' }).Count
            $err = @($Data | Where-Object { $_.Status -eq 'Error' }).Count
            $extra += " | WS:$ws Inst:$inst Miss:$miss Err:$err"
        }
        'Scripts' {
            $types = $Data | Group-Object FileType | Sort-Object Count -Descending | Select-Object -First 4
            $typeSummary = ($types | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ' '
            if ($typeSummary) { $extra += " | $typeSummary" }
        }
        'OrphanFiles' {
            $orphans = @($Data | Where-Object { $_.Status -eq 'ORPHAN' }).Count
            $extra += " | Orphans: $orphans"
        }
        'ExecutionPolicy' {
            $critical = @($Data | Where-Object { $_.RiskLevel -in @('CRITICAL', 'HIGH') }).Count
            if ($critical -gt 0) { $extra += " | HIGH+CRITICAL: $critical" }
        }
        'PreflightBaseline' {
            $ok = @($Data | Where-Object { $_.Status -eq 'OK' }).Count
            $warn = @($Data | Where-Object { $_.Status -eq 'WARN' }).Count
            $errC = @($Data | Where-Object { $_.Status -eq 'ERROR' }).Count
            $extra += " | OK:$ok WARN:$warn ERR:$errC"
        }
        'CascadeFailures' {
            $crit = @($Data | Where-Object { $_.Impact -eq 'CRITICAL' }).Count
            $high = @($Data | Where-Object { $_.Impact -eq 'HIGH' }).Count
            if ($crit -gt 0 -or $high -gt 0) { $extra += " | CRIT:$crit HIGH:$high" }
        }
    }

    return "  $Key -- $count items$extra"
}

function Populate-GridByKey {
    param([string]$Key)
    if (-not $script:grids.ContainsKey($Key)) { return }
    $entry = $script:grids[$Key]
    $dgv = $entry.Grid
    $lbl = $entry.Summary

    if ($script:ScanResults.ContainsKey($Key)) {
        $data = $script:ScanResults[$Key]
        if ($data -and $data.Count -gt 0) {
            $dt = New-Object System.Data.DataTable
            $props = $data[0].PSObject.Properties
            foreach ($p in $props) {
                $colType = switch ($p.TypeNameOfValue) {
                    'System.Boolean' { [bool] }
                    'System.Int32'   { [int] }
                    'System.Int64'   { [long] }
                    'System.Double'  { [double] }
                    default          { [string] }
                }
                $dt.Columns.Add($p.Name, $colType) | Out-Null
            }
            foreach ($item in $data) {
                $row = $dt.NewRow()
                foreach ($p in $props) {
                    $val = $item.($p.Name)
                    $colType = $dt.Columns[$p.Name].DataType
                    if ($null -eq $val) {
                        $val = [DBNull]::Value
                    } elseif ($val -is [array]) {
                        $val = ($val -join ', ')
                    } elseif ($colType -eq [bool])   { $val = [bool]$val   }
                      elseif ($colType -eq [int])    { $val = [int]$val    }
                      elseif ($colType -eq [long])   { $val = [long]$val   }
                      elseif ($colType -eq [double]) { $val = [double]$val }
                      else                           { $val = [string]$val }
                    $row[$p.Name] = $val
                }
                $dt.Rows.Add($row) | Out-Null
            }
            $dgv.DataSource = $dt
            $lbl.Text = Get-GridSummaryText -Key $Key -Data $data
            Apply-RowColoring -Grid $dgv -Key $Key
        } else {
            $dgv.DataSource = $null
            $lbl.Text = "  $Key -- 0 items (empty)"
        }
    }
}

function Populate-AllGrids {
    foreach ($kv in $script:grids.GetEnumerator()) {
        try {
            Populate-GridByKey -Key $kv.Key
            Write-AppLog "Populate-AllGrids: bound key '$($kv.Key)'" 'Debug'
        } catch {
            Write-AppLog "Populate-AllGrids: failed to populate '$($kv.Key)' -- $($_.Exception.Message)" 'Warning'
        }
    }
}

# ─────────────────────────────────────────────────────────────────
# FILTER-CAPABLE COLUMN HEADER CONTROLS
# ─────────────────────────────────────────────────────────────────
$script:FilterPanels = @{}

function Add-GridFilterRow {
    <#
    .SYNOPSIS  Adds a filter TextBox panel above a DataGridView.
    .DESCRIPTION
        Creates a single TextBox that applies a DataView.RowFilter
        across all string columns of the bound DataTable.
        Type any text to filter rows containing that text in any column.
    #>
    param(
        [System.Windows.Forms.TabPage]$TabPage,
        [System.Windows.Forms.DataGridView]$Dgv,
        [string]$Key
    )
    if ($script:FilterPanels.ContainsKey($Key)) { return }

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Dock = 'Top'
    $filterPanel.Height = 26
    $filterPanel.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 42)

    $filterIcon = New-Object System.Windows.Forms.Label
    $filterIcon.Text = 'Filter:'
    $filterIcon.Location = New-Object System.Drawing.Point(6, 4)
    $filterIcon.Size = New-Object System.Drawing.Size(42, 18)
    $filterIcon.ForeColor = [System.Drawing.Color]::Gray
    $filterIcon.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $filterPanel.Controls.Add($filterIcon)

    $filterBox = New-Object System.Windows.Forms.TextBox
    $filterBox.Location = New-Object System.Drawing.Point(50, 3)
    $filterBox.Size = New-Object System.Drawing.Size(350, 20)
    $filterBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $filterBox.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $filterBox.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $filterBox.BorderStyle = 'FixedSingle'
    $filterBox.Tag = @{ Dgv = $Dgv; Key = $Key }

    $filterBox.Add_TextChanged({
        $info = $this.Tag
        $dgvRef = $info.Dgv
        $filterText = $this.Text.Trim()
        $ds = $dgvRef.DataSource
        if ($null -eq $ds -or $ds -isnot [System.Data.DataTable]) { return }
        if ([string]::IsNullOrWhiteSpace($filterText)) {
            $ds.DefaultView.RowFilter = ''
            return
        }
        # Escape single quotes for DataView filter syntax
        $escapedFilter = $filterText.Replace("'", "''")
        # Build OR filter across all string columns
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($col in $ds.Columns) {
            if ($col.DataType -eq [string]) {
                $parts.Add(("CONVERT([{0}], 'System.String') LIKE '%{1}%'" -f $col.ColumnName, $escapedFilter))
            }
        }
        if ($parts.Count -gt 0) {
            try { $ds.DefaultView.RowFilter = ($parts -join ' OR ') } catch { $ds.DefaultView.RowFilter = '' }
        }
    })

    $filterPanel.Controls.Add($filterBox)

    $clearBtn = New-Object System.Windows.Forms.Button
    $clearBtn.Text = 'X'
    $clearBtn.Location = New-Object System.Drawing.Point(404, 2)
    $clearBtn.Size = New-Object System.Drawing.Size(22, 22)
    $clearBtn.FlatStyle = 'Flat'
    $clearBtn.BackColor = [System.Drawing.Color]::FromArgb(60, 30, 30)
    $clearBtn.ForeColor = [System.Drawing.Color]::OrangeRed
    $clearBtn.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
    $clearBtn.Tag = $filterBox
    $clearBtn.Add_Click({ $this.Tag.Text = '' })
    $filterPanel.Controls.Add($clearBtn)

    $TabPage.Controls.Add($filterPanel)
    $filterPanel.BringToFront()
    $script:FilterPanels[$Key] = $filterPanel
}

function Apply-RowColoring {
    param($Grid, $Key)
    # Guard: only add handler once per grid key to prevent stacking
    if ($script:ColoredGrids.ContainsKey($Key)) { return }
    $script:ColoredGrids[$Key] = $true
    $Grid.Add_CellFormatting({
        param($gridSender, $e)
        if ($e.RowIndex -lt 0) { return }
        try {
            $row = $gridSender.Rows[$e.RowIndex]
            $statusCol = $null
            foreach ($col in $gridSender.Columns) {
                if ($col.Name -in @('Status', 'RiskLevel', 'Impact', 'ModuleStatus')) {
                    $statusCol = $col.Name
                    break
                }
            }
            if ($statusCol) {
                $statusVal = [string]$row.Cells[$statusCol].Value
                switch -Wildcard ($statusVal) {
                    'Missing*'   { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                    'Error*'     { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Red }
                    'ORPHAN'     { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                    'CRITICAL*'  { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Red }
                    'HIGH*'      { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed }
                    'Installed'  { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::LimeGreen }
                    'Workspace'  { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Cyan }
                    'Low'        { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::LimeGreen }
                    'Medium'     { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gold }
                }
            }

            if ($gridSender.Columns.Contains('Percent')) {
                $pRaw = $row.Cells['Percent'].Value
                $p = 0
                if ([int]::TryParse([string]$pRaw, [ref]$p)) {
                    $bc = if ($p -lt 35) {
                        [System.Drawing.Color]::FromArgb(55, 20, 20)
                    } elseif ($p -lt 70) {
                        [System.Drawing.Color]::FromArgb(55, 45, 10)
                    } else {
                        [System.Drawing.Color]::FromArgb(20, 55, 20)
                    }
                    if ($null -ne $bc) { $row.DefaultCellStyle.BackColor = $bc }
                }
            }

            if ($gridSender.Columns.Contains('Guidance') -and $gridSender.Columns.Contains('Impacted')) {
                $impact = [string]$row.Cells['Impacted'].Value
                $guide = [string]$row.Cells['Guidance'].Value
                $row.Cells['Status'].ToolTipText = "Impact: $impact`nFix: $guide"
            }
        } catch { <# Intentional: non-fatal #> }
    })
}

function Highlight-CascadeFailures {
    # Overlay cascade failures onto the Scripts tab
    $cascadeData = $script:ScanResults['CascadeFailures']
    if (-not $cascadeData -or $cascadeData.Count -eq 0) {
        Write-Console "No cascade failure data to overlay" "DarkYellow"
        return
    }

    $affectedScripts = @($cascadeData | Select-Object -ExpandProperty AffectedScript -Unique)
    $scriptsGrid = $script:grids['Scripts']
    if ($scriptsGrid -and $scriptsGrid.Grid.DataSource) {
        foreach ($row in $scriptsGrid.Grid.Rows) {
            $fileName = [string]$row.Cells['FileName'].Value
            if ($fileName -in $affectedScripts) {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(80, 20, 20)
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::OrangeRed
            }
        }
    }
    Write-Console "Cascade overlay applied -- $($affectedScripts.Count) scripts highlighted" "Red"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LAUNCH
# ═══════════════════════════════════════════════════════════════════════════════

$form = Build-ScannerGUI

if ($script:historyCombo) {
    try {
        $script:historyCombo.Items.Clear()
        $files = Get-ScanHistoryFiles
        foreach ($hf in $files) {
            $comboItem = New-Object PSObject -Property @{ Text = $hf.Name; Tag = $hf.FullName }
            [void]$script:historyCombo.Items.Add($comboItem)
        }
        if ($script:historyCombo.Items.Count -gt 0) { $script:historyCombo.SelectedIndex = 0 }
    } catch { <# Intentional: non-fatal #> }
}

if ($AutoScan) {
    $form.Add_Shown({ Invoke-FullScan })
}

# Relax strict mode before ShowDialog -- the WinForms message pump dispatches
# parent-scope event handlers (timer ticks, FormClosing) that reference
# $script: variables not set in *this* script scope.  Under StrictMode Latest
# those accesses throw "variable has not been set" (SIN-P022 scope bleed).
Set-StrictMode -Off
$form.ShowDialog() | Out-Null
Set-StrictMode -Version Latest
$form.Dispose()






<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





