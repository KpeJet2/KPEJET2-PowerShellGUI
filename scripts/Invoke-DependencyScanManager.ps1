# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Invoke-DependencyScanManager.ps1
# Orchestrates phased workspace dependency scanning with checkpoint persistence.
# Supports Full mode (complete rescan) and Incremental mode (missing/stale phases only).
# Writes per-phase checkpoints for crash recovery. Emits progress to scan-progress.json.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Full','Incremental')]
    [string]$Mode = 'Full',

    [string]$WorkspacePath = '',
    [string]$ConfigFile    = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Bootstrap ─────────────────────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($WorkspacePath)) {
    $WorkspacePath = Split-Path $ScriptDir -Parent
}

# Resolve config
if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $WorkspacePath 'config'
    $ConfigFile = Join-Path $ConfigFile 'dependency-scan-config.json'
}

# ─── Helpers ───────────────────────────────────────────────────────────────────
function Write-DSMLog {
    [CmdletBinding()]
    param([string]$Level = 'Info', [string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'Error'    { 'Red'     }
        'Warning'  { 'Yellow'  }
        'Critical' { 'Magenta' }
        default    { 'Cyan'    }
    }
    Write-Host "[$ts][DSM][$Level] $Message" -ForegroundColor $color
    try { Write-AppLog -Level $Level -Message "[DSM] $Message" } catch { <# non-fatal #> }
}

function Save-Checkpoint {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    [CmdletBinding()]
    param(
        [hashtable]$Checkpoint,
        [string]$CheckpointPath
    )
    try {
        $json = $Checkpoint | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $CheckpointPath -Value $json -Encoding UTF8 -Force
    } catch {
        Write-DSMLog -Level 'Warning' -Message "Could not save checkpoint: $_"
    }
}

function Load-Checkpoint {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    [CmdletBinding()]
    param([string]$CheckpointPath, [hashtable]$Default)
    if (Test-Path -LiteralPath $CheckpointPath) {
        try {
            $raw = Get-Content -LiteralPath $CheckpointPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrEmpty($raw)) {
                $obj = $raw | ConvertFrom-Json
                if ($null -ne $obj) {
                    return $obj
                }
            }
        } catch {
            Write-DSMLog -Level 'Warning' -Message "Could not load checkpoint, using default: $_"
        }
    }
    return $Default
}

function Write-ProgressLog {
    [CmdletBinding()]
    param([hashtable]$State, [string]$ProgressPath)
    try {
        $json = $State | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $ProgressPath -Value $json -Encoding UTF8 -Force
    } catch { <# non-fatal #> }
}

function New-Bug2FixItem {
    [CmdletBinding()]
    param(
        [string]$Title,
        [string]$Description,
        [string]$Category = 'scan-subroutine-failure',
        [string]$Priority = 'HIGH',
        [string[]]$Tags = @('scan','bug2fix')
    )
    $ts = Get-Date
    $stamp = $ts.ToString('yyyyMMddHHmmss')
    $seed = "$Title|$Description|$stamp"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))[0..3]).Replace('-','').ToLower()
    $sha.Dispose()
    $now = $ts.ToString('o')
    return [ordered]@{
        id              = "Bug-$stamp-$hash"
        type            = 'Bug'
        status          = 'OPEN'
        priority        = $Priority
        category        = $Category
        title           = $Title
        description     = $Description
        affectedFiles   = @()
        source          = 'Invoke-DependencyScanManager'
        created         = $now
        modified        = $now
        completedAt     = $null
        linkedFeatures  = @()
        linkedBugs      = @()
        tags            = $Tags
        notes           = 'Auto-created by LocalWebEngine scan manager resilience path.'
        sessionModCount = 0
        parentId        = ''
        executionAgent  = ''
    }
}

function Push-Bug2FixItem {
    [CmdletBinding()]
    param([hashtable]$BugItem, [string]$PipelinePath)
    if (-not (Test-Path -LiteralPath $PipelinePath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $PipelinePath -Raw -Encoding UTF8
        if ([string]::IsNullOrEmpty($raw)) { return $false }
        $pipe = $raw | ConvertFrom-Json
        if ($null -eq $pipe.bugs) { return $false }
        $exists = @($pipe.bugs | Where-Object { $null -ne $_ -and $_.id -eq $BugItem.id }).Count -gt 0
        if ($exists) { return $true }
        $newBugs = [System.Collections.ArrayList]@()
        foreach ($b in @($pipe.bugs)) { $null = $newBugs.Add($b) }
        $null = $newBugs.Add($BugItem)
        $pipe.bugs = @($newBugs)
        if ($null -ne $pipe.meta) { $pipe.meta.lastModified = (Get-Date -Format 'o') }
        Set-Content -LiteralPath $PipelinePath -Value ($pipe | ConvertTo-Json -Depth 10) -Encoding UTF8 -Force
        return $true
    } catch {
        Write-DSMLog -Level 'Warning' -Message "Could not push Bug2FIX item: $($_.Exception.Message)"
        return $false
    }
}

function Get-AgeMinutes {
    [CmdletBinding()]
    param([string]$Timestamp)
    if ([string]::IsNullOrEmpty($Timestamp)) { return 99999 }
    try {
        $dt = [datetime]::Parse($Timestamp)
        $diff = (Get-Date) - $dt
        # P021: guard division
        if ($diff.TotalMinutes -gt 0) { return [int]$diff.TotalMinutes }
        return 0
    } catch { return 99999 }
}

function Test-PhaseStale {
    [CmdletBinding()]
    param($PhaseObj, [int]$MaxAgeMinutes = 60)
    if ($null -eq $PhaseObj) { return $true }
    if ($null -eq $PhaseObj.status -or $PhaseObj.status -ne 'done') { return $true }
    if ($null -eq $PhaseObj.timestamp) { return $true }
    $ageMin = Get-AgeMinutes -Timestamp $PhaseObj.timestamp
    return ($ageMin -gt $MaxAgeMinutes)
}

# ─── Load config ───────────────────────────────────────────────────────────────
$cfg = $null
try {
    if (Test-Path -LiteralPath $ConfigFile) {
        $cfgRaw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrEmpty($cfgRaw)) {
            $cfg = $cfgRaw | ConvertFrom-Json
        }
    }
} catch {
    Write-DSMLog -Level 'Warning' -Message "Could not load config from '$ConfigFile': $_"
}

# Derive paths (P015: no hardcoded paths)
$checkpointRel = if ($null -ne $cfg -and $null -ne $cfg.paths -and -not [string]::IsNullOrEmpty($cfg.paths.checkpointFile)) {
    $cfg.paths.checkpointFile } else { Join-Path 'checkpoints' 'dependency-scan-checkpoint.json' }
$crashDumpRel  = if ($null -ne $cfg -and $null -ne $cfg.paths -and -not [string]::IsNullOrEmpty($cfg.paths.crashDumpDir)) {
    $cfg.paths.crashDumpDir } else { Join-Path 'logs' 'crash-dumps' }
$progressRel   = if ($null -ne $cfg -and $null -ne $cfg.paths -and -not [string]::IsNullOrEmpty($cfg.paths.scanProgressLog)) {
    $cfg.paths.scanProgressLog } else { Join-Path 'logs' 'scan-progress.json' }
$scanScriptRel = if ($null -ne $cfg -and $null -ne $cfg.scan -and -not [string]::IsNullOrEmpty($cfg.scan.scanScriptPath)) {
    $cfg.scan.scanScriptPath } else { Join-Path 'scripts' 'Invoke-WorkspaceDependencyMap.ps1' }

$checkpointPath = Join-Path $WorkspacePath $checkpointRel
$crashDumpPath  = Join-Path $WorkspacePath $crashDumpRel
$progressPath   = Join-Path $WorkspacePath $progressRel
$scanScriptPath = Join-Path $WorkspacePath $scanScriptRel
$pipelinePath   = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
$staleMins      = if ($null -ne $cfg -and $null -ne $cfg.staleness) { [int]$cfg.staleness.greenMaxMinutes } else { 60 }
$maxRetries     = if ($null -ne $cfg -and $null -ne $cfg.scan)      { [int]$cfg.scan.maxRetries }           else { 3  }

# Import core module for Write-CrashDump / Write-AppLog
$coreModPath = Join-Path $WorkspacePath 'modules'
$coreModPath = Join-Path $coreModPath 'PwShGUICore.psm1'
if (Test-Path -LiteralPath $coreModPath) {
    try { Import-Module $coreModPath -Force } catch { <# non-fatal — continue without module #> }
}

# ─── Ensure directories exist ──────────────────────────────────────────────────
foreach ($dirPath in @($crashDumpPath, (Split-Path $progressPath))) {
    if (-not (Test-Path $dirPath)) {
        try { $null = New-Item -Path $dirPath -ItemType Directory -Force } catch { <# non-fatal #> }
    }
}

# ─── Load checkpoint ───────────────────────────────────────────────────────────
$phaseIds = @('folders','modules','scripts','configs','urls_ips','dns_resolution')

$defaultCheckpoint = [ordered]@{
    lastFullScan        = $null
    lastIncrementalScan = $null
    currentScanMode     = $null
    currentScanPid      = $null
    phases              = [ordered]@{}
    fileHashes          = [ordered]@{}
    dataFile            = $null
    version             = '1.0'
}
foreach ($pid2 in $phaseIds) {
    $defaultCheckpoint.phases[$pid2] = [ordered]@{
        status = 'pending'; timestamp = $null; hash = $null; itemCount = 0; error = $null; durationMs = 0
    }
}

$cp = Load-Checkpoint -CheckpointPath $checkpointPath -Default $defaultCheckpoint

# ─── Determine which phases to run ─────────────────────────────────────────────
$phasesToRun = [System.Collections.ArrayList]@()

if ($Mode -eq 'Full') {
    Write-DSMLog -Level 'Info' -Message "Mode=Full — scheduling all 6 phases"
    foreach ($pid2 in $phaseIds) { $null = $phasesToRun.Add($pid2) }
} else {
    Write-DSMLog -Level 'Info' -Message "Mode=Incremental — checking which phases are stale or missing"
    foreach ($pid2 in $phaseIds) {
        $phaseObj = $null
        if ($null -ne $cp.phases -and $null -ne $cp.phases.$pid2) {
            $phaseObj = $cp.phases.$pid2
        }
        if (Test-PhaseStale -PhaseObj $phaseObj -MaxAgeMinutes $staleMins) {
            Write-DSMLog -Level 'Info' -Message "  Phase '$pid2' is stale/missing — will rescan"
            $null = $phasesToRun.Add($pid2)
        } else {
            Write-DSMLog -Level 'Info' -Message "  Phase '$pid2' is fresh — skipped"
        }
    }
}

$totalPhases = @($phasesToRun).Count
if ($totalPhases -eq 0) {
    Write-DSMLog -Level 'Info' -Message "All phases are fresh. Nothing to scan."
    exit 0
}

# ─── Progress state ────────────────────────────────────────────────────────────
$progressState = [ordered]@{
    mode          = $Mode
    status        = 'running'
    startedAt     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    finishedAt    = $null
    totalPhases   = $totalPhases
    completedPhases = 0
    currentPhase  = $null
    phasesStatus  = [ordered]@{}
    error         = $null
    activity      = @()
}
foreach ($pid2 in $phaseIds) { $progressState.phasesStatus[$pid2] = 'pending' }

function Add-ProgressEvent {
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$Phase = ''
    )
    $evt = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        level     = $Level
        phase     = $Phase
        message   = $Message
    }
    $State.activity += $evt
    if (@($State.activity).Count -gt 120) {
        $State.activity = @($State.activity | Select-Object -Last 120)
    }
    Write-ProgressLog -State $State -ProgressPath $progressPath
}

Write-ProgressLog -State $progressState -ProgressPath $progressPath
Add-ProgressEvent -State $progressState -Message "Scan job initialised (mode: $Mode)" -Level 'INFO'

# ─── Mark scan as in-progress in checkpoint ────────────────────────────────────
if ($null -ne $cp.phases -and $cp -is [hashtable]) {
    $cp.currentScanMode = $Mode
    $cp.currentScanPid  = $PID
} else {
    try { Add-Member -InputObject $cp -MemberType NoteProperty -Name 'currentScanMode' -Value $Mode -Force } catch { <# non-fatal #> }
    try { Add-Member -InputObject $cp -MemberType NoteProperty -Name 'currentScanPid'  -Value $PID  -Force } catch { <# non-fatal #> }
}

# Convert PSObject checkpoint to ordered hashtable for serialisation (P026: no direct PSObject cast)
$cpSaveEarly = [ordered]@{}
foreach ($prop in @($cp.PSObject.Properties)) { $cpSaveEarly[$prop.Name] = $prop.Value }
Save-Checkpoint -Checkpoint $cpSaveEarly -CheckpointPath $checkpointPath
foreach ($prop in @($cp.PSObject.Properties)) { $cpSaveEarly[$prop.Name] = $prop.Value }
Save-Checkpoint -Checkpoint $cpSaveEarly -CheckpointPath $checkpointPath

# ─── Run the actual scan via Invoke-WorkspaceDependencyMap ─────────────────────
# The scan script handles all phases internally; we checkpoint per completion below.
# P010: use & operator, never iex
$scanSuccess     = $false
$scanPartial     = $false
$scanErrorMsg    = ''
$scanStackTrace  = ''
$staticFallbackMsg = ''
$scanStopwatch   = [System.Diagnostics.Stopwatch]::StartNew()

Write-DSMLog -Level 'Info' -Message "Starting scan: Mode=$Mode, Phases=$($phasesToRun -join ',')"
Write-DSMLog -Level 'Info' -Message "Script: $scanScriptPath"
Add-ProgressEvent -State $progressState -Message "Primary scan started: $(Split-Path $scanScriptPath -Leaf)" -Level 'INFO'

for ($retry = 0; $retry -le $maxRetries; $retry++) {
    if ($retry -gt 0) {
        Write-DSMLog -Level 'Warning' -Message "Retry $retry/$maxRetries after failure..."
        Add-ProgressEvent -State $progressState -Message "Retry $retry of $maxRetries after failure" -Level 'WARN'
        Start-Sleep -Seconds 3
    }

    try {
        if ($WhatIf) {
            Write-DSMLog -Level 'Info' -Message "[WhatIf] Would run: & '$scanScriptPath' -WorkspacePath '$WorkspacePath'"
            $scanSuccess = $true
            Add-ProgressEvent -State $progressState -Message '[WhatIf] Primary scan skipped and marked success' -Level 'INFO'
        } elseif (Test-Path -LiteralPath $scanScriptPath) {
            # Run and capture output — Phase checkpointing happens inline after each phase
            $null = & $scanScriptPath -WorkspacePath $WorkspacePath
            $scanSuccess = $true
            Add-ProgressEvent -State $progressState -Message 'Primary scan script completed successfully' -Level 'INFO'
        } else {
            Write-DSMLog -Level 'Error' -Message "Scan script not found: $scanScriptPath"
            $scanSuccess = $false
            $scanErrorMsg = "Scan script not found: $scanScriptPath"
            Add-ProgressEvent -State $progressState -Message $scanErrorMsg -Level 'ERROR'
        }
        if ($scanSuccess) { break }
    } catch {
        $scanErrorMsg   = $_.Exception.Message
        $scanStackTrace = $_.ScriptStackTrace
        Write-DSMLog -Level 'Error' -Message "Scan failed (attempt $($retry+1)): $scanErrorMsg"
        Add-ProgressEvent -State $progressState -Message "Primary scan attempt $($retry+1) failed: $scanErrorMsg" -Level 'ERROR'
    }
}

if (-not $scanSuccess -and -not $WhatIf) {
    $staticScriptPath = Join-Path (Join-Path $WorkspacePath 'scripts') 'Invoke-StaticWorkspaceScan.ps1'
    if (Test-Path -LiteralPath $staticScriptPath) {
        try {
            $staticFallbackMsg = "Primary scan failed; falling back to static scan: $(Split-Path $staticScriptPath -Leaf)"
            Write-DSMLog -Level 'Warning' -Message $staticFallbackMsg
            Add-ProgressEvent -State $progressState -Message $staticFallbackMsg -Level 'WARN'
            $null = & $staticScriptPath -WorkspacePath $WorkspacePath
            $scanSuccess = $true
            $scanPartial = $true
            Add-ProgressEvent -State $progressState -Message 'Static fallback scan completed' -Level 'WARN'
        } catch {
            $scanErrorMsg = if ([string]::IsNullOrEmpty($scanErrorMsg)) { $_.Exception.Message } else { "$scanErrorMsg | static fallback failed: $($_.Exception.Message)" }
            Add-ProgressEvent -State $progressState -Message "Static fallback failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    } else {
        Add-ProgressEvent -State $progressState -Message "Static fallback script missing: $staticScriptPath" -Level 'ERROR'
    }
}

$scanStopwatch.Stop()

# ─── Update checkpoint phases on scan completion ───────────────────────────────
$nowTs = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

if ($scanSuccess) {
    foreach ($pid2 in $phasesToRun) {
        $progressState.phasesStatus[$pid2] = 'done'
        $progressState.completedPhases++
    }
    $progressState.status = if ($scanPartial) { 'partial' } else { 'done' }
    $progressState.finishedAt = $nowTs
    if ($scanPartial) {
        $progressState.error = $staticFallbackMsg
        Write-DSMLog -Level 'Warning' -Message "Scan completed with fallback in $([int]$scanStopwatch.Elapsed.TotalSeconds)s"
    } else {
        Write-DSMLog -Level 'Info' -Message "Scan completed in $([int]$scanStopwatch.Elapsed.TotalSeconds)s"
    }
} else {
    $progressState.status = 'error'
    $progressState.finishedAt = $nowTs
    $progressState.error = $scanErrorMsg

    # Write crash dump for final failure (P010: no iex)
    try {
        Write-CrashDump `
            -Phase           'dependency-scan' `
            -ErrorMessage    $scanErrorMsg `
            -StackTraceText  $scanStackTrace `
            -RetryCount      $maxRetries `
            -CrashDumpDir    $crashDumpPath `
            -ExtraContext    @{ mode = $Mode; script = $scanScriptPath }
    } catch {
        Write-DSMLog -Level 'Warning' -Message "Could not write crash dump: $_"
    }
}

Write-ProgressLog -State $progressState -ProgressPath $progressPath
if ($scanPartial -or -not $scanSuccess) {
    $bugTitle = if ($scanPartial) {
        "[SCAN PARTIAL] Dependency scan used static fallback ($Mode)"
    } else {
        "[SCAN FAIL] Dependency scan failed ($Mode)"
    }
    $bugDesc = if ($scanPartial) {
        "Primary script '$scanScriptPath' failed and static fallback was used. Last error: $scanErrorMsg"
    } else {
        "Dependency scan failed after retries. Script: $scanScriptPath. Error: $scanErrorMsg"
    }
    $bug = New-Bug2FixItem -Title $bugTitle -Description $bugDesc -Category 'scan-subroutine-failure' -Priority 'HIGH' -Tags @('scan','bug2fix',$Mode.ToLower())
    $pushed = Push-Bug2FixItem -BugItem $bug -PipelinePath $pipelinePath
    if ($pushed) {
        Add-ProgressEvent -State $progressState -Message "Bug2FIX created: $($bug.id)" -Level 'WARN'
    } else {
        Add-ProgressEvent -State $progressState -Message 'Bug2FIX creation failed or pipeline unavailable' -Level 'WARN'
    }
}

# ─── Reload pointer file to update checkpoint with output file info ────────────
$reportsDir  = Join-Path $WorkspacePath '~REPORTS'
$pointerFile = Join-Path $reportsDir 'workspace-dependency-map-pointer.json'
if (Test-Path -LiteralPath $pointerFile) {
    try {
        $ptRaw = Get-Content -LiteralPath $pointerFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrEmpty($ptRaw)) {
            $pt = $ptRaw | ConvertFrom-Json
            if ($null -ne $pt -and $null -ne $pt.latest) {
                try { Add-Member -InputObject $cp -MemberType NoteProperty -Name 'dataFile' -Value $pt.latest -Force } catch { <# non-fatal #> }
            }
        }
    } catch { <# non-fatal #> }
}

# Update phase timestamps
foreach ($pid2 in $phaseIds) {
    $phaseStatus = if ($phasesToRun -contains $pid2) {
        if ($scanSuccess) { 'done' } else { 'error' }
    } else { 'skipped' }

    $newPhase = [ordered]@{
        status     = $phaseStatus
        timestamp  = $nowTs
        hash       = $null
        itemCount  = 0
        error      = if (-not $scanSuccess -and $phasesToRun -contains $pid2) { $scanErrorMsg } else { $null }
        durationMs = if ($phasesToRun -contains $pid2) { [int]$scanStopwatch.Elapsed.TotalMilliseconds } else { 0 }
    }

    try { Add-Member -InputObject $cp.phases -MemberType NoteProperty -Name $pid2 -Value $newPhase -Force } catch { <# non-fatal #> }
}

if ($scanSuccess) {
    try { Add-Member -InputObject $cp -MemberType NoteProperty -Name 'lastFullScan' -Value $nowTs -Force } catch { <# non-fatal #> }
}
# Convert PSObject checkpoint to ordered hashtable for serialisation (P026: iterate PSObject.Properties, never cast collection directly)
$cpSave = [ordered]@{}
foreach ($prop in @($cp.PSObject.Properties)) { $cpSave[$prop.Name] = $prop.Value }
Save-Checkpoint -Checkpoint $cpSave -CheckpointPath $checkpointPath

if ($scanSuccess) {
    Write-DSMLog -Level 'Info' -Message "Checkpoint saved. Scan complete."
    Write-ProcessBanner -ProcessName "DependencyScanManager [$Mode]" -Stopwatch $scanStopwatch -Success $true
    exit 0
} else {
    Write-ProcessBanner -ProcessName "DependencyScanManager [$Mode]" -Stopwatch $scanStopwatch -Success $false
    exit 1
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





